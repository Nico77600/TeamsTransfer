#Requires -Version 7.4

<#
.SYNOPSIS
    Downloads, verifies and installs the third-party dependencies of Teams Transfer from nuget.org: the console (WebView2, WPF-UI) and the engine (SQLite:
    Microsoft.Data.Sqlite.Core, SQLitePCLRaw) with the retained licence texts.

.DESCRIPTION
    The pinned packages, the selected files and their hashes are recorded in package\dependency-lock.json. For each package the script:
      1. downloads the exact pinned version from nuget.org into a fresh temporary folder (nothing from it is ever executed);
      2. checks the SHA-512 of the package against the value nuget.org publishes for that version (the package catalog data) AND against the lock;
      3. opens the archive and reads ONLY the selected entries (no extraction of the rest, size limits, no path from the archive is used);
      4. checks the SHA-256 of every selected file against the lock;
      5. only then copies the file to its target under package\lib\gui or package\lib\licenses.
    A file already in place with the right hash is left alone (the run is idempotent and offline when everything is there, unless -Force).

    Licence texts: the NuGet packages of SQLite carry only an SPDX expression, not the text, so the retained texts under package\lib\licenses come from the
    official sources named in the lock ("notices": the dotnet/efcore LICENSE for Microsoft.Data.Sqlite (MIT), the SQLitePCL.raw LICENSE.TXT for SQLitePCLRaw
    (Apache-2.0), the sqlite.org copyright page for SQLite (public domain)). The SHA-256 of each retained file is in the lock and is verified with -Verify.

    -UpdateLock is the reviewed way to move a pin: it downloads the versions named in this script, takes the SHA-512 from nuget.org, computes
    the SHA-256 of the selected files and rewrites the lock. Review the diff of the lock before committing it.

    Network: nuget.org only (www.nuget.org for the package and its metadata, redirected to globalcdn.nuget.org).

.PARAMETER PackageRoot
    The package folder (default: ..\package of this script).

.PARAMETER UpdateLock
    Rewrite dependency-lock.json from nuget.org (a deliberate change of pins). Also installs the files.

.PARAMETER Package
    With -UpdateLock: only these pins (package ids or wildcards, for example 'SQLitePCLRaw*', 'Microsoft.Data.Sqlite*', 'SQLite') are downloaded and
    rewritten; the other entries of the lock are kept as they are.

.PARAMETER Force
    Download and copy again even when the files in place already match the lock.

.PARAMETER Verify
    Only check the installed files (DLLs and licence texts, the SQLite libraries included) against the lock (no network).

.EXAMPLE
    .\tools\Get-TeamsTransferDependencies.ps1
    Installs (or confirms) the pinned GUI libraries under package\lib\gui.

.EXAMPLE
    .\tools\Get-TeamsTransferDependencies.ps1 -Verify
    Checks the installed files against dependency-lock.json, offline.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'package'),
    [switch]$UpdateLock,
    [string[]]$Package,
    [switch]$Force,
    [switch]$Verify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

