#Requires -Version 7.4
<#
.SYNOPSIS
    Verifies the Teams Transfer package before any of its code runs.

.DESCRIPTION
    Invoked by Invoke-TeamsTransfer.ps1 (and by the package builder). It checks PackageIntegrity.psd1, the manifest written by
    tools\Build-PackageManifest.ps1: the SHA256 of every file of the package. Missing, changed, unlisted, duplicated or
    reparse-point files fail closed.

    Three states, always reported explicitly in the result (Status) and in Message:
      Valid                        the verifier, the manifest and every PowerShell file carry the trusted, timestamped owner signature
                                   and every hash matches. The only state of a release package.
      UnsignedDevelopmentPackage   a manifest exists but the owner signature is missing (the owner signs a release later). The hashes are
                                   still enforced. Accepted only with -DevelopmentMode.
      UnverifiedDevelopmentTree    no manifest (a source checkout). Nothing is verified: package byte integrity and publisher
                                   authentication are NOT established. Accepted only with -DevelopmentMode.
    There is no silent bypass: any other situation throws.

    Not protected, by design: config\TeamsTransfer.config.psd1 and config\TeamsTransfer.config.local.psd1 (edited by the administrator, data
    that is never executed) and the generated folders bin\, data\, logs\ and out\ (no compiled cache is ever loaded).

.PARAMETER Root
    Package folder to verify, not its src subfolder. This script must belong to that package's src folder.

.PARAMETER Distribution
    Verifies a release package: the owner signature is mandatory. Refused together with -DevelopmentMode.

.PARAMETER DevelopmentMode
    For a source tree or a developer package: accepts the two development states above (the hashes of a manifest that is there are still enforced).

.OUTPUTS
    PSCustomObject (Status, Signed, FileCount, Message).

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.1
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [switch]$Distribution, [switch]$DevelopmentMode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Distribution -and $DevelopmentMode) { throw 'Package integrity: -Distribution and -DevelopmentMode cannot be combined.' }
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
$releaseHint = 'Use the complete release ZIP (https://github.com/Nico77600/TeamsTransfer/releases/latest): extract it again and unblock it. A modified, re-saved or unsigned file cannot be started. A source checkout is started with -DevelopmentMode.'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
# Written or edited by the administrator; data, never executed.
$editableFiles = @('config\TeamsTransfer.config.psd1', 'config\TeamsTransfer.config.local.psd1')
# Created at run time, never loaded as code: exact names, at the package root only.
$generatedFolders = @('bin', 'data', 'logs', 'out')
# Files that every manifest must list.
$required = @(
    'Invoke-TeamsTransfer.ps1', 'TeamsTransfer.psd1', 'TeamsTransfer.psm1', 'TeamsTransfer.Console.ps1', 'TeamsTransfer.Export.ps1', 'TeamsTransfer.Archive.ps1',
    'src\Test-PackageIntegrity.ps1', 'src\Engine.Store.cs', 'src\Engine.Auth.cs', 'lib\sqlite\Microsoft.Data.Sqlite.dll',
    'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'templates\Archive.template.html', 'templates\Archive.template.js'
)
$codeExtensions = @('.ps1', '.psm1', '.psd1')

