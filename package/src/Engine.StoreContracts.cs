// =============================================================================
//  TeamsTransfer - engine, part 0b: store contracts
// -----------------------------------------------------------------------------
//  The seam between the exporter (Engine.Inventory.cs, Engine.Export.cs) and the local store (Engine.Store*.cs).
//  The exporter only knows IExportStore; the store implementation (partitioned SQLite + jsonl.gz segments +
//  content-addressed blobs, design section 5) is free behind it. Tests of the exporter use their own in-memory
//  implementation; the integration tests run the exporter against the real store.
//
//  Messages are stored as the RAW Graph chatMessage JSON (UTF-8 bytes of the element as received), never re-shaped:
//  the import and the preview read exactly what Graph returned. Keys:
//    ConversationKey  chat:<chatId>  |  channel:<teamId>/<channelId>
//    message identity (ConversationKey, MessageId); a reply of a channel message has its own MessageId and ReplyToId.
//  A message seen again with a later lastModifiedDateTime (edit, deletion, reaction) is a new VERSION: the store keeps
//  the latest as current and counts the versions. Imported messages have lastModifiedDateTime = 0001-01-01 (phase 0):
//  the store must not treat that as "older" than nothing; compare (lastModifiedDateTime, etag, content hash).
//
//  OWNERSHIP: coordinator. Agents do not change this file; a needed change is reported.
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace TeamsTransfer
{
    public enum ConversationKind { OneOnOne, Group, Meeting, Channel }

    public enum UserState { Active, Disabled, Deleted, Guest, External, Unknown }

    public static class ConversationKeys
    {
        public static string ForChat(string chatId) => "chat:" + chatId;
        public static string ForChannel(string teamId, string channelId) => "channel:" + teamId + "/" + channelId;
    }

    public sealed class UserRecord
    {
        public string Id { get; set; }
        public string UserPrincipalName { get; set; }
        public string DisplayName { get; set; }
        public string Mail { get; set; }
        public UserState State { get; set; } = UserState.Unknown;
        /// <summary>Home tenant of a guest/external member, when known.</summary>
        public string TenantId { get; set; }
    }

    public sealed class ConversationRecord
    {
        public string Key { get; set; }
        public ConversationKind Kind { get; set; }
        public string ChatId { get; set; }
        public string TeamId { get; set; }
        public string ChannelId { get; set; }
        /// <summary>standard | private | shared for channels; null for chats.</summary>
        public string MembershipType { get; set; }
        public string Topic { get; set; }
        public string TeamDisplayName { get; set; }
        public DateTimeOffset? CreatedUtc { get; set; }
        public DateTimeOffset? LastActivityUtc { get; set; }
        /// <summary>Raw JSON array of the Graph conversationMember objects (snapshot at export time).</summary>
        public string MembersJson { get; set; }
        public int MemberCount { get; set; }
        /// <summary>True when the conversation contains messages imported by a previous migration (invisible to getAllMessages).</summary>
        public bool? HasImportedContent { get; set; }
    }

    public sealed class MessageWriteResult
    {
        public int New { get; set; }
        public int Updated { get; set; }
        public int Unchanged { get; set; }
    }

    public sealed class ContentRef
    {
        public string Sha256 { get; set; }
        public long Length { get; set; }
        public string ContentType { get; set; }
        public bool AlreadyPresent { get; set; }
    }

    public enum FileStatus { Pending, Downloaded, NotFound, Forbidden, TooLarge, Excluded, Failed }

    public sealed class FileRecord
    {
        public string ConversationKey { get; set; }
        public string MessageId { get; set; }
        /// <summary>attachment.id of the message.</summary>
        public string AttachmentId { get; set; }
        public string Name { get; set; }
        public string SourceUrl { get; set; }
        public string DriveId { get; set; }
        public string ItemId { get; set; }
        public string ETag { get; set; }
        public long? Size { get; set; }
        public FileStatus Status { get; set; }
        public string Error { get; set; }
        /// <summary>Set when Status = Downloaded.</summary>
        public string Sha256 { get; set; }
    }

    /// <summary>What the exporter needs from the store. Thread-safe: the exporter writes from many tasks at once.</summary>
    public interface IExportStore : IDisposable
    {
        // --- catalog -------------------------------------------------------------------------------------------
        void UpsertUsers(IEnumerable<UserRecord> users);
        void UpsertConversations(IEnumerable<ConversationRecord> conversations);
        /// <summary>Records that a user is (or was) a member of a conversation: drives per-user lots and the preview.</summary>
        void LinkUserConversations(string userId, IEnumerable<string> conversationKeys);
        ConversationRecord GetConversation(string conversationKey);

        // --- messages ------------------------------------------------------------------------------------------
        /// <summary>Appends raw Graph chatMessage elements of ONE conversation (any order). Deduplicates; keeps versions.</summary>
        MessageWriteResult AppendMessages(string conversationKey, IReadOnlyList<JsonElement> messages);
        long CountMessages(string conversationKey);

        // --- content (hosted contents, files) -----------------------------------------------------------------
        /// <summary>Streams data into the content-addressed store (SHA-256). Never buffers the whole stream in memory.</summary>
        ContentRef PutContent(Stream data, string contentType);
        bool HasContent(string sha256);
        Stream OpenContent(string sha256);
        void RecordHostedContent(string conversationKey, string messageId, string hostedContentId, ContentRef content);
        void RecordFile(FileRecord file);
        /// <summary>Files still to download (Pending or Failed with retries left), for the Files stage.</summary>
        IEnumerable<FileRecord> PendingFiles(int max);

        // --- checkpoints ---------------------------------------------------------------------------------------
        /// <summary>Opaque value per scope, e.g. "gam:{userId}" -> saved @odata.nextLink, "wm:{userId}" -> watermark.</summary>
        string GetCheckpoint(string scope);
        void SetCheckpoint(string scope, string value);
    }

    /// <summary>What the preview, the planner and the verifier read. Ordered, streamed, never all in memory.</summary>
    public interface IStoreReader
    {
        IEnumerable<ConversationRecord> ListConversations(string userId = null, ConversationKind? kind = null, string teamId = null);
        IEnumerable<UserRecord> ListUsers();
        /// <summary>Current version of each message, ordered by createdDateTime then id; replies follow their root.</summary>
        IEnumerable<JsonElement> ReadMessages(string conversationKey, DateTimeOffset? fromUtc = null, DateTimeOffset? toUtc = null);
        IEnumerable<FileRecord> ListFiles(string conversationKey);
        /// <summary>sha256 of a hosted content, null when not exported.</summary>
        string FindHostedContent(string conversationKey, string messageId, string hostedContentId);
        Stream OpenContent(string sha256);
    }
}