# "-Package a,b" given through pwsh -File arrives as one string: split it on commas.
$Package = @($Package | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$LockPath = Join-Path $PackageRoot 'dependency-lock.json'
$Limits = @{ MaxPackageBytes = 64MB; MaxEntryBytes = 8MB; TimeoutSeconds = 180 }

# The pins. Only -UpdateLock reads this table; a normal run follows the lock file.
$Wanted = @(
    @{
        Id = 'Microsoft.Web.WebView2'; Version = '1.0.4258.31'; License = 'Microsoft WebView2 SDK license (BSD-3-Clause style, see LICENSE.txt / NOTICE.txt)'
        Files = @(
            @{ Entry = 'lib_manual/netcoreapp3.0/Microsoft.Web.WebView2.Core.dll'; Target = 'lib\gui\Microsoft.Web.WebView2.Core.dll'; Kind = 'runtime-managed' }
            @{ Entry = 'lib_manual/netcoreapp3.0/Microsoft.Web.WebView2.Wpf.dll'; Target = 'lib\gui\Microsoft.Web.WebView2.Wpf.dll'; Kind = 'runtime-managed' }
            @{ Entry = 'runtimes/win-x64/native/WebView2Loader.dll'; Target = 'lib\gui\runtimes\win-x64\native\WebView2Loader.dll'; Kind = 'runtime-native' }
            @{ Entry = 'runtimes/win-arm64/native/WebView2Loader.dll'; Target = 'lib\gui\runtimes\win-arm64\native\WebView2Loader.dll'; Kind = 'runtime-native' }
            @{ Entry = 'LICENSE.txt'; Target = 'lib\licenses\WebView2\LICENSE.txt'; Kind = 'notice' }
            @{ Entry = 'NOTICE.txt'; Target = 'lib\licenses\WebView2\NOTICE.txt'; Kind = 'notice' }
        )
    }
    @{
        Id = 'WPF-UI'; Version = '4.1.0'; License = 'MIT with complete embedded-component notices; Segoe font is an OS reference, not a font byte to distribute'
        Files = @(
            @{ Entry = 'lib/net8.0-windows7.0/Wpf.Ui.dll'; Target = 'lib\gui\Wpf.Ui.dll'; Kind = 'runtime-managed' }
            @{ Entry = 'LICENSE.md'; Target = 'lib\licenses\WPF-UI\LICENSE.md'; Kind = 'notice' }
            @{ Entry = 'ThirdPartyNotices.txt'; Target = 'lib\licenses\WPF-UI\ThirdPartyNotices.txt'; Kind = 'notice' }
        )
    }
    @{
        Id = 'WPF-UI.Abstractions'; Version = '4.1.0'; License = 'MIT; same LICENSE.md / ThirdPartyNotices as WPF-UI'
        Files = @(
            @{ Entry = 'lib/net8.0/Wpf.Ui.Abstractions.dll'; Target = 'lib\gui\Wpf.Ui.Abstractions.dll'; Kind = 'runtime-managed' }
        )
    }
    # Engine: SQLite (the files of lib\sqlite are the original binaries of these packages)
    @{
        Id = 'Microsoft.Data.Sqlite.Core'; Version = '10.0.12'; License = 'MIT (Microsoft Corporation); text retained from dotnet/efcore, see notices'
        Files = @( @{ Entry = 'lib/net8.0/Microsoft.Data.Sqlite.dll'; Target = 'lib\sqlite\Microsoft.Data.Sqlite.dll'; Kind = 'runtime-managed' } )
    }
    @{
        Id = 'SQLitePCLRaw.core'; Version = '2.1.12'; License = 'Apache-2.0 (SourceGear, LLC); text retained from ericsink/SQLitePCL.raw, see notices'
        Files = @( @{ Entry = 'lib/netstandard2.0/SQLitePCLRaw.core.dll'; Target = 'lib\sqlite\SQLitePCLRaw.core.dll'; Kind = 'runtime-managed' } )
    }
    @{
        Id = 'SQLitePCLRaw.provider.e_sqlite3'; Version = '2.1.12'; License = 'Apache-2.0 (SourceGear, LLC); same text as SQLitePCLRaw.core'
        Files = @( @{ Entry = 'lib/netstandard2.0/SQLitePCLRaw.provider.e_sqlite3.dll'; Target = 'lib\sqlite\SQLitePCLRaw.provider.e_sqlite3.dll'; Kind = 'runtime-managed' } )
    }
    @{
        Id = 'SQLitePCLRaw.bundle_e_sqlite3'; Version = '2.1.12'; License = 'Apache-2.0 (SourceGear, LLC); same text as SQLitePCLRaw.core'
        Files = @( @{ Entry = 'lib/netstandard2.0/SQLitePCLRaw.batteries_v2.dll'; Target = 'lib\sqlite\SQLitePCLRaw.batteries_v2.dll'; Kind = 'runtime-managed' } )
    }
    @{
        Id = 'SQLitePCLRaw.lib.e_sqlite3'; Version = '2.1.12'; License = 'Apache-2.0 (SourceGear, LLC) for the packaging; the SQLite engine inside e_sqlite3.dll is public domain (sqlite.org), see notices'
        Files = @(
            @{ Entry = 'runtimes/win-x64/native/e_sqlite3.dll'; Target = 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll'; Kind = 'runtime-native' }
            @{ Entry = 'runtimes/win-arm64/native/e_sqlite3.dll'; Target = 'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll'; Kind = 'runtime-native' }
        )
    }
)

# Licence texts retained under package\lib\licenses (not inside the packages). Kind 'text': the retained file is the downloaded file, byte for byte.
# Kind 'sqlite-html': the notice is the text of the sqlite.org copyright page (the SHA-256 of the raw page is recorded as sourceSha256).
$WantedNotices = @(
    @{ Id = 'Microsoft.Data.Sqlite'; License = 'MIT'; Copyright = '(c) Microsoft Corporation. All rights reserved. / The MIT License (MIT), Copyright (c) .NET Foundation and Contributors'
       Source = 'https://raw.githubusercontent.com/dotnet/efcore/v10.0.0/LICENSE.txt'; Target = 'lib\licenses\Microsoft.Data.Sqlite\LICENSE.txt'; Kind = 'text' }
    @{ Id = 'SQLitePCLRaw'; License = 'Apache-2.0'; Copyright = 'Copyright 2014-2024 SourceGear, LLC'
       Source = 'https://raw.githubusercontent.com/ericsink/SQLitePCL.raw/v2.1.12/LICENSE.TXT'; Target = 'lib\licenses\SQLitePCLRaw\LICENSE.TXT'; Kind = 'text' }
    @{ Id = 'SQLite'; License = 'Public domain'; Copyright = 'none (dedicated to the public domain by the authors)'
       Source = 'https://www.sqlite.org/copyright.html'; Target = 'lib\licenses\SQLite\PUBLIC-DOMAIN.txt'; Kind = 'sqlite-html' }
)
$NoticeHosts = 'raw.githubusercontent.com', 'www.sqlite.org', 'www.apache.org'

function Test-PackageSelected {
    # With -Package (-UpdateLock): is this pin or notice one of the selected ids (wildcards allowed)? Without -Package every pin is.
    param([Parameter(Mandatory)][string]$Id)
    if (-not $Package) { return $true }
    foreach ($pattern in $Package) { if ($pattern -and $Id -like $pattern) { return $true } }
    return $false
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-TargetUnderLib {
    # A target comes from the lock file: it must stay under lib\gui, lib\sqlite or lib\licenses of the package.
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -match '\.\.' -or [IO.Path]::IsPathRooted($Target) -or $Target -notmatch '^lib\\(gui|licenses|sqlite)\\') { throw "Refused target '$Target': it must be a relative path under lib\gui, lib\sqlite or lib\licenses." }
    $full = [IO.Path]::GetFullPath((Join-Path $PackageRoot $Target))
    $libRoot = [IO.Path]::GetFullPath((Join-Path $PackageRoot 'lib')) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($libRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Refused target '$Target': outside $libRoot" }
    return $full
}

function Get-NuGetCatalogHash {
    # The SHA-512 (base64) that nuget.org publishes for the package version. V2 package metadata first, then the V3 catalog.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version)
    try {
        $x = (Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/Packages(Id='$Id',Version='$Version')" -UseBasicParsing -TimeoutSec 60).Content
        $alg = [regex]::Match($x, '<d:PackageHashAlgorithm[^>]*>([^<]+)').Groups[1].Value
        $hash = [regex]::Match($x, '<d:PackageHash[^>]*>([^<]+)').Groups[1].Value
        $size = [regex]::Match($x, '<d:PackageSize[^>]*>([^<]+)').Groups[1].Value
        if ($alg -eq 'SHA512' -and $hash) { return [pscustomobject]@{ Algorithm = 'SHA512'; Base64 = $hash; Bytes = [long]$size; Source = 'nuget.org package metadata (V2)' } }
    } catch { Write-Verbose "V2 metadata unavailable: $($_.Exception.Message)" }
    $lower = $Id.ToLowerInvariant(); $ver = $Version.ToLowerInvariant()
    $reg = Invoke-RestMethod -Uri "https://api.nuget.org/v3/registration5-gz-semver2/$lower/$ver.json" -TimeoutSec 60
    $entry = Invoke-RestMethod -Uri $reg.catalogEntry -TimeoutSec 60
    if ($entry.packageHashAlgorithm -ne 'SHA512') { throw "nuget.org catalog gives $($entry.packageHashAlgorithm) for $Id $Version, SHA512 expected." }
    return [pscustomobject]@{ Algorithm = 'SHA512'; Base64 = [string]$entry.packageHash; Bytes = [long]$entry.packageSize; Source = 'nuget.org catalog (V3)' }
}

function Save-NuGetPackage {
    # Downloads into $Folder (a fresh temp folder). Only nuget.org (and its CDN redirect) is contacted.
    param([string]$Id, [string]$Version, [string]$Folder)
    $dest = Join-Path $Folder "$Id.$Version.nupkg"
    $client = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]::new())
    $client.Timeout = [TimeSpan]::FromSeconds($Limits.TimeoutSeconds)
    try {
        $uri = "https://www.nuget.org/api/v2/package/$Id/$Version"
        $resp = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$resp.EnsureSuccessStatusCode()
        $host2 = $resp.RequestMessage.RequestUri.Host
        if ($host2 -notin 'www.nuget.org', 'api.nuget.org', 'globalcdn.nuget.org') { throw "Unexpected download host $host2" }
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($dest)
        try {
            $buffer = New-Object byte[] 81920; $total = 0L
            while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $n
                if ($total -gt $Limits.MaxPackageBytes) { throw "Package larger than $($Limits.MaxPackageBytes) bytes: refused." }
                $out.Write($buffer, 0, $n)
            }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $client.Dispose() }
    return $dest
}

function Read-LockFile {
    if (-not (Test-Path -LiteralPath $LockPath)) { throw "Lock file not found: $LockPath (run with -UpdateLock to create it from the pins of this script)." }
    return Get-Content -LiteralPath $LockPath -Raw -Encoding utf8 | ConvertFrom-Json
}

function Test-Installed {
    param($Package)
    foreach ($f in $Package.selectedFiles) {
        $path = Assert-TargetUnderLib $f.target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileSha256 $path) -ne $f.sha256) { return $false }
    }
    return $true
}

function ConvertFrom-SqliteCopyrightHtml {
    # The text of the sqlite.org copyright page ("SQLite Is Public Domain" and what follows), with a header that names the source.
    param([Parameter(Mandatory)][string]$Html, [Parameter(Mandatory)][string]$Source)
    $t = [regex]::Replace($Html, '(?s)<(script|style).*?</\1>', '')
    $t = [regex]::Replace($t, '<[^>]+>', '')
    $t = [Net.WebUtility]::HtmlDecode($t)
    $lines = @($t -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $start = [Array]::IndexOf($lines, 'SQLite Is Public Domain')
    if ($start -lt 0) { throw "The page $Source has no 'SQLite Is Public Domain' heading: its layout changed, review it by hand." }
    $body = $lines[$start..($lines.Count - 1)]
    return (@("SQLite - public domain notice", "Source: $Source", "(text of the page, retained for the SQLite library inside e_sqlite3.dll)", '') + $body) -join "`n"
}

function Save-NoticeSource {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Folder)
    $uri = [Uri]$Source
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin $NoticeHosts) { throw "Refused notice source '$Source': https on $($NoticeHosts -join ', ') only." }
    $dest = Join-Path $Folder ([guid]::NewGuid().ToString('N') + '.src')
    Invoke-WebRequest -Uri $Source -OutFile $dest -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 | Out-Null
    if ((Get-Item -LiteralPath $dest).Length -gt 1MB) { throw "Notice source '$Source' is larger than 1 MB: refused." }
    return $dest
}

