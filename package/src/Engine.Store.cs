// =============================================================================
//  TeamsTransfer - engine, part 4a: local store (messages, content, catalog of users/conversations/files)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.1
//
//  Why this file exists:
//    1 to 3 billion messages cannot live in one SQLite file, in one JSON file per message, or in memory. The store
//    splits the problem in three, each with the structure that suits it (design section 5):
//      - catalog.db (SQLite, WAL)  users, conversations, links, checkpoints, files, hosted contents, lots, leases,
//                                  import journal, ghosts (Engine.Catalog.cs). Small rows, many readers.
//      - parts\NNN\part.db         the MESSAGE INDEX of one partition: partition = FNV-1a(ConversationKey) mod Partitions
//                                  (256 by default, fixed at creation and recorded in catalog.db AND in every part.db).
//      - parts\NNN\seg\<yyyy-MM>-<n>.jsonl.gz   the message BODIES: raw Graph JSON, one line per VERSION, append only.
//      - content\ab\cd\<sha256>    content-addressed blobs (hosted contents, files), written to content\tmp then moved.
//
//  Segment format and why (crash safety + random access):
//    A segment is a sequence of INDEPENDENT gzip members ("blocks", ~64 KB of uncompressed JSON lines each, sorted by
//    conversation so a conversation is contiguous). `gzip -dc segment` yields the whole jsonl. A block is only ever
//    appended whole: a crash can only leave a truncated LAST member, never damage an earlier one. The index (table
//    `blocks`: segment, offset, compressed length, uncompressed length; table `messages`: block, offset of the line in
//    the block, line length) lets a read seek to a block, inflate ~64 KB and slice the line. Month of a segment = the
//    UTC month of the message createdDateTime; a new file <month>-<n+1> is started when one reaches SegmentMaxBytes
//    (uncompressed, default 256 MB).
//
//  Write path (per partition, under the partition lock):
//    AppendMessages decides New / Updated / Unchanged against the pending buffer and the index, then buffers the line.
//    A FLUSH (BatchSize messages, MaxPendingBytes, FlushIntervalMs timer, Flush(), a read of that partition, a
//    checkpoint) does: compress blocks -> append to the segment file -> fsync -> ONE SQLite transaction that inserts the
//    blocks, upserts the message rows and moves segs.committed_clen. So the index can never point past the end of a
//    segment, whatever kills the process. Bytes written after the last commit are an ORPHAN TAIL: ignored, reported by
//    Verify (and a new segment file is started instead of appending after them). A segment shorter than its
//    committed length (disk damage, manual truncation) is repaired at the first open of the partition: the blocks and
//    messages beyond the end are removed from the index (listed in RecoveryLog); a re-export refetches them.
//    DURABILITY CONTRACT: AppendMessages returns once the messages are buffered and visible to readers of this store;
//    they are on disk after Flush(), the timer, or SetCheckpoint (which flushes first: a checkpoint never gets ahead
//    of its data).
//
//  Versions (see Engine.StoreContracts.cs): same lastModifiedDateTime/etag/sha -> Unchanged. Otherwise compare
//  lastModifiedDateTime (absent < any value, 0001-01-01 is a VALUE): greater -> new version, smaller -> ignored.
//  Equal: same non-null etag -> Unchanged (same service version, only the JSON projection differs), else Updated.
//  The sha256 is computed on the stored line (the raw JSON text; line breaks, which are only insignificant whitespace in
//  JSON, are removed so that the segment stays valid jsonl).
//
//  One process owns a store for writing (store.lock, FileShare.None). StoreOptions.ReadOnly opens without the lock.
//  Refused: a root inside the package folder (an upgrade would delete it), a UNC or mapped network drive (SQLite over
//  SMB corrupts), a partition count different from the recorded one.
// =============================================================================
using System;
using System.Buffers;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using Microsoft.Data.Sqlite;

namespace TeamsTransfer
{
    public sealed class StoreOptions
    {
        /// <summary>Number of message partitions. Fixed when the store is created; opening with another value is refused.</summary>
        public int Partitions = 256;
        /// <summary>Uncompressed bytes after which a new segment file is started (per partition and month).</summary>
        public long SegmentMaxBytes = 256L * 1024 * 1024;
        /// <summary>Target uncompressed size of one gzip block.</summary>
        public int BlockBytes = 64 * 1024;
        /// <summary>Messages buffered in a partition before it is flushed (one SQLite transaction).</summary>
        public int BatchSize = 2000;
        /// <summary>Bytes buffered in a partition before it is flushed.</summary>
        public int MaxPendingBytes = 4 * 1024 * 1024;
        /// <summary>A partition with buffered data is flushed after this delay. 0 = no timer (flush on thresholds/Flush only).</summary>
        public int FlushIntervalMs = 1000;
        /// <summary>FlushFileBuffers on the segment before each commit (power-loss safety). Process crashes are safe either way.</summary>
        public bool SyncSegments = true;
        public bool ReadOnly = false;
        public int PartitionCacheKb = 1024;
        public int MaxOpenSegmentsPerPartition = 6;
        /// <summary>A Failed file is retried until it has failed this many times.</summary>
        public int MaxFileAttempts = 3;
        /// <summary>Optional extra folder in which a store is refused (the package folder is also detected by TeamsTransfer.psm1).</summary>
        public string PackageRoot;
        /// <summary>Time source for leases and timestamps (tests).</summary>
        public Func<DateTimeOffset> Clock;
    }

    public sealed class StoreVerifyReport
    {
        public int PartitionsChecked, Segments, Blocks;
        public long Messages, DeepChecked;
        /// <summary>Bytes after the last committed block of a segment (killed writer): ignored by readers.</summary>
        public long OrphanTailBytes;
        public int OrphanTails, OrphanFiles;
        /// <summary>Blocks (and their messages) whose bytes are missing from the segment: only after damage.</summary>
        public int DanglingBlocks;
        public long DanglingMessages;
        public int HashMismatches;
        public bool Repaired;
        public List<string> Problems = new List<string>();
        /// <summary>True when the index is fully backed by segment data (orphan tails alone do not make a store unhealthy).</summary>
        public bool Consistent { get { return DanglingBlocks == 0 && HashMismatches == 0; } }
    }

    public sealed class StoreMessageInfo
    {
        public string ConversationKey, MessageId, ReplyToId, ETag, Sha256;
        public DateTimeOffset CreatedUtc;
        public DateTimeOffset? LastModifiedUtc;
        public int Versions;
    }

    public sealed class StoreStats
    {
        public int Partitions, PartitionsUsed;
        public long Messages, Conversations, Users, SegmentBytes, Segments;
    }

    public sealed partial class TmtStore : IExportStore, IStoreReader
    {
        const int SchemaVersion = 1;

        readonly StoreOptions _o;
        readonly string _root, _catalogPath, _partsRoot, _contentRoot;
        readonly int _partitions;
        readonly Partition[] _parts;
        readonly object _catLock = new object();
        SqliteConnection _cat;
        FileStream _lockFs;
        Timer _timer;
        volatile Exception _fault;
        int _disposed;
        readonly List<string> _recovery = new List<string>();
        readonly ConcurrentDictionary<string, byte> _authorsSeen = new ConcurrentDictionary<string, byte>();
        readonly ConcurrentQueue<string[]> _authorQueue = new ConcurrentQueue<string[]>();
        readonly string _catalogConnString;

        public string Root { get { return _root; } }
        public int Partitions { get { return _partitions; } }
        public StoreOptions Options { get { return _o; } }
        /// <summary>What the open-time recovery had to repair (empty after a clean shutdown or a plain kill).</summary>
        public IReadOnlyList<string> RecoveryLog { get { lock (_recovery) return _recovery.ToArray(); } }
        internal DateTimeOffset Now { get { return _o.Clock != null ? _o.Clock() : DateTimeOffset.UtcNow; } }

        // =====================================================================================================
        #region Open / dispose

        TmtStore(string root, StoreOptions o)
        {
            _o = o; _root = root; _partitions = o.Partitions;
            _catalogPath = Path.Combine(root, "catalog.db");
            _partsRoot = Path.Combine(root, "parts");
            _contentRoot = Path.Combine(root, "content");
            _parts = new Partition[_partitions];
            _catalogConnString = "Data Source=" + _catalogPath + ";Pooling=False;Default Timeout=30";
        }

        /// <summary>Recorded partition count of an existing store, 0 when the folder holds no store.</summary>
        public static int PeekPartitions(string root)
        {
            string db = Path.Combine(Path.GetFullPath(root), "catalog.db");
            if (!File.Exists(db)) return 0;
            using (var c = new SqliteConnection("Data Source=" + db + ";Pooling=False;Mode=ReadOnly"))
            {
                c.Open();
                using (var cmd = c.CreateCommand())
                {
                    cmd.CommandText = "SELECT value FROM meta WHERE key='partitions'";
                    object v = cmd.ExecuteScalar();
                    return v == null ? 0 : int.Parse((string)v, CultureInfo.InvariantCulture);
                }
            }
        }

