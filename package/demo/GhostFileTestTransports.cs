// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// Test helpers of lot J (ghosts, file copy, verify): GfGraphTransport wraps the FakeGraphTransport (which is NOT edited) and adds what the fake
// does not know yet:
//   - POST /users, GET /users/{id|upn} with accountEnabled / employeeType, DELETE /users/{id}, DELETE /directory/deletedItems/{id}
//     (a created ghost is also added to the FakeTenant, so its OneDrive and the drive invitations work);
//   - groups: GET /groups?$filter=displayName eq '...', POST /groups, POST /groups/{id}/members/$ref, GET /groups/{id}/members;
//   - $batch of such requests: every item is dispatched on its own (so the request log sees each one), the others go to the fake as stand-alone calls;
//   - switches: 403 on user creation, a replication delay (404) before a new user can join a group, network failure of the upload fragments after N
//     good ones, expired upload sessions, one transient 500 on the first user creations;
//   - a request log (method, path, status), the number of write requests, the passwords it received (so a test can prove they never leak) and the
//     process working set sampled at every upload fragment.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer.Testing
{
    public sealed class GfRequest
    {
        public long Seq; public string Method, Path, Url, Body; public int Status; public bool Anonymous; public long BodyBytes;
    }

    public sealed class GfUser
    {
        public string Id, Upn, DisplayName, EmployeeType, UsageLocation; public bool Enabled, Deleted; public bool Licensed;
    }

    public sealed class GfGroup
    {
        public string Id, DisplayName; public readonly HashSet<string> Members = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    public sealed class GfGraphTransport : IGraphTransport
    {
        private readonly IGraphTransport _inner;
        private readonly FakeTenant _tenant;
        private readonly object _gate = new object();
        private readonly List<GfRequest> _log = new List<GfRequest>();
        private long _seq;
        private readonly ConcurrentDictionary<string, GfUser> _users = new ConcurrentDictionary<string, GfUser>(StringComparer.OrdinalIgnoreCase);   // by id
        private readonly ConcurrentDictionary<string, GfGroup> _groups = new ConcurrentDictionary<string, GfGroup>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, int> _lagLeft = new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentBag<string> _passwords = new ConcurrentBag<string>();

        /// <summary>POST /users answers 403 Authorization_RequestDenied.</summary>
        public bool RefuseUserCreation;
        /// <summary>The first N POST /users answer this status (e.g. 503) before working: GraphClient retries them.</summary>
        public int TransientCreateFailures; public int TransientCreateStatus = 503;
        /// <summary>A freshly created user is "not found" (404) for the first N attempts to add it to a group (directory replication).</summary>
        public int MembershipLag;
        /// <summary>After this many successful upload fragments every further fragment PUT fails with a network error (-1 = never).</summary>
        public int FailFragmentsAfter = -1;
        /// <summary>The status of an upload session (GET on the upload URL) answers 404: the session expired.</summary>
        /// <summary>The next N fragment PUTs fail with a network error, then the network is back.</summary>
        public int FragmentFailuresLeft;
        /// <summary>A path regex that answers 403 Forbidden (a missing application permission), or null.</summary>
        public string DenyPathRegex;
        public bool ExpireSessions;
        public long FragmentAttempts, FragmentsOk, MaxFragmentBytes, MaxWorkingSet, UploadStatusGets, SessionCreates;
        public readonly List<long> FragmentSizes = new List<long>();

        public GfGraphTransport(IGraphTransport inner, FakeTenant tenant) { _inner = inner; _tenant = tenant; }

        // ------------------------------------------------------------------ inspection

        public GfRequest[] Requests { get { lock (_gate) return _log.ToArray(); } }
        public IEnumerable<string> Passwords { get { return _passwords.ToArray(); } }
        public void ClearLog() { lock (_gate) _log.Clear(); }
        /// <summary>Requests that change something: every method but GET.</summary>
        public int WriteCount { get { lock (_gate) return _log.Count(r => r.Method != "GET" && r.Method != "BATCH"); } }
        public int Count(string method, string pathRegex)
        {
            var rx = new Regex(pathRegex, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            lock (_gate) return _log.Count(r => (method == null || r.Method == method) && rx.IsMatch(r.Path));
        }
        public GfUser[] Users { get { return _users.Values.ToArray(); } }
        public GfUser UserByUpn(string upn) { return _users.Values.FirstOrDefault(u => string.Equals(u.Upn, upn, StringComparison.OrdinalIgnoreCase)); }
        public GfUser UserById(string id) { GfUser u; return id != null && _users.TryGetValue(id, out u) ? u : null; }
        public GfGroup[] Groups { get { return _groups.Values.ToArray(); } }

        public GfUser SeedUser(string upn, string displayName, bool enabled, string employeeType, string id = null)
        {
            var u = new GfUser { Id = id ?? NewId(), Upn = upn, DisplayName = displayName, Enabled = enabled, EmployeeType = employeeType };
            _users[u.Id] = u;
            AddToTenant(u);
            return u;
        }

        public GfGroup SeedGroup(string name)
        {
            var g = new GfGroup { Id = NewId(), DisplayName = name };
            _groups[g.Id] = g;
            return g;
        }

        string NewId() { lock (_tenant.Gate) return _tenant.NewGuid(); }

        void AddToTenant(GfUser u)
        {
            lock (_tenant.Gate) { if (_tenant.FindUser(u.Id) == null) _tenant.AddUser(u.Upn, u.DisplayName, false, false, null, u.Id); }
        }

        // ------------------------------------------------------------------ pipeline

        static string PathOf(string url, out bool uploadHost)
        {
            uploadHost = false;
            string rest = url ?? "";
            int scheme = rest.IndexOf("://", StringComparison.Ordinal);
            if (scheme > 0)
            {
                rest = rest.Substring(scheme + 3);
                int slash = rest.IndexOf('/');
                string host = slash < 0 ? rest : rest.Substring(0, slash);
                rest = slash < 0 ? "" : rest.Substring(slash);
                uploadHost = host.StartsWith("upload.", StringComparison.OrdinalIgnoreCase);
            }
            int q = rest.IndexOf('?'); if (q >= 0) rest = rest.Substring(0, q);
            rest = rest.TrimStart('/');
            if (!uploadHost && (rest.StartsWith("v1.0/", StringComparison.OrdinalIgnoreCase) || rest.StartsWith("beta/", StringComparison.OrdinalIgnoreCase))) rest = rest.Substring(rest.IndexOf('/') + 1);
            try { rest = Uri.UnescapeDataString(rest); } catch (UriFormatException) { }
            return rest.TrimEnd('/');
        }

        static string QueryOf(string url)
        {
            int q = (url ?? "").IndexOf('?');
            return q < 0 ? "" : url.Substring(q + 1);
        }

        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken ct)
        {
            bool upload;
            string path = PathOf(request.Url, out upload);
            if (!upload && (path.Equals("$batch", StringComparison.OrdinalIgnoreCase)) && request.Method == HttpMethod.Post) return await BatchAsync(request, ct).ConfigureAwait(false);
            return await HandleAsync(request, path, upload, ct).ConfigureAwait(false);
        }

        static readonly Regex UserRx = new Regex(@"^users/(?<u>[^/]+)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        static readonly Regex DeletedRx = new Regex(@"^directory/deletedItems/(?<u>[^/]+)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        static readonly Regex GroupMemberRefRx = new Regex(@"^groups/(?<g>[^/]+)/members/\$ref$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        static readonly Regex GroupMembersRx = new Regex(@"^groups/(?<g>[^/]+)/members$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        async Task<GraphResponse> HandleAsync(GraphRequest r, string path, bool upload, CancellationToken ct)
        {
            string method = (r.Method ?? HttpMethod.Get).Method.ToUpperInvariant();
            var entry = new GfRequest { Seq = Interlocked.Increment(ref _seq), Method = method, Path = path, Url = r.Url, Body = (r.BodyJson != null && r.BodyJson.Length < 4000 ? r.BodyJson : null), Anonymous = r.Anonymous, BodyBytes = r.BodyBytes != null ? r.BodyBytes.Length : (r.BodyJson != null ? r.BodyJson.Length : 0) };
            lock (_gate) _log.Add(entry);
            GraphResponse resp;
            try { resp = await DispatchAsync(r, method, path, upload, ct).ConfigureAwait(false); }
            catch (Exception) { entry.Status = 0; throw; }
            entry.Status = resp.StatusCode;
            return resp;
        }

        async Task<GraphResponse> DispatchAsync(GraphRequest r, string method, string path, bool upload, CancellationToken ct)
        {
            if (upload)
            {
                if (method == "PUT")
                {
                    Interlocked.Increment(ref FragmentAttempts);
                    long ws = Environment.WorkingSet; if (ws > MaxWorkingSet) MaxWorkingSet = ws;
                    if (Interlocked.Decrement(ref FragmentFailuresLeft) >= 0) throw new HttpRequestException("Injected transient network failure on an upload fragment.");
                    Interlocked.Exchange(ref FragmentFailuresLeft, 0);
                    if (FailFragmentsAfter >= 0 && Interlocked.Read(ref FragmentsOk) >= FailFragmentsAfter) throw new HttpRequestException("Injected network failure on an upload fragment.");
                    var resp = await _inner.SendAsync(r, ct).ConfigureAwait(false);
                    if (resp.IsSuccess)
                    {
                        Interlocked.Increment(ref FragmentsOk);
                        long n = r.BodyBytes != null ? r.BodyBytes.Length : 0;
                        lock (FragmentSizes) FragmentSizes.Add(n);
                        if (n > MaxFragmentBytes) MaxFragmentBytes = n;
                    }
                    return resp;
                }
                if (method == "GET")
                {
                    Interlocked.Increment(ref UploadStatusGets);
                    if (ExpireSessions) return Error(404, "itemNotFound", "The upload session was not found or has expired.");
                }
                return await _inner.SendAsync(r, ct).ConfigureAwait(false);
            }
            if (DenyPathRegex != null && Regex.IsMatch(path, DenyPathRegex, RegexOptions.IgnoreCase)) return Error(403, "Forbidden", "API requires one of 'ChannelMessage.Read.All, ChannelMessage.Read.Group'. Scopes on the request: none.");
            if (method == "POST" && path.EndsWith("createUploadSession", StringComparison.OrdinalIgnoreCase)) Interlocked.Increment(ref SessionCreates);

            Match m;
            if (method == "POST" && path.Equals("users", StringComparison.OrdinalIgnoreCase)) return CreateUser(r);
            if ((m = UserRx.Match(path)).Success)
            {
                string key = m.Groups["u"].Value;
                if (method == "GET")
                {
                    var u = FindUser(key);
                    if (u != null && !u.Deleted) return JsonUser(u);
                    if (key.StartsWith("tt-ghost-", StringComparison.OrdinalIgnoreCase) || (u != null && u.Deleted)) return Error(404, "Request_ResourceNotFound", "Resource '" + key + "' does not exist or one of its queried reference-property objects are not present.");
                }
                else if (method == "DELETE")
                {
                    var u = FindUser(key);
                    if (u == null || u.Deleted) return Error(404, "Request_ResourceNotFound", "Resource '" + key + "' does not exist.");
                    u.Deleted = true;
                    return Empty(204);
                }
            }
            if (method == "DELETE" && (m = DeletedRx.Match(path)).Success)
            {
                var u = FindUser(m.Groups["u"].Value);
                if (u == null) return Error(404, "Request_ResourceNotFound", "Resource does not exist.");
                return Empty(204);
            }
            if (method == "GET" && path.Equals("groups", StringComparison.OrdinalIgnoreCase)) return ListGroups(r);
            if (method == "POST" && path.Equals("groups", StringComparison.OrdinalIgnoreCase))
            {
                using (var doc = JsonDocument.Parse(BodyText(r)))
                {
                    var g = new GfGroup { Id = NewId(), DisplayName = doc.RootElement.GetProperty("displayName").GetString() };
                    _groups[g.Id] = g;
                    return Json(201, w => { w.WriteString("id", g.Id); w.WriteString("displayName", g.DisplayName); });
                }
            }
            if (method == "POST" && (m = GroupMemberRefRx.Match(path)).Success) return AddMember(m.Groups["g"].Value, r);
            if (method == "GET" && (m = GroupMembersRx.Match(path)).Success)
            {
                GfGroup g;
                if (!_groups.TryGetValue(m.Groups["g"].Value, out g)) return Error(404, "Request_ResourceNotFound", "Group not found.");
                return Json(200, w => { w.WriteStartArray("value"); foreach (var id in g.Members) { w.WriteStartObject(); w.WriteString("id", id); w.WriteEndObject(); } w.WriteEndArray(); });
            }
            return await _inner.SendAsync(r, ct).ConfigureAwait(false);
        }

        GfUser FindUser(string key)
        {
            GfUser u;
            if (_users.TryGetValue(key, out u)) return u;
            return _users.Values.FirstOrDefault(x => string.Equals(x.Upn, key, StringComparison.OrdinalIgnoreCase));
        }

        GraphResponse CreateUser(GraphRequest r)
        {
            if (RefuseUserCreation) return Error(403, "Authorization_RequestDenied", "Insufficient privileges to complete the operation.");
            if (Interlocked.Decrement(ref TransientCreateFailures) >= 0) return Error(TransientCreateStatus, "ServiceUnavailable", "The service is temporarily unavailable.");
            Interlocked.Exchange(ref TransientCreateFailures, 0);
            using (var doc = JsonDocument.Parse(BodyText(r)))
            {
                var e = doc.RootElement; JsonElement p;
                string upn = e.GetProperty("userPrincipalName").GetString();
                string pwd = e.TryGetProperty("passwordProfile", out p) && p.TryGetProperty("password", out var pw) ? pw.GetString() : null;
                if (pwd == null || pwd.Length < 8) return Error(400, "Request_BadRequest", "The specified password does not comply with password complexity requirements.");
                _passwords.Add(pwd);
                lock (_gate)
                {
                    if (_users.Values.Any(x => !x.Deleted && string.Equals(x.Upn, upn, StringComparison.OrdinalIgnoreCase)))
                        return Error(400, "Request_BadRequest", "Another object with the same value for property userPrincipalName already exists.");
                    var u = new GfUser
                    {
                        Id = NewId(), Upn = upn, DisplayName = e.GetProperty("displayName").GetString(), Enabled = e.TryGetProperty("accountEnabled", out p) && p.ValueKind == JsonValueKind.True,
                        EmployeeType = e.TryGetProperty("employeeType", out p) ? p.GetString() : null, UsageLocation = e.TryGetProperty("usageLocation", out p) ? p.GetString() : null
                    };
                    _users[u.Id] = u;
                    if (MembershipLag > 0) _lagLeft[u.Id] = MembershipLag;
                    AddToTenant(u);
                    return JsonUserStatus(201, u);
                }
            }
        }

        GraphResponse AddMember(string groupId, GraphRequest r)
        {
            GfGroup g;
            if (!_groups.TryGetValue(groupId, out g)) return Error(404, "Request_ResourceNotFound", "Resource '" + groupId + "' does not exist.");
            using (var doc = JsonDocument.Parse(BodyText(r)))
            {
                string odata = doc.RootElement.GetProperty("@odata.id").GetString();
                string uid = odata.Substring(odata.LastIndexOf('/') + 1);
                var u = UserById(uid);
                if (u == null || u.Deleted) return Error(404, "Request_ResourceNotFound", "Resource '" + uid + "' does not exist.");
                int left;
                if (_lagLeft.TryGetValue(uid, out left) && left > 0) { _lagLeft[uid] = left - 1; return Error(404, "Request_ResourceNotFound", "Resource '" + uid + "' does not exist or one of its queried reference-property objects are not present."); }
                lock (g)
                {
                    if (!g.Members.Add(uid)) return Error(400, "Request_BadRequest", "One or more added object references already exist for the following modified properties: 'members'.");
                }
                return Empty(204);
            }
        }

        GraphResponse ListGroups(GraphRequest r)
        {
            string q = Uri.UnescapeDataString(QueryOf(r.Url).Replace("+", " "));
            var mt = Regex.Match(q, @"displayName eq '(?<n>(?:[^']|'')*)'", RegexOptions.IgnoreCase);
            string name = mt.Success ? mt.Groups["n"].Value.Replace("''", "'") : null;
            var list = _groups.Values.Where(g => name == null || string.Equals(g.DisplayName, name, StringComparison.OrdinalIgnoreCase)).ToList();
            return Json(200, w => { w.WriteStartArray("value"); foreach (var g in list) { w.WriteStartObject(); w.WriteString("id", g.Id); w.WriteString("displayName", g.DisplayName); w.WriteEndObject(); } w.WriteEndArray(); });
        }

        // ------------------------------------------------------------------ $batch

        async Task<GraphResponse> BatchAsync(GraphRequest outer, CancellationToken ct)
        {
            var ms = new MemoryStream();
            using (var doc = JsonDocument.Parse(BodyText(outer)))
            using (var w = new Utf8JsonWriter(ms))
            {
                w.WriteStartObject(); w.WriteStartArray("responses");
                foreach (var item in doc.RootElement.GetProperty("requests").EnumerateArray())
                {
                    string id = item.GetProperty("id").GetString();
                    string url = item.GetProperty("url").GetString();
                    var inner = new GraphRequest { Method = new HttpMethod(item.GetProperty("method").GetString()), Url = "v1.0" + (url.StartsWith("/") ? url : "/" + url) };
                    JsonElement b;
                    if (item.TryGetProperty("body", out b)) inner.BodyJson = b.GetRawText();
                    GraphResponse resp;
                    try { bool up; resp = await HandleAsync(inner, PathOf(inner.Url, out up), up, ct).ConfigureAwait(false); }
                    catch (Exception) { resp = Error(503, "ServiceUnavailable", "The service is temporarily unavailable."); }
                    string text;
                    using (resp) text = resp.Content == null ? "" : await new StreamReader(resp.Content).ReadToEndAsync().ConfigureAwait(false);
                    w.WriteStartObject();
                    w.WriteString("id", id); w.WriteNumber("status", resp.StatusCode);
                    w.WriteStartObject("headers"); w.WriteString("Content-Type", "application/json"); w.WriteEndObject();
                    if (!string.IsNullOrWhiteSpace(text)) { w.WritePropertyName("body"); using (var d = JsonDocument.Parse(text)) d.RootElement.WriteTo(w); }
                    w.WriteEndObject();
                }
                w.WriteEndArray(); w.WriteEndObject();
            }
            ms.Position = 0;
            var res = new GraphResponse { StatusCode = 200, Content = ms, ContentType = "application/json" };
            lock (_gate) _log.Add(new GfRequest { Seq = Interlocked.Increment(ref _seq), Method = "BATCH", Path = "$batch", Url = outer.Url, Status = 200 });
            return res;
        }

        // ------------------------------------------------------------------ responses

        static string BodyText(GraphRequest r)
        {
            if (r.BodyJson != null) return r.BodyJson;
            if (r.BodyBytes != null) return Encoding.UTF8.GetString(r.BodyBytes);
            return "{}";
        }

        static GraphResponse Json(int status, Action<Utf8JsonWriter> body)
        {
            var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms)) { w.WriteStartObject(); body(w); w.WriteEndObject(); }
            ms.Position = 0;
            return new GraphResponse { StatusCode = status, Content = ms, ContentType = "application/json" };
        }

        static GraphResponse Error(int status, string code, string message)
        {
            return Json(status, w => { w.WriteStartObject("error"); w.WriteString("code", code); w.WriteString("message", message); w.WriteEndObject(); });
        }

        static GraphResponse Empty(int status) { return new GraphResponse { StatusCode = status, Content = new MemoryStream(new byte[0]) }; }

        static GraphResponse JsonUser(GfUser u) { return JsonUserStatus(200, u); }

        static GraphResponse JsonUserStatus(int status, GfUser u)
        {
            return Json(status, w =>
            {
                w.WriteString("id", u.Id); w.WriteString("userPrincipalName", u.Upn); w.WriteString("displayName", u.DisplayName);
                w.WriteBoolean("accountEnabled", u.Enabled);
                if (u.EmployeeType == null) w.WriteNull("employeeType"); else w.WriteString("employeeType", u.EmployeeType);
            });
        }
    }

    /// <summary>Collects the events GraphClient emits (the "log" of the engine) as text, to prove a secret never reaches it.</summary>
    public sealed class GfEventLog
    {
        private readonly ConcurrentQueue<string> _q = new ConcurrentQueue<string>();
        public void OnEvent(GraphEvent e) { _q.Enqueue(e.Kind + " " + e.Method + " " + e.EndpointClass + " " + e.StatusCode + " " + e.Url + " " + e.Message); }
        public string Text { get { return string.Join("\n", _q.ToArray()); } }
        public int Count { get { return _q.Count; } }
    }

    /// <summary>A generated stream of a given length (no allocation, deterministic): PutContent reads it in 128 KiB steps.</summary>
    public sealed class GfGenStream : Stream
    {
        readonly long _len; long _pos; ulong _x = 88172645463325252UL;
        public GfGenStream(long length) { _len = length; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return _len; } }
        public override long Position { get { return _pos; } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            long left = _len - _pos; if (left <= 0) return 0;
            int n = (int)Math.Min(count, left);
            for (int i = 0; i < n; i++) { _x ^= _x << 13; _x ^= _x >> 7; _x ^= _x << 17; buffer[offset + i] = (byte)_x; }
            _pos += n;
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }
}
