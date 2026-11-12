// =============================================================================
//  TeamsTransfer - engine: the Importer
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.2
//
//  What it does: re-injects the exported Teams messages of a lot into the TARGET tenant with the Microsoft Graph Teams
//  migration API (startMigration, POST messages with createdDateTime + from, completeMigration), conversation by conversation.
//  Scale: 1 to 3 billion messages over months, so every step is resumable, idempotent and paced by the service limits.
//
//  Request flow of one (conversation, slice) item
//    1  seed the journal       SeedJournal(conversation, slice, ids of the slice in order)        local, idempotent
//    2  ensure the target      ExistingChat / NewChat (POST /chats) / ExistingChannel / NewChannel / ArchiveChannel
//                              (POST /teams with ONE member when the team is missing, then POST /teams/{t}/channels, then members);
//                              the ids are written back with ITargetMap.Upsert(State = Created)
//    3  open the session       BeginImportSession (the owner appId) BEFORE startMigration, so a crash in between leaves a trace;
//                              conversationCreationDateTime = min(oldest message of the slice, current target createdDateTime) - 1 s
//    4  startMigration         skipped when the thread already reads inProgress; a 400 is checked against the thread state
//    5  poll GET               until migrationMode = inProgress (eventually consistent: bounded, increasing delay)
//    6  import                 NextPending batches in journal order; one POST per message (replies via .../replies after their root);
//                              each outcome is journaled at once: Imported (target id), Conflict409TreatedAsImported, Rejected
//                              (400/403 + code), Skipped (system events, deleted messages)
//    7  completeMigration      retried with an increasing delay on 400 "not in migration mode" (eventual consistency), then GET
//                              until migrationMode = completed, CompleteImportSession, item -> Completing (the Verify stage checks it)
//
//  Idempotency and resume (kill -9 safe)
//    The journal (catalog.db) says what was done. A POST in flight at the kill is not journaled; on the next run the same
//    message is sent again with the SAME createdDateTime and the service answers 409 Conflict, which is journaled as
//    Conflict409TreatedAsImported. The createdDateTime of a message is a pure function of the slice order (see DateScope): a
//    resumed run recomputes exactly the same values, including the +1 ms shifts. A session left Started (same appId) is reused.
//    The GraphClient retries a POST after a timeout, which may duplicate: the same 409 is the guard.
//
//  Dry run (ImportRunOptions.Apply = false): NO request is sent and nothing is written (not even the journal): the same
//  builders produce the exact requests, counted per endpoint, with the first N payloads redacted (DryRunReport).
//
//  Limits honoured: 5 requests/s per conversation (ThreadKey = target conversation id, class migration.importMessage),
//  parallelism across conversations (ConversationParallelism), ~60-90 msg/s per application (the limiter's class rate).
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    #region Options and results

    /// <summary>Waiting and batching knobs of the importer. The defaults are the production values; tests shrink the delays.</summary>
    public sealed class ImportTuning
    {
        /// <summary>GET polls waiting for migrationMode = inProgress after startMigration.</summary>
        public int PollMaxAttempts { get; set; } = 30;
        public TimeSpan PollBaseDelay { get; set; } = TimeSpan.FromSeconds(1);
        public TimeSpan PollMaxDelay { get; set; } = TimeSpan.FromSeconds(20);
        /// <summary>completeMigration attempts on "not in migration mode" (eventual consistency can last minutes).</summary>
        public int CompleteMaxAttempts { get; set; } = 30;
        public TimeSpan CompleteBaseDelay { get; set; } = TimeSpan.FromSeconds(2);
        public TimeSpan CompleteMaxDelay { get; set; } = TimeSpan.FromSeconds(60);
        /// <summary>GET polls waiting for migrationMode = completed after completeMigration.</summary>
        public int VerifyMaxAttempts { get; set; } = 20;
        /// <summary>Sends of one message when the service keeps answering 429 / 5xx / network errors (the GraphClient already retried).</summary>
        public int TransientMessageAttempts { get; set; } = 3;
        public TimeSpan TransientDelay { get; set; } = TimeSpan.FromSeconds(5);
        /// <summary>Pending journal entries read per NextPending call.</summary>
        public int BatchSize { get; set; } = 200;
        /// <summary>Payloads kept in a dry run (redacted).</summary>
        public int DryRunSamples { get; set; } = 20;
        public int MaxReactions { get; set; } = 250;
        /// <summary>Concurrent message POSTs per conversation (3 in flight reach 5.2 msg/s on one thread, 8 degrade). The 5 req/s per thread limiter still applies.</summary>
        public int InFlightPerConversation { get; set; } = 3;
        /// <summary>Copy the files of a conversation (the FileCopier, scoped to it) right after its target exists and before its messages are imported, so the
        /// reference attachments can point to the copied files. Needed for channels (the folder exists only once the channel does). A failure is a warning.</summary>
        public bool CopyFilesInline { get; set; } = true;
        public int FileCopyParallelism { get; set; } = 4;
        /// <summary>Group chats created by the import: after completeMigration every member is removed and re-added with visibleHistoryStartDateTime = 0001-01-01
        /// best effort. Never for 1:1 chats. POST/DELETE chat members are limited to 4 requests/min per chat.</summary>
        public bool RestoreGroupHistory { get; set; } = true;
        public TimeSpan ChatMemberRequestInterval { get; set; } = TimeSpan.FromSeconds(15);
        /// <summary>A hosted content larger than this is dropped from the message (with a reason).</summary>
        public long MaxHostedContentBytes { get; set; } = 10L * 1024 * 1024;
        /// <summary>Slowest conversations kept in the result.</summary>
        public int SlowestCount { get; set; } = 10;
        /// <summary>Application ceiling used for the duration estimate of a dry run (messages per second).</summary>
        public double ApplicationRate { get; set; } = 75;
        public IClock Clock { get; set; } = SystemClock.Instance;
    }

    public sealed class ConversationImportStat
    {
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public int Fragment { get; set; }
        public string TargetKind { get; set; }
        public string TargetId { get; set; }
        /// <summary>Completed | NothingToDo | Stopped | Incomplete (transient, resumable) | Failed | Uncertain | Skipped</summary>
        public string State { get; set; }
        public long Imported { get; set; }
        public long Conflicts { get; set; }
        public long Rejected { get; set; }
        public long Skipped { get; set; }
        public long Pending { get; set; }
        public double Seconds { get; set; }
        public double MessagesPerSecond { get; set; }
        public string Error { get; set; }
    }

    public sealed class DryRunRequest
    {
        public string Method { get; set; }
        public string Url { get; set; }
        /// <summary>Redacted: no body text, no names, no image bytes; dates, ids and structure are kept.</summary>
        public string BodyJson { get; set; }
        public string ConversationKey { get; set; }
    }

    public sealed class ConversationEstimate
    {
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public string TargetKind { get; set; }
        public long Messages { get; set; }
        public long Replies { get; set; }
        public long Skipped { get; set; }
        public long Rejected { get; set; }
        public long Requests { get; set; }
        public double EstimatedSeconds { get; set; }
    }

    public sealed class DryRunReport
    {
        /// <summary>"METHOD /path/with/{placeholders}" to the number of requests that would be sent.</summary>
        public SortedDictionary<string, long> RequestsByEndpoint { get; } = new SortedDictionary<string, long>(StringComparer.Ordinal);
        public long TotalRequests { get; set; }
        public long MessagesToImport { get; set; }
        public long MessagesSkipped { get; set; }
        public long MessagesRejected { get; set; }
        public SortedDictionary<string, long> DroppedByReason { get; } = new SortedDictionary<string, long>(StringComparer.Ordinal);
        public List<DryRunRequest> Samples { get; } = new List<DryRunRequest>();
        public List<ConversationEstimate> Conversations { get; } = new List<ConversationEstimate>();
        public TimeSpan EstimatedDuration { get; set; }
        public int ConversationsToCreate { get; set; }
        /// <summary>Downloaded files not yet copied to the target (copied inline per conversation before its messages), and their bytes.</summary>
        public long FilesToCopy { get; set; }
        public long FileBytesToCopy { get; set; }
    }

    public sealed class ImportResult
    {
        public long LotId { get; set; }
        public string LotName { get; set; }
        public bool Applied { get; set; }
        public bool Stopped { get; set; }
        public TimeSpan Elapsed { get; set; }
        public int ItemsTotal { get; set; }
        public int ItemsCompleted { get; set; }
        public int ItemsIncomplete { get; set; }
        public int ItemsFailed { get; set; }
        public int ItemsSkipped { get; set; }
        public int ItemsUncertain { get; set; }
        public long MessagesImported { get; set; }
        public long MessagesConflict409 { get; set; }
        public long MessagesRejected { get; set; }
        public long MessagesSkipped { get; set; }
        public long DateShifts { get; set; }
        public long ChatsCreated { get; set; }
        public long TeamsCreated { get; set; }
        public long ChannelsCreated { get; set; }
        /// <summary>HTTP status counters of the importer's own calls (after the client's retries).</summary>
        public long Status400 { get; set; }
        public long Status403 { get; set; }
        public long Status409 { get; set; }
        public long Status404 { get; set; }
        /// <summary>429 / 503 answers seen by the GraphClient (including the ones it retried), when GraphMetrics is attached.</summary>
        public long Throttled429 { get; set; }
        public long Throttled503 { get; set; }
        public Dictionary<string, long> RequestsByClass { get; set; } = new Dictionary<string, long>();
        public Dictionary<string, long> DroppedByReason { get; set; } = new Dictionary<string, long>();
        public double MessagesPerSecond { get; set; }
        public List<ConversationImportStat> Conversations { get; set; } = new List<ConversationImportStat>();
        public List<ConversationImportStat> Slowest { get; set; } = new List<ConversationImportStat>();
        public List<ErrorRecord> Errors { get; set; } = new List<ErrorRecord>();
        public List<string> Warnings { get; set; } = new List<string>();
        public DryRunReport DryRun { get; set; }
        /// <summary>Messages journaled Pending in the processed items when the run ended.</summary>
        public long MessagesPending { get; set; }
        /// <summary>Files copied inline before the messages (uploaded + reused), their bytes, and the files that could not be copied.</summary>
        public long FilesCopied { get; set; }
        public long FileBytesCopied { get; set; }
        public long FilesFailed { get; set; }
        /// <summary>Rejected messages in the journal of the processed items (this run and earlier ones): drives exit code 3.</summary>
        public long MessagesRejectedTotal { get; set; }
        public long MessagesDone { get { return MessagesImported + MessagesConflict409; } }
    }

    #endregion

    #region Importer

    public sealed class Importer
    {
        // ------------------------------------------------------------------------------------------ construction
        private readonly GraphClient _client;
        private readonly TmtStore _store;
        private readonly IIdentityMap _identities;
        private readonly ITargetMap _targets;
        private readonly IFileCopyMap _files;
        private readonly ImportRunOptions _o;
        private readonly string _appId;
        private readonly IStoreReader _reader;

        /// <summary>The target object id of the first identity of kind ServiceAccount (the planner records the service account that way); null when none.</summary>
        public static string FindServiceAccountId(IIdentityMap identities)
        {
            if (identities == null) return null;
            foreach (var m in identities.List(IdentityKind.ServiceAccount)) if (!string.IsNullOrEmpty(m.TargetUserId)) return m.TargetUserId;
            return null;
        }

        /// <summary>An object id as it is, a user principal name resolved with GET /users/{upn}. Null when it cannot be resolved.</summary>
        public static async Task<string> ResolveUserIdAsync(GraphClient client, string idOrUpn, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(idOrUpn)) return null;
            idOrUpn = idOrUpn.Trim();
            Guid g;
            if (Guid.TryParse(idOrUpn, out g) || client == null) return idOrUpn;
            try
            {
                using (var doc = await client.GetJsonAsync("v1.0/users/" + Uri.EscapeDataString(idOrUpn) + "?$select=id", EndpointClass.Users, null, ct).ConfigureAwait(false))
                    return doc == null ? null : Str(doc.RootElement, "id");
            }
            catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 400) { return null; }
        }

        public ImportTuning Tuning { get; set; } = new ImportTuning();
        public ImportRunOptions Options { get { return _o; } }

        /// <param name="targetClient">The TARGET tenant client (null is allowed for a dry run only).</param>
        /// <param name="appId">The application id of the target app: the same application must start, import and complete.</param>
        public Importer(GraphClient targetClient, TmtStore store, IIdentityMap identities, ITargetMap targets, IFileCopyMap files, ImportRunOptions options, string appId = null)
        {
            if (store == null) throw new ArgumentNullException(nameof(store));
            if (identities == null) throw new ArgumentNullException(nameof(identities));
            if (targets == null) throw new ArgumentNullException(nameof(targets));
            if (files == null) throw new ArgumentNullException(nameof(files));
            _client = targetClient; _store = store; _reader = store; _identities = identities; _targets = targets; _files = files;
            _o = options ?? new ImportRunOptions();
            _appId = string.IsNullOrEmpty(appId) ? "target-app" : appId;
        }

        // ------------------------------------------------------------------------------------------ counters
        private long _imported, _conflicts, _rejected, _skipped, _shifts, _chatsCreated, _teamsCreated, _channelsCreated;
        private long _s400, _s403, _s409, _s404, _pendingLeft;
        private long _itemsDone, _itemsTotal, _convDone, _errorCount;
        private readonly ConcurrentDictionary<string, long> _byClass = new ConcurrentDictionary<string, long>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, long> _dropped = new ConcurrentDictionary<string, long>(StringComparer.Ordinal);
        private readonly ConcurrentBag<ConversationImportStat> _stats = new ConcurrentBag<ConversationImportStat>();
        private readonly ConcurrentQueue<ErrorRecord> _errors = new ConcurrentQueue<ErrorRecord>();
        private readonly ConcurrentQueue<string> _warnings = new ConcurrentQueue<string>();
        private readonly ConcurrentDictionary<string, IdentityMapping> _idCache = new ConcurrentDictionary<string, IdentityMapping>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, SemaphoreSlim> _teamLocks = new ConcurrentDictionary<string, SemaphoreSlim>(StringComparer.Ordinal);
        private readonly Stopwatch _sw = new Stopwatch();
        private string _phase = "";
        private volatile bool _stopped;
        private int _active;
        private long _filesCopied, _fileBytes, _filesFailed;
        private readonly HashSet<string> _dryFilesSeen = new HashSet<string>(StringComparer.Ordinal);

        /// <summary>Live counters for a console (poll it from any thread).</summary>
        public ProgressSnapshot Progress
        {
            get
            {
                double secs = Math.Max(0.001, _sw.Elapsed.TotalSeconds);
                long done = Interlocked.Read(ref _imported) + Interlocked.Read(ref _conflicts);
                long units = Interlocked.Read(ref _itemsDone), total = Interlocked.Read(ref _itemsTotal);
                TimeSpan? eta = null;
                if (total > 0 && units > 0 && units < total) eta = TimeSpan.FromSeconds(secs / units * (total - units));
                var p = new ProgressSnapshot
                {
                    Operation = "Import", Phase = _phase == "Importing" ? "Importing, " + Math.Max(0, Volatile.Read(ref _active)) + " active conversation(s), " + (Volatile.Read(ref _active) > 0 ? (done / secs / Volatile.Read(ref _active)).ToString("0.0", CultureInfo.InvariantCulture) : "0") + " msg/s each" : _phase, Conversations = Interlocked.Read(ref _convDone), Messages = done, NewMessages = Interlocked.Read(ref _imported),
                    Errors = Interlocked.Read(ref _rejected) + Interlocked.Read(ref _errorCount), UnitsDone = units, UnitsTotal = total, Elapsed = _sw.Elapsed,
                    MessagesPerSecond = done / secs, UnitsPerSecond = units / secs, Eta = eta, Final = false
                };
                return p;
            }
        }

        // ------------------------------------------------------------------------------------------ run
        private sealed class Unit { public string Key; public List<LotItem> Items = new List<LotItem>(); public int Priority; }

        /// <summary>
        /// Imports (Apply) or plans (dry run) the items of the lot. slices = null or empty means every slice. Conversations run in
        /// parallel (ConversationParallelism); the items of one conversation (its slices, newest wave first) run one after the other
        /// in one worker. Stop control is checked between messages: a stopped run leaves the thread in migration mode and the
        /// session Started; the next run resumes it.
        /// </summary>
        public async Task<ImportResult> RunAsync(long lotId, int[] slices, CancellationToken ct)
        {
            _sw.Restart();
            var lot = _store.GetLot(lotId);
            if (lot == null) throw new KeyNotFoundException("No lot #" + lotId);
            var result = new ImportResult { LotId = lotId, LotName = lot.Name, Applied = _o.Apply };
            if (_o.Apply && _client == null) throw new InvalidOperationException("Apply needs a target Graph client.");
            if (!_o.Apply && !IsImportable(lot.State)) throw new InvalidOperationException("Lot '" + lot.Name + "' is " + lot.State + ": the import needs a planned lot (state ImportPlanned or later).");

            var sliceSet = slices != null && slices.Length > 0 ? new HashSet<int>(slices) : null;
            var items = _store.ListItems(lotId).Where(i => sliceSet == null || sliceSet.Contains(i.SliceNo)).ToList();
            var units = new List<Unit>();
            var byKey = new Dictionary<string, Unit>(StringComparer.Ordinal);
            foreach (var it in items)
            {
                if (!ItemRunnable(it.State)) continue;
                Unit u;
                if (!byKey.TryGetValue(it.ConversationKey, out u)) { u = new Unit { Key = it.ConversationKey, Priority = it.Priority }; byKey[it.ConversationKey] = u; units.Add(u); }
                u.Items.Add(it);
            }
            foreach (var u in units) u.Items.Sort((a, b) => a.SliceNo != b.SliceNo ? a.SliceNo.CompareTo(b.SliceNo) : a.Fragment.CompareTo(b.Fragment));
            result.ItemsTotal = units.Sum(u => u.Items.Count);
            _itemsTotal = result.ItemsTotal;
            if (_o.Apply) { Preflight(units); PrepareLot(lot); }
            var before = GraphMetrics.Of(_client)?.Snapshot();

            if (!_o.Apply)
            {
                _phase = "Preview";
                result.DryRun = new DryRunReport();
                await Par.ForEachAsync(units, Math.Max(1, Math.Min(_o.ConversationParallelism, 16)), (u, token) => DryRunUnitAsync(u, result.DryRun, token), ct, _o.Stop).ConfigureAwait(false);
                FinishDryRun(result.DryRun);
                result.Stopped = StopControl.Stopped(_o.Stop);
            }
            else
            {
                _phase = "Importing";
                await Par.ForEachAsync(units, Math.Max(1, _o.ConversationParallelism), (u, token) => RunUnitAsync(u, token), ct, _o.Stop).ConfigureAwait(false);
                result.Stopped = _stopped || StopControl.Stopped(_o.Stop);
            }
            _sw.Stop();

            result.Elapsed = _sw.Elapsed;
            result.MessagesImported = Interlocked.Read(ref _imported);
            result.MessagesConflict409 = Interlocked.Read(ref _conflicts);
            result.MessagesRejected = Interlocked.Read(ref _rejected);
            result.MessagesSkipped = Interlocked.Read(ref _skipped);
            result.DateShifts = Interlocked.Read(ref _shifts);
            result.ChatsCreated = _chatsCreated; result.TeamsCreated = _teamsCreated; result.ChannelsCreated = _channelsCreated;
            result.Status400 = _s400; result.Status403 = _s403; result.Status409 = _s409; result.Status404 = _s404;
            result.MessagesPending = Interlocked.Read(ref _pendingLeft);
            result.FilesCopied = Interlocked.Read(ref _filesCopied); result.FileBytesCopied = Interlocked.Read(ref _fileBytes); result.FilesFailed = Interlocked.Read(ref _filesFailed);
            result.RequestsByClass = new Dictionary<string, long>(_byClass);
            result.DroppedByReason = new Dictionary<string, long>(_dropped);
            result.Conversations = _stats.OrderBy(s => s.ConversationKey, StringComparer.Ordinal).ThenBy(s => s.SliceNo).ThenBy(s => s.Fragment).ToList();
            result.Slowest = result.Conversations.Where(s => s.Imported + s.Conflicts > 0).OrderByDescending(s => s.Seconds).Take(Tuning.SlowestCount).ToList();
            result.ItemsCompleted = result.Conversations.Count(s => s.State == "Completed" || s.State == "NothingToDo");
            result.ItemsIncomplete = result.Conversations.Count(s => s.State == "Incomplete" || s.State == "Stopped");
            result.ItemsFailed = result.Conversations.Count(s => s.State == "Failed");
            result.ItemsUncertain = result.Conversations.Count(s => s.State == "Uncertain");
            result.ItemsSkipped = result.Conversations.Count(s => s.State == "Skipped");
            result.MessagesPerSecond = result.Elapsed.TotalSeconds > 0 ? result.MessagesDone / result.Elapsed.TotalSeconds : 0;
            if (_o.Apply)
                foreach (var g in result.Conversations.Where(s => s.TargetKind != null && s.TargetKind != "Skip").GroupBy(s => s.ConversationKey + "#" + s.SliceNo))
                {
                    var s0 = g.First();
                    try { result.MessagesRejectedTotal += _store.GetJournalSummary(s0.ConversationKey, s0.SliceNo)[JournalStatus.Rejected]; } catch (Exception) { }
                }
            result.Errors = _errors.ToList();
            result.Warnings = _warnings.Distinct().ToList();
            var after = GraphMetrics.Of(_client)?.Snapshot();
            if (before != null && after != null) { result.Throttled429 = after.Throttled429 - before.Throttled429; result.Throttled503 = after.Throttled503 - before.Throttled503; }
            if (_o.Apply && !result.Stopped) CompleteLotIfDone(lot);
            return result;
        }

        /// <summary>Refuses to start (before anything is written) when a team to create has no owner: one clear message instead of one failure per conversation.</summary>
        private void Preflight(List<Unit> units)
        {
            if (!string.IsNullOrEmpty(_o.ServiceAccountUserId)) return;
            var all = _targets.List().ToList();
            var bad = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var u in units)
            {
                var tm = all.FirstOrDefault(x => x.SourceConversationKey == u.Key);
                if (tm == null || (tm.Kind != TargetKind.NewChannel && tm.Kind != TargetKind.ArchiveChannel) || !string.IsNullOrEmpty(tm.TargetTeamId)) continue;
                string team = tm.CreateTeamName ?? "";
                if (!TeamMembersOf(all, team, tm).Any()) bad.Add(team);
            }
            if (bad.Count > 0)
                throw new InvalidOperationException("No service account: the new team(s) " + string.Join(", ", bad.Take(5).Select(x => "'" + x + "'")) + (bad.Count > 5 ? ", ..." : "") +
                    " need an owner at creation. Give -ServiceAccount (UPN or object id), set Target.ServiceAccountUserId in the configuration, or plan a ServiceAccount identity. Nothing was started.");
        }

        /// <summary>Every planned member of every channel that targets the same new team (distinct, in order).</summary>
        private static IEnumerable<string> TeamMembersOf(List<TargetMapping> all, string teamName, TargetMapping self)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var t in all.Where(x => x.CreateTeamName == teamName && x.SourceConversationKey != self.SourceConversationKey).Prepend(self))
                foreach (var m in t.TargetMemberIds ?? new List<string>())
                    if (!string.IsNullOrEmpty(m) && seen.Add(m)) yield return m;
        }

        private static bool IsImportable(LotState s)
        {
            return s == LotState.ImportPlanned || s == LotState.Ghosts || s == LotState.Files || s == LotState.Importing || s == LotState.Completing || s == LotState.Verified;
        }

        private static bool ItemRunnable(LotState s)
        {
            // the lot state gates the run; the planner moves the lot, not its items, so an item may still read Planned / Exporting / Exported
            return s != LotState.Verified && s != LotState.Closed;
        }

        private void PrepareLot(LotInfo lot)
        {
            if (lot.State == LotState.Importing) return;
            if (!IsImportable(lot.State))
                throw new InvalidOperationException("Lot '" + lot.Name + "' is " + lot.State + ": the import needs a planned lot (state ImportPlanned, Ghosts, Files or Importing). Run the planner first.");
            _store.TransitionLot(lot.Id, LotState.Importing, "Import started");
        }

        private void CompleteLotIfDone(LotInfo lot)
        {
            try
            {
                var cur = _store.GetLot(lot.Id);
                if (cur == null || cur.State != LotState.Importing) return;
                foreach (var it in _store.ListItems(lot.Id))
                {
                    if (it.State == LotState.Completing || it.State == LotState.Verified || it.State == LotState.Closed) continue;
                    var tm = _targets.Get(it.ConversationKey);
                    if (tm != null && tm.Kind == TargetKind.Skip) continue;
                    return;
                }
                _store.TransitionLot(lot.Id, LotState.Completing, "Every item imported");
            }
            catch (Exception ex) { _warnings.Enqueue("The lot state could not be advanced: " + ex.Message); }
        }

        private void AddError(string scope, string operation, Exception ex)
        {
            Interlocked.Increment(ref _errorCount);
            var g = ex as GraphException;
            _errors.Enqueue(new ErrorRecord
            {
                Scope = scope, Operation = operation, When = DateTimeOffset.UtcNow, StatusCode = g != null ? g.StatusCode : 0,
                ErrorCode = g != null ? g.ErrorCode : ex.GetType().Name, Message = ex.Message.Length > 400 ? ex.Message.Substring(0, 400) : ex.Message
            });
        }

        // ------------------------------------------------------------------------------------------ one conversation (all its items)
        private async Task RunUnitAsync(Unit u, CancellationToken ct)
        {
            foreach (var item in u.Items)
            {
                if (StopControl.Stopped(_o.Stop)) { _stopped = true; return; }
                ct.ThrowIfCancellationRequested();
                var st = await RunItemAsync(item, ct).ConfigureAwait(false);
                _stats.Add(st);
                if (st.State == "Stopped") { _stopped = true; return; }
                if (st.State == "Failed" || st.State == "Incomplete" || st.State == "Uncertain") return;   // the older waves wait for the newer one
            }
        }

        private sealed class FatalConversation : Exception { public FatalConversation(string m, Exception inner = null) : base(m, inner) { } }
        private sealed class TransientConversation : Exception { public TransientConversation(string m, Exception inner = null) : base(m, inner) { } }
        private sealed class UncertainConversation : Exception { public UncertainConversation(string m) : base(m) { } }

        private async Task<ConversationImportStat> RunItemAsync(LotItem item, CancellationToken ct)
        {
            var key = item.ConversationKey;
            var st = new ConversationImportStat { ConversationKey = key, SliceNo = item.SliceNo, Fragment = item.Fragment, State = "Completed" };
            var sw = Stopwatch.StartNew();
            var counters = new ItemCounters();
            Interlocked.Increment(ref _active);
            try
            {
                var tm = _targets.Get(key);
                if (tm == null) throw new FatalConversation("No target mapping for the conversation: run the planner.");
                st.TargetKind = tm.Kind.ToString();
                if (tm.Kind == TargetKind.Skip) { st.State = "Skipped"; st.Error = tm.Note; Interlocked.Increment(ref _convDone); Interlocked.Increment(ref _itemsDone); return st; }
                if (item.State == LotState.Completing)
                {
                    // already imported by an earlier run: nothing to do unless the journal still holds pending messages or an open session
                    var sm = _store.GetJournalSummary(key, item.SliceNo);
                    var ls = _store.GetLatestImportSession(key, item.SliceNo);
                    if (sm[JournalStatus.Pending] == 0 && (ls == null || ls.State != ImportSessionState.Started))
                    {
                        FillStat(st, key, item.SliceNo, counters, sm);
                        st.State = "Completed"; Interlocked.Increment(ref _itemsDone);
                        return st;
                    }
                }
                MarkItem(item, LotState.Importing);

                var conv = _store.GetConversation(key);
                DateTimeOffset? oldest = SeedItem(item);
                var summary = _store.GetJournalSummary(key, item.SliceNo);
                int pending = summary[JournalStatus.Pending];
                var latest = _store.GetLatestImportSession(key, item.SliceNo);

                if (pending == 0)
                {
                    // nothing left to send: a session still Started (crash after the last message) is closed, the item is done
                    if (latest != null && latest.State == ImportSessionState.Started)
                    {
                        var th0 = ThreadFromMapping(tm);
                        if (th0 == null) { _store.CompleteImportSession(latest.Id, ImportSessionState.Abandoned, "No target thread known"); }
                        else
                        {
                            if (latest.AppId != _appId) throw new FatalConversation("The migration session was started by another application (" + latest.AppId + "): only that application can complete it.");
                            st.TargetId = th0.Id;
                            await FinishMigrationAsync(th0, latest.Id, key, ct).ConfigureAwait(false);
                        }
                    }
                    FillStat(st, key, item.SliceNo, counters, summary);
                    st.State = (st.Imported + st.Conflicts + st.Rejected + st.Skipped) == 0 ? "NothingToDo" : "Completed";
                    MarkItem(item, LotState.Completing);
                    Interlocked.Increment(ref _convDone); Interlocked.Increment(ref _itemsDone);
                    return st;
                }

                var thread = await EnsureTargetAsync(tm, conv, ct).ConfigureAwait(false);
                st.TargetId = thread.Id;
                if (Tuning.CopyFilesInline) await CopyFilesInlineAsync(key, item, ct).ConfigureAwait(false);
                long sessionId = await OpenSessionAsync(item, thread, latest, oldest, ct).ConfigureAwait(false);
                var stopped = await ImportPendingAsync(item, thread, sessionId, counters, ct).ConfigureAwait(false);
                if (stopped) { st.State = "Stopped"; }
                else
                {
                    await FinishMigrationAsync(thread, sessionId, key, ct).ConfigureAwait(false);
                    MarkItem(item, LotState.Completing);
                    Interlocked.Increment(ref _convDone); Interlocked.Increment(ref _itemsDone);
                    if (Tuning.RestoreGroupHistory && tm.Kind == TargetKind.NewChat && thread.IsChat) await RestoreGroupHistoryAsync(thread, key, conv, ct).ConfigureAwait(false);
                }
                summary = _store.GetJournalSummary(key, item.SliceNo);
                FillStat(st, key, item.SliceNo, counters, summary);
                Interlocked.Add(ref _pendingLeft, summary[JournalStatus.Pending]);
                return st;
            }
            catch (OperationCanceledException) { st.State = "Stopped"; return st; }
            catch (FatalConversation ex)
            {
                st.State = "Failed"; st.Error = ex.Message; AddError(key, "import", ex.InnerException ?? ex);
                try { MarkItem(item, LotState.Failed); } catch (Exception) { }
                return st;
            }
            catch (UncertainConversation ex) { st.State = "Uncertain"; st.Error = ex.Message; AddError(key, "complete", ex); return st; }
            catch (TransientConversation ex) { st.State = "Incomplete"; st.Error = ex.Message; AddError(key, "import", ex.InnerException ?? ex); return st; }
            catch (GraphException ex)
            {
                bool transient = ex.StatusCode == 0 || ex.StatusCode == 429 || ex.StatusCode >= 500;
                st.State = transient ? "Incomplete" : "Failed"; st.Error = ex.Message; AddError(key, "import", ex);
                if (!transient) { try { MarkItem(item, LotState.Failed); } catch (Exception) { } }
                return st;
            }
            catch (Exception ex)
            {
                st.State = "Failed"; st.Error = ex.Message; AddError(key, "import", ex);
                try { MarkItem(item, LotState.Failed); } catch (Exception) { }
                return st;
            }
            finally
            {
                Interlocked.Decrement(ref _active);
                sw.Stop();
                st.Seconds = sw.Elapsed.TotalSeconds;
                st.MessagesPerSecond = st.Seconds > 0 ? (st.Imported + st.Conflicts) / st.Seconds : 0;
            }
        }

        /// <summary>The Downloaded files of the conversation that the file copy map does not hold as Uploaded / Shared yet.</summary>
        private List<FileRecord> FilesToCopy(string key)
        {
            var l = new List<FileRecord>();
            foreach (var f in _reader.ListFiles(key))
            {
                if (f.Status != FileStatus.Downloaded) continue;
                var r = _files.Get(key, f.MessageId, f.AttachmentId);
                if (r != null && (r.State == FileCopyState.Uploaded || r.State == FileCopyState.Shared)) continue;
                l.Add(f);
            }
            return l;
        }

        /// <summary>Runs the FileCopier scoped to ONE conversation whose target now exists. Failures are warnings: the attachment is then dropped with AttachmentNotCopied.</summary>
        private async Task CopyFilesInlineAsync(string key, LotItem item, CancellationToken ct)
        {
            try
            {
                if (FilesToCopy(key).Count == 0) return;
                var fo = new FileCopyOptions { Parallelism = Math.Max(1, Tuning.FileCopyParallelism) };
                var copier = new FileCopier(_client, _store, _identities, _targets, _files, _o, fo);
                var res = await copier.RunAsync(new[] { new FileCopyScope { ConversationKey = key, FromUtc = item.FromUtc, ToUtc = item.ToUtc } }, ct).ConfigureAwait(false);
                Interlocked.Add(ref _filesCopied, res.Uploaded + res.Reused);
                Interlocked.Add(ref _fileBytes, res.Bytes);
                Interlocked.Add(ref _filesFailed, res.Failed);
                if (res.Failed > 0 || res.WaitingForTarget > 0 || res.NoDestination > 0)
                    _warnings.Enqueue("Files of " + key + ": " + res.Failed + " failed, " + res.WaitingForTarget + " waiting for the target, " + res.NoDestination + " without destination: their attachments are dropped from the messages.");
                foreach (var w in res.Warnings) _warnings.Enqueue(key + ": " + w);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { Interlocked.Increment(ref _filesFailed); _warnings.Enqueue("Files of " + key + " could not be copied (" + ex.GetType().Name + ": " + Shorten(ex.Message, 160) + "): their attachments are dropped from the messages."); }
        }

        private const string HistoryMarker = "[history-restored]";

        /// <summary>
        /// Best effort: a group chat created by the import gives its members no access to the imported history. Each member is removed and
        /// re-added at once with visibleHistoryStartDateTime = 0001-01-01. POST/DELETE chat members are limited to 4 requests/min per chat: paced with
        /// ChatMemberRequestInterval. Never for 1:1 chats. A failure is a warning; done once per chat (marker in the target note).
        /// </summary>
        private async Task RestoreGroupHistoryAsync(TargetThread t, string key, ConversationRecord conv, CancellationToken ct)
        {
            var tm = _targets.Get(key);
            if (tm == null || (tm.Note ?? "").Contains(HistoryMarker)) return;
            int planned = tm.TargetMemberIds.Count(x => !string.IsNullOrEmpty(x));
            bool oneOnOne = conv != null ? conv.Kind == ConversationKind.OneOnOne && planned == 2 : planned == 2;
            if (oneOnOne) return;
            var members = new List<Tuple<string, string, bool>>();
            try
            {
                Count(EndpointClass.ChatMembers);
                await foreach (var e in _client.GetPagedAsync(t.Base + "/members", EndpointClass.ChatMembers, null, null, null, ct).ConfigureAwait(false))
                {
                    bool owner = false; JsonElement roles;
                    if (e.TryGetProperty("roles", out roles) && roles.ValueKind == JsonValueKind.Array) foreach (var r in roles.EnumerateArray()) if (r.ValueKind == JsonValueKind.String && r.GetString() == "owner") owner = true;
                    members.Add(Tuple.Create(Str(e, "id"), Str(e, "userId"), owner));
                }
            }
            catch (GraphException ex) { Tally(ex); _warnings.Enqueue("Group history not restored for " + key + ": the members could not be listed (" + ex.StatusCode + " " + ex.ErrorCode + ")"); return; }
            bool allOk = true;
            foreach (var mem in members)
            {
                if (string.IsNullOrEmpty(mem.Item1) || string.IsNullOrEmpty(mem.Item2)) continue;
                try
                {
                    await Delay(Tuning.ChatMemberRequestInterval, ct).ConfigureAwait(false);
                    Count(EndpointClass.ChatMembers);
                    using (await SendJson(HttpMethod.Delete, t.Base + "/members/" + Uri.EscapeDataString(mem.Item1), null, EndpointClass.ChatMembers, null, ct).ConfigureAwait(false)) { }
                }
                catch (GraphException ex) { allOk = false; _warnings.Enqueue("Group history: member " + mem.Item2 + " of " + key + " not removed (" + ex.StatusCode + " " + ex.ErrorCode + ")"); continue; }
                string body;
                using (var ms = new System.IO.MemoryStream())
                {
                    using (var w = new Utf8JsonWriter(ms)) WriteMember(w, mem.Item2, mem.Item3, true);
                    body = Encoding.UTF8.GetString(ms.ToArray());
                }
                for (int a = 1; a <= 2; a++)
                {
                    try
                    {
                        await Delay(Tuning.ChatMemberRequestInterval, ct).ConfigureAwait(false);
                        Count(EndpointClass.ChatMembers);
                        using (await SendJson(HttpMethod.Post, t.Base + "/members", body, EndpointClass.ChatMembers, null, ct).ConfigureAwait(false)) { }
                        break;
                    }
                    catch (GraphException ex) when (ex.StatusCode == 409) { break; }
                    catch (GraphException ex)
                    {
                        if (a == 2) { allOk = false; _warnings.Enqueue("Group history: member " + mem.Item2 + " of " + key + " was removed and could NOT be re-added (" + ex.StatusCode + " " + ex.ErrorCode + "): add it again by hand."); }
                    }
                }
            }
            if (allOk)
            {
                tm.Note = ((tm.Note ?? "") + " " + HistoryMarker).Trim();
                _targets.Upsert(tm);
            }
        }

        private sealed class ItemCounters { public long Imported, Conflicts, Rejected, Skipped; }

        private void FillStat(ConversationImportStat st, string key, int slice, ItemCounters c, IReadOnlyDictionary<JournalStatus, int> summary)
        {
            st.Imported = c.Imported; st.Conflicts = c.Conflicts; st.Rejected = c.Rejected; st.Skipped = c.Skipped;
            st.Pending = summary[JournalStatus.Pending];
            if (c.Imported + c.Conflicts + c.Rejected + c.Skipped == 0)
            {
                // a pure resume: report what the journal holds
                st.Imported = summary[JournalStatus.Imported]; st.Conflicts = summary[JournalStatus.Conflict409TreatedAsImported];
                st.Rejected = summary[JournalStatus.Rejected]; st.Skipped = summary[JournalStatus.Skipped];
            }
        }

        private void MarkItem(LotItem item, LotState to)
        {
            // legal moves only (the item lifecycle of the catalog): Planned -> Exporting -> Exported -> ImportPlanned -> Importing,
            // Ghosts / Files / Completing / Failed / Paused -> Importing, Importing -> Completing / Failed
            var cur = _store.ListItems(item.LotId, item.SliceNo).FirstOrDefault(i => i.ConversationKey == item.ConversationKey && i.Fragment == item.Fragment);
            if (cur == null) return;
            var state = cur.State;
            if (state == to) return;
            if (to == LotState.Completing && state != LotState.Importing) return;
            if (to == LotState.Importing)
            {
                foreach (var step in new[] { LotState.Exporting, LotState.Exported, LotState.ImportPlanned })
                {
                    if (state == LotState.Planned && step == LotState.Exporting || state == LotState.Exporting && step == LotState.Exported || state == LotState.Exported && step == LotState.ImportPlanned)
                    {
                        _store.SetItemState(item.LotId, item.ConversationKey, item.SliceNo, item.Fragment, step);
                        state = step;
                    }
                }
            }
            _store.SetItemState(item.LotId, item.ConversationKey, item.SliceNo, item.Fragment, to);
        }

        // ------------------------------------------------------------------------------------------ seeding
        /// <summary>Registers the ordered ids of the item in the journal (idempotent). Returns the oldest message date of the item.</summary>
        private DateTimeOffset? SeedItem(LotItem item)
        {
            DateTimeOffset? oldest = null;
            var chunk = new List<string>(2000);
            foreach (var m in _reader.ReadMessages(item.ConversationKey, item.FromUtc, item.ToUtc))
            {
                string id = Str(m, "id");
                if (id == null) continue;
                var c = ParseDate(Str(m, "createdDateTime"));
                if (c.HasValue && (!oldest.HasValue || c.Value < oldest.Value)) oldest = c;
                chunk.Add(id);
                if (chunk.Count >= 2000) { _store.SeedJournal(item.ConversationKey, item.SliceNo, chunk); chunk.Clear(); }
            }
            if (chunk.Count > 0) _store.SeedJournal(item.ConversationKey, item.SliceNo, chunk);
            return oldest;
        }

        // ------------------------------------------------------------------------------------------ target conversation
        private sealed class TargetThread
        {
            public bool IsChat; public string ChatId, TeamId, ChannelId;
            public string Id { get { return IsChat ? ChatId : TeamId + "/" + ChannelId; } }
            public string Base { get { return IsChat ? "v1.0/chats/" + Uri.EscapeDataString(ChatId) : "v1.0/teams/" + Uri.EscapeDataString(TeamId) + "/channels/" + Uri.EscapeDataString(ChannelId); } }
            public string ThreadKey { get { return IsChat ? ChatId : ChannelId; } }
            public string InfoClass { get { return IsChat ? EndpointClass.Chat : EndpointClass.Channels; } }
        }

        private static TargetThread ThreadFromMapping(TargetMapping tm)
        {
            switch (tm.Kind)
            {
                case TargetKind.ExistingChat:
                case TargetKind.NewChat:
                    return string.IsNullOrEmpty(tm.TargetChatId) ? null : new TargetThread { IsChat = true, ChatId = tm.TargetChatId };
                case TargetKind.ExistingChannel:
                case TargetKind.NewChannel:
                case TargetKind.ArchiveChannel:
                    return string.IsNullOrEmpty(tm.TargetTeamId) || string.IsNullOrEmpty(tm.TargetChannelId) ? null : new TargetThread { TeamId = tm.TargetTeamId, ChannelId = tm.TargetChannelId };
                default: return null;
            }
        }

        private async Task<TargetThread> EnsureTargetAsync(TargetMapping tm, ConversationRecord conv, CancellationToken ct)
        {
            switch (tm.Kind)
            {
                case TargetKind.ExistingChat:
                    if (string.IsNullOrEmpty(tm.TargetChatId)) throw new FatalConversation("ExistingChat without TargetChatId.");
                    return new TargetThread { IsChat = true, ChatId = tm.TargetChatId };
                case TargetKind.ExistingChannel:
                    if (string.IsNullOrEmpty(tm.TargetTeamId) || string.IsNullOrEmpty(tm.TargetChannelId)) throw new FatalConversation("ExistingChannel without TargetTeamId / TargetChannelId.");
                    return new TargetThread { TeamId = tm.TargetTeamId, ChannelId = tm.TargetChannelId };
                case TargetKind.NewChat:
                    {
                        var th = ThreadFromMapping(tm);
                        if (th != null && tm.State == TargetState.Created) return th;
                        return await CreateChatAsync(tm, conv, ct).ConfigureAwait(false);
                    }
                case TargetKind.NewChannel:
                case TargetKind.ArchiveChannel:
                    {
                        var th = ThreadFromMapping(tm);
                        if (th != null && tm.State == TargetState.Created) return th;
                        return await CreateChannelAsync(tm, conv, ct).ConfigureAwait(false);
                    }
                default: throw new FatalConversation("Target kind " + tm.Kind + " cannot be imported.");
            }
        }

        private static string UserBind(string id) { return "https://graph.microsoft.com/v1.0/users('" + id + "')"; }

        private static void WriteMember(Utf8JsonWriter w, string userId, bool owner, bool allHistory)
        {
            w.WriteStartObject();
            w.WriteString("@odata.type", "#microsoft.graph.aadUserConversationMember");
            w.WriteStartArray("roles"); if (owner) w.WriteStringValue("owner"); w.WriteEndArray();
            w.WriteString("user@odata.bind", UserBind(userId));
            if (allHistory) w.WriteString("visibleHistoryStartDateTime", "0001-01-01T00:00:00Z");
            w.WriteEndObject();
        }

        private async Task<TargetThread> CreateChatAsync(TargetMapping tm, ConversationRecord conv, CancellationToken ct)
        {
            List<string> departed;
            var members = LiveMembers(tm.TargetMemberIds, tm.SourceConversationKey, out departed);
            bool oneOnOne = conv != null ? conv.Kind == ConversationKind.OneOnOne && members.Count == 2 && departed.Count == 0 : members.Count == 2 && departed.Count == 0;
            string topic = tm.CreateTopic;
            if (members.Count < 2 && departed.Count > 0 && !string.IsNullOrEmpty(_o.ServiceAccountUserId))
            {
                // A chat with a departed person keeps one live member only: it becomes a group chat with the service account,
                // titled after the departed participant(s), so that the history can be imported and read.
                if (!members.Contains(_o.ServiceAccountUserId, StringComparer.OrdinalIgnoreCase)) members.Add(_o.ServiceAccountUserId);
                oneOnOne = false;
                if (string.IsNullOrEmpty(topic)) topic = "Archived chat with " + string.Join(", ", departed);
                _warnings.Enqueue(tm.SourceConversationKey + ": the other participant has left (" + string.Join(", ", departed) + "): imported as the group chat '" + topic + "' with the service account.");
            }
            if (members.Count < 2) throw new FatalConversation("A new chat needs at least two target members (planned: " + members.Count + (departed.Count > 0 ? ", departed: " + departed.Count + "; give -ServiceAccount" : "") + ").");
            string json = ChatBody(oneOnOne, topic, members);
            Count(EndpointClass.Chat);
            using (var doc = await SendJson(HttpMethod.Post, "v1.0/chats", json, EndpointClass.Chat, null, ct).ConfigureAwait(false))
            {
                string id = doc == null ? null : Str(doc.RootElement, "id");
                if (string.IsNullOrEmpty(id)) throw new FatalConversation("POST /chats returned no chat id.");
                tm.TargetChatId = id; tm.State = TargetState.Created;
                _targets.Upsert(tm);
                Interlocked.Increment(ref _chatsCreated);
                return new TargetThread { IsChat = true, ChatId = id };
            }
        }

        /// <summary>
        /// The members that can really be added to a target chat, channel or team. Ghost accounts are disabled: they are authors of
        /// imported messages, never members. A planned "ghost:&lt;SourceUserId&gt;" placeholder (ghost not created at plan time) and the
        /// target id of a created ghost are both left out; their display names are returned in <paramref name="departed"/>.
        /// </summary>
        private List<string> LiveMembers(IEnumerable<string> planned, string conversationKey, out List<string> departed)
        {
            var ghostIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var g in _identities.List(IdentityKind.Ghost)) if (g != null && !string.IsNullOrEmpty(g.TargetUserId)) ghostIds.Add(g.TargetUserId);
            var live = new List<string>();
            departed = new List<string>();
            foreach (var raw in planned ?? Enumerable.Empty<string>())
            {
                if (string.IsNullOrEmpty(raw)) continue;
                IdentityMapping ghost = null;
                if (raw.StartsWith("ghost:", StringComparison.Ordinal)) ghost = _identities.Get(raw.Substring(6));
                else if (ghostIds.Contains(raw)) ghost = _identities.List(IdentityKind.Ghost).FirstOrDefault(g => string.Equals(g.TargetUserId, raw, StringComparison.OrdinalIgnoreCase));
                if (ghost != null || raw.StartsWith("ghost:", StringComparison.Ordinal))
                {
                    string name = ghost != null ? (ghost.SourceDisplayName ?? ghost.TargetDisplayName ?? ghost.SourceUserId) : raw.Substring(6);
                    if (!departed.Contains(name)) departed.Add(name);
                    continue;
                }
                if (!live.Contains(raw, StringComparer.OrdinalIgnoreCase)) live.Add(raw);
            }
            if (departed.Count > 0)
                _warnings.Enqueue(conversationKey + ": " + departed.Count + " departed member(s) not added (ghost accounts are disabled; their messages keep the ghost as author).");
            return live;
        }

        internal static string ChatBody(bool oneOnOne, string topic, IList<string> members)
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("chatType", oneOnOne ? "oneOnOne" : "group");
                    if (!oneOnOne && !string.IsNullOrEmpty(topic)) w.WriteString("topic", topic);
                    w.WriteStartArray("members");
                    foreach (var m in members) WriteMember(w, m, true, false);   // the service refuses visibleHistoryStartDateTime at creation: see RestoreGroupHistoryAsync
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        private SemaphoreSlim TeamLock(string name) { return _teamLocks.GetOrAdd(name ?? "", _ => new SemaphoreSlim(1, 1)); }

        private async Task<TargetThread> CreateChannelAsync(TargetMapping tm, ConversationRecord conv, CancellationToken ct)
        {
            string name = !string.IsNullOrEmpty(tm.CreateTopic) ? tm.CreateTopic : (conv != null && !string.IsNullOrEmpty(conv.Topic) ? conv.Topic : "Imported channel");
            string membership = (tm.CreateMembershipType ?? (conv != null ? conv.MembershipType : null) ?? "standard").ToLowerInvariant();
            if (membership != "private" && membership != "shared") membership = "standard";
            List<string> departedMembers, departedTeam;
            var members = LiveMembers(tm.TargetMemberIds, tm.SourceConversationKey, out departedMembers);
            var allMaps = _targets.List().ToList();
            var teamMembers = LiveMembers(TeamMembersOf(allMaps, tm.CreateTeamName ?? "", tm), tm.SourceConversationKey, out departedTeam);
            // one owner per TEAM (never the member list of one channel only): the service account, else the first planned member of any channel of the team
            string owner = !string.IsNullOrEmpty(_o.ServiceAccountUserId) ? _o.ServiceAccountUserId : (teamMembers.Count > 0 ? teamMembers[0] : (members.Count > 0 ? members[0] : null));
            bool teamIsOurs = string.IsNullOrEmpty(tm.TargetTeamId);

            // 1. the team (created once, even when several channels name the same team)
            string teamId = tm.TargetTeamId;
            if (string.IsNullOrEmpty(teamId))
            {
                string teamName = tm.CreateTeamName;
                if (string.IsNullOrEmpty(teamName)) throw new FatalConversation("NewChannel without TargetTeamId and without CreateTeamName.");
                var gate = TeamLock(teamName);
                await gate.WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    teamId = _targets.List().Where(x => x.CreateTeamName == teamName && !string.IsNullOrEmpty(x.TargetTeamId)).Select(x => x.TargetTeamId).FirstOrDefault();
                    // A run killed between POST /teams and the Upsert below (or a POST retried after a timeout) already created
                    // the team: find it by name before creating one, so that a retried creation never makes a duplicate team.
                    if (string.IsNullOrEmpty(teamId)) teamId = await FindTeamByNameAsync(teamName, ct).ConfigureAwait(false);
                    if (string.IsNullOrEmpty(teamId))
                    {
                        if (owner == null) throw new FatalConversation("A new team needs an owner: set ImportRunOptions.ServiceAccountUserId or plan at least one member.");
                        teamId = await CreateTeamAsync(teamName, owner, ct).ConfigureAwait(false);
                    }
                    tm.TargetTeamId = teamId; tm.State = TargetState.Planned;
                    _targets.Upsert(tm);   // the team is recorded before the channel: a crash never creates a second team
                    if (_teamPopulated.TryAdd(teamId, true)) await AddTeamMembersAsync(teamId, teamMembers, owner, tm.CreateTeamName, ct).ConfigureAwait(false);
                }
                finally { gate.Release(); }
            }

            // 2. the channel
            string channelId;
            string cjson = ChannelBody(name, membership, tm.Note, membership == "standard" ? null : owner);
            if (membership != "standard" && owner == null) throw new FatalConversation("A private or shared channel needs an owner.");
            try
            {
                Count(EndpointClass.Channels);
                using (var doc = await SendJson(HttpMethod.Post, "v1.0/teams/" + Uri.EscapeDataString(teamId) + "/channels", cjson, EndpointClass.Channels, null, ct).ConfigureAwait(false))
                    channelId = doc == null ? null : Str(doc.RootElement, "id");
                Interlocked.Increment(ref _channelsCreated);
            }
            catch (GraphException ex) when (ex.StatusCode == 409)
            {
                channelId = await FindChannelByNameAsync(teamId, name, ct).ConfigureAwait(false);   // created by an earlier, interrupted run
            }
            if (string.IsNullOrEmpty(channelId)) throw new FatalConversation("The channel '" + name + "' could not be created or found.");
            tm.TargetTeamId = teamId; tm.TargetChannelId = channelId; tm.State = TargetState.Created;
            _targets.Upsert(tm);

            // 3. the channel members (private / shared only: a standard channel shows the team members, added with the team above). Best effort.
            foreach (var mid in membership == "standard" ? new List<string>() : members)
            {
                if (string.Equals(mid, owner, StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    string mj = MemberBody(mid);
                    string url = "v1.0/teams/" + Uri.EscapeDataString(teamId) + "/channels/" + Uri.EscapeDataString(channelId) + "/members";
                    string cls = EndpointClass.ChannelMembers;
                    Count(cls);
                    using (await SendJson(HttpMethod.Post, url, mj, cls, null, ct).ConfigureAwait(false)) { }
                }
                catch (GraphException ex) when (ex.StatusCode != 409 && ex.StatusCode != 429 && ex.StatusCode < 500) { _warnings.Enqueue("Member " + mid + " not added to '" + name + "': " + ex.ErrorCode + " (" + ex.StatusCode + ")"); }
                catch (GraphException ex) when (ex.StatusCode == 409) { }
            }
            return new TargetThread { TeamId = teamId, ChannelId = channelId };
        }

        private readonly ConcurrentDictionary<string, bool> _teamPopulated = new ConcurrentDictionary<string, bool>(StringComparer.Ordinal);

        /// <summary>Adds every planned member of every channel of a team the import created to the TEAM (the service account is the owner already; 409 = already a member). Best effort.</summary>
        private async Task AddTeamMembersAsync(string teamId, List<string> members, string owner, string teamName, CancellationToken ct)
        {
            foreach (var mid in members)
            {
                if (string.Equals(mid, owner, StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    Count(EndpointClass.Teams);
                    using (await SendJson(HttpMethod.Post, "v1.0/teams/" + Uri.EscapeDataString(teamId) + "/members", MemberBody(mid), EndpointClass.Teams, null, ct).ConfigureAwait(false)) { }
                }
                catch (GraphException ex) when (ex.StatusCode == 409) { }
                catch (GraphException ex) when (ex.StatusCode != 429 && ex.StatusCode < 500) { _warnings.Enqueue("Member " + mid + " not added to the team '" + teamName + "': " + ex.ErrorCode + " (" + ex.StatusCode + ")"); }
            }
        }

        private static string MemberBody(string userId)
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms)) WriteMember(w, userId, false, false);
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        internal static string ChannelBody(string name, string membership, string description, string owner)
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("displayName", name);
                    w.WriteString("description", string.IsNullOrEmpty(description) ? "Imported by TeamsTransfer" : description);
                    w.WriteString("membershipType", membership);
                    if (owner != null) { w.WriteStartArray("members"); WriteMember(w, owner, true, false); w.WriteEndArray(); }
                    w.WriteEndObject();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        /// <summary>Id of the target team with exactly this display name, or null (GET /teams with a displayName filter: Team.ReadBasic.All).</summary>
        private async Task<string> FindTeamByNameAsync(string name, CancellationToken ct)
        {
            string url = "v1.0/teams?$filter=" + Uri.EscapeDataString("displayName eq '" + name.Replace("'", "''") + "'") + "&$select=id,displayName";
            try
            {
                Count(EndpointClass.Teams);
                await foreach (var e in _client.GetPagedAsync(url, EndpointClass.Teams, null, null, null, ct).ConfigureAwait(false))
                    if (string.Equals(Str(e, "displayName"), name, StringComparison.OrdinalIgnoreCase)) return Str(e, "id");
            }
            catch (GraphException ex) when (ex.StatusCode == 400 || ex.StatusCode == 404) { }   // offline fakes without the filter: fall back to creating
            return null;
        }

        private async Task<string> CreateTeamAsync(string name, string ownerId, CancellationToken ct)
        {
            string json;
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("template@odata.bind", "https://graph.microsoft.com/v1.0/teamsTemplates('standard')");
                    w.WriteString("displayName", name);
                    w.WriteString("description", "Imported by TeamsTransfer");
                    w.WriteStartArray("members"); WriteMember(w, ownerId, true, false); w.WriteEndArray();   // one member at creation
                    w.WriteEndObject();
                }
                json = Encoding.UTF8.GetString(ms.ToArray());
            }
            Count(EndpointClass.Teams);
            string teamId = null;
            var req = new GraphRequest { Method = HttpMethod.Post, Url = "v1.0/teams", BodyJson = json, EndpointClass = EndpointClass.Teams };
            try
            {
                using (var resp = await _client.SendAsync(req, ct).ConfigureAwait(false))
                {
                    string loc;
                    if (resp.Headers.TryGetValue("Content-Location", out loc) || resp.Headers.TryGetValue("Location", out loc))
                    {
                        var m = Regex.Match(loc ?? "", @"teams\('([^']+)'\)", RegexOptions.IgnoreCase);
                        if (m.Success) teamId = m.Groups[1].Value;
                    }
                }
            }
            catch (GraphException ex) { Tally(ex); throw; }
            if (teamId == null) throw new FatalConversation("POST /teams returned no team id (no Content-Location header).");
            Interlocked.Increment(ref _teamsCreated);
            // the team is provisioned asynchronously: wait until it can be read
            for (int a = 1; ; a++)
            {
                try
                {
                    Count(EndpointClass.Teams);
                    using (await SendJson(HttpMethod.Get, "v1.0/teams/" + Uri.EscapeDataString(teamId), null, EndpointClass.Teams, null, ct).ConfigureAwait(false)) { }
                    break;
                }
                catch (GraphException ex) when ((ex.StatusCode == 404 || ex.StatusCode == 403) && a < Tuning.PollMaxAttempts) { await Delay(Backoff(a, Tuning.PollBaseDelay, Tuning.PollMaxDelay), ct).ConfigureAwait(false); }
            }
            return teamId;
        }

        private async Task<string> FindChannelByNameAsync(string teamId, string name, CancellationToken ct)
        {
            Count(EndpointClass.Channels);
            using (var doc = await SendJson(HttpMethod.Get, "v1.0/teams/" + Uri.EscapeDataString(teamId) + "/channels", null, EndpointClass.Channels, null, ct).ConfigureAwait(false))
            {
                JsonElement arr;
                if (doc != null && doc.RootElement.TryGetProperty("value", out arr) && arr.ValueKind == JsonValueKind.Array)
                    foreach (var c in arr.EnumerateArray())
                        if (string.Equals(Str(c, "displayName"), name, StringComparison.OrdinalIgnoreCase)) return Str(c, "id");
            }
            return null;
        }

        // ------------------------------------------------------------------------------------------ migration lifecycle
        private sealed class ThreadInfo { public string Mode; public DateTimeOffset? Created; }

        private async Task<ThreadInfo> GetInfoAsync(TargetThread t, CancellationToken ct)
        {
            Count(t.InfoClass);
            using (var doc = await SendJson(HttpMethod.Get, t.Base, null, t.InfoClass, null, ct).ConfigureAwait(false))
            {
                if (doc == null) return new ThreadInfo();
                return new ThreadInfo { Mode = Str(doc.RootElement, "migrationMode"), Created = ParseDate(Str(doc.RootElement, "createdDateTime")) };
            }
        }

        private static string Iso(DateTimeOffset d) { return d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture); }
        private static string IsoMs(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture); }
        private static DateTimeOffset FloorMs(DateTimeOffset d) { return DateTimeOffset.FromUnixTimeMilliseconds(d.ToUnixTimeMilliseconds()); }

        /// <summary>Begins or resumes the session and brings the thread to migrationMode = inProgress. Returns the journal session id.</summary>
        private async Task<long> OpenSessionAsync(LotItem item, TargetThread thread, ImportSession latest, DateTimeOffset? oldest, CancellationToken ct)
        {
            var key = item.ConversationKey;
            var info = await GetInfoAsync(thread, ct).ConfigureAwait(false);
            var now = DateTimeOffset.UtcNow;
            var current = info.Created ?? now;

            if (latest != null && latest.State == ImportSessionState.Started)
            {
                if (latest.AppId != _appId) throw new FatalConversation("The migration session of this conversation was started by another application (" + latest.AppId + "): only that application can import into it and complete it.");
                if (string.Equals(info.Mode, "inProgress", StringComparison.OrdinalIgnoreCase)) return latest.Id;        // resume: nothing to start
                if (latest.ConversationCreationUtc < current)
                {
                    // our startMigration may not have run (or is not visible yet): send it again with the journaled date
                    await StartAndWaitAsync(thread, latest.ConversationCreationUtc, ct).ConfigureAwait(false);
                    return latest.Id;
                }
                // The thread is already at or before that date: our startMigration was executed, but the state is not readable yet
                // (eventual consistency) or the session was completed. Wait for the state before deciding.
                string settled = null;
                for (int a = 1; a <= Tuning.PollMaxAttempts; a++)
                {
                    if (a > 1) await Delay(Backoff(a - 1, Tuning.PollBaseDelay, Tuning.PollMaxDelay), ct).ConfigureAwait(false);
                    var again = await GetInfoAsync(thread, ct).ConfigureAwait(false);
                    if (string.Equals(again.Mode, "inProgress", StringComparison.OrdinalIgnoreCase)) return latest.Id;
                    if (string.Equals(again.Mode, "completed", StringComparison.OrdinalIgnoreCase)) { settled = "completed"; info = again; current = again.Created ?? now; break; }
                }
                if (settled == null) throw new TransientConversation("migrationMode is still not readable after the session was started: the service has not converged yet, the next run resumes.");
                _store.CompleteImportSession(latest.Id, ImportSessionState.Completed, "Closed on resume: the migration was completed; a new wave follows");
            }

            if (string.Equals(info.Mode, "inProgress", StringComparison.OrdinalIgnoreCase))
            {
                // already in migration mode with no session of ours: adopt it when its creation date is old enough
                if (oldest.HasValue && info.Created.HasValue && oldest.Value < info.Created.Value)
                    throw new FatalConversation("The thread is already in migration mode with a creation date (" + Iso(info.Created.Value) + ") later than the oldest message (" + Iso(oldest.Value) + ").");
                return _store.BeginImportSession(key, item.SliceNo, _appId, info.Created ?? now, thread.Id);
            }

            var basis = oldest.HasValue && oldest.Value < current ? oldest.Value : current;
            var creation = FloorMs(basis).AddSeconds(-1);
            long sid = _store.BeginImportSession(key, item.SliceNo, _appId, creation, thread.Id);
            await StartAndWaitAsync(thread, creation, ct).ConfigureAwait(false);
            return sid;
        }

        private async Task StartAndWaitAsync(TargetThread t, DateTimeOffset creation, CancellationToken ct)
        {
            string json = "{\"conversationCreationDateTime\":\"" + Iso(creation) + "\"}";
            try
            {
                Count(EndpointClass.MigrationStart);
                using (await SendJson(HttpMethod.Post, t.Base + "/startMigration", json, EndpointClass.MigrationStart, null, ct).ConfigureAwait(false)) { }
            }
            catch (GraphException ex) when (ex.StatusCode == 400)
            {
                // "already in migration mode" / a date that is no longer earlier: acceptable when the thread reads inProgress
                var info = await GetInfoAsync(t, ct).ConfigureAwait(false);
                if (!string.Equals(info.Mode, "inProgress", StringComparison.OrdinalIgnoreCase)) throw new FatalConversation("startMigration refused: " + ex.ErrorCode + " " + ex.Message, ex);
            }
            catch (GraphException ex) when (ex.StatusCode == 403 || ex.StatusCode == 404) { throw new FatalConversation("startMigration refused (" + ex.StatusCode + "): " + ex.ErrorCode, ex); }
            for (int a = 1; ; a++)
            {
                var info = await GetInfoAsync(t, ct).ConfigureAwait(false);
                if (string.Equals(info.Mode, "inProgress", StringComparison.OrdinalIgnoreCase)) return;
                if (a >= Tuning.PollMaxAttempts) throw new TransientConversation("migrationMode is still '" + (info.Mode ?? "none") + "' after " + a + " reads: the service has not converged yet, the next run resumes.");
                await Delay(Backoff(a, Tuning.PollBaseDelay, Tuning.PollMaxDelay), ct).ConfigureAwait(false);
            }
        }

        private async Task FinishMigrationAsync(TargetThread t, long sessionId, string key, CancellationToken ct)
        {
            bool done = false;
            for (int a = 1; !done; a++)
            {
                try
                {
                    Count(EndpointClass.MigrationComplete);
                    using (await SendJson(HttpMethod.Post, t.Base + "/completeMigration", null, EndpointClass.MigrationComplete, null, ct).ConfigureAwait(false)) { }
                    done = true;
                }
                catch (GraphException ex) when (ex.StatusCode == 400 || ex.StatusCode == 409)
                {
                    // eventual consistency ("not in migration mode") or an answer lost after a success: read the state
                    var info = await GetInfoAsync(t, ct).ConfigureAwait(false);
                    if (string.Equals(info.Mode, "completed", StringComparison.OrdinalIgnoreCase)) { done = true; break; }
                    if (a >= Tuning.CompleteMaxAttempts) throw new UncertainConversation("completeMigration still refused after " + a + " attempts (" + ex.Message + "): the thread stays in migration mode, run the import again.");
                    await Delay(Backoff(a, Tuning.CompleteBaseDelay, Tuning.CompleteMaxDelay), ct).ConfigureAwait(false);
                }
                catch (GraphException ex) when (ex.StatusCode == 403 || ex.StatusCode == 404) { throw new FatalConversation("completeMigration refused (" + ex.StatusCode + "): " + ex.ErrorCode, ex); }
            }
            for (int a = 1; ; a++)
            {
                var info = await GetInfoAsync(t, ct).ConfigureAwait(false);
                if (string.Equals(info.Mode, "completed", StringComparison.OrdinalIgnoreCase)) break;
                if (a >= Tuning.VerifyMaxAttempts) throw new UncertainConversation("completeMigration was accepted but migrationMode reads '" + (info.Mode ?? "none") + "' after " + a + " reads.");
                await Delay(Backoff(a, Tuning.PollBaseDelay, Tuning.PollMaxDelay), ct).ConfigureAwait(false);
            }
            _store.CompleteImportSession(sessionId, ImportSessionState.Completed);
        }

        private static TimeSpan Backoff(int attempt, TimeSpan b, TimeSpan max)
        {
            double s = b.TotalSeconds * Math.Pow(2, Math.Min(20, Math.Max(0, attempt - 1)));
            return TimeSpan.FromSeconds(Math.Min(max.TotalSeconds, s));
        }

        private Task Delay(TimeSpan d, CancellationToken ct) { return (Tuning.Clock ?? SystemClock.Instance).DelayAsync(d, ct); }

        // ------------------------------------------------------------------------------------------ graph calls
        private void Count(string cls) { _byClass.AddOrUpdate(cls, 1, (k, v) => v + 1); }

        private void Tally(GraphException ex)
        {
            if (ex.StatusCode == 400) Interlocked.Increment(ref _s400);
            else if (ex.StatusCode == 403) Interlocked.Increment(ref _s403);
            else if (ex.StatusCode == 409) Interlocked.Increment(ref _s409);
            else if (ex.StatusCode == 404) Interlocked.Increment(ref _s404);
        }

        private async Task<JsonDocument> SendJson(HttpMethod method, string url, string json, string cls, string threadKey, CancellationToken ct)
        {
            var req = new GraphRequest { Method = method, Url = url, BodyJson = json, EndpointClass = cls, ThreadKey = threadKey };
            try { return await _client.SendJsonAsync(req, ct).ConfigureAwait(false); }
            catch (GraphException ex) { Tally(ex); throw; }
        }

        // ------------------------------------------------------------------------------------------ dates
        /// <summary>
        /// Unique createdDateTime per thread at millisecond precision, a pure function of the slice order: the next message of the
        /// thread gets max(its own date, previous assigned + 1 ms). A reply is unique per root and strictly after it. Recomputed
        /// identically by a resumed run (it walks every message of the slice, imported or not).
        /// </summary>
        /// <summary>The target id of a channel root, shared with its replies (a reply is sent only after its root's id is known).</summary>
        private sealed class RootHolder { public string Id; public volatile string Target; public Task Done; }

        private sealed class DateScope
        {
            public bool Channel;
            long _lastRoot = long.MinValue, _lastReply = long.MinValue, _curRootAssigned;
            public RootHolder Cur;
            public long Assign(long createdMs, string id, string replyTo, out bool isReply)
            {
                isReply = Channel && !string.IsNullOrEmpty(replyTo);
                long a;
                if (!isReply)
                {
                    a = createdMs > _lastRoot ? createdMs : _lastRoot + 1;
                    _lastRoot = a;
                    if (Channel) { Cur = new RootHolder { Id = id }; _curRootAssigned = a; _lastReply = a; }
                }
                else if (Cur != null && replyTo == Cur.Id)
                {
                    long floor = Math.Max(_lastReply + 1, _curRootAssigned + 1);
                    a = createdMs >= floor ? createdMs : floor;
                    _lastReply = a;
                }
                else a = createdMs;
                return a;
            }
        }
        // ------------------------------------------------------------------------------------------ the import loop
        private async Task<bool> ImportPendingAsync(LotItem item, TargetThread thread, long sessionId, ItemCounters c, CancellationToken ct)
        {
            var key = item.ConversationKey;
            bool channelConv = key.StartsWith("channel:", StringComparison.Ordinal);
            int maxInFlight = Math.Max(1, Tuning.InFlightPerConversation);
            var inflight = new List<Task<bool>>();
            using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                try
                {
                    return await ImportPassesAsync(item, thread, sessionId, c, key, channelConv, maxInFlight, inflight, cts.Token).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    cts.Cancel();                                                   // the other in-flight sends stop; their messages stay Pending (or 409 on resume)
                    try { await Task.WhenAll(inflight.ToArray()).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
            }
        }

        /// <summary>Waits until at most `keep` sends are in flight. True when one of the finished sends moved its message out of Pending. A failed send throws.</summary>
        private static async Task<bool> DrainAsync(List<Task<bool>> list, int keep)
        {
            bool any = false;
            while (list.Count > keep)
            {
                var t = await Task.WhenAny(list).ConfigureAwait(false);
                list.Remove(t);
                if (await t.ConfigureAwait(false)) any = true;
            }
            return any;
        }

        private async Task<bool> ImportPassesAsync(LotItem item, TargetThread thread, long sessionId, ItemCounters c, string key, bool channelConv, int maxInFlight, List<Task<bool>> inflight, CancellationToken ct)
        {
            while (true)
            {
                var batch = new Dictionary<string, JournalEntry>(StringComparer.Ordinal);
                Refill(batch, key, item.SliceNo);
                if (batch.Count == 0) return false;
                bool progressed = false;
                var scope = new DateScope { Channel = channelConv };
                foreach (var m in _reader.ReadMessages(key, item.FromUtc, item.ToUtc))
                {
                    string id = Str(m, "id");
                    if (id == null) continue;
                    var created = ParseDate(Str(m, "createdDateTime"));
                    bool isReply;
                    long assigned = scope.Assign(created.HasValue ? created.Value.ToUnixTimeMilliseconds() : 0, id, ReplyTo(m), out isReply);   // dates are fixed here, in stream order: the order of completion does not matter
                    JournalEntry entry;
                    if (!batch.TryGetValue(id, out entry))
                    {
                        if (batch.Count > 0) continue;
                        if (await DrainAsync(inflight, 0).ConfigureAwait(false)) progressed = true;                // the in-flight messages must be journaled before the next NextPending
                        Refill(batch, key, item.SliceNo);
                        if (!batch.TryGetValue(id, out entry)) continue;
                    }
                    if (StopControl.Stopped(_o.Stop)) { await DrainAsync(inflight, 0).ConfigureAwait(false); _stopped = true; return true; }
                    ct.ThrowIfCancellationRequested();
                    long shift = created.HasValue ? assigned - created.Value.ToUnixTimeMilliseconds() : 0;
                    RootHolder holder = null;
                    if (channelConv)
                    {
                        if (isReply)
                        {
                            holder = scope.Cur != null && scope.Cur.Id == ReplyTo(m) ? scope.Cur : null;
                            if (holder != null && holder.Done != null && !holder.Done.IsCompleted)
                                if (await DrainAsync(inflight, 0).ConfigureAwait(false)) progressed = true;       // a reply waits for its root's target id
                        }
                        else holder = scope.Cur;
                    }
                    batch.Remove(id);
                    if (await DrainAsync(inflight, maxInFlight - 1).ConfigureAwait(false)) progressed = true;
                    var task = ProcessMessageAsync(m, entry, item, thread, sessionId, holder, assigned, shift, isReply, c, ct);
                    if (!isReply && holder != null) holder.Done = task;
                    inflight.Add(task);
                }
                if (await DrainAsync(inflight, 0).ConfigureAwait(false)) progressed = true;
                if (!progressed) return false;
            }
        }
        private void Refill(Dictionary<string, JournalEntry> batch, string key, int slice)
        {
            foreach (var e in _store.NextPending(key, slice, Math.Max(1, Tuning.BatchSize))) batch[e.SourceMessageId] = e;
        }

        private static string ReplyTo(JsonElement m) { return Str(m, "replyToId"); }

        private void Mark(string key, int slice, string srcId, JournalStatus status, string targetId, string code, long sessionId)
        {
            _store.MarkJournal(new JournalMark { ConversationKey = key, SliceNo = slice, SourceMessageId = srcId, Status = status, TargetMessageId = targetId, ErrorCode = code, SessionId = sessionId });
        }

        /// <summary>Returns true when the message left the Pending state.</summary>
        private async Task<bool> ProcessMessageAsync(JsonElement m, JournalEntry entry, LotItem item, TargetThread thread, long sessionId, RootHolder holder,
            long assignedMs, long shiftMs, bool isReply, ItemCounters c, CancellationToken ct)
        {
            var key = item.ConversationKey; int slice = item.SliceNo; string id = entry.SourceMessageId;
            string type = Str(m, "messageType") ?? "message";
            if (!string.Equals(type, "message", StringComparison.OrdinalIgnoreCase))
            {
                Mark(key, slice, id, JournalStatus.Skipped, null, "SystemEvent:" + type, sessionId); Interlocked.Increment(ref _skipped); Interlocked.Increment(ref c.Skipped); return true;
            }
            string del = Str(m, "deletedDateTime");
            if (!string.IsNullOrEmpty(del)) { Mark(key, slice, id, JournalStatus.Skipped, null, "Deleted", sessionId); Interlocked.Increment(ref _skipped); Interlocked.Increment(ref c.Skipped); return true; }

            string rootTarget = null;
            if (isReply)
            {
                string rootId = ReplyTo(m);
                if (holder != null && holder.Target != null) rootTarget = holder.Target;
                else
                {
                    var root = _store.GetJournalEntry(key, rootId);
                    if (root == null) { Mark(key, slice, id, JournalStatus.Rejected, null, "RootMissing", sessionId); Interlocked.Increment(ref _rejected); Interlocked.Increment(ref c.Rejected); return true; }
                    if (root.Status == JournalStatus.Pending) return false;                       // root not processed yet (another fragment): wait
                    if (root.Status == JournalStatus.Skipped) { Mark(key, slice, id, JournalStatus.Skipped, null, "RootSkipped", sessionId); Interlocked.Increment(ref _skipped); Interlocked.Increment(ref c.Skipped); return true; }
                    if (root.Status == JournalStatus.Rejected) { Mark(key, slice, id, JournalStatus.Rejected, null, "RootRejected", sessionId); Interlocked.Increment(ref _rejected); Interlocked.Increment(ref c.Rejected); return true; }
                    rootTarget = root.TargetMessageId;
                    if (string.IsNullOrEmpty(rootTarget)) rootTarget = await ResolveRootIdAsync(thread, assignedRootGuess: null, rootSource: root, ct: ct).ConfigureAwait(false);
                    if (holder != null) holder.Target = rootTarget ?? "";      // "" = looked for, not found: the other replies do not look again
                }
                if (string.IsNullOrEmpty(rootTarget)) { Mark(key, slice, id, JournalStatus.Rejected, null, "RootTargetUnknown", sessionId); Interlocked.Increment(ref _rejected); Interlocked.Increment(ref c.Rejected); return true; }
            }

            var built = BuildMessage(m, key, id, assignedMs, false);
            if (built.Reject != null)
            {
                Mark(key, slice, id, JournalStatus.Rejected, null, built.Reject, sessionId); Interlocked.Increment(ref _rejected); Interlocked.Increment(ref c.Rejected); return true;
            }
            foreach (var n in built.Notes) _dropped.AddOrUpdate(n, 1, (k, v) => v + 1);
            string url = thread.Base + (isReply ? "/messages/" + Uri.EscapeDataString(rootTarget) + "/replies" : "/messages");
            string notes = built.Notes.Count > 0 ? string.Join(";", built.Notes.Distinct()) : null;
            if (shiftMs != 0) { notes = (notes == null ? "" : notes + ";") + "shift+" + shiftMs + "ms"; Interlocked.Increment(ref _shifts); }
            if (notes != null && notes.Length > 240) notes = notes.Substring(0, 240);

            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    Count(EndpointClass.ImportMessage);
                    using (var doc = await SendJson(HttpMethod.Post, url, built.Json, EndpointClass.ImportMessage, thread.ThreadKey, ct).ConfigureAwait(false))
                    {
                        string tid = doc == null ? null : Str(doc.RootElement, "id");
                        Mark(key, slice, id, JournalStatus.Imported, tid, notes, sessionId);
                        Interlocked.Increment(ref _imported); Interlocked.Increment(ref c.Imported);
                        if (!isReply && holder != null && !thread.IsChat) holder.Target = tid;
                        return true;
                    }
                }
                catch (GraphException ex)
                {
                    if (ex.StatusCode == 409)
                    {
                        string tid = null;
                        if (!isReply && !thread.IsChat) { tid = await ResolveRootIdAsync(thread, assignedMs, null, ct).ConfigureAwait(false); if (holder != null) holder.Target = tid ?? ""; }
                        Mark(key, slice, id, JournalStatus.Conflict409TreatedAsImported, tid, notes, sessionId);
                        Interlocked.Increment(ref _conflicts); Interlocked.Increment(ref c.Conflicts);
                        return true;
                    }
                    bool transient = ex.StatusCode == 0 || ex.StatusCode == 429 || ex.StatusCode >= 500;
                    if (transient)
                    {
                        if (attempt >= Tuning.TransientMessageAttempts) throw new TransientConversation("The service keeps failing (" + ex.StatusCode + " " + ex.ErrorCode + ") on message " + id + ": the next run resumes.", ex);
                        await Delay(Tuning.TransientDelay, ct).ConfigureAwait(false);
                        continue;
                    }
                    bool suspect = ex.StatusCode == 401 || ex.StatusCode == 404 || ex.StatusCode == 403 ||
                                   (ex.StatusCode == 400 && Regex.IsMatch(ex.Message ?? "", "migration|completed", RegexOptions.IgnoreCase)) ||
                                   Regex.IsMatch(ex.Message ?? "", "another application", RegexOptions.IgnoreCase);
                    if (suspect)
                    {
                        // a conversation-level refusal must not turn every message into a Rejected one
                        var info = await GetInfoAsync(thread, ct).ConfigureAwait(false);
                        if (!string.Equals(info.Mode, "inProgress", StringComparison.OrdinalIgnoreCase) || ex.StatusCode == 401 || ex.StatusCode == 404 || Regex.IsMatch(ex.Message ?? "", "another application", RegexOptions.IgnoreCase))
                            throw new FatalConversation("The conversation refuses the import (" + ex.StatusCode + " " + ex.ErrorCode + "; migrationMode " + (info.Mode ?? "none") + "): " + ex.Message, ex);
                    }
                    string code = ex.StatusCode.ToString(CultureInfo.InvariantCulture) + " " + ex.ErrorCode + ": " + Shorten(ex.Message, 160);
                    Mark(key, slice, id, JournalStatus.Rejected, null, code, sessionId);
                    Interlocked.Increment(ref _rejected); Interlocked.Increment(ref c.Rejected);
                    return true;
                }
            }
        }

        private static string Shorten(string s, int n)
        {
            if (s == null) return "";
            s = Regex.Replace(s, @"^Graph \d+ \w+: ", "");
            int i = s.IndexOf(" (url:", StringComparison.Ordinal);
            if (i > 0) s = s.Substring(0, i);
            return s.Length > n ? s.Substring(0, n) : s;
        }

        /// <summary>The target id of a channel root known only by its date (after a 409): ids are the epoch milliseconds of createdDateTime.</summary>
        private async Task<string> ResolveRootIdAsync(TargetThread thread, long? assignedRootGuess, JournalEntry rootSource, CancellationToken ct)
        {
            if (thread.IsChat) return null;
            long ms;
            if (assignedRootGuess.HasValue) ms = assignedRootGuess.Value;
            else
            {
                // the root was a 409 in an earlier run and its id was not recorded: recompute its date from the store
                var mj = FindMessage(rootSource.ConversationKey, rootSource.SourceMessageId);
                if (mj == null) return null;
                var d = ParseDate(Str(mj.Value, "createdDateTime"));
                if (!d.HasValue) return null;
                ms = d.Value.ToUnixTimeMilliseconds();
            }
            string guess = ms.ToString(CultureInfo.InvariantCulture);
            try
            {
                Count(EndpointClass.ChannelMessages);
                using (var doc = await SendJson(HttpMethod.Get, thread.Base + "/messages/" + guess, null, EndpointClass.ChannelMessages, null, ct).ConfigureAwait(false))
                    return doc == null ? null : (Str(doc.RootElement, "id") ?? guess);
            }
            catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 400) { return null; }
        }

        private JsonElement? FindMessage(string key, string id)
        {
            foreach (var m in _reader.ReadMessages(key)) if (Str(m, "id") == id) return m;
            return null;
        }

        // ------------------------------------------------------------------------------------------ building a message
        internal sealed class BuiltMessage
        {
            public string Json, Reject;
            public List<string> Notes = new List<string>();
            public int Hosted, Mentions, Reactions, Attachments;
        }

        private static readonly Regex HostedImg = new Regex(@"<img\b[^>]*?\bsrc=(?<q>[""'])(?<url>[^""']*?/hostedContents/(?<id>[^/""']+)/\$value)\k<q>[^>]*>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private IdentityMapping Identity(string sourceId)
        {
            if (string.IsNullOrEmpty(sourceId)) return null;
            IdentityMapping im;
            if (_idCache.TryGetValue(sourceId, out im)) return im;
            im = _identities.Get(sourceId);
            if (im != null) _idCache[sourceId] = im;
            return im;
        }

        private static bool IsRealUser(IdentityMapping im)
        {
            return im != null && !string.IsNullOrEmpty(im.TargetUserId) && (im.Kind == IdentityKind.Mapped || im.Kind == IdentityKind.Same || im.Kind == IdentityKind.Ghost);
        }

        private static string ImageType(byte[] b)
        {
            if (b.Length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return "image/png";
            if (b.Length > 3 && b[0] == 0xFF && b[1] == 0xD8) return "image/jpeg";
            if (b.Length > 5 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return "image/gif";
            if (b.Length > 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' && b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') return "image/webp";
            if (b.Length > 2 && b[0] == 'B' && b[1] == 'M') return "image/bmp";
            return "image/png";
        }

        private static void EnsureHtml(ref string contentType, ref string content)
        {
            if (string.Equals(contentType, "html", StringComparison.OrdinalIgnoreCase)) return;
            content = "<p>" + WebUtility.HtmlEncode(content ?? "").Replace("\r\n", "<br>").Replace("\n", "<br>") + "</p>";
            contentType = "html";
        }

        /// <summary>
        /// Builds the POST body of one message: mapped author (service account + banner when the author fell back), body as exported with
        /// the inline images re-attached (hostedContents + temporaryId, src rewritten), mentions and reactions mapped, reference
        /// attachments pointed to the copied file. What cannot be imported is dropped and named in Notes. Reject = the message cannot be
        /// sent at all (no usable author): nothing is sent. dryRun = no image bytes are read.
        /// </summary>
        internal BuiltMessage BuildMessage(JsonElement m, string key, string srcId, long assignedMs, bool dryRun)
        {
            var b = new BuiltMessage();
            // --- author
            string srcUserId = null, srcName = null, appName = null;
            JsonElement from, u;
            if (m.TryGetProperty("from", out from) && from.ValueKind == JsonValueKind.Object)
            {
                if (from.TryGetProperty("user", out u) && u.ValueKind == JsonValueKind.Object) { srcUserId = Str(u, "id"); srcName = Str(u, "displayName"); }
                else if (from.TryGetProperty("application", out u) && u.ValueKind == JsonValueKind.Object) appName = Str(u, "displayName") ?? "application";
            }
            string authorId = null, authorName = null; bool banner = false; string bannerName = null, bannerUpn = null;
            var im = Identity(srcUserId);
            if (IsRealUser(im)) { authorId = im.TargetUserId; authorName = im.TargetDisplayName ?? im.SourceDisplayName ?? srcName; }
            else if (im != null && im.Kind == IdentityKind.ServiceAccount)
            {
                authorId = !string.IsNullOrEmpty(im.TargetUserId) ? im.TargetUserId : _o.ServiceAccountUserId; authorName = im.TargetDisplayName;
                banner = true; bannerName = im.SourceDisplayName ?? srcName ?? srcUserId; bannerUpn = im.SourceUserPrincipalName ?? srcUserId;
            }
            else if (srcUserId == null && appName != null && !string.IsNullOrEmpty(_o.ServiceAccountUserId))
            {
                authorId = _o.ServiceAccountUserId; banner = true; bannerName = appName; bannerUpn = "application";
            }
            if (string.IsNullOrEmpty(authorId)) { b.Reject = srcUserId == null && appName == null ? "NoAuthor" : "IdentityUnresolved"; return b; }

            // --- body
            JsonElement body;
            string ctype = "html", content = "";
            if (m.TryGetProperty("body", out body) && body.ValueKind == JsonValueKind.Object) { ctype = Str(body, "contentType") ?? "html"; content = Str(body, "content") ?? ""; }
            var notesAtEnd = new StringBuilder();

            // attachments
            var keepAtt = new List<Tuple<string, string, string>>();   // id, url, name
            JsonElement atts;
            if (m.TryGetProperty("attachments", out atts) && atts.ValueKind == JsonValueKind.Array)
                foreach (var a in atts.EnumerateArray())
                {
                    string aid = Str(a, "id"), act = Str(a, "contentType"), aname = Str(a, "name");
                    bool kept = false;
                    if (string.Equals(act, "reference", StringComparison.OrdinalIgnoreCase) && aid != null)
                    {
                        var fr = _files.Get(key, srcId, aid);
                        if (fr != null && (fr.State == FileCopyState.Uploaded || fr.State == FileCopyState.Shared) && !string.IsNullOrEmpty(fr.TargetWebUrl))
                        {
                            // the migration API wants a GUID as attachment id (real 400 "Invalid GUID 'a1' for file attachment"): a source id that is
                            // not one becomes a deterministic GUID, and the <attachment id=...> tag of the body follows
                            string wid = AttachmentGuid(aid);
                            if (!string.Equals(wid, aid, StringComparison.Ordinal))
                                content = Regex.Replace(content, @"(<attachment\s+id=)([""'])" + Regex.Escape(aid) + @"\2", "${1}${2}" + wid + "${2}", RegexOptions.IgnoreCase);
                            keepAtt.Add(Tuple.Create(wid, fr.TargetWebUrl, aname ?? fr.Name)); kept = true;
                        }
                        else
                        {
                            b.Notes.Add("AttachmentNotCopied");
                            EnsureHtml(ref ctype, ref content);
                            notesAtEnd.Append("<p><em>[Attachment not copied: ").Append(WebUtility.HtmlEncode(aname ?? (fr != null ? fr.Name : null) ?? "file")).Append("]</em></p>");
                        }
                    }
                    else b.Notes.Add("AttachmentTypeUnsupported:" + (act ?? "unknown"));
                    if (!kept && aid != null)
                        content = Regex.Replace(content, @"<attachment\s+id=([""'])" + Regex.Escape(aid) + @"\1\s*(?:/>|>\s*</attachment>)", "", RegexOptions.IgnoreCase);
                }
            b.Attachments = keepAtt.Count;

            // inline images
            var hosted = new List<Tuple<string, string, string>>();    // temporaryId, base64, contentType
            var hostedIds = new Dictionary<string, string>(StringComparer.Ordinal);
            if (content.IndexOf("hostedContents", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                content = HostedImg.Replace(content, mm =>
                {
                    string hid = mm.Groups["id"].Value;
                    string tmp;
                    if (hostedIds.TryGetValue(hid, out tmp)) return tmp == null ? "<em>[image not available]</em>" : mm.Value.Replace(mm.Groups["url"].Value, "../hostedContents/" + tmp + "/$value");
                    string sha = _reader.FindHostedContent(key, srcId, hid);
                    if (sha == null) { hostedIds[hid] = null; b.Notes.Add("HostedContentMissing"); return "<em>[image not available]</em>"; }
                    string b64 = ""; string mime = "image/png";
                    if (!dryRun)
                    {
                        try
                        {
                            using (var s = _reader.OpenContent(sha))
                            using (var ms = new System.IO.MemoryStream())
                            {
                                s.CopyTo(ms);
                                if (ms.Length > Tuning.MaxHostedContentBytes) { hostedIds[hid] = null; b.Notes.Add("HostedContentTooLarge"); return "<em>[image too large]</em>"; }
                                var bytes = ms.ToArray(); mime = ImageType(bytes); b64 = Convert.ToBase64String(bytes);
                            }
                        }
                        catch (Exception) { hostedIds[hid] = null; b.Notes.Add("HostedContentMissing"); return "<em>[image not available]</em>"; }
                    }
                    tmp = (hosted.Count + 1).ToString(CultureInfo.InvariantCulture);
                    hostedIds[hid] = tmp; hosted.Add(Tuple.Create(tmp, b64, mime));
                    return mm.Value.Replace(mm.Groups["url"].Value, "../hostedContents/" + tmp + "/$value");
                });
            }
            b.Hosted = hosted.Count;

            // mentions
            var keepMentions = new List<Tuple<int, string, string, string>>();   // id, text, target id, target name
            JsonElement ments;
            if (m.TryGetProperty("mentions", out ments) && ments.ValueKind == JsonValueKind.Array)
                foreach (var mn in ments.EnumerateArray())
                {
                    int mid = mn.TryGetProperty("id", out var idv) && idv.ValueKind == JsonValueKind.Number ? idv.GetInt32() : -1;
                    string text = Str(mn, "mentionText") ?? "";
                    JsonElement md, mu;
                    bool kept = false;
                    if (mn.TryGetProperty("mentioned", out md) && md.TryGetProperty("user", out mu) && mu.ValueKind == JsonValueKind.Object)
                    {
                        var mim = Identity(Str(mu, "id"));
                        if (IsRealUser(mim) && mid >= 0) { keepMentions.Add(Tuple.Create(mid, text, mim.TargetUserId, mim.TargetDisplayName ?? Str(mu, "displayName") ?? text)); kept = true; }
                        else b.Notes.Add("MentionUnmapped");
                    }
                    else b.Notes.Add("MentionTypeUnsupported");
                    if (!kept && mid >= 0)
                        content = Regex.Replace(content, @"<at\s+id=([""'])" + mid.ToString(CultureInfo.InvariantCulture) + @"\1\s*>(?<t>.*?)</at>", "${t}", RegexOptions.IgnoreCase | RegexOptions.Singleline);
                }
            b.Mentions = keepMentions.Count;

            // fallback author banner
            if (banner)
            {
                EnsureHtml(ref ctype, ref content);
                var when = DateTimeOffset.FromUnixTimeMilliseconds(assignedMs).UtcDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
                string head;
                try { head = string.Format(CultureInfo.InvariantCulture, _o.FallbackBannerFormat ?? "", WebUtility.HtmlEncode(bannerName ?? ""), WebUtility.HtmlEncode(bannerUpn ?? ""), when); }
                catch (FormatException) { head = "<p><em>Original message from " + WebUtility.HtmlEncode(bannerName ?? "") + "</em></p>"; }
                content = head + content;
            }
            if (notesAtEnd.Length > 0) content += notesAtEnd.ToString();

            // reactions
            var reactions = new List<Tuple<string, string, string, string>>();   // type, user id, name, created
            JsonElement rs;
            int unmappedReactions = 0;
            if (m.TryGetProperty("reactions", out rs) && rs.ValueKind == JsonValueKind.Array)
                foreach (var r in rs.EnumerateArray())
                {
                    string rtype = Str(r, "reactionType");
                    JsonElement ru, ruu;
                    string ruid = null, rname = null;
                    if (r.TryGetProperty("user", out ru) && ru.ValueKind == JsonValueKind.Object && ru.TryGetProperty("user", out ruu) && ruu.ValueKind == JsonValueKind.Object) { ruid = Str(ruu, "id"); rname = Str(ruu, "displayName"); }
                    var rim = Identity(ruid);
                    if (rtype == null || !IsRealUser(rim)) { unmappedReactions++; continue; }
                    var rc = ParseDate(Str(r, "createdDateTime"));
                    long rms = rc.HasValue ? Math.Max(rc.Value.ToUnixTimeMilliseconds(), assignedMs) : assignedMs;
                    reactions.Add(Tuple.Create(rtype, rim.TargetUserId, rim.TargetDisplayName ?? rname, IsoMs(rms)));
                }
            if (unmappedReactions > 0) b.Notes.Add("ReactionUnmapped");
            if (reactions.Count > Tuning.MaxReactions) { b.Notes.Add("ReactionsTruncated"); reactions.RemoveRange(Tuning.MaxReactions, reactions.Count - Tuning.MaxReactions); }
            b.Reactions = reactions.Count;

            // --- JSON
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("createdDateTime", IsoMs(assignedMs));
                    w.WriteStartObject("from"); w.WriteStartObject("user");
                    w.WriteString("id", authorId);
                    if (!string.IsNullOrEmpty(authorName)) w.WriteString("displayName", authorName);
                    w.WriteString("userIdentityType", "aadUser");
                    w.WriteEndObject(); w.WriteEndObject();
                    string subject = Str(m, "subject");
                    if (!string.IsNullOrEmpty(subject)) w.WriteString("subject", subject);
                    string imp = Str(m, "importance");
                    if (imp == "high" || imp == "urgent") w.WriteString("importance", imp);
                    w.WriteStartObject("body"); w.WriteString("contentType", ctype); w.WriteString("content", content); w.WriteEndObject();
                    if (keepAtt.Count > 0)
                    {
                        w.WriteStartArray("attachments");
                        foreach (var a in keepAtt) { w.WriteStartObject(); w.WriteString("id", a.Item1); w.WriteString("contentType", "reference"); w.WriteString("contentUrl", a.Item2); if (a.Item3 != null) w.WriteString("name", a.Item3); w.WriteEndObject(); }
                        w.WriteEndArray();
                    }
                    if (keepMentions.Count > 0)
                    {
                        w.WriteStartArray("mentions");
                        foreach (var mn in keepMentions)
                        {
                            w.WriteStartObject(); w.WriteNumber("id", mn.Item1); w.WriteString("mentionText", mn.Item2);
                            w.WriteStartObject("mentioned"); w.WriteStartObject("user"); w.WriteString("id", mn.Item3); w.WriteString("displayName", mn.Item4); w.WriteString("userIdentityType", "aadUser"); w.WriteEndObject(); w.WriteEndObject();
                            w.WriteEndObject();
                        }
                        w.WriteEndArray();
                    }
                    if (reactions.Count > 0)
                    {
                        w.WriteStartArray("reactions");
                        foreach (var r in reactions)
                        {
                            w.WriteStartObject(); w.WriteString("reactionType", r.Item1); w.WriteString("createdDateTime", r.Item4);
                            w.WriteStartObject("user"); w.WriteStartObject("user"); w.WriteString("id", r.Item2); if (!string.IsNullOrEmpty(r.Item3)) w.WriteString("displayName", r.Item3); w.WriteString("userIdentityType", "aadUser"); w.WriteEndObject(); w.WriteEndObject();
                            w.WriteEndObject();
                        }
                        w.WriteEndArray();
                    }
                    if (hosted.Count > 0)
                    {
                        w.WriteStartArray("hostedContents");
                        foreach (var h in hosted) { w.WriteStartObject(); w.WriteString("@microsoft.graph.temporaryId", h.Item1); w.WriteString("contentBytes", h.Item2); w.WriteString("contentType", h.Item3); w.WriteEndObject(); }
                        w.WriteEndArray();
                    }
                    w.WriteEndObject();
                }
                b.Json = Encoding.UTF8.GetString(ms.ToArray());
            }
            return b;
        }

        // ------------------------------------------------------------------------------------------ dry run
        private readonly object _dryLock = new object();


        private void Req(DryRunReport rep, ConversationEstimate est, string endpoint, long n = 1)
        {
            lock (_dryLock)
            {
                long v; rep.RequestsByEndpoint.TryGetValue(endpoint, out v); rep.RequestsByEndpoint[endpoint] = v + n; rep.TotalRequests += n;
            }
            if (est != null) est.Requests += n;
        }

        private async Task DryRunUnitAsync(Unit u, DryRunReport rep, CancellationToken ct)
        {
            foreach (var item in u.Items)
            {
                if (StopControl.Stopped(_o.Stop)) return;
                ct.ThrowIfCancellationRequested();
                var est = new ConversationEstimate { ConversationKey = item.ConversationKey, SliceNo = item.SliceNo };
                var st = new ConversationImportStat { ConversationKey = item.ConversationKey, SliceNo = item.SliceNo, Fragment = item.Fragment, State = "Planned" };
                var tm = _targets.Get(item.ConversationKey);
                if (tm == null) { est.TargetKind = "None"; st.State = "Failed"; st.Error = "No target mapping: run the planner."; _warnings.Enqueue(item.ConversationKey + ": no target mapping"); lock (_dryLock) rep.Conversations.Add(est); _stats.Add(st); Interlocked.Increment(ref _itemsDone); continue; }
                est.TargetKind = tm.Kind.ToString(); st.TargetKind = est.TargetKind;
                if (tm.Kind == TargetKind.Skip) { st.State = "Skipped"; st.Error = tm.Note; lock (_dryLock) rep.Conversations.Add(est); _stats.Add(st); Interlocked.Increment(ref _itemsDone); continue; }

                bool chat = item.ConversationKey.StartsWith("chat:", StringComparison.Ordinal);
                bool channelConv = !chat;
                string baseP = chat ? "/chats/{chatId}" : "/teams/{teamId}/channels/{channelId}";
                bool created = tm.State == TargetState.Created;
                var existing = ThreadFromMapping(tm);
                bool toCreate = (tm.Kind == TargetKind.NewChat || tm.Kind == TargetKind.NewChannel || tm.Kind == TargetKind.ArchiveChannel) && !(created && existing != null);
                if (tm.Kind == TargetKind.NewChat && toCreate) { Req(rep, est, "POST /chats"); lock (_dryLock) rep.ConversationsToCreate++; }
                if ((tm.Kind == TargetKind.NewChannel || tm.Kind == TargetKind.ArchiveChannel) && toCreate)
                {
                    if (string.IsNullOrEmpty(tm.TargetTeamId)) { Req(rep, est, "POST /teams"); Req(rep, est, "GET /teams/{teamId}"); }
                    Req(rep, est, "POST /teams/{teamId}/channels");
                    int extra = Math.Max(0, tm.TargetMemberIds.Count - 1);
                    if (extra > 0) Req(rep, est, (string.Equals(tm.CreateMembershipType, "private", StringComparison.OrdinalIgnoreCase) || string.Equals(tm.CreateMembershipType, "shared", StringComparison.OrdinalIgnoreCase)) ? "POST /teams/{teamId}/channels/{channelId}/members" : "POST /teams/{teamId}/members", extra);
                    lock (_dryLock) rep.ConversationsToCreate++;
                }
                if (tm.Kind == TargetKind.ExistingChat && string.IsNullOrEmpty(tm.TargetChatId)) _warnings.Enqueue(item.ConversationKey + ": ExistingChat without TargetChatId");
                if (tm.Kind == TargetKind.ExistingChannel && (string.IsNullOrEmpty(tm.TargetTeamId) || string.IsNullOrEmpty(tm.TargetChannelId))) _warnings.Enqueue(item.ConversationKey + ": ExistingChannel without target ids");

                // walk the slice exactly like the import does
                var summary = _store.GetJournalSummary(item.ConversationKey, item.SliceNo);
                bool journaled = summary.Values.Sum() > 0;
                var scope = new DateScope { Channel = channelConv };
                long pendingMsgs = 0;
                string endpointRoot = "POST " + baseP + "/messages", endpointReply = "POST " + baseP + "/messages/{messageId}/replies";
                foreach (var m in _reader.ReadMessages(item.ConversationKey, item.FromUtc, item.ToUtc))
                {
                    string id = Str(m, "id"); if (id == null) continue;
                    var cdt = ParseDate(Str(m, "createdDateTime"));
                    bool isReply;
                    long assigned = scope.Assign(cdt.HasValue ? cdt.Value.ToUnixTimeMilliseconds() : 0, id, ReplyTo(m), out isReply);
                    if (journaled)
                    {
                        var je = _store.GetJournalEntry(item.ConversationKey, id);
                        if (je != null && je.Status != JournalStatus.Pending) continue;
                    }
                    string type = Str(m, "messageType") ?? "message";
                    if (!string.Equals(type, "message", StringComparison.OrdinalIgnoreCase) || !string.IsNullOrEmpty(Str(m, "deletedDateTime")))
                    { est.Skipped++; lock (_dryLock) rep.MessagesSkipped++; continue; }
                    var built = BuildMessage(m, item.ConversationKey, id, assigned, true);
                    if (built.Reject != null) { est.Rejected++; lock (_dryLock) { rep.MessagesRejected++; long v; rep.DroppedByReason.TryGetValue("Rejected:" + built.Reject, out v); rep.DroppedByReason["Rejected:" + built.Reject] = v + 1; } continue; }
                    foreach (var n in built.Notes) lock (_dryLock) { long v; rep.DroppedByReason.TryGetValue(n, out v); rep.DroppedByReason[n] = v + 1; }
                    pendingMsgs++;
                    if (isReply) est.Replies++;
                    Req(rep, est, isReply ? endpointReply : endpointRoot);
                    lock (_dryLock) rep.MessagesToImport++;
                    lock (_dryLock)
                    {
                        if (rep.Samples.Count < Tuning.DryRunSamples)
                        {
                            string url = "v1.0" + (isReply ? endpointReply : endpointRoot).Substring(5);
                            rep.Samples.Add(new DryRunRequest { Method = "POST", Url = url, BodyJson = Redact(built.Json), ConversationKey = item.ConversationKey });
                        }
                    }
                }
                est.Messages = pendingMsgs;
                if (Tuning.CopyFilesInline)
                {
                    bool firstTime; lock (_dryLock) firstTime = _dryFilesSeen.Add(item.ConversationKey);
                    if (firstTime)
                    {
                        var todo = FilesToCopy(item.ConversationKey);
                        lock (_dryLock) { rep.FilesToCopy += todo.Count; rep.FileBytesToCopy += todo.Sum(f => f.Size ?? 0); }
                    }
                }
                if (pendingMsgs > 0)
                {
                    Req(rep, est, "POST " + baseP + "/startMigration");
                    Req(rep, est, "GET " + baseP, 2);   // poll until inProgress + verify after complete (at least)
                    Req(rep, est, "POST " + baseP + "/completeMigration");
                }
                est.EstimatedSeconds = pendingMsgs / Math.Max(0.1, _o.PerConversationRate) + (pendingMsgs > 0 ? 10 : 0);
                st.Pending = pendingMsgs;
                lock (_dryLock) rep.Conversations.Add(est);
                _stats.Add(st);
                Interlocked.Increment(ref _itemsDone); Interlocked.Increment(ref _convDone);
                await Task.Yield();
            }
        }

        private void FinishDryRun(DryRunReport rep)
        {
            rep.Conversations.Sort((a, b) => { int c = string.CompareOrdinal(a.ConversationKey, b.ConversationKey); return c != 0 ? c : a.SliceNo.CompareTo(b.SliceNo); });
            double total = rep.Conversations.Sum(c => (double)c.Messages);
            double longest = rep.Conversations.Count == 0 ? 0 : rep.Conversations.Max(c => c.EstimatedSeconds);
            double rate = Math.Min(Math.Max(1, _o.ConversationParallelism) * Math.Max(0.1, _o.PerConversationRate), Tuning.ApplicationRate);
            double byThroughput = total / Math.Max(0.1, rate);
            rep.EstimatedDuration = TimeSpan.FromSeconds(Math.Max(byThroughput, longest));
        }

        /// <summary>Removes text, names, urls and image bytes of a payload; keeps ids, dates and structure.</summary>
        internal static string Redact(string json)
        {
            var root = JsonNode.Parse(json);
            var body = root["body"] as JsonObject;
            if (body != null && body["content"] != null) body["content"] = "<redacted: " + (body["content"].GetValue<string>() ?? "").Length + " chars>";
            var fu = root["from"]?["user"] as JsonObject;
            if (fu != null && fu["displayName"] != null) fu["displayName"] = "<name>";
            if (root["subject"] != null) root["subject"] = "<subject>";
            var ms = root["mentions"] as JsonArray;
            if (ms != null) foreach (var x in ms.OfType<JsonObject>()) { x["mentionText"] = "<text>"; var mu = x["mentioned"]?["user"] as JsonObject; if (mu != null) mu["displayName"] = "<name>"; }
            var rs = root["reactions"] as JsonArray;
            if (rs != null) foreach (var x in rs.OfType<JsonObject>()) { var ru = x["user"]?["user"] as JsonObject; if (ru != null && ru["displayName"] != null) ru["displayName"] = "<name>"; }
            var hs = root["hostedContents"] as JsonArray;
            if (hs != null) foreach (var x in hs.OfType<JsonObject>()) x["contentBytes"] = "<image bytes>";
            var at = root["attachments"] as JsonArray;
            if (at != null) foreach (var x in at.OfType<JsonObject>()) { if (x["name"] != null) x["name"] = "<file name>"; if (x["contentUrl"] != null) x["contentUrl"] = "<url>"; }
            return root.ToJsonString();
        }

        /// <summary>The attachment id as the migration API wants it: the source id when it is a GUID, else a deterministic GUID derived from it (MD5 of the id).</summary>
        public static string AttachmentGuid(string sourceId)
        {
            Guid g;
            if (Guid.TryParse(sourceId, out g)) return sourceId;
            using (var md5 = System.Security.Cryptography.MD5.Create())
                return new Guid(md5.ComputeHash(Encoding.UTF8.GetBytes("tt-attachment:" + sourceId))).ToString();
        }
        // ------------------------------------------------------------------------------------------ small json helpers
        private static string Str(JsonElement e, string name)
        {
            JsonElement p;
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out p) && p.ValueKind == JsonValueKind.String) return p.GetString();
            return null;
        }

        private static DateTimeOffset? ParseDate(string s)
        {
            DateTimeOffset d;
            if (!string.IsNullOrEmpty(s) && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) return d;
            return null;
        }
    }

    #endregion
}
