// =============================================================================
//  TeamsTransfer - engine: Microsoft Graph transport and client
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.2
//
//  Two layers, on purpose:
//    HttpGraphTransport  - "dumb": one request in, one response out. One shared HttpClient (pooled connections,
//                          gzip/brotli), bearer token, client-request-id, response STREAMED (headers read, body
//                          left on the wire). No retry, no paging. FakeGraphTransport (tests/demo) replaces it.
//    GraphClient         - everything the engine actually uses: retry with Retry-After, jittered backoff, the
//                          adaptive rate limiter, @odata.nextLink paging that yields element by element and hands
//                          the next link to the caller BEFORE following it (page-level resume), streaming
//                          downloads, $batch. Because it only talks to IGraphTransport, the fake exercises the
//                          real retry/paging/throttling code.
//
//  Rules that follow from 100k users / billions of messages:
//    - memory is constant: a page is parsed, its elements are cloned and yielded, then the page is dropped;
//      a download is copied stream to stream and never buffered;
//    - nothing sensitive in logs: events carry the URL WITHOUT its query string (upload-session URLs carry a
//      token there), never headers, never bodies, never tokens;
//    - retries never replay a body that cannot be replayed (non-seekable stream), and a download restarts from
//      the position it started at (the destination is truncated first);
//    - NOTE for callers: a POST retried after a 5xx or a timeout may already have been executed by Graph. The
//      importer must be idempotent on its own (journal + unique createdDateTime), this layer cannot know.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    #region Transport

    /// <summary>Real transport over one shared HttpClient. No retry: that is GraphClient's job.</summary>
    public sealed class HttpGraphTransport : IGraphTransport, IDisposable
    {
        private readonly HttpClient _http;
        private readonly IAccessTokenProvider _tokens;
        private readonly string _root;
        private readonly string _rootHost;

        /// <param name="handler">Test seam. When null a pooled SocketsHttpHandler is created.</param>
        public HttpGraphTransport(IAccessTokenProvider tokens, GraphCloud cloud = GraphCloud.Global,
            int maxConnectionsPerServer = 64, HttpMessageHandler handler = null)
        {
            _tokens = tokens;
            _root = GraphCloudEndpoints.GraphRoot(cloud).TrimEnd('/');
            _rootHost = new Uri(_root).Host;
            if (handler == null)
            {
                handler = new SocketsHttpHandler
                {
                    MaxConnectionsPerServer = Math.Max(1, maxConnectionsPerServer),
                    AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
                    PooledConnectionLifetime = TimeSpan.FromMinutes(5),
                    PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
                    EnableMultipleHttp2Connections = true,
                    AllowAutoRedirect = true,
                    ConnectTimeout = TimeSpan.FromSeconds(30)
                };
            }
            // Timeouts are enforced per attempt by GraphClient; a download may legitimately last hours.
            _http = new HttpClient(handler, true) { Timeout = Timeout.InfiniteTimeSpan };
        }

        public void Dispose() { _http.Dispose(); }

        private Uri Resolve(GraphRequest r)
        {
            if (string.IsNullOrWhiteSpace(r.Url)) throw new ArgumentException("GraphRequest.Url is required");
            Uri abs;
            if (Uri.TryCreate(r.Url, UriKind.Absolute, out abs) && (abs.Scheme == Uri.UriSchemeHttps || abs.Scheme == Uri.UriSchemeHttp))
            {
                // Never send the bearer token to a host that is not Graph (a hostile or corrupted nextLink).
                if (!r.Anonymous && !string.Equals(abs.Host, _rootHost, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Refusing to send credentials to a host other than the Graph endpoint: " + abs.Host);
                return abs;
            }
            return new Uri(_root + "/" + r.Url.TrimStart('/'));
        }

        /// <summary>
        /// Sends once; on a 401 for an authenticated request, asks the provider to drop the rejected token and resends ONCE with a
        /// fresh one (token revoked, CAE, clock skew). Only when the body is replayable. A second 401 is returned as is.
        /// Concurrent 401s carrying the same rejected token cause a single refresh (the provider ignores stale invalidations).
        /// </summary>
        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            string token = request.Anonymous ? null : await _tokens.GetTokenAsync(cancellationToken).ConfigureAwait(false);
            long bodyStart = request.BodyStream != null && request.BodyStream.CanSeek ? request.BodyStream.Position : -1;
            var resp = await SendOnceAsync(request, token, cancellationToken).ConfigureAwait(false);
            var inv = _tokens as IInvalidatableTokenProvider;
            bool replayable = request.BodyStream == null || bodyStart >= 0;
            if (resp.StatusCode != 401 || request.Anonymous || inv == null || !replayable) return resp;
            resp.Dispose();
            inv.InvalidateToken(token);
            token = await _tokens.GetTokenAsync(cancellationToken).ConfigureAwait(false);
            if (bodyStart >= 0) request.BodyStream.Position = bodyStart;
            return await SendOnceAsync(request, token, cancellationToken).ConfigureAwait(false);
        }

        private async Task<GraphResponse> SendOnceAsync(GraphRequest request, string token, CancellationToken cancellationToken)
        {
            var uri = Resolve(request);
            using (var msg = new HttpRequestMessage(request.Method ?? HttpMethod.Get, uri))
            {
                HttpContent content = null;
                if (request.BodyJson != null) content = new StringContent(request.BodyJson, Encoding.UTF8, "application/json");
                else if (request.BodyBytes != null) content = new ByteArrayContent(request.BodyBytes);
                else if (request.BodyStream != null) content = new StreamContent(new LeaveOpenStream(request.BodyStream));
                if (content != null)
                {
                    if (request.BodyJson == null && !string.IsNullOrEmpty(request.ContentType))
                        content.Headers.ContentType = MediaTypeHeaderValue.Parse(request.ContentType);
                    msg.Content = content;
                }

                foreach (var kv in request.Headers)
                {
                    if (!msg.Headers.TryAddWithoutValidation(kv.Key, kv.Value) && content != null)
                        content.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
                }
                msg.Headers.TryAddWithoutValidation("client-request-id", Guid.NewGuid().ToString());
                msg.Headers.TryAddWithoutValidation("return-client-request-id", "true");
                if (!request.Anonymous)
                {
                    msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                }

                HttpResponseMessage resp = await _http.SendAsync(msg, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
                try
                {
                    var result = new GraphResponse { StatusCode = (int)resp.StatusCode };
                    foreach (var h in resp.Headers) result.Headers[h.Key] = string.Join(", ", h.Value);
                    if (resp.Content != null)
                    {
                        foreach (var h in resp.Content.Headers) result.Headers[h.Key] = string.Join(", ", h.Value);
                        result.ContentType = resp.Content.Headers.ContentType?.ToString();
                        var body = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                        result.Content = new ResponseStream(body, resp);   // disposes the HttpResponseMessage with the stream
                    }
                    else resp.Dispose();
                    return result;
                }
                catch { resp.Dispose(); throw; }
            }
        }

        /// <summary>Request body wrapper: HttpClient disposes its content, the caller keeps ownership of the stream (retry).</summary>
        private sealed class LeaveOpenStream : Stream
        {
            private readonly Stream _s;
            public LeaveOpenStream(Stream s) { _s = s; }
            public override bool CanRead => _s.CanRead;
            public override bool CanSeek => _s.CanSeek;
            public override bool CanWrite => false;
            public override long Length => _s.Length;
            public override long Position { get => _s.Position; set => _s.Position = value; }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) => _s.Read(buffer, offset, count);
            public override int Read(Span<byte> buffer) => _s.Read(buffer);
            public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => _s.ReadAsync(buffer, ct);
            public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => _s.ReadAsync(buffer, offset, count, ct);
            public override long Seek(long offset, SeekOrigin origin) => _s.Seek(offset, origin);
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { /* intentionally leaves the inner stream open */ }
        }

        /// <summary>Response body wrapper that releases the HttpResponseMessage (and the pooled connection) on dispose.</summary>
        private sealed class ResponseStream : Stream
        {
            private readonly Stream _s;
            private readonly HttpResponseMessage _resp;
            public ResponseStream(Stream s, HttpResponseMessage resp) { _s = s; _resp = resp; }
            public override bool CanRead => _s.CanRead;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) => _s.Read(buffer, offset, count);
            public override int Read(Span<byte> buffer) => _s.Read(buffer);
            public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => _s.ReadAsync(buffer, ct);
            public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => _s.ReadAsync(buffer, offset, count, ct);
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing)
            {
                if (disposing) { _s.Dispose(); _resp.Dispose(); }
                base.Dispose(disposing);
            }
        }
    }

    #endregion

    #region Options, events, batch types

    public sealed class GraphClientOptions
    {
        /// <summary>Total attempts per request (first try included).</summary>
        public int MaxAttempts { get; set; } = 6;
        public TimeSpan BaseBackoff { get; set; } = TimeSpan.FromSeconds(1);
        public TimeSpan MaxBackoff { get; set; } = TimeSpan.FromSeconds(60);
        /// <summary>Per attempt: until the response headers (and, for JSON calls, the body). Not applied to streamed downloads.</summary>
        public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(100);
        /// <summary>getAllMessages requires model=B (since 25/08/2025 no billing); appended when missing.</summary>
        public string ExportModel { get; set; } = "B";
        /// <summary>Advisory: process-wide in-flight limit. Used by ToRateLimiterOptions().</summary>
        public int MaxConcurrency { get; set; } = 32;
        /// <summary>Where JSON batches are posted (relative to the Graph root).</summary>
        public string BatchEndpoint { get; set; } = "v1.0/$batch";
        public IClock Clock { get; set; } = SystemClock.Instance;
        /// <summary>Uniform random in [0,1) for the backoff jitter; replaced in tests.</summary>
        public Func<double> Random { get; set; } = () => System.Random.Shared.NextDouble();

        public RateLimiterOptions ToRateLimiterOptions()
        {
            return new RateLimiterOptions { MaxConcurrency = MaxConcurrency, Clock = Clock };
        }
    }

    public enum GraphEventKind { Request, Retry, Throttled, Error }

    /// <summary>What the client reports to logs and to the console. Never carries headers, bodies, tokens or a query string.</summary>
    public sealed class GraphEvent
    {
        public GraphEventKind Kind { get; set; }
        public DateTimeOffset Timestamp { get; set; }
        public string Method { get; set; }
        public string EndpointClass { get; set; }
        /// <summary>HTTP status, 0 for a network error or timeout.</summary>
        public int StatusCode { get; set; }
        /// <summary>Wait before the next attempt (Retry, Throttled).</summary>
        public TimeSpan Delay { get; set; }
        public int Attempt { get; set; }
        /// <summary>Request URL without the query string.</summary>
        public string Url { get; set; }
        /// <summary>Graph error code, or the exception type name for a network error.</summary>
        public string Message { get; set; }
    }

    public sealed class BatchItem
    {
        public string Id { get; set; }
        public string Method { get; set; } = "GET";
        /// <summary>Relative to the API version root, e.g. "/users/abc/chats".</summary>
        public string Url { get; set; }
        public string BodyJson { get; set; }
        public Dictionary<string, string> Headers { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Optional; Classify(Url) otherwise. Used to tell the limiter which class an item throttled.</summary>
        public string EndpointClass { get; set; }
    }

    public sealed class BatchResult
    {
        public string Id { get; set; }
        /// <summary>Status of the item; 0 when the batch answer did not contain it.</summary>
        public int StatusCode { get; set; }
        public Dictionary<string, string> Headers { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Raw JSON body of the item, null when none.</summary>
        public string Body { get; set; }
        public string ErrorCode { get; set; }
        public string ErrorMessage { get; set; }
        public int Attempts { get; set; }
        public bool IsSuccess => StatusCode >= 200 && StatusCode < 300;
        public JsonDocument ParseBody() { return string.IsNullOrEmpty(Body) ? null : JsonDocument.Parse(Body); }
    }

    #endregion

    #region Client

    public sealed class GraphClient
    {
        private readonly IGraphTransport _transport;
        private readonly GraphClientOptions _o;
        private readonly IRateLimiter _limiter;
        private readonly Action<GraphEvent> _onEvent;
        private readonly IClock _clock;

        public GraphClientOptions Options => _o;
        public IRateLimiter Limiter => _limiter;

        /// <param name="limiter">May be null (no pacing).</param>
        public GraphClient(IGraphTransport transport, GraphClientOptions options, IRateLimiter limiter, Action<GraphEvent> onEvent = null)
        {
            if (transport == null) throw new ArgumentNullException(nameof(transport));
            _transport = transport;
            _o = options ?? new GraphClientOptions();
            _limiter = limiter;
            _onEvent = onEvent;
            _clock = _o.Clock ?? SystemClock.Instance;
        }

        // ---------------------------------------------------------------- public API

        /// <summary>
        /// Sends a request with retry. Returns a successful (2xx) response whose body is NOT read: the caller disposes it.
        /// Non-retryable or exhausted failures throw GraphException.
        /// </summary>
        public Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken = default)
        {
            return ExecuteAsync<GraphResponse>(request, (r, t) => Task.FromResult(r), false, false, true, cancellationToken);
        }

        /// <summary>Sends any request and parses the JSON answer. Null when the answer has no body (204).</summary>
        public Task<JsonDocument> SendJsonAsync(GraphRequest request, CancellationToken cancellationToken = default)
        {
            return ExecuteAsync<JsonDocument>(request, ParseJsonAsync, true, true, true, cancellationToken);
        }

        public Task<JsonDocument> GetJsonAsync(string url, string endpointClass, string threadKey = null, CancellationToken cancellationToken = default)
        {
            var req = new GraphRequest { Method = HttpMethod.Get, Url = url, EndpointClass = endpointClass, ThreadKey = threadKey };
            return SendJsonAsync(req, cancellationToken);
        }

        public Task<JsonDocument> PostJsonAsync(string url, string json, string endpointClass, string threadKey = null, CancellationToken cancellationToken = default)
        {
            var req = new GraphRequest { Method = HttpMethod.Post, Url = url, BodyJson = json, EndpointClass = endpointClass, ThreadKey = threadKey };
            return SendJsonAsync(req, cancellationToken);
        }

        /// <summary>
        /// Streams the elements of "value" across @odata.nextLink pages; one page in memory at a time.
        /// onNextLink receives each next link BEFORE it is requested, i.e. once every element of the current page has been
        /// handed to the consumer: persist it as the checkpoint. To resume, pass the saved link as resumeFromNextLink
        /// (url is then ignored).
        /// </summary>
        public async IAsyncEnumerable<JsonElement> GetPagedAsync(string url, string endpointClass, Func<string, Task> onNextLink = null,
            string resumeFromNextLink = null, string threadKey = null, [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            string next = string.IsNullOrEmpty(resumeFromNextLink) ? WithExportModel(url) : resumeFromNextLink;
            while (next != null)
            {
                JsonDocument page = await GetJsonAsync(next, endpointClass, threadKey, cancellationToken).ConfigureAwait(false);
                if (page == null) yield break;
                string following = null;
                using (page)
                {
                    var root = page.RootElement;
                    JsonElement value;
                    if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("value", out value) && value.ValueKind == JsonValueKind.Array)
                        foreach (var el in value.EnumerateArray()) yield return el.Clone();
                    JsonElement nl;
                    if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("@odata.nextLink", out nl) && nl.ValueKind == JsonValueKind.String)
                        following = nl.GetString();
                }
                if (!string.IsNullOrEmpty(following) && onNextLink != null) await onNextLink(following).ConfigureAwait(false);
                next = string.IsNullOrEmpty(following) ? null : following;
            }
        }

        /// <summary>
        /// Copies the body to destination without buffering. A retry restarts the download: the destination is truncated
        /// back to where it started, so it must be seekable for any retry to happen.
        /// </summary>
        public async Task DownloadToStreamAsync(string url, Stream destination, string endpointClass, string threadKey = null,
            CancellationToken cancellationToken = default)
        {
            if (destination == null) throw new ArgumentNullException(nameof(destination));
            long startPos = destination.CanSeek ? destination.Position : -1;
            bool first = true;
            var req = new GraphRequest { Method = HttpMethod.Get, Url = url, EndpointClass = endpointClass, ThreadKey = threadKey };
            await ExecuteAsync<bool>(req, async (resp, ct) =>
            {
                if (!first && startPos >= 0)
                {
                    destination.SetLength(startPos);
                    destination.Position = startPos;
                }
                first = false;
                await resp.Content.CopyToAsync(destination, 81920, ct).ConfigureAwait(false);
                return true;
            }, true, false, destination.CanSeek, cancellationToken).ConfigureAwait(false);
        }

        // ---------------------------------------------------------------- $batch

        public const int MaxBatchSize = 20;

        /// <summary>
        /// Runs the items through JSON $batch (20 per call, split automatically). Items answered 429/503 are resent in a
        /// later batch after their Retry-After, up to MaxAttempts; the others are final. Results keep the input order.
        /// A failed item is reported in its result (not thrown); only a failure of the batch call itself throws.
        /// </summary>
        public async Task<IReadOnlyList<BatchResult>> BatchAsync(IReadOnlyList<BatchItem> items, CancellationToken cancellationToken = default)
        {
            if (items == null) throw new ArgumentNullException(nameof(items));
            var byId = new Dictionary<string, BatchResult>(StringComparer.Ordinal);
            var itemById = new Dictionary<string, BatchItem>(StringComparer.Ordinal);
            foreach (var it in items)
            {
                if (string.IsNullOrEmpty(it.Id)) throw new ArgumentException("Every BatchItem needs an Id.");
                if (itemById.ContainsKey(it.Id)) throw new ArgumentException("Duplicate BatchItem Id: " + it.Id);
                itemById[it.Id] = it;
            }

            var pending = new List<BatchItem>(items);
            for (int attempt = 1; pending.Count > 0; attempt++)
            {
                var throttled = new List<BatchItem>();
                TimeSpan? longest = null;
                for (int i = 0; i < pending.Count; i += MaxBatchSize)
                {
                    var chunk = pending.GetRange(i, Math.Min(MaxBatchSize, pending.Count - i));
                    var answers = await SendBatchChunkAsync(chunk, cancellationToken).ConfigureAwait(false);
                    foreach (var it in chunk)
                    {
                        BatchResult r;
                        if (!answers.TryGetValue(it.Id, out r))
                            r = new BatchResult { Id = it.Id, StatusCode = 0, ErrorCode = "MissingBatchResponse", ErrorMessage = "The batch answer did not contain this item." };
                        r.Attempts = attempt;
                        byId[it.Id] = r;
                        if ((r.StatusCode == 429 || r.StatusCode == 503) && attempt < _o.MaxAttempts)
                        {
                            throttled.Add(it);
                            string raw;
                            TimeSpan? ra = null;
                            if (r.Headers.TryGetValue("Retry-After", out raw)) ra = ParseRetryAfter(raw);
                            string cls = it.EndpointClass ?? Classify(it.Url);
                            _limiter?.OnThrottled(cls, ra);
                            Emit(GraphEventKind.Throttled, "POST", cls, r.StatusCode, ra ?? TimeSpan.Zero, attempt, it.Url, r.ErrorCode);
                            if (ra.HasValue && (!longest.HasValue || ra.Value > longest.Value)) longest = ra;
                        }
                    }
                }
                if (throttled.Count == 0) break;
                TimeSpan wait = longest ?? Backoff(attempt);
                await _clock.DelayAsync(wait, cancellationToken).ConfigureAwait(false);
                pending = throttled;
            }

            var ordered = new List<BatchResult>(items.Count);
            foreach (var it in items) ordered.Add(byId[it.Id]);
            return ordered;
        }

        private async Task<Dictionary<string, BatchResult>> SendBatchChunkAsync(List<BatchItem> chunk, CancellationToken ct)
        {
            var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                w.WriteStartArray("requests");
                foreach (var it in chunk)
                {
                    w.WriteStartObject();
                    w.WriteString("id", it.Id);
                    w.WriteString("method", it.Method ?? "GET");
                    w.WriteString("url", it.Url);
                    bool hasContentType = false;
                    foreach (var h in it.Headers) if (string.Equals(h.Key, "Content-Type", StringComparison.OrdinalIgnoreCase)) hasContentType = true;
                    if (it.Headers.Count > 0 || it.BodyJson != null)
                    {
                        w.WriteStartObject("headers");
                        foreach (var h in it.Headers) w.WriteString(h.Key, h.Value);
                        if (it.BodyJson != null && !hasContentType) w.WriteString("Content-Type", "application/json");
                        w.WriteEndObject();
                    }
                    if (it.BodyJson != null) { w.WritePropertyName("body"); w.WriteRawValue(it.BodyJson); }
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteEndObject();
            }
            var req = new GraphRequest
            {
                Method = HttpMethod.Post,
                Url = _o.BatchEndpoint,
                BodyJson = Encoding.UTF8.GetString(ms.ToArray()),
                EndpointClass = EndpointClass.Batch
            };
            var result = new Dictionary<string, BatchResult>(StringComparer.Ordinal);
            using (var doc = await SendJsonAsync(req, ct).ConfigureAwait(false))
            {
                JsonElement arr;
                if (doc == null || !doc.RootElement.TryGetProperty("responses", out arr) || arr.ValueKind != JsonValueKind.Array) return result;
                foreach (var e in arr.EnumerateArray())
                {
                    var r = new BatchResult { Id = e.GetProperty("id").ToString() };
                    JsonElement p;
                    if (e.TryGetProperty("status", out p) && p.ValueKind == JsonValueKind.Number) r.StatusCode = p.GetInt32();
                    if (e.TryGetProperty("headers", out p) && p.ValueKind == JsonValueKind.Object)
                        foreach (var h in p.EnumerateObject()) r.Headers[h.Name] = h.Value.ToString();
                    if (e.TryGetProperty("body", out p) && p.ValueKind != JsonValueKind.Null) r.Body = p.GetRawText();
                    if (r.StatusCode >= 400 && r.Body != null)
                    {
                        string code, msg;
                        ParseErrorBody(r.Body, out code, out msg);
                        r.ErrorCode = code; r.ErrorMessage = msg;
                    }
                    result[r.Id] = r;
                }
            }
            return result;
        }

        // ---------------------------------------------------------------- retry engine

        private static Task<JsonDocument> ParseJsonAsync(GraphResponse resp, CancellationToken ct)
        {
            return ParseJsonCoreAsync(resp, ct);
        }

        private static async Task<JsonDocument> ParseJsonCoreAsync(GraphResponse resp, CancellationToken ct)
        {
            if (resp.StatusCode == 204) return null;
            var ms = new MemoryStream();
            await resp.Content.CopyToAsync(ms, 81920, ct).ConfigureAwait(false);
            if (ms.Length == 0) return null;
            return JsonDocument.Parse(new ReadOnlyMemory<byte>(ms.GetBuffer(), 0, (int)ms.Length));
        }

        private static bool IsRetryableStatus(int s)
        {
            return s == 429 || s == 503 || s == 502 || s == 504 || s == 500;
        }

        private static bool IsTransient(Exception ex, CancellationToken callerToken)
        {
            if (ex is HttpRequestException || ex is IOException || ex is TimeoutException) return true;
            // Our per-attempt timeout cancels the linked token, not the caller's.
            if (ex is OperationCanceledException && !callerToken.IsCancellationRequested) return true;
            return false;
        }

        /// <summary>Delay in [BaseBackoff, min(MaxBackoff, BaseBackoff * 2^(attempt-1))], uniformly random (full jitter above the base).</summary>
        public TimeSpan Backoff(int attempt)
        {
            double baseS = _o.BaseBackoff.TotalSeconds, maxS = _o.MaxBackoff.TotalSeconds;
            double cap = Math.Min(maxS, baseS * Math.Pow(2, Math.Min(30, Math.Max(0, attempt - 1))));
            if (cap < baseS) cap = baseS;
            double rnd = _o.Random();
            if (rnd < 0) rnd = 0; else if (rnd > 1) rnd = 1;
            return TimeSpan.FromSeconds(baseS + rnd * (cap - baseS));
        }

        private async Task<T> ExecuteAsync<T>(GraphRequest req, Func<GraphResponse, CancellationToken, Task<T>> handler,
            bool disposeResponse, bool timeoutCoversBody, bool replayable, CancellationToken ct)
        {
            if (req == null) throw new ArgumentNullException(nameof(req));
            string cls = string.IsNullOrEmpty(req.EndpointClass) ? Classify(req.Url) : req.EndpointClass;
            req.EndpointClass = cls;   // the transport (and the fake) see the resolved family
            string method = (req.Method ?? HttpMethod.Get).Method;
            string safeUrl = SafeUrl(req.Url);
            long bodyStart = -1;
            if (req.BodyStream != null)
            {
                if (req.BodyStream.CanSeek) bodyStart = req.BodyStream.Position;
                else replayable = false;
            }

            for (int attempt = 1; ; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                if (attempt > 1 && bodyStart >= 0) req.BodyStream.Position = bodyStart;

                GraphResponse bad = null;
                Exception transient = null;
                IDisposable lease = null;
                try
                {
                    if (_limiter != null) lease = await _limiter.AcquireAsync(cls, req.ThreadKey, ct).ConfigureAwait(false);
                    using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                    {
                        if (_o.RequestTimeout > TimeSpan.Zero && _o.RequestTimeout != Timeout.InfiniteTimeSpan) cts.CancelAfter(_o.RequestTimeout);
                        var resp = await _transport.SendAsync(req, cts.Token).ConfigureAwait(false);
                        if (resp.IsSuccess)
                        {
                            T result;
                            try { result = await handler(resp, timeoutCoversBody ? cts.Token : ct).ConfigureAwait(false); }
                            catch { resp.Dispose(); throw; }
                            if (disposeResponse) resp.Dispose();
                            _limiter?.OnSuccess(cls);
                            Emit(GraphEventKind.Request, method, cls, resp.StatusCode, TimeSpan.Zero, attempt, safeUrl, null);
                            return result;
                        }
                        bad = resp;
                    }
                }
                catch (Exception ex) when (IsTransient(ex, ct))
                {
                    transient = ex;
                }
                finally { lease?.Dispose(); }

                if (bad != null)
                {
                    int status = bad.StatusCode;
                    TimeSpan? retryAfter = bad.RetryAfter;
                    bool retry = IsRetryableStatus(status) && attempt < _o.MaxAttempts && replayable;
                    if (!retry)
                    {
                        var gex = await BuildExceptionAsync(bad, safeUrl).ConfigureAwait(false);
                        Emit(GraphEventKind.Error, method, cls, status, TimeSpan.Zero, attempt, safeUrl, gex.ErrorCode);
                        throw gex;
                    }
                    bad.Dispose();
                    bool throttle = status == 429 || status == 503;
                    if (throttle) _limiter?.OnThrottled(cls, retryAfter);
                    TimeSpan delay = retryAfter ?? Backoff(attempt);
                    Emit(throttle ? GraphEventKind.Throttled : GraphEventKind.Retry, method, cls, status, delay, attempt, safeUrl, null);
                    await _clock.DelayAsync(delay, ct).ConfigureAwait(false);
                    continue;
                }

                // network error / timeout
                if (attempt >= _o.MaxAttempts || !replayable)
                {
                    Emit(GraphEventKind.Error, method, cls, 0, TimeSpan.Zero, attempt, safeUrl, transient.GetType().Name);
                    throw new GraphException(0, "NetworkError", transient.GetType().Name + ": " + transient.Message, null, safeUrl, transient);
                }
                var d = Backoff(attempt);
                Emit(GraphEventKind.Retry, method, cls, 0, d, attempt, safeUrl, transient.GetType().Name);
                await _clock.DelayAsync(d, ct).ConfigureAwait(false);
            }
        }

        private static async Task<GraphException> BuildExceptionAsync(GraphResponse resp, string safeUrl)
        {
            string requestId = null, v;
            if (resp.Headers.TryGetValue("request-id", out v)) requestId = v;
            else if (resp.Headers.TryGetValue("client-request-id", out v)) requestId = v;
            string body = null;
            try
            {
                var ms = new MemoryStream();
                var buf = new byte[8192];
                int n;
                while (ms.Length < 65536 && (n = await resp.Content.ReadAsync(buf, 0, buf.Length).ConfigureAwait(false)) > 0) ms.Write(buf, 0, n);
                body = Encoding.UTF8.GetString(ms.ToArray());
            }
            catch (Exception) { /* the status line is enough */ }
            finally { resp.Dispose(); }

            string code, msg;
            ParseErrorBody(body, out code, out msg);
            if (requestId == null) requestId = ExtractInnerRequestId(body);
            if (string.IsNullOrEmpty(code)) code = "HTTP" + resp.StatusCode.ToString(CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(msg)) msg = "No error detail in the response.";
            return new GraphException(resp.StatusCode, code, msg, requestId, safeUrl);
        }

        private static void ParseErrorBody(string body, out string code, out string message)
        {
            code = null; message = null;
            if (string.IsNullOrWhiteSpace(body)) return;
            try
            {
                using (var doc = JsonDocument.Parse(body))
                {
                    JsonElement err, p;
                    if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("error", out err) && err.ValueKind == JsonValueKind.Object)
                    {
                        if (err.TryGetProperty("code", out p) && p.ValueKind == JsonValueKind.String) code = p.GetString();
                        if (err.TryGetProperty("message", out p) && p.ValueKind == JsonValueKind.String) message = p.GetString();
                    }
                }
            }
            catch (JsonException) { }
            if (message != null && message.Length > 500) message = message.Substring(0, 500);
        }

        private static string ExtractInnerRequestId(string body)
        {
            if (string.IsNullOrWhiteSpace(body)) return null;
            try
            {
                using (var doc = JsonDocument.Parse(body))
                {
                    JsonElement err, inner, p;
                    if (doc.RootElement.TryGetProperty("error", out err) && err.ValueKind == JsonValueKind.Object &&
                        err.TryGetProperty("innerError", out inner) && inner.ValueKind == JsonValueKind.Object &&
                        inner.TryGetProperty("request-id", out p) && p.ValueKind == JsonValueKind.String) return p.GetString();
                }
            }
            catch (JsonException) { }
            return null;
        }

        private static TimeSpan? ParseRetryAfter(string v)
        {
            var r = new GraphResponse();
            r.Headers["Retry-After"] = v;
            return r.RetryAfter;
        }

        private void Emit(GraphEventKind kind, string method, string cls, int status, TimeSpan delay, int attempt, string url, string message)
        {
            var cb = _onEvent;
            if (cb == null) return;
            try
            {
                cb(new GraphEvent
                {
                    Kind = kind, Timestamp = _clock.UtcNow, Method = method, EndpointClass = cls, StatusCode = status,
                    Delay = delay, Attempt = attempt, Url = url, Message = message
                });
            }
            catch (Exception) { /* a faulty log sink must never break the transfer */ }
        }

        /// <summary>The URL without query string and fragment (upload-session URLs carry a token in the query).</summary>
        public static string SafeUrl(string url)
        {
            if (string.IsNullOrEmpty(url)) return url;
            int i = url.IndexOfAny(new[] { '?', '#' });
            return i < 0 ? url : url.Substring(0, i);
        }

        private string WithExportModel(string url)
        {
            if (string.IsNullOrEmpty(url) || string.IsNullOrEmpty(_o.ExportModel)) return url;
            if (url.IndexOf("getAllMessages", StringComparison.OrdinalIgnoreCase) < 0) return url;
            if (Regex.IsMatch(url, @"[?&]model=", RegexOptions.IgnoreCase)) return url;
            return url + (url.IndexOf('?') >= 0 ? "&" : "?") + "model=" + _o.ExportModel;
        }

        // ---------------------------------------------------------------- classification

        private sealed class Rule
        {
            public readonly Regex Pattern;
            public readonly string Class;
            public Rule(string pattern, string cls) { Pattern = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled); Class = cls; }
        }

        private static readonly Regex VersionPrefix = new Regex(@"^(v1\.0|beta)(/|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        // Order matters: the most specific rules first. Segments are matched on the path only (no query).
        private static readonly Rule[] Rules =
        {
            new Rule(@"^\$batch$", EndpointClass.Batch),
            new Rule(@"(^|/)startMigration$", EndpointClass.MigrationStart),
            new Rule(@"(^|/)completeMigration$", EndpointClass.MigrationComplete),
            new Rule(@"/createUploadSession$", EndpointClass.DriveUpload),
            new Rule(@"(^|/)(drives?|shares)(/.*)?/content(/.*)?$", EndpointClass.DriveContent),
            new Rule(@"(^|/)(drives?|shares)(/|$)", EndpointClass.DriveItem),
            new Rule(@"/hostedContents(/|$)", EndpointClass.HostedContent),
            new Rule(@"(^|/)(users/[^/]+/|me/)?chats/getAllMessages$", EndpointClass.ChatGetAllMessages),
            new Rule(@"(^|/)(teams|channels)/getAllMessages$", EndpointClass.ChannelGetAllMessages),
            new Rule(@"/messages/[^/]+/replies(/|$)", EndpointClass.ChannelReplies),
            new Rule(@"^teams/[^/]+/channels/[^/]+/messages(/|$)", EndpointClass.ChannelMessages),
            new Rule(@"^channels/[^/]+/messages(/|$)", EndpointClass.ChannelMessages),
            new Rule(@"^teams/[^/]+/channels/[^/]+/members(/|$)", EndpointClass.ChannelMembers),
            new Rule(@"^channels/[^/]+/members(/|$)", EndpointClass.ChannelMembers),
            new Rule(@"^chats/[^/]+/members(/|$)", EndpointClass.ChatMembers),
            new Rule(@"^chats/[^/]+/messages(/|$)", EndpointClass.ChatMessages),
            new Rule(@"^teams/[^/]+/channels(/|$)", EndpointClass.Channels),
            new Rule(@"^teams(/|$)", EndpointClass.Teams),
            new Rule(@"^(users/[^/]+|me)/chats(/|$)", EndpointClass.UserChats),
            new Rule(@"^chats(/|$)", EndpointClass.Chat),
            new Rule(@"^(users|me)(/|$)", EndpointClass.Users),
        };

        /// <summary>Maps an absolute or relative Graph URL (v1.0 or beta, query ignored) to an EndpointClass constant.</summary>
        public static string Classify(string url)
        {
            if (string.IsNullOrWhiteSpace(url)) return EndpointClass.Other;
            string path = url;
            Uri abs;
            if (Uri.TryCreate(url, UriKind.Absolute, out abs) && (abs.Scheme == Uri.UriSchemeHttps || abs.Scheme == Uri.UriSchemeHttp))
                path = abs.AbsolutePath;
            else
            {
                int q = path.IndexOfAny(new[] { '?', '#' });
                if (q >= 0) path = path.Substring(0, q);
            }
            try { path = Uri.UnescapeDataString(path); } catch (UriFormatException) { }
            path = path.Trim('/');
            path = VersionPrefix.Replace(path, "");
            foreach (var rule in Rules)
                if (rule.Pattern.IsMatch(path)) return rule.Class;
            return EndpointClass.Other;
        }
    }

    #endregion
}
