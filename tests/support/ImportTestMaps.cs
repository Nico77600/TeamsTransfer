// =============================================================================
//  TeamsTransfer tests - in-memory implementations of the three import maps (lot I)
//  IIdentityMap, ITargetMap and IFileCopyMap over concurrent dictionaries. Every Get returns a COPY and every Upsert stores a copy,
//  like a database would: a test can never rely on sharing an instance with the importer.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace TeamsTransfer.Testing
{
    public sealed class MemoryIdentityMap : IIdentityMap
    {
        private readonly ConcurrentDictionary<string, IdentityMapping> _d = new ConcurrentDictionary<string, IdentityMapping>(StringComparer.Ordinal);
        public long Reads;

        private static IdentityMapping Copy(IdentityMapping m)
        {
            return new IdentityMapping { SourceUserId = m.SourceUserId, SourceDisplayName = m.SourceDisplayName, SourceUserPrincipalName = m.SourceUserPrincipalName, Kind = m.Kind, TargetUserId = m.TargetUserId, TargetDisplayName = m.TargetDisplayName, Rule = m.Rule, Note = m.Note };
        }

        public IdentityMapping Get(string sourceUserId)
        {
            System.Threading.Interlocked.Increment(ref Reads);
            IdentityMapping m;
            return sourceUserId != null && _d.TryGetValue(sourceUserId, out m) ? Copy(m) : null;
        }
        public void Upsert(IdentityMapping mapping) { _d[mapping.SourceUserId] = Copy(mapping); }
        public IEnumerable<IdentityMapping> List(IdentityKind? kind = null) { return _d.Values.Where(x => !kind.HasValue || x.Kind == kind.Value).Select(Copy).ToList(); }

        /// <summary>Convenience for tests: Mapped / Same / Ghost / ServiceAccount.</summary>
        public void Set(string sourceId, IdentityKind kind, string targetId, string sourceName = null, string upn = null, string targetName = null)
        {
            Upsert(new IdentityMapping { SourceUserId = sourceId, Kind = kind, TargetUserId = targetId, SourceDisplayName = sourceName, SourceUserPrincipalName = upn, TargetDisplayName = targetName });
        }
    }

    public sealed class MemoryTargetMap : ITargetMap
    {
        private readonly ConcurrentDictionary<string, TargetMapping> _d = new ConcurrentDictionary<string, TargetMapping>(StringComparer.Ordinal);
        public long Upserts;

        private static TargetMapping Copy(TargetMapping m)
        {
            return new TargetMapping
            {
                SourceConversationKey = m.SourceConversationKey, Kind = m.Kind, TargetChatId = m.TargetChatId, TargetTeamId = m.TargetTeamId, TargetChannelId = m.TargetChannelId,
                CreateTopic = m.CreateTopic, CreateMembershipType = m.CreateMembershipType, CreateTeamName = m.CreateTeamName,
                TargetMemberIds = new List<string>(m.TargetMemberIds ?? new List<string>()), State = m.State, Note = m.Note
            };
        }

        public TargetMapping Get(string sourceConversationKey)
        {
            TargetMapping m;
            return sourceConversationKey != null && _d.TryGetValue(sourceConversationKey, out m) ? Copy(m) : null;
        }
        public void Upsert(TargetMapping mapping) { System.Threading.Interlocked.Increment(ref Upserts); _d[mapping.SourceConversationKey] = Copy(mapping); }
        public IEnumerable<TargetMapping> List(TargetKind? kind = null) { return _d.Values.Where(x => !kind.HasValue || x.Kind == kind.Value).Select(Copy).ToList(); }
    }

    public sealed class MemoryFileCopyMap : IFileCopyMap
    {
        private readonly ConcurrentDictionary<string, FileCopyRecord> _d = new ConcurrentDictionary<string, FileCopyRecord>(StringComparer.Ordinal);
        private static string K(string c, string m, string a) { return c + "|" + m + "|" + a; }
        private static FileCopyRecord Copy(FileCopyRecord r)
        {
            return new FileCopyRecord { ConversationKey = r.ConversationKey, MessageId = r.MessageId, AttachmentId = r.AttachmentId, Sha256 = r.Sha256, Name = r.Name, TargetDriveId = r.TargetDriveId, TargetItemId = r.TargetItemId, TargetWebUrl = r.TargetWebUrl, State = r.State, Error = r.Error };
        }
        public FileCopyRecord Get(string conversationKey, string messageId, string attachmentId)
        {
            FileCopyRecord r;
            return _d.TryGetValue(K(conversationKey, messageId, attachmentId), out r) ? Copy(r) : null;
        }
        public void Upsert(FileCopyRecord record) { _d[K(record.ConversationKey, record.MessageId, record.AttachmentId)] = Copy(record); }
        public IEnumerable<FileCopyRecord> List(string conversationKey = null, FileCopyState? state = null)
        {
            return _d.Values.Where(x => (conversationKey == null || x.ConversationKey == conversationKey) && (!state.HasValue || x.State == state.Value)).Select(Copy).ToList();
        }
    }
}
