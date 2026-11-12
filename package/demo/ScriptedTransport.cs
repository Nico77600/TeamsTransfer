// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// Test helpers of lot A (Auth / Graph / Throttle): a scripted IGraphTransport, a virtual clock and a stub HttpMessageHandler.
// Compiled together with the engine by TestHelpers.ps1. Offline, deterministic, no real sleeping.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    public sealed class RecordedRequest
    {
        public string Method { get; set; }
        public string Url { get; set; }
        public string BodyJson { get; set; }
        public string EndpointClass { get; set; }
        public string ThreadKey { get; set; }
        public bool Anonymous { get; set; }
    }

    /// <summary>Virtual time: DelayAsync advances the clock at once and records the requested delay.</summary>
    public sealed class TestManualClock : IClock
    {
        private readonly object _gate = new object();
        private DateTimeOffset _now;
        public List<TimeSpan> Delays { get; } = new List<TimeSpan>();

        public TestManualClock() { _now = new DateTimeOffset(2026, 11, 9, 8, 0, 0, TimeSpan.Zero); }

        public DateTimeOffset UtcNow { get { lock (_gate) return _now; } }
        public void Advance(TimeSpan t) { lock (_gate) _now += t; }

        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_gate)
            {
                Delays.Add(delay);
                if (delay > TimeSpan.Zero) _now += delay;
            }
            return Task.CompletedTask;
        }
    }

    /// <summary>Returns queued answers in order; when the queue is empty, DefaultHandler (or a 500) answers.</summary>
    public sealed class ScriptedTransport : IGraphTransport
    {
        private readonly Queue<Func<GraphRequest, GraphResponse>> _queue = new Queue<Func<GraphRequest, GraphResponse>>();
        private readonly object _gate = new object();
        public List<RecordedRequest> Requests { get; } = new List<RecordedRequest>();
        public Func<GraphRequest, GraphResponse> DefaultHandler { get; set; }
        /// <summary>For every request: the position of BodyStream at the time of sending (retry replay checks).</summary>
        public List<long> BodyStreamPositions { get; } = new List<long>();

        public int Pending { get { lock (_gate) return _queue.Count; } }

        public void EnqueueJson(int status, string json, string retryAfter = null, string requestId = null)
        {
            Enqueue(r =>
            {
                var resp = new GraphResponse { StatusCode = status, ContentType = "application/json" };
                if (json != null) resp.Content = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(json));
                if (retryAfter != null) resp.Headers["Retry-After"] = retryAfter;
                if (requestId != null) resp.Headers["request-id"] = requestId;
                return resp;
            });
        }

        /// <summary>A body that throws IOException after failAfterBytes bytes (-1: never).</summary>
        public void EnqueueBytes(int status, byte[] data, int failAfterBytes = -1)
        {
            Enqueue(r => new GraphResponse { StatusCode = status, Content = new FlakyStream(data, failAfterBytes) });
        }

        public void EnqueueThrow(Exception ex) { Enqueue(r => { throw ex; }); }

        public void Enqueue(Func<GraphRequest, GraphResponse> step) { lock (_gate) _queue.Enqueue(step); }

        public Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            Func<GraphRequest, GraphResponse> step = null;
            lock (_gate)
            {
                Requests.Add(new RecordedRequest
                {
                    Method = request.Method.Method, Url = request.Url, BodyJson = request.BodyJson,
                    EndpointClass = request.EndpointClass, ThreadKey = request.ThreadKey, Anonymous = request.Anonymous
                });
                BodyStreamPositions.Add(request.BodyStream != null && request.BodyStream.CanSeek ? request.BodyStream.Position : -1);
                if (_queue.Count > 0) step = _queue.Dequeue();
            }
            try
            {
                if (step == null) step = DefaultHandler;
                if (step == null) step = r => new GraphResponse { StatusCode = 500 };
                var resp = step(request);
                // consume the replayable body like a real transport would
                if (request.BodyStream != null && request.BodyStream.CanRead && request.BodyStream.CanSeek) { var b = new byte[request.BodyStream.Length - request.BodyStream.Position]; request.BodyStream.Read(b, 0, b.Length); }
                return Task.FromResult(resp);
            }
            catch (Exception ex)
            {
                var tcs = new TaskCompletionSource<GraphResponse>();
                tcs.SetException(ex);
                return tcs.Task;
            }
        }

        private sealed class FlakyStream : Stream
        {
            private readonly byte[] _data; private readonly int _failAfter; private int _pos;
            public FlakyStream(byte[] data, int failAfter) { _data = data; _failAfter = failAfter; }
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count)
            {
                if (_failAfter >= 0 && _pos >= _failAfter) throw new IOException("simulated connection reset");
                int limit = _failAfter >= 0 ? Math.Min(_data.Length, _failAfter) : _data.Length;
                int n = Math.Min(Math.Min(count, 4), limit - _pos);   // small chunks so a copy is really partial
                if (n <= 0) return 0;
                Buffer.BlockCopy(_data, _pos, buffer, offset, n);
                _pos += n;
                return n;
            }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        }
    }

    public sealed class StubHttpRequest
    {
        public string Method { get; set; }
        public string Uri { get; set; }
        public string Authorization { get; set; }
        public string ClientRequestId { get; set; }
        public string Body { get; set; }
        public string ContentType { get; set; }
        public Dictionary<string, string> Headers { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>HttpMessageHandler that answers from a queue and records what was sent (token endpoint and HttpGraphTransport tests).</summary>
    public sealed class StubHttpHandler : HttpMessageHandler
    {
        private readonly Queue<Func<HttpResponseMessage>> _queue = new Queue<Func<HttpResponseMessage>>();
        private readonly object _gate = new object();
        public List<StubHttpRequest> Requests { get; } = new List<StubHttpRequest>();
        public int Delivered { get; private set; }
        /// <summary>When set, a request bearing this token (or any bearer token if "*") is answered 401 without using the queue.</summary>
        public string RejectToken { get; set; }
        /// <summary>When set, an empty queue answers 200 with this body instead of 500.</summary>
        public string DefaultOkBody { get; set; }

        public void Enqueue(int status, string body, string contentType = "application/json")
        {
            lock (_gate) _queue.Enqueue(() =>
            {
                var m = new HttpResponseMessage((System.Net.HttpStatusCode)status);
                m.Content = new StringContent(body ?? "", System.Text.Encoding.UTF8, contentType);
                return m;
            });
        }

        public void EnqueueThrow(Exception ex) { lock (_gate) _queue.Enqueue(() => { throw ex; }); }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var rec = new StubHttpRequest
            {
                Method = request.Method.Method,
                Uri = request.RequestUri.ToString(),
                Authorization = request.Headers.Authorization?.ToString()
            };
            IEnumerable<string> v;
            if (request.Headers.TryGetValues("client-request-id", out v)) foreach (var x in v) rec.ClientRequestId = x;
            foreach (var h in request.Headers) rec.Headers[h.Key] = string.Join(",", h.Value);
            if (request.Content != null)
            {
                rec.Body = await request.Content.ReadAsStringAsync().ConfigureAwait(false);
                rec.ContentType = request.Content.Headers.ContentType?.MediaType;
            }
            Func<HttpResponseMessage> step = null;
            lock (_gate)
            {
                Requests.Add(rec);
                if (_queue.Count > 0) step = _queue.Dequeue();
                Delivered++;
            }
            if (RejectToken != null && rec.Authorization != null && (RejectToken == "*" || rec.Authorization == "Bearer " + RejectToken))
                return new HttpResponseMessage(System.Net.HttpStatusCode.Unauthorized) { Content = new StringContent("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"expired\"}}") };
            if (step == null && DefaultOkBody != null) return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(DefaultOkBody) };
            if (step == null) return new HttpResponseMessage(System.Net.HttpStatusCode.InternalServerError);
            return step();
        }
    }
}

