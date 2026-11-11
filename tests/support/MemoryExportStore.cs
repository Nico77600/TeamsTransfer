// =============================================================================
//  TeamsTransfer - tests of lot E: in-memory IExportStore / IStoreReader + a transport decorator
// -----------------------------------------------------------------------------
//  MemoryExportStore    a thread-safe, in-memory implementation of the store contracts (NOT the real store): lets the
//                       inventory / exporter / assess tests run without SQLite, and the volume test run with KeepBodies = false
//                       (ids + hashes only, ~60 bytes per message) so that 1M+ messages fit in a test process.
//                       Content is hashed (SHA-256) while streaming and retained only up to MaxRetainedContentBytes, so a 1 GiB
//                       file costs no memory; PeakPutBufferBytes shows the biggest buffer it ever needed.
//                       Hooks: OnAppend (throw to simulate a crash in the store).
//  ImportedHidingTransport  wraps a transport and reproduces the phase 0 finding the fake does not: messages whose
//                       lastModifiedDateTime is 0001-01-01 (imported by a migration) are INVISIBLE to getAllMessages.
//                       The test builds such messages by setting FakeMessage.ModifiedMs to the minimum date.
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
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer.Testing
{
    public sealed class MemoryExportStore : IExportStore, IStoreReader
    {
        private struct Entry { public string Created; public string Modified; public int Hash; public int Versions; public byte[] Raw; }

        private sealed class Conv
        {
            public readonly object Gate = new object();
            public readonly Dictionary<string, Entry> By = new Dictionary<string, Entry>(StringComparer.Ordinal);
        }

        private readonly ConcurrentDictionary<string, UserRecord> _users = new ConcurrentDictionary<string, UserRecord>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, ConversationRecord> _convs = new ConcurrentDictionary<string, ConversationRecord>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, HashSet<string>> _links = new ConcurrentDictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, Conv> _messages = new ConcurrentDictionary<string, Conv>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, long> _contentLength = new ConcurrentDictionary<string, long>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, byte[]> _contentBytes = new ConcurrentDictionary<string, byte[]>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, string> _hosted = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, FileRecord> _files = new ConcurrentDictionary<string, FileRecord>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, int> _fileFailures = new ConcurrentDictionary<string, int>(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, string> _checkpoints = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);

        public bool KeepBodies = true;
        public long MaxRetainedContentBytes = 4L * 1024 * 1024;
        public int MaxFileFailures = 3;
        /// <summary>Called at the start of AppendMessages (key, count). Throw to simulate a failing store.</summary>
        public Action<string, int> OnAppend;

        public long AppendCalls, NewMessages, UpdatedMessages, UnchangedMessages, PutContentCalls, ContentBytesRead, PeakPutBufferBytes, SetCheckpointCalls;

        // ------------------------------------------------------------------ IExportStore

        public void UpsertUsers(IEnumerable<UserRecord> users) { foreach (var u in users) _users[u.Id] = u; }

        public void UpsertConversations(IEnumerable<ConversationRecord> conversations) { foreach (var c in conversations) _convs[c.Key] = c; }

        public void LinkUserConversations(string userId, IEnumerable<string> conversationKeys)
        {
            var set = _links.GetOrAdd(userId, _ => new HashSet<string>(StringComparer.Ordinal));
            lock (set) foreach (var k in conversationKeys) set.Add(k);
        }

        public ConversationRecord GetConversation(string conversationKey)
        {
            ConversationRecord c;
            return _convs.TryGetValue(conversationKey, out c) ? c : null;
        }

        public MessageWriteResult AppendMessages(string conversationKey, IReadOnlyList<JsonElement> messages)
        {
            Interlocked.Increment(ref AppendCalls);
            var hook = OnAppend;
            if (hook != null) hook(conversationKey, messages.Count);
            var conv = _messages.GetOrAdd(conversationKey, _ => new Conv());
            var r = new MessageWriteResult();
            var prepared = new List<KeyValuePair<string, Entry>>(messages.Count);
            foreach (var m in messages)
            {
                string raw = m.GetRawText();
                var e = new Entry
                {
                    Created = Str(m, "createdDateTime"), Modified = Str(m, "lastModifiedDateTime"), Hash = raw.GetHashCode(), Versions = 1,
                    Raw = KeepBodies ? Encoding.UTF8.GetBytes(raw) : null
                };
                prepared.Add(new KeyValuePair<string, Entry>(Str(m, "id"), e));
            }
            lock (conv.Gate)
            {
                foreach (var kv in prepared)
                {
                    Entry old;
                    if (!conv.By.TryGetValue(kv.Key, out old)) { conv.By[kv.Key] = kv.Value; r.New++; }
                    else if (old.Modified != kv.Value.Modified || old.Hash != kv.Value.Hash)
                    {
                        var e = kv.Value; e.Versions = old.Versions + 1; conv.By[kv.Key] = e; r.Updated++;
                    }
                    else r.Unchanged++;
                }
            }
            Interlocked.Add(ref NewMessages, r.New); Interlocked.Add(ref UpdatedMessages, r.Updated); Interlocked.Add(ref UnchangedMessages, r.Unchanged);
            return r;
        }

        private static string Str(JsonElement e, string name)
        {
            JsonElement p;
            return e.TryGetProperty(name, out p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
        }

        public long CountMessages(string conversationKey)
        {
            Conv c;
            if (!_messages.TryGetValue(conversationKey, out c)) return 0;
            lock (c.Gate) return c.By.Count;
        }

        public ContentRef PutContent(Stream data, string contentType)
        {
            Interlocked.Increment(ref PutContentCalls);
            using (var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buf = new byte[81920];
                MemoryStream keep = new MemoryStream();
                long total = 0; int n;
                while ((n = data.Read(buf, 0, buf.Length)) > 0)
                {
                    sha.AppendData(buf, 0, n);
                    total += n;
                    if (keep != null)
                    {
                        if (total <= MaxRetainedContentBytes) keep.Write(buf, 0, n);
                        else { keep = null; }
                    }
                }
                string hex = Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
                Interlocked.Add(ref ContentBytesRead, total);
                long peak = keep == null ? 0 : keep.Length;
                long cur;
                while (peak > (cur = Interlocked.Read(ref PeakPutBufferBytes))) Interlocked.CompareExchange(ref PeakPutBufferBytes, peak, cur);
                bool present = !_contentLength.TryAdd(hex, total);
                if (!present && keep != null) _contentBytes[hex] = keep.ToArray();
                return new ContentRef { Sha256 = hex, Length = total, ContentType = contentType, AlreadyPresent = present };
            }
        }

        public bool HasContent(string sha256) { return _contentLength.ContainsKey(sha256); }

        public Stream OpenContent(string sha256)
        {
            byte[] b;
            if (_contentBytes.TryGetValue(sha256, out b)) return new MemoryStream(b, false);
            throw new NotSupportedException("MemoryExportStore does not retain content larger than " + MaxRetainedContentBytes + " bytes.");
        }

        public void RecordHostedContent(string conversationKey, string messageId, string hostedContentId, ContentRef content)
        {
            _hosted[conversationKey + "|" + messageId + "|" + hostedContentId] = content.Sha256;
        }

        public void RecordFile(FileRecord file)
        {
            string key = file.ConversationKey + "|" + file.MessageId + "|" + file.AttachmentId;
            var copy = new FileRecord
            {
                ConversationKey = file.ConversationKey, MessageId = file.MessageId, AttachmentId = file.AttachmentId, Name = file.Name, SourceUrl = file.SourceUrl,
                DriveId = file.DriveId, ItemId = file.ItemId, ETag = file.ETag, Size = file.Size, Status = file.Status, Error = file.Error, Sha256 = file.Sha256
            };
            _files.AddOrUpdate(key, copy, (k, old) =>
            {
                if (old.Status == FileStatus.Downloaded && copy.Status == FileStatus.Pending) return old;   // never downgrade
                return copy;
            });
            if (copy.Status == FileStatus.Failed) _fileFailures.AddOrUpdate(key, 1, (k, v) => v + 1);
        }

        public IEnumerable<FileRecord> PendingFiles(int max)
        {
            var list = new List<FileRecord>();
            foreach (var kv in _files)
            {
                var f = kv.Value;
                bool pending = f.Status == FileStatus.Pending;
                int fails; _fileFailures.TryGetValue(kv.Key, out fails);
                if (f.Status == FileStatus.Failed && fails < MaxFileFailures) pending = true;
                if (!pending) continue;
                list.Add(new FileRecord
                {
                    ConversationKey = f.ConversationKey, MessageId = f.MessageId, AttachmentId = f.AttachmentId, Name = f.Name, SourceUrl = f.SourceUrl,
                    DriveId = f.DriveId, ItemId = f.ItemId, ETag = f.ETag, Size = f.Size, Status = f.Status, Error = f.Error, Sha256 = f.Sha256
                });
                if (list.Count >= max) break;
            }
            return list;
        }

        public string GetCheckpoint(string scope) { string v; return _checkpoints.TryGetValue(scope, out v) ? v : null; }

        public void SetCheckpoint(string scope, string value)
        {
            Interlocked.Increment(ref SetCheckpointCalls);
            if (string.IsNullOrEmpty(value)) { string ignore; _checkpoints.TryRemove(scope, out ignore); }
            else _checkpoints[scope] = value;
        }

        public void Dispose() { }

        // ------------------------------------------------------------------ IStoreReader

        public IEnumerable<ConversationRecord> ListConversations(string userId = null, ConversationKind? kind = null, string teamId = null)
        {
            IEnumerable<ConversationRecord> q = _convs.Values;
            if (userId != null)
            {
                HashSet<string> set;
                if (!_links.TryGetValue(userId, out set)) return new ConversationRecord[0];
                string[] keys; lock (set) keys = set.ToArray();
                q = keys.Select(k => GetConversation(k)).Where(c => c != null);
            }
            if (kind.HasValue) q = q.Where(c => c.Kind == kind.Value);
            if (teamId != null) q = q.Where(c => string.Equals(c.TeamId, teamId, StringComparison.OrdinalIgnoreCase));
            return q.OrderBy(c => c.Key, StringComparer.Ordinal).ToList();
        }

        public IEnumerable<UserRecord> ListUsers() { return _users.Values.OrderBy(u => u.Id, StringComparer.Ordinal).ToList(); }

        public IEnumerable<JsonElement> ReadMessages(string conversationKey, DateTimeOffset? fromUtc = null, DateTimeOffset? toUtc = null)
        {
            Conv c;
            if (!_messages.TryGetValue(conversationKey, out c)) yield break;
            List<KeyValuePair<string, Entry>> all;
            lock (c.Gate) all = c.By.ToList();
            foreach (var kv in all.OrderBy(x => x.Value.Created, StringComparer.Ordinal).ThenBy(x => x.Key, StringComparer.Ordinal))
            {
                if (kv.Value.Raw == null) continue;
                yield return JsonDocument.Parse(kv.Value.Raw).RootElement;
            }
        }

        public IEnumerable<FileRecord> ListFiles(string conversationKey) { return _files.Values.Where(f => f.ConversationKey == conversationKey).ToList(); }

        public string FindHostedContent(string conversationKey, string messageId, string hostedContentId)
        {
            string sha;
            return _hosted.TryGetValue(conversationKey + "|" + messageId + "|" + hostedContentId, out sha) ? sha : null;
        }

        // ------------------------------------------------------------------ test helpers

        public long TotalMessages { get { long n = 0; foreach (var c in _messages.Values) lock (c.Gate) n += c.By.Count; return n; } }
        public int ConversationCount { get { return _convs.Count; } }
        public int UserCount { get { return _users.Count; } }
        public int HostedCount { get { return _hosted.Count; } }
        public int FileCount { get { return _files.Count; } }
        public int DistinctContentCount { get { return _contentLength.Count; } }
        public string[] MessageIds(string conversationKey)
        {
            Conv c;
            if (!_messages.TryGetValue(conversationKey, out c)) return new string[0];
            lock (c.Gate) return c.By.Keys.OrderBy(x => x, StringComparer.Ordinal).ToArray();
        }
        public string[] ConversationKeysWithMessages() { return _messages.Where(kv => kv.Value.By.Count > 0).Select(kv => kv.Key).OrderBy(x => x, StringComparer.Ordinal).ToArray(); }
        public int Versions(string conversationKey, string messageId)
        {
            Conv c; Entry e;
            if (!_messages.TryGetValue(conversationKey, out c)) return 0;
            lock (c.Gate) return c.By.TryGetValue(messageId, out e) ? e.Versions : 0;
        }
        public IReadOnlyDictionary<string, string> Checkpoints { get { return new Dictionary<string, string>(_checkpoints); } }
        public IEnumerable<FileRecord> AllFiles { get { return _files.Values.ToList(); } }
        public IEnumerable<UserRecord> AllUsers { get { return _users.Values.ToList(); } }
    }

    /// <summary>Hooks for the store (a PowerShell scriptblock cannot be called from engine threads).</summary>
    public static class StoreHooks
    {
        /// <summary>After n AppendMessages calls, asks the run to stop.</summary>
        public static void StopAfterAppends(MemoryExportStore store, StopControl stop, int n)
        {
            int count = 0;
            store.OnAppend = (k, c) => { if (Interlocked.Increment(ref count) >= n) stop.Request(); };
        }
        /// <summary>The n-th AppendMessages call throws (a crashing store); later calls succeed.</summary>
        public static void ThrowAtAppend(MemoryExportStore store, int n)
        {
            int count = 0;
            store.OnAppend = (k, c) => { if (Interlocked.Increment(ref count) == n) throw new InvalidOperationException("simulated store crash"); };
        }
    }

    /// <summary>
    /// Behaves like real Graph on getAllMessages: a $filter that bounds lastModifiedDateTime on one side only is a 400
    /// ("Invalid '$filter' query. Missing 'lastModifiedDateTime' value."). Wrap every transport of the export tests in it.
    /// </summary>
    public sealed class StrictFilterTransport : IGraphTransport
    {
        private readonly IGraphTransport _inner;
        public long Rejected, Checked;
        public StrictFilterTransport(IGraphTransport inner) { _inner = inner; }

        public Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            string url = request.Url ?? "";
            {
                // real Graph: "The entity property 'createdDateTime' and operationKind 'GreaterThan' is not allowed in $filter query"
                string dec = Uri.UnescapeDataString(url.Replace("+", " "));
                int fi = dec.IndexOf("$filter=", StringComparison.OrdinalIgnoreCase);
                if (fi >= 0 && dec.IndexOf("createdDateTime", fi, StringComparison.OrdinalIgnoreCase) >= 0 && dec.IndexOf("/messages", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    Interlocked.Increment(ref Rejected);
                    var body = "{\"error\":{\"code\":\"BadRequest\",\"message\":\"The entity property 'createdDateTime' and operationKind 'GreaterThan' is not allowed in $filter query.\"}}";
                    return Task.FromResult(new GraphResponse { StatusCode = 400, Content = new MemoryStream(Encoding.UTF8.GetBytes(body)), ContentType = "application/json" });
                }
            }
            if (System.Text.RegularExpressions.Regex.IsMatch(url, @"teams/[^/]+/channels/[^/?]+/messages", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            {
                // real Graph: "The query specified in the URI is not valid. Query option 'OrderBy' is not allowed." (no $filter either)
                string dq = Uri.UnescapeDataString(url.Replace("+", " "));
                if (dq.IndexOf("$orderby=", StringComparison.OrdinalIgnoreCase) >= 0 || dq.IndexOf("$filter=", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    Interlocked.Increment(ref Rejected);
                    var eb = "{\"error\":{\"code\":\"BadRequest\",\"message\":\"The query specified in the URI is not valid. Query option 'OrderBy' is not allowed.\"}}";
                    return Task.FromResult(new GraphResponse { StatusCode = 400, Content = new MemoryStream(Encoding.UTF8.GetBytes(eb)), ContentType = "application/json" });
                }
            }
            if (url.IndexOf("getAllMessages", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Interlocked.Increment(ref Checked);
                int q = url.IndexOf('?');
                string query = q >= 0 ? Uri.UnescapeDataString(url.Substring(q + 1).Replace("+", " ")) : "";
                int f = query.IndexOf("$filter=", StringComparison.OrdinalIgnoreCase);
                if (f >= 0)
                {
                    string filter = query.Substring(f + 8);
                    int amp = filter.IndexOf("&$", StringComparison.Ordinal);
                    if (amp >= 0) filter = filter.Substring(0, amp);
                    bool gt = System.Text.RegularExpressions.Regex.IsMatch(filter, @"lastModifiedDateTime\s+(gt|ge)\s+\S+");
                    bool lt = System.Text.RegularExpressions.Regex.IsMatch(filter, @"lastModifiedDateTime\s+(lt|le)\s+\S+");
                    if (!(gt && lt))
                    {
                        Interlocked.Increment(ref Rejected);
                        var body = "{\"error\":{\"code\":\"BadRequest\",\"message\":\"Invalid '$filter' query. Missing 'lastModifiedDateTime' value.\"}}";
                        var resp = new GraphResponse { StatusCode = 400, Content = new MemoryStream(Encoding.UTF8.GetBytes(body)), ContentType = "application/json" };
                        return Task.FromResult(resp);
                    }
                }
            }
            return _inner.SendAsync(request, cancellationToken);
        }
    }

    /// <summary>
    /// Emulates $expand=replies on GET teams/{t}/channels/{c}/messages (real Graph honours it, the fake ignores it): each root gets a
    /// "replies" array. Roots without replies get an empty array, like the service. Counts the roots expanded.
    /// </summary>
    public sealed class ExpandRepliesTransport : IGraphTransport
    {
        private readonly IGraphTransport _inner;
        public long Expanded;
        public ExpandRepliesTransport(IGraphTransport inner) { _inner = inner; }

        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            string url = request.Url ?? "";
            string dec = Uri.UnescapeDataString(url);
            var m = System.Text.RegularExpressions.Regex.Match(dec, @"^(?<base>.*teams/[^/]+/channels/[^/?]+/messages)\?(?<q>.*)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (!m.Success || dec.IndexOf("$expand=replies", StringComparison.OrdinalIgnoreCase) < 0) return await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
            // the inner fake does not know $expand: strip it, then add the replies ourselves
            var inner = new GraphRequest { Method = request.Method, Url = url.Replace("&$expand=replies", "").Replace("$expand=replies&", "").Replace("?$expand=replies", ""), EndpointClass = request.EndpointClass, ThreadKey = request.ThreadKey };
            foreach (var h in request.Headers) inner.Headers[h.Key] = h.Value;
            var resp = await _inner.SendAsync(inner, cancellationToken).ConfigureAwait(false);
            if (!resp.IsSuccess) return resp;
            var ms = new MemoryStream();
            try { await resp.Content.CopyToAsync(ms, 81920, cancellationToken).ConfigureAwait(false); } finally { resp.Content.Dispose(); }
            ms.Position = 0;
            var outMs = new MemoryStream();
            using (var doc = JsonDocument.Parse(ms))
            using (var w = new Utf8JsonWriter(outMs))
            {
                w.WriteStartObject();
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    if (p.NameEquals("value") && p.Value.ValueKind == JsonValueKind.Array)
                    {
                        w.WriteStartArray("value");
                        foreach (var root in p.Value.EnumerateArray())
                        {
                            w.WriteStartObject();
                            foreach (var rp in root.EnumerateObject()) rp.WriteTo(w);
                            w.WritePropertyName("replies");
                            w.WriteStartArray();
                            var rr = new GraphRequest { Method = request.Method, Url = m.Groups["base"].Value + "/" + root.GetProperty("id").GetString() + "/replies?$top=50" };
                            using (var rresp = await _inner.SendAsync(rr, cancellationToken).ConfigureAwait(false))
                            {
                                var rms = new MemoryStream();
                                await rresp.Content.CopyToAsync(rms, 81920, cancellationToken).ConfigureAwait(false);
                                rms.Position = 0;
                                using (var rd = JsonDocument.Parse(rms))
                                    foreach (var rep in rd.RootElement.GetProperty("value").EnumerateArray()) rep.WriteTo(w);
                            }
                            w.WriteEndArray();
                            w.WriteEndObject();
                            Interlocked.Increment(ref Expanded);
                        }
                        w.WriteEndArray();
                    }
                    else if (p.NameEquals("@odata.nextLink") && p.Value.ValueKind == JsonValueKind.String) w.WriteString("@odata.nextLink", p.Value.GetString() + "&$expand=replies");   // the service keeps the query options
                    else p.WriteTo(w);
                }
                w.WriteEndObject();
            }
            outMs.Position = 0;
            var copy = new GraphResponse { StatusCode = resp.StatusCode, Content = outMs, ContentType = resp.ContentType };
            foreach (var h in resp.Headers) copy.Headers[h.Key] = h.Value;
            return copy;
        }
    }

    /// <summary>A settable clock for ExportOptions.Now / InventoryOptions.Now (a PowerShell scriptblock cannot be called from engine threads).</summary>
    public sealed class TestNow
    {
        private long _ticks;
        public TestNow(string iso) { Set(iso); }
        public void Set(string iso) { Interlocked.Exchange(ref _ticks, DateTimeOffset.Parse(iso, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal).UtcTicks); }
        public DateTimeOffset Value { get { return new DateTimeOffset(Interlocked.Read(ref _ticks), TimeSpan.Zero); } }
        public Func<DateTimeOffset> Func { get { return () => Value; } }
    }

    /// <summary>
    /// Reproduces the phase 0 finding for the offline tests: a message with lastModifiedDateTime = 0001-01-01 (imported by a migration)
    /// is not returned by getAllMessages (users/{id}/chats and teams/{id}/channels), while the per-chat / per-channel listing still returns it.
    /// </summary>
    public sealed class ImportedHidingTransport : IGraphTransport
    {
        private readonly IGraphTransport _inner;
        public long HiddenMessages;
        public ImportedHidingTransport(IGraphTransport inner) { _inner = inner; }

        public async Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            var resp = await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!resp.IsSuccess) return resp;
            string url = request.Url ?? "";
            if (url.IndexOf("getAllMessages", StringComparison.OrdinalIgnoreCase) < 0) return resp;
            var ms = new MemoryStream();
            try { await resp.Content.CopyToAsync(ms, 81920, cancellationToken).ConfigureAwait(false); } finally { resp.Content.Dispose(); }
            ms.Position = 0;
            var outMs = new MemoryStream();
            using (var doc = JsonDocument.Parse(ms))
            using (var w = new Utf8JsonWriter(outMs))
            {
                w.WriteStartObject();
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    if (p.NameEquals("value") && p.Value.ValueKind == JsonValueKind.Array)
                    {
                        w.WriteStartArray("value");
                        foreach (var el in p.Value.EnumerateArray())
                        {
                            JsonElement lm;
                            if (el.TryGetProperty("lastModifiedDateTime", out lm) && lm.ValueKind == JsonValueKind.String && lm.GetString().StartsWith("0001-01-01", StringComparison.Ordinal))
                            { Interlocked.Increment(ref HiddenMessages); continue; }
                            el.WriteTo(w);
                        }
                        w.WriteEndArray();
                    }
                    else p.WriteTo(w);
                }
                w.WriteEndObject();
            }
            outMs.Position = 0;
            var copy = new GraphResponse { StatusCode = resp.StatusCode, Content = outMs, ContentType = resp.ContentType };
            foreach (var h in resp.Headers) copy.Headers[h.Key] = h.Value;
            return copy;
        }
    }
}
