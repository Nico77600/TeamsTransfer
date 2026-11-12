#Requires -Version 7.4

<#
.SYNOPSIS
    Teams Transfer console: a WPF window over the same module functions and the same engine as Invoke-TeamsTransfer.ps1.

.DESCRIPTION
    Started by Invoke-TeamsTransfer.ps1 -Gui (or Start-TeamsTransferConsole.cmd): pwsh -STA -File .\Invoke-TeamsTransfer.ps1 -Gui.
    A guided flow in five steps: 1 Setup (store, configuration, Source and Target tenant with traffic lights), 2 Task, 3 Verify, 4 Run, 5 Next steps.
    The tasks: Estimate (Assess), Export conversations (Inventory, Export, Files), Browse the archive (the Teams-like viewer, WebView2), Import a lot
    (Plan, Ghosts, Copy files, Import, chained) and Verify a lot (Verify, Report). Every step of a task calls the same module function as its command
    line mode, in a background runspace, with a stop file, a live progress line and the house log. The task that writes into the target tenant
    previews first (nothing runs on page load) and asks for an explicit Apply, with a confirmation, on the Verify step.

    -Demo uses a synthetic source tenant, a synthetic target tenant and a temporary store (the demo sources of package\demo (a synthetic tenant and a fake Graph) are compiled with the
    engine in this mode only): every page works offline, for screenshots, tests and demonstrations. A DEMO badge is always visible.

    Needs lib\gui (Wpf.Ui, WebView2): tools\Get-TeamsTransferDependencies.ps1 installs them, pinned and verified (dependency-lock.json).
    The Microsoft Edge WebView2 runtime is not redistributed: without it the Explorer shows a message and everything else works.

.PARAMETER Demo
    Synthetic tenants and a temporary store.

.PARAMETER Harness
    Builds the window and returns the console state without showing it (the tests and tools\New-ConsoleScreens.ps1 drive it).

.PARAMETER Theme
    System (default, follows Windows), Light or Dark for this session.

.PARAMETER SettingsPath
    The settings file (default: %LOCALAPPDATA%\TeamsTransfer\console-settings.json; Demo mode saves nothing unless given).

.PARAMETER ConfigPath
    A configuration file other than config\TeamsTransfer.config.psd1.

.PARAMETER DemoRoot
    Demo mode: the temporary folder (store, logs, reports). Default: a new folder under the temp folder.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.1

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding()]
param(
    [switch]$Demo,
    [switch]$Harness,
    [ValidateSet('System', 'Light', 'Dark')][string]$Theme,
    [string]$SettingsPath,
    [string]$ConfigPath,
    [string]$DemoRoot,
    [ValidateRange(0, 4000)][int]$Width = 0,
    [ValidateRange(0, 4000)][int]$Height = 0
)
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The console needs an STA thread. Start it with: pwsh -STA -File .\Invoke-TeamsTransfer.ps1 -Gui (or use Start-TeamsTransferConsole.cmd).'
}
if (-not $IsWindows) { throw 'The console runs on Windows only (WPF).' }

# 1. WPF and the pinned libraries (lib\gui). Checked against dependency-lock.json by tools\Get-TeamsTransferDependencies.ps1 -Verify.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing
$guiLib = Join-Path $packageRoot 'lib\gui'
foreach ($dll in 'Wpf.Ui.Abstractions.dll', 'Wpf.Ui.dll') {
    $p = Join-Path $guiLib $dll
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing $p. Run tools\Get-TeamsTransferDependencies.ps1 (it downloads the pinned libraries from nuget.org and verifies them)." }
    if (-not ('Wpf.Ui.Controls.FluentWindow' -as [type]) -or $dll -eq 'Wpf.Ui.Abstractions.dll') { Add-Type -LiteralPath $p }
}

# 2. WebView2 (managed libraries + native loader). A failure here is not fatal: the Explorer shows the reason.
$webView2Error = $null
try {
    if (-not ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
        $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
        $loader = Join-Path $guiLib "runtimes\$arch\native\WebView2Loader.dll"
        foreach ($p in $loader, (Join-Path $guiLib 'Microsoft.Web.WebView2.Core.dll'), (Join-Path $guiLib 'Microsoft.Web.WebView2.Wpf.dll')) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing $p (run tools\Get-TeamsTransferDependencies.ps1)." }
        }
        [void][Runtime.InteropServices.NativeLibrary]::Load($loader)
        Add-Type -LiteralPath (Join-Path $guiLib 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -LiteralPath (Join-Path $guiLib 'Microsoft.Web.WebView2.Wpf.dll')
    }
} catch { $webView2Error = "The WebView2 libraries could not be loaded: $($_.Exception.Message)" }

# 3. The module and the engine (Demo: compiled together with the synthetic tenant and the fake Graph transport).
Import-Module (Join-Path $packageRoot 'TeamsTransfer.psd1') -Force
. (Join-Path $packageRoot 'TeamsTransfer.Gui.Demo.ps1')
$support = @()
if ($Demo) {
    $support = @(Get-TtgDemoSupportFiles -PackageRoot $packageRoot)
    Write-Host 'Teams Transfer console (Demo): compiling the engine with the synthetic tenant...'
    Initialize-TmtEngine -AdditionalSource $support
} else {
    Initialize-TmtEngine
}

# 4. The console code lives in an in-memory module so that every event handler shares its state ($script: scope).
$guiFiles = @('TeamsTransfer.Gui.Jobs.ps1', 'TeamsTransfer.Gui.Demo.ps1', 'TeamsTransfer.Gui.Core.ps1', 'TeamsTransfer.Gui.Wizard.ps1')
$guiModule = New-Module -Name TeamsTransferGui -ArgumentList $packageRoot, $guiFiles -ScriptBlock {
    param($Root, $Files)
    foreach ($f in $Files) { . (Join-Path $Root $f) }
    Export-ModuleMember -Function *
}
Import-Module $guiModule -Global -Force

$startArgs = @{ PackageRoot = $packageRoot; Demo = $Demo; Harness = $Harness; Support = $support; WebView2Error = $webView2Error; Width = $Width; Height = $Height }
foreach ($n in 'Theme', 'SettingsPath', 'ConfigPath', 'DemoRoot') { $v = Get-Variable -Name $n -ValueOnly; if ($v) { $startArgs[$n] = $v } }
Start-TtgConsole @startArgs
