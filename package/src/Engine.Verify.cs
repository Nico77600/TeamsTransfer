// =============================================================================
//  TeamsTransfer - engine, lot J part 3: verification after the import (design 5, "Verification") and the lot report
// -----------------------------------------------------------------------------
//  Phase 0: imported messages (lastModifiedDateTime = 0001-01-01) are INVISIBLE to getAllMessages, so the target is read per chat / per channel:
//    chats     GET /chats/{id}/messages?$top=50, every page (an $orderby / $filter on lastModifiedDateTime is useless for imported messages), then the
//              createdDateTime of each message is bucketed CLIENT-SIDE into the slice windows of the lot items.
//    channels  GET /teams/{t}/channels/{c}/messages?$top=50&$expand=replies (the endpoint refuses $orderby and $filter); when the answer carries no
//              "replies" array (or a replies@odata.nextLink) the replies of that root are read from .../messages/{id}/replies.
//  One pass over the target conversation serves all its slices.
//
//  Unit of verification = (conversation, slice) of a lot; the window of a slice is the union of its lot items (fragments), from inclusive, to exclusive.
//  Compared, per (conversation, slice):
//    - the journal (Imported + Conflict409TreatedAsImported = what must be on the target) with the source count of the store in the window and
//      with the number of messages found on the target in the window;
//    - a deterministic random sample (reservoir, SampleSize per slice, seeded by the conversation key) message by message: createdDateTime (the
//      key), author (through the identity map: Mapped/Same/Ghost -> TargetUserId, ServiceAccount -> the service account), body hash;
//    - reactions and file (reference) attachments: totals over the window. ADVISORY by default (they are reported in the CSV and the detail and
//      do not change the outcome) because the importer legitimately drops what it cannot rewrite; ReactionsAndFilesStrict turns them into a Mismatch.
//      Reactions per message are capped at 250 on the expected side (the import limit). The totals are compared only when the journal holds no
//      Skipped / Rejected message, otherwise they are reported as "not compared".
//    - migrationMode of the conversation: must read "completed"; an absent value is accepted only when the latest import session of the slice is
//      recorded Completed in the journal (to be confirmed on the real service by the lab test); "inProgress" = NotCompleted.
//  BODY NORMALISATION (same function for source and target, so the hash ignores what the service and the importer rewrite):
//    1. the fallback banner of ImportRunOptions.FallbackBannerFormat is removed from the START of the target text;
//    2. tags <img>, <attachment>, <codeblock> content markers are dropped, <at id=..>name</at> keeps "name"; every other tag is removed;
//    3. HTML entities are decoded, every run of whitespace (nbsp included) becomes one space, the text is trimmed;
//    4. SHA-256 of the lower-cased UTF-8 text.
//  Unverified    the target read was refused (401/403): the permission is named in the detail; resumable once granted (not a Mismatch).
//  TARGET MESSAGES counted = messageType "message" and not deleted; system events (chat created, members added, migration markers) are reported as info only.
//  SAMPLE = only messages the journal says Imported / Conflict409; when the journal ErrorCode records dropped parts (AttachmentNotCopied...) the body is
//  compared without them (attachment names removed, target words a subsequence of the source) and reported as info.
//  OUTCOMES (priority Missing > NotCompleted > Mismatch > OK):
//    Missing       the target conversation is not mapped, not created, or answers 404; or the journal says N imported and the target holds none.
//    NotCompleted  migrationMode is not completed, the journal still has Pending messages, or nothing was imported yet for a non-empty slice.
//    Mismatch      fewer messages on the target than imported, journal rows missing or Rejected, an extra message on the target (unless the scenario is
//                  a restore into the same tenant, where messages that were already there are expected), a failed sample, an unreadable target.
//    OK            everything above agrees.
//  LOT STATE: when EVERY item of the lot is OK the items are set Verified and the lot Verified, through the legal transitions only
//  (Importing -> Completing -> Verified when the importer did not already move them). Anything else leaves the states untouched.
//
//  Graph permissions (application, target tenant): Chat.Read.All (chat messages and migrationMode), ChannelMessage.Read.All (channel messages and
//  replies), Channel.ReadBasic.All + Team.ReadBasic.All (migrationMode of a channel). Read only.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    public enum VerifyOutcome { OK, Mismatch, Missing, NotCompleted, Unverified }

    public sealed class VerifyOptions
    {
        public int Parallelism { get; set; } = 8;
        public int SampleSize { get; set; } = 10;
        public int PageSize { get; set; } = 50;
        public bool ReactionsAndFilesStrict { get; set; }
        /// <summary>Messages already on the target (not imported by this lot) are not a mismatch. Null = true for SameTenantRestore only.</summary>
        public bool? AllowExtraOnTarget { get; set; }
        /// <summary>Set items and lot to Verified when everything is OK.</summary>
        public bool UpdateLotState { get; set; } = true;
        /// <summary>Folder for the persisted rows (read back by Report). Null = &lt;store root&gt;\verify. Empty string = do not persist.</summary>
        public string ResultsFolder { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    public sealed class VerifyItem
    {
        public string Lot { get; set; }
        public string ConversationKey { get; set; }
        public int SliceNo { get; set; }
        public VerifyOutcome Outcome { get; set; }
        public string TargetKind { get; set; }
        public string TargetId { get; set; }
        public string MigrationMode { get; set; }
        public long SourceMessages { get; set; }
        public long JournalImported { get; set; }
        public long JournalConflict { get; set; }
        public long JournalSkipped { get; set; }
        public long JournalRejected { get; set; }
        public long JournalPending { get; set; }
        public long TargetMessages { get; set; }
        public long ExtraOnTarget { get; set; }
        public long MissingOnTarget { get; set; }
        public int SamplesChecked { get; set; }
        public int SamplesFailed { get; set; }
        public long ReactionsExpected { get; set; }
        public long ReactionsTarget { get; set; }
        public long FileRefsExpected { get; set; }
        public long FileRefsTarget { get; set; }
        public string Detail { get; set; }
        /// <summary>System events (chat created, members added, migration markers) found on the target in the window: info only, never counted.</summary>
        public long TargetSystemEvents { get; set; }
        public DateTimeOffset VerifiedUtc { get; set; }
        public string Key { get { return ConversationKey + "#" + SliceNo; } }
    }

    public sealed class VerifyResult
    {
        public long LotId { get; set; }
        public string LotName { get; set; }
        public List<VerifyItem> Items { get; } = new List<VerifyItem>();
        public int Ok { get; set; }
        public int Mismatch { get; set; }
        public int Missing { get; set; }
        public int NotCompleted { get; set; }
        /// <summary>The target could not be read (401/403: a permission is missing): resumable once it is granted.</summary>
        public int Unverified { get; set; }
        public long SourceMessages { get; set; }
        public long TargetMessages { get; set; }
        public int Conversations { get; set; }
        public LotState? LotStateBefore { get; set; }
        public LotState? LotStateAfter { get; set; }
        public int ItemsSetVerified { get; set; }
        public bool Stopped { get; set; }
        public TimeSpan Duration { get; set; }
        public string ResultsFile { get; set; }
        public List<ErrorRecord> Errors { get; } = new List<ErrorRecord>();
        public bool AllOk { get { return Items.Count > 0 && Mismatch == 0 && Missing == 0 && NotCompleted == 0 && Unverified == 0; } }

        public string ToText()
        {
            return "Lot " + LotName + ": " + Items.Count + " conversation-slice(s): OK " + Ok + ", Mismatch " + Mismatch + ", Missing " + Missing + ", NotCompleted " + NotCompleted + ", Unverified " + Unverified +
                "; source " + SourceMessages.ToString("N0", CultureInfo.InvariantCulture) + " / target " + TargetMessages.ToString("N0", CultureInfo.InvariantCulture) + " messages" +
                (LotStateAfter.HasValue ? "; lot " + LotStateBefore + " -> " + LotStateAfter : "");
        }
    }

    public sealed class Verifier
    {
        private readonly GraphClient _g;
        private readonly TmtStore _store;
        private readonly ITargetMap _targets;
        private readonly IIdentityMap _ids;
        private readonly ImportRunOptions _run;
        private readonly VerifyOptions _o;
        private readonly Func<DateTimeOffset> _now;
        private ProgressReporter _p;
        private readonly Regex _banner;
        private static readonly Regex TagRx = new Regex("<[^>]*>", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly Regex DropRx = new Regex(@"<(img|attachment|codeblock)\b[^>]*>(\s*</\1>)?", RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
        private static readonly Regex WsRx = new Regex(@"[\s ]+", RegexOptions.Compiled | RegexOptions.CultureInvariant);

        public Verifier(GraphClient target, TmtStore store, ITargetMap targets, ImportRunOptions run, IIdentityMap ids = null, VerifyOptions options = null)
        {
            if (target == null) throw new ArgumentNullException("target");
            if (store == null) throw new ArgumentNullException("store");
            if (targets == null) throw new ArgumentNullException("targets");
            _g = target; _store = store; _targets = targets; _ids = ids; _run = run ?? new ImportRunOptions(); _o = options ?? new VerifyOptions();
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _p = new ProgressReporter("Verify", _o.OnProgress, _now);
            _banner = BuildBannerRegex(_run.FallbackBannerFormat);
        }

        public ProgressSnapshot Progress { get { return _p.Snapshot(); } }

        // ------------------------------------------------------------------ normalisation (public: documented and tested)

        private static Regex BuildBannerRegex(string format)
        {
            if (string.IsNullOrWhiteSpace(format)) return null;
            try
            {
                string text = WsRx.Replace(System.Net.WebUtility.HtmlDecode(TagRx.Replace(format.Replace("{0}", "\u0001").Replace("{1}", "\u0002").Replace("{2}", "\u0003"), "")), " ").Trim();
                string pat = Regex.Escape(text).Replace("\u0001", ".*?").Replace("\u0002", ".*?").Replace("\u0003", ".*?");
                return new Regex("^" + pat + @"\s*", RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
            }
            catch (ArgumentException) { return null; }
        }

        /// <summary>The text that is hashed: see the header of this file. isTarget removes the fallback banner.</summary>
        public string NormalizeBody(string content, bool isTarget)
        {
            string s = content ?? "";
            s = DropRx.Replace(s, " ");
            s = TagRx.Replace(s, " ");
            s = System.Net.WebUtility.HtmlDecode(s);
            s = WsRx.Replace(s, " ").Trim();
            if (isTarget && _banner != null) s = _banner.Replace(s, "").Trim();
            return s;
        }

        public string BodyHash(string content, bool isTarget)
        {
            using (var sha = SHA256.Create())
                return Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(NormalizeBody(content, isTarget).ToLowerInvariant()))).ToLowerInvariant();
        }

        // ------------------------------------------------------------------ model of one message

        private struct Brief
        {
            public long CreatedMs; public string Id, Author, Hash, Text; public int Reactions, FileRefs; public string[] Names;
        }

        private Brief BriefOf(JsonElement m, bool isTarget, bool withHash)
        {
            var b = new Brief { Id = ExportUtil.Str(m, "id") };
            var created = ExportUtil.Date(m, "createdDateTime");
            b.CreatedMs = created.HasValue ? created.Value.UtcTicks / 10000 : 0;
            JsonElement from, user, arr;
            if (m.TryGetProperty("from", out from) && from.ValueKind == JsonValueKind.Object && from.TryGetProperty("user", out user) && user.ValueKind == JsonValueKind.Object) b.Author = ExportUtil.Str(user, "id");
            if (m.TryGetProperty("reactions", out arr) && arr.ValueKind == JsonValueKind.Array) b.Reactions = arr.GetArrayLength();
            var names = new List<string>();
            if (m.TryGetProperty("attachments", out arr) && arr.ValueKind == JsonValueKind.Array)
                foreach (var a in arr.EnumerateArray())
                {
                    if (string.Equals(ExportUtil.Str(a, "contentType"), "reference", StringComparison.OrdinalIgnoreCase)) b.FileRefs++;
                    string an = ExportUtil.Str(a, "name"); if (!string.IsNullOrWhiteSpace(an)) names.Add(an);
                }
            b.Names = names.ToArray();
            if (withHash)
            {
                JsonElement body;
                b.Text = NormalizeBody(m.TryGetProperty("body", out body) && body.ValueKind == JsonValueKind.Object ? ExportUtil.Str(body, "content") : null, isTarget).ToLowerInvariant();
                using (var sha = SHA256.Create()) b.Hash = Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(b.Text))).ToLowerInvariant();
            }
            return b;
        }

        /// <summary>Only messageType "message" (or absent) that is not deleted counts on the target, like the planner does on the source.</summary>
        private static bool IsSystemEvent(JsonElement m)
        {
            string t = ExportUtil.Str(m, "messageType");
            return !string.IsNullOrEmpty(t) && !string.Equals(t, "message", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsDeleted(JsonElement m) { return !string.IsNullOrEmpty(ExportUtil.Str(m, "deletedDateTime")); }

        private static string[] Words(string s) { return s.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries); }

        private static string StripNames(string text, string[] names)
        {
            foreach (var n in names ?? new string[0]) { if (n.Length > 0) text = Regex.Replace(text, Regex.Escape(n.ToLowerInvariant()), " "); }
            return WsRx.Replace(text, " ").Trim();
        }

        /// <summary>True when the target text is the source text with parts removed (equal after dropping the attachment names, or a word-by-word subsequence).</summary>
        // The importer writes a visible note in place of a file it could not copy: "<p><em>[Attachment not copied: name]</em></p>"
        // (Engine.Import.cs). It is not source text: remove it before comparing (real lab case, 2026-11-10).
        private static readonly Regex DroppedNoteRx = new Regex(@"\[attachment not copied:[^\]]*\]", RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private static bool EqualWithoutDroppedParts(Brief src, Brief tgt)
        {
            string a = StripNames(src.Text ?? "", src.Names), b = StripNames(DroppedNoteRx.Replace(tgt.Text ?? "", " "), src.Names);
            if (a == b) return true;
            var sw = Words(a); var tw = Words(b);
            int i = 0;
            foreach (var w in sw) { if (i < tw.Length && tw[i] == w) i++; }
            return i == tw.Length;
        }

        // ------------------------------------------------------------------ run

        private sealed class Window { public DateTimeOffset From; public DateTimeOffset? To; public bool Contains(DateTimeOffset d) { return d >= From && (!To.HasValue || d < To.Value); } }

        private sealed class SliceAcc
        {
            public int No; public List<Window> Windows = new List<Window>();
            public long Source, Reactions, FileRefs, Seen, TargetSystemEvents;
            public HashSet<string> Eligible = new HashSet<string>(StringComparer.Ordinal);
            public Dictionary<string, string> Dropped = new Dictionary<string, string>(StringComparer.Ordinal);
            public List<Brief> Sample = new List<Brief>();
            public long TargetCount, TargetReactions, TargetFileRefs;
            public Dictionary<long, Brief> TargetSamples = new Dictionary<long, Brief>();
            public bool Contains(DateTimeOffset d) { foreach (var w in Windows) if (w.Contains(d)) return true; return false; }
        }

        public Task<VerifyResult> RunAsync(string lotName, int[] slices = null, CancellationToken ct = default(CancellationToken))
        {
            var lot = _store.GetLot(lotName);
            if (lot == null) throw new KeyNotFoundException("No lot named '" + lotName + "'");
            return RunAsync(lot.Id, slices, ct);
        }

        public async Task<VerifyResult> RunAsync(long lotId, int[] slices = null, CancellationToken ct = default(CancellationToken))
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var lot = _store.GetLot(lotId);
            if (lot == null) throw new KeyNotFoundException("No lot #" + lotId);
            var res = new VerifyResult { LotId = lotId, LotName = lot.Name, LotStateBefore = lot.State };
            _p = new ProgressReporter("Verify", _o.OnProgress, _now);
            var all = _store.ListItems(lotId).Where(i => slices == null || slices.Length == 0 || slices.Contains(i.SliceNo)).ToList();
            var byConv = all.GroupBy(i => i.ConversationKey, StringComparer.Ordinal).ToList();
            _p.Phase("verify", byConv.Count);
            var rows = new ConcurrentBag<VerifyItem>();
            try
            {
                await Par.ForEachAsync(byConv, Math.Max(1, _o.Parallelism), async (grp, token) =>
                {
                    try
                    {
                        foreach (var it in await VerifyConversationAsync(lot, grp.Key, grp.ToList(), token).ConfigureAwait(false)) rows.Add(it);
                    }
                    catch (Exception ex) when (!ExportUtil.IsCancel(ex, token))
                    {
                        Interlocked.Increment(ref _p.Errors);
                        lock (res.Errors) res.Errors.Add(ErrorRecord.From(grp.Key, "verify", ex, _now()));
                        foreach (var sno in grp.Select(i => i.SliceNo).Distinct())
                            {
                            var g = ex as GraphException;
                            bool denied = g != null && (g.StatusCode == 401 || g.StatusCode == 403);
                            rows.Add(new VerifyItem { Lot = lot.Name, ConversationKey = grp.Key, SliceNo = sno, Outcome = denied ? VerifyOutcome.Unverified : VerifyOutcome.Mismatch, Detail = (denied ? "cannot be verified: " + DeniedText(grp.Key, g) : "could not be verified: " + Short(ex.Message)), VerifiedUtc = _now() });
                        }
                    }
                    Interlocked.Increment(ref _p.UnitsDone);
                    _p.Tick();
                }, ct, _run.Stop).ConfigureAwait(false);
            }
            finally { _p.Finish(); }
            res.Stopped = StopControl.Stopped(_run.Stop);

            foreach (var r in rows.OrderBy(r => r.ConversationKey, StringComparer.Ordinal).ThenBy(r => r.SliceNo)) res.Items.Add(r);
            foreach (var r in res.Items)
            {
                switch (r.Outcome) { case VerifyOutcome.OK: res.Ok++; break; case VerifyOutcome.Mismatch: res.Mismatch++; break; case VerifyOutcome.Missing: res.Missing++; break; case VerifyOutcome.Unverified: res.Unverified++; break; default: res.NotCompleted++; break; }
                res.SourceMessages += r.SourceMessages; res.TargetMessages += r.TargetMessages;
            }
            res.Conversations = byConv.Count;

            if (_o.UpdateLotState) UpdateStates(lot, all, res);
            res.LotStateAfter = _store.GetLot(lotId).State;
            if (_o.ResultsFolder != "") res.ResultsFile = VerifyReport.SaveRows(_o.ResultsFolder ?? Path.Combine(_store.Root, "verify"), lot.Name, res.Items);
            res.Duration = sw.Elapsed;
            return res;
        }

        private static string DeniedText(string key, GraphException ex)
        {
            string perm = key.StartsWith("channel:", StringComparison.Ordinal) ? "ChannelMessage.Read.All" : "Chat.Read.All";
            return "the target read was refused (HTTP " + ex.StatusCode + " " + ex.ErrorCode + "): the application needs " + perm + " (application permission with administrator consent) on the target tenant. " + Short(ex.Message);
        }

        private static string Short(string s) { return s != null && s.Length > 300 ? s.Substring(0, 300) : s; }

        private void UpdateStates(LotInfo lot, List<LotItem> items, VerifyResult res)
        {
            var ok = new HashSet<string>(res.Items.Where(i => i.Outcome == VerifyOutcome.OK).Select(i => i.Key), StringComparer.Ordinal);
            foreach (var it in items)
            {
                if (!ok.Contains(it.ConversationKey + "#" + it.SliceNo)) continue;
                if (it.State == LotState.Verified || it.State == LotState.Closed) continue;
                try
                {
                    if (it.State == LotState.Importing) { _store.SetItemState(lot.Id, it.ConversationKey, it.SliceNo, it.Fragment, LotState.Completing); }
                    if (it.State == LotState.Importing || it.State == LotState.Completing)
                    {
                        _store.SetItemState(lot.Id, it.ConversationKey, it.SliceNo, it.Fragment, LotState.Verified);
                        res.ItemsSetVerified++;
                    }
                }
                catch (InvalidOperationException) { }
            }
            var now = _store.ListItems(lot.Id).ToList();
            if (now.Count > 0 && now.All(i => i.State == LotState.Verified || i.State == LotState.Closed))
            {
                var cur = _store.GetLot(lot.Id);
                try
                {
                    if (cur.State == LotState.Importing) _store.TransitionLot(lot.Id, LotState.Completing, "verify: every conversation completed");
                    cur = _store.GetLot(lot.Id);
                    if (cur.State == LotState.Completing) _store.TransitionLot(lot.Id, LotState.Verified, "verified: " + res.Ok + " conversation-slice(s) OK, source and target agree");
                }
                catch (InvalidOperationException) { }
            }
        }

        // ------------------------------------------------------------------ one conversation

        private string ExpectedTargetAuthor(string sourceId)
        {
            if (_ids == null || string.IsNullOrEmpty(sourceId)) return null;
            var m = _ids.Get(sourceId);
            if (m == null) return null;
            switch (m.Kind)
            {
                case IdentityKind.Mapped: case IdentityKind.Same: case IdentityKind.Ghost: return string.IsNullOrEmpty(m.TargetUserId) ? null : m.TargetUserId;
                case IdentityKind.ServiceAccount: return !string.IsNullOrEmpty(_run.ServiceAccountUserId) ? _run.ServiceAccountUserId : m.TargetUserId;
                default: return null;
            }
        }

        private async Task<List<VerifyItem>> VerifyConversationAsync(LotInfo lot, string key, List<LotItem> items, CancellationToken ct)
        {
            var slices = new SortedDictionary<int, SliceAcc>();
            foreach (var it in items)
            {
                SliceAcc a;
                if (!slices.TryGetValue(it.SliceNo, out a)) slices[it.SliceNo] = a = new SliceAcc { No = it.SliceNo };
                a.Windows.Add(new Window { From = it.FromUtc, To = it.ToUtc });
            }
            var results = new List<VerifyItem>();
            Func<SliceAcc, VerifyItem> blank = a => new VerifyItem { Lot = lot.Name, ConversationKey = key, SliceNo = a.No, VerifiedUtc = _now() };

            var t = _targets.Get(key);
            if (t == null)
            {
                foreach (var a in slices.Values) { var v = blank(a); v.Outcome = VerifyOutcome.Missing; v.Detail = "no target mapping for this conversation"; results.Add(v); }
                return results;
            }
            string kind = t.Kind.ToString();
            bool chat = t.Kind == TargetKind.ExistingChat || t.Kind == TargetKind.NewChat;
            string targetId = chat ? t.TargetChatId : (string.IsNullOrEmpty(t.TargetTeamId) ? null : t.TargetTeamId + "/" + t.TargetChannelId);
            if (t.Kind == TargetKind.Skip)
            {
                foreach (var a in slices.Values) { var v = blank(a); v.Outcome = VerifyOutcome.OK; v.TargetKind = kind; v.Detail = "target kind Skip: not imported, nothing to verify" + (string.IsNullOrEmpty(t.Note) ? "" : " (" + t.Note + ")"); results.Add(v); }
                return results;
            }
            if (string.IsNullOrEmpty(targetId) || (!chat && string.IsNullOrEmpty(t.TargetChannelId)))
            {
                foreach (var a in slices.Values) { var v = blank(a); v.Outcome = VerifyOutcome.Missing; v.TargetKind = kind; v.Detail = "the target conversation was not created (no target id in the target map)"; results.Add(v); }
                return results;
            }

            // ---- source pass (store): counts, totals and the reservoir sample, per slice
            DateTimeOffset? min = null, max = null;
            min = items.Min(i => i.FromUtc); if (items.All(i => i.ToUtc.HasValue)) max = items.Max(i => i.ToUtc.Value);
            var rng = new Random(StableSeed(key));
            foreach (var a in slices.Values)
                foreach (var je in _store.ListJournal(key, a.No))
                    if (je.Status == JournalStatus.Imported || je.Status == JournalStatus.Conflict409TreatedAsImported)
                    {
                        a.Eligible.Add(je.SourceMessageId);
                        if (!string.IsNullOrEmpty(je.ErrorCode)) a.Dropped[je.SourceMessageId] = je.ErrorCode;
                    }
            foreach (var m in _store.ReadMessages(key, min, max))
            {
                var created = ExportUtil.Date(m, "createdDateTime");
                if (!created.HasValue) continue;
                SliceAcc acc = null;
                foreach (var a in slices.Values) if (a.Contains(created.Value)) { acc = a; break; }
                if (acc == null) continue;
                acc.Source++;
                int react = 0, refs = 0; JsonElement arr;
                if (m.TryGetProperty("reactions", out arr) && arr.ValueKind == JsonValueKind.Array) react = Math.Min(250, arr.GetArrayLength());
                if (m.TryGetProperty("attachments", out arr) && arr.ValueKind == JsonValueKind.Array)
                    foreach (var at in arr.EnumerateArray()) if (string.Equals(ExportUtil.Str(at, "contentType"), "reference", StringComparison.OrdinalIgnoreCase)) refs++;
                acc.Reactions += react; acc.FileRefs += refs;
                string mid = ExportUtil.Str(m, "id");
                if (_o.SampleSize > 0 && mid != null && acc.Eligible.Contains(mid))      // only what the journal says reached the target
                {
                    acc.Seen++;
                    if (acc.Sample.Count < _o.SampleSize) acc.Sample.Add(BriefOf(m, false, true));
                    else { long j = rng.NextInt64(acc.Seen); if (j < _o.SampleSize) acc.Sample[(int)j] = BriefOf(m, false, true); }
                }
            }
            var wanted = new Dictionary<long, List<SliceAcc>>();
            foreach (var a in slices.Values) foreach (var s in a.Sample) { List<SliceAcc> l; if (!wanted.TryGetValue(s.CreatedMs, out l)) wanted[s.CreatedMs] = l = new List<SliceAcc>(); l.Add(a); }

            // ---- target: migration mode, then every message
            string mode = null;
            try
            {
                string modeUrl = chat ? "v1.0/chats/" + ExportUtil.Seg(t.TargetChatId) : "v1.0/teams/" + ExportUtil.Seg(t.TargetTeamId) + "/channels/" + ExportUtil.Seg(t.TargetChannelId);
                using (var doc = await _g.GetJsonAsync(modeUrl, chat ? EndpointClass.Chat : EndpointClass.Channels, key, ct).ConfigureAwait(false)) mode = ExportUtil.Str(doc.RootElement, "migrationMode");
                await ReadTargetAsync(t, chat, key, slices, wanted, ct).ConfigureAwait(false);
            }
            catch (GraphException ex) when (ex.StatusCode == 401 || ex.StatusCode == 403)
            {
                foreach (var a in slices.Values) { var v = blank(a); v.Outcome = VerifyOutcome.Unverified; v.TargetKind = kind; v.TargetId = targetId; v.SourceMessages = a.Source; v.Detail = "cannot be verified: " + DeniedText(key, ex); results.Add(v); }
                return results;
            }
            catch (GraphException ex) when (ex.StatusCode == 404)
            {
                foreach (var a in slices.Values) { var v = blank(a); v.Outcome = VerifyOutcome.Missing; v.TargetKind = kind; v.TargetId = targetId; v.SourceMessages = a.Source; v.Detail = "the target conversation answers 404 (not found)"; results.Add(v); }
                return results;
            }

            // ---- evaluation
            bool allowExtra = _o.AllowExtraOnTarget ?? (_run.Scenario == ImportScenario.SameTenantRestore);
            foreach (var a in slices.Values)
            {
                var v = blank(a);
                v.TargetKind = kind; v.TargetId = targetId; v.MigrationMode = mode;
                var js = _store.GetJournalSummary(key, a.No);
                v.JournalImported = js[JournalStatus.Imported]; v.JournalConflict = js[JournalStatus.Conflict409TreatedAsImported]; v.JournalSkipped = js[JournalStatus.Skipped];
                v.JournalRejected = js[JournalStatus.Rejected]; v.JournalPending = js[JournalStatus.Pending];
                long jTotal = v.JournalImported + v.JournalConflict + v.JournalSkipped + v.JournalRejected + v.JournalPending;
                long expected = v.JournalImported + v.JournalConflict;
                v.SourceMessages = a.Source; v.TargetMessages = a.TargetCount;
                v.ExtraOnTarget = Math.Max(0, a.TargetCount - expected); v.MissingOnTarget = Math.Max(0, expected - a.TargetCount);
                v.TargetSystemEvents = a.TargetSystemEvents; v.ReactionsExpected = a.Reactions; v.ReactionsTarget = a.TargetReactions; v.FileRefsExpected = a.FileRefs; v.FileRefsTarget = a.TargetFileRefs;
                var notes = new List<string>();
                bool missing = false, notCompleted = false, mismatch = false;

                var session = _store.GetLatestImportSession(key, a.No);
                bool modeOk = string.Equals(mode, "completed", StringComparison.OrdinalIgnoreCase) || (string.IsNullOrEmpty(mode) && session != null && session.State == ImportSessionState.Completed);
                if (!modeOk) { notCompleted = true; notes.Add("migrationMode is '" + (mode ?? "(absent)") + "', not completed" + (string.IsNullOrEmpty(mode) && session == null ? " and no import session is recorded" : "")); }
                if (v.JournalPending > 0) { notCompleted = true; notes.Add(v.JournalPending + " message(s) still pending in the journal"); }
                if (jTotal == 0 && a.Source > 0) { notCompleted = true; notes.Add("nothing was imported yet (the journal is empty, " + a.Source + " source message(s))"); }

                if (jTotal > 0)
                {
                    if (v.JournalRejected > 0) { mismatch = true; notes.Add(v.JournalRejected + " message(s) rejected by the service (not on the target)"); }
                    if (jTotal < a.Source) { mismatch = true; notes.Add("the journal covers " + jTotal + " of " + a.Source + " source message(s)"); }
                    if (expected > 0 && a.TargetCount == 0) { missing = true; notes.Add("the journal says " + expected + " imported, the target holds none in this window"); }
                    else if (a.TargetCount < expected) { mismatch = true; notes.Add((expected - a.TargetCount) + " imported message(s) not found on the target (target " + a.TargetCount + ", expected " + expected + ")"); }
                    else if (a.TargetCount > expected && !allowExtra) { mismatch = true; notes.Add((a.TargetCount - expected) + " extra message(s) on the target (target " + a.TargetCount + ", expected " + expected + ")"); }
                    else if (a.TargetCount > expected) notes.Add((a.TargetCount - expected) + " message(s) were already on the target (restore scenario)");
                }

                // sample
                int droppedInfo = 0; var droppedCodes = new SortedSet<string>(StringComparer.Ordinal);
                foreach (var s in a.Sample)
                {
                    v.SamplesChecked++;
                    Brief tb;
                    if (!a.TargetSamples.TryGetValue(s.CreatedMs, out tb))
                    {
                        v.SamplesFailed++; if (notes.Count < 12) notes.Add("sample " + s.Id + " (" + ExportUtil.Iso(FromMs(s.CreatedMs)) + ") not found on the target");
                        continue;
                    }
                    var problems = new List<string>();
                    string exp = ExpectedTargetAuthor(s.Author);
                    if (exp != null && !string.Equals(exp, tb.Author, StringComparison.OrdinalIgnoreCase)) problems.Add("author " + (tb.Author ?? "(none)") + " instead of " + exp);
                    if (!string.Equals(s.Hash, tb.Hash, StringComparison.Ordinal))
                    {
                        string dc;
                        if (a.Dropped.TryGetValue(s.Id, out dc) && EqualWithoutDroppedParts(s, tb)) { droppedInfo++; foreach (var c in dc.Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)) droppedCodes.Add(c); }
                        else problems.Add("body differs after normalisation" + (a.Dropped.ContainsKey(s.Id) ? " (even without the dropped parts: " + a.Dropped[s.Id] + ")" : ""));
                    }
                    if (problems.Count > 0) { v.SamplesFailed++; if (notes.Count < 12) notes.Add("sample " + s.Id + " (" + ExportUtil.Iso(FromMs(s.CreatedMs)) + "): " + string.Join(", ", problems)); }
                }
                if (v.SamplesFailed > 0) mismatch = true;
                if (droppedInfo > 0) notes.Add("info: " + droppedInfo + " sampled message(s) had dropped parts (" + string.Join(", ", droppedCodes) + "): compared without them");
                if (a.TargetSystemEvents > 0) notes.Add("info: " + a.TargetSystemEvents + " system event(s) on the target ignored");

                // reactions and files
                bool comparable = v.JournalSkipped == 0 && v.JournalRejected == 0 && jTotal > 0 && !notCompleted;
                if (comparable)
                {
                    bool rd = a.Reactions != a.TargetReactions, fd = a.FileRefs != a.TargetFileRefs;
                    if (rd) notes.Add("reactions: " + a.TargetReactions + " on the target, " + a.Reactions + " expected");
                    if (fd) notes.Add("file attachments: " + a.TargetFileRefs + " on the target, " + a.FileRefs + " expected");
                    if ((rd || fd) && _o.ReactionsAndFilesStrict) mismatch = true;
                }
                else if (jTotal > 0 && (v.JournalSkipped > 0 || v.JournalRejected > 0)) notes.Add("reactions and file attachments not compared (the journal holds skipped or rejected messages)");

                v.Outcome = missing ? VerifyOutcome.Missing : notCompleted ? VerifyOutcome.NotCompleted : mismatch ? VerifyOutcome.Mismatch : VerifyOutcome.OK;
                v.Detail = string.Join(" | ", notes);
                results.Add(v);
            }
            return results;
        }

        private static DateTimeOffset FromMs(long ms) { return new DateTimeOffset(ms * 10000, TimeSpan.Zero); }

        private static int StableSeed(string s)
        {
            unchecked { int h = 17; foreach (char c in s) h = h * 31 + c; return h; }
        }

        private async Task ReadTargetAsync(TargetMapping t, bool chat, string key, SortedDictionary<int, SliceAcc> slices, Dictionary<long, List<SliceAcc>> wanted, CancellationToken ct)
        {
            Action<JsonElement> take = m =>
            {
                var created = ExportUtil.Date(m, "createdDateTime");
                Interlocked.Increment(ref _p.Messages);
                if (!created.HasValue) return;
                SliceAcc acc = null;
                foreach (var a in slices.Values) if (a.Contains(created.Value)) { acc = a; break; }
                if (acc == null) return;
                if (IsSystemEvent(m)) { acc.TargetSystemEvents++; return; }
                if (IsDeleted(m)) return;
                var b = BriefOf(m, true, wanted.Count > 0);
                acc.TargetCount++; acc.TargetReactions += b.Reactions; acc.TargetFileRefs += b.FileRefs;
                List<SliceAcc> w;
                if (wanted.TryGetValue(b.CreatedMs, out w) && w.Contains(acc)) acc.TargetSamples[b.CreatedMs] = b;
            };
            string top = Math.Max(1, Math.Min(50, _o.PageSize)).ToString(CultureInfo.InvariantCulture);
            if (chat)
            {
                await foreach (var m in _g.GetPagedAsync("v1.0/chats/" + ExportUtil.Seg(t.TargetChatId) + "/messages?$top=" + top, EndpointClass.ChatMessages, null, null, key, ct).ConfigureAwait(false)) take(m);
                return;
            }
            string baseUrl = "v1.0/teams/" + ExportUtil.Seg(t.TargetTeamId) + "/channels/" + ExportUtil.Seg(t.TargetChannelId) + "/messages";
            await foreach (var root in _g.GetPagedAsync(baseUrl + "?$top=" + top + "&$expand=replies", EndpointClass.ChannelMessages, null, null, key, ct).ConfigureAwait(false))
            {
                take(root);
                JsonElement reps;
                bool expanded = root.TryGetProperty("replies", out reps) && reps.ValueKind == JsonValueKind.Array && !root.TryGetProperty("replies@odata.nextLink", out _);
                if (expanded) { foreach (var r in reps.EnumerateArray()) take(r); continue; }
                string id = ExportUtil.Str(root, "id");
                if (string.IsNullOrEmpty(id)) continue;
                await foreach (var r in _g.GetPagedAsync(baseUrl + "/" + ExportUtil.Seg(id) + "/replies?$top=" + top, EndpointClass.ChannelReplies, null, null, key, ct).ConfigureAwait(false)) take(r);
            }
        }
    }

    // =========================================================================================================
    //  Reports: verify.csv, verify.html, the persisted rows, and the lot report (-Mode Report)
    // =========================================================================================================

    public static class VerifyReport
    {
        static readonly string[] Cols = { "Lot", "ConversationKey", "Slice", "Outcome", "TargetKind", "TargetId", "MigrationMode", "SourceMessages", "JournalImported", "JournalConflict409", "JournalSkipped", "JournalRejected", "JournalPending",
            "TargetMessages", "ExtraOnTarget", "MissingOnTarget", "SamplesChecked", "SamplesFailed", "ReactionsExpected", "ReactionsTarget", "FileRefsExpected", "FileRefsTarget", "Detail", "VerifiedUtc", "TargetSystemEvents" };

        static string Q(string s)
        {
            if (s == null) return "";
            s = s.Replace("\r", " ").Replace("\n", " ");
            return s.IndexOfAny(new[] { ',', '"' }) >= 0 ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
        }

        static string N(long v) { return v.ToString(CultureInfo.InvariantCulture); }

        public static void WriteCsv(string path, IEnumerable<VerifyItem> items)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            using (var w = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                w.Write(string.Join(",", Cols) + "\r\n");
                foreach (var i in items)
                    w.Write(string.Join(",", Q(i.Lot), Q(i.ConversationKey), i.SliceNo.ToString(CultureInfo.InvariantCulture), i.Outcome, Q(i.TargetKind), Q(i.TargetId), Q(i.MigrationMode), N(i.SourceMessages), N(i.JournalImported), N(i.JournalConflict), N(i.JournalSkipped),
                        N(i.JournalRejected), N(i.JournalPending), N(i.TargetMessages), N(i.ExtraOnTarget), N(i.MissingOnTarget), i.SamplesChecked.ToString(CultureInfo.InvariantCulture), i.SamplesFailed.ToString(CultureInfo.InvariantCulture),
                        N(i.ReactionsExpected), N(i.ReactionsTarget), N(i.FileRefsExpected), N(i.FileRefsTarget), Q(i.Detail), i.VerifiedUtc.UtcDateTime.ToString("O", CultureInfo.InvariantCulture), N(i.TargetSystemEvents)) + "\r\n");
            }
        }

        static string SafeFile(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s ?? "lot") sb.Append(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.' ? c : '_');
            return sb.ToString();
        }

        /// <summary>Persists the rows of the lot (merged with the earlier ones by conversation + slice) for the Report mode. Returns the file.</summary>
        public static string SaveRows(string folder, string lotName, IEnumerable<VerifyItem> items)
        {
            Directory.CreateDirectory(folder);
            string file = Path.Combine(folder, SafeFile(lotName) + ".csv");
            var merged = new Dictionary<string, VerifyItem>(StringComparer.Ordinal);
            foreach (var r in LoadRows(file)) merged[r.Key] = r;
            foreach (var r in items) merged[r.Key] = r;
            string tmp = file + ".tmp";
            WriteCsv(tmp, merged.Values.OrderBy(r => r.ConversationKey, StringComparer.Ordinal).ThenBy(r => r.SliceNo));
            if (File.Exists(file)) File.Delete(file);
            File.Move(tmp, file);
            return file;
        }

        public static string RowsFileOf(TmtStore store, string lotName) { return Path.Combine(store.Root, "verify", SafeFile(lotName) + ".csv"); }

        static List<string> SplitCsv(string text, ref int pos)
        {
            var row = new List<string>(); var sb = new StringBuilder(); bool q = false;
            while (pos < text.Length)
            {
                char c = text[pos++];
                if (q) { if (c == '"') { if (pos < text.Length && text[pos] == '"') { sb.Append('"'); pos++; } else q = false; } else sb.Append(c); }
                else if (c == '"') q = true;
                else if (c == ',') { row.Add(sb.ToString()); sb.Clear(); }
                else if (c == '\r') { }
                else if (c == '\n') { row.Add(sb.ToString()); return row; }
                else sb.Append(c);
            }
            if (sb.Length > 0 || row.Count > 0) row.Add(sb.ToString());
            return row;
        }

        public static List<VerifyItem> LoadRows(string file)
        {
            var list = new List<VerifyItem>();
            if (!File.Exists(file)) return list;
            string text = File.ReadAllText(file, Encoding.UTF8);
            int pos = 0;
            var header = SplitCsv(text, ref pos);
            while (pos < text.Length)
            {
                var f = SplitCsv(text, ref pos);
                if (f.Count < Cols.Length - 1) continue;
                Func<int, long> n = i => { long v; return long.TryParse(f[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : 0; };
                VerifyOutcome oc; Enum.TryParse(f[3], out oc);
                DateTimeOffset when; DateTimeOffset.TryParse(f[23], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out when);
                list.Add(new VerifyItem
                {
                    Lot = f[0], ConversationKey = f[1], SliceNo = (int)n(2), Outcome = oc, TargetKind = f[4], TargetId = f[5], MigrationMode = f[6], SourceMessages = n(7), JournalImported = n(8), JournalConflict = n(9), JournalSkipped = n(10),
                    JournalRejected = n(11), JournalPending = n(12), TargetMessages = n(13), ExtraOnTarget = n(14), MissingOnTarget = n(15), SamplesChecked = (int)n(16), SamplesFailed = (int)n(17), ReactionsExpected = n(18), ReactionsTarget = n(19),
                    FileRefsExpected = n(20), FileRefsTarget = n(21), Detail = f[22], VerifiedUtc = when, TargetSystemEvents = f.Count > 24 ? n(24) : 0
                });
            }
            return list;
        }

        // ---- HTML (house look: same variables, font and dark mode as the run reports of the entry script)

        const string Css = ":root{color-scheme:light dark;--bg:#fff;--fg:#1b1b1f;--muted:#5f6368;--line:#d9dbe0;--ok:#1a7f37;--warn:#9a6700;--fail:#cf222e;--card:#f6f8fa}" +
            "@media (prefers-color-scheme:dark){:root{--bg:#1b1b1f;--fg:#ececf1;--muted:#a0a3ab;--line:#3a3b42;--ok:#3fb950;--warn:#d29922;--fail:#f85149;--card:#24252b}}" +
            "body{background:var(--bg);color:var(--fg);font:15px/1.5 \"Segoe UI\",system-ui,sans-serif;margin:0 auto;padding:24px 16px;max-width:1180px}" +
            "h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}p{color:var(--muted);margin:0 0 16px}" +
            "table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:5px 9px;border-bottom:1px solid var(--line);vertical-align:top}th{font-weight:600}td.n{text-align:right;font-variant-numeric:tabular-nums}" +
            ".cards{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0 8px}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 16px;min-width:110px}.card b{display:block;font-size:22px}" +
            ".OK{color:var(--ok)}.Mismatch,.Missing{color:var(--fail)}.NotCompleted,.Unverified{color:var(--warn)}.badge{font-weight:600}pre{white-space:pre-wrap;border:1px solid var(--line);padding:10px;border-radius:6px}.small{font-size:13px;color:var(--muted)}" +
            "@media (max-width:700px){body{padding:16px}th,td{padding:4px 6px}}";

        static string E(object s) { return System.Net.WebUtility.HtmlEncode(Convert.ToString(s, CultureInfo.InvariantCulture) ?? ""); }

        static string Head(string title, string sub)
        {
            return "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>" + E(title) + "</title>\n<style>" + Css + "</style></head><body>\n<h1>" + E(title) + "</h1>\n<p>" + sub + "</p>\n";
        }

        static void Cards(StringBuilder sb, IList<VerifyItem> rows)
        {
            Func<VerifyOutcome, int> c = o => rows.Count(r => r.Outcome == o);
            sb.Append("<div class=\"cards\">");
            sb.Append("<div class=\"card\"><b>" + rows.Count + "</b>conversation-slices</div>");
            foreach (var o in new[] { VerifyOutcome.OK, VerifyOutcome.Mismatch, VerifyOutcome.Missing, VerifyOutcome.NotCompleted, VerifyOutcome.Unverified })
                sb.Append("<div class=\"card " + o + "\"><b>" + c(o) + "</b>" + o + "</div>");
            sb.Append("<div class=\"card\"><b>" + rows.Sum(r => r.SourceMessages).ToString("N0", CultureInfo.InvariantCulture) + "</b>source messages</div>");
            sb.Append("<div class=\"card\"><b>" + rows.Sum(r => r.TargetMessages).ToString("N0", CultureInfo.InvariantCulture) + "</b>target messages</div></div>\n");
        }

        static void RowsTable(StringBuilder sb, IEnumerable<VerifyItem> rows, int cap)
        {
            sb.Append("<table><thead><tr><th>Conversation</th><th>Slice</th><th>Outcome</th><th>Source</th><th>Imported</th><th>Target</th><th>Samples</th><th>Detail</th></tr></thead><tbody>\n");
            int n = 0;
            foreach (var r in rows)
            {
                if (n++ >= cap) { sb.Append("<tr><td colspan=\"8\" class=\"small\">... more rows: see verify.csv</td></tr>"); break; }
                sb.Append("<tr><td>" + E(r.ConversationKey) + "</td><td class=\"n\">" + r.SliceNo + "</td><td class=\"badge " + r.Outcome + "\">" + r.Outcome + "</td><td class=\"n\">" + r.SourceMessages + "</td><td class=\"n\">" + (r.JournalImported + r.JournalConflict) +
                    "</td><td class=\"n\">" + r.TargetMessages + "</td><td class=\"n\">" + (r.SamplesChecked - r.SamplesFailed) + "/" + r.SamplesChecked + "</td><td>" + E(r.Detail) + "</td></tr>\n");
            }
            sb.Append("</tbody></table>\n");
        }

        const string NormalisationNote = "Bodies are compared after normalisation: the fallback banner is removed from the target, img / attachment tags are dropped, other tags are removed, entities are decoded, whitespace is collapsed, then SHA-256 of the lower-cased text. " +
            "Reactions and file attachments are compared as totals and reported, but do not change the outcome unless the run was strict.";

        public static void WriteHtml(string path, string lotName, IList<VerifyItem> rows, DateTimeOffset generated, string version = null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            var sb = new StringBuilder();
            sb.Append(Head("Teams Transfer - Verify", "Lot " + E(lotName) + (version != null ? " &middot; v" + E(version) : "") + " &middot; " + E(generated.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)) + " UTC"));
            Cards(sb, rows);
            var bad = rows.Where(r => r.Outcome != VerifyOutcome.OK).ToList();
            sb.Append("<h2>" + (bad.Count == 0 ? "Everything agrees" : "To look at (" + bad.Count + ")") + "</h2>\n");
            if (bad.Count > 0) RowsTable(sb, bad.OrderBy(r => r.Outcome == VerifyOutcome.Missing ? 0 : r.Outcome == VerifyOutcome.Mismatch ? 1 : 2), 2000);
            else sb.Append("<p>Every conversation-slice of the lot matches the journal, the source counts and the sample.</p>\n");
            sb.Append("<h2>Method</h2>\n<p>" + E(NormalisationNote) + "</p>\n</body></html>\n");
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        }

        /// <summary>The summary text of a set of rows (also written next to the csv).</summary>
        public static string Summary(string lotName, IList<VerifyItem> rows)
        {
            return "Lot " + lotName + ": " + rows.Count + " conversation-slice(s): OK " + rows.Count(r => r.Outcome == VerifyOutcome.OK) + ", Mismatch " + rows.Count(r => r.Outcome == VerifyOutcome.Mismatch) +
                ", Missing " + rows.Count(r => r.Outcome == VerifyOutcome.Missing) + ", NotCompleted " + rows.Count(r => r.Outcome == VerifyOutcome.NotCompleted) + ", Unverified " + rows.Count(r => r.Outcome == VerifyOutcome.Unverified) +
                "; source " + rows.Sum(r => r.SourceMessages).ToString("N0", CultureInfo.InvariantCulture) + " / target " + rows.Sum(r => r.TargetMessages).ToString("N0", CultureInfo.InvariantCulture) + " messages.";
        }

        /// <summary>Rebuilds the HTML report of a lot from the catalog: state and history, items per state, journal totals per slice, ghosts, file copies, last verification.</summary>
        public static string WriteLotReport(TmtStore store, long lotId, string htmlPath, IFileCopyMap files = null, string version = null)
        {
            var lot = store.GetLot(lotId);
            if (lot == null) throw new KeyNotFoundException("No lot #" + lotId);
            var sb = new StringBuilder();
            sb.Append(Head("Teams Transfer - Lot " + lot.Name, "State <b>" + E(lot.State) + "</b>" + (lot.PreviousState.HasValue ? " (was " + E(lot.PreviousState) + ")" : "") + " &middot; created " + E(lot.CreatedUtc.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)) +
                " &middot; as of " + E(lot.AsOfUtc.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)) + (version != null ? " &middot; v" + E(version) : "")));
            var items = store.ListItems(lotId).ToList();
            var slices = store.ListSlices(lotId).ToList();
            sb.Append("<h2>Items by slice and state</h2>\n<table><thead><tr><th>Slice</th><th>Window</th>");
            var states = items.Select(i => i.State).Distinct().OrderBy(s => (int)s).ToList();
            foreach (var s in states) sb.Append("<th>" + E(s) + "</th>");
            sb.Append("<th>Total</th></tr></thead><tbody>\n");
            foreach (var sl in slices)
            {
                var inSlice = items.Where(i => i.SliceNo == sl.No).ToList();
                if (inSlice.Count == 0) continue;
                sb.Append("<tr><td>" + E(sl.Name) + "</td><td class=\"small\">" + E(sl.FromUtc.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)) + " .. " + (sl.ToUtc.HasValue ? E(sl.ToUtc.Value.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)) : "now") + "</td>");
                foreach (var s in states) sb.Append("<td class=\"n\">" + inSlice.Count(i => i.State == s) + "</td>");
                sb.Append("<td class=\"n\">" + inSlice.Count + "</td></tr>\n");
            }
            sb.Append("</tbody></table>\n");

            sb.Append("<h2>Import journal</h2>\n<table><thead><tr><th>Slice</th>");
            var statuses = (JournalStatus[])Enum.GetValues(typeof(JournalStatus));
            foreach (var s in statuses) sb.Append("<th>" + E(s) + "</th>");
            sb.Append("</tr></thead><tbody>\n");
            foreach (var g in items.GroupBy(i => i.SliceNo).OrderBy(g => g.Key))
            {
                var tot = new long[statuses.Length];
                foreach (var key in g.Select(i => i.ConversationKey).Distinct(StringComparer.Ordinal))
                {
                    var js = store.GetJournalSummary(key, g.Key);
                    for (int k = 0; k < statuses.Length; k++) tot[k] += js[statuses[k]];
                }
                sb.Append("<tr><td>Slice " + g.Key + "</td>");
                for (int k = 0; k < statuses.Length; k++) sb.Append("<td class=\"n\">" + tot[k].ToString("N0", CultureInfo.InvariantCulture) + "</td>");
                sb.Append("</tr>\n");
            }
            sb.Append("</tbody></table>\n");

            var ghosts = store.ListGhosts().ToList();
            if (ghosts.Count > 0)
            {
                sb.Append("<h2>Ghost accounts</h2>\n<p>");
                sb.Append(string.Join(" &middot; ", ghosts.GroupBy(g => g.State).OrderBy(g => (int)g.Key).Select(g => E(g.Key) + " " + g.Count())));
                sb.Append("</p>\n");
            }
            if (files != null)
            {
                var recs = items.Select(i => i.ConversationKey).Distinct(StringComparer.Ordinal).SelectMany(k => files.List(k, null)).ToList();
                if (recs.Count > 0)
                {
                    sb.Append("<h2>File copy</h2>\n<p>");
                    sb.Append(string.Join(" &middot; ", recs.GroupBy(r => r.State).OrderBy(g => (int)g.Key).Select(g => E(g.Key) + " " + g.Count())));
                    sb.Append("</p>\n");
                }
            }

            var rows = LoadRows(RowsFileOf(store, lot.Name));
            sb.Append("<h2>Last verification</h2>\n");
            if (rows.Count == 0) sb.Append("<p>Not run yet (-Mode Verify).</p>\n");
            else
            {
                sb.Append("<p>" + E(Summary(lot.Name, rows)) + "</p>\n");
                Cards(sb, rows);
                var bad = rows.Where(r => r.Outcome != VerifyOutcome.OK).ToList();
                if (bad.Count > 0) RowsTable(sb, bad, 500);
            }

            sb.Append("<h2>History</h2>\n<table><thead><tr><th>When (UTC)</th><th>From</th><th>To</th><th>Note</th></tr></thead><tbody>\n");
            foreach (var h in store.LotHistory(lotId))
                sb.Append("<tr><td>" + E(h.AtUtc.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)) + "</td><td>" + E(h.From) + "</td><td>" + E(h.To) + "</td><td>" + E(h.Note) + "</td></tr>\n");
            sb.Append("</tbody></table>\n</body></html>\n");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(htmlPath)));
            File.WriteAllText(htmlPath, sb.ToString(), new UTF8Encoding(false));
            return htmlPath;
        }
    }
}