function Test-NoticeInstalled {
    param($Notice)
    $path = Assert-TargetUnderLib $Notice.target
    return ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-FileSha256 $path) -eq $Notice.sha256)
}

#region -Verify (offline) ------------------------------------------------------------------------
if ($Verify) {
    $lock = Read-LockFile
    $bad = 0
    foreach ($p in $lock.packages) {
        foreach ($f in $p.selectedFiles) {
            $path = Assert-TargetUnderLib $f.target
            if (-not (Test-Path -LiteralPath $path)) { Write-Host "[MISSING] $($f.target)" -ForegroundColor Red; $bad++ }
            elseif ((Get-FileSha256 $path) -ne $f.sha256) { Write-Host "[HASH]    $($f.target)" -ForegroundColor Red; $bad++ }
            else { Write-Host "[OK]      $($f.target)" }
        }
    }
    foreach ($n in @($lock.PSObject.Properties['notices'] | ForEach-Object { $_.Value })) {
        $path = Assert-TargetUnderLib $n.target
        if (-not (Test-Path -LiteralPath $path)) { Write-Host "[MISSING] $($n.target)" -ForegroundColor Red; $bad++ }
        elseif ((Get-FileSha256 $path) -ne $n.sha256) { Write-Host "[HASH]    $($n.target)" -ForegroundColor Red; $bad++ }
        else { Write-Host "[OK]      $($n.target) (licence of $($n.id): $($n.license))" }
    }
    if ($bad) { throw "$bad file(s) do not match dependency-lock.json: run tools\Get-TeamsTransferDependencies.ps1." }
    return
}
#endregion

