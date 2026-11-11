#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'
[void][IO.Directory]::CreateDirectory($Destination)
Save-Module -Name Pester -RequiredVersion 6.1.0 -Repository PSGallery -Path $Destination -Force -ErrorAction Stop
Save-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Repository PSGallery -Path $Destination -Force -ErrorAction Stop

foreach ($module in @(
    @{ Name = 'Pester'; Version = '6.1.0' },
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
)) {
    $manifest = Join-Path $Destination ('{0}\{1}\{0}.psd1' -f $module.Name, $module.Version)
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "The pinned module was not saved: $manifest"
    }
    $data = Import-PowerShellDataFile -LiteralPath $manifest
    if ([string]$data.ModuleVersion -cne $module.Version) {
        throw "The saved module version does not match: $manifest"
    }
}

if (-not $env:GITHUB_ENV) { throw 'The GitHub Actions environment file is missing.' }
'CI_MODULE_PATH={0}' -f [IO.Path]::GetFullPath($Destination) |
    Out-File -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Append
