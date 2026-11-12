#Requires -Version 7.4

<#
.SYNOPSIS
    Teams Transfer - exports Microsoft Teams chats and channels (messages, reactions, files) from a tenant into a local store, previews
    them offline as a Teams-like HTML archive, and (later) imports them into a tenant with the Microsoft Graph Teams migration API.

.DESCRIPTION
    This is the owner's own tooling to migrate or archive Teams content the operator is authorised to access (application permissions
    granted by the tenant administrator, certificate sign-in). Throttling is obeyed, not worked around: Retry-After is honoured exactly
    and the request rate is lowered when the service answers 429 / 503.

    Mode Assess    Samples some users (and teams), measures, and extrapolates volume, duration and waves to the whole tenant. Read only.
                   Writes a report folder, no store.
    Mode Inventory Lists users (including deleted and guests), chats, teams, channels and members into the store. Resumable. Read only
                   on the tenant, writes the store.
    Mode Export    Exports the messages of the chats (and, with -IncludeChannels, of the channels) to the store. Incremental: a second run
                   reads only what changed. -IncludeFiles also downloads the files that the messages refer to.
    Mode Files     Downloads the file references recorded as Pending by an export.
    Mode Archive   Writes an offline, Teams-like HTML archive of the store (folder or single file). English page, no network.
    Mode Status    The state of the store: counts (conversations inventoried and conversations with messages), inventory pass, pending files, and
                   every lot with its state, its items per state and its import journal summary. Without a store: version, configuration, engine.
                   This is the default mode. It writes nothing, except with -CancelLot (a write to the local store only, after a confirmation).
    Mode Plan      The dry-run import plan of a lot (-Lot, or -Users / -Teams for a lot created on the fly), slice by slice (-Slices): the
                   conversations and messages that would be imported, where each conversation goes (new or existing chat / channel, archive
                   channel), how every author is mapped (CSV, domain rule, same user, ghost, service account), the ghosts to create, the
                   files to copy, the blockers and warnings, and the estimated duration. Read only on the target tenant; writes the plan folder
                   (plan.html, plan.json, CSV files) and, locally, the identity / target maps and the import journal. Exit code 3: the plan
                   has blockers (it cannot be imported until they are fixed).
    Mode Import    Imports the messages of a planned lot (-Lot, state ImportPlanned) into the TARGET tenant with the Teams migration API
                   (startMigration, import, completeMigration). Preview by default: it counts the exact requests per endpoint, keeps the first
                   payloads (redacted), estimates the duration and sends nothing; -Apply performs the import, after one confirmation (none with
                   -Force). Resumable and idempotent (journal + the 409 of the service), 5 requests per second per conversation, conversations in
                   parallel (-ConversationParallelism). Report folder: summary.html, conversations.csv, rejected.csv. Exit code 3: messages were
                   rejected or a conversation is uncertain; 2: stopped or incomplete (run the same command again).
    Mode Ghosts    Creates the ghost accounts of the deleted authors in the TARGET tenant: one disabled, unlicensed account per person
                   ("First Last (former)", UPN tt-ghost-<hash>@<-GhostDomain>, employeeType TeamsTransferGhost, member of the group
                   "TeamsTransfer - Ghost accounts", random password that is never stored). Preview by default: it reads the target, lists
                   exactly what would be created and writes nothing; -Apply creates them, after one confirmation (none with -Force). Idempotent:
                   a second run creates nothing. Above -GhostThreshold (5,000) it refuses unless -ConfirmGhostCount. If the target refuses the
                   creation (403) the identity falls back to the service account. Ghosts found enabled are reported (exit code 3).
                   -Remove deletes the ghosts of the catalog (lab cleanup; each one is re-checked in the tenant). With -Lot -Apply the lot moves
                   to Ghosts.
    Mode CopyFiles Copies the exported files into the TARGET tenant before the import: chat files into the OneDrive of the sender (or of the
                   service account for a ghost), channel files into the channel folder, large files in resumable upload sessions, the same
                   content uploaded once per folder, chat files shared read-only with the chat members. Preview by default (no request at all:
                   files and bytes per destination); -Apply copies, after one confirmation (none with -Force). Failures are recorded per file and
                   never stop the run; run the same command again to retry. With -Lot -Apply the lot moves to Files.
    Mode Verify    Verifies an imported lot (-Lot) on the TARGET tenant (read only): per conversation and slice, the journal, the source counts
                   and a sample of messages (author, date, body), reactions and file attachments, and migrationMode. Outcome per conversation:
                   OK, Mismatch, Missing, NotCompleted, Unverified (target not readable: a permission is missing). When everything is OK the lot is set Verified. Writes verify.html, verify.csv and
                   verify-summary.txt. Exit code 0: all OK; 3: mismatches or missing conversations; 2: not completed yet.
    Mode Report    Rebuilds the HTML reports of a lot (-Lot, or every lot) from the catalog: lot state and history, items per slice and state,
                   journal totals, ghosts, file copies and the last verification. Read only, no network.
    Mode Merge     Folds another store (-FromStore, the store of another workstation) into this one. The other store is opened read-only and
                   never modified; this store is written (created when missing, with the partition count of the other store). Idempotent: a
                   second run changes nothing. Prints a summary (users, conversations, messages new / updated / unchanged, files, content).
                   Lots, leases and import sessions are not merged: the store of the coordinator is authoritative for them. Multi-workstation
                   use: each workstation exports a DISJOINT lot (-Mode Export -Lot <name> -LotFile <csv>) into its OWN store, then the
                   coordinator runs -Mode Merge once per workstation store and creates its own lot over the merged store with -Mode Plan
                   -Lot <name> -LotFile <csv> (the same CSV). Close the run of the workstation (nothing may write its store) before merging it.

    The modes that write only locally (store, log, report folder, HTML archive) need neither -Apply nor a confirmation. With -WhatIf they
    show what they would do and do not start the engine.

    Everything is set in config\TeamsTransfer.config.psd1 (and config\TeamsTransfer.config.local.psd1 for the private values of the
    machine); the command line overrides it for one run and never modifies the file.

    Every run writes a log (TeamsTransfer_yyyyMMdd.log), shows numbered steps, and ends with a summary card that names the log and the
    report. While a long mode runs the script writes a progress line every -IntervalSeconds. Ctrl+C (or the appearance of -StopFile) stops
    after the requests in flight; run the same command again to resume.

    Reports: <Output.Root>\reports\yyyy-MM-dd_HHmmss_<Mode>\ with TeamsTransfer_<Mode>.html, .csv and a .json detail file.

.OUTPUTS
    Exit code: 0 the run is complete; 1 an error stopped it; 2 it is not complete but resumable, nothing was lost (stopped, or some items
    failed and will be retried by the next run: run the same command again); 3 the run holds items in an uncertain state
    (see -Mode Status). Order of the codes: 3, then 2, then 1, then 0.
    Nothing is written to the pipeline; with -PassThru the result of the run is returned as an object.

.PARAMETER Mode
    Assess, Inventory, Export, Files, Archive or Status (default). Plan (the dry-run import plan), Ghosts, CopyFiles, Import, Verify and Report work on a planned lot.
    Merge folds the store of another workstation (-FromStore) into this one.

.PARAMETER ConfigPath
    Configuration file. Default: config\TeamsTransfer.config.psd1 next to this script (and config\TeamsTransfer.config.local.psd1 on top).

.PARAMETER StoreRoot
    Folder of the local store. Default: Store.Path of the configuration, otherwise <Output.Root>\store (a relative Output.Root is resolved against the parent
    folder of the package, never against the current folder: by default <parent of the package>\out). Created by Inventory / Export / Merge,
    reopened later. Only one process at a time may write to it. It must be a local disk outside the package folder.

.PARAMETER OutputPath
    Archive: the folder of the archive (or the .html file with -SingleFile). Default: a folder in the report folder of the run.

.PARAMETER LogFolder
    Where the log file of the run is written: TeamsTransfer_yyyyMMdd.log (one line per message, no colour, no secret; the runs of a day
    append to it; files older than 14 days are deleted). Default: the folder named by the environment variable TEAMSTRANSFER_LOG_FOLDER,
    otherwise the logs folder of Output.Root (<parent folder of the package>\out\logs).

.PARAMETER Users
    Inventory, Export, Archive, Plan: limit the run to these users (ids or UPNs, comma separated, or the path of a CSV with an Id / Identity /
    UserPrincipalName / Mail column). Archive takes one user at a time. Default for Export: the users linked to a conversation in the store. Plan: creates a lot on the fly over these users (and -Teams).

.PARAMETER Teams
    Inventory, Export, Archive, Plan: limit the run to these teams (ids or exact display names, or the path of a CSV with an Id / TeamId /
    DisplayName column). Archive takes one team at a time.

.PARAMETER Conversation
    Archive: one or more conversation keys (chat:<id> or channel:<team>/<channel>).

.PARAMETER Lot
    Export, Status, Plan, Import, Ghosts, CopyFiles, Verify, Report: the name of a lot (batch of conversations) of the store. Export reads the users, teams, chats and channels that are members of the lot (chats and channels with strategy C) and moves the lot to Exported when every unit succeeded; Plan plans it.
    Plan with -Users / -Teams / -LotFile: the lot is created with this name when it does not exist, used as it is when it exists with the same members, and refused when it exists with different members. Without -Lot the lot gets an automatic name (plan-yyyyMMdd-HHmmss).
    Export with -LotFile: the lot is created with this name when it does not exist (same rules), then exported.

.PARAMETER LotFile
    Plan, Export: a CSV that defines the members of a lot, with the columns Type (User, Team, Chat or Channel), Identity (user id or UPN; team id or exact name;
    chat id or chat:<id>; channel teamId/channelId or channel:<key>) and Priority (optional whole number, lower runs first, default 100). Plan: with or without -Lot
    (and combinable with -Users / -Teams). Export: needs -Lot <name>.

.PARAMETER FromStore
    Merge: the root folder of the other store to fold into this one (opened read-only, never modified). It must hold a store (catalog.db), not be this store, and
    have the same number of partitions as this store (a missing destination store is created with that number).

.PARAMETER Window
    Export, Archive, Plan: the period to read. Nm with N from 1 to 600 (the last N months, for example 24m or 60m) or <from>..<to> (ISO dates, for example
    2024-01-01..2025-12-31). Default for Export: the whole history. Alternative to -From / -To.
    Plan (a lot that is created): Nm only (N from 1 to 600), cut in waves of 24 months then 12 months each (default 24m); a date range is refused there.
    Export with -LotFile: the waves of the new lot follow Nm (default 24, 36, 48 and 60 months).

.PARAMETER From
    Export, Archive: start of the period (a date or date and time).

.PARAMETER To
    Export, Archive: end of the period (a date or date and time).

.PARAMETER Strategy
    Export: U (per user), C (per chat) or Auto (default: U, then C for the conversations that contain imported messages).

.PARAMETER IncludeChannels
    Export: also export the messages and replies of the channels of the teams in the store.

.PARAMETER IncludeFiles
    Export: record the file references, then run the Files stage (download) unless -SkipFileDownload.

.PARAMETER SkipChats
    Inventory, Export: do not read the chats.

.PARAMETER SkipFileDownload
    Export: with -IncludeFiles, record the file references only; download them later with -Mode Files.

.PARAMETER NoHostedContents
    Export: do not download the images pasted inside messages.

.PARAMETER AllStoreUsers
    Export: without -Users, export every non-deleted user of the store, not only the users linked to a conversation.

.PARAMETER Full
    Export: read everything again instead of only what changed since the last run.

.PARAMETER MaxFileSizeMB
    Export, Files: files larger than this are not downloaded (0 = no limit, default).

.PARAMETER ExcludeExtensions
    Export, Files: file extensions that are not downloaded (for example .iso,.zip).

.PARAMETER SampleUsers
    Assess: number of users to sample (default 20).

.PARAMETER SampleTeams
    Assess: number of teams to sample (default 0: none).

.PARAMETER HistoryMonths
    Assess: depth of history to extrapolate over, in months (default 60).

.PARAMETER SingleFile
    Archive: write one self-contained .html file instead of a folder.

.PARAMETER Viewer
    Archive: the user (id, UPN or mail) whose messages are drawn on the right. Default: the user of -Users.

.PARAMETER Language
    Archive: language of the page. English only for now (en).

.PARAMETER Title
    Archive: title of the archive page. Default: derived from the scope.

.PARAMETER UserParallelism
    Inventory, Export, Ghosts: users read in parallel (1 to 64; Ghosts: 1 to 32). Default 8 in every one of these modes. The request rate is still limited by the service.

.PARAMETER Scenario
    Plan: TenantToTenant (A, default), SameTenantRestore (B, the same tenant: existing chats and channels are appended to) or
    DepartedArchive (C, one archive channel per departed user in archive teams).

.PARAMETER Slices
    Plan: the waves to plan, 1 to 4 (1 = the last 24 months, 2 = months 25-36, 3 = 37-48, 4 = 49-60). Default 1.
    Import: the waves to import (default: every slice of the lot). A later wave is older: the conversation is reopened with startMigration
    at an even earlier date.

.PARAMETER IdentityMap
    Plan: CSV of user mappings with the columns SourceUpn and / or SourceId, TargetUpn and / or TargetId.

.PARAMETER TeamMap
    Plan: CSV of team mappings with the columns SourceTeamId and / or SourceTeam (name), TargetTeamId and / or TargetTeam (name).
    Without a row, a team is the target team of the same display name, or is created.

.PARAMETER DomainMap
    Plan: 'source.com=target.com' (several, comma separated): a@source.com is looked up as a@target.com (UPN, then mail) in the target tenant.

.PARAMETER ServiceAccount
    UPN or object id of the service account (fallback author of federated and deleted authors, owner of the created teams). One order in Plan, Ghosts, CopyFiles,
    Import and Verify: this parameter, then Target.ServiceAccountUserId of the configuration, then the service account recorded by the plan of the lot, then the
    ServiceAccount identity of the identity map. A UPN is resolved with GET /users in the target tenant (an object id is used as it is).

.PARAMETER GhostDomain
    Plan: domain of the ghost accounts (tt-ghost-<hash>@domain) created for deleted authors. Without it they fall back to the service account.

.PARAMETER DeletedAuthors
    Plan: Auto (default: ghost when -GhostDomain is given, else service account), Ghost or ServiceAccount.

.PARAMETER ConfirmGhostCount
    Plan: accept a number of ghost accounts above -GhostThreshold (otherwise the plan is blocked, exit code 3).

.PARAMETER GhostThreshold
    Plan: the ghost count above which the plan is blocked without -ConfirmGhostCount (default 5000).

.PARAMETER ArchiveOwners
    Plan, scenario C: owners of the archive channels (UPNs or ids, comma separated). The service account is added.

.PARAMETER ArchiveTeamPrefix
    Plan, scenario C: archive teams are named '<prefix> NN' (default 'Teams Archive').

.PARAMETER ChannelsPerArchiveTeam
    Plan, scenario C: channels per archive team, 1 to 1000 (default 200; Teams allows 1000 including deleted channels).

.PARAMETER SkipTargetLookup
    Plan: do not read the target tenant (offline plan). CSV targets given as object ids are trusted; other users stay unresolved in scenario A. The service
    account must then be an object id.

.PARAMETER ConversationParallelism
    Export, Import, Verify: conversations processed at the same time (1 to 64). One default per mode: Export 8, Import 32, Verify 8. In Import each
    conversation stays at 5 requests per second.

.PARAMETER IntervalSeconds
    Seconds between two progress lines of a long mode (default 5).

.PARAMETER StopFile
    A stop request: when this file exists the job stops as Ctrl+C stops it (the requests in flight finish, the state is saved), exit code 2.

.PARAMETER Apply
    Ghosts, CopyFiles, Import: perform the changes in the target tenant. Without it the mode only previews. -WhatIf always wins over -Apply.

.PARAMETER Remove
    Ghosts: delete the ghost accounts recorded in the catalog instead of creating them (lab cleanup). Each account is read back and refused unless its
    employeeType is TeamsTransferGhost and its UPN starts with tt-ghost-. -Users limits it to some source users.

.PARAMETER Purge
    Ghosts with -Remove: also purge the removed ghosts from the recycle bin of the tenant.

.PARAMETER CreateTrackingGroup
    Ghosts: allow the tool to create the group "TeamsTransfer - Ghost accounts" when it does not exist (otherwise the stage is blocked). The group name can be
    set in the Ghosts section of the configuration (TrackingGroupName), as well as DomainName, DisplayNameFormat, ConfirmThreshold and CreateTrackingGroup.

.PARAMETER UsageLocation
    Ghosts: two-letter usageLocation set on the ghost accounts (default: Ghosts.UsageLocation of the configuration, otherwise none).

.PARAMETER FileParallelism
    CopyFiles: files copied in parallel (1 to 64, default 4).

.PARAMETER ChunkSizeMB
    CopyFiles: size of the fragments of an upload session, in MB (rounded to a multiple of 320 KiB, 1 to 60, default 10).

.PARAMETER NoShare
    CopyFiles: do not share the chat files with the chat members.

.PARAMETER SampleSize
    Verify: messages compared one by one per conversation and slice (0 to 1000, default 10).

.PARAMETER StrictCounts
    Verify: a different number of reactions or file attachments becomes a Mismatch (otherwise it is only reported).

.PARAMETER AllowExtra
    Verify: messages that were already on the target are not a mismatch (the default for -Scenario SameTenantRestore).

.PARAMETER NoLotUpdate
    Verify: do not change the state of the items and of the lot.

.PARAMETER CancelLot
    Status (with -Lot): abandons a lot that has not started importing (states Planned, Exporting, Exported, ImportPlanned, Paused, Failed and no import session):
    its items and its coverage are released, the lot stays in the store as Cancelled (audit row in its history). A lot that has started importing is refused.
    Writes to the local store only, never to a tenant; asks a confirmation unless -Force.

.PARAMETER Reason
    Status -CancelLot: the reason written in the history of the lot.

.PARAMETER Force
    With -Apply (or -Mode Status -CancelLot): no confirmation question (scheduled or unattended runs). Never skips a safety check.

.PARAMETER PassThru
    Also returns the result of the run as an object (Mode, Status, ExitCode, counters, log and report paths). Without it, nothing is written to the pipeline.

.PARAMETER Gui
    Opens the console window (WPF, STA) over the same module functions and engine, and ignores every other parameter except -Demo and -DevelopmentMode.
    Without an STA thread the script restarts itself in pwsh -STA.

.PARAMETER Demo
    With -Gui only: synthetic source and target tenants and a temporary store, no network (screenshots, tests, demonstrations; a DEMO badge is always shown).

.PARAMETER DevelopmentMode
    Allows a source checkout (no package manifest) or a development package (manifest without the owner signature). A present
    PackageIntegrity.psd1 is always verified; the state is announced as "unverified development tree" or "unsigned development package".

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Status
    Shows the state of the store (the default mode, Status): counts, inventory pass, pending files, lots. Nothing is written.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Status -Lot wave1 -CancelLot -Reason 'wrong scope'
    Abandons the lot wave1 (not imported yet) after a confirmation: its conversations are free for another lot. Local store only, no tenant is touched.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Assess -SampleUsers 30
    Samples 30 users and extrapolates volume and duration to the tenant. Nothing is written to the tenant.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Inventory -StoreRoot D:\ttstore
    Lists users, chats, teams and channels into the store; run it again to resume or to refresh.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Export -StoreRoot D:\ttstore -Window 24m -IncludeChannels -IncludeFiles
    Exports the last 24 months of chats and channels and their files; run it again to continue or to take what changed.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Files -StoreRoot D:\ttstore -MaxFileSizeMB 200
    Downloads the files recorded as Pending, skipping the files larger than 200 MB.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Archive -StoreRoot D:\ttstore -Users camille.martin@contoso.com -OutputPath D:\archives\camille
    Writes the offline HTML archive of one user.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Export -StoreRoot D:\ttstore -WhatIf
    Shows what the export would do and starts nothing.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Import -StoreRoot D:\ttstore
    Preview of the import of a planned lot (add -Lot <name>): the exact requests per endpoint, the first payloads (redacted), the estimated duration; nothing is sent and nothing is written to a tenant.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Import -StoreRoot D:\ttstore -Apply
    Imports the lot (add -Lot <name>) into the target tenant, after one confirmation (-Force skips it). Run the same command again to resume: a message is never sent twice.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Plan -StoreRoot D:\ttstore -Lot wave1 -DomainMap contoso.com=fabrikam.com -ServiceAccount svc-migration@fabrikam.com -GhostDomain fabrikam.com
    Plans the import of wave 1 of the lot (the last 24 months): conversations, messages, how every author is mapped, ghosts, files, estimated duration.
    Writes reports\<date>_Plan\plan.html (and the CSV files). Nothing is written to the target tenant; exit code 3 when the plan has blockers.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Ghosts -StoreRoot D:\ttstore -GhostDomain fabrikam.com -CreateTrackingGroup
    Preview: reads the target and lists the ghost accounts that would be created (ghosts.csv in the report folder). Nothing is written.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Ghosts -StoreRoot D:\ttstore -Lot wave1 -GhostDomain fabrikam.com -CreateTrackingGroup -Apply -Force
    Creates the ghost accounts of the deleted authors in the target tenant, without the confirmation question, and moves the lot to Ghosts.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode CopyFiles -StoreRoot D:\ttstore -Lot wave1
    Preview of the file copy: files and bytes per destination, no request. Add -Apply to copy and share the files; run it again to retry failures.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Verify -StoreRoot D:\ttstore -Lot wave1
    Verifies the imported lot against the journal and the source, writes verify.html and verify.csv, and sets the lot Verified when everything is OK (exit code 3 on a mismatch).

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Report -StoreRoot D:\ttstore
    Rebuilds the HTML report of every lot from the catalog (states, journal, ghosts, files, last verification).

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Export -StoreRoot D:\ws1\store -Lot ws1 -LotFile .\lots\ws1.csv -IncludeChannels -IncludeFiles
    On workstation 1: creates the lot ws1 from the CSV (Type, Identity, Priority) when it does not exist, then exports it into its own store.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Merge -StoreRoot D:\coordinator\store -FromStore \\ws1\share\store
    On the coordinator: folds the store of workstation 1 into this one (the other store is only read). Run it again for the next workstation; a second run of the same one changes nothing.

.EXAMPLE
    .\Invoke-TeamsTransfer.ps1 -Mode Plan -StoreRoot D:\ttstore -Lot ws1 -LotFile .\lots\ws1.csv -DomainMap contoso.com=fabrikam.com -ServiceAccount svc-migration@fabrikam.com
    Creates the lot ws1 over the (merged) store with the same CSV, then plans it. An existing lot with other members is refused.

.EXAMPLE
    pwsh -STA -File .\Invoke-TeamsTransfer.ps1 -Gui
    Opens the console (pages for every mode, Teams-like preview). Add -Demo for the offline demonstration with synthetic tenants.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.2
    Requires : PowerShell 7.4 or later (pwsh.exe). Microsoft Graph application permissions, certificate sign-in (see config).
    Exit codes : 0 = complete, 1 = failed, 2 = resumable, 3 = uncertain items.
    History : see CHANGELOG.md

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.

    Import creates conversations in the target tenant and an imported conversation cannot be rolled back: run the preview, review the plan and test in a lab first.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report', 'Merge')][string]$Mode = 'Status',
    [string]$ConfigPath,

    # store and output
    [string]$StoreRoot,
    [string]$OutputPath,
    [string]$LogFolder,
    [string]$FromStore,

    # selection
    [string[]]$Users,
    [string[]]$Teams,
    [string[]]$Conversation,
    [string]$Lot,
    [string]$LotFile,
    [string]$Window,
    [Nullable[datetimeoffset]]$From,
    [Nullable[datetimeoffset]]$To,
    [ValidateSet('U', 'C', 'Auto')][string]$Strategy = 'Auto',
    [switch]$IncludeChannels,
    [switch]$IncludeFiles,
    [switch]$SkipChats,
    [switch]$SkipFileDownload,
    [switch]$NoHostedContents,
    [switch]$AllStoreUsers,
    [switch]$Full,
    [ValidateRange(0, 100000)][int]$MaxFileSizeMB = 0,
    [string[]]$ExcludeExtensions,

    # assess
    [ValidateRange(1, 10000)][int]$SampleUsers = 20,
    [ValidateRange(0, 10000)][int]$SampleTeams = 0,
    [ValidateRange(1, 600)][int]$HistoryMonths = 60,

    # archive
    [switch]$SingleFile,
    [string]$Viewer,
    [ValidateSet('en')][string]$Language = 'en',
    [string]$Title,

    # plan
    [ValidateSet('TenantToTenant', 'SameTenantRestore', 'DepartedArchive')][string]$Scenario = 'TenantToTenant',
    [string[]]$Slices = @('1'),
    [string]$IdentityMap,
    [string]$TeamMap,
    [string[]]$DomainMap,
    [string]$ServiceAccount,
    [string]$GhostDomain,
    [ValidateSet('Auto', 'Ghost', 'ServiceAccount')][string]$DeletedAuthors = 'Auto',
    [switch]$ConfirmGhostCount,
    [ValidateRange(1, 1000000)][int]$GhostThreshold = 5000,
    [string[]]$ArchiveOwners,
    [string]$ArchiveTeamPrefix = 'Teams Archive',
    [ValidateRange(1, 1000)][int]$ChannelsPerArchiveTeam = 200,
    [switch]$SkipTargetLookup,

    # ghosts, file copy, verify
    [switch]$Remove,
    [switch]$Purge,
    [switch]$CreateTrackingGroup,
    [ValidatePattern('^[A-Za-z]{2}$')][string]$UsageLocation,
    [ValidateRange(1, 64)][int]$FileParallelism = 4,
    [ValidateRange(1, 60)][int]$ChunkSizeMB = 10,
    [switch]$NoShare,
    [ValidateRange(0, 1000)][int]$SampleSize = 10,
    [switch]$StrictCounts,
    [switch]$AllowExtra,
    [switch]$NoLotUpdate,
    [switch]$CancelLot,
    [string]$Reason,

    # throughput and stop
    [ValidateRange(1, 64)][int]$UserParallelism,           # default 8 (Inventory, Export, Ghosts): see $parallelismDefaults
    [ValidateRange(1, 64)][int]$ConversationParallelism,   # default per mode: Export 8, Import 32, Verify 8
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 5,
    [string]$StopFile,

    # write modes (target tenant): preview unless -Apply
    [switch]$Apply,
    [switch]$Force,

    # console contract
    [switch]$PassThru,
    [switch]$DevelopmentMode,
    [switch]$Gui,
    [switch]$Demo
)
# The frames and the icons of the console are Unicode; a redirected output (a scheduled task) is UTF-8 without BOM. Set before the first write.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose "Console output encoding unchanged: $($_.Exception.Message)" }
# No ANSI sequence in a redirected output (a scheduled task, a pipe) or with NO_COLOR: warnings and errors included.
if ([Console]::IsOutputRedirected -or $env:NO_COLOR) { $PSStyle.OutputRendering = [Management.Automation.OutputRendering]::PlainText }
# A French operator sees 1,234 and 0.5, never 1 234 or 0,5 (and the messages of PowerShell itself are English).
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

#region 1. Package integrity ------------------------------------------------------------------------
# The package is verified before any of its code runs. The verifier (src\Test-PackageIntegrity.ps1) checks the SHA256 list of
# PackageIntegrity.psd1; a release is signed by the owner. A source checkout (no manifest) or a development package (manifest not yet signed)
# starts only with -DevelopmentMode, and the state is always announced: there is no silent bypass.
$integrityManifest = Join-Path $PSScriptRoot 'PackageIntegrity.psd1'
$integrityVerifier = Join-Path $PSScriptRoot 'src\Test-PackageIntegrity.ps1'
$integrityResult = $null
if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $integrityManifest) {
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $integrityVerifier -PathType Leaf)) { throw 'Package integrity: the verifier src\Test-PackageIntegrity.ps1 is missing. Use the complete release ZIP: extract it again and unblock it.' }
    $integrityCursor = [IO.Path]::GetFullPath($integrityVerifier)
    while ($integrityCursor) {
        $integrityItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $integrityCursor -Force -ErrorAction Stop
        if ($integrityItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package integrity: reparse point: $integrityCursor" }
        $integrityCursor = [IO.Path]::GetDirectoryName($integrityCursor)
    }
    $integritySignature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $integrityVerifier -ErrorAction Stop
    $verifierSigned = [string]$integritySignature.Status -ceq 'Valid' -and $null -ne $integritySignature.SignerCertificate -and
        $integritySignature.SignerCertificate.Thumbprint -ceq '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6' -and $null -ne $integritySignature.TimeStamperCertificate
    if (-not $verifierSigned -and -not $DevelopmentMode) {
        throw 'Package integrity: unsigned development package (the verifier does not carry the trusted, timestamped owner signature). Use the complete release ZIP (https://github.com/Nico77600/TeamsTransfer/releases/latest): extract it again and unblock it. A source checkout or a development package is started with -DevelopmentMode.'
    }
    $integrityResult = if ($DevelopmentMode) { & $integrityVerifier -Root $PSScriptRoot -DevelopmentMode } else { & $integrityVerifier -Root $PSScriptRoot -Distribution }
} elseif (-not $DevelopmentMode) {
    throw 'Package integrity: PackageIntegrity.psd1 is missing. Use the complete release ZIP (https://github.com/Nico77600/TeamsTransfer/releases/latest): extract it again and unblock it. A source checkout is started with -DevelopmentMode.'
} elseif (Microsoft.PowerShell.Management\Test-Path -LiteralPath $integrityVerifier -PathType Leaf) {
    $integrityResult = & $integrityVerifier -Root $PSScriptRoot -DevelopmentMode
}
if ($integrityResult -and [string]$integrityResult.Status -ne 'Valid') {
    Write-Warning "DevelopmentMode ($($integrityResult.Status)): $($integrityResult.Message)"
}
#endregion

