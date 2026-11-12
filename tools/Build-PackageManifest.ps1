#Requires -Version 7.4

<#
.SYNOPSIS
    Writes package\PackageIntegrity.psd1: the SHA256 of every file of the Teams Transfer package.

.DESCRIPTION
    The manifest is what src\Test-PackageIntegrity.ps1 checks before any code of the package runs. This script writes the
    list; it does not sign anything. The owner signs the release later:

      1. sign the PowerShell files of the package (Set-AuthenticodeSignature, trusted timestamped certificate 0F28E442...);
      2. run this script again (the hashes of the signed files are what the manifest must hold);
      3. sign src\Test-PackageIntegrity.ps1 and PackageIntegrity.psd1 itself.

    Until then the manifest is an "unsigned development package": the verifier says so and Invoke-TeamsTransfer.ps1 runs it only with
    -DevelopmentMode. Without any manifest a source checkout is an "unverified development tree" (also -DevelopmentMode only).

    Not listed, by design: PackageIntegrity.psd1 itself, config\TeamsTransfer.config.psd1 and config\TeamsTransfer.config.local.psd1
    (administrator data) and the generated folders bin\, data\, logs\, out\.

.PARAMETER PackageRoot
    The package folder. Default: ..\package of this script.

.PARAMETER OutputPath
    Where to write the manifest. Default: <PackageRoot>\PackageIntegrity.psd1.

.PARAMETER Version
    Version recorded in the manifest. Default: the ModuleVersion of TeamsTransfer.psd1.

.EXAMPLE
    .\tools\Build-PackageManifest.ps1
    Writes package\PackageIntegrity.psd1 and checks it with the verifier (development mode).

.EXAMPLE
    .\tools\Build-PackageManifest.ps1 -WhatIf
    Shows the file count without writing anything.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.2

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..\package'),
    [string]$OutputPath,
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
$root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Package folder not found: $root" }
if (-not $OutputPath) { $OutputPath = Join-Path $root 'PackageIntegrity.psd1' }
if (-not $Version) { $Version = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'TeamsTransfer.psd1')).ModuleVersion }
# Same exclusions as src\Test-PackageIntegrity.ps1.
$editableFiles = @('config\TeamsTransfer.config.psd1', 'config\TeamsTransfer.config.local.psd1')
$generatedFolders = @('bin', 'data', 'logs', 'out')

$prefix = $root + '\'
$entries = foreach ($file in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
    $relative = $file.Substring($prefix.Length)
    if ($relative -ceq 'PackageIntegrity.psd1' -or $relative -cin $editableFiles) { continue }
    if ($generatedFolders -contains $relative.Split('\')[0] -and $relative.Contains('\')) { continue }
    if ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in the package: $relative" }
    [pscustomobject]@{ Path = $relative; Sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
}
$entries = @($entries | Sort-Object { $_.Path } -CaseSensitive)

$text = [Text.StringBuilder]::new()
[void]$text.AppendLine('@{')
[void]$text.AppendLine('    SchemaVersion = 1')
[void]$text.AppendLine("    Algorithm = 'SHA256'")
[void]$text.AppendLine("    SignerThumbprint = '$signer'")
[void]$text.AppendLine("    Version = '$Version'")
[void]$text.AppendLine('    Files = @(')
foreach ($e in $entries) { [void]$text.AppendLine(("        @{{ Path = '{0}'; Sha256 = '{1}' }}" -f $e.Path.Replace("'", "''"), $e.Sha256)) }
[void]$text.AppendLine('    )')
[void]$text.AppendLine('}')

if ($PSCmdlet.ShouldProcess($OutputPath, "Write the SHA256 list of $($entries.Count) files")) {
    [IO.File]::WriteAllText($OutputPath, $text.ToString().Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Host "Manifest written: $OutputPath ($($entries.Count) files)"
    if ([IO.Path]::GetFullPath($OutputPath) -ieq (Join-Path $root 'PackageIntegrity.psd1')) {
        $result = & (Join-Path $root 'src\Test-PackageIntegrity.ps1') -Root $root -DevelopmentMode
        Write-Host "Verifier: $($result.Status) - $($result.Message)"
    }
    Write-Host 'The owner signs the PowerShell files, the verifier and the manifest later (see Get-Help).'
} else {
    Write-Host "WhatIf: $($entries.Count) files would be listed in $OutputPath"
}
