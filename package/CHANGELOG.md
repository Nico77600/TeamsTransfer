# Changelog

All notable changes of Teams Transfer. Author: Nicolas Fabert (Nico77600). Versions follow `MAJOR.MINOR.PATCH`:
a MAJOR version changes the command line or the configuration file, a MINOR version adds a feature,
a PATCH version fixes a defect. The archive data format has its own version (`preview-v1`, see the reference guide, chapter 16).

## 1.0.2 — 2026-11-12

New release published. Various syntax fixes, no new features.

## 1.0.1 — 2026-11-12

Documentation release: no change to the engine, the command line or the configuration.

### Changed
- **README and guides in the house layout.** A new README banner (title, lead, pills and key figures) and explanatory drawings,
  light and dark: what the tool does, the guided path, how it works and its modes, the principles, lots and waves, and the
  application permissions per mode (drawn from `config\Permissions.psd1`). The repository README follows the layout of the
  other projects of the author (download badge, release tip, Get started, Console).
- **HTML guides.** Icons on every note, tip, important, warning and caution box; the Teams Transfer icon in the header and the
  side bar; the guided path drawn as in the other guides; a picture dictionary in the user guide; the drawings switch with the
  light or dark theme.

## 1.0.0 — 2026-11-12

First public release. Validated end to end on a real lab (two tenants, 1:1 chats, group chats, standard and private channels,
a deleted author, files): Inventory, Export, Files, Archive, Plan, Ghosts, CopyFiles, Import and Verify.
The repository also holds a tag `v0.1.0`: the same feature set as a release candidate, never published as a release.

### Added
- **Command line** `Invoke-TeamsTransfer.ps1` with thirteen modes: `Status` (default), `Assess`, `Inventory`, `Export`, `Files`,
  `Archive`, `Plan`, `Ghosts`, `CopyFiles`, `Import`, `Verify`, `Report` and `Merge`. Parameters are checked against the mode before anything
  is read or written. Numbered steps, a progress line every `-IntervalSeconds`, a final card, a daily log, HTML/CSV/JSON reports,
  `-WhatIf`, `-PassThru`, `-StopFile`, exit codes 0 (complete), 1 (failed), 2 (resumable), 3 (uncertain items).
- **Export** of chats and channels (messages, replies, reactions, mentions, inline images, members) with strategy U (per user)
  or C (per chat), incremental and resumable at page level, plus the `Files` stage (download, de-duplicated by SHA256).
- **Local store**: a SQLite catalog, 256 message partitions in append-only compressed segments, a content-addressed blob store;
  crash-safe flushes, orphan-tail detection and repair, one writer, refusal of the package folder and of network shares.
- **Offline Teams-like archive** (`-Mode Archive`, folder or `-SingleFile`): chats, teams and channels, replies, reactions,
  mentions, images, file cards, search, light and dark theme, a "former account" badge; a sanitiser with an allow-list and a strict
  content security policy, no network access.
- **Assess**: samples users and teams and extrapolates volume, disk, duration and waves to the whole tenant.
- **Named lots and several workstations**: `-Lot <name>` with `-Users`, `-Teams` or a `-LotFile` CSV (`Type`, `Identity`, `Priority`) on `Plan` and `Export`; `-Mode Merge -FromStore` folds the store of another workstation into the coordinator's.
- **Lots and waves**: lots by user, team or CSV; wave 1 is the last 24 months, extension waves cover months 25 to 36, 37 to 48 and
  49 to 60 (up to 600 months); coverage so that a conversation is never planned twice; life cycle `Planned` to `Closed` with
  `Paused`, `Failed` and `Cancelled`; `-Mode Status -Lot <name> -CancelLot` abandons a lot that has not started importing.
- **Plan**: a dry-run import plan with identity mapping (CSV, domain rule, same user, ghost, service account), target mapping
  (new or existing chat or channel, archive channel), ghosts, files, blockers, warnings and an estimated duration; three scenarios
  (`TenantToTenant`, `SameTenantRestore`, `DepartedArchive`).
- **Ghosts**: one disabled, unlicensed account per deleted author, with a tracking group, a threshold, idempotency and a safe `-Remove`.
- **CopyFiles**: files copied to the OneDrive of the sender or to the channel folder, upload sessions with resume, de-duplication,
  sharing with the chat members.
- **Import** with the Teams migration API: preview with the exact requests per endpoint, `-Apply` after one confirmation,
  3 requests in flight and 5 per second per conversation, a journal so that a message is never sent twice (the `409` of the service
  is recorded as already imported), group chat history restore, GUID attachment ids.
- **Verify**: reads the target chat by chat and compares the journal, the source, a sample of messages, reactions, files and the
  migration state; outcomes `OK`, `Mismatch`, `Missing`, `NotCompleted`, `Unverified`; sets the lot `Verified`.
- **Adaptive throttling**: `Retry-After` honoured, jittered backoff, an AIMD limiter per endpoint class, a bucket per conversation.
- **Guided WPF console** (`Start-TeamsTransferConsole.cmd`, `-Gui`): Setup, Task, Verify, Run, Next steps; permission lights per
  tenant; every run shown as a copyable command; Explorer with the archive in WebView2; **Demo mode** with synthetic tenants.
- **Package integrity**: a manifest of SHA256 hashes checked before any code runs; the owner signature for a release;
  `-DevelopmentMode` for a source tree or an unsigned development package.
- **Documentation**: this package readme, a user guide for the operator and a reference guide, in Markdown and as self-contained HTML.

### Known limits
- Importing years of history takes weeks or months: about 5 messages per second per conversation and 60 to 90 per second per
  application and tenant. The gain of a second application is not demonstrated.
- An imported conversation cannot be rolled back.
- Meeting chats are imported as group chats; federated content cannot be imported (the service account stands in);
  videos, cross-posts and SharePoint-generated links are outside the import API.
- Imported messages are invisible to `getAllMessages`; verification reads chat by chat.
- A chat whose members are all deleted or federated is not reachable app-only through a user listing.
- `Archive` takes one user or one team per run. The product is English only.
- A chat with a departed person is imported as a group chat with the service account ("Archived chat with ..."); ghost accounts are never members.
- Windows x64, PowerShell 7.4 or later. The store must be on a local disk.