#region Install or update the lock -----------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ('tt-deps-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    $plan = if ($UpdateLock) {
        $Wanted | Where-Object { Test-PackageSelected $_.Id } | ForEach-Object { [pscustomobject]@{ id = $_.Id; version = $_.Version; license = $_.License; files = @($_.Files | ForEach-Object { [pscustomobject]$_ }); lock = $null } }
    } else {
        $lock = Read-LockFile
        $lock.packages | ForEach-Object { [pscustomobject]@{ id = $_.id; version = $_.version; license = $_.license; files = @($_.selectedFiles | ForEach-Object { [pscustomobject]@{ Entry = $_.entry; Target = $_.target; Kind = $_.kind } }); lock = $_ } }
    }
    $newPackages = [Collections.Generic.List[object]]::new()

    foreach ($pkg in $plan) {
        $label = "$($pkg.id) $($pkg.version)"
        if (-not $UpdateLock -and -not $Force -and (Test-Installed $pkg.lock)) { Write-Host "[OK]   $label already installed and verified"; continue }
        Write-Host "[....] $label"
        $dir = Join-Path $work ($pkg.id + '-' + $pkg.version)
        [void][IO.Directory]::CreateDirectory($dir)
        $catalog = Get-NuGetCatalogHash -Id $pkg.id -Version $pkg.version
        $nupkg = Save-NuGetPackage -Id $pkg.id -Version $pkg.version -Folder $dir
        $bytes = (Get-Item -LiteralPath $nupkg).Length
        $sha512 = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($nupkg)))
        if ($sha512 -ne $catalog.Base64) { throw "$label : SHA-512 of the download does not match $($catalog.Source). Refused." }
        if (-not $UpdateLock -and $sha512 -ne $pkg.lock.sha512) { throw "$label : SHA-512 of the download does not match dependency-lock.json. Refused." }
        Write-Host "       package SHA-512 matches $($catalog.Source)"

        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        $selected = [Collections.Generic.List[object]]::new()
        try {
            if ($zip.Entries.Count -gt 512) { throw "$label : too many archive entries." }
            foreach ($f in $pkg.files) {
                $entry = $zip.GetEntry($f.Entry)
                if ($null -eq $entry) { throw "$label : entry '$($f.Entry)' not found in the package." }
                if ($entry.Length -gt $Limits.MaxEntryBytes) { throw "$label : entry '$($f.Entry)' is larger than $($Limits.MaxEntryBytes) bytes." }
                $staged = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.bin')
                $s = $entry.Open(); $o = [IO.File]::Create($staged)
                try { $s.CopyTo($o) } finally { $o.Dispose(); $s.Dispose() }
                $sha = Get-FileSha256 $staged
                $expectedFile = if ($UpdateLock) { $null } else { ($pkg.lock.selectedFiles | Where-Object { $_.entry -eq $f.Entry }).sha256 }
                if (-not $UpdateLock -and $sha -ne $expectedFile) { throw "$label : SHA-256 of '$($f.Entry)' does not match the lock. Refused." }
                $target = Assert-TargetUnderLib $f.Target
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                # a library already in place with the right hash is not rewritten (it may be loaded by a running session)
                if (-not ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileSha256 $target) -eq $sha)) { Copy-Item -LiteralPath $staged -Destination $target -Force }
                Write-Host "       $($f.Target)"
                $selected.Add([ordered]@{ entry = $f.Entry; bytes = (Get-Item -LiteralPath $target).Length; sha256 = $sha; target = $f.Target; kind = $f.Kind })
            }
        } finally { $zip.Dispose() }
        $newPackages.Add([ordered]@{
                id = $pkg.id; version = $pkg.version; bytes = $bytes; sha512 = $sha512; sha512Source = $catalog.Source
                license = $pkg.license; selectedFiles = $selected.ToArray()
            })
        Write-Host "[OK]   $label installed"
    }

    # Licence texts (the retained files under lib\licenses)
    $newNotices = [Collections.Generic.List[object]]::new()
    if ($UpdateLock) {
        $oldLock = if (Test-Path -LiteralPath $LockPath) { Read-LockFile } else { $null }
        foreach ($wn in $WantedNotices) {
            if (-not (Test-PackageSelected $wn.Id)) {
                $kept = if ($oldLock -and $oldLock.PSObject.Properties['notices']) { @($oldLock.notices | Where-Object { $_.id -eq $wn.Id }) } else { @() }
                if ($kept) { $newNotices.Add($kept[0]) }
                continue
            }
            Write-Host "[....] licence text of $($wn.Id)"
            $src = Save-NoticeSource -Source $wn.Source -Folder $work
            $srcSha = Get-FileSha256 $src
            $target = Assert-TargetUnderLib $wn.Target
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            if ($wn.Kind -eq 'sqlite-html') {
                [IO.File]::WriteAllText($target, (ConvertFrom-SqliteCopyrightHtml -Html ([IO.File]::ReadAllText($src)) -Source $wn.Source) + "`n", [Text.UTF8Encoding]::new($false))
            } else { Copy-Item -LiteralPath $src -Destination $target -Force }
            $newNotices.Add([ordered]@{ id = $wn.Id; license = $wn.License; copyright = $wn.Copyright; source = $wn.Source; sourceSha256 = $srcSha; kind = $wn.Kind
                    retrieved = (Get-Date -Format 'yyyy-MM-dd'); bytes = (Get-Item -LiteralPath $target).Length; sha256 = (Get-FileSha256 $target); target = $wn.Target })
            Write-Host "[OK]   $($wn.Target)"
        }
    } else {
        $lockNow = Read-LockFile
        foreach ($n in @($lockNow.PSObject.Properties['notices'] | ForEach-Object { $_.Value })) {
            if (-not $Force -and (Test-NoticeInstalled $n)) { Write-Host "[OK]   licence text $($n.target) verified"; continue }
            if ($n.kind -ne 'text') { throw "The retained text $($n.target) is missing or changed: restore it from the release (it is made from $($n.source) with -UpdateLock)." }
            $src = Save-NoticeSource -Source $n.source -Folder $work
            if ((Get-FileSha256 $src) -ne $n.sha256) { throw "Licence text of $($n.id): the file at $($n.source) does not match the lock (sha256). Refused." }
            $target = Assert-TargetUnderLib $n.target
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            Copy-Item -LiteralPath $src -Destination $target -Force
            Write-Host "[OK]   $($n.target) installed"
        }
    }

    if ($UpdateLock) {
        $byId = @{}
        if ($Package -and (Test-Path -LiteralPath $LockPath)) { foreach ($old in @((Read-LockFile).packages)) { $byId[$old.id] = $old } }
        foreach ($np in $newPackages) { $byId[$np.id] = $np }
        $ordered = @($Wanted | ForEach-Object { $_.Id } | Where-Object { $byId.ContainsKey($_) } | ForEach-Object { $byId[$_] })
        $doc = [ordered]@{
            schemaVersion = 1
            kind          = 'TeamsTransfer.DependencyLock'
            classification = 'Pin metadata of the third-party dependencies of Teams Transfer: the GUI libraries of the console and the SQLite libraries of the engine, with the retained licence texts. Packages come from nuget.org only; each package is checked against its published SHA-512 and each selected file against the SHA-256 below before it is copied. The licence texts of SQLite are not inside the packages: they are retained from the official sources named in notices, with their SHA-256.'
            target        = [ordered]@{ framework = 'net8.0-windows'; runtimeIdentifiers = @('win-x64', 'win-arm64'); reviewedFor = @('PowerShell 7.4', 'PowerShell 7.5') }
            acquisition   = [ordered]@{
                policy  = 'Original official packages only; downloaded into a fresh temporary folder; only the selected entries are read; nothing from a package is executed.'
                source  = 'https://www.nuget.org/api/v2/package/{id}/{version} (redirect to globalcdn.nuget.org)'
                limits  = [ordered]@{ maxPackageBytes = [long]$Limits.MaxPackageBytes; maxEntryBytes = [long]$Limits.MaxEntryBytes }
            }
            packages      = $ordered
            notices       = $newNotices.ToArray()
            notes         = @(
                'The WebView2 runtime itself (Microsoft Edge WebView2) is not redistributed: it is installed with Windows 11 and Microsoft 365, or from https://developer.microsoft.com/microsoft-edge/webview2/.'
                'WPF-UI embeds only the two MIT FluentSystemIcons fonts; Segoe Fluent Icons is an OS font reference and no Segoe font bytes are distributed.'
                'The SQLite libraries of lib\sqlite are the original binaries of the packages above, unchanged (SHA-256 of every file recorded). Microsoft.Data.Sqlite.dll is the lib/net8.0 build of Microsoft.Data.Sqlite.Core; the Microsoft.Data.Sqlite and SQLitePCLRaw.bundle_e_sqlite3 meta packages are pinned for batteries_v2.dll only.'
            )
        }
        [IO.File]::WriteAllText($LockPath, ($doc | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
        Write-Host "[OK]   lock written: $LockPath (review the diff before committing)"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
#endregion
