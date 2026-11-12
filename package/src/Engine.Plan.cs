// =============================================================================
//  TeamsTransfer - engine, part 5c: the dry-run import plan (lot H)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.1
//
//  ImportPlanner.BuildAsync(store, lot, slices, options, targetClient, ct) answers "what would the import do?" without
//  doing it. It reads the local store (lot items, conversations, messages, files, users, authors) and, read-only, the target
//  tenant through the GraphClient (users, teams, channels, chats). It NEVER sends a POST / PATCH / PUT / DELETE to a tenant.
//
//  What it writes LOCALLY (catalog.db and the plan folder) - decided here, documented for the importer:
//    - identity_map and target_map: the decisions of the mappers (always, even when the plan is blocked: the operator
//      reviews and corrects them; a Created target is never overwritten);
//    - the import journal (TmtStore.SeedJournal): SEEDED AT PLAN TIME, so the Import stage only reads it. The ids are the
//      messages the importer will send, in order. Seeding is idempotent (INSERT OR IGNORE) and a blocked plan seeds too:
//      Pending rows are inert until an Import runs on a plan that is not blocked;
//    - the ghost table: one Planned row per ghost to create (only when the plan is not blocked);
//    - the lot state Exported -> ImportPlanned (only when the plan is not blocked);
//    - checkpoint "plan:lot<id>": JSON {scenario, slices, createdUtc, blocked, blockers, messages, folder} - the importer
//      refuses a lot whose last plan is missing or blocked;
//    - the plan folder: plan.json, conversations.csv, identities.csv, ghosts.csv, issues.csv, plan.html.
//
//  MESSAGES THAT ARE IMPORTED (counted in ImportPlan.Messages): current version, createdDateTime inside the item window
//  (slice x fragment), messageType "message", not deleted (deletedDateTime empty). Replies of channel messages count.
//  NOT imported (ImportPlan.MessagesSkipped, with the reason in plan.json): system events (messageType systemEventMessage,
//  chatEvent, unknownFutureValue, typing...) - the API cannot create them - and messages deleted at the source.
//  A message without a user author (an application or a bot) is imported under the service account, with the banner.
//
//  DURATION: messages / min(application ceiling, parallelism x per-conversation rate), and never less than the largest
//  conversation / per-conversation rate (5 msg/s per conversation, ~60-90 msg/s per application: Phase0-Results). The
//  ceiling is PlanOptions.AppCeilingMessagesPerSecond (default 75).
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    public sealed class PlanOptions
    {
        public MappingOptions Mapping { get; set; } = new MappingOptions();
        /// <summary>Folder that receives plan.json, the CSV files and plan.html. Null: no artefact (the result object only).</summary>
        public string OutputFolder { get; set; }
        /// <summary>Whole-application ceiling used for the duration estimate (messages per second).</summary>
        public double AppCeilingMessagesPerSecond { get; set; } = 75;
        /// <summary>Seed the import journal while planning (default). False: the importer seeds it itself.</summary>
        public bool SeedJournal { get; set; } = true;
        /// <summary>Move the lot Exported -> ImportPlanned when the plan is not blocked.</summary>
        public bool AdvanceLotState { get; set; } = true;
        /// <summary>Rows of the HTML tables (the CSV files hold everything).</summary>
        public int MaxHtmlRows { get; set; } = 300;
        /// <summary>Optional progress counters polled by the console (Conversations, Messages, UnitsDone / UnitsTotal).</summary>
        public ProgressReporter Progress { get; set; }
        /// <summary>A stop request (stop file / hook): the plan stops after the current conversation with an OperationCanceledException (nothing is lost, plan again).</summary>
        public StopControl Stop { get; set; }
    }

    public sealed class PlanSliceStat
    {
        public int SliceNo { get; set; }
        public string Name { get; set; }
        public DateTimeOffset FromUtc { get; set; }
        public DateTimeOffset? ToUtc { get; set; }
        public int Conversations { get; set; }
        public long Messages { get; set; }
        public long MessagesSkipped { get; set; }
    }

    public sealed class PlanConversation
    {
        public string Key { get; set; }
        public string Kind { get; set; }
        public string Topic { get; set; }
        public string Team { get; set; }
        public string TargetKind { get; set; }
        public string TargetChatId { get; set; }
        public string TargetTeamId { get; set; }
        public string TargetChannelId { get; set; }
        public string CreateTeamName { get; set; }
        public string CreateTopic { get; set; }
        public string MembershipType { get; set; }
        public long Messages { get; set; }
        public long MessagesSkipped { get; set; }
        public DateTimeOffset? FirstUtc { get; set; }
        public DateTimeOffset? LastUtc { get; set; }
        public int Files { get; set; }
        public long FileBytes { get; set; }
        public int Authors { get; set; }
        public string Slices { get; set; }
        public string Note { get; set; }
    }

    public sealed class GhostPlanRow
    {
        public string SourceUserId { get; set; }
        public string SourceDisplayName { get; set; }
        public string SourceUserPrincipalName { get; set; }
        public string GhostDisplayName { get; set; }
        public string GhostUserPrincipalName { get; set; }
        public long Messages { get; set; }
    }

    public sealed class PlanResult
    {
        public ImportPlan Plan { get; set; }
        public string Folder { get; set; }
        public List<PlanSliceStat> SliceStats { get; } = new List<PlanSliceStat>();
        public List<PlanConversation> Conversations { get; } = new List<PlanConversation>();
        public List<IdentityMapping> Identities { get; } = new List<IdentityMapping>();
        public List<GhostPlanRow> Ghosts { get; } = new List<GhostPlanRow>();
        public Dictionary<string, long> SkippedByReason { get; } = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int> TeamsToCreate { get; } = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int> ArchiveTeams { get; } = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public int MeetingChats { get; set; }
        public long ApplicationMessages { get; set; }
        public int FilesNotAvailable { get; set; }
        public bool Offline { get; set; }
        public bool JournalSeeded { get; set; }
        public long JournalRowsAdded { get; set; }
        public int TeamsCreatedCount { get { return TeamsToCreate.Count; } }
        /// <summary>Artefact name -> full path (empty without an output folder).</summary>
        public Dictionary<string, string> Files { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    public static class ImportPlanner
    {
        public static async Task<ImportPlan> BuildAsync(TmtStore store, long lotId, int[] slices, ImportRunOptions run, GraphClient targetClient, CancellationToken ct, PlanOptions options = null)
        {
            return (await BuildCoreAsync(store, store.GetLot(lotId), "#" + lotId, slices, run, targetClient, options, ct).ConfigureAwait(false)).Plan;
        }

        public static async Task<ImportPlan> BuildAsync(TmtStore store, string lotName, int[] slices, ImportRunOptions run, GraphClient targetClient, CancellationToken ct, PlanOptions options = null)
        {
            return (await BuildCoreAsync(store, store.GetLot(lotName), "'" + lotName + "'", slices, run, targetClient, options, ct).ConfigureAwait(false)).Plan;
        }

        /// <summary>Same as BuildAsync, with the detail (conversations, identities, ghosts, slices) and the artefact paths.</summary>
        public static Task<PlanResult> BuildDetailedAsync(TmtStore store, string lotName, int[] slices, ImportRunOptions run, GraphClient targetClient, CancellationToken ct, PlanOptions options = null)
        {
            return BuildCoreAsync(store, store.GetLot(lotName), "'" + lotName + "'", slices, run, targetClient, options, ct);
        }

        public static Task<PlanResult> BuildDetailedAsync(TmtStore store, long lotId, int[] slices, ImportRunOptions run, GraphClient targetClient, CancellationToken ct, PlanOptions options = null)
        {
            return BuildCoreAsync(store, store.GetLot(lotId), "#" + lotId, slices, run, targetClient, options, ct);
        }

        /// <summary>Resolves the service account (UPN or object id) in the target tenant (read-only). Throws when it does not exist.</summary>
        public static async Task<TargetUserInfo> ResolveServiceAccountAsync(GraphClient targetClient, string upnOrId, CancellationToken ct)
        {
            var u = await new TargetDirectory(targetClient).FindUserAsync(upnOrId, ct).ConfigureAwait(false);
            if (u == null) throw new InvalidOperationException("The service account '" + upnOrId + "' does not exist in the target tenant.");
            return u;
        }

        // =====================================================================================================

        sealed class ConvStat
        {
            public long Messages, Skipped;
            public DateTimeOffset? First, Last;
            public HashSet<string> Authors = new HashSet<string>(StringComparer.Ordinal);
            public HashSet<string> ImportableIds = new HashSet<string>(StringComparer.Ordinal);
            public SortedSet<int> Slices = new SortedSet<int>();
        }

        static string S(JsonElement e, string name)
        {
            JsonElement p;
            return e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
        }

        static async Task<PlanResult> BuildCoreAsync(TmtStore store, LotInfo lot, string lotRef, int[] slices, ImportRunOptions run, GraphClient client, PlanOptions opt, CancellationToken ct)
        {
            if (store == null) throw new ArgumentNullException("store");
            if (lot == null) throw new KeyNotFoundException("No lot " + lotRef + " in the store.");
            run = run ?? new ImportRunOptions();
            opt = opt ?? new PlanOptions();
            var sliceNos = (slices == null || slices.Length == 0 ? new[] { 1 } : slices).Distinct().OrderBy(x => x).ToArray();
            var plan = new ImportPlan { LotId = lot.Id, LotName = lot.Name, Slices = sliceNos, Scenario = run.Scenario, CreatedUtc = DateTimeOffset.UtcNow };
            var res = new PlanResult { Plan = plan, Offline = client == null };
            var progress = opt.Progress;
            var dir = new TargetDirectory(client);
            if (client == null) plan.Warnings.Add("Offline plan: the target tenant was not looked up. CSV targets are trusted, users that need a look-up stay unresolved (scenario A) or are assumed to exist (scenarios B and C).");

            // ---- lot state -------------------------------------------------------------------------------------------------
            if (lot.State == LotState.Planned || lot.State == LotState.Exporting) plan.Blockers.Add("Lot '" + lot.Name + "' is " + lot.State + ": finish the export first (the plan reads the exported messages).");
            else if (lot.State == LotState.Paused || lot.State == LotState.Failed) plan.Blockers.Add("Lot '" + lot.Name + "' is " + lot.State + ": resume it first.");
            else if (lot.State == LotState.Closed) plan.Blockers.Add("Lot '" + lot.Name + "' is Closed.");
            else if (lot.State == LotState.Cancelled) plan.Blockers.Add("Lot '" + lot.Name + "' is Cancelled.");
            else if (lot.State == LotState.Importing || lot.State == LotState.Completing) plan.Warnings.Add("Lot '" + lot.Name + "' is already " + lot.State + ": the plan is informational, the journal only receives messages it does not know yet.");

            // ---- items (conversation x slice x fragment) -------------------------------------------------------------------
            if (lot.State != LotState.Paused && lot.State != LotState.Failed && lot.State != LotState.Closed && lot.State != LotState.Cancelled)
            {
                var resolved = store.ResolveLot(lot.Id, sliceNos);
                if (resolved.Unresolved.Count > 0) plan.Warnings.Add(resolved.Unresolved.Count + " lot member(s) match nothing in the inventory: " + string.Join(", ", resolved.Unresolved.Take(5)) + (resolved.Unresolved.Count > 5 ? ", ..." : "") + ".");
                if (resolved.CoveredByOtherLot > 0) plan.Warnings.Add(resolved.CoveredByOtherLot + " conversation(s) are already covered by another lot for these slices: not planned again.");
            }
            var sliceInfo = store.ListSlices(lot.Id).ToDictionary(x => x.No);
            var items = new List<LotItem>();
            foreach (int sn in sliceNos)
            {
                if (!sliceInfo.ContainsKey(sn)) { plan.Blockers.Add("Lot '" + lot.Name + "' has no slice " + sn + "."); continue; }
                items.AddRange(store.ListItems(lot.Id, sn));
            }
            int done = items.Count(i => i.State == LotState.Verified || i.State == LotState.Closed);
            if (done > 0) plan.Warnings.Add(done + " item(s) are already Verified or Closed: not planned again.");
            items = items.Where(i => i.State != LotState.Verified && i.State != LotState.Closed).ToList();
            var order = new List<string>(); var byConv = new Dictionary<string, List<LotItem>>(StringComparer.Ordinal);
            foreach (var it in items.OrderBy(i => i.Priority).ThenBy(i => i.ConversationKey, StringComparer.Ordinal).ThenBy(i => i.SliceNo).ThenBy(i => i.Fragment))
            {
                List<LotItem> l; if (!byConv.TryGetValue(it.ConversationKey, out l)) { byConv[it.ConversationKey] = l = new List<LotItem>(); order.Add(it.ConversationKey); }
                l.Add(it);
            }
            plan.Conversations = order.Count;
            if (order.Count == 0) plan.Warnings.Add("Nothing is planned for slice(s) " + string.Join(",", sliceNos) + ": no conversation had messages in the window, or they are covered by another lot.");
            foreach (int sn in sliceNos) if (sliceInfo.ContainsKey(sn))
                    res.SliceStats.Add(new PlanSliceStat { SliceNo = sn, Name = sliceInfo[sn].Name, FromUtc = sliceInfo[sn].FromUtc, ToUtc = sliceInfo[sn].ToUtc });

            // ---- scan: messages, authors, files, journal ----------------------------------------------------------------------
            if (progress != null) progress.Phase("Reading the messages", order.Count);
            var stats = new Dictionary<string, ConvStat>(StringComparer.Ordinal);
            var convs = new Dictionary<string, ConversationRecord>(StringComparer.Ordinal);
            var authors = new Dictionary<string, SourceIdentity>(StringComparer.Ordinal);
            long appMessages = 0;
            foreach (var key in order)
            {
                ct.ThrowIfCancellationRequested();
                if (StopControl.Stopped(opt.Stop)) throw new OperationCanceledException("Stop requested.");
                if (opt.Progress != null) { progress.Current(key); progress.Tick(); }
                var conv = store.GetConversation(key);
                if (conv == null) { plan.Blockers.Add("Conversation " + key + " is in the lot but not in the inventory of the store."); continue; }
                convs[key] = conv;
                var cs = new ConvStat(); stats[key] = cs;
                foreach (var it in byConv[key])
                {
                    cs.Slices.Add(it.SliceNo);
                    var ids = new List<string>();
                    var sstat = res.SliceStats.First(x => x.SliceNo == it.SliceNo);
                    foreach (var m in store.ReadMessages(key, it.FromUtc, it.ToUtc))
                    {
                        string id = S(m, "id");
                        string reason = SkipReason(m);
                        if (reason != null)
                        {
                            cs.Skipped++; sstat.MessagesSkipped++;
                            long n; res.SkippedByReason.TryGetValue(reason, out n); res.SkippedByReason[reason] = n + 1;
                            continue;
                        }
                        cs.Messages++; sstat.Messages++;
                        DateTimeOffset when;
                        if (DateTimeOffset.TryParse(S(m, "createdDateTime"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out when))
                        {
                            if (!cs.First.HasValue || when < cs.First.Value) cs.First = when;
                            if (!cs.Last.HasValue || when > cs.Last.Value) cs.Last = when;
                        }
                        cs.ImportableIds.Add(id);
                        string uid = null, uname = null, utype = null;
                        JsonElement from, user;
                        if (m.TryGetProperty("from", out from) && from.ValueKind == JsonValueKind.Object && from.TryGetProperty("user", out user) && user.ValueKind == JsonValueKind.Object)
                        { uid = S(user, "id"); uname = S(user, "displayName"); utype = S(user, "userIdentityType"); }
                        if (uid == null) { appMessages++; }
                        else
                        {
                            cs.Authors.Add(uid);
                            SourceIdentity a;
                            if (!authors.TryGetValue(uid, out a)) authors[uid] = a = new SourceIdentity { Id = uid };
                            a.Messages++;
                            if (a.DisplayName == null) a.DisplayName = uname;
                            if (a.IdentityType == null) a.IdentityType = utype;
                        }
                        if (opt.SeedJournal) { ids.Add(id); if (ids.Count >= 5000) { res.JournalRowsAdded += store.SeedJournal(key, it.SliceNo, ids); ids.Clear(); } }
                        if (progress != null) System.Threading.Interlocked.Increment(ref progress.Messages);
                    }
                    if (opt.SeedJournal && ids.Count > 0) res.JournalRowsAdded += store.SeedJournal(key, it.SliceNo, ids);
                }
                // files of the imported messages
                foreach (var f in store.ListFiles(key))
                {
                    if (!cs.ImportableIds.Contains(f.MessageId)) continue;
                    if (f.Status == FileStatus.Downloaded) { plan.FilesToCopy++; plan.FileBytesToCopy += f.Size ?? 0; }
                    else res.FilesNotAvailable++;
                }
                if (progress != null) { System.Threading.Interlocked.Increment(ref progress.Conversations); System.Threading.Interlocked.Increment(ref progress.UnitsDone); }
            }
            res.JournalSeeded = opt.SeedJournal;
            res.ApplicationMessages = appMessages;
            foreach (var cs in stats.Values) { plan.Messages += cs.Messages; plan.MessagesSkipped += cs.Skipped; }
            foreach (var sst in res.SliceStats) sst.Conversations = byConv.Count(kv => kv.Value.Any(i => i.SliceNo == sst.SliceNo));
            if (opt.SeedJournal && !store.Options.ReadOnly)
            {
                try { store.RegisterAuthors(authors.Values.Select(a => (a.Id, a.DisplayName, a.IdentityType))); }
                catch (InvalidOperationException) { }
            }

            // ---- identities -------------------------------------------------------------------------------------------------
            if (progress != null) progress.Phase("Mapping the identities", 0);
            var users = new Dictionary<string, UserRecord>(StringComparer.OrdinalIgnoreCase);
            foreach (var u in store.ListUsers()) users[u.Id] = u;
            bool archive = run.Scenario == ImportScenario.DepartedArchive;
            var sources = new Dictionary<string, SourceIdentity>(authors, StringComparer.Ordinal);
            foreach (var conv in convs.Values)
            {
                bool listMembers = !archive && (conv.Kind != ConversationKind.Channel || !string.Equals(conv.MembershipType ?? "standard", "standard", StringComparison.OrdinalIgnoreCase));
                if (!listMembers || string.IsNullOrEmpty(conv.MembersJson) || !(stats[conv.Key].Messages > 0)) continue;
                try
                {
                    using (var doc = JsonDocument.Parse(conv.MembersJson))
                        foreach (var m in doc.RootElement.EnumerateArray())
                        {
                            string uid = S(m, "userId");
                            if (uid == null || sources.ContainsKey(uid)) continue;
                            sources[uid] = new SourceIdentity { Id = uid, DisplayName = S(m, "displayName"), Mail = S(m, "email"), TenantId = S(m, "tenantId") };
                        }
                }
                catch (JsonException) { }
            }
            foreach (var s in sources.Values)
            {
                UserRecord rec;
                if (users.TryGetValue(s.Id, out rec))
                {
                    s.UserPrincipalName = rec.UserPrincipalName; s.Mail = rec.Mail ?? s.Mail; s.DisplayName = rec.DisplayName ?? s.DisplayName; s.TenantId = rec.TenantId ?? s.TenantId;
                    s.State = rec.State == UserState.Unknown ? UserState.Active : rec.State;
                }
                else s.State = UserState.Deleted;   // an author that the user inventory never saw: gone from the tenant
            }
            var ghostTable = new Dictionary<string, GhostRecord>(StringComparer.OrdinalIgnoreCase);
            foreach (var g in store.ListGhosts()) ghostTable[g.SourceUserId] = g;
            var mapper = new IdentityMapper(store, run, opt.Mapping, dir, id => { GhostRecord g; return ghostTable.TryGetValue(id, out g) ? g : null; });
            var sourceList = sources.Values.OrderBy(s => s.Id, StringComparer.Ordinal).ToList();
            var idMaps = await mapper.ResolveAsync(sourceList, run.Scenario, ct).ConfigureAwait(false);
            var idByUser = idMaps.ToDictionary(m => m.SourceUserId, StringComparer.OrdinalIgnoreCase);
            res.Identities.AddRange(idMaps);

            foreach (var m in idMaps)
            {
                SourceIdentity s = sources[m.SourceUserId];
                if (m.Kind == IdentityKind.Unresolved) plan.UnresolvedIdentities++;
                else if (m.Kind == IdentityKind.ServiceAccount) plan.ServiceAccountAuthors++;
                else if (m.Kind == IdentityKind.Ghost && string.IsNullOrEmpty(m.TargetUserId))
                {
                    plan.GhostsToCreate++;
                    res.Ghosts.Add(new GhostPlanRow { SourceUserId = m.SourceUserId, SourceDisplayName = s.DisplayName, SourceUserPrincipalName = s.UserPrincipalName, GhostDisplayName = m.TargetDisplayName, GhostUserPrincipalName = IdentityMapper.GhostUpn(m.SourceUserId, run.GhostDomain), Messages = s.Messages });
                }
            }

            // ---- target conversations ---------------------------------------------------------------------------------------
            if (progress != null) progress.Phase("Mapping the conversations", 0);
            var withMessages = order.Where(k => convs.ContainsKey(k) && stats[k].Messages > 0).Select(k => convs[k]).ToList();
            Func<string, IEnumerable<string>> authorsOf = k => stats.ContainsKey(k) ? stats[k].Authors : (IEnumerable<string>)new string[0];
            Func<string, Tuple<string, string>> ownerOf = null;
            if (archive)
            {
                var owner = new Dictionary<string, Tuple<string, string>>(StringComparer.Ordinal);
                var byUpn = users.Values.Where(u => u.UserPrincipalName != null).GroupBy(u => u.UserPrincipalName, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
                foreach (var mem in store.ListLotMembers(lot.Id).Where(x => x.Type == LotMemberType.User))
                {
                    UserRecord u; if (!users.TryGetValue(mem.Identity, out u) && !byUpn.TryGetValue(mem.Identity, out u)) continue;
                    foreach (var c in store.ListConversations(u.Id)) if (!owner.ContainsKey(c.Key)) owner[c.Key] = Tuple.Create(u.Id, u.DisplayName ?? u.UserPrincipalName ?? u.Id);
                }
                ownerOf = k => { Tuple<string, string> o; return owner.TryGetValue(k, out o) ? o : null; };
            }
            var tmapper = new TargetMapper(run, opt.Mapping, dir, id => { IdentityMapping m; return idByUser.TryGetValue(id, out m) ? m : null; }, store);
            var tres = await tmapper.MapAsync(withMessages, run.Scenario, authorsOf, ownerOf, ct).ConfigureAwait(false);
            foreach (var b in tres.Blockers) plan.Blockers.Add(b);
            foreach (var w in tres.Warnings.Take(20)) plan.Warnings.Add(w);
            if (tres.Warnings.Count > 20) plan.Warnings.Add((tres.Warnings.Count - 20) + " more warning(s) of the same kind.");
            res.MeetingChats = tres.MeetingChats;
            foreach (var kv in tres.TeamsToCreate) res.TeamsToCreate[kv.Key] = kv.Value;
            foreach (var kv in tres.ArchiveTeams) res.ArchiveTeams[kv.Key] = kv.Value;

            // a target already Created by an earlier import is never replanned
            var finalTargets = new List<TargetMapping>();
            var targetByKey = new Dictionary<string, TargetMapping>(StringComparer.Ordinal);
            var already = store.ListTargets().ToDictionary(t => t.SourceConversationKey, StringComparer.Ordinal);
            foreach (var t in tres.Targets)
            {
                TargetMapping old;
                var use = already.TryGetValue(t.SourceConversationKey, out old) && old.State == TargetState.Created ? old : t;
                finalTargets.Add(use); targetByKey[use.SourceConversationKey] = use;
            }
            foreach (var key in order)
            {
                if (!convs.ContainsKey(key) || stats[key].Messages > 0 || targetByKey.ContainsKey(key)) continue;
                var skip = new TargetMapping { SourceConversationKey = key, Kind = TargetKind.Skip, Note = "no importable message in the slice(s)" };
                finalTargets.Add(skip); targetByKey[key] = skip;
            }
            foreach (var t in finalTargets)
                switch (t.Kind)
                {
                    case TargetKind.NewChat: plan.NewChats++; break;
                    case TargetKind.ExistingChat: plan.ExistingChats++; break;
                    case TargetKind.NewChannel: plan.NewChannels++; break;
                    case TargetKind.ExistingChannel: plan.ExistingChannels++; break;
                    case TargetKind.ArchiveChannel: plan.ArchiveChannels++; break;
                }

            // ---- per-conversation rows --------------------------------------------------------------------------------------
            foreach (var key in order)
            {
                ConversationRecord conv; ConvStat cs;
                if (!convs.TryGetValue(key, out conv)) continue;
                cs = stats[key];
                TargetMapping t; targetByKey.TryGetValue(key, out t);
                var fileRows = store.ListFiles(key).Where(f => cs.ImportableIds.Contains(f.MessageId)).ToList();
                res.Conversations.Add(new PlanConversation
                {
                    Key = key, Kind = conv.Kind.ToString(), Topic = conv.Topic, Team = conv.TeamDisplayName, TargetKind = t == null ? "" : t.Kind.ToString(),
                    TargetChatId = t == null ? null : t.TargetChatId, TargetTeamId = t == null ? null : t.TargetTeamId, TargetChannelId = t == null ? null : t.TargetChannelId,
                    CreateTeamName = t == null ? null : t.CreateTeamName, CreateTopic = t == null ? null : t.CreateTopic, MembershipType = conv.MembershipType,
                    Messages = cs.Messages, MessagesSkipped = cs.Skipped, FirstUtc = cs.First, LastUtc = cs.Last,
                    Files = fileRows.Count(f => f.Status == FileStatus.Downloaded), FileBytes = fileRows.Where(f => f.Status == FileStatus.Downloaded).Sum(f => f.Size ?? 0),
                    Authors = cs.Authors.Count, Slices = string.Join(";", cs.Slices), Note = t == null ? null : t.Note
                });
            }

            // ---- blockers, warnings, duration -------------------------------------------------------------------------------
            if (plan.UnresolvedIdentities > 0)
            {
                var sample = res.Identities.Where(m => m.Kind == IdentityKind.Unresolved).Take(5).Select(m => (m.SourceUserPrincipalName ?? m.SourceDisplayName ?? m.SourceUserId)).ToList();
                plan.Blockers.Add(plan.UnresolvedIdentities + " unresolved identit" + (plan.UnresolvedIdentities == 1 ? "y" : "ies") + " (e.g. " + string.Join(", ", sample) + "): decide each one in the identity CSV (-IdentityMap), a domain rule, a ghost domain or a service account; see identities.csv.");
            }
            if (plan.GhostsToCreate > run.GhostConfirmThreshold && !run.ConfirmGhostCount)
                plan.Blockers.Add(plan.GhostsToCreate.ToString("N0", CultureInfo.InvariantCulture) + " ghost accounts to create is above the threshold of " + run.GhostConfirmThreshold.ToString("N0", CultureInfo.InvariantCulture) + ": review ghosts.csv, then confirm with ConfirmGhostCount (or use a service account instead).");
            if (appMessages > 0 && string.IsNullOrEmpty(run.ServiceAccountUserId))
                plan.Blockers.Add(appMessages.ToString("N0", CultureInfo.InvariantCulture) + " message(s) have no user author (application or bot): they are imported under the service account, which is not configured.");
            if (plan.GhostsToCreate > 0) plan.Warnings.Add(plan.GhostsToCreate.ToString("N0", CultureInfo.InvariantCulture) + " ghost account(s) will be created in the target tenant (disabled, unlicensed; ghosts.csv).");
            if (plan.ServiceAccountAuthors > 0)
            {
                long banner = res.Identities.Where(m => m.Kind == IdentityKind.ServiceAccount).Sum(m => sources[m.SourceUserId].Messages) + appMessages;
                plan.Warnings.Add(plan.ServiceAccountAuthors.ToString("N0", CultureInfo.InvariantCulture) + " author(s) fall back to the service account (federated, external or deleted): " + banner.ToString("N0", CultureInfo.InvariantCulture) + " message(s) carry the 'Original message from ...' banner.");
            }
            else if (appMessages > 0) plan.Warnings.Add(appMessages.ToString("N0", CultureInfo.InvariantCulture) + " application / bot message(s) are imported under the service account.");
            if (res.MeetingChats > 0) plan.Warnings.Add(res.MeetingChats.ToString("N0", CultureInfo.InvariantCulture) + " meeting chat(s): the import API does not support meeting chats, they are imported as group chats with the meeting title.");
            foreach (var kv in res.SkippedByReason.OrderByDescending(x => x.Value)) plan.Warnings.Add(kv.Value.ToString("N0", CultureInfo.InvariantCulture) + " message(s) not imported: " + kv.Key + ".");
            if (res.FilesNotAvailable > 0) plan.Warnings.Add(res.FilesNotAvailable.ToString("N0", CultureInfo.InvariantCulture) + " file(s) referenced by imported messages were not downloaded (pending, missing, forbidden, too large or excluded): the attachment cannot be copied.");
            if (res.TeamsToCreate.Count > 0) plan.Warnings.Add(res.TeamsToCreate.Count.ToString("N0", CultureInfo.InvariantCulture) + " team(s) will be created (one member each at creation): " + string.Join(", ", res.TeamsToCreate.Keys.Take(5)) + (res.TeamsToCreate.Count > 5 ? ", ..." : "") + ".");
            if (sliceNos.Any(n => n > 1)) plan.Warnings.Add("Extension wave(s) " + string.Join(",", sliceNos.Where(n => n > 1)) + ": a conversation that was imported before is reopened with startMigration at an even earlier date.");

            double perConv = run.PerConversationRate > 0 ? run.PerConversationRate : 5;
            double ceiling = opt.AppCeilingMessagesPerSecond > 0 ? opt.AppCeilingMessagesPerSecond : 75;
            double effective = Math.Min(ceiling, Math.Max(1, run.ConversationParallelism) * perConv);
            long biggest = stats.Count == 0 ? 0 : stats.Values.Max(c => c.Messages);
            double seconds = Math.Max(plan.Messages / effective, biggest / perConv);
            plan.EstimatedDuration = TimeSpan.FromSeconds(Math.Min(seconds, TimeSpan.MaxValue.TotalSeconds / 2));
            if (plan.EstimatedDuration.TotalDays > 14) plan.Warnings.Add("Estimated import duration " + plan.EstimatedDuration.TotalDays.ToString("N1", CultureInfo.InvariantCulture) + " days at " + effective.ToString("N0", CultureInfo.InvariantCulture) + " msg/s: consider a narrower lot or window.");

            // ---- persistence (local only) -----------------------------------------------------------------------------------
            store.UpsertTargets(finalTargets);
            if (!plan.IsBlocked)
            {
                foreach (var gh in res.Ghosts)
                    if (!ghostTable.ContainsKey(gh.SourceUserId))
                        store.UpsertGhost(new GhostRecord { SourceUserId = gh.SourceUserId, DisplayName = gh.GhostDisplayName, UserPrincipalName = gh.GhostUserPrincipalName, State = GhostState.Planned });
                if (opt.AdvanceLotState && lot.State == LotState.Exported)
                    store.TransitionLot(lot.Id, LotState.ImportPlanned, "import plan: " + plan.Messages + " message(s), " + plan.Conversations + " conversation(s)", LotState.Exported);
            }

            if (!string.IsNullOrEmpty(opt.OutputFolder)) WriteArtefacts(res, run, opt, sources, ceiling, effective);
            var summary = JsonSerializer.Serialize(new Dictionary<string, object>
            {
                { "scenario", run.Scenario.ToString() }, { "slices", sliceNos }, { "createdUtc", plan.CreatedUtc }, { "blocked", plan.IsBlocked }, { "blockers", plan.Blockers.Count },
                { "messages", plan.Messages }, { "conversations", plan.Conversations }, { "folder", opt.OutputFolder },
                // read by the importer (owner of the teams it creates, fallback author) when -Mode Import gets no -ServiceAccount
                { "serviceAccountUserId", run.ServiceAccountUserId }
            });
            if (!store.Options.ReadOnly) store.SetCheckpoint("plan:lot" + lot.Id.ToString(CultureInfo.InvariantCulture), summary);
            if (progress != null) progress.Finish();
            return res;
        }

        /// <summary>Why a message is not imported, or null when it is.</summary>
        static string SkipReason(JsonElement m)
        {
            string type = S(m, "messageType");
            if (type != null && !type.Equals("message", StringComparison.OrdinalIgnoreCase))
                return type.Equals("systemEventMessage", StringComparison.OrdinalIgnoreCase) ? "system events (members added, calls, meetings...) cannot be imported" : "messageType '" + type + "' cannot be imported";
            if (!string.IsNullOrEmpty(S(m, "deletedDateTime"))) return "deleted at the source";
            return null;
        }

        // =====================================================================================================
        #region Artefacts

        static readonly JsonSerializerOptions JsonOpt = new JsonSerializerOptions
        {
            WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull, Converters = { new JsonStringEnumConverter() }
        };

        static string Iso(DateTimeOffset? d) { return d.HasValue ? d.Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) : ""; }

        public static string FormatDuration(TimeSpan t)
        {
            if (t.TotalSeconds < 1) return "under a second";
            if (t.TotalDays >= 1) return t.TotalDays.ToString("N1", CultureInfo.InvariantCulture) + " days";
            if (t.TotalHours >= 1) return t.TotalHours.ToString("N1", CultureInfo.InvariantCulture) + " hours";
            if (t.TotalMinutes >= 1) return t.TotalMinutes.ToString("N0", CultureInfo.InvariantCulture) + " minutes";
            return t.TotalSeconds.ToString("N0", CultureInfo.InvariantCulture) + " seconds";
        }

        static void WriteArtefacts(PlanResult res, ImportRunOptions run, PlanOptions opt, Dictionary<string, SourceIdentity> sources, double ceiling, double effective)
        {
            string dir = opt.OutputFolder;
            Directory.CreateDirectory(dir);
            res.Folder = dir;
            var utf8 = new UTF8Encoding(false);
            var plan = res.Plan;
            Func<string, string> path = n => { string p = Path.Combine(dir, n); res.Files[n] = p; return p; };

            // conversations.csv
            using (var w = new StreamWriter(path("conversations.csv"), false, utf8))
            {
                w.WriteLine("SourceKey,Kind,Topic,Team,TargetKind,TargetChatId,TargetTeamId,TargetChannelId,CreateTeamName,CreateTopic,MembershipType,Messages,MessagesSkipped,FirstUtc,LastUtc,Files,FileBytes,Authors,Slices,Note");
                foreach (var c in res.Conversations)
                    w.WriteLine(MapCsv.Line(c.Key, c.Kind, c.Topic, c.Team, c.TargetKind, c.TargetChatId, c.TargetTeamId, c.TargetChannelId, c.CreateTeamName, c.CreateTopic, c.MembershipType, c.Messages, c.MessagesSkipped, Iso(c.FirstUtc), Iso(c.LastUtc), c.Files, c.FileBytes, c.Authors, c.Slices, c.Note));
            }
            // identities.csv
            using (var w = new StreamWriter(path("identities.csv"), false, utf8))
            {
                w.WriteLine("SourceUserId,SourceUpn,SourceDisplayName,Kind,TargetUserId,TargetDisplayName,Rule,Messages,Note");
                foreach (var m in res.Identities.OrderBy(x => x.Kind == IdentityKind.Unresolved ? 0 : 1).ThenBy(x => x.SourceUserId, StringComparer.Ordinal))
                    w.WriteLine(MapCsv.Line(m.SourceUserId, m.SourceUserPrincipalName, m.SourceDisplayName, m.Kind, m.TargetUserId, m.TargetDisplayName, m.Rule, sources.ContainsKey(m.SourceUserId) ? sources[m.SourceUserId].Messages : 0, m.Note));
            }
            // ghosts.csv
            using (var w = new StreamWriter(path("ghosts.csv"), false, utf8))
            {
                w.WriteLine("SourceUserId,SourceUpn,SourceDisplayName,GhostDisplayName,GhostUpn,Messages");
                foreach (var g in res.Ghosts) w.WriteLine(MapCsv.Line(g.SourceUserId, g.SourceUserPrincipalName, g.SourceDisplayName, g.GhostDisplayName, g.GhostUserPrincipalName, g.Messages));
            }
            // issues.csv
            using (var w = new StreamWriter(path("issues.csv"), false, utf8))
            {
                w.WriteLine("Level,Message");
                foreach (var b in plan.Blockers) w.WriteLine(MapCsv.Line("Blocker", b));
                foreach (var x in plan.Warnings) w.WriteLine(MapCsv.Line("Warning", x));
            }
            // plan.json
            var doc = new Dictionary<string, object>
            {
                { "schema", "plan-v1" }, { "tool", "TeamsTransfer" }, { "plan", plan }, { "blocked", plan.IsBlocked },
                { "estimatedDurationSeconds", Math.Round(plan.EstimatedDuration.TotalSeconds) }, { "estimatedDurationText", FormatDuration(plan.EstimatedDuration) },
                { "rates", new { perConversation = run.PerConversationRate, applicationCeiling = ceiling, parallelism = run.ConversationParallelism, effective } },
                { "slices", res.SliceStats }, { "skippedByReason", res.SkippedByReason }, { "teamsToCreate", res.TeamsToCreate }, { "archiveTeams", res.ArchiveTeams },
                { "meetingChats", res.MeetingChats }, { "applicationMessages", res.ApplicationMessages }, { "filesNotDownloaded", res.FilesNotAvailable },
                { "offline", res.Offline }, { "journalSeeded", res.JournalSeeded }, { "journalRowsAdded", res.JournalRowsAdded },
                { "identities", res.Identities.GroupBy(m => m.Kind.ToString()).ToDictionary(g => g.Key, g => g.Count()) },
                { "artefacts", res.Files.Keys.Concat(new[] { "plan.json", "plan.html" }).Distinct().OrderBy(x => x).ToArray() }
            };
            File.WriteAllText(path("plan.json"), JsonSerializer.Serialize(doc, JsonOpt), utf8);
            File.WriteAllText(path("plan.html"), RenderHtml(res, run, ceiling, effective, opt.MaxHtmlRows), utf8);
        }

        static string H(object s) { return System.Net.WebUtility.HtmlEncode(Convert.ToString(s, CultureInfo.InvariantCulture) ?? ""); }
        static string N(long v) { return v.ToString("N0", CultureInfo.InvariantCulture); }

        static string Bytes(long b)
        {
            string[] u = { "B", "KB", "MB", "GB", "TB", "PB" }; double v = b; int i = 0;
            while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
            return (i == 0 ? v.ToString("N0", CultureInfo.InvariantCulture) : v.ToString("N1", CultureInfo.InvariantCulture)) + " " + u[i];
        }

        static string RenderHtml(PlanResult res, ImportRunOptions run, double ceiling, double effective, int maxRows)
        {
            var plan = res.Plan; var sb = new StringBuilder();
            sb.Append(@"<!doctype html>
<html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">
<title>Teams Transfer - import plan</title>
<style>
:root{color-scheme:light dark;--bg:#f2f3f5;--surface:#fff;--text:#1d2129;--muted:#5f6877;--border:#dfe3ea;--accent:#2b6c8f;--soft:#e1eff6;--bad:#a4262c;--badbg:#fde7e9;--warn:#7a5b00;--warnbg:#fff4ce;--ok:#0e6027;--okbg:#dff6dd}
@media (prefers-color-scheme:dark){:root{--bg:#121418;--surface:#1b1e25;--text:#e5e8ee;--muted:#a0a8b8;--border:#2d3340;--accent:#6bb3d6;--soft:#223645;--bad:#ffb3b8;--badbg:#4a1d20;--warn:#ffd97a;--warnbg:#463a12;--ok:#9fe0a8;--okbg:#17361f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 ""Segoe UI"",system-ui,sans-serif;padding:24px 16px}
main{max-width:1100px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 8px}.sub{color:var(--muted);margin:0 0 18px}
.verdict{display:inline-block;padding:3px 12px;border-radius:999px;font-weight:600;font-size:13px}.v-ok{background:var(--okbg);color:var(--ok)}.v-bad{background:var(--badbg);color:var(--bad)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:14px 0}.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:10px 12px}
.card b{display:block;font-size:20px;font-variant-numeric:tabular-nums}.card span{color:var(--muted);font-size:12px}
table{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden;font-size:13px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--border);vertical-align:top}th{background:var(--soft);color:var(--accent);font-weight:600}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
.box{border-radius:8px;padding:8px 12px;margin:6px 0}.b-bad{background:var(--badbg);color:var(--bad)}.b-warn{background:var(--warnbg);color:var(--warn)}
.wrap{overflow-x:auto}code{font-family:Consolas,monospace;font-size:12px}.muted{color:var(--muted)}
</style></head><body><main>
");
            sb.Append("<h1>Import plan - lot ").Append(H(plan.LotName)).Append("</h1>");
            sb.Append("<p class=\"sub\">").Append(H(plan.Scenario)).Append(" &middot; slice(s) ").Append(H(string.Join(", ", plan.Slices))).Append(" &middot; planned ").Append(H(plan.CreatedUtc.UtcDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture))).Append(" UTC &middot; dry run: nothing was written to any tenant</p>");
            sb.Append(plan.IsBlocked ? "<p><span class=\"verdict v-bad\">Blocked: " + plan.Blockers.Count + " blocker(s)</span></p>" : "<p><span class=\"verdict v-ok\">Ready to import</span></p>");
            foreach (var b in plan.Blockers) sb.Append("<div class=\"box b-bad\"><strong>Blocker.</strong> ").Append(H(b)).Append("</div>");
            foreach (var w in plan.Warnings) sb.Append("<div class=\"box b-warn\"><strong>Warning.</strong> ").Append(H(w)).Append("</div>");

            Action<string, string> card = (v, l) => sb.Append("<div class=\"card\"><b>").Append(H(v)).Append("</b><span>").Append(H(l)).Append("</span></div>");
            sb.Append("<h2>Summary</h2><div class=\"cards\">");
            card(N(plan.Conversations), "conversations"); card(N(plan.Messages), "messages to import"); card(N(plan.MessagesSkipped), "messages not importable");
            card(N(plan.NewChats), "new chats"); card(N(plan.ExistingChats), "existing chats"); card(N(plan.NewChannels), "new channels"); card(N(plan.ExistingChannels), "existing channels"); card(N(plan.ArchiveChannels), "archive channels");
            card(N(plan.GhostsToCreate), "ghosts to create"); card(N(plan.ServiceAccountAuthors), "service-account authors"); card(N(plan.UnresolvedIdentities), "unresolved identities");
            card(N(plan.FilesToCopy), "files to copy"); card(Bytes(plan.FileBytesToCopy), "file volume"); card(FormatDuration(plan.EstimatedDuration), "estimated duration");
            sb.Append("</div><p class=\"muted\">Rates: ").Append(H(run.PerConversationRate)).Append(" messages/s per conversation, application ceiling ").Append(H(ceiling)).Append(" messages/s, ").Append(H(run.ConversationParallelism)).Append(" conversations in parallel (effective ").Append(H(effective.ToString("N0", CultureInfo.InvariantCulture))).Append(" messages/s).</p>");

            sb.Append("<h2>Slices</h2><div class=\"wrap\"><table><tr><th>Slice</th><th>From (UTC)</th><th>To (UTC)</th><th class=\"n\">Conversations</th><th class=\"n\">Messages</th><th class=\"n\">Not importable</th></tr>");
            foreach (var s in res.SliceStats)
                sb.Append("<tr><td>").Append(H(s.SliceNo + " - " + s.Name)).Append("</td><td>").Append(H(Iso(s.FromUtc))).Append("</td><td>").Append(H(s.ToUtc.HasValue ? Iso(s.ToUtc) : "open")).Append("</td><td class=\"n\">").Append(N(s.Conversations)).Append("</td><td class=\"n\">").Append(N(s.Messages)).Append("</td><td class=\"n\">").Append(N(s.MessagesSkipped)).Append("</td></tr>");
            sb.Append("</table></div>");

            var kinds = res.Identities.GroupBy(m => m.Kind).OrderBy(g => g.Key.ToString());
            sb.Append("<h2>Identities</h2><div class=\"wrap\"><table><tr><th>Kind</th><th class=\"n\">Users</th></tr>");
            foreach (var g in kinds) sb.Append("<tr><td>").Append(H(g.Key)).Append("</td><td class=\"n\">").Append(N(g.Count())).Append("</td></tr>");
            sb.Append("</table></div>");
            var unres = res.Identities.Where(m => m.Kind == IdentityKind.Unresolved).Take(maxRows).ToList();
            if (unres.Count > 0)
            {
                sb.Append("<h2>Unresolved identities</h2><div class=\"wrap\"><table><tr><th>Source</th><th>Name</th><th>Reason</th></tr>");
                foreach (var m in unres) sb.Append("<tr><td><code>").Append(H(m.SourceUserPrincipalName ?? m.SourceUserId)).Append("</code></td><td>").Append(H(m.SourceDisplayName)).Append("</td><td>").Append(H(m.Note)).Append("</td></tr>");
                sb.Append("</table></div>");
            }
            if (res.Ghosts.Count > 0)
            {
                sb.Append("<h2>Ghost accounts to create (").Append(N(res.Ghosts.Count)).Append(")</h2><div class=\"wrap\"><table><tr><th>Source</th><th>Ghost name</th><th>Ghost UPN</th><th class=\"n\">Messages</th></tr>");
                foreach (var g in res.Ghosts.Take(maxRows)) sb.Append("<tr><td>").Append(H(g.SourceUserPrincipalName ?? g.SourceUserId)).Append("</td><td>").Append(H(g.GhostDisplayName)).Append("</td><td><code>").Append(H(g.GhostUserPrincipalName)).Append("</code></td><td class=\"n\">").Append(N(g.Messages)).Append("</td></tr>");
                sb.Append("</table></div>");
                if (res.Ghosts.Count > maxRows) sb.Append("<p class=\"muted\">First ").Append(maxRows).Append(" of ").Append(N(res.Ghosts.Count)).Append(": see ghosts.csv.</p>");
            }
            if (res.TeamsToCreate.Count > 0)
            {
                sb.Append("<h2>Teams to create</h2><div class=\"wrap\"><table><tr><th>Team</th><th class=\"n\">Channels</th></tr>");
                foreach (var kv in res.TeamsToCreate.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase).Take(maxRows)) sb.Append("<tr><td>").Append(H(kv.Key)).Append("</td><td class=\"n\">").Append(N(kv.Value)).Append("</td></tr>");
                sb.Append("</table></div>");
            }
            sb.Append("<h2>Conversations (largest first)</h2><div class=\"wrap\"><table><tr><th>Source</th><th>Kind</th><th>Topic</th><th>Target</th><th class=\"n\">Messages</th><th>First</th><th>Last</th><th class=\"n\">Files</th><th class=\"n\">Authors</th></tr>");
            foreach (var c in res.Conversations.OrderByDescending(x => x.Messages).Take(maxRows))
                sb.Append("<tr><td><code>").Append(H(c.Key)).Append("</code></td><td>").Append(H(c.Kind)).Append("</td><td>").Append(H(c.Topic ?? c.Team)).Append("</td><td>").Append(H(c.TargetKind)).Append(string.IsNullOrEmpty(c.CreateTeamName) ? "" : " (" + H(c.CreateTeamName) + ")")
                  .Append("</td><td class=\"n\">").Append(N(c.Messages)).Append("</td><td>").Append(H(Iso(c.FirstUtc))).Append("</td><td>").Append(H(Iso(c.LastUtc))).Append("</td><td class=\"n\">").Append(N(c.Files)).Append("</td><td class=\"n\">").Append(N(c.Authors)).Append("</td></tr>");
            sb.Append("</table></div>");
            if (res.Conversations.Count > maxRows) sb.Append("<p class=\"muted\">First ").Append(maxRows).Append(" of ").Append(N(res.Conversations.Count)).Append(": see conversations.csv.</p>");
            sb.Append("<h2>Files of this plan</h2><p class=\"muted\">plan.json, conversations.csv, identities.csv, ghosts.csv, issues.csv, plan.html</p>");
            sb.Append("</main></body></html>");
            return sb.ToString();
        }

        #endregion
    }
}
