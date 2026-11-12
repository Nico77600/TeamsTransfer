#Requires -Version 7.4
<#
.SYNOPSIS
    Takes the screenshots of the console for the user guide: starts the console in Demo mode, runs the pages in the order of the guided path,
    and saves package\docs\images\console-<page>-light.png and -dark.png.

.DESCRIPTION
    No tenant and no network: the Demo mode uses synthetic tenants and a temporary store. The pages are driven through the console's own functions
    (the same ones the buttons call), so a screenshot shows what an operator sees after pressing Run. Every page is captured in both themes.
    The window is rendered by WPF (deterministic, never the real screen); the WebView2 picture of the Explorer is taken from the control itself.
    Run it in a desktop session; it restarts itself in pwsh -STA when needed.

    The console is a guided flow (Setup, Task, Verify, Run, Next steps): the images are named console-<step>[-<task>]-<theme>.png.

.PARAMETER OutDir
    Where the PNG files go (default: package\docs\images).

.PARAMETER Width
    Window width (default 1320).

.PARAMETER Height
    Window height (default 860).

.PARAMETER Pages
    Only these page names (default: all). Names are the image names without the theme, for example setup, task, verify-export, run-import.

.EXAMPLE
    pwsh -STA -File .\tools\New-ConsoleScreens.ps1

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.1

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [ValidateRange(800, 3000)][int]$Width = 1320,
    [ValidateRange(600, 2000)][int]$Height = 940,
    [string[]]$Pages
)
$ErrorActionPreference = 'Stop'
trap { Write-Host ($_ | Out-String); Write-Host $_.ScriptStackTrace; exit 1 }
$packageRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'package'
if (-not $OutDir) { $OutDir = Join-Path $packageRoot 'docs\images' }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $argsList = @('-NoLogo', '-NoProfile', '-STA', '-File', $PSCommandPath, '-OutDir', $OutDir, '-Width', $Width, '-Height', $Height)
    if ($Pages) { $argsList += @('-Pages', ($Pages -join ',')) }
    & (Get-Process -Id $PID).Path @argsList
    exit $LASTEXITCODE
}
if ($Pages) { $Pages = @($Pages | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) }

$T = & (Join-Path $packageRoot 'TeamsTransfer.Gui.ps1') -Demo -Harness -Theme Light -Width $Width -Height $Height
$T.NoShell = $true
$T.ConfirmHook = { param($title, $message) $true }
$w = $T.Window
$w.Left = 40; $w.Top = 30; $w.WindowStartupLocation = 'Manual'
$w.Show()
[void](Wait-TtgUi -MinimumMilliseconds 800)

$shots = [Collections.Generic.List[string]]::new()
function Wait-Chain { param([int]$Seconds = 400) $ok = Wait-TtgUi -Until { $c = (Get-TtgState).Chain; (-not $c) -or $c.Done } -TimeoutSeconds $Seconds; if (-not $ok) { throw 'A task did not finish in time.' }; [void](Wait-TtgUi -MinimumMilliseconds 500) }
function Next-Step { Invoke-TtgPrimary; [void](Wait-TtgUi -MinimumMilliseconds 400) }
function Set-Scope { param([string]$Scope, [string]$Field, [string]$Value) Set-TtgScope -Key $Scope; $f = (Get-TtgState).Form[(Get-TtgState).Task].Scopes[$Scope][$Field]; if ($f.Type -eq 'check') { $f.Control.IsChecked = [bool]$Value } else { $f.Control.Text = $Value }; Update-TtgTaskText }
function Snap {
    param([string]$Name, [int]$Settle = 500, [switch]$Bottom)
    if ($Pages -and $Name -notin $Pages) { return }
    $sv = (Get-TtgState).Ui.StepHost.Content
    if ($sv -is [System.Windows.Controls.ScrollViewer]) { if ($Bottom) { $sv.ScrollToEnd() } else { $sv.ScrollToHome() } }
    foreach ($theme in 'Light', 'Dark') {
        $null = Set-TtgTheme -Requested $theme
        (Get-TtgState).Ui["Theme$theme"].IsChecked = $true
        [void](Wait-TtgUi -MinimumMilliseconds $Settle)
        $path = Join-Path $OutDir ("console-{0}-{1}.png" -f $Name, $theme.ToLowerInvariant())
        [void](Save-TtgWindowImage -Path $path)
        $shots.Add($path)
    }
    $null = Set-TtgTheme -Requested Light; (Get-TtgState).Ui.ThemeLight.IsChecked = $true
}

# 1 Setup
Start-TtgRoleCheck -Side Source; Start-TtgRoleCheck -Side Target
Select-TtgStep 1; Update-TtgSetup
Snap setup

# Estimate (short): task, run
Set-TtgTask -Key Estimate; Select-TtgStep 2; Snap task-estimate
Next-Step; Snap verify-estimate
Next-Step; Wait-Chain; Snap run-estimate
Next-Step; Snap next-estimate

# Export: single user test, then the whole demo store
Reset-TtgRun; Set-TtgTask -Key Export; Select-TtgStep 2
Set-Scope user Users 'camille.martin@contoso.com'
Snap task
Set-TtgScope -Key all
Next-Step; Snap verify-export
Next-Step; Wait-Chain; Snap run-export
Next-Step; Snap next-export

# Browse the archive
Reset-TtgRun; Set-TtgTask -Key Browse; Select-TtgStep 2; Snap task-browse
Next-Step; Snap verify-browse
Next-Step
$px = (Get-TtgState).Pages.Explorer.Root
$px.FindName('ModeChats').IsChecked = $true; (Get-TtgState).Explorer.Mode = 'Chats'; Update-TtgExplorerList
$list = $px.FindName('ExplorerList')
$pick = $list.Items | Where-Object { $_.Tag.Title -like 'Project Moon*' } | Select-Object -First 1
if (-not $pick) { $pick = $list.Items | Select-Object -First 1 }
if ($pick) { $pick.IsSelected = $true; [void](Wait-TtgUi -Until { (Get-TtgState).Explorer.LastNavigationOk -or (Get-TtgState).WebView2Error } -TimeoutSeconds 90); [void](Wait-TtgUi -MinimumMilliseconds 2500) }
Snap explorer -Settle 1500

# Import a lot: a team, preview, Apply
Reset-TtgRun; Set-TtgTask -Key Import; Select-TtgStep 2
Set-Scope user Users 'camille.martin@contoso.com'
Snap task-import
Next-Step; Snap verify-import
Next-Step; Wait-Chain; Select-TtgStep 3; [void](Wait-TtgUi -MinimumMilliseconds 500)
Snap verify-import-preview
Snap verify-import-preview-requests -Bottom
(Get-TtgState).Pages.Verify.Root.FindName('ApplyToggle').IsChecked = $true; Update-TtgBottomBar
Snap verify-import-apply -Bottom
(Get-TtgState).ConfirmHook = { param($t, $m) $true }
Next-Step; Wait-Chain; Snap run-import
Next-Step; Snap next-import

# Verify the imported lot
$lot = (Get-TtgState).LastLot
Switch-TtgTask -Spec @{ Task = 'Verify'; Lot = $lot }
Snap task-verify
Next-Step; Snap verify-verify
Next-Step; Wait-Chain; Snap run-verify
Next-Step; Snap next-verify

$errors = @((Get-TtgState).Errors)
$w.Close()
Stop-TtgConsole
"Saved $($shots.Count) screenshot(s) to $OutDir"
if ($errors.Count) { Write-Warning "Console errors during the run: $($errors -join ' | ')"; exit 1 }