// =============================================================================
//  TeamsTransfer - engine, part 0c: import contracts
// -----------------------------------------------------------------------------
//  The seam between the three import lots:
//    H  Mapping + Plan    (Engine.Mapping.cs, Engine.Plan.cs)   fills IIdentityMap and ITargetMap, resolves lots,
//                                                               writes the dry-run plan (ImportPlan).
//    J  Ghosts + Files + Verify (Engine.Ghosts.cs, Engine.FileCopy.cs, Engine.Verify.cs)
//                                                               creates ghost accounts (fills IIdentityMap with
//                                                               Kind=Ghost), copies files (fills IFileCopyMap),
//                                                               verifies source vs target counts.
//    I  Importer          (Engine.Import.cs)                    reads the plan, the three maps, the store and the
//                                                               journal; creates/finds target conversations;
//                                                               startMigration / import / completeMigration.
//  Persistence of the three maps lives in catalog.db (lot H implements it in Engine.CatalogImport.cs as a partial of
//  TmtStore); every lot programs against the interfaces below and tests with in-memory implementations.
//
//  Stage order of a lot (design 3.7): Plan -> Ghosts -> Files -> Import -> Verify. Every write stage is a dry run
//  unless ImportRunOptions.Apply is true (the entry script maps -Apply / -WhatIf onto it).
//
//  Phase 0 facts the implementations MUST honour (docs\design\Phase0-Results.md):
//    - a deleted user cannot be an author (400 "could not be found in the tenant"): Ghost or ServiceAccount;
//      a disabled user or a guest can.
//    - 5 requests/s per conversation; ~60-90 msg/s per app per tenant; parallelism across conversations.
//    - duplicate createdDateTime in a thread -> 409 Conflict = already imported (idempotency).
//    - migrationMode is eventually consistent: poll until inProgress before importing; retry completeMigration.
//    - startMigration moves createdDateTime earlier for good; a later wave needs an even earlier date.
//    - POST /teams accepts one member at creation.
//    - imported messages have lastModifiedDateTime 0001-01-01 and are invisible to getAllMessages: verify per chat.
//
//  OWNERSHIP: coordinator. Agents do not change this file; a needed change is reported.
// =============================================================================
using System;
using System.Collections.Generic;

namespace TeamsTransfer
{
    /// <summary>Design 3.5: A tenant-to-tenant, B restore in the same tenant, C archive of departed users.</summary>
    public enum ImportScenario { TenantToTenant, SameTenantRestore, DepartedArchive }

    // --- identities ----------------------------------------------------------------------------------------------

    public enum IdentityKind
    {
        /// <summary>Source user mapped to a different target user (CSV or domain rule).</summary>
        Mapped,
        /// <summary>Same object in the target (scenario B, user still exists).</summary>
        Same,
        /// <summary>Source user deleted/absent: a disabled, unlicensed ghost account in the target (design 3.6).</summary>
        Ghost,
        /// <summary>Fallback author: the service account, the message body gets the "Original message from ..." prefix.</summary>
        ServiceAccount,
        /// <summary>No decision yet: blocks the plan.</summary>
        Unresolved
    }

    public sealed class IdentityMapping
    {
        public string SourceUserId { get; set; }
        public string SourceDisplayName { get; set; }
        public string SourceUserPrincipalName { get; set; }
        public IdentityKind Kind { get; set; } = IdentityKind.Unresolved;
        /// <summary>Target object id (Mapped, Same, Ghost, ServiceAccount). Null while a ghost is only planned.</summary>
        public string TargetUserId { get; set; }
        public string TargetDisplayName { get; set; }
        /// <summary>How it was decided: csv, domain-rule, same-id, upn-match, ghost, service-account, manual.</summary>
        public string Rule { get; set; }
        public string Note { get; set; }
    }

    public interface IIdentityMap
    {
        IdentityMapping Get(string sourceUserId);
        void Upsert(IdentityMapping mapping);
        IEnumerable<IdentityMapping> List(IdentityKind? kind = null);
    }

    // --- target conversations -----------------------------------------------------------------------------------

    public enum TargetKind
    {
        /// <summary>Import into an existing chat (scenario B, or a 1:1 that POST /chats returns as existing).</summary>
        ExistingChat,
        /// <summary>Create a chat (POST /chats) with the mapped members, then import.</summary>
        NewChat,
        ExistingChannel,
        /// <summary>Create a channel (and the team when TargetTeamId is null and CreateTeamName is set).</summary>
        NewChannel,
        /// <summary>Scenario C: one channel per departed user in an archive team (auto-sharded teams).</summary>
        ArchiveChannel,
        /// <summary>Not imported (out of window, excluded, federated-only...). Reason in Note.</summary>
        Skip
    }

    public enum TargetState { Planned, Created, Failed }