function Assert-PlainPath([string]$Path, [bool]$Directory = $false) {
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.PSIsContainer -ne $Directory) {
        throw "Package integrity: unsafe path or unexpected type: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($parent) {
        $ancestor = Microsoft.PowerShell.Management\Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package integrity: reparse-point ancestor: $parent" }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
function Test-OwnerSignature([string]$Path) {
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    return ([string]$signature.Status -ceq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Thumbprint -ceq $signer -and $null -ne $signature.TimeStamperCertificate)
}
function Test-RelativePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.StartsWith('\') -or $Path.Contains('/') -or $Path.Contains(':')) { return $false }
    foreach ($part in $Path.Split('\')) { if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { return $false } }
    return $true
}

Assert-PlainPath $rootPath $true
if (-not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::Combine($rootPath, 'src', 'Test-PackageIntegrity.ps1'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package integrity: verifier must belong to this package root.'
}
Assert-PlainPath $PSCommandPath

$manifestPath = [IO.Path]::Combine($rootPath, 'PackageIntegrity.psd1')
if (-not [IO.File]::Exists($manifestPath)) {
    if (-not $DevelopmentMode) { throw "Package integrity: PackageIntegrity.psd1 is missing. $releaseHint" }
    return [pscustomobject][ordered]@{
        Status = 'UnverifiedDevelopmentTree'; Signed = $false; FileCount = 0
        Message = 'Unverified development tree: no PackageIntegrity.psd1, so package byte integrity and publisher authentication are not established.'
    }
}
Assert-PlainPath $manifestPath

# Signature state: the verifier and the manifest must both carry the owner signature.
$signed = (Test-OwnerSignature $PSCommandPath) -and (Test-OwnerSignature $manifestPath)
if (-not $signed -and -not $DevelopmentMode) {
    throw "Package integrity: unsigned development package. The verifier and PackageIntegrity.psd1 must carry the trusted, timestamped owner signature. $releaseHint"
}
if ($Distribution -and -not $signed) { throw "Package integrity: a release package must be signed by the owner. $releaseHint" }

# The raw PSD1 is authenticated (when signed) before its restricted data language is parsed.
$manifest = Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
if ($manifest.Count -ne 5 -or -not $manifest.ContainsKey('SchemaVersion') -or -not $manifest.ContainsKey('Algorithm') -or
    -not $manifest.ContainsKey('SignerThumbprint') -or -not $manifest.ContainsKey('Version') -or -not $manifest.ContainsKey('Files') -or
    $manifest.SchemaVersion -isnot [int] -or $manifest.SchemaVersion -ne 1 -or $manifest.Algorithm -cne 'SHA256' -or
    $manifest.SignerThumbprint -cne $signer -or $manifest.Version -isnot [string] -or $manifest.Files -isnot [array]) {
    throw 'Package integrity: unsupported or incomplete manifest schema.'
}
$listed = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.Files) {
    if ($entry -isnot [hashtable] -or $entry.Count -ne 2 -or -not $entry.ContainsKey('Path') -or -not $entry.ContainsKey('Sha256') -or
        $entry.Path -isnot [string] -or $entry.Sha256 -isnot [string] -or $entry.Sha256 -cnotmatch '^[0-9A-F]{64}$' -or
        -not (Test-RelativePath $entry.Path) -or $entry.Path -ceq 'PackageIntegrity.psd1' -or $entry.Path -cin $editableFiles -or
        -not $listed.TryAdd($entry.Path, $entry.Sha256)) {
        throw 'Package integrity: invalid, duplicate or unapproved inventory path/hash.'
    }
}
foreach ($path in $required) { if (-not $listed.ContainsKey($path)) { throw "Package integrity: required file missing from the manifest: $path" } }

# Every listed file exists, is a plain file and matches; every file of the package is listed.
$problems = [Collections.Generic.List[string]]::new()
foreach ($kv in $listed.GetEnumerator()) {
    $full = [IO.Path]::Combine($rootPath, $kv.Key)
    if (-not [IO.File]::Exists($full)) { $problems.Add("missing: $($kv.Key)"); continue }
    Assert-PlainPath $full
    if ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -cne $kv.Value) { $problems.Add("changed: $($kv.Key)"); continue }
    if ($signed -and [IO.Path]::GetExtension($full).ToLowerInvariant() -in $codeExtensions -and -not (Test-OwnerSignature $full)) { $problems.Add("not signed by the owner: $($kv.Key)") }
}
$prefix = $rootPath + '\'
foreach ($file in [IO.Directory]::EnumerateFiles($rootPath, '*', [IO.SearchOption]::AllDirectories)) {
    $relative = $file.Substring($prefix.Length)
    if ($relative -ceq 'PackageIntegrity.psd1' -or $relative -cin $editableFiles) { continue }
    if ($generatedFolders -contains $relative.Split('\')[0] -and $relative.Contains('\')) { continue }
    if (-not $listed.ContainsKey($relative)) { $problems.Add("unlisted: $relative") }
}
if ($problems.Count -gt 0) {
    $shown = ($problems | Select-Object -First 10) -join '; '
    throw "Package integrity: $($problems.Count) problem(s): $shown$(if ($problems.Count -gt 10) { '; ...' }). $releaseHint"
}
if ($signed) {
    return [pscustomobject][ordered]@{ Status = 'Valid'; Signed = $true; FileCount = $listed.Count; Message = "Package verified: $($listed.Count) files, owner signature valid." }
}
return [pscustomobject][ordered]@{
    Status = 'UnsignedDevelopmentPackage'; Signed = $false; FileCount = $listed.Count
    Message = "Unsigned development package: $($listed.Count) file hashes match the manifest, but the owner signature is missing, so publisher authentication is not established."
}