# -Gui: the console (TeamsTransfer.Gui.ps1) opens and every other parameter is ignored. WPF needs an STA thread: restart in pwsh -STA when needed.
if ($Gui) {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        $guiArgs = @('-NoLogo', '-NoProfile', '-STA', '-File', $PSCommandPath, '-Gui')
        if ($Demo) { $guiArgs += '-Demo' }
        if ($DevelopmentMode) { $guiArgs += '-DevelopmentMode' }
        & (Microsoft.PowerShell.Management\Get-Process -Id $PID).Path @guiArgs
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot 'TeamsTransfer.Gui.ps1') -Demo:$Demo
    return
}
if ($Demo) { throw '-Demo goes with -Gui (the offline console with synthetic tenants).' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#region 2. Parameters, mode, preview or apply ----------------------------------------------------------
# ValidateSet accepts any casing: bring the mode back to its official spelling.
$Mode = @('Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report', 'Merge') | Where-Object { $_ -ieq $Mode } | Select-Object -First 1
$writeModes = 'Import', 'Ghosts', 'CopyFiles'                                    # modes that write into the TARGET tenant: preview unless -Apply
$laterModes = @()       # announced, not implemented yet (none left)
$isWriteMode = $Mode -in $writeModes
# -WhatIf always wins over -Apply; it only means "plan": the files of the run (log, store, report) are written like in any run.
$dryRun = [bool]$WhatIfPreference -or ($isWriteMode -and -not $Apply)
$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false
$skipConfirmation = $Force -or ($PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm'])

$localModes = 'Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Plan', 'Verify', 'Report', 'Merge'
# One documented default per mode (the parameters have no default of their own, so that the help and the code say the same thing).
$parallelismDefaults = @{ UserParallelism = @{ Inventory = 8; Export = 8; Ghosts = 8 }; ConversationParallelism = @{ Export = 8; Import = 32; Verify = 8 } }
foreach ($parallelName in $parallelismDefaults.Keys) {
    if (-not $PSBoundParameters.ContainsKey($parallelName) -and $parallelismDefaults[$parallelName].ContainsKey($Mode)) { Set-Variable -Name $parallelName -Value $parallelismDefaults[$parallelName][$Mode] }
}
$parameterModes = [ordered]@{
    Apply = $writeModes; Force = (@($writeModes) + 'Status')
    Conversation = 'Archive'; SingleFile = 'Archive'; Viewer = 'Archive'; Title = 'Archive'; OutputPath = 'Archive'
    Users = 'Inventory', 'Export', 'Archive', 'Plan'; Teams = 'Inventory', 'Export', 'Archive', 'Plan'
    Lot = 'Export', 'Status', 'Plan', 'Import'; LotFile = 'Export', 'Plan'; FromStore = 'Merge'; Window = 'Export', 'Archive', 'Plan'; From = 'Export', 'Archive'; To = 'Export', 'Archive'
    Strategy = 'Export'; IncludeChannels = 'Export'; IncludeFiles = 'Export'; SkipFileDownload = 'Export'; NoHostedContents = 'Export'
    AllStoreUsers = 'Export'; Full = 'Export'; ConversationParallelism = 'Export', 'Import'
    SkipChats = 'Inventory', 'Export'; UserParallelism = 'Inventory', 'Export'
    MaxFileSizeMB = 'Export', 'Files'; ExcludeExtensions = 'Export', 'Files'
    SampleUsers = 'Assess'; SampleTeams = 'Assess'; HistoryMonths = 'Assess'
    Scenario = 'Plan'; Slices = 'Plan', 'Import'; IdentityMap = 'Plan'; TeamMap = 'Plan'; DomainMap = 'Plan'; ServiceAccount = 'Plan', 'Import'; GhostDomain = 'Plan'; DeletedAuthors = 'Plan'
    ConfirmGhostCount = 'Plan'; GhostThreshold = 'Plan'; ArchiveOwners = 'Plan'; ArchiveTeamPrefix = 'Plan'; ChannelsPerArchiveTeam = 'Plan'; SkipTargetLookup = 'Plan'}
# Ghosts / CopyFiles / Verify / Report share some of the parameters above and add their own.
foreach ($shared in @{ Lot = 'Ghosts', 'CopyFiles', 'Verify', 'Report'; Slices = 'CopyFiles', 'Verify'; Users = 'Ghosts'; UserParallelism = 'Ghosts'; GhostDomain = 'Ghosts'; ConfirmGhostCount = 'Ghosts'; GhostThreshold = 'Ghosts'
                     ServiceAccount = 'Ghosts', 'CopyFiles', 'Verify'; Scenario = 'Verify'; ConversationParallelism = 'Verify'; MaxFileSizeMB = 'CopyFiles'; ExcludeExtensions = 'CopyFiles' }.GetEnumerator()) {
    $parameterModes[$shared.Key] = @($parameterModes[$shared.Key]) + @($shared.Value)
}
foreach ($own in 'Remove', 'Purge', 'CreateTrackingGroup', 'UsageLocation') { $parameterModes[$own] = @('Ghosts') }
foreach ($own in 'FileParallelism', 'ChunkSizeMB', 'NoShare') { $parameterModes[$own] = @('CopyFiles') }
foreach ($own in 'SampleSize', 'StrictCounts', 'AllowExtra', 'NoLotUpdate') { $parameterModes[$own] = @('Verify') }
foreach ($own in 'CancelLot', 'Reason') { $parameterModes[$own] = @('Status') }
#endregion

#region 3. Functions of the entry script -------------------------------------------------------------

function Get-RunHint {
    # The action to take for the errors that have a known cause.
    param([string]$Message)
    switch -Regex ($Message) {
        'Configuration\.\w+\.\w+ is empty' { return 'Fill the Source / Target section of config\TeamsTransfer.config.local.psd1 (TenantId, ClientId, CertificateThumbprint).' }
        'certificate.*(not found|private key)|thumbprint' { return 'The certificate must be in Cert:\CurrentUser\My or Cert:\LocalMachine\My with its private key; check CertificateThumbprint.' }
        'AADSTS7000(16|22|27)|AADSTS700027|AADSTS1002' { return 'Check TenantId, ClientId and that the certificate is uploaded to the app registration.' }
        '403|Forbidden|Authorization_RequestDenied|protected API' { return 'Grant administrator consent to the application permissions of the app registration, and check the access to the Teams protected APIs (see the documentation).' }
        'already open for writing' { return 'Another TeamsTransfer process holds the store: wait for it, or use another -StoreRoot.' }
        'inside the package folder|SQLite over SMB' { return 'Choose a -StoreRoot on a local disk, outside the package folder.' }
        default { return '' }
    }
}

function Format-RunCommand {
    # The command that repeats this run, on one copyable line.
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('.\Invoke-TeamsTransfer.ps1')
    foreach ($entry in $script:BoundParameters.GetEnumerator()) {
        $k = $entry.Key; $v = $entry.Value
        if ($k -in 'PassThru', 'Verbose', 'Debug', 'WhatIf', 'Confirm', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable') { continue }
        if ($v -is [switch]) { if ($v.IsPresent) { $parts.Add("-$k") }; continue }
        $text = (@($v) | ForEach-Object { [string]$_ }) -join ','
        if ($text -match '\s') { $text = "'" + $text.Replace("'", "''") + "'" }
        $parts.Add("-$k $text")
    }
    return ($parts -join ' ')
}

function Test-StopRequested {
    return [bool]($StopFile -and (Test-Path -LiteralPath $StopFile))
}

function Assert-NotStopped {
    # Called between the steps: a stop request ends the run as resumable (exit code 2) before the next step starts.
    if (Test-StopRequested) {
        Write-TmtItem WARN 'stop requested: the requests in flight finish first, run the command again to resume'
        throw [OperationCanceledException]::new('Stop requested (-StopFile).')
    }
}

function New-RunFolder {
    # <Output.Root>\reports\yyyy-MM-dd_HHmmss_<Mode>, with -1, -2 on a collision.
    $name = '{0}_{1}' -f $script:runStart.ToString('yyyy-MM-dd_HHmmss', [Globalization.CultureInfo]::InvariantCulture), $Mode
    $base = Join-Path (Join-Path $script:outRoot 'reports') $name
    $path = $base; $i = 0
    while (Test-Path -LiteralPath $path) { $i++; $path = "$base-$i" }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Save-RunReport {
    # TeamsTransfer_<Mode>.csv (counters), .json (detail) and .html (readable summary), UTF-8 without BOM.
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts, $Detail, [string[]]$Notes = @())
    $utf8 = [Text.UTF8Encoding]::new($false)
    $stem = Join-Path $Folder "TeamsTransfer_$Mode"
    $csv = [Collections.Generic.List[string]]::new()
    $csv.Add('Name,Value')
    foreach ($k in $Counts.Keys) { $csv.Add(('"{0}","{1}"' -f ([string]$k).Replace('"', '""'), ([string]$Counts[$k]).Replace('"', '""'))) }
    [IO.File]::WriteAllText("$stem.csv", ($csv -join "`r`n") + "`r`n", $utf8)
    if ($null -ne $Detail) { [IO.File]::WriteAllText("$stem.json", ($Detail | ConvertTo-Json -Depth 8), $utf8) }
    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $rows = ($Counts.Keys | ForEach-Object { '<tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (& $enc $_), (& $enc $(if ($Counts[$_] -is [long] -or $Counts[$_] -is [int]) { Format-TmtNumber $Counts[$_] } else { $Counts[$_] })) }) -join "`n"
    $noteHtml = if ($Notes) { '<h2>Notes</h2><pre>' + (& $enc ($Notes -join "`n")) + '</pre>' } else { '' }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teams Transfer - $(& $enc $Mode) report</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1b1b1f;--muted:#5f6368;--line:#d9dbe0}
@media (prefers-color-scheme:dark){:root{--bg:#1b1b1f;--fg:#ececf1;--muted:#a0a3ab;--line:#3a3b42}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif;margin:0 auto;padding:24px 16px;max-width:760px}
h1{font-size:22px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px}table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}th{font-weight:600;width:55%}td{font-variant-numeric:tabular-nums}
pre{white-space:pre-wrap;border:1px solid var(--line);padding:10px;border-radius:6px}
</style></head><body>
<h1>Teams Transfer - $(& $enc $Mode)</h1>
<p>v$($script:ToolVersionText) &middot; $(& $enc $script:runStart.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)) &middot; store $(& $enc $script:StoreRootResolved)</p>
<table>
$rows
</table>
$noteHtml
</body></html>
"@
    [IO.File]::WriteAllText("$stem.html", $html, $utf8)
    return $Folder
}

function Open-RunStore {
    # Opens the store for the mode: read-only for Status and Archive (the store must exist), read-write otherwise (created when missing).
    param([switch]$ReadOnly, [switch]$MustExist)
    $catalog = Join-Path $script:StoreRootResolved 'catalog.db'
    if (($ReadOnly -or $MustExist) -and -not (Test-Path -LiteralPath $catalog)) { throw "No store at $($script:StoreRootResolved): run -Mode Inventory or -Mode Export first, or check -StoreRoot." }
    $partitions = [int]$script:config.Store.Partitions
    if ($ReadOnly) { return Open-TmtStore -Root $script:StoreRootResolved -ReadOnly }
    return Open-TmtStore -Root $script:StoreRootResolved -Partitions $partitions
}

#endregion

#region 4. Setup: culture, configuration, paths, log, banner ------------------------------------------


$script:BoundParameters = $PSBoundParameters
# "-Users a,b" given through pwsh -File arrives as one string: lists are split on commas here.
foreach ($listName in 'Users', 'Teams', 'Conversation', 'ExcludeExtensions') {
    $listValue = Get-Variable -Name $listName -ValueOnly
    if ($listValue) { Set-Variable -Name $listName -Value @($listValue | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
}
$script:runStart = Get-Date
$runClock = [Diagnostics.Stopwatch]::StartNew()
Import-Module (Join-Path $PSScriptRoot 'TeamsTransfer.psd1') -Force
$script:ToolVersionText = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'TeamsTransfer.psd1')).ModuleVersion
Reset-TmtRunIssues

# A configuration that cannot be read does not prevent the card and the log: the error is raised first thing in the work block.
$configError = $null
$config = $null
try { $config = if ($ConfigPath) { Import-TmtConfiguration -Path $ConfigPath } else { Import-TmtConfiguration } }
catch {
    $configError = $_
    $none = @{ Cloud = 'Global'; TenantId = ''; ClientId = ''; CertificateThumbprint = '' }
    $config = @{ Output = @{ Root = '.\out' }; Store = @{ Path = ''; Partitions = 256 }; Logging = @{ RetentionDays = 14 }; Source = $none.Clone(); Target = $none.Clone() }
}
$script:config = $config
$outRootConfigured = if ($config.Output.Root) { [string]$config.Output.Root } else { '.\out' }
# A relative Output.Root is resolved against the PARENT folder of the package (...\TeamsTransfer\out next to package\), never against the current folder:
# running from the package folder must not put the store inside the package (it would be refused).
$script:packageParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/'))
if (-not $script:packageParent) { $script:packageParent = [IO.Path]::GetFullPath($PSScriptRoot) }
$script:outRoot = if ([IO.Path]::IsPathRooted($outRootConfigured)) { $outRootConfigured } else { [IO.Path]::GetFullPath($outRootConfigured, $script:packageParent) }
if (-not $StoreRoot) { $StoreRoot = if ($config.Store.Path) { [string]$config.Store.Path } else { Join-Path $script:outRoot 'store' } }
$script:StoreRootResolved = if ([IO.Path]::IsPathRooted($StoreRoot)) { $StoreRoot } else { [IO.Path]::GetFullPath($StoreRoot, (Get-Location).ProviderPath) }
$script:FromStoreResolved = if (-not $FromStore) { '' } elseif ([IO.Path]::IsPathRooted($FromStore)) { $FromStore } else { [IO.Path]::GetFullPath($FromStore, (Get-Location).ProviderPath) }
if ($OutputPath -and -not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).ProviderPath) }
if ($StopFile -and -not [IO.Path]::IsPathRooted($StopFile)) { $StopFile = [IO.Path]::GetFullPath($StopFile, (Get-Location).ProviderPath) }
if (-not $LogFolder) { $LogFolder = if ($env:TEAMSTRANSFER_LOG_FOLDER) { $env:TEAMSTRANSFER_LOG_FOLDER } else { Join-Path $script:outRoot 'logs' } }
$retention = if ($config.Logging.RetentionDays) { [int]$config.Logging.RetentionDays } else { 14 }
$logPath = $null
try { $logPath = Start-TmtLog -Directory $LogFolder -RetentionDays $retention } catch { Write-Warning "No log file ($LogFolder): $($_.Exception.Message)" }
if ($integrityResult -and [string]$integrityResult.Status -ne 'Valid') { Write-TmtLog WARN "Package integrity ($($integrityResult.Status)): $($integrityResult.Message)" }

$subtitle = switch ($Mode) {
    'Assess'    { 'Measures a sample of the tenant and estimates the migration (read only)' }
    'Inventory' { 'Lists users, chats, teams and channels into the local store' }
    'Export'    { 'Exports Teams chats and channels to a verified local store' }
    'Files'     { 'Downloads the files that the exported messages refer to' }
    'Archive'   { 'Writes an offline, Teams-like HTML archive of the store' }
    'Status'    { 'Shows the state of the local store' }
    'Plan'      { 'Plans the import of a lot: identities, targets, ghosts, files (nothing is written to a tenant)' }
    'Ghosts'    { 'Creates the ghost accounts of the deleted authors in the target tenant' }
    'CopyFiles' { 'Copies the exported files into the target tenant and shares them' }
    'Verify'    { 'Compares the target tenant with the journal and the source, conversation by conversation' }
    'Report'    { 'Rebuilds the HTML reports of a lot from the catalog' }
    'Import'    { 'Creates the conversations of the store in the target tenant' }
    'Merge'     { 'Folds the store of another workstation into this one (the other store is only read)' }
    default     { "Mode $Mode (not implemented yet)" }
}
$modeText = $Mode
if ($isWriteMode) { $modeText += $(if ($dryRun) { ' - Preview (nothing is written)' } else { ' - Apply (changes are made)' }) }
elseif ($whatIf) { $modeText += ' - WhatIf (nothing is written)' }
$details = [ordered]@{ Mode = @('Mode', $modeText) }
if ($Mode -in 'Assess', 'Inventory', 'Export', 'Files') { $details.Tenant = @('Key', $(if ($config.Source.TenantId) { [string]$config.Source.TenantId } else { '(Source not configured)' })) }
if ($Mode -in 'Plan', 'Ghosts', 'CopyFiles', 'Verify') { $details.Tenant = @('Key', $(if ($config.Target.TenantId) { [string]$config.Target.TenantId } else { '(Target not configured)' })) }
if ($Mode -ne 'Assess') { $details.Store = @('Store', $script:StoreRootResolved) }
if ($Mode -eq 'Merge' -and $script:FromStoreResolved) { $details.From = @('Store', $script:FromStoreResolved) }
$details.OutFolder = @('Folder', "$($script:outRoot) (logs, reports, default store: next to the package folder)")
if ($OutputPath) { $details.Output = @('Folder', $OutputPath) }
if ($logPath) { $details.Log = @('Log', $logPath) }
Write-TmtBanner -Title 'Teams Transfer' -Subtitle $subtitle -Details $details
#endregion

#region 5. Work ---------------------------------------------------------------------------------------

$script:counts = [ordered]@{}
$script:next = $null
$script:reportPath = $null
$exitCode = 0
$failure = $null
$caught = $null
$store = $null
$resultDetail = $null

try {
    if ($configError) { throw $configError.Exception.Message }

    # Combinations are refused before anything is read or written.
    foreach ($name in $parameterModes.Keys) {
        if ($PSBoundParameters.ContainsKey($name) -and $Mode -notin $parameterModes[$name]) {
            if ($name -in 'Apply', 'Force') { throw "-$name belongs to the modes that write to the target tenant ($($writeModes -join ', ')); $Mode never writes there." }
            throw "-$name does not apply to -Mode $Mode (it applies to: $($parameterModes[$name] -join ', '))."
        }
    }
    if ($Window -and ($From -or $To)) { throw '-Window and -From / -To are alternatives: give one of them.' }
    if ($CancelLot -and -not $Lot) { throw '-CancelLot needs the lot to cancel: add -Lot <name> (-Mode Status lists the lots).' }
    if ($Reason -and -not $CancelLot) { throw '-Reason applies to -CancelLot.' }
    if ($Mode -eq 'Status' -and $PSBoundParameters.ContainsKey('Force') -and -not $CancelLot) { throw '-Force applies to -Mode Status only with -CancelLot (cancelling a lot asks a confirmation).' }
    if ($Lot -and ($Users -or $Teams) -and $Mode -ne 'Plan') { throw '-Lot already names the users and teams of the run: do not combine it with -Users / -Teams (with -Mode Plan they create the lot; with -Mode Export use -LotFile).' }
    if ($LotFile -and $Mode -eq 'Export' -and -not $Lot) { throw '-LotFile needs the name of the lot to create: add -Lot <name> (with -Mode Plan the name is optional).' }
    if ($LotFile -and -not (Test-Path -LiteralPath $LotFile -PathType Leaf)) { throw "-LotFile: file not found: $LotFile" }
    if ($Window) {
        # the same rule as the engine, checked before anything is opened: Plan cuts a lot in waves of months (Nm); Export and Archive also take <from>..<to>
        if ($Mode -eq 'Plan') { [void](ConvertTo-TmtWindowBoundaries $Window) } else { [void](Resolve-TmtWindow $Window) }
    }
    if ($Mode -eq 'Ghosts' -and $UserParallelism -gt 32) { throw '-UserParallelism: with -Mode Ghosts the value is 1 to 32 (default 8).' }
    if ($Mode -eq 'Merge') {
        if (-not $FromStore) { throw '-FromStore is required with -Mode Merge: the root folder of the other store (the store of the other workstation) to fold into this one.' }
        $mergeThis = $script:StoreRootResolved.TrimEnd('\', '/'); $mergeThat = $script:FromStoreResolved.TrimEnd('\', '/')
        if ($mergeThis -ieq $mergeThat) { throw '-FromStore is this store: give the root of ANOTHER store.' }
        if ($mergeThat.StartsWith($mergeThis + '\', [StringComparison]::OrdinalIgnoreCase) -or $mergeThis.StartsWith($mergeThat + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '-FromStore and -StoreRoot overlap (one is inside the other): give two separate store folders.' }
    }
    if ($SingleFile -and $OutputPath -and -not $OutputPath.EndsWith('.html', [StringComparison]::OrdinalIgnoreCase)) { throw '-SingleFile writes one .html file: -OutputPath must end with .html.' }

    if ($Mode -in $laterModes) {
        # Later modes: the preview / apply plumbing is in place, the work is not.
        Write-TmtStep "Checking the request" -Number 1 -Total 1 -Icon Plan
        if ($isWriteMode) {
            if ($dryRun) {
                Write-TmtItem SKIP "Preview: nothing is written. $(if ($whatIf) { '-WhatIf wins over -Apply.' } else { 'Run it again with -Apply to make the changes.' })"
            } else {
                $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if (-not $skipConfirmation) {
                    if (-not $interactive) { throw "-Apply needs a confirmation and this session is not interactive: add -Force for an unattended run." }
                    if (-not $PSCmdlet.ShouldContinue("$Mode creates content in the target tenant $($config.Target.TenantId). Continue?", 'Teams Transfer - Apply')) { throw 'Cancelled by the operator: nothing was written.' }
                }
            }
        }
        throw "Mode $Mode is not implemented yet. Nothing was read and nothing was written."
    }

    if ($whatIf -and $Mode -in $localModes) {
        # WhatIf on a local mode: the plan, without starting the engine.
        Write-TmtStep 'Planning the run' -Number 1 -Total 1 -Icon Plan
        Write-TmtItem SKIP "WhatIf: $Mode would use the store $($script:StoreRootResolved)"
        switch ($Mode) {
            'Assess'    { Write-TmtItem SKIP "WhatIf: it would sample $SampleUsers user(s) and $SampleTeams team(s) over $HistoryMonths month(s) and write a report folder" }
            'Inventory' { Write-TmtItem SKIP 'WhatIf: it would read users, chats, teams and channels from the Source tenant into the store' }
            'Export'    { Write-TmtItem SKIP "WhatIf: it would export the messages ($(if ($Window) { "window $Window" } else { 'whole history' }), strategy $Strategy$(if ($IncludeChannels) { ', channels' })$(if ($IncludeFiles) { ', files' })) into the store" }
            'Files'     { Write-TmtItem SKIP 'WhatIf: it would download the files recorded as Pending' }
            'Plan'      { Write-TmtItem SKIP "WhatIf: it would plan the import of $(if ($Lot) { "lot $Lot" } else { 'a new lot over the given users and teams' }) ($Scenario, slice(s) $($(@($Slices | ForEach-Object { $_ -split ',' }) -join ','))) and write the plan folder" }
            'Archive'   { Write-TmtItem SKIP "WhatIf: it would write the HTML archive$(if ($OutputPath) { " to $OutputPath" })" }
            'Verify'    { Write-TmtItem SKIP "WhatIf: it would verify lot $Lot on the target tenant (read only), write the results and, if everything is OK, set the lot Verified" }
            'Report'    { Write-TmtItem SKIP 'WhatIf: it would rebuild the HTML reports of the lot(s) from the catalog' }
            'Merge'     { Write-TmtItem SKIP "WhatIf: it would fold the store $($script:FromStoreResolved) (read only) into $($script:StoreRootResolved)" }
        }
        $script:next = (Format-RunCommand) -replace ' -WhatIf', ''
        $exitCode = 0
    } else {
        switch ($Mode) {
            'Status' {
                Write-TmtStep 'Reading the package and the configuration' -Number 1 -Total 2 -Icon Plan
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Initialize-TmtEngine
                Write-TmtOk "Teams Transfer $($script:ToolVersionText), PowerShell $($PSVersionTable.PSVersion), engine compiled in $(Format-TmtDuration $clock.Elapsed.TotalSeconds)"
                $cfgFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot 'config\TeamsTransfer.config.psd1' }
                Write-TmtOk "Configuration: $cfgFile$(if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($cfgFile, '.local.psd1'))) { ' (+ local file)' })"
                foreach ($side in 'Source', 'Target') {
                    $s = $config[$side]
                    if ($s.TenantId -and $s.ClientId -and $s.CertificateThumbprint) { Write-TmtInfo "${side}: tenant $($s.TenantId), app $($s.ClientId), certificate configured" }
                    else { Write-TmtInfo "${side}: not configured (fill config\TeamsTransfer.config.local.psd1)" }
                }
                Write-TmtStep 'Reading the store' -Number 2 -Total 2 -Icon Store
                if (Test-Path -LiteralPath (Join-Path $script:StoreRootResolved 'catalog.db')) {
                    $store = if ($CancelLot) { Open-RunStore -MustExist } else { Open-RunStore -ReadOnly }
                    $statusLotId = $null
                    if ($CancelLot) {
                        # a write to the LOCAL store only (never the tenant): it asks a confirmation unless -Force
                        $cl = $store.GetLot($Lot)
                        if ($null -eq $cl) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
                        $statusLotId = $cl.Id
                        $clItems = @($store.ListItems($cl.Id)).Count
                        if ($whatIf) { Write-TmtItem SKIP "WhatIf: it would cancel lot $Lot ($($cl.State), $(Format-TmtNumber $clItems) item(s)): items and coverage released, an audit row kept" }
                        else {
                            if (-not $skipConfirmation) {
                                $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                                if (-not $interactive) { throw '-CancelLot needs a confirmation and this session is not interactive: add -Force for an unattended run.' }
                                if (-not $PSCmdlet.ShouldContinue("Cancel lot '$Lot' ($($cl.State), $(Format-TmtNumber $clItems) item(s))? Its items and coverage are released; nothing is changed in any tenant.", 'Teams Transfer - Cancel lot')) { throw 'Cancelled by the operator: the lot is unchanged.' }
                            }
                            try { $cancelled = $store.CancelLot([long]$cl.Id, $(if ($Reason) { $Reason } else { 'cancelled by the operator' })) }
                            catch [InvalidOperationException] { throw $_.Exception.Message }
                            Write-TmtOk "Lot $Lot cancelled ($(Format-TmtNumber $clItems) item(s) and their coverage released; kept as $($cancelled.Name))" -Icon Done
                        }
                    }
                    $st = Get-TmtStoreStatus -Store $store
                    Write-TmtOk "Store $($st.Root) (id $($st.StoreId))" -Icon Store
                    Write-TmtInfo "Users $(Format-TmtNumber $st.Users), $(Format-TmtNumber $st.InventoriedConversations) conversations inventoried, $(Format-TmtNumber $st.Conversations) with messages ($(Format-TmtNumber $st.Messages) messages)"
                    Write-TmtInfo "Partitions $(Format-TmtNumber $st.PartitionsUsed) used of $(Format-TmtNumber $st.Partitions), segments $(Format-TmtNumber $st.Segments) ($(Format-TmtBytes $st.SegmentBytes))"
                    Write-TmtInfo "Inventory pass: $(if ($st.InventoryState) { $st.InventoryState } else { 'never run' }); files waiting for download: $(if ($st.PendingFiles -gt 100000) { '100,000+' } else { Format-TmtNumber $st.PendingFiles })"
                    $shownLots = @($st.Lots | Where-Object { -not $Lot -or $_.Name -eq $Lot -or ($null -ne $statusLotId -and $_.Id -eq $statusLotId) })
                    if ($Lot -and -not $shownLots) { throw "Lot '$Lot' not found in the store." }
                    foreach ($l in $shownLots) {
                        $itemText = if ($l.Items -gt 0) { "$(Format-TmtNumber $l.Items) item(s) ($(($l.ItemsByState.GetEnumerator() | ForEach-Object { '{0} {1}' -f (Format-TmtNumber $_.Value), $_.Key }) -join ', '))" } else { 'no item' }
                        $j = $l.Journal
                        $jText = if ($l.Sessions -gt 0 -or ($j.Imported + $j.Conflict409 + $j.Rejected + $j.Pending + $j.Skipped) -gt 0) { "; journal $(Format-TmtNumber $j.Imported) imported, $(Format-TmtNumber $j.Conflict409) 409, $(Format-TmtNumber $j.Rejected) rejected, $(Format-TmtNumber $j.Pending) pending$(if ($j.Skipped) { ", $(Format-TmtNumber $j.Skipped) skipped" }) ($(Format-TmtNumber $l.Sessions) session(s))" } else { '' }
                        Write-TmtDetail "lot $($l.Name): $($l.State), $itemText$jText"
                    }
                    $script:counts.users = [long]$st.Users; $script:counts.conversations = [long]$st.Conversations; $script:counts.messages = [long]$st.Messages
                    $script:next = '.\Invoke-TeamsTransfer.ps1 -Mode Archive -StoreRoot ' + $(if ($script:StoreRootResolved -match '\s') { "'$($script:StoreRootResolved)'" } else { $script:StoreRootResolved })
                } else {
                    Write-TmtItem SKIP "No store at $($script:StoreRootResolved) yet."
                    $script:next = '.\Invoke-TeamsTransfer.ps1 -Mode Inventory'
                }
            }

            'Assess' {
                Write-TmtStep 'Preparing the assessment' -Number 1 -Total 3 -Icon Key
                Assert-NotStopped
                Initialize-TmtEngine
                $client = New-TmtGraphClient -Configuration $config -Side Source
                Write-TmtOk "Signed in as application $($config.Source.ClientId) on tenant $($config.Source.TenantId)"
                Write-TmtStep "Sampling the tenant ($SampleUsers users, $SampleTeams teams)" -Number 2 -Total 3 -Icon Team
                $report = Invoke-TmtAssess -Client $client -SampleUsers $SampleUsers -SampleTeams $SampleTeams -HistoryMonths $HistoryMonths -StopFile $StopFile -IntervalSeconds $IntervalSeconds
                foreach ($line in ($report.ToText() -split "`r?`n" | Where-Object { $_ })) { Write-TmtInfo $line }
                $script:counts.users = [long]$report.TotalUsers; $script:counts.sampled = [long]$report.SampledUsers
                $script:counts.chats = [long][Math]::Round($report.Chats); $script:counts.messages = [long][Math]::Round($report.Messages); $script:counts.errors = [long]$report.SampleErrors
                if ($report.SampleErrors -gt 0) { Write-TmtWarn "$(Format-TmtNumber $report.SampleErrors) sample error(s): the estimate may be low, see the log" }
                Write-TmtStep 'Writing the report' -Number 3 -Total 3 -Icon Report
                $script:reportPath = New-RunFolder
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail ($report.ToJson() | ConvertFrom-Json) -Notes @($report.ToText() -split "`r?`n"))
                [IO.File]::WriteAllText((Join-Path $script:reportPath 'TeamsTransfer_Assess.txt'), $report.ToText(), [Text.UTF8Encoding]::new($false))
                Write-TmtOk "Report written to $($script:reportPath)" -Icon Report
                if (Test-StopRequested) { $exitCode = 2 }
                $script:next = '.\Invoke-TeamsTransfer.ps1 -Mode Inventory'
            }

            'Inventory' {
                Write-TmtStep 'Opening the store' -Number 1 -Total 3 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore
                Write-TmtOk "Store $($script:StoreRootResolved) opened for writing" -Icon Store
                Write-TmtStep 'Reading the tenant' -Number 2 -Total 3 -Icon Team
                Assert-NotStopped
                $client = New-TmtGraphClient -Configuration $config -Side Source
                $r = Invoke-TmtInventory -Store $store -Client $client -Users $Users -Teams $Teams -SkipChats:$SkipChats -UserParallelism $UserParallelism -StopFile $StopFile -IntervalSeconds $IntervalSeconds
                $resultDetail = $r
                $script:counts.users = [long]$r.Users; $script:counts.chats = [long]$r.Chats; $script:counts.teams = [long]$r.Teams; $script:counts.channels = [long]$r.Channels; $script:counts.errors = [long]$r.Errors.Count
                Write-TmtOk "$(Format-TmtNumber $r.Users) users ($(Format-TmtNumber $r.DeletedUsers) deleted, $(Format-TmtNumber $r.GuestUsers) guests), $(Format-TmtNumber $r.Chats) chats, $(Format-TmtNumber $r.Teams) teams, $(Format-TmtNumber $r.Channels) channels" -Icon Chat
                if ($r.Resumed) { Write-TmtInfo 'An interrupted pass was resumed.' }
                if ($r.Errors.Count -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.Errors.Count) user(s) or team(s) could not be read, retried by the next run"; foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtDetail "$($e.Scope): $($e.ErrorCode) $($e.Message)" } }
                if ($r.Stopped -or (Test-StopRequested)) { $exitCode = 2 } elseif ($r.Errors.Count -gt 0) { $exitCode = 2 }
                Write-TmtStep 'Writing the report' -Number 3 -Total 3 -Icon Report
                $script:reportPath = New-RunFolder
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail $resultDetail)
                Write-TmtOk "Report written to $($script:reportPath)" -Icon Report
                $script:next = if ($exitCode -eq 2) { Format-RunCommand } else { ".\Invoke-TeamsTransfer.ps1 -Mode Export -StoreRoot '$($script:StoreRootResolved)'" }
            }

            'Export' {
                Write-TmtStep 'Opening the store' -Number 1 -Total 4 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore
                Write-TmtOk "Store $($script:StoreRootResolved) opened for writing" -Icon Store
                Write-TmtStep "Exporting the chats$(if ($IncludeChannels) { ' and channels' })$(if ($IncludeFiles -and -not $SkipFileDownload) { ' and their files' })" -Number 2 -Total 4 -Icon Chat
                Assert-NotStopped
                $client = New-TmtGraphClient -Configuration $config -Side Source
                $exportArgs = @{
                    Store = $store; Client = $client; Strategy = $Strategy; IncludeChannels = $IncludeChannels; SkipChats = $SkipChats; AllStoreUsers = $AllStoreUsers
                    IncludeFiles = $IncludeFiles; SkipFileDownload = $SkipFileDownload; NoHostedContents = $NoHostedContents; Full = $Full
                    UserParallelism = $UserParallelism; ConversationParallelism = $ConversationParallelism; MaxFileSizeMB = $MaxFileSizeMB
                    StopFile = $StopFile; IntervalSeconds = $IntervalSeconds
                }
                if ($Users) { $exportArgs.Users = $Users }
                if ($Teams) { $exportArgs.Teams = $Teams }
                if ($Window) { $exportArgs.Window = $Window }
                if ($null -ne $From) { $exportArgs.From = $From }
                if ($null -ne $To) { $exportArgs.To = $To }
                if ($ExcludeExtensions) { $exportArgs.ExcludeExtensions = $ExcludeExtensions }
                $lotExport = $null
                if ($Lot) {
                    # the members of the lot: users and teams (strategy U + channels), chats and channels (strategy C, one by one); the lot goes Planned -> Exporting -> Exported
                    $lotFileArgs = if ($LotFile) { @{ LotFile = $LotFile } } else { @{} }
                    $lotExport = Invoke-TmtLotExport -Store $store -Lot $Lot -ExportArguments $exportArgs @lotFileArgs
                    if ($lotExport.LotCreated) { Write-TmtInfo "Lot $Lot created from ${LotFile} (the lot did not exist)." } elseif ($LotFile) { Write-TmtInfo "Lot $Lot already exists with the members of ${LotFile}: used as it is." }
                    $lotScope = $lotExport.Scope
                    Write-TmtInfo "Lot $Lot ($($lotScope.State)): $(Format-TmtNumber @($lotScope.Users).Count) user(s), $(Format-TmtNumber @($lotScope.Teams).Count) team(s), $(Format-TmtNumber @($lotScope.ConversationKeys).Count) chat / channel member(s)"
                    foreach ($w in $lotExport.Warnings) { Write-TmtWarn $w }
                    $allResults = @($lotExport.Results)
                } else { $allResults = @(Invoke-TmtExport @exportArgs) }
                foreach ($r in $allResults) {
                $script:counts['conversations'] = [long]$script:counts['conversations'] + [long]$r.Conversations; $script:counts['messages'] = [long]$script:counts['messages'] + [long]$r.MessagesSeen; $script:counts['new'] = [long]$script:counts['new'] + [long]$r.MessagesNew
                $script:counts['updated'] = [long]$script:counts['updated'] + [long]$r.MessagesUpdated; $script:counts['errors'] = [long]$script:counts['errors'] + [long]($r.Errors.Count)
                Write-TmtOk "$(Format-TmtNumber $r.Conversations) conversations, $(Format-TmtNumber $r.MessagesSeen) messages seen ($(Format-TmtNumber $r.MessagesNew) new, $(Format-TmtNumber $r.MessagesUpdated) updated, $(Format-TmtNumber $r.MessagesUnchanged) unchanged), $(Format-TmtBytes $r.ContentBytes) of content" -Icon Chat
                if ($r.UsersGone -gt 0) { Write-TmtInfo "$(Format-TmtNumber $r.UsersGone) user account(s) no longer exist: their chats come through the other members" }
                if ($r.UnitsFailed -gt 0 -or $r.Errors.Count -gt 0) {
                    Write-TmtWarn "$(Format-TmtNumber $r.UnitsFailed) unit(s) failed, $(Format-TmtNumber $r.Errors.Count) error(s): retried by the next run"
                    foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtDetail "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                }
                $filesNote = @()
                if ($r.PSObject.Properties['Files'] -and $r.Files) {
                    $f = $r.Files
                    $script:counts.files = [long]$f.Downloaded; $script:counts.fileBytes = Format-TmtBytes $f.Bytes
                    Write-TmtOk "Files: $(Format-TmtNumber $f.Downloaded) downloaded ($(Format-TmtBytes $f.Bytes)), $(Format-TmtNumber $f.Deduplicated) already there, $(Format-TmtNumber $f.Failed) failed" -Icon File
                    if ($f.NotFound -or $f.Forbidden -or $f.TooLarge) { Write-TmtWarn "Files not copied: $(Format-TmtNumber $f.NotFound) not found, $(Format-TmtNumber $f.Forbidden) forbidden, $(Format-TmtNumber $f.TooLarge) too large" }
                    if ($f.Failed -gt 0) { $exitCode = 2 }
                    if ($f.Stopped) { $exitCode = 2 }
                }
                if ($r.Stopped -or (Test-StopRequested) -or $r.UnitsFailed -gt 0 -or $r.Errors.Count -gt 0) { $exitCode = 2 }
                }
                $resultDetail = if ($allResults.Count -eq 1) { $allResults[0] } else { @($allResults) }
                if ($lotExport -and $lotExport.StateMoved) {
                    if ($lotExport.Complete) { Write-TmtOk "Lot $Lot is now Exported" -Icon Done }
                    else { Write-TmtWarn "Lot $Lot stays Exporting: run the same command again to finish it." }
                }
                Write-TmtStep 'Checking the store' -Number 3 -Total 4 -Icon Store
                $store.Flush()
                $check = $store.Verify($false, $false)
                if ($check.Consistent) { Write-TmtOk "Store consistent: $(Format-TmtNumber $check.Messages) messages in $(Format-TmtNumber $check.Segments) segments checked" -Icon Store }
                else { foreach ($p in ($check.Problems | Select-Object -First 3)) { Write-TmtFail $p }; throw "The store check found $(Format-TmtNumber $check.Problems.Count) problem(s): see the log." }
                Write-TmtStep 'Writing the report' -Number 4 -Total 4 -Icon Report
                $script:reportPath = New-RunFolder
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail $resultDetail)
                Write-TmtOk "Report written to $($script:reportPath)" -Icon Report
                $script:next = if ($exitCode -eq 2) { Format-RunCommand } else { ".\Invoke-TeamsTransfer.ps1 -Mode Archive -StoreRoot '$($script:StoreRootResolved)'" }
            }

            'Files' {
                Write-TmtStep 'Opening the store' -Number 1 -Total 3 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore -MustExist
                Write-TmtOk "Store $($script:StoreRootResolved) opened for writing" -Icon Store
                Write-TmtStep 'Downloading the files' -Number 2 -Total 3 -Icon File
                Assert-NotStopped
                $client = New-TmtGraphClient -Configuration $config -Side Source
                $filesArgs = @{ Store = $store; Client = $client; MaxFileSizeMB = $MaxFileSizeMB; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds }
                if ($ExcludeExtensions) { $filesArgs.ExcludeExtensions = $ExcludeExtensions }
                $f = Invoke-TmtFiles @filesArgs
                $resultDetail = $f
                $script:counts.files = [long]$f.Downloaded; $script:counts.deduplicated = [long]$f.Deduplicated; $script:counts.failed = [long]$f.Failed
                Write-TmtOk "$(Format-TmtNumber $f.Downloaded) downloaded ($(Format-TmtBytes $f.Bytes)), $(Format-TmtNumber $f.Deduplicated) already there, $(Format-TmtNumber $f.Failed) failed" -Icon File
                if ($f.NotFound -or $f.Forbidden -or $f.TooLarge -or $f.Excluded) { Write-TmtWarn "Files not copied: $(Format-TmtNumber $f.NotFound) not found, $(Format-TmtNumber $f.Forbidden) forbidden, $(Format-TmtNumber $f.TooLarge) too large, $(Format-TmtNumber $f.Excluded) excluded" }
                if ($f.Stopped -or (Test-StopRequested) -or $f.Failed -gt 0) { $exitCode = 2 }
                Write-TmtStep 'Writing the report' -Number 3 -Total 3 -Icon Report
                $script:reportPath = New-RunFolder
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail $resultDetail)
                Write-TmtOk "Report written to $($script:reportPath)" -Icon Report
                $script:next = if ($exitCode -eq 2) { Format-RunCommand } else { ".\Invoke-TeamsTransfer.ps1 -Mode Archive -StoreRoot '$($script:StoreRootResolved)'" }
            }

            'Import' {
                # Import: preview by default (the exact requests are counted, nothing is sent and nothing is journaled); -Apply sends them.
                Write-TmtStep 'Checking the request' -Number 1 -Total 4 -Icon Plan
                if ($dryRun) { Write-TmtItem SKIP "Preview: nothing is written. $(if ($whatIf) { '-WhatIf wins over -Apply.' } else { 'Run it again with -Apply to make the changes.' })" }
                Assert-NotStopped
                if (-not $dryRun) {
                    if (-not $skipConfirmation) {
                        $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                        if (-not $interactive) { throw "-Apply needs a confirmation and this session is not interactive: add -Force for an unattended run." }
                        if (-not $PSCmdlet.ShouldContinue("Import lot '$Lot' creates content in the target tenant $($config.Target.TenantId); an imported conversation cannot be rolled back. Continue?", 'Teams Transfer - Apply')) { throw 'Cancelled by the operator: nothing was written.' }
                    }
                }
                if (-not $Lot) { throw '-Lot is required: name the planned lot to import (-Mode Status lists the lots).' }
                Write-TmtStep 'Opening the store and the lot' -Number 2 -Total 4 -Icon Store
                Initialize-TmtEngine
                $store = if ($dryRun) { Open-RunStore -ReadOnly } else { Open-RunStore -MustExist }
                Write-TmtOk "Store $($script:StoreRootResolved) opened $(if ($dryRun) { 'read-only' } else { 'for writing (the import journal lives there)' })" -Icon Store
                $lotInfo = $store.GetLot($Lot)
                if ($null -eq $lotInfo) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
                if ([string]$lotInfo.State -notin 'ImportPlanned', 'Ghosts', 'Files', 'Importing', 'Completing', 'Verified') {
                    throw "Lot '$Lot' is $($lotInfo.State): the import needs a planned lot (state ImportPlanned). Run -Mode Plan first; a plan with blockers never reaches that state."
                }
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run -Mode Plan first.' }
                $importSlices = if ($PSBoundParameters.ContainsKey('Slices')) { @($Slices) } else { @() }
                $lotItems = @($store.ListItems($lotInfo.Id) | Where-Object { -not $importSlices -or [int]$_.SliceNo -in $importSlices })
                Write-TmtInfo "Lot $Lot ($($lotInfo.State)): $(Format-TmtNumber $lotItems.Count) item(s) (conversation x slice)$(if ($importSlices) { ", slice(s) $($importSlices -join ',')" })"
                $script:counts.items = [long]$lotItems.Count
                $importArgs = @{ Store = $store; Lot = $Lot; Configuration = $config; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds }
                if ($importSlices) { $importArgs.Slices = [int[]]$importSlices }
                $importArgs.ConversationParallelism = $ConversationParallelism      # Import default: 32 (see $parallelismDefaults)
                if ($ServiceAccount) { $importArgs.ServiceAccount = $ServiceAccount }
                $report = New-RunFolder
                $script:reportPath = $report
                if ($dryRun) {
                    Write-TmtStep 'Previewing the import (no request is sent)' -Number 3 -Total 4 -Icon Plan
                    Assert-NotStopped
                    $r = Invoke-TmtImport @importArgs
                    $resultDetail = $r
                    $d = $r.DryRun
                    $script:counts.messages = [long]$d.MessagesToImport; $script:counts.requests = [long]$d.TotalRequests; $script:counts.conversationsToCreate = [long]$d.ConversationsToCreate
                    Write-TmtOk "$(Format-TmtNumber $d.MessagesToImport) message(s) to import, $(Format-TmtNumber $d.MessagesSkipped) skipped (system events, deleted), $(Format-TmtNumber $d.MessagesRejected) without a usable author; $(Format-TmtNumber $d.TotalRequests) request(s), $(Format-TmtNumber $d.ConversationsToCreate) conversation(s) to create" -Icon Chat
                    foreach ($k in $d.RequestsByEndpoint.Keys) { Write-TmtDetail ('{0,12}  {1}' -f (Format-TmtNumber $d.RequestsByEndpoint[$k]), $k) }
                    foreach ($k in $d.DroppedByReason.Keys) { Write-TmtDetail ('{0,12}  dropped: {1}' -f (Format-TmtNumber $d.DroppedByReason[$k]), $k) }
                    if ($d.FilesToCopy) { Write-TmtInfo "$(Format-TmtNumber $d.FilesToCopy) file(s) ($(Format-TmtBytes $d.FileBytesToCopy)) would be copied to the target, conversation by conversation, right before their messages" }
                    Write-TmtInfo "Estimated duration $(Format-TmtDuration $d.EstimatedDuration.TotalSeconds) at the measured rates (5 msg/s per conversation, about 75 msg/s per application)"
                    if ($r.ItemsFailed -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.ItemsFailed) item(s) cannot be imported as planned (no target): see conversations.csv and run -Mode Plan again" }
                    $exitCode = 0
                    $script:next = ".\Invoke-TeamsTransfer.ps1 -Mode Import -StoreRoot '$($script:StoreRootResolved)' -Lot '$Lot' -Apply"
                } else {
                    Write-TmtStep 'Importing into the target tenant' -Number 3 -Total 4 -Icon Chat
                    Assert-NotStopped
                    $r = Invoke-TmtImport @importArgs -Apply
                    $resultDetail = $r
                    $script:counts.imported = [long]$r.MessagesImported; $script:counts.already = [long]$r.MessagesConflict409; $script:counts.rejected = [long]$r.MessagesRejectedTotal
                    $script:counts.skipped = [long]$r.MessagesSkipped; $script:counts.items = [long]$r.ItemsTotal; $script:counts.completed = [long]$r.ItemsCompleted
                    Write-TmtOk "$(Format-TmtNumber $r.MessagesImported) message(s) imported ($(Format-TmtNumber $r.MessagesConflict409) already there), $(Format-TmtNumber $r.MessagesSkipped) skipped, $(Format-TmtNumber $r.MessagesRejectedTotal) rejected; $(Format-TmtNumber $r.MessagesPerSecond) msg/s" -Icon Chat
                    if ($r.FilesCopied -or $r.FilesFailed) { Write-TmtInfo "Files copied inline: $(Format-TmtNumber $r.FilesCopied) ($(Format-TmtBytes $r.FileBytesCopied)), $(Format-TmtNumber $r.FilesFailed) failed (their attachments were dropped)" }
                    Write-TmtInfo "Items: $(Format-TmtNumber $r.ItemsCompleted) completed, $(Format-TmtNumber $r.ItemsIncomplete) incomplete, $(Format-TmtNumber $r.ItemsFailed) failed, $(Format-TmtNumber $r.ItemsUncertain) uncertain"
                    if ($r.Throttled429 -or $r.Throttled503) { Write-TmtDetail "Throttled by the service: 429 x $(Format-TmtNumber $r.Throttled429), 503 x $(Format-TmtNumber $r.Throttled503) (Retry-After is honoured)" }
                    foreach ($s in $r.Slowest | Select-Object -First 3) { Write-TmtDetail "slowest: $($s.ConversationKey) $(Format-TmtNumber ($s.Imported + $s.Conflicts)) msg in $(Format-TmtDuration $s.Seconds)" }
                    foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                    if ($r.MessagesRejectedTotal -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.MessagesRejectedTotal) message(s) were rejected by the service: see rejected.csv" }
                    if ($r.ItemsUncertain -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.ItemsUncertain) conversation(s) are in an uncertain state (completeMigration not confirmed): run the same command again" }
                    $exitCode = Get-TmtImportExitCode -Result $r
                    if ($r.Stopped -or (Test-StopRequested)) { $exitCode = [Math]::Max($exitCode, 2) }
                    $script:next = if ($exitCode -in 2, 3) { Format-RunCommand } else { ".\Invoke-TeamsTransfer.ps1 -Mode Verify -StoreRoot '$($script:StoreRootResolved)' -Lot '$Lot'" }
                }
                Write-TmtStep 'Writing the report' -Number 4 -Total 4 -Icon Report
                [void](Write-TmtImportReport -Result $r -Folder $report -Store $store)
                Write-TmtOk "Report written to $report (summary.html, conversations.csv, rejected.csv)" -Icon Report
            }

            'Plan' {
                Write-TmtStep 'Opening the store' -Number 1 -Total 5 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore -MustExist
                Write-TmtOk "Store $($script:StoreRootResolved) opened for writing (the plan writes the maps and the import journal there, never a tenant)" -Icon Store
                Write-TmtStep 'Connecting to the target tenant (read only)' -Number 2 -Total 5 -Icon Key
                Assert-NotStopped
                $planClient = $null
                if ($SkipTargetLookup) { Write-TmtItem SKIP 'Offline plan (-SkipTargetLookup): the target tenant is not looked up.' }
                else {
                    $planClient = New-TmtGraphClient -Configuration $config -Side Target
                    Write-TmtOk "Signed in as application $($config.Target.ClientId) on tenant $($config.Target.TenantId) (read only)"
                }
                $sliceNumbers = @($Slices | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_ -notmatch '^[1-4]$') { throw "-Slices '$_': expected 1, 2, 3 or 4 (one or more, comma separated)." }; [int]$_ })
                Write-TmtStep "Planning the import ($Scenario, slice $($sliceNumbers -join ','))" -Number 3 -Total 5 -Icon Plan
                Assert-NotStopped
                $script:reportPath = New-RunFolder
                $planArgs = @{
                    Store = $store; Scenario = $Scenario; Slices = [int[]]$sliceNumbers; DeletedAuthors = $DeletedAuthors; GhostThreshold = $GhostThreshold; ConfirmGhostCount = $ConfirmGhostCount
                    ArchiveTeamPrefix = $ArchiveTeamPrefix; ChannelsPerArchiveTeam = $ChannelsPerArchiveTeam; OutputFolder = $script:reportPath; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds
                }
                if ($planClient) { $planArgs.Client = $planClient } else { $planArgs.Offline = $true }
                if ($Lot) { $planArgs.Lot = $Lot }
                if ($Users) { $planArgs.Users = $Users }
                if ($Teams) { $planArgs.Teams = $Teams }
                if ($LotFile) { $planArgs.LotFile = $LotFile }
                if ($Window) { $planArgs.Window = $Window }
                $planArgs.Configuration = $config      # the service account: parameter, then Target.ServiceAccountUserId, then plan checkpoint, then map
                if ($IdentityMap) { $planArgs.IdentityMap = $IdentityMap }
                if ($TeamMap) { $planArgs.TeamMap = $TeamMap }
                if ($DomainMap) { $planArgs.DomainMap = $DomainMap }
                if ($ServiceAccount) { $planArgs.ServiceAccount = $ServiceAccount }
                # Same ghost settings as the Ghosts stage (parameter first, then the Ghosts section of the configuration), so that
                # the plan announces exactly the accounts that will be created (UPN and display name).
                if ($GhostDomain) { $planArgs.GhostDomain = $GhostDomain }
                elseif ($config.ContainsKey('Ghosts') -and $config.Ghosts.DomainName) { $planArgs.GhostDomain = [string]$config.Ghosts.DomainName }
                if ($config.ContainsKey('Ghosts') -and $config.Ghosts.DisplayNameFormat) { $planArgs.GhostDisplayNameFormat = [string]$config.Ghosts.DisplayNameFormat }
                if ($ArchiveOwners) { $planArgs.ArchiveOwners = $ArchiveOwners }
                $planned = New-TmtImportPlan @planArgs
                $pl = $planned.Plan
                $resultDetail = $pl
                if ($planned.Created) { Write-TmtInfo "Lot $($planned.LotName) created over the users, teams and lot file given (the store is used as it is)." }
                elseif ($Users -or $Teams -or $LotFile) { Write-TmtInfo "Lot $($planned.LotName) already exists with these members: used as it is." }
                Write-TmtOk "$(Format-TmtNumber $pl.Conversations) conversations, $(Format-TmtNumber $pl.Messages) messages to import ($(Format-TmtNumber $pl.MessagesSkipped) not importable) in lot $($pl.LotName)" -Icon Chat
                Write-TmtStep 'Checking the plan' -Number 4 -Total 5 -Icon Plan
                Write-TmtInfo "Targets: $(Format-TmtNumber $pl.NewChats) new chats, $(Format-TmtNumber $pl.ExistingChats) existing chats, $(Format-TmtNumber $pl.NewChannels) new channels, $(Format-TmtNumber $pl.ExistingChannels) existing channels, $(Format-TmtNumber $pl.ArchiveChannels) archive channels"
                Write-TmtInfo "Identities: $(Format-TmtNumber $pl.GhostsToCreate) ghosts to create, $(Format-TmtNumber $pl.ServiceAccountAuthors) on the service account, $(Format-TmtNumber $pl.UnresolvedIdentities) unresolved"
                Write-TmtInfo "Files: $(Format-TmtNumber $pl.FilesToCopy) to copy ($(Format-TmtBytes $pl.FileBytesToCopy)); estimated import duration $(Format-TmtDuration $pl.EstimatedDuration.TotalSeconds)"
                foreach ($w in ($pl.Warnings | Select-Object -First 10)) { Write-TmtWarn $w }
                if ($pl.Warnings.Count -gt 10) { Write-TmtDetail "$(Format-TmtNumber ($pl.Warnings.Count - 10)) more warning(s): see plan.html" }
                foreach ($b in $pl.Blockers) { Write-TmtFail "Blocker: $b" }
                $script:counts.conversations = [long]$pl.Conversations; $script:counts.messages = [long]$pl.Messages; $script:counts.ghosts = [long]$pl.GhostsToCreate
                $script:counts.unresolved = [long]$pl.UnresolvedIdentities; $script:counts.files = [long]$pl.FilesToCopy; $script:counts.blockers = [long]$pl.Blockers.Count
                Write-TmtStep 'Writing the report' -Number 5 -Total 5 -Icon Report
                $notes = @($pl.Blockers | ForEach-Object { "BLOCKER: $_" }) + @($pl.Warnings | ForEach-Object { "Warning: $_" })
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail $resultDetail -Notes $notes)
                Write-TmtOk "Plan written to $($script:reportPath) (plan.html, plan.json, conversations.csv, identities.csv, ghosts.csv, issues.csv)" -Icon Report
                if ($pl.IsBlocked) {
                    $exitCode = 3
                    $failure = "The plan has $($pl.Blockers.Count) blocker(s): fix them (see issues.csv) and plan again; nothing was written to any tenant."
                    $script:next = Format-RunCommand
                } else {
                    $script:next = ".\Invoke-TeamsTransfer.ps1 -Mode Import -StoreRoot '$($script:StoreRootResolved)' -Lot '$($planned.LotName)'"
                }
            }

            'Archive' {                Write-TmtStep 'Opening the store' -Number 1 -Total 2 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore -ReadOnly
                Write-TmtOk "Store $($script:StoreRootResolved) opened read-only" -Icon Store
                Write-TmtStep 'Writing the archive' -Number 2 -Total 2 -Icon Report
                if (-not $OutputPath) {
                    $runFolder = New-RunFolder
                    $OutputPath = if ($SingleFile) { Join-Path $runFolder 'TeamsTransfer_Archive.html' } else { Join-Path $runFolder 'archive' }
                }
                $archiveArgs = @{ Store = $store; OutputPath = $OutputPath; SingleFile = $SingleFile; Language = $Language; IntervalSeconds = $IntervalSeconds }
                if ($Users) { $archiveArgs.Users = $Users }
                if ($Teams) { $archiveArgs.Teams = $Teams }
                if ($Conversation) { $archiveArgs.Conversation = $Conversation }
                if ($Viewer) { $archiveArgs.Viewer = $Viewer }
                if ($Title) { $archiveArgs.Title = $Title }
                if ($Window) { $archiveArgs.Window = $Window }
                if ($null -ne $From) { $archiveArgs.From = $From }
                if ($null -ne $To) { $archiveArgs.To = $To }
                $r = Export-TmtArchive @archiveArgs
                $resultDetail = $r
                $script:counts.conversations = [long]$r.Conversations; $script:counts.messages = [long]$r.Messages; $script:counts.files = [long]$r.FilesExported; $script:counts.images = [long]$r.Images
                Write-TmtOk "$(Format-TmtNumber $r.Conversations) conversations, $(Format-TmtNumber $r.Messages) messages, $(Format-TmtNumber $r.Images) images, $(Format-TmtNumber $r.FilesExported) of $(Format-TmtNumber $r.Files) files; $(Format-TmtBytes $r.OutputBytes) in $(Format-TmtDuration $r.Seconds)" -Icon Report
                $script:reportPath = $r.OutputPath
                $open = if ($r.Mode -match 'single' -or $SingleFile) { $r.OutputPath } else { Join-Path $r.OutputPath 'index.html' }
                $script:next = "Open $open in a browser (no network needed)"
            }

            'Ghosts' {
                # Ghost accounts of the deleted authors: preview by default (reads the target, writes nothing); -Apply creates them (or, with -Remove, deletes them).
                Write-TmtStep 'Checking the request' -Number 1 -Total 5 -Icon Plan
                if ($dryRun) { Write-TmtItem SKIP "Preview: nothing is written. $(if ($whatIf) { '-WhatIf wins over -Apply.' } else { 'Run it again with -Apply to make the changes.' })" }
                if ($Purge -and -not $Remove) { throw '-Purge goes with -Remove (it purges the removed ghosts from the recycle bin).' }
                Assert-NotStopped
                Write-TmtStep 'Opening the store' -Number 2 -Total 5 -Icon Store
                Initialize-TmtEngine
                $store = if ($dryRun) { Open-RunStore -ReadOnly } else { Open-RunStore -MustExist }
                Write-TmtOk "Store $($script:StoreRootResolved) opened $(if ($dryRun) { 'read-only' } else { 'for writing (the ghost catalog and the identity map live there)' })" -Icon Store
                if (-not ($store -is [TeamsTransfer.IIdentityMap])) { throw 'The store holds no identity map: run -Mode Plan first.' }
                if ($Lot -and $null -eq $store.GetLot($Lot)) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
                Write-TmtStep "Connecting to the target tenant$(if ($dryRun) { ' (read only)' })" -Number 3 -Total 5 -Icon Key
                Assert-NotStopped
                $ghostClient = New-TmtGraphClient -Configuration $config -Side Target
                Write-TmtOk "Signed in as application $($config.Target.ClientId) on tenant $($config.Target.TenantId)"
                $report = New-RunFolder
                $script:reportPath = $report
                $ghostArgs = @{ Store = $store; Client = $ghostClient; Configuration = $config; Apply = (-not $dryRun); ReportFolder = $report; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds; Parallelism = $UserParallelism }
                if ($PSBoundParameters.ContainsKey('GhostThreshold')) { $ghostArgs.GhostThreshold = $GhostThreshold }
                if ($ConfirmGhostCount) { $ghostArgs.ConfirmGhostCount = $true }
                if ($GhostDomain) { $ghostArgs.GhostDomain = $GhostDomain }
                if ($ServiceAccount) { $ghostArgs.ServiceAccount = $ServiceAccount }
                if ($CreateTrackingGroup) { $ghostArgs.CreateTrackingGroup = $true }
                if ($UsageLocation) { $ghostArgs.UsageLocation = $UsageLocation }
                if ($Remove) { $ghostArgs.Remove = $true }
                if ($Purge) { $ghostArgs.Purge = $true }
                if ($Users) { $ghostArgs.Users = $Users }
                if ($Lot) { $ghostArgs.Lot = $Lot; $ghostArgs.AdvanceLot = $true }
                Write-TmtStep $(if ($Remove) { if ($dryRun) { 'Previewing the removal of the ghost accounts' } else { 'Removing the ghost accounts' } } elseif ($dryRun) { 'Previewing the ghost accounts' } else { 'Creating the ghost accounts' }) -Number 4 -Total 5 -Icon Team
                Assert-NotStopped
                if (-not $dryRun -and -not $skipConfirmation) {
                    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                    if (-not $interactive) { throw "-Apply needs a confirmation and this session is not interactive: add -Force for an unattended run." }
                    $what = if ($Remove) { 'DELETES the ghost accounts recorded in the catalog from' } else { 'creates disabled, unlicensed ghost accounts in' }
                    if (-not $PSCmdlet.ShouldContinue("Ghosts $what the target tenant $($config.Target.TenantId). Continue?", 'Teams Transfer - Apply')) { throw 'Cancelled by the operator: nothing was written.' }
                }
                $r = Invoke-TmtGhosts @ghostArgs
                $resultDetail = $r
                $script:counts.candidates = [long]$r.Candidates
                if ($Remove) {
                    $script:counts.removed = [long]$r.Removed; $script:counts.refused = [long]$r.Refused; $script:counts.failed = [long]$r.Failed
                    Write-TmtOk "$(Format-TmtNumber $r.Candidates) ghost(s) in the catalog: $(Format-TmtNumber $r.Removed) $(if ($r.DryRun) { 'would be removed' } else { 'removed' }), $(Format-TmtNumber $r.Refused) refused (not identified as ghosts), $(Format-TmtNumber $r.Failed) failed" -Icon Team
                } else {
                    if ($r.DryRun) { $script:counts.toCreate = [long]$r.ToCreate } else { $script:counts.created = [long]$r.Created }
                    $script:counts.linked = [long]$r.LinkedExisting; $script:counts.fallback = [long]$r.FallbackToServiceAccount; $script:counts.reactivated = [long]$r.Reactivated; $script:counts.failed = [long]$r.Failed
                    Write-TmtOk "$(Format-TmtNumber $r.Candidates) identit(ies) to place: $(Format-TmtNumber $(if ($r.DryRun) { $r.ToCreate } else { $r.Created })) ghost account(s) $(if ($r.DryRun) { 'would be created' } else { 'created' }), $(Format-TmtNumber $r.LinkedExisting) already existed, $(Format-TmtNumber $r.FallbackToServiceAccount) on the service account, $(Format-TmtNumber $r.Failed) failed" -Icon Team
                    if ($r.TrackingGroupCreated) { Write-TmtInfo 'The tracking group was created in the target tenant.' }
                }
                foreach ($b in $r.Blockers) { Write-TmtFail "Blocker: $b" }
                foreach ($g in ($r.ReactivatedGhosts | Select-Object -First 5)) { Write-TmtWarn "Reactivated ghost $($g.UserPrincipalName): it is enabled and must be disabled again" }
                foreach ($w in $r.Warnings) { Write-TmtWarn $w }
                foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                if ($r.IsBlocked) { $failure = "The ghost stage is blocked ($($r.Blockers.Count) blocker(s)): nothing was written to the target tenant." }
                if ($r.IsBlocked -or $r.Reactivated -gt 0) { $exitCode = 3 }
                elseif ($r.Stopped -or (Test-StopRequested) -or $r.Failed -gt 0 -or $r.GroupMembershipFailed -gt 0) { $exitCode = 2 }
                Write-TmtStep 'Writing the report' -Number 5 -Total 5 -Icon Report
                $notes = @($r.Blockers | ForEach-Object { "BLOCKER: $_" }) + @($r.Warnings | ForEach-Object { "Warning: $_" })
                [void](Save-RunReport -Folder $report -Counts $script:counts -Detail $resultDetail -Notes $notes)
                [void]$store.ExportGhostsCsv((Join-Path $report 'ghosts-catalog.csv'))
                Write-TmtOk "Report written to $report (ghosts.csv: the plan of this run, ghosts-catalog.csv: the catalog; no password is ever written)" -Icon Report
                $lotText = if ($Lot) { " -Lot '$Lot'" } else { '' }
                $script:next = if ($exitCode -in 2, 3) { Format-RunCommand } elseif ($dryRun) { ((Format-RunCommand) -replace ' -WhatIf', '') + ' -Apply' } else { ".\Invoke-TeamsTransfer.ps1 -Mode CopyFiles -StoreRoot '$($script:StoreRootResolved)'$lotText" }
            }

            'CopyFiles' {
                # Copy of the exported files into the target tenant: preview by default (no request at all); -Apply uploads and shares them.
                Write-TmtStep 'Checking the request' -Number 1 -Total 5 -Icon Plan
                if ($dryRun) { Write-TmtItem SKIP "Preview: nothing is written, the target tenant is not contacted. $(if ($whatIf) { '-WhatIf wins over -Apply.' } else { 'Run it again with -Apply to copy the files.' })" }
                Assert-NotStopped
                Write-TmtStep 'Opening the store' -Number 2 -Total 5 -Icon Store
                Initialize-TmtEngine
                $store = if ($dryRun) { Open-RunStore -ReadOnly } else { Open-RunStore -MustExist }
                Write-TmtOk "Store $($script:StoreRootResolved) opened $(if ($dryRun) { 'read-only' } else { 'for writing (the file copy records live there)' })" -Icon Store
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run -Mode Plan first.' }
                if ($Lot) {
                    $copyLot = $store.GetLot($Lot)
                    if ($null -eq $copyLot) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
                    Write-TmtInfo "Lot $Lot ($($copyLot.State))"
                }
                Write-TmtStep 'Connecting to the target tenant' -Number 3 -Total 5 -Icon Key
                Assert-NotStopped
                $copyClient = $null
                if ($dryRun) { Write-TmtItem SKIP 'Preview: not needed.' }
                else {
                    $copyClient = New-TmtGraphClient -Configuration $config -Side Target
                    Write-TmtOk "Signed in as application $($config.Target.ClientId) on tenant $($config.Target.TenantId)"
                }
                $report = New-RunFolder
                $script:reportPath = $report
                $copyArgs = @{ Store = $store; Configuration = $config; Apply = (-not $dryRun); ReportFolder = $report; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds; Parallelism = $FileParallelism; ChunkSizeMB = $ChunkSizeMB; MaxFileSizeMB = $MaxFileSizeMB }
                if ($copyClient) { $copyArgs.Client = $copyClient }
                if ($NoShare) { $copyArgs.NoShare = $true }
                if ($ExcludeExtensions) { $copyArgs.ExcludeExtensions = $ExcludeExtensions }
                if ($ServiceAccount) { $copyArgs.ServiceAccount = $ServiceAccount }
                if ($Lot) { $copyArgs.Lot = $Lot; $copyArgs.AdvanceLot = $true }
                if ($PSBoundParameters.ContainsKey('Slices')) { $copyArgs.Slices = [int[]]$Slices }
                Write-TmtStep $(if ($dryRun) { 'Previewing the file copy' } else { 'Copying the files' }) -Number 4 -Total 5 -Icon File
                Assert-NotStopped
                if (-not $dryRun -and -not $skipConfirmation) {
                    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                    if (-not $interactive) { throw "-Apply needs a confirmation and this session is not interactive: add -Force for an unattended run." }
                    if (-not $PSCmdlet.ShouldContinue("CopyFiles uploads files into OneDrive and the channel libraries of the target tenant $($config.Target.TenantId) and shares them. Continue?", 'Teams Transfer - Apply')) { throw 'Cancelled by the operator: nothing was written.' }
                }
                $r = Invoke-TmtFileCopy @copyArgs
                $resultDetail = $r
                $script:counts.files = [long]$r.Files
                if ($r.DryRun) {
                    $script:counts.bytes = Format-TmtBytes $r.Bytes
                    Write-TmtOk "$(Format-TmtNumber $r.Files) file(s) in scope, $(Format-TmtBytes $r.Bytes) to upload, $(Format-TmtNumber $r.AlreadyDone) already copied, $(Format-TmtNumber $r.Skipped) excluded" -Icon File
                    foreach ($d in ($r.Destinations | Sort-Object Bytes -Descending | Select-Object -First 10)) { Write-TmtDetail ('{0,12}  {1}  {2} file(s){3}' -f (Format-TmtBytes $d.Bytes), $d.Destination, (Format-TmtNumber $d.Files), $(if ($d.Duplicates) { ", $(Format-TmtNumber $d.Duplicates) duplicate(s)" } else { '' })) }
                    if ($r.Destinations.Count -gt 10) { Write-TmtDetail "$(Format-TmtNumber ($r.Destinations.Count - 10)) more destination(s): see filecopy.csv" }
                } else {
                    $script:counts.uploaded = [long]$r.Uploaded; $script:counts.reused = [long]$r.Reused; $script:counts.shared = [long]$r.Shared; $script:counts.skipped = [long]$r.Skipped; $script:counts.failed = [long]$r.Failed
                    $script:counts.bytes = Format-TmtBytes $r.Bytes
                    Write-TmtOk "$(Format-TmtNumber $r.Uploaded) uploaded ($(Format-TmtBytes $r.Bytes), $(Format-TmtBytes $r.BytesPerSecond)/s), $(Format-TmtNumber $r.Reused) reused, $(Format-TmtNumber $r.Shared) shared, $(Format-TmtNumber $r.Skipped) skipped, $(Format-TmtNumber $r.AlreadyDone) already done, $(Format-TmtNumber $r.Failed) failed" -Icon File
                }
                if ($r.WaitingForTarget -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.WaitingForTarget) file(s) wait for a target channel that does not exist yet: run -Mode CopyFiles again after the conversations are created" }
                if ($r.NoDestination -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.NoDestination) file(s) have no destination (sender not mapped and no service account): see filecopy-errors.csv" }
                if ($r.SharingIncomplete -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.SharingIncomplete) file(s) are uploaded but not shared yet: run the same command again" }
                if ($r.RecipientsRefused -gt 0) { Write-TmtInfo "$(Format-TmtNumber $r.RecipientsRefused) recipient(s) were refused by the service (guests, disabled accounts)" }
                if ($r.NotDownloaded -gt 0) { Write-TmtInfo "$(Format-TmtNumber $r.NotDownloaded) file(s) were not downloaded from the source (not found, forbidden, too large): they stay links" }
                foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                if (-not $r.DryRun -and ($r.Stopped -or (Test-StopRequested) -or $r.Failed -gt 0 -or $r.WaitingForTarget -gt 0 -or $r.SharingIncomplete -gt 0 -or $r.NoDestination -gt 0)) { $exitCode = 2 }
                Write-TmtStep 'Writing the report' -Number 5 -Total 5 -Icon Report
                [void](Save-RunReport -Folder $report -Counts $script:counts -Detail $resultDetail -Notes @($r.Warnings))
                Write-TmtOk "Report written to $report (filecopy.csv$(if ($r.Errors.Count -gt 0) { ', filecopy-errors.csv' }))" -Icon Report
                $lotText = if ($Lot) { " -Lot '$Lot'" } else { '' }
                $script:next = if ($exitCode -eq 2) { Format-RunCommand } elseif ($dryRun) { ((Format-RunCommand) -replace ' -WhatIf', '') + ' -Apply' } else { ".\Invoke-TeamsTransfer.ps1 -Mode Import -StoreRoot '$($script:StoreRootResolved)'$lotText -Apply" }
            }

            'Verify' {
                if (-not $Lot) { throw '-Lot is required: name the imported lot to verify (-Mode Status lists the lots).' }
                Write-TmtStep 'Opening the store and the lot' -Number 1 -Total 4 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = if ($NoLotUpdate) { Open-RunStore -ReadOnly } else { Open-RunStore -MustExist }
                Write-TmtOk "Store $($script:StoreRootResolved) opened $(if ($NoLotUpdate) { 'read-only (-NoLotUpdate)' } else { 'for writing (the lot state and the results are saved there)' })" -Icon Store
                $lotInfo = $store.GetLot($Lot)
                if ($null -eq $lotInfo) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run -Mode Plan and -Mode Import first.' }
                Write-TmtInfo "Lot $Lot ($($lotInfo.State))$(if ($PSBoundParameters.ContainsKey('Slices')) { ", slice(s) $($Slices -join ',')" })"
                Write-TmtStep 'Connecting to the target tenant (read only)' -Number 2 -Total 4 -Icon Key
                Assert-NotStopped
                $verifyClient = New-TmtGraphClient -Configuration $config -Side Target
                Write-TmtOk "Signed in as application $($config.Target.ClientId) on tenant $($config.Target.TenantId) (read only)"
                Write-TmtStep 'Verifying the target conversation by conversation' -Number 3 -Total 4 -Icon Chat
                Assert-NotStopped
                $verifyArgs = @{ Store = $store; Client = $verifyClient; Configuration = $config; Lot = $Lot; SampleSize = $SampleSize; StopFile = $StopFile; IntervalSeconds = $IntervalSeconds; ConversationParallelism = $ConversationParallelism; Strict = $StrictCounts; AllowExtra = $AllowExtra; NoLotUpdate = $NoLotUpdate }
                if ($PSBoundParameters.ContainsKey('Slices')) { $verifyArgs.Slices = [int[]]$Slices }
                if ($PSBoundParameters.ContainsKey('Scenario')) { $verifyArgs.Scenario = $Scenario }
                if ($ServiceAccount) { $verifyArgs.ServiceAccount = $ServiceAccount }
                $report = New-RunFolder
                $script:reportPath = $report
                $verifyArgs.ReportFolder = $report
                $r = Invoke-TmtVerify @verifyArgs
                $resultDetail = $r
                $script:counts.conversations = [long]$r.Items.Count; $script:counts.ok = [long]$r.Ok; $script:counts.mismatch = [long]$r.Mismatch; $script:counts.missing = [long]$r.Missing; $script:counts.notCompleted = [long]$r.NotCompleted; $script:counts.unverified = [long]$r.Unverified
                Write-TmtOk "$(Format-TmtNumber $r.Items.Count) conversation-slice(s): $(Format-TmtNumber $r.Ok) OK, $(Format-TmtNumber $r.Mismatch) mismatch, $(Format-TmtNumber $r.Missing) missing, $(Format-TmtNumber $r.NotCompleted) not completed, $(Format-TmtNumber $r.Unverified) unverified (target not readable); $(Format-TmtNumber $r.SourceMessages) source / $(Format-TmtNumber $r.TargetMessages) target message(s)" -Icon Chat
                foreach ($i in ($r.Items | Where-Object { [string]$_.Outcome -ne 'OK' } | Select-Object -First 8)) { Write-TmtWarn "$($i.ConversationKey) slice $($i.SliceNo): $($i.Outcome) - $($i.Detail)" }
                if ($r.Errors.Count -gt 0) { foreach ($e in ($r.Errors | Select-Object -First 3)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" } }
                if ($r.LotStateAfter -ne $r.LotStateBefore) { Write-TmtOk "Lot $Lot is now $($r.LotStateAfter) ($(Format-TmtNumber $r.ItemsSetVerified) item(s) set Verified)" -Icon Done }
                elseif ($r.AllOk -and $NoLotUpdate) { Write-TmtInfo 'Everything is OK; the lot was left as it is (-NoLotUpdate).' }
                if ($r.Mismatch -gt 0 -or $r.Missing -gt 0) { $exitCode = 3; $failure = "$(Format-TmtNumber ($r.Mismatch + $r.Missing)) conversation-slice(s) do not match the source: see verify.csv." }
                elseif ($r.NotCompleted -gt 0 -or $r.Unverified -gt 0 -or (Test-StopRequested)) { $exitCode = 2 }
                Write-TmtStep 'Writing the report' -Number 4 -Total 4 -Icon Report
                [void](Save-RunReport -Folder $report -Counts $script:counts -Detail ([pscustomobject]@{ Lot = $r.LotName; Ok = $r.Ok; Mismatch = $r.Mismatch; Missing = $r.Missing; NotCompleted = $r.NotCompleted; Unverified = $r.Unverified; SourceMessages = $r.SourceMessages; TargetMessages = $r.TargetMessages; LotStateBefore = [string]$r.LotStateBefore; LotStateAfter = [string]$r.LotStateAfter }) -Notes @($r.ToText()))
                Write-TmtOk "Report written to $report (verify.html, verify.csv, verify-summary.txt)" -Icon Report
                $script:next = if ($exitCode -in 2, 3) { Format-RunCommand } else { ".\Invoke-TeamsTransfer.ps1 -Mode Report -StoreRoot '$($script:StoreRootResolved)' -Lot '$Lot'" }
            }

            'Merge' {
                Write-TmtStep 'Checking the two stores' -Number 1 -Total 4 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $theirs = [TeamsTransfer.TmtStore]::PeekPartitions($script:FromStoreResolved)
                if ($theirs -le 0 -or -not (Test-Path -LiteralPath (Join-Path $script:FromStoreResolved 'catalog.db'))) { throw "No store at $($script:FromStoreResolved) (-FromStore): give the root folder of the other store, the one that holds catalog.db." }
                $mine = [TeamsTransfer.TmtStore]::PeekPartitions($script:StoreRootResolved)
                if ($mine -gt 0 -and $mine -ne $theirs) { throw "The two stores do not have the same number of partitions: $($script:StoreRootResolved) has $mine, $($script:FromStoreResolved) has $theirs. Stores can only be merged when they were created with the same Store.Partitions." }
                Write-TmtOk "Other store $($script:FromStoreResolved): $theirs partition(s), opened read-only (it is never modified)" -Icon Store
                $store = Open-TmtStore -Root $script:StoreRootResolved -Partitions $theirs
                Write-TmtOk "Store $($script:StoreRootResolved) opened for writing$(if ($mine -le 0) { " (created with $theirs partition(s), like the other store)" })" -Icon Store
                Write-TmtStep 'Merging' -Number 2 -Total 4 -Icon Chat
                Assert-NotStopped
                $r = Merge-TmtStore -Store $store -FromStore $script:FromStoreResolved
                $resultDetail = $r
                $script:counts.users = [long]$r.Users; $script:counts.conversations = [long]$r.Conversations; $script:counts.messagesNew = [long]$r.MessagesNew; $script:counts.messagesUpdated = [long]$r.MessagesUpdated
                $script:counts.messagesUnchanged = [long]$r.MessagesUnchanged; $script:counts.files = [long]$r.Files; $script:counts.contentCopied = [long]$r.ContentCopied; $script:counts.contentPresent = [long]$r.ContentPresent
                Write-TmtOk "$(Format-TmtNumber $r.MessagesNew) message(s) new, $(Format-TmtNumber $r.MessagesUpdated) updated, $(Format-TmtNumber $r.MessagesUnchanged) unchanged, from $(Format-TmtNumber $r.PartitionsMerged) partition(s)" -Icon Chat
                Write-TmtInfo "Catalog rows seen: $(Format-TmtNumber $r.Users) user(s), $(Format-TmtNumber $r.Conversations) conversation(s), $(Format-TmtNumber $r.Links) link(s), $(Format-TmtNumber $r.Files) file record(s), $(Format-TmtNumber $r.HostedContents) hosted content(s), $(Format-TmtNumber $r.Checkpoints) checkpoint(s), $(Format-TmtNumber $r.Authors) author(s), $(Format-TmtNumber $r.Ghosts) ghost(s)"
                Write-TmtInfo "Content blobs: $(Format-TmtNumber $r.ContentCopied) copied, $(Format-TmtNumber $r.ContentPresent) already here"
                if ($r.MessagesNew -eq 0 -and $r.MessagesUpdated -eq 0 -and $r.ContentCopied -eq 0) { Write-TmtInfo 'Nothing new: this store already holds the messages and the files of the other store (a second run changes nothing).' }
                Write-TmtInfo 'Lots, leases and import sessions are not merged: create the lot here with -Mode Plan -Lot <name> -LotFile <csv>.'
                Write-TmtStep 'Checking the store' -Number 3 -Total 4 -Icon Store
                $store.Flush()
                $check = $store.Verify($false, $false)
                if ($check.Consistent) { Write-TmtOk "Store consistent: $(Format-TmtNumber $check.Messages) messages in $(Format-TmtNumber $check.Segments) segments checked" -Icon Store }
                else { foreach ($p in ($check.Problems | Select-Object -First 3)) { Write-TmtFail $p }; throw "The store check found $(Format-TmtNumber $check.Problems.Count) problem(s): see the log." }
                Write-TmtStep 'Writing the report' -Number 4 -Total 4 -Icon Report
                $script:reportPath = New-RunFolder
                [void](Save-RunReport -Folder $script:reportPath -Counts $script:counts -Detail ([pscustomobject]@{ FromStore = $script:FromStoreResolved; Store = $script:StoreRootResolved; Merge = $r }))
                Write-TmtOk "Report written to $($script:reportPath)" -Icon Report
                $script:next = ".\Invoke-TeamsTransfer.ps1 -Mode Status -StoreRoot '$($script:StoreRootResolved)'"
            }

            'Report' {
                Write-TmtStep 'Opening the store' -Number 1 -Total 3 -Icon Store
                Assert-NotStopped
                Initialize-TmtEngine
                $store = Open-RunStore -ReadOnly
                Write-TmtOk "Store $($script:StoreRootResolved) opened read-only" -Icon Store
                Write-TmtStep 'Rebuilding the reports from the catalog' -Number 2 -Total 3 -Icon Report
                $report = New-RunFolder
                $script:reportPath = $report
                $reportArgs = @{ Store = $store; Folder = $report }
                if ($Lot) { $reportArgs.Lot = $Lot }
                $reports = @(Invoke-TmtLotReport @reportArgs)
                $resultDetail = $reports
                $script:counts.lots = [long]$reports.Count
                if ($reports.Count -eq 0) { Write-TmtItem SKIP 'No lot in the store yet: run -Mode Plan first.' }
                foreach ($x in $reports) { Write-TmtOk "Lot $($x.Lot): $($x.State)$(if ($x.Verified) { ", verification $($x.Verified) OK" })" -Icon Report }
                Write-TmtStep 'Writing the report' -Number 3 -Total 3 -Icon Report
                [void](Save-RunReport -Folder $report -Counts $script:counts -Detail $resultDetail)
                Write-TmtOk "Reports written to $report (TeamsTransfer_Lot_<name>.html per lot)" -Icon Report
                $script:next = "Open $report in a browser (no network needed)"
            }
        }
    }
} catch {
    $caught = $_
    if ($_.Exception -is [OperationCanceledException] -or $_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        $exitCode = 2
        $script:next = Format-RunCommand
    } else {
        $exitCode = 1
        $failure = $_.Exception.Message
        $hint = Get-RunHint $failure
        if ($hint) { $failure = "$failure Hint: $hint" }
        Write-TmtLog FAIL $failure
    }
} finally {
    # The card is always written, after success, a stop or an error.
    if ($null -ne $store) { try { $store.Dispose() } catch { Write-TmtLog WARN "The store could not be closed cleanly: $($_.Exception.Message)" } }
    try {
        if ($exitCode -eq 2 -and $null -ne $caught -and -not $script:next) { $script:next = 'Run the same command again to resume' }
        Write-TmtEndCard -Mode $Mode -ExitCode $exitCode -Failure $failure -Counts $script:counts -Planned:($whatIf -or ($isWriteMode -and $dryRun)) `
            -Report $script:reportPath -Next $script:next -DurationSeconds $runClock.Elapsed.TotalSeconds -StoreRoot $(if ($Mode -notin 'Assess') { $script:StoreRootResolved } else { '' })
    } finally {
        Stop-TmtLog
    }
}
#endregion

if ($PassThru) {
    [pscustomobject][ordered]@{
        Mode = $Mode
        Status = if ($exitCode -eq 0) { if ($dryRun) { 'Planned' } else { 'Success' } } elseif ($exitCode -eq 1) { 'Failed' } else { 'Pending' }
        ExitCode = $exitCode; Counts = $script:counts; Duration = $runClock.Elapsed; LogFile = $logPath; Report = $script:reportPath; Next = $script:next
    }
}
# An error ends the script with its message (exit code 1, like pwsh -File reports an unhandled error); every other outcome exits explicitly.
if ($exitCode -eq 1 -and $caught) { throw $caught }
exit $exitCode