namespace TeamsTransfer
{
    public sealed class LinkRecorder
    {
        public List<string> Links { get; } = new List<string>();
        public Func<string, Task> Callback { get; }
        public LinkRecorder() { Callback = l => { lock (Links) Links.Add(l); return Task.CompletedTask; }; }
    }

    public sealed class EventRecorder
    {
        public List<GraphEvent> Events { get; } = new List<GraphEvent>();
        public Action<GraphEvent> Callback { get; }
        public EventRecorder() { Callback = e => { lock (Events) Events.Add(e); }; }
    }

    public static class TestAsync
    {
        /// <summary>Sends n GET requests truly in parallel (thread pool) and returns the statuses.</summary>
        public static async Task<int[]> ParallelStatuses(IGraphTransport t, string url, int n)
        {
            var tasks = new List<Task<int>>();
            for (int i = 0; i < n; i++)
                tasks.Add(Task.Run(async () => { using (var r = await t.SendAsync(new GraphRequest { Url = url }, CancellationToken.None)) return r.StatusCode; }));
            return await Task.WhenAll(tasks);
        }

        /// <summary>Enumerates an async sequence (at most max elements) and returns the elements.</summary>
        public static async Task<List<System.Text.Json.JsonElement>> Collect(IAsyncEnumerable<System.Text.Json.JsonElement> source, int max = int.MaxValue)
        {
            var list = new List<System.Text.Json.JsonElement>();
            if (max <= 0) return list;
            await foreach (var e in source)
            {
                list.Add(e);
                if (list.Count >= max) break;
            }
            return list;
        }
    }
}

