// Test helpers of lot J (ghosts, file copy, verify): thread-safe in-memory implementations of the three import maps. Used when a test does not
// need the persistence of the real store (TmtStore implements the same interfaces in Engine.CatalogImport.cs). Names are prefixed Gf to stay clear
// of the helpers of the other lots.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace TeamsTransfer.Testing
{
    public sealed class GfIdentityMap : IIdentityMap
    {
        private readonly ConcurrentDictionary<string, IdentityMapping> _m = new ConcurrentDictionary<string, IdentityMapping>(StringComparer.OrdinalIgnoreCase);
        public long Upserts;

        public IdentityMapping Get(string sourceUserId)
        {
            IdentityMapping m;
            return sourceUserId != null && _m.TryGetValue(sourceUserId, out m) ? Clone(m) : null;
        }

        public void Upsert(IdentityMapping mapping)
        {
            System.Threading.Interlocked.Increment(ref Upserts);
            _m[mapping.SourceUserId] = Clone(mapping);
        }

        public IEnumerable<IdentityMapping> List(IdentityKind? kind = null)
        {
            return _m.Values.Where(x => !kind.HasValue || x.Kind == kind.Value).OrderBy(x => x.SourceUserId, StringComparer.Ordinal).Select(Clone).ToList();
        }

        public IdentityMapping Add(string id, string name, IdentityKind kind, string targetId = null)
        {
            var m = new IdentityMapping { SourceUserId = id, SourceDisplayName = name, SourceUserPrincipalName = id + "@source.invalid", Kind = kind, TargetUserId = targetId, Rule = kind.ToString() };
            Upsert(m);
            return m;
        }

        static IdentityMapping Clone(IdentityMapping m)
        {
            return new IdentityMapping { SourceUserId = m.SourceUserId, SourceDisplayName = m.SourceDisplayName, SourceUserPrincipalName = m.SourceUserPrincipalName, Kind = m.Kind, TargetUserId = m.TargetUserId, TargetDisplayName = m.TargetDisplayName, Rule = m.Rule, Note = m.Note };
        }
    }

    public sealed class GfTargetMap : ITargetMap
    {
        private readonly ConcurrentDictionary<string, TargetMapping> _m = new ConcurrentDictionary<string, TargetMapping>(StringComparer.Ordinal);

        public TargetMapping Get(string sourceConversationKey)
        {
            TargetMapping m;
            return sourceConversationKey != null && _m.TryGetValue(sourceConversationKey, out m) ? m : null;
        }

        public void Upsert(TargetMapping mapping) { _m[mapping.SourceConversationKey] = mapping; }

        public IEnumerable<TargetMapping> List(TargetKind? kind = null)
        {
            return _m.Values.Where(x => !kind.HasValue || x.Kind == kind.Value).OrderBy(x => x.SourceConversationKey, StringComparer.Ordinal).ToList();
        }
    }

    public sealed class GfFileCopyMap : IFileCopyMap
    {
        private readonly ConcurrentDictionary<string, FileCopyRecord> _m = new ConcurrentDictionary<string, FileCopyRecord>(StringComparer.Ordinal);
        static string K(string c, string m, string a) { return c + "|" + m + "|" + a; }

        public FileCopyRecord Get(string conversationKey, string messageId, string attachmentId)
        {
            FileCopyRecord r;
            return _m.TryGetValue(K(conversationKey, messageId, attachmentId ?? ""), out r) ? Clone(r) : null;
        }

        public void Upsert(FileCopyRecord record) { _m[K(record.ConversationKey, record.MessageId, record.AttachmentId ?? "")] = Clone(record); }

        public IEnumerable<FileCopyRecord> List(string conversationKey = null, FileCopyState? state = null)
        {
            return _m.Values.Where(x => (conversationKey == null || x.ConversationKey == conversationKey) && (!state.HasValue || x.State == state.Value)).OrderBy(x => K(x.ConversationKey, x.MessageId, x.AttachmentId), StringComparer.Ordinal).Select(Clone).ToList();
        }

        static FileCopyRecord Clone(FileCopyRecord r)
        {
            return new FileCopyRecord { ConversationKey = r.ConversationKey, MessageId = r.MessageId, AttachmentId = r.AttachmentId, Sha256 = r.Sha256, Name = r.Name, TargetDriveId = r.TargetDriveId, TargetItemId = r.TargetItemId, TargetWebUrl = r.TargetWebUrl, State = r.State, Error = r.Error };
        }
    }
}