        public static TmtStore Open(string root, StoreOptions options = null)
        {
            var o = options ?? new StoreOptions();
            if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("root");
            if (o.Partitions < 1 || o.Partitions > 4096) throw new ArgumentOutOfRangeException("Partitions", "1..4096");
            string full = Path.GetFullPath(root).TrimEnd('\\', '/');
            RefuseUnsafeLocation(full, o);

            var s = new TmtStore(full, o);
            bool ok = false;
            try
            {
                if (!o.ReadOnly)
                {
                    Directory.CreateDirectory(full);
                    s._lockFs = AcquireLock(full);
                    Directory.CreateDirectory(s._partsRoot);
                    Directory.CreateDirectory(Path.Combine(s._contentRoot, "tmp"));
                    s.CleanTempContent();
                }
                else if (!File.Exists(s._catalogPath)) throw new FileNotFoundException("No store at " + full, s._catalogPath);
                s.InitCatalog();
                if (!o.ReadOnly && o.FlushIntervalMs > 0)
                    s._timer = new Timer(s.OnTimer, null, o.FlushIntervalMs, o.FlushIntervalMs);
                ok = true;
                return s;
            }
            finally { if (!ok) { try { s.DisposeCore(false); } catch { } } }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetDriveTypeW(string rootPathName);

        static void RefuseUnsafeLocation(string full, StoreOptions o)
        {
            // network: UNC (\\server\share, \\?\UNC\...) or a mapped drive
            bool unc = full.StartsWith(@"\\", StringComparison.Ordinal) && !full.StartsWith(@"\\?\", StringComparison.Ordinal) && !full.StartsWith(@"\\.\", StringComparison.Ordinal);
            if (full.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) unc = true;
            if (!unc)
            {
                try
                {
                    string r = Path.GetPathRoot(full);
                    if (OperatingSystem.IsWindows() && !string.IsNullOrEmpty(r) && r.Length >= 2 && r[1] == ':' && GetDriveTypeW(r) == 4) unc = true;
                }
                catch { }
            }
            if (unc) throw new InvalidOperationException("Refusing to open the store at '" + full + "': SQLite over SMB (a network share) is unsafe and corrupts the database. Use a local disk of this machine.");

            // package folder
            var bad = new List<string>();
            if (!string.IsNullOrEmpty(o.PackageRoot)) bad.Add(Path.GetFullPath(o.PackageRoot).TrimEnd('\\', '/'));
            for (string d = full; !string.IsNullOrEmpty(d); d = Path.GetDirectoryName(d))
            {
                if (File.Exists(Path.Combine(d, "TeamsTransfer.psm1")) || File.Exists(Path.Combine(d, "TeamsTransfer.psd1"))) { bad.Add(d); break; }
            }
            foreach (var b in bad)
                if (string.Equals(full, b, StringComparison.OrdinalIgnoreCase) || full.StartsWith(b + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Refusing to open the store at '" + full + "': it is inside the package folder '" + b + "', which is replaced at each upgrade. Choose a data folder outside the package.");
        }

        static FileStream AcquireLock(string root)
        {
            try { return new FileStream(Path.Combine(root, "store.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1); }
            catch (IOException e) { throw new IOException("The store '" + root + "' is already open for writing by another process or instance.", e); }
        }

        void CleanTempContent()
        {
            try { foreach (var f in Directory.EnumerateFiles(Path.Combine(_contentRoot, "tmp"))) { try { File.Delete(f); } catch { } } } catch { }
        }

        SqliteConnection OpenConn(string path, bool readOnly, int cacheKb)
        {
            var c = new SqliteConnection("Data Source=" + path + ";Pooling=False;Default Timeout=30" + (readOnly ? ";Mode=ReadOnly" : ""));
            c.Open();
            if (!readOnly)
            {
                Exec(c, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-" + cacheKb.ToString(CultureInfo.InvariantCulture) + ";");
            }
            return c;
        }

        void InitCatalog()
        {
            if (_o.ReadOnly)
            {
                _cat = OpenConn(_catalogPath, true, 0);
                CheckPartitionCount();
                return;
            }
            _cat = OpenConn(_catalogPath, false, 8192);
            Exec(_cat, CatalogSchemaSql + WorkSchemaSql);
            lock (_catLock)
            {
                string pc = MetaGet("partitions");
                if (pc == null)
                {
                    MetaSet("partitions", _partitions.ToString(CultureInfo.InvariantCulture));
                    MetaSet("schema_version", SchemaVersion.ToString(CultureInfo.InvariantCulture));
                    MetaSet("store_id", Guid.NewGuid().ToString());
                    MetaSet("created_utc", Now.UtcTicks.ToString(CultureInfo.InvariantCulture));
                }
                else CheckPartitionCount();
            }
        }

        void CheckPartitionCount()
        {
            string pc = MetaGet("partitions");
            if (pc != null && int.Parse(pc, CultureInfo.InvariantCulture) != _partitions)
                throw new InvalidOperationException("Partition count mismatch: the store at '" + _root + "' was created with " + pc + " partitions, StoreOptions.Partitions is " + _partitions +
                    ". The count is fixed at creation (conversations are placed by hash); open it with the recorded value.");
        }

        string MetaGet(string key)
        {
            using (var c = _cat.CreateCommand()) { c.CommandText = "SELECT value FROM meta WHERE key=@k"; c.Parameters.AddWithValue("@k", key); return (string)c.ExecuteScalar(); }
        }
        void MetaSet(string key, string value)
        {
            using (var c = _cat.CreateCommand()) { c.CommandText = "INSERT INTO meta(key,value) VALUES(@k,@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value"; c.Parameters.AddWithValue("@k", key); c.Parameters.AddWithValue("@v", value); c.ExecuteNonQuery(); }
        }

        /// <summary>Unique id of this store (merge bookkeeping).</summary>
        public string StoreId { get { lock (_catLock) return MetaGet("store_id"); } }

        public void Dispose() { DisposeCore(true); }

        void DisposeCore(bool flush)
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            Exception first = null;
            try { _timer?.Dispose(); } catch { }
            // a timer callback may be running: take every partition lock below, it finishes first
            if (flush && !_o.ReadOnly)
            {
                try { FlushAuthors(); } catch (Exception e) { first = first ?? e; }
            }
            foreach (var p in _parts)
            {
                if (p == null) continue;
                try { p.Close(this, flush && !_o.ReadOnly); } catch (Exception e) { first = first ?? e; }
            }
            try { if (_cat != null) { if (!_o.ReadOnly) { try { Exec(_cat, "PRAGMA wal_checkpoint(TRUNCATE)"); } catch { } } _cat.Dispose(); } } catch { }
            try { _lockFs?.Dispose(); } catch { }
            if (first != null && flush) throw new IOException("Flushing the store failed on dispose: " + first.Message, first);
        }

        void ThrowIfBad()
        {
            if (_disposed != 0) throw new ObjectDisposedException("TmtStore");
            var f = _fault;
            if (f != null) throw new IOException("A background flush of the store failed earlier; data may not be on disk: " + f.Message, f);
        }
        void ThrowIfReadOnly() { if (_o.ReadOnly) throw new InvalidOperationException("The store is open read-only."); }

        #endregion

        // =====================================================================================================
        #region SQL helpers

        internal static void Exec(SqliteConnection c, string sql)
        {
            using (var cmd = c.CreateCommand()) { cmd.CommandText = sql; cmd.ExecuteNonQuery(); }
        }

        internal static object Norm(object v)
        {
            if (v == null) return DBNull.Value;
            if (v is bool b) return b ? 1 : 0;
            if (v is Enum) return Convert.ToInt32(v, CultureInfo.InvariantCulture);
            if (v is DateTimeOffset d) return d.UtcTicks;
            return v;
        }

        internal static SqliteCommand Cmd(SqliteConnection c, string sql, params object[] nameValue)
        {
            var cmd = c.CreateCommand();
            cmd.CommandText = sql;
            for (int i = 0; i + 1 < nameValue.Length; i += 2) cmd.Parameters.AddWithValue((string)nameValue[i], Norm(nameValue[i + 1]));
            return cmd;
        }

        /// <summary>Untyped parameter: the SQLite type is inferred from each assigned value.</summary>
        internal static SqliteParameter AddP(SqliteCommand cmd, string name)
        {
            var p = cmd.CreateParameter(); p.ParameterName = name; cmd.Parameters.Add(p); return p;
        }

        internal static int Run(SqliteConnection c, string sql, params object[] nameValue)
        {
            using (var cmd = Cmd(c, sql, nameValue)) return cmd.ExecuteNonQuery();
        }

        internal static object Scalar(SqliteConnection c, string sql, params object[] nameValue)
        {
            using (var cmd = Cmd(c, sql, nameValue)) { object v = cmd.ExecuteScalar(); return v == DBNull.Value ? null : v; }
        }

        internal SqliteConnection OpenCatalogRead()
        {
            var c = new SqliteConnection("Data Source=" + _catalogPath + ";Pooling=False;Default Timeout=30;Mode=ReadOnly");
            c.Open();
            return c;
        }

        internal void InCatalogTransaction(Action a)
        {
            lock (_catLock)
            {
                Exec(_cat, "BEGIN IMMEDIATE");
                try { a(); Exec(_cat, "COMMIT"); }
                catch { try { Exec(_cat, "ROLLBACK"); } catch { } throw; }
            }
        }

        internal static DateTimeOffset? FromTicks(object v)
        {
            if (v == null || v == DBNull.Value) return null;
            return new DateTimeOffset(Convert.ToInt64(v, CultureInfo.InvariantCulture), TimeSpan.Zero);
        }
        internal static string Str(SqliteDataReader r, int i) { return r.IsDBNull(i) ? null : r.GetString(i); }
        internal static DateTimeOffset? Dt(SqliteDataReader r, int i) { return r.IsDBNull(i) ? (DateTimeOffset?)null : new DateTimeOffset(r.GetInt64(i), TimeSpan.Zero); }

        const string CatalogSchemaSql = @"
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, upn TEXT, display TEXT, mail TEXT, state INTEGER NOT NULL DEFAULT 5, tenant TEXT);
CREATE INDEX IF NOT EXISTS ix_users_upn ON users(upn COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS conversations(key TEXT PRIMARY KEY, kind INTEGER NOT NULL, chat_id TEXT, team_id TEXT, channel_id TEXT, membership TEXT, topic TEXT, team_name TEXT,
  created INTEGER, last_activity INTEGER, members_json TEXT, member_count INTEGER NOT NULL DEFAULT 0, has_imported INTEGER);
CREATE INDEX IF NOT EXISTS ix_conv_team ON conversations(team_id) WHERE team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_conv_kind ON conversations(kind);
CREATE TABLE IF NOT EXISTS user_conversations(user_id TEXT NOT NULL, conv_key TEXT NOT NULL, PRIMARY KEY(user_id, conv_key)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_uc_conv ON user_conversations(conv_key);
CREATE TABLE IF NOT EXISTS checkpoints(scope TEXT PRIMARY KEY, value TEXT, updated INTEGER);
CREATE TABLE IF NOT EXISTS files(conv_key TEXT NOT NULL, message_id TEXT NOT NULL, attachment_id TEXT NOT NULL, name TEXT, source_url TEXT, drive_id TEXT, item_id TEXT, etag TEXT,
  size INTEGER, status INTEGER NOT NULL, error TEXT, sha256 TEXT, attempts INTEGER NOT NULL DEFAULT 0, updated INTEGER, PRIMARY KEY(conv_key, message_id, attachment_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_files_pending ON files(status) WHERE status IN (0,6);
CREATE TABLE IF NOT EXISTS hosted(conv_key TEXT NOT NULL, message_id TEXT NOT NULL, hosted_id TEXT NOT NULL, sha256 TEXT NOT NULL, length INTEGER, content_type TEXT, PRIMARY KEY(conv_key, message_id, hosted_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS authors(user_id TEXT PRIMARY KEY, display_name TEXT, identity_type TEXT, first_conv TEXT, first_seen INTEGER);
";

        #endregion

        // =====================================================================================================
        #region Catalog: users, conversations, checkpoints, files, hosted contents

        public void UpsertUsers(IEnumerable<UserRecord> users)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (users == null) return;
            InCatalogTransaction(() =>
            {
                using (var cmd = Cmd(_cat, @"INSERT INTO users(id,upn,display,mail,state,tenant) VALUES(@id,@upn,@dn,@mail,@st,@t)
ON CONFLICT(id) DO UPDATE SET upn=COALESCE(excluded.upn,upn), display=COALESCE(excluded.display,display), mail=COALESCE(excluded.mail,mail),
  state=CASE WHEN excluded.state<>5 THEN excluded.state ELSE state END, tenant=COALESCE(excluded.tenant,tenant)"))
                {
                    var pId = cmd.Parameters.Add("@id", SqliteType.Text); var pU = cmd.Parameters.Add("@upn", SqliteType.Text); var pD = cmd.Parameters.Add("@dn", SqliteType.Text);
                    var pM = cmd.Parameters.Add("@mail", SqliteType.Text); var pS = cmd.Parameters.Add("@st", SqliteType.Integer); var pT = cmd.Parameters.Add("@t", SqliteType.Text);
                    foreach (var u in users)
                    {
                        if (u == null || string.IsNullOrEmpty(u.Id)) continue;
                        pId.Value = u.Id; pU.Value = Norm(u.UserPrincipalName); pD.Value = Norm(u.DisplayName); pM.Value = Norm(u.Mail); pS.Value = (int)u.State; pT.Value = Norm(u.TenantId);
                        cmd.ExecuteNonQuery();
                    }
                }
            });
        }

        public void UpsertConversations(IEnumerable<ConversationRecord> conversations)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (conversations == null) return;
            InCatalogTransaction(() =>
            {
                using (var cmd = Cmd(_cat, @"INSERT INTO conversations(key,kind,chat_id,team_id,channel_id,membership,topic,team_name,created,last_activity,members_json,member_count,has_imported)
VALUES(@key,@kind,@chat,@team,@chan,@mem,@topic,@tname,@cr,@la,@mj,@mc,@hi)
ON CONFLICT(key) DO UPDATE SET kind=excluded.kind, chat_id=COALESCE(excluded.chat_id,chat_id), team_id=COALESCE(excluded.team_id,team_id), channel_id=COALESCE(excluded.channel_id,channel_id),
  membership=COALESCE(excluded.membership,membership), topic=COALESCE(excluded.topic,topic), team_name=COALESCE(excluded.team_name,team_name), created=COALESCE(excluded.created,created),
  last_activity=CASE WHEN excluded.last_activity IS NOT NULL AND (last_activity IS NULL OR excluded.last_activity>last_activity) THEN excluded.last_activity ELSE last_activity END,
  members_json=COALESCE(excluded.members_json,members_json), member_count=CASE WHEN excluded.members_json IS NOT NULL THEN excluded.member_count ELSE member_count END,
  has_imported=COALESCE(excluded.has_imported,has_imported)"))
                {
                    foreach (var n in new[] { "@key", "@kind", "@chat", "@team", "@chan", "@mem", "@topic", "@tname", "@cr", "@la", "@mj", "@mc", "@hi" }) AddP(cmd, n);
                    foreach (var c in conversations)
                    {
                        if (c == null || string.IsNullOrEmpty(c.Key)) continue;
                        var p = cmd.Parameters;
                        p["@key"].Value = c.Key; p["@kind"].Value = (int)c.Kind; p["@chat"].Value = Norm(c.ChatId); p["@team"].Value = Norm(c.TeamId); p["@chan"].Value = Norm(c.ChannelId);
                        p["@mem"].Value = Norm(c.MembershipType); p["@topic"].Value = Norm(c.Topic); p["@tname"].Value = Norm(c.TeamDisplayName);
                        p["@cr"].Value = Norm(c.CreatedUtc); p["@la"].Value = Norm(c.LastActivityUtc); p["@mj"].Value = Norm(c.MembersJson); p["@mc"].Value = c.MemberCount; p["@hi"].Value = Norm(c.HasImportedContent);
                        cmd.ExecuteNonQuery();
                    }
                }
            });
        }

        public void LinkUserConversations(string userId, IEnumerable<string> conversationKeys)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (string.IsNullOrEmpty(userId) || conversationKeys == null) return;
            InCatalogTransaction(() =>
            {
                using (var cmd = Cmd(_cat, "INSERT OR IGNORE INTO user_conversations(user_id,conv_key) VALUES(@u,@k)"))
                {
                    cmd.Parameters.AddWithValue("@u", userId); var pk = cmd.Parameters.Add("@k", SqliteType.Text);
                    foreach (var k in conversationKeys) { if (string.IsNullOrEmpty(k)) continue; pk.Value = k; cmd.ExecuteNonQuery(); }
                }
            });
        }

        const string ConvCols = "key,kind,chat_id,team_id,channel_id,membership,topic,team_name,created,last_activity,members_json,member_count,has_imported";
        static ConversationRecord ReadConv(SqliteDataReader r, int o = 0)
        {
            return new ConversationRecord
            {
                Key = r.GetString(o), Kind = (ConversationKind)r.GetInt32(o + 1), ChatId = Str(r, o + 2), TeamId = Str(r, o + 3), ChannelId = Str(r, o + 4), MembershipType = Str(r, o + 5),
                Topic = Str(r, o + 6), TeamDisplayName = Str(r, o + 7), CreatedUtc = Dt(r, o + 8), LastActivityUtc = Dt(r, o + 9), MembersJson = Str(r, o + 10), MemberCount = r.GetInt32(o + 11),
                HasImportedContent = r.IsDBNull(o + 12) ? (bool?)null : r.GetInt32(o + 12) != 0
            };
        }

        public ConversationRecord GetConversation(string conversationKey)
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + ConvCols + " FROM conversations WHERE key=@k", "@k", conversationKey))
            using (var r = cmd.ExecuteReader())
                return r.Read() ? ReadConv(r) : null;
        }

        public IEnumerable<ConversationRecord> ListConversations(string userId = null, ConversationKind? kind = null, string teamId = null)
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead())
            {
                var sb = new StringBuilder();
                var ps = new List<object>();
                if (!string.IsNullOrEmpty(userId)) { sb.Append("SELECT " + string.Join(",", ConvCols.Split(',').Select(x => "c." + x)) + " FROM user_conversations uc JOIN conversations c ON c.key=uc.conv_key WHERE uc.user_id=@u"); ps.Add("@u"); ps.Add(userId); }
                else sb.Append("SELECT " + ConvCols + " FROM conversations c WHERE 1=1");
                if (kind.HasValue) { sb.Append(" AND c.kind=@kind"); ps.Add("@kind"); ps.Add((int)kind.Value); }
                if (!string.IsNullOrEmpty(teamId)) { sb.Append(" AND c.team_id=@team"); ps.Add("@team"); ps.Add(teamId); }
                sb.Append(" ORDER BY c.key");
                using (var cmd = Cmd(c, sb.ToString(), ps.ToArray()))
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) yield return ReadConv(r);
            }
        }

        public IEnumerable<UserRecord> ListUsers()
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT id,upn,display,mail,state,tenant FROM users ORDER BY id"))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    yield return new UserRecord { Id = r.GetString(0), UserPrincipalName = Str(r, 1), DisplayName = Str(r, 2), Mail = Str(r, 3), State = (UserState)r.GetInt32(4), TenantId = Str(r, 5) };
        }

        public string GetCheckpoint(string scope)
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead()) return (string)Scalar(c, "SELECT value FROM checkpoints WHERE scope=@s", "@s", scope);
        }

        /// <summary>Flushes every buffered message first: a checkpoint never gets ahead of the data it stands for.</summary>
        public void SetCheckpoint(string scope, string value)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            Flush();
            lock (_catLock) Run(_cat, "INSERT INTO checkpoints(scope,value,updated) VALUES(@s,@v,@u) ON CONFLICT(scope) DO UPDATE SET value=excluded.value, updated=excluded.updated", "@s", scope, "@v", value, "@u", Now);
        }

        public void RecordHostedContent(string conversationKey, string messageId, string hostedContentId, ContentRef content)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (content == null) throw new ArgumentNullException("content");
            lock (_catLock)
                Run(_cat, @"INSERT INTO hosted(conv_key,message_id,hosted_id,sha256,length,content_type) VALUES(@c,@m,@h,@s,@l,@t)
ON CONFLICT(conv_key,message_id,hosted_id) DO UPDATE SET sha256=excluded.sha256, length=excluded.length, content_type=COALESCE(excluded.content_type,content_type)",
                    "@c", conversationKey, "@m", messageId, "@h", hostedContentId, "@s", content.Sha256, "@l", content.Length, "@t", content.ContentType);
        }

        public string FindHostedContent(string conversationKey, string messageId, string hostedContentId)
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead())
                return (string)Scalar(c, "SELECT sha256 FROM hosted WHERE conv_key=@c AND message_id=@m AND hosted_id=@h", "@c", conversationKey, "@m", messageId, "@h", hostedContentId);
        }

