#Requires -Version 7.4

<#
.SYNOPSIS
    Builds the release package of Teams Transfer: tests, documentation, integrity manifest, verification, ZIP and SHA256SUMS.txt.

.DESCRIPTION
    The release ZIP holds exactly the content of the package folder and nothing else (no tests, no tools, no .local-test-data,
    no config\*.local.psd1, no store, out, logs, reports, bin or data folder). The integrity model is the one of ExchangeLogReport and
    PraRemoteMailbox: PackageIntegrity.psd1 lists the SHA256 of every file of the package, src\Test-PackageIntegrity.ps1 verifies it before any
    code runs, and the owner signs the PowerShell files, the verifier and the manifest. This script never signs anything.

    Order of a signed release (the owner does the signing, the script does the rest):
      1. The owner signs every PowerShell file of the package (*.ps1, *.psm1, *.psd1, the verifier src\Test-PackageIntegrity.ps1 included;
         Set-AuthenticodeSignature, trusted timestamped certificate 0F28E442...). Not the manifest yet.
      2. .\tools\Build-Package.ps1 -Stage Prepare
         (a) the full test suite (or -SkipTests, which is announced and never silent), (b) the documentation (tools\Build-Documentation.ps1),
         (c) package\PackageIntegrity.psd1 (tools\Build-PackageManifest.ps1: the hashes of the SIGNED files), (d) the manifest is verified with
         src\Test-PackageIntegrity.ps1 in development mode.
      3. The owner signs package\PackageIntegrity.psd1 (the verifier was signed in step 1; signing the manifest changes no listed file).
      4. .\tools\Build-Package.ps1 -Stage Package -RequireSignature
         the package is verified again (with -RequireSignature: the owner signature of the verifier, the manifest and every PowerShell file is
         mandatory), then (e) out\release\TeamsTransfer-<version>-win-x64.zip is created (and checked: its content list must equal the manifest
         plus PackageIntegrity.psd1 plus config\TeamsTransfer.config.psd1; it is extracted and verified), and (f) SHA256SUMS.txt is written.
      Without -Stage the default is All: steps (a) to (f) in one run, which gives an UNSIGNED development ZIP when nothing was signed (the
      script says so; such a ZIP starts only with -DevelopmentMode and is not to be published).
    Running -Stage Prepare again after the manifest was signed replaces the manifest: sign it again.

    The ZIP has one top folder TeamsTransfer-<version> (like the other products of the owner). Entries are sorted and use forward slashes.
    The package folder must not hold a store, reports or .local-test-data folder (they would end up in the manifest): the script refuses and
    names them. config\*.local.psd1 and the generated folders bin, data, logs and out are left out of the manifest and of the ZIP.

.PARAMETER PackageRoot
    The package folder. Default: ..\package of this script.

.PARAMETER OutputFolder
    Where the ZIP and SHA256SUMS.txt are written. Default: <repository>\out\release (the folder that holds package and tools).

.PARAMETER Stage
    All (default), Prepare (a to d) or Package (d to f, after the owner signed the manifest).

.PARAMETER SkipTests
    Do not run the test suite. Without it a failing test (or no tests folder) stops the build. The skip is written in the output.

.PARAMETER RequireSignature
    Verify the package as a release (owner signature mandatory) instead of in development mode. Use it for the real release.

.PARAMETER Force
    Replace an existing ZIP of the same name.

.EXAMPLE
    .\tools\Build-Package.ps1 -Stage Prepare
    Tests, documentation, manifest and its development-mode verification (after the owner signed the PowerShell files).

.EXAMPLE
    .\tools\Build-Package.ps1 -Stage Package -RequireSignature -Force
    After the owner signed the manifest: verifies the signed package, writes out\release\TeamsTransfer-<version>-win-x64.zip and SHA256SUMS.txt.

.EXAMPLE
    .\tools\Build-Package.ps1 -SkipTests
    Development build of everything in one run (documentation, manifest, ZIP) without the tests.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.2

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..\package'),
    [string]$OutputFolder,
    [ValidateSet('All', 'Prepare', 'Package')][string]$Stage = 'All',
    [switch]$SkipTests,
    [switch]$RequireSignature,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $root 'TeamsTransfer.psd1') -PathType Leaf)) { throw "Not a package folder (TeamsTransfer.psd1 not found): $root" }
