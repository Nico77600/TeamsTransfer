// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// =============================================================================
//  TeamsTransfer - fake Microsoft Graph: fault injection, quotas and counters
// -----------------------------------------------------------------------------
//  WHY: the value of the engine's GraphClient and of its adaptive rate limiter is how they behave when Graph misbehaves, and a real
//  tenant cannot be asked to throttle on cue. Everything here is configurable AND deterministic: probabilistic rules draw from a
//  seeded generator (same seed + same call sequence = same faults), "every Nth" and "next N" rules need no randomness, and the rate
//  windows read an injectable monotonic clock so a test can drive time by hand (FakeManualTime) instead of sleeping.
//
//  What can be injected (all through FakeGraphFaults, reachable as transport.Faults):
//   - 429 with Retry-After, seconds or HTTP-date form, per endpoint class: at a probability, every Nth call, or for the next N calls
//   - 500/503/504 bursts (optionally with Retry-After, as the real service sometimes sends)
//   - a simulated quota: requests per second per endpoint class and/or for the whole application (exceeding -> 429)
//   - the Teams import limit: ImportLimitPerThread requests per second per conversation (real service: 5) -> 429
//   - slow responses (latency through an injectable delay, default zero: nothing is ever slept unless asked)
//   - connection resets (HttpRequestException thrown from SendAsync)
//   - truncated download streams (premature end of a file or a hosted content, by exception or by a silent short read)
//   - forced failures on an URL pattern (e.g. 403 on one drive item)
//  Counters (FakeGraphCounters, transport.Counters): calls per endpoint class, 429 sent, 5xx sent, bytes served, resets, truncations...
//  They are what the tests assert on and what a comparison with the real service uses.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer.Testing
{
    public enum RetryAfterFormat { Seconds, HttpDate }

    /// <summary>A monotonic clock driven by hand, for rate-window tests: faults.UseManualTime().Advance(1).</summary>
    public sealed class FakeManualTime
    {
        double _seconds;
        public double Seconds { get { return Volatile.Read(ref _seconds); } }
        public void Advance(double seconds) { lock (this) { _seconds += seconds; } }
        /// <summary>A Delay implementation that does not sleep but moves this clock forward (latency then shows up in the rate windows).</summary>
        public Task AdvanceDelay(TimeSpan d, CancellationToken ct) { Advance(d.TotalSeconds); return Task.CompletedTask; }
    }

    public sealed class FakeFaultRule
    {
        public string Name;
        /// <summary>One of EndpointClass.* or null for every class.</summary>
        public string EndpointClass;
        public Regex UrlRegex;
        public string Method;
        public int Status;
        public string ErrorCode;
        public bool ConnectionReset;
        public double TruncateFraction;
        public bool TruncateThrows = true;
        public TimeSpan Latency;
        public double Probability = 1.0;
        public int EveryNth;
        public int SkipFirst;
        public int MaxFires;
        public TimeSpan? RetryAfter;
        public RetryAfterFormat Format;
        public long Seen, Fired;
    }

    public sealed class FakeFaultDecision
    {
        public TimeSpan Latency;
        public bool Reset;
        public int Status;
        public string ErrorCode, Message, RetryAfterHeader, Reason;
        public double TruncateFraction;
        public bool TruncateThrows = true;
    }

    public sealed class FakeLogEntry
    {
        public long Seq;
        public string Method, Url, EndpointClass, ThreadKey;
        public int Status;
        public string Note;
    }

    public sealed class FakeGraphCounters
    {
        readonly ConcurrentDictionary<string, long> _calls = new ConcurrentDictionary<string, long>();
        readonly ConcurrentDictionary<string, long> _throttled = new ConcurrentDictionary<string, long>();
        readonly ConcurrentDictionary<int, long> _byStatus = new ConcurrentDictionary<int, long>();
        public long TotalCalls, Total429, Total5xx, ConnectionResets, TruncatedDownloads, BytesServed, BytesReceived,
                    EvaluationModeResponses, ImportedMessages, FaultsInjected;
        readonly object _logLock = new object();
        readonly List<FakeLogEntry> _log = new List<FakeLogEntry>();
        long _seq;

        /// <summary>Keep a log of the requests (method, url, class, status): off by default, capped to LogCapacity entries.</summary>
        public bool LogEnabled;
        public int LogCapacity = 100000;

        public void Reset()
        {
            _calls.Clear(); _throttled.Clear(); _byStatus.Clear();
            TotalCalls = Total429 = Total5xx = ConnectionResets = TruncatedDownloads = BytesServed = BytesReceived = EvaluationModeResponses = ImportedMessages = FaultsInjected = 0;
            lock (_logLock) { _log.Clear(); }
        }

        public long Calls(string endpointClass) { long v; return _calls.TryGetValue(endpointClass, out v) ? v : 0; }
        public long Throttled(string endpointClass) { long v; return _throttled.TryGetValue(endpointClass, out v) ? v : 0; }
        public long WithStatus(int status) { long v; return _byStatus.TryGetValue(status, out v) ? v : 0; }
        public IReadOnlyDictionary<string, long> CallsByClass { get { return new Dictionary<string, long>(_calls); } }
        public IReadOnlyDictionary<string, long> ThrottledByClass { get { return new Dictionary<string, long>(_throttled); } }

        public FakeLogEntry[] Log { get { lock (_logLock) { return _log.ToArray(); } } }

        /// <summary>Flat name -> value view, convenient for a report or a Pester assertion.</summary>
        public IDictionary<string, long> Snapshot()
        {
            var d = new SortedDictionary<string, long>(StringComparer.Ordinal);
            d["totalCalls"] = TotalCalls; d["total429"] = Total429; d["total5xx"] = Total5xx; d["connectionResets"] = ConnectionResets;
            d["truncatedDownloads"] = TruncatedDownloads; d["bytesServed"] = BytesServed; d["bytesReceived"] = BytesReceived;
            d["evaluationModeResponses"] = EvaluationModeResponses; d["importedMessages"] = ImportedMessages; d["faultsInjected"] = FaultsInjected;
            foreach (var kv in _calls) d["calls." + kv.Key] = kv.Value;
            foreach (var kv in _throttled) d["throttled." + kv.Key] = kv.Value;
            return d;
        }

        internal void Call(string cls) { Interlocked.Increment(ref TotalCalls); _calls.AddOrUpdate(cls, 1, (k, v) => v + 1); }
        internal void Status(int status, string cls)
        {
            _byStatus.AddOrUpdate(status, 1, (k, v) => v + 1);
            if (status == 429) { Interlocked.Increment(ref Total429); _throttled.AddOrUpdate(cls, 1, (k, v) => v + 1); }
            else if (status >= 500) Interlocked.Increment(ref Total5xx);
        }
        internal void Served(long n) { Interlocked.Add(ref BytesServed, n); }
        internal void Received(long n) { Interlocked.Add(ref BytesReceived, n); }
        internal void Incr(ref long field) { Interlocked.Increment(ref field); }

        internal FakeLogEntry Begin(string method, string url, string cls, string threadKey)
        {
            if (!LogEnabled) return null;
            var e = new FakeLogEntry { Seq = Interlocked.Increment(ref _seq), Method = method, Url = url, EndpointClass = cls, ThreadKey = threadKey };
            lock (_logLock) { if (_log.Count < LogCapacity) _log.Add(e); }
            return e;
        }
    }

    public sealed class FakeGraphFaults
    {
        readonly object _lock = new object();
        readonly List<FakeFaultRule> _rules = new List<FakeFaultRule>();
        readonly FakeRng _rng;
        readonly Stopwatch _sw = Stopwatch.StartNew();
        readonly Dictionary<string, Queue<double>> _windows = new Dictionary<string, Queue<double>>();
        readonly Dictionary<string, int> _quotas = new Dictionary<string, int>();

        public FakeGraphFaults(int seed = 4242) { _rng = new FakeRng(seed); MonotonicSeconds = () => _sw.Elapsed.TotalSeconds; }

        /// <summary>Time source of the rate windows (quota, import limit). Default: a Stopwatch. See UseManualTime.</summary>
        public Func<double> MonotonicSeconds;
        /// <summary>How latency is "spent". Default Task.Delay; tests inject a no-op or FakeManualTime.AdvanceDelay.</summary>
        public Func<TimeSpan, CancellationToken, Task> Delay = (d, ct) => Task.Delay(d, ct);
        /// <summary>Requests per second allowed per conversation on the import endpoints (POST messages / replies). 0 = not enforced. The real service: 5.</summary>
        public int ImportLimitPerThread;
        /// <summary>Retry-After style used by the quota and the import limit when they throttle.</summary>
        public RetryAfterFormat QuotaRetryAfterFormat = RetryAfterFormat.Seconds;

        public FakeManualTime UseManualTime()
        {
            var t = new FakeManualTime();
            MonotonicSeconds = () => t.Seconds;
            Delay = t.AdvanceDelay;
            return t;
        }

        public IReadOnlyList<FakeFaultRule> Rules { get { lock (_lock) { return _rules.ToArray(); } } }

        public FakeFaultRule Add(FakeFaultRule r) { if (r.EndpointClass == "") r.EndpointClass = null; lock (_lock) { _rules.Add(r); } return r; }

        public void Clear()
        {
            lock (_lock) { _rules.Clear(); _quotas.Clear(); _windows.Clear(); ImportLimitPerThread = 0; }
        }

        // ---- 429
        /// <summary>429 with probability p (1 = always) on the class; null class = every request.</summary>
        public FakeFaultRule Throttle(string endpointClass, double probability = 1.0, TimeSpan? retryAfter = null, RetryAfterFormat format = RetryAfterFormat.Seconds, int maxFires = 0)
        {
            return Add(new FakeFaultRule { Name = "throttle", EndpointClass = endpointClass, Status = 429, ErrorCode = "TooManyRequests", Probability = probability, RetryAfter = retryAfter ?? TimeSpan.FromSeconds(1), Format = format, MaxFires = maxFires });
        }

        /// <summary>429 on every Nth call of the class (N, 2N, 3N...).</summary>
        public FakeFaultRule ThrottleEveryNth(string endpointClass, int n, TimeSpan? retryAfter = null, RetryAfterFormat format = RetryAfterFormat.Seconds)
        {
            return Add(new FakeFaultRule { Name = "throttle-nth", EndpointClass = endpointClass, Status = 429, ErrorCode = "TooManyRequests", EveryNth = n, RetryAfter = retryAfter ?? TimeSpan.FromSeconds(1), Format = format });
        }

        /// <summary>429 on the next `count` calls of the class, then back to normal.</summary>
        public FakeFaultRule ThrottleNext(string endpointClass, int count, TimeSpan? retryAfter = null, RetryAfterFormat format = RetryAfterFormat.Seconds, int skipFirst = 0)
        {
            return Add(new FakeFaultRule { Name = "throttle-burst", EndpointClass = endpointClass, Status = 429, ErrorCode = "TooManyRequests", MaxFires = count, SkipFirst = skipFirst, RetryAfter = retryAfter ?? TimeSpan.FromSeconds(1), Format = format });
        }

        // ---- 5xx
        /// <summary>A burst of `count` consecutive 503 (or 504, 500) answers, starting after skipFirst matching calls.</summary>
        public FakeFaultRule ServerErrorBurst(string endpointClass, int count, int status = 503, TimeSpan? retryAfter = null, int skipFirst = 0)
        {
            return Add(new FakeFaultRule { Name = "5xx-burst", EndpointClass = endpointClass, Status = status, ErrorCode = status == 504 ? "GatewayTimeout" : status == 500 ? "InternalServerError" : "ServiceUnavailable", MaxFires = count, SkipFirst = skipFirst, RetryAfter = retryAfter });
        }

        public FakeFaultRule ServerError(string endpointClass, double probability, int status = 503, TimeSpan? retryAfter = null)
        {
            return Add(new FakeFaultRule { Name = "5xx", EndpointClass = endpointClass, Status = status, ErrorCode = status == 504 ? "GatewayTimeout" : status == 500 ? "InternalServerError" : "ServiceUnavailable", Probability = probability, RetryAfter = retryAfter });
        }

        // ---- network
        public FakeFaultRule ResetConnections(string endpointClass, double probability = 1.0, int everyNth = 0, int maxFires = 0, int skipFirst = 0)
        {
            return Add(new FakeFaultRule { Name = "reset", EndpointClass = endpointClass, ConnectionReset = true, Probability = probability, EveryNth = everyNth, MaxFires = maxFires, SkipFirst = skipFirst });
        }

        /// <summary>The download stream ends after `fraction` of its bytes: with an IOException (default) or silently (short read, the Content-Length header still announces the full size).</summary>
        public FakeFaultRule TruncateDownloads(string endpointClass, double fraction = 0.5, bool throwOnRead = true, double probability = 1.0, int everyNth = 0, int maxFires = 0)
        {
            return Add(new FakeFaultRule { Name = "truncate", EndpointClass = endpointClass, TruncateFraction = fraction, TruncateThrows = throwOnRead, Probability = probability, EveryNth = everyNth, MaxFires = maxFires });
        }

        public FakeFaultRule Latency(string endpointClass, TimeSpan latency, double probability = 1.0)
        {
            return Add(new FakeFaultRule { Name = "latency", EndpointClass = endpointClass, Latency = latency, Probability = probability });
        }

        /// <summary>Forces `status` on every request whose URL matches the regex (e.g. one drive item that answers 403).</summary>
        public FakeFaultRule FailUrl(string urlRegex, int status, string errorCode, string method = null, int maxFires = 0)
        {
            return Add(new FakeFaultRule { Name = "fail-url", UrlRegex = new Regex(urlRegex, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), Status = status, ErrorCode = errorCode, Method = method, MaxFires = maxFires });
        }

        // ---- quota
        /// <summary>
        /// Simulated Graph quota: at most `requestsPerSecond` requests in any sliding one-second window, for the class (or for the whole
        /// application when endpointClass is null). The excess gets 429 + Retry-After. Pass 0 to remove the quota.
        /// </summary>
        public void SetQuota(string endpointClass, int requestsPerSecond)
        {
            lock (_lock)
            {
                var k = string.IsNullOrEmpty(endpointClass) ? "*" : endpointClass;
                if (requestsPerSecond <= 0) _quotas.Remove(k); else _quotas[k] = requestsPerSecond;
            }
        }

        // ---- evaluation (called by the transport, one call per request)
        internal FakeFaultDecision Evaluate(string cls, string method, string url, string threadKey)
        {
            var d = new FakeFaultDecision();
            lock (_lock)
            {
                foreach (var r in _rules)
                {
                    if (r.EndpointClass != null && !string.Equals(r.EndpointClass, cls, StringComparison.Ordinal)) continue;
                    if (r.Method != null && !string.Equals(r.Method, method, StringComparison.OrdinalIgnoreCase)) continue;
                    if (r.UrlRegex != null && !r.UrlRegex.IsMatch(url)) continue;
                    r.Seen++;
                    if (r.Seen <= r.SkipFirst) continue;
                    if (r.MaxFires > 0 && r.Fired >= r.MaxFires) continue;
                    bool fire;
                    if (r.EveryNth > 0) fire = (r.Seen - r.SkipFirst) % r.EveryNth == 0;
                    else fire = r.Probability >= 1.0 || _rng.NextDouble() < r.Probability;
                    if (!fire) continue;
                    r.Fired++;
                    d.Latency += r.Latency;
                    if (r.TruncateFraction > 0) { d.TruncateFraction = r.TruncateFraction; d.TruncateThrows = r.TruncateThrows; d.Reason = d.Reason ?? "truncate"; }
                    if (d.Status == 0 && !d.Reset)
                    {
                        if (r.ConnectionReset) { d.Reset = true; d.Reason = "reset"; }
                        else if (r.Status != 0)
                        {
                            d.Status = r.Status; d.ErrorCode = r.ErrorCode ?? "Error"; d.Reason = r.Name;
                            if (r.RetryAfter.HasValue) d.RetryAfterHeader = Header(r.RetryAfter.Value, r.Format);
                        }
                    }
                }
                if (d.Status == 0 && !d.Reset)
                {
                    double now = MonotonicSeconds();
                    // application-wide quota first, then the class quota, then the per-conversation import limit
                    int q;
                    if (_quotas.TryGetValue("*", out q) && Exceeds("*", q, now, d)) { }
                    else if (cls != null && _quotas.TryGetValue(cls, out q) && Exceeds("c:" + cls, q, now, d)) { }
                    else if (ImportLimitPerThread > 0 && cls == EndpointClass.ImportMessage && !string.IsNullOrEmpty(threadKey) && Exceeds("t:" + threadKey, ImportLimitPerThread, now, d)) { }
                }
            }
            return d;
        }

        bool Exceeds(string key, int limit, double now, FakeFaultDecision d)
        {
            Queue<double> w;
            if (!_windows.TryGetValue(key, out w)) _windows[key] = w = new Queue<double>();
            while (w.Count > 0 && w.Peek() <= now - 1.0) w.Dequeue();
            if (w.Count >= limit)
            {
                double wait = Math.Max(1.0, Math.Ceiling(w.Peek() + 1.0 - now));
                d.Status = 429; d.ErrorCode = "TooManyRequests"; d.Reason = key.StartsWith("t:") ? "import-limit" : "quota";
                d.RetryAfterHeader = Header(TimeSpan.FromSeconds(wait), QuotaRetryAfterFormat);
                return true;
            }
            w.Enqueue(now);
            return false;
        }

        static string Header(TimeSpan ts, RetryAfterFormat f)
        {
            if (f == RetryAfterFormat.HttpDate)
                return DateTimeOffset.UtcNow.Add(ts).ToString("R", System.Globalization.CultureInfo.InvariantCulture);
            return ((long)Math.Ceiling(Math.Max(0, ts.TotalSeconds))).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