        public void RecordFile(FileRecord f)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (f == null) throw new ArgumentNullException("file");
            lock (_catLock)
                Run(_cat, @"INSERT INTO files(conv_key,message_id,attachment_id,name,source_url,drive_id,item_id,etag,size,status,error,sha256,attempts,updated)
VALUES(@c,@m,@a,@n,@u,@d,@i,@e,@sz,@st,@er,@sh,@at,@up)
ON CONFLICT(conv_key,message_id,attachment_id) DO UPDATE SET name=COALESCE(excluded.name,name), source_url=COALESCE(excluded.source_url,source_url), drive_id=COALESCE(excluded.drive_id,drive_id),
  item_id=COALESCE(excluded.item_id,item_id), etag=COALESCE(excluded.etag,etag), size=COALESCE(excluded.size,size),
  status=CASE WHEN status=1 AND excluded.status=0 THEN 1 ELSE excluded.status END,
  error=CASE WHEN status=1 AND excluded.status=0 THEN error ELSE excluded.error END,
  sha256=CASE WHEN status=1 AND excluded.status=0 THEN sha256 ELSE COALESCE(excluded.sha256,sha256) END,
  attempts=CASE WHEN excluded.status=6 THEN attempts+1 ELSE attempts END, updated=excluded.updated",
                    "@c", f.ConversationKey, "@m", f.MessageId, "@a", f.AttachmentId ?? "", "@n", f.Name, "@u", f.SourceUrl, "@d", f.DriveId, "@i", f.ItemId, "@e", f.ETag, "@sz", f.Size,
                    "@st", f.Status, "@er", f.Error, "@sh", f.Sha256, "@at", f.Status == FileStatus.Failed ? 1 : 0, "@up", Now);
        }

        const string FileCols = "conv_key,message_id,attachment_id,name,source_url,drive_id,item_id,etag,size,status,error,sha256";
        static FileRecord ReadFile(SqliteDataReader r)
        {
            return new FileRecord
            {
                ConversationKey = r.GetString(0), MessageId = r.GetString(1), AttachmentId = r.GetString(2), Name = Str(r, 3), SourceUrl = Str(r, 4), DriveId = Str(r, 5), ItemId = Str(r, 6),
                ETag = Str(r, 7), Size = r.IsDBNull(8) ? (long?)null : r.GetInt64(8), Status = (FileStatus)r.GetInt32(9), Error = Str(r, 10), Sha256 = Str(r, 11)
            };
        }

        public IEnumerable<FileRecord> PendingFiles(int max)
        {
            ThrowIfBad();
            var list = new List<FileRecord>();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + FileCols + " FROM files WHERE status IN (0,6) AND (status=0 OR attempts<@max) ORDER BY conv_key, message_id, attachment_id LIMIT @n", "@max", _o.MaxFileAttempts, "@n", Math.Max(0, max)))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) list.Add(ReadFile(r));
            return list;
        }

        public IEnumerable<FileRecord> ListFiles(string conversationKey)
        {
            ThrowIfBad();
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + FileCols + " FROM files WHERE conv_key=@c ORDER BY message_id, attachment_id", "@c", conversationKey))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadFile(r);
        }

        #endregion

        // =====================================================================================================
        #region Content-addressed blobs

        static bool IsSha(string s)
        {
            if (s == null || s.Length != 64) return false;
            foreach (char ch in s) if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return false;
            return true;
        }

        internal string ContentPath(string sha) { return Path.Combine(_contentRoot, sha.Substring(0, 2), sha.Substring(2, 2), sha); }

        public ContentRef PutContent(Stream data, string contentType)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (data == null) throw new ArgumentNullException("data");
            string tmp = Path.Combine(_contentRoot, "tmp", Guid.NewGuid().ToString("N"));
            long total = 0;
            string sha;
            byte[] buf = ArrayPool<byte>.Shared.Rent(128 * 1024);
            try
            {
                using (var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
                {
                    using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.SequentialScan))
                    {
                        int n;
                        while ((n = data.Read(buf, 0, buf.Length)) > 0) { h.AppendData(buf, 0, n); fs.Write(buf, 0, n); total += n; }
                        fs.Flush(true);
                    }
                    sha = Convert.ToHexStringLower(h.GetHashAndReset());
                }
                string dest = ContentPath(sha);
                bool present = File.Exists(dest);
                if (!present)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    try { File.Move(tmp, dest); }
                    catch (IOException) when (File.Exists(dest)) { present = true; }
                }
                if (present) { try { File.Delete(tmp); } catch { } }
                return new ContentRef { Sha256 = sha, Length = total, ContentType = contentType, AlreadyPresent = present };
            }
            catch { try { File.Delete(tmp); } catch { } throw; }
            finally { ArrayPool<byte>.Shared.Return(buf); }
        }

        public bool HasContent(string sha256) { return IsSha(sha256) && File.Exists(ContentPath(sha256)); }

        /// <summary>Read stream over a blob, or null when it was not exported.</summary>
        public Stream OpenContent(string sha256)
        {
            if (!IsSha(sha256)) return null;
            string p = ContentPath(sha256);
            try { return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 128 * 1024, FileOptions.SequentialScan); }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
        }

        #endregion

        // =====================================================================================================
        #region Partitions

        /// <summary>Stable partition of a conversation: FNV-1a over the UTF-8 key, avalanche, modulo the (fixed) partition count.</summary>
        public static int PartitionOf(string conversationKey, int partitions)
        {
            if (conversationKey == null) throw new ArgumentNullException("conversationKey");
            uint h = 2166136261;
            foreach (byte b in Encoding.UTF8.GetBytes(conversationKey)) { h ^= b; h *= 16777619; }
            h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
            return (int)(h % (uint)partitions);
        }

        internal Partition PartOf(string conversationKey)
        {
            int i = PartitionOf(conversationKey, _partitions);
            return PartAt(i);
        }

        internal Partition PartAt(int i)
        {
            var p = Volatile.Read(ref _parts[i]);
            if (p != null) return p;
            var np = new Partition(this, i);
            p = Interlocked.CompareExchange(ref _parts[i], np, null) ?? np;
            return p;
        }

        internal string PartDir(int i) { return Path.Combine(_partsRoot, i.ToString("D3", CultureInfo.InvariantCulture)); }

        void OnTimer(object state)
        {
            if (_disposed != 0) return;
            try
            {
                long now = Environment.TickCount64;
                foreach (var p in _parts)
                {
                    if (p == null || p.PendingCount == 0) continue;
                    if (now - p.PendingSinceTick < _o.FlushIntervalMs) continue;
                    if (!Monitor.TryEnter(p.Gate)) continue;
                    try { if (_disposed == 0) p.FlushLocked(this); } finally { Monitor.Exit(p.Gate); }
                }
                FlushAuthors();
            }
            catch (Exception e) { _fault = e; }
        }

        /// <summary>Writes every buffered message to disk (segments fsync'ed, index committed). Barrier for checkpoints.</summary>
        public void Flush()
        {
            ThrowIfBad();
            if (_o.ReadOnly) return;
            foreach (var p in _parts)
            {
                if (p == null || p.PendingCount == 0) continue;
                lock (p.Gate) p.FlushLocked(this);
            }
            FlushAuthors();
        }

        void FlushPartition(Partition p)
        {
            if (_o.ReadOnly) return;
            if (p.PendingCount == 0 && (p.IsOpen || !File.Exists(p.DbPath))) return;
            // first use of an existing partition: opening it runs the crash recovery before anything is read
            lock (p.Gate) { p.EnsureOpenLocked(this); p.FlushLocked(this); }
        }

        #endregion

        // =====================================================================================================
        #region Messages: append

        static long? ParseTicks(in JsonElement e, string name)
        {
            if (!e.TryGetProperty(name, out var v)) return null;
            if (v.ValueKind == JsonValueKind.String)
            {
                if (v.TryGetDateTimeOffset(out var d)) return d.UtcTicks;
                if (DateTimeOffset.TryParse(v.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) return d.UtcTicks;
            }
            return null;
        }
        static string OptString(in JsonElement e, string name)
        {
            return e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }

        static string MonthOf(long ticks)
        {
            DateTime d = new DateTime(Math.Max(0, Math.Min(ticks, DateTime.MaxValue.Ticks)), DateTimeKind.Utc);
            return d.Year.ToString("D4", CultureInfo.InvariantCulture) + "-" + d.Month.ToString("D2", CultureInfo.InvariantCulture);
        }

        public MessageWriteResult AppendMessages(string conversationKey, IReadOnlyList<JsonElement> messages)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (string.IsNullOrEmpty(conversationKey)) throw new ArgumentException("conversationKey");
            var res = new MessageWriteResult();
            if (messages == null || messages.Count == 0) return res;
            var p = PartOf(conversationKey);
            Span<byte> sha = stackalloc byte[32];
            lock (p.Gate)
            {
                p.EnsureOpenLocked(this);
                long cid = p.LookupCid(conversationKey);
                for (int i = 0; i < messages.Count; i++)
                {
                    JsonElement el = messages[i];
                    if (el.ValueKind != JsonValueKind.Object) throw new ArgumentException("messages[" + i + "] is not a JSON object");
                    string id = OptString(el, "id");
                    if (string.IsNullOrEmpty(id)) throw new ArgumentException("messages[" + i + "] has no 'id'");
                    string replyTo = OptString(el, "replyToId");
                    if (replyTo != null && replyTo.Length == 0) replyTo = null;
                    long created = ParseTicks(el, "createdDateTime") ?? 0;
                    long? lm = ParseTicks(el, "lastModifiedDateTime");
                    string etag = OptString(el, "etag");
                    ReadOnlySpan<byte> raw = JsonMarshal.GetRawUtf8Value(el);
                    byte[] norm = null;
                    if (raw.IndexOfAny((byte)'\n', (byte)'\r') >= 0)
                    {
                        var tmp = new List<byte>(raw.Length);
                        foreach (byte b in raw) if (b != (byte)'\n' && b != (byte)'\r') tmp.Add(b);
                        norm = tmp.ToArray(); raw = norm;
                    }
                    SHA256.HashData(raw, sha);
                    NoteAuthor(el, conversationKey);
                    p.AcceptLocked(conversationKey, cid, id, replyTo, created, lm, etag, sha, raw, res);
                }
                if (p.PendingCount >= _o.BatchSize || p.BufLen >= _o.MaxPendingBytes) p.FlushLocked(this);
            }
            return res;
        }

        void NoteAuthor(in JsonElement el, string conversationKey)
        {
            if (!el.TryGetProperty("from", out var f) || f.ValueKind != JsonValueKind.Object) return;
            if (!f.TryGetProperty("user", out var u) || u.ValueKind != JsonValueKind.Object) return;
            string id = OptString(u, "id");
            if (string.IsNullOrEmpty(id) || !_authorsSeen.TryAdd(id, 0)) return;
            _authorQueue.Enqueue(new[] { id, OptString(u, "displayName"), OptString(u, "userIdentityType"), conversationKey });
        }

        void FlushAuthors()
        {
            if (_authorQueue.IsEmpty || _o.ReadOnly) return;
            var batch = new List<string[]>();
            while (_authorQueue.TryDequeue(out var a)) batch.Add(a);
            try
            {
                InCatalogTransaction(() =>
                {
                    foreach (var a in batch)
                        Run(_cat, "INSERT OR IGNORE INTO authors(user_id,display_name,identity_type,first_conv,first_seen) VALUES(@i,@d,@t,@c,@s)", "@i", a[0], "@d", a[1], "@t", a[2], "@c", a[3], "@s", Now);
                });
            }
            catch { foreach (var a in batch) { _authorsSeen.TryRemove(a[0], out _); _authorQueue.Enqueue(a); } throw; }
        }

        /// <summary>Index entry of the current version of a message (versions = how many versions were ever kept), or null.</summary>
        public StoreMessageInfo GetMessageInfo(string conversationKey, string messageId)
        {
            ThrowIfBad();
            var p = PartOf(conversationKey);
            FlushPartition(p);
            if (!File.Exists(p.DbPath)) return null;
            using (var db = OpenConn(p.DbPath, true, 0))
            using (var cmd = Cmd(db, "SELECT m.reply_to,m.created,m.modified,m.etag,m.sha,m.versions FROM messages m JOIN convs c ON c.cid=m.cid WHERE c.key=@k AND m.id=@i", "@k", conversationKey, "@i", messageId))
            using (var r = cmd.ExecuteReader())
            {
                if (!r.Read()) return null;
                return new StoreMessageInfo
                {
                    ConversationKey = conversationKey, MessageId = messageId, ReplyToId = Str(r, 0), CreatedUtc = new DateTimeOffset(r.GetInt64(1), TimeSpan.Zero), LastModifiedUtc = Dt(r, 2),
                    ETag = Str(r, 3), Sha256 = Convert.ToHexStringLower((byte[])r["sha"]), Versions = r.GetInt32(5)
                };
            }
        }

        public long CountMessages(string conversationKey)
        {
            ThrowIfBad();
            var p = PartOf(conversationKey);
            FlushPartition(p);
            if (!File.Exists(p.DbPath)) return 0;
            using (var c = OpenConn(p.DbPath, true, 0))
                return Convert.ToInt64(Scalar(c, "SELECT msg_count FROM convs WHERE key=@k", "@k", conversationKey) ?? 0L, CultureInfo.InvariantCulture);
        }

        #endregion

        // =====================================================================================================
        #region Messages: read

        sealed class BlockCache : IDisposable
        {
            readonly string _segDir;
            readonly Dictionary<long, string> _segNames = new Dictionary<long, string>();
            readonly Dictionary<long, FileStream> _files = new Dictionary<long, FileStream>();
            readonly Dictionary<long, byte[]> _blocks = new Dictionary<long, byte[]>();
            readonly Queue<long> _order = new Queue<long>();
            readonly SqliteConnection _db;
            public BlockCache(string segDir, SqliteConnection db) { _segDir = segDir; _db = db; }

            string SegPath(long seg)
            {
                if (!_segNames.TryGetValue(seg, out var name))
                {
                    using (var cmd = Cmd(_db, "SELECT id,month,n FROM segs"))
                    using (var r = cmd.ExecuteReader())
                        while (r.Read()) _segNames[r.GetInt64(0)] = r.GetString(1) + "-" + r.GetInt64(2).ToString(CultureInfo.InvariantCulture) + ".jsonl.gz";
                    if (!_segNames.TryGetValue(seg, out name)) throw new InvalidDataException("Segment #" + seg + " is not registered in the partition index.");
                }
                return Path.Combine(_segDir, name);
            }

            public byte[] Block(long bid, long seg, long off, long clen, long blen)
            {
                if (_blocks.TryGetValue(bid, out var b)) return b;
                if (!_files.TryGetValue(seg, out var fs))
                {
                    string path = SegPath(seg);
                    try { fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.RandomAccess); }
                    catch (FileNotFoundException e) { throw new InvalidDataException("Segment file missing: " + path, e); }
                    _files[seg] = fs;
                }
                var comp = new byte[clen];
                fs.Position = off;
                int got = 0;
                while (got < clen) { int n = fs.Read(comp, got, (int)clen - got); if (n <= 0) throw new InvalidDataException("Segment '" + fs.Name + "' ends before block #" + bid + " (offset " + off + ", length " + clen + ")."); got += n; }
                b = new byte[blen];
                using (var gz = new GZipStream(new MemoryStream(comp, false), CompressionMode.Decompress))
                {
                    int read = 0;
                    while (read < blen) { int n = gz.Read(b, read, (int)blen - read); if (n <= 0) throw new InvalidDataException("Block #" + bid + " of '" + fs.Name + "' is shorter than recorded."); read += n; }
                }
                _blocks[bid] = b; _order.Enqueue(bid);
                if (_order.Count > 4) _blocks.Remove(_order.Dequeue());
                return b;
            }

            public void Dispose() { foreach (var f in _files.Values) f.Dispose(); _files.Clear(); _blocks.Clear(); }
        }

        const string MsgSelect = "SELECT m.id,m.created,m.bid,m.ioff,m.len,b.seg,b.off,b.clen,b.blen FROM messages m JOIN blocks b ON b.bid=m.bid WHERE m.cid=@c";

        sealed class Cursor : IDisposable
        {
            public SqliteCommand Cmd; public SqliteDataReader R; public bool Has; public string Id; public long Created;
            public Cursor(SqliteCommand cmd) { Cmd = cmd; R = cmd.ExecuteReader(); Advance(); }
            public void Advance() { Has = R.Read(); if (Has) { Id = R.GetString(0); Created = R.GetInt64(1); } }
            public void Dispose() { R.Dispose(); Cmd.Dispose(); }
        }

        static JsonElement Materialize(BlockCache cache, SqliteDataReader r)
        {
            byte[] blk = cache.Block(r.GetInt64(2), r.GetInt64(5), r.GetInt64(6), r.GetInt64(7), r.GetInt64(8));
            int ioff = (int)r.GetInt64(3), len = (int)r.GetInt64(4);
            using (var doc = JsonDocument.Parse(new ReadOnlyMemory<byte>(blk, ioff, len)))
                return doc.RootElement.Clone();
        }

        /// <summary>
        /// Current version of each message of the conversation ordered by createdDateTime then id. In a channel every
        /// reply follows its root (replies ordered the same way); a reply whose root is absent or outside the range is
        /// placed by its own date. The range filters on each message's own createdDateTime: from inclusive, to exclusive.
        /// Streamed: only the rows and the few ~64 KB blocks being read are in memory.
        /// </summary>
        public IEnumerable<JsonElement> ReadMessages(string conversationKey, DateTimeOffset? fromUtc = null, DateTimeOffset? toUtc = null)
        {
            ThrowIfBad();
            var p = PartOf(conversationKey);
            FlushPartition(p);
            if (!File.Exists(p.DbPath)) yield break;
            bool channel = conversationKey.StartsWith("channel:", StringComparison.Ordinal);
            using (var db = OpenConn(p.DbPath, true, 0))
            {
                object cidObj = Scalar(db, "SELECT cid FROM convs WHERE key=@k", "@k", conversationKey);
                if (cidObj == null) yield break;
                long cid = Convert.ToInt64(cidObj, CultureInfo.InvariantCulture);
                string range = (fromUtc.HasValue ? " AND m.created>=@from" : "") + (toUtc.HasValue ? " AND m.created<@to" : "");
                Func<string, SqliteCommand> mk = sql =>
                {
                    var cmd = Cmd(db, sql, "@c", cid);
                    if (fromUtc.HasValue) cmd.Parameters.AddWithValue("@from", fromUtc.Value.UtcTicks);
                    if (toUtc.HasValue) cmd.Parameters.AddWithValue("@to", toUtc.Value.UtcTicks);
                    return cmd;
                };
                using (var cache = new BlockCache(p.SegDir, db))
                using (var roots = new Cursor(mk(MsgSelect + " AND m.reply_to IS NULL" + range + " ORDER BY m.created, m.id")))
                using (var orphans = channel ? new Cursor(mk(MsgSelect + " AND m.reply_to IS NOT NULL" + range +
                    " AND NOT EXISTS (SELECT 1 FROM messages r WHERE r.cid=m.cid AND r.id=m.reply_to AND r.reply_to IS NULL" +
                    (fromUtc.HasValue ? " AND r.created>=@from" : "") + (toUtc.HasValue ? " AND r.created<@to" : "") + ") ORDER BY m.created, m.id")) : null)
                using (var replies = channel ? mk(MsgSelect + " AND m.reply_to=@root" + range + " ORDER BY m.created, m.id") : null)
                {
                    SqliteParameter pRoot = null;
                    if (replies != null) pRoot = replies.Parameters.Add("@root", SqliteType.Text);
                    while (roots.Has || (orphans != null && orphans.Has))
                    {
                        bool takeRoot;
                        if (!roots.Has) takeRoot = false;
                        else if (orphans == null || !orphans.Has) takeRoot = true;
                        else
                        {
                            int c = roots.Created.CompareTo(orphans.Created);
                            if (c == 0) c = string.CompareOrdinal(roots.Id, orphans.Id);
                            takeRoot = c <= 0;
                        }
                        if (takeRoot)
                        {
                            yield return Materialize(cache, roots.R);
                            string rootId = roots.Id;
                            roots.Advance();
                            if (replies != null)
                            {
                                pRoot.Value = rootId;
                                using (var rr = replies.ExecuteReader())
                                    while (rr.Read()) yield return Materialize(cache, rr);
                            }
                        }
                        else
                        {
                            yield return Materialize(cache, orphans.R);
                            orphans.Advance();
                        }
                    }
                }
            }
        }

        #endregion

        // =====================================================================================================
        #region Verify / stats

        /// <summary>
        /// Checks every partition against its segments. Orphan tails (bytes after the last commit, left by a killed writer) are
        /// reported but harmless. Dangling blocks (index entries whose bytes are missing) are repaired at open already; if
        /// any remain they are reported. deep = re-reads every current message and compares its sha256. repair = truncate
        /// orphan tails and delete orphan files (not the files of live segments).
        /// </summary>
        public StoreVerifyReport Verify(bool deep = false, bool repair = false)
        {
            ThrowIfBad();
            var rep = new StoreVerifyReport();
            if (repair) ThrowIfReadOnly();
            Flush();
            for (int i = 0; i < _partitions; i++)
            {
                var p = PartAt(i);
                if (!Directory.Exists(PartDir(i))) continue;
                if (!File.Exists(p.DbPath)) { VerifyOrphanFiles(p, new HashSet<string>(StringComparer.OrdinalIgnoreCase), rep, repair); continue; }
                rep.PartitionsChecked++;
                if (_o.ReadOnly) VerifyPartition(p, rep, deep, false, null);
                else lock (p.Gate) { p.EnsureOpenLocked(this); VerifyPartition(p, rep, deep, repair, p); }
            }
            rep.Repaired = repair;
            return rep;
        }

        void VerifyOrphanFiles(Partition p, HashSet<string> known, StoreVerifyReport rep, bool repair)
        {
            if (!Directory.Exists(p.SegDir)) return;
            foreach (var f in Directory.EnumerateFiles(p.SegDir, "*.jsonl.gz"))
            {
                if (known.Contains(Path.GetFileName(f))) continue;
                rep.OrphanFiles++; rep.Problems.Add("partition " + p.Index + ": segment file not in the index (created by a killed writer): " + Path.GetFileName(f));
                if (repair) { try { File.Delete(f); } catch { } }
            }
        }

        void VerifyPartition(Partition p, StoreVerifyReport rep, bool deep, bool repair, Partition locked)
        {
            using (var db = OpenConn(p.DbPath, true, 0))
            {
                var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var segs = new List<long[]>(); var names = new Dictionary<long, string>();
                using (var cmd = Cmd(db, "SELECT id,month,n,committed_clen FROM segs"))
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) { string name = r.GetString(1) + "-" + r.GetInt64(2).ToString(CultureInfo.InvariantCulture) + ".jsonl.gz"; names[r.GetInt64(0)] = name; known.Add(name); segs.Add(new[] { r.GetInt64(0), r.GetInt64(3) }); }
                foreach (var s in segs)
                {
                    rep.Segments++;
                    string path = Path.Combine(p.SegDir, names[s[0]]);
                    long len = File.Exists(path) ? new FileInfo(path).Length : -1;
                    long maxEnd = Convert.ToInt64(Scalar(db, "SELECT COALESCE(MAX(off+clen),0) FROM blocks WHERE seg=@s", "@s", s[0]) ?? 0L, CultureInfo.InvariantCulture);
                    if (len < maxEnd)
                    {
                        long bad = Convert.ToInt64(Scalar(db, "SELECT COUNT(*) FROM blocks WHERE seg=@s AND off+clen>@l", "@s", s[0], "@l", Math.Max(0, len)), CultureInfo.InvariantCulture);
                        rep.DanglingBlocks += (int)bad; rep.Problems.Add("partition " + p.Index + ": " + names[s[0]] + " is " + len + " bytes, the index needs " + maxEnd + " (" + bad + " blocks dangling)");
                    }
                    else if (len > s[1])
                    {
                        rep.OrphanTails++; rep.OrphanTailBytes += len - s[1];
                        rep.Problems.Add("partition " + p.Index + ": " + names[s[0]] + " has an orphan tail of " + (len - s[1]) + " bytes after the last commit (ignored)");
                        if (repair && locked != null) { locked.CloseWriters(); using (var fs = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) fs.SetLength(s[1]); }
                    }
                }
                rep.Blocks += (int)Convert.ToInt64(Scalar(db, "SELECT COUNT(*) FROM blocks") ?? 0L, CultureInfo.InvariantCulture);
                rep.Messages += Convert.ToInt64(Scalar(db, "SELECT COALESCE(SUM(msg_count),0) FROM convs") ?? 0L, CultureInfo.InvariantCulture);
                VerifyOrphanFiles(p, known, rep, repair);
                if (deep)
                {
                    using (var cache = new BlockCache(p.SegDir, db))
                    using (var cmd = Cmd(db, "SELECT m.id,m.created,m.bid,m.ioff,m.len,b.seg,b.off,b.clen,b.blen,m.sha FROM messages m JOIN blocks b ON b.bid=m.bid ORDER BY b.seg,b.off,m.ioff"))
                    using (var r = cmd.ExecuteReader())
                    {
                        while (r.Read())
                        {
                            rep.DeepChecked++;
                            try
                            {
                                byte[] blk = cache.Block(r.GetInt64(2), r.GetInt64(5), r.GetInt64(6), r.GetInt64(7), r.GetInt64(8));
                                var h = SHA256.HashData(new ReadOnlySpan<byte>(blk, (int)r.GetInt64(3), (int)r.GetInt64(4)));
                                if (!h.AsSpan().SequenceEqual((byte[])r["sha"])) { rep.HashMismatches++; rep.Problems.Add("partition " + p.Index + ": hash mismatch for message " + r.GetString(0)); }
                            }
                            catch (InvalidDataException e) { rep.HashMismatches++; rep.Problems.Add("partition " + p.Index + ": message " + r.GetString(0) + ": " + e.Message); }
                        }
                    }
                }
            }
        }

        public StoreStats GetStats()
        {
            ThrowIfBad();
            Flush();
            var s = new StoreStats { Partitions = _partitions };
            for (int i = 0; i < _partitions; i++)
            {
                var p = PartAt(i);
                if (!File.Exists(p.DbPath)) continue;
                s.PartitionsUsed++;
                using (var db = OpenConn(p.DbPath, true, 0))
                {
                    s.Messages += Convert.ToInt64(Scalar(db, "SELECT COALESCE(SUM(msg_count),0) FROM convs") ?? 0L, CultureInfo.InvariantCulture);
                    s.Conversations += Convert.ToInt64(Scalar(db, "SELECT COUNT(*) FROM convs") ?? 0L, CultureInfo.InvariantCulture);
                    s.Segments += Convert.ToInt64(Scalar(db, "SELECT COUNT(*) FROM segs") ?? 0L, CultureInfo.InvariantCulture);
                }
                if (Directory.Exists(p.SegDir)) foreach (var f in Directory.EnumerateFiles(p.SegDir)) s.SegmentBytes += new FileInfo(f).Length;
            }
            using (var c = OpenCatalogRead()) s.Users = Convert.ToInt64(Scalar(c, "SELECT COUNT(*) FROM users") ?? 0L, CultureInfo.InvariantCulture);
            return s;
        }

        #endregion

        // =====================================================================================================
        #region Partition (index + segments of one hash bucket)

        sealed class Pend
        {
            public string Conv, Id, ReplyTo, Etag, Month;
            public int Start, Len, Seq, Versions, Ioff;
            public long Created, Bid;
            public long? Lm;
            public byte[] Sha;
        }

        sealed class SegWriter
        {
            public string Month; public long N, Id; public string Path; public FileStream Fs; public long Pos, Ulen; public bool RowInserted; public long LastUse;
        }

        internal sealed class Partition
        {
            public readonly int Index;
            public readonly string Dir, DbPath, SegDir;
            public readonly object Gate = new object();
            readonly TmtStore _s;
            SqliteConnection _db;
            bool _open;
            SqliteCommand _selMsg, _selCid, _insConv, _updCount, _insBlock, _upsMsg, _insSeg, _updSeg;
            SqliteParameter _selMsgC, _selMsgI;
            readonly Dictionary<string, long> _cids = new Dictionary<string, long>();
            long _nextCid = 1, _nextBid = 1, _nextSeg = 1;
            readonly Dictionary<string, SegWriter> _writers = new Dictionary<string, SegWriter>();

            byte[] _buf = new byte[0];
            public int BufLen;
            readonly List<Pend> _entries = new List<Pend>();
            readonly Dictionary<(string, string), Pend> _latest = new Dictionary<(string, string), Pend>();
            readonly Dictionary<string, int> _convNew = new Dictionary<string, int>();
            volatile int _pending;
            public long PendingSinceTick;
            public int PendingCount { get { return _pending; } }
            public bool IsOpen { get { return _open; } }

            public Partition(TmtStore s, int index)
            {
                _s = s; Index = index; Dir = s.PartDir(index); DbPath = Path.Combine(Dir, "part.db"); SegDir = Path.Combine(Dir, "seg");
            }

            public void EnsureOpenLocked(TmtStore s)
            {
                if (_open) return;
                Directory.CreateDirectory(SegDir);
                _db = s.OpenConn(DbPath, false, s._o.PartitionCacheKb);
                Exec(_db, @"
CREATE TABLE IF NOT EXISTS pmeta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS convs(cid INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, msg_count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS segs(id INTEGER PRIMARY KEY, month TEXT NOT NULL, n INTEGER NOT NULL, committed_clen INTEGER NOT NULL DEFAULT 0, committed_ulen INTEGER NOT NULL DEFAULT 0, UNIQUE(month,n));
CREATE TABLE IF NOT EXISTS blocks(bid INTEGER PRIMARY KEY, seg INTEGER NOT NULL, off INTEGER NOT NULL, clen INTEGER NOT NULL, blen INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS ix_blocks_seg ON blocks(seg, off);
CREATE TABLE IF NOT EXISTS messages(cid INTEGER NOT NULL, id TEXT NOT NULL, reply_to TEXT, created INTEGER NOT NULL, modified INTEGER, etag TEXT, sha BLOB NOT NULL,
  versions INTEGER NOT NULL, bid INTEGER NOT NULL, ioff INTEGER NOT NULL, len INTEGER NOT NULL, PRIMARY KEY(cid,id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_roots ON messages(cid, created, id) WHERE reply_to IS NULL;
CREATE INDEX IF NOT EXISTS ix_replies ON messages(cid, reply_to, created, id) WHERE reply_to IS NOT NULL;");
                string pc = (string)Scalar(_db, "SELECT value FROM pmeta WHERE key='partitions'");
                if (pc == null) { Run(_db, "INSERT INTO pmeta(key,value) VALUES('partitions',@v),('index',@i)", "@v", s._partitions.ToString(CultureInfo.InvariantCulture), "@i", Index.ToString(CultureInfo.InvariantCulture)); }
                else if (int.Parse(pc, CultureInfo.InvariantCulture) != s._partitions) throw new InvalidOperationException("Partition " + Index + " was created for " + pc + " partitions, the store has " + s._partitions + ".");
                _nextCid = Convert.ToInt64(Scalar(_db, "SELECT COALESCE(MAX(cid),0)+1 FROM convs"), CultureInfo.InvariantCulture);
                _nextBid = Convert.ToInt64(Scalar(_db, "SELECT COALESCE(MAX(bid),0)+1 FROM blocks"), CultureInfo.InvariantCulture);
                _nextSeg = Convert.ToInt64(Scalar(_db, "SELECT COALESCE(MAX(id),0)+1 FROM segs"), CultureInfo.InvariantCulture);
                Recover(s);

                _selMsg = Cmd(_db, "SELECT modified,etag,sha,versions FROM messages WHERE cid=@c AND id=@i");
                _selMsgC = _selMsg.Parameters.Add("@c", SqliteType.Integer); _selMsgI = _selMsg.Parameters.Add("@i", SqliteType.Text);
                _selCid = Cmd(_db, "SELECT cid FROM convs WHERE key=@k"); _selCid.Parameters.Add("@k", SqliteType.Text);
                _insConv = Cmd(_db, "INSERT INTO convs(cid,key,msg_count) VALUES(@c,@k,0)"); _insConv.Parameters.Add("@c", SqliteType.Integer); _insConv.Parameters.Add("@k", SqliteType.Text);
                _updCount = Cmd(_db, "UPDATE convs SET msg_count=msg_count+@n WHERE cid=@c"); _updCount.Parameters.Add("@n", SqliteType.Integer); _updCount.Parameters.Add("@c", SqliteType.Integer);
                _insBlock = Cmd(_db, "INSERT INTO blocks(bid,seg,off,clen,blen) VALUES(@b,@s,@o,@c,@l)");
                foreach (var n in new[] { "@b", "@s", "@o", "@c", "@l" }) _insBlock.Parameters.Add(n, SqliteType.Integer);
                _upsMsg = Cmd(_db, @"INSERT INTO messages(cid,id,reply_to,created,modified,etag,sha,versions,bid,ioff,len) VALUES(@c,@i,@rp,@cr,@lm,@et,@sh,@v,@b,@io,@ln)
ON CONFLICT(cid,id) DO UPDATE SET reply_to=excluded.reply_to, created=excluded.created, modified=excluded.modified, etag=excluded.etag, sha=excluded.sha, versions=excluded.versions,
  bid=excluded.bid, ioff=excluded.ioff, len=excluded.len");
                foreach (var n in new[] { "@c", "@i", "@rp", "@cr", "@lm", "@et", "@sh", "@v", "@b", "@io", "@ln" }) AddP(_upsMsg, n);
                _insSeg = Cmd(_db, "INSERT INTO segs(id,month,n,committed_clen,committed_ulen) VALUES(@i,@m,@n,0,0)");
                _insSeg.Parameters.Add("@i", SqliteType.Integer); _insSeg.Parameters.Add("@m", SqliteType.Text); _insSeg.Parameters.Add("@n", SqliteType.Integer);
                _updSeg = Cmd(_db, "UPDATE segs SET committed_clen=@c, committed_ulen=@u WHERE id=@i");
                foreach (var n in new[] { "@c", "@u", "@i" }) _updSeg.Parameters.Add(n, SqliteType.Integer);
                _open = true;
            }

            /// <summary>Open-time repair: segments shorter than their committed length lose the blocks (and message rows) beyond their end.</summary>
            void Recover(TmtStore s)
            {
                var segs = new List<(long id, string name, long clen)>();
                using (var cmd = Cmd(_db, "SELECT id,month,n,committed_clen FROM segs"))
                using (var r = cmd.ExecuteReader())
                    while (r.Read()) segs.Add((r.GetInt64(0), r.GetString(1) + "-" + r.GetInt64(2).ToString(CultureInfo.InvariantCulture) + ".jsonl.gz", r.GetInt64(3)));
                bool changed = false;
                foreach (var sg in segs)
                {
                    string path = Path.Combine(SegDir, sg.name);
                    long len = File.Exists(path) ? new FileInfo(path).Length : 0;
                    if (len >= sg.clen) continue;
                    long blocks = Convert.ToInt64(Scalar(_db, "SELECT COUNT(*) FROM blocks WHERE seg=@s AND off+clen>@l", "@s", sg.id, "@l", len), CultureInfo.InvariantCulture);
                    Exec(_db, "BEGIN IMMEDIATE");
                    try
                    {
                        long msgs = Run(_db, "DELETE FROM messages WHERE bid IN (SELECT bid FROM blocks WHERE seg=@s AND off+clen>@l)", "@s", sg.id, "@l", len);
                        Run(_db, "DELETE FROM blocks WHERE seg=@s AND off+clen>@l", "@s", sg.id, "@l", len);
                        Run(_db, "UPDATE segs SET committed_clen=@l WHERE id=@s", "@s", sg.id, "@l", len);
                        Exec(_db, "COMMIT");
                        lock (s._recovery) s._recovery.Add("partition " + Index + ": segment " + sg.name + " is " + len + " bytes, " + sg.clen + " were committed: " + blocks + " blocks and " + msgs + " message index entries removed (they will be exported again).");
                        changed = true;
                    }
                    catch { try { Exec(_db, "ROLLBACK"); } catch { } throw; }
                }
                if (changed) Exec(_db, "UPDATE convs SET msg_count=(SELECT COUNT(*) FROM messages WHERE messages.cid=convs.cid)");
            }

            public long LookupCid(string key)
            {
                if (_cids.TryGetValue(key, out long c)) return c;
                _selCid.Parameters["@k"].Value = key;
                object v = _selCid.ExecuteScalar();
                if (v == null) return -1;
                c = Convert.ToInt64(v, CultureInfo.InvariantCulture);
                _cids[key] = c;
                return c;
            }

            static int CompareLm(long? a, long? b)
            {
                if (a == null) return b == null ? 0 : -1;
                if (b == null) return 1;
                return a.Value.CompareTo(b.Value);
            }

            public void AcceptLocked(string conv, long cid, string id, string replyTo, long created, long? lm, string etag, ReadOnlySpan<byte> sha, ReadOnlySpan<byte> line, MessageWriteResult res)
            {
                bool exists = false; long? exLm = null; string exEtag = null; byte[] exSha = null; int exVer = 0;
                if (_latest.TryGetValue((conv, id), out var pm)) { exists = true; exLm = pm.Lm; exEtag = pm.Etag; exSha = pm.Sha; exVer = pm.Versions; }
                else if (cid >= 0)
                {
                    _selMsgC.Value = cid; _selMsgI.Value = id;
                    using (var r = _selMsg.ExecuteReader())
                        if (r.Read())
                        {
                            exists = true; exLm = r.IsDBNull(0) ? (long?)null : r.GetInt64(0); exEtag = r.IsDBNull(1) ? null : r.GetString(1); exSha = (byte[])r["sha"]; exVer = r.GetInt32(3);
                        }
                }
                if (exists)
                {
                    if (sha.SequenceEqual(exSha)) { res.Unchanged++; return; }
                    int c = CompareLm(lm, exLm);
                    if (c < 0) { res.Unchanged++; return; }
                    if (c == 0 && etag != null && string.Equals(etag, exEtag, StringComparison.Ordinal)) { res.Unchanged++; return; }
                    res.Updated++;
                }
                else
                {
                    res.New++;
                    _convNew.TryGetValue(conv, out int n); _convNew[conv] = n + 1;
                }
                int need = BufLen + line.Length;
                if (need > _buf.Length) Array.Resize(ref _buf, Math.Max(Math.Max(need, 64 * 1024), _buf.Length * 2));
                line.CopyTo(new Span<byte>(_buf, BufLen, line.Length));
                var e = new Pend { Conv = conv, Id = id, ReplyTo = replyTo, Etag = etag, Created = created, Lm = lm, Sha = sha.ToArray(), Versions = exVer + 1, Start = BufLen, Len = line.Length, Seq = _entries.Count, Month = MonthOf(created) };
                BufLen += line.Length;
                if (_entries.Count == 0) PendingSinceTick = Environment.TickCount64;
                _entries.Add(e); _latest[(conv, id)] = e;
                _pending = _entries.Count;
            }

            SegWriter GetWriter(string month, long needBytes)
            {
                if (_writers.TryGetValue(month, out var w))
                {
                    if (w.Ulen == 0 || w.Ulen + needBytes <= _s._o.SegmentMaxBytes)
                    {
                        // metadata stays cached when the handle is evicted: no SQL, no directory scan on the hot path
                        if (w.Fs == null)
                        {
                            w.Fs = new FileStream(w.Path, FileMode.Open, FileAccess.Write, FileShare.Read | FileShare.Delete, 4096);
                            if (w.Fs.Length != w.Pos) { long len = w.Fs.Length; w.Fs.Dispose(); w.Fs = null; throw new IOException("Segment " + w.Path + " changed under the writer (length " + len + ", expected " + w.Pos + ")."); }
                            w.Fs.Seek(0, SeekOrigin.End);
                        }
                        w.LastUse = Environment.TickCount64; return w;
                    }
                    RetireWriter(w);
                }
                // continue the newest segment of this month when it is intact, else start the next one
                long n = 0, id = 0, clen = 0, ulen = 0;
                using (var cmd = Cmd(_db, "SELECT id,n,committed_clen,committed_ulen FROM segs WHERE month=@m ORDER BY n DESC LIMIT 1", "@m", month))
                using (var r = cmd.ExecuteReader())
                    if (r.Read()) { id = r.GetInt64(0); n = r.GetInt64(1); clen = r.GetInt64(2); ulen = r.GetInt64(3); }
                long maxFileN = 0;
                foreach (var f in Directory.EnumerateFiles(SegDir, month + "-*.jsonl.gz"))
                {
                    string nm = Path.GetFileName(f); string mid = nm.Substring(month.Length + 1, nm.Length - month.Length - 1 - ".jsonl.gz".Length);
                    if (long.TryParse(mid, NumberStyles.None, CultureInfo.InvariantCulture, out long fn) && fn > maxFileN) maxFileN = fn;
                }
                var nw = new SegWriter { Month = month, LastUse = Environment.TickCount64 };
                string existing = n > 0 ? Path.Combine(SegDir, month + "-" + n.ToString(CultureInfo.InvariantCulture) + ".jsonl.gz") : null;
                if (n > 0 && File.Exists(existing) && new FileInfo(existing).Length == clen && (ulen == 0 || ulen + needBytes <= _s._o.SegmentMaxBytes))
                {
                    nw.N = n; nw.Id = id; nw.Path = existing; nw.Pos = clen; nw.Ulen = ulen; nw.RowInserted = true;
                    nw.Fs = new FileStream(existing, FileMode.Open, FileAccess.Write, FileShare.Read | FileShare.Delete, 4096);
                    nw.Fs.Seek(0, SeekOrigin.End);
                }
                else
                {
                    nw.N = Math.Max(n, maxFileN) + 1; nw.Id = _nextSeg++;
                    nw.Path = Path.Combine(SegDir, month + "-" + nw.N.ToString(CultureInfo.InvariantCulture) + ".jsonl.gz");
                    nw.Fs = new FileStream(nw.Path, FileMode.CreateNew, FileAccess.Write, FileShare.Read | FileShare.Delete, 4096);
                }
                _writers[month] = nw;
                return nw;
            }

            readonly List<SegWriter> _retired = new List<SegWriter>();
            void RetireWriter(SegWriter w) { _writers.Remove(w.Month); _retired.Add(w); }

            public void CloseWriters()
            {
                foreach (var w in _writers.Values) { try { w.Fs?.Dispose(); } catch { } }
                _writers.Clear();
            }

            sealed class BlockRec { public long Bid, Seg, Off, Clen, Blen; }

            public void FlushLocked(TmtStore s)
            {
                if (_entries.Count == 0) return;
                EnsureOpenLocked(s);
                var o = s._o;
                _entries.Sort((a, b) => { int c = string.CompareOrdinal(a.Month, b.Month); if (c != 0) return c; c = string.CompareOrdinal(a.Conv, b.Conv); return c != 0 ? c : a.Seq.CompareTo(b.Seq); });
                var blocks = new List<BlockRec>();
                var touched = new HashSet<SegWriter>();
                var ms = new MemoryStream(Math.Max(1024, o.BlockBytes / 2));
                byte[] nl = { (byte)'\n' };
                int i = 0, n = _entries.Count;
                while (i < n)
                {
                    string month = _entries[i].Month;
                    int j = i; long blen = 0;
                    while (j < n && _entries[j].Month == month && (j == i || blen + _entries[j].Len + 1 <= o.BlockBytes)) { blen += _entries[j].Len + 1; j++; }
                    var w = GetWriter(month, blen);
                    touched.Add(w);
                    ms.SetLength(0);
                    using (var gz = new GZipStream(ms, CompressionLevel.Fastest, true))
                    {
                        int ioff = 0;
                        for (int k = i; k < j; k++)
                        {
                            var e = _entries[k];
                            gz.Write(_buf, e.Start, e.Len); gz.Write(nl, 0, 1);
                            e.Ioff = ioff; ioff += e.Len + 1;
                        }
                    }
                    long bid = _nextBid++;
                    w.Fs.Write(ms.GetBuffer(), 0, (int)ms.Length);
                    blocks.Add(new BlockRec { Bid = bid, Seg = w.Id, Off = w.Pos, Clen = ms.Length, Blen = blen });
                    w.Pos += ms.Length; w.Ulen += blen; w.LastUse = Environment.TickCount64;
                    for (int k = i; k < j; k++) _entries[k].Bid = bid;
                    i = j;
                }
                foreach (var w in touched) w.Fs.Flush(o.SyncSegments);
                foreach (var w in _retired) { if (w.Fs != null) { w.Fs.Flush(o.SyncSegments); touched.Add(w); } }

                var newCids = new List<string>();
                Exec(_db, "BEGIN IMMEDIATE");
                try
                {
                    foreach (var w in touched)
                        if (!w.RowInserted) { _insSeg.Parameters["@i"].Value = w.Id; _insSeg.Parameters["@m"].Value = w.Month; _insSeg.Parameters["@n"].Value = w.N; _insSeg.ExecuteNonQuery(); }
                    foreach (var b in blocks)
                    {
                        var pr = _insBlock.Parameters; pr["@b"].Value = b.Bid; pr["@s"].Value = b.Seg; pr["@o"].Value = b.Off; pr["@c"].Value = b.Clen; pr["@l"].Value = b.Blen;
                        _insBlock.ExecuteNonQuery();
                    }
                    var cidOf = new Dictionary<string, long>();
                    foreach (var e in _latest.Values)
                    {
                        if (!cidOf.TryGetValue(e.Conv, out long cid))
                        {
                            cid = LookupCid(e.Conv);
                            if (cid < 0) { cid = _nextCid++; _insConv.Parameters["@c"].Value = cid; _insConv.Parameters["@k"].Value = e.Conv; _insConv.ExecuteNonQuery(); _cids[e.Conv] = cid; newCids.Add(e.Conv); }
                            cidOf[e.Conv] = cid;
                        }
                        var pr = _upsMsg.Parameters;
                        pr["@c"].Value = cid; pr["@i"].Value = e.Id; pr["@rp"].Value = (object)e.ReplyTo ?? DBNull.Value; pr["@cr"].Value = e.Created;
                        pr["@lm"].Value = e.Lm.HasValue ? (object)e.Lm.Value : DBNull.Value; pr["@et"].Value = (object)e.Etag ?? DBNull.Value; pr["@sh"].Value = e.Sha;
                        pr["@v"].Value = e.Versions; pr["@b"].Value = e.Bid; pr["@io"].Value = e.Ioff; pr["@ln"].Value = e.Len;
                        _upsMsg.ExecuteNonQuery();
                    }
                    foreach (var kv in _convNew)
                    {
                        _updCount.Parameters["@n"].Value = kv.Value; _updCount.Parameters["@c"].Value = cidOf[kv.Key]; _updCount.ExecuteNonQuery();
                    }
                    foreach (var w in touched) { _updSeg.Parameters["@c"].Value = w.Pos; _updSeg.Parameters["@u"].Value = w.Ulen; _updSeg.Parameters["@i"].Value = w.Id; _updSeg.ExecuteNonQuery(); }
                    Exec(_db, "COMMIT");
                }
                catch
                {
                    try { Exec(_db, "ROLLBACK"); } catch { }
                    foreach (var k in newCids) _cids.Remove(k);
                    throw;
                }
                foreach (var w in touched) w.RowInserted = true;
                foreach (var w in _retired) { try { w.Fs?.Dispose(); } catch { } }
                _retired.Clear();
                _entries.Clear(); _latest.Clear(); _convNew.Clear(); BufLen = 0; _pending = 0;
                if (_buf.Length > 16 * 1024 * 1024) _buf = new byte[0];
                if (_writers.Count > o.MaxOpenSegmentsPerPartition && _writers.Values.Count(x => x.Fs != null) > o.MaxOpenSegmentsPerPartition)
                {
                    var open = _writers.Values.Where(x => x.Fs != null).ToList();
                    foreach (var w in open.OrderBy(x => x.LastUse).Take(open.Count - o.MaxOpenSegmentsPerPartition)) { try { w.Fs.Dispose(); } catch { } w.Fs = null; }
                }
            }

            public void Close(TmtStore s, bool flush)
            {
                lock (Gate)
                {
                    try { if (flush && _open && _entries.Count > 0) FlushLocked(s); }
                    finally
                    {
                        CloseWriters();
                        foreach (var w in _retired) { try { w.Fs?.Dispose(); } catch { } }
                        foreach (var c in new[] { _selMsg, _selCid, _insConv, _updCount, _insBlock, _upsMsg, _insSeg, _updSeg }) { try { c?.Dispose(); } catch { } }
                        if (_db != null) { try { if (flush) Exec(_db, "PRAGMA wal_checkpoint(TRUNCATE)"); } catch { } try { _db.Dispose(); } catch { } _db = null; }
                        _open = false;
                    }
                }
            }
        }

        #endregion
    }
}
