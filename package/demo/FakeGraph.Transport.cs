// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// =============================================================================
//  TeamsTransfer - fake Microsoft Graph, part 2: FakeGraphTransport (IGraphTransport over a FakeTenant)
// -----------------------------------------------------------------------------
//  WHY: one object that answers like graph.microsoft.com for the endpoints the engine uses (design 3.2 - 3.5), with realistic paging,
//  filters, error shapes, the migration (import) rules and the OneDrive/SharePoint file endpoints, so GraphClient, the export, the
//  file copy, the import, the preview and the demo mode all run against it unchanged. It is "dumb" in the same way as the real
//  transport: no retry, no paging loop, no throttling logic of its own beyond what FakeGraphFaults injects.
//
//  ROUTING: method + path. Absolute (https://graph.microsoft.com/v1.0/...) or relative ("v1.0/...", "beta/...", or with no version =
//  v1.0). Path segments are percent-decoded, matching is case-insensitive. Upload sessions and pre-authenticated download URLs are
//  served on two fake hosts (upload.fake-sharepoint.invalid / download.fake-sharepoint.invalid) and require Anonymous = true on the
//  upload host (the real service refuses an Authorization header there), Anonymous = false on the Graph host.
//
//  ASSUMED BEHAVIOUR (not yet measured on the real service: phase 0 must confirm each one; the tenant / faults options say which can be flipped):
//   A01 getAllMessages needs model=A or model=B. Missing or invalid model = EVALUATION MODE: at most FakeTenant.EvaluationModeMaxMessages (500)
//       messages per query, the data then simply ends (no nextLink), and the response carries   Warning: 199 - "Evaluation mode ..."
//       (counted in Counters.EvaluationModeResponses). The real service may answer 400/402 instead.
//   A02 Page sizes. chat/channel messages, replies and getAllMessages: default 20, max 50, a larger $top is REJECTED with 400.
//       users/chats: default and max 50 (clamped). users, groups, teams, deletedItems, members: default 100, max 999 (clamped). Channels: not paged.
//   A03 Order. Every message listing is lastModifiedDateTime DESC, ties broken by id DESC (deterministic). $orderby accepts
//       "lastModifiedDateTime desc" (default) and "createdDateTime desc"; ascending is rejected with 400. getAllMessages order is not
//       documented by Microsoft; we use the same order. $filter on messages: lastModifiedDateTime / createdDateTime with gt, ge, lt, le joined by "and".
//   A04 Message ids are the createdDateTime in epoch milliseconds, also for imported messages. Unique per chat / per channel (replies included).
//   A05 Listing the teams: GET groups?$filter=resourceProvisioningOptions/Any(x:x eq 'Team') is the primary way (every group here is a team);
//       GET teams also answers unless FakeTenant.TeamsListEndpointEnabled is false. Both return the same page order.
//   A06 Deleted accounts: GET users/{id} -> 404 Request_ResourceNotFound; listed under directory/deletedItems/microsoft.graph.user. Federated
//       (external) users are not in the directory at all (404), but appear as chat members and message authors.
//   A07 POST chats: 201 with the chat; a oneOnOne chat for a pair that already has one returns that chat (also 201). Members that are deleted
//       or federated: 404 Request_ResourceNotFound.
//   A08 startMigration: 204. conversationCreationDateTime must be strictly earlier than the current createdDateTime (else 400), a chat already
//       inProgress or completed answers 400, another application's inProgress thread answers 403. completeMigration: 204, owner app only.
//   A09 Import POST (messages / replies): outside inProgress (mode null or completed) -> 403 Forbidden, with or without createdDateTime;
//       another application than the owner -> 403; missing createdDateTime or from -> 400; createdDateTime in the future (vs
//       FakeTenant.Clock), before the conversation creation, or already used in the thread (ms precision, sub-ms truncated) -> 400 BadRequest;
//       reply not strictly after its root -> 400; federated author -> 400; deleted author -> 400 unless FakeTenant.DeletedAuthorsAccepted;
//       more than 250 reactions -> 400; body above FakeTenant.MaxBodyBytes (28 KB) -> 400; a "../hostedContents/N/$value" reference with no
//       matching @microsoft.graph.temporaryId -> 400. The imported lastModifiedDateTime = createdDateTime unless supplied.
//   A10 Hosted contents of an imported message get new ids and the body src is rewritten to the absolute .../hostedContents/{id}/$value URL.
//   A11 Chat members: POST on a oneOnOne -> 400; an existing member -> 409; DELETE -> 204; visibleHistoryStartDateTime defaults to 0001-01-01 (all history).
//   A12 Drive: /content answers 200 with the bytes directly (the real service answers 302 to a pre-authenticated URL; the downloadUrl is also served).
//       Range requests are honoured (206). createUploadSession conflict default = replace; fragments must be multiples of 320 KiB except the
//       last (else 400 invalidRange), contiguous (else 416), at most 60 MiB. Uploaded bytes are kept up to FakeTenant.MaxRetainedUploadBytes,
//       above that only length and SHA-256 are kept and the download is a generated stream of the same length (flagged by Item.UploadedSha256).
//   A13 invite / createLink answer like OneDrive (value[] of permissions / link); recipients must be known, non-deleted users or an e-mail.
//   A14 $batch: at most 20 requests (else 400), no nesting, each item dispatched through the SAME pipeline (faults, quota, counters) as a
//       stand-alone call, so a 429 can hit one item and not the others; the outer call counts as one "$batch" call.
//   A15 Error shape {"error":{"code","message","innerError":{"request-id","date","client-request-id"}}} + request-id header; unknown route = 400
//       BadRequest "Resource not found for the segment"; unknown entity = 404; wrong verb on a known route = 405.
//   A16 $select is honoured on users only; $expand=members on chats; other query options are ignored.
//   A17 Request-ids and ids of created entities derive from seeds and counters (deterministic); the only non-deterministic values are the
//       service clock (Clock) and the Retry-After HTTP-date form.
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer.Testing
{
    /// <summary>A failure raised inside a handler, turned into a Graph error body by the transport.</summary>
    public sealed class FakeHttpException : Exception
    {
        public int Status; public string Code; public string RetryAfter;
        public FakeHttpException(int status, string code, string message) : base(message) { Status = status; Code = code; }
    }

    public sealed partial class FakeGraphTransport : IGraphTransport
    {
        public const string GraphRoot = "https://graph.microsoft.com";
        public const string UploadHost = "upload.fake-sharepoint.invalid";
        public const string DownloadHost = "download.fake-sharepoint.invalid";
        const string JsonType = "application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false;charset=utf-8";

        public FakeTenant Tenant { get; private set; }
        public FakeGraphFaults Faults { get; private set; }
        public FakeGraphCounters Counters { get; private set; }
        /// <summary>The application id this transport "is". Start/import/complete must come from the same one. A request header X-Fake-AppId overrides it per call.</summary>
        public string CallingAppId;
        readonly int _seed;
        long _reqSeq;

        public FakeGraphTransport(FakeTenant tenant, int faultSeed = 4242, string callingAppId = "11111111-1111-1111-1111-111111111111")
        {
            Tenant = tenant; Faults = new FakeGraphFaults(faultSeed); Counters = new FakeGraphCounters(); CallingAppId = callingAppId; _seed = faultSeed;
        }

        /// <summary>A second "application" talking to the same tenant (own faults and counters).</summary>
        public FakeGraphTransport ForApp(string appId) { return new FakeGraphTransport(Tenant, _seed, appId); }

        // ------------------------------------------------------------------ pipeline

        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            if (request == null) throw new ArgumentNullException("request");
            cancellationToken.ThrowIfCancellationRequested();
            return await ProcessAsync(request, cancellationToken, false).ConfigureAwait(false);
        }

        sealed class Parsed
        {
            public string Host = GraphRoot.Substring(8), Version = "v1.0", Path = "", RawPath = "", RawQuery = "";
            public Dictionary<string, string> Query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }

        static string Dec(string s) { try { return Uri.UnescapeDataString(s.Replace('+', ' ')); } catch { return s; } }

        static Parsed Parse(string url)
        {
            var p = new Parsed();
            string rest = url ?? "";
            int h = rest.IndexOf('#'); if (h >= 0) rest = rest.Substring(0, h);
            int scheme = rest.IndexOf("://", StringComparison.Ordinal);
            if (scheme > 0)
            {
                rest = rest.Substring(scheme + 3);
                int slash = rest.IndexOf('/');
                if (slash < 0) { p.Host = rest; rest = ""; } else { p.Host = rest.Substring(0, slash); rest = rest.Substring(slash); }
            }
            int q = rest.IndexOf('?');
            if (q >= 0) { p.RawQuery = rest.Substring(q + 1); rest = rest.Substring(0, q); }
            rest = rest.TrimStart('/');
            bool graphHost = !p.Host.StartsWith("upload.", StringComparison.OrdinalIgnoreCase) && !p.Host.StartsWith("download.", StringComparison.OrdinalIgnoreCase);
            if (graphHost)
            {
                int s = rest.IndexOf('/'); string first = s < 0 ? rest : rest.Substring(0, s);
                if (first.Equals("v1.0", StringComparison.OrdinalIgnoreCase) || first.Equals("beta", StringComparison.OrdinalIgnoreCase))
                { p.Version = first.ToLowerInvariant(); rest = s < 0 ? "" : rest.Substring(s + 1); }
            }
            p.RawPath = rest.TrimEnd('/');
            p.Path = Dec(rest.Replace("+", "%2B")).TrimEnd('/');
            if (!graphHost) p.Path = (p.Host.StartsWith("upload.", StringComparison.OrdinalIgnoreCase) ? "@upload/" : "@download/") + p.Path;
            foreach (var part in p.RawQuery.Split(new[] { '&' }, StringSplitOptions.RemoveEmptyEntries))
            {
                int eq = part.IndexOf('=');
                string k = Dec(eq < 0 ? part : part.Substring(0, eq)); string v = eq < 0 ? "" : Dec(part.Substring(eq + 1));
                p.Query[k] = v;
            }
            return p;
        }

        sealed class Ctx
        {
            public string AppId; public GraphRequest Req; public Parsed P; public Match M; public CancellationToken Ct; public string RequestId;
            public string G(string n) { return M.Groups[n].Success ? M.Groups[n].Value : null; }
            public string Q(string n) { string v; return P.Query.TryGetValue(n, out v) ? v : null; }
            public string Header(string n) { string v; return Req.Headers.TryGetValue(n, out v) ? v : null; }
        }

        delegate GraphResponse Handler(FakeGraphTransport t, Ctx c);

        sealed class Route
        {
            public string Method; public Regex Rx; public string Class; public Handler H;
        }

        static readonly List<Route> Routes = new List<Route>();

        static void R(string method, string pattern, string cls, Handler h)
        {
            Routes.Add(new Route { Method = method, Class = cls, H = h, Rx = new Regex("^" + pattern + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture) });
        }

        const string Seg = "[^/]+";

        async Task<GraphResponse> ProcessAsync(GraphRequest req, CancellationToken ct, bool inBatch)
        {
            long n = Interlocked.Increment(ref _reqSeq);
            string requestId = new Guid((int)(_seed * 2654435761L), (short)(n >> 16), (short)n, 0, 0, 0, 0, 0, 0, 0, 1).ToString();
            var p = Parse(req.Url);
            string method = (req.Method ?? HttpMethod.Get).Method.ToUpperInvariant();

            Route route = null; Match match = null; bool pathKnown = false;
            foreach (var r in Routes)
            {
                var m = r.Rx.Match(p.Path);
                if (!m.Success) continue;
                pathKnown = true;
                if (r.Method == method) { route = r; match = m; break; }
            }
            string cls = route != null ? route.Class : EndpointClass.Other;
            string threadKey = !string.IsNullOrEmpty(req.ThreadKey) ? req.ThreadKey : ThreadKeyOf(match);
            Counters.Call(cls);
            var log = Counters.Begin(method, req.Url, cls, threadKey);

            var d = Faults.Evaluate(cls, method, req.Url ?? "", threadKey);
            if (d.Latency > TimeSpan.Zero) await Faults.Delay(d.Latency, ct).ConfigureAwait(false);
            if (d.Reset && !inBatch)
            {
                Counters.Incr(ref Counters.ConnectionResets); Counters.Incr(ref Counters.FaultsInjected);
                if (log != null) log.Note = "connection reset";
                throw new HttpRequestException("The fake Graph reset the connection (injected fault).", new IOException("Unable to read data from the transport connection: An existing connection was forcibly closed by the remote host."));
            }
            GraphResponse resp;
            if (d.Status != 0 || d.Reset)
            {
                Counters.Incr(ref Counters.FaultsInjected);
                int st = d.Status != 0 ? d.Status : 503;
                resp = ErrorResponse(st, d.ErrorCode ?? "ServiceUnavailable", "Injected fault (" + d.Reason + ").", requestId, p, d.RetryAfterHeader);
            }
            else
            {
                try
                {
                    string appId = req.Headers.ContainsKey("X-Fake-AppId") ? req.Headers["X-Fake-AppId"] : CallingAppId;
                    bool uploadHost = p.Path.StartsWith("@upload/", StringComparison.Ordinal);
                    bool downloadHost = p.Path.StartsWith("@download/", StringComparison.Ordinal);
                    if (uploadHost && !req.Anonymous) throw new FakeHttpException(401, "InvalidAuthenticationToken", "The upload session URL is pre-authenticated: send the request without an Authorization header (GraphRequest.Anonymous = true).");
                    if (!uploadHost && !downloadHost && req.Anonymous) throw new FakeHttpException(401, "InvalidAuthenticationToken", "Access token is empty.");
                    if (route == null)
                    {
                        if (pathKnown) throw new FakeHttpException(405, "MethodNotAllowed", "The HTTP verb " + method + " is not allowed on this resource.");
                        throw new FakeHttpException(400, "BadRequest", "Resource not found for the segment '" + (p.Path.Split('/')[0]) + "'.");
                    }
                    var ctx = new Ctx { AppId = appId, Req = req, P = p, M = match, Ct = ct, RequestId = requestId };
                    if (route.Class == EndpointClass.Batch) resp = await BatchAsync(ctx).ConfigureAwait(false);
                    else
                    {
                        lock (Tenant.Gate) { resp = route.H(this, ctx); }
                    }
                    if (req.BodyBytes != null) Counters.Received(req.BodyBytes.Length);
                    else if (req.BodyJson != null) Counters.Received(req.BodyJson.Length);
                }
                catch (FakeHttpException ex)
                {
                    resp = ErrorResponse(ex.Status, ex.Code, ex.Message, requestId, p, ex.RetryAfter);
                }
                if (d.TruncateFraction > 0 && resp.StatusCode / 100 == 2 && resp.Content != null && resp.Content.CanSeek && resp.Headers.ContainsKey("X-Fake-Download"))
                {
                    long total = resp.Content.Length - resp.Content.Position;
                    resp.Content = new TruncatedStream(resp.Content, (long)(total * d.TruncateFraction), d.TruncateThrows);
                    Counters.Incr(ref Counters.TruncatedDownloads); Counters.Incr(ref Counters.FaultsInjected);
                }
                resp.Headers.Remove("X-Fake-Download");
            }
            resp.Headers["request-id"] = requestId;
            resp.Headers["client-request-id"] = req.Headers.ContainsKey("client-request-id") ? req.Headers["client-request-id"] : requestId;
            resp.Headers["Date"] = DateTimeOffset.UtcNow.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
            Counters.Status(resp.StatusCode, cls);
            if (log != null) log.Status = resp.StatusCode;
            var ms = resp.Content as MemoryStream;
            if (ms != null) Counters.Served(ms.Length); else if (resp.Content != null && resp.Content != Stream.Null) resp.Content = new CountingStream(resp.Content, Counters);
            return resp;
        }

        static string ThreadKeyOf(Match m)
        {
            if (m == null) return null;
            if (m.Groups["chat"].Success) return m.Groups["chat"].Value;
            if (m.Groups["team"].Success && m.Groups["chan"].Success) return m.Groups["team"].Value + "/" + m.Groups["chan"].Value;
            return null;
        }

        sealed class CountingStream : Stream
        {
            readonly Stream _s; readonly FakeGraphCounters _c;
            public CountingStream(Stream s, FakeGraphCounters c) { _s = s; _c = c; }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return _s.CanSeek; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { return _s.Length; } }
            public override long Position { get { return _s.Position; } set { _s.Position = value; } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) { int n = _s.Read(buffer, offset, count); if (n > 0) _c.Served(n); return n; }
            public override int Read(Span<byte> buffer) { int n = _s.Read(buffer); if (n > 0) _c.Served(n); return n; }
            public override long Seek(long offset, SeekOrigin origin) { return _s.Seek(offset, origin); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) _s.Dispose(); base.Dispose(disposing); }
        }

        /// <summary>Ends after `limit` bytes: by IOException (the way HttpClient reports a response that ended before Content-Length) or by a quiet EOF.</summary>
        sealed class TruncatedStream : Stream
        {
            readonly Stream _s; long _left; readonly bool _throw;
            public TruncatedStream(Stream s, long limit, bool throwOnEnd) { _s = s; _left = limit; _throw = throwOnEnd; }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count)
            {
                if (_left <= 0)
                {
                    if (_throw) throw new IOException("The response ended prematurely, with at least some bytes of the content missing (injected truncation).");
                    return 0;
                }
                int n = _s.Read(buffer, offset, (int)Math.Min(count, _left));
                _left -= n;
                return n;
            }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) _s.Dispose(); base.Dispose(disposing); }
        }

        // ------------------------------------------------------------------ response helpers

        GraphResponse ErrorResponse(int status, string code, string message, string requestId, Parsed p, string retryAfter)
        {
            var r = JsonResponse(status, w =>
            {
                w.WriteStartObject("error");
                w.WriteString("code", code); w.WriteString("message", message);
                w.WriteStartObject("innerError");
                w.WriteString("date", FakeTime.Format(Tenant.NowMs));
                w.WriteString("request-id", requestId); w.WriteString("client-request-id", requestId);
                w.WriteEndObject(); w.WriteEndObject();
            });
            if (retryAfter != null) r.Headers["Retry-After"] = retryAfter;
            return r;
        }

        static GraphResponse JsonResponse(int status, Action<Utf8JsonWriter> body)
        {
            var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                body(w);
                w.WriteEndObject();
            }
            ms.Position = 0;
            var r = new GraphResponse { StatusCode = status, Content = ms, ContentType = JsonType };
            r.Headers["Content-Type"] = JsonType;
            return r;
        }

        static GraphResponse EmptyResponse(int status)
        {
            return new GraphResponse { StatusCode = status, Content = new MemoryStream(new byte[0]) };
        }

        static GraphResponse BytesResponse(byte[] data, string contentType)
        {
            var r = new GraphResponse { StatusCode = 200, Content = new MemoryStream(data, false), ContentType = contentType };
            r.Headers["Content-Type"] = contentType; r.Headers["Content-Length"] = data.Length.ToString();
            r.Headers["X-Fake-Download"] = "1";
            return r;
        }

        /// <summary>Streams a file, honouring Range: bytes=a-b (206).</summary>
        GraphResponse StreamResponse(Ctx c, Stream content, long length, string contentType)
        {
            string range = c.Header("Range");
            int status = 200; long start = 0, end = length - 1;
            if (range != null)
            {
                var m = Regex.Match(range, @"bytes=(\d*)-(\d*)");
                if (m.Success)
                {
                    if (m.Groups[1].Value != "") { start = long.Parse(m.Groups[1].Value); if (m.Groups[2].Value != "") end = Math.Min(end, long.Parse(m.Groups[2].Value)); }
                    else if (m.Groups[2].Value != "") { start = Math.Max(0, length - long.Parse(m.Groups[2].Value)); }
                    if (start >= length) throw new FakeHttpException(416, "invalidRange", "The requested range cannot be satisfied.");
                    status = 206;
                }
            }
            content.Position = start;
            Stream body = status == 206 ? (Stream)new LimitedStream(content, end - start + 1) : content;
            var r = new GraphResponse { StatusCode = status, Content = body, ContentType = contentType };
            r.Headers["Content-Type"] = contentType;
            r.Headers["Content-Length"] = (end - start + 1).ToString();
            if (status == 206) r.Headers["Content-Range"] = "bytes " + start + "-" + end + "/" + length;
            r.Headers["X-Fake-Download"] = "1";
            return r;
        }

        sealed class LimitedStream : Stream
        {
            readonly Stream _s; long _left;
            public LimitedStream(Stream s, long n) { _s = s; _left = n; }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { return _left; } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count)
            {
                if (_left <= 0) return 0;
                int n = _s.Read(buffer, offset, (int)Math.Min(count, _left)); _left -= n; return n;
            }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) _s.Dispose(); base.Dispose(disposing); }
        }

        static FakeHttpException NotFound(string code, string what) { return new FakeHttpException(404, code, what); }
        static FakeHttpException Bad(string message) { return new FakeHttpException(400, "BadRequest", message); }

        // ------------------------------------------------------------------ request helpers

        static string BodyText(GraphRequest r)
        {
            if (r.BodyJson != null) return r.BodyJson;
            if (r.BodyBytes != null) return Encoding.UTF8.GetString(r.BodyBytes);
            if (r.BodyStream != null) { using (var sr = new StreamReader(r.BodyStream, Encoding.UTF8, true, 4096, true)) return sr.ReadToEnd(); }
            return null;
        }

        static JsonDocument BodyDoc(GraphRequest r, bool required = true)
        {
            string t = BodyText(r);
            if (string.IsNullOrWhiteSpace(t)) { if (required) throw Bad("The request body is required."); return null; }
            try { return JsonDocument.Parse(t); }
            catch (JsonException) { throw Bad("The request body is not valid JSON."); }
        }

        static string Str(JsonElement e, string name)
        {
            JsonElement v;
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String) return v.GetString();
            return null;
        }

        static bool Has(JsonElement e, string name)
        {
            JsonElement v;
            return e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out v) && v.ValueKind != JsonValueKind.Null;
        }

        int PageSize(Ctx c, int def, int max, bool strict)
        {
            int top = def;
            string t = c.Q("$top");
            if (t != null)
            {
                if (!int.TryParse(t, out top) || top < 1) throw Bad("Invalid value '" + t + "' for $top.");
            }
            else
            {
                var pref = c.Header("Prefer");
                var m = pref == null ? null : Regex.Match(pref, @"odata\.maxpagesize\s*=\s*(\d+)", RegexOptions.IgnoreCase);
                if (m != null && m.Success) top = int.Parse(m.Groups[1].Value);
            }
            if (top > max) { if (strict) throw Bad("Maximum allowed page size is " + max + " (requested $top=" + top + ")."); top = max; }
            return top;
        }

        static string Token(string s) { return Convert.ToBase64String(Encoding.ASCII.GetBytes("v1;" + s)).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        static string Untoken(string t)
        {
            try
            {
                string b = t.Replace('-', '+').Replace('_', '/'); while (b.Length % 4 != 0) b += "=";
                var s = Encoding.ASCII.GetString(Convert.FromBase64String(b));
                if (!s.StartsWith("v1;")) throw new FormatException();
                return s.Substring(3);
            }
            catch (FormatException) { throw Bad("Invalid $skiptoken."); }
        }

        string NextLink(Ctx c, string token)
        {
            var q = new List<string>();
            foreach (var part in c.P.RawQuery.Split(new[] { '&' }, StringSplitOptions.RemoveEmptyEntries))
            {
                int eq = part.IndexOf('=');
                string k = Dec(eq < 0 ? part : part.Substring(0, eq));
                if (k == "$skiptoken" || k == "$skip") continue;
                q.Add(part);
            }
            q.Add("$skiptoken=" + token);
            return GraphRoot + "/" + c.P.Version + "/" + c.P.RawPath + "?" + string.Join("&", q);
        }

        /// <summary>A plain offset-paged list (users, groups, teams, chats, members...).</summary>
        GraphResponse OffsetList<T>(Ctx c, string context, IList<T> items, int pageSize, Action<Utf8JsonWriter, T> write)
        {
            int offset = 0;
            string tok = c.Q("$skiptoken");
            if (tok != null)
            {
                var s = Untoken(tok);
                if (!s.StartsWith("o:") || !int.TryParse(s.Substring(2), out offset)) throw Bad("Invalid $skiptoken.");
            }
            int end = Math.Min(items.Count, offset + pageSize);
            return JsonResponse(200, w =>
            {
                w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#" + context);
                if (end < items.Count) w.WriteString("@odata.nextLink", NextLink(c, Token("o:" + end)));
                w.WriteStartArray("value");
                for (int i = offset; i < end; i++) write(w, items[i]);
                w.WriteEndArray();
            });
        }

        // ------------------------------------------------------------------ $filter

        sealed class Clause { public string Prop, Op; public string Raw; public long Ms; public bool IsTime; }

        static List<Clause> ParseFilter(string filter, params string[] timeProps)
        {
            var list = new List<Clause>();
            if (string.IsNullOrWhiteSpace(filter)) return list;
            foreach (var part in Regex.Split(filter.Trim(), @"\s+and\s+", RegexOptions.IgnoreCase))
            {
                var m = Regex.Match(part.Trim(), @"^(?<p>[A-Za-z_/]+)\s+(?<op>eq|ne|gt|ge|lt|le)\s+(?<v>.+)$", RegexOptions.IgnoreCase);
                if (!m.Success) throw Bad("Invalid filter clause: '" + part + "'.");
                var cl = new Clause { Prop = m.Groups["p"].Value, Op = m.Groups["op"].Value.ToLowerInvariant(), Raw = m.Groups["v"].Value.Trim().Trim('\'') };
                var tp = timeProps.FirstOrDefault(x => x.Equals(cl.Prop, StringComparison.OrdinalIgnoreCase));
                if (tp != null)
                {
                    cl.Prop = tp; cl.IsTime = true;
                    if (!FakeTime.TryParse(cl.Raw, out cl.Ms)) throw Bad("Invalid date '" + cl.Raw + "' in the filter.");
                }
                list.Add(cl);
            }
            return list;
        }

        static bool TimeOk(Clause c, long v)
        {
            switch (c.Op)
            {
                case "gt": return v > c.Ms;
                case "ge": return v >= c.Ms;
                case "lt": return v < c.Ms;
                case "le": return v <= c.Ms;
                case "eq": return v == c.Ms;
                default: return v != c.Ms;
            }
        }

        // ------------------------------------------------------------------ message sequences (sorted views)

        abstract class Seq
        {
            public abstract int Count { get; }
            public abstract long Key(int i);        // sort key, descending
            public abstract long Id(int i);
            public abstract int Ord(int i);
            public abstract FakeThread Thread(int i);
            public abstract FakeMessage Msg(int i);
        }

        sealed class ThreadSeq : Seq
        {
            readonly FakeThread _t; readonly int[] _pos; readonly bool _byCreated;
            public ThreadSeq(FakeThread t, int[] pos, bool byCreated) { _t = t; _pos = pos; _byCreated = byCreated; }
            public override int Count { get { return _pos.Length; } }
            public override long Key(int i) { var m = _t.Messages[_pos[i]]; return _byCreated ? m.CreatedMs : m.ModifiedMs; }
            public override long Id(int i) { return _t.Messages[_pos[i]].CreatedMs; }
            public override int Ord(int i) { return 0; }
            public override FakeThread Thread(int i) { return _t; }
            public override FakeMessage Msg(int i) { return _t.Messages[_pos[i]]; }
        }

        /// <summary>Messages of several threads merged and sorted: built once per (owner, version) and cached, because a user can own 100k+ messages.</summary>
        sealed class MergedSeq : Seq
        {
            public readonly FakeThread[] Threads; public readonly long[] Mod; public readonly int[] OrdArr; public readonly int[] PosArr; public long Sig;
            public MergedSeq(FakeThread[] threads, bool byCreated)
            {
                Threads = threads;
                int total = 0; foreach (var t in threads) total += t.Messages.Count;
                var mod = new long[total]; var ord = new int[total]; var pos = new int[total];
                int k = 0;
                for (int o = 0; o < threads.Length; o++)
                {
                    var msgs = threads[o].Messages;
                    for (int i = 0; i < msgs.Count; i++) { mod[k] = byCreated ? msgs[i].CreatedMs : msgs[i].ModifiedMs; ord[k] = o; pos[k] = i; k++; }
                }
                var idx = new int[total];
                for (int i = 0; i < total; i++) idx[i] = i;
                var th = threads;
                Array.Sort(idx, (a, b) =>
                {
                    int c = mod[b].CompareTo(mod[a]);
                    if (c != 0) return c;
                    c = th[ord[b]].Messages[pos[b]].CreatedMs.CompareTo(th[ord[a]].Messages[pos[a]].CreatedMs);
                    return c != 0 ? c : ord[a].CompareTo(ord[b]);
                });
                Mod = new long[total]; OrdArr = new int[total]; PosArr = new int[total];
                for (int i = 0; i < total; i++) { int j = idx[i]; Mod[i] = mod[j]; OrdArr[i] = ord[j]; PosArr[i] = pos[j]; }
            }
            public override int Count { get { return Mod.Length; } }
            public override long Key(int i) { return Mod[i]; }
            public override long Id(int i) { return Threads[OrdArr[i]].Messages[PosArr[i]].CreatedMs; }
            public override int Ord(int i) { return OrdArr[i]; }
            public override FakeThread Thread(int i) { return Threads[OrdArr[i]]; }
            public override FakeMessage Msg(int i) { return Threads[OrdArr[i]].Messages[PosArr[i]]; }
        }

        readonly Dictionary<string, MergedSeq> _merged = new Dictionary<string, MergedSeq>();

        MergedSeq GetMerged(string key, IList<FakeThread> threads, bool byCreated)
        {
            long sig = threads.Count;
            unchecked { foreach (var t in threads) sig = sig * 31 + t.Version + t.Ordinal * 7 + (t is FakeChannel ? 1 : 0); }
            key += byCreated ? "|c" : "|m";
            MergedSeq m;
            lock (_merged)
            {
                if (_merged.TryGetValue(key, out m) && m.Sig == sig) return m;
                if (_merged.Count >= 2) _merged.Clear();
                m = new MergedSeq(threads.ToArray(), byCreated) { Sig = sig };
                _merged[key] = m;
                return m;
            }
        }

        // first index in [lo, hi) for which pred is false (pred is true on a prefix)
        static int Partition(int lo, int hi, Func<int, bool> pred)
        {
            while (lo < hi) { int mid = lo + ((hi - lo) >> 1); if (pred(mid)) lo = mid + 1; else hi = mid; }
            return lo;
        }

        /// <summary>
        /// Writes one page of a sorted message view. Cursor = (key, id, ordinal, served): "strictly after" in (key desc, id desc, ordinal asc),
        /// so paging survives concurrent imports (a new message lands before or after the cursor, never duplicates or loses one).
        /// </summary>
        GraphResponse MessagePage(Ctx c, Seq seq, List<Clause> filter, string sortProp, int top, int cap, string context, Action<Utf8JsonWriter, FakeThread, FakeMessage> write, bool evalMode)
        {
            int start = 0, end = seq.Count;
            foreach (var cl in filter)
            {
                if (!cl.IsTime || !cl.Prop.Equals(sortProp, StringComparison.OrdinalIgnoreCase)) continue;
                var cc = cl;
                if (cc.Op == "gt") end = Math.Min(end, Partition(0, end, i => seq.Key(i) > cc.Ms));
                else if (cc.Op == "ge") end = Math.Min(end, Partition(0, end, i => seq.Key(i) >= cc.Ms));
                else if (cc.Op == "lt") start = Math.Max(start, Partition(0, seq.Count, i => seq.Key(i) >= cc.Ms));
                else if (cc.Op == "le") start = Math.Max(start, Partition(0, seq.Count, i => seq.Key(i) > cc.Ms));
            }
            int served = 0;
            string tok = c.Q("$skiptoken");
            if (tok != null)
            {
                var parts = Untoken(tok).Split(':');
                long km, kid; int kord;
                if (parts.Length != 5 || parts[0] != "k" || !long.TryParse(parts[1], out km) || !long.TryParse(parts[2], out kid) || !int.TryParse(parts[3], out kord) || !int.TryParse(parts[4], out served))
                    throw Bad("Invalid $skiptoken.");
                int after = Partition(0, seq.Count, i =>
                {
                    long k = seq.Key(i);
                    if (k != km) return k > km;
                    long id = seq.Id(i);
                    if (id != kid) return id > kid;
                    return seq.Ord(i) <= kord;
                });
                start = Math.Max(start, after);
            }
            var resp = JsonResponse(200, w =>
            {
                w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#" + context);
                int written = 0, i = start, lastI = -1;
                var buffer = new List<int>();
                for (; i < end && written < top && served + written < cap; i++)
                {
                    var m = seq.Msg(i);
                    bool ok = true;
                    foreach (var cl in filter) if (cl.IsTime && !TimeOk(cl, cl.Prop == "createdDateTime" ? m.CreatedMs : m.ModifiedMs)) { ok = false; break; }
                    if (!ok) continue;
                    buffer.Add(i); written++; lastI = i;
                }
                // a next page exists only if there is something after the last returned item that passes the filter
                bool more = false;
                if (lastI >= 0 && written >= top && served + written < cap)
                {
                    for (int j = lastI + 1; j < end; j++)
                    {
                        var m = seq.Msg(j); bool ok = true;
                        foreach (var cl in filter) if (cl.IsTime && !TimeOk(cl, cl.Prop == "createdDateTime" ? m.CreatedMs : m.ModifiedMs)) { ok = false; break; }
                        if (ok) { more = true; break; }
                    }
                }
                w.WriteNumber("@odata.count", written);
                if (more) w.WriteString("@odata.nextLink", NextLink(c, Token("k:" + seq.Key(lastI) + ":" + seq.Id(lastI) + ":" + seq.Ord(lastI) + ":" + (served + written))));
                w.WriteStartArray("value");
                foreach (int ix in buffer) write(w, seq.Thread(ix), seq.Msg(ix));
                w.WriteEndArray();
            });
            if (evalMode)
            {
                resp.Headers["Warning"] = "199 - \"Evaluation mode: the model query parameter is missing or invalid (use model=A or model=B). Results are limited to " + Tenant.EvaluationModeMaxMessages + " messages.\"";
                Counters.Incr(ref Counters.EvaluationModeResponses);
            }
            return resp;
        }

        // ------------------------------------------------------------------ JSON writers

        FakeUser U(int ord) { return ord >= 0 && ord < Tenant.Users.Count ? Tenant.Users[ord] : null; }

        void WriteIdentity(Utf8JsonWriter w, string prop, FakeUser u)
        {
            w.WriteStartObject(prop);
            w.WriteString("@odata.type", "#microsoft.graph.teamworkUserIdentity");
            w.WriteString("id", u.Id); w.WriteString("displayName", u.DisplayName);
            w.WriteString("userIdentityType", "aadUser"); w.WriteString("tenantId", u.TenantId);
            w.WriteEndObject();
        }

        static readonly string[] DefaultUserFields = { "id", "userPrincipalName", "displayName", "mail", "givenName", "surname", "jobTitle" };

        void WriteUser(Utf8JsonWriter w, FakeUser u, HashSet<string> select, bool deletedView)
        {
            w.WriteStartObject();
            Func<string, bool> on = f => select == null ? (Array.IndexOf(DefaultUserFields, f) >= 0) : select.Contains(f);
            if (on("id")) w.WriteString("id", u.Id);
            if (on("userPrincipalName")) w.WriteString("userPrincipalName", u.Upn);
            if (on("displayName")) w.WriteString("displayName", u.DisplayName);
            if (on("mail")) w.WriteString("mail", u.Mail);
            if (on("givenName")) w.WriteString("givenName", u.GivenName);
            if (on("surname")) w.WriteString("surname", u.Surname);
            if (on("jobTitle")) { if (u.JobTitle == null) w.WriteNull("jobTitle"); else w.WriteString("jobTitle", u.JobTitle); }
            if (select != null && select.Contains("userType")) w.WriteString("userType", u.UserType);
            if (select != null && select.Contains("accountEnabled")) w.WriteBoolean("accountEnabled", !u.Deleted);
            if (deletedView) w.WriteString("deletedDateTime", FakeTime.Format(u.DeletedMs));
            w.WriteEndObject();
        }

        void WriteMember(Utf8JsonWriter w, int threadOrd, FakeMember m)
        {
            var u = U(m.UserOrd);
            w.WriteStartObject();
            w.WriteString("@odata.type", "#microsoft.graph.aadUserConversationMember");
            w.WriteString("id", FakeTenant.MembershipId(threadOrd, m.UserOrd));
            w.WriteStartArray("roles"); if (!string.IsNullOrEmpty(m.Roles)) foreach (var r in m.Roles.Split(',')) w.WriteStringValue(r); w.WriteEndArray();
            w.WriteString("displayName", u.DisplayName);
            w.WriteString("visibleHistoryStartDateTime", m.VisibleHistoryStartMs == FakeMember.AllHistory ? "0001-01-01T00:00:00Z" : FakeTime.Format(m.VisibleHistoryStartMs));
            w.WriteString("userId", u.Id); w.WriteString("email", u.Mail); w.WriteString("tenantId", u.TenantId);
            w.WriteEndObject();
        }

        void WriteChat(Utf8JsonWriter w, FakeChat ch, bool expandMembers)
        {
            w.WriteStartObject();
            w.WriteString("id", ch.Id);
            if (ch.Topic == null) w.WriteNull("topic"); else w.WriteString("topic", ch.Topic);
            w.WriteString("createdDateTime", FakeTime.Format(ch.CreatedMs));
            w.WriteString("lastUpdatedDateTime", FakeTime.Format(Math.Max(ch.LastUpdatedMs, ch.CreatedMs)));
            w.WriteString("chatType", ch.TypeName);
            w.WriteString("webUrl", "https://teams.microsoft.com/l/chat/" + Uri.EscapeDataString(ch.Id) + "/0?tenantId=" + Tenant.TenantId);
            w.WriteString("tenantId", Tenant.TenantId);
            if (ch.MigrationMode != null) w.WriteString("migrationMode", ch.MigrationMode);
            if (ch.ChatType == FakeChatType.Meeting) { w.WriteStartObject("onlineMeetingInfo"); w.WriteString("joinWebUrl", ch.MeetingJoinUrl); w.WriteEndObject(); }
            if (expandMembers)
            {
                w.WriteStartArray("members");
                foreach (var m in ch.Members) WriteMember(w, ch.Ordinal, m);
                w.WriteEndArray();
            }
            w.WriteEndObject();
        }

        void WriteChannel(Utf8JsonWriter w, FakeChannel ch)
        {
            w.WriteStartObject();
            w.WriteString("id", ch.Id);
            w.WriteString("createdDateTime", FakeTime.Format(ch.CreatedMs));
            w.WriteString("displayName", ch.DisplayName);
            w.WriteString("description", ch.Description ?? "");
            w.WriteNull("email");
            w.WriteBoolean("isFavoriteByDefault", false);
            w.WriteString("membershipType", ch.TypeName);
            w.WriteString("tenantId", Tenant.TenantId);
            w.WriteString("webUrl", "https://teams.microsoft.com/l/channel/" + Uri.EscapeDataString(ch.Id) + "/" + Uri.EscapeDataString(ch.DisplayName) + "?groupId=" + ch.Team.Id + "&tenantId=" + Tenant.TenantId);
            if (ch.MigrationMode != null) w.WriteString("migrationMode", ch.MigrationMode);
            w.WriteEndObject();
        }

        void WriteTeam(Utf8JsonWriter w, FakeTeam t, bool asGroup)
        {
            w.WriteStartObject();
            w.WriteString("id", t.Id); w.WriteString("displayName", t.DisplayName); w.WriteString("description", t.Description ?? "");
            w.WriteString("createdDateTime", FakeTime.Format(t.CreatedMs));
            w.WriteString("visibility", t.Visibility);
            if (asGroup)
            {
                w.WriteStartArray("resourceProvisioningOptions"); w.WriteStringValue("Team"); w.WriteEndArray();
                w.WriteString("mail", t.SiteSlug + "@" + Tenant.Domain);
            }
            else { w.WriteBoolean("isArchived", false); if (t.MigrationMode != null) w.WriteString("migrationMode", t.MigrationMode); }
            w.WriteEndObject();
        }

        static string Hosted(long msgId, int k) { return Convert.ToBase64String(Encoding.ASCII.GetBytes("id=x_" + k + "-wus-d1-" + msgId.ToString("x"))).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        void WriteMessage(Utf8JsonWriter w, FakeThread th, FakeMessage m)
        {
            var x = m.X; bool sys = (m.Flags & FakeMessage.FlagSystem) != 0;
            string id = m.CreatedMs.ToString();
            w.WriteStartObject();
            w.WriteString("id", id);
            if (x != null && x.ReplyTo != 0) w.WriteString("replyToId", x.ReplyTo.ToString()); else w.WriteNull("replyToId");
            w.WriteString("etag", id);
            w.WriteString("messageType", sys ? "systemEventMessage" : "message");
            w.WriteString("createdDateTime", FakeTime.Format(m.CreatedMs));
            w.WriteString("lastModifiedDateTime", FakeTime.Format(m.ModifiedMs));
            if (x != null && x.EditedMs != 0) w.WriteString("lastEditedDateTime", FakeTime.Format(x.EditedMs)); else w.WriteNull("lastEditedDateTime");
            if (x != null && x.DeletedMs != 0) w.WriteString("deletedDateTime", FakeTime.Format(x.DeletedMs)); else w.WriteNull("deletedDateTime");
            if (x != null && x.Subject != null) w.WriteString("subject", x.Subject); else w.WriteNull("subject");
            w.WriteNull("summary");
            var chat = th as FakeChat;
            if (chat != null) w.WriteString("chatId", chat.Id);
            else
            {
                var chn = (FakeChannel)th;
                w.WriteStartObject("channelIdentity"); w.WriteString("teamId", chn.Team.Id); w.WriteString("channelId", chn.Id); w.WriteEndObject();
            }
            w.WriteString("importance", x != null && x.Importance != null ? x.Importance : "normal");
            w.WriteString("locale", "en-us");
            w.WriteNull("webUrl");
            w.WriteNull("policyViolation");
            if (sys && x != null && x.EventDetailJson != null) { w.WritePropertyName("eventDetail"); w.WriteRawValue(x.EventDetailJson); } else w.WriteNull("eventDetail");
            var au = U(m.AuthorOrd);
            if (au == null && !(x != null && x.FromApplication != null)) w.WriteNull("from");
            else
            {
            w.WriteStartObject("from");
            if (x != null && x.FromApplication != null)
            {
                var ap = x.FromApplication.Split('|');
                w.WriteStartObject("application"); w.WriteString("@odata.type", "#microsoft.graph.teamworkApplicationIdentity"); w.WriteString("id", ap[0]); w.WriteString("displayName", ap.Length > 1 ? ap[1] : ap[0]); w.WriteString("applicationIdentityType", "bot"); w.WriteEndObject();
                w.WriteNull("device"); w.WriteNull("user");
            }
            else if (au != null) { w.WriteNull("application"); w.WriteNull("device"); WriteIdentity(w, "user", au); }
            w.WriteEndObject();
            }
            bool deleted = m.IsDeleted;
            w.WriteStartObject("body");
            w.WriteString("contentType", (m.Flags & FakeMessage.FlagText) != 0 ? "text" : "html");
            if (deleted) w.WriteString("content", "");
            else if (sys) w.WriteString("content", "<systemEventMessage/>");
            else w.WriteString("content", x != null && x.Body != null ? x.Body : (m.Flags & FakeMessage.FlagText) != 0 ? FakeText.Plain(m.Seed, th.Lang) : FakeText.Render(m.Seed, th.Lang));
            w.WriteEndObject();
            w.WriteStartArray("attachments");
            if (!deleted && x != null && x.Attachments != null)
                foreach (var a in x.Attachments)
                {
                    w.WriteStartObject();
                    w.WriteString("id", a.Id); w.WriteString("contentType", a.ContentType);
                    if (a.ContentUrl == null) w.WriteNull("contentUrl"); else w.WriteString("contentUrl", a.ContentUrl);
                    if (a.Content == null) w.WriteNull("content"); else w.WriteString("content", a.Content);
                    if (a.Name == null) w.WriteNull("name"); else w.WriteString("name", a.Name);
                    if (a.ThumbnailUrl == null) w.WriteNull("thumbnailUrl"); else w.WriteString("thumbnailUrl", a.ThumbnailUrl);
                    w.WriteEndObject();
                }
            w.WriteEndArray();
            w.WriteStartArray("mentions");
            if (!deleted && x != null && x.Mentions != null)
                foreach (var mn in x.Mentions)
                {
                    w.WriteStartObject();
                    w.WriteNumber("id", mn.Id); w.WriteString("mentionText", mn.Text);
                    w.WriteStartObject("mentioned");
                    w.WriteNull("application"); w.WriteNull("device");
                    if (mn.Kind == "user" && U(mn.UserOrd) != null) { w.WriteNull("conversation"); WriteIdentity(w, "user", U(mn.UserOrd)); }
                    else
                    {
                        w.WriteStartObject("conversation"); w.WriteString("id", mn.TargetId ?? ""); w.WriteString("displayName", mn.TargetName ?? mn.Text); w.WriteString("conversationIdentityType", mn.Kind); w.WriteEndObject();
                        w.WriteNull("user");
                    }
                    w.WriteEndObject(); w.WriteEndObject();
                }
            w.WriteEndArray();
            w.WriteStartArray("reactions");
            if (!deleted && x != null && x.Reactions != null)
                foreach (var r in x.Reactions)
                {
                    var ru = U(r.UserOrd);
                    w.WriteStartObject();
                    w.WriteString("reactionType", r.Type); w.WriteString("createdDateTime", FakeTime.Format(r.CreatedMs));
                    w.WriteStartObject("user"); w.WriteNull("application"); w.WriteNull("device");
                    if (ru != null) WriteIdentity(w, "user", ru); else w.WriteNull("user");
                    w.WriteEndObject(); w.WriteEndObject();
                }
            w.WriteEndArray();
            w.WriteEndObject();
        }

        // ------------------------------------------------------------------ resolvers

        FakeUser ResolveUser(string idOrUpn, bool allowDeleted)
        {
            var u = Tenant.FindUser(idOrUpn);
            if (u == null || u.External || (u.Deleted && !allowDeleted))
                throw NotFound("Request_ResourceNotFound", "Resource '" + idOrUpn + "' does not exist or one of its queried reference-property objects are not present.");
            return u;
        }

        FakeChat ResolveChat(Ctx c)
        {
            FakeChat ch;
            if (!Tenant.ChatsById.TryGetValue(c.G("chat"), out ch)) throw NotFound("NotFound", "Chat " + c.G("chat") + " was not found.");
            return ch;
        }

        FakeChannel ResolveChannel(Ctx c, out FakeTeam team)
        {
            if (!Tenant.TeamsById.TryGetValue(c.G("team"), out team)) throw NotFound("NotFound", "Team " + c.G("team") + " was not found.");
            var chn = team.Channels.Find(x => string.Equals(x.Id, c.G("chan"), StringComparison.OrdinalIgnoreCase));
            if (chn == null) throw NotFound("NotFound", "Channel " + c.G("chan") + " was not found.");
            return chn;
        }

        FakeTeam ResolveTeam(Ctx c)
        {
            FakeTeam t;
            if (!Tenant.TeamsById.TryGetValue(c.G("team"), out t)) throw NotFound("NotFound", "Team " + c.G("team") + " was not found.");
            return t;
        }

        static long MsgId(string s)
        {
            long id;
            if (!long.TryParse(s, out id)) throw Bad("Invalid message id '" + s + "'.");
            return id;
        }

        string AppId(Ctx c) { return c.AppId; }

        // ------------------------------------------------------------------ routes

        static FakeGraphTransport()
        {
            const string DrvPfx = "(?:drives/(?<drive>[^/]+)|users/(?<user>[^/]+)/drive)";
            // users and directory
            R("GET", "users", EndpointClass.Users, (t, c) => t.ListUsers(c));
            R("GET", "users/(?<user>" + Seg + ")", EndpointClass.Users, (t, c) => t.GetUser(c));
            R("GET", "directory/deletedItems/microsoft\\.graph\\.user", EndpointClass.Users, (t, c) => t.ListDeletedUsers(c));
            R("GET", "directory/deletedItems/(?<user>" + Seg + ")", EndpointClass.Users, (t, c) => t.GetDeletedUser(c));
            R("GET", "users/(?<user>" + Seg + ")/chats", EndpointClass.UserChats, (t, c) => t.ListUserChats(c));
            R("GET", "users/(?<user>" + Seg + ")/chats/getAllMessages", EndpointClass.ChatGetAllMessages, (t, c) => t.UserGetAllMessages(c));
            R("GET", "chats/getAllMessages", EndpointClass.ChatGetAllMessages, (t, c) => t.TenantGetAllMessages(c));
            // chats
            R("POST", "chats", EndpointClass.Chat, (t, c) => t.CreateChat(c));
            R("GET", "chats/(?<chat>" + Seg + ")", EndpointClass.Chat, (t, c) => t.GetChat(c));
            R("GET", "chats/(?<chat>" + Seg + ")/members", EndpointClass.ChatMembers, (t, c) => t.ListChatMembers(c));
            R("POST", "chats/(?<chat>" + Seg + ")/members", EndpointClass.ChatMembers, (t, c) => t.AddChatMember(c));
            R("DELETE", "chats/(?<chat>" + Seg + ")/members/(?<mem>" + Seg + ")", EndpointClass.ChatMembers, (t, c) => t.RemoveChatMember(c));
            R("GET", "chats/(?<chat>" + Seg + ")/messages", EndpointClass.ChatMessages, (t, c) => t.ListChatMessages(c));
            R("POST", "chats/(?<chat>" + Seg + ")/messages", EndpointClass.ImportMessage, (t, c) => t.PostChatMessage(c));
            R("GET", "chats/(?<chat>" + Seg + ")/messages/(?<msg>" + Seg + ")", EndpointClass.ChatMessages, (t, c) => t.GetChatMessage(c));
            R("POST", "chats/(?<chat>" + Seg + ")/startMigration", EndpointClass.MigrationStart, (t, c) => t.StartMigration(c, t.ResolveChat(c)));
            R("POST", "chats/(?<chat>" + Seg + ")/completeMigration", EndpointClass.MigrationComplete, (t, c) => t.CompleteMigration(c, t.ResolveChat(c)));
            // hosted contents: chat message, channel message, channel reply
            R("GET", "(?:chats/(?<chat>" + Seg + ")|teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + "))/messages/(?<msg>" + Seg + ")(?:/replies/(?<rep>" + Seg + "))?/hostedContents", EndpointClass.HostedContent, (t, c) => t.ListHosted(c));
            R("GET", "(?:chats/(?<chat>" + Seg + ")|teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + "))/messages/(?<msg>" + Seg + ")(?:/replies/(?<rep>" + Seg + "))?/hostedContents/(?<hid>" + Seg + ")", EndpointClass.HostedContent, (t, c) => t.GetHosted(c, false));
            R("GET", "(?:chats/(?<chat>" + Seg + ")|teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + "))/messages/(?<msg>" + Seg + ")(?:/replies/(?<rep>" + Seg + "))?/hostedContents/(?<hid>" + Seg + ")/\\$value", EndpointClass.HostedContent, (t, c) => t.GetHosted(c, true));
            // teams and channels
            R("GET", "groups", EndpointClass.Teams, (t, c) => t.ListTeams(c, true));
            R("GET", "teams", EndpointClass.Teams, (t, c) => t.ListTeams(c, false));
            R("POST", "teams", EndpointClass.Teams, (t, c) => t.CreateTeam(c));
            R("GET", "teams/(?<team>" + Seg + ")", EndpointClass.Teams, (t, c) => t.GetTeam(c));
            R("GET", "teams/(?<team>" + Seg + ")/members", EndpointClass.ChannelMembers, (t, c) => t.ListTeamMembers(c));
            R("POST", "teams/(?<team>" + Seg + ")/completeMigration", EndpointClass.MigrationComplete, (t, c) => t.CompleteTeamMigration(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels", EndpointClass.Channels, (t, c) => t.ListChannels(c));
            R("POST", "teams/(?<team>" + Seg + ")/channels", EndpointClass.Channels, (t, c) => t.CreateChannel(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels/getAllMessages", EndpointClass.ChannelGetAllMessages, (t, c) => t.TeamGetAllMessages(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")", EndpointClass.Channels, (t, c) => t.GetChannel(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/members", EndpointClass.ChannelMembers, (t, c) => t.ListChannelMembers(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/filesFolder", EndpointClass.DriveItem, (t, c) => t.ChannelFilesFolder(c));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages", EndpointClass.ChannelMessages, (t, c) => t.ListChannelMessages(c));
            R("POST", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages", EndpointClass.ImportMessage, (t, c) => t.PostChannelMessage(c, false));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages/(?<msg>" + Seg + ")", EndpointClass.ChannelMessages, (t, c) => t.GetChannelMessage(c, false));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages/(?<msg>" + Seg + ")/replies", EndpointClass.ChannelReplies, (t, c) => t.ListReplies(c));
            R("POST", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages/(?<msg>" + Seg + ")/replies", EndpointClass.ImportMessage, (t, c) => t.PostChannelMessage(c, true));
            R("GET", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/messages/(?<msg>" + Seg + ")/replies/(?<rep>" + Seg + ")", EndpointClass.ChannelReplies, (t, c) => t.GetChannelMessage(c, true));
            R("POST", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/startMigration", EndpointClass.MigrationStart, (t, c) => { FakeTeam tm; var ch = t.ResolveChannel(c, out tm); return t.StartMigration(c, ch); });
            R("POST", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/completeMigration", EndpointClass.MigrationComplete, (t, c) => { FakeTeam tm; var ch = t.ResolveChannel(c, out tm); return t.CompleteMigration(c, ch); });
            R("POST", "teams/(?<team>" + Seg + ")/channels/(?<chan>" + Seg + ")/members", EndpointClass.ChannelMembers, (t, c) => t.AddChannelMember(c));
            R("GET", "groups/(?<team>" + Seg + ")/drive", EndpointClass.DriveItem, (t, c) => t.GetDriveObject(c));
            // files
            R("GET", "shares/(?<share>" + Seg + ")/driveItem", EndpointClass.DriveItem, (t, c) => t.GetShare(c, false));
            R("GET", "shares/(?<share>" + Seg + ")/driveItem/content", EndpointClass.DriveContent, (t, c) => t.GetShare(c, true));
            R("GET", "drives/(?<drive>" + Seg + ")", EndpointClass.DriveItem, (t, c) => t.GetDriveObject(c));
            R("GET", "users/(?<user>" + Seg + ")/drive", EndpointClass.DriveItem, (t, c) => t.GetDriveObject(c));
            R("GET", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")", EndpointClass.DriveItem, (t, c) => t.GetItem(c));
            R("GET", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")/content", EndpointClass.DriveContent, (t, c) => t.GetItemContent(c));
            R("GET", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")/children", EndpointClass.DriveItem, (t, c) => t.ListChildren(c));
            R("GET", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")/permissions", EndpointClass.DriveItem, (t, c) => t.ListPermissions(c));
            R("POST", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")/invite", EndpointClass.DriveItem, (t, c) => t.Invite(c));
            R("POST", "drives/(?<drive>" + Seg + ")/items/(?<item>" + Seg + ")/createLink", EndpointClass.DriveItem, (t, c) => t.CreateLink(c));
            R("POST", "drives/(?<drive>" + Seg + ")/items/(?<item>[^/:]+):/(?<name>.+?):/createUploadSession", EndpointClass.DriveUpload, (t, c) => t.CreateUploadSession(c));
            R("GET", DrvPfx + "/root", EndpointClass.DriveItem, (t, c) => t.GetByPath(c, "/"));
            R("GET", DrvPfx + "/root:(?<path>/.+?):/content", EndpointClass.DriveContent, (t, c) => t.GetPathContent(c));
            R("PUT", DrvPfx + "/root:(?<path>/.+?):/content", EndpointClass.DriveUpload, (t, c) => t.SimpleUpload(c));
            R("POST", DrvPfx + "/root:(?<path>/.+?):/createUploadSession", EndpointClass.DriveUpload, (t, c) => t.CreateUploadSession(c));
            R("GET", DrvPfx + "/root:(?<path>/.+?):?", EndpointClass.DriveItem, (t, c) => t.GetByPath(c, null));
            R("PUT", "@upload/up/(?<sid>" + Seg + ")", EndpointClass.DriveUpload, (t, c) => t.UploadFragment(c));
            R("GET", "@upload/up/(?<sid>" + Seg + ")", EndpointClass.DriveUpload, (t, c) => t.UploadStatus(c));
            R("DELETE", "@upload/up/(?<sid>" + Seg + ")", EndpointClass.DriveUpload, (t, c) => t.UploadCancel(c));
            R("GET", "@download/dl/(?<drive>" + Seg + ")/(?<item>" + Seg + ")", EndpointClass.DriveContent, (t, c) => t.GetItemContent(c));
            R("POST", "\\$batch", EndpointClass.Batch, null);
        }

        // ------------------------------------------------------------------ users

        GraphResponse ListUsers(Ctx c)
        {
            var filter = ParseFilter(c.Q("$filter"));
            IEnumerable<FakeUser> q = Tenant.Users.Where(u => !u.Deleted && !u.External);
            foreach (var cl in filter)
            {
                if (cl.Op != "eq") throw Bad("Only 'eq' is supported on users in the fake.");
                var v = cl.Raw;
                switch (cl.Prop.ToLowerInvariant())
                {
                    case "userprincipalname": q = q.Where(u => string.Equals(u.Upn, v, StringComparison.OrdinalIgnoreCase)); break;
                    case "mail": q = q.Where(u => string.Equals(u.Mail, v, StringComparison.OrdinalIgnoreCase)); break;
                    case "displayname": q = q.Where(u => string.Equals(u.DisplayName, v, StringComparison.OrdinalIgnoreCase)); break;
                    case "id": q = q.Where(u => string.Equals(u.Id, v, StringComparison.OrdinalIgnoreCase)); break;
                    default: throw Bad("Property '" + cl.Prop + "' is not supported in $filter on users.");
                }
            }
            var list = q.ToList();
            var sel = Select(c);
            return OffsetList(c, "users", list, PageSize(c, 100, 999, false), (w, u) => WriteUser(w, u, sel, false));
        }

        static HashSet<string> Select(Ctx c)
        {
            var s = c.Q("$select");
            return string.IsNullOrWhiteSpace(s) ? null : new HashSet<string>(s.Split(',').Select(x => x.Trim()), StringComparer.OrdinalIgnoreCase);
        }

        GraphResponse GetUser(Ctx c)
        {
            var u = ResolveUser(c.G("user"), false);
            var sel = Select(c);
            return JsonResponse(200, w => { w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#users/$entity"); WriteUserBody(w, u, sel); });
        }

        void WriteUserBody(Utf8JsonWriter w, FakeUser u, HashSet<string> sel)
        {
            Func<string, bool> on = f => sel == null ? (Array.IndexOf(DefaultUserFields, f) >= 0) : sel.Contains(f);
            if (on("id")) w.WriteString("id", u.Id);
            if (on("userPrincipalName")) w.WriteString("userPrincipalName", u.Upn);
            if (on("displayName")) w.WriteString("displayName", u.DisplayName);
            if (on("mail")) w.WriteString("mail", u.Mail);
            if (on("givenName")) w.WriteString("givenName", u.GivenName);
            if (on("surname")) w.WriteString("surname", u.Surname);
            if (on("jobTitle")) { if (u.JobTitle == null) w.WriteNull("jobTitle"); else w.WriteString("jobTitle", u.JobTitle); }
            if (sel != null && sel.Contains("userType")) w.WriteString("userType", u.UserType);
            if (sel != null && sel.Contains("accountEnabled")) w.WriteBoolean("accountEnabled", !u.Deleted);
        }

        GraphResponse ListDeletedUsers(Ctx c)
        {
            var list = Tenant.Users.Where(u => u.Deleted && !u.External).ToList();
            return OffsetList(c, "directoryObjects", list, PageSize(c, 100, 999, false), (w, u) => WriteUser(w, u, Select(c), true));
        }

        GraphResponse GetDeletedUser(Ctx c)
        {
            var u = Tenant.FindUser(c.G("user"));
            if (u == null || !u.Deleted || u.External) throw NotFound("Request_ResourceNotFound", "Resource '" + c.G("user") + "' does not exist in the deleted items.");
            return JsonResponse(200, w => { WriteUserBody(w, u, Select(c)); w.WriteString("deletedDateTime", FakeTime.Format(u.DeletedMs)); });
        }

        // ------------------------------------------------------------------ chats

        GraphResponse ListUserChats(Ctx c)
        {
            var u = ResolveUser(c.G("user"), false);
            List<FakeChat> src; if (!Tenant.ChatsByUser.TryGetValue(u.Ordinal, out src)) src = new List<FakeChat>();
            IEnumerable<FakeChat> q = src;
            foreach (var cl in ParseFilter(c.Q("$filter"), "createdDateTime"))
            {
                var cc = cl;
                if (cc.Prop.Equals("chatType", StringComparison.OrdinalIgnoreCase) && cc.Op == "eq") q = q.Where(x => x.TypeName.Equals(cc.Raw, StringComparison.OrdinalIgnoreCase));
                else if (cc.IsTime) q = q.Where(x => TimeOk(cc, x.CreatedMs));
                else throw Bad("Property '" + cc.Prop + "' is not supported in $filter on chats.");
            }
            bool expand = (c.Q("$expand") ?? "").IndexOf("members", StringComparison.OrdinalIgnoreCase) >= 0;
            return OffsetList(c, "chats", q.ToList(), PageSize(c, 50, 50, false), (w, ch) => WriteChat(w, ch, expand));
        }

        GraphResponse GetChat(Ctx c)
        {
            var ch = ResolveChat(c);
            bool expand = (c.Q("$expand") ?? "").IndexOf("members", StringComparison.OrdinalIgnoreCase) >= 0;
            return JsonResponse(200, w => { w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#chats/$entity"); WriteChatBody(w, ch, expand); });
        }

        void WriteChatBody(Utf8JsonWriter w, FakeChat ch, bool expand)
        {
            // WriteChat writes a whole object; re-emit its properties inline by writing to a nested buffer would copy, so write the same fields here.
            w.WriteString("id", ch.Id);
            if (ch.Topic == null) w.WriteNull("topic"); else w.WriteString("topic", ch.Topic);
            w.WriteString("createdDateTime", FakeTime.Format(ch.CreatedMs));
            w.WriteString("lastUpdatedDateTime", FakeTime.Format(Math.Max(ch.LastUpdatedMs, ch.CreatedMs)));
            w.WriteString("chatType", ch.TypeName);
            w.WriteString("webUrl", "https://teams.microsoft.com/l/chat/" + Uri.EscapeDataString(ch.Id) + "/0?tenantId=" + Tenant.TenantId);
            w.WriteString("tenantId", Tenant.TenantId);
            if (ch.MigrationMode != null) w.WriteString("migrationMode", ch.MigrationMode);
            if (ch.ChatType == FakeChatType.Meeting) { w.WriteStartObject("onlineMeetingInfo"); w.WriteString("joinWebUrl", ch.MeetingJoinUrl); w.WriteEndObject(); }
            if (expand) { w.WriteStartArray("members"); foreach (var m in ch.Members) WriteMember(w, ch.Ordinal, m); w.WriteEndArray(); }
        }

        GraphResponse ListChatMembers(Ctx c)
        {
            var ch = ResolveChat(c);
            return OffsetList(c, "chats('" + ch.Id + "')/members", ch.Members.ToList(), PageSize(c, 100, 999, false), (w, m) => WriteMember(w, ch.Ordinal, m));
        }

        FakeUser MemberUserFromBody(JsonElement e)
        {
            string id = Str(e, "userId");
            if (id == null)
            {
                var bind = Str(e, "user@odata.bind");
                if (bind != null) { var m = Regex.Match(bind, @"users(?:\('([^']+)'\)|/([^/?]+))", RegexOptions.IgnoreCase); if (m.Success) id = m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value; }
            }
            if (id == null) throw Bad("The member must carry user@odata.bind or userId.");
            var u = Tenant.FindUser(id);
            if (u == null || u.Deleted || u.External) throw NotFound("Request_ResourceNotFound", "Resource '" + id + "' does not exist or one of its queried reference-property objects are not present.");
            return u;
        }

        static string RolesOf(JsonElement e)
        {
            JsonElement r;
            if (e.TryGetProperty("roles", out r) && r.ValueKind == JsonValueKind.Array) return string.Join(",", r.EnumerateArray().Select(x => x.GetString()));
            return "";
        }

        static long HistoryStart(JsonElement e)
        {
            var s = Str(e, "visibleHistoryStartDateTime");
            if (s == null || s.StartsWith("0001-01-01")) return FakeMember.AllHistory;
            long ms; if (!FakeTime.TryParse(s, out ms)) throw Bad("Invalid visibleHistoryStartDateTime.");
            return ms;
        }

        GraphResponse CreateChat(Ctx c)
        {
            using (var doc = BodyDoc(c.Req))
            {
                var e = doc.RootElement;
                string type = Str(e, "chatType");
                JsonElement ms;
                if (type == null || !e.TryGetProperty("members", out ms) || ms.ValueKind != JsonValueKind.Array) throw Bad("chatType and members are required.");
                FakeChatType ct;
                if (type.Equals("oneOnOne", StringComparison.OrdinalIgnoreCase)) ct = FakeChatType.OneOnOne;
                else if (type.Equals("group", StringComparison.OrdinalIgnoreCase)) ct = FakeChatType.Group;
                else throw Bad("chatType must be oneOnOne or group.");
                var users = new List<FakeUser>(); var hist = new List<long>(); var roles = new List<string>();
                foreach (var m in ms.EnumerateArray())
                {
                    var u = MemberUserFromBody(m);
                    if (users.Contains(u)) continue;
                    users.Add(u); hist.Add(HistoryStart(m)); roles.Add(RolesOf(m));
                }
                if (ct == FakeChatType.OneOnOne && users.Count != 2) throw Bad("A oneOnOne chat needs exactly two distinct members.");
                if (ct == FakeChatType.Group && users.Count < 2) throw Bad("A group chat needs at least two members.");
                if (ct == FakeChatType.OneOnOne)
                {
                    FakeChat existing;
                    if (Tenant.OneOnOneByPair.TryGetValue(FakeTenant.PairKey(users[0].Ordinal, users[1].Ordinal), out existing))
                        return JsonResponse(201, w => WriteChatBody(w, existing, false));
                }
                long created = Tenant.NowMs;
                string cs = Str(e, "createdDateTime");
                if (cs != null) { if (!FakeTime.TryParse(cs, out created)) throw Bad("Invalid createdDateTime."); if (created > Tenant.NowMs) throw Bad("createdDateTime cannot be in the future."); }
                var chat = Tenant.AddChatMs(ct, users, Str(e, "topic"), created, "fr");
                for (int i = 0; i < users.Count; i++) { chat.Members[i].VisibleHistoryStartMs = hist[i]; chat.Members[i].Roles = roles[i]; }
                return JsonResponse(201, w => WriteChatBody(w, chat, false));
            }
        }

        GraphResponse AddChatMember(Ctx c)
        {
            var ch = ResolveChat(c);
            using (var doc = BodyDoc(c.Req))
            {
                if (ch.ChatType == FakeChatType.OneOnOne) throw Bad("Members cannot be added to a oneOnOne chat.");
                var u = MemberUserFromBody(doc.RootElement);
                if (ch.Members.Any(x => x.UserOrd == u.Ordinal)) throw new FakeHttpException(409, "Conflict", "The user is already a member of the chat.");
                var m = Tenant.AttachMember(ch, u, HistoryStart(doc.RootElement), RolesOf(doc.RootElement));
                return JsonResponse(201, w => { w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#chats('" + ch.Id + "')/members/$entity"); WriteMemberBody(w, ch.Ordinal, m); });
            }
        }

        void WriteMemberBody(Utf8JsonWriter w, int threadOrd, FakeMember m)
        {
            var u = U(m.UserOrd);
            w.WriteString("@odata.type", "#microsoft.graph.aadUserConversationMember");
            w.WriteString("id", FakeTenant.MembershipId(threadOrd, m.UserOrd));
            w.WriteStartArray("roles"); if (!string.IsNullOrEmpty(m.Roles)) foreach (var r in m.Roles.Split(',')) w.WriteStringValue(r); w.WriteEndArray();
            w.WriteString("displayName", u.DisplayName);
            w.WriteString("visibleHistoryStartDateTime", m.VisibleHistoryStartMs == FakeMember.AllHistory ? "0001-01-01T00:00:00Z" : FakeTime.Format(m.VisibleHistoryStartMs));
            w.WriteString("userId", u.Id); w.WriteString("email", u.Mail); w.WriteString("tenantId", u.TenantId);
        }

        GraphResponse RemoveChatMember(Ctx c)
        {
            var ch = ResolveChat(c);
            if (ch.ChatType == FakeChatType.OneOnOne) throw Bad("Members cannot be removed from a oneOnOne chat.");
            var m = ch.Members.Find(x => FakeTenant.MembershipId(ch.Ordinal, x.UserOrd).Equals(c.G("mem"), StringComparison.OrdinalIgnoreCase));
            if (m == null) throw NotFound("NotFound", "Membership " + c.G("mem") + " was not found.");
            Tenant.DetachMember(ch, m.UserOrd);
            return EmptyResponse(204);
        }

        // ------------------------------------------------------------------ messages (read side)

        List<Clause> MessageFilter(Ctx c)
        {
            var f = ParseFilter(c.Q("$filter"), "lastModifiedDateTime", "createdDateTime");
            foreach (var cl in f) if (!cl.IsTime || cl.Op == "eq" || cl.Op == "ne") throw Bad("Only lastModifiedDateTime and createdDateTime with gt, ge, lt, le are supported in $filter on messages.");
            return f;
        }

        bool OrderByCreated(Ctx c)
        {
            var o = c.Q("$orderby");
            if (string.IsNullOrWhiteSpace(o)) return false;
            var m = Regex.Match(o.Trim(), @"^(lastModifiedDateTime|createdDateTime)\s+desc$", RegexOptions.IgnoreCase);
            if (!m.Success) throw Bad("Only '$orderby=lastModifiedDateTime desc' and '$orderby=createdDateTime desc' are supported on messages.");
            return m.Groups[1].Value.Equals("createdDateTime", StringComparison.OrdinalIgnoreCase);
        }

        Seq ThreadView(FakeThread th, int[] pos, bool byCreated)
        {
            if (!byCreated) return new ThreadSeq(th, pos, false);
            // createdDateTime desc: the same positions ordered by creation (Messages is already creation-ordered)
            var sorted = (int[])pos.Clone(); Array.Sort(sorted); Array.Reverse(sorted);
            return new ThreadSeq(th, sorted, true);
        }

        GraphResponse ListChatMessages(Ctx c)
        {
            var ch = ResolveChat(c);
            bool byCreated = OrderByCreated(c);
            var filter = MessageFilter(c);
            int[] all;
            if (byCreated) { all = new int[ch.Messages.Count]; for (int i = 0; i < all.Length; i++) all[all.Length - 1 - i] = i; }
            else all = ch.ByModified;
            var seq = byCreated ? (Seq)new ThreadSeq(ch, all, true) : new ThreadSeq(ch, all, false);
            return MessagePage(c, seq, filter, byCreated ? "createdDateTime" : "lastModifiedDateTime", PageSize(c, 20, 50, true), int.MaxValue, "chats('" + ch.Id + "')/messages", (w, th, m) => WriteMessage(w, th, m), false);
        }

        GraphResponse GetChatMessage(Ctx c)
        {
            var ch = ResolveChat(c);
            var m = ch.Find(MsgId(c.G("msg")));
            if (m == null) throw NotFound("NotFound", "Message " + c.G("msg") + " was not found.");
            return JsonResponse(200, w => { w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#chats('" + ch.Id + "')/messages/$entity"); WriteMessageBody(w, ch, m); });
        }

        void WriteMessageBody(Utf8JsonWriter w, FakeThread th, FakeMessage m)
        {
            // WriteMessage writes a complete object; for a single entity we reuse it through a scratch writer and splice the properties.
            using (var ms = new MemoryStream())
            {
                using (var tmp = new Utf8JsonWriter(ms)) WriteMessage(tmp, th, m);
                using (var d = JsonDocument.Parse(ms.ToArray()))
                    foreach (var p in d.RootElement.EnumerateObject()) p.WriteTo(w);
            }
        }

        bool IsEval(Ctx c)
        {
            var model = c.Q("model");
            return !(string.Equals(model, "A", StringComparison.OrdinalIgnoreCase) || string.Equals(model, "B", StringComparison.OrdinalIgnoreCase));
        }

        GraphResponse GetAllMessages(Ctx c, string key, IList<FakeThread> threads, string context)
        {
            bool eval = IsEval(c);
            var filter = MessageFilter(c);
            var seq = GetMerged(key, threads, false);
            return MessagePage(c, seq, filter, "lastModifiedDateTime", PageSize(c, 20, 50, true), eval ? Tenant.EvaluationModeMaxMessages : int.MaxValue, context, (w, th, m) => WriteMessage(w, th, m), eval);
        }

        GraphResponse UserGetAllMessages(Ctx c)
        {
            var u = ResolveUser(c.G("user"), false);
            List<FakeChat> src; if (!Tenant.ChatsByUser.TryGetValue(u.Ordinal, out src)) src = new List<FakeChat>();
            return GetAllMessages(c, "u:" + u.Id, src.Cast<FakeThread>().ToList(), "users('" + u.Id + "')/chats/getAllMessages");
        }

        GraphResponse TenantGetAllMessages(Ctx c)
        {
            return GetAllMessages(c, "chats", Tenant.Chats.Cast<FakeThread>().ToList(), "chats/getAllMessages");
        }

        FakeMessage FindForHosted(Ctx c, out FakeThread th)
        {
            long id = MsgId(c.G("rep") ?? c.G("msg"));
            if (c.G("chat") != null) th = ResolveChat(c);
            else { FakeTeam t; th = ResolveChannel(c, out t); }
            var m = th.Find(id);
            if (m == null) throw NotFound("NotFound", "Message " + id + " was not found.");
            return m;
        }

        GraphResponse ListHosted(Ctx c)
        {
            FakeThread th; var m = FindForHosted(c, out th);
            var list = m.X != null && m.X.Hosted != null ? m.X.Hosted : new FakeHostedContent[0];
            return JsonResponse(200, w =>
            {
                w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#hostedContents");
                w.WriteNumber("@odata.count", list.Length);
                w.WriteStartArray("value");
                foreach (var h in list) { w.WriteStartObject(); w.WriteString("id", h.Id); w.WriteNull("contentBytes"); w.WriteString("contentType", h.ContentType); w.WriteEndObject(); }
                w.WriteEndArray();
            });
        }

        GraphResponse GetHosted(Ctx c, bool value)
        {
            FakeThread th; var m = FindForHosted(c, out th);
            var h = m.X == null || m.X.Hosted == null ? null : m.X.Hosted.FirstOrDefault(x => x.Id == c.G("hid"));
            if (h == null) throw NotFound("NotFound", "Hosted content " + c.G("hid") + " was not found.");
            if (value) return BytesResponse(h.Bytes, h.ContentType);
            return JsonResponse(200, w => { w.WriteString("id", h.Id); w.WriteString("contentBytes", Convert.ToBase64String(h.Bytes)); w.WriteString("contentType", h.ContentType); });
        }

        // ------------------------------------------------------------------ teams and channels

        GraphResponse ListTeams(Ctx c, bool asGroup)
        {
            if (!asGroup && !Tenant.TeamsListEndpointEnabled) throw Bad("Resource not found for the segment 'teams'.");
            var f = c.Q("$filter");
            if (asGroup && !string.IsNullOrWhiteSpace(f) && f.IndexOf("resourceProvisioningOptions", StringComparison.OrdinalIgnoreCase) < 0)
                throw Bad("Only $filter=resourceProvisioningOptions/Any(x:x eq 'Team') is supported on groups in the fake.");
            return OffsetList(c, asGroup ? "groups" : "teams", Tenant.Teams, PageSize(c, 100, 999, false), (w, t) => WriteTeam(w, t, asGroup));
        }

        GraphResponse GetTeam(Ctx c)
        {
            var t = ResolveTeam(c);
            return JsonResponse(200, w =>
            {
                w.WriteString("@odata.context", GraphRoot + "/" + c.P.Version + "/$metadata#teams/$entity");
                using (var ms = new MemoryStream())
                {
                    using (var tmp = new Utf8JsonWriter(ms)) WriteTeam(tmp, t, false);
                    using (var d = JsonDocument.Parse(ms.ToArray())) foreach (var p in d.RootElement.EnumerateObject()) p.WriteTo(w);
                }
            });
        }

        GraphResponse ListTeamMembers(Ctx c)
        {
            var t = ResolveTeam(c);
            return OffsetList(c, "teams('" + t.Id + "')/members", t.Members.ToList(), PageSize(c, 100, 999, false), (w, m) => WriteMember(w, 100000 + t.Ordinal, m));
        }

        GraphResponse CreateTeam(Ctx c)
        {
            using (var doc = BodyDoc(c.Req))
            {
                var e = doc.RootElement;
                string name = Str(e, "displayName");
                if (string.IsNullOrWhiteSpace(name)) throw Bad("displayName is required.");
                bool migration = string.Equals(Str(e, "@microsoft.graph.teamCreationMode"), "migration", StringComparison.OrdinalIgnoreCase);
                long created = Tenant.NowMs;
                string cs = Str(e, "createdDateTime");
                if (migration && cs == null) throw Bad("createdDateTime is required when creating a team in migration mode.");
                if (cs != null) { if (!FakeTime.TryParse(cs, out created)) throw Bad("Invalid createdDateTime."); if (created > Tenant.NowMs) throw Bad("createdDateTime cannot be in the future."); }
                var members = new List<FakeUser>();
                JsonElement ms;
                if (e.TryGetProperty("members", out ms) && ms.ValueKind == JsonValueKind.Array) foreach (var m in ms.EnumerateArray()) members.Add(MemberUserFromBody(m));
                var team = Tenant.AddTeam(name, members, FakeTime.FromMs(created), Str(e, "description"));
                var general = Tenant.AddChannel(team, "General", FakeChannelType.Standard, null, FakeTime.FromMs(created));
                if (migration)
                {
                    team.MigrationMode = "inProgress"; team.MigrationOwnerAppId = AppId(c);
                    general.MigrationMode = "inProgress"; general.MigrationOwnerAppId = AppId(c);
                }
                var r = EmptyResponse(202);
                r.Headers["Location"] = "/teams('" + team.Id + "')/operations('" + Tenant.NewGuid() + "')";
                r.Headers["Content-Location"] = "/teams('" + team.Id + "')";
                return r;
            }
        }

        GraphResponse ListChannels(Ctx c)
        {
            var t = ResolveTeam(c);
            IEnumerable<FakeChannel> q = t.Channels;
            foreach (var cl in ParseFilter(c.Q("$filter")))
            {
                var cc = cl;
                if (cc.Prop.Equals("membershipType", StringComparison.OrdinalIgnoreCase) && cc.Op == "eq") q = q.Where(x => x.TypeName.Equals(cc.Raw, StringComparison.OrdinalIgnoreCase));
                else throw Bad("Property '" + cc.Prop + "' is not supported in $filter on channels.");
            }
            return OffsetList(c, "teams('" + t.Id + "')/channels", q.ToList(), 999, (w, ch) => WriteChannel(w, ch));
        }

        GraphResponse GetChannel(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            return JsonResponse(200, w =>
            {
                using (var ms = new MemoryStream())
                {
                    using (var tmp = new Utf8JsonWriter(ms)) WriteChannel(tmp, ch);
                    using (var d = JsonDocument.Parse(ms.ToArray())) foreach (var p in d.RootElement.EnumerateObject()) p.WriteTo(w);
                }
            });
        }

        GraphResponse CreateChannel(Ctx c)
        {
            var team = ResolveTeam(c);
            using (var doc = BodyDoc(c.Req))
            {
                var e = doc.RootElement;
                string name = Str(e, "displayName");
                if (string.IsNullOrWhiteSpace(name)) throw Bad("displayName is required.");
                if (team.Channels.Any(x => x.DisplayName.Equals(name, StringComparison.OrdinalIgnoreCase))) throw new FakeHttpException(409, "NameAlreadyExists", "Channel name already existed.");
                string mt = Str(e, "membershipType") ?? "standard";
                FakeChannelType type = mt.Equals("private", StringComparison.OrdinalIgnoreCase) ? FakeChannelType.Private : mt.Equals("shared", StringComparison.OrdinalIgnoreCase) ? FakeChannelType.Shared : FakeChannelType.Standard;
                bool migration = string.Equals(Str(e, "@microsoft.graph.channelCreationMode"), "migration", StringComparison.OrdinalIgnoreCase);
                long created = Tenant.NowMs;
                string cs = Str(e, "createdDateTime");
                if (migration)
                {
                    if (team.MigrationMode != "inProgress") throw new FakeHttpException(403, "Forbidden", "A channel can be created in migration mode only in a team that is in migration mode.");
                    if (team.MigrationOwnerAppId != AppId(c)) throw new FakeHttpException(403, "Forbidden", "The migration of this team was started by another application.");
                    if (cs == null) throw Bad("createdDateTime is required when creating a channel in migration mode.");
                }
                if (cs != null) { if (!FakeTime.TryParse(cs, out created)) throw Bad("Invalid createdDateTime."); if (created > Tenant.NowMs) throw Bad("createdDateTime cannot be in the future."); }
                var members = new List<FakeUser>();
                JsonElement ms;
                if (e.TryGetProperty("members", out ms) && ms.ValueKind == JsonValueKind.Array) foreach (var m in ms.EnumerateArray()) members.Add(MemberUserFromBody(m));
                if (type != FakeChannelType.Standard && members.Count == 0) throw Bad("A private or shared channel needs at least one member (owner).");
                var ch = Tenant.AddChannel(team, name, type, members, FakeTime.FromMs(created), Str(e, "description"));
                if (migration) { ch.MigrationMode = "inProgress"; ch.MigrationOwnerAppId = AppId(c); }
                return JsonResponse(201, w =>
                {
                    using (var tmp = new MemoryStream())
                    {
                        using (var tw = new Utf8JsonWriter(tmp)) WriteChannel(tw, ch);
                        using (var d = JsonDocument.Parse(tmp.ToArray())) foreach (var p in d.RootElement.EnumerateObject()) p.WriteTo(w);
                    }
                });
            }
        }

        GraphResponse ListChannelMembers(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            var list = ch.ChannelType == FakeChannelType.Standard ? t.Members : ch.Members;
            int ord = 100000 + t.Ordinal * 1000 + ch.Ordinal;
            return OffsetList(c, "teams('" + t.Id + "')/channels('" + ch.Id + "')/members", list.ToList(), PageSize(c, 100, 999, false), (w, m) => WriteMember(w, ord, m));
        }

        GraphResponse AddChannelMember(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            if (ch.ChannelType == FakeChannelType.Standard) throw Bad("Members of a standard channel are the members of the team.");
            using (var doc = BodyDoc(c.Req))
            {
                var u = MemberUserFromBody(doc.RootElement);
                if (ch.Members.Any(x => x.UserOrd == u.Ordinal)) throw new FakeHttpException(409, "Conflict", "The user is already a member of the channel.");
                var m = new FakeMember { UserOrd = u.Ordinal, Roles = RolesOf(doc.RootElement) };
                ch.Members.Add(m);
                int ord = 100000 + t.Ordinal * 1000 + ch.Ordinal;
                return JsonResponse(201, w => WriteMemberBody(w, ord, m));
            }
        }

        GraphResponse TeamGetAllMessages(Ctx c)
        {
            var t = ResolveTeam(c);
            return GetAllMessages(c, "t:" + t.Id, t.Channels.Cast<FakeThread>().ToList(), "teams('" + t.Id + "')/channels/getAllMessages");
        }

        GraphResponse ListChannelMessages(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            bool byCreated = OrderByCreated(c);
            var filter = MessageFilter(c);
            int[] pos;
            if (byCreated) { var l = new List<int>(); for (int i = ch.Messages.Count - 1; i >= 0; i--) if (ch.Messages[i].ReplyTo == 0) l.Add(i); pos = l.ToArray(); }
            else pos = ch.Roots;
            return MessagePage(c, new ThreadSeq(ch, pos, byCreated), filter, byCreated ? "createdDateTime" : "lastModifiedDateTime", PageSize(c, 20, 50, true), int.MaxValue,
                "teams('" + t.Id + "')/channels('" + ch.Id + "')/messages", (w, th, m) => WriteMessage(w, th, m), false);
        }

        GraphResponse ListReplies(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            var root = ch.Find(MsgId(c.G("msg")));
            if (root == null || root.ReplyTo != 0) throw NotFound("NotFound", "Message " + c.G("msg") + " was not found.");
            bool byCreated = OrderByCreated(c);
            var filter = MessageFilter(c);
            var pos = ch.RepliesOf(root.Id);
            if (byCreated) { pos = (int[])pos.Clone(); Array.Sort(pos); Array.Reverse(pos); }
            return MessagePage(c, new ThreadSeq(ch, pos, byCreated), filter, byCreated ? "createdDateTime" : "lastModifiedDateTime", PageSize(c, 20, 50, true), int.MaxValue,
                "teams('" + t.Id + "')/channels('" + ch.Id + "')/messages('" + root.Id + "')/replies", (w, th, m) => WriteMessage(w, th, m), false);
        }

        GraphResponse GetChannelMessage(Ctx c, bool reply)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            var root = ch.Find(MsgId(c.G("msg")));
            if (root == null || root.ReplyTo != 0) throw NotFound("NotFound", "Message " + c.G("msg") + " was not found.");
            var m = root;
            if (reply)
            {
                m = ch.Find(MsgId(c.G("rep")));
                if (m == null || m.ReplyTo != root.Id) throw NotFound("NotFound", "Reply " + c.G("rep") + " was not found.");
            }
            return JsonResponse(200, w => WriteMessageBody(w, ch, m));
        }

        GraphResponse ChannelFilesFolder(Ctx c)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            var folder = Tenant.EnsureFolder(ch.Drive, "/" + ch.FolderName);
            return JsonResponse(200, w => WriteDriveItemBody(w, ch.Drive, folder));
        }

        // ------------------------------------------------------------------ migration (import) API

        GraphResponse StartMigration(Ctx c, FakeThread th)
        {
            using (var doc = BodyDoc(c.Req))
            {
                string s = Str(doc.RootElement, "conversationCreationDateTime");
                if (s == null) throw Bad("conversationCreationDateTime is required.");
                long ms; if (!FakeTime.TryParse(s, out ms)) throw Bad("Invalid conversationCreationDateTime.");
                string app = AppId(c);
                if (th.MigrationMode == "inProgress")
                {
                    if (th.MigrationOwnerAppId != app) throw new FakeHttpException(403, "Forbidden", "The migration of this conversation was started by another application.");
                    throw Bad("The conversation is already in migration mode.");
                }
                if (th.MigrationMode == "completed") throw Bad("The migration of this conversation is completed; it cannot be started again.");
                if (ms >= th.CreatedMs) throw Bad("conversationCreationDateTime must be earlier than the current createdDateTime of the conversation.");
                if (ms > Tenant.NowMs) throw Bad("conversationCreationDateTime cannot be in the future.");
                th.CreatedMs = ms; th.MigrationMode = "inProgress"; th.MigrationOwnerAppId = app; th.Touch();
                return EmptyResponse(204);
            }
        }

        GraphResponse CompleteMigration(Ctx c, FakeThread th)
        {
            if (th.MigrationMode != "inProgress") throw Bad("The conversation is not in migration mode.");
            if (th.MigrationOwnerAppId != AppId(c)) throw new FakeHttpException(403, "Forbidden", "The migration of this conversation was started by another application.");
            th.MigrationMode = "completed"; th.Touch();
            return EmptyResponse(204);
        }

        GraphResponse CompleteTeamMigration(Ctx c)
        {
            var t = ResolveTeam(c);
            if (t.MigrationMode != "inProgress") throw Bad("The team is not in migration mode.");
            if (t.MigrationOwnerAppId != AppId(c)) throw new FakeHttpException(403, "Forbidden", "The migration of this team was started by another application.");
            if (t.Channels.Any(x => x.MigrationMode == "inProgress")) throw Bad("Complete the migration of every channel before completing the team.");
            t.MigrationMode = "completed";
            return EmptyResponse(204);
        }

        GraphResponse PostChatMessage(Ctx c)
        {
            var ch = ResolveChat(c);
            return ImportMessage(c, ch, null, id => "chats/" + ch.Id + "/messages/" + id);
        }

        GraphResponse PostChannelMessage(Ctx c, bool reply)
        {
            FakeTeam t; var ch = ResolveChannel(c, out t);
            FakeMessage root = null;
            string bp = "teams/" + t.Id + "/channels/" + ch.Id + "/messages/";
            if (reply)
            {
                root = ch.Find(MsgId(c.G("msg")));
                if (root == null || root.ReplyTo != 0) throw NotFound("NotFound", "Message " + c.G("msg") + " was not found.");
                return ImportMessage(c, ch, root, id => bp + root.Id + "/replies/" + id);
            }
            return ImportMessage(c, ch, null, id => bp + id);
        }

        GraphResponse ImportMessage(Ctx c, FakeThread th, FakeMessage root, Func<long, string> msgPath)
        {
            string app = AppId(c);
            using (var doc = BodyDoc(c.Req))
            {
                var e = doc.RootElement;
                if (th.MigrationMode != "inProgress")
                    throw new FakeHttpException(403, "Forbidden", th.MigrationMode == "completed"
                        ? "The migration of this conversation is completed; messages can no longer be imported."
                        : Has(e, "createdDateTime") ? "createdDateTime can only be set while the conversation is in migration mode (call startMigration first)."
                                                    : "Application permissions can only post to a conversation that is in migration mode.");
                if (th.MigrationOwnerAppId != app) throw new FakeHttpException(403, "Forbidden", "The migration of this conversation was started by another application.");
                string cs = Str(e, "createdDateTime");
                if (cs == null) throw Bad("createdDateTime is required in migration mode.");
                long created; if (!FakeTime.TryParse(cs, out created)) throw Bad("Invalid createdDateTime '" + cs + "'.");
                if (created > Tenant.NowMs) throw Bad("createdDateTime cannot be in the future.");
                if (created < th.CreatedMs) throw Bad("createdDateTime cannot be earlier than the creation of the conversation.");
                if (root != null && created <= root.CreatedMs) throw Bad("A reply must be created after its root message.");
                if (th.IndexOf(created) >= 0) throw Bad("A message with this createdDateTime already exists in the conversation (createdDateTime must be unique per thread at millisecond precision).");

                // author
                JsonElement from, fu, fa;
                int authorOrd = -1; string fromApp = null;
                if (!e.TryGetProperty("from", out from) || from.ValueKind != JsonValueKind.Object) throw Bad("from is required in migration mode.");
                if (from.TryGetProperty("user", out fu) && fu.ValueKind == JsonValueKind.Object)
                {
                    var id = Str(fu, "id");
                    var au = id == null ? null : Tenant.FindUser(id);
                    if (au == null) throw Bad("The author '" + id + "' was not found.");
                    if (au.External) throw Bad("A federated (external tenant) user cannot be the author of an imported message.");
                    if (au.Deleted && !Tenant.DeletedAuthorsAccepted) throw Bad("The author '" + id + "' is a deleted account.");
                    authorOrd = au.Ordinal;
                }
                else if (from.TryGetProperty("application", out fa) && fa.ValueKind == JsonValueKind.Object) fromApp = (Str(fa, "id") ?? "bot") + "|" + (Str(fa, "displayName") ?? "Bot");
                else throw Bad("from.user.id is required in migration mode.");

                // body
                string content = ""; bool isText = false;
                JsonElement body;
                if (e.TryGetProperty("body", out body) && body.ValueKind == JsonValueKind.Object)
                {
                    content = Str(body, "content") ?? "";
                    isText = string.Equals(Str(body, "contentType"), "text", StringComparison.OrdinalIgnoreCase);
                }
                if (Encoding.UTF8.GetByteCount(content) > Tenant.MaxBodyBytes) throw Bad("The message body is too large (" + Encoding.UTF8.GetByteCount(content) + " bytes, maximum " + Tenant.MaxBodyBytes + ").");

                // hosted contents
                var hosted = new List<FakeHostedContent>(); var map = new Dictionary<string, string>();
                JsonElement hc;
                if (e.TryGetProperty("hostedContents", out hc) && hc.ValueKind == JsonValueKind.Array)
                {
                    int k = 0;
                    foreach (var h in hc.EnumerateArray())
                    {
                        string tmp = Str(h, "@microsoft.graph.temporaryId") ?? (k + 1).ToString();
                        byte[] bytes;
                        try { bytes = Convert.FromBase64String(Str(h, "contentBytes") ?? ""); } catch (FormatException) { throw Bad("hostedContents[" + k + "].contentBytes is not valid base64."); }
                        string hid = Hosted(created, k++);
                        hosted.Add(new FakeHostedContent { Id = hid, ContentType = Str(h, "contentType") ?? "image/png", Bytes = bytes });
                        map[tmp] = hid;
                    }
                }
                foreach (Match rm in Regex.Matches(content, @"\.\./hostedContents/([^/""'\s]+)/\$value"))
                    if (!map.ContainsKey(rm.Groups[1].Value)) throw Bad("The body references hosted content '" + rm.Groups[1].Value + "' that is not in hostedContents.");
                if (map.Count > 0)
                    content = Regex.Replace(content, @"\.\./hostedContents/([^/""'\s]+)/\$value", rm => GraphRoot + "/v1.0/" + msgPath(created) + "/hostedContents/" + map[rm.Groups[1].Value] + "/$value");

                // reactions
                var reactions = new List<FakeReaction>();
                JsonElement re;
                if (e.TryGetProperty("reactions", out re) && re.ValueKind == JsonValueKind.Array)
                {
                    if (re.GetArrayLength() > Tenant.MaxReactions) throw Bad("A message cannot have more than " + Tenant.MaxReactions + " reactions.");
                    foreach (var r in re.EnumerateArray())
                    {
                        string rt = Str(r, "reactionType"); if (rt == null) throw Bad("reactionType is required.");
                        JsonElement ru, ruu; int uo = -1;
                        if (r.TryGetProperty("user", out ru) && ru.TryGetProperty("user", out ruu))
                        {
                            var rid = Str(ruu, "id"); var rUser = rid == null ? null : Tenant.FindUser(rid);
                            if (rUser == null) throw Bad("The reaction user '" + rid + "' was not found.");
                            uo = rUser.Ordinal;
                        }
                        long rms = created;
                        var rcs = Str(r, "createdDateTime"); if (rcs != null && !FakeTime.TryParse(rcs, out rms)) throw Bad("Invalid reaction createdDateTime.");
                        reactions.Add(new FakeReaction { Type = rt, UserOrd = uo, CreatedMs = rms });
                    }
                }

                // mentions
                var mentions = new List<FakeMention>();
                JsonElement me;
                if (e.TryGetProperty("mentions", out me) && me.ValueKind == JsonValueKind.Array)
                    foreach (var mn in me.EnumerateArray())
                    {
                        var fm = new FakeMention { Id = mn.TryGetProperty("id", out var idv) && idv.ValueKind == JsonValueKind.Number ? idv.GetInt32() : mentions.Count, Text = Str(mn, "mentionText") ?? "" };
                        JsonElement md, mdu, mdc;
                        if (mn.TryGetProperty("mentioned", out md))
                        {
                            if (md.TryGetProperty("user", out mdu) && mdu.ValueKind == JsonValueKind.Object) { var mu = Tenant.FindUser(Str(mdu, "id") ?? ""); if (mu != null) fm.UserOrd = mu.Ordinal; }
                            else if (md.TryGetProperty("conversation", out mdc) && mdc.ValueKind == JsonValueKind.Object) { fm.Kind = Str(mdc, "conversationIdentityType") ?? "channel"; fm.TargetId = Str(mdc, "id"); fm.TargetName = Str(mdc, "displayName"); }
                        }
                        mentions.Add(fm);
                    }

                // attachments
                var atts = new List<FakeAttachment>();
                JsonElement at;
                if (e.TryGetProperty("attachments", out at) && at.ValueKind == JsonValueKind.Array)
                    foreach (var a in at.EnumerateArray())
                    {
                        // real service (lab 2026-11-10): the attachment id must be a GUID
                        string aid = Str(a, "id");
                        Guid ag;
                        if (aid != null && !Guid.TryParse(aid, out ag)) throw Bad("Invalid GUID '" + aid + "' for file attachment.");
                        atts.Add(new FakeAttachment { Id = aid ?? Tenant.NewGuid(), ContentType = Str(a, "contentType") ?? FakeAttachment.Reference, ContentUrl = Str(a, "contentUrl"), Name = Str(a, "name"), Content = Str(a, "content"), ThumbnailUrl = Str(a, "thumbnailUrl") }); }

                long modified = created;
                var mcs = Str(e, "lastModifiedDateTime");
                if (mcs != null) { if (!FakeTime.TryParse(mcs, out modified) || modified < created) throw Bad("lastModifiedDateTime must not be earlier than createdDateTime."); }
                var imp = Str(e, "importance");
                var msg = new FakeMessage { CreatedMs = created, ModifiedMs = modified, AuthorOrd = authorOrd, Flags = (byte)(FakeMessage.FlagImported | (isText ? FakeMessage.FlagText : 0)) };
                var x = msg.Ext();
                x.Body = content; x.ReplyTo = root == null ? 0 : root.CreatedMs; x.Subject = Str(e, "subject"); x.FromApplication = fromApp;
                if (imp == "high" || imp == "urgent") x.Importance = imp;
                if (hosted.Count > 0) x.Hosted = hosted.ToArray();
                if (reactions.Count > 0) x.Reactions = reactions.ToArray();
                if (mentions.Count > 0) x.Mentions = mentions.ToArray();
                if (atts.Count > 0) x.Attachments = atts.ToArray();
                var dts = Str(e, "deletedDateTime");
                if (dts != null) { long dms; if (!FakeTime.TryParse(dts, out dms)) throw Bad("Invalid deletedDateTime."); x.DeletedMs = dms; msg.Flags |= FakeMessage.FlagDeleted; if (msg.ModifiedMs < dms) msg.ModifiedMs = dms; }
                th.Add(msg);
                var chat = th as FakeChat; if (chat != null && modified > chat.LastUpdatedMs) chat.LastUpdatedMs = modified;
                Counters.Incr(ref Counters.ImportedMessages);
                return JsonResponse(201, w => WriteMessageBody(w, th, msg));
            }
        }

        // ------------------------------------------------------------------ drives

        void WriteDriveItemBody(Utf8JsonWriter w, FakeDrive d, FakeDriveItem it)
        {
            if (!it.IsFolder) w.WriteString("@microsoft.graph.downloadUrl", "https://" + DownloadHost + "/dl/" + Uri.EscapeDataString(d.Id) + "/" + it.Id);
            w.WriteString("id", it.Id); w.WriteString("name", it.Name); w.WriteNumber("size", it.Size);
            w.WriteString("webUrl", it.WebUrl);
            w.WriteString("createdDateTime", FakeTime.Format(it.CreatedMs)); w.WriteString("lastModifiedDateTime", FakeTime.Format(it.ModifiedMs));
            w.WriteString("eTag", it.ETag ?? "\"{" + it.Id.Substring(2, 8) + "},1\"");
            var cu = U(it.CreatedByOrd);
            foreach (var prop in new[] { "createdBy", "lastModifiedBy" })
            {
                w.WriteStartObject(prop);
                if (cu != null) { w.WriteStartObject("user"); w.WriteString("id", cu.Id); w.WriteString("displayName", cu.DisplayName); w.WriteString("email", cu.Mail); w.WriteEndObject(); }
                w.WriteEndObject();
            }
            w.WriteStartObject("parentReference");
            w.WriteString("driveId", d.Id); w.WriteString("driveType", d.DriveType);
            if (it.ParentId != null) w.WriteString("id", it.ParentId);
            w.WriteString("path", "/drives/" + d.Id + "/root:" + (it.FolderPath ?? ""));
            w.WriteEndObject();
            if (it.IsFolder) { w.WriteStartObject("folder"); w.WriteNumber("childCount", d.Items.Values.Count(x => x.ParentId == it.Id && !x.Deleted)); w.WriteEndObject(); }
            else { w.WriteStartObject("file"); w.WriteString("mimeType", it.ContentType); w.WriteEndObject(); }
        }

        FakeDrive ResolveDrive(Ctx c)
        {
            FakeDrive d;
            if (c.G("user") != null) return Tenant.UserDrive(ResolveUser(c.G("user"), false));
            if (c.G("team") != null && c.G("drive") == null) return ResolveTeam(c).Drive;
            if (!Tenant.Drives.TryGetValue(c.G("drive"), out d)) throw NotFound("itemNotFound", "The drive '" + c.G("drive") + "' was not found.");
            return d;
        }

        FakeDriveItem CheckItem(FakeDriveItem it, string what)
        {
            if (it == null || it.Deleted) throw NotFound("itemNotFound", "The resource could not be found" + (what == null ? "." : ": " + what));
            if (it.AccessDenied) throw new FakeHttpException(403, "accessDenied", "Access denied.");
            return it;
        }

        FakeDriveItem ResolveItem(Ctx c)
        {
            var d = ResolveDrive(c);
            FakeDriveItem it;
            string id = c.G("item");
            if (id.Equals("root", StringComparison.OrdinalIgnoreCase)) it = d.Root;
            else d.Items.TryGetValue(id, out it);
            return CheckItem(it, id);
        }

        GraphResponse GetDriveObject(Ctx c)
        {
            var d = ResolveDrive(c);
            return JsonResponse(200, w =>
            {
                w.WriteString("id", d.Id); w.WriteString("driveType", d.DriveType); w.WriteString("name", d.Name); w.WriteString("webUrl", d.WebUrlBase);
                var ou = U(d.OwnerUserOrd);
                if (ou != null) { w.WriteStartObject("owner"); w.WriteStartObject("user"); w.WriteString("id", ou.Id); w.WriteString("displayName", ou.DisplayName); w.WriteEndObject(); w.WriteEndObject(); }
            });
        }

        GraphResponse GetItem(Ctx c)
        {
            var d = ResolveDrive(c); var it = ResolveItem(c);
            return JsonResponse(200, w => WriteDriveItemBody(w, d, it));
        }

        GraphResponse GetItemContent(Ctx c)
        {
            var d = ResolveDrive(c); var it = ResolveItem(c);
            if (it.IsFolder) throw Bad("The item is a folder.");
            return StreamResponse(c, it.OpenRead(), it.Size, it.ContentType);
        }

        GraphResponse GetShare(Ctx c, bool content)
        {
            string s = c.G("share");
            if (!s.StartsWith("u!")) throw Bad("Invalid sharing token (expected u!<base64url>).");
            string url;
            try
            {
                string b = s.Substring(2).Replace('-', '+').Replace('_', '/'); while (b.Length % 4 != 0) b += "=";
                url = Encoding.UTF8.GetString(Convert.FromBase64String(b));
            }
            catch (FormatException) { throw Bad("Invalid sharing token."); }
            FakeDriveItem it;
            if (!Tenant.ItemsByUrl.TryGetValue(FakeTenant.NormUrl(url), out it)) throw NotFound("itemNotFound", "The sharing link does not resolve to an item.");
            CheckItem(it, null);
            var d = Tenant.Drives[it.DriveId];
            if (content) return StreamResponse(c, it.OpenRead(), it.Size, it.ContentType);
            return JsonResponse(200, w => WriteDriveItemBody(w, d, it));
        }

        string FullPath(FakeDriveItem it) { return (it.FolderPath ?? "") + "/" + it.Name; }

        GraphResponse GetByPath(Ctx c, string forced)
        {
            var d = ResolveDrive(c);
            string path = forced ?? FakeTenant.NormalizePath(c.G("path").TrimEnd(':'));
            FakeDriveItem it;
            d.ByPath.TryGetValue(path, out it);
            CheckItem(it, path);
            return JsonResponse(200, w => WriteDriveItemBody(w, d, it));
        }

        GraphResponse GetPathContent(Ctx c)
        {
            var d = ResolveDrive(c);
            FakeDriveItem it;
            d.ByPath.TryGetValue(FakeTenant.NormalizePath(c.G("path")), out it);
            CheckItem(it, c.G("path"));
            return StreamResponse(c, it.OpenRead(), it.Size, it.ContentType);
        }

        GraphResponse ListChildren(Ctx c)
        {
            var d = ResolveDrive(c); var it = ResolveItem(c);
            var list = d.Items.Values.Where(x => x.ParentId == it.Id && !x.Deleted).OrderBy(x => x.Name, StringComparer.Ordinal).ToList();
            return OffsetList(c, "drives('" + d.Id + "')/items('" + it.Id + "')/children", list, PageSize(c, 200, 999, false), (w, x) => { w.WriteStartObject(); WriteDriveItemBody(w, d, x); w.WriteEndObject(); });
        }

        void WritePermission(Utf8JsonWriter w, FakePermission p)
        {
            w.WriteStartObject();
            w.WriteString("id", p.Id);
            w.WriteStartArray("roles"); foreach (var r in p.Roles) w.WriteStringValue(r); w.WriteEndArray();
            if (p.LinkUrl != null) { w.WriteStartObject("link"); w.WriteString("type", p.LinkType); w.WriteString("scope", p.LinkScope); w.WriteString("webUrl", p.LinkUrl); w.WriteEndObject(); }
            else
            {
                w.WriteStartObject("grantedToV2"); w.WriteStartObject("user");
                var u = U(p.UserOrd);
                if (u != null) { w.WriteString("id", u.Id); w.WriteString("displayName", u.DisplayName); }
                w.WriteString("email", u != null ? u.Mail : p.Email);
                w.WriteEndObject(); w.WriteEndObject();
            }
            w.WriteEndObject();
        }

        GraphResponse ListPermissions(Ctx c)
        {
            var it = ResolveItem(c);
            return JsonResponse(200, w => { w.WriteStartArray("value"); foreach (var p in it.Permissions) WritePermission(w, p); w.WriteEndArray(); });
        }

        GraphResponse Invite(Ctx c)
        {
            var it = ResolveItem(c);
            using (var doc = BodyDoc(c.Req))
            {
                var e = doc.RootElement;
                JsonElement rs, rl;
                if (!e.TryGetProperty("recipients", out rs) || rs.ValueKind != JsonValueKind.Array || rs.GetArrayLength() == 0) throw new FakeHttpException(400, "invalidRequest", "recipients is required.");
                var roles = new List<string>();
                if (e.TryGetProperty("roles", out rl) && rl.ValueKind == JsonValueKind.Array) foreach (var r in rl.EnumerateArray()) roles.Add(r.GetString());
                if (roles.Count == 0) roles.Add("read");
                var created = new List<FakePermission>();
                foreach (var rc in rs.EnumerateArray())
                {
                    FakeUser u = null; string mail = Str(rc, "email");
                    string oid = Str(rc, "objectId");
                    if (oid != null) { u = Tenant.FindUser(oid); if (u == null || u.Deleted) throw new FakeHttpException(404, "itemNotFound", "The recipient '" + oid + "' was not found."); }
                    else if (mail != null) { u = Tenant.FindUser(mail); if (u == null || u.Deleted) throw new FakeHttpException(400, "invalidRequest", "The recipient '" + mail + "' is not a known user."); }
                    else throw new FakeHttpException(400, "invalidRequest", "Each recipient needs an email or an objectId.");
                    created.Add(new FakePermission { Id = Tenant.NewGuid().Replace("-", ""), Roles = roles.ToArray(), UserOrd = u.Ordinal, Email = u.Mail });
                }
                foreach (var p in created) it.Permissions.Add(p);
                return JsonResponse(200, w => { w.WriteStartArray("value"); foreach (var p in created) WritePermission(w, p); w.WriteEndArray(); });
            }
        }

        GraphResponse CreateLink(Ctx c)
        {
            var it = ResolveItem(c);
            using (var doc = BodyDoc(c.Req))
            {
                string type = Str(doc.RootElement, "type") ?? "view", scope = Str(doc.RootElement, "scope") ?? "organization";
                var p = new FakePermission { Id = Tenant.NewGuid().Replace("-", ""), Roles = new[] { type == "edit" ? "write" : "read" }, LinkType = type, LinkScope = scope, LinkUrl = it.WebUrl + "?share=" + Tenant.NewGuid().Substring(0, 8) };
                it.Permissions.Add(p);
                return JsonResponse(201, w => { using (var ms = new MemoryStream()) { using (var tw = new Utf8JsonWriter(ms)) WritePermission(tw, p); using (var d = JsonDocument.Parse(ms.ToArray())) foreach (var pr in d.RootElement.EnumerateObject()) pr.WriteTo(w); } });
            }
        }

        // ---- uploads

        sealed class UploadSession
        {
            public string Id, FolderPath, Name, Conflict; public FakeDrive Drive;
            public long Total = -1, Next; public IncrementalHash Hash; public MemoryStream Retained;
        }

        readonly Dictionary<string, UploadSession> _sessions = new Dictionary<string, UploadSession>();
        const int FragmentMultiple = 327680;
        const long MaxFragment = 60L * 1024 * 1024;

        GraphResponse CreateUploadSession(Ctx c)
        {
            var d = ResolveDrive(c);
            string folder, name;
            if (c.G("item") != null)
            {
                FakeDriveItem parent; d.Items.TryGetValue(c.G("item"), out parent);
                CheckItem(parent, c.G("item"));
                string pfull = parent == d.Root ? "" : FullPath(parent);
                string rel = c.G("name");
                int cut = rel.LastIndexOf('/');
                folder = cut < 0 ? (pfull == "" ? "/" : pfull) : pfull + "/" + rel.Substring(0, cut); name = rel.Substring(cut + 1);
            }
            else
            {
                string full = FakeTenant.NormalizePath(c.G("path"));
                int cut = full.LastIndexOf('/');
                folder = cut <= 0 ? "/" : full.Substring(0, cut); name = full.Substring(cut + 1);
            }
            string conflict = "replace";
            if (!string.IsNullOrWhiteSpace(BodyText(c.Req)))
                using (var doc = BodyDoc(c.Req))
                {
                    JsonElement item;
                    if (doc.RootElement.TryGetProperty("item", out item)) conflict = Str(item, "@microsoft.graph.conflictBehavior") ?? conflict;
                }
            string full2 = folder == "/" ? "/" + name : folder + "/" + name;
            if (conflict == "fail" && d.ByPath.ContainsKey(full2)) throw new FakeHttpException(409, "nameAlreadyExists", "The specified item name already exists.");
            var s = new UploadSession { Id = Tenant.NewGuid().Replace("-", ""), Drive = d, FolderPath = folder, Name = name, Conflict = conflict, Hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256), Retained = new MemoryStream() };
            _sessions[s.Id] = s;
            return JsonResponse(200, w =>
            {
                w.WriteString("uploadUrl", "https://" + UploadHost + "/up/" + s.Id);
                w.WriteString("expirationDateTime", FakeTime.Format(Tenant.NowMs + 7L * 86400000));
                w.WriteStartArray("nextExpectedRanges"); w.WriteStringValue("0-"); w.WriteEndArray();
            });
        }

        UploadSession Session(Ctx c)
        {
            UploadSession s;
            if (!_sessions.TryGetValue(c.G("sid"), out s)) throw NotFound("itemNotFound", "The upload session was not found or has expired.");
            return s;
        }

        GraphResponse UploadStatus(Ctx c)
        {
            var s = Session(c);
            return JsonResponse(200, w => { w.WriteString("expirationDateTime", FakeTime.Format(Tenant.NowMs + 86400000)); w.WriteStartArray("nextExpectedRanges"); w.WriteStringValue(s.Next + "-"); w.WriteEndArray(); });
        }

        GraphResponse UploadCancel(Ctx c)
        {
            var s = Session(c);
            _sessions.Remove(s.Id); s.Hash.Dispose();
            return EmptyResponse(204);
        }

        static byte[] ReadAll(GraphRequest r)
        {
            if (r.BodyBytes != null) return r.BodyBytes;
            if (r.BodyStream != null) { using (var ms = new MemoryStream()) { r.BodyStream.CopyTo(ms); return ms.ToArray(); } }
            if (r.BodyJson != null) return Encoding.UTF8.GetBytes(r.BodyJson);
            return new byte[0];
        }

        GraphResponse UploadFragment(Ctx c)
        {
            var s = Session(c);
            var cr = c.Header("Content-Range");
            var m = cr == null ? null : Regex.Match(cr, @"^bytes\s+(\d+)-(\d+)/(\d+)$", RegexOptions.IgnoreCase);
            if (m == null || !m.Success) throw new FakeHttpException(400, "invalidRange", "A valid Content-Range header (bytes a-b/total) is required.");
            long a = long.Parse(m.Groups[1].Value), b = long.Parse(m.Groups[2].Value), total = long.Parse(m.Groups[3].Value);
            if (b < a || b >= total) throw new FakeHttpException(400, "invalidRange", "The Content-Range is inconsistent.");
            if (s.Total >= 0 && s.Total != total) throw new FakeHttpException(400, "invalidRange", "The total size changed between fragments.");
            if (a != s.Next) throw new FakeHttpException(416, "invalidRange", "The fragment does not start at the next expected byte (" + s.Next + ").");
            long len = b - a + 1;
            bool last = b + 1 == total;
            if (len > MaxFragment) throw new FakeHttpException(400, "invalidRange", "A fragment cannot exceed 60 MiB.");
            if (!last && len % FragmentMultiple != 0) throw new FakeHttpException(400, "invalidRange", "Fragment sizes must be a multiple of 320 KiB (327,680 bytes), except the last one.");
            var data = ReadAll(c.Req);
            if (data.Length != len) throw new FakeHttpException(400, "invalidRange", "The body length (" + data.Length + ") does not match the Content-Range (" + len + ").");
            Counters.Received(data.Length);
            s.Total = total; s.Hash.AppendData(data); s.Next = b + 1;
            if (s.Retained != null) { if (s.Next <= Tenant.MaxRetainedUploadBytes) s.Retained.Write(data, 0, data.Length); else { s.Retained = null; } }
            if (!last)
                return JsonResponse(202, w => { w.WriteString("expirationDateTime", FakeTime.Format(Tenant.NowMs + 86400000)); w.WriteStartArray("nextExpectedRanges"); w.WriteStringValue(s.Next + "-"); w.WriteEndArray(); });
            _sessions.Remove(s.Id);
            string sha = Convert.ToHexString(s.Hash.GetHashAndReset()).ToLowerInvariant(); s.Hash.Dispose();
            string full = s.FolderPath == "/" ? "/" + s.Name : s.FolderPath + "/" + s.Name;
            string name = s.Name;
            bool existed = s.Drive.ByPath.ContainsKey(full);
            if (existed && s.Conflict == "fail") throw new FakeHttpException(409, "nameAlreadyExists", "The specified item name already exists.");
            if (existed && s.Conflict == "rename") { int n = 1; string ext = Path.GetExtension(name), stem = Path.GetFileNameWithoutExtension(name); do { name = stem + " " + n++ + ext; full = (s.FolderPath == "/" ? "" : s.FolderPath) + "/" + name; } while (s.Drive.ByPath.ContainsKey(full)); existed = false; }
            FakeDriveItem it = StoreUpload(s.Drive, s.FolderPath, name, total, s.Retained != null ? s.Retained.ToArray() : null, sha);
            return JsonResponse(existed ? 200 : 201, w => WriteDriveItemBody(w, s.Drive, it));
        }

        FakeDriveItem StoreUpload(FakeDrive d, string folder, string name, long size, byte[] bytes, string sha)
        {
            ulong seed = 0;
            if (bytes == null) seed = BitConverter.ToUInt64(Convert.FromHexString(sha.Substring(0, 16)), 0);
            var it = Tenant.AddFileCore(d, folder, name, size, seed, bytes, null, Tenant.NowMs, null);
            if (bytes == null) it.UploadedSha256 = sha;
            return it;
        }

        GraphResponse SimpleUpload(Ctx c)
        {
            var d = ResolveDrive(c);
            string full = FakeTenant.NormalizePath(c.G("path"));
            int cut = full.LastIndexOf('/');
            string folder = cut <= 0 ? "/" : full.Substring(0, cut), name = full.Substring(cut + 1);
            var data = ReadAll(c.Req);
            if (data.Length > 250L * 1024 * 1024) throw new FakeHttpException(413, "requestEntityTooLarge", "Use an upload session above 250 MB.");
            Counters.Received(data.Length);
            bool existed = d.ByPath.ContainsKey(full);
            string sha;
            using (var h = SHA256.Create()) sha = Convert.ToHexString(h.ComputeHash(data)).ToLowerInvariant();
            var it = StoreUpload(d, folder, name, data.Length, data, sha);
            return JsonResponse(existed ? 200 : 201, w => WriteDriveItemBody(w, d, it));
        }

        // ------------------------------------------------------------------ $batch

        async Task<GraphResponse> BatchAsync(Ctx c)
        {
            using (var doc = BodyDoc(c.Req))
            {
                JsonElement reqs;
                if (!doc.RootElement.TryGetProperty("requests", out reqs) || reqs.ValueKind != JsonValueKind.Array) throw Bad("The batch body must contain a requests array.");
                if (reqs.GetArrayLength() > 20) throw Bad("Batch request has more than 20 requests (maximum 20).");
                var results = new List<Tuple<string, int, Dictionary<string, string>, byte[], string>>();
                var ids = new HashSet<string>();
                foreach (var r in reqs.EnumerateArray())
                {
                    string id = Str(r, "id") ?? ""; string method = Str(r, "method") ?? "GET"; string url = Str(r, "url") ?? "";
                    if (id == "" || !ids.Add(id)) throw Bad("Each batch request needs a unique id.");
                    var g = new GraphRequest { Method = new HttpMethod(method.ToUpperInvariant()), Url = "v1.0" + (url.StartsWith("/") ? url : "/" + url) };
                    g.Headers["X-Fake-AppId"] = AppId(c);
                    JsonElement hs, bd;
                    if (r.TryGetProperty("headers", out hs) && hs.ValueKind == JsonValueKind.Object) foreach (var h in hs.EnumerateObject()) g.Headers[h.Name] = h.Value.GetString();
                    if (r.TryGetProperty("body", out bd) && bd.ValueKind != JsonValueKind.Null) g.BodyJson = bd.ValueKind == JsonValueKind.String ? bd.GetString() : bd.GetRawText();
                    GraphResponse inner;
                    if (url.TrimStart('/').StartsWith("$batch", StringComparison.OrdinalIgnoreCase)) inner = ErrorResponse(400, "BadRequest", "Batch requests cannot be nested.", c.RequestId, c.P, null);
                    else
                        try { inner = await ProcessAsync(g, c.Ct, true).ConfigureAwait(false); }
                        catch (HttpRequestException) { inner = ErrorResponse(504, "GatewayTimeout", "Connection reset inside the batch.", c.RequestId, c.P, null); }
                    byte[] payload;
                    using (inner) using (var ms = new MemoryStream()) { inner.Content.CopyTo(ms); payload = ms.ToArray(); }
                    var hd = new Dictionary<string, string>();
                    foreach (var kv in inner.Headers) if (kv.Key == "Retry-After" || kv.Key == "Content-Type" || kv.Key == "Location" || kv.Key == "Warning") hd[kv.Key] = kv.Value;
                    results.Add(Tuple.Create(id, inner.StatusCode, hd, payload, inner.ContentType));
                }
                return JsonResponse(200, w =>
                {
                    w.WriteStartArray("responses");
                    foreach (var rs in results)
                    {
                        w.WriteStartObject();
                        w.WriteString("id", rs.Item1); w.WriteNumber("status", rs.Item2);
                        w.WriteStartObject("headers"); foreach (var kv in rs.Item3) w.WriteString(kv.Key, kv.Value); w.WriteEndObject();
                        if (rs.Item4.Length > 0)
                        {
                            w.WritePropertyName("body");
                            if (rs.Item5 != null && rs.Item5.IndexOf("json", StringComparison.OrdinalIgnoreCase) >= 0) w.WriteRawValue(rs.Item4);
                            else w.WriteStringValue(Convert.ToBase64String(rs.Item4));
                        }
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                });
            }
        }
    }
}
