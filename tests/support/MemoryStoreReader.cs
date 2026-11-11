// =============================================================================
//  TeamsTransfer - tests: an in-memory IStoreReader (lot F, preview)
// -----------------------------------------------------------------------------
//  WHY: the preview exporter reads an IStoreReader; the real store is written elsewhere. Tests and screenshots fill this reader
//  from a FakeTenant (SyntheticTenant.Tiny / Demo / Small) so they depend on nothing but the contract.
//  - MemoryStoreReader      : a FakeTenant seen through IStoreReader. Messages are serialized on the fly as RAW Graph chatMessage JSON
//                             (same shape as FakeGraphTransport), so the preview reads exactly what the store would return.
//  - LargeConversationReader: one generated conversation of N messages (200 000 for the virtualization test), produced lazily.
//  Both are read-only, streaming, thread-safe for concurrent reads.
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TeamsTransfer.Testing
{
    public sealed class MemoryStoreReader : IStoreReader
    {
        readonly FakeTenant _t;
        readonly object _gate = new object();
        readonly Dictionary<string, Func<Stream>> _content = new Dictionary<string, Func<Stream>>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, FakeThread> _threads = new Dictionary<string, FakeThread>(StringComparer.Ordinal);
        readonly List<ConversationRecord> _convs = new List<ConversationRecord>();

        /// <summary>Files larger than this are reported as TooLarge (not exported), like the real Files stage would.</summary>
        public long MaxFileBytes = 64L * 1024 * 1024;
        /// <summary>When false, hosted contents are reported as not exported (tests the placeholder).</summary>
        public bool ExportHostedContents = true;

        public MemoryStoreReader(FakeTenant tenant)
        {
            _t = tenant;
            foreach (var c in tenant.Chats)
            {
                string key = ConversationKeys.ForChat(c.Id);
                _threads[key] = c;
                _convs.Add(new ConversationRecord
                {
                    Key = key, Kind = c.ChatType == FakeChatType.OneOnOne ? ConversationKind.OneOnOne : c.ChatType == FakeChatType.Group ? ConversationKind.Group : ConversationKind.Meeting,
                    ChatId = c.Id, Topic = c.Topic, CreatedUtc = FakeTime.FromMs(c.CreatedMs),
                    LastActivityUtc = c.Messages.Count > 0 ? FakeTime.FromMs(c.Messages.Max(m => m.CreatedMs)) : FakeTime.FromMs(c.CreatedMs),
                    MembersJson = MembersJson(c.Ordinal, c.Members), MemberCount = c.Members.Count
                });
            }
            foreach (var team in tenant.Teams)
                foreach (var ch in team.Channels)
                {
                    string key = ConversationKeys.ForChannel(team.Id, ch.Id);
                    _threads[key] = ch;
                    var mem = ch.Members.Count > 0 ? ch.Members : team.Members;
                    _convs.Add(new ConversationRecord
                    {
                        Key = key, Kind = ConversationKind.Channel, TeamId = team.Id, ChannelId = ch.Id, MembershipType = ch.TypeName, Topic = ch.DisplayName, TeamDisplayName = team.DisplayName,
                        CreatedUtc = FakeTime.FromMs(ch.CreatedMs),
                        LastActivityUtc = ch.Messages.Count > 0 ? FakeTime.FromMs(ch.Messages.Max(m => m.CreatedMs)) : FakeTime.FromMs(ch.CreatedMs),
                        MembersJson = MembersJson(ch.Ordinal, mem), MemberCount = mem.Count
                    });
                }
        }

        string MembersJson(int threadOrd, List<FakeMember> members)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartArray();
                    foreach (var m in members)
                    {
                        var u = _t.Users[m.UserOrd];
                        w.WriteStartObject();
                        w.WriteString("@odata.type", "#microsoft.graph.aadUserConversationMember");
                        w.WriteString("id", FakeTenant.MembershipId(threadOrd, m.UserOrd));
                        w.WriteStartArray("roles"); if (!string.IsNullOrEmpty(m.Roles)) foreach (var r in m.Roles.Split(',')) w.WriteStringValue(r); w.WriteEndArray();
                        w.WriteString("displayName", u.DisplayName);
                        w.WriteString("userId", u.Id); w.WriteString("email", u.Mail ?? u.Upn); w.WriteString("tenantId", u.TenantId);
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        static UserState StateOf(FakeUser u)
        {
            return u.Deleted ? UserState.Deleted : u.External ? UserState.External : string.Equals(u.UserType, "Guest", StringComparison.OrdinalIgnoreCase) ? UserState.Guest : UserState.Active;
        }

        public IEnumerable<UserRecord> ListUsers()
        {
            foreach (var u in _t.Users)
                yield return new UserRecord { Id = u.Id, UserPrincipalName = u.Upn, DisplayName = u.DisplayName, Mail = u.Mail, State = StateOf(u), TenantId = u.TenantId };
        }

        public IEnumerable<ConversationRecord> ListConversations(string userId = null, ConversationKind? kind = null, string teamId = null)
        {
            foreach (var c in _convs)
            {
                if (kind.HasValue && c.Kind != kind.Value) continue;
                if (!string.IsNullOrEmpty(teamId) && !string.Equals(c.TeamId, teamId, StringComparison.OrdinalIgnoreCase)) continue;
                if (!string.IsNullOrEmpty(userId))
                {
                    bool member = false;
                    using (var d = JsonDocument.Parse(c.MembersJson))
                        foreach (var m in d.RootElement.EnumerateArray())
                            if (m.TryGetProperty("userId", out var id) && string.Equals(id.GetString(), userId, StringComparison.OrdinalIgnoreCase)) { member = true; break; }
                    if (!member) continue;
                }
                yield return c;
            }
        }

        public IEnumerable<JsonElement> ReadMessages(string conversationKey, DateTimeOffset? fromUtc = null, DateTimeOffset? toUtc = null)
        {
            FakeThread th;
            if (!_threads.TryGetValue(conversationKey, out th)) yield break;
            long from = fromUtc.HasValue ? FakeTime.ToMs(fromUtc.Value) : long.MinValue, to = toUtc.HasValue ? FakeTime.ToMs(toUtc.Value) : long.MaxValue;
            var all = th.Messages.OrderBy(m => m.CreatedMs).ThenBy(m => m.Id).ToList();
            IEnumerable<FakeMessage> ordered;
            if (th.IsChannel)
            {
                var byRoot = all.Where(m => m.ReplyTo != 0).GroupBy(m => m.ReplyTo).ToDictionary(g => g.Key, g => g.ToList());
                var rootIds = new HashSet<long>(all.Where(m => m.ReplyTo == 0).Select(m => m.Id));
                var seq = new List<FakeMessage>();
                foreach (var m in all)
                {
                    if (m.ReplyTo != 0 && rootIds.Contains(m.ReplyTo)) continue;   // emitted after its root
                    seq.Add(m);
                    List<FakeMessage> reps;
                    if (byRoot.TryGetValue(m.Id, out reps)) seq.AddRange(reps);
                }
                ordered = seq;
            }
            else ordered = all;
            foreach (var m in ordered)
            {
                if (m.ReplyTo == 0 && (m.CreatedMs < from || m.CreatedMs >= to)) continue;
                byte[] bytes;
                using (var ms = new MemoryStream())
                {
                    using (var w = new Utf8JsonWriter(ms)) WriteMessage(w, th, m);
                    bytes = ms.ToArray();
                }
                using (var doc = JsonDocument.Parse(bytes)) yield return doc.RootElement.Clone();
            }
        }

        public IEnumerable<FileRecord> ListFiles(string conversationKey)
        {
            FakeThread th;
            if (!_threads.TryGetValue(conversationKey, out th)) yield break;
            foreach (var m in th.Messages)
            {
                if (m.X == null || m.X.Attachments == null || m.IsDeleted) continue;
                foreach (var a in m.X.Attachments)
                {
                    if (a.ContentType != FakeAttachment.Reference) continue;
                    FakeDriveItem item = null;
                    if (a.ContentUrl != null) _t.ItemsByUrl.TryGetValue(FakeTenant.NormUrl(a.ContentUrl), out item);
                    var rec = new FileRecord { ConversationKey = conversationKey, MessageId = m.Id.ToString(), AttachmentId = a.Id, Name = a.Name, SourceUrl = a.ContentUrl };
                    if (item == null || item.Deleted) { rec.Status = FileStatus.NotFound; }
                    else if (item.AccessDenied) { rec.Status = FileStatus.Forbidden; rec.Size = item.Size; }
                    else if (item.Size > MaxFileBytes) { rec.Status = FileStatus.TooLarge; rec.Size = item.Size; }
                    else
                    {
                        rec.Size = item.Size; rec.Status = FileStatus.Downloaded; rec.Sha256 = item.Sha256Hex();
                        var it = item; lock (_gate) _content[rec.Sha256] = () => it.OpenRead();
                    }
                    yield return rec;
                }
            }
        }

        public string FindHostedContent(string conversationKey, string messageId, string hostedContentId)
        {
            if (!ExportHostedContents) return null;
            FakeThread th; long id;
            if (!_threads.TryGetValue(conversationKey, out th) || !long.TryParse(messageId, out id)) return null;
            var m = th.Find(id);
            if (m == null || m.X == null || m.X.Hosted == null) return null;
            foreach (var h in m.X.Hosted)
                if (h.Id == hostedContentId)
                {
                    string sha = Convert.ToHexString(SHA256.HashData(h.Bytes)).ToLowerInvariant();
                    var bytes = h.Bytes; lock (_gate) _content[sha] = () => new MemoryStream(bytes, false);
                    return sha;
                }
            return null;
        }

        public Stream OpenContent(string sha256)
        {
            Func<Stream> f; lock (_gate) _content.TryGetValue(sha256 ?? "", out f);
            if (f == null) throw new FileNotFoundException("Content not found: " + sha256);
            return f();
        }

        // ---------------------------------------------------------------- raw Graph chatMessage JSON (mirrors FakeGraphTransport.WriteMessage)
        FakeUser U(int ord) { return ord >= 0 && ord < _t.Users.Count ? _t.Users[ord] : null; }

        static void WriteIdentity(Utf8JsonWriter w, string prop, FakeUser u)
        {
            w.WriteStartObject(prop);
            w.WriteString("@odata.type", "#microsoft.graph.teamworkUserIdentity");
            w.WriteString("id", u.Id); w.WriteString("displayName", u.DisplayName);
            w.WriteString("userIdentityType", "aadUser"); w.WriteString("tenantId", u.TenantId);
            w.WriteEndObject();
        }

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
            var chat = th as FakeChat;
            if (chat != null) w.WriteString("chatId", chat.Id);
            else
            {
                var chn = (FakeChannel)th;
                w.WriteStartObject("channelIdentity"); w.WriteString("teamId", chn.Team.Id); w.WriteString("channelId", chn.Id); w.WriteEndObject();
            }
            w.WriteString("importance", x != null && x.Importance != null ? x.Importance : "normal");
            if (sys && x != null && x.EventDetailJson != null) { w.WritePropertyName("eventDetail"); w.WriteRawValue(x.EventDetailJson); } else w.WriteNull("eventDetail");
            var au = U(m.AuthorOrd);
            if (au == null && !(x != null && x.FromApplication != null)) w.WriteNull("from");
            else
            {
                w.WriteStartObject("from");
                if (x != null && x.FromApplication != null)
                {
                    var ap = x.FromApplication.Split('|');
                    w.WriteStartObject("application"); w.WriteString("id", ap[0]); w.WriteString("displayName", ap.Length > 1 ? ap[1] : ap[0]); w.WriteString("applicationIdentityType", "bot"); w.WriteEndObject();
                    w.WriteNull("device"); w.WriteNull("user");
                }
                else { w.WriteNull("application"); w.WriteNull("device"); WriteIdentity(w, "user", au); }
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
    }

    /// <summary>One group chat of N messages over ~18 months, generated lazily: the virtualization test (200 000 messages) without a tenant in memory.</summary>
    public sealed class LargeConversationReader : IStoreReader
    {
        public const string Key = "chat:19:large@thread.v2";
        readonly int _n; readonly long _startMs; readonly long _endMs;
        readonly string[] _ids = { "00000000-0000-0000-0000-0000000000a1", "00000000-0000-0000-0000-0000000000a2", "00000000-0000-0000-0000-0000000000a3", "00000000-0000-0000-0000-0000000000a4" };
        readonly string[] _names = { "Alice Durand", "Bruno Lambert", "Chloé Girard", "David Roux" };

        public LargeConversationReader(int messages)
        {
            _n = messages;
            _startMs = FakeTime.ToMs(new DateTimeOffset(2025, 5, 1, 8, 0, 0, TimeSpan.Zero));
            _endMs = FakeTime.ToMs(new DateTimeOffset(2026, 11, 2, 17, 0, 0, TimeSpan.Zero));
        }

        public IEnumerable<UserRecord> ListUsers()
        {
            for (int i = 0; i < _ids.Length; i++)
                yield return new UserRecord { Id = _ids[i], DisplayName = _names[i], UserPrincipalName = "user" + i + "@contoso.com", State = UserState.Active };
        }

        public IEnumerable<ConversationRecord> ListConversations(string userId = null, ConversationKind? kind = null, string teamId = null)
        {
            if (kind.HasValue && kind.Value != ConversationKind.Group) yield break;
            if (teamId != null) yield break;
            var members = "[" + string.Join(",", _ids.Select((id, i) => "{\"userId\":\"" + id + "\",\"displayName\":\"" + _names[i] + "\"}")) + "]";
            yield return new ConversationRecord { Key = Key, Kind = ConversationKind.Group, ChatId = "19:large@thread.v2", Topic = "Gros volume", MembersJson = members, MemberCount = _ids.Length,
                CreatedUtc = FakeTime.FromMs(_startMs), LastActivityUtc = FakeTime.FromMs(_endMs) };
        }

        public IEnumerable<JsonElement> ReadMessages(string conversationKey, DateTimeOffset? fromUtc = null, DateTimeOffset? toUtc = null)
        {
            if (conversationKey != Key) yield break;
            var rng = new FakeRng(99);
            long span = _endMs - _startMs;
            for (int i = 0; i < _n; i++)
            {
                long t = _startMs + (long)((double)i / _n * span);
                var d = FakeTime.FromMs(t);
                if (fromUtc.HasValue && d < fromUtc.Value) continue;
                if (toUtc.HasValue && d >= toUtc.Value) continue;
                int a = (i * 7 + i / 5) % _ids.Length;
                string body = (i % 50 == 0) ? "<p>Point <b>" + i + "</b> : <a href=\"https://fabrikam.com/p/" + i + "\">lien</a></p><p>" + FakeText.Plain(i, "fr") + "</p>" : FakeText.Render(i, "fr");
                string json = "{\"id\":\"" + t + "\",\"replyToId\":null,\"messageType\":\"message\",\"createdDateTime\":\"" + FakeTime.Format(t) + "\",\"lastModifiedDateTime\":\"" + FakeTime.Format(t) + "\",\"lastEditedDateTime\":null,\"deletedDateTime\":null,\"subject\":null,\"importance\":\"normal\",\"eventDetail\":null," +
                    "\"from\":{\"application\":null,\"device\":null,\"user\":{\"id\":\"" + _ids[a] + "\",\"displayName\":\"" + _names[a] + "\",\"userIdentityType\":\"aadUser\"}}," +
                    "\"body\":{\"contentType\":\"html\",\"content\":" + JsonSerializer.Serialize(body) + "},\"attachments\":[],\"mentions\":[],\"reactions\":" + (i % 11 == 0 ? "[{\"reactionType\":\"like\",\"createdDateTime\":\"" + FakeTime.Format(t + 1000) + "\",\"user\":{\"user\":{\"id\":\"" + _ids[(a + 1) % 4] + "\",\"displayName\":\"" + _names[(a + 1) % 4] + "\"}}}]" : "[]") + "}";
                using (var doc = JsonDocument.Parse(json)) yield return doc.RootElement.Clone();
            }
        }

        public IEnumerable<FileRecord> ListFiles(string conversationKey) { return new FileRecord[0]; }
        public string FindHostedContent(string conversationKey, string messageId, string hostedContentId) { return null; }
        public Stream OpenContent(string sha256) { throw new FileNotFoundException(sha256); }
    }
}
