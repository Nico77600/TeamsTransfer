// =============================================================================
//  TeamsTransfer - engine: adaptive rate limiter
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.2
//
//  Why this file exists:
//    Microsoft Graph throttles per application and per tenant, with different budgets per endpoint family, and
//    the Teams import API adds a hard limit of 5 requests per second PER CONVERSATION. Reacting to 429 only
//    (retry, wait, retry) wastes most of the quota: every worker keeps hammering a closed door. The limiter sits
//    in front of every request (GraphClient asks it before each attempt) and does four things:
//      - a pacing "bucket" per EndpointClass, starting at InitialRatePerSecond;
//      - AIMD: a 429/503 halves the rate of that class (floor MinRatePerSecond) and pauses the class for the
//        Retry-After delay; N consecutive successes raise it by a fixed step up to a ceiling;
//      - an optional per-thread (per-conversation) bucket at a fixed rate, only for the classes that carry the
//        import limit; idle buckets are evicted so memory stays bounded over 100k+ conversations;
//      - a process-wide concurrency gate (MaxConcurrency requests in flight).
//    Pacing is done by reserving the next free time slot (no burst, no timers, O(1) per request), which keeps the
//    logic deterministic. Time is read and waited through IClock so that the tests run on virtual time.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    /// <summary>Time source and delay, injectable so that tests never really sleep.</summary>
    public interface IClock
    {
        DateTimeOffset UtcNow { get; }
        Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
    }

    public sealed class SystemClock : IClock
    {
        public static readonly SystemClock Instance = new SystemClock();
        public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            if (delay <= TimeSpan.Zero) return Task.CompletedTask;
            return Task.Delay(delay, cancellationToken);
        }
    }

    /// <summary>Gate in front of every Graph attempt. The returned lease must be disposed when the attempt ends.</summary>
    public interface IRateLimiter
    {
        /// <summary>Waits for the class pacing (and the per-thread pacing when applicable), then for a concurrency slot.</summary>
        Task<IDisposable> AcquireAsync(string endpointClass, string threadKey, CancellationToken cancellationToken);
        void OnSuccess(string endpointClass);
        /// <summary>A 429/503 was received. retryAfter is the server delay when present.</summary>
        void OnThrottled(string endpointClass, TimeSpan? retryAfter);
        RateLimiterSnapshot Snapshot();
    }

    public sealed class RateLimiterOptions
    {
        public double InitialRatePerSecond { get; set; } = 20;
        /// <summary>Optional starting rate for specific classes (key = EndpointClass constant).</summary>
        public Dictionary<string, double> InitialRateByClass { get; } = new Dictionary<string, double>(StringComparer.Ordinal);
        public double MinRatePerSecond { get; set; } = 0.5;
        public double MaxRatePerSecond { get; set; } = 200;
        /// <summary>Multiplier applied to the rate on a 429/503.</summary>
        public double DecreaseFactor { get; set; } = 0.5;
        /// <summary>Consecutive successes needed to add IncreaseStep.</summary>
        public int SuccessesBeforeIncrease { get; set; } = 50;
        public double IncreaseStep { get; set; } = 1.0;
        /// <summary>Pause applied when a 429/503 carries no Retry-After.</summary>
        public TimeSpan DefaultThrottlePause { get; set; } = TimeSpan.FromSeconds(1);
        public int MaxConcurrency { get; set; } = 32;
        public double PerThreadRatePerSecond { get; set; } = 5;
        /// <summary>Classes subject to the per-thread limit (only when the request has a ThreadKey).</summary>
        public HashSet<string> PerThreadClasses { get; } = new HashSet<string>(StringComparer.Ordinal)
            { EndpointClass.ImportMessage, EndpointClass.ChannelReplies };
        public TimeSpan ThreadIdleEviction { get; set; } = TimeSpan.FromMinutes(2);
        public TimeSpan EvictionSweepInterval { get; set; } = TimeSpan.FromSeconds(30);
        public IClock Clock { get; set; } = SystemClock.Instance;
    }

    public sealed class RateClassSnapshot
    {
        public string EndpointClass { get; set; }
        public double RatePerSecond { get; set; }
        public DateTimeOffset? PausedUntil { get; set; }
        public long Requests { get; set; }
        public long Successes { get; set; }
        public long Throttled { get; set; }
    }

    public sealed class RateLimiterSnapshot
    {
        public DateTimeOffset At { get; set; }
        public int MaxConcurrency { get; set; }
        public int InFlight { get; set; }
        public int ThreadBuckets { get; set; }
        public IReadOnlyList<RateClassSnapshot> Classes { get; set; }
    }

    public sealed class AdaptiveRateLimiter : IRateLimiter
    {
        private sealed class ClassState
        {
            public readonly object Gate = new object();
            public double Rate;
            public DateTimeOffset NextSlot = DateTimeOffset.MinValue;
            public DateTimeOffset PausedUntil = DateTimeOffset.MinValue;
            public int ConsecutiveSuccesses;
            public long Requests, Successes, Throttled;
        }

        private sealed class ThreadBucket
        {
            public readonly object Gate = new object();
            public DateTimeOffset NextSlot = DateTimeOffset.MinValue;
            public DateTimeOffset LastUsed;
            public bool Removed;
        }

        private sealed class Lease : IDisposable
        {
            private AdaptiveRateLimiter _owner;
            public Lease(AdaptiveRateLimiter owner) { _owner = owner; }
            public void Dispose()
            {
                var o = Interlocked.Exchange(ref _owner, null);
                if (o == null) return;
                Interlocked.Decrement(ref o._inFlight);
                o._gate.Release();
            }
        }

        private readonly RateLimiterOptions _o;
        private readonly IClock _clock;
        private readonly ConcurrentDictionary<string, ClassState> _classes = new ConcurrentDictionary<string, ClassState>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, ThreadBucket> _threads = new ConcurrentDictionary<string, ThreadBucket>(StringComparer.Ordinal);
        private readonly SemaphoreSlim _gate;
        private int _inFlight;
        private long _lastSweepTicks;

        public AdaptiveRateLimiter(RateLimiterOptions options = null)
        {
            _o = options ?? new RateLimiterOptions();
            _clock = _o.Clock ?? SystemClock.Instance;
            if (_o.MaxConcurrency < 1) throw new ArgumentOutOfRangeException(nameof(options), "MaxConcurrency must be >= 1");
            _gate = new SemaphoreSlim(_o.MaxConcurrency, _o.MaxConcurrency);
            _lastSweepTicks = _clock.UtcNow.UtcTicks;
        }

        private ClassState State(string cls)
        {
            return _classes.GetOrAdd(cls ?? EndpointClass.Other, k =>
            {
                double r;
                if (!_o.InitialRateByClass.TryGetValue(k, out r)) r = _o.InitialRatePerSecond;
                return new ClassState { Rate = Math.Min(_o.MaxRatePerSecond, Math.Max(_o.MinRatePerSecond, r)) };
            });
        }

        private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) { return a >= b ? a : b; }

        public async Task<IDisposable> AcquireAsync(string endpointClass, string threadKey, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string cls = endpointClass ?? EndpointClass.Other;
            var st = State(cls);
            var now = _clock.UtcNow;
            MaybeSweep(now);

            // 1. per-thread slot (only for the import-limited classes)
            DateTimeOffset start = now;
            if (!string.IsNullOrEmpty(threadKey) && _o.PerThreadClasses.Contains(cls) && _o.PerThreadRatePerSecond > 0)
            {
                var interval = TimeSpan.FromSeconds(1.0 / _o.PerThreadRatePerSecond);
                while (true)
                {
                    var tb = _threads.GetOrAdd(threadKey, _ => new ThreadBucket());
                    lock (tb.Gate)
                    {
                        if (tb.Removed) continue;
                        start = Max(now, tb.NextSlot);
                        tb.NextSlot = start + interval;
                        tb.LastUsed = start;
                    }
                    break;
                }
            }

            // 2. class slot, never before the thread slot
            lock (st.Gate)
            {
                start = Max(start, Max(st.NextSlot, st.PausedUntil));
                st.NextSlot = start + TimeSpan.FromSeconds(1.0 / st.Rate);
                st.Requests++;
            }

            var wait = start - now;
            if (wait > TimeSpan.Zero) await _clock.DelayAsync(wait, cancellationToken).ConfigureAwait(false);

            // A 429 may have paused the class while we were waiting for our slot.
            while (true)
            {
                DateTimeOffset paused;
                lock (st.Gate) paused = st.PausedUntil;
                var remaining = paused - _clock.UtcNow;
                if (remaining <= TimeSpan.Zero) break;
                await _clock.DelayAsync(remaining, cancellationToken).ConfigureAwait(false);
            }

            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            Interlocked.Increment(ref _inFlight);
            return new Lease(this);
        }

        public void OnSuccess(string endpointClass)
        {
            var st = State(endpointClass);
            lock (st.Gate)
            {
                st.Successes++;
                if (++st.ConsecutiveSuccesses >= _o.SuccessesBeforeIncrease)
                {
                    st.ConsecutiveSuccesses = 0;
                    st.Rate = Math.Min(_o.MaxRatePerSecond, st.Rate + _o.IncreaseStep);
                }
            }
        }

        public void OnThrottled(string endpointClass, TimeSpan? retryAfter)
        {
            var st = State(endpointClass);
            var now = _clock.UtcNow;
            var pause = retryAfter ?? _o.DefaultThrottlePause;
            lock (st.Gate)
            {
                st.Throttled++;
                st.ConsecutiveSuccesses = 0;
                // Several in-flight requests of the same class usually fail together: halve once per pause window.
                if (now >= st.PausedUntil)
                    st.Rate = Math.Max(_o.MinRatePerSecond, st.Rate * _o.DecreaseFactor);
                st.PausedUntil = Max(st.PausedUntil, now + pause);
            }
        }

        private void MaybeSweep(DateTimeOffset now)
        {
            long last = Interlocked.Read(ref _lastSweepTicks);
            if (now.UtcTicks - last < _o.EvictionSweepInterval.Ticks) return;
            if (Interlocked.CompareExchange(ref _lastSweepTicks, now.UtcTicks, last) != last) return;
            EvictIdleThreadBuckets();
        }

        /// <summary>Removes the per-thread buckets idle for ThreadIdleEviction. Returns how many were removed.</summary>
        public int EvictIdleThreadBuckets()
        {
            var now = _clock.UtcNow;
            int removed = 0;
            foreach (var kv in _threads)
            {
                var tb = kv.Value;
                lock (tb.Gate)
                {
                    if (tb.Removed) continue;
                    if (now - tb.LastUsed < _o.ThreadIdleEviction || tb.NextSlot > now) continue;
                    tb.Removed = true;
                }
                ThreadBucket ignored;
                if (_threads.TryRemove(kv.Key, out ignored)) removed++;
            }
            return removed;
        }

        public RateLimiterSnapshot Snapshot()
        {
            var now = _clock.UtcNow;
            var list = new List<RateClassSnapshot>();
            foreach (var kv in _classes.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                var st = kv.Value;
                lock (st.Gate)
                {
                    list.Add(new RateClassSnapshot
                    {
                        EndpointClass = kv.Key,
                        RatePerSecond = st.Rate,
                        PausedUntil = st.PausedUntil > now ? (DateTimeOffset?)st.PausedUntil : null,
                        Requests = st.Requests,
                        Successes = st.Successes,
                        Throttled = st.Throttled
                    });
                }
            }
            return new RateLimiterSnapshot
            {
                At = now,
                MaxConcurrency = _o.MaxConcurrency,
                InFlight = Volatile.Read(ref _inFlight),
                ThreadBuckets = _threads.Count,
                Classes = list
            };
        }
    }
}
