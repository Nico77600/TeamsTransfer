<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="package/docs/images/readme-banner-dark.svg">
    <img alt="Teams Transfer: export Teams chats and channels to a local store, browse them offline, import them into a tenant and verify. Version 1.0.0, Windows x64, PowerShell 7.4 or later." src="package/docs/images/readme-banner-light.svg">
  </picture>
</p>

<p align="center">
  <a href="#why"><b>Why</b></a> &nbsp;&middot;&nbsp;
  <a href="#how-it-works"><b>How it works</b></a> &nbsp;&middot;&nbsp;
  <a href="#reports"><b>Reports</b></a> &nbsp;&middot;&nbsp;
  <a href="#requirements"><b>Requirements</b></a> &nbsp;&middot;&nbsp;
  <a href="#quick-start"><b>Quick start</b></a> &nbsp;&middot;&nbsp;
  <a href="package/docs/TeamsTransfer-UserGuide.md"><b>User guide</b></a> &nbsp;&middot;&nbsp;
  <a href="package/docs/TeamsTransfer-Guide.md"><b>Reference guide</b></a>
</p>

# Teams Transfer

**Author: Nicolas Fabert (Nico77600)** | Version 1.0.0 | [Latest release](https://github.com/Nico77600/TeamsTransfer/releases/latest) | MIT license

Exports Microsoft Teams chats and channels (messages, reactions, images, files) from a tenant into a verified local store, lets you read them offline in a Teams-like HTML archive, and imports them into a tenant with the Microsoft Graph Teams migration API, in lots and in waves, with a ghost account for every deleted author and a verification at the end. A guided WPF console and a scriptable command line drive the same engine.

> [!IMPORTANT]
> Imported messages cannot be rolled back, and the import of several years of history takes weeks or months because of the limits of the service. Run every write mode as a preview, read the plan, and test in a lab tenant before you use real data. A release package is signed by its owner; a source checkout starts only with `-DevelopmentMode`. See the [Disclaimer](#disclaimer).

## Why

Moving Teams conversations between tenants is not a copy: the service has no export for chats and channels, an author who left the company cannot be named in the target, and an import is slow and cannot be undone. Teams Transfer is made for that long, careful job.

- **You see before you write.** Every mode that writes to a tenant is a preview unless you add `-Apply`. The plan says where each conversation goes, who writes it, which files are copied, what blocks and how long it will take.
- **Nothing is lost on the way.** Messages, reactions, images and files go to a local store that is checked and de-duplicated. What you do not re-import stays readable in an offline archive.
- **The original author is kept.** A person deleted at the source gets one disabled, unlicensed ghost account in the target, the same one for the whole project.
- **A long job survives.** A journal makes every run resumable and idempotent: run the same command again and only what is left is done, a message is never sent twice.
- **The result is verified.** The target is read back chat by chat and compared with the journal and the source.

## How it works

1. **Export.** Reads the chats and the channels of the source tenant with application permissions and a certificate, obeys the throttling of the service and writes a local store (a SQLite catalog, compressed message segments, a content store for images and files). A second run reads only what changed.
2. **Archive.** Writes an offline, Teams-like HTML archive that anybody can open without Teams.
3. **Plan.** You group conversations into lots (by user, team or CSV). The plan is a dry run: destinations, author mapping, files, blockers, estimated duration.
4. **Ghosts, copy files, import.** Ghost accounts first, then the files, then each conversation is opened with `startMigration`, filled with its messages at their original dates and authors, and closed with `completeMigration`.
5. **Verify.** The target is read back and compared with the journal and the source.

The first wave of a lot is the last 24 months; older history follows as extension waves. The service allows about 5 messages per second per conversation, so plan the volume you re-inject: everything else stays in the archive. The [package README](package/README.md) has the details and the [reference guide](package/docs/TeamsTransfer-Guide.md) explains every mode.

## Reports

Every run writes a log and a report folder. Treat all of it as personal data: it repeats names, addresses and message text.

| Output | What it is |
|---|---|
| Archive | A Teams-like HTML archive (a folder, or one file with `-SingleFile`) that opens by double-click, with no network |
| `plan.html`, `plan.json` | The dry run of an import: conversations, authors, ghosts, files, blockers, estimated duration |
| `verify.html`, `verify.csv` | The comparison after the import: OK, Mismatch, Missing, NotCompleted or Unverified per conversation |
| CSV files | `conversations.csv`, `identities.csv`, `ghosts.csv`, `issues.csv`, `rejected.csv`: the detail behind each report |
| Logs | `TeamsTransfer_yyyyMMdd.log`: numbered steps, no token, no secret; the final card names the log and the report |

The [reference guide](package/docs/TeamsTransfer-Guide.md) lists every file of every mode.

## Requirements

- Windows x64 with PowerShell 7.4 or later (`pwsh.exe`). Windows PowerShell 5.1 is refused.
- One app registration per side (a read-only source app, a target app that writes) with certificate sign-in; the permissions are listed in the [user guide](package/docs/TeamsTransfer-UserGuide.md) and in the [reference guide](package/docs/TeamsTransfer-Guide.md).
- A certificate whose public part is uploaded to each app registration. No secret is ever stored.
- A local disk for the store. A network share is refused.
- For the console: the Microsoft Edge WebView2 runtime (optional: only the Explorer preview needs it).

## Quick start

1. Download the release ZIP from the [latest release](https://github.com/Nico77600/TeamsTransfer/releases/latest) (under Assets, not Source code) and extract it into a writable, access-restricted local folder, for example `D:\Tools\TeamsTransfer`.
2. Check the publisher (right-click `Invoke-TeamsTransfer.ps1`, Properties, Digital Signatures), then unblock the folder once:

   ```powershell
   Get-ChildItem . -Recurse -File -Force |
       Unblock-File
   ```

3. Fill in `config\TeamsTransfer.config.local.psd1` (tenant ids, application ids, certificate thumbprints), or let the console show what is missing.
4. Start with something that touches nothing:

   ```powershell
   .\Start-TeamsTransferConsole.cmd -Demo
   .\Invoke-TeamsTransfer.ps1 -Mode Assess -SampleUsers 30
   ```

The [package README](package/README.md) has the full table of modes, from `Assess` to `Verify`.

## Documentation

- [Package README](package/README.md): requirements, quick start, content, data handling
- [User guide](package/docs/TeamsTransfer-UserGuide.md): for the operator, one picture per step
- [Reference guide](package/docs/TeamsTransfer-Guide.md): for the engineer
- [Change log](package/CHANGELOG.md)
- [Security policy](SECURITY.md)
- [Third-party notices](package/THIRD-PARTY-NOTICES.md)
- [Development and release rules](AGENTS.md)

## Tests

The tests are offline (a fake Graph and a synthetic tenant: no network, no tenant) and need Pester 5 and PowerShell 7.4 or later. From the repository root:

```powershell
Invoke-Pester .\tests
```

Building the documentation, the package and the signed release is described in [annex D of the reference guide](package/docs/TeamsTransfer-Guide.md#annex-d--release-procedure).

## License

[MIT](package/LICENSE), copyright Nicolas Fabert. Third-party components: [THIRD-PARTY-NOTICES.md](package/THIRD-PARTY-NOTICES.md).

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.

Import creates conversations in the target tenant and an imported conversation cannot be rolled back: run the preview, review the plan and test in a lab before using it on real data.
