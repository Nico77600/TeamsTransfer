#Requires -Version 7.4
<#
.SYNOPSIS
    CI only. Runs the existing package builder (tools\Build-Package.ps1) on a disposable copy and extracts the unsigned development ZIP into -Destination.
.DESCRIPTION
    Invoke-CI.ps1 calls its package builder as: <builder> -Destination <folder>, then looks for the package entry point in that folder.
    tools\Build-Package.ps1 has another interface (it writes a ZIP and a manifest next to the package folder), so this adapter copies package\ and
    tools\ to a temporary tree, runs the real builder there (-SkipTests: the tests have their own CI step), and extracts the ZIP without its top folder.
    The checked-out tree is not changed. Nothing is signed, published or sent anywhere; the ZIP is a development build.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'The destination already exists; it will not be overwritten.' }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('tt-ci-package-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($temp)
try {
    Copy-Item -LiteralPath (Join-Path $root 'package') -Destination (Join-Path $temp 'package') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'tools') -Destination (Join-Path $temp 'tools') -Recurse -Exclude 'phase0-output'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    & $pwsh -NoProfile -NonInteractive -File (Join-Path $temp 'tools\Build-Package.ps1') -SkipTests
    if ($LASTEXITCODE -ne 0) { throw "The package builder failed with exit code $LASTEXITCODE." }
    $zip = @(Get-ChildItem -LiteralPath (Join-Path $temp 'out\release') -Filter '*.zip' -File)
    if ($zip.Count -ne 1) { throw 'The package builder did not produce exactly one ZIP.' }
    $extract = Join-Path $temp 'extract'
    Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $extract
    $top = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($top.Count -ne 1) { throw 'The ZIP must hold exactly one top folder.' }
    Move-Item -LiteralPath $top[0].FullName -Destination $Destination
    Write-Output ('Development package extracted to {0} from {1}.' -f $Destination, $zip[0].Name)
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