$repo = Split-Path -Parent $root
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'TeamsTransfer.psd1')).ModuleVersion
if (-not $OutputFolder) { $OutputFolder = Join-Path $repo 'out\release' }
$OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
if ($OutputFolder.TrimEnd('\').StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $OutputFolder.TrimEnd('\') -ieq $root) { throw "-OutputFolder must be outside the package folder: $OutputFolder" }
$zipName = "TeamsTransfer-$version-win-x64.zip"
$zipPath = Join-Path $OutputFolder $zipName
$verifier = Join-Path $root 'src\Test-PackageIntegrity.ps1'
$pwshExe = (Get-Process -Id $PID).Path
$step = 0
function Write-Step([string]$Text) { $script:step++; Write-Host ("`n[{0}] {1}" -f $script:step, $Text) -ForegroundColor Cyan }

# Same lists as tools\Build-PackageManifest.ps1 and src\Test-PackageIntegrity.ps1.
$editableFiles = @('config\TeamsTransfer.config.psd1', 'config\TeamsTransfer.config.local.psd1')
$generatedFolders = @('bin', 'data', 'logs', 'out')
$forbiddenFolders = @('store', 'reports', '.local-test-data')

function Assert-CleanPackage {
    # Folders that must never be in a package: they would be listed in the manifest and shipped.
    foreach ($name in $forbiddenFolders) {
        if (Test-Path -LiteralPath (Join-Path $root $name)) { throw "The package folder holds '$name': remove it or move it outside the package (it would be listed in the manifest and shipped). $root\$name" }
    }
    $strayLocal = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Name -like '*.local.psd1' -and ($_.FullName.Substring($root.Length + 1)) -cne 'config\TeamsTransfer.config.local.psd1' })
    if ($strayLocal) { throw "Private configuration file(s) in the package (only config\TeamsTransfer.config.local.psd1 is tolerated, and it is never shipped): $(($strayLocal | ForEach-Object FullName) -join ', ')" }
}