namespace TeamsTransfer
{
    public sealed class StaticTokenProvider : IAccessTokenProvider
    {
        public string TenantId => "test-tenant";
        public string Token { get; set; } = "TEST-TOKEN";
        public Task<string> GetTokenAsync(CancellationToken cancellationToken) { return Task.FromResult(Token); }
    }

    /// <summary>
    /// Answers a $batch request: one item answer per request id. Script[id] is a list of "status" or "status:retryAfterSeconds",
    /// consumed one per time the id is seen (default 200 with body {"id":"..."}). Every incoming batch size is recorded.
    /// </summary>
    public sealed class BatchResponder
    {
        public Dictionary<string, List<string>> Script { get; } = new Dictionary<string, List<string>>();
        public List<int> BatchSizes { get; } = new List<int>();
        public List<List<string>> BatchIds { get; } = new List<List<string>>();
        public Func<GraphRequest, GraphResponse> Handler { get; }

        public BatchResponder() { Handler = Respond; }

        public void Plan(string id, params string[] steps) { Script[id] = new List<string>(steps); }

        private GraphResponse Respond(GraphRequest req)
        {
            var sb = new System.Text.StringBuilder("{\"responses\":[");
            var ids = new List<string>();
            using (var doc = System.Text.Json.JsonDocument.Parse(req.BodyJson))
            {
                bool first = true;
                foreach (var r in doc.RootElement.GetProperty("requests").EnumerateArray())
                {
                    string id = r.GetProperty("id").GetString();
                    ids.Add(id);
                    int status = 200; string ra = null;
                    List<string> steps;
                    if (Script.TryGetValue(id, out steps) && steps.Count > 0)
                    {
                        var s = steps[0]; steps.RemoveAt(0);
                        var parts = s.Split(':');
                        status = int.Parse(parts[0]);
                        if (parts.Length > 1) ra = parts[1];
                    }
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append("{\"id\":\"").Append(id).Append("\",\"status\":").Append(status);
                    if (ra != null) sb.Append(",\"headers\":{\"Retry-After\":\"").Append(ra).Append("\"}");
                    if (status >= 400) sb.Append(",\"body\":{\"error\":{\"code\":\"E").Append(status).Append("\",\"message\":\"item failed\"}}");
                    else sb.Append(",\"body\":{\"id\":\"").Append(id).Append("\"}");
                    sb.Append('}');
                }
            }
            sb.Append("]}");
            BatchSizes.Add(ids.Count);
            BatchIds.Add(ids);
            var resp = new GraphResponse { StatusCode = 200, ContentType = "application/json" };
            resp.Content = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(sb.ToString()));
            return resp;
        }
    }
}

namespace TeamsTransfer
{
    /// <summary>Delegates built in C#: a PowerShell script block cannot run on a thread-pool continuation.</summary>
    public static class TestFuncs
    {
        public static Func<double> Const(double v) { return () => v; }
        public static Func<double> Uniform() { return () => System.Random.Shared.NextDouble(); }
    }
}
