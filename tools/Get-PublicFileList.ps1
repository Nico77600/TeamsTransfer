#Requires -Version 7.4

<#
.SYNOPSIS
    Lists the tracked files of this private repository that belong in the public repository, and nothing else.

.DESCRIPTION
    The private development repository tracks files that must never be published: the design record and the Phase 0 lab notes (docs\design, they
    name the lab tenant), the raw Phase 0 output (tools\phase0-output) and private configuration (*.local.psd1). The release preparation calls this
    script to build the public candidate: it copies exactly the listed files (their bytes, from the Git index or the working tree), never the
    whole tree.

    The list is the output of `git ls-files` minus the exclusion rules below. Untracked and ignored files are never listed. The script also
    stops with an error when a rule of the public documentation would be broken by the list: a file that is required in the public repository
    is missing, or a public Markdown file links to an excluded file.

    Exclusion rules (repository-relative, forward slashes):
      docs/design/**        design record and Phase 0 runbook (private)
      tools/phase0-output/** raw Phase 0 output (private)
      **/*.local.psd1       private configuration
      **/*.local-test-data/** local test data

.PARAMETER RepositoryPath
    The repository root. Default: the parent of this script's folder.

.PARAMETER OutputPath
    Optional file that receives the list (UTF-8, one path per line, forward slashes, sorted). The list is always written to the output stream too.

.PARAMETER Count
    Write only the number of public files.

.EXAMPLE
    .\tools\Get-PublicFileList.ps1
    The public paths, one per line.

.EXAMPLE
    .\tools\Get-PublicFileList.ps1 -OutputPath C:\Temp\public-files.txt
    Also writes the list to a file for the release preparation.
#>
[CmdletBinding()]
param(
    [string]$RepositoryPath = (Join-Path $PSScriptRoot '..'),
    [string]$OutputPath,
    [switch]$Count
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepositoryPath).Path.TrimEnd('\')
$git = (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
$tracked = @(& $git -C $root -c core.quotepath=off ls-files)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }

$excluded = @(
    '^docs/design/',
    '^tools/phase0-output/',
    '(?i)\.local\.psd1$',
    '(?i)(^|/)\.local-test-data/'
)
$public = @($tracked | Where-Object { $p = $_; -not ($excluded | Where-Object { $p -match $_ }) } | Sort-Object -Culture ([cultureinfo]::InvariantCulture) -CaseSensitive)

# The files the public documentation standard needs must be in the list.
$required = @('README.md', 'SECURITY.md', 'package/README.md', 'package/LICENSE', '.github/ci.json', '.github/workflows/ci.yml')
$missing = @($required | Where-Object { $_ -cnotin $public })
if ($missing) { throw ('Required public files are not tracked or are excluded: ' + ($missing -join ', ')) }

# A public Markdown file must not point at an excluded file (the link would be broken in the public repository).
$broken = foreach ($file in @($public | Where-Object { $_ -match '\.md$' })) {
    $text = [IO.File]::ReadAllText((Join-Path $root $file))
    foreach ($m in [regex]::Matches($text, '(?<!\!)\[[^\]]*\]\(([^)\s#]+)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^(?i:https?|mailto):') { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path (Join-Path $root $file) -Parent) $target)).Substring($root.Length + 1).Replace('\', '/')
        if ($resolved -cin $tracked -and $resolved -cnotin $public) { "$file -> $resolved" }
    }
}
if ($broken) { throw ('Public Markdown files link to excluded files: ' + (@($broken) -join '; ')) }

if ($OutputPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($public -join "`n") + "`n"), [Text.UTF8Encoding]::new($false)) }
if ($Count) { $public.Count } else { $public }
