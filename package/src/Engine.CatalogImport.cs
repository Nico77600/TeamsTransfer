// =============================================================================
//  TeamsTransfer - engine: catalog persistence of the import maps
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.2
//
//  A partial class of TmtStore: it implements the three maps of Engine.ImportContracts.cs on the same catalog.db (same
//  writer connection and lock as the lots, the journal and the ghosts), so a plan and the maps it is built on can never
//  disagree.
//
//    identity_map   source user id -> kind, target id, rule        one row per source user (100k+ rows)
//    target_map     conversation key -> where it is imported       one row per conversation (millions at the extreme)
//    file_copy_map  (conversation, message, attachment) -> copy    one row per attachment (millions)
//
//  Schema: TmtStore has no hook to run extra DDL when the catalog is opened (Engine.Store.cs belongs to another lot), so
//  the tables are created lazily and idempotently (CREATE TABLE IF NOT EXISTS) by EnsureImportSchema(), which every method
//  of this file calls first (one volatile flag read once the schema is ready). A store opened read-only never creates
//  anything: reads answer "nothing" while the tables do not exist, writes are refused like every other write.
//
//  Indexes (what the stages actually ask):
//    identity_map   PK source id; kind (List(kind), the plan counters); target id (reverse look-up, ghost audit)
//    target_map     PK conversation key; kind; state (the importer lists Planned / Failed ones); (team name, topic) of the
//                   archive channels (which conversations share a channel, how full a team already is)
//    file_copy_map  PK (conversation, message, attachment); state (pending / failed lists); sha256 (a file posted in 50
//                   chats is uploaded once: look it up before uploading)
//
//  Upsert replaces the whole row. UpsertIdentities / UpsertTargets / UpsertFileCopies do the same for a batch in ONE
//  transaction (use them for 100k rows: a transaction per row is ~50x slower). Merge(otherStoreRoot) does NOT carry these
//  tables: the coordinator's catalog is authoritative for the maps, like for lots and the journal (documented, not needed).
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace TeamsTransfer
{
    public sealed partial class TmtStore : IIdentityMap, ITargetMap, IFileCopyMap
    {
        const string ImportSchemaSql = @"
CREATE TABLE IF NOT EXISTS identity_map(src_id TEXT PRIMARY KEY, src_name TEXT, src_upn TEXT, kind INTEGER NOT NULL, tgt_id TEXT, tgt_name TEXT, rule TEXT, note TEXT, updated INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_idmap_kind ON identity_map(kind);
CREATE INDEX IF NOT EXISTS ix_idmap_target ON identity_map(tgt_id) WHERE tgt_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS target_map(conv_key TEXT PRIMARY KEY, kind INTEGER NOT NULL, tgt_chat TEXT, tgt_team TEXT, tgt_channel TEXT, topic TEXT, membership TEXT, team_name TEXT, members_json TEXT,
  state INTEGER NOT NULL DEFAULT 0, note TEXT, updated INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_target_kind ON target_map(kind);
CREATE INDEX IF NOT EXISTS ix_target_state ON target_map(state);
CREATE INDEX IF NOT EXISTS ix_target_archive ON target_map(team_name, topic) WHERE kind=4;
CREATE TABLE IF NOT EXISTS file_copy_map(conv_key TEXT NOT NULL, message_id TEXT NOT NULL, attachment_id TEXT NOT NULL, sha256 TEXT, name TEXT, drive_id TEXT, item_id TEXT, web_url TEXT,
  state INTEGER NOT NULL DEFAULT 0, error TEXT, updated INTEGER NOT NULL, PRIMARY KEY(conv_key, message_id, attachment_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_fcm_state ON file_copy_map(state);
CREATE INDEX IF NOT EXISTS ix_fcm_sha ON file_copy_map(sha256) WHERE sha256 IS NOT NULL;
";

        volatile bool _importSchemaReady;

        /// <summary>
        /// Creates the three import-map tables when they do not exist yet (idempotent, called by every method of the maps).
        /// Returns false only for a read-only store whose catalog does not hold them: nothing to read, nothing to create.
        /// </summary>
        public bool EnsureImportSchema()
        {
            if (_importSchemaReady) return true;
            ThrowIfBad();
            if (_o.ReadOnly)
            {
                using (var c = OpenCatalogRead())
                {
                    bool have = Scalar(c, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='identity_map'") != null
                             && Scalar(c, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='target_map'") != null
                             && Scalar(c, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='file_copy_map'") != null;
                    if (have) _importSchemaReady = true;
                    return have;
                }
            }
            lock (_catLock) { Exec(_cat, ImportSchemaSql); }
            _importSchemaReady = true;
            return true;
        }

        // =====================================================================================================
        #region IIdentityMap

        static IdentityMapping ReadIdentity(SqliteDataReader r)
        {
            return new IdentityMapping
            {
                SourceUserId = r.GetString(0), SourceDisplayName = Str(r, 1), SourceUserPrincipalName = Str(r, 2), Kind = (IdentityKind)r.GetInt32(3),
                TargetUserId = Str(r, 4), TargetDisplayName = Str(r, 5), Rule = Str(r, 6), Note = Str(r, 7)
            };
        }
        const string IdentityCols = "src_id,src_name,src_upn,kind,tgt_id,tgt_name,rule,note";
        const string IdentityUpsertSql = "INSERT OR REPLACE INTO identity_map(" + IdentityCols + ",updated) VALUES(@i,@sn,@su,@k,@ti,@tn,@r,@no,@u)";

        IdentityMapping IIdentityMap.Get(string sourceUserId) { return GetIdentity(sourceUserId); }

        /// <summary>The identity mapping of a source user (null when none). Named: Get(string) is implemented explicitly by IIdentityMap and by ITargetMap.</summary>
        public IdentityMapping GetIdentity(string sourceUserId)
        {
            if (string.IsNullOrEmpty(sourceUserId) || !EnsureImportSchema()) return null;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + IdentityCols + " FROM identity_map WHERE src_id=@i", "@i", sourceUserId))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadIdentity(r) : null;
        }

        void IIdentityMap.Upsert(IdentityMapping mapping) { UpsertIdentities(new[] { mapping }); }
        public void UpsertIdentity(IdentityMapping mapping) { UpsertIdentities(new[] { mapping }); }

        /// <summary>Upserts many identity mappings in one transaction (same semantics as Upsert, which replaces the row).</summary>
        public void UpsertIdentities(IEnumerable<IdentityMapping> mappings)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (mappings == null) return;
            EnsureImportSchema();
            DateTimeOffset now = Now;
            InCatalogTransaction(() =>
            {
                foreach (var m in mappings)
                {
                    if (m == null || string.IsNullOrEmpty(m.SourceUserId)) throw new ArgumentException("IdentityMapping.SourceUserId is required.");
                    Run(_cat, IdentityUpsertSql, "@i", m.SourceUserId, "@sn", m.SourceDisplayName, "@su", m.SourceUserPrincipalName, "@k", m.Kind, "@ti", m.TargetUserId, "@tn", m.TargetDisplayName,
                        "@r", m.Rule, "@no", m.Note, "@u", now);
                }
            });
        }

        /// <summary>Identity mappings, optionally of one kind, ordered by source user id.</summary>
        IEnumerable<IdentityMapping> IIdentityMap.List(IdentityKind? kind) { return ListIdentities(kind); }

        public IEnumerable<IdentityMapping> ListIdentities(IdentityKind? kind = null)
        {
            if (!EnsureImportSchema()) yield break;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + IdentityCols + " FROM identity_map" + (kind.HasValue ? " WHERE kind=@k" : "") + " ORDER BY src_id", "@k", kind))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadIdentity(r);
        }

        /// <summary>Number of identity mappings per kind (the plan counters, without reading the rows).</summary>
        public IReadOnlyDictionary<IdentityKind, int> GetIdentitySummary()
        {
            var d = new Dictionary<IdentityKind, int>();
            foreach (IdentityKind k in Enum.GetValues(typeof(IdentityKind))) d[k] = 0;
            if (!EnsureImportSchema()) return d;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT kind,COUNT(*) FROM identity_map GROUP BY kind"))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) d[(IdentityKind)r.GetInt32(0)] = r.GetInt32(1);
            return d;
        }

        #endregion

        // =====================================================================================================
        #region ITargetMap

        static TargetMapping ReadTarget(SqliteDataReader r)
        {
            var t = new TargetMapping
            {
                SourceConversationKey = r.GetString(0), Kind = (TargetKind)r.GetInt32(1), TargetChatId = Str(r, 2), TargetTeamId = Str(r, 3), TargetChannelId = Str(r, 4),
                CreateTopic = Str(r, 5), CreateMembershipType = Str(r, 6), CreateTeamName = Str(r, 7), State = (TargetState)r.GetInt32(9), Note = Str(r, 10)
            };
            string mj = Str(r, 8);
            if (!string.IsNullOrEmpty(mj))
            {
                try { t.TargetMemberIds = JsonSerializer.Deserialize<List<string>>(mj) ?? new List<string>(); }
                catch (JsonException) { t.TargetMemberIds = new List<string>(); }
            }
            return t;
        }
        const string TargetCols = "conv_key,kind,tgt_chat,tgt_team,tgt_channel,topic,membership,team_name,members_json,state,note";
        const string TargetUpsertSql = "INSERT OR REPLACE INTO target_map(" + TargetCols + ",updated) VALUES(@k,@kd,@tc,@tt,@tch,@tp,@m,@tn,@mj,@s,@no,@u)";

        TargetMapping ITargetMap.Get(string sourceConversationKey)
        {
            if (string.IsNullOrEmpty(sourceConversationKey) || !EnsureImportSchema()) return null;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + TargetCols + " FROM target_map WHERE conv_key=@k", "@k", sourceConversationKey))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadTarget(r) : null;
        }

        /// <summary>The target of one conversation (same as the ITargetMap member; the plain name is taken by IIdentityMap.Get).</summary>
        public TargetMapping GetTarget(string sourceConversationKey) { return ((ITargetMap)this).Get(sourceConversationKey); }

        void ITargetMap.Upsert(TargetMapping mapping) { UpsertTargets(new[] { mapping }); }
        public void UpsertTarget(TargetMapping mapping) { UpsertTargets(new[] { mapping }); }

        /// <summary>Upserts many target mappings in one transaction (the row is replaced, State included).</summary>
        public void UpsertTargets(IEnumerable<TargetMapping> mappings)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (mappings == null) return;
            EnsureImportSchema();
            DateTimeOffset now = Now;
            InCatalogTransaction(() =>
            {
                foreach (var m in mappings)
                {
                    if (m == null || string.IsNullOrEmpty(m.SourceConversationKey)) throw new ArgumentException("TargetMapping.SourceConversationKey is required.");
                    string members = m.TargetMemberIds != null && m.TargetMemberIds.Count > 0 ? JsonSerializer.Serialize(m.TargetMemberIds) : null;
                    Run(_cat, TargetUpsertSql, "@k", m.SourceConversationKey, "@kd", m.Kind, "@tc", m.TargetChatId, "@tt", m.TargetTeamId, "@tch", m.TargetChannelId, "@tp", m.CreateTopic,
                        "@m", m.CreateMembershipType, "@tn", m.CreateTeamName, "@mj", members, "@s", m.State, "@no", m.Note, "@u", now);
                }
            });
        }

        /// <summary>Target mappings, optionally of one kind, ordered by conversation key.</summary>
        IEnumerable<TargetMapping> ITargetMap.List(TargetKind? kind) { return ListTargets(kind); }

        public IEnumerable<TargetMapping> ListTargets(TargetKind? kind = null, TargetState? state = null)
        {
            if (!EnsureImportSchema()) yield break;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + TargetCols + " FROM target_map WHERE 1=1" + (kind.HasValue ? " AND kind=@k" : "") + (state.HasValue ? " AND state=@s" : "") + " ORDER BY conv_key", "@k", kind, "@s", state))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadTarget(r);
        }

        /// <summary>Sets the state of one target (the importer: Created / Failed) and, when given, the ids it learned.</summary>
        public void SetTargetState(string sourceConversationKey, TargetState state, string targetChatId = null, string targetTeamId = null, string targetChannelId = null, string note = null)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            EnsureImportSchema();
            lock (_catLock)
                if (Run(_cat, @"UPDATE target_map SET state=@s, tgt_chat=COALESCE(@tc,tgt_chat), tgt_team=COALESCE(@tt,tgt_team), tgt_channel=COALESCE(@tch,tgt_channel), note=COALESCE(@no,note), updated=@u WHERE conv_key=@k",
                    "@s", state, "@tc", targetChatId, "@tt", targetTeamId, "@tch", targetChannelId, "@no", note, "@u", Now, "@k", sourceConversationKey) == 0)
                    throw new KeyNotFoundException("No target mapping for conversation " + sourceConversationKey);
        }

        #endregion

        // =====================================================================================================
        #region IFileCopyMap

        static FileCopyRecord ReadFileCopy(SqliteDataReader r)
        {
            return new FileCopyRecord
            {
                ConversationKey = r.GetString(0), MessageId = r.GetString(1), AttachmentId = r.GetString(2), Sha256 = Str(r, 3), Name = Str(r, 4), TargetDriveId = Str(r, 5), TargetItemId = Str(r, 6),
                TargetWebUrl = Str(r, 7), State = (FileCopyState)r.GetInt32(8), Error = Str(r, 9)
            };
        }
        const string FileCopyCols = "conv_key,message_id,attachment_id,sha256,name,drive_id,item_id,web_url,state,error";

        FileCopyRecord IFileCopyMap.Get(string conversationKey, string messageId, string attachmentId) { return GetFileCopy(conversationKey, messageId, attachmentId); }

        public FileCopyRecord GetFileCopy(string conversationKey, string messageId, string attachmentId)
        {
            if (!EnsureImportSchema()) return null;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + FileCopyCols + " FROM file_copy_map WHERE conv_key=@c AND message_id=@m AND attachment_id=@a", "@c", conversationKey, "@m", messageId, "@a", attachmentId))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadFileCopy(r) : null;
        }

        void IFileCopyMap.Upsert(FileCopyRecord record) { UpsertFileCopies(new[] { record }); }
        public void UpsertFileCopy(FileCopyRecord record) { UpsertFileCopies(new[] { record }); }

        /// <summary>Upserts many file-copy records in one transaction (the row is replaced).</summary>
        public void UpsertFileCopies(IEnumerable<FileCopyRecord> records)
        {
            ThrowIfBad(); ThrowIfReadOnly();
            if (records == null) return;
            EnsureImportSchema();
            DateTimeOffset now = Now;
            InCatalogTransaction(() =>
            {
                foreach (var f in records)
                {
                    if (f == null || string.IsNullOrEmpty(f.ConversationKey) || string.IsNullOrEmpty(f.MessageId) || string.IsNullOrEmpty(f.AttachmentId))
                        throw new ArgumentException("FileCopyRecord needs ConversationKey, MessageId and AttachmentId.");
                    Run(_cat, "INSERT OR REPLACE INTO file_copy_map(" + FileCopyCols + ",updated) VALUES(@c,@m,@a,@sh,@n,@d,@i,@w,@s,@e,@u)",
                        "@c", f.ConversationKey, "@m", f.MessageId, "@a", f.AttachmentId, "@sh", f.Sha256, "@n", f.Name, "@d", f.TargetDriveId, "@i", f.TargetItemId, "@w", f.TargetWebUrl,
                        "@s", f.State, "@e", f.Error, "@u", now);
                }
            });
        }

        IEnumerable<FileCopyRecord> IFileCopyMap.List(string conversationKey, FileCopyState? state) { return ListFileCopies(conversationKey, state); }

        public IEnumerable<FileCopyRecord> ListFileCopies(string conversationKey = null, FileCopyState? state = null)
        {
            if (!EnsureImportSchema()) yield break;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + FileCopyCols + " FROM file_copy_map WHERE 1=1" + (!string.IsNullOrEmpty(conversationKey) ? " AND conv_key=@c" : "") + (state.HasValue ? " AND state=@s" : "") + " ORDER BY conv_key, message_id, attachment_id",
                "@c", string.IsNullOrEmpty(conversationKey) ? null : conversationKey, "@s", state))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) yield return ReadFileCopy(r);
        }

        /// <summary>A copy already uploaded for this content (same SHA-256): the upload of a file posted in many chats happens once.</summary>
        public FileCopyRecord FindUploadedBySha256(string sha256)
        {
            if (string.IsNullOrEmpty(sha256) || !EnsureImportSchema()) return null;
            using (var c = OpenCatalogRead())
            using (var cmd = Cmd(c, "SELECT " + FileCopyCols + " FROM file_copy_map WHERE sha256=@h AND state IN (1,2) AND item_id IS NOT NULL LIMIT 1", "@h", sha256))
            using (var r = cmd.ExecuteReader()) return r.Read() ? ReadFileCopy(r) : null;
        }

        #endregion
    }
}
