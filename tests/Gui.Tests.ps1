# Tests of the console: TeamsTransfer.Gui.ps1, ui\*.xaml, Jobs, Demo mode.
# The window runs in a child process on an STA thread (pwsh -STA): the Demo mode compiles the engine with the synthetic tenant, builds the window,
# drives the pages through the console's own functions and writes what it saw to a JSON file, which the tests assert on.
# Skipped when there is no desktop session or when lib\gui is not installed (tools\Get-TeamsTransferDependencies.ps1).
# Run: Invoke-Pester .\tests\Gui.Tests.ps1

BeforeDiscovery {
    $script:PackageRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'package'
    $script:CanRun = $IsWindows -and [Environment]::UserInteractive -and (Test-Path -LiteralPath (Join-Path $script:PackageRoot 'lib\gui\Wpf.Ui.dll')) -and
        (Test-Path -LiteralPath (Join-Path $script:PackageRoot 'demo\SyntheticTenant.cs'))
}

BeforeAll {
    $script:PackageRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'package'
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('tt-guitest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($script:Work)
    $script:Result = $null
    $driver = @'
param($Package, $Work)
$ErrorActionPreference = 'Stop'
$out = [ordered]@{ Steps = [ordered]@{}; Fatal = $null }
try {
    $T = & (Join-Path $Package 'TeamsTransfer.Gui.ps1') -Demo -Harness -Theme Light -DemoRoot (Join-Path $Work 'demo') | Select-Object -Last 1
    $T.NoShell = $true
    $T.Window.Show()
    [void](Wait-TtgUi -MinimumMilliseconds 500)
    $S = $out.Steps
    $S.Built = @{ DemoBadge = [string]$T.Ui.DemoBadge.Visibility; Title = $T.Window.Title; Errors = $T.Errors.Count; IsFluent = ($T.Window -is [Wpf.Ui.Controls.FluentWindow]); Step = $T.Step; Stepper = @($T.Ui.StepperHost.Children | Where-Object { $_.Tag -is [int] }).Count }

    function Wait-Chain { $ok = Wait-TtgUi -Until { $c = (Get-TtgState).Chain; (-not $c) -or $c.Done } -TimeoutSeconds 300; if (-not $ok) { throw 'chain timeout' }; [void](Wait-TtgUi -MinimumMilliseconds 400) }

    # the flow: Setup -> Task -> Verify, nothing runs on page load
    Invoke-TtgPrimary; $S.AfterSetup = @{ Step = $T.Step; Content = ($T.Ui.StepHost.Content -eq $T.Pages.Task.Root) }
    $cards = $T.Pages.Task.Root.FindName('TaskCards').Children
    $S.Cards = @($cards | ForEach-Object { $_.Tag })
    $S.Happen = @{}
    foreach ($k in 'Estimate', 'Export', 'Browse', 'Import', 'Verify') { Set-TtgTask -Key $k; $S.Happen[$k] = [string]$T.Pages.Task.Root.FindName('WillHappenText').Text }
    $S.ScopeChoices = @{ Export = $T.TaskDef.Export.Scopes.Count; Import = $T.TaskDef.Import.Scopes.Count }

    # Export: step 3 shows the checks and runs nothing; the primary button starts the run
    Set-TtgTask -Key Export; Set-TtgScope -Key all
    Invoke-TtgPrimary
    $S.ExportVerify = @{ Step = $T.Step; ChainStarted = ($null -ne $T.Chain); Checks = @($T.LastChecks).Count; Primary = [string]$T.Ui.PrimaryButton.Content; Command = [string]$T.Pages.Verify.Root.FindName('CommandText').Text }
    Invoke-TtgPrimary
    $S.ExportRunStarted = @{ Step = $T.Step; Steps = @($T.Chain.Steps).Count; ListItems = $T.Pages.Run.Root.FindName('StepsList').Items.Count; StopVisible = [string]$T.Ui.SecondaryButton.Visibility }
    Wait-Chain
    $S.Export = @{ Exit = $T.Chain.Exit; Statuses = @($T.Chain.Steps | ForEach-Object { $_.Status }); Messages = [long]($T.Chain.Steps | Where-Object { $_.Id -eq 'export' }).Result.Counts.messages; Report = [bool](Test-Path ($T.Chain.Steps | Where-Object { $_.Id -eq 'export' }).Result.Report) }
    $S.RunPill = [string]$T.Pages.Run.Root.FindName('RunPillText').Text
    Invoke-TtgPrimary
    $S.ExportNext = @{ Step = $T.Step; Commands = $T.Pages.Next.Root.FindName('NextCommands').Children.Count; Buttons = $T.Pages.Next.Root.FindName('NextButtons').Children.Count; Title = [string]$T.Pages.Next.Root.FindName('NextTitle').Text }

    # Import: preview first (nothing is written, nothing is asked), then Apply with a confirmation
    Switch-TtgTask -Spec @{ Task = 'Import' }
    Set-TtgScope -Key user; ($T.Form.Import.Scopes.user.Users).Control.Text = 'camille.martin@contoso.com'; Update-TtgTaskText
    Invoke-TtgPrimary
    $S.ImportVerify = @{ Step = $T.Step; Preview = ($null -ne $T.Preview); Chain = ($null -ne $T.Chain); Primary = [string]$T.Ui.PrimaryButton.Content; Apply = [string]$T.Pages.Verify.Root.FindName('ApplyCard').Visibility }
    $T.LastConfirm = $null
    Invoke-TtgPrimary
    Wait-Chain
    $pv = $T.Preview
    $S.ImportPreview = @{ Done = ($null -ne $pv); Blocked = [bool]$pv.Blocked; Messages = $pv.Messages; Lines = @($pv.Lines).Count; Confirmed = ($null -ne $T.LastConfirm); Apply = [string]$T.Pages.Verify.Root.FindName('ApplyCard').Visibility; Primary = [string]$T.Ui.PrimaryButton.Content; PrimaryEnabled = [bool]$T.Ui.PrimaryButton.IsEnabled }
    # the ghost count of the Verify page is the plan's: the Ghosts step must find exactly that many candidates
    $S.GhostKpi = @{ Preview = [long]$pv.Ghosts; PlanCounts = [long]$pv.PlanResult.Counts.ghosts }
    $S.ImportCheckPills = @($T.LastChecks | ForEach-Object { "$($_.Level):$($_.Pill)" })
    # Apply is chosen here, explicitly, with the target tenant name; a refusal starts nothing
    $T.Pages.Verify.Root.FindName('ApplyToggle').IsChecked = $true; Update-TtgBottomBar
    $S.ApplyLabel = [string]$T.Pages.Verify.Root.FindName('ApplyToggle').Content
    $S.ApplyEnabled = [bool]$T.Ui.PrimaryButton.IsEnabled
    $T.ConfirmHook = { param($title, $message) $false }
    Invoke-TtgPrimary
    $S.ApplyDeclined = @{ Chain = ($null -ne $T.Chain); Step = $T.Step; Asked = [string]$T.LastConfirm.Message }
    $T.ConfirmHook = { param($title, $message) $true }
    Invoke-TtgPrimary
    Wait-Chain
    $gs = $T.Chain.Steps | Where-Object { $_.Id -eq 'ghosts' } | Select-Object -First 1
    $S.GhostApply = @{ Candidates = [long]$gs.Result.Counts.candidates; Created = [long]$gs.Result.Counts.created; Status = [string]$gs.Status }
    $S.ImportApply = @{ Step = $T.Step; Exit = $T.Chain.Exit; Apply = [bool]$T.Chain.Apply; Statuses = @($T.Chain.Steps | ForEach-Object { $_.Status }) }
    $T.ConfirmHook = $null
    Invoke-TtgPrimary
    $S.ImportNext = @{ Step = $T.Step; Lot = [string]$T.LastChain.Lot; Button = [string](($T.Pages.Next.Root.FindName('NextButtons').Children | Select-Object -First 1).Content) }

    # Verify the lot, from the button of the Next steps page
    Switch-TtgTask -Spec @{ Task = 'Verify'; Lot = $T.LastChain.Lot }
    $S.VerifyLot = [string]$T.Form.Verify.Scopes.lot.Lot.Control.Text
    Invoke-TtgPrimary; Invoke-TtgPrimary; Wait-Chain
    $S.Verify = @{ Exit = $T.Chain.Exit; Steps = @($T.Chain.Steps).Count }

    # Stop: the stop file exists before the work starts, so the run ends resumable (exit code 2)
    Switch-TtgTask -Spec @{ Task = 'Export' }
    Set-TtgScope -Key all
    Invoke-TtgPrimary; Invoke-TtgPrimary
    Stop-TtgChain
    Wait-Chain
    $S.Stop = @{ Exit = $T.Chain.Exit; Pill = [string]$T.Pages.Run.Root.FindName('RunPillText').Text }

    # Browse: the viewer
    Switch-TtgTask -Spec @{ Task = 'Browse' }
    Invoke-TtgPrimary; Invoke-TtgPrimary
    $px = $T.Pages.Explorer.Root
    $S.BrowseStep = @{ Step = $T.Step; Viewer = ($T.Ui.StepHost.Content -eq $px) }
    $px.FindName('ModeChats').IsChecked = $true; $T.Explorer.Mode = 'Chats'; Update-TtgExplorerList
    $list = $px.FindName('ExplorerList')
    $S.ExplorerItems = $list.Items.Count
    $px.FindName('ExplorerSearch').Text = 'moon'; Update-TtgExplorerList
    $S.ExplorerSearch = $list.Items.Count
    $px.FindName('ExplorerSearch').Text = ''; Update-TtgExplorerList
    $pick = $list.Items | Where-Object { $_.Tag.Title -like 'Project Moon*' } | Select-Object -First 1
    if (-not $pick) { $pick = $list.Items | Select-Object -First 1 }
    $pick.IsSelected = $true
    [void](Wait-TtgUi -Until { -not (Get-TtgState).Explorer.Busy } -TimeoutSeconds 120)
    [void](Wait-TtgUi -Until { (Get-TtgState).Explorer.LastNavigationOk -or (Get-TtgState).WebView2Error } -TimeoutSeconds 90)
    $S.Explorer = @{
        ArchiveIndex = [bool]($T.Explorer.ArchiveIndex -and (Test-Path -LiteralPath $T.Explorer.ArchiveIndex))
        WebView2Error = [string]$T.WebView2Error; Message = [string]$px.FindName('ExplorerMessageText').Text
        Navigated = [bool]$T.Explorer.LastNavigationOk; Navigations = @($T.Explorer.Navigations)
    }
    if ($T.Explorer.LastNavigationOk) {
        $before = $T.Explorer.Blocked.Count
        $T.ConfirmHook = { param($t, $m) $false }
        $T.WebView.CoreWebView2.Navigate('https://example.invalid/')
        [void](Wait-TtgUi -Until { (Get-TtgState).Explorer.Blocked.Count -gt $before } -TimeoutSeconds 20)
        $S.Explorer.BlockedExternal = ($T.Explorer.Blocked.Count -gt $before)
        $S.Explorer.StillInArchive = ([string]$T.WebView.Source -like 'file:*')
        $S.Explorer.DevTools = [bool]$T.WebView.CoreWebView2.Settings.AreDevToolsEnabled
        $T.ConfirmHook = $null
    }

    # the live window, as the user sees it (PrintWindow): light, not black; the brand colour, not Windows blue
    $null = Set-TtgTheme -Requested Light; $T.Ui.ThemeLight.IsChecked = $true
    Reset-TtgRun; Set-TtgTask -Key Export; Select-TtgStep 2; [void](Wait-TtgUi -MinimumMilliseconds 800)
    $png = Join-Path $Work 'live-light.png'
    [void](Save-TtgWindowImage -Path $png)
    $bmp = [System.Drawing.Bitmap]::new($png)
    try {
        $sum = 0.0; $n = 0
        for ($x = 4; $x -lt $bmp.Width; $x += 9) { for ($y = 4; $y -lt $bmp.Height; $y += 9) { $p = $bmp.GetPixel($x, $y); $sum += (0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B); $n++ } }
        $src = [System.Windows.PresentationSource]::FromVisual($T.Window); $m = $src.CompositionTarget.TransformToDevice
        $btn = $T.Ui.PrimaryButton; $pt = $btn.TransformToAncestor($T.Window).Transform([System.Windows.Point]::new(12, $btn.ActualHeight / 2))
        $sx = $bmp.Width / $T.Window.ActualWidth; $sy = $bmp.Height / $T.Window.ActualHeight
        $bp = $bmp.GetPixel([Math]::Min($bmp.Width - 1, [int]($pt.X * $sx)), [Math]::Min($bmp.Height - 1, [int]($pt.Y * $sy)))
        $card = $T.Pages.Task.Root.FindName('TaskCards').Children | Where-Object { $_.Tag -eq 'Export' } | Select-Object -First 1
        $cp = $card.TransformToAncestor($T.Window).Transform([System.Windows.Point]::new(3, $card.ActualHeight / 2))
        $edge = $bmp.GetPixel([Math]::Min($bmp.Width - 1, [int]($cp.X * $sx)), [Math]::Min($bmp.Height - 1, [int]($cp.Y * $sy)))
        $S.Live = @{ Mean = [Math]::Round($sum / $n, 1); Width = $bmp.Width; Button = @($bp.R, $bp.G, $bp.B); SelectedCardEdge = @($edge.R, $edge.G, $edge.B) }
    } finally { $bmp.Dispose() }

    $S.GhostApplyText = @{ Create = [string](Get-TtgApplyMessage -Mode 'Ghosts' -Params @{} -StoreRoot 'S' -Tenant 'T'); Remove = [string](Get-TtgApplyMessage -Mode 'Ghosts' -Params @{ Remove = $true } -StoreRoot 'S' -Tenant 'T') }

    # Demo: no real identity on the screen (the screenshots are published)
    function Get-AllText($root) { $o = [Collections.Generic.List[string]]::new(); $stack = [Collections.Generic.Stack[object]]::new(); $stack.Push($root)
        while ($stack.Count) { $n = $stack.Pop(); if ($n -is [System.Windows.Controls.TextBlock]) { $o.Add([string]$n.Text) } elseif ($n -is [System.Windows.Controls.TextBox]) { $o.Add([string]$n.Text) } elseif ($n -is [System.Windows.Controls.ContentControl] -and $n.Content -is [string]) { $o.Add([string]$n.Content) }
            if ($n -is [System.Windows.DependencyObject]) { foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) } } } }
        $o -join "`n" }
    $leaks = @()
    $banned = @($env:USERNAME, $env:COMPUTERNAME, [IO.Path]::GetTempPath().TrimEnd('\'), $T.DemoRoot, $T.PackageRoot) | Where-Object { $_ -and $_.Length -gt 3 }
    foreach ($step in 1, 2, 3, 5) {
        if ($step -eq 5) { $T.LastChain = $T.LastChain; Select-TtgStep 5 } else { Select-TtgStep $step }
        $txt = Get-AllText $T.Ui.StepHost.Content
        foreach ($b in $banned) { if ($txt.IndexOf($b, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $leaks += "step $step shows '$b'" } }
    }
    Select-TtgStep 4
    $S.DemoLeaks = $leaks
    $S.DemoShown = @{ Store = (Get-TtgShown $T.StoreRoot); Machine = (Get-TtgShown $env:COMPUTERNAME) }
    $S.BrowseScopeBox = $null
    Set-TtgTask -Key Browse; $S.BrowseScopeBox = [string]$T.Pages.Task.Root.FindName('ScopeCard').Visibility
    Set-TtgTask -Key Export; $S.ExportScopeBox = [string]$T.Pages.Task.Root.FindName('ScopeCard').Visibility
    $S.Permissions = @{ Target = @((Get-TtgRoleNeeds -Side Target).Keys); Source = @((Get-TtgRoleNeeds -Side Source).Keys); Table = [bool](Test-Path (Join-Path $Package 'config\Permissions.psd1')) }

    # theme: the house palette follows the theme
    $null = Set-TtgTheme -Requested Dark
    $dark = [string]$T.App.Resources['TmtBrand'].Color; $darkBg = [string]$T.App.Resources['ApplicationBackgroundBrush'].Color
    $null = Set-TtgTheme -Requested Light
    $S.Theme = @{ Light = [string]$T.App.Resources['TmtBrand'].Color; Dark = $dark; Cream = [string]$T.App.Resources['ApplicationBackgroundBrush'].Color }

    # Setup reads the store and the demo permissions
    Select-TtgStep 1
    Start-TtgRoleCheck -Side Source
    $S.Setup = @{ Tiles = $T.Pages.Home.Root.FindName('StatTiles').Children.Count; SourceMissing = $T.Checks.Source.Missing.Count }
    $logs = @(Get-ChildItem -LiteralPath $T.LogFolder -Filter 'TeamsTransfer_*.log' -File -ErrorAction SilentlyContinue)
    $fail = @(); foreach ($l in $logs) { $fail += @(Select-String -LiteralPath $l.FullName -Pattern '\[FAIL' | ForEach-Object { $_.Line }) }
    $S.LogFailLines = $fail
    $S.Errors = @($T.Errors)
    # the window cannot be closed while the engine runs
    Switch-TtgTask -Spec @{ Task = 'Export' }; Set-TtgScope -Key all
    Invoke-TtgPrimary; Invoke-TtgPrimary
    $T.Window.Close(); [void](Wait-TtgUi -MinimumMilliseconds 300)
    $S.CloseBlocked = [bool]$T.Window.IsVisible
    Stop-TtgChain; Wait-Chain
    Stop-TtgConsole
} catch {
    $out.Fatal = ($_ | Out-String) + $_.ScriptStackTrace
}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Work 'result.json') -Encoding utf8
'@
    Set-Content -LiteralPath (Join-Path $script:Work 'driver.ps1') -Value $driver -Encoding utf8
    if ($script:CanRun -or ($IsWindows -and [Environment]::UserInteractive -and (Test-Path -LiteralPath (Join-Path $script:PackageRoot 'lib\gui\Wpf.Ui.dll')))) {
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoLogo -NoProfile -STA -File (Join-Path $script:Work 'driver.ps1') -Package $script:PackageRoot -Work $script:Work 2>&1 | Out-Null
        $json = Join-Path $script:Work 'result.json'
        if (Test-Path -LiteralPath $json) { $script:Result = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json }
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Console files' {
    It 'every XAML file is well formed and has no code-behind or event attribute' {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:PackageRoot 'ui') -Filter *.xaml) {
            { [xml](Get-Content -LiteralPath $f.FullName -Raw) } | Should -Not -Throw
            (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match '(?i)\sx:Class\s*=|\s(Click|Loaded|SelectionChanged|Closing)\s*='
        }
    }
    It 'uses no hard-coded colour in the XAML or the console code (the house palette lives in Set-TtgPalette)' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:PackageRoot 'ui') -Filter *.xaml) + @(Get-ChildItem -LiteralPath $script:PackageRoot -Filter 'TeamsTransfer.Gui.*.ps1' | Where-Object { $_.Name -ne 'TeamsTransfer.Gui.Jobs.ps1' })
        foreach ($f in $files) {
            $lines = Get-Content -LiteralPath $f.FullName | Where-Object { $_ -match '#[0-9A-Fa-f]{6,8}\b' -and $_ -notmatch "Tmt\w+ = @\(|\w+Brush\w* = @\(|AccentButton\w+ = @\(" }
            $lines | Should -BeNullOrEmpty -Because $f.Name
        }
    }
    It 'pins the console libraries in the lock file and they match it' {
        $lock = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'dependency-lock.json') -Raw | ConvertFrom-Json
        $lock.packages.id | Should -Contain 'Microsoft.Web.WebView2'
        $lock.packages.id | Should -Contain 'WPF-UI'
        foreach ($p in $lock.packages) {
            $p.sha512 | Should -Not -BeNullOrEmpty
            foreach ($f in $p.selectedFiles) {
                $path = Join-Path $script:PackageRoot $f.target
                if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.sha256 }
            }
        }
    }
    It 'the entry script has -Gui and -Demo and the launcher exists' {
        (Get-Content -LiteralPath (Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1') -Raw) | Should -Match '\[switch\]\$Gui'
        Test-Path -LiteralPath (Join-Path $script:PackageRoot 'Start-TeamsTransferConsole.cmd') | Should -BeTrue
    }
    It 'resolves a relative Output.Root against the parent of the package and passes no parallelism of its own' {
        $core = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Gui.Core.ps1') -Raw
        $core | Should -Match 'GetDirectoryName\(\[IO.Path\]::GetFullPath\(\$PackageRoot\)'
        $jobs = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Gui.Jobs.ps1') -Raw
        $jobs | Should -Not -Match 'else \{ (8|32|4) \}'
        $jobs | Should -Not -Match 'Parallelism = (8|32)\b'
    }
    It 'the jobs map each mode to the same module function as the command line' {
        $jobs = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Gui.Jobs.ps1') -Raw
        foreach ($fn in 'Invoke-TmtAssess', 'Invoke-TmtInventory', 'Invoke-TmtExport', 'Invoke-TmtFiles', 'New-TmtImportPlan', 'Invoke-TmtGhosts', 'Invoke-TmtFileCopy', 'Invoke-TmtImport', 'Invoke-TmtVerify', 'Invoke-TmtLotReport') { $jobs | Should -Match ([regex]::Escape($fn)) }
    }
}

Describe 'Console (Demo mode, STA child process)' -Skip:(-not $script:CanRun) {
    It 'the child process finished without a fatal error' { $script:Result | Should -Not -BeNullOrEmpty; $script:Result.Fatal | Should -BeNullOrEmpty }
    It 'builds a Fluent window with the DEMO badge, the five-step bar and no handler error' {
        $b = $script:Result.Steps.Built
        $b.IsFluent | Should -BeTrue; $b.DemoBadge | Should -Be 'Visible'; $b.Title | Should -Match 'DEMO'; $b.Errors | Should -Be 0; $b.Step | Should -Be 1; $b.Stepper | Should -Be 5
    }
    It 'Setup leads to the Task step with five task cards and a sentence of what will happen for each' {
        $script:Result.Steps.AfterSetup.Step | Should -Be 2; $script:Result.Steps.AfterSetup.Content | Should -BeTrue
        @($script:Result.Steps.Cards).Count | Should -Be 5
        foreach ($k in 'Estimate', 'Export', 'Browse', 'Import', 'Verify') { $script:Result.Steps.Happen.$k | Should -Match 'Nothing is written|Offline|Until then|read only' -Because $k }
        $script:Result.Steps.ScopeChoices.Export | Should -BeGreaterThan 3
    }
    It 'step 3 shows checks and runs nothing on load; the primary button starts the export run (Inventory, Export, Files)' {
        $v = $script:Result.Steps.ExportVerify
        $v.Step | Should -Be 3; $v.ChainStarted | Should -BeFalse; $v.Checks | Should -BeGreaterThan 1; $v.Primary | Should -Match '^Start'; $v.Command | Should -Match '-Mode Inventory'
        $script:Result.Steps.ExportRunStarted.Step | Should -Be 4; $script:Result.Steps.ExportRunStarted.Steps | Should -Be 3; $script:Result.Steps.ExportRunStarted.ListItems | Should -Be 3
        $script:Result.Steps.ExportRunStarted.StopVisible | Should -Be 'Visible'
    }
    It 'the window cannot be closed while the engine runs' { $script:Result.Steps.CloseBlocked | Should -BeTrue }
    It 'Demo mode runs the export end to end against the fake tenant' {
        $e = $script:Result.Steps.Export
        $e.Exit | Should -Be 0; $e.Messages | Should -BeGreaterThan 0; $e.Report | Should -BeTrue
        @($e.Statuses | Where-Object { $_ -ne 'Done' }).Count | Should -Be 0
        $script:Result.Steps.RunPill | Should -Be 'Done'
    }
    It 'Next steps proposes the next task and the same command lines' {
        $n = $script:Result.Steps.ExportNext
        $n.Step | Should -Be 5; $n.Commands | Should -Be 3; $n.Buttons | Should -BeGreaterThan 1; $n.Title | Should -Match 'done'
    }
    It 'the import preview runs only on request, counts requests, asks nothing and writes nothing' {
        $v = $script:Result.Steps.ImportVerify
        $v.Step | Should -Be 3; $v.Preview | Should -BeFalse; $v.Chain | Should -BeFalse; $v.Primary | Should -Be 'Run preview'; $v.Apply | Should -Be 'Collapsed'
        $p = $script:Result.Steps.ImportPreview
        $p.Done | Should -BeTrue; $p.Blocked | Should -BeFalse; $p.Messages | Should -BeGreaterThan 0; $p.Lines | Should -BeGreaterThan 0; $p.Confirmed | Should -BeFalse
        $p.Apply | Should -Be 'Visible'; $p.Primary | Should -Be 'Apply now'; $p.PrimaryEnabled | Should -BeFalse
        @($script:Result.Steps.ImportCheckPills).Count | Should -BeGreaterThan 2
    }
    It 'Apply is explicit, names the target tenant and needs a confirmation; a refusal starts nothing' {
        $script:Result.Steps.ApplyLabel | Should -Match 'northwind'; $script:Result.Steps.ApplyEnabled | Should -BeTrue
        $a = $script:Result.Steps.ApplyDeclined
        $a.Chain | Should -BeFalse; $a.Step | Should -Be 3; $a.Asked | Should -Match 'Target tenant'; $a.Asked | Should -Match 'cannot be rolled back'
    }
    It 'the confirmed Apply chains Ghosts, Copy files and Import and moves to Next steps' {
        $i = $script:Result.Steps.ImportApply
        $i.Step | Should -Be 4; $i.Apply | Should -BeTrue; @($i.Statuses).Count | Should -Be 5
        $script:Result.Steps.ImportNext.Step | Should -Be 5; $script:Result.Steps.ImportNext.Lot | Should -Not -BeNullOrEmpty; $script:Result.Steps.ImportNext.Button | Should -Match 'Verify'
    }
    It 'the ghost count shown on the Verify page equals the candidates of the Ghosts step' {
        $k = $script:Result.Steps.GhostKpi; $a = $script:Result.Steps.GhostApply
        $k.Preview | Should -BeGreaterThan 0 -Because 'the user chats include a deleted author'
        $k.Preview | Should -Be $k.PlanCounts
        $a.Candidates | Should -Be $k.Preview
        $a.Status | Should -Be 'Done'; $a.Created | Should -Be $k.Preview
    }
    It 'the Ghosts Apply confirmation says create without -Remove and DELETE only with it' {
        $script:Result.Steps.GhostApplyText.Create | Should -Match 'create disabled, unlicensed ghost accounts'
        $script:Result.Steps.GhostApplyText.Create | Should -Not -Match 'DELETE'
        $script:Result.Steps.GhostApplyText.Remove | Should -Match 'DELETE'
    }
    It 'shows no real identity in Demo mode (user, machine, temp or package folder)' {
        @($script:Result.Steps.DemoLeaks) | Should -BeNullOrEmpty
        $script:Result.Steps.DemoShown.Store | Should -Be 'D:\TeamsTransfer\store'
        $script:Result.Steps.DemoShown.Machine | Should -Be 'ADMIN-WS01'
    }
    It 'reads the permissions from the one table and shows no empty scope box for Browse' {
        $script:Result.Steps.Permissions.Table | Should -BeTrue
        $script:Result.Steps.Permissions.Target | Should -Contain 'Group.Read.All'
        $script:Result.Steps.Permissions.Target | Should -Contain 'GroupMember.ReadWrite.All'
        $script:Result.Steps.Permissions.Source | Should -Contain 'TeamMember.Read.All'
        $script:Result.Steps.BrowseScopeBox | Should -Be 'Collapsed'; $script:Result.Steps.ExportScopeBox | Should -Be 'Visible'
    }
    It 'the Verify task starts from the proposed lot and runs Verify and Report' {
        $script:Result.Steps.VerifyLot | Should -Not -BeNullOrEmpty; $script:Result.Steps.Verify.Steps | Should -Be 2
    }
    It 'Stop ends a run as resumable (exit code 2)' { $script:Result.Steps.Stop.Exit | Should -Be 2; $script:Result.Steps.Stop.Pill | Should -Be 'Stopped' }
    It 'the Browse task opens the viewer: it lists and searches the store and shows the archive (or says why it cannot)' {
        $b = $script:Result.Steps.BrowseStep; $b.Step | Should -Be 4; $b.Viewer | Should -BeTrue
        $e = $script:Result.Steps.Explorer
        $script:Result.Steps.ExplorerItems | Should -BeGreaterThan 0
        $script:Result.Steps.ExplorerSearch | Should -BeGreaterThan 0; $script:Result.Steps.ExplorerSearch | Should -BeLessThan $script:Result.Steps.ExplorerItems
        $e.ArchiveIndex | Should -BeTrue
        if ($e.WebView2Error) { $e.Message | Should -Not -BeNullOrEmpty }
        else { $e.Navigated | Should -BeTrue; @($e.Navigations)[0] | Should -Match 'index\.html'; $e.BlockedExternal | Should -BeTrue; $e.StillInArchive | Should -BeTrue; $e.DevTools | Should -BeFalse }
    }
    It 'the live window is light (not black) and its accents are the brand colour, not Windows blue' {
        $l = $script:Result.Steps.Live
        $l.Mean | Should -BeGreaterThan 200
        $l.Button[0] | Should -BeGreaterThan ($l.Button[2] + 40) -Because 'the primary button is raspberry'
        $l.SelectedCardEdge[0] | Should -BeGreaterThan ($l.SelectedCardEdge[2]) -Because 'the selected card border is raspberry, not blue'
    }
    It 'applies the house palette in both themes (raspberry brand, cream background)' { $script:Result.Steps.Theme.Light | Should -Be '#FFB11F4B'; $script:Result.Steps.Theme.Dark | Should -Be '#FFFD8EA1'; $script:Result.Steps.Theme.Cream | Should -Be '#FFF7F4EF' }
    It 'Setup reads the store and the demo permissions' { $script:Result.Steps.Setup.Tiles | Should -BeGreaterThan 0; $script:Result.Steps.Setup.SourceMissing | Should -Be 0 }
    It 'leaves no unhandled exception and no FAIL line in the log' { @($script:Result.Steps.Errors).Count | Should -Be 0; @($script:Result.Steps.LogFailLines).Count | Should -Be 0 }
}