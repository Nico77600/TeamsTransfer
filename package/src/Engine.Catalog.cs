// =============================================================================
//  TeamsTransfer - engine, part 4b: catalog = work management (lots, slices, leases, import journal, ghosts, merge)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.1
//
//  Why this file exists:
//    The unit of work is the CONVERSATION, never the user (design 3.7): a group chat belongs to several people and is
//    imported once. This part of the catalog turns "these users / teams / chats / channels" into a frozen plan of
//    (conversation x time slice) items, hands that plan out to workers, and remembers what the importer already did so
//    that nothing is ever sent twice. It is a partial class of TmtStore (same catalog.db, same writer connection and
//    lock), so a plan and the store it plans over can never disagree.
//
//  Lots and slices
//    CreateLot freezes the lot: members (User | Team | Chat | Channel, priority) and the time slices, computed once from
//    an "as of" date. Wave 1 = the last 24 months (open ended: it also takes what arrives later); extension waves
//    25-36, 37-48, 49-60 months (LotOptions.WaveMonths, configurable). ResolveLot(lot, slices) expands members into
//    conversations through the inventory already in the catalog and plans one LotItem per (conversation, slice).
//    "Covered": every planned item writes a coverage interval for its conversation; a later lot (or the same lot again)
//    never plans an interval already covered by ANOTHER lot - partial overlaps are cut into fragments. Conversations
//    created after a slice ends, or silent since before it starts, are not planned for that slice. Priority: lower
//    number first (default 100); a conversation reached through several members keeps the smallest.
//
//  Lifecycle (lot and items): Planned -> Exporting -> Exported -> ImportPlanned -> Ghosts -> Files -> Importing ->
//    Completing -> Verified -> Closed, with Paused (resume only to where it was) and Failed (retry to where it was, or
//    back to Planned) from any non-closed state. Ghosts and Files may be skipped when there is nothing to do;
//    Exported -> Exporting allows a delta pass; Completing/Verified -> Importing re-runs after a fix. Closed is final.
//    Cancelled (final, only through CancelLot): a lot that has not started importing (no import session for its items) is abandoned;
//    items and coverage are released, row, members, slices and history stay as an audit trail, the name becomes <name>~cancelled-<id>.
//    Everything else is refused (InvalidOperationException). Each transition is written to lot_history with a time.
//    One exception, deliberate: resolving a NEW slice on a Verified/Closed lot (extension wave) reopens it to Planned.
//
//  Work leases (multi-machine)
//    Work units (a batch of ~500 conversation items, or a range of partitions) are leased with a time to live;
//    a unit whose lease expired is handed out again (attempt counter + worker id fence stale workers: a worker that
//    lost its lease gets false from RenewLease/ReleaseLease and must stop). Time comes from StoreOptions.Clock.
//    HOW SEVERAL MACHINES SHARE WORK WITHOUT SQLITE OVER SMB: catalog.db lives on the LOCAL disk of ONE coordinator
//    machine, which is the only process that opens it. Workers never open it: the coordinator (console/CLI) acquires a
//    lease for a worker and writes a WORK ORDER file (WorkLease.ToJson) to a share; the worker, on its own machine,
//    runs the export of those conversations into ITS OWN store root on ITS OWN local disk, and drops the finished
//    folder (or copies it) where the coordinator can read it. The coordinator then runs Merge(workerRoot) - idempotent,
//    catalog + partitions + content - and calls ReleaseLease(done). A crashed worker simply lets the lease expire.
//    The merge is a plain file read of the worker folder (never a remote SQLite session): copy it to local disk first
//    when it sits on a share.
//
//  Import journal (the "no message is ever resent" guarantee)
//    import_sessions: per (conversation, slice) one startMigration..completeMigration, with the owner appId (the same
//    app must start, import and complete) and the conversationCreationDateTime used. import_messages: per source
//    message its order, status (Pending, Imported, Conflict409TreatedAsImported, Rejected, Skipped), target id, error
//    code. SeedJournal registers the ordered ids; NextPending(conv, slice, n) is the resume query. An imported status
//    cannot be downgraded. The journal lives in catalog.db: fine for the volumes a lot re-injects (millions of rows);
//    it would move to partitions if one catalog had to hold billions.
//
//  Ghost accounts (3.6): source user id -> ghost target id (+ name, state, times); the same person keeps the same
//  ghost for the whole project (an attempt to map one source id to two different ghosts is refused). Input for
//  detection: every message author seen by AppendMessages (from.user.id) is remembered in `authors`; candidates are the
//  authors that are not in the user inventory or are marked Deleted and have no ghost yet.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace TeamsTransfer
{
    public enum LotMemberType { User, Team, Chat, Channel }

    public sealed class LotMember
    {
        public LotMemberType Type { get; set; }
        /// <summary>User: id or UPN. Team: team id. Chat: chat id or "chat:..." key. Channel: "teamId/channelId" or "channel:..." key.</summary>
        public string Identity { get; set; }
        /// <summary>Lower runs first.</summary>
        public int Priority { get; set; } = 100;
        public LotMember() { }
        public LotMember(LotMemberType type, string identity, int priority = 100) { Type = type; Identity = identity; Priority = priority; }
    }

    public sealed class LotOptions
    {
        /// <summary>Reference date of the slices; frozen at creation. Default: now.</summary>
        public DateTimeOffset? AsOfUtc;
        /// <summary>Cumulative boundaries in months: 24, 36, 48, 60 = wave 1 is 0-24 months, wave 2 is 24-36, ...</summary>
        public int[] Boundaries = { 24, 36, 48, 60 };
        public string Notes;
    }

    public enum LotState { Planned, Exporting, Exported, ImportPlanned, Ghosts, Files, Importing, Completing, Verified, Closed, Paused, Failed, Cancelled }

    public sealed class LotInfo
    {
        public long Id { get; set; }
        public string Name { get; set; }
        public LotState State { get; set; }
        public LotState? PreviousState { get; set; }
        public DateTimeOffset CreatedUtc { get; set; }
        public DateTimeOffset StateChangedUtc { get; set; }
        public DateTimeOffset AsOfUtc { get; set; }
        public string Notes { get; set; }
    }

    public sealed class LotSlice
    {
        public long LotId { get; set; }
        public int No { get; set; }
        public string Name { get; set; }
        /// <summary>Inclusive.</summary>
        public DateTimeOffset FromUtc { get; set; }
        /// <summary>Exclusive; null = open ended (wave 1).</summary>
        public DateTimeOffset? ToUtc { get; set; }
    }

    public sealed class LotItem
    {
        public long LotId { get; set; }
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        /// <summary>0 unless a partial overlap with another lot cut the slice into pieces.</summary>
        public int Fragment { get; set; }
        public DateTimeOffset FromUtc { get; set; }
        public DateTimeOffset? ToUtc { get; set; }
        public int Priority { get; set; }
        public LotState State { get; set; }
    }

    public sealed class LotResolveResult
    {
        public long LotId;
        public List<int> Slices = new List<int>();
        public int Planned, AlreadyPlanned, CoveredByOtherLot, NothingInSlice, ConversationsMatched;
        /// <summary>Members that matched nothing in the inventory (typo, not inventoried yet).</summary>
        public List<string> Unresolved = new List<string>();
        public bool Reopened;
    }

    public sealed class LotHistoryEntry
    {
        public DateTimeOffset AtUtc { get; set; }
        public LotState? From { get; set; }
        public LotState To { get; set; }
        public string Note { get; set; }
    }

    public enum LeaseOutcome { Done, Retry, Failed }

    public sealed class WorkLease
    {
        public long Id { get; set; }
        public string Kind { get; set; }
        public long? LotId { get; set; }
        public string UnitKey { get; set; }
        public string PayloadJson { get; set; }
        public string WorkerId { get; set; }
        public int Attempt { get; set; }
        public DateTimeOffset ExpiresUtc { get; set; }

        /// <summary>The work order handed to a remote worker (plain JSON file; no SQLite is shared).</summary>
        public string ToJson()
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
                {
                    w.WriteStartObject();
                    w.WriteNumber("id", Id); w.WriteString("kind", Kind);
                    if (LotId.HasValue) w.WriteNumber("lotId", LotId.Value);
                    w.WriteString("unitKey", UnitKey); w.WriteString("workerId", WorkerId); w.WriteNumber("attempt", Attempt);
                    w.WriteString("expiresUtc", ExpiresUtc.UtcDateTime.ToString("O", CultureInfo.InvariantCulture));
                    if (PayloadJson != null) { w.WritePropertyName("payload"); using (var d = JsonDocument.Parse(PayloadJson)) d.RootElement.WriteTo(w); }
                    w.WriteEndObject();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        public static WorkLease FromJson(string json)
        {
            using (var d = JsonDocument.Parse(json))
            {
                var r = d.RootElement;
                var l = new WorkLease { Id = r.GetProperty("id").GetInt64(), Kind = r.GetProperty("kind").GetString(), UnitKey = r.GetProperty("unitKey").GetString(), WorkerId = r.GetProperty("workerId").GetString(), Attempt = r.GetProperty("attempt").GetInt32() };
                if (r.TryGetProperty("lotId", out var lot)) l.LotId = lot.GetInt64();
                l.ExpiresUtc = DateTimeOffset.Parse(r.GetProperty("expiresUtc").GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
                if (r.TryGetProperty("payload", out var p)) l.PayloadJson = p.GetRawText();
                return l;
            }
        }
    }

    public sealed class WorkProgress
    {
        public string Kind { get; set; }
        public int Available { get; set; }
        public int Leased { get; set; }
        public int Expired { get; set; }
        public int Done { get; set; }
        public int Failed { get; set; }
        public int Total { get { return Available + Leased + Expired + Done + Failed; } }
    }

    public enum JournalStatus { Pending, Imported, Conflict409TreatedAsImported, Rejected, Skipped }

    public sealed class JournalEntry
    {
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public string SourceMessageId { get; set; }
        public int Ordinal { get; set; }
        public JournalStatus Status { get; set; }
        public string TargetMessageId { get; set; }
        public string ErrorCode { get; set; }
        public long? SessionId { get; set; }
        public int Attempts { get; set; }
        public DateTimeOffset? UpdatedUtc { get; set; }
    }

    public sealed class JournalMark
    {
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public string SourceMessageId { get; set; }
        public JournalStatus Status { get; set; }
        public string TargetMessageId { get; set; }
        public string ErrorCode { get; set; }
        public long? SessionId { get; set; }
    }

    public enum ImportSessionState { Started, Completed, Failed, Abandoned }

    public sealed class ImportSession
    {
        public long Id { get; set; }
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public string AppId { get; set; }
        public string TargetConversationId { get; set; }
        public DateTimeOffset ConversationCreationUtc { get; set; }
        public DateTimeOffset StartedUtc { get; set; }
        public DateTimeOffset? CompletedUtc { get; set; }
        public ImportSessionState State { get; set; }
        public string Note { get; set; }
    }

    public enum GhostState { Planned, Created, Failed, Reactivated, Deleted }

    public sealed class GhostRecord
    {
        public string SourceUserId { get; set; }
        /// <summary>Id of the ghost account in the target tenant; null while only planned.</summary>
        public string GhostId { get; set; }
        public string DisplayName { get; set; }
        public string UserPrincipalName { get; set; }
        public GhostState State { get; set; }
        public DateTimeOffset? CreatedUtc { get; set; }
        public DateTimeOffset? UpdatedUtc { get; set; }
        public string Error { get; set; }
    }

    public sealed class GhostCandidate
    {
        public string UserId { get; set; }
        public string DisplayName { get; set; }
        public string IdentityType { get; set; }
        /// <summary>NotInInventory | Deleted</summary>
        public string Reason { get; set; }
        public string FirstConversation { get; set; }
    }

    public sealed class StoreMergeReport
    {
        public int Users, Conversations, Links, Files, HostedContents, Checkpoints, Authors, Ghosts, PartitionsMerged;
        public long MessagesNew, MessagesUpdated, MessagesUnchanged;
        public int ContentCopied, ContentPresent;
    }

    public sealed partial class TmtStore
    {
        const string WorkSchemaSql = @"
CREATE TABLE IF NOT EXISTS lots(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, state TEXT NOT NULL, prev_state TEXT, created INTEGER NOT NULL, state_changed INTEGER NOT NULL, as_of INTEGER NOT NULL, notes TEXT);
CREATE TABLE IF NOT EXISTS lot_members(lot_id INTEGER NOT NULL, ord INTEGER NOT NULL, type TEXT NOT NULL, identity TEXT NOT NULL, priority INTEGER NOT NULL, PRIMARY KEY(lot_id, ord));
CREATE TABLE IF NOT EXISTS lot_history(id INTEGER PRIMARY KEY AUTOINCREMENT, lot_id INTEGER NOT NULL, at INTEGER NOT NULL, from_state TEXT, to_state TEXT NOT NULL, note TEXT);
CREATE INDEX IF NOT EXISTS ix_lot_history ON lot_history(lot_id, id);
CREATE TABLE IF NOT EXISTS lot_slices(lot_id INTEGER NOT NULL, no INTEGER NOT NULL, name TEXT NOT NULL, from_utc INTEGER NOT NULL, to_utc INTEGER, PRIMARY KEY(lot_id, no));
CREATE TABLE IF NOT EXISTS lot_items(lot_id INTEGER NOT NULL, conv_key TEXT NOT NULL, slice_no INTEGER NOT NULL, frag INTEGER NOT NULL, from_utc INTEGER NOT NULL, to_utc INTEGER, priority INTEGER NOT NULL,
  state TEXT NOT NULL, state_changed INTEGER NOT NULL, PRIMARY KEY(lot_id, conv_key, slice_no, frag)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_items_conv ON lot_items(conv_key);
CREATE TABLE IF NOT EXISTS coverage(conv_key TEXT NOT NULL, from_utc INTEGER NOT NULL, to_utc INTEGER NOT NULL, lot_id INTEGER NOT NULL, slice_no INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS ix_coverage ON coverage(conv_key);
CREATE TABLE IF NOT EXISTS work_units(id INTEGER PRIMARY KEY AUTOINCREMENT, lot_id INTEGER, kind TEXT NOT NULL, unit_key TEXT NOT NULL, ord INTEGER NOT NULL, priority INTEGER NOT NULL DEFAULT 100,
  payload TEXT, state TEXT NOT NULL, worker_id TEXT, attempt INTEGER NOT NULL DEFAULT 0, leased_at INTEGER, expires INTEGER, done_at INTEGER, note TEXT, UNIQUE(kind, unit_key));
CREATE INDEX IF NOT EXISTS ix_units ON work_units(kind, state, priority, lot_id, ord);
CREATE TABLE IF NOT EXISTS import_sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, conv_key TEXT NOT NULL, slice_no INTEGER NOT NULL, app_id TEXT NOT NULL, target_conv TEXT, creation_dt INTEGER NOT NULL,
  started INTEGER NOT NULL, completed INTEGER, state TEXT NOT NULL, note TEXT);
CREATE INDEX IF NOT EXISTS ix_sessions ON import_sessions(conv_key, slice_no, id);
CREATE TABLE IF NOT EXISTS import_messages(conv_key TEXT NOT NULL, src_id TEXT NOT NULL, slice_no INTEGER NOT NULL, ord INTEGER NOT NULL, status INTEGER NOT NULL DEFAULT 0, target_id TEXT, error TEXT,
  session_id INTEGER, attempts INTEGER NOT NULL DEFAULT 0, updated INTEGER, PRIMARY KEY(conv_key, src_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_journal_next ON import_messages(conv_key, slice_no, status, ord);
CREATE TABLE IF NOT EXISTS ghosts(source_user_id TEXT PRIMARY KEY, ghost_id TEXT, display_name TEXT, upn TEXT, state TEXT NOT NULL, created INTEGER, updated INTEGER, error TEXT);
";

        // =====================================================================================================
        #region Lots

        static readonly Dictionary<LotState, LotState[]> Forward = new Dictionary<LotState, LotState[]>
        {
            { LotState.Planned, new[] { LotState.Exporting } },
            { LotState.Exporting, new[] { LotState.Exported } },
            { LotState.Exported, new[] { LotState.ImportPlanned, LotState.Exporting } },
            { LotState.ImportPlanned, new[] { LotState.Ghosts, LotState.Files, LotState.Importing } },
            { LotState.Ghosts, new[] { LotState.Files, LotState.Importing } },
            { LotState.Files, new[] { LotState.Importing } },
            { LotState.Importing, new[] { LotState.Completing } },
            { LotState.Completing, new[] { LotState.Verified, LotState.Importing } },
            { LotState.Verified, new[] { LotState.Closed, LotState.Importing } },
        };

        /// <summary>The lifecycle rules (see header). previous = the state a Paused/Failed lot came from.</summary>
        public static bool IsLegalTransition(LotState from, LotState to, LotState? previous)
        {
            if (from == to || from == LotState.Closed || from == LotState.Cancelled || to == LotState.Cancelled) return false;
            if (from == LotState.Paused) return to == LotState.Failed || (previous.HasValue && to == previous.Value);
            if (from == LotState.Failed) return to == LotState.Planned || (previous.HasValue && to == previous.Value) || to == LotState.Paused;
            if (to == LotState.Paused || to == LotState.Failed) return true;
            LotState[] next;
            return Forward.TryGetValue(from, out next) && next.Contains(to);
        }

        static LotState ParseState(object o) { return (LotState)Enum.Parse(typeof(LotState), (string)o); }

        static LotInfo ReadLot(SqliteDataReader r)
        {
            return new LotInfo
            {
                Id = r.GetInt64(0), Name = r.GetString(1), State = ParseState(r.GetString(2)), PreviousState = r.IsDBNull(3) ? (LotState?)null : ParseState(r.GetString(3)),
                CreatedUtc = Dt(r, 4).Value, StateChangedUtc = Dt(r, 5).Value, AsOfUtc = Dt(r, 6).Value, Notes = Str(r, 7)
            };
        }
        const string LotCols = "id,name,state,prev_state,created,state_changed,as_of,notes";

        /// <summary>Creates a lot in state Planned with its members and its frozen slices. Names are unique.</summary>
        public long CreateLot(string name, IEnumerable<LotMember> members, LotOptions options = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("name");
            if (members == null) throw new ArgumentNullException("members");
            var o = options ?? new LotOptions();
            var list = members.Where(m => m != null && !string.IsNullOrWhiteSpace(m.Identity)).ToList();
            if (list.Count == 0) throw new ArgumentException("A lot needs at least one member.");
            if (o.Boundaries == null || o.Boundaries.Length == 0) throw new ArgumentException("Boundaries");
            for (int i = 0; i < o.Boundaries.Length; i++) if (o.Boundaries[i] <= (i == 0 ? 0 : o.Boundaries[i - 1])) throw new ArgumentException("Boundaries must be strictly increasing months.");
            DateTimeOffset now = Now, asOf = (o.AsOfUtc ?? now).ToUniversalTime();
            long id = 0;
            InCatalogTransaction(() =>
            {
                if (Scalar(_cat, "SELECT 1 FROM lots WHERE name=@n", "@n", name) != null) throw new InvalidOperationException("A lot named '" + name + "' already exists.");
                Run(_cat, "INSERT INTO lots(name,state,created,state_changed,as_of,notes) VALUES(@n,'Planned',@t,@t,@a,@no)", "@n", name, "@t", now, "@a", asOf, "@no", o.Notes);
                id = Convert.ToInt64(Scalar(_cat, "SELECT last_insert_rowid()"), CultureInfo.InvariantCulture);
                int ord = 0;
                foreach (var m in list) Run(_cat, "INSERT INTO lot_members(lot_id,ord,type,identity,priority) VALUES(@l,@o,@t,@i,@p)", "@l", id, "@o", ord++, "@t", m.Type.ToString(), "@i", m.Identity.Trim(), "@p", m.Priority);
                for (int i = 0; i < o.Boundaries.Length; i++)
                {
                    int lo = i == 0 ? 0 : o.Boundaries[i - 1], hi = o.Boundaries[i];
                    DateTimeOffset from = asOf.AddMonths(-hi);
                    DateTimeOffset? to = i == 0 ? (DateTimeOffset?)null : asOf.AddMonths(-lo);
                    Run(_cat, "INSERT INTO lot_slices(lot_id,no,name,from_utc,to_utc) VALUES(@l,@n,@nm,@f,@t)", "@l", id, "@n", i + 1, "@nm", "Wave " + (i + 1) + " (" + lo + "-" + hi + " months)", "@f", from, "@t", to);
                }
                Run(_cat, "INSERT INTO lot_history(lot_id,at,from_state,to_state,note) VALUES(@l,@t,NULL,'Planned','created')", "@l", id, "@t", now);
            });
            return id;
        }

        public LotInfo GetLot(long lotId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + LotCols + " FROM lots WHERE id=@i", "@i", lotId))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadLot(r) : null;
        }

        public LotInfo GetLot(string name)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + LotCols + " FROM lots WHERE name=@n", "@n", name))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadLot(r) : null;
        }

        public IEnumerable<LotInfo> ListLots(LotState? state = null)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + LotCols + " FROM lots" + (state.HasValue ? " WHERE state=@s" : "") + " ORDER BY id", "@s", state?.ToString()))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadLot(r);
        }

        public IEnumerable<LotMember> ListLotMembers(long lotId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT type,identity,priority FROM lot_members WHERE lot_id=@l ORDER BY ord", "@l", lotId))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return new LotMember((LotMemberType)Enum.Parse(typeof(LotMemberType), r.GetString(0)), r.GetString(1), r.GetInt32(2));
        }

        public IEnumerable<LotSlice> ListSlices(long lotId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT no,name,from_utc,to_utc FROM lot_slices WHERE lot_id=@l ORDER BY no", "@l", lotId))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return new LotSlice { LotId = lotId, No = r.GetInt32(0), Name = r.GetString(1), FromUtc = Dt(r, 2).Value, ToUtc = Dt(r, 3) };
        }

        public IEnumerable<LotHistoryEntry> LotHistory(long lotId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT at,from_state,to_state,note FROM lot_history WHERE lot_id=@l ORDER BY id", "@l", lotId))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return new LotHistoryEntry { AtUtc = Dt(r, 0).Value, From = r.IsDBNull(1) ? (LotState?)null : ParseState(r.GetString(1)), To = ParseState(r.GetString(2)), Note = Str(r, 3) };
        }

        /// <summary>Moves the lot along its lifecycle; an illegal move throws InvalidOperationException and changes nothing.</summary>
        public LotInfo TransitionLot(long lotId, LotState to, string note = null, LotState? expectedFrom = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                LotState from; LotState? prev;
                using (var cmd = Cmd(_cat, "SELECT state,prev_state FROM lots WHERE id=@i", "@i", lotId))
                using (var r = cmd.ExecuteReader())
                {
                    if (!r.Read()) throw new KeyNotFoundException("No lot #" + lotId);
                    from = ParseState(r.GetString(0)); prev = r.IsDBNull(1) ? (LotState?)null : ParseState(r.GetString(1));
                }
                if (expectedFrom.HasValue && expectedFrom.Value != from) throw new InvalidOperationException("Lot #" + lotId + " is " + from + ", expected " + expectedFrom.Value + ".");
                if (!IsLegalTransition(from, to, prev)) throw new InvalidOperationException("Illegal lot transition " + from + " -> " + to + (prev.HasValue ? " (came from " + prev.Value + ")" : "") + ".");
                string newPrev = (to == LotState.Paused || to == LotState.Failed) ? (from == LotState.Paused || from == LotState.Failed ? prev?.ToString() : from.ToString()) : null;
                Run(_cat, "UPDATE lots SET state=@s, prev_state=@p, state_changed=@t WHERE id=@i", "@s", to.ToString(), "@p", newPrev, "@t", Now, "@i", lotId);
                Run(_cat, "INSERT INTO lot_history(lot_id,at,from_state,to_state,note) VALUES(@l,@t,@f,@s,@n)", "@l", lotId, "@t", Now, "@f", from.ToString(), "@s", to.ToString(), "@n", note);
            });
            return GetLot(lotId);
        }

        /// <summary>Removes a lot that has not started (state Planned): its items and its coverage are released for other lots.</summary>
        public void DeletePlannedLot(long lotId)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                object st = Scalar(_cat, "SELECT state FROM lots WHERE id=@i", "@i", lotId);
                if (st == null) return;
                if ((string)st != "Planned") throw new InvalidOperationException("Only a Planned lot can be deleted (lot #" + lotId + " is " + st + ").");
                foreach (var t in new[] { "lot_items", "coverage", "lot_slices", "lot_members", "lot_history", "work_units" }) Run(_cat, "DELETE FROM " + t + " WHERE lot_id=@l", "@l", lotId);
                Run(_cat, "DELETE FROM lots WHERE id=@l", "@l", lotId);
            });
        }

        /// <summary>Number of import sessions (startMigration..completeMigration) recorded for the (conversation, slice) of the lot's items.</summary>
        public int CountImportSessions(long lotId)
        {
            using (var c = OpenCatalogRead())
                return Convert.ToInt32(Scalar(c, "SELECT COUNT(*) FROM import_sessions s WHERE EXISTS (SELECT 1 FROM lot_items i WHERE i.lot_id=@l AND i.conv_key=s.conv_key AND i.slice_no=s.slice_no)", "@l", lotId) ?? 0L, CultureInfo.InvariantCulture);
        }

        /// <summary>Journal messages per status over every (conversation, slice) of the lot's items.</summary>
        public IReadOnlyDictionary<JournalStatus, int> GetLotJournalSummary(long lotId)
        {
            var d = new Dictionary<JournalStatus, int>();
            foreach (JournalStatus s in Enum.GetValues(typeof(JournalStatus))) d[s] = 0;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT m.status,COUNT(*) FROM import_messages m WHERE EXISTS (SELECT 1 FROM lot_items i WHERE i.lot_id=@l AND i.conv_key=m.conv_key AND i.slice_no=m.slice_no) GROUP BY m.status", "@l", lotId))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) d[(JournalStatus)r.GetInt32(0)] = r.GetInt32(1);
            return d;
        }

        /// <summary>Conversations of the inventory (all of them, with or without exported messages).</summary>
        public long CountInventoriedConversations()
        {
            using (var c = OpenCatalogRead()) return Convert.ToInt64(Scalar(c, "SELECT COUNT(*) FROM conversations") ?? 0L, CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Abandons a lot that has not started importing (states Planned, Exporting, Exported, ImportPlanned, Paused, Failed; no import session for
        /// its items): items, coverage and work units are released, the lot row stays in state Cancelled with its history (audit) and is renamed
        /// '&lt;name&gt;~cancelled-&lt;id&gt;'. Journal rows still Pending for its items are removed. Refused (InvalidOperationException) otherwise.
        /// </summary>
        public LotInfo CancelLot(long lotId, string reason)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                string name, st;
                using (var cmd = Cmd(_cat, "SELECT name,state FROM lots WHERE id=@i", "@i", lotId))
                using (var r = cmd.ExecuteReader())
                {
                    if (!r.Read()) throw new KeyNotFoundException("No lot #" + lotId);
                    name = r.GetString(0); st = r.GetString(1);
                }
                var state = (LotState)Enum.Parse(typeof(LotState), st);
                if (state == LotState.Cancelled) throw new InvalidOperationException("Lot " + name + " is already Cancelled.");
                if (state != LotState.Planned && state != LotState.Exporting && state != LotState.Exported && state != LotState.ImportPlanned && state != LotState.Paused && state != LotState.Failed)
                    throw new InvalidOperationException("Lot " + name + " is " + state + ": it cannot be cancelled; finish or verify it.");
                int sessions = Convert.ToInt32(Scalar(_cat, "SELECT COUNT(*) FROM import_sessions s WHERE EXISTS (SELECT 1 FROM lot_items i WHERE i.lot_id=@l AND i.conv_key=s.conv_key AND i.slice_no=s.slice_no)", "@l", lotId) ?? 0L, CultureInfo.InvariantCulture);
                if (sessions > 0) throw new InvalidOperationException("Lot " + name + " has started importing (" + sessions + " session" + (sessions == 1 ? "" : "s") + "): it cannot be cancelled; finish or verify it.");
                Run(_cat, "DELETE FROM import_messages WHERE status=0 AND EXISTS (SELECT 1 FROM lot_items i WHERE i.lot_id=@l AND i.conv_key=import_messages.conv_key AND i.slice_no=import_messages.slice_no)", "@l", lotId);
                foreach (var t in new[] { "lot_items", "coverage", "work_units" }) Run(_cat, "DELETE FROM " + t + " WHERE lot_id=@l", "@l", lotId);
                var now = Now;
                Run(_cat, "UPDATE lots SET state='Cancelled', prev_state=NULL, state_changed=@t, name=@n WHERE id=@i", "@t", now, "@n", name + "~cancelled-" + lotId, "@i", lotId);
                Run(_cat, "INSERT INTO lot_history(lot_id,at,from_state,to_state,note) VALUES(@l,@t,@f,'Cancelled',@n)", "@l", lotId, "@t", now, "@f", st, "@n", string.IsNullOrEmpty(reason) ? "cancelled" : reason);
            });
            return GetLot(lotId);
        }

        /// <summary>Cancels a lot by name (see the id overload).</summary>
        public LotInfo CancelLot(string lotName, string reason)
        {
            var lot = GetLot(lotName);
            if (lot == null) throw new KeyNotFoundException("No lot '" + lotName + "'.");
            return CancelLot(lot.Id, reason);
        }

        List<string> ColumnStrings(string sql, params object[] kv)
        {
            var l = new List<string>();
            using (var cmd = Cmd(_cat, sql, kv)) using (var r = cmd.ExecuteReader()) while (r.Read()) l.Add(r.GetString(0));
            return l;
        }

        /// <summary>Conversation keys a member designates, from the inventory in the catalog (called inside the catalog lock).</summary>
        List<string> ResolveMember(LotMember m)
        {
            string id = m.Identity.Trim();
            switch (m.Type)
            {
                case LotMemberType.User:
                    {
                        string uid = (string)Scalar(_cat, "SELECT id FROM users WHERE id=@i", "@i", id) ?? (string)Scalar(_cat, "SELECT id FROM users WHERE upn=@i COLLATE NOCASE", "@i", id) ?? id;
                        return ColumnStrings("SELECT conv_key FROM user_conversations WHERE user_id=@u ORDER BY conv_key", "@u", uid);
                    }
                case LotMemberType.Team:
                    return ColumnStrings("SELECT key FROM conversations WHERE team_id=@t AND kind=@k ORDER BY key", "@t", id, "@k", ConversationKind.Channel);
                case LotMemberType.Chat:
                    return ColumnStrings("SELECT key FROM conversations WHERE key=@k", "@k", id.StartsWith("chat:", StringComparison.Ordinal) ? id : ConversationKeys.ForChat(id));
                default:
                    {
                        string key = id.StartsWith("channel:", StringComparison.Ordinal) ? id : "channel:" + id;
                        return ColumnStrings("SELECT key FROM conversations WHERE key=@k", "@k", key);
                    }
            }
        }

        /// <summary>
        /// Expands the lot's members into conversations and plans one item per (conversation, slice). Idempotent: items that
        /// exist are kept, conversations inventoried since are added. Slice numbers default to wave 1.
        /// </summary>
        public LotResolveResult ResolveLot(long lotId, params int[] sliceNos)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            var res = new LotResolveResult { LotId = lotId };
            var slicesWanted = (sliceNos == null || sliceNos.Length == 0 ? new[] { 1 } : sliceNos).Distinct().OrderBy(x => x).ToList();
            InCatalogTransaction(() =>
            {
                object st = Scalar(_cat, "SELECT state FROM lots WHERE id=@i", "@i", lotId);
                if (st == null) throw new KeyNotFoundException("No lot #" + lotId);
                var state = ParseState(st);
                if (state == LotState.Failed || state == LotState.Paused) throw new InvalidOperationException("Lot #" + lotId + " is " + state + ": resume it before planning more.");
                if (state == LotState.Cancelled) throw new InvalidOperationException("Lot #" + lotId + " is Cancelled.");

                var slices = new Dictionary<int, LotSlice>();
                using (var cmd = Cmd(_cat, "SELECT no,name,from_utc,to_utc FROM lot_slices WHERE lot_id=@l", "@l", lotId))
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) slices[r.GetInt32(0)] = new LotSlice { LotId = lotId, No = r.GetInt32(0), Name = r.GetString(1), FromUtc = Dt(r, 2).Value, ToUtc = Dt(r, 3) };
                foreach (int s in slicesWanted) if (!slices.ContainsKey(s)) throw new ArgumentException("Lot #" + lotId + " has no slice " + s + " (defined: " + string.Join(",", slices.Keys.OrderBy(x => x)) + ").");

                // members -> conversations, smallest priority wins
                var prio = new Dictionary<string, int>(StringComparer.Ordinal);
                var members = new List<LotMember>();
                using (var cmd = Cmd(_cat, "SELECT type,identity,priority FROM lot_members WHERE lot_id=@l ORDER BY ord", "@l", lotId))
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) members.Add(new LotMember((LotMemberType)Enum.Parse(typeof(LotMemberType), r.GetString(0)), r.GetString(1), r.GetInt32(2)));
                foreach (var m in members)
                {
                    var keys = ResolveMember(m);
                    if (keys.Count == 0)
                    {
                        bool known = m.Type == LotMemberType.User && (Scalar(_cat, "SELECT 1 FROM users WHERE id=@i OR upn=@i COLLATE NOCASE", "@i", m.Identity) != null);
                        if (!known) res.Unresolved.Add(m.Type + ":" + m.Identity);
                    }
                    foreach (var k in keys) { int cur; if (!prio.TryGetValue(k, out cur) || m.Priority < cur) prio[k] = m.Priority; }
                }
                res.ConversationsMatched = prio.Count;
                var convs = prio.OrderBy(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Key).ToList();

                var info = new Dictionary<string, (long? created, long? last)>();
                DateTimeOffset now = Now;
                foreach (int sn in slicesWanted)
                {
                    var sl = slices[sn];
                    long from = sl.FromUtc.UtcTicks, to = sl.ToUtc.HasValue ? sl.ToUtc.Value.UtcTicks : long.MaxValue;
                    res.Slices.Add(sn);
                    foreach (var key in convs)
                    {
                        if (Scalar(_cat, "SELECT 1 FROM lot_items WHERE lot_id=@l AND conv_key=@k AND slice_no=@s", "@l", lotId, "@k", key, "@s", sn) != null) { res.AlreadyPlanned++; continue; }
                        long? created = null, last = null;
                        using (var cmd = Cmd(_cat, "SELECT created,last_activity FROM conversations WHERE key=@k", "@k", key))
                        using (var r = cmd.ExecuteReader())
                            if (r.Read()) { created = r.IsDBNull(0) ? (long?)null : r.GetInt64(0); last = r.IsDBNull(1) ? (long?)null : r.GetInt64(1); }
                        if ((created.HasValue && created.Value >= to) || (last.HasValue && last.Value < from)) { res.NothingInSlice++; continue; }
                        // subtract what other lots already cover
                        var cov = new List<long[]>();
                        using (var cmd = Cmd(_cat, "SELECT from_utc,to_utc FROM coverage WHERE conv_key=@k AND lot_id<>@l AND from_utc<@to AND to_utc>@from ORDER BY from_utc", "@k", key, "@l", lotId, "@to", to, "@from", from))
                        using (var r = cmd.ExecuteReader())
                            while (r.Read()) cov.Add(new[] { r.GetInt64(0), r.GetInt64(1) });
                        var frags = new List<long[]>();
                        long cur = from;
                        foreach (var c in cov)
                        {
                            if (c[0] > cur) frags.Add(new[] { cur, Math.Min(c[0], to) });
                            if (c[1] > cur) cur = c[1];
                            if (cur >= to) break;
                        }
                        if (cur < to) frags.Add(new[] { cur, to });
                        if (frags.Count == 0) { res.CoveredByOtherLot++; continue; }
                        int fi = 0;
                        foreach (var f in frags)
                        {
                            object toVal = f[1] == long.MaxValue ? null : (object)f[1];
                            Run(_cat, "INSERT INTO lot_items(lot_id,conv_key,slice_no,frag,from_utc,to_utc,priority,state,state_changed) VALUES(@l,@k,@s,@f,@fr,@to,@p,'Planned',@t)",
                                "@l", lotId, "@k", key, "@s", sn, "@f", fi++, "@fr", f[0], "@to", toVal, "@p", prio[key], "@t", now);
                            Run(_cat, "INSERT INTO coverage(conv_key,from_utc,to_utc,lot_id,slice_no) VALUES(@k,@fr,@to,@l,@s)", "@k", key, "@fr", f[0], "@to", f[1], "@l", lotId, "@s", sn);
                            res.Planned++;
                        }
                    }
                }
                if (res.Planned > 0 && (state == LotState.Verified || state == LotState.Closed))
                {
                    Run(_cat, "UPDATE lots SET state='Planned', prev_state=NULL, state_changed=@t WHERE id=@i", "@t", now, "@i", lotId);
                    Run(_cat, "INSERT INTO lot_history(lot_id,at,from_state,to_state,note) VALUES(@l,@t,@f,'Planned',@n)", "@l", lotId, "@t", now, "@f", state.ToString(), "@n", "reopened: wave(s) " + string.Join(",", slicesWanted) + " planned");
                    res.Reopened = true;
                }
            });
            return res;
        }

        public LotResolveResult ResolveLot(string lotName, params int[] sliceNos)
        {
            var l = GetLot(lotName);
            if (l == null) throw new KeyNotFoundException("No lot named '" + lotName + "'");
            return ResolveLot(l.Id, sliceNos);
        }

        static LotItem ReadItem(SqliteDataReader r)
        {
            return new LotItem { LotId = r.GetInt64(0), ConversationKey = r.GetString(1), SliceNo = r.GetInt32(2), Fragment = r.GetInt32(3), FromUtc = Dt(r, 4).Value, ToUtc = Dt(r, 5), Priority = r.GetInt32(6), State = ParseState(r.GetString(7)) };
        }

        /// <summary>Items of a lot, by priority then key.</summary>
        public IEnumerable<LotItem> ListItems(long lotId, int? sliceNo = null, LotState? state = null)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT lot_id,conv_key,slice_no,frag,from_utc,to_utc,priority,state FROM lot_items WHERE lot_id=@l" + (sliceNo.HasValue ? " AND slice_no=@s" : "") + (state.HasValue ? " AND state=@st" : "") +
                " ORDER BY priority, conv_key, slice_no, frag", "@l", lotId, "@s", sliceNo, "@st", state?.ToString()))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadItem(r);
        }

        /// <summary>Which lot(s) plan a conversation, and on which interval (the "covered" view).</summary>
        public IEnumerable<LotItem> ItemsOfConversation(string conversationKey)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT lot_id,conv_key,slice_no,frag,from_utc,to_utc,priority,state FROM lot_items WHERE conv_key=@k ORDER BY lot_id, slice_no, frag", "@k", conversationKey))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadItem(r);
        }

        /// <summary>Same lifecycle rules as the lot, applied to one item (Paused/Failed items may resume anywhere).</summary>
        public void SetItemState(long lotId, string conversationKey, int sliceNo, int fragment, LotState to)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                object st = Scalar(_cat, "SELECT state FROM lot_items WHERE lot_id=@l AND conv_key=@k AND slice_no=@s AND frag=@f", "@l", lotId, "@k", conversationKey, "@s", sliceNo, "@f", fragment);
                if (st == null) throw new KeyNotFoundException("No such item.");
                var from = ParseState(st);
                bool ok = (from == LotState.Paused || from == LotState.Failed) ? (to != from && to != LotState.Closed) : IsLegalTransition(from, to, null);
                if (!ok) throw new InvalidOperationException("Illegal item transition " + from + " -> " + to + ".");
                Run(_cat, "UPDATE lot_items SET state=@t, state_changed=@n WHERE lot_id=@l AND conv_key=@k AND slice_no=@s AND frag=@f", "@t", to.ToString(), "@n", Now, "@l", lotId, "@k", conversationKey, "@s", sliceNo, "@f", fragment);
            });
        }

        /// <summary>Messages held by the store for the conversations of a lot (all dates): sizes a lot against the ~5M messages target.</summary>
        public long EstimateLotMessages(long lotId)
        {
            long n = 0;
            List<string> keys;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT DISTINCT conv_key FROM lot_items WHERE lot_id=@l", "@l", lotId))
            using (var r = cmd.ExecuteReader()) { keys = new List<string>(); while (r.Read()) keys.Add(r.GetString(0)); }
            foreach (var k in keys) n += CountMessages(k);
            return n;
        }

        #endregion

        // =====================================================================================================
        #region Work units and leases

        /// <summary>Adds a unit of work (ignored when kind+unitKey exist). Returns the unit id, or 0 when it already existed.</summary>
        public long AddWorkUnit(string kind, string unitKey, string payloadJson, long? lotId = null, int priority = 100, int ordinal = 0)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            long id = 0;
            InCatalogTransaction(() =>
            {
                if (Run(_cat, "INSERT OR IGNORE INTO work_units(lot_id,kind,unit_key,ord,priority,payload,state) VALUES(@l,@k,@u,@o,@p,@pl,'Available')", "@l", lotId, "@k", kind, "@u", unitKey, "@o", ordinal, "@p", priority, "@pl", payloadJson) > 0)
                    id = Convert.ToInt64(Scalar(_cat, "SELECT last_insert_rowid()"), CultureInfo.InvariantCulture);
            });
            return id;
        }

        /// <summary>
        /// Cuts the items of a lot (by priority) into units of batchSize conversation items: payload {"lot":id,"items":[[key,slice,frag],...]}.
        /// Idempotent: units already created for (lot, kind) are kept. Returns the number of units created.
        /// </summary>
        public int PlanWorkUnits(long lotId, string kind, int batchSize = 500, int? sliceNo = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (batchSize < 1) throw new ArgumentOutOfRangeException("batchSize");
            int created = 0;
            var items = ListItems(lotId, sliceNo).ToList();
            InCatalogTransaction(() =>
            {
                int existing = Convert.ToInt32(Scalar(_cat, "SELECT COUNT(*) FROM work_units WHERE lot_id=@l AND kind=@k", "@l", lotId, "@k", kind), CultureInfo.InvariantCulture);
                var planned = new HashSet<string>(StringComparer.Ordinal);
                using (var cmd = Cmd(_cat, "SELECT payload FROM work_units WHERE lot_id=@l AND kind=@k", "@l", lotId, "@k", kind))
                using (var r = cmd.ExecuteReader())
                    while (r.Read())
                        using (var d = JsonDocument.Parse(r.GetString(0)))
                            foreach (var it in d.RootElement.GetProperty("items").EnumerateArray()) planned.Add(it[0].GetString() + "|" + it[1].GetInt32() + "|" + it[2].GetInt32());
                var todo = items.Where(i => !planned.Contains(i.ConversationKey + "|" + i.SliceNo + "|" + i.Fragment)).ToList();
                int ord = existing;
                for (int off = 0; off < todo.Count; off += batchSize)
                {
                    var chunk = todo.Skip(off).Take(batchSize).ToList();
                    using (var ms = new MemoryStream())
                    {
                        using (var w = new Utf8JsonWriter(ms))
                        {
                            w.WriteStartObject(); w.WriteNumber("lot", lotId); w.WriteStartArray("items");
                            foreach (var it in chunk) { w.WriteStartArray(); w.WriteStringValue(it.ConversationKey); w.WriteNumberValue(it.SliceNo); w.WriteNumberValue(it.Fragment); w.WriteEndArray(); }
                            w.WriteEndArray(); w.WriteEndObject();
                        }
                        Run(_cat, "INSERT INTO work_units(lot_id,kind,unit_key,ord,priority,payload,state) VALUES(@l,@k,@u,@o,@p,@pl,'Available')",
                            "@l", lotId, "@k", kind, "@u", "lot" + lotId + ":" + ord, "@o", ord, "@p", chunk.Min(c => c.Priority), "@pl", Encoding.UTF8.GetString(ms.ToArray()));
                    }
                    ord++; created++;
                }
            });
            return created;
        }

        /// <summary>Units covering ranges of partitions ({"partitions":[from,to]}), e.g. for a distributed verify.</summary>
        public int PlanPartitionUnits(string kind, int partitionsPerUnit)
        {
            int created = 0;
            for (int a = 0, ord = 0; a < _partitions; a += partitionsPerUnit, ord++)
            {
                int b = Math.Min(_partitions - 1, a + partitionsPerUnit - 1);
                if (AddWorkUnit(kind, "p" + a.ToString("D3", CultureInfo.InvariantCulture) + "-" + b.ToString("D3", CultureInfo.InvariantCulture), "{\"partitions\":[" + a + "," + b + "]}", null, 100, ord) > 0) created++;
            }
            return created;
        }

        /// <summary>
        /// Hands out the next available unit of this kind (lowest priority number, then lot, then order), or one whose lease
        /// expired. Units of Paused/Failed/Closed lots are not handed out. Returns null when nothing is left.
        /// </summary>
        public WorkLease AcquireLease(string workerId, string kind, TimeSpan ttl)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (string.IsNullOrEmpty(workerId)) throw new ArgumentException("workerId");
            WorkLease lease = null;
            InCatalogTransaction(() =>
            {
                DateTimeOffset now = Now;
                long id = 0; long? lot = null; string key = null, payload = null; int attempt = 0;
                using (var cmd = Cmd(_cat, @"SELECT u.id,u.lot_id,u.unit_key,u.payload,u.attempt FROM work_units u LEFT JOIN lots l ON l.id=u.lot_id
WHERE u.kind=@k AND (u.state='Available' OR (u.state='Leased' AND u.expires<@now)) AND (l.id IS NULL OR l.state NOT IN ('Paused','Failed','Closed'))
ORDER BY u.priority, COALESCE(u.lot_id,0), u.ord, u.id LIMIT 1", "@k", kind, "@now", now))
                using (var r = cmd.ExecuteReader())
                {
                    if (!r.Read()) return;
                    id = r.GetInt64(0); lot = r.IsDBNull(1) ? (long?)null : r.GetInt64(1); key = r.GetString(2); payload = Str(r, 3); attempt = r.GetInt32(4) + 1;
                }
                DateTimeOffset exp = now + ttl;
                Run(_cat, "UPDATE work_units SET state='Leased', worker_id=@w, attempt=@a, leased_at=@n, expires=@e WHERE id=@i", "@w", workerId, "@a", attempt, "@n", now, "@e", exp, "@i", id);
                lease = new WorkLease { Id = id, Kind = kind, LotId = lot, UnitKey = key, PayloadJson = payload, WorkerId = workerId, Attempt = attempt, ExpiresUtc = exp };
            });
            return lease;
        }

        /// <summary>Extends a lease. False when it was lost (reclaimed by another worker after expiry, or the unit is finished): stop working on it.</summary>
        public bool RenewLease(WorkLease lease, TimeSpan ttl)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            DateTimeOffset exp = Now + ttl;
            int n;
            lock (_catLock)
                n = Run(_cat, "UPDATE work_units SET expires=@e WHERE id=@i AND state='Leased' AND worker_id=@w AND attempt=@a", "@e", exp, "@i", lease.Id, "@w", lease.WorkerId, "@a", lease.Attempt);
            if (n > 0) lease.ExpiresUtc = exp;
            return n > 0;
        }

        /// <summary>Done: finished. Retry: back to Available. Failed: parked until ResetWorkUnit. False when the lease was no longer ours.</summary>
        public bool ReleaseLease(WorkLease lease, LeaseOutcome outcome = LeaseOutcome.Done, string note = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            string state = outcome == LeaseOutcome.Done ? "Done" : outcome == LeaseOutcome.Retry ? "Available" : "Failed";
            lock (_catLock)
                return Run(_cat, "UPDATE work_units SET state=@s, worker_id=CASE WHEN @s='Available' THEN NULL ELSE worker_id END, expires=NULL, done_at=@d, note=@n WHERE id=@i AND state='Leased' AND worker_id=@w AND attempt=@a",
                    "@s", state, "@d", outcome == LeaseOutcome.Done ? (DateTimeOffset?)Now : null, "@n", note, "@i", lease.Id, "@w", lease.WorkerId, "@a", lease.Attempt) > 0;
        }

        /// <summary>Puts expired leases back to Available (AcquireLease does it implicitly); returns how many.</summary>
        public int ReclaimExpiredLeases()
        {
            ThrowIfBad(); ThrowIfReadOnly();
            lock (_catLock) return Run(_cat, "UPDATE work_units SET state='Available', worker_id=NULL, expires=NULL WHERE state='Leased' AND expires<@n", "@n", Now);
        }

        public void ResetWorkUnit(long unitId)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            lock (_catLock) Run(_cat, "UPDATE work_units SET state='Available', worker_id=NULL, expires=NULL, attempt=0 WHERE id=@i", "@i", unitId);
        }

        public IReadOnlyList<WorkProgress> GetWorkProgress(long? lotId = null)
        {
            var list = new Dictionary<string, WorkProgress>();
            DateTimeOffset now = Now;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT kind,state,expires FROM work_units" + (lotId.HasValue ? " WHERE lot_id=@l" : ""), "@l", lotId))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    string k = r.GetString(0);
                    if (!list.TryGetValue(k, out var w)) list[k] = w = new WorkProgress { Kind = k };
                    switch (r.GetString(1))
                    {
                        case "Available": w.Available++; break;
                        case "Done": w.Done++; break;
                        case "Failed": w.Failed++; break;
                        default: if (!r.IsDBNull(2) && r.GetInt64(2) < now.UtcTicks) w.Expired++; else w.Leased++; break;
                    }
                }
            return list.Values.OrderBy(x => x.Kind).ToList();
        }

        #endregion

        // =====================================================================================================
        #region Import journal

        public long BeginImportSession(string conversationKey, int sliceNo, string appId, DateTimeOffset conversationCreationUtc, string targetConversationId = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (string.IsNullOrEmpty(appId)) throw new ArgumentException("appId");
            lock (_catLock)
            {
                Run(_cat, "INSERT INTO import_sessions(conv_key,slice_no,app_id,target_conv,creation_dt,started,state) VALUES(@c,@s,@a,@t,@cd,@n,'Started')",
                    "@c", conversationKey, "@s", sliceNo, "@a", appId, "@t", targetConversationId, "@cd", conversationCreationUtc, "@n", Now);
                return Convert.ToInt64(Scalar(_cat, "SELECT last_insert_rowid()"), CultureInfo.InvariantCulture);
            }
        }

        public void CompleteImportSession(long sessionId, ImportSessionState state = ImportSessionState.Completed, string note = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (state == ImportSessionState.Started) throw new ArgumentException("state");
            lock (_catLock) Run(_cat, "UPDATE import_sessions SET state=@s, completed=@t, note=COALESCE(@n,note) WHERE id=@i", "@s", state.ToString(), "@t", Now, "@n", note, "@i", sessionId);
        }

        static ImportSession ReadSession(SqliteDataReader r)
        {
            return new ImportSession
            {
                Id = r.GetInt64(0), ConversationKey = r.GetString(1), SliceNo = r.GetInt32(2), AppId = r.GetString(3), TargetConversationId = Str(r, 4), ConversationCreationUtc = Dt(r, 5).Value,
                StartedUtc = Dt(r, 6).Value, CompletedUtc = Dt(r, 7), State = (ImportSessionState)Enum.Parse(typeof(ImportSessionState), r.GetString(8)), Note = Str(r, 9)
            };
        }
        const string SessionCols = "id,conv_key,slice_no,app_id,target_conv,creation_dt,started,completed,state,note";

        /// <summary>The newest session of (conversation, slice), whatever its state: resume it (same app) or open a new one.</summary>
        public ImportSession GetLatestImportSession(string conversationKey, int sliceNo)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + SessionCols + " FROM import_sessions WHERE conv_key=@c AND slice_no=@s ORDER BY id DESC LIMIT 1", "@c", conversationKey, "@s", sliceNo))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadSession(r) : null;
        }

        public IEnumerable<ImportSession> ListImportSessions(string conversationKey, int? sliceNo = null)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + SessionCols + " FROM import_sessions WHERE conv_key=@c" + (sliceNo.HasValue ? " AND slice_no=@s" : "") + " ORDER BY id", "@c", conversationKey, "@s", sliceNo))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadSession(r);
        }

        /// <summary>Registers the source message ids of (conversation, slice) in import order, as Pending. Ids already journaled are left alone. Returns the number added.</summary>
        public int SeedJournal(string conversationKey, int sliceNo, IEnumerable<string> orderedSourceMessageIds)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            int added = 0;
            InCatalogTransaction(() =>
            {
                long ord = Convert.ToInt64(Scalar(_cat, "SELECT COALESCE(MAX(ord),0) FROM import_messages WHERE conv_key=@c AND slice_no=@s", "@c", conversationKey, "@s", sliceNo), CultureInfo.InvariantCulture);
                using (var cmd = Cmd(_cat, "INSERT OR IGNORE INTO import_messages(conv_key,src_id,slice_no,ord,status,updated) VALUES(@c,@m,@s,@o,0,@u)"))
                {
                    cmd.Parameters.AddWithValue("@c", conversationKey); cmd.Parameters.AddWithValue("@s", sliceNo); cmd.Parameters.AddWithValue("@u", Now.UtcTicks);
                    var pm = AddP(cmd, "@m"); var po = AddP(cmd, "@o");
                    foreach (var id in orderedSourceMessageIds)
                    {
                        pm.Value = id; po.Value = ord + 1;
                        if (cmd.ExecuteNonQuery() > 0) { ord++; added++; }
                    }
                }
            });
            return added;
        }

        static JournalEntry ReadJournal(SqliteDataReader r)
        {
            return new JournalEntry
            {
                ConversationKey = r.GetString(0), SourceMessageId = r.GetString(1), SliceNo = r.GetInt32(2), Ordinal = (int)r.GetInt64(3), Status = (JournalStatus)r.GetInt32(4), TargetMessageId = Str(r, 5), ErrorCode = Str(r, 6),
                SessionId = r.IsDBNull(7) ? (long?)null : r.GetInt64(7), Attempts = r.GetInt32(8), UpdatedUtc = Dt(r, 9)
            };
        }
        const string JournalCols = "conv_key,src_id,slice_no,ord,status,target_id,error,session_id,attempts,updated";

        /// <summary>Resume query: the next n Pending messages of the conversation in this slice, in import order.</summary>
        public IReadOnlyList<JournalEntry> NextPending(string conversationKey, int sliceNo, int n)
        {
            var l = new List<JournalEntry>();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + JournalCols + " FROM import_messages WHERE conv_key=@c AND slice_no=@s AND status=0 ORDER BY ord LIMIT @n", "@c", conversationKey, "@s", sliceNo, "@n", Math.Max(0, n)))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) l.Add(ReadJournal(r));
            return l;
        }

        public IEnumerable<JournalEntry> ListJournal(string conversationKey, int sliceNo, JournalStatus? status = null)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + JournalCols + " FROM import_messages WHERE conv_key=@c AND slice_no=@s" + (status.HasValue ? " AND status=@st" : "") + " ORDER BY ord", "@c", conversationKey, "@s", sliceNo, "@st", status))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadJournal(r);
        }

        public JournalEntry GetJournalEntry(string conversationKey, string sourceMessageId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + JournalCols + " FROM import_messages WHERE conv_key=@c AND src_id=@m", "@c", conversationKey, "@m", sourceMessageId))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadJournal(r) : null;
        }

        /// <summary>Counts per status for (conversation, slice).</summary>
        public IReadOnlyDictionary<JournalStatus, int> GetJournalSummary(string conversationKey, int sliceNo)
        {
            var d = new Dictionary<JournalStatus, int>();
            foreach (JournalStatus s in Enum.GetValues(typeof(JournalStatus))) d[s] = 0;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT status,COUNT(*) FROM import_messages WHERE conv_key=@c AND slice_no=@s GROUP BY status", "@c", conversationKey, "@s", sliceNo))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) d[(JournalStatus)r.GetInt32(0)] = r.GetInt32(1);
            return d;
        }

        static string Nz(string s) { return string.IsNullOrEmpty(s) ? null : s; }

        public void MarkJournal(JournalMark mark) { MarkJournal(new[] { mark }); }

        /// <summary>
        /// Records outcomes in one transaction. A message already Imported / Conflict409TreatedAsImported keeps an imported status
        /// (it can only be re-marked as imported, e.g. to learn its target id): nothing is ever sent twice. A message not seeded yet is added.
        /// </summary>
        public void MarkJournal(IEnumerable<JournalMark> marks)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                foreach (var m in marks)
                {
                    int n = Run(_cat, @"UPDATE import_messages SET status=@s, target_id=COALESCE(@t,target_id), error=@e, session_id=COALESCE(@sid,session_id), attempts=attempts+1, updated=@u
WHERE conv_key=@c AND src_id=@m AND (status NOT IN (1,2) OR @s IN (1,2))", "@s", m.Status, "@t", Nz(m.TargetMessageId), "@e", Nz(m.ErrorCode), "@sid", m.SessionId, "@u", Now, "@c", m.ConversationKey, "@m", m.SourceMessageId);
                    if (n == 0 && Scalar(_cat, "SELECT 1 FROM import_messages WHERE conv_key=@c AND src_id=@m", "@c", m.ConversationKey, "@m", m.SourceMessageId) == null)
                        Run(_cat, @"INSERT INTO import_messages(conv_key,src_id,slice_no,ord,status,target_id,error,session_id,attempts,updated)
VALUES(@c,@m,@sl,(SELECT COALESCE(MAX(ord),0)+1 FROM import_messages WHERE conv_key=@c AND slice_no=@sl),@s,@t,@e,@sid,1,@u)",
                            "@c", m.ConversationKey, "@m", m.SourceMessageId, "@sl", m.SliceNo, "@s", m.Status, "@t", Nz(m.TargetMessageId), "@e", Nz(m.ErrorCode), "@sid", m.SessionId, "@u", Now);
                }
            });
        }

        #endregion

        // =====================================================================================================
        #region Ghost accounts

        static GhostRecord ReadGhost(SqliteDataReader r)
        {
            return new GhostRecord
            {
                SourceUserId = r.GetString(0), GhostId = Str(r, 1), DisplayName = Str(r, 2), UserPrincipalName = Str(r, 3), State = (GhostState)Enum.Parse(typeof(GhostState), r.GetString(4)),
                CreatedUtc = Dt(r, 5), UpdatedUtc = Dt(r, 6), Error = Str(r, 7)
            };
        }
        const string GhostCols = "source_user_id,ghost_id,display_name,upn,state,created,updated,error";

        public GhostRecord GetGhost(string sourceUserId)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + GhostCols + " FROM ghosts WHERE source_user_id=@i", "@i", sourceUserId))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadGhost(r) : null;
        }

        public IEnumerable<GhostRecord> ListGhosts(GhostState? state = null)
        {
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + GhostCols + " FROM ghosts" + (state.HasValue ? " WHERE state=@s" : "") + " ORDER BY source_user_id", "@s", state?.ToString()))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadGhost(r);
        }

        /// <summary>Plans or records a ghost. One source id keeps ONE ghost id for the whole project: changing it is refused.</summary>
        public void UpsertGhost(GhostRecord g)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (g == null || string.IsNullOrEmpty(g.SourceUserId)) throw new ArgumentException("SourceUserId");
            InCatalogTransaction(() =>
            {
                object cur = Scalar(_cat, "SELECT ghost_id FROM ghosts WHERE source_user_id=@i", "@i", g.SourceUserId);
                if (cur != null && g.GhostId != null && !string.Equals((string)cur, g.GhostId, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Source user " + g.SourceUserId + " already has ghost " + cur + "; it cannot be mapped to " + g.GhostId + ".");
                DateTimeOffset now = Now;
                Run(_cat, @"INSERT INTO ghosts(source_user_id,ghost_id,display_name,upn,state,created,updated,error) VALUES(@i,@g,@d,@u,@s,@c,@n,@e)
ON CONFLICT(source_user_id) DO UPDATE SET ghost_id=COALESCE(excluded.ghost_id,ghost_id), display_name=COALESCE(excluded.display_name,display_name), upn=COALESCE(excluded.upn,upn),
  state=excluded.state, created=COALESCE(created,excluded.created), updated=excluded.updated, error=excluded.error",
                    "@i", g.SourceUserId, "@g", cur != null ? (string)cur : g.GhostId, "@d", g.DisplayName, "@u", g.UserPrincipalName, "@s", g.State.ToString(), "@c", g.State == GhostState.Created ? (g.CreatedUtc ?? now) : g.CreatedUtc, "@n", now, "@e", g.Error);
            });
        }

        public void SetGhostState(string sourceUserId, GhostState state, string error = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            lock (_catLock)
                if (Run(_cat, "UPDATE ghosts SET state=@s, error=@e, updated=@n, created=CASE WHEN @s='Created' THEN COALESCE(created,@n) ELSE created END WHERE source_user_id=@i", "@s", state.ToString(), "@e", error, "@n", Now, "@i", sourceUserId) == 0)
                    throw new KeyNotFoundException("No ghost for source user " + sourceUserId);
        }

        /// <summary>Feeds the author list directly (the importer, tests). AppendMessages already records every from.user.id it sees.</summary>
        public void RegisterAuthors(IEnumerable<(string userId, string displayName, string identityType)> authors)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            InCatalogTransaction(() =>
            {
                foreach (var a in authors)
                    Run(_cat, "INSERT INTO authors(user_id,display_name,identity_type,first_seen) VALUES(@i,@d,@t,@s) ON CONFLICT(user_id) DO UPDATE SET display_name=COALESCE(excluded.display_name,display_name), identity_type=COALESCE(excluded.identity_type,identity_type)",
                        "@i", a.userId, "@d", a.displayName, "@t", a.identityType, "@s", Now);
            });
        }

        /// <summary>
        /// Message authors that need a ghost: seen as from.user.id but absent from the user inventory, or inventoried as Deleted, with
        /// no ghost yet (excludeMapped). Guests and federated identities are not candidates (phase 0: accepted as authors).
        /// </summary>
        public IReadOnlyList<GhostCandidate> FindGhostCandidates(bool excludeMapped = true)
        {
            ThrowIfBad();
            if (!_o.ReadOnly) FlushAuthors();
            var l = new List<GhostCandidate>();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, @"SELECT a.user_id, COALESCE(a.display_name,u.display), a.identity_type, a.first_conv, CASE WHEN u.id IS NULL THEN 'NotInInventory' ELSE 'Deleted' END
FROM authors a LEFT JOIN users u ON u.id=a.user_id
WHERE (u.id IS NULL OR u.state=2) AND (a.identity_type IS NULL OR a.identity_type='aadUser')" +
                (excludeMapped ? " AND NOT EXISTS (SELECT 1 FROM ghosts g WHERE g.source_user_id=a.user_id)" : "") + " ORDER BY a.user_id"))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) l.Add(new GhostCandidate { UserId = r.GetString(0), DisplayName = Str(r, 1), IdentityType = Str(r, 2), FirstConversation = Str(r, 3), Reason = r.GetString(4) });
            return l;
        }

        static string Csv(string s)
        {
            if (s == null) return "";
            if (s.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0) return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }

        /// <summary>The ghost mapping as CSV for review (design 3.6). Returns the number of rows.</summary>
        public int ExportGhostsCsv(string path)
        {
            int n = 0;
            using (var w = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                w.WriteLine("SourceUserId,GhostId,DisplayName,UserPrincipalName,State,CreatedUtc,Error");
                foreach (var g in ListGhosts())
                {
                    w.WriteLine(string.Join(",", Csv(g.SourceUserId), Csv(g.GhostId), Csv(g.DisplayName), Csv(g.UserPrincipalName), g.State, g.CreatedUtc.HasValue ? g.CreatedUtc.Value.UtcDateTime.ToString("O", CultureInfo.InvariantCulture) : "", Csv(g.Error)));
                    n++;
                }
            }
            return n;
        }

        #endregion

        // =====================================================================================================
        #region Merge

        /// <summary>
        /// Folds another store (a worker's, closed or read-only) into this one: catalog inventory, checkpoints (this store wins),
        /// files (Downloaded wins), hosted contents, authors, ghosts, every message (through the normal version rules, so a
        /// newer version wins and a second run changes nothing), and the content blobs. Lots, leases and import sessions
        /// are NOT merged: the coordinator's catalog is authoritative for them. Both stores must have the same partition count.
        /// </summary>
        public StoreMergeReport Merge(string otherStoreRoot)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            string full = Path.GetFullPath(otherStoreRoot).TrimEnd('\\', '/');
            if (string.Equals(full, _root, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Cannot merge a store into itself.");
            int theirs = PeekPartitions(full);
            if (theirs == 0) throw new FileNotFoundException("No store at " + full);
            if (theirs != _partitions) throw new InvalidOperationException("Partition count mismatch: the store to merge has " + theirs + " partitions, this one " + _partitions + ".");
            var rep = new StoreMergeReport();
            Flush();
            using (var other = Open(full, new StoreOptions { Partitions = theirs, ReadOnly = true }))
            {
                MergeCatalog(other, rep);
                for (int i = 0; i < _partitions; i++)
                {
                    var op = other.PartAt(i);
                    if (!File.Exists(op.DbPath)) continue;
                    MergePartition(other, op, rep);
                    rep.PartitionsMerged++;
                }
                Flush();
                MergeContent(other, rep);
            }
            return rep;
        }

        void MergeCatalog(TmtStore other, StoreMergeReport rep)
        {
            lock (_catLock)
            {
                Run(_cat, "ATTACH DATABASE @p AS o", "@p", other._catalogPath);
                try
                {
                    Exec(_cat, "BEGIN IMMEDIATE");
                    try
                    {
                        rep.Users += Run(_cat, @"INSERT INTO users(id,upn,display,mail,state,tenant) SELECT id,upn,display,mail,state,tenant FROM o.users WHERE true
ON CONFLICT(id) DO UPDATE SET upn=COALESCE(excluded.upn,upn), display=COALESCE(excluded.display,display), mail=COALESCE(excluded.mail,mail),
  state=CASE WHEN excluded.state<>5 THEN excluded.state ELSE state END, tenant=COALESCE(excluded.tenant,tenant)");
                        rep.Conversations += Run(_cat, @"INSERT INTO conversations(" + ConvCols + ") SELECT " + ConvCols + @" FROM o.conversations WHERE true
ON CONFLICT(key) DO UPDATE SET kind=excluded.kind, chat_id=COALESCE(excluded.chat_id,chat_id), team_id=COALESCE(excluded.team_id,team_id), channel_id=COALESCE(excluded.channel_id,channel_id),
  membership=COALESCE(excluded.membership,membership), topic=COALESCE(excluded.topic,topic), team_name=COALESCE(excluded.team_name,team_name), created=COALESCE(excluded.created,created),
  last_activity=CASE WHEN excluded.last_activity IS NOT NULL AND (last_activity IS NULL OR excluded.last_activity>last_activity) THEN excluded.last_activity ELSE last_activity END,
  members_json=COALESCE(excluded.members_json,members_json), member_count=CASE WHEN excluded.members_json IS NOT NULL THEN excluded.member_count ELSE member_count END,
  has_imported=COALESCE(excluded.has_imported,has_imported)");
                        rep.Links += Run(_cat, "INSERT OR IGNORE INTO user_conversations(user_id,conv_key) SELECT user_id,conv_key FROM o.user_conversations");
                        rep.Checkpoints += Run(_cat, "INSERT OR IGNORE INTO checkpoints(scope,value,updated) SELECT scope,value,updated FROM o.checkpoints");
                        rep.Files += Run(_cat, @"INSERT INTO files(conv_key,message_id,attachment_id,name,source_url,drive_id,item_id,etag,size,status,error,sha256,attempts,updated)
SELECT conv_key,message_id,attachment_id,name,source_url,drive_id,item_id,etag,size,status,error,sha256,attempts,updated FROM o.files WHERE true
ON CONFLICT(conv_key,message_id,attachment_id) DO UPDATE SET name=COALESCE(excluded.name,name), status=1, error=NULL, sha256=excluded.sha256, updated=excluded.updated
WHERE excluded.status=1 AND files.status<>1");
                        rep.HostedContents += Run(_cat, "INSERT OR IGNORE INTO hosted(conv_key,message_id,hosted_id,sha256,length,content_type) SELECT conv_key,message_id,hosted_id,sha256,length,content_type FROM o.hosted");
                        rep.Authors += Run(_cat, "INSERT OR IGNORE INTO authors(user_id,display_name,identity_type,first_conv,first_seen) SELECT user_id,display_name,identity_type,first_conv,first_seen FROM o.authors");
                        rep.Ghosts += Run(_cat, "INSERT OR IGNORE INTO ghosts(source_user_id,ghost_id,display_name,upn,state,created,updated,error) SELECT source_user_id,ghost_id,display_name,upn,state,created,updated,error FROM o.ghosts");
                        Exec(_cat, "COMMIT");
                    }
                    catch { try { Exec(_cat, "ROLLBACK"); } catch { } throw; }
                }
                finally { try { Exec(_cat, "DETACH DATABASE o"); } catch { } }
            }
        }

        void MergePartition(TmtStore other, Partition op, StoreMergeReport rep)
        {
            using (var db = other.OpenConn(op.DbPath, true, 0))
            using (var cache = new BlockCache(op.SegDir, db))
            using (var cmd = Cmd(db, @"SELECT c.key,m.id,m.reply_to,m.created,m.modified,m.etag,m.sha,m.bid,m.ioff,m.len,b.seg,b.off,b.clen,b.blen
FROM messages m JOIN convs c ON c.cid=m.cid JOIN blocks b ON b.bid=m.bid ORDER BY m.cid, b.seg, b.off, m.ioff"))
            using (var r = cmd.ExecuteReader())
            {
                string conv = null; int inBatch = 0;
                Partition dp = null; long cid = -1; bool locked = false;
                var res = new MessageWriteResult();
                Action release = () =>
                {
                    if (!locked) return;
                    if (dp.PendingCount >= _o.BatchSize || dp.BufLen >= _o.MaxPendingBytes) dp.FlushLocked(this);
                    System.Threading.Monitor.Exit(dp.Gate); locked = false;
                };
                try
                {
                    while (r.Read())
                    {
                        string key = r.GetString(0);
                        if (key != conv || inBatch >= 500)
                        {
                            release();
                            conv = key; inBatch = 0;
                            dp = PartOf(key);
                            System.Threading.Monitor.Enter(dp.Gate); locked = true;
                            dp.EnsureOpenLocked(this);
                            cid = dp.LookupCid(key);
                        }
                        byte[] blk = cache.Block(r.GetInt64(7), r.GetInt64(10), r.GetInt64(11), r.GetInt64(12), r.GetInt64(13));
                        var line = new ReadOnlySpan<byte>(blk, (int)r.GetInt64(8), (int)r.GetInt64(9));
                        dp.AcceptLocked(key, cid, r.GetString(1), Str(r, 2), r.GetInt64(3), r.IsDBNull(4) ? (long?)null : r.GetInt64(4), Str(r, 5), (byte[])r["sha"], line, res);
                        inBatch++;
                    }
                }
                finally { release(); }
                rep.MessagesNew += res.New; rep.MessagesUpdated += res.Updated; rep.MessagesUnchanged += res.Unchanged;
            }
        }

        void MergeContent(TmtStore other, StoreMergeReport rep)
        {
            if (!Directory.Exists(other._contentRoot)) return;
            string tmpDir = Path.Combine(other._contentRoot, "tmp") + Path.DirectorySeparatorChar;
            foreach (var f in Directory.EnumerateFiles(other._contentRoot, "*", SearchOption.AllDirectories))
            {
                if (f.StartsWith(tmpDir, StringComparison.OrdinalIgnoreCase)) continue;
                string sha = Path.GetFileName(f);
                if (!IsSha(sha)) continue;
                string dest = ContentPath(sha);
                if (File.Exists(dest)) { rep.ContentPresent++; continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                string tmp = Path.Combine(_contentRoot, "tmp", Guid.NewGuid().ToString("N"));
                File.Copy(f, tmp);
                try { File.Move(tmp, dest); rep.ContentCopied++; }
                catch (IOException) when (File.Exists(dest)) { try { File.Delete(tmp); } catch { } rep.ContentPresent++; }
            }
        }

        #endregion
    }
}
