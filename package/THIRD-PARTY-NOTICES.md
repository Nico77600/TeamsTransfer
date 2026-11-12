# Third-party notices

Teams Transfer retains the original bytes of its selected dependencies and their notices. This file is an attribution index, not a substitute for the license texts and not a license grant for this project's own source.

The exact package versions, selected entries, lengths, SHA-512 (package) and SHA-256 (files) values of the console dependencies are recorded in `dependency-lock.json`; the hash of every file of the package, the SQLite libraries included, is recorded in `PackageIntegrity.psd1`. `tools\Get-TeamsTransferDependencies.ps1` installs and verifies them. Do not replace a library independently or remove notices when making a runtime copy.

## Console (WPF) dependencies

| Dependency | Version | Deployment | License / retained notice |
|---|---|---|---|
| Microsoft.Web.WebView2 | 1.0.4258.31 | `lib\gui\Microsoft.Web.WebView2.Core.dll`, `lib\gui\Microsoft.Web.WebView2.Wpf.dll`, `lib\gui\runtimes\win-x64\native\WebView2Loader.dll`, `lib\gui\runtimes\win-arm64\native\WebView2Loader.dll` | [Microsoft license](lib/licenses/WebView2/LICENSE.txt), [notice](lib/licenses/WebView2/NOTICE.txt) |
| WPF-UI | 4.1.0 | `lib\gui\Wpf.Ui.dll` | [MIT](lib/licenses/WPF-UI/LICENSE.md), [complete embedded-component notices](lib/licenses/WPF-UI/ThirdPartyNotices.txt) |
| WPF-UI.Abstractions | 4.1.0 | `lib\gui\Wpf.Ui.Abstractions.dll` | Same retained WPF-UI license and third-party notices |

The Microsoft Edge WebView2 **runtime** is not redistributed. It is installed with Windows 11 and Microsoft 365 Apps, or from the Microsoft WebView2 download page. The console shows a clear message when it is missing and keeps working without the Explorer preview.

## Engine dependencies

| Dependency | Version | Deployment | License |
|---|---|---|---|
| Microsoft.Data.Sqlite (package Microsoft.Data.Sqlite.Core) | 10.0.12 | `lib\sqlite\Microsoft.Data.Sqlite.dll` | [MIT](lib/licenses/Microsoft.Data.Sqlite/LICENSE.txt) (Microsoft) |
| SQLitePCLRaw (core, provider.e_sqlite3, bundle_e_sqlite3 = batteries_v2, lib.e_sqlite3) | 2.1.12 | `lib\sqlite\` (managed assemblies, and the native `e_sqlite3.dll` for `win-x64` and `win-arm64` under `lib\sqlite\runtimes\`) | [Apache-2.0](lib/licenses/SQLitePCLRaw/LICENSE.TXT) (SourceGear, LLC) |
| SQLite (the native engine inside `e_sqlite3.dll`) | as built by SQLitePCLRaw 2.1.12 | `lib\sqlite\runtimes\*\e_sqlite3.dll` | [public domain](lib/licenses/SQLite/PUBLIC-DOMAIN.txt) (sqlite.org) |

The SQLite libraries are the original binaries of the NuGet packages, unchanged; the lock records the SHA-512 of each package and the SHA-256 of each file. The NuGet packages carry only the licence identifier (SPDX expression), not the text, so the texts are retained under `lib\licenses\` from the official sources named in `dependency-lock.json` (`notices`): the dotnet/efcore `LICENSE.txt` (MIT), the SQLitePCL.raw `LICENSE.TXT` of tag v2.1.12 (Apache License 2.0; copyright 2014-2024 SourceGear, LLC) and the text of https://www.sqlite.org/copyright.html (public domain). `tools\Get-TeamsTransferDependencies.ps1 -Verify` checks them offline.

## Embedded and platform components

The WPF-UI notice file includes attribution and terms for VirtualizingWrapPanel, Fluent System Icons, .NET WPF, Windows UI XAML and the Segoe Fluent Icons font reference. Preserve it unchanged. The fonts used by Windows are platform references, not font files distributed by this package.

Windows, PowerShell, .NET and the installed Microsoft Edge WebView2 runtime keep their respective platform terms and are not redistributed by this package.

## Maintaining the inventory

Use `tools\Get-TeamsTransferDependencies.ps1 -UpdateLock` when a dependency change is intended, review the diff of the lock and the notices, then refresh the package manifest. A checksum alone is not publisher authentication.
