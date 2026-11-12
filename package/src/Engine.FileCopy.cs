// =============================================================================
//  TeamsTransfer - engine, lot J part 2: file copy to the target (design 3.3, "Import")
// -----------------------------------------------------------------------------
//  The download counterpart is FilesStage (Engine.Export.cs). Files are copied BEFORE the messages, in their own resumable step, so that the
//  importer can rewrite each reference attachment to the new item (IFileCopyMap: TargetDriveId / TargetItemId / TargetWebUrl).
//
//  WHERE a file goes (decided per FileRecord with State Downloaded, for the conversations the run covers):
//    chat target     the OneDrive of the MAPPED SENDER of the message, folder "Microsoft Teams Chat Files". A sender that is a ghost (an unlicensed
//                    account has no OneDrive), the service account, unresolved or unknown -> the OneDrive of the service account.
//    channel target  the target channel's files folder: GET /teams/{t}/channels/{c}/filesFolder -> drive + folder, upload by root-relative path.
//                    A channel that does not exist yet (NewChannel before the importer created it) leaves the record Pending ("waiting for the target").
//  HOW: below SmallFileLimit (4 MiB) one PUT .../root:/folder/name:/content; above it createUploadSession and fragments of ChunkBytes (a multiple of
//  320 KiB, 10 MiB by default) read from store.OpenContent(sha256) one fragment at a time (memory = one fragment, never the whole file). Fragment
//  requests are Anonymous (the upload URL is pre-authenticated). conflictBehavior = rename.
//  RESUME: before the first fragment the session is saved in the store checkpoints ("fc:up:<hash of drive|folder|sha256>": upload URL, name, size,
//  sha256). After a crash or a stop the next run asks the session for nextExpectedRanges and continues from there; an expired session (404/410) starts a
//  new one. A fragment that fails (network, 5xx, 416 after a retried success) resyncs from the session status and is re-sent, up to FragmentAttempts.
//  A small file that was uploaded just before a crash is uploaded again under a renamed name (rename): harmless duplicate, never data loss.
//  DEDUP: same sha256 + same destination folder = one upload ("fc:dd:<drive|folder|sha256>" -> item id and URL, checked with one GET before reuse);
//  the file is still SHARED with each chat's members. Parallel uploads of the same content in the same folder share one in-flight upload.
//  SHARE: chats only. POST /drives/{d}/items/{i}/invite, roles read, requireSignIn, sendInvitation = false (no e-mail), recipients = the target chat
//  members (ghosts, the service account and the owner excluded), 50 per call. A recipient the service refuses (4xx) is counted, not fatal; a
//  transient failure keeps the record Uploaded with an Error so the next run shares again. Channels inherit the folder permissions: State Shared at once.
//  STATE: Pending -> Uploaded -> Shared | Failed | Skipped (extension / size exclusion). Failures are recorded per file and never stop the run.
//  Shared and Skipped records are not touched by a rerun; Uploaded ones are only shared; Failed and Pending ones are tried again.
//  DRY RUN (ImportRunOptions.Apply = false): no request at all, nothing written; counts and bytes per destination from the maps and the store.
//
//  Graph permissions (application, target tenant): Files.ReadWrite.All (OneDrive and channel files, invite), Sites.ReadWrite.All (channel site libraries),
//  Team.ReadBasic.All + Channel.ReadBasic.All (filesFolder), Chat.ReadBasic.All (members of an existing target chat), User.Read.All (user drive lookup).
// =============================================================================
using System;
using System.Collections.Concurrent;
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
    public sealed class FileCopyOptions
    {
        /// <summary>Files larger than this are Skipped (0 = no limit).</summary>
        public long MaxFileBytes { get; set; }
        public string[] ExcludedExtensions { get; set; } = new string[0];
        public int Parallelism { get; set; } = 4;
        /// <summary>Strictly below: one PUT. At or above: an upload session.</summary>
        public long SmallFileLimit { get; set; } = 4L * 1024 * 1024;
        /// <summary>Fragment size of an upload session; rounded down to a multiple of 320 KiB (min 320 KiB, max 60 MiB).</summary>
        public int ChunkBytes { get; set; } = 32 * 327680;
        public string ChatFilesFolder { get; set; } = "Microsoft Teams Chat Files";
        public string ConflictBehavior { get; set; } = "rename";
        public bool ShareChats { get; set; } = true;
        public int ShareBatchSize { get; set; } = 50;
        public int FragmentAttempts { get; set; } = 5;
        public Action<ProgressSnapshot> OnProgress { get; set; }
        public Func<DateTimeOffset> Now { get; set; }
    }

    /// <summary>A conversation to copy files for, optionally limited to a time window (a lot item: from inclusive, to exclusive).</summary>
    public sealed class FileCopyScope
    {
        public string ConversationKey { get; set; }
        public DateTimeOffset? FromUtc { get; set; }
        public DateTimeOffset? ToUtc { get; set; }
    }

    public sealed class FileCopyDestinationStat
    {
        public string Destination { get; set; }
        public long Files { get; set; }
        public long Bytes { get; set; }
        /// <summary>Files that need no second upload (same content, same folder).</summary>
        public long Duplicates { get; set; }
    }

    public sealed class FileCopyResult
    {
        public bool DryRun;
        /// <summary>Downloaded files of the covered conversations that the run looked at.</summary>
        public long Files;
        public long Uploaded, Reused, Shared, AlreadyDone, Skipped, Excluded, TooLarge, Failed, WaitingForTarget, NoDestination, NotDownloaded, NoTarget;
        public long SharingIncomplete, RecipientsRefused, ResumedUploads;
        /// <summary>Bytes uploaded (apply) or to upload (dry run, duplicates counted once).</summary>
        public long Bytes;
        public double BytesPerSecond;
        public bool Stopped;
        public TimeSpan Duration;
        public List<FileCopyDestinationStat> Destinations = new List<FileCopyDestinationStat>();
        public List<ErrorRecord> Errors = new List<ErrorRecord>();
        public List<string> Warnings = new List<string>();
    }

    /// <summary>A transport that refuses every request: gives a dry run a GraphClient that can never reach a tenant.</summary>
    public sealed class RefusingTransport : IGraphTransport
    {
        public Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken)
        {
            throw new InvalidOperationException("This is a dry run: no request may be sent (" + (request == null ? "" : GraphClient.SafeUrl(request.Url)) + ").");
        }
    }

    public sealed class FileCopier
    {
        private readonly GraphClient _g;
        private readonly TmtStore _store;
        private readonly IIdentityMap _ids;
        private readonly ITargetMap _targets;
        private readonly IFileCopyMap _files;
        private readonly ImportRunOptions _run;
        private readonly FileCopyOptions _o;
        private readonly Func<DateTimeOffset> _now;
        private ProgressReporter _p;
        private readonly int _chunk;
        private readonly BoundedCache<string> _userDrive = new BoundedCache<string>(200000);
        private readonly BoundedCache<ChannelFolder> _channelFolder = new BoundedCache<ChannelFolder>(50000);
        private readonly BoundedCache<string[]> _members = new BoundedCache<string[]>(2000);
        private readonly Dictionary<string, Task<Item>> _inflight = new Dictionary<string, Task<Item>>(StringComparer.Ordinal);
        private Lazy<HashSet<string>> _noShare;
        private readonly ConcurrentDictionary<string, FileCopyDestinationStat> _dest = new ConcurrentDictionary<string, FileCopyDestinationStat>(StringComparer.Ordinal);
        private readonly ConcurrentQueue<ErrorRecord> _errors = new ConcurrentQueue<ErrorRecord>();
        private readonly HashSet<string> _dryDup = new HashSet<string>(StringComparer.Ordinal);

        public FileCopier(GraphClient target, TmtStore store, IIdentityMap ids, ITargetMap targets, IFileCopyMap files, ImportRunOptions run, FileCopyOptions options = null)
        {
            if (target == null) throw new ArgumentNullException("target");
            if (store == null) throw new ArgumentNullException("store");
            if (ids == null) throw new ArgumentNullException("ids");
            if (targets == null) throw new ArgumentNullException("targets");
            if (files == null) throw new ArgumentNullException("files");
            _g = target; _store = store; _ids = ids; _targets = targets; _files = files; _run = run ?? new ImportRunOptions(); _o = options ?? new FileCopyOptions();
            _now = _o.Now ?? (() => DateTimeOffset.UtcNow);
            _p = new ProgressReporter("FileCopy", _o.OnProgress, _now);
            int c = (_o.ChunkBytes / 327680) * 327680;
            _chunk = Math.Max(327680, Math.Min(c, 60 * 1024 * 1024 / 327680 * 327680));
        }

        public ProgressSnapshot Progress { get { return _p.Snapshot(); } }

        private sealed class ChannelFolder { public string DriveId, FolderPath; }

        private sealed class Item { public string Id, WebUrl, DriveId; public long Size; public bool Reused; }

        private sealed class Dest
        {
            public string Label; public bool Channel; public string OwnerUserId; public string TeamId, ChannelId; public bool ServiceAccount;
            public string DriveId, FolderPath;
        }

        private sealed class Work { public FileRecord F; public string SenderId; public TargetMapping T; }

        private sealed class StopRequested : Exception { }

        private sealed class WaitingForTarget : Exception { public WaitingForTarget(string m) : base(m) { } }

        private sealed class NoDestination : Exception { public NoDestination(string m) : base(m) { } }

        // ------------------------------------------------------------------ run

        public async Task<FileCopyResult> RunAsync(IEnumerable<FileCopyScope> scopes = null, CancellationToken ct = default(CancellationToken))
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var res = new FileCopyResult { DryRun = !_run.Apply };
            _p = new ProgressReporter("FileCopy", _o.OnProgress, _now);
            _p.Phase("file copy");
            _noShare = new Lazy<HashSet<string>>(BuildNoShareSet);
            _dest.Clear(); _dryDup.Clear();
            var list = scopes != null ? scopes.Where(s => s != null && !string.IsNullOrEmpty(s.ConversationKey)).ToList()
                : _targets.List().Where(t => t.Kind != TargetKind.Skip).Select(t => new FileCopyScope { ConversationKey = t.SourceConversationKey }).ToList();
            _p.Phase("file copy", list.Select(s => s.ConversationKey).Distinct().Count());
            try
            {
                await Par.ForEachAsync(Produce(list, res), Math.Max(1, _o.Parallelism), (w, token) => ProcessAsync(w, res, token), ct, _run.Stop).ConfigureAwait(false);
            }
            finally
            {
                res.Stopped = StopControl.Stopped(_run.Stop);
                res.Duration = sw.Elapsed;
                res.BytesPerSecond = res.Bytes / Math.Max(0.001, sw.Elapsed.TotalSeconds);
                res.Destinations = _dest.Values.OrderBy(d => d.Destination, StringComparer.Ordinal).ToList();
                res.Errors = _errors.ToList();
                _p.Finish();
            }
            return res;
        }

        private HashSet<string> BuildNoShareSet()
        {
            var h = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var k in new[] { IdentityKind.Ghost, IdentityKind.ServiceAccount })
                foreach (var m in _ids.List(k)) if (m != null && !string.IsNullOrEmpty(m.TargetUserId)) h.Add(m.TargetUserId);
            if (!string.IsNullOrEmpty(_run.ServiceAccountUserId)) h.Add(_run.ServiceAccountUserId);
            return h;
        }

        private static bool IsChat(TargetMapping t) { return t.Kind == TargetKind.ExistingChat || t.Kind == TargetKind.NewChat; }

        private static bool Inside(FileCopyScope s, DateTimeOffset d)
        {
            return (!s.FromUtc.HasValue || d >= s.FromUtc.Value) && (!s.ToUtc.HasValue || d < s.ToUtc.Value);
        }

        private IEnumerable<Work> Produce(List<FileCopyScope> scopes, FileCopyResult res)
        {
            foreach (var grp in scopes.GroupBy(s => s.ConversationKey, StringComparer.Ordinal))
            {
                string key = grp.Key;
                var t = _targets.Get(key);
                if (t == null || t.Kind == TargetKind.Skip) { Interlocked.Increment(ref res.NoTarget); Interlocked.Increment(ref _p.UnitsDone); continue; }
                var all = _store.ListFiles(key).ToList();
                var recs = all.Where(f => f.Status == FileStatus.Downloaded && !string.IsNullOrEmpty(f.Sha256)).ToList();
                Interlocked.Add(ref res.NotDownloaded, all.Count - recs.Count);
                Interlocked.Increment(ref _p.UnitsDone);
                if (recs.Count == 0) continue;
                bool unbounded = grp.Any(s => !s.FromUtc.HasValue && !s.ToUtc.HasValue);
                Dictionary<string, string> senders = null; HashSet<string> inWindow = null;
                if (!unbounded || IsChat(t))
                {
                    var need = new HashSet<string>(recs.Select(r => r.MessageId), StringComparer.Ordinal);
                    DateTimeOffset? min = null, max = null;
                    if (!unbounded && grp.All(s => s.FromUtc.HasValue)) min = grp.Min(s => s.FromUtc.Value);
                    if (!unbounded && grp.All(s => s.ToUtc.HasValue)) max = grp.Max(s => s.ToUtc.Value);
                    senders = new Dictionary<string, string>(StringComparer.Ordinal); inWindow = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var m in _store.ReadMessages(key, min, max))
                    {
                        string id = ExportUtil.Str(m, "id");
                        if (id == null || !need.Contains(id)) continue;
                        var created = ExportUtil.Date(m, "createdDateTime");
                        if (!unbounded && !(created.HasValue && grp.Any(s => Inside(s, created.Value)))) continue;
                        inWindow.Add(id);
                        JsonElement from, user;
                        senders[id] = m.TryGetProperty("from", out from) && from.ValueKind == JsonValueKind.Object && from.TryGetProperty("user", out user) && user.ValueKind == JsonValueKind.Object ? ExportUtil.Str(user, "id") : null;
                    }
                }
                foreach (var r in recs)
                {
                    if (!unbounded && !inWindow.Contains(r.MessageId)) continue;
                    string sender = null;
                    if (senders != null) senders.TryGetValue(r.MessageId, out sender);
                    yield return new Work { F = r, SenderId = sender, T = t };
                }
            }
        }

        // ------------------------------------------------------------------ one file

        private static string KeyOf(FileRecord f) { return f.ConversationKey + "|" + f.MessageId + "|" + f.AttachmentId; }

        private void Fail(FileCopyResult res, Work w, FileCopyRecord rec, Exception ex, string message = null)
        {
            string msg = message ?? ex.Message;
            if (msg != null && msg.Length > 400) msg = msg.Substring(0, 400);
            Interlocked.Increment(ref res.Failed);
            Interlocked.Increment(ref _p.Errors);
            _errors.Enqueue(ex != null ? ErrorRecord.From(KeyOf(w.F), "filecopy", ex, _now()) : new ErrorRecord { Scope = KeyOf(w.F), Operation = "filecopy", Message = msg, When = _now() });
            if (rec == null) rec = NewRecord(w.F);
            rec.State = FileCopyState.Failed; rec.Error = msg;
            _files.Upsert(rec);
        }

        private static FileCopyRecord NewRecord(FileRecord f)
        {
            return new FileCopyRecord { ConversationKey = f.ConversationKey, MessageId = f.MessageId, AttachmentId = f.AttachmentId ?? "", Sha256 = f.Sha256, Name = f.Name };
        }

        private async Task ProcessAsync(Work w, FileCopyResult res, CancellationToken ct)
        {
            var f = w.F;
            Interlocked.Increment(ref res.Files);
            FileCopyRecord rec = null;
            try
            {
                var prev = _files.Get(f.ConversationKey, f.MessageId, f.AttachmentId ?? "");
                if (prev != null && (prev.State == FileCopyState.Shared || prev.State == FileCopyState.Skipped)) { Interlocked.Increment(ref res.AlreadyDone); return; }

                if (FilesStage.IsExcluded(f.Name ?? f.SourceUrl, _o.ExcludedExtensions))
                { if (!res.DryRun) Skip(f, "extension excluded"); Interlocked.Increment(ref res.Excluded); Interlocked.Increment(ref res.Skipped); return; }
                if (_o.MaxFileBytes > 0 && f.Size.HasValue && f.Size.Value > _o.MaxFileBytes)
                { if (!res.DryRun) Skip(f, "larger than " + _o.MaxFileBytes + " bytes"); Interlocked.Increment(ref res.TooLarge); Interlocked.Increment(ref res.Skipped); return; }

                Dest d;
                try { d = ResolveOffline(w); }
                catch (WaitingForTarget wt)
                {
                    Interlocked.Increment(ref res.WaitingForTarget);
                    if (!res.DryRun) { rec = prev ?? NewRecord(f); rec.State = FileCopyState.Pending; rec.Error = wt.Message; _files.Upsert(rec); }
                    return;
                }
                catch (NoDestination nd)
                {
                    Interlocked.Increment(ref res.NoDestination);
                    if (!res.DryRun) Fail(res, w, prev, null, nd.Message);
                    return;
                }

                if (res.DryRun) { DryCount(res, d, f); return; }
                if (StopControl.Stopped(_run.Stop)) throw new StopRequested();

                rec = prev ?? NewRecord(f);
                rec.Sha256 = f.Sha256; rec.Name = f.Name;
                if (rec.State != FileCopyState.Uploaded || string.IsNullOrEmpty(rec.TargetItemId))
                {
                    await ResolveOnlineAsync(d, f, ct).ConfigureAwait(false);
                    var item = await GetOrUploadAsync(d, f, res, ct).ConfigureAwait(false);
                    if (item == null) return;     // skipped by the size limit once the real length is known
                    rec.TargetDriveId = item.DriveId ?? d.DriveId; rec.TargetItemId = item.Id; rec.TargetWebUrl = item.WebUrl;
                    rec.State = FileCopyState.Uploaded; rec.Error = null;
                    _files.Upsert(rec);
                    if (item.Reused) Interlocked.Increment(ref res.Reused);
                    else { Interlocked.Increment(ref res.Uploaded); }
                    Interlocked.Increment(ref _p.FilesDownloaded);
                }
                // share
                if (d.Channel || !_o.ShareChats) { rec.State = FileCopyState.Shared; rec.Error = null; _files.Upsert(rec); Interlocked.Increment(ref res.Shared); return; }
                string shareError = await ShareAsync(w, d, rec, res, ct).ConfigureAwait(false);
                if (shareError == null) { rec.State = FileCopyState.Shared; _files.Upsert(rec); Interlocked.Increment(ref res.Shared); }
                else { rec.State = FileCopyState.Uploaded; rec.Error = shareError; _files.Upsert(rec); Interlocked.Increment(ref res.SharingIncomplete); }
            }
            catch (StopRequested) { res.Stopped = true; }
            catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && (ex is GraphException || ex is IOException || ex is HttpRequestException || ex is TimeoutException || ex is InvalidOperationException))
            {
                Fail(res, w, rec, ex);
            }
        }

        private void Skip(FileRecord f, string why)
        {
            var r = NewRecord(f); r.State = FileCopyState.Skipped; r.Error = why; _files.Upsert(r);
        }

        // ------------------------------------------------------------------ destination

        private string OwnerOf(string senderId, out bool serviceAccount)
        {
            serviceAccount = false;
            IdentityMapping m = string.IsNullOrEmpty(senderId) ? null : _ids.Get(senderId);
            if (m != null && (m.Kind == IdentityKind.Mapped || m.Kind == IdentityKind.Same) && !string.IsNullOrEmpty(m.TargetUserId)) return m.TargetUserId;
            serviceAccount = true;
            if (!string.IsNullOrEmpty(_run.ServiceAccountUserId)) return _run.ServiceAccountUserId;
            if (m != null && m.Kind == IdentityKind.ServiceAccount && !string.IsNullOrEmpty(m.TargetUserId)) return m.TargetUserId;
            return null;
        }

        /// <summary>What can be known without a request: the destination kind and label. Throws WaitingForTarget / NoDestination.</summary>
        private Dest ResolveOffline(Work w)
        {
            var t = w.T;
            if (IsChat(t))
            {
                bool sa; string owner = OwnerOf(w.SenderId, out sa);
                if (owner == null) throw new NoDestination("no destination: the sender " + (w.SenderId ?? "(unknown)") + " has no usable target identity and no service account is configured (ServiceAccountUserId).");
                return new Dest { Label = "OneDrive:" + owner + (sa ? " (service account)" : ""), OwnerUserId = owner, ServiceAccount = sa };
            }
            if (string.IsNullOrEmpty(t.TargetTeamId) || string.IsNullOrEmpty(t.TargetChannelId))
                throw new WaitingForTarget("waiting for the target channel: it does not exist yet (the importer creates it), run the file copy again after the conversations are created.");
            return new Dest { Label = "Channel:" + t.TargetTeamId + "/" + t.TargetChannelId, Channel = true, TeamId = t.TargetTeamId, ChannelId = t.TargetChannelId };
        }

        private async Task ResolveOnlineAsync(Dest d, FileRecord f, CancellationToken ct)
        {
            if (!string.IsNullOrEmpty(d.DriveId)) return;
            if (d.Channel)
            {
                string ck = d.TeamId + "/" + d.ChannelId;
                ChannelFolder cf;
                if (!_channelFolder.TryGet(ck, out cf))
                {
                    using (var doc = await _g.GetJsonAsync("v1.0/teams/" + ExportUtil.Seg(d.TeamId) + "/channels/" + ExportUtil.Seg(d.ChannelId) + "/filesFolder", EndpointClass.DriveItem, f.ConversationKey, ct).ConfigureAwait(false))
                    {
                        var r = doc.RootElement;
                        string name = ExportUtil.Str(r, "name");
                        string parent = ExportUtil.Str(r, "parentReference", "path") ?? "";
                        int i = parent.IndexOf("root:", StringComparison.OrdinalIgnoreCase);
                        string rel = i >= 0 ? parent.Substring(i + 5) : "";
                        cf = new ChannelFolder { DriveId = ExportUtil.Str(r, "parentReference", "driveId"), FolderPath = (rel.Trim('/') + "/" + name).Trim('/') };
                    }
                    if (string.IsNullOrEmpty(cf.DriveId)) throw new InvalidOperationException("The files folder of channel " + ck + " did not return a drive id.");
                    _channelFolder.Set(ck, cf);
                }
                d.DriveId = cf.DriveId; d.FolderPath = cf.FolderPath;
            }
            else
            {
                string drive;
                if (!_userDrive.TryGet(d.OwnerUserId, out drive))
                {
                    try
                    {
                        using (var doc = await _g.GetJsonAsync("v1.0/users/" + ExportUtil.Seg(d.OwnerUserId) + "/drive?$select=id", EndpointClass.DriveItem, f.ConversationKey, ct).ConfigureAwait(false))
                            drive = ExportUtil.Str(doc.RootElement, "id");
                    }
                    catch (GraphException ex) when (ex.StatusCode == 404)
                    {
                        throw new InvalidOperationException("The OneDrive of user " + d.OwnerUserId + " does not exist (not provisioned yet: the user must sign in once, or provision it in advance).", ex);
                    }
                    if (string.IsNullOrEmpty(drive)) throw new InvalidOperationException("The OneDrive of user " + d.OwnerUserId + " did not return an id.");
                    _userDrive.Set(d.OwnerUserId, drive);
                }
                d.DriveId = drive; d.FolderPath = _o.ChatFilesFolder;
            }
        }

        // ------------------------------------------------------------------ dry run

        private void DryCount(FileCopyResult res, Dest d, FileRecord f)
        {
            long size = f.Size ?? 0;
            string key = d.Label + "|" + (d.Channel ? "" : _o.ChatFilesFolder) + "|" + f.Sha256;
            bool dup;
            lock (_dryDup) dup = !_dryDup.Add(key);
            var st = _dest.GetOrAdd(d.Label, l => new FileCopyDestinationStat { Destination = l });
            lock (st)
            {
                st.Files++;
                if (dup) st.Duplicates++; else st.Bytes += size;
            }
            if (!dup) Interlocked.Add(ref res.Bytes, size);
        }

        // ------------------------------------------------------------------ upload

        private static string SafeName(string name, string sha)
        {
            string n = string.IsNullOrWhiteSpace(name) ? (sha ?? "file").Substring(0, Math.Min(12, (sha ?? "file").Length)) : name.Trim();
            var sb = new StringBuilder(n.Length);
            foreach (char c in n)
                sb.Append(c < 32 || "\"*:<>?/\\|".IndexOf(c) >= 0 ? '_' : c);
            n = sb.ToString().TrimEnd('.', ' ');
            if (n.Length == 0) n = "file";
            if (n.Length > 200)
            {
                string ext = Path.GetExtension(n);
                if (ext.Length > 20) ext = "";
                n = n.Substring(0, 200 - ext.Length) + ext;
            }
            return n;
        }

        private static string Hex(string s)
        {
            using (var h = SHA256.Create()) return Convert.ToHexString(h.ComputeHash(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();
        }

        private static string EncPath(string folderPath, string name)
        {
            var parts = new List<string>();
            foreach (var seg in (folderPath ?? "").Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries)) parts.Add(Uri.EscapeDataString(seg));
            parts.Add(Uri.EscapeDataString(name));
            return string.Join("/", parts);
        }

        private async Task<Item> GetOrUploadAsync(Dest d, FileRecord f, FileCopyResult res, CancellationToken ct)
        {
            string ddKey = (d.DriveId + "|" + d.FolderPath + "|" + f.Sha256).ToLowerInvariant();
            Task<Item> t; bool owner = false;
            lock (_inflight)
            {
                if (!_inflight.TryGetValue(ddKey, out t)) { t = UploadCoreAsync(d, f, ddKey, res, ct); _inflight[ddKey] = t; owner = true; }
            }
            try
            {
                var item = await t.ConfigureAwait(false);
                if (item != null && !owner && !item.Reused) return new Item { Id = item.Id, WebUrl = item.WebUrl, DriveId = item.DriveId, Size = item.Size, Reused = true };
                return item;
            }
            finally { if (owner) lock (_inflight) _inflight.Remove(ddKey); }
        }

        private async Task<Item> UploadCoreAsync(Dest d, FileRecord f, string ddKey, FileCopyResult res, CancellationToken ct)
        {
            string ddScope = "fc:dd:" + ddKey;
            string cached = _store.GetCheckpoint(ddScope);
            if (!string.IsNullOrEmpty(cached))
            {
                var parts = cached.Split('\t');
                if (parts.Length >= 2)
                {
                    try
                    {
                        using (var doc = await _g.GetJsonAsync("v1.0/drives/" + ExportUtil.Seg(d.DriveId) + "/items/" + ExportUtil.Seg(parts[0]) + "?$select=id,webUrl,size", EndpointClass.DriveItem, f.ConversationKey, ct).ConfigureAwait(false))
                            return new Item { Id = parts[0], WebUrl = ExportUtil.Str(doc.RootElement, "webUrl") ?? parts[1], DriveId = d.DriveId, Reused = true };
                    }
                    catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 410) { _store.SetCheckpoint(ddScope, ""); }
                }
            }
            string name = SafeName(f.Name, f.Sha256);
            Item item;
            using (var s = _store.OpenContent(f.Sha256))
            {
                if (s == null) throw new IOException("The content " + f.Sha256 + " is not in the store (file not downloaded?).");
                long size = s.CanSeek ? s.Length : (f.Size ?? -1);
                if (size < 0) throw new IOException("The size of " + f.Sha256 + " is unknown.");
                if (_o.MaxFileBytes > 0 && size > _o.MaxFileBytes)
                {
                    Skip(f, "larger than " + _o.MaxFileBytes + " bytes"); Interlocked.Increment(ref res.TooLarge); Interlocked.Increment(ref res.Skipped);
                    return null;
                }
                item = size < _o.SmallFileLimit ? await UploadSmallAsync(d, f, name, s, size, ct).ConfigureAwait(false)
                    : await UploadLargeAsync(d, f, name, s, size, ddKey, res, ct).ConfigureAwait(false);
            }
            Interlocked.Add(ref res.Bytes, item.Size);
            Interlocked.Add(ref _p.Bytes, item.Size);
            var st = _dest.GetOrAdd(d.Label, l => new FileCopyDestinationStat { Destination = l });
            lock (st) { st.Files++; st.Bytes += item.Size; }
            _store.SetCheckpoint(ddScope, item.Id + "\t" + item.WebUrl);
            return item;
        }

        private static Item ParseItem(JsonDocument doc, string defaultDrive)
        {
            var r = doc.RootElement;
            long size = 0; JsonElement sz;
            if (r.TryGetProperty("size", out sz) && sz.ValueKind == JsonValueKind.Number) size = sz.GetInt64();
            return new Item { Id = ExportUtil.Str(r, "id"), WebUrl = ExportUtil.Str(r, "webUrl"), DriveId = ExportUtil.Str(r, "parentReference", "driveId") ?? defaultDrive, Size = size };
        }

        private async Task<Item> UploadSmallAsync(Dest d, FileRecord f, string name, Stream s, long size, CancellationToken ct)
        {
            var bytes = new byte[size];
            int got = 0, n;
            while (got < size && (n = await s.ReadAsync(bytes, got, (int)(size - got), ct).ConfigureAwait(false)) > 0) got += n;
            if (got != size) throw new IOException("The stored content of " + f.Sha256 + " is shorter than its recorded length.");
            var req = new GraphRequest
            {
                Method = HttpMethod.Put, EndpointClass = EndpointClass.DriveUpload, ThreadKey = f.ConversationKey, BodyBytes = bytes, ContentType = "application/octet-stream",
                Url = "v1.0/drives/" + ExportUtil.Seg(d.DriveId) + "/root:/" + EncPath(d.FolderPath, name) + ":/content?@microsoft.graph.conflictBehavior=" + _o.ConflictBehavior
            };
            using (var doc = await _g.SendJsonAsync(req, ct).ConfigureAwait(false))
            {
                var item = ParseItem(doc, d.DriveId);
                if (string.IsNullOrEmpty(item.Id)) throw new InvalidOperationException("The upload of " + name + " did not return an item.");
                if (item.Size != size) throw new IOException("Uploaded size " + item.Size + " differs from " + size + " for " + name + ".");
                return item;
            }
        }

        private sealed class SessionState { public string Url, Drive, Folder, Name, Sha; public long Size; }

        private SessionState LoadSession(string cpKey)
        {
            string v = _store.GetCheckpoint(cpKey);
            if (string.IsNullOrEmpty(v)) return null;
            try
            {
                using (var d = JsonDocument.Parse(v))
                {
                    var r = d.RootElement;
                    return new SessionState { Url = ExportUtil.Str(r, "url"), Drive = ExportUtil.Str(r, "drive"), Folder = ExportUtil.Str(r, "folder"), Name = ExportUtil.Str(r, "name"), Sha = ExportUtil.Str(r, "sha"), Size = r.GetProperty("size").GetInt64() };
                }
            }
            catch (Exception ex) when (ex is JsonException || ex is KeyNotFoundException || ex is InvalidOperationException) { return null; }
        }

        private void SaveSession(string cpKey, SessionState s)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject(); w.WriteString("url", s.Url); w.WriteString("drive", s.Drive); w.WriteString("folder", s.Folder); w.WriteString("name", s.Name); w.WriteString("sha", s.Sha); w.WriteNumber("size", s.Size); w.WriteEndObject();
                }
                _store.SetCheckpoint(cpKey, Encoding.UTF8.GetString(ms.ToArray()));
            }
        }

        /// <summary>Status of an upload session: next expected byte, or -1 when the session is gone (404/410).</summary>
        private async Task<long> SessionStatusAsync(string url, string thread, CancellationToken ct)
        {
            try
            {
                var req = new GraphRequest { Method = HttpMethod.Get, Url = url, Anonymous = true, EndpointClass = EndpointClass.DriveUpload, ThreadKey = thread };
                using (var doc = await _g.SendJsonAsync(req, ct).ConfigureAwait(false))
                    return doc == null ? -1 : NextExpected(doc.RootElement, -1);
            }
            catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 410) { return -1; }
        }

        private static long NextExpected(JsonElement root, long fallback)
        {
            JsonElement a;
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("nextExpectedRanges", out a) && a.ValueKind == JsonValueKind.Array && a.GetArrayLength() > 0)
            {
                string r = a[0].GetString() ?? "";
                int dash = r.IndexOf('-');
                long v;
                if (long.TryParse(dash >= 0 ? r.Substring(0, dash) : r, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return v;
            }
            return fallback;
        }

        private static bool IsTransient(Exception ex)
        {
            var g = ex as GraphException;
            if (g != null) return g.StatusCode == 0 || g.StatusCode == 416 || g.StatusCode >= 500 || g.StatusCode == 429;
            return ex is HttpRequestException || ex is IOException || ex is TimeoutException;
        }

        private async Task<Item> UploadLargeAsync(Dest d, FileRecord f, string name, Stream s, long size, string ddKey, FileCopyResult res, CancellationToken ct)
        {
            string cpKey = "fc:up:" + Hex(ddKey).Substring(0, 40);
            for (int restart = 0; ; restart++)
            {
                string url = null; long next = 0;
                var st = LoadSession(cpKey);
                if (st != null && st.Sha == f.Sha256 && st.Size == size && st.Drive == d.DriveId && st.Folder == d.FolderPath && st.Name == name)
                {
                    long n = await SessionStatusAsync(st.Url, f.ConversationKey, ct).ConfigureAwait(false);
                    if (n >= 0 && n < size) { url = st.Url; next = n; Interlocked.Increment(ref res.ResumedUploads); }
                }
                if (url == null)
                {
                    var body = "{\"item\":{\"@microsoft.graph.conflictBehavior\":\"" + _o.ConflictBehavior + "\",\"name\":" + JsonSerializer.Serialize(name) + "}}";
                    using (var doc = await _g.PostJsonAsync("v1.0/drives/" + ExportUtil.Seg(d.DriveId) + "/root:/" + EncPath(d.FolderPath, name) + ":/createUploadSession", body, EndpointClass.DriveUpload, f.ConversationKey, ct).ConfigureAwait(false))
                        url = ExportUtil.Str(doc.RootElement, "uploadUrl");
                    if (string.IsNullOrEmpty(url)) throw new InvalidOperationException("createUploadSession for " + name + " did not return an upload URL.");
                    SaveSession(cpKey, new SessionState { Url = url, Drive = d.DriveId, Folder = d.FolderPath, Name = name, Sha = f.Sha256, Size = size });
                }

                var buf = new byte[(int)Math.Min(_chunk, size)];
                int attempts = 0;
                bool expired = false;
                while (next < size)
                {
                    if (StopControl.Stopped(_run.Stop)) throw new StopRequested();
                    int want = (int)Math.Min(_chunk, size - next);
                    byte[] body = want == buf.Length ? buf : new byte[want];
                    ReadAt(s, next, body, want);
                    var req = new GraphRequest { Method = HttpMethod.Put, Url = url, Anonymous = true, BodyBytes = body, ContentType = "application/octet-stream", EndpointClass = EndpointClass.DriveUpload, ThreadKey = f.ConversationKey };
                    req.Headers["Content-Range"] = "bytes " + next + "-" + (next + want - 1) + "/" + size;
                    try
                    {
                        int status; string text;
                        using (var resp = await _g.SendAsync(req, ct).ConfigureAwait(false)) { status = resp.StatusCode; text = await resp.ReadAsStringAsync().ConfigureAwait(false); }
                        attempts = 0;
                        if (status == 200 || status == 201)
                        {
                            using (var doc = JsonDocument.Parse(text))
                            {
                                var item = ParseItem(doc, d.DriveId);
                                if (string.IsNullOrEmpty(item.Id)) throw new InvalidOperationException("The last fragment of " + name + " did not return an item.");
                                if (item.Size != size) throw new IOException("Uploaded size " + item.Size + " differs from " + size + " for " + name + ".");
                                _store.SetCheckpoint(cpKey, "");
                                return item;
                            }
                        }
                        long expect = next + want;
                        if (!string.IsNullOrEmpty(text)) using (var doc = JsonDocument.Parse(text)) expect = NextExpected(doc.RootElement, expect);
                        next = expect;
                    }
                    catch (GraphException ex) when (ex.StatusCode == 404 || ex.StatusCode == 410) { expired = true; break; }
                    catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && IsTransient(ex))
                    {
                        if (++attempts >= Math.Max(1, _o.FragmentAttempts)) throw;
                        long n = await SessionStatusAsync(url, f.ConversationKey, ct).ConfigureAwait(false);
                        if (n < 0) { expired = true; break; }
                        next = n;
                    }
                }
                if (expired || next >= size)
                {
                    _store.SetCheckpoint(cpKey, "");
                    if (restart >= 2) throw new InvalidOperationException("The upload session of " + name + " keeps expiring or ending without an item.");
                    continue;
                }
            }
        }

        private static void ReadAt(Stream s, long pos, byte[] buf, int count)
        {
            if (s.CanSeek) s.Position = pos;
            else if (s.Position != pos) throw new IOException("The store content stream cannot be repositioned.");
            int got = 0, n;
            while (got < count && (n = s.Read(buf, got, count - got)) > 0) got += n;
            if (got != count) throw new IOException("The stored content ended early (" + (pos + got) + " bytes).");
        }

        // ------------------------------------------------------------------ share

        private async Task<string[]> MembersOfAsync(Work w, CancellationToken ct)
        {
            var t = w.T;
            string[] list;
            if (_members.TryGet(w.F.ConversationKey, out list)) return list;
            var ids = new List<string>();
            if (t.TargetMemberIds != null && t.TargetMemberIds.Count > 0) ids.AddRange(t.TargetMemberIds);
            else if (!string.IsNullOrEmpty(t.TargetChatId))
                await foreach (var m in _g.GetPagedAsync("v1.0/chats/" + ExportUtil.Seg(t.TargetChatId) + "/members", EndpointClass.ChatMembers, null, null, w.F.ConversationKey, ct).ConfigureAwait(false))
                { string uid = ExportUtil.Str(m, "userId"); if (!string.IsNullOrEmpty(uid)) ids.Add(uid); }
            list = ids.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            _members.Set(w.F.ConversationKey, list);
            return list;
        }

        /// <summary>Returns null when the file is shared (or has nobody to share with), otherwise the reason it must be retried.</summary>
        private async Task<string> ShareAsync(Work w, Dest d, FileCopyRecord rec, FileCopyResult res, CancellationToken ct)
        {
            var all = await MembersOfAsync(w, ct).ConfigureAwait(false);
            var skip = _noShare.Value;
            var rcpt = all.Where(u => !string.Equals(u, d.OwnerUserId, StringComparison.OrdinalIgnoreCase) && !skip.Contains(u)).ToList();
            if (rcpt.Count == 0) return null;
            string url = "v1.0/drives/" + ExportUtil.Seg(rec.TargetDriveId) + "/items/" + ExportUtil.Seg(rec.TargetItemId) + "/invite";
            int refused = 0;
            for (int i = 0; i < rcpt.Count; i += Math.Max(1, _o.ShareBatchSize))
            {
                var chunk = rcpt.Skip(i).Take(Math.Max(1, _o.ShareBatchSize)).ToList();
                try { await InviteAsync(url, chunk, w.F.ConversationKey, ct).ConfigureAwait(false); }
                catch (GraphException ex) when (ex.StatusCode >= 400 && ex.StatusCode < 500 && ex.StatusCode != 429 && ex.StatusCode != 401)
                {
                    // one recipient the service refuses (guest, disabled...): grant the others one by one
                    foreach (var u in chunk)
                    {
                        try { await InviteAsync(url, new List<string> { u }, w.F.ConversationKey, ct).ConfigureAwait(false); }
                        catch (GraphException ex2) when (ex2.StatusCode >= 400 && ex2.StatusCode < 500 && ex2.StatusCode != 429 && ex2.StatusCode != 401) { refused++; }
                    }
                }
                catch (Exception ex) when (!ExportUtil.IsCancel(ex, ct) && (ex is GraphException || ex is HttpRequestException || ex is IOException || ex is TimeoutException))
                {
                    return "share incomplete: " + (ex.Message.Length > 200 ? ex.Message.Substring(0, 200) : ex.Message);
                }
            }
            if (refused > 0) { Interlocked.Add(ref res.RecipientsRefused, refused); rec.Error = "shared; " + refused + " of " + rcpt.Count + " recipient(s) refused by the service"; }
            else rec.Error = null;
            return null;
        }

        private async Task InviteAsync(string url, List<string> userIds, string thread, CancellationToken ct)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteBoolean("requireSignIn", true);
                    w.WriteBoolean("sendInvitation", false);
                    w.WriteStartArray("roles"); w.WriteStringValue("read"); w.WriteEndArray();
                    w.WriteStartArray("recipients");
                    foreach (var u in userIds) { w.WriteStartObject(); w.WriteString("objectId", u); w.WriteEndObject(); }
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                using (var doc = await _g.PostJsonAsync(url, Encoding.UTF8.GetString(ms.ToArray()), EndpointClass.DriveItem, thread, ct).ConfigureAwait(false)) { }
            }
        }
    }
}