    public sealed class TargetMapping
    {
        public string SourceConversationKey { get; set; }
        public TargetKind Kind { get; set; }
        public string TargetChatId { get; set; }
        public string TargetTeamId { get; set; }
        public string TargetChannelId { get; set; }
        /// <summary>For NewChat/NewChannel/ArchiveChannel: topic or channel name, membership type, team name.</summary>
        public string CreateTopic { get; set; }
        public string CreateMembershipType { get; set; }
        public string CreateTeamName { get; set; }
        /// <summary>Target member ids (after identity mapping) for a new chat/channel.</summary>
        public List<string> TargetMemberIds { get; set; } = new List<string>();
        public TargetState State { get; set; } = TargetState.Planned;
        public string Note { get; set; }
    }

    public interface ITargetMap
    {
        TargetMapping Get(string sourceConversationKey);
        void Upsert(TargetMapping mapping);
        IEnumerable<TargetMapping> List(TargetKind? kind = null);
    }

    // --- files --------------------------------------------------------------------------------------------------

    public enum FileCopyState { Pending, Uploaded, Shared, Failed, Skipped }

    public sealed class FileCopyRecord
    {
        /// <summary>Identity of the source attachment (FileRecord in the store).</summary>
        public string ConversationKey { get; set; }
        public string MessageId { get; set; }
        public string AttachmentId { get; set; }
        public string Sha256 { get; set; }
        public string Name { get; set; }
        /// <summary>Where it was uploaded in the target (sender's OneDrive "Microsoft Teams Chat Files", channel folder...).</summary>
        public string TargetDriveId { get; set; }
        public string TargetItemId { get; set; }
        /// <summary>URL to put in the imported attachment (contentUrl of a reference attachment).</summary>
        public string TargetWebUrl { get; set; }
        public FileCopyState State { get; set; } = FileCopyState.Pending;
        public string Error { get; set; }
    }

    public interface IFileCopyMap
    {
        FileCopyRecord Get(string conversationKey, string messageId, string attachmentId);
        void Upsert(FileCopyRecord record);
        IEnumerable<FileCopyRecord> List(string conversationKey = null, FileCopyState? state = null);
    }

    // --- run options and plan -----------------------------------------------------------------------------------

    public sealed class ImportRunOptions
    {
        /// <summary>False = dry run: nothing is written to the target tenant (the default; -Apply sets it).</summary>
        public bool Apply { get; set; }
        public ImportScenario Scenario { get; set; } = ImportScenario.TenantToTenant;
        /// <summary>Object id of the service account used as fallback author and as owner of created teams/chats.</summary>
        public string ServiceAccountUserId { get; set; }
        /// <summary>Prefix of a message whose author falls back to the service account. {0}=display name, {1}=UPN,
        /// {2}=original UTC date-time "yyyy-MM-dd HH:mm".</summary>
        public string FallbackBannerFormat { get; set; } = "<p><em>Original message from {0} ({1}), {2} UTC</em></p>";
        /// <summary>Ghost display name format; {0}=source display name.</summary>
        public string GhostDisplayNameFormat { get; set; } = "{0} (former)";
        /// <summary>Ghost UPN domain in the target tenant (verified domain or onmicrosoft.com).</summary>
        public string GhostDomain { get; set; }
        /// <summary>Above this many ghosts the plan is blocked unless ConfirmGhostCount is set (design 3.6).</summary>
        public int GhostConfirmThreshold { get; set; } = 5000;
        public bool ConfirmGhostCount { get; set; }
        public int ConversationParallelism { get; set; } = 32;
        /// <summary>Requests per second per conversation (Teams import limit).</summary>
        public double PerConversationRate { get; set; } = 5;
        /// <summary>Scenario B: skip a message whose fingerprint (createdDateTime, author, body hash) already exists in the target.</summary>
        public bool SkipExistingByFingerprint { get; set; } = true;
        public StopControl Stop { get; set; }
    }

    public sealed class ImportPlan
    {
        public long LotId { get; set; }
        public string LotName { get; set; }
        public int[] Slices { get; set; }
        public ImportScenario Scenario { get; set; }
        public DateTimeOffset CreatedUtc { get; set; }
        public int Conversations { get; set; }
        public long Messages { get; set; }
        public long MessagesSkipped { get; set; }
        public int NewChats { get; set; }
        public int ExistingChats { get; set; }
        public int NewChannels { get; set; }
        public int ExistingChannels { get; set; }
        public int ArchiveChannels { get; set; }
        public int GhostsToCreate { get; set; }
        public int ServiceAccountAuthors { get; set; }
        public int UnresolvedIdentities { get; set; }
        public int FilesToCopy { get; set; }
        public long FileBytesToCopy { get; set; }
        /// <summary>Estimated import duration from the measured rates (5 msg/s per conversation, app ceiling).</summary>
        public TimeSpan EstimatedDuration { get; set; }
        /// <summary>Blocking problems: the import refuses to start while this list is not empty.</summary>
        public List<string> Blockers { get; set; } = new List<string>();
        public List<string> Warnings { get; set; } = new List<string>();
        public bool IsBlocked => Blockers.Count > 0;
    }
}
