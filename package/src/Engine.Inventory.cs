// =============================================================================
//  TeamsTransfer - engine, lot E part 1: shared work helpers + tenant inventory
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.0
//
//  WHAT THIS FILE HOLDS
//    - small shared helpers of the export engine (Engine.Export.cs uses them too): StopControl (stop file / hook),
//      ProgressSnapshot + ProgressReporter (counts, rates, ETA, throttled event), ErrorRecord, Par (bounded parallelism
//      over a sync or async source), BoundedKeySet (fixed-memory "seen" cache), GraphMetrics (what the Graph client
//      reported: requests, 429s, per class), Iso/Seg helpers;
//    - Inventory: enumerates the tenant ONCE and writes it to the store (IExportStore):
//        users (directory, with guests and disabled accounts), deleted users (directory/deletedItems),
//        the chats of every user (/users/{id}/chats?$expand=members) DEDUPLICATED across users by chat id,
//        the user -> conversation links, the teams (groups provisioned as Team) and their channels
//        (standard, private, shared) with members.
//
//  WHY THIS SHAPE (100k users, 5 years)
//    - the inventory is cheap compared to the export (one listing page = 50 chats) but it is the PLAN of everything
//      that follows: the exporter works per conversation, the lots are built from it, the preview lists from it;
//    - resumable: an interrupted pass is resumed (markers per user and per team, keyed by a pass id); a finished pass
//      is followed by a brand new one (new users / chats appear), so re-running is always safe and idempotent;
//    - a user, a team or a page that fails is recorded as an error and the pass continues: the failed unit is NOT
//      marked done and is retried by the next run;
//    - memory is bounded: users and teams are streamed page by page into a bounded worker pool.
//
//  Departed users: /users/{id}/chats answers 404 for a deleted account. Their chats are reached through the other
//  members (the chat lists its members, deleted ones included). A chat whose members are ALL deleted/federated is not
//  reachable app-only through a user listing: it is a known blind spot, reported by the tests.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    #region Shared helpers

    /// <summary>Cooperative stop: a manual request, a hook and/or a stop file. Checked between units of work and between pages.</summary>
    public sealed class StopControl
    {
        private volatile bool _requested;
        private long _lastFileCheckTicks;
        private volatile bool _lastFileResult;
        public Func<bool> Hook { get; set; }
        public string StopFile { get; set; }
        /// <summary>Minimum delay between two probes of the stop file.</summary>
        public TimeSpan FileCheckInterval { get; set; } = TimeSpan.FromMilliseconds(500);

        public void Request() { _requested = true; }
        public bool IsRequested
        {
            get
            {
                if (_requested) return true;
                var h = Hook;
                if (h != null)
                {
                    try { if (h()) { _requested = true; return true; } } catch (Exception) { }
                }
                var f = StopFile;
                if (!string.IsNullOrEmpty(f))
                {
                    long now = Environment.TickCount64;
                    long last = Interlocked.Read(ref _lastFileCheckTicks);
                    if (last == 0 || now - last >= (long)FileCheckInterval.TotalMilliseconds)
                    {
                        Interlocked.Exchange(ref _lastFileCheckTicks, now == 0 ? 1 : now);
                        try { _lastFileResult = File.Exists(f); } catch (Exception) { _lastFileResult = false; }
                    }
                    if (_lastFileResult) { _requested = true; return true; }
                }
                return false;
            }
        }
        public static bool Stopped(StopControl s) { return s != null && s.IsRequested; }
    }

    /// <summary>A structured error attached to a scope (user, conversation, team, file). Never aborts the run.</summary>
    public sealed class ErrorRecord
    {
        public string Scope { get; set; }
        public string Operation { get; set; }
        public int StatusCode { get; set; }
        public string ErrorCode { get; set; }
        public string Message { get; set; }
        public DateTimeOffset When { get; set; }
        public override string ToString() { return Scope + " [" + Operation + "] " + (StatusCode != 0 ? StatusCode + " " : "") + ErrorCode + ": " + Message; }

        public static ErrorRecord From(string scope, string operation, Exception ex, DateTimeOffset when)
        {
            var g = ex as GraphException;
            return new ErrorRecord
            {
                Scope = scope, Operation = operation, When = when,
                StatusCode = g != null ? g.StatusCode : 0,
                ErrorCode = g != null ? g.ErrorCode : ex.GetType().Name,
                Message = ex.Message.Length > 400 ? ex.Message.Substring(0, 400) : ex.Message
            };
        }
    }

    /// <summary>What a console needs: counts, rates, ETA. Immutable copy taken by ProgressReporter.Snapshot().</summary>
    public sealed class ProgressSnapshot
    {
        public string Operation { get; set; }
        public string Phase { get; set; }
        public string Current { get; set; }
        public long Users { get; set; }
        public long Conversations { get; set; }
        public long Teams { get; set; }
        public long Channels { get; set; }
        public long Messages { get; set; }
        public long NewMessages { get; set; }
        public long UpdatedMessages { get; set; }
        public long HostedContents { get; set; }
        public long FilesRecorded { get; set; }
        public long FilesDownloaded { get; set; }
        public long Bytes { get; set; }
        public long Errors { get; set; }
        public long UnitsDone { get; set; }
        public long UnitsTotal { get; set; }
        public TimeSpan Elapsed { get; set; }
        public double MessagesPerSecond { get; set; }
        public double UnitsPerSecond { get; set; }
        /// <summary>Estimated time left based on units (users, conversations, teams) done so far; null when unknown.</summary>
        public TimeSpan? Eta { get; set; }
        public bool Final { get; set; }
    }

    /// <summary>Thread-safe counters + a throttled progress event (at most one per Interval, plus phase changes and the end).</summary>
    public sealed class ProgressReporter
    {
        public long Users, Conversations, Teams, Channels, Messages, NewMessages, UpdatedMessages, HostedContents, FilesRecorded, FilesDownloaded, Bytes, Errors, UnitsDone, UnitsTotal;
        private readonly string _operation;
        private readonly Action<ProgressSnapshot> _sink;
        private readonly Func<DateTimeOffset> _now;
        private readonly System.Diagnostics.Stopwatch _sw = System.Diagnostics.Stopwatch.StartNew();
        private long _lastEmitMs = -100000;
        private volatile bool _finished;
        private string _phase = "", _current = "";
        public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(1);

        public ProgressReporter(string operation, Action<ProgressSnapshot> sink, Func<DateTimeOffset> now = null)
        {
            _operation = operation; _sink = sink; _now = now ?? (() => DateTimeOffset.UtcNow);
        }

        public void Phase(string phase, long unitsTotal = 0)
        {
            _phase = phase; _current = "";
            Interlocked.Exchange(ref UnitsDone, 0);
            Interlocked.Exchange(ref UnitsTotal, unitsTotal);
            Emit(true, false);
        }
        public void Current(string c) { _current = c; }
        public void Tick() { Emit(false, false); }
        public void Finish() { _finished = true; Emit(true, true); }

        public ProgressSnapshot Snapshot(bool final = false)
        {
            double secs = Math.Max(0.001, _sw.Elapsed.TotalSeconds);
            long done = Interlocked.Read(ref UnitsDone), total = Interlocked.Read(ref UnitsTotal);
            long msgs = Interlocked.Read(ref Messages);
            TimeSpan? eta = null;
            if (total > 0 && done > 0 && done < total) eta = TimeSpan.FromSeconds(secs / done * (total - done));
            return new ProgressSnapshot
            {
                Operation = _operation, Phase = _phase, Current = _current,
                Users = Interlocked.Read(ref Users), Conversations = Interlocked.Read(ref Conversations), Teams = Interlocked.Read(ref Teams),
                Channels = Interlocked.Read(ref Channels), Messages = msgs, NewMessages = Interlocked.Read(ref NewMessages),
                UpdatedMessages = Interlocked.Read(ref UpdatedMessages), HostedContents = Interlocked.Read(ref HostedContents),
                FilesRecorded = Interlocked.Read(ref FilesRecorded), FilesDownloaded = Interlocked.Read(ref FilesDownloaded),
                Bytes = Interlocked.Read(ref Bytes), Errors = Interlocked.Read(ref Errors),
                UnitsDone = done, UnitsTotal = total, Elapsed = _sw.Elapsed, MessagesPerSecond = msgs / secs, UnitsPerSecond = done / secs,
                Eta = eta, Final = final || _finished
            };
        }

        private void Emit(bool force, bool final)
        {
            var sink = _sink;
            if (sink == null) return;
            long nowMs = _sw.ElapsedMilliseconds;
            if (!force)
            {
                long last = Interlocked.Read(ref _lastEmitMs);
                if (nowMs - last < (long)Interval.TotalMilliseconds) return;
                if (Interlocked.CompareExchange(ref _lastEmitMs, nowMs, last) != last) return;
            }
            else Interlocked.Exchange(ref _lastEmitMs, nowMs);
            try { sink(Snapshot(final)); } catch (Exception) { /* a faulty console must never break the run */ }
        }
    }

    /// <summary>Bounded parallel loops (System.Threading.Tasks.Parallel is not in the compile references).</summary>
    public static class Par
    {
        public static Task ForEachAsync<T>(IEnumerable<T> source, int degree, Func<T, CancellationToken, Task> body, CancellationToken ct, StopControl stop = null)
        {
            return RunAsync<T>(async (write, token) =>
            {
                foreach (var item in source)
                {
                    if (StopControl.Stopped(stop)) break;
                    await write(item).ConfigureAwait(false);
                }
            }, degree, body, ct);
        }

        public static Task ForEachAsync<T>(IAsyncEnumerable<T> source, int degree, Func<T, CancellationToken, Task> body, CancellationToken ct, StopControl stop = null)
        {
            return RunAsync<T>(async (write, token) =>
            {
                await foreach (var item in source.WithCancellation(token).ConfigureAwait(false))
                {
                    if (StopControl.Stopped(stop)) break;
                    await write(item).ConfigureAwait(false);
                }
            }, degree, body, ct);
        }

        private static async Task RunAsync<T>(Func<Func<T, ValueTask>, CancellationToken, Task> produce, int degree, Func<T, CancellationToken, Task> body, CancellationToken ct)
        {
            if (degree < 1) degree = 1;
            using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                var ch = Channel.CreateBounded<T>(new BoundedChannelOptions(Math.Max(2, degree * 2)) { SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
                Exception first = null;
                var workers = new Task[degree];
                for (int i = 0; i < degree; i++)
                {
                    workers[i] = Task.Run(async () =>
                    {
                        try
                        {
                            await foreach (var item in ch.Reader.ReadAllAsync(cts.Token).ConfigureAwait(false))
                                await body(item, cts.Token).ConfigureAwait(false);
                        }
                        catch (Exception ex)
                        {
                            Interlocked.CompareExchange(ref first, ex, null);
                            cts.Cancel();
                        }
                    });
                }
                try
                {
                    await produce(item => ch.Writer.WriteAsync(item, cts.Token), cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (Volatile.Read(ref first) != null || ct.IsCancellationRequested) { }
                catch (Exception ex)
                {
                    Interlocked.CompareExchange(ref first, ex, null);
                    cts.Cancel();
                }
                finally { ch.Writer.TryComplete(); }
                await Task.WhenAll(workers).ConfigureAwait(false);
                var f = Volatile.Read(ref first);
                if (f != null) ExceptionDispatchInfo.Capture(f).Throw();
                ct.ThrowIfCancellationRequested();
            }
        }
    }

    /// <summary>
    /// Fixed-memory "have I seen this key" cache (two generations: when the young one is full it becomes the old one and the
    /// previous old one is dropped). A false "not seen" only costs a repeated (idempotent) piece of work, never a wrong result.
    /// </summary>
    public sealed class BoundedKeySet
    {
        private readonly int _capacity;
        private readonly object _gate = new object();
        private HashSet<string> _young = new HashSet<string>(StringComparer.Ordinal);
        private HashSet<string> _old = new HashSet<string>(StringComparer.Ordinal);
        public BoundedKeySet(int capacity = 200000) { _capacity = Math.Max(16, capacity); }

        /// <summary>True when the key was not in the set (and is now).</summary>
        public bool Add(string key)
        {
            lock (_gate)
            {
                if (_young.Contains(key) || _old.Contains(key)) return false;
                if (_young.Count >= _capacity) { _old = _young; _young = new HashSet<string>(StringComparer.Ordinal); }
                _young.Add(key);
                return true;
            }
        }
        public void Remove(string key) { lock (_gate) { _young.Remove(key); _old.Remove(key); } }
        public bool Contains(string key) { lock (_gate) return _young.Contains(key) || _old.Contains(key); }
    }

    /// <summary>Same idea for a key -> value cache.</summary>
    public sealed class BoundedCache<TValue>
    {
        private readonly int _capacity;
        private readonly object _gate = new object();
        private Dictionary<string, TValue> _young = new Dictionary<string, TValue>(StringComparer.Ordinal);
        private Dictionary<string, TValue> _old = new Dictionary<string, TValue>(StringComparer.Ordinal);
        public BoundedCache(int capacity = 100000) { _capacity = Math.Max(16, capacity); }
        public bool TryGet(string key, out TValue value)
        {
            lock (_gate) { return _young.TryGetValue(key, out value) || _old.TryGetValue(key, out value); }
        }
        public void Set(string key, TValue value)
        {
            lock (_gate)
            {
                if (_young.Count >= _capacity) { _old = _young; _young = new Dictionary<string, TValue>(StringComparer.Ordinal); }
                _young[key] = value;
            }
        }
    }

    /// <summary>
    /// Counts what the Graph client reports (GraphEvent): requests, retries, 429/503, errors, per endpoint class. Pass
    /// metrics.OnEvent as the onEvent callback of GraphClient. Used by Assess for the measured throughput.
    /// </summary>
    public sealed class GraphMetrics
    {
        private long _requests, _retries, _throttled429, _throttled503, _errors, _delayTicks;
        private readonly ConcurrentDictionary<string, long> _byClass = new ConcurrentDictionary<string, long>(StringComparer.Ordinal);
        private readonly System.Diagnostics.Stopwatch _sw = System.Diagnostics.Stopwatch.StartNew();
        private static readonly ConditionalWeakTable<GraphClient, GraphMetrics> Attached = new ConditionalWeakTable<GraphClient, GraphMetrics>();

        public void OnEvent(GraphEvent e)
        {
            if (e == null) return;
            switch (e.Kind)
            {
                case GraphEventKind.Request: Interlocked.Increment(ref _requests); _byClass.AddOrUpdate(e.EndpointClass ?? "other", 1, (k, v) => v + 1); break;
                case GraphEventKind.Retry: Interlocked.Increment(ref _retries); Interlocked.Add(ref _delayTicks, e.Delay.Ticks); break;
                case GraphEventKind.Throttled:
                    if (e.StatusCode == 503) Interlocked.Increment(ref _throttled503); else Interlocked.Increment(ref _throttled429);
                    Interlocked.Add(ref _delayTicks, e.Delay.Ticks); break;
                case GraphEventKind.Error: Interlocked.Increment(ref _errors); break;
            }
        }

        public void Attach(GraphClient client) { Attached.AddOrUpdate(client, this); }
        public static GraphMetrics Of(GraphClient client)
        {
            GraphMetrics m;
            return client != null && Attached.TryGetValue(client, out m) ? m : null;
        }

        public GraphMetricsSnapshot Snapshot()
        {
            return new GraphMetricsSnapshot
            {
                Requests = Interlocked.Read(ref _requests), Retries = Interlocked.Read(ref _retries),
                Throttled429 = Interlocked.Read(ref _throttled429), Throttled503 = Interlocked.Read(ref _throttled503),
                Errors = Interlocked.Read(ref _errors), WaitedByServer = TimeSpan.FromTicks(Interlocked.Read(ref _delayTicks)),
                Elapsed = _sw.Elapsed, ByClass = new Dictionary<string, long>(_byClass)
            };
        }
    }

    public sealed class GraphMetricsSnapshot
    {
        /// <summary>Successful requests.</summary>
        public long Requests { get; set; }
        public long Retries { get; set; }
        public long Throttled429 { get; set; }
        public long Throttled503 { get; set; }
        public long Errors { get; set; }
        public TimeSpan WaitedByServer { get; set; }
        public TimeSpan Elapsed { get; set; }
        public Dictionary<string, long> ByClass { get; set; }
        public long Attempts => Requests + Retries + Throttled429 + Throttled503 + Errors;
        public double RequestsPerSecond => Elapsed.TotalSeconds > 0 ? Requests / Elapsed.TotalSeconds : 0;
        public static GraphMetricsSnapshot Delta(GraphMetricsSnapshot after, GraphMetricsSnapshot before)
        {
            var d = new GraphMetricsSnapshot
            {
                Requests = after.Requests - before.Requests, Retries = after.Retries - before.Retries,
                Throttled429 = after.Throttled429 - before.Throttled429, Throttled503 = after.Throttled503 - before.Throttled503,
                Errors = after.Errors - before.Errors, WaitedByServer = after.WaitedByServer - before.WaitedByServer,
                Elapsed = after.Elapsed - before.Elapsed, ByClass = new Dictionary<string, long>()
            };
            foreach (var kv in after.ByClass)
            {
                long b; before.ByClass.TryGetValue(kv.Key, out b);
                if (kv.Value - b != 0) d.ByClass[kv.Key] = kv.Value - b;
            }
            return d;
        }
    }

    internal static class ExportUtil
    {
        public static string Iso(DateTimeOffset d) { return d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture); }

        public static bool TryParseDate(string s, out DateTimeOffset d)
        {
            return DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d);
        }

        /// <summary>Path segment for an id: escaped, but ':' and '@' (chat ids) stay readable.</summary>
        public static string Seg(string id)
        {
            return Uri.EscapeDataString(id ?? "").Replace("%3A", ":").Replace("%40", "@");
        }

        public static string Str(JsonElement e, string name)
        {
            JsonElement p;
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out p) && p.ValueKind == JsonValueKind.String) return p.GetString();
            return null;
        }

        public static string Str(JsonElement e, string obj, string name)
        {
            JsonElement o;
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(obj, out o) && o.ValueKind == JsonValueKind.Object) return Str(o, name);
            return null;
        }

        public static DateTimeOffset? Date(JsonElement e, string name)
        {
            var s = Str(e, name);
            DateTimeOffset d;
            if (s != null && TryParseDate(s, out d) && d.Year > 1) return d;
            return null;
        }

        public static bool IsCancel(Exception ex, CancellationToken ct)
        {
            return ex is OperationCanceledException && ct.IsCancellationRequested;
        }
    }

    #endregion

    #region Inventory

    public sealed class InventoryOptions
    {
        public int UserParallelism { get; set; } = 8;
        public int TeamParallelism { get; set; } = 4;
        public bool IncludeUsers { get; set; } = true;
        public bool IncludeDeletedUsers { get; set; } = true;
        public bool IncludeChats { get; set; } = true;
        public bool IncludeTeams { get; set; } = true;
        /// <summary>Link every member of a channel to the channel (user -> conversation). Off for very large tenants if the store is slow.</summary>
        public bool LinkChannelMembers { get; set; } = true;
        /// <summary>List teams with GET teams (needs no Group.Read.All). False, or a 400/404 from GET teams: groups?$filter=resourceProvisioningOptions (needs Group.Read.All).</summary>
        public bool UseTeamsEndpoint { get; set; } = true;
        /// <summary>Use teams/{id}/allChannels (includes shared channels shared with the team) instead of teams/{id}/channels.</summary>
        public bool UseAllChannels { get; set; } = false;
        /// <summary>Only enumerate the chats of these users (id, UPN or mail). Null = every user.</summary>
        public IReadOnlyCollection<string> OnlyUsers { get; set; }
        /// <summary>Only inventory these teams (id or display name, exact match). Null/empty = every team (independent of OnlyUsers).</summary>
        public IReadOnlyCollection<string> OnlyTeams { get; set; }
        /// <summary>Own tenant id (to tell federated members from internal ones); learnt from the first chat when empty.</summary>
        public string TenantId { get; set; }
        /// <summary>When false, an interrupted pass is NOT resumed: a new pass starts from scratch.</summary>
        public bool Resume { get; set; } = true;
        public int ChatPageSize { get; set; } = 50;
        public StopControl Stop { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    public sealed class InventoryResult
    {
        public string PassId { get; set; }
        public bool Resumed { get; set; }
        public bool Stopped { get; set; }
        public long Users { get; set; }
        public long DisabledUsers { get; set; }
        public long GuestUsers { get; set; }
        public long DeletedUsers { get; set; }
        /// <summary>Members seen in chats / channels that are not in the directory (federated, or deleted past the recycle bin).</summary>
        public long OtherMembers { get; set; }
        public long UsersWithChats { get; set; }
        public long UsersSkipped { get; set; }
        /// <summary>Distinct chats (deduplicated across users).</summary>
        public long Chats { get; set; }
        public long OneOnOneChats { get; set; }
        public long GroupChats { get; set; }
        public long MeetingChats { get; set; }
        /// <summary>Sum over users of their chat count: how many times the strategy U would read a conversation.</summary>
        public long ChatMemberships { get; set; }
        public long Teams { get; set; }
        public long Channels { get; set; }
        public long PrivateChannels { get; set; }
        public long SharedChannels { get; set; }
        public long ChannelLinks { get; set; }
        public List<ErrorRecord> Errors { get; set; } = new List<ErrorRecord>();
        /// <summary>Conversations that carry a migrationMode (imported by a migration): exported by strategy C.</summary>
        public long ImportedConversations { get; set; }
        /// <summary>Conversations whose migrationMode is inProgress: a migration is running on them, the export may be incomplete.</summary>
        public List<string> MigrationsInProgress { get; set; } = new List<string>();
        /// <summary>Non-fatal problems, each reported once (for example a missing permission).</summary>
        public List<string> Warnings { get; set; } = new List<string>();
        public TimeSpan Duration { get; set; }
    }

    public sealed class Inventory
    {
        private readonly GraphClient _graph;
        private readonly IExportStore _store;
        private readonly InventoryOptions _o;
        private readonly Func<DateTimeOffset> _now;
        private readonly ProgressReporter _progress;

        private readonly ConcurrentDictionary<string, byte> _knownUsers = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, UserRecord> _discovered = new ConcurrentDictionary<string, UserRecord>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, byte> _seenChats = new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, byte> _seenSharedChannels = new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        private readonly ConcurrentQueue<ErrorRecord> _errors = new ConcurrentQueue<ErrorRecord>();
        private readonly ConcurrentQueue<string> _inProgress = new ConcurrentQueue<string>();
        private readonly ConcurrentDictionary<string, string> _warnings = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
        private long _imported;
        private long _teamsListed;
        private string _ownTenant;
        private string _pass;
        private readonly InventoryResultCounters _c = new InventoryResultCounters();

        private sealed class InventoryResultCounters
        {
            public long Users, Disabled, Guests, Deleted, UsersWithChats, Skipped, Chats, OneOnOne, Group, Meeting, Memberships, Teams, Channels, Private, Shared, ChannelLinks;
        }

        public Inventory(GraphClient graph, IExportStore store, InventoryOptions options = null)
        {
            if (graph == null) throw new ArgumentNullException(nameof(graph));
            if (store == null) throw new ArgumentNullException(nameof(store));
            _graph = graph; _store = store; _o = options ?? new InventoryOptions();
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _ownTenant = _o.TenantId;
            _progress = new ProgressReporter("Inventory", _o.OnProgress, _now);
        }

        public ProgressSnapshot Progress => _progress.Snapshot();

        public async Task<InventoryResult> RunAsync(CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var result = new InventoryResult();

            // pass handling: resume an interrupted pass, otherwise start a new one
            string state = _store.GetCheckpoint("inv:state"), pass = _store.GetCheckpoint("inv:pass");
            if (_o.Resume && state == "running" && !string.IsNullOrEmpty(pass)) { _pass = pass; result.Resumed = true; }
            else
            {
                _pass = _now().UtcDateTime.ToString("yyyyMMddHHmmssfff", CultureInfo.InvariantCulture);
                _store.SetCheckpoint("inv:pass", _pass);
            }
            _store.SetCheckpoint("inv:state", "running");
            result.PassId = _pass;

            if (_o.IncludeDeletedUsers) await DeletedUsersAsync(ct).ConfigureAwait(false);
            if (_o.IncludeUsers || _o.IncludeChats) await UsersAndChatsAsync(ct).ConfigureAwait(false);
            if (_o.IncludeTeams && !StopControl.Stopped(_o.Stop)) await TeamsAsync(ct).ConfigureAwait(false);

            FlushDiscovered();
            result.Stopped = StopControl.Stopped(_o.Stop);
            if (!result.Stopped && _errors.IsEmpty) _store.SetCheckpoint("inv:state", "complete");
            else if (!result.Stopped) _store.SetCheckpoint("inv:state", "running");   // errors: the next run resumes this pass and retries the failed units

            result.Users = _c.Users; result.DisabledUsers = _c.Disabled; result.GuestUsers = _c.Guests; result.DeletedUsers = _c.Deleted;
            result.OtherMembers = _discovered.Count;
            result.UsersWithChats = _c.UsersWithChats; result.UsersSkipped = _c.Skipped;
            result.Chats = _c.Chats; result.OneOnOneChats = _c.OneOnOne; result.GroupChats = _c.Group; result.MeetingChats = _c.Meeting;
            result.ChatMemberships = _c.Memberships;
            result.Teams = _c.Teams; result.Channels = _c.Channels; result.PrivateChannels = _c.Private; result.SharedChannels = _c.Shared;
            result.ChannelLinks = _c.ChannelLinks;
            result.Errors = _errors.ToList();
            result.ImportedConversations = Interlocked.Read(ref _imported);
            result.MigrationsInProgress = _inProgress.ToList();
            result.Warnings = _warnings.Values.OrderBy(x => x, StringComparer.Ordinal).ToList();
            result.Duration = sw.Elapsed;
            _progress.Finish();
            return result;
        }

        private void Fail(string scope, string op, Exception ex)
        {
            var rec = ErrorRecord.From(scope, op, ex, _now());
            _errors.Enqueue(rec);
            Interlocked.Increment(ref _progress.Errors);
            try { _store.SetCheckpoint("err:inv:" + scope, rec.ToString()); } catch (Exception) { }
        }

        // ------------------------------------------------------------------ users

        private const string UserSelect = "id,userPrincipalName,displayName,mail,userType,accountEnabled";

        private async Task DeletedUsersAsync(CancellationToken ct)
        {
            _progress.Phase("deleted users");
            var batch = new List<UserRecord>();
            try
            {
                await foreach (var u in _graph.GetPagedAsync("v1.0/directory/deletedItems/microsoft.graph.user?$select=id,userPrincipalName,displayName,mail&$top=999",
                    EndpointClass.Users, cancellationToken: ct).ConfigureAwait(false))
                {
                    var id = ExportUtil.Str(u, "id");
                    if (id == null) continue;
                    _knownUsers[id] = 1;
                    batch.Add(new UserRecord
                    {
                        Id = id, UserPrincipalName = ExportUtil.Str(u, "userPrincipalName"), DisplayName = ExportUtil.Str(u, "displayName"),
                        Mail = ExportUtil.Str(u, "mail"), State = UserState.Deleted
                    });
                    Interlocked.Increment(ref _c.Deleted);
                    if (batch.Count >= 500) { _store.UpsertUsers(batch); batch = new List<UserRecord>(); }
                }
            }
            catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && ex is GraphException)
            {
                Fail("deletedUsers", "list", ex);   // e.g. 403 without the directory permission: not fatal
            }
            if (batch.Count > 0) _store.UpsertUsers(batch);
        }

        private async IAsyncEnumerable<UserRecord> StreamUsersAsync([EnumeratorCancellation] CancellationToken ct)
        {
            var batch = new List<UserRecord>();
            var url = "v1.0/users?$select=" + UserSelect + "&$top=999";
            await foreach (var u in _graph.GetPagedAsync(url, EndpointClass.Users, cancellationToken: ct).ConfigureAwait(false))
            {
                var id = ExportUtil.Str(u, "id");
                if (id == null) continue;
                var rec = new UserRecord
                {
                    Id = id, UserPrincipalName = ExportUtil.Str(u, "userPrincipalName"), DisplayName = ExportUtil.Str(u, "displayName"), Mail = ExportUtil.Str(u, "mail"),
                    State = UserState.Active
                };
                JsonElement p;
                if (string.Equals(ExportUtil.Str(u, "userType"), "Guest", StringComparison.OrdinalIgnoreCase)) { rec.State = UserState.Guest; Interlocked.Increment(ref _c.Guests); }
                else if (u.TryGetProperty("accountEnabled", out p) && p.ValueKind == JsonValueKind.False) { rec.State = UserState.Disabled; Interlocked.Increment(ref _c.Disabled); }
                _knownUsers[id] = 1;
                Interlocked.Increment(ref _c.Users);
                Interlocked.Increment(ref _progress.Users);
                if (_o.IncludeUsers)
                {
                    batch.Add(rec);
                    if (batch.Count >= 500) { _store.UpsertUsers(batch); batch = new List<UserRecord>(); }
                }
                yield return rec;
            }
            if (batch.Count > 0) _store.UpsertUsers(batch);
        }

        private bool Wanted(UserRecord u)
        {
            var only = _o.OnlyUsers;
            if (only == null || only.Count == 0) return true;
            foreach (var w in only)
                if (string.Equals(w, u.Id, StringComparison.OrdinalIgnoreCase) || string.Equals(w, u.UserPrincipalName, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(w, u.Mail, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private async Task UsersAndChatsAsync(CancellationToken ct)
        {
            _progress.Phase("users and chats");
            await Par.ForEachAsync(StreamUsersAsync(ct), Math.Max(1, _o.UserParallelism), async (u, token) =>
            {
                if (!_o.IncludeChats) return;
                if (!Wanted(u)) { Interlocked.Increment(ref _c.Skipped); return; }
                string marker = "inv:" + _pass + ":u:" + u.Id;
                if (_store.GetCheckpoint(marker) != null && _store.GetCheckpoint(marker) != "")
                {
                    Interlocked.Increment(ref _c.Skipped);   // done by the interrupted pass we are resuming
                    Interlocked.Increment(ref _progress.UnitsDone);
                    return;
                }
                try
                {
                    int n = await UserChatsAsync(u, token).ConfigureAwait(false);
                    if (n > 0) Interlocked.Increment(ref _c.UsersWithChats);
                    _store.SetCheckpoint(marker, "1");
                    _store.SetCheckpoint("err:inv:u:" + u.Id, "");
                }
                catch (Exception ex) when (!ExportUtil.IsCancel(ex, token) && ex is GraphException)
                {
                    Fail("u:" + u.Id, "chats", ex);
                }
                Interlocked.Increment(ref _progress.UnitsDone);
                _progress.Tick();
            }, ct, _o.Stop).ConfigureAwait(false);
        }

        private async Task<int> UserChatsAsync(UserRecord user, CancellationToken ct)
        {
            string url = "v1.0/users/" + ExportUtil.Seg(user.Id) + "/chats?$expand=members&$top=" + Math.Min(50, Math.Max(1, _o.ChatPageSize));
            var page = new List<JsonElement>();
            int total = 0;
            await foreach (var chat in _graph.GetPagedAsync(url, EndpointClass.UserChats, threadKey: user.Id, cancellationToken: ct).ConfigureAwait(false))
            {
                page.Add(chat);
                if (page.Count >= 50) { total += HandleChats(user, page); page.Clear(); }
            }
            if (page.Count > 0) total += HandleChats(user, page);
            return total;
        }

        private int HandleChats(UserRecord user, List<JsonElement> chats)
        {
            var keys = new List<string>(chats.Count);
            var fresh = new List<ConversationRecord>();
            foreach (var chat in chats)
            {
                var id = ExportUtil.Str(chat, "id");
                if (id == null) continue;
                string key = ConversationKeys.ForChat(id);
                keys.Add(key);
                Interlocked.Increment(ref _c.Memberships);
                if (!_seenChats.TryAdd(key, 1)) continue;   // already inventoried through another member
                if (_ownTenant == null) _ownTenant = ExportUtil.Str(chat, "tenantId");
                var rec = BuildChat(chat, id, key);
                var existing = _store.GetConversation(key);      // keep what Assess / the exporter learnt: a flag never goes from true back to false
                if (existing != null && existing.HasImportedContent == true) rec.HasImportedContent = true;
                else if (existing != null && rec.HasImportedContent == null) rec.HasImportedContent = existing.HasImportedContent;
                NoteMigration(rec, chat);
                fresh.Add(rec);
                Interlocked.Increment(ref _c.Chats);
                Interlocked.Increment(ref _progress.Conversations);
                switch (rec.Kind)
                {
                    case ConversationKind.OneOnOne: Interlocked.Increment(ref _c.OneOnOne); break;
                    case ConversationKind.Meeting: Interlocked.Increment(ref _c.Meeting); break;
                    default: Interlocked.Increment(ref _c.Group); break;
                }
                DiscoverMembers(chat);
            }
            if (fresh.Count > 0) _store.UpsertConversations(fresh);
            if (keys.Count > 0) _store.LinkUserConversations(user.Id, keys);
            return keys.Count;
        }

        private static ConversationRecord BuildChat(JsonElement chat, string id, string key)
        {
            var type = ExportUtil.Str(chat, "chatType");
            var rec = new ConversationRecord
            {
                Key = key, ChatId = id,
                Kind = string.Equals(type, "oneOnOne", StringComparison.OrdinalIgnoreCase) ? ConversationKind.OneOnOne
                     : string.Equals(type, "meeting", StringComparison.OrdinalIgnoreCase) ? ConversationKind.Meeting : ConversationKind.Group,
                Topic = ExportUtil.Str(chat, "topic"),
                CreatedUtc = ExportUtil.Date(chat, "createdDateTime"),
                LastActivityUtc = ExportUtil.Date(chat, "lastUpdatedDateTime")
            };
            if (IsMigrated(chat)) rec.HasImportedContent = true;
            JsonElement m;
            if (chat.TryGetProperty("members", out m) && m.ValueKind == JsonValueKind.Array)
            {
                rec.MembersJson = m.GetRawText();
                rec.MemberCount = m.GetArrayLength();
            }
            return rec;
        }

        /// <summary>Graph reports migrationMode (inProgress / completed) and originalCreatedDateTime on conversations that went through the import API.</summary>
        private static bool IsMigrated(JsonElement conv)
        {
            JsonElement p;
            if (conv.TryGetProperty("migrationMode", out p) && p.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(p.GetString())) return true;
            if (conv.TryGetProperty("originalCreatedDateTime", out p) && p.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(p.GetString())) return true;
            return false;
        }

        private void NoteMigration(ConversationRecord rec, JsonElement conv)
        {
            if (rec.HasImportedContent == true && IsMigrated(conv)) Interlocked.Increment(ref _imported);
            if (string.Equals(ExportUtil.Str(conv, "migrationMode"), "inProgress", StringComparison.OrdinalIgnoreCase))
            {
                _inProgress.Enqueue(rec.Key);
                _warnings.TryAdd("inProgress:" + rec.Key, "A migration is in progress on " + rec.Key + " (migrationMode = inProgress): its export may be incomplete.");
            }
        }

        /// <summary>Members that are not in the directory (federated, or long deleted) become UserRecords of their own.</summary>
        private void DiscoverMembers(JsonElement conv)
        {
            JsonElement members;
            if (!conv.TryGetProperty("members", out members) || members.ValueKind != JsonValueKind.Array) return;
            foreach (var mem in members.EnumerateArray()) DiscoverMember(mem);
        }

        private void DiscoverMember(JsonElement mem)
        {
            var uid = ExportUtil.Str(mem, "userId");
            if (string.IsNullOrEmpty(uid) || _knownUsers.ContainsKey(uid) || _discovered.ContainsKey(uid)) return;
            var tenant = ExportUtil.Str(mem, "tenantId");
            bool foreign = _ownTenant != null && tenant != null && !string.Equals(tenant, _ownTenant, StringComparison.OrdinalIgnoreCase);
            _discovered.TryAdd(uid, new UserRecord
            {
                Id = uid, DisplayName = ExportUtil.Str(mem, "displayName"), Mail = ExportUtil.Str(mem, "email"), TenantId = tenant,
                State = foreign ? UserState.External : UserState.Unknown
            });
        }

        private void FlushDiscovered()
        {
            if (_discovered.IsEmpty) return;
            // re-evaluate against the tenant id learnt later in the run
            var list = new List<UserRecord>();
            foreach (var kv in _discovered)
            {
                if (_knownUsers.ContainsKey(kv.Key)) continue;
                var u = kv.Value;
                if (_ownTenant != null && u.TenantId != null)
                    u.State = string.Equals(u.TenantId, _ownTenant, StringComparison.OrdinalIgnoreCase) ? UserState.Unknown : UserState.External;
                list.Add(u);
            }
            for (int i = 0; i < list.Count; i += 500) _store.UpsertUsers(list.GetRange(i, Math.Min(500, list.Count - i)));
        }

        // ------------------------------------------------------------------ teams and channels

        private async Task TeamsAsync(CancellationToken ct)
        {
            _progress.Phase("teams");
            const string groupsUrl = "v1.0/groups?$filter=resourceProvisioningOptions/Any(x:x%20eq%20'Team')&$select=id,displayName,description,createdDateTime,visibility&$top=999";
            if (_o.UseTeamsEndpoint)
            {
                try { await TeamsFromAsync("v1.0/teams", ct).ConfigureAwait(false); return; }
                catch (GraphException ex) when ((ex.StatusCode == 404 || ex.StatusCode == 400) && Interlocked.Read(ref _teamsListed) == 0 && !ExportUtil.IsCancel(ex, ct))
                {
                    _warnings.TryAdd("teamsEndpoint", "GET teams answered " + ex.StatusCode + " " + ex.ErrorCode + ": teams were listed through groups (needs Group.Read.All).");
                }
            }
            await TeamsFromAsync(groupsUrl, ct).ConfigureAwait(false);
        }

        private async Task TeamsFromAsync(string url, CancellationToken ct)
        {
            var source = _graph.GetPagedAsync(url, EndpointClass.Teams, cancellationToken: ct);
            await Par.ForEachAsync(source, Math.Max(1, _o.TeamParallelism), async (team, token) =>
            {
                Interlocked.Increment(ref _teamsListed);
                var tid = ExportUtil.Str(team, "id");
                if (tid == null) return;
                if (_o.OnlyTeams != null && _o.OnlyTeams.Count > 0)
                {
                    var tname = ExportUtil.Str(team, "displayName");
                    bool wanted = false;
                    foreach (var w in _o.OnlyTeams)
                        if (string.Equals(w, tid, StringComparison.OrdinalIgnoreCase) || (tname != null && string.Equals(w, tname, StringComparison.Ordinal))) { wanted = true; break; }
                    if (!wanted) return;
                }
                string marker = "inv:" + _pass + ":t:" + tid;
                if (!string.IsNullOrEmpty(_store.GetCheckpoint(marker)))
                {
                    Interlocked.Increment(ref _progress.UnitsDone);
                    return;
                }
                try
                {
                    await TeamChannelsAsync(tid, ExportUtil.Str(team, "displayName"), token).ConfigureAwait(false);
                    Interlocked.Increment(ref _c.Teams);
                    Interlocked.Increment(ref _progress.Teams);
                    _store.SetCheckpoint(marker, "1");
                    _store.SetCheckpoint("err:inv:t:" + tid, "");
                }
                catch (Exception ex) when (!ExportUtil.IsCancel(ex, token) && ex is GraphException)
                {
                    Fail("t:" + tid, "channels", ex);
                }
                Interlocked.Increment(ref _progress.UnitsDone);
                _progress.Tick();
            }, ct, _o.Stop).ConfigureAwait(false);
        }

        private async Task<List<JsonElement>> ListAsync(string url, string cls, string thread, CancellationToken ct)
        {
            var list = new List<JsonElement>();
            await foreach (var e in _graph.GetPagedAsync(url, cls, threadKey: thread, cancellationToken: ct).ConfigureAwait(false)) list.Add(e);
            return list;
        }

        private static string MembersToJson(List<JsonElement> members)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartArray();
                    foreach (var m in members) m.WriteTo(w);
                    w.WriteEndArray();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        private static List<string> MemberIds(List<JsonElement> members)
        {
            var ids = new List<string>(members.Count);
            foreach (var m in members) { var id = ExportUtil.Str(m, "userId"); if (id != null) ids.Add(id); }
            return ids;
        }

        private async Task TeamChannelsAsync(string teamId, string teamName, CancellationToken ct)
        {
            string t = ExportUtil.Seg(teamId);
            // standard channels share the team's members: read them once per team
            List<JsonElement> teamMembers;
            try { teamMembers = await ListAsync("v1.0/teams/" + t + "/members?$top=999", EndpointClass.ChannelMembers, teamId, ct).ConfigureAwait(false); }
            catch (GraphException ex) when ((ex.StatusCode == 403 || ex.StatusCode == 401) && !ExportUtil.IsCancel(ex, ct))
            {
                // the channel export does not need the members: keep the channels, say once which permission is missing
                teamMembers = new List<JsonElement>();
                _warnings.TryAdd("teamMembers", "Team members could not be read (" + ex.StatusCode + " " + ex.ErrorCode + "): grant TeamMember.Read.All (or Group.Read.All). Teams and channels were inventoried WITHOUT their members.");
            }
            foreach (var m in teamMembers) DiscoverMember(m);
            string teamMembersJson = MembersToJson(teamMembers);
            var teamMemberIds = MemberIds(teamMembers);

            var channels = await ListAsync("v1.0/teams/" + t + (_o.UseAllChannels ? "/allChannels" : "/channels"), EndpointClass.Channels, teamId, ct).ConfigureAwait(false);
            var records = new List<ConversationRecord>();
            foreach (var ch in channels)
            {
                var cid = ExportUtil.Str(ch, "id");
                if (cid == null) continue;
                string type = (ExportUtil.Str(ch, "membershipType") ?? "standard").ToLowerInvariant();
                // a shared channel is listed by the host team and by every team it is shared with: one conversation, first team wins
                if (type == "shared" && !_seenSharedChannels.TryAdd(cid, 1)) continue;
                var key = ConversationKeys.ForChannel(teamId, cid);
                var rec = new ConversationRecord
                {
                    Key = key, Kind = ConversationKind.Channel, TeamId = teamId, ChannelId = cid, MembershipType = type,
                    Topic = ExportUtil.Str(ch, "displayName"), TeamDisplayName = teamName, CreatedUtc = ExportUtil.Date(ch, "createdDateTime")
                };
                List<string> ids;
                if (type == "standard")
                {
                    rec.MembersJson = teamMembersJson; rec.MemberCount = teamMemberIds.Count; ids = teamMemberIds;
                }
                else
                {
                    List<JsonElement> members;
                    try { members = await ListAsync("v1.0/teams/" + t + "/channels/" + ExportUtil.Seg(cid) + "/members?$top=999", EndpointClass.ChannelMembers, teamId + "/" + cid, ct).ConfigureAwait(false); }
                    catch (GraphException ex) when ((ex.StatusCode == 403 || ex.StatusCode == 401) && !ExportUtil.IsCancel(ex, ct))
                    {
                        members = new List<JsonElement>();
                        _warnings.TryAdd("channelMembers", "Private/shared channel members could not be read (" + ex.StatusCode + " " + ex.ErrorCode + "): grant ChannelMember.Read.All. Those channels were inventoried WITHOUT their members.");
                    }
                    foreach (var m in members) DiscoverMember(m);
                    rec.MembersJson = MembersToJson(members); rec.MemberCount = members.Count; ids = MemberIds(members);
                    if (type == "private") Interlocked.Increment(ref _c.Private); else Interlocked.Increment(ref _c.Shared);
                }
                if (IsMigrated(ch)) rec.HasImportedContent = true;
                var existing = _store.GetConversation(key);
                if (existing != null && existing.HasImportedContent == true) rec.HasImportedContent = true;
                else if (existing != null && rec.HasImportedContent == null) rec.HasImportedContent = existing.HasImportedContent;
                NoteMigration(rec, ch);
                records.Add(rec);
                Interlocked.Increment(ref _c.Channels);
                Interlocked.Increment(ref _progress.Channels);
                Interlocked.Increment(ref _progress.Conversations);
                _channelMembers[key] = ids;
            }
            if (records.Count > 0) _store.UpsertConversations(records);
            if (_o.LinkChannelMembers)
            {
                // one LinkUserConversations call per user of the team (all their channels of this team at once)
                var perUser = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
                foreach (var rec in records)
                {
                    List<string> ids;
                    if (!_channelMembers.TryRemove(rec.Key, out ids)) continue;
                    foreach (var uid in ids)
                    {
                        List<string> l;
                        if (!perUser.TryGetValue(uid, out l)) perUser[uid] = l = new List<string>();
                        l.Add(rec.Key);
                    }
                }
                foreach (var kv in perUser)
                {
                    _store.LinkUserConversations(kv.Key, kv.Value);
                    Interlocked.Add(ref _c.ChannelLinks, kv.Value.Count);
                }
            }
            else foreach (var rec in records) { List<string> ignore; _channelMembers.TryRemove(rec.Key, out ignore); }
        }

        private readonly ConcurrentDictionary<string, List<string>> _channelMembers = new ConcurrentDictionary<string, List<string>>(StringComparer.Ordinal);
    }

    #endregion
}
