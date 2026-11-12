// =============================================================================
//  TeamsTransfer - engine: identity and target mapping
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.2
//
//  IdentityMapper   decides, for every source user that appears in the planned conversations (message authors AND members),
//                   who that person is in the target: IdentityKind Mapped | Same | Ghost | ServiceAccount | Unresolved.
//  TargetMapper     decides, for every planned conversation, where it is imported: TargetKind NewChat | ExistingChat |
//                   NewChannel | ExistingChannel | ArchiveChannel | Skip.
//  TargetDirectory  the READ-ONLY look-ups on the target tenant (users, teams, channels, chats), batched with $batch (20 per
//                   call) and cached. Nothing in this file writes to a tenant. With no GraphClient the directory is
//                   "offline": every look-up is skipped, the mappers say so in their notes.
//
//  IDENTITY RULES (first match wins)
//    0  an existing mapping kept as is: Rule "manual", or a Ghost that already has its target id (created by the Ghosts stage)
//    1  CSV row (SourceUpn / SourceId -> TargetUpn / TargetId)                              Mapped, rule "csv"
//    2  federated / external / non-AAD author                                                ServiceAccount (cannot be imported as that person)
//    3  scenario A (TenantToTenant), user still active in the source:
//         domain rule (a@src -> a@dst) looked up by UPN then by mail in the target          Mapped, rule "domain-rule"
//         same UPN (or mail) in the target                                                  Mapped, rule "upn-match"
//         nothing found                                                                     Unresolved (blocks the plan)
//    4  scenarios B and C (same tenant): GET /users/{id}: exists -> Same ("same-id"; a disabled user or a guest is a valid
//       author); gone -> same UPN or mail (account recreated: old object id -> new)  Mapped "upn-match"
//    5  deleted / absent from the tenant -> MappingOptions.DeletedAuthors:
//         Auto (default)  Ghost when ImportRunOptions.GhostDomain is set, else ServiceAccount
//         Ghost           Ghost (Unresolved when no GhostDomain)       ServiceAccount   ServiceAccount
//       A ghost planned here has TargetUserId = null until the Ghosts stage creates it (the store's ghost table carries the id).
//    A ServiceAccount (rule 2 or 5) needs ImportRunOptions.ServiceAccountUserId; without it the mapping is Unresolved.
//
//  TARGET RULES
//    A  1:1 -> NewChat with the mapped pair (POST /chats returns the existing one); group -> NewChat (topic kept);
//       meeting -> NewChat group with the meeting title (meeting chats are not supported by the import API: warning);
//       channel -> team from the team map CSV or the same display name in the target, created when absent (one member at
//       creation); the channel is ExistingChannel when the team already has one of that name and type (General), else NewChannel.
//       Private / shared membership is kept (CreateMembershipType); only private/shared channels list members.
//    B  the same chat / channel when GET still finds it (ExistingChat / ExistingChannel), else as A.
//    C  every conversation -> ArchiveChannel: one private channel per departed user (all their conversations share it) in
//       archive teams "<prefix> NN" holding at most MappingOptions.ChannelsPerArchiveTeam channels each (Teams limit: 1000
//       including deleted); owners = ArchiveOwners (+ the service account).
//
//  TargetMapping.TargetMemberIds holds target user object ids. A member that is a ghost still to be created is written as
//  "ghost:<SourceUserId>": the importer replaces it by IIdentityMap.Get(SourceUserId).TargetUserId once the Ghosts stage ran.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    public enum DeletedAuthorPolicy { Auto, Ghost, ServiceAccount }

    /// <summary>What the mappers need beyond ImportRunOptions (which belongs to the contracts).</summary>
    public sealed class MappingOptions
    {
        /// <summary>CSV of user mappings: columns SourceUpn and/or SourceId, TargetUpn and/or TargetId (aliases: SourceUserPrincipalName, Source, TargetUserPrincipalName, Target).</summary>
        public string IdentityCsvPath { get; set; }
        /// <summary>Domain rule(s), source domain -> target domain (case-insensitive).</summary>
        public Dictionary<string, string> DomainMap { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        /// <summary>CSV of team mappings: SourceTeamId and/or SourceTeam (name), TargetTeamId and/or TargetTeam (name).</summary>
        public string TeamMapCsvPath { get; set; }
        public DeletedAuthorPolicy DeletedAuthors { get; set; } = DeletedAuthorPolicy.Auto;
        /// <summary>Scenario A without a domain rule or CSV row: try the same UPN / mail in the target.</summary>
        public bool MatchBySameUpn { get; set; } = true;
        /// <summary>Scenario C: archive teams are named "<prefix> NN".</summary>
        public string ArchiveTeamPrefix { get; set; } = "Teams Archive";
        /// <summary>Scenario C: channels per archive team (Teams allows 1000 including deleted ones).</summary>
        public int ChannelsPerArchiveTeam { get; set; } = 200;
        /// <summary>Scenario C: owners of the archive channels (UPNs or object ids). The service account is added.</summary>
        public List<string> ArchiveOwners { get; } = new List<string>();
    }

    public sealed class TargetUserInfo
    {
        public string Id { get; set; }
        public string UserPrincipalName { get; set; }
        public string DisplayName { get; set; }
        public string Mail { get; set; }
        public string UserType { get; set; }
        public bool? AccountEnabled { get; set; }
    }

    public sealed class TargetTeamInfo { public string Id { get; set; } public string DisplayName { get; set; } }
    public sealed class TargetChannelInfo { public string Id { get; set; } public string DisplayName { get; set; } public string MembershipType { get; set; } }

    /// <summary>A source user to map: a message author, a member of a planned conversation, or both.</summary>
    public sealed class SourceIdentity
    {
        public string Id { get; set; }
        public string DisplayName { get; set; }
        public string UserPrincipalName { get; set; }
        public string Mail { get; set; }
        public UserState State { get; set; } = UserState.Unknown;
        /// <summary>from.user.userIdentityType (aadUser, federatedUser, ...); null when unknown.</summary>
        public string IdentityType { get; set; }
        public string TenantId { get; set; }
        /// <summary>Messages authored in the planned slices.</summary>
        public long Messages { get; set; }
    }

    // =========================================================================================================
    #region CSV

    /// <summary>Minimal RFC 4180 reader / writer (quotes, doubled quotes, CR LF inside quotes, BOM, ',' or ';' delimiter).</summary>
    public static class MapCsv
    {
        public static List<Dictionary<string, string>> Read(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("CSV file not found: " + path, path);
            string text = File.ReadAllText(path, Encoding.UTF8);
            var rows = Parse(text);
            var result = new List<Dictionary<string, string>>();
            if (rows.Count == 0) return result;
            var header = rows[0].Select(h => (h ?? "").Trim().Trim('﻿')).ToList();
            for (int i = 1; i < rows.Count; i++)
            {
                var r = rows[i];
                if (r.Count == 0 || (r.Count == 1 && string.IsNullOrWhiteSpace(r[0]))) continue;
                var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int c = 0; c < header.Count; c++) if (header[c].Length > 0) d[header[c]] = c < r.Count ? (r[c] ?? "").Trim() : "";
                result.Add(d);
            }
            return result;
        }

        public static List<List<string>> Parse(string text)
        {
            var rows = new List<List<string>>();
            if (string.IsNullOrEmpty(text)) return rows;
            if (text[0] == '﻿') text = text.Substring(1);
            // delimiter: the one that appears more often on the first line
            int eol = text.IndexOfAny(new[] { '\r', '\n' });
            string first = eol < 0 ? text : text.Substring(0, eol);
            char delim = first.Count(ch => ch == ';') > first.Count(ch => ch == ',') ? ';' : ',';
            var row = new List<string>(); var sb = new StringBuilder(); bool quoted = false, any = false;
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (quoted)
                {
                    if (c == '"') { if (i + 1 < text.Length && text[i + 1] == '"') { sb.Append('"'); i++; } else quoted = false; }
                    else sb.Append(c);
                }
                else if (c == '"') { quoted = true; any = true; }
                else if (c == delim) { row.Add(sb.ToString()); sb.Clear(); any = true; }
                else if (c == '\r' || c == '\n')
                {
                    if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                    if (any || sb.Length > 0 || row.Count > 0) { row.Add(sb.ToString()); rows.Add(row); }
                    row = new List<string>(); sb.Clear(); any = false;
                }
                else { sb.Append(c); any = true; }
            }
            if (any || sb.Length > 0 || row.Count > 0) { row.Add(sb.ToString()); rows.Add(row); }
            return rows;
        }

        public static string Quote(string s)
        {
            if (s == null) return "";
            // a cell that starts like a formula is neutralised (CSV injection when the file is opened in a spreadsheet)
            if (s.Length > 0 && (s[0] == '=' || s[0] == '+' || s[0] == '@' || (s[0] == '-' && s.Length > 1 && !char.IsDigit(s[1])))) s = "'" + s;
            if (s.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0) return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }

        public static string Line(params object[] cells)
        {
            return string.Join(",", cells.Select(c => Quote(c == null ? "" : Convert.ToString(c, CultureInfo.InvariantCulture))));
        }

        internal static string Get(Dictionary<string, string> row, params string[] names)
        {
            foreach (var n in names) { string v; if (row.TryGetValue(n, out v) && !string.IsNullOrWhiteSpace(v)) return v.Trim(); }
            return null;
        }
    }

    #endregion

    // =========================================================================================================
    #region TargetDirectory: read-only look-ups on the target tenant

    public sealed class TargetDirectory
    {
        const string UserSelect = "id,userPrincipalName,displayName,mail,userType,accountEnabled";
        readonly GraphClient _client;
        readonly Dictionary<string, TargetUserInfo> _byId = new Dictionary<string, TargetUserInfo>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, TargetUserInfo> _byUpn = new Dictionary<string, TargetUserInfo>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, TargetUserInfo> _byMail = new Dictionary<string, TargetUserInfo>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> _missId = new HashSet<string>(StringComparer.OrdinalIgnoreCase), _missUpn = new HashSet<string>(StringComparer.OrdinalIgnoreCase), _missMail = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, bool> _exists = new Dictionary<string, bool>(StringComparer.Ordinal);
        readonly Dictionary<string, List<TargetTeamInfo>> _teamsByName = new Dictionary<string, List<TargetTeamInfo>>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, List<TargetChannelInfo>> _channels = new Dictionary<string, List<TargetChannelInfo>>(StringComparer.OrdinalIgnoreCase);

        /// <summary>A directory without a client answers nothing (offline plan).</summary>
        public TargetDirectory(GraphClient client) { _client = client; }
        public bool Online { get { return _client != null; } }
        /// <summary>Number of read requests sent through $batch or GET (informational).</summary>
        public int Lookups { get; private set; }

        static string Esc(string v) { return Uri.EscapeDataString((v ?? "").Replace("'", "''")); }

        static TargetUserInfo ParseUser(JsonElement e)
        {
            var u = new TargetUserInfo { Id = Str(e, "id"), UserPrincipalName = Str(e, "userPrincipalName"), DisplayName = Str(e, "displayName"), Mail = Str(e, "mail"), UserType = Str(e, "userType") };
            JsonElement p;
            if (e.TryGetProperty("accountEnabled", out p) && (p.ValueKind == JsonValueKind.True || p.ValueKind == JsonValueKind.False)) u.AccountEnabled = p.GetBoolean();
            return u;
        }

        internal static string Str(JsonElement e, string name)
        {
            JsonElement p;
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out p) && p.ValueKind == JsonValueKind.String) return p.GetString();
            return null;
        }

        void Remember(TargetUserInfo u)
        {
            if (u == null || u.Id == null) return;
            _byId[u.Id] = u;
            if (u.UserPrincipalName != null) _byUpn[u.UserPrincipalName] = u;
            if (u.Mail != null) _byMail[u.Mail] = u;
        }

        static Exception Fail(BatchResult r, string what)
        {
            string hint = r.StatusCode == 403 || r.StatusCode == 401 ? " The target application needs User.Read.All (and Team.ReadBasic.All / Channel.ReadBasic.All / Chat.ReadBasic.All) to plan." : "";
            return new InvalidOperationException("Target look-up failed (" + what + "): " + r.StatusCode + " " + r.ErrorCode + " " + r.ErrorMessage + "." + hint);
        }

        /// <summary>Looks the users up in the target, in batches: by object id (GET /users/{id}), by UPN and by mail (GET /users?$filter=... eq ...). Results are cached.</summary>
        public async Task PrefetchUsersAsync(IEnumerable<string> ids, IEnumerable<string> upns, IEnumerable<string> mails, CancellationToken ct)
        {
            if (_client == null) return;
            var items = new List<BatchItem>();
            var map = new Dictionary<string, (char kind, string value)>(StringComparer.Ordinal);
            int n = 0;
            Action<char, string, string> add = (kind, value, url) =>
            {
                string id = "r" + (n++).ToString(CultureInfo.InvariantCulture);
                items.Add(new BatchItem { Id = id, Url = url, EndpointClass = EndpointClass.Users });
                map[id] = (kind, value);
            };
            foreach (var v in (ids ?? new string[0]).Where(x => !string.IsNullOrEmpty(x)).Distinct(StringComparer.OrdinalIgnoreCase))
                if (!_byId.ContainsKey(v) && !_missId.Contains(v)) add('i', v, "/users/" + Uri.EscapeDataString(v) + "?$select=" + UserSelect);
            foreach (var v in (upns ?? new string[0]).Where(x => !string.IsNullOrEmpty(x)).Distinct(StringComparer.OrdinalIgnoreCase))
                if (!_byUpn.ContainsKey(v) && !_missUpn.Contains(v)) add('u', v, "/users?$filter=" + Uri.EscapeDataString("userPrincipalName eq '") + Esc(v) + Uri.EscapeDataString("'") + "&$select=" + UserSelect);
            foreach (var v in (mails ?? new string[0]).Where(x => !string.IsNullOrEmpty(x)).Distinct(StringComparer.OrdinalIgnoreCase))
                if (!_byMail.ContainsKey(v) && !_missMail.Contains(v)) add('m', v, "/users?$filter=" + Uri.EscapeDataString("mail eq '") + Esc(v) + Uri.EscapeDataString("'") + "&$select=" + UserSelect);
            if (items.Count == 0) return;
            // chunks of 200 keep a progress/cancellation point without holding 100k results at once
            for (int i = 0; i < items.Count; i += 200)
            {
                ct.ThrowIfCancellationRequested();
                var chunk = items.GetRange(i, Math.Min(200, items.Count - i));
                Lookups += chunk.Count;
                var results = await _client.BatchAsync(chunk, ct).ConfigureAwait(false);
                foreach (var r in results)
                {
                    var key = map[r.Id];
                    if (r.StatusCode == 404) { MarkMissing(key.kind, key.value); continue; }
                    if (!r.IsSuccess) throw Fail(r, "user " + key.value);
                    using (var doc = r.ParseBody())
                    {
                        if (doc == null) { MarkMissing(key.kind, key.value); continue; }
                        JsonElement el = doc.RootElement, arr;
                        if (key.kind != 'i')
                        {
                            if (el.TryGetProperty("value", out arr) && arr.ValueKind == JsonValueKind.Array && arr.GetArrayLength() > 0) el = arr[0];
                            else { MarkMissing(key.kind, key.value); continue; }
                        }
                        var u = ParseUser(el);
                        if (u.Id == null) { MarkMissing(key.kind, key.value); continue; }
                        Remember(u);
                        // the key it was asked by must hit the cache even when the service answered another casing / alias
                        if (key.kind == 'u') _byUpn[key.value] = u; else if (key.kind == 'm') _byMail[key.value] = u; else _byId[key.value] = u;
                    }
                }
            }
        }

        void MarkMissing(char kind, string v) { if (kind == 'i') _missId.Add(v); else if (kind == 'u') _missUpn.Add(v); else _missMail.Add(v); }

        public TargetUserInfo CachedById(string id) { TargetUserInfo u; return id != null && _byId.TryGetValue(id, out u) ? u : null; }
        public TargetUserInfo CachedByUpn(string upn) { TargetUserInfo u; return upn != null && _byUpn.TryGetValue(upn, out u) ? u : null; }
        public TargetUserInfo CachedByMail(string mail) { TargetUserInfo u; return mail != null && _byMail.TryGetValue(mail, out u) ? u : null; }

        /// <summary>One user by object id or UPN (null when absent). Read-only.</summary>
        public async Task<TargetUserInfo> FindUserAsync(string idOrUpn, CancellationToken ct)
        {
            if (string.IsNullOrEmpty(idOrUpn) || _client == null) return null;
            bool upn = idOrUpn.Contains("@");
            if (upn) await PrefetchUsersAsync(null, new[] { idOrUpn }, null, ct).ConfigureAwait(false);
            else await PrefetchUsersAsync(new[] { idOrUpn }, null, null, ct).ConfigureAwait(false);
            return upn ? CachedByUpn(idOrUpn) : CachedById(idOrUpn);
        }

        /// <summary>GET existence of many relative URLs in batches (200 OK = true, 404 = false, anything else throws). Cached.</summary>
        public async Task PrefetchExistsAsync(IEnumerable<string> relativeUrls, CancellationToken ct)
        {
            if (_client == null) return;
            var items = new List<BatchItem>();
            int n = 0;
            var byId = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var u in relativeUrls.Distinct(StringComparer.Ordinal))
            {
                if (_exists.ContainsKey(u)) continue;
                string id = "e" + (n++).ToString(CultureInfo.InvariantCulture);
                byId[id] = u;
                items.Add(new BatchItem { Id = id, Url = u, EndpointClass = GraphClient.Classify(u) });
            }
            for (int i = 0; i < items.Count; i += 200)
            {
                ct.ThrowIfCancellationRequested();
                var chunk = items.GetRange(i, Math.Min(200, items.Count - i));
                Lookups += chunk.Count;
                var results = await _client.BatchAsync(chunk, ct).ConfigureAwait(false);
                foreach (var r in results)
                {
                    if (r.StatusCode == 404) _exists[byId[r.Id]] = false;
                    else if (r.IsSuccess) _exists[byId[r.Id]] = true;
                    else throw Fail(r, byId[r.Id]);
                }
            }
        }

        public bool? Exists(string relativeUrl) { bool b; return _exists.TryGetValue(relativeUrl, out b) ? b : (bool?)null; }

        public static string ChatUrl(string chatId) { return "/chats/" + Uri.EscapeDataString(chatId).Replace("%3A", ":").Replace("%40", "@") + "?$select=id"; }
        public static string TeamUrl(string teamId) { return "/teams/" + Uri.EscapeDataString(teamId) + "?$select=id"; }
        public static string ChannelUrl(string teamId, string channelId) { return "/teams/" + Uri.EscapeDataString(teamId) + "/channels/" + Uri.EscapeDataString(channelId).Replace("%3A", ":").Replace("%40", "@") + "?$select=id"; }

        /// <summary>Teams with this exact display name (GET /teams with a displayName filter, which only needs Team.ReadBasic.All;
        /// /groups would need Group.Read.All). The name is compared again here.</summary>
        public async Task<IReadOnlyList<TargetTeamInfo>> FindTeamsByNameAsync(string displayName, CancellationToken ct)
        {
            if (_client == null || string.IsNullOrEmpty(displayName)) return new List<TargetTeamInfo>();
            List<TargetTeamInfo> list;
            if (_teamsByName.TryGetValue(displayName, out list)) return list;
            list = new List<TargetTeamInfo>();
            string url = "v1.0/teams?$filter=" + Uri.EscapeDataString("displayName eq '" + (displayName ?? "").Replace("'", "''") + "'") + "&$select=id,displayName";
            Lookups++;
            await foreach (var e in _client.GetPagedAsync(url, EndpointClass.Teams, null, null, null, ct).ConfigureAwait(false))
            {
                string name = Str(e, "displayName");
                if (string.Equals(name, displayName, StringComparison.OrdinalIgnoreCase)) list.Add(new TargetTeamInfo { Id = Str(e, "id"), DisplayName = name });
            }
            _teamsByName[displayName] = list;
            return list;
        }

        /// <summary>The channels of a target team (empty offline or when the team does not exist).</summary>
        public async Task<IReadOnlyList<TargetChannelInfo>> ListChannelsAsync(string teamId, CancellationToken ct)
        {
            if (_client == null || string.IsNullOrEmpty(teamId)) return new List<TargetChannelInfo>();
            List<TargetChannelInfo> list;
            if (_channels.TryGetValue(teamId, out list)) return list;
            list = new List<TargetChannelInfo>();
            Lookups++;
            try
            {
                await foreach (var e in _client.GetPagedAsync("v1.0/teams/" + Uri.EscapeDataString(teamId) + "/channels", EndpointClass.Channels, null, null, null, ct).ConfigureAwait(false))
                    list.Add(new TargetChannelInfo { Id = Str(e, "id"), DisplayName = Str(e, "displayName"), MembershipType = (Str(e, "membershipType") ?? "standard").ToLowerInvariant() });
            }
            catch (GraphException ex) when (ex.StatusCode == 404) { }
            _channels[teamId] = list;
            return list;
        }
    }

    #endregion

    // =========================================================================================================
    #region IdentityMapper

    public sealed class IdentityMapper
    {
        readonly IIdentityMap _map;
        readonly ImportRunOptions _run;
        readonly MappingOptions _opt;
        readonly TargetDirectory _dir;
        readonly Func<string, GhostRecord> _ghosts;
        Dictionary<string, Dictionary<string, string>> _csvById, _csvByUpn;

        /// <param name="ghostLookup">Optional: the store's ghost table (TmtStore.GetGhost), so a ghost already created keeps its target id.</param>
        public IdentityMapper(IIdentityMap map, ImportRunOptions run, MappingOptions options, TargetDirectory directory, Func<string, GhostRecord> ghostLookup = null)
        {
            _map = map; _run = run ?? new ImportRunOptions(); _opt = options ?? new MappingOptions(); _dir = directory ?? new TargetDirectory(null); _ghosts = ghostLookup;
        }

        /// <summary>The UPN a ghost gets in the target. Null without a domain. Single source of truth:
        /// GhostProvisioner.UpnFor, the account actually created (the plan and the Ghosts stage must announce and create the same
        /// 16-hex UPN).</summary>
        public static string GhostUpn(string sourceUserId, string ghostDomain)
        {
            if (string.IsNullOrWhiteSpace(ghostDomain)) return null;
            return GhostProvisioner.UpnFor(sourceUserId, ghostDomain);
        }

        static string DomainOf(string upn) { int i = upn == null ? -1 : upn.LastIndexOf('@'); return i > 0 ? upn.Substring(i + 1) : null; }
        static string LocalOf(string upn) { int i = upn == null ? -1 : upn.LastIndexOf('@'); return i > 0 ? upn.Substring(0, i) : upn; }

        static bool IsAadIdentity(string identityType)
        {
            return string.IsNullOrEmpty(identityType) || identityType.Equals("aadUser", StringComparison.OrdinalIgnoreCase) || identityType.Equals("onPremiseAadUser", StringComparison.OrdinalIgnoreCase);
        }

        void LoadCsv()
        {
            if (_csvById != null) return;
            _csvById = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            _csvByUpn = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrWhiteSpace(_opt.IdentityCsvPath)) return;
            foreach (var row in MapCsv.Read(_opt.IdentityCsvPath))
            {
                string sid = MapCsv.Get(row, "SourceId", "SourceUserId", "SourceObjectId"), sup = MapCsv.Get(row, "SourceUpn", "SourceUserPrincipalName", "Source");
                if (MapCsv.Get(row, "TargetUpn", "TargetUserPrincipalName", "Target", "TargetId", "TargetUserId") == null) continue;   // no target: nothing to say
                if (sid != null) _csvById[sid] = row;
                if (sup != null) _csvByUpn[sup] = row;
            }
        }

        /// <summary>
        /// Maps every source identity and stores the result in the identity map (one transaction when the map is a TmtStore).
        /// Returns the mappings in the order of the input. Read-only on the target tenant.
        /// </summary>
        public async Task<IReadOnlyList<IdentityMapping>> ResolveAsync(IReadOnlyList<SourceIdentity> sources, ImportScenario scenario, CancellationToken ct)
        {
            LoadCsv();
            var result = new IdentityMapping[sources.Count];
            var pending = new List<int>();

            // phase 1: what needs no look-up (kept mappings, federated authors) and what needs one
            var wantIds = new List<string>(); var wantUpns = new List<string>(); var wantMails = new List<string>();
            var csvRow = new Dictionary<int, Dictionary<string, string>>();
            var known = new Dictionary<string, IdentityMapping>(StringComparer.OrdinalIgnoreCase);   // one pass over the map, not one query per user
            if (_map != null) foreach (var m in _map.List()) known[m.SourceUserId] = m;
            for (int i = 0; i < sources.Count; i++)
            {
                var s = sources[i];
                IdentityMapping existing;
                if (!known.TryGetValue(s.Id ?? "", out existing)) existing = null;
                if (existing != null && (string.Equals(existing.Rule, "manual", StringComparison.OrdinalIgnoreCase) || (existing.Kind == IdentityKind.Ghost && !string.IsNullOrEmpty(existing.TargetUserId))))
                {
                    result[i] = existing; continue;
                }
                var g = _ghosts == null ? null : _ghosts(s.Id);
                if (g != null && g.State == GhostState.Created && !string.IsNullOrEmpty(g.GhostId))
                {
                    result[i] = Base(s, IdentityKind.Ghost, g.GhostId, g.DisplayName, "ghost", "ghost account already created"); continue;
                }
                Dictionary<string, string> row = null;
                if (!_csvById.TryGetValue(s.Id ?? "", out row) && s.UserPrincipalName != null) _csvByUpn.TryGetValue(s.UserPrincipalName, out row);
                if (row != null)
                {
                    csvRow[i] = row;
                    string tid = MapCsv.Get(row, "TargetId", "TargetUserId", "TargetObjectId"), tup = MapCsv.Get(row, "TargetUpn", "TargetUserPrincipalName", "Target");
                    if (tid != null) wantIds.Add(tid); else if (tup != null) wantUpns.Add(tup);
                    pending.Add(i); continue;
                }
                if (!IsAadIdentity(s.IdentityType) || s.State == UserState.External)
                {
                    result[i] = Fallback(s, "service-account", "federated or external author: its content cannot be imported as that person"); continue;
                }
                if (s.State != UserState.Deleted)
                {
                    if (scenario == ImportScenario.TenantToTenant)
                    {
                        foreach (var cand in CandidateUpns(s)) wantUpns.Add(cand);
                        if (_opt.MatchBySameUpn) { if (s.Mail != null) wantMails.Add(s.Mail); if (s.Mail != null) foreach (var c in CandidateMails(s)) wantMails.Add(c); }
                    }
                    else { wantIds.Add(s.Id); if (s.UserPrincipalName != null) wantUpns.Add(s.UserPrincipalName); }
                }
                else if (scenario != ImportScenario.TenantToTenant && s.UserPrincipalName != null) wantUpns.Add(s.UserPrincipalName);   // a recreated account
                pending.Add(i);
            }

            // phase 2: look-ups (batched, read-only)
            await _dir.PrefetchUsersAsync(wantIds, wantUpns, wantMails, ct).ConfigureAwait(false);

            // phase 3: decisions
            foreach (int i in pending)
            {
                var s = sources[i];
                Dictionary<string, string> row;
                result[i] = csvRow.TryGetValue(i, out row) ? FromCsv(s, row) : Decide(s, scenario);
            }

            if (_map != null)
            {
                var store = _map as TmtStore;
                if (store != null) store.UpsertIdentities(result);
                else foreach (var m in result) _map.Upsert(m);
            }
            return result;
        }

        IdentityMapping Base(SourceIdentity s, IdentityKind kind, string targetId, string targetName, string rule, string note)
        {
            return new IdentityMapping
            {
                SourceUserId = s.Id, SourceDisplayName = s.DisplayName, SourceUserPrincipalName = s.UserPrincipalName, Kind = kind, TargetUserId = targetId,
                TargetDisplayName = targetName ?? s.DisplayName, Rule = rule, Note = note
            };
        }

        IdentityMapping FromCsv(SourceIdentity s, Dictionary<string, string> row)
        {
            string tid = MapCsv.Get(row, "TargetId", "TargetUserId", "TargetObjectId"), tup = MapCsv.Get(row, "TargetUpn", "TargetUserPrincipalName", "Target");
            if (!_dir.Online)
            {
                if (tid != null) return Base(s, IdentityKind.Mapped, tid, null, "csv", "target not checked (offline plan)");
                return Base(s, IdentityKind.Unresolved, null, null, "csv", "CSV gives " + tup + " but the target tenant was not looked up (offline plan): give TargetId or plan online");
            }
            var u = tid != null ? _dir.CachedById(tid) : _dir.CachedByUpn(tup) ?? _dir.CachedByMail(tup);
            if (u == null) return Base(s, IdentityKind.Unresolved, null, null, "csv", "CSV target " + (tid ?? tup) + " does not exist in the target tenant");
            return Base(s, IdentityKind.Mapped, u.Id, u.DisplayName, "csv", Note(u));
        }

        static string Note(TargetUserInfo u)
        {
            if (u.AccountEnabled == false) return "target account is disabled (valid author)";
            if (string.Equals(u.UserType, "Guest", StringComparison.OrdinalIgnoreCase)) return "target account is a guest (valid author)";
            return null;
        }

        IEnumerable<string> CandidateUpns(SourceIdentity s)
        {
            string upn = s.UserPrincipalName;
            if (upn == null) yield break;
            string dom = DomainOf(upn), dst;
            if (dom != null && _opt.DomainMap.TryGetValue(dom, out dst)) yield return LocalOf(upn) + "@" + dst;
            if (_opt.MatchBySameUpn) yield return upn;
        }

        IEnumerable<string> CandidateMails(SourceIdentity s)
        {
            string mail = s.Mail ?? s.UserPrincipalName;
            if (mail == null) yield break;
            string dom = DomainOf(mail), dst;
            if (dom != null && _opt.DomainMap.TryGetValue(dom, out dst)) yield return LocalOf(mail) + "@" + dst;
        }

        IdentityMapping Decide(SourceIdentity s, ImportScenario scenario)
        {
            if (s.State == UserState.Deleted)
            {
                if (scenario != ImportScenario.TenantToTenant)
                {
                    var re = _dir.CachedByUpn(s.UserPrincipalName);
                    if (re != null) return Base(s, IdentityKind.Mapped, re.Id, re.DisplayName, "upn-match", "account recreated in the tenant (old object id -> new)");
                }
                return Gone(s, "no longer in the source tenant");
            }
            if (scenario == ImportScenario.TenantToTenant)
            {
                if (!_dir.Online) return Base(s, IdentityKind.Unresolved, null, null, null, "no CSV row and the target tenant was not looked up (offline plan)");
                string dom = DomainOf(s.UserPrincipalName), dst;
                bool ruled = dom != null && _opt.DomainMap.TryGetValue(dom, out dst);
                if (ruled)
                {
                    var cands = new List<string> { LocalOf(s.UserPrincipalName) + "@" + _opt.DomainMap[dom] };
                    string mdst;
                    if (s.Mail != null && DomainOf(s.Mail) != null && _opt.DomainMap.TryGetValue(DomainOf(s.Mail), out mdst)) cands.Add(LocalOf(s.Mail) + "@" + mdst);
                    foreach (var cand in cands.Distinct(StringComparer.OrdinalIgnoreCase))
                    {
                        var u = _dir.CachedByUpn(cand) ?? _dir.CachedByMail(cand);
                        if (u != null) return Base(s, IdentityKind.Mapped, u.Id, u.DisplayName, "domain-rule", Note(u));
                    }
                }
                if (_opt.MatchBySameUpn)
                {
                    var u = _dir.CachedByUpn(s.UserPrincipalName) ?? _dir.CachedByMail(s.Mail ?? s.UserPrincipalName);
                    if (u != null) return Base(s, IdentityKind.Mapped, u.Id, u.DisplayName, "upn-match", Note(u));
                }
                return Base(s, IdentityKind.Unresolved, null, null, ruled ? "domain-rule" : null, "no matching user in the target tenant" + (ruled ? " for " + LocalOf(s.UserPrincipalName) + "@" + _opt.DomainMap[dom] : "") + ": add a CSV row, or decide ghost / service account");
            }
            // same tenant (B, C)
            if (!_dir.Online) return Base(s, IdentityKind.Same, s.Id, s.DisplayName, "same-id", "target not checked (offline plan)");
            var same = _dir.CachedById(s.Id);
            if (same != null) return Base(s, IdentityKind.Same, same.Id, same.DisplayName, "same-id", Note(same));
            var recreated = _dir.CachedByUpn(s.UserPrincipalName);
            if (recreated != null) return Base(s, IdentityKind.Mapped, recreated.Id, recreated.DisplayName, "upn-match", "account recreated in the tenant (old object id -> new)");
            return Gone(s, "no longer in the tenant");
        }

        IdentityMapping Gone(SourceIdentity s, string why)
        {
            bool ghost = _opt.DeletedAuthors == DeletedAuthorPolicy.Ghost || (_opt.DeletedAuthors == DeletedAuthorPolicy.Auto && !string.IsNullOrWhiteSpace(_run.GhostDomain));
            if (ghost)
            {
                if (string.IsNullOrWhiteSpace(_run.GhostDomain)) return Base(s, IdentityKind.Unresolved, null, null, "ghost", why + "; ghost accounts need a ghost domain (GhostDomain)");
                string name = string.Format(CultureInfo.InvariantCulture, _run.GhostDisplayNameFormat ?? "{0} (former)", s.DisplayName ?? s.UserPrincipalName ?? s.Id);
                return Base(s, IdentityKind.Ghost, null, name, "ghost", why + "; ghost " + GhostUpn(s.Id, _run.GhostDomain) + " to create");
            }
            return Fallback(s, "service-account", why + "; the original author is named in the message");
        }

        IdentityMapping Fallback(SourceIdentity s, string rule, string why)
        {
            if (string.IsNullOrEmpty(_run.ServiceAccountUserId)) return Base(s, IdentityKind.Unresolved, null, null, rule, why + "; no service account is configured (ServiceAccountUserId)");
            return Base(s, IdentityKind.ServiceAccount, _run.ServiceAccountUserId, null, rule, why);
        }
    }

    #endregion

    // =========================================================================================================
    #region TargetMapper

    public sealed class TargetMapResult
    {
        public List<TargetMapping> Targets { get; } = new List<TargetMapping>();
        public List<string> Warnings { get; } = new List<string>();
        public List<string> Blockers { get; } = new List<string>();
        /// <summary>Teams that will be created (name -> number of conversations that need it).</summary>
        public Dictionary<string, int> TeamsToCreate { get; } = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Scenario C: archive team name -> number of channels (existing + planned).</summary>
        public Dictionary<string, int> ArchiveTeams { get; } = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public int MeetingChats { get; set; }
    }

    public sealed class TargetMapper
    {
        readonly ImportRunOptions _run;
        readonly MappingOptions _opt;
        readonly TargetDirectory _dir;
        readonly Func<string, IdentityMapping> _identity;
        readonly ITargetMap _existing;
        List<Dictionary<string, string>> _teamCsv;
        readonly Dictionary<string, TeamRes> _teams = new Dictionary<string, TeamRes>(StringComparer.OrdinalIgnoreCase);

        sealed class TeamRes { public string Id; public string Name; public bool Exists; }

        public TargetMapper(ImportRunOptions run, MappingOptions options, TargetDirectory directory, Func<string, IdentityMapping> identity, ITargetMap existing = null)
        {
            _run = run ?? new ImportRunOptions(); _opt = options ?? new MappingOptions(); _dir = directory ?? new TargetDirectory(null); _identity = identity; _existing = existing;
        }

        /// <summary>Characters a channel name cannot hold, length 50, no leading/trailing dot or underscore (Teams rules).</summary>
        public static string SanitizeChannelName(string name)
        {
            var sb = new StringBuilder();
            foreach (char c in name ?? "") sb.Append("~#%&*{}+/\\:<>?|'\"".IndexOf(c) >= 0 || char.IsControl(c) ? ' ' : c);
            string s = System.Text.RegularExpressions.Regex.Replace(sb.ToString(), @"\s+", " ").Trim().TrimEnd('.').TrimStart('_', '.');
            if (s.Length > 50) s = s.Substring(0, 50).TrimEnd();
            return s.Length == 0 ? "Channel" : s;
        }

        /// <summary>
        /// Maps the conversations. membersOf / authorsOf give the source user ids of a conversation (members first, authors as a fallback);
        /// departedOwnerOf (scenario C) gives (source user id, display name) of the departed user a conversation is archived for, or null.
        /// </summary>
        public async Task<TargetMapResult> MapAsync(IReadOnlyList<ConversationRecord> conversations, ImportScenario scenario, Func<string, IEnumerable<string>> authorsOf,
            Func<string, Tuple<string, string>> departedOwnerOf, CancellationToken ct)
        {
            var res = new TargetMapResult();
            _teamCsv = string.IsNullOrWhiteSpace(_opt.TeamMapCsvPath) ? new List<Dictionary<string, string>>() : MapCsv.Read(_opt.TeamMapCsvPath);
            if (scenario == ImportScenario.DepartedArchive) { await MapArchiveAsync(conversations, authorsOf, departedOwnerOf, res, ct).ConfigureAwait(false); return res; }

            // B: which source objects still exist (one batched pass)
            if (scenario == ImportScenario.SameTenantRestore && _dir.Online)
            {
                var urls = new List<string>();
                foreach (var c in conversations)
                {
                    if (c.Kind == ConversationKind.Channel) { if (c.TeamId != null && c.ChannelId != null) { urls.Add(TargetDirectory.ChannelUrl(c.TeamId, c.ChannelId)); urls.Add(TargetDirectory.TeamUrl(c.TeamId)); } }
                    else if (c.ChatId != null) urls.Add(TargetDirectory.ChatUrl(c.ChatId));
                }
                await _dir.PrefetchExistsAsync(urls, ct).ConfigureAwait(false);
            }

            foreach (var c in conversations)
            {
                ct.ThrowIfCancellationRequested();
                TargetMapping t;
                if (c.Kind == ConversationKind.Channel) t = await MapChannelAsync(c, scenario, authorsOf, res, ct).ConfigureAwait(false);
                else t = MapChat(c, scenario, authorsOf, res);
                res.Targets.Add(t);
            }
            return res;
        }

        /// <summary>Target ids of the members (or, without a member list, of the authors) of a conversation. ghost:&lt;id&gt; for a ghost not created yet.</summary>
        List<string> MemberTargets(ConversationRecord c, Func<string, IEnumerable<string>> authorsOf, out bool anyUnresolved, out bool fromAuthors)
        {
            anyUnresolved = false; fromAuthors = false;
            var ids = new List<string>();
            if (!string.IsNullOrEmpty(c.MembersJson))
            {
                try
                {
                    using (var doc = JsonDocument.Parse(c.MembersJson))
                        if (doc.RootElement.ValueKind == JsonValueKind.Array)
                            foreach (var m in doc.RootElement.EnumerateArray()) { string id = TargetDirectory.Str(m, "userId"); if (id != null) ids.Add(id); }
                }
                catch (JsonException) { }
            }
            if (ids.Count == 0 && authorsOf != null) { ids.AddRange(authorsOf(c.Key) ?? new string[0]); fromAuthors = ids.Count > 0; }
            var result = new List<string>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var sid in ids.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var m = _identity(sid);
                string tid;
                if (m == null || m.Kind == IdentityKind.Unresolved) { anyUnresolved = true; continue; }
                if (m.Kind == IdentityKind.Ghost && string.IsNullOrEmpty(m.TargetUserId)) tid = "ghost:" + sid; else tid = m.TargetUserId;
                if (!string.IsNullOrEmpty(tid) && seen.Add(tid)) result.Add(tid);
            }
            return result;
        }

        TargetMapping MapChat(ConversationRecord c, ImportScenario scenario, Func<string, IEnumerable<string>> authorsOf, TargetMapResult res)
        {
            var t = new TargetMapping { SourceConversationKey = c.Key };
            if (c.Kind == ConversationKind.Meeting)
            {
                res.MeetingChats++;
                t.Note = "meeting chat: the import API does not support meeting chats, imported as a group chat with the meeting title";
            }
            if (scenario == ImportScenario.SameTenantRestore && c.ChatId != null)
            {
                bool? ex = _dir.Online ? _dir.Exists(TargetDirectory.ChatUrl(c.ChatId)) : true;
                if (ex == true)
                {
                    t.Kind = TargetKind.ExistingChat; t.TargetChatId = c.ChatId;
                    t.Note = Join(t.Note, _dir.Online ? "the chat still exists: messages are appended" : "target not checked (offline plan): assumed to exist");
                    return t;
                }
                t.Note = Join(t.Note, "the chat no longer exists: a new chat is created");
            }
            bool unresolved, fromAuthors;
            var members = MemberTargets(c, authorsOf, out unresolved, out fromAuthors);
            t.Kind = TargetKind.NewChat;
            t.CreateMembershipType = c.Kind == ConversationKind.OneOnOne ? "oneOnOne" : "group";
            t.CreateTopic = c.Kind == ConversationKind.OneOnOne ? null : c.Topic;
            t.TargetMemberIds = members;
            if (fromAuthors) t.Note = Join(t.Note, "no member list was exported: members taken from the message authors");
            if (members.Count == 0)
            {
                t.Kind = TargetKind.Skip;
                t.Note = Join(t.Note, unresolved ? "no member could be mapped yet (unresolved identities)" : "no member to create the chat with");
                if (!unresolved) res.Warnings.Add("Conversation " + c.Key + " has no member that can be mapped: skipped.");
            }
            else if (c.Kind == ConversationKind.OneOnOne && members.Count < 2 && !unresolved)
                t.Note = Join(t.Note, "the other participant maps to the same account: the chat has one member");
            return t;
        }

        async Task<TargetMapping> MapChannelAsync(ConversationRecord c, ImportScenario scenario, Func<string, IEnumerable<string>> authorsOf, TargetMapResult res, CancellationToken ct)
        {
            var t = new TargetMapping { SourceConversationKey = c.Key, CreateMembershipType = c.MembershipType ?? "standard" };
            string chanName = SanitizeChannelName(c.Topic ?? c.ChannelId);
            if (!string.Equals(chanName, c.Topic, StringComparison.Ordinal)) t.Note = Join(t.Note, "channel name adjusted to the Teams rules");
            if (string.Equals(t.CreateMembershipType, "shared", StringComparison.OrdinalIgnoreCase)) res.Warnings.Add("Shared channel " + c.Key + ": members from other teams or tenants cannot be recreated, only the messages are imported.");

            if (scenario == ImportScenario.SameTenantRestore && c.TeamId != null && c.ChannelId != null)
            {
                bool? chEx = _dir.Online ? _dir.Exists(TargetDirectory.ChannelUrl(c.TeamId, c.ChannelId)) : true;
                if (chEx == true)
                {
                    t.Kind = TargetKind.ExistingChannel; t.TargetTeamId = c.TeamId; t.TargetChannelId = c.ChannelId;
                    t.Note = Join(t.Note, _dir.Online ? "the channel still exists: messages are appended" : "target not checked (offline plan): assumed to exist");
                    return t;
                }
                t.Note = Join(t.Note, "the channel no longer exists: a new channel is created");
            }

            var team = await ResolveTeamAsync(c, scenario, ct).ConfigureAwait(false);
            t.CreateTopic = chanName;
            if (team.Exists)
            {
                t.TargetTeamId = team.Id; t.CreateTeamName = team.Name;
                var existing = (await _dir.ListChannelsAsync(team.Id, ct).ConfigureAwait(false))
                    .FirstOrDefault(x => string.Equals(x.DisplayName, chanName, StringComparison.OrdinalIgnoreCase) && string.Equals(x.MembershipType, t.CreateMembershipType, StringComparison.OrdinalIgnoreCase));
                if (existing != null) { t.Kind = TargetKind.ExistingChannel; t.TargetChannelId = existing.Id; t.Note = Join(t.Note, "the team already has this channel"); return t; }
            }
            else
            {
                t.CreateTeamName = team.Name;
                int n; res.TeamsToCreate.TryGetValue(team.Name, out n); res.TeamsToCreate[team.Name] = n + 1;
                t.Note = Join(t.Note, "team '" + team.Name + "' is created with ONE member (the service account); the others are added afterwards");
            }
            t.Kind = TargetKind.NewChannel;
            if (!string.Equals(t.CreateMembershipType, "standard", StringComparison.OrdinalIgnoreCase))
            {
                bool unresolved, fromAuthors;
                t.TargetMemberIds = MemberTargets(c, authorsOf, out unresolved, out fromAuthors);
            }
            return t;
        }

        async Task<TeamRes> ResolveTeamAsync(ConversationRecord c, ImportScenario scenario, CancellationToken ct)
        {
            string cacheKey = c.TeamId ?? ("name:" + c.TeamDisplayName);
            TeamRes r;
            if (_teams.TryGetValue(cacheKey, out r)) return r;
            string srcName = string.IsNullOrWhiteSpace(c.TeamDisplayName) ? "Team " + (c.TeamId ?? "") : c.TeamDisplayName;
            Dictionary<string, string> row = _teamCsv.FirstOrDefault(x => (MapCsv.Get(x, "SourceTeamId") != null && string.Equals(MapCsv.Get(x, "SourceTeamId"), c.TeamId, StringComparison.OrdinalIgnoreCase)) ||
                (MapCsv.Get(x, "SourceTeam", "SourceTeamName") != null && string.Equals(MapCsv.Get(x, "SourceTeam", "SourceTeamName"), c.TeamDisplayName, StringComparison.OrdinalIgnoreCase)));
            string tgtId = row == null ? null : MapCsv.Get(row, "TargetTeamId");
            string tgtName = row == null ? null : MapCsv.Get(row, "TargetTeam", "TargetTeamName");
            r = new TeamRes { Name = tgtName ?? srcName };
            if (!_dir.Online)
            {
                // offline: a team given by id is trusted; the same tenant keeps its team; otherwise it is planned as "to create"
                if (tgtId != null) { r.Id = tgtId; r.Exists = true; }
                else if (scenario == ImportScenario.SameTenantRestore && c.TeamId != null) { r.Id = c.TeamId; r.Exists = true; }
            }
            else if (tgtId != null)
            {
                await _dir.PrefetchExistsAsync(new[] { TargetDirectory.TeamUrl(tgtId) }, ct).ConfigureAwait(false);
                if (_dir.Exists(TargetDirectory.TeamUrl(tgtId)) == true) { r.Id = tgtId; r.Exists = true; }
            }
            else
            {
                if (scenario == ImportScenario.SameTenantRestore && c.TeamId != null)
                {
                    await _dir.PrefetchExistsAsync(new[] { TargetDirectory.TeamUrl(c.TeamId) }, ct).ConfigureAwait(false);
                    if (_dir.Exists(TargetDirectory.TeamUrl(c.TeamId)) == true) { r.Id = c.TeamId; r.Exists = true; }
                }
                if (!r.Exists)
                {
                    var found = await _dir.FindTeamsByNameAsync(r.Name, ct).ConfigureAwait(false);
                    if (found.Count > 0) { r.Id = found[0].Id; r.Exists = true; }
                }
            }
            _teams[cacheKey] = r;
            return r;
        }

        // ------------------------------------------------------------------------------------------------ scenario C

        async Task MapArchiveAsync(IReadOnlyList<ConversationRecord> conversations, Func<string, IEnumerable<string>> authorsOf, Func<string, Tuple<string, string>> ownerOf, TargetMapResult res, CancellationToken ct)
        {
            int cap = _opt.ChannelsPerArchiveTeam;
            if (cap < 1) cap = 1;
            if (cap > 1000) { res.Blockers.Add("ChannelsPerArchiveTeam " + cap + " exceeds the Teams limit of 1000 channels per team (deleted channels included)."); cap = 1000; }

            // archive channel owners (ids): the configured owners and the service account
            var owners = new List<string>();
            foreach (var o in _opt.ArchiveOwners.Where(x => !string.IsNullOrWhiteSpace(x)))
            {
                if (_dir.Online)
                {
                    var u = await _dir.FindUserAsync(o, ct).ConfigureAwait(false);
                    if (u == null) res.Blockers.Add("Archive owner '" + o + "' does not exist in the target tenant.");
                    else owners.Add(u.Id);
                }
                else owners.Add(o);
            }
            if (!string.IsNullOrEmpty(_run.ServiceAccountUserId)) owners.Add(_run.ServiceAccountUserId);
            owners = owners.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            if (owners.Count == 0) res.Blockers.Add("Archive channels need at least one owner: give ArchiveOwners or a service account.");

            // what earlier plans already placed: archive key -> (team, channel name); team -> number of distinct channels
            var placed = new Dictionary<string, Tuple<string, string>>(StringComparer.OrdinalIgnoreCase);
            var teamChannels = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
            if (_existing != null)
                foreach (var m in _existing.List(TargetKind.ArchiveChannel))
                {
                    if (string.IsNullOrEmpty(m.CreateTeamName) || string.IsNullOrEmpty(m.CreateTopic)) continue;
                    HashSet<string> set; if (!teamChannels.TryGetValue(m.CreateTeamName, out set)) teamChannels[m.CreateTeamName] = set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    set.Add(m.CreateTopic);
                    string note = m.Note ?? ""; int p = note.IndexOf("archive:", StringComparison.Ordinal);
                    if (p >= 0) { int e = note.IndexOf(';', p); string k = note.Substring(p + 8, (e < 0 ? note.Length : e) - p - 8).Trim(); if (k.Length > 0) placed[k] = Tuple.Create(m.CreateTeamName, m.CreateTopic); }
                }

            // group the conversations by archive key (the departed user; a team channel archives on its own)
            var groups = new SortedDictionary<string, Tuple<string, List<ConversationRecord>>>(StringComparer.OrdinalIgnoreCase);
            foreach (var c in conversations)
            {
                var o = ownerOf == null ? null : ownerOf(c.Key);
                string key = o != null ? o.Item1 : c.Key;
                string label = o != null ? (o.Item2 ?? o.Item1) : ((c.TeamDisplayName != null ? c.TeamDisplayName + " - " : "") + (c.Topic ?? c.Key));
                Tuple<string, List<ConversationRecord>> g;
                if (!groups.TryGetValue(key, out g)) groups[key] = g = Tuple.Create(label, new List<ConversationRecord>());
                g.Item2.Add(c);
            }

            // channel names, unique per archive key
            var usedNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);   // name -> archive key
            foreach (var kv in placed) usedNames[kv.Value.Item2] = kv.Key;
            var plan = new Dictionary<string, Tuple<string, string>>(StringComparer.OrdinalIgnoreCase);   // archive key -> (team, channel)
            var existingTeams = new Dictionary<string, TeamRes>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in groups)
            {
                Tuple<string, string> already;
                if (placed.TryGetValue(kv.Key, out already)) { plan[kv.Key] = already; continue; }
                string name = SanitizeChannelName(kv.Value.Item1), owner;
                if (usedNames.TryGetValue(name, out owner) && !string.Equals(owner, kv.Key, StringComparison.OrdinalIgnoreCase))
                {
                    string suffix = " (" + new string(kv.Key.Where(char.IsLetterOrDigit).Take(6).ToArray()) + ")";
                    name = SanitizeChannelName(name.Length + suffix.Length > 50 ? name.Substring(0, 50 - suffix.Length) : name) + suffix;
                }
                usedNames[name] = kv.Key;
                // the first team with room
                int no = 1; string team = null;
                for (; ; no++)
                {
                    team = _opt.ArchiveTeamPrefix + " " + no.ToString("00", CultureInfo.InvariantCulture);
                    HashSet<string> set; if (!teamChannels.TryGetValue(team, out set)) teamChannels[team] = set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    if (!existingTeams.ContainsKey(team))
                    {
                        // channels already in the tenant's archive team count against its capacity
                        var tr = new TeamRes { Name = team };
                        if (_dir.Online)
                        {
                            var found = await _dir.FindTeamsByNameAsync(team, ct).ConfigureAwait(false);
                            if (found.Count > 0)
                            {
                                tr.Id = found[0].Id; tr.Exists = true;
                                foreach (var ch in await _dir.ListChannelsAsync(tr.Id, ct).ConfigureAwait(false)) if (!string.Equals(ch.DisplayName, "General", StringComparison.OrdinalIgnoreCase)) set.Add(ch.DisplayName);
                            }
                        }
                        existingTeams[team] = tr;
                    }
                    if (set.Count < cap) { set.Add(name); break; }
                }
                plan[kv.Key] = Tuple.Create(team, name);
            }

            foreach (var kv in groups)
            {
                var where = plan[kv.Key];
                TeamRes tr; existingTeams.TryGetValue(where.Item1, out tr);
                foreach (var c in kv.Value.Item2)
                {
                    var t = new TargetMapping
                    {
                        SourceConversationKey = c.Key, Kind = TargetKind.ArchiveChannel, CreateTeamName = where.Item1, CreateTopic = where.Item2, CreateMembershipType = "private",
                        TargetTeamId = tr != null && tr.Exists ? tr.Id : null, TargetMemberIds = owners.ToList(),
                        Note = "archive:" + kv.Key + "; " + kv.Value.Item1
                    };
                    if (c.Kind == ConversationKind.Meeting) { res.MeetingChats++; t.Note += "; meeting chat archived as plain messages"; }
                    res.Targets.Add(t);
                }
            }
            foreach (var kv in teamChannels) if (kv.Value.Count > 0 && plan.Values.Any(p => string.Equals(p.Item1, kv.Key, StringComparison.OrdinalIgnoreCase))) res.ArchiveTeams[kv.Key] = kv.Value.Count;
            foreach (var kv in existingTeams) if (!kv.Value.Exists && res.ArchiveTeams.ContainsKey(kv.Key)) res.TeamsToCreate[kv.Key] = res.ArchiveTeams[kv.Key];
        }

        static string Join(string a, string b) { return string.IsNullOrEmpty(a) ? b : (string.IsNullOrEmpty(b) ? a : a + "; " + b); }
    }

    #endregion
}
