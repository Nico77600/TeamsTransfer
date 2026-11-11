// =============================================================================
//  TeamsTransfer tests - ImportRealismTransport (lot I)
//  Wraps FakeGraphTransport (which is NOT edited) and makes it behave like the REAL service where Phase0-Results.md says they differ:
//    - a duplicate createdDateTime answers 409 Conflict (the fake answers 400 BadRequest);
//    - a createdDateTime earlier than the thread creation answers 403 (the fake answers 400);
//    - a completed thread can be reopened by a later startMigration with an earlier date (the fake answers 400);
//    - migrationMode is eventually consistent: after startMigration the next N reads of the thread still hide inProgress;
//      completeMigration answers 400 "not in migration mode" N times before it succeeds (nothing is forwarded to the fake meanwhile);
//    - network trouble on demand: the response of the Nth import POST is lost AFTER the service executed it (the GraphClient retries it
//      and the retry meets the 409), or the whole process is "killed" (a CancellationTokenSource is cancelled) right after the Nth POST.
//  It also records every request with a (virtual or real) timestamp so a test can assert the per-conversation rate.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer.Testing
{
    public sealed class ImportRealismTransport : IGraphTransport
    {
        public sealed class Rec { public DateTimeOffset At; public string Method, Url, ThreadKey; public int Status; }

        private readonly FakeGraphTransport _inner;
        private readonly Func<DateTimeOffset> _now;
        private readonly object _gate = new object();
        private readonly List<Rec> _log = new List<Rec>();
        private readonly Dictionary<string, int> _lag = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private int _completeCalls, _posts;
        private bool _lostOnce;

        public FakeGraphTransport Inner { get { return _inner; } }
        public bool DuplicateAs409 = true, EarlierAs403 = true, ReopenCompleted = true;
        /// <summary>After a startMigration, the next N GETs of that thread do not show migrationMode.</summary>
        public int ModeLagAfterStart;
        /// <summary>The first N completeMigration calls (all threads together) answer 400 "not in migration mode".</summary>
        public int CompleteFailures;
        /// <summary>1-based number of the import POST whose response is lost after the service executed it (0 = never).</summary>
        public int LoseResponseOnPost;
        /// <summary>1-based number of the import POST after which the run is "killed": KillSource is cancelled and the call throws (0 = never).</summary>
        public int KillAfterPost;
        public CancellationTokenSource KillSource;
        /// <summary>Requests this StopControl after the StopAfterPosts-th successful import POST (0 = never).</summary>
        public StopControl StopControlToRequest;
        public int StopAfterPosts;
        /// <summary>Slows every call (a real network latency) by this many milliseconds of real time (0 = none).</summary>
        public int LatencyMs;
        /// <summary>Real service (lab): POST /chats with visibleHistoryStartDateTime on a member answers 400 "'visibleHistoryStartDateTime' cannot be set".</summary>
        public bool RejectHistoryOnChatCreate = true;
        /// <summary>Real service (assumed): the members of a new group chat only see the history from now on until they are removed and re-added with an old date.</summary>
        public bool GroupChatsStartHidden = true;
        /// <summary>The fake has no POST /teams/{id}/members: emulated here (201, or 409 for an existing member).</summary>
        public bool EmulateTeamMembersRoute = true;
        /// <summary>Real service (lab): adding a member to a private channel of a team they do not belong to answers 404.</summary>
        public bool ChannelMemberNeedsTeamMember = true;
        private readonly ConcurrentDictionary<string, int> _cur = new ConcurrentDictionary<string, int>();
        private int _maxConcurrent;
        /// <summary>Largest number of import POSTs of one conversation in flight at the same time.</summary>
        public int MaxConcurrentPosts { get { return Volatile.Read(ref _maxConcurrent); } }

        /// <param name="clock">Time source of the recorded timestamps (a TestManualClock for virtual time); null = the real clock.</param>
        public ImportRealismTransport(FakeGraphTransport inner, IClock clock = null)
        {
            _inner = inner; _now = clock == null ? (Func<DateTimeOffset>)(() => DateTimeOffset.UtcNow) : (() => clock.UtcNow);
        }

        /// <summary>Makes the fake's own rate windows (import limit per thread, quotas) read the same virtual clock as the GraphClient.</summary>
        public void AlignFaultsTo(IClock clock) { _inner.Faults.MonotonicSeconds = () => clock.UtcNow.ToUnixTimeMilliseconds() / 1000.0; }

        public Rec[] Records { get { lock (_gate) return _log.ToArray(); } }
        public int ImportPosts { get { return Volatile.Read(ref _posts); } }
        public Rec[] Writes { get { return Records.Where(r => r.Method != "GET").ToArray(); } }

        /// <summary>Largest number of import POSTs of one thread inside any window of `window` (default 1 s).</summary>
        public int MaxPostsPerWindow(string threadKey = null, TimeSpan? window = null)
        {
            var w = window ?? TimeSpan.FromSeconds(1);
            int best = 0;
            foreach (var g in Records.Where(r => IsImportPost(r.Method, r.Url)).GroupBy(r => threadKey ?? r.ThreadKey))
            {
                var t = g.Select(r => r.At).OrderBy(x => x).ToArray();
                int j = 0;
                for (int i = 0; i < t.Length; i++)
                {
                    while (t[i] - t[j] >= w) j++;
                    best = Math.Max(best, i - j + 1);
                }
            }
            return best;
        }

        public static bool IsImportPost(string method, string url)
        {
            if (method != "POST" || url == null) return false;
            string p = Path(url);
            return p.EndsWith("/messages", StringComparison.OrdinalIgnoreCase) || p.EndsWith("/replies", StringComparison.OrdinalIgnoreCase);
        }

        private static string Path(string url)
        {
            string p = url ?? "";
            int q = p.IndexOf('?'); if (q >= 0) p = p.Substring(0, q);
            int s = p.IndexOf("://", StringComparison.Ordinal);
            if (s > 0) { int sl = p.IndexOf('/', s + 3); p = sl < 0 ? "" : p.Substring(sl); }
            p = p.TrimStart('/');
            if (p.StartsWith("v1.0/", StringComparison.OrdinalIgnoreCase)) p = p.Substring(5);
            return "/" + p.TrimEnd('/');
        }

        private static string Normalize(string p) { try { return Uri.UnescapeDataString(p); } catch (Exception) { return p; } }

        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            string tk = request.ThreadKey;
            bool track = tk != null && IsImportPost((request.Method ?? HttpMethod.Get).Method.ToUpperInvariant(), request.Url);
            if (track)
            {
                int n = _cur.AddOrUpdate(tk, 1, (k, v) => v + 1);
                int seen; do { seen = Volatile.Read(ref _maxConcurrent); } while (n > seen && Interlocked.CompareExchange(ref _maxConcurrent, n, seen) != seen);
            }
            try { return await SendCoreAsync(request, cancellationToken).ConfigureAwait(false); }
            finally { if (track) _cur.AddOrUpdate(tk, 0, (k, v) => v - 1); }
        }

        private static string UserIdOf(string body)
        {
            try
            {
                string bind = (string)JsonNode.Parse(body ?? "{}")["user@odata.bind"];
                var m = Regex.Match(bind ?? "", @"users\('([^']+)'\)");
                return m.Success ? m.Groups[1].Value : null;
            }
            catch (Exception) { return null; }
        }

        private async Task<GraphResponse> SendCoreAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            if (LatencyMs > 0) await Task.Delay(LatencyMs, cancellationToken).ConfigureAwait(false);
            string method = (request.Method ?? HttpMethod.Get).Method.ToUpperInvariant();
            string path = Normalize(Path(request.Url));
            var rec = new Rec { At = _now(), Method = method, Url = request.Url, ThreadKey = request.ThreadKey };
            lock (_gate) _log.Add(rec);
            bool importPost = IsImportPost(method, request.Url) && !path.Contains("hostedContents");
            bool start = method == "POST" && path.EndsWith("/startMigration", StringComparison.OrdinalIgnoreCase);
            bool complete = method == "POST" && path.EndsWith("/completeMigration", StringComparison.OrdinalIgnoreCase);

            if (method == "POST" && path == "/chats")
            {
                if (RejectHistoryOnChatCreate && (request.BodyJson ?? "").Contains("visibleHistoryStartDateTime"))
                { rec.Status = 400; return Error(400, "BadRequest", "'visibleHistoryStartDateTime' cannot be set. (Parameter 'visibleHistoryStartDateTime')"); }
                var created = await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
                rec.Status = created.StatusCode;
                if (!created.IsSuccess || !GroupChatsStartHidden) return created;
                string ctext = await created.ReadAsStringAsync().ConfigureAwait(false);
                created.Dispose();
                try
                {
                    string cid = (string)JsonNode.Parse(ctext)["id"];
                    lock (_inner.Tenant.Gate)
                    {
                        FakeChat chat;
                        if (cid != null && _inner.Tenant.ChatsById.TryGetValue(cid, out chat) && chat.ChatType == FakeChatType.Group)
                            foreach (var mem in chat.Members) mem.VisibleHistoryStartMs = _inner.Tenant.NowMs;
                    }
                }
                catch (Exception) { }
                return Rebuild(created.StatusCode, ctext);
            }
            if (method == "POST" && EmulateTeamMembersRoute && Regex.IsMatch(path, @"^/teams/[^/]+/members$"))
            {
                string tid = path.Split('/')[2], uid = UserIdOf(request.BodyJson);
                lock (_inner.Tenant.Gate)
                {
                    FakeTeam team; FakeUser user = uid == null ? null : _inner.Tenant.FindUser(uid);
                    if (!_inner.Tenant.TeamsById.TryGetValue(tid, out team)) { rec.Status = 404; return Error(404, "NotFound", "Team not found."); }
                    if (user == null) { rec.Status = 404; return Error(404, "Request_ResourceNotFound", "User not found."); }
                    if (team.Members.Any(x => x.UserOrd == user.Ordinal)) { rec.Status = 409; return Error(409, "Conflict", "The user is already a member of the team."); }
                    team.Members.Add(new FakeMember { UserOrd = user.Ordinal, Roles = (request.BodyJson ?? "").Contains("\"owner\"") ? "owner" : "" });
                }
                rec.Status = 201;
                return Rebuild(201, "{\"id\":\"" + Guid.NewGuid() + "\"}");
            }
            if (method == "POST" && ChannelMemberNeedsTeamMember && Regex.IsMatch(path, @"^/teams/[^/]+/channels/[^/]+/members$"))
            {
                string tid = path.Split('/')[2], uid = UserIdOf(request.BodyJson);
                bool member;
                lock (_inner.Tenant.Gate)
                {
                    FakeTeam team; FakeUser user = uid == null ? null : _inner.Tenant.FindUser(uid);
                    member = _inner.Tenant.TeamsById.TryGetValue(tid, out team) && user != null && team.Members.Any(x => x.UserOrd == user.Ordinal);
                }
                if (!member) { rec.Status = 404; return Error(404, "NotFound", "The user is not a member of the team."); }
            }

            // completeMigration: the service has not converged yet
            if (complete)
            {
                int n = Interlocked.Increment(ref _completeCalls);
                if (n <= CompleteFailures)
                {
                    rec.Status = 400;
                    return Error(400, "BadRequest", "The conversation is not in migration mode.");
                }
            }
            // startMigration on a completed thread: the real service reopens it
            if (start && ReopenCompleted) ReopenThread(path);

            // reading the thread while the service has not converged
            string basePath = path;
            if (method == "GET")
            {
                bool hide = false;
                lock (_gate)
                {
                    int left;
                    if (_lag.TryGetValue(basePath, out left) && left > 0) { _lag[basePath] = left - 1; hide = true; }
                }
                var r = await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
                rec.Status = r.StatusCode;
                if (hide && r.IsSuccess) return await HideMode(r).ConfigureAwait(false);
                return r;
            }

            var resp = await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
            rec.Status = resp.StatusCode;
            if (start && resp.IsSuccess && ModeLagAfterStart > 0)
            {
                string b = path.Substring(0, path.Length - "/startMigration".Length);
                lock (_gate) _lag[b] = ModeLagAfterStart;
            }
            if (resp.StatusCode == 400 && (importPost || start))
            {
                string text = await resp.ReadAsStringAsync().ConfigureAwait(false);
                resp.Dispose();
                string msg = Message(text);
                if (DuplicateAs409 && importPost && msg.IndexOf("already exists in the conversation", StringComparison.OrdinalIgnoreCase) >= 0) { rec.Status = 409; return Error(409, "Conflict", "A message with this createdDateTime already exists in the thread."); }
                if (EarlierAs403 && importPost && msg.IndexOf("earlier than the creation", StringComparison.OrdinalIgnoreCase) >= 0) { rec.Status = 403; return Error(403, "Forbidden", "createdDateTime is earlier than the creation of the conversation."); }
                return Rebuild(400, text);
            }
            if (importPost && resp.IsSuccess)
            {
                int n = Interlocked.Increment(ref _posts);
                if (StopAfterPosts > 0 && n == StopAfterPosts && StopControlToRequest != null) StopControlToRequest.Request();
                if (KillAfterPost > 0 && n == KillAfterPost && KillSource != null) { KillSource.Cancel(); resp.Dispose(); throw new OperationCanceledException(KillSource.Token); }
                if (LoseResponseOnPost > 0 && n == LoseResponseOnPost && !_lostOnce)
                {
                    _lostOnce = true; resp.Dispose();
                    throw new HttpRequestException("The response was lost after the service executed the request (simulated).");
                }
            }
            return resp;
        }

        private void ReopenThread(string startPath)
        {
            string b = startPath.Substring(0, startPath.Length - "/startMigration".Length).TrimStart('/');
            var parts = b.Split('/');
            lock (_inner.Tenant.Gate)
            {
                FakeThread th = null;
                if (parts.Length >= 2 && parts[0] == "chats") { FakeChat c; _inner.Tenant.ChatsById.TryGetValue(parts[1], out c); th = c; }
                else if (parts.Length >= 4 && parts[0] == "teams" && parts[2] == "channels")
                {
                    FakeTeam t;
                    if (_inner.Tenant.TeamsById.TryGetValue(parts[1], out t)) th = t.Channels.FirstOrDefault(x => x.Id == parts[3]);
                }
                if (th != null && th.MigrationMode == "completed") th.MigrationMode = null;
            }
        }

        private static string Message(string json)
        {
            try { var n = JsonNode.Parse(json); return (string)n["error"]["message"] ?? ""; } catch (Exception) { return json ?? ""; }
        }

        private static GraphResponse Rebuild(int status, string text)
        {
            return new GraphResponse { StatusCode = status, ContentType = "application/json", Content = new MemoryStream(Encoding.UTF8.GetBytes(text)) };
        }

        private static GraphResponse Error(int status, string code, string message)
        {
            var o = new JsonObject { ["error"] = new JsonObject { ["code"] = code, ["message"] = message } };
            return Rebuild(status, o.ToJsonString());
        }

        private static async Task<GraphResponse> HideMode(GraphResponse r)
        {
            string text = await r.ReadAsStringAsync().ConfigureAwait(false);
            r.Dispose();
            var n = JsonNode.Parse(text) as JsonObject;
            if (n != null) n.Remove("migrationMode");
            return Rebuild(r.StatusCode, n == null ? text : n.ToJsonString());
        }
    }
}
