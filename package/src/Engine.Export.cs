// =============================================================================
//  TeamsTransfer - engine, lot E part 2: export (messages, hosted contents, file references) and Files stage
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.1
//
//  STRATEGIES (design 3.2, Phase0-Results)
//    U  per user  : GET /users/{id}/chats/getAllMessages?model=B&$filter=lastModifiedDateTime gt .. and lt ..
//       One paged stream for ALL the chats of a user, routed to the conversations by chatId. Fast (50 messages per call,
//       ~20 req/s per user, the limit is per user so users run in parallel). Costs: a group chat is read once per member
//       (the store deduplicates), and MESSAGES IMPORTED BY A MIGRATION ARE INVISIBLE to it (phase 0).
//    C  per chat  : GET /chats/{id}/messages?$top=50 [&$filter=..&$orderby=lastModifiedDateTime desc]
//       Reads a conversation exactly once, sees imported messages. About 1 req/s per chat and 20 req/s per app (throttling
//       page), so it is the exception: conversations flagged HasImportedContent, verification, or explicit choice.
//    Auto (default) = U for every user, then C for the conversations flagged HasImportedContent in the store.
//
//  CHANNELS: default is ONE stream per team (teams/{id}/channels/getAllMessages, roots AND replies, 50 per call, routed by
//  channelIdentity) rather than per channel messages + one replies call per thread: the latter costs 1 + (threads) calls per
//  channel, the former messages/50. PerChannel (roots, then replies of each root) is kept for channels flagged
//  HasImportedContent, as an automatic fallback when the team stream is refused, and by choice. LIMIT of PerChannel in
//  incremental mode: a new reply may not touch the root's lastModifiedDateTime; replies of unmodified roots are then missed
//  until a full pass. The team stream does not have this problem.
//
//  INCREMENTAL / RESUME
//    - watermark per unit (wm:u:{user}, wm:c:{conv}, wm:t:{team}) = the interval already covered "from|to". A new request for
//      [F,T) reads only what is missing, with an overlap (default 2 min) because the service is eventually consistent;
//      the store deduplicates (MessageWriteResult.Unchanged), so the overlap is free of side effects.
//    - an interrupted unit keeps its @odata.nextLink (gam:{user}, cm:{conv}, tgam:{team}) saved AFTER the page was flushed to
//      the store: resume restarts at the next page, never loses and rarely repeats.
//    - the watermark only moves when the unit finished; a failed unit is recorded (err:...) and retried by the next run.
//
//  HOSTED CONTENTS are downloaded once per (conversation, message, id): bounded in-memory set + IStoreReader.FindHostedContent
//  when a reader is available; streamed (no buffering) to IExportStore.PutContent (SHA-256 content addressed).
//  FILE REFERENCES (attachments of contentType 'reference') are only RECORDED (Pending) here; FilesStage downloads them.
//  Hosted contents and files of a batch of messages that the store reports entirely Unchanged are not reprocessed.
//  Contract assumed from the store: RecordFile must not downgrade a Downloaded file back to Pending.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    #region Options and results

    /// <summary>The run was stopped because the same error hit the first units with no success: the cause is systematic, not per user.</summary>
    public sealed class SystematicFailureException : Exception
    {
        public int StatusCode { get; }
        public string ErrorCode { get; }
        public string Endpoint { get; }
        public SystematicFailureException(int status, string code, string message, string endpoint)
            : base("systematic failure: " + status + " " + code + " " + message + " on " + endpoint + "; nothing exported; fix the cause and run again")
        { StatusCode = status; ErrorCode = code; Endpoint = endpoint; }
    }

    public enum ExportStrategy { Auto, U, C }
    public enum ChannelMode { PerTeam, PerChannel }

    public sealed class ExportOptions
    {
        public ExportStrategy Strategy { get; set; } = ExportStrategy.Auto;
        /// <summary>Window on lastModifiedDateTime [From, To). Null From = from the beginning; null To = now (run start).</summary>
        public DateTimeOffset? From { get; set; }
        public DateTimeOffset? To { get; set; }
        /// <summary>Use and update the watermarks. False = read the whole requested window again (store still deduplicates).</summary>
        public bool Incremental { get; set; } = true;
        public TimeSpan WatermarkOverlap { get; set; } = TimeSpan.FromMinutes(2);
        public bool IncludeChats { get; set; } = true;
        public bool IncludeChannels { get; set; } = false;
        /// <summary>Default user scope with an IStoreReader: only users linked to at least one conversation (the ones the inventory covered). True = every non-deleted user of the store.</summary>
        public bool AllStoreUsers { get; set; } = false;
        /// <summary>Stop the run when this many units fail with the same Graph error on the same endpoint before any unit succeeded (0 = off).</summary>
        public int CircuitBreakerUnits { get; set; } = 25;
        /// <summary>Restricts the channel export to these teams (id or display name, exact match). Null/empty = every team of the store.</summary>
        public IReadOnlyCollection<string> Teams { get; set; }
        public ChannelMode ChannelMode { get; set; } = ChannelMode.PerTeam;
        public bool IncludeHostedContents { get; set; } = true;
        /// <summary>Record the file references (FilesStage downloads them).</summary>
        public bool IncludeFiles { get; set; } = false;
        public int UserParallelism { get; set; } = 8;
        public int ConversationParallelism { get; set; } = 8;
        public int TeamParallelism { get; set; } = 4;
        /// <summary>Channels read at the same time inside one team (per-channel reads are slow: about 0.15 s per message on the service, so only parallelism speeds them up).</summary>
        public int ChannelParallelism { get; set; } = 32;
        /// <summary>Ask for the replies inside the root listing ($expand=replies) instead of one replies call per root. Roots that come back without a replies array fall back to the replies endpoint.</summary>
        public bool ExpandReplies { get; set; } = true;
        /// <summary>$top of the channel root listing. The service answers cost about 0.15 s per message at 50 but only about 0.09 s at 10 (a 10-message page returns in about 1 s, a 50-message page in 7-10 s), so small pages finish a channel sooner.</summary>
        public int ChannelPageSize { get; set; } = 10;
        public int PageSize { get; set; } = 50;
        /// <summary>Messages buffered before one AppendMessages call (and a checkpoint at every page).</summary>
        public int BatchSize { get; set; } = 200;
        public string[] ExcludedExtensions { get; set; } = new string[0];
        public int HostedContentAttempts { get; set; } = 3;
        public int KeyCacheSize { get; set; } = 200000;
        public StopControl Stop { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    public sealed class UnitTiming
    {
        public string Scope { get; set; }
        public double Seconds { get; set; }
        public string Outcome { get; set; }
    }

    public sealed class ExportResult
    {
        public string Strategy { get; set; }
        public bool Stopped { get; set; }
        public long UnitsDone { get; set; }
        public long UnitsUpToDate { get; set; }
        public long UnitsFailed { get; set; }
        /// <summary>Users whose account no longer exists (404): their chats come through the other members.</summary>
        public long UsersGone { get; set; }
        public long Conversations { get; set; }
        /// <summary>Conversations read with strategy C in this run (flagged HasImportedContent, or chosen).</summary>
        public long ConversationsViaC { get; set; }
        public long MessagesSeen { get; set; }
        public long MessagesNew { get; set; }
        public long MessagesUpdated { get; set; }
        public long MessagesUnchanged { get; set; }
        public long HostedDownloaded { get; set; }
        public long HostedSkipped { get; set; }
        public long HostedFailed { get; set; }
        public long FilesRecorded { get; set; }
        public long ContentBytes { get; set; }
        public List<string> FailedUnits { get; set; } = new List<string>();
        public List<string> Warnings { get; set; } = new List<string>();
        public List<ErrorRecord> Errors { get; set; } = new List<ErrorRecord>();
        /// <summary>What the Graph client did during this run: requests per endpoint class, retries, 429/503, time waited for the server.</summary>
        public GraphMetricsSnapshot Metrics { get; set; }
        /// <summary>The slowest units (user, conversation, team) of the run, to find where the time goes.</summary>
        public List<UnitTiming> SlowestUnits { get; set; } = new List<UnitTiming>();
        public TimeSpan Duration { get; set; }
        public double MessagesPerSecond => Duration.TotalSeconds > 0 ? MessagesSeen / Duration.TotalSeconds : 0;
        public string Summary => Strategy + ": " + (UnitsDone + UnitsUpToDate + UnitsFailed + UsersGone) + " units (" + UnitsFailed + " failed), " + ConversationsViaC + " conversation(s) read with strategy C, " + MessagesNew + " new / " + MessagesUpdated + " updated / " + MessagesUnchanged + " unchanged messages";
    }

    #endregion

    #region Window planning

    /// <summary>Interval of lastModifiedDateTime (or createdDateTime) to read. Exposed for tests.</summary>
    public sealed class ExportRange
    {
        public DateTimeOffset? From { get; set; }
        public DateTimeOffset To { get; set; }
        /// <summary>True when To must be sent as a filter (explicit window); false = open ended (up to now).</summary>
        public bool ToBounded { get; set; }
        /// <summary>
        /// Initial range of a conversation with imported content: READ IN FULL (no server-side filter: Graph rejects $filter on createdDateTime, and
        /// the window is applied on createdDateTime on the client). Delta ranges always use lastModifiedDateTime on the server.
        /// </summary>
        public bool ByCreated { get; set; }
        public bool Delta { get; set; }
        public string Id => (From.HasValue ? ExportUtil.Iso(From.Value) : "-") + "|" + (ToBounded ? ExportUtil.Iso(To) : "~") + "|" + (ByCreated ? "c" : "m");
    }

    public sealed class CoveredInterval
    {
        public DateTimeOffset? From { get; set; }
        public DateTimeOffset To { get; set; }
        public string Serialize() { return (From.HasValue ? ExportUtil.Iso(From.Value) : "-") + "|" + ExportUtil.Iso(To); }
        public static CoveredInterval Parse(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            var p = s.Split('|');
            DateTimeOffset to, from;
            if (p.Length != 2 || !ExportUtil.TryParseDate(p[1], out to)) return null;
            var c = new CoveredInterval { To = to };
            if (p[0] != "-" && ExportUtil.TryParseDate(p[0], out from)) c.From = from;
            return c;
        }
    }

    public static class WindowPlanner
    {
        /// <summary>
        /// What must be read to cover [from, to) given what was already covered. Returns 0, 1 or 2 ranges and the interval covered
        /// once they are done. byCreatedForInitial: the initial (non delta) ranges filter on createdDateTime (conversations that
        /// contain imported messages: their lastModifiedDateTime is 0001-01-01).
        /// </summary>
        public static List<ExportRange> Plan(DateTimeOffset? from, DateTimeOffset to, bool toBounded, CoveredInterval covered, bool incremental,
            TimeSpan overlap, bool byCreatedForInitial, out CoveredInterval newCovered)
        {
            var list = new List<ExportRange>();
            Func<DateTimeOffset?, DateTimeOffset?, bool> ge = (f, cf) => !cf.HasValue || (f.HasValue && f.Value >= cf.Value);
            if (!incremental || covered == null)
            {
                newCovered = new CoveredInterval { From = from, To = to };
                list.Add(new ExportRange { From = from, To = to, ToBounded = toBounded, ByCreated = byCreatedForInitial });
                return list;
            }
            if (ge(from, covered.From))
            {
                if (from.HasValue && from.Value > covered.To)
                {
                    newCovered = new CoveredInterval { From = from, To = to };   // gap: the covered interval is not contiguous with the request
                    list.Add(new ExportRange { From = from, To = to, ToBounded = toBounded, ByCreated = byCreatedForInitial });
                    return list;
                }
                if (to <= covered.To) { newCovered = covered; return list; }
                var start = covered.To - overlap;
                if (from.HasValue && from.Value > start) start = from.Value;
                newCovered = new CoveredInterval { From = covered.From, To = to };
                list.Add(new ExportRange { From = start, To = to, ToBounded = toBounded, Delta = true });
                return list;
            }
            // the request starts before what is covered (an extension wave: 25-36 months after 0-24)
            if (to < covered.From.Value)
            {
                newCovered = new CoveredInterval { From = from, To = to };
                list.Add(new ExportRange { From = from, To = to, ToBounded = toBounded, ByCreated = byCreatedForInitial });
                return list;
            }
            var head = new ExportRange { From = from, To = covered.From.Value, ToBounded = true, ByCreated = byCreatedForInitial };
            list.Add(head);
            if (to > covered.To) list.Add(new ExportRange { From = covered.To - overlap, To = to, ToBounded = toBounded, Delta = true });
            newCovered = new CoveredInterval { From = from, To = to > covered.To ? to : covered.To };
            return list;
        }
    }

    #endregion

    #region Exporter

    public sealed class Exporter
    {
        private readonly GraphClient _g;
        private readonly IExportStore _store;
        private readonly IStoreReader _reader;
        private readonly ExportOptions _o;
        private readonly Func<DateTimeOffset> _now;
        private ProgressReporter _p;
        private Totals _t = new Totals();
        private readonly BoundedKeySet _hostedSeen;
        private readonly BoundedKeySet _filesSeen;
        private readonly BoundedKeySet _convKnown;
        private ConcurrentQueue<ErrorRecord> _errors = new ConcurrentQueue<ErrorRecord>();
        private ConcurrentQueue<string> _failed = new ConcurrentQueue<string>();
        private ConcurrentQueue<string> _warnings = new ConcurrentQueue<string>();
        private long _successUnits;
        private ConcurrentQueue<UnitTiming> _timings = new ConcurrentQueue<UnitTiming>();
        private GraphMetricsSnapshot _metrics0;
        private readonly ConcurrentDictionary<string, int> _failureSignatures = new ConcurrentDictionary<string, int>(StringComparer.Ordinal);
        private DateTimeOffset _runTo;
        private static readonly Regex HostedRx = new Regex(@"hostedContents/([^/""'\s<>]+)/\$value", RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private sealed class Totals
        {
            public long ViaC, Done, UpToDate, Failed, Gone, Conversations, Seen, New, Updated, Unchanged, HostedOk, HostedSkipped, HostedFailed, Files, Bytes;
        }

        private enum Outcome { Done, UpToDate, Stopped, Gone }

        public Exporter(GraphClient graph, IExportStore store, ExportOptions options = null, IStoreReader reader = null)
        {
            if (graph == null) throw new ArgumentNullException(nameof(graph));
            if (store == null) throw new ArgumentNullException(nameof(store));
            _g = graph; _store = store; _o = options ?? new ExportOptions();
            _reader = reader ?? (store as IStoreReader);
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _hostedSeen = new BoundedKeySet(_o.KeyCacheSize);
            _filesSeen = new BoundedKeySet(_o.KeyCacheSize);
            _convKnown = new BoundedKeySet(_o.KeyCacheSize);
            _p = new ProgressReporter("Export", _o.OnProgress, _now);
        }

        public ProgressSnapshot Progress => _p.Snapshot();
        public ExportOptions Options => _o;

        // ------------------------------------------------------------------ public entry points

        /// <summary>
        /// Maps user identities (id, UPN or mail) to the ids the store links conversations to, when the store knows the user. The
        /// links, the watermarks and the strategy C selection are all keyed by id; Graph itself accepts either form.
        /// </summary>
        private List<string> NormalizeUsers(IEnumerable<string> identities)
        {
            if (identities == null) return null;
            var list = identities.Where(x => !string.IsNullOrWhiteSpace(x)).ToList();
            if (_reader == null || !list.Any(x => x.IndexOf('@') >= 0)) return list.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var u in _reader.ListUsers())
            {
                if (u.Id == null) continue;
                if (!string.IsNullOrEmpty(u.UserPrincipalName)) map[u.UserPrincipalName] = u.Id;
                if (!string.IsNullOrEmpty(u.Mail) && !map.ContainsKey(u.Mail)) map[u.Mail] = u.Id;
            }
            return list.Select(x => { string id; return map.TryGetValue(x, out id) ? id : x; }).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }

        private void Begin(string op)
        {
            _t = new Totals(); _errors = new ConcurrentQueue<ErrorRecord>(); _failed = new ConcurrentQueue<string>(); _warnings = new ConcurrentQueue<string>();
            Interlocked.Exchange(ref _successUnits, 0); _failureSignatures.Clear(); _timings = new ConcurrentQueue<UnitTiming>();
            var gm = GraphMetrics.Of(_g); _metrics0 = gm != null ? gm.Snapshot() : null;
            _p = new ProgressReporter(op, _o.OnProgress, _now);
            _runTo = _o.To ?? _now();
        }

        private ExportResult End(string strategy, System.Diagnostics.Stopwatch sw)
        {
            var r = new ExportResult
            {
                Strategy = strategy, Stopped = StopControl.Stopped(_o.Stop), UnitsDone = _t.Done, UnitsUpToDate = _t.UpToDate, UnitsFailed = _t.Failed, UsersGone = _t.Gone,
                Conversations = _t.Conversations, ConversationsViaC = _t.ViaC, MessagesSeen = _t.Seen, MessagesNew = _t.New, MessagesUpdated = _t.Updated, MessagesUnchanged = _t.Unchanged,
                HostedDownloaded = _t.HostedOk, HostedSkipped = _t.HostedSkipped, HostedFailed = _t.HostedFailed, FilesRecorded = _t.Files, ContentBytes = _t.Bytes,
                FailedUnits = _failed.ToList(), Warnings = _warnings.ToList(),
                SlowestUnits = _timings.OrderByDescending(x => x.Seconds).Take(10).ToList(), Errors = _errors.ToList(), Duration = sw.Elapsed
            };
            var gm = GraphMetrics.Of(_g);
            if (gm != null && _metrics0 != null) r.Metrics = GraphMetricsSnapshot.Delta(gm.Snapshot(), _metrics0);
            _p.Finish();
            return r;
        }

        /// <summary>Whole export according to Options: chats (U, C or Auto) then channels when IncludeChannels.</summary>
        public async Task<ExportResult> RunAsync(IEnumerable<string> userIds = null, CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Begin("Export");
            var users = NormalizeUsers(userIds);
            if (_o.IncludeChats)
            {
                if (_o.Strategy != ExportStrategy.C) await UsersCoreAsync(users, ct).ConfigureAwait(false);
                if (_o.Strategy == ExportStrategy.C || _o.Strategy == ExportStrategy.Auto)
                {
                    if (_reader == null)
                    {
                        if (_o.Strategy == ExportStrategy.C) throw new InvalidOperationException("Strategy C needs the list of conversations: pass an IStoreReader (or use ExportConversationsAsync with explicit keys).");
                    }
                    else await ConversationsCoreAsync(ChatKeysForC(users, _o.Strategy == ExportStrategy.Auto), ct).ConfigureAwait(false);
                }
            }
            if (_o.IncludeChannels && !StopControl.Stopped(_o.Stop)) await TeamsCoreAsync(null, ct).ConfigureAwait(false);
            return End(_o.Strategy.ToString(), sw);
        }

        /// <summary>Strategy U for these users (null = every user known to the store, else every user of the directory).</summary>
        public async Task<ExportResult> ExportUsersAsync(IEnumerable<string> userIds, CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Begin("Export U");
            await UsersCoreAsync(NormalizeUsers(userIds), ct).ConfigureAwait(false);
            return End("U", sw);
        }

        /// <summary>Strategy C for these conversation keys (chat:... and channel:team/channel:...). Each key is read once.</summary>
        public async Task<ExportResult> ExportConversationsAsync(IEnumerable<string> conversationKeys, CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Begin("Export C");
            await ConversationsCoreAsync(conversationKeys.Distinct(StringComparer.Ordinal), ct).ConfigureAwait(false);
            return End("C", sw);
        }

        /// <summary>Channels of these teams (null = every team that has channels in the store).</summary>
        public async Task<ExportResult> ExportTeamsAsync(IEnumerable<string> teamIds, CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Begin("Export channels");
            await TeamsCoreAsync(teamIds == null ? null : teamIds.Distinct(StringComparer.OrdinalIgnoreCase).ToList(), ct).ConfigureAwait(false);
            return End("channels", sw);
        }

        // ------------------------------------------------------------------ helpers

        private void Fail(string scope, string op, Exception ex)
        {
            var rec = ErrorRecord.From(scope, op, ex, _now());
            _errors.Enqueue(rec);
            _failed.Enqueue(scope);
            Interlocked.Increment(ref _t.Failed);
            Interlocked.Increment(ref _p.Errors);
            try { _store.SetCheckpoint("err:" + scope, rec.ToString()); } catch (Exception) { }
        }

        /// <summary>Same Graph error on the same endpoint for N units and not one success so far: stop instead of failing every unit.</summary>
        private void CheckCircuit(Exception ex)
        {
            int limit = _o.CircuitBreakerUnits;
            var g = ex as GraphException;
            if (limit <= 0 || g == null || Interlocked.Read(ref _successUnits) > 0) return;
            string endpoint = GraphClient.Classify(g.Url);
            string sig = g.StatusCode + "|" + g.ErrorCode + "|" + endpoint;
            int n = _failureSignatures.AddOrUpdate(sig, 1, (k, v) => v + 1);
            if (n >= limit && Interlocked.Read(ref _successUnits) == 0)
            {
                string msg = g.Message;
                int i = msg.IndexOf(": ", StringComparison.Ordinal);
                int j = msg.IndexOf(" (url:", StringComparison.Ordinal);
                if (i >= 0 && j > i) msg = msg.Substring(i + 2, j - i - 2);
                throw new SystematicFailureException(g.StatusCode, g.ErrorCode, msg, endpoint);
            }
        }

        private static bool Recoverable(Exception ex)
        {
            return ex is GraphException || ex is IOException || ex is HttpRequestException || ex is JsonException || ex is TimeoutException;
        }

        private async Task RunUnitAsync(string scope, string op, Func<CancellationToken, Task<Outcome>> work, CancellationToken ct)
        {
            var unitSw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                var o = await work(ct).ConfigureAwait(false);
                _timings.Enqueue(new UnitTiming { Scope = scope, Seconds = unitSw.Elapsed.TotalSeconds, Outcome = o.ToString() });
                switch (o)
                {
                    case Outcome.Done: Interlocked.Increment(ref _t.Done); Interlocked.Increment(ref _successUnits); break;
                    case Outcome.UpToDate: Interlocked.Increment(ref _t.UpToDate); Interlocked.Increment(ref _successUnits); break;
                    case Outcome.Gone: Interlocked.Increment(ref _t.Gone); break;
                }
                if (o != Outcome.Stopped && !string.IsNullOrEmpty(_store.GetCheckpoint("err:" + scope))) _store.SetCheckpoint("err:" + scope, "");
            }
            catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && Recoverable(ex))
            {
                _timings.Enqueue(new UnitTiming { Scope = scope, Seconds = unitSw.Elapsed.TotalSeconds, Outcome = "Failed" });
                Fail(scope, op, ex);
                CheckCircuit(ex);
            }
            Interlocked.Increment(ref _p.UnitsDone);
            _p.Tick();
        }

        private List<ExportRange> PlanFor(string wmScope, bool byCreatedInitial, out CoveredInterval newCovered)
        {
            var covered = _o.Incremental ? CoveredInterval.Parse(_store.GetCheckpoint(wmScope)) : null;
            return WindowPlanner.Plan(_o.From, _runTo, _o.To.HasValue, covered, _o.Incremental, _o.WatermarkOverlap, byCreatedInitial, out newCovered);
        }

        private string FilterQuery(ExportRange r, bool listing)
        {
            // never a server-side filter on createdDateTime: Graph answers 400 ("property 'createdDateTime' ... is not allowed in $filter")
            const string prop = "lastModifiedDateTime";
            if (listing && r.ByCreated) return "";
            var clauses = new List<string>();
            if (!listing)
            {
                // getAllMessages: Graph answers 400 "Missing 'lastModifiedDateTime' value" to a one-sided filter: always send both bounds.
                var lo = r.From ?? MinLowerBound;
                var hi = r.ToBounded ? r.To : _runTo.AddMinutes(5);
                clauses.Add(prop + " gt " + ExportUtil.Iso(lo.AddMilliseconds(-1)));
                clauses.Add(prop + " lt " + ExportUtil.Iso(hi));
                return "&$filter=" + Uri.EscapeDataString(string.Join(" and ", clauses));
            }
            if (r.From.HasValue) clauses.Add(prop + " gt " + ExportUtil.Iso(r.From.Value.AddMilliseconds(-1)));
            if (r.ToBounded) clauses.Add(prop + " lt " + ExportUtil.Iso(r.To));
            if (clauses.Count == 0) return "";
            string q = "&$filter=" + Uri.EscapeDataString(string.Join(" and ", clauses));
            if (listing) q += "&$orderby=" + prop + "%20desc";
            return q;
        }

        /// <summary>Lower bound sent when no start date is given (getAllMessages needs both bounds).</summary>
        public static readonly DateTimeOffset MinLowerBound = new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);

        /// <summary>Client-side window of a full-read range (conversation with imported content): messages created inside [From, To).</summary>
        private static bool InRange(ExportRange r, JsonElement msg)
        {
            if (!r.ByCreated) return true;
            var created = ExportUtil.Date(msg, "createdDateTime");
            if (!created.HasValue) return true;
            if (r.From.HasValue && created.Value < r.From.Value) return false;
            if (r.ToBounded && created.Value >= r.To) return false;
            return true;
        }

        /// <summary>
        /// Client-side window for the root messages of a channel listing (the endpoint accepts neither $filter nor $orderby):
        /// a full-read range uses createdDateTime, a delta range lastModifiedDateTime. A missing or 0001 date is always in.
        /// </summary>
        private static bool InWindow(ExportRange r, JsonElement msg)
        {
            if (r.ByCreated) return InRange(r, msg);
            var lm = ExportUtil.Date(msg, "lastModifiedDateTime");
            if (!lm.HasValue) return true;
            if (r.From.HasValue && lm.Value <= r.From.Value.AddMilliseconds(-1)) return false;
            if (r.ToBounded && lm.Value >= r.To) return false;
            return true;
        }

        /// <summary>The root message as stored: without the expanded "replies" (they are stored as messages of their own).</summary>
        private static JsonElement StripReplies(JsonElement root)
        {
            JsonElement p;
            bool has = false;
            foreach (var prop in root.EnumerateObject()) if (prop.Name.StartsWith("replies", StringComparison.Ordinal)) { has = true; break; }
            if (!has) return root;
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    foreach (var prop in root.EnumerateObject())
                        if (!prop.Name.StartsWith("replies", StringComparison.Ordinal)) prop.WriteTo(w);
                    w.WriteEndObject();
                }
                using (var doc = JsonDocument.Parse(ms.ToArray())) return doc.RootElement.Clone();
            }
        }

        private int Top => Math.Min(50, Math.Max(1, _o.PageSize));

        private bool Stopping => StopControl.Stopped(_o.Stop);

        /// <summary>Creates a minimal conversation (and the user link) when the export reaches a conversation the inventory does not know.</summary>
        private void EnsureConversation(string key, string chatId, string teamId, string channelId, string userId)
        {
            if (!_convKnown.Add(key)) return;
            if (_store.GetConversation(key) != null) return;
            var rec = new ConversationRecord { Key = key };
            if (chatId != null) { rec.Kind = ConversationKind.Group; rec.ChatId = chatId; }
            else { rec.Kind = ConversationKind.Channel; rec.TeamId = teamId; rec.ChannelId = channelId; }
            _store.UpsertConversations(new[] { rec });
            if (userId != null) _store.LinkUserConversations(userId, new[] { key });
        }

        // ------------------------------------------------------------------ batching sink

        private sealed class Sink
        {
            private readonly Exporter _x;
            private readonly Dictionary<string, List<JsonElement>> _by = new Dictionary<string, List<JsonElement>>(StringComparer.Ordinal);
            private int _count;
            public Sink(Exporter x) { _x = x; }

            public Task AddAsync(string key, JsonElement el, CancellationToken ct)
            {
                List<JsonElement> l;
                if (!_by.TryGetValue(key, out l)) _by[key] = l = new List<JsonElement>();
                l.Add(el);
                if (++_count >= _x._o.BatchSize) return FlushAsync(ct);
                return Task.CompletedTask;
            }

            public async Task FlushAsync(CancellationToken ct)
            {
                if (_count == 0) return;
                var by = new List<KeyValuePair<string, List<JsonElement>>>(_by);
                _by.Clear(); _count = 0;
                foreach (var kv in by)
                {
                    var r = _x._store.AppendMessages(kv.Key, kv.Value);
                    Interlocked.Add(ref _x._t.Seen, kv.Value.Count);
                    Interlocked.Add(ref _x._t.New, r.New);
                    Interlocked.Add(ref _x._t.Updated, r.Updated);
                    Interlocked.Add(ref _x._t.Unchanged, r.Unchanged);
                    Interlocked.Add(ref _x._p.Messages, kv.Value.Count);
                    Interlocked.Add(ref _x._p.NewMessages, r.New);
                    Interlocked.Add(ref _x._p.UpdatedMessages, r.Updated);
                    if ((r.New > 0 || r.Updated > 0) && (_x._o.IncludeHostedContents || _x._o.IncludeFiles))
                        foreach (var el in kv.Value) await _x.ProcessMessageAsync(kv.Key, el, ct).ConfigureAwait(false);
                }
            }
        }

        // ------------------------------------------------------------------ hosted contents and file references

        private async Task ProcessMessageAsync(string convKey, JsonElement msg, CancellationToken ct)
        {
            JsonElement body, content, atts;
            string msgId = ExportUtil.Str(msg, "id");
            if (msgId == null) return;
            if (_o.IncludeHostedContents && msg.TryGetProperty("body", out body) && body.ValueKind == JsonValueKind.Object &&
                body.TryGetProperty("content", out content) && content.ValueKind == JsonValueKind.String)
            {
                string html = content.GetString();
                if (html != null && html.IndexOf("hostedContents", StringComparison.Ordinal) >= 0)
                    foreach (Match m in HostedRx.Matches(html))
                        await DownloadHostedAsync(convKey, msg, msgId, m.Groups[1].Value, ct).ConfigureAwait(false);
            }
            if (_o.IncludeFiles && msg.TryGetProperty("attachments", out atts) && atts.ValueKind == JsonValueKind.Array)
            {
                foreach (var a in atts.EnumerateArray())
                {
                    if (!string.Equals(ExportUtil.Str(a, "contentType"), "reference", StringComparison.OrdinalIgnoreCase)) continue;
                    string url = ExportUtil.Str(a, "contentUrl");
                    if (string.IsNullOrEmpty(url)) continue;
                    string attId = ExportUtil.Str(a, "id") ?? "";
                    if (!_filesSeen.Add(convKey + "|" + msgId + "|" + attId)) continue;
                    string name = ExportUtil.Str(a, "name");
                    var rec = new FileRecord
                    {
                        ConversationKey = convKey, MessageId = msgId, AttachmentId = attId, Name = name, SourceUrl = url, Status = FileStatus.Pending
                    };
                    if (FilesStage.IsExcluded(name ?? url, _o.ExcludedExtensions)) { rec.Status = FileStatus.Excluded; rec.Error = "extension excluded"; }
                    _store.RecordFile(rec);
                    Interlocked.Increment(ref _t.Files);
                    Interlocked.Increment(ref _p.FilesRecorded);
                }
            }
        }

        internal static string HostedUrl(string convKey, JsonElement msg, string msgId, string hostedId)
        {
            string hid = ExportUtil.Seg(hostedId);
            if (convKey.StartsWith("chat:", StringComparison.Ordinal))
                return "v1.0/chats/" + ExportUtil.Seg(convKey.Substring(5)) + "/messages/" + ExportUtil.Seg(msgId) + "/hostedContents/" + hid + "/$value";
            string rest = convKey.Substring("channel:".Length);
            int slash = rest.IndexOf('/');
            string team = ExportUtil.Seg(rest.Substring(0, slash)), chan = ExportUtil.Seg(rest.Substring(slash + 1));
            string replyTo = ExportUtil.Str(msg, "replyToId");
            string prefix = "v1.0/teams/" + team + "/channels/" + chan + "/messages/";
            if (!string.IsNullOrEmpty(replyTo)) return prefix + ExportUtil.Seg(replyTo) + "/replies/" + ExportUtil.Seg(msgId) + "/hostedContents/" + hid + "/$value";
            return prefix + ExportUtil.Seg(msgId) + "/hostedContents/" + hid + "/$value";
        }

        private async Task DownloadHostedAsync(string convKey, JsonElement msg, string msgId, string hostedId, CancellationToken ct)
        {
            string key = convKey + "|" + msgId + "|" + hostedId;
            if (!_hostedSeen.Add(key)) { Interlocked.Increment(ref _t.HostedSkipped); return; }
            if (_reader != null && _reader.FindHostedContent(convKey, msgId, hostedId) != null) { Interlocked.Increment(ref _t.HostedSkipped); return; }
            string url = HostedUrl(convKey, msg, msgId, hostedId);
            Exception last = null;
            for (int attempt = 1; attempt <= Math.Max(1, _o.HostedContentAttempts); attempt++)
            {
                try
                {
                    var req = new GraphRequest { Method = HttpMethod.Get, Url = url, EndpointClass = EndpointClass.HostedContent, ThreadKey = convKey };
                    using (var resp = await _g.SendAsync(req, ct).ConfigureAwait(false))
                    {
                        ContentRef cr = await PutVerifiedAsync(_store, resp, ct).ConfigureAwait(false);
                        _store.RecordHostedContent(convKey, msgId, hostedId, cr);
                        Interlocked.Increment(ref _t.HostedOk);
                        Interlocked.Increment(ref _p.HostedContents);
                        Interlocked.Add(ref _t.Bytes, cr.Length);
                        Interlocked.Add(ref _p.Bytes, cr.Length);
                    }
                    return;
                }
                catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 403 || ex.StatusCode == 410)
                {
                    last = ex; break;     // gone or forbidden: retrying will not help
                }
                catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && Recoverable(ex)) { last = ex; }
            }
            Interlocked.Increment(ref _t.HostedFailed);
            Interlocked.Increment(ref _p.Errors);
            _errors.Enqueue(ErrorRecord.From(key, "hostedContent", last, _now()));
        }

        /// <summary>Streams the response body into the store; fails when the body is shorter than the announced Content-Length (truncated download).</summary>
        internal static async Task<ContentRef> PutVerifiedAsync(IExportStore store, GraphResponse resp, CancellationToken ct)
        {
            long expected = -1;
            string cl;
            if (resp.Headers.TryGetValue("Content-Length", out cl)) { long v; if (long.TryParse(cl, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) expected = v; }
            var counting = new CountingReadStream(resp.Content);
            string ctype = resp.ContentType;
            ContentRef cr = await Task.Run(() => store.PutContent(counting, ctype), ct).ConfigureAwait(false);
            if (expected >= 0 && counting.Count != expected)
                throw new IOException("Truncated download: received " + counting.Count + " of " + expected + " bytes.");
            return cr;
        }

        internal sealed class CountingReadStream : Stream
        {
            private readonly Stream _s;
            public long Count;
            public CountingReadStream(Stream s) { _s = s; }
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) { int n = _s.Read(buffer, offset, count); Count += n; return n; }
            public override int Read(Span<byte> buffer) { int n = _s.Read(buffer); Count += n; return n; }
            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) { int n = await _s.ReadAsync(buffer, ct).ConfigureAwait(false); Count += n; return n; }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        }

        // ------------------------------------------------------------------ strategy U (per user)

        /// <summary>
        /// Default user scope with a reader: the users the inventory actually covered (not deleted, linked to at least one conversation).
        /// allStoreUsers = every non-deleted user of the store, covered or not.
        /// </summary>
        public List<string> ResolveDefaultUsers(bool allStoreUsers)
        {
            if (_reader == null) throw new InvalidOperationException("ResolveDefaultUsers needs an IStoreReader.");
            var list = new List<string>();
            foreach (var u in _reader.ListUsers())
            {
                if (u.State == UserState.Deleted || u.State == UserState.External) continue;
                if (allStoreUsers || _reader.ListConversations(u.Id).Any()) list.Add(u.Id);
            }
            return list;
        }

        private async Task UsersCoreAsync(List<string> users, CancellationToken ct)
        {
            if (users == null)
            {
                if (_reader != null)
                {
                    users = ResolveDefaultUsers(_o.AllStoreUsers);
                    if (!_o.AllStoreUsers && users.Count > 1000)
                        _warnings.Enqueue("No -Users given: exporting the " + users.Count + " users linked to a conversation in the store. Pass -Users to scope the run.");
                    if (users.Count == 0)
                        _warnings.Enqueue("No user is linked to a conversation in the store: run the inventory first, or pass -Users / -AllStoreUsers.");
                }
                else
                {
                    users = new List<string>();
                    await foreach (var u in _g.GetPagedAsync("v1.0/users?$select=id&$top=999", EndpointClass.Users, cancellationToken: ct).ConfigureAwait(false))
                    { var id = ExportUtil.Str(u, "id"); if (id != null) users.Add(id); }
                }
            }
            _p.Phase("users (U)", users.Count);
            await Par.ForEachAsync(users, Math.Max(1, _o.UserParallelism),
                (u, token) => RunUnitAsync("u:" + u, "getAllMessages", t => ExportUserAsync(u, t), token), ct, _o.Stop).ConfigureAwait(false);
        }

        private async Task<Outcome> ExportUserAsync(string userId, CancellationToken ct)
        {
            string wm = "wm:u:" + userId, cp = "gam:" + userId;
            CoveredInterval newCov;
            var ranges = PlanFor(wm, false, out newCov);
            if (ranges.Count == 0) return Outcome.UpToDate;
            var sink = new Sink(this);
            foreach (var range in ranges)
            {
                string id = range.Id;
                string resume = ResumeLink(cp, id);
                string url = "v1.0/users/" + ExportUtil.Seg(userId) + "/chats/getAllMessages?$top=" + Top + FilterQuery(range, false);
                try
                {
                    await foreach (var msg in _g.GetPagedAsync(url, EndpointClass.ChatGetAllMessages,
                        onNextLink: async nl => { await sink.FlushAsync(ct).ConfigureAwait(false); _store.SetCheckpoint(cp, id + "#" + nl); },
                        resumeFromNextLink: resume, threadKey: userId, cancellationToken: ct).ConfigureAwait(false))
                    {
                        string chatId = ExportUtil.Str(msg, "chatId");
                        if (chatId == null) continue;
                        string key = ConversationKeys.ForChat(chatId);
                        EnsureConversation(key, chatId, null, null, userId);
                        await sink.AddAsync(key, msg, ct).ConfigureAwait(false);
                        if (Stopping) { await sink.FlushAsync(ct).ConfigureAwait(false); return Outcome.Stopped; }
                    }
                }
                catch (GraphException ex) when (ex.StatusCode == 404 && !ExportUtil.IsCancel(ex, ct))
                {
                    await sink.FlushAsync(ct).ConfigureAwait(false);
                    _store.SetCheckpoint(cp, "");
                    return Outcome.Gone;      // deleted account: its chats are exported through the other members
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    try { await sink.FlushAsync(ct).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
                await sink.FlushAsync(ct).ConfigureAwait(false);
                _store.SetCheckpoint(cp, "");
            }
            if (_o.Incremental) _store.SetCheckpoint(wm, newCov.Serialize());
            return Outcome.Done;
        }

        private string ResumeLink(string cpScope, string rangeId)
        {
            var v = _store.GetCheckpoint(cpScope);
            if (string.IsNullOrEmpty(v)) return null;
            int i = v.IndexOf('#');
            if (i < 0 || v.Substring(0, i) != rangeId) return null;
            return v.Substring(i + 1);
        }

        // ------------------------------------------------------------------ strategy C (per chat / per channel)

        private IEnumerable<string> ChatKeysForC(List<string> users, bool onlyFlagged)
        {
            Func<ConversationRecord, bool> ok = c => c.Kind != ConversationKind.Channel && (!onlyFlagged || c.HasImportedContent == true);
            if (users == null)
            {
                foreach (var c in _reader.ListConversations()) if (ok(c)) yield return c.Key;
                yield break;
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var u in users)
                foreach (var c in _reader.ListConversations(u))
                    if (ok(c) && seen.Add(c.Key)) yield return c.Key;
        }

        private async Task ConversationsCoreAsync(IEnumerable<string> keys, CancellationToken ct)
        {
            _p.Phase("conversations (C)");
            await Par.ForEachAsync(keys, Math.Max(1, _o.ConversationParallelism), (k, token) =>
            {
                Interlocked.Increment(ref _t.Conversations);
                if (k.StartsWith("chat:", StringComparison.Ordinal))
                    return RunUnitAsync("c:" + k, "chat messages", t => ExportChatAsync(k, t), token);
                if (k.StartsWith("channel:", StringComparison.Ordinal))
                    return RunUnitAsync("c:" + k, "channel messages", t => ExportChannelAsync(k, t), token);
                return Task.CompletedTask;
            }, ct, _o.Stop).ConfigureAwait(false);
        }

        private async Task<Outcome> ExportChatAsync(string key, CancellationToken ct)
        {
            Interlocked.Increment(ref _t.ViaC);
            string chatId = key.Substring(5);
            string wm = "wm:c:" + key, cp = "cm:" + key;
            var conv = _store.GetConversation(key);
            bool flagged = conv != null && conv.HasImportedContent == true;
            CoveredInterval newCov;
            var ranges = PlanFor(wm, flagged, out newCov);
            if (ranges.Count == 0) return Outcome.UpToDate;
            EnsureConversation(key, chatId, null, null, null);
            var sink = new Sink(this);
            foreach (var range in ranges)
            {
                string id = range.Id;
                string url = "v1.0/chats/" + ExportUtil.Seg(chatId) + "/messages?$top=" + Top + FilterQuery(range, true);
                try
                {
                    await foreach (var msg in _g.GetPagedAsync(url, EndpointClass.ChatMessages,
                        onNextLink: async nl => { await sink.FlushAsync(ct).ConfigureAwait(false); _store.SetCheckpoint(cp, id + "#" + nl); },
                        resumeFromNextLink: ResumeLink(cp, id), threadKey: key, cancellationToken: ct).ConfigureAwait(false))
                    {
                        if (InRange(range, msg)) await sink.AddAsync(key, msg, ct).ConfigureAwait(false);
                        if (Stopping) { await sink.FlushAsync(ct).ConfigureAwait(false); return Outcome.Stopped; }
                    }
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    try { await sink.FlushAsync(ct).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
                await sink.FlushAsync(ct).ConfigureAwait(false);
                _store.SetCheckpoint(cp, "");
            }
            if (_o.Incremental) _store.SetCheckpoint(wm, newCov.Serialize());
            return Outcome.Done;
        }

        // ------------------------------------------------------------------ channels

        private async Task TeamsCoreAsync(List<string> teams, CancellationToken ct)
        {
            if (teams == null && _o.Teams != null && _o.Teams.Count > 0)
            {
                if (_reader == null) teams = _o.Teams.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                else
                {
                    var want = _o.Teams;
                    teams = _reader.ListConversations(null, ConversationKind.Channel)
                        .Where(c => c.TeamId != null && want.Any(w => string.Equals(w, c.TeamId, StringComparison.OrdinalIgnoreCase) || (c.TeamDisplayName != null && string.Equals(w, c.TeamDisplayName, StringComparison.Ordinal))))
                        .Select(c => c.TeamId).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                }
            }
            if (teams == null)
            {
                if (_reader == null) throw new InvalidOperationException("Exporting the channels of every team needs an IStoreReader (run the inventory first) or explicit team ids.");
                teams = _reader.ListConversations(null, ConversationKind.Channel).Select(c => c.TeamId).Where(t => t != null).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            }
            _p.Phase("channels", teams.Count);
            await Par.ForEachAsync(teams, Math.Max(1, _o.TeamParallelism),
                (t, token) => RunUnitAsync("t:" + t, "channels", x => _o.ChannelMode == ChannelMode.PerChannel ? ExportTeamPerChannelAsync(t, x) : ExportTeamAsync(t, x), token),
                ct, _o.Stop).ConfigureAwait(false);
        }

        private IEnumerable<ConversationRecord> ChannelsOf(string teamId)
        {
            if (_reader == null) return new ConversationRecord[0];
            return _reader.ListConversations(null, ConversationKind.Channel, teamId);
        }

        private async Task<Outcome> ExportTeamAsync(string teamId, CancellationToken ct)
        {
            string wm = "wm:t:" + teamId, cp = "tgam:" + teamId;
            CoveredInterval newCov;
            var ranges = PlanFor(wm, false, out newCov);
            var flaggedChannels = ChannelsOf(teamId).Where(c => c.HasImportedContent == true).ToList();
            if (ranges.Count == 0 && flaggedChannels.Count == 0) return Outcome.UpToDate;
            long routed = 0;
            var sink = new Sink(this);
            bool fallback = false;
            foreach (var range in ranges)
            {
                string id = range.Id;
                string url = "v1.0/teams/" + ExportUtil.Seg(teamId) + "/channels/getAllMessages?$top=" + Top + FilterQuery(range, false);
                try
                {
                    await foreach (var msg in _g.GetPagedAsync(url, EndpointClass.ChannelGetAllMessages,
                        onNextLink: async nl => { await sink.FlushAsync(ct).ConfigureAwait(false); _store.SetCheckpoint(cp, id + "#" + nl); },
                        resumeFromNextLink: ResumeLink(cp, id), threadKey: teamId, cancellationToken: ct).ConfigureAwait(false))
                    {
                        string channelId = ExportUtil.Str(msg, "channelIdentity", "channelId");
                        string team = ExportUtil.Str(msg, "channelIdentity", "teamId") ?? teamId;
                        if (channelId == null) continue;
                        string key = ConversationKeys.ForChannel(team, channelId);
                        EnsureConversation(key, null, team, channelId, null);
                        await sink.AddAsync(key, msg, ct).ConfigureAwait(false);
                        routed++;
                        if (Stopping) { await sink.FlushAsync(ct).ConfigureAwait(false); return Outcome.Stopped; }
                    }
                }
                catch (GraphException ex) when (routed == 0 && (ex.StatusCode == 400 || ex.StatusCode == 403 || ex.StatusCode == 404 || ex.StatusCode == 405) && !ExportUtil.IsCancel(ex, ct))
                {
                    fallback = true;      // team stream refused: read the channels one by one
                    break;
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    try { await sink.FlushAsync(ct).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
                await sink.FlushAsync(ct).ConfigureAwait(false);
                _store.SetCheckpoint(cp, "");
            }
            if (fallback) return await ExportTeamPerChannelAsync(teamId, ct).ConfigureAwait(false);
            if (_o.Incremental && ranges.Count > 0) _store.SetCheckpoint(wm, newCov.Serialize());
            // the team stream does not see imported messages: read the flagged channels one by one. Once a flagged channel has been read in
            // full, later passes need only its delta, which the team stream already carries (native messages and edits): skip it then.
            // (Imported messages added to the source after the first pass need -Full.)
            var toRead = new List<string>();
            foreach (var ch in flaggedChannels)
            {
                CoveredInterval nc;
                var chRanges = PlanFor("wm:c:" + ch.Key, true, out nc);
                if (chRanges.Count > 0 && chRanges.Any(r => !r.Delta)) toRead.Add(ch.Key);
            }
            await ExportChannelsAsync(toRead, ct).ConfigureAwait(false);
            return Stopping ? Outcome.Stopped : Outcome.Done;
        }

        private async Task<Outcome> ExportTeamPerChannelAsync(string teamId, CancellationToken ct)
        {
            var channels = ChannelsOf(teamId).ToList();
            if (channels.Count == 0 && _reader == null)
            {
                // no reader: ask Graph
                await foreach (var ch in _g.GetPagedAsync("v1.0/teams/" + ExportUtil.Seg(teamId) + "/channels", EndpointClass.Channels, cancellationToken: ct).ConfigureAwait(false))
                {
                    var cid = ExportUtil.Str(ch, "id");
                    if (cid != null) channels.Add(new ConversationRecord { Key = ConversationKeys.ForChannel(teamId, cid), Kind = ConversationKind.Channel, TeamId = teamId, ChannelId = cid });
                }
            }
            await ExportChannelsAsync(channels.Select(c => c.Key).ToList(), ct).ConfigureAwait(false);
            return Stopping ? Outcome.Stopped : Outcome.Done;
        }

        /// <summary>Reads channels in parallel; each one is its own unit, so a failing channel does not fail the team.</summary>
        private Task ExportChannelsAsync(List<string> keys, CancellationToken ct)
        {
            return Par.ForEachAsync(keys, Math.Max(1, _o.ChannelParallelism), (k, token) =>
            {
                Interlocked.Increment(ref _t.Conversations);
                return RunUnitAsync("c:" + k, "channel messages", t => ExportChannelAsync(k, t), token);
            }, ct, _o.Stop);
        }

        /// <summary>One channel: root messages (filtered/ordered on lastModifiedDateTime), then the replies of every root read.</summary>
        private async Task<Outcome> ExportChannelAsync(string key, CancellationToken ct)
        {
            string rest = key.Substring("channel:".Length);
            int slash = rest.IndexOf('/');
            Interlocked.Increment(ref _t.ViaC);
            string teamId = rest.Substring(0, slash), channelId = rest.Substring(slash + 1);
            string wm = "wm:c:" + key, cp = "cm:" + key;
            var conv = _store.GetConversation(key);
            bool flagged = conv != null && conv.HasImportedContent == true;
            CoveredInterval newCov;
            var ranges = PlanFor(wm, flagged, out newCov);
            if (ranges.Count == 0) return Outcome.UpToDate;
            EnsureConversation(key, null, teamId, channelId, null);
            var sink = new Sink(this);
            string basePath = "v1.0/teams/" + ExportUtil.Seg(teamId) + "/channels/" + ExportUtil.Seg(channelId) + "/messages";
            foreach (var range in ranges)
            {
                string id = range.Id;
                // GET teams/{t}/channels/{c}/messages accepts $top and $expand only ("Query option 'OrderBy' is not allowed"; no $filter either):
                // the roots are read in full, newest first, and the window is applied on the client. The messages/delta endpoint would avoid
                // re-reading the roots, but it needs a deltaLink per channel and is not offered by the fake; the cost here is one call per 50 roots.
                string url = basePath + "?$top=" + Math.Min(50, Math.Max(1, _o.ChannelPageSize)) + (_o.ExpandReplies ? "&$expand=replies" : "");
                try
                {
                    await foreach (var root in _g.GetPagedAsync(url, EndpointClass.ChannelMessages,
                        onNextLink: async nl => { await sink.FlushAsync(ct).ConfigureAwait(false); _store.SetCheckpoint(cp, id + "#" + nl); },
                        resumeFromNextLink: ResumeLink(cp, id), threadKey: key, cancellationToken: ct).ConfigureAwait(false))
                    {
                        bool inRange = InWindow(range, root);
                        string rootId = ExportUtil.Str(root, "id");
                        if (inRange)
                        {
                            JsonElement expanded;
                            bool hasExpanded = _o.ExpandReplies && root.TryGetProperty("replies", out expanded) && expanded.ValueKind == JsonValueKind.Array && expanded.GetArrayLength() < 50;
                            if (hasExpanded)
                            {
                                // replies came with the listing: no call for this root (a root with 0 replies is the common case)
                                root.TryGetProperty("replies", out expanded);
                                await sink.AddAsync(key, StripReplies(root), ct).ConfigureAwait(false);
                                foreach (var rep in expanded.EnumerateArray()) await sink.AddAsync(key, rep.Clone(), ct).ConfigureAwait(false);
                            }
                            else
                            {
                                // no expansion honoured, or a full page of replies (possibly truncated): ask the replies endpoint
                                await sink.AddAsync(key, StripReplies(root), ct).ConfigureAwait(false);
                                if (rootId != null)
                                {
                                    string rurl = basePath + "/" + ExportUtil.Seg(rootId) + "/replies?$top=" + Top;
                                    await foreach (var rep in _g.GetPagedAsync(rurl, EndpointClass.ChannelReplies, threadKey: key, cancellationToken: ct).ConfigureAwait(false))
                                        await sink.AddAsync(key, rep, ct).ConfigureAwait(false);
                                }
                            }
                        }
                        if (Stopping) { await sink.FlushAsync(ct).ConfigureAwait(false); return Outcome.Stopped; }
                    }
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    try { await sink.FlushAsync(ct).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
                await sink.FlushAsync(ct).ConfigureAwait(false);
                _store.SetCheckpoint(cp, "");
            }
            if (_o.Incremental) _store.SetCheckpoint(wm, newCov.Serialize());
            return Outcome.Done;
        }
    }

    #endregion

    #region Files stage

    public sealed class FilesOptions
    {
        /// <summary>Files larger than this are recorded TooLarge and not downloaded (0 = no limit).</summary>
        public long MaxFileBytes { get; set; } = 0;
        public string[] ExcludedExtensions { get; set; } = new string[0];
        public int Parallelism { get; set; } = 4;
        public int BatchSize { get; set; } = 200;
        public int Attempts { get; set; } = 3;
        public int KeyCacheSize { get; set; } = 100000;
        public StopControl Stop { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    public sealed class FilesResult
    {
        public long Processed { get; set; }
        public long Downloaded { get; set; }
        /// <summary>Served from a file already downloaded (same drive item and ETag): no second download.</summary>
        public long Deduplicated { get; set; }
        public long NotFound { get; set; }
        public long Forbidden { get; set; }
        public long TooLarge { get; set; }
        public long Excluded { get; set; }
        public long Failed { get; set; }
        public long Bytes { get; set; }
        public bool Stopped { get; set; }
        public TimeSpan Duration { get; set; }
        public List<ErrorRecord> Errors { get; set; } = new List<ErrorRecord>();
    }

    /// <summary>
    /// Downloads the files recorded Pending by the exporter: /shares/u!{base64url(contentUrl)}/driveItem (id, driveId, eTag, size),
    /// then /drives/{d}/items/{i}/content streamed to the store. The same drive item (id + ETag) is downloaded once.
    /// </summary>
    public sealed class FilesStage
    {
        private readonly GraphClient _g;
        private readonly IExportStore _store;
        private readonly FilesOptions _o;
        private readonly BoundedCache<string> _shaByItem;
        private readonly Func<DateTimeOffset> _now;
        private readonly ConcurrentQueue<ErrorRecord> _errors = new ConcurrentQueue<ErrorRecord>();
        private long _processed, _downloaded, _dedup, _notFound, _forbidden, _tooLarge, _excluded, _failed, _bytes;
        private ProgressReporter _p;

        public FilesStage(GraphClient graph, IExportStore store, FilesOptions options = null)
        {
            _g = graph; _store = store; _o = options ?? new FilesOptions();
            _shaByItem = new BoundedCache<string>(_o.KeyCacheSize);
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _p = new ProgressReporter("Files", _o.OnProgress, _now);
        }

        public static bool IsExcluded(string nameOrUrl, string[] excluded)
        {
            if (excluded == null || excluded.Length == 0 || string.IsNullOrEmpty(nameOrUrl)) return false;
            string n = nameOrUrl;
            int q = n.IndexOfAny(new[] { '?', '#' });
            if (q >= 0) n = n.Substring(0, q);
            string ext = Path.GetExtension(n);
            if (string.IsNullOrEmpty(ext)) return false;
            foreach (var e in excluded)
            {
                if (string.IsNullOrWhiteSpace(e)) continue;
                string x = e.Trim().TrimStart('*');
                if (!x.StartsWith(".")) x = "." + x;
                if (string.Equals(ext, x, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        /// <summary>sharing token of a URL: u! + base64url(url) without padding.</summary>
        public static string ShareToken(string url)
        {
            return "u!" + Convert.ToBase64String(Encoding.UTF8.GetBytes(url)).TrimEnd('=').Replace('/', '_').Replace('+', '-');
        }

        public async Task<FilesResult> RunAsync(CancellationToken ct = default)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            _p = new ProgressReporter("Files", _o.OnProgress, _now);
            _p.Phase("files");
            var attempted = new HashSet<string>(StringComparer.Ordinal);   // Failed this run: not retried before the next run
            bool stopped = false;
            while (true)
            {
                if (StopControl.Stopped(_o.Stop)) { stopped = true; break; }
                var batch = _store.PendingFiles(_o.BatchSize + attempted.Count).Where(f => !attempted.Contains(Key(f))).Take(_o.BatchSize).ToList();
                if (batch.Count == 0) break;
                await Par.ForEachAsync(batch, Math.Max(1, _o.Parallelism), async (f, token) =>
                {
                    await ProcessAsync(f, token).ConfigureAwait(false);
                    Interlocked.Increment(ref _p.UnitsDone);
                    _p.Tick();
                }, ct, _o.Stop).ConfigureAwait(false);
                foreach (var f in batch) if (f.Status == FileStatus.Failed || f.Status == FileStatus.Pending) attempted.Add(Key(f));
            }
            var r = new FilesResult
            {
                Processed = _processed, Downloaded = _downloaded, Deduplicated = _dedup, NotFound = _notFound, Forbidden = _forbidden, TooLarge = _tooLarge,
                Excluded = _excluded, Failed = _failed, Bytes = _bytes, Stopped = stopped, Duration = sw.Elapsed, Errors = _errors.ToList()
            };
            _p.Finish();
            return r;
        }

        private static string Key(FileRecord f) { return f.ConversationKey + "|" + f.MessageId + "|" + f.AttachmentId; }

        private async Task ProcessAsync(FileRecord f, CancellationToken ct)
        {
            Interlocked.Increment(ref _processed);
            try
            {
                if (IsExcluded(f.Name ?? f.SourceUrl, _o.ExcludedExtensions))
                {
                    f.Status = FileStatus.Excluded; f.Error = "extension excluded"; Interlocked.Increment(ref _excluded);
                    _store.RecordFile(f);
                    return;
                }
                if (string.IsNullOrEmpty(f.SourceUrl)) { f.Status = FileStatus.NotFound; f.Error = "no contentUrl"; Interlocked.Increment(ref _notFound); _store.RecordFile(f); return; }

                // 1. resolve the sharing link to a drive item
                string share = ShareToken(f.SourceUrl);
                if (string.IsNullOrEmpty(f.DriveId) || string.IsNullOrEmpty(f.ItemId))
                {
                    using (var doc = await _g.GetJsonAsync("v1.0/shares/" + share + "/driveItem", EndpointClass.DriveItem, f.ConversationKey, ct).ConfigureAwait(false))
                    {
                        var root = doc.RootElement;
                        f.ItemId = ExportUtil.Str(root, "id");
                        f.DriveId = ExportUtil.Str(root, "parentReference", "driveId");
                        f.ETag = ExportUtil.Str(root, "eTag");
                        JsonElement sz;
                        if (root.TryGetProperty("size", out sz) && sz.ValueKind == JsonValueKind.Number) f.Size = sz.GetInt64();
                        if (string.IsNullOrEmpty(f.Name)) f.Name = ExportUtil.Str(root, "name");
                    }
                }
                if (IsExcluded(f.Name, _o.ExcludedExtensions))
                {
                    f.Status = FileStatus.Excluded; f.Error = "extension excluded"; Interlocked.Increment(ref _excluded); _store.RecordFile(f); return;
                }
                if (_o.MaxFileBytes > 0 && f.Size.HasValue && f.Size.Value > _o.MaxFileBytes)
                {
                    f.Status = FileStatus.TooLarge; f.Error = "larger than " + _o.MaxFileBytes + " bytes"; Interlocked.Increment(ref _tooLarge); _store.RecordFile(f); return;
                }

                // 2. already downloaded under another message? (same drive item and ETag)
                string itemKey = f.DriveId + "|" + f.ItemId + "|" + f.ETag;
                string sha;
                if (!string.IsNullOrEmpty(f.ItemId) && _shaByItem.TryGet(itemKey, out sha) && _store.HasContent(sha))
                {
                    f.Sha256 = sha; f.Status = FileStatus.Downloaded; f.Error = null; Interlocked.Increment(ref _dedup);
                    _store.RecordFile(f);
                    return;
                }

                // 3. stream the content
                string url = !string.IsNullOrEmpty(f.DriveId) && !string.IsNullOrEmpty(f.ItemId)
                    ? "v1.0/drives/" + ExportUtil.Seg(f.DriveId) + "/items/" + ExportUtil.Seg(f.ItemId) + "/content"
                    : "v1.0/shares/" + share + "/driveItem/content";
                Exception last = null;
                for (int attempt = 1; attempt <= Math.Max(1, _o.Attempts); attempt++)
                {
                    try
                    {
                        var req = new GraphRequest { Method = HttpMethod.Get, Url = url, EndpointClass = EndpointClass.DriveContent, ThreadKey = f.ConversationKey };
                        using (var resp = await _g.SendAsync(req, ct).ConfigureAwait(false))
                        {
                            ContentRef cr = await Exporter.PutVerifiedAsync(_store, resp, ct).ConfigureAwait(false);
                            f.Sha256 = cr.Sha256; f.Size = cr.Length; f.Status = FileStatus.Downloaded; f.Error = null;
                            if (!string.IsNullOrEmpty(f.ItemId)) _shaByItem.Set(itemKey, cr.Sha256);
                            Interlocked.Increment(ref _downloaded);
                            Interlocked.Add(ref _bytes, cr.Length);
                            Interlocked.Add(ref _p.Bytes, cr.Length);
                            Interlocked.Increment(ref _p.FilesDownloaded);
                            _store.RecordFile(f);
                        }
                        return;
                    }
                    catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 403 || ex.StatusCode == 401 || ex.StatusCode == 410) { throw; }
                    catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && (ex is GraphException || ex is IOException || ex is HttpRequestException || ex is TimeoutException)) { last = ex; }
                }
                throw last;
            }
            catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 410)
            {
                f.Status = FileStatus.NotFound; f.Error = ex.ErrorCode; Interlocked.Increment(ref _notFound); _store.RecordFile(f);
            }
            catch (GraphException ex) when (ex.StatusCode == 403 || ex.StatusCode == 401)
            {
                f.Status = FileStatus.Forbidden; f.Error = ex.ErrorCode; Interlocked.Increment(ref _forbidden); _store.RecordFile(f);
            }
            catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && (ex is GraphException || ex is IOException || ex is HttpRequestException || ex is TimeoutException))
            {
                f.Status = FileStatus.Failed; f.Error = ex.Message.Length > 300 ? ex.Message.Substring(0, 300) : ex.Message;
                Interlocked.Increment(ref _failed);
                Interlocked.Increment(ref _p.Errors);
                _errors.Enqueue(ErrorRecord.From(Key(f), "file", ex, _now()));
                _store.RecordFile(f);
            }
        }
    }

    #endregion
}

// =============================================================================
//  Assess mode: sample, measure, extrapolate (design section 5: "the first command run at the customer")
// -----------------------------------------------------------------------------
//  ESTIMATOR (documented because the numbers are quoted to a customer)
//    Sample n of N users (evenly spaced in id order: deterministic). For each sampled user every chat message of the window
//    is read through getAllMessages (strategy U). A chat with k in-tenant members is seen k times by a full population, and
//    k * n/N times by the sample, so each message seen by a sampled user stands for  (N/n) / k  distinct messages:
//        unique messages  = (N/n) * SUM over sampled views of 1/k       (k = members found in the directory, >= 1)
//        U reads          = (N/n) * SUM over sampled views of 1          (what strategy U will actually read)
//    Same weights for bytes, hosted contents, file references, months. Teams are sampled the same way with weight (T/m), no 1/k
//    (a channel message belongs to one team). Sizes of hosted contents and files are measured on a small sample of each.
//    Export duration = requests / requests-per-second, with requests = pages of messages (50 per call) + chat/channel listings
//    + 1 per hosted content + 2 per file (resolve + download); requests-per-second is MEASURED during the sampling (or given).
//    Import duration = unique messages / app rate (60, 75, 90 msg/s: phase 0); the longest sampled conversation gives a floor
//    (messages / 5 per second, a single conversation cannot go faster).
//    U versus C on a few chats: ids that C returns (created in the window, visible to the sampled members) and U does not are
//    messages imported by a previous migration: the conversation is flagged HasImportedContent (exported by C from then on).
// =============================================================================
namespace TeamsTransfer
{
    public sealed class AssessOptions
    {
        public int SampleUsers { get; set; } = 20;
        public int SampleTeams { get; set; } = 0;
        public int HistoryMonths { get; set; } = 60;
        public int Parallelism { get; set; } = 4;
        public int CompareChats { get; set; } = 6;
        public int HostedSample { get; set; } = 20;
        public int FileSample { get; set; } = 20;
        /// <summary>Override of the directory counts (when the full listing is too slow or not wanted).</summary>
        public long? TotalUsers { get; set; }
        public long? TotalTeams { get; set; }
        public double ImportRateLow { get; set; } = 60;
        public double ImportRateCentral { get; set; } = 75;
        public double ImportRateHigh { get; set; } = 90;
        public double ImportRatePerConversation { get; set; } = 5;
        /// <summary>Sustained export request rate to assume; null = the rate measured during the assessment.</summary>
        public double? ExportRequestsPerSecond { get; set; }
        public double CompressionRatio { get; set; } = 0.25;
        public long AssumedAverageFileBytes { get; set; } = 2L * 1024 * 1024;
        public long AssumedAverageHostedBytes { get; set; } = 150L * 1024;
        public int PageSize { get; set; } = 50;
        /// <summary>Write HasImportedContent on the conversations compared (needs the store to know them).</summary>
        public bool WriteFlags { get; set; } = true;
        public GraphMetrics Metrics { get; set; }
        public StopControl Stop { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    public sealed class AssessmentWave
    {
        public string Name { get; set; }
        public int FromMonths { get; set; }
        public int ToMonths { get; set; }
        public double Messages { get; set; }
        public double JsonBytes { get; set; }
        public double ImportDaysLow { get; set; }
        public double ImportDaysCentral { get; set; }
        public double ImportDaysHigh { get; set; }
        public double ExportRequests { get; set; }
        public double ExportDays { get; set; }
    }

    public sealed class ChatComparison
    {
        public string Conversation { get; set; }
        public int ViaU { get; set; }
        public int ViaC { get; set; }
        public int MissingFromU { get; set; }
        public int ModifiedMinValue { get; set; }
        public bool ImportedContent { get; set; }
    }

    public sealed class AssessmentReport
    {
        public DateTimeOffset GeneratedAt { get; set; }
        public DateTimeOffset WindowFrom { get; set; }
        public int HistoryMonths { get; set; }
        // directory and sample
        public long TotalUsers { get; set; }
        public long TotalTeams { get; set; }
        public int SampledUsers { get; set; }
        public int SampledTeams { get; set; }
        public double UserWeight { get; set; }
        public double TeamWeight { get; set; }
        public int SampleChats { get; set; }
        public long SampleMessageViews { get; set; }
        public long SampleChannelMessages { get; set; }
        public int SampleErrors { get; set; }
        // extrapolation to the whole tenant
        public double Chats { get; set; }
        public double ChatMessages { get; set; }
        public double ChatMessageReadsStrategyU { get; set; }
        public double ReadAmplificationU { get; set; }
        public double Channels { get; set; }
        public double ChannelMessages { get; set; }
        public double Messages { get; set; }
        public double JsonBytes { get; set; }
        public double CompressedBytes { get; set; }
        public double HostedContents { get; set; }
        public double HostedBytes { get; set; }
        public double FileReferences { get; set; }
        public double FileBytes { get; set; }
        public double AverageFileBytes { get; set; }
        public double AverageHostedBytes { get; set; }
        public double AverageMessageBytes { get; set; }
        public long LargestSampledConversationMessages { get; set; }
        public SortedDictionary<string, double> MessagesByMonth { get; set; } = new SortedDictionary<string, double>(StringComparer.Ordinal);
        public List<AssessmentWave> Waves { get; set; } = new List<AssessmentWave>();
        // U versus C
        public List<ChatComparison> Comparisons { get; set; } = new List<ChatComparison>();
        public int ChatsCompared { get; set; }
        public int ChatsWithImportedContent { get; set; }
        public bool ImportedContentDetected { get; set; }
        // measured throughput
        public long MeasuredRequests { get; set; }
        public double MeasuredSeconds { get; set; }
        public double MeasuredRequestsPerSecond { get; set; }
        public long Measured429 { get; set; }
        public long MeasuredRetries { get; set; }
        // durations
        public double AssumedExportRequestsPerSecond { get; set; }
        public double ExportRequests { get; set; }
        public double ExportDays { get; set; }
        /// <summary>Fastest import (90 msg/s).</summary>
        public double ImportDaysLow { get; set; }
        public double ImportDaysCentral { get; set; }
        /// <summary>Slowest import (60 msg/s).</summary>
        public double ImportDaysHigh { get; set; }
        public double ImportDaysFloorLongestConversation { get; set; }
        public List<string> Notes { get; set; } = new List<string>();

        public string ToJson()
        {
            return JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        }

        public string ToText()
        {
            var sb = new StringBuilder();
            var inv = CultureInfo.InvariantCulture;
            Func<double, string> n = v => v >= 1e9 ? (v / 1e9).ToString("0.##", inv) + " G" : v >= 1e6 ? (v / 1e6).ToString("0.##", inv) + " M" : v >= 1e3 ? (v / 1e3).ToString("0.#", inv) + " k" : v.ToString("0", inv);
            Func<double, string> gb = v => (v / (1024.0 * 1024 * 1024)).ToString("0.##", inv) + " GiB";
            sb.AppendLine("Assessment " + GeneratedAt.ToString("u", inv) + ", window " + HistoryMonths + " months");
            sb.AppendLine("Sample: " + SampledUsers + " of " + TotalUsers + " users, " + SampledTeams + " of " + TotalTeams + " teams");
            sb.AppendLine("Chats ~" + n(Chats) + ", channels ~" + n(Channels) + ", unique messages ~" + n(Messages) + " (strategy U would read ~" + n(ChatMessageReadsStrategyU) + " chat messages)");
            sb.AppendLine("JSON ~" + gb(JsonBytes) + " (" + gb(CompressedBytes) + " compressed), hosted contents ~" + n(HostedContents) + " (" + gb(HostedBytes) + "), file references ~" + n(FileReferences) + " (" + gb(FileBytes) + ")");
            sb.AppendLine("Export: ~" + ExportDays.ToString("0.##", inv) + " days at " + AssumedExportRequestsPerSecond.ToString("0.#", inv) + " req/s");
            sb.AppendLine("Import: ~" + ImportDaysCentral.ToString("0.##", inv) + " days (" + ImportDaysLow.ToString("0.##", inv) + " to " + ImportDaysHigh.ToString("0.##", inv) + ")");
            foreach (var w in Waves) sb.AppendLine("  " + w.Name + ": ~" + n(w.Messages) + " messages, import ~" + w.ImportDaysCentral.ToString("0.##", inv) + " days");
            if (ImportedContentDetected) sb.AppendLine("Previously imported content detected in " + ChatsWithImportedContent + " of " + ChatsCompared + " conversations compared: export those by strategy C.");
            foreach (var note in Notes) sb.AppendLine("Note: " + note);
            return sb.ToString();
        }
    }

    public sealed class Assessor
    {
        private readonly GraphClient _g;
        private readonly AssessOptions _o;
        private readonly IExportStore _store;
        private readonly Func<DateTimeOffset> _now;
        private readonly ProgressReporter _p;
        private static readonly int[] WaveBounds = { 24, 36, 48, 60 };
        private static readonly Regex HostedRx = new Regex(@"hostedContents/([^/""'\s<>]+)/\$value", RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private sealed class ChatInfo
        {
            public string Key, Id, MembersJson, UserId;
            public int InTenant, MemberCount;
        }

        private sealed class Acc
        {
            public readonly object Gate = new object();
            public long Views, Pages, Errors;
            public double Uniq, UniqBytes, ViewBytes, Hosted, Files;
            public readonly SortedDictionary<string, double> Months = new SortedDictionary<string, double>(StringComparer.Ordinal);
            public double[] WaveMsgs, WaveBytes, WavePages;
            public readonly Dictionary<string, int> ConvViews = new Dictionary<string, int>(StringComparer.Ordinal);
            public readonly List<Tuple<string, JsonElement, string>> HostedRefs = new List<Tuple<string, JsonElement, string>>();   // conversation key, message, hosted id
            public readonly List<string> FileUrls = new List<string>();
            public Acc(int waves) { WaveMsgs = new double[waves]; WaveBytes = new double[waves]; WavePages = new double[waves]; }
        }

        public Assessor(GraphClient graph, AssessOptions options = null, IExportStore store = null)
        {
            _g = graph; _o = options ?? new AssessOptions(); _store = store;
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _p = new ProgressReporter("Assess", _o.OnProgress, _now);
        }

        public ProgressSnapshot Progress => _p.Snapshot();

        private static int WaveOf(double ageMonths)
        {
            for (int i = 0; i < WaveBounds.Length; i++) if (ageMonths < WaveBounds[i]) return i;
            return WaveBounds.Length;
        }

        private static List<T> EvenlySpaced<T>(IList<T> sorted, int n)
        {
            var r = new List<T>();
            if (n <= 0 || sorted.Count == 0) return r;
            if (n >= sorted.Count) { r.AddRange(sorted); return r; }
            for (int i = 0; i < n; i++) r.Add(sorted[(int)Math.Floor((i + 0.5) * sorted.Count / n)]);
            return r;
        }

        public async Task<AssessmentReport> RunAsync(CancellationToken ct = default)
        {
            var metrics = _o.Metrics ?? GraphMetrics.Of(_g);
            var m0 = metrics != null ? metrics.Snapshot() : null;
            var report = new AssessmentReport { GeneratedAt = _now(), HistoryMonths = _o.HistoryMonths };
            DateTimeOffset now = report.GeneratedAt;
            DateTimeOffset from = now.AddMonths(-Math.Max(1, _o.HistoryMonths));
            report.WindowFrom = from;
            var errors = new ConcurrentQueue<string>();
            int waves = WaveBounds.Length + 1;

            // 1. directory
            _p.Phase("directory");
            var users = new List<string>();
            var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!_o.TotalUsers.HasValue || _o.SampleUsers > 0)
            {
                await foreach (var u in _g.GetPagedAsync("v1.0/users?$select=id&$top=999", EndpointClass.Users, cancellationToken: ct).ConfigureAwait(false))
                { var id = ExportUtil.Str(u, "id"); if (id != null) { users.Add(id); known.Add(id); } }
            }
            long totalUsers = _o.TotalUsers ?? users.Count;
            var teams = new List<string>();
            if (!_o.TotalTeams.HasValue || _o.SampleTeams > 0)
            {
                // GET /teams needs only Team.ReadBasic.All (/groups needs Group.Read.All: real 403 on the lab, 2026-11-10).
                await foreach (var t in _g.GetPagedAsync("v1.0/teams?$select=id",
                    EndpointClass.Teams, cancellationToken: ct).ConfigureAwait(false))
                { var id = ExportUtil.Str(t, "id"); if (id != null) teams.Add(id); }
            }
            long totalTeams = _o.TotalTeams ?? teams.Count;
            report.TotalUsers = totalUsers; report.TotalTeams = totalTeams;

            users.Sort(StringComparer.Ordinal); teams.Sort(StringComparer.Ordinal);
            var sampleUsers = EvenlySpaced(users, _o.SampleUsers);
            var sampleTeams = EvenlySpaced(teams, _o.SampleTeams);
            report.SampledUsers = sampleUsers.Count; report.SampledTeams = sampleTeams.Count;
            double wu = sampleUsers.Count > 0 ? (double)totalUsers / sampleUsers.Count : 0;
            double wt = sampleTeams.Count > 0 ? (double)totalTeams / sampleTeams.Count : 0;
            report.UserWeight = wu; report.TeamWeight = wt;
            var sampleSet = new HashSet<string>(sampleUsers, StringComparer.OrdinalIgnoreCase);
            var acc = new Acc(waves);
            var chanAcc = new Acc(waves);

            // 2. chats of the sampled users
            _p.Phase("chats", sampleUsers.Count);
            var chatsByUser = new ConcurrentDictionary<string, List<ChatInfo>>(StringComparer.OrdinalIgnoreCase);
            await Par.ForEachAsync(sampleUsers, Math.Max(1, _o.Parallelism), async (uid, token) =>
            {
                var list = new List<ChatInfo>();
                try
                {
                    await foreach (var chat in _g.GetPagedAsync("v1.0/users/" + ExportUtil.Seg(uid) + "/chats?$expand=members&$top=50", EndpointClass.UserChats, threadKey: uid, cancellationToken: token).ConfigureAwait(false))
                    {
                        var ci = new ChatInfo { Id = ExportUtil.Str(chat, "id"), UserId = uid };
                        if (ci.Id == null) continue;
                        ci.Key = ConversationKeys.ForChat(ci.Id);
                        JsonElement mem;
                        int inTenant = 0, count = 0;
                        if (chat.TryGetProperty("members", out mem) && mem.ValueKind == JsonValueKind.Array)
                        {
                            ci.MembersJson = mem.GetRawText();
                            foreach (var mm in mem.EnumerateArray()) { count++; var mu = ExportUtil.Str(mm, "userId"); if (mu != null && known.Contains(mu)) inTenant++; }
                        }
                        ci.MemberCount = count; ci.InTenant = known.Count > 0 ? Math.Max(1, inTenant) : Math.Max(1, count);
                        list.Add(ci);
                    }
                }
                catch (GraphException ex) when (!ExportUtil.IsCancel(ex, token)) { errors.Enqueue("chats " + uid + ": " + ex.Message); }
                chatsByUser[uid] = list;
                Interlocked.Increment(ref _p.UnitsDone);
            }, ct, _o.Stop).ConfigureAwait(false);

            // 3. pick the chats compared by U and C (deterministic)
            var allChats = chatsByUser.Values.SelectMany(x => x).GroupBy(c => c.Key).Select(g => g.First()).OrderBy(c => c.Key, StringComparer.Ordinal).ToList();
            var targets = EvenlySpaced(allChats, _o.CompareChats).ToDictionary(c => c.Key, c => c, StringComparer.Ordinal);
            var uIds = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            foreach (var k in targets.Keys) uIds[k] = new HashSet<string>(StringComparer.Ordinal);

            // 4. messages of the sampled users (strategy U) over the window
            _p.Phase("messages (U)", sampleUsers.Count);
            string filter = "&$filter=" + Uri.EscapeDataString("lastModifiedDateTime gt " + ExportUtil.Iso(from.AddMilliseconds(-1)) + " and lastModifiedDateTime lt " + ExportUtil.Iso(now.AddMinutes(5)));
            await Par.ForEachAsync(sampleUsers, Math.Max(1, _o.Parallelism), async (uid, token) =>
            {
                List<ChatInfo> mine;
                chatsByUser.TryGetValue(uid, out mine);
                var byKey = (mine ?? new List<ChatInfo>()).GroupBy(c => c.Key).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
                var local = new Acc(waves);
                long userMsgs = 0;
                try
                {
                    await foreach (var msg in _g.GetPagedAsync("v1.0/users/" + ExportUtil.Seg(uid) + "/chats/getAllMessages?$top=" + Math.Min(50, _o.PageSize) + filter,
                        EndpointClass.ChatGetAllMessages, threadKey: uid, cancellationToken: token).ConfigureAwait(false))
                    {
                        string chatId = ExportUtil.Str(msg, "chatId");
                        if (chatId == null) continue;
                        string key = ConversationKeys.ForChat(chatId);
                        ChatInfo ci;
                        int k = byKey.TryGetValue(key, out ci) ? ci.InTenant : 1;
                        Tally(local, key, key, msg, 1.0 / k, now);
                        userMsgs++;
                        HashSet<string> set;
                        if (uIds.TryGetValue(key, out set))
                        {
                            var mid = ExportUtil.Str(msg, "id");
                            lock (set) set.Add(mid);
                        }
                    }
                }
                catch (GraphException ex) when (!ExportUtil.IsCancel(ex, token))
                {
                    errors.Enqueue("messages " + uid + ": " + ex.Message);
                    local.Errors++;
                }
                long chatCount = mine == null ? 0 : mine.Count;
                local.Pages += (userMsgs + _o.PageSize - 1) / Math.Max(1, _o.PageSize) + (chatCount + 49) / 50 + 1;
                Merge(acc, local);
                Interlocked.Increment(ref _p.UnitsDone);
                _p.Tick();
            }, ct, _o.Stop).ConfigureAwait(false);

            // 5. U versus C on the compared chats
            _p.Phase("U versus C", targets.Count);
            foreach (var kv in targets)
            {
                if (StopControl.Stopped(_o.Stop)) break;
                var ci = kv.Value;
                var cmp = new ChatComparison { Conversation = kv.Key };
                try
                {
                    DateTimeOffset minVisible = DateTimeOffset.MaxValue;
                    bool anyVisible = false;
                    if (ci.MembersJson != null)
                        using (var doc = JsonDocument.Parse(ci.MembersJson))
                            foreach (var mm in doc.RootElement.EnumerateArray())
                            {
                                var mu = ExportUtil.Str(mm, "userId");
                                if (mu == null || !sampleSet.Contains(mu)) continue;
                                var vs = ExportUtil.Date(mm, "visibleHistoryStartDateTime");   // null = 0001-01-01 = all history
                                anyVisible = true;
                                if (!vs.HasValue) { minVisible = DateTimeOffset.MinValue; break; }
                                if (vs.Value < minVisible) minVisible = vs.Value;
                            }
                    DateTimeOffset lower = from;
                    if (anyVisible && minVisible != DateTimeOffset.MaxValue && minVisible > lower) lower = minVisible;
                    var cIds = new HashSet<string>(StringComparer.Ordinal);
                    int minValue = 0;
                    string curl = "v1.0/chats/" + ExportUtil.Seg(ci.Id) + "/messages?$top=50";   // read in full: Graph rejects a $filter on createdDateTime
                    await foreach (var msg in _g.GetPagedAsync(curl, EndpointClass.ChatMessages, threadKey: kv.Key, cancellationToken: ct).ConfigureAwait(false))
                    {
                        var cdt = ExportUtil.Date(msg, "createdDateTime");
                        if (cdt.HasValue && cdt.Value < lower) continue;
                        cIds.Add(ExportUtil.Str(msg, "id"));
                        var lm = ExportUtil.Str(msg, "lastModifiedDateTime");
                        if (lm != null && lm.StartsWith("0001-01-01", StringComparison.Ordinal)) minValue++;
                    }
                    var uSet = uIds[kv.Key];
                    int missing = 0, both = 0;
                    foreach (var id in cIds) { if (uSet.Contains(id)) both++; else missing++; }
                    cmp.ViaC = cIds.Count; cmp.ViaU = both; cmp.MissingFromU = missing; cmp.ModifiedMinValue = minValue;
                    cmp.ImportedContent = missing > 0;
                    if (_o.WriteFlags && _store != null)
                    {
                        var conv = _store.GetConversation(kv.Key);
                        // a flag never goes from true back to false (the inventory read migrationMode, the comparison is a second signal)
                        if (conv != null && (cmp.ImportedContent || conv.HasImportedContent == null)) { conv.HasImportedContent = conv.HasImportedContent == true || cmp.ImportedContent; _store.UpsertConversations(new[] { conv }); }
                    }
                }
                catch (GraphException ex) when (!ExportUtil.IsCancel(ex, ct)) { errors.Enqueue("compare " + kv.Key + ": " + ex.Message); continue; }
                report.Comparisons.Add(cmp);
                Interlocked.Increment(ref _p.UnitsDone);
            }

            // 6. teams (channels)
            _p.Phase("teams", sampleTeams.Count);
            long channelCount = 0;
            await Par.ForEachAsync(sampleTeams, Math.Max(1, Math.Min(_o.Parallelism, 2)), async (tid, token) =>
            {
                var local = new Acc(waves);
                long msgs = 0;
                try
                {
                    int chans = 0;
                    await foreach (var ch in _g.GetPagedAsync("v1.0/teams/" + ExportUtil.Seg(tid) + "/channels", EndpointClass.Channels, threadKey: tid, cancellationToken: token).ConfigureAwait(false)) chans++;
                    Interlocked.Add(ref channelCount, chans);
                    await foreach (var msg in _g.GetPagedAsync("v1.0/teams/" + ExportUtil.Seg(tid) + "/channels/getAllMessages?$top=" + Math.Min(50, _o.PageSize) + filter,
                        EndpointClass.ChannelGetAllMessages, threadKey: tid, cancellationToken: token).ConfigureAwait(false))
                    {
                        string cid = ExportUtil.Str(msg, "channelIdentity", "channelId") ?? "?";
                        string key = ConversationKeys.ForChannel(tid, cid);
                        Tally(local, key, key, msg, 1.0, now);
                        msgs++;
                    }
                    local.Pages += (msgs + _o.PageSize - 1) / Math.Max(1, _o.PageSize) + chans + 2;
                }
                catch (GraphException ex) when (!ExportUtil.IsCancel(ex, token)) { errors.Enqueue("team " + tid + ": " + ex.Message); }
                Merge(chanAcc, local);
                Interlocked.Increment(ref _p.UnitsDone);
            }, ct, _o.Stop).ConfigureAwait(false);

            // 7. sizes of hosted contents and files
            _p.Phase("sizes");
            double avgHosted = _o.AssumedAverageHostedBytes, avgFile = _o.AssumedAverageFileBytes;
            var hostedSample = acc.HostedRefs.Concat(chanAcc.HostedRefs).Take(_o.HostedSample).ToList();
            if (hostedSample.Count > 0)
            {
                long bytes = 0; int ok = 0;
                foreach (var h in hostedSample)
                {
                    try
                    {
                        var req = new GraphRequest { Method = HttpMethod.Get, Url = Exporter.HostedUrl(h.Item1, h.Item2, ExportUtil.Str(h.Item2, "id"), h.Item3), EndpointClass = EndpointClass.HostedContent };
                        using (var resp = await _g.SendAsync(req, ct).ConfigureAwait(false))
                        {
                            var cs = new Exporter.CountingReadStream(resp.Content);
                            await cs.CopyToAsync(Stream.Null, 81920, ct).ConfigureAwait(false);
                            bytes += cs.Count; ok++;
                        }
                    }
                    catch (GraphException ex) when (!ExportUtil.IsCancel(ex, ct)) { }
                }
                if (ok > 0) avgHosted = (double)bytes / ok; else report.Notes.Add("No hosted content could be measured: average size assumed (" + _o.AssumedAverageHostedBytes + " bytes).");
            }
            else if (acc.Hosted + chanAcc.Hosted > 0) report.Notes.Add("Hosted contents are referenced but none was sampled: average size assumed.");
            var fileSample = acc.FileUrls.Concat(chanAcc.FileUrls).Take(_o.FileSample).ToList();
            if (fileSample.Count > 0)
            {
                long bytes = 0; int ok = 0;
                foreach (var url in fileSample)
                {
                    try
                    {
                        using (var doc = await _g.GetJsonAsync("v1.0/shares/" + FilesStage.ShareToken(url) + "/driveItem", EndpointClass.DriveItem, null, ct).ConfigureAwait(false))
                        {
                            JsonElement sz;
                            if (doc.RootElement.TryGetProperty("size", out sz) && sz.ValueKind == JsonValueKind.Number) { bytes += sz.GetInt64(); ok++; }
                        }
                    }
                    catch (GraphException ex) when (!ExportUtil.IsCancel(ex, ct)) { }
                }
                if (ok > 0) avgFile = (double)bytes / ok; else report.Notes.Add("No file could be resolved: average size assumed (" + _o.AssumedAverageFileBytes + " bytes).");
            }
            else if (acc.Files + chanAcc.Files > 0) report.Notes.Add("File references found but none sampled: average size assumed.");

            // 8. extrapolation
            report.SampleErrors = errors.Count;
            foreach (var e in errors.Take(20)) report.Notes.Add("sample error: " + e);
            report.SampleChats = allChats.Count;
            report.SampleMessageViews = acc.Views;
            report.SampleChannelMessages = chanAcc.Views;
            double chatUniq = acc.Uniq * wu, chatViews = acc.Views * wu;
            double chanMsgs = chanAcc.Views * wt;
            double chatCountEst = 0;
            foreach (var l in chatsByUser.Values) foreach (var c in l) chatCountEst += 1.0 / c.InTenant;
            report.Chats = chatCountEst * wu;
            report.ChatMessages = chatUniq;
            report.ChatMessageReadsStrategyU = chatViews;
            report.ReadAmplificationU = chatUniq > 0 ? chatViews / chatUniq : 1;
            report.Channels = channelCount * wt;
            report.ChannelMessages = chanMsgs;
            report.Messages = chatUniq + chanMsgs;
            report.JsonBytes = acc.UniqBytes * wu + chanAcc.ViewBytes * wt;
            report.CompressedBytes = report.JsonBytes * _o.CompressionRatio;
            report.AverageMessageBytes = report.Messages > 0 ? report.JsonBytes / report.Messages : 0;
            report.HostedContents = acc.Hosted * wu + chanAcc.Hosted * wt;
            report.AverageHostedBytes = avgHosted;
            report.HostedBytes = report.HostedContents * avgHosted;
            report.FileReferences = acc.Files * wu + chanAcc.Files * wt;
            report.AverageFileBytes = avgFile;
            report.FileBytes = report.FileReferences * avgFile;
            long longest = 0;
            foreach (var v in acc.ConvViews.Values) if (v > longest) longest = v;
            foreach (var v in chanAcc.ConvViews.Values) if (v > longest) longest = v;
            report.LargestSampledConversationMessages = longest;
            foreach (var kv in acc.Months) report.MessagesByMonth[kv.Key] = kv.Value * wu;
            foreach (var kv in chanAcc.Months) { double v; report.MessagesByMonth.TryGetValue(kv.Key, out v); report.MessagesByMonth[kv.Key] = v + kv.Value * wt; }

            report.ChatsCompared = report.Comparisons.Count;
            report.ChatsWithImportedContent = report.Comparisons.Count(c => c.ImportedContent);
            report.ImportedContentDetected = report.ChatsWithImportedContent > 0;
            if (report.ImportedContentDetected)
                report.Notes.Add("Messages imported by a previous migration are invisible to getAllMessages (phase 0): the flagged conversations are exported by strategy C, which is slower (about 1 request/s per chat).");

            // measured throughput
            if (metrics != null && m0 != null)
            {
                var d = GraphMetricsSnapshot.Delta(metrics.Snapshot(), m0);
                report.MeasuredRequests = d.Requests; report.MeasuredSeconds = d.Elapsed.TotalSeconds;
                report.MeasuredRequestsPerSecond = d.RequestsPerSecond; report.Measured429 = d.Throttled429; report.MeasuredRetries = d.Retries;
            }
            else report.Notes.Add("No GraphMetrics attached to the Graph client: throughput not measured, pass AssessOptions.ExportRequestsPerSecond.");
            double rps = _o.ExportRequestsPerSecond ?? (report.MeasuredRequestsPerSecond > 0 ? report.MeasuredRequestsPerSecond : 10);
            report.AssumedExportRequestsPerSecond = rps;

            double pagesU = acc.Pages * wu, pagesT = chanAcc.Pages * wt;
            report.ExportRequests = pagesU + pagesT + report.HostedContents + 2 * report.FileReferences;
            report.ExportDays = rps > 0 ? report.ExportRequests / rps / 86400.0 : 0;
            report.ImportDaysLow = report.Messages / _o.ImportRateHigh / 86400.0;
            report.ImportDaysCentral = report.Messages / _o.ImportRateCentral / 86400.0;
            report.ImportDaysHigh = report.Messages / _o.ImportRateLow / 86400.0;
            report.ImportDaysFloorLongestConversation = longest / Math.Max(0.1, _o.ImportRatePerConversation) / 86400.0;

            // waves: 0-24, 25-36, 37-48, 49-60 months (+ older when the history is longer)
            int[] waveLower = { 0, 24, 36, 48, 60 };
            for (int i = 0; i < waves; i++)
            {
                if (waveLower[i] >= _o.HistoryMonths) break;
                int upper = i < WaveBounds.Length ? Math.Min(WaveBounds[i], _o.HistoryMonths) : _o.HistoryMonths;
                double msgs = acc.WaveMsgs[i] * wu + chanAcc.WaveMsgs[i] * wt;
                double bytes = acc.WaveBytes[i] * wu + chanAcc.WaveBytes[i] * wt;
                double pages = acc.WavePages[i] * wu + chanAcc.WavePages[i] * wt;
                report.Waves.Add(new AssessmentWave
                {
                    Name = i == 0 ? "wave 1 (0-24 months)" : "wave " + (i + 1) + " (" + (waveLower[i] + 1) + "-" + upper + " months)",
                    FromMonths = waveLower[i], ToMonths = upper, Messages = msgs, JsonBytes = bytes,
                    ImportDaysLow = msgs / _o.ImportRateHigh / 86400.0, ImportDaysCentral = msgs / _o.ImportRateCentral / 86400.0, ImportDaysHigh = msgs / _o.ImportRateLow / 86400.0,
                    ExportRequests = pages, ExportDays = rps > 0 ? pages / rps / 86400.0 : 0
                });
            }
            if (report.SampledUsers == 0) report.Notes.Add("No user sampled: chat figures are zero.");
            if (report.SampledTeams == 0 && report.TotalTeams > 0) report.Notes.Add("No team sampled (SampleTeams = 0): channel messages are NOT included in the totals.");
            _p.Finish();
            return report;
        }

        /// <summary>Adds one message (weight = share of a distinct message it represents) to a local accumulator.</summary>
        private void Tally(Acc a, string convKey, string urlKey, JsonElement msg, double weight, DateTimeOffset now)
        {
            a.Views++;
            int cv; a.ConvViews.TryGetValue(convKey, out cv); a.ConvViews[convKey] = cv + 1;
            int size = Encoding.UTF8.GetByteCount(msg.GetRawText());
            a.Uniq += weight; a.UniqBytes += size * weight; a.ViewBytes += size;
            var created = ExportUtil.Date(msg, "createdDateTime");
            int wave = 0;
            if (created.HasValue)
            {
                string month = created.Value.ToString("yyyy-MM", CultureInfo.InvariantCulture);
                double m; a.Months.TryGetValue(month, out m); a.Months[month] = m + weight;
                wave = WaveOf(Math.Max(0, (now - created.Value).TotalDays / 30.4375));
            }
            a.WaveMsgs[wave] += weight; a.WaveBytes[wave] += size * weight; a.WavePages[wave] += 1.0 / Math.Max(1, _o.PageSize);
            JsonElement body, content, atts;
            if (msg.TryGetProperty("body", out body) && body.ValueKind == JsonValueKind.Object && body.TryGetProperty("content", out content) && content.ValueKind == JsonValueKind.String)
            {
                var html = content.GetString();
                if (html != null && html.IndexOf("hostedContents", StringComparison.Ordinal) >= 0)
                {
                    var ms = HostedRx.Matches(html);
                    a.Hosted += ms.Count * weight;
                    if (ms.Count > 0 && a.HostedRefs.Count < 50) a.HostedRefs.Add(Tuple.Create(urlKey, msg, ms[0].Groups[1].Value));
                }
            }
            if (msg.TryGetProperty("attachments", out atts) && atts.ValueKind == JsonValueKind.Array)
                foreach (var at in atts.EnumerateArray())
                    if (string.Equals(ExportUtil.Str(at, "contentType"), "reference", StringComparison.OrdinalIgnoreCase))
                    {
                        a.Files += weight;
                        var url = ExportUtil.Str(at, "contentUrl");
                        if (url != null && a.FileUrls.Count < 50) a.FileUrls.Add(url);
                    }
        }

        private static void Merge(Acc total, Acc l)
        {
            lock (total.Gate)
            {
                total.Views += l.Views; total.Pages += l.Pages; total.Errors += l.Errors;
                total.Uniq += l.Uniq; total.UniqBytes += l.UniqBytes; total.ViewBytes += l.ViewBytes; total.Hosted += l.Hosted; total.Files += l.Files;
                foreach (var kv in l.Months) { double v; total.Months.TryGetValue(kv.Key, out v); total.Months[kv.Key] = v + kv.Value; }
                for (int i = 0; i < total.WaveMsgs.Length; i++) { total.WaveMsgs[i] += l.WaveMsgs[i]; total.WaveBytes[i] += l.WaveBytes[i]; total.WavePages[i] += l.WavePages[i]; }
                foreach (var kv in l.ConvViews) { int v; total.ConvViews.TryGetValue(kv.Key, out v); if (kv.Value > v) total.ConvViews[kv.Key] = kv.Value; }
                total.HostedRefs.AddRange(l.HostedRefs.Take(Math.Max(0, 50 - total.HostedRefs.Count)));
                total.FileUrls.AddRange(l.FileUrls.Take(Math.Max(0, 50 - total.FileUrls.Count)));
            }
        }
    }
}
