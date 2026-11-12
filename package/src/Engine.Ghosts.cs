// =============================================================================
//  TeamsTransfer - engine: ghost accounts
// -----------------------------------------------------------------------------
//  A DELETED user cannot be the author of an imported message (400 "could not be found in the tenant"); a DISABLED user can.
//  So every source author that no longer exists gets, in the TARGET tenant, one disabled, unlicensed "ghost" account:
//    accountEnabled=false, no licence, a random password that is generated here, sent once and never stored, logged or returned;
//    displayName per ImportRunOptions.GhostDisplayNameFormat ("First Last (former)"); UPN tt-ghost-<16 hex of SHA-256(source id)>@<domain>;
//    employeeType = "TeamsTransferGhost"; member of the tracking group "TeamsTransfer - Ghost accounts".
//  One ghost per source person for the whole project: the UPN is a pure function of the source user id, so creation is idempotent:
//    look the UPN up first (GET /users/{upn}, 20 per $batch), create only when absent (POST /users), then record the GhostRecord in the
//    catalog and IdentityMapping.TargetUserId. A crash between the POST and the record is healed by the next run (the UPN is found).
//
//  Decisions (all visible in GhostResult):
//    - dry run (ImportRunOptions.Apply = false): reads only (users/groups lookups), NOTHING is written, the exact list is in Items.
//    - threshold: more than ImportRunOptions.GhostConfirmThreshold ghosts to create and ConfirmGhostCount not set -> blocker, nothing is created.
//    - tracking group missing: created only when GhostOptions.CreateTrackingGroup is set, otherwise a blocker.
//    - creation refused (403): the identity falls back to the service account (Kind = ServiceAccount, TargetUserId = ServiceAccountUserId)
//      with a clear message; if no service account is configured the identity is reported Failed. The fallback is final for that run: set the
//      identities back to Ghost (re-plan) to retry once the permission is granted.
//    - a user found under the ghost UPN whose employeeType is not the marker is NEVER adopted (Failed, "not a ghost").
//    - a ghost found enabled (accountEnabled = true) is "reactivated": reported, recorded as GhostState.Reactivated, and still mapped.
//      The application never enables, never licenses and never changes the password of an existing account.
//    - Remove (lab cleanup): only ghosts recorded in the catalog, re-read and double-checked (employeeType marker AND UPN prefix) before DELETE.
//
//  Graph permissions (application): User.ReadWrite.All (create/read/delete users); Group.ReadWrite.All (create the tracking group and add
//  members; GroupMember.ReadWrite.All + Group.Read.All when the group already exists); User.DeleteRestore.All only for -Purge.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    public sealed class GhostOptions
    {
        public string TrackingGroupName { get; set; } = "TeamsTransfer - Ghost accounts";
        /// <summary>The application may create the tracking group when it is missing. Otherwise a missing group is a blocker.</summary>
        public bool CreateTrackingGroup { get; set; }
        /// <summary>ISO 3166-1 alpha-2 usageLocation to set on the ghost (from the configuration); null = not sent.</summary>
        public string UsageLocation { get; set; }
        public int Parallelism { get; set; } = 4;
        /// <summary>Read the catalog ghosts back (accountEnabled) at the start of a run to report the reactivated ones.</summary>
        public bool CheckReactivated { get; set; } = true;
        /// <summary>Graph root used in "@odata.id" of a group member reference (national clouds differ).</summary>
        public string GraphRoot { get; set; } = "https://graph.microsoft.com";
        public int GroupAddAttempts { get; set; } = 4;
        public TimeSpan GroupRetryDelay { get; set; } = TimeSpan.FromSeconds(3);
        /// <summary>Remove: also purge the deleted ghost from the recycle bin (needs User.DeleteRestore.All).</summary>
        public bool PurgeDeleted { get; set; }
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
        /// <summary>Test seam for the waits between group-membership attempts (replication delay after the creation).</summary>
        public Func<TimeSpan, CancellationToken, Task> Delay { get; set; }
    }

    public enum GhostAction { Create, LinkExisting, LinkCatalog, FallbackServiceAccount, Reactivated, Created, Failed, Remove, Removed, Refused }

    public sealed class GhostPlanItem
    {
        public string SourceUserId { get; set; }
        public string SourceDisplayName { get; set; }
        public string DisplayName { get; set; }
        public string UserPrincipalName { get; set; }
        public string GhostId { get; set; }
        public GhostAction Action { get; set; }
        public string Detail { get; set; }
    }

    public sealed class GhostResult
    {
        public bool DryRun { get; set; }
        /// <summary>Identities of Kind Ghost without a target id at the start of the run.</summary>
        public int Candidates { get; set; }
        /// <summary>Accounts that are (dry run) or were (apply) not found in the target and had to be created.</summary>
        public int ToCreate { get; set; }
        public int Created { get; set; }
        /// <summary>Found in the target under the ghost UPN (a previous run was interrupted) or in the catalog: no creation.</summary>
        public int LinkedExisting { get; set; }
        public int FallbackToServiceAccount { get; set; }
        public int Reactivated { get; set; }
        public int Failed { get; set; }
        public int GroupMembershipFailed { get; set; }
        public int Removed { get; set; }
        public int Refused { get; set; }
        public string TrackingGroupId { get; set; }
        public bool TrackingGroupExists { get; set; }
        public bool TrackingGroupCreated { get; set; }
        public bool Stopped { get; set; }
        public TimeSpan Duration { get; set; }
        public List<string> Blockers { get; } = new List<string>();
        public List<string> Warnings { get; } = new List<string>();
        public List<GhostPlanItem> Items { get; } = new List<GhostPlanItem>();
        /// <summary>Catalog ghosts found accountEnabled = true (never expected: a ghost cannot sign in).</summary>
        public List<GhostPlanItem> ReactivatedGhosts { get; } = new List<GhostPlanItem>();
        public List<ErrorRecord> Errors { get; } = new List<ErrorRecord>();
        public bool IsBlocked { get { return Blockers.Count > 0; } }
    }

    public sealed class GhostProvisioner
    {
        public const string EmployeeTypeMarker = "TeamsTransferGhost";
        public const string UpnPrefix = "tt-ghost-";

        private readonly GraphClient _g;
        private readonly TmtStore _store;
        private readonly IIdentityMap _map;
        private readonly ImportRunOptions _run;
        private readonly GhostOptions _o;
        private readonly Func<DateTimeOffset> _now;
        private ProgressReporter _p;
        private volatile bool _creationForbidden;
        private string _forbiddenMessage;

        public GhostProvisioner(GraphClient target, TmtStore store, IIdentityMap map, ImportRunOptions run, GhostOptions options = null)
        {
            if (target == null) throw new ArgumentNullException("target");
            if (store == null) throw new ArgumentNullException("store");
            if (map == null) throw new ArgumentNullException("map");
            _g = target; _store = store; _map = map; _run = run ?? new ImportRunOptions(); _o = options ?? new GhostOptions();
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _p = new ProgressReporter("Ghosts", _o.OnProgress, _now);
        }

        public ProgressSnapshot Progress { get { return _p.Snapshot(); } }

        // ------------------------------------------------------------------ pure helpers (public: the plan and the tests use them)

        /// <summary>First 16 hex characters of SHA-256 over the lower-cased, trimmed source user id: the "short hash" of the UPN.</summary>
        public static string ShortHash(string sourceUserId)
        {
            using (var sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(Encoding.UTF8.GetBytes((sourceUserId ?? "").Trim().ToLowerInvariant()));
                var sb = new StringBuilder(16);
                for (int i = 0; i < 8; i++) sb.Append(h[i].ToString("x2", CultureInfo.InvariantCulture));
                return sb.ToString();
            }
        }

        public static string MailNicknameFor(string sourceUserId) { return UpnPrefix + ShortHash(sourceUserId); }

        /// <summary>tt-ghost-&lt;short hash&gt;@domain: a pure function of the source id, so the same person always gets the same name.</summary>
        public static string UpnFor(string sourceUserId, string domain)
        {
            return MailNicknameFor(sourceUserId) + "@" + (domain ?? "").Trim().TrimStart('@');
        }

        public static string DisplayNameFor(string format, string sourceDisplayName)
        {
            string name = string.IsNullOrWhiteSpace(sourceDisplayName) ? "Unknown user" : sourceDisplayName.Trim();
            string f = string.IsNullOrWhiteSpace(format) ? "{0} (former)" : format;
            string s;
            try { s = string.Format(CultureInfo.InvariantCulture, f, name); } catch (FormatException) { s = name + " (former)"; }
            return s.Length > 256 ? s.Substring(0, 256) : s;
        }

        /// <summary>40 characters from a CSPRNG with at least one lower, upper, digit and symbol (tenant password policy). Never logged, never stored.</summary>
        public static string GeneratePassword()
        {
            const string lower = "abcdefghijkmnopqrstuvwxyz", upper = "ABCDEFGHJKLMNPQRSTUVWXYZ", digit = "23456789", symbol = "!#$%&*+-=?@^_";
            string all = lower + upper + digit + symbol;
            var chars = new char[40];
            chars[0] = lower[RandomNumberGenerator.GetInt32(lower.Length)];
            chars[1] = upper[RandomNumberGenerator.GetInt32(upper.Length)];
            chars[2] = digit[RandomNumberGenerator.GetInt32(digit.Length)];
            chars[3] = symbol[RandomNumberGenerator.GetInt32(symbol.Length)];
            for (int i = 4; i < chars.Length; i++) chars[i] = all[RandomNumberGenerator.GetInt32(all.Length)];
            for (int i = chars.Length - 1; i > 0; i--) { int j = RandomNumberGenerator.GetInt32(i + 1); char t = chars[i]; chars[i] = chars[j]; chars[j] = t; }
            return new string(chars);
        }

        // ------------------------------------------------------------------ run (plan / create)

        private sealed class Cand
        {
            public IdentityMapping Map; public string Upn; public string Display;
            public GhostRecord Known; public UserProbe Probe; public GhostPlanItem Item;
        }

        private sealed class UserProbe
        {
            public int Status; public string Id, Upn, DisplayName, EmployeeType, ErrorCode, Error; public bool? Enabled;
            public bool Found { get { return Status >= 200 && Status < 300; } }
        }

        public async Task<GhostResult> RunAsync(CancellationToken ct = default(CancellationToken))
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var res = new GhostResult { DryRun = !_run.Apply };
            _p = new ProgressReporter("Ghosts", _o.OnProgress, _now);
            _p.Phase("ghosts");
            lock (_errorsLock) _errors.Clear();
            try
            {
                if (_o.CheckReactivated) await CheckCatalogGhostsAsync(res, ct).ConfigureAwait(false);

                var cands = new List<Cand>();
                foreach (var m in _map.List(IdentityKind.Ghost))
                {
                    if (m == null || string.IsNullOrEmpty(m.SourceUserId) || !string.IsNullOrEmpty(m.TargetUserId)) continue;
                    cands.Add(new Cand { Map = m });
                }
                res.Candidates = cands.Count;
                _p.Phase("ghosts", cands.Count);
                if (cands.Count == 0) return res;

                string domain = _run.GhostDomain;
                if (string.IsNullOrWhiteSpace(domain))
                {
                    res.Blockers.Add("ImportRunOptions.GhostDomain is empty: set the verified domain (or the onmicrosoft.com domain) of the target tenant for the ghost UPNs (tt-ghost-<hash>@<domain>).");
                    return res;
                }
                foreach (var c in cands)
                {
                    c.Upn = UpnFor(c.Map.SourceUserId, domain);
                    c.Display = DisplayNameFor(_run.GhostDisplayNameFormat, c.Map.SourceDisplayName);
                    c.Known = _store.GetGhost(c.Map.SourceUserId);
                }

                // 1. what the catalog already knows (no network), 2. look the rest up in the target
                var lookup = new List<Cand>();
                foreach (var c in cands)
                {
                    if (c.Known != null && !string.IsNullOrEmpty(c.Known.GhostId) && (c.Known.State == GhostState.Created || c.Known.State == GhostState.Reactivated))
                    {
                        c.Item = new GhostPlanItem { SourceUserId = c.Map.SourceUserId, SourceDisplayName = c.Map.SourceDisplayName, DisplayName = c.Known.DisplayName ?? c.Display, UserPrincipalName = c.Known.UserPrincipalName ?? c.Upn, GhostId = c.Known.GhostId, Action = GhostAction.LinkCatalog, Detail = "already recorded in the catalog (" + c.Known.State + "): the mapping is completed, nothing is created" };
                    }
                    else if (c.Known != null && c.Known.State == GhostState.Deleted && !string.IsNullOrEmpty(c.Known.GhostId))
                    {
                        c.Item = new GhostPlanItem { SourceUserId = c.Map.SourceUserId, SourceDisplayName = c.Map.SourceDisplayName, DisplayName = c.Display, UserPrincipalName = c.Upn, Action = GhostAction.Refused, Detail = "the catalog records this ghost as Deleted (" + c.Known.GhostId + "): the catalog refuses a second ghost id for the same source user" };
                    }
                    else lookup.Add(c);
                }
                if (lookup.Count > 0)
                {
                    var probes = await ProbeAsync(lookup.Select(c => c.Upn).ToList(), ct).ConfigureAwait(false);
                    foreach (var c in lookup)
                    {
                        UserProbe pr;
                        if (!probes.TryGetValue(c.Upn, out pr)) pr = new UserProbe { Status = 0, ErrorCode = "NoAnswer" };
                        c.Probe = pr;
                        var it = new GhostPlanItem { SourceUserId = c.Map.SourceUserId, SourceDisplayName = c.Map.SourceDisplayName, DisplayName = c.Display, UserPrincipalName = c.Upn };
                        c.Item = it;
                        if (pr.Status == 404) { it.Action = GhostAction.Create; it.Detail = "not found in the target: would be created (disabled, unlicensed)"; }
                        else if (pr.Found)
                        {
                            it.GhostId = pr.Id;
                            if (!string.Equals(pr.EmployeeType, EmployeeTypeMarker, StringComparison.Ordinal))
                            { it.Action = GhostAction.Refused; it.Detail = "a user with this UPN exists and its employeeType is '" + (pr.EmployeeType ?? "") + "', not '" + EmployeeTypeMarker + "': it is not adopted"; }
                            else if (pr.Enabled == true) { it.Action = GhostAction.Reactivated; it.Detail = "REACTIVATED: the ghost is enabled in the target (accountEnabled = true); it is mapped but must be disabled again"; }
                            else { it.Action = GhostAction.LinkExisting; it.Detail = "already in the target (an earlier run was interrupted): linked, nothing is created"; }
                        }
                        else { it.Action = GhostAction.Failed; it.Detail = "lookup failed: " + pr.Status + " " + pr.ErrorCode + " " + pr.Error; }
                    }
                }
                foreach (var c in cands) res.Items.Add(c.Item);
                res.ToCreate = cands.Count(c => c.Item.Action == GhostAction.Create);

                // blockers (nothing is written while one stands)
                if (res.ToCreate > _run.GhostConfirmThreshold && !_run.ConfirmGhostCount)
                    res.Blockers.Add(res.ToCreate.ToString("N0", CultureInfo.InvariantCulture) + " ghost accounts would be created, above the threshold of " + _run.GhostConfirmThreshold.ToString("N0", CultureInfo.InvariantCulture) +
                        ": review the list (ghosts.csv), then confirm the number explicitly (-ConfirmGhostCount).");
                bool needGroup = cands.Any(c => c.Item.Action == GhostAction.Create || c.Item.Action == GhostAction.LinkExisting);
                if (needGroup) await ResolveTrackingGroupAsync(res, ct).ConfigureAwait(false);
                if (needGroup && !res.TrackingGroupExists && !(_o.CreateTrackingGroup))
                    res.Blockers.Add("The tracking group '" + _o.TrackingGroupName + "' does not exist in the target tenant: create it, or allow the tool to create it (-CreateTrackingGroup).");
                if (res.Blockers.Count > 0) return res;
                if (needGroup && !res.TrackingGroupExists) res.Warnings.Add("The tracking group '" + _o.TrackingGroupName + "' does not exist yet: " + (res.DryRun ? "it would be created." : "it is created first."));
                foreach (var c in cands.Where(c => c.Item.Action == GhostAction.Refused)) { res.Refused++; }
                foreach (var c in cands.Where(c => c.Item.Action == GhostAction.Failed)) { res.Failed++; res.Errors.Add(new ErrorRecord { Scope = c.Map.SourceUserId, Operation = "ghost.lookup", Message = c.Item.Detail, When = _now() }); }
                foreach (var c in cands.Where(c => c.Item.Action == GhostAction.Reactivated)) { res.Reactivated++; res.ReactivatedGhosts.Add(c.Item); }
                if (res.DryRun) { res.LinkedExisting = cands.Count(c => c.Item.Action == GhostAction.LinkExisting || c.Item.Action == GhostAction.LinkCatalog); return res; }

                // ---- apply
                if (needGroup && !res.TrackingGroupExists) await CreateTrackingGroupAsync(res, ct).ConfigureAwait(false);
                var work = cands.Where(c => c.Item.Action == GhostAction.Create || c.Item.Action == GhostAction.LinkExisting || c.Item.Action == GhostAction.LinkCatalog || c.Item.Action == GhostAction.Reactivated).ToList();
                var groupFailed = new ConcurrentBag<string>();
                int created = 0, linked = 0, fallback = 0, failed = 0;
                await Par.ForEachAsync(work, Math.Max(1, _o.Parallelism), async (c, token) =>
                {
                    try
                    {
                        switch (c.Item.Action)
                        {
                            case GhostAction.LinkCatalog:
                                Map(c, c.Item.GhostId, c.Item.UserPrincipalName, GhostState.Created, null);
                                Interlocked.Increment(ref linked);
                                break;
                            case GhostAction.LinkExisting:
                            case GhostAction.Reactivated:
                                {
                                    bool ok = await EnsureGroupMemberAsync(res.TrackingGroupId, c.Item.GhostId, token).ConfigureAwait(false);
                                    if (!ok) groupFailed.Add(c.Map.SourceUserId);
                                    Map(c, c.Item.GhostId, c.Upn, c.Item.Action == GhostAction.Reactivated ? GhostState.Reactivated : GhostState.Created, null);
                                    if (c.Item.Action == GhostAction.LinkExisting) Interlocked.Increment(ref linked);
                                    break;
                                }
                            case GhostAction.Create:
                                {
                                    var outcome = await CreateOneAsync(c, res.TrackingGroupId, groupFailed, token).ConfigureAwait(false);
                                    if (outcome == GhostAction.Created) Interlocked.Increment(ref created);
                                    else if (outcome == GhostAction.FallbackServiceAccount) Interlocked.Increment(ref fallback);
                                    else if (outcome == GhostAction.Failed) Interlocked.Increment(ref failed);
                                    else if (outcome == GhostAction.LinkExisting) Interlocked.Increment(ref linked);
                                    break;
                                }
                        }
                    }
                    catch (Exception ex) when (!ExportUtil.IsCancel(ex, token))
                    {
                        Interlocked.Increment(ref failed);
                        c.Item.Action = GhostAction.Failed; c.Item.Detail = Short(ex.Message);
                        lock (res.Errors) res.Errors.Add(ErrorRecord.From(c.Map.SourceUserId, "ghost", ex, _now()));
                        Interlocked.Increment(ref _p.Errors);
                    }
                    Interlocked.Increment(ref _p.UnitsDone);
                    _p.Tick();
                }, ct, _run.Stop).ConfigureAwait(false);
                res.Created = created; res.LinkedExisting += linked; res.FallbackToServiceAccount = fallback; res.Failed += failed;
                res.GroupMembershipFailed = groupFailed.Count;
                if (res.GroupMembershipFailed > 0) res.Warnings.Add(res.GroupMembershipFailed + " ghost(s) could not be added to the tracking group; run the stage again to complete them.");
                if (_creationForbidden) res.Warnings.Add(_forbiddenMessage);
                res.Stopped = StopControl.Stopped(_run.Stop);
                res.Errors.AddRange(Errors);
                return res;
            }
            finally { res.Duration = sw.Elapsed; _p.Finish(); }
        }

        private string Short(string s) { return s != null && s.Length > 400 ? s.Substring(0, 400) : s; }

        /// <summary>Records the ghost in the catalog first (so a crash never loses an account), then completes the mapping.</summary>
        private void Map(Cand c, string ghostId, string upn, GhostState state, string error)
        {
            _store.UpsertGhost(new GhostRecord { SourceUserId = c.Map.SourceUserId, GhostId = ghostId, DisplayName = c.Display, UserPrincipalName = upn, State = state, Error = error });
            var cur = _map.Get(c.Map.SourceUserId) ?? c.Map;
            cur.Kind = IdentityKind.Ghost; cur.TargetUserId = ghostId; cur.TargetDisplayName = c.Display; cur.Rule = "ghost";
            cur.Note = state == GhostState.Reactivated ? "ghost account is ENABLED: disable it again" : null;
            _map.Upsert(cur);
        }

        private async Task<GhostAction> CreateOneAsync(Cand c, string groupId, ConcurrentBag<string> groupFailed, CancellationToken ct)
        {
            if (_creationForbidden) return Fallback(c, _forbiddenMessage);
            string password = GeneratePassword();
            try
            {
                string id;
                try
                {
                    using (var doc = await _g.PostJsonAsync("v1.0/users", BuildCreateBody(c, password), EndpointClass.Users, c.Map.SourceUserId, ct).ConfigureAwait(false))
                        id = ExportUtil.Str(doc.RootElement, "id");
                }
                catch (GraphException ex) when (ex.StatusCode == 400 && IsConflict(ex))
                {
                    // a retried POST that Graph had already executed, or a concurrent run: the account exists under the ghost UPN
                    var pr = (await ProbeAsync(new List<string> { c.Upn }, ct).ConfigureAwait(false))[c.Upn];
                    if (!pr.Found)
                        throw new InvalidOperationException("The target reports that " + c.Upn + " already exists but cannot read it yet (directory replication delay): run the stage again in a few minutes, the account will then be found and linked.");
                    if (!string.Equals(pr.EmployeeType, EmployeeTypeMarker, StringComparison.Ordinal))
                        throw new InvalidOperationException("The UPN " + c.Upn + " already exists in the target and is not a ghost account (employeeType '" + pr.EmployeeType + "'): it is not adopted.");
                    id = pr.Id;
                }
                if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("The target did not return the id of the created ghost account.");
                bool ok = await EnsureGroupMemberAsync(groupId, id, ct).ConfigureAwait(false);
                if (!ok) groupFailed.Add(c.Map.SourceUserId);
                Map(c, id, c.Upn, GhostState.Created, null);
                c.Item.Action = GhostAction.Created; c.Item.GhostId = id; c.Item.Detail = "created (disabled, unlicensed)" + (ok ? "" : "; tracking group membership pending");
                return GhostAction.Created;
            }
            catch (GraphException ex) when (ex.StatusCode == 403)
            {
                _forbiddenMessage = "Ghost creation was refused by the target tenant (403 " + ex.ErrorCode + "): the application needs User.ReadWrite.All with administrator consent. The authors fall back to the service account.";
                _creationForbidden = true;
                return Fallback(c, _forbiddenMessage);
            }
            catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct))
            {
                string msg = Scrub(ex.Message, password);
                try { _store.UpsertGhost(new GhostRecord { SourceUserId = c.Map.SourceUserId, DisplayName = c.Display, UserPrincipalName = c.Upn, State = GhostState.Failed, Error = Short(msg) }); } catch (InvalidOperationException) { }
                c.Item.Action = GhostAction.Failed; c.Item.Detail = Short(msg);
                lock (_errorsLock) { _errors.Add(new ErrorRecord { Scope = c.Map.SourceUserId, Operation = "ghost.create", StatusCode = (ex as GraphException)?.StatusCode ?? 0, ErrorCode = (ex as GraphException)?.ErrorCode ?? ex.GetType().Name, Message = Short(msg), When = _now() }); }
                Interlocked.Increment(ref _p.Errors);
                return GhostAction.Failed;
            }
            finally { password = null; }
        }

        private readonly object _errorsLock = new object();
        private readonly List<ErrorRecord> _errors = new List<ErrorRecord>();
        public IReadOnlyList<ErrorRecord> Errors { get { lock (_errorsLock) return _errors.ToArray(); } }

        private static string Scrub(string message, string secret)
        {
            if (string.IsNullOrEmpty(message) || string.IsNullOrEmpty(secret)) return message;
            return message.Replace(secret, "***");
        }

        private static bool IsConflict(GraphException ex)
        {
            string m = (ex.ErrorCode ?? "") + " " + (ex.Message ?? "");
            return m.IndexOf("already exists", StringComparison.OrdinalIgnoreCase) >= 0 || m.IndexOf("ObjectConflict", StringComparison.OrdinalIgnoreCase) >= 0 || m.IndexOf("same value for property userPrincipalName", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private GhostAction Fallback(Cand c, string why)
        {
            if (string.IsNullOrEmpty(_run.ServiceAccountUserId))
            {
                c.Item.Action = GhostAction.Failed; c.Item.Detail = why + " No service account is configured (ServiceAccountUserId): the identity stays unresolved.";
                lock (_errorsLock) _errors.Add(new ErrorRecord { Scope = c.Map.SourceUserId, Operation = "ghost.create", StatusCode = 403, ErrorCode = "Forbidden", Message = c.Item.Detail, When = _now() });
                Interlocked.Increment(ref _p.Errors);
                return GhostAction.Failed;
            }
            try { _store.UpsertGhost(new GhostRecord { SourceUserId = c.Map.SourceUserId, DisplayName = c.Display, UserPrincipalName = c.Upn, State = GhostState.Failed, Error = "creation refused (403): fell back to the service account" }); } catch (InvalidOperationException) { }
            var cur = _map.Get(c.Map.SourceUserId) ?? c.Map;
            cur.Kind = IdentityKind.ServiceAccount; cur.TargetUserId = _run.ServiceAccountUserId; cur.Rule = "service-account";
            cur.Note = "ghost creation refused (403): original author is replaced by the service account";
            _map.Upsert(cur);
            c.Item.Action = GhostAction.FallbackServiceAccount; c.Item.Detail = "creation refused (403): falls back to the service account " + _run.ServiceAccountUserId;
            return GhostAction.FallbackServiceAccount;
        }

        private string BuildCreateBody(Cand c, string password)
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteBoolean("accountEnabled", false);
                    w.WriteString("displayName", c.Display);
                    w.WriteString("mailNickname", MailNicknameFor(c.Map.SourceUserId));
                    w.WriteString("userPrincipalName", c.Upn);
                    w.WriteString("employeeType", EmployeeTypeMarker);
                    if (!string.IsNullOrWhiteSpace(_o.UsageLocation)) w.WriteString("usageLocation", _o.UsageLocation.Trim().ToUpperInvariant());
                    w.WriteStartObject("passwordProfile");
                    w.WriteString("password", password);
                    w.WriteBoolean("forceChangePasswordNextSignIn", false);
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        // ------------------------------------------------------------------ users: batched reads

        private const string UserSelect = "?$select=id,userPrincipalName,displayName,accountEnabled,employeeType";

        /// <summary>GET /users/{idOrUpn}?$select=... for many keys, 20 per $batch call, in parallel. The key is the dictionary key of the result.</summary>
        private async Task<Dictionary<string, UserProbe>> ProbeAsync(IList<string> keys, CancellationToken ct)
        {
            var result = new Dictionary<string, UserProbe>(StringComparer.OrdinalIgnoreCase);
            var chunks = new List<List<string>>();
            for (int i = 0; i < keys.Count; i += GraphClient.MaxBatchSize) chunks.Add(keys.Skip(i).Take(GraphClient.MaxBatchSize).ToList());
            await Par.ForEachAsync(chunks, Math.Max(1, _o.Parallelism), async (chunk, token) =>
            {
                var items = new List<BatchItem>();
                for (int i = 0; i < chunk.Count; i++) items.Add(new BatchItem { Id = i.ToString(CultureInfo.InvariantCulture), Method = "GET", Url = "/users/" + ExportUtil.Seg(chunk[i]) + UserSelect, EndpointClass = EndpointClass.Users });
                var answers = await _g.BatchAsync(items, token).ConfigureAwait(false);
                for (int i = 0; i < chunk.Count; i++)
                {
                    var a = answers[i];
                    var pr = new UserProbe { Status = a.StatusCode, ErrorCode = a.ErrorCode, Error = a.ErrorMessage };
                    if (a.IsSuccess && a.Body != null)
                        using (var d = JsonDocument.Parse(a.Body))
                        {
                            var r = d.RootElement; JsonElement e;
                            pr.Id = ExportUtil.Str(r, "id"); pr.Upn = ExportUtil.Str(r, "userPrincipalName"); pr.DisplayName = ExportUtil.Str(r, "displayName"); pr.EmployeeType = ExportUtil.Str(r, "employeeType");
                            if (r.TryGetProperty("accountEnabled", out e) && (e.ValueKind == JsonValueKind.True || e.ValueKind == JsonValueKind.False)) pr.Enabled = e.GetBoolean();
                        }
                    lock (result) result[chunk[i]] = pr;
                }
            }, ct).ConfigureAwait(false);
            return result;
        }

        /// <summary>Reads the catalog ghosts back: a ghost that is enabled is reported (and recorded Reactivated when applying); a missing one is recorded Deleted.</summary>
        public async Task CheckCatalogGhostsAsync(GhostResult res, CancellationToken ct = default(CancellationToken))
        {
            var recs = _store.ListGhosts().Where(g => (g.State == GhostState.Created || g.State == GhostState.Reactivated) && !string.IsNullOrEmpty(g.GhostId)).ToList();
            if (recs.Count == 0) return;
            var probes = await ProbeAsync(recs.Select(g => g.GhostId).ToList(), ct).ConfigureAwait(false);
            foreach (var g in recs)
            {
                UserProbe pr;
                if (!probes.TryGetValue(g.GhostId, out pr)) continue;
                if (pr.Status == 404)
                {
                    res.Warnings.Add("Ghost " + g.UserPrincipalName + " (" + g.GhostId + ") no longer exists in the target tenant.");
                    if (_run.Apply) _store.SetGhostState(g.SourceUserId, GhostState.Deleted, "not found in the target");
                }
                else if (pr.Found && pr.Enabled == true)
                {
                    res.Reactivated++;
                    res.ReactivatedGhosts.Add(new GhostPlanItem { SourceUserId = g.SourceUserId, DisplayName = g.DisplayName, UserPrincipalName = g.UserPrincipalName, GhostId = g.GhostId, Action = GhostAction.Reactivated, Detail = "REACTIVATED: accountEnabled = true. A ghost must never be able to sign in: disable it again." });
                    if (_run.Apply && g.State != GhostState.Reactivated) _store.SetGhostState(g.SourceUserId, GhostState.Reactivated, "accountEnabled = true in the target");
                }
                else if (pr.Found && pr.Enabled == false && g.State == GhostState.Reactivated && _run.Apply)
                    _store.SetGhostState(g.SourceUserId, GhostState.Created, null);
                else if (pr.Found && !string.Equals(pr.EmployeeType, EmployeeTypeMarker, StringComparison.Ordinal))
                    res.Warnings.Add("Ghost " + g.UserPrincipalName + " no longer carries employeeType '" + EmployeeTypeMarker + "'.");
            }
        }

        // ------------------------------------------------------------------ tracking group

        private static string Quote(string s) { return "'" + (s ?? "").Replace("'", "''") + "'"; }

        private async Task ResolveTrackingGroupAsync(GhostResult res, CancellationToken ct)
        {
            string url = "v1.0/groups?$filter=" + Uri.EscapeDataString("displayName eq " + Quote(_o.TrackingGroupName)) + "&$select=id,displayName";
            var ids = new List<string>();
            await foreach (var g in _g.GetPagedAsync(url, EndpointClass.Other, null, null, null, ct).ConfigureAwait(false))
                if (string.Equals(ExportUtil.Str(g, "displayName"), _o.TrackingGroupName, StringComparison.OrdinalIgnoreCase)) ids.Add(ExportUtil.Str(g, "id"));
            if (ids.Count > 0)
            {
                ids.Sort(StringComparer.Ordinal);
                res.TrackingGroupExists = true; res.TrackingGroupId = ids[0];
                if (ids.Count > 1) res.Warnings.Add(ids.Count + " groups are named '" + _o.TrackingGroupName + "': " + ids[0] + " is used.");
            }
        }

        private async Task CreateTrackingGroupAsync(GhostResult res, CancellationToken ct)
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("displayName", _o.TrackingGroupName);
                    w.WriteString("description", "Ghost accounts created by TeamsTransfer for authors who no longer exist. Disabled, unlicensed; do not enable.");
                    w.WriteBoolean("mailEnabled", false);
                    w.WriteBoolean("securityEnabled", true);
                    w.WriteString("mailNickname", "teamstransfer-ghost-accounts");
                    w.WriteEndObject();
                }
                using (var doc = await _g.PostJsonAsync("v1.0/groups", Encoding.UTF8.GetString(ms.ToArray()), EndpointClass.Other, null, ct).ConfigureAwait(false))
                    res.TrackingGroupId = ExportUtil.Str(doc.RootElement, "id");
            }
            res.TrackingGroupExists = true; res.TrackingGroupCreated = true;
        }

        /// <summary>POST /groups/{id}/members/$ref. "already a member" is success; 404 (replication delay after the creation) is retried.</summary>
        private async Task<bool> EnsureGroupMemberAsync(string groupId, string userId, CancellationToken ct)
        {
            if (string.IsNullOrEmpty(groupId)) return false;
            string body = "{\"@odata.id\":\"" + _o.GraphRoot.TrimEnd('/') + "/v1.0/directoryObjects/" + userId + "\"}";
            for (int attempt = 1; attempt <= Math.Max(1, _o.GroupAddAttempts); attempt++)
            {
                try
                {
                    var req = new GraphRequest { Method = System.Net.Http.HttpMethod.Post, Url = "v1.0/groups/" + groupId + "/members/$ref", BodyJson = body, EndpointClass = EndpointClass.Other };
                    using (var r = await _g.SendAsync(req, ct).ConfigureAwait(false)) { }
                    return true;
                }
                catch (GraphException ex) when (ex.StatusCode == 400 && (ex.Message ?? "").IndexOf("already exist", StringComparison.OrdinalIgnoreCase) >= 0) { return true; }
                catch (GraphException ex) when ((ex.StatusCode == 404 || ex.StatusCode == 400) && attempt < _o.GroupAddAttempts)
                {
                    if (_o.Delay != null) await _o.Delay(_o.GroupRetryDelay, ct).ConfigureAwait(false);
                    else await Task.Delay(_o.GroupRetryDelay, ct).ConfigureAwait(false);
                }
                catch (GraphException) { return false; }
            }
            return false;
        }

        // ------------------------------------------------------------------ remove (lab cleanup)

        /// <summary>
        /// Deletes ghosts recorded in the catalog. Each one is read back first and refused unless employeeType = TeamsTransferGhost AND the UPN starts
        /// with tt-ghost-. Dry run unless ImportRunOptions.Apply. onlySourceUserIds limits the removal to some source users.
        /// </summary>
        public async Task<GhostResult> RemoveAsync(IEnumerable<string> onlySourceUserIds = null, CancellationToken ct = default(CancellationToken))
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var res = new GhostResult { DryRun = !_run.Apply };
            _p = new ProgressReporter("Ghosts", _o.OnProgress, _now);
            try
            {
                var only = onlySourceUserIds == null ? null : new HashSet<string>(onlySourceUserIds, StringComparer.OrdinalIgnoreCase);
                if (only != null && only.Count == 0) only = null;     // an empty list means "all", never "none"
                var recs = _store.ListGhosts().Where(g => !string.IsNullOrEmpty(g.GhostId) && g.State != GhostState.Deleted && (only == null || only.Contains(g.SourceUserId))).ToList();
                res.Candidates = recs.Count;
                _p.Phase("remove ghosts", recs.Count);
                if (recs.Count == 0) return res;
                var probes = await ProbeAsync(recs.Select(g => g.GhostId).ToList(), ct).ConfigureAwait(false);
                var work = new List<KeyValuePair<GhostRecord, UserProbe>>();
                foreach (var g in recs)
                {
                    UserProbe pr = probes[g.GhostId];
                    var it = new GhostPlanItem { SourceUserId = g.SourceUserId, DisplayName = g.DisplayName, UserPrincipalName = g.UserPrincipalName, GhostId = g.GhostId };
                    res.Items.Add(it);
                    if (pr.Status == 404) { it.Action = GhostAction.Removed; it.Detail = "already absent from the target"; if (_run.Apply) { _store.SetGhostState(g.SourceUserId, GhostState.Deleted, "not found in the target"); ClearMapping(g.SourceUserId); } res.Removed++; continue; }
                    if (!pr.Found) { it.Action = GhostAction.Failed; it.Detail = "read failed: " + pr.Status + " " + pr.ErrorCode; res.Failed++; continue; }
                    bool isGhost = string.Equals(pr.EmployeeType, EmployeeTypeMarker, StringComparison.Ordinal) && (pr.Upn ?? "").StartsWith(UpnPrefix, StringComparison.OrdinalIgnoreCase);
                    if (!isGhost) { it.Action = GhostAction.Refused; it.Detail = "NOT removed: employeeType '" + (pr.EmployeeType ?? "") + "' / UPN '" + pr.Upn + "' do not identify a TeamsTransfer ghost"; res.Refused++; continue; }
                    it.Action = GhostAction.Remove; it.Detail = res.DryRun ? "would be deleted" : "deleting";
                    work.Add(new KeyValuePair<GhostRecord, UserProbe>(g, pr));
                }
                if (res.DryRun) return res;
                int removed = 0, failed = 0;
                await Par.ForEachAsync(work, Math.Max(1, _o.Parallelism), async (kv, token) =>
                {
                    var g = kv.Key;
                    var it = res.Items.First(x => x.SourceUserId == g.SourceUserId);
                    try
                    {
                        var del = new GraphRequest { Method = System.Net.Http.HttpMethod.Delete, Url = "v1.0/users/" + ExportUtil.Seg(g.GhostId), EndpointClass = EndpointClass.Users };
                        using (var r = await _g.SendAsync(del, token).ConfigureAwait(false)) { }
                        if (_o.PurgeDeleted)
                        {
                            var purge = new GraphRequest { Method = System.Net.Http.HttpMethod.Delete, Url = "v1.0/directory/deletedItems/" + ExportUtil.Seg(g.GhostId), EndpointClass = EndpointClass.Other };
                            try { using (var r = await _g.SendAsync(purge, token).ConfigureAwait(false)) { } }
                            catch (GraphException pex) when (pex.StatusCode == 404) { }
                        }
                        _store.SetGhostState(g.SourceUserId, GhostState.Deleted, "removed by -Mode Ghosts remove");
                        ClearMapping(g.SourceUserId);
                        it.Action = GhostAction.Removed; it.Detail = "deleted";
                        Interlocked.Increment(ref removed);
                    }
                    catch (GraphException ex)
                    {
                        it.Action = GhostAction.Failed; it.Detail = Short(ex.Message);
                        lock (res.Errors) res.Errors.Add(ErrorRecord.From(g.SourceUserId, "ghost.remove", ex, _now()));
                        Interlocked.Increment(ref failed);
                    }
                    Interlocked.Increment(ref _p.UnitsDone);
                }, ct, _run.Stop).ConfigureAwait(false);
                res.Removed += removed; res.Failed += failed;
                res.Stopped = StopControl.Stopped(_run.Stop);
                return res;
            }
            finally { res.Duration = sw.Elapsed; _p.Finish(); }
        }

        private void ClearMapping(string sourceUserId)
        {
            var m = _map.Get(sourceUserId);
            if (m == null || m.Kind != IdentityKind.Ghost) return;
            m.TargetUserId = null; m.Note = "ghost removed from the target tenant";
            _map.Upsert(m);
        }
    }
}
