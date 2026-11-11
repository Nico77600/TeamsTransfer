#Requires -Version 5.1
<#
.SYNOPSIS
    CI only. Makes sure that the pwsh used by the next steps is PowerShell 7.5 or later (the engine requires 7.5+).
.DESCRIPTION
    The GitHub-hosted Windows images ship PowerShell 7.4. If pwsh on PATH is older than 7.5, the pinned release below is
    downloaded from the official PowerShell release page, its SHA-256 is checked against the value pinned here (the same value
    appears in the hashes.sha256 asset of the release), it is extracted under RUNNER_TEMP and put first on PATH for the
    following steps. A full extracted copy keeps pwsh.exe inside $PSHOME, which the engine needs to start its child processes.
    It does not connect to a lab or use publication credentials.
#>
[CmdletBinding()]
param(
    [string]$Version = '7.5.13',
    [string]$Sha256 = '120B8F0B04F3B3F6E8C351DDBE568BF596CDCA15EEB2ECB7E724060051A36D65'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$minimum = [version]'7.5.0'

function Get-PwshVersion {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    $text = & $command.Source -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0) { return $null }
    return [version](($text | Select-Object -First 1) -replace '[-+].*$', '')
}

$current = Get-PwshVersion
if ($current -and $current -ge $minimum) {
    Write-Output ('pwsh {0} already satisfies PowerShell 7.5+.' -f $current)
    return
}

$runnerTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$zip = Join-Path $runnerTemp ('PowerShell-{0}-win-x64.zip' -f $Version)
$destination = Join-Path $runnerTemp ('pwsh-{0}' -f $Version)
$uri = 'https://github.com/PowerShell/PowerShell/releases/download/v{0}/PowerShell-{0}-win-x64.zip' -f $Version
Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if (-not [string]::Equals($actual, $Sha256, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $zip -Force
    throw "The downloaded PowerShell archive does not match the pinned SHA-256 ($actual)."
}
if (Test-Path -LiteralPath $destination) { throw "The destination already exists and will not be overwritten: $destination" }
Expand-Archive -LiteralPath $zip -DestinationPath $destination
if (-not (Test-Path -LiteralPath (Join-Path $destination 'pwsh.exe') -PathType Leaf)) { throw 'The archive does not contain pwsh.exe.' }
if (-not $env:GITHUB_PATH) { throw 'The GitHub Actions path file is missing.' }
$destination | Out-File -LiteralPath $env:GITHUB_PATH -Encoding utf8 -Append
Write-Output ('PowerShell {0} extracted to {1} and added to PATH for the next steps.' -f $Version, $destination)