function Get-ShippedFiles {
    # Relative paths (with backslashes) of the files that the ZIP holds: everything of the package except the local configuration and the generated folders.
    $prefix = $root + '\'
    foreach ($file in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
        $relative = $file.Substring($prefix.Length)
        if ($relative -ceq 'config\TeamsTransfer.config.local.psd1') { continue }
        if ($generatedFolders -contains $relative.Split('\')[0] -and $relative.Contains('\')) { continue }
        $relative
    }
}

function Invoke-Verifier([string]$Where = $root, [switch]$Release) {
    $v = Join-Path $Where 'src\Test-PackageIntegrity.ps1'
    $result = if ($Release) { & $v -Root $Where -Distribution } else { & $v -Root $Where -DevelopmentMode }
    Write-Host "      Verifier: $($result.Status) - $($result.Message)"
    if ($result.Status -notin 'Valid', 'UnsignedDevelopmentPackage') { throw "The package is not verified ($($result.Status)): $($result.Message)" }
    return $result
}

Write-Host "Teams Transfer $version - stage $Stage - package $root"
Assert-CleanPackage
$verified = $null

if ($Stage -in 'All', 'Prepare') {
    # (a) tests
    Write-Step 'Tests'
    if ($SkipTests) {
        Write-Warning '-SkipTests: the test suite was NOT run for this build.'
    } else {
        $tests = Join-Path $repo 'tests'
        if (-not (Test-Path -LiteralPath $tests -PathType Container)) { throw "The tests folder is not there ($tests): run the build from the repository, or give -SkipTests explicitly." }
        & $pwshExe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; `$r = Invoke-Pester -Path '$tests' -Output Minimal -PassThru; if (`$r.FailedCount -gt 0 -or `$r.Result -ne 'Passed') { exit 1 }"
        if ($LASTEXITCODE -ne 0) { throw 'The test suite failed: no package is built. Fix the tests (or, for a development build only, give -SkipTests).' }
    }

    # (b) documentation
    Write-Step 'Documentation (tools\Build-Documentation.ps1)'
    & (Join-Path $PSScriptRoot 'Build-Documentation.ps1')

    # (c) manifest
    Write-Step 'Integrity manifest (tools\Build-PackageManifest.ps1)'
    & (Join-Path $PSScriptRoot 'Build-PackageManifest.ps1') -PackageRoot $root

    # (d) verification
    Write-Step 'Verification of the manifest (development mode)'
    $verified = Invoke-Verifier
    if ($Stage -eq 'Prepare') {
        Write-Host "`nPrepared. Next: the owner signs PackageIntegrity.psd1, then  .\tools\Build-Package.ps1 -Stage Package -RequireSignature" -ForegroundColor Green
        return
    }
}

if ($Stage -eq 'Package') {
    Write-Step 'Verification of the package'
    $verified = Invoke-Verifier -Release:$RequireSignature
}

# (e) ZIP
Write-Step "ZIP ($zipName)"
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) { throw "$zipPath exists: add -Force to replace it." }
[void][IO.Directory]::CreateDirectory($OutputFolder)
$shipped = @(Get-ShippedFiles | Sort-Object { $_ } -CaseSensitive)
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'PackageIntegrity.psd1')
$expected = @(@($manifest.Files | ForEach-Object { $_.Path }) + 'PackageIntegrity.psd1' + 'config\TeamsTransfer.config.psd1' | Sort-Object -Unique -CaseSensitive)
$diff = @(Compare-Object -ReferenceObject $expected -DifferenceObject $shipped -CaseSensitive)
if ($diff) { throw "The files of the package do not match the manifest: $(($diff | Select-Object -First 8 | ForEach-Object { "$($_.InputObject) ($(if ($_.SideIndicator -eq '<=') { 'listed, not found' } else { 'found, not listed' }))" }) -join '; '). Run -Stage Prepare again." }
$top = "TeamsTransfer-$version"
$tmpZip = "$zipPath.tmp"
if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force }
$fs = [IO.File]::Create($tmpZip)
try {
    $archive = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($relative in $shipped) {
            $source = Join-Path $root $relative
            $entry = $archive.CreateEntry($top + '/' + $relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new([Math]::Max(([IO.File]::GetLastWriteTimeUtc($source)).Ticks, ([DateTime]'1980-01-01').Ticks), [TimeSpan]::Zero)
            $in = [IO.File]::OpenRead($source); $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $fs.Dispose() }
Move-Item -LiteralPath $tmpZip -Destination $zipPath -Force

# the ZIP is read back: its content list must be exactly the shipped list, and the extracted copy must verify
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try { $inZip = @($zip.Entries | ForEach-Object { $_.FullName.Substring($top.Length + 1).Replace('/', '\') } | Sort-Object { $_ } -CaseSensitive) } finally { $zip.Dispose() }
if (@(Compare-Object -ReferenceObject $shipped -DifferenceObject $inZip -CaseSensitive).Count) { throw 'The ZIP content list differs from the package content: the ZIP is not kept.' }
$check = Join-Path ([IO.Path]::GetTempPath()) ('tt-zipcheck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $check)
    [void](Invoke-Verifier -Where (Join-Path $check $top) -Release:$RequireSignature)
} finally { Remove-Item -LiteralPath $check -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("      {0}: {1} files, {2:N1} MB" -f $zipPath, $shipped.Count, ((Get-Item -LiteralPath $zipPath).Length / 1MB))

# (f) SHA256SUMS.txt
Write-Step 'SHA256SUMS.txt'
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputFolder 'SHA256SUMS.txt'), "$hash  $zipName`n", [Text.UTF8Encoding]::new($false))
Write-Host "      $hash  $zipName"

if ($verified -and $verified.Status -ne 'Valid') {
    Write-Warning 'UNSIGNED development ZIP: the verifier and the manifest do not carry the owner signature. It starts only with -DevelopmentMode and must not be published. For a release: sign, then -Stage Prepare, sign the manifest, then -Stage Package -RequireSignature.'
}
Write-Host "`nDone: $zipPath" -ForegroundColor Green
