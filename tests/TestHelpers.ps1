# Shared by every *.Tests.ps1: imports the module and compiles the engine together with package\demo\*.cs (the synthetic tenant and the fake Graph, shared with the console Demo mode) and tests\support\*.cs.
# Usage, in BeforeAll:  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:PackageRoot = Join-Path $script:RepoRoot 'package'
Import-Module (Join-Path $script:PackageRoot 'TeamsTransfer.psm1') -Force
$support = @(@(Get-ChildItem -LiteralPath (Join-Path $script:PackageRoot 'demo') -Filter *.cs -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'support') -Filter *.cs -File -ErrorAction SilentlyContinue) | Sort-Object Name | ForEach-Object FullName)
Initialize-TmtEngine -Root $script:PackageRoot -AdditionalSource $support
