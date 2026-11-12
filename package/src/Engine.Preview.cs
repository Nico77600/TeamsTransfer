// =============================================================================
//  TeamsTransfer - engine, lot F: the Teams-like preview and the offline HTML archive
// -----------------------------------------------------------------------------
//  PreviewExporter reads an IStoreReader (raw Graph chatMessage JSON, streamed, never all in memory) and writes either
//    (a) a FOLDER archive : index.html + data\<conv>\<month>.js + search\<conv>.js + content\<sha256>.<ext>
//    (b) a SINGLE FILE    : one self-contained .html (gzip+base64 blocks for chunks / search / images, within a size budget)
//  scoped by user (all the conversations of a user), by conversation keys, or by team. The viewer (page) is package\templates\Archive.template.*.
//  Format: package\schemas\preview-v1.schema.json  (manifest + chunk + search file).
//
//  Chunks: one per conversation and month (split at MaxItemsPerChunk top-level items, never inside a channel thread). Chat items are
//  messages; channel items are posts (root + replies). The page loads a chunk when its month scrolls into view.
//  Data files of a folder archive are JSONP scripts (TT.chunk("<path>", [...])) so that the archive opens by double-click from file://,
//  where fetch() is blocked by the browsers; there is no network access of any kind.
//
//  Message bodies are NOT sanitized here (the page does it, with an allow-list, at render time: that is the security boundary). The generator
//  only rewrites <img> sources: a hosted content that was exported becomes "tt:<sha256>.<ext>", anything else "tt:missing" / "tt:remote".
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TeamsTransfer
{
    public static class PreviewDataset
    {
        public const string Schema = "preview-v1";
        public const string TemplateHtml = "Archive.template.html";
        public const string TemplateJs = "Archive.template.js";
        public static string MonthKey(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM", CultureInfo.InvariantCulture); }
    }

    public sealed class PreviewOptions
    {
        /// <summary>Folder (folder archive) or .html file path (single file).</summary>
        public string OutputPath { get; set; }
        public bool SingleFile { get; set; }
        /// <summary>Scope: all the conversations of this user (id, UPN or mail).</summary>
        public string User { get; set; }
        /// <summary>Scope: these conversation keys only (chat:... / channel:...).</summary>
        public string[] ConversationKeys { get; set; }
        /// <summary>Scope: the channels of this team.</summary>
        public string TeamId { get; set; }
        /// <summary>Whose messages go on the right (id, UPN or mail). Defaults to User.</summary>
        public string Viewer { get; set; }
        public string Language { get; set; } = "en";
        public string Title { get; set; }
        public string ScopeLabel { get; set; }
        /// <summary>Accent palette of the viewer: "House" (brand raspberry, default) or "Teams" (indigo).</summary>
        public string Accent { get; set; } = "House";
        public DateTimeOffset? FromUtc { get; set; }
        public DateTimeOffset? ToUtc { get; set; }
        /// <summary>Folder that contains Archive.template.html and Archive.template.js.</summary>
        public string TemplateDirectory { get; set; }
        /// <summary>Single file: total raw bytes of images and files that may be embedded (the rest is "not embedded").</summary>
        public long ContentBudgetBytes { get; set; } = 128L * 1024 * 1024;
        /// <summary>Single file: largest item that may be embedded.</summary>
        public long MaxEmbeddedItemBytes { get; set; } = 16L * 1024 * 1024;
        public int MaxItemsPerChunk { get; set; } = 2000;
        public Action<string> Progress { get; set; }
    }

    public sealed class PreviewResult
    {
        public string OutputPath { get; set; }
        public string Mode { get; set; }
        public int Conversations { get; set; }
        public long Messages { get; set; }
        public int Chunks { get; set; }
        public int Files { get; set; }
        public int FilesExported { get; set; }
        public int Images { get; set; }
        public int ImagesMissing { get; set; }
        public long ContentBytes { get; set; }
        public long OutputBytes { get; set; }
        public double Seconds { get; set; }
        public string ContentSecurityPolicy { get; set; }
        public List<string> Warnings { get; } = new List<string>();
    }

    public sealed class PreviewExporter
    {
        readonly IStoreReader _r;
        readonly PreviewOptions _o;
        readonly PreviewResult _res = new PreviewResult();
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        // users table of the archive: append-only, referenced by index
        readonly List<UserRef> _users = new List<UserRef>();
        readonly Dictionary<string, int> _userIx = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, UserRecord> _known = new Dictionary<string, UserRecord>(StringComparer.OrdinalIgnoreCase);

        sealed class UserRef { public string Id, Name, Upn, State; }

        // content placed so far (sha -> ref "sha.ext", or null when it could not be placed)
        readonly Dictionary<string, PlacedContent> _placed = new Dictionary<string, PlacedContent>(StringComparer.OrdinalIgnoreCase);
        sealed class PlacedContent { public string Ref; public bool Embedded; public long Length; }
        long _budgetLeft;
        Stream _single;                    // single-file output while data blocks are streamed
        string _folder;
        int _viewerIx = -1;
        string _ownerName;                 // display name of the user / viewer the archive is for (title)

        static readonly Regex ImgTag = new Regex(@"<img\b(?:[^>""']|""[^""]*""|'[^']*')*>", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        static readonly Regex SrcAttr = new Regex(@"\bsrc\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        static readonly Regex HostedId = new Regex(@"hostedContents/([^/?#""'\s]+)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        static readonly Regex BreakTag = new Regex(@"<(?:br|/p|/div|/li|/tr|/h[1-6]|/blockquote)\b[^>]*>", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        static readonly Regex AnyTag = new Regex(@"<[^>]*>", RegexOptions.Compiled);
        static readonly Regex Spaces = new Regex(@"\s+", RegexOptions.Compiled);
        static readonly Regex IsoDur = new Regex(@"^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        static readonly HashSet<string> RiskyExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "html", "htm", "xhtml", "shtml", "svg", "xml", "js", "mjs", "hta", "mht", "mhtml", "xht", "xsl", "xslt", "swf" };

        public PreviewExporter(IStoreReader reader, PreviewOptions options)
        {
            if (reader == null) throw new ArgumentNullException("reader");
            if (options == null) throw new ArgumentNullException("options");
            if (string.IsNullOrWhiteSpace(options.OutputPath)) throw new ArgumentException("OutputPath is required.");
            if (string.IsNullOrWhiteSpace(options.TemplateDirectory)) throw new ArgumentException("TemplateDirectory is required.");
            _r = reader; _o = options;
        }

        void Log(string s) { var p = _o.Progress; if (p != null) p(s); }

        // ================================================================================== entry point
        public PreviewResult Run()
        {
            var sw = Stopwatch.StartNew();
            string html = NormalizeNewlines(File.ReadAllText(Path.Combine(_o.TemplateDirectory, PreviewDataset.TemplateHtml), Utf8));
            string js = NormalizeNewlines(File.ReadAllText(Path.Combine(_o.TemplateDirectory, PreviewDataset.TemplateJs), Utf8));
            if (js.IndexOf("</script", StringComparison.OrdinalIgnoreCase) >= 0 || js.IndexOf("<!--", StringComparison.Ordinal) >= 0) throw new InvalidOperationException("The viewer script must not contain '</script' or '<!--'.");
            var sm = Regex.Match(html, @"<style>(.*?)</style>", RegexOptions.Singleline);
            if (!sm.Success) throw new InvalidOperationException("The viewer template has no <style> block.");
            string csp = "default-src 'none'; script-src 'sha256-" + Sha64(js) + "' 'self'; style-src 'sha256-" + Sha64(sm.Groups[1].Value) + "'; img-src 'self' data: blob:; " +
                         "connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'";
            _res.ContentSecurityPolicy = csp;
            _res.Mode = _o.SingleFile ? "single" : "folder";
            _budgetLeft = _o.ContentBudgetBytes;
            string lang = "en";   // the product is English only; the page keeps an i18n table so a translation can be added

            // --- catalog
            foreach (var u in _r.ListUsers()) { if (u.Id != null) _known[u.Id] = u; if (u.UserPrincipalName != null) _known["upn:" + u.UserPrincipalName] = u; if (u.Mail != null) _known["mail:" + u.Mail] = u; }
            var convs = SelectConversations();
            if (!string.IsNullOrWhiteSpace(_o.Viewer) || !string.IsNullOrWhiteSpace(_o.User))
            {
                var vu = FindUser(!string.IsNullOrWhiteSpace(_o.Viewer) ? _o.Viewer : _o.User);
                if (vu != null) { _viewerIx = UserIndex(vu.Id, vu.DisplayName, vu.UserPrincipalName ?? vu.Mail); _ownerName = vu.DisplayName ?? vu.UserPrincipalName ?? vu.Mail; }
                else _ownerName = !string.IsNullOrWhiteSpace(_o.Viewer) ? _o.Viewer : _o.User;
            }

            // --- output
            string indexPath;
            string head = null, tail = null;
            string[] parts = html.Split(new[] { "<!--TT:DATA-->" }, StringSplitOptions.None);
            if (parts.Length != 2) throw new InvalidOperationException("The viewer template must contain exactly one <!--TT:DATA--> marker.");
            string title = !string.IsNullOrWhiteSpace(_o.Title) ? _o.Title : "Teams archive" + (_ownerName != null ? " - " + _ownerName : "");
            // one pass: a value (title, topic...) that happens to contain "{{CSP}}" or "{{SCRIPT}}" is never substituted again
            var map = new Dictionary<string, string> { { "LANG", lang }, { "TITLE", WebUtility.HtmlEncode(title) }, { "CSP", WebUtility.HtmlEncode(csp) }, { "SCRIPT", js } };
            Func<string, string> fill = s => Regex.Replace(s, @"\{\{(LANG|TITLE|CSP|SCRIPT|MANIFEST)\}\}", m => map.ContainsKey(m.Groups[1].Value) ? map[m.Groups[1].Value] : m.Value);
            if (_o.SingleFile)
            {
                indexPath = Path.GetFullPath(_o.OutputPath);
                Directory.CreateDirectory(Path.GetDirectoryName(indexPath));
                _single = new FileStream(indexPath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16);
                head = fill(parts[0]); tail = parts[1];
                WriteText(_single, head);
            }
            else
            {
                _folder = Path.GetFullPath(_o.OutputPath);
                Directory.CreateDirectory(_folder);
                foreach (var d in new[] { "data", "search", "content" })   // a previous archive in the same folder: start clean (only the three folders this exporter owns)
                {
                    string dir = Path.Combine(_folder, d);
                    if (Directory.Exists(dir)) Directory.Delete(dir, true);
                    Directory.CreateDirectory(dir);
                }
                indexPath = Path.Combine(_folder, "index.html");
                tail = parts[0] + parts[1];
            }

            // --- conversations
            var convJson = new List<byte[]>();
            int n = 0;
            try
            {
                foreach (var c in convs)
                {
                    n++;
                    Log("Conversation " + n + "/" + convs.Count + ": " + (c.Topic ?? c.Key));
                    convJson.Add(ProcessConversation(c, "c" + n, lang));
                }
                _res.Conversations = n;

                // --- manifest
                byte[] manifest = BuildManifest(convJson, lang, title);
                string manifestText = Utf8.GetString(manifest);       // Utf8JsonWriter's default encoder escapes < > & ' : safe inside <script>
                map["MANIFEST"] = manifestText;
                tail = fill(tail);
                if (_single != null) { WriteText(_single, tail); _single.Flush(); _res.OutputBytes = _single.Length; }
                else { File.WriteAllText(indexPath, tail, Utf8); _res.OutputBytes += new FileInfo(indexPath).Length; }
            }
            finally { if (_single != null) { _single.Dispose(); _single = null; } }
            _res.OutputPath = _o.SingleFile ? indexPath : _folder;
            _res.Seconds = sw.Elapsed.TotalSeconds;
            return _res;
        }

        // The HTML parser turns CRLF into LF before the browser hashes an inline script / style: hash what the parser will see.
        static string NormalizeNewlines(string s) { return s.Replace("\r\n", "\n").Replace("\r", "\n"); }
        static string Sha64(string s) { return Convert.ToBase64String(SHA256.HashData(Utf8.GetBytes(s))); }
        static void WriteText(Stream s, string text) { var b = Utf8.GetBytes(text); s.Write(b, 0, b.Length); }

        // ================================================================================== selection
        UserRecord FindUser(string s)
        {
            if (string.IsNullOrWhiteSpace(s)) return null;
            s = s.Trim();
            UserRecord u;
            if (_known.TryGetValue(s, out u) || _known.TryGetValue("upn:" + s, out u) || _known.TryGetValue("mail:" + s, out u)) return u;
            return null;
        }

        List<ConversationRecord> SelectConversations()
        {
            IEnumerable<ConversationRecord> q;
            if (!string.IsNullOrWhiteSpace(_o.User))
            {
                var u = FindUser(_o.User);
                // not in the user table (case/format of the UPN differs, or only the id is known): fall back to the value as an id
                q = _r.ListConversations(u != null ? u.Id : _o.User.Trim(), null, _o.TeamId);
            }
            else if (!string.IsNullOrWhiteSpace(_o.TeamId)) q = _r.ListConversations(null, null, _o.TeamId);
            else q = _r.ListConversations();
            var list = q.ToList();
            if (list.Count == 0 && !string.IsNullOrWhiteSpace(_o.User) && FindUser(_o.User) == null) throw new ArgumentException("User not found in the store: " + _o.User);
            if (_o.ConversationKeys != null && _o.ConversationKeys.Length > 0)
            {
                var keys = new HashSet<string>(_o.ConversationKeys.Where(k => !string.IsNullOrWhiteSpace(k)), StringComparer.OrdinalIgnoreCase);
                list = list.Where(c => keys.Contains(c.Key)).ToList();
            }
            return list.OrderByDescending(c => c.LastActivityUtc ?? DateTimeOffset.MinValue).ToList();
        }

        // ================================================================================== users
        int UserIndex(string id, string name, string upn)
        {
            string key = !string.IsNullOrEmpty(id) ? id : (!string.IsNullOrEmpty(name) ? "name:" + name : null);
            if (key == null) return -1;
            int ix;
            if (_userIx.TryGetValue(key, out ix))
            {
                if (name != null && _users[ix].Name == null) _users[ix].Name = name;
                return ix;
            }
            UserRecord k = null;
            if (id != null) _known.TryGetValue(id, out k);
            var ur = new UserRef { Id = id, Name = (k != null && !string.IsNullOrEmpty(k.DisplayName)) ? k.DisplayName : name, Upn = k != null ? (k.UserPrincipalName ?? k.Mail) : upn, State = k != null ? k.State.ToString().ToLowerInvariant() : "unknown" };
            _users.Add(ur); _userIx[key] = _users.Count - 1;
            return _users.Count - 1;
        }

        // ================================================================================== a conversation
        sealed class ChunkState
        {
            public MemoryStream Ms; public Utf8JsonWriter W;
            public string Month; public int Items, Msgs; public long First, Last;
            public List<byte[]> Parts;
        }

        sealed class ConvState
        {
            public string Id; public ConversationRecord Rec; public Dictionary<string, FileRecord> Files;
            public ChunkState Cur; public Dictionary<string, int> Parts = new Dictionary<string, int>();
            public List<string> ChunkEntries = new List<string>();
            public string CurRootId; public int ItemOrdinal; public long Msgs;
            public List<string> SX = new List<string>(); public List<long> SMs = new List<long>(); public List<int> SAu = new List<int>(); public List<int> SIt = new List<int>();
            public long FirstMs, LastMs; public string Preview, PreviewBy;
            public int ChunkCount;
            public List<string> FileEntries = new List<string>();   // Files tab (capped)
            public long CurT; public int CurAu, CurItem;
            public Dictionary<string, string> UserNames;
        }

        byte[] ProcessConversation(ConversationRecord rec, string cid, string lang)
        {
            var cs = new ConvState { Id = cid, Rec = rec };
            cs.Files = new Dictionary<string, FileRecord>(StringComparer.Ordinal);
            foreach (var f in _r.ListFiles(rec.Key)) { cs.Files[f.MessageId + "|" + f.AttachmentId] = f; _res.Files++; }

            foreach (var el in _r.ReadMessages(rec.Key, _o.FromUtc, _o.ToUtc))
            {
                string id = Str(el, "id");
                string reply = Str(el, "replyToId");
                bool isReply = !string.IsNullOrEmpty(reply) && reply == cs.CurRootId && cs.Cur != null;
                long t = DateMs(el, "createdDateTime");
                if (!isReply)
                {
                    string month = PreviewDataset.MonthKey(t);
                    if (cs.Cur != null && (cs.Cur.Month != month || cs.Cur.Items >= _o.MaxItemsPerChunk)) FlushChunk(cs);
                    if (cs.Cur == null) StartChunk(cs, month);
                    cs.Cur.Items++; cs.ItemOrdinal++; cs.CurRootId = id;
                    if (cs.Cur.First == 0 || t < cs.Cur.First) cs.Cur.First = t;
                    if (t > cs.Cur.Last) cs.Cur.Last = t;
                }
                cs.Cur.Msgs++; cs.Msgs++;
                WriteMessage(cs, el, id, t, reply, isReply ? cs.ItemOrdinal - 1 : cs.ItemOrdinal - 1);
                _res.Messages++;
                if (cs.FirstMs == 0 || t < cs.FirstMs) cs.FirstMs = t;
                if (t > cs.LastMs) cs.LastMs = t;
            }
            FlushChunk(cs);

            // search file
            string searchRef = null;
            if (cs.SX.Count > 0) searchRef = WriteSearch(cs);

            // conversation entry
            return BuildConversationEntry(cs, searchRef, lang);
        }

        void StartChunk(ConvState cs, string month)
        {
            var ms = new MemoryStream();
            var w = new Utf8JsonWriter(ms);
            w.WriteStartArray();
            cs.Cur = new ChunkState { Ms = ms, W = w, Month = month };
        }

        void FlushChunk(ConvState cs)
        {
            var c = cs.Cur; if (c == null) return;
            c.W.WriteEndArray(); c.W.Flush(); c.W.Dispose();
            byte[] json = c.Ms.ToArray();
            int part;
            cs.Parts.TryGetValue(c.Month, out part); part++; cs.Parts[c.Month] = part;
            string name = c.Month + (part > 1 ? "." + part : "");
            string f;
            if (_o.SingleFile)
            {
                f = "d-" + cs.Id + "-" + cs.ChunkCount;
                WriteGzipBlock(f, json, null);
            }
            else
            {
                f = "data/" + cs.Id + "/" + name + ".js";
                string path = Path.Combine(_folder, "data", cs.Id);
                Directory.CreateDirectory(path);
                using (var fs = new FileStream(Path.Combine(path, name + ".js"), FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16))
                {
                    WriteText(fs, "TT.chunk(" + JsonSerializer.Serialize(f) + ",");
                    fs.Write(json, 0, json.Length);
                    WriteText(fs, ");\n");
                    _res.OutputBytes += fs.Length;
                }
            }
            cs.ChunkCount++; _res.Chunks++;
            cs.ChunkEntries.Add("{\"k\":" + JsonSerializer.Serialize(name) + ",\"f\":" + JsonSerializer.Serialize(f) + ",\"n\":" + c.Items + ",\"m\":" + c.Msgs + ",\"a\":" + c.First + ",\"b\":" + c.Last + ",\"z\":" + json.Length + "}");
            cs.Cur = null;
        }

        void WriteGzipBlock(string id, byte[] json, string mime)
        {
            byte[] gz;
            using (var o = new MemoryStream())
            {
                using (var g = new GZipStream(o, CompressionLevel.Optimal, true)) g.Write(json, 0, json.Length);
                gz = o.ToArray();
            }
            WriteText(_single, "<script type=\"application/x-tt-gzip\" id=\"" + id + "\">");
            WriteText(_single, Convert.ToBase64String(gz));
            WriteText(_single, "</script>\n");
        }

        string WriteSearch(ConvState cs)
        {
            byte[] json;
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteStartArray("x"); foreach (var s in cs.SX) w.WriteStringValue(s); w.WriteEndArray();
                    w.WriteStartArray("ms"); foreach (var v in cs.SMs) w.WriteNumberValue(v); w.WriteEndArray();
                    w.WriteStartArray("au"); foreach (var v in cs.SAu) w.WriteNumberValue(v); w.WriteEndArray();
                    w.WriteStartArray("it"); foreach (var v in cs.SIt) w.WriteNumberValue(v); w.WriteEndArray();
                    w.WriteEndObject();
                }
                json = ms.ToArray();
            }
            if (_o.SingleFile) { string id = "s-" + cs.Id; WriteGzipBlock(id, json, null); return id; }
            string rel = "search/" + cs.Id + ".js";
            using (var fs = new FileStream(Path.Combine(_folder, "search", cs.Id + ".js"), FileMode.Create, FileAccess.Write, FileShare.Read))
            {
                WriteText(fs, "TT.search(" + JsonSerializer.Serialize(rel) + ",");
                fs.Write(json, 0, json.Length);
                WriteText(fs, ");\n");
                _res.OutputBytes += fs.Length;
            }
            return rel;
        }

        // ================================================================================== messages
        static string Str(JsonElement e, string name)
        {
            JsonElement v;
            return e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }
        static JsonElement Obj(JsonElement e, string name)
        {
            JsonElement v;
            return e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.Object ? v : default(JsonElement);
        }
        static long DateMs(JsonElement e, string name)
        {
            string s = Str(e, name);
            DateTimeOffset d;
            if (s != null && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out d) && d.Year > 1) return d.ToUnixTimeMilliseconds();
            return 0;
        }

        void WriteMessage(ConvState cs, JsonElement el, string id, long t, string reply, int itemOrdinal)
        {
            var w = cs.Cur.W;
            bool sys = Str(el, "messageType") == "systemEventMessage";
            long edited = DateMs(el, "lastEditedDateTime"), deleted = DateMs(el, "deletedDateTime");
            var body = Obj(el, "body");
            bool text = Str(body, "contentType") == "text";
            string content = Str(body, "content") ?? "";
            w.WriteStartObject();
            w.WriteString("i", id);
            w.WriteNumber("t", t);
            // author
            int au = -1; string an = null; bool bot = false;
            var from = Obj(el, "from");
            var fu = Obj(from, "user"); var fa = Obj(from, "application"); var fd = Obj(from, "device");
            if (fu.ValueKind == JsonValueKind.Object) { au = UserIndex(Str(fu, "id"), Str(fu, "displayName"), null); }
            else if (fa.ValueKind == JsonValueKind.Object) { an = Str(fa, "displayName") ?? Str(fa, "id"); bot = true; }
            else if (fd.ValueKind == JsonValueKind.Object) { an = Str(fd, "displayName"); }
            w.WriteNumber("a", au);
            if (an != null) w.WriteString("an", an);
            if (bot) w.WriteBoolean("ab", true);
            if (sys) w.WriteNumber("k", 1);
            if (edited > 0) w.WriteNumber("e", edited);
            if (deleted > 0) w.WriteNumber("d", deleted);
            if (!string.IsNullOrEmpty(reply)) w.WriteString("r", reply);
            string subject = Str(el, "subject");
            if (!string.IsNullOrEmpty(subject)) w.WriteString("s", subject);
            string imp = Str(el, "importance");
            if (imp == "high" || imp == "urgent") w.WriteString("im", imp);
            var searchText = new StringBuilder();
            if (!string.IsNullOrEmpty(subject)) searchText.Append(subject).Append(' ');

            if (sys) WriteSystem(w, el);
            else if (deleted == 0)
            {
                if (text) w.WriteString("f", "t");
                string b = text ? content : RewriteImages(cs, content, id);
                w.WriteString("b", b);
                searchText.Append(text ? content : HtmlToText(content)).Append(' ');
                WriteMentions(w, el);
                WriteReactions(w, el);
                cs.CurT = t; cs.CurAu = au; cs.CurItem = itemOrdinal;
                WriteAttachments(w, cs, el, id, searchText);
            }
            w.WriteEndObject();

            if (!sys && deleted == 0)
            {
                string line = Spaces.Replace(searchText.ToString(), " ").Trim();
                if (line.Length > 0)
                {
                    if (line.Length > 1200) line = line.Substring(0, 1200);
                    cs.SX.Add(line); cs.SMs.Add(t); cs.SAu.Add(au); cs.SIt.Add(itemOrdinal);
                    string pv = line.Length > 110 ? line.Substring(0, 110) : line;
                    cs.Preview = pv; cs.PreviewBy = au >= 0 ? FirstName(_users[au].Name) : an;
                }
            }
        }

        static string FirstName(string n)
        {
            if (string.IsNullOrWhiteSpace(n)) return null;
            return n.Trim().Split(' ')[0];
        }

        static string HtmlToText(string html)
        {
            if (string.IsNullOrEmpty(html)) return "";
            string s = BreakTag.Replace(html, " ");
            s = AnyTag.Replace(s, "");
            return Spaces.Replace(WebUtility.HtmlDecode(s), " ").Trim();
        }

        // ---------------------------------------------------------------- images
        string RewriteImages(ConvState cs, string html, string messageId)
        {
            if (html.IndexOf("<img", StringComparison.OrdinalIgnoreCase) < 0) return html;
            return ImgTag.Replace(html, m =>
            {
                string tag = m.Value;
                var sm = SrcAttr.Match(tag);
                if (!sm.Success) return tag;
                string src = sm.Groups[1].Success ? sm.Groups[1].Value : sm.Groups[2].Success ? sm.Groups[2].Value : sm.Groups[3].Value;
                string token = "tt:remote";
                var hm = HostedId.Match(src);
                if (hm.Success)
                {
                    _res.Images++;
                    string sha = null;
                    try { sha = _r.FindHostedContent(cs.Rec.Key, messageId, WebUtility.UrlDecode(hm.Groups[1].Value)); } catch (Exception ex) { _res.Warnings.Add("Hosted content lookup failed: " + ex.Message); }
                    var pc = sha == null ? null : Place(sha.ToLowerInvariant(), null, true);
                    if (pc != null && pc.Ref != null) token = "tt:" + pc.Ref; else { token = "tt:missing"; _res.ImagesMissing++; }
                }
                return tag.Substring(0, sm.Index) + "src=\"" + token + "\"" + tag.Substring(sm.Index + sm.Length);
            });
        }

        // ---------------------------------------------------------------- content placement
        static string SniffImageExt(byte[] h, int n)
        {
            if (n >= 8 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return "png";
            if (n >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF) return "jpg";
            if (n >= 4 && h[0] == 'G' && h[1] == 'I' && h[2] == 'F' && h[3] == '8') return "gif";
            if (n >= 12 && h[0] == 'R' && h[1] == 'I' && h[2] == 'F' && h[3] == 'F' && h[8] == 'W' && h[9] == 'E' && h[10] == 'B' && h[11] == 'P') return "webp";
            if (n >= 26 && h[0] == 'B' && h[1] == 'M') return "bmp";
            return null;
        }
        static string FileExt(string name)
        {
            string e = "";
            try { e = (Path.GetExtension(name ?? "") ?? "").TrimStart('.').ToLowerInvariant(); } catch { }
            if (e.Length == 0 || e.Length > 5 || !Regex.IsMatch(e, "^[a-z0-9]+$") || RiskyExt.Contains(e)) return "bin";
            return e;
        }
        static string MimeOf(string ext)
        {
            switch (ext)
            {
                case "png": return "image/png"; case "jpg": case "jpeg": return "image/jpeg"; case "gif": return "image/gif"; case "webp": return "image/webp"; case "bmp": return "image/bmp";
                case "pdf": return "application/pdf"; case "txt": return "text/plain"; default: return "application/octet-stream";
            }
        }

        /// <summary>Copies (folder) or embeds (single file, within the budget) a content of the store. isImage: the extension comes from the bytes. Returns null Ref on failure.</summary>
        PlacedContent Place(string sha, string fileName, bool isImage)
        {
            PlacedContent pc;
            if (_placed.TryGetValue(sha, out pc)) return pc;
            pc = new PlacedContent();
            _placed[sha] = pc;
            try
            {
                using (var src = _r.OpenContent(sha))
                {
                    var head = new byte[16]; int hn = 0, r;
                    while (hn < head.Length && (r = src.Read(head, hn, head.Length - hn)) > 0) hn += r;
                    string ext = isImage ? (SniffImageExt(head, hn) ?? "bin") : FileExt(fileName);
                    if (!isImage && ext == "bin") ext = SniffImageExt(head, hn) ?? "bin";
                    pc.Ref = sha + "." + ext;
                    if (_o.SingleFile)
                    {
                        long cap = Math.Min(_o.MaxEmbeddedItemBytes, _budgetLeft);
                        long known = -1; try { known = src.CanSeek ? src.Length : -1; } catch { }
                        if (cap <= 0 || (known >= 0 && known > cap)) { pc.Embedded = false; return pc; }
                        var buf = new MemoryStream();
                        buf.Write(head, 0, hn);
                        var chunk = new byte[1 << 16]; bool over = false;
                        while ((r = src.Read(chunk, 0, chunk.Length)) > 0)
                        {
                            buf.Write(chunk, 0, r);
                            if (buf.Length > cap) { over = true; break; }
                        }
                        if (over) { pc.Embedded = false; return pc; }
                        _budgetLeft -= buf.Length; pc.Length = buf.Length; pc.Embedded = true;
                        WriteText(_single, "<script type=\"application/x-tt-content\" id=\"i-" + pc.Ref + "\" data-type=\"" + MimeOf(ext) + "\">");
                        WriteText(_single, Convert.ToBase64String(buf.GetBuffer(), 0, (int)buf.Length));
                        WriteText(_single, "</script>\n");
                        _res.ContentBytes += buf.Length;
                    }
                    else
                    {
                        string path = Path.Combine(_folder, "content", pc.Ref);
                        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16))
                        {
                            fs.Write(head, 0, hn);
                            src.CopyTo(fs, 1 << 16);
                            pc.Length = fs.Length; _res.ContentBytes += fs.Length; _res.OutputBytes += fs.Length;
                        }
                        pc.Embedded = true;
                    }
                }
            }
            catch (Exception ex)
            {
                _res.Warnings.Add("Content " + sha + " not placed: " + ex.Message);
                pc.Ref = null; pc.Embedded = false;
            }
            return pc;
        }

        // ---------------------------------------------------------------- mentions, reactions
        void WriteMentions(Utf8JsonWriter w, JsonElement el)
        {
            JsonElement arr;
            if (!el.TryGetProperty("mentions", out arr) || arr.ValueKind != JsonValueKind.Array || arr.GetArrayLength() == 0) return;
            w.WriteStartArray("mn");
            foreach (var m in arr.EnumerateArray())
            {
                JsonElement idEl; long id = 0;
                if (m.TryGetProperty("id", out idEl) && idEl.ValueKind == JsonValueKind.Number) idEl.TryGetInt64(out id);
                var mentioned = Obj(m, "mentioned"); var u = Obj(mentioned, "user"); var conv = Obj(mentioned, "conversation");
                int ix = u.ValueKind == JsonValueKind.Object ? UserIndex(Str(u, "id"), Str(u, "displayName"), null) : -1;
                string name = Str(m, "mentionText") ?? Str(u, "displayName") ?? Str(conv, "displayName") ?? "";
                w.WriteStartArray(); w.WriteNumberValue(id); w.WriteStringValue(name); w.WriteNumberValue(ix); w.WriteEndArray();
            }
            w.WriteEndArray();
        }

        void WriteReactions(Utf8JsonWriter w, JsonElement el)
        {
            JsonElement arr;
            if (!el.TryGetProperty("reactions", out arr) || arr.ValueKind != JsonValueKind.Array || arr.GetArrayLength() == 0) return;
            var order = new List<string>(); var who = new Dictionary<string, List<object>>();
            foreach (var r in arr.EnumerateArray())
            {
                string type = Str(r, "reactionType") ?? "like";
                var ru = Obj(Obj(r, "user"), "user");
                object o;
                if (ru.ValueKind == JsonValueKind.Object) { int ix = UserIndex(Str(ru, "id"), Str(ru, "displayName"), null); o = ix >= 0 ? (object)ix : (Str(ru, "displayName") ?? "?"); }
                else o = "?";
                List<object> l;
                if (!who.TryGetValue(type, out l)) { who[type] = l = new List<object>(); order.Add(type); }
                l.Add(o);
            }
            w.WriteStartArray("rx");
            foreach (var type in order)
            {
                w.WriteStartArray(); w.WriteStringValue(type);
                w.WriteStartArray(); foreach (var o in who[type]) { if (o is int) w.WriteNumberValue((int)o); else w.WriteStringValue((string)o); } w.WriteEndArray();
                w.WriteEndArray();
            }
            w.WriteEndArray();
        }

        // ---------------------------------------------------------------- attachments
        void WriteAttachments(Utf8JsonWriter w, ConvState cs, JsonElement el, string messageId, StringBuilder searchText)
        {
            JsonElement arr;
            if (!el.TryGetProperty("attachments", out arr) || arr.ValueKind != JsonValueKind.Array || arr.GetArrayLength() == 0) return;
            w.WriteStartArray("at");
            foreach (var a in arr.EnumerateArray())
            {
                string ct = Str(a, "contentType") ?? "";
                string name = Str(a, "name");
                string aid = Str(a, "id");
                if (ct == "reference")
                {
                    FileRecord fr;
                    cs.Files.TryGetValue(messageId + "|" + aid, out fr);
                    w.WriteStartObject();
                    w.WriteString("c", "file");
                    w.WriteString("n", name ?? (fr != null ? fr.Name : null) ?? "file");
                    if (fr != null && fr.Size.HasValue) w.WriteNumber("sz", fr.Size.Value);
                    string st = "unknown", rf = null;
                    if (fr != null)
                    {
                        if (fr.Status == FileStatus.Downloaded && !string.IsNullOrEmpty(fr.Sha256))
                        {
                            var pc = Place(fr.Sha256.ToLowerInvariant(), name ?? fr.Name, false);
                            if (pc.Ref == null) st = "failed";
                            else if (!pc.Embedded) st = _o.SingleFile ? "notembedded" : "failed";
                            else { st = "ok"; rf = pc.Ref; _res.FilesExported++; }
                        }
                        else st = fr.Status.ToString().ToLowerInvariant();
                    }
                    w.WriteString("st", st);
                    if (rf != null) w.WriteString("ref", rf);
                    w.WriteEndObject();
                    if (cs.FileEntries.Count < 2000)
                        cs.FileEntries.Add("{\"n\":" + JsonSerializer.Serialize(name ?? (fr != null ? fr.Name : null) ?? "file") + (fr != null && fr.Size.HasValue ? ",\"sz\":" + fr.Size.Value : "") + ",\"st\":\"" + st + "\"" + (rf != null ? ",\"ref\":\"" + rf + "\"" : "") + ",\"t\":" + cs.CurT + ",\"a\":" + cs.CurAu + ",\"it\":" + cs.CurItem + "}");
                    if (name != null) searchText.Append(name).Append(' ');
                }
                else if (ct == "messageReference")
                {
                    string preview = null, sender = null;
                    try
                    {
                        using (var d = JsonDocument.Parse(Str(a, "content") ?? "{}"))
                        {
                            preview = Str(d.RootElement, "messagePreview");
                            var ms = Obj(d.RootElement, "messageSender");
                            sender = Str(Obj(ms, "user"), "displayName") ?? Str(Obj(ms, "application"), "displayName");
                        }
                    }
                    catch (JsonException) { }
                    w.WriteStartObject(); w.WriteString("c", "quote");
                    string qid = null;
                    try { using (var d = JsonDocument.Parse(Str(a, "content") ?? "{}")) qid = Str(d.RootElement, "messageId"); } catch (JsonException) { }
                    if (qid != null) w.WriteString("id", qid);
                    if (sender != null) w.WriteString("sn", sender);
                    if (preview != null) w.WriteString("pv", preview.Length > 400 ? preview.Substring(0, 400) : preview);
                    w.WriteEndObject();
                }
                else if (ct.StartsWith("application/vnd.microsoft.card.", StringComparison.OrdinalIgnoreCase))
                {
                    var lines = new List<string>(); string title = null;
                    try
                    {
                        using (var d = JsonDocument.Parse(Str(a, "content") ?? "{}"))
                        {
                            CardTexts(d.RootElement, lines, 0);
                            title = Str(d.RootElement, "title");
                        }
                    }
                    catch (JsonException) { }
                    if (title == null && lines.Count > 0) { title = lines[0]; lines.RemoveAt(0); }
                    else if (title != null && lines.Count > 0 && lines[0] == title) lines.RemoveAt(0);
                    w.WriteStartObject(); w.WriteString("c", "card");
                    w.WriteString("ty", ct.EndsWith("adaptive", StringComparison.OrdinalIgnoreCase) ? "adaptive" : ct.EndsWith("hero", StringComparison.OrdinalIgnoreCase) ? "hero" : "other");
                    if (title != null) w.WriteString("ti", Clip(title, 200));
                    w.WriteStartArray("tx"); foreach (var l in lines.Take(8)) w.WriteStringValue(Clip(l, 300)); w.WriteEndArray();
                    w.WriteEndObject();
                    if (title != null) searchText.Append(title).Append(' ');
                    foreach (var l in lines.Take(8)) searchText.Append(l).Append(' ');
                }
                else
                {
                    w.WriteStartObject(); w.WriteString("c", "other");
                    if (name != null) w.WriteString("n", name);
                    w.WriteString("ty", ct);
                    w.WriteEndObject();
                    if (name != null) searchText.Append(name).Append(' ');
                }
            }
            w.WriteEndArray();
        }

        static string Clip(string s, int n) { return s.Length > n ? s.Substring(0, n) : s; }

        /// <summary>Neutral summary of an adaptive / hero card: every "text", "title", "subtitle", fact title/value, in document order.</summary>
        static void CardTexts(JsonElement e, List<string> lines, int depth)
        {
            if (depth > 12 || lines.Count >= 40) return;
            if (e.ValueKind == JsonValueKind.Array) { foreach (var x in e.EnumerateArray()) CardTexts(x, lines, depth + 1); return; }
            if (e.ValueKind != JsonValueKind.Object) return;
            foreach (var p in e.EnumerateObject())
            {
                if (p.Value.ValueKind == JsonValueKind.String && (p.Name == "text" || p.Name == "title" || p.Name == "subtitle" || p.Name == "value" || p.Name == "altText" || p.Name == "label" || p.Name == "placeholder"))
                {
                    string s = Spaces.Replace(p.Value.GetString() ?? "", " ").Trim();
                    if (s.Length > 0 && !lines.Contains(s)) lines.Add(s);
                }
                else if (p.Value.ValueKind == JsonValueKind.Object || p.Value.ValueKind == JsonValueKind.Array) CardTexts(p.Value, lines, depth + 1);
            }
        }

        // ---------------------------------------------------------------- system events
        void WriteSystem(Utf8JsonWriter w, JsonElement el)
        {
            var ev = Obj(el, "eventDetail");
            if (ev.ValueKind != JsonValueKind.Object) { w.WriteStartObject("sy"); w.WriteString("ty", "unknown"); w.WriteEndObject(); return; }
            string type = Str(ev, "@odata.type") ?? "";
            int hash = type.LastIndexOf('.'); if (hash >= 0) type = type.Substring(hash + 1);
            if (type.EndsWith("EventMessageDetail", StringComparison.Ordinal)) type = type.Substring(0, type.Length - "EventMessageDetail".Length);
            if (type.Length > 0) type = char.ToLowerInvariant(type[0]) + type.Substring(1);
            var ini = Obj(ev, "initiator");
            string by = Str(Obj(ini, "user"), "displayName") ?? Str(Obj(ini, "application"), "displayName");
            if (by == null) { string iid = Str(Obj(ini, "user"), "id"); UserRecord k; if (iid != null && _known.TryGetValue(iid, out k)) by = k.DisplayName; }
            w.WriteStartObject("sy");
            w.WriteString("ty", type);
            if (by != null) w.WriteString("by", by);
            JsonElement members;
            if (ev.TryGetProperty("members", out members) && members.ValueKind == JsonValueKind.Array)
            {
                var names = new List<string>();
                foreach (var m in members.EnumerateArray())
                {
                    string nm = Str(m, "displayName"); string mid = Str(m, "id");
                    UserRecord k;
                    if (string.IsNullOrEmpty(nm) && mid != null && _known.TryGetValue(mid, out k)) nm = k.DisplayName;
                    if (!string.IsNullOrEmpty(nm)) names.Add(nm);
                }
                if (names.Count > 0) { w.WriteStartArray("who"); foreach (var n in names.Take(20)) w.WriteStringValue(n); w.WriteEndArray(); }
            }
            string nm2 = Str(ev, "chatDisplayName") ?? Str(ev, "channelDisplayName") ?? Str(ev, "teamDisplayName") ?? Str(ev, "teamsAppDisplayName") ?? Str(ev, "displayName");
            if (nm2 != null) w.WriteString("nm", nm2);
            string dur = Str(ev, "callDuration");
            if (dur != null)
            {
                var dm = IsoDur.Match(dur);
                if (dm.Success)
                {
                    double sec = (dm.Groups[1].Success ? double.Parse(dm.Groups[1].Value, CultureInfo.InvariantCulture) * 86400 : 0) + (dm.Groups[2].Success ? double.Parse(dm.Groups[2].Value, CultureInfo.InvariantCulture) * 3600 : 0) +
                                 (dm.Groups[3].Success ? double.Parse(dm.Groups[3].Value, CultureInfo.InvariantCulture) * 60 : 0) + (dm.Groups[4].Success ? double.Parse(dm.Groups[4].Value, CultureInfo.InvariantCulture) : 0);
                    w.WriteNumber("du", (long)Math.Round(sec));
                }
            }
            w.WriteEndObject();
        }

        // ================================================================================== manifest
        byte[] BuildConversationEntry(ConvState cs, string searchRef, string lang)
        {
            var rec = cs.Rec;
            var members = new List<int>(); int memberCount = rec.MemberCount;
            var memberNames = new List<string>();
            if (!string.IsNullOrEmpty(rec.MembersJson))
            {
                try
                {
                    using (var d = JsonDocument.Parse(rec.MembersJson))
                    {
                        if (d.RootElement.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var m in d.RootElement.EnumerateArray())
                            {
                                int ix = UserIndex(Str(m, "userId"), Str(m, "displayName"), Str(m, "email"));
                                if (ix >= 0 && members.Count < 500 && !members.Contains(ix)) members.Add(ix);
                            }
                            if (memberCount <= 0) memberCount = d.RootElement.GetArrayLength();
                        }
                    }
                }
                catch (JsonException) { }
            }
            string title = rec.Topic;
            if (rec.Kind == ConversationKind.Channel) title = string.IsNullOrWhiteSpace(rec.Topic) ? rec.ChannelId : rec.Topic;
            else if (string.IsNullOrWhiteSpace(title))
            {
                var others = members.Where(ix => ix != _viewerIx).Select(ix => _users[ix].Name).Where(n => !string.IsNullOrEmpty(n)).ToList();
                if (others.Count == 0) others = members.Select(ix => _users[ix].Name).Where(n => !string.IsNullOrEmpty(n)).ToList();
                if (others.Count > 0) title = string.Join(rec.Kind == ConversationKind.OneOnOne ? " & " : ", ", others.Take(3)) + (others.Count > 3 ? " +" + (others.Count - 3) : "");
                else title = rec.Kind == ConversationKind.Meeting ? ("Meeting") : "Conversation";
            }
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("id", cs.Id);
                    w.WriteString("key", rec.Key);
                    w.WriteString("kind", rec.Kind == ConversationKind.OneOnOne ? "oneOnOne" : rec.Kind == ConversationKind.Group ? "group" : rec.Kind == ConversationKind.Meeting ? "meeting" : "channel");
                    if (rec.Kind == ConversationKind.Channel) w.WriteString("membership", string.IsNullOrEmpty(rec.MembershipType) ? "standard" : rec.MembershipType.ToLowerInvariant());
                    w.WriteString("title", title);
                    if (rec.Kind == ConversationKind.Channel) { w.WriteString("team", rec.TeamDisplayName ?? rec.TeamId); w.WriteString("teamId", rec.TeamId ?? ""); }
                    w.WriteStartArray("members"); foreach (var ix in members) w.WriteNumberValue(ix); w.WriteEndArray();
                    w.WriteNumber("memberCount", memberCount);
                    w.WriteNumber("count", cs.Msgs);
                    long first = cs.FirstMs != 0 ? cs.FirstMs : (rec.CreatedUtc.HasValue ? rec.CreatedUtc.Value.ToUnixTimeMilliseconds() : 0);
                    long last = cs.LastMs != 0 ? cs.LastMs : (rec.LastActivityUtc.HasValue ? rec.LastActivityUtc.Value.ToUnixTimeMilliseconds() : first);
                    w.WriteNumber("first", first); w.WriteNumber("last", last);
                    if (cs.Preview != null) w.WriteString("preview", cs.Preview);
                    if (cs.PreviewBy != null) w.WriteString("previewBy", cs.PreviewBy);
                    if (searchRef != null) w.WriteString("search", searchRef);
                    if (cs.FileEntries.Count > 0) { w.WriteStartArray("files"); foreach (var fe in cs.FileEntries) w.WriteRawValue(fe); w.WriteEndArray(); }
                    w.WriteStartArray("chunks");
                    foreach (var e in cs.ChunkEntries) w.WriteRawValue(e);
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                return ms.ToArray();
            }
        }

        byte[] BuildManifest(List<byte[]> convs, string lang, string title)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("schema", PreviewDataset.Schema);
                    w.WriteString("generator", "TeamsTransfer");
                    w.WriteString("generatedUtc", DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
                    w.WriteString("language", lang);
                    w.WriteString("accent", string.Equals(_o.Accent, "Teams", StringComparison.OrdinalIgnoreCase) ? "Teams" : "House");
                    w.WriteString("mode", _o.SingleFile ? "single" : "folder");
                    w.WriteString("title", title);
                    if (!string.IsNullOrEmpty(_o.ScopeLabel)) w.WriteString("scopeLabel", _o.ScopeLabel);
                    if (_viewerIx >= 0) w.WriteNumber("viewer", _viewerIx); else w.WriteNull("viewer");
                    w.WriteStartArray("users");
                    foreach (var u in _users)
                    {
                        w.WriteStartObject();
                        w.WriteString("i", u.Id ?? ""); w.WriteString("n", u.Name ?? "?");
                        if (!string.IsNullOrEmpty(u.Upn)) w.WriteString("u", u.Upn);
                        w.WriteString("s", u.State ?? "unknown");
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                    w.WriteStartArray("conversations"); foreach (var c in convs) w.WriteRawValue(c); w.WriteEndArray();
                    w.WriteStartObject("stats");
                    w.WriteNumber("conversations", _res.Conversations); w.WriteNumber("messages", _res.Messages); w.WriteNumber("chunks", _res.Chunks);
                    w.WriteNumber("files", _res.Files); w.WriteNumber("filesExported", _res.FilesExported);
                    w.WriteNumber("images", _res.Images); w.WriteNumber("imagesMissing", _res.ImagesMissing);
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                return ms.ToArray();
            }
        }
    }
}
