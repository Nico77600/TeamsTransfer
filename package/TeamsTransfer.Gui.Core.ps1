# TeamsTransfer console - core: state, settings, house palette and theme, background tasks, dialogs, window capture, start and stop.
# Dot-sourced into the in-memory module TeamsTransferGui by TeamsTransfer.Gui.ps1 (see there). Nothing here talks to a tenant: the pages start jobs
# (TeamsTransfer.Gui.Jobs.ps1) that call the same functions as Invoke-TeamsTransfer.ps1.
#
# Event handlers: every handler is attached with Add-TtgHandler, which catches and records what a handler throws (an exception that escapes an
# event handler would end the dispatcher). Handlers use $args / the sender, module functions and Get-TtgState only.

$script:Ttg = $null

function Get-TtgState { return $script:Ttg }

#region Settings -----------------------------------------------------------------------------------

function Get-TtgDefaultSettingsPath {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
    return Join-Path $base 'TeamsTransfer\console-settings.json'
}

function Read-TtgSettings {
    param([Parameter(Mandatory)][string]$Path, [switch]$NoLive)
    $s = @{ Theme = 'System'; StoreRoot = ''; RecentStores = @(); LogFolder = ''; ConfigPath = '' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($k in 'Theme', 'StoreRoot', 'LogFolder', 'ConfigPath') { if ($j.PSObject.Properties[$k] -and $j.$k) { $s[$k] = [string]$j.$k } }
            if ($j.PSObject.Properties['RecentStores']) { $s.RecentStores = @($j.RecentStores | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        } catch { Write-Verbose "Settings unreadable ($Path): $($_.Exception.Message)" }
    }
    if ($s.Theme -notin 'System', 'Light', 'Dark') { $s.Theme = 'System' }
    return $s
}

function Save-TtgSettings {
    $T = $script:Ttg
    if ($T.Demo -and -not $T.PersistSettings) { return }
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $T.SettingsPath))
        $o = [ordered]@{ Theme = $T.Settings.Theme; StoreRoot = $T.Settings.StoreRoot; RecentStores = @($T.Settings.RecentStores | Select-Object -First 8); LogFolder = $T.Settings.LogFolder; ConfigPath = $T.Settings.ConfigPath }
        [IO.File]::WriteAllText($T.SettingsPath, ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch { Add-TtgError $_ }
}

function Add-TtgError {
    # Records what a handler threw (shown in the status bar, kept for the tests).
    param($ErrorRecord)
    $T = $script:Ttg
    $text = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { "$($ErrorRecord.Exception.Message) ($($ErrorRecord.InvocationInfo.ScriptName | Split-Path -Leaf -ErrorAction SilentlyContinue):$($ErrorRecord.InvocationInfo.ScriptLineNumber))" } else { [string]$ErrorRecord }
    if ($null -ne $T) {
        $T.Errors.Add($text)
        try { if ($T.Ui.StatusText) { $T.Ui.StatusText.Text = "Error: $text" } } catch { Write-Verbose "status: $($_.Exception.Message)" }
        try { if (Get-Command Write-TmtLog -ErrorAction SilentlyContinue) { Write-TmtLog FAIL "Console: $text" } } catch { Write-Verbose "log: $($_.Exception.Message)" }
    }
}

function Add-TtgHandler {
    <# .SYNOPSIS Attaches an event handler that cannot end the dispatcher: the exception is recorded. #>
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][string]$Event, [Parameter(Mandatory)][scriptblock]$Action)
    $wrapper = {
        param($s, $e)
        try { & $Action $s $e } catch { Add-TtgError $_ }
    }.GetNewClosure()
    $Control."add_$Event"($wrapper)
}
#endregion

#region Paths and configuration -------------------------------------------------------------------

function Resolve-TtgOutRoot {
    # Same rule as Invoke-TeamsTransfer.ps1: a relative Output.Root is resolved against the PARENT folder of the package (<parent>\out next to
    # package\), never against the current folder and never inside the package.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$PackageRoot)
    $configured = if ($Config.Output -and $Config.Output.Root) { [string]$Config.Output.Root } else { '.\out' }
    if ([IO.Path]::IsPathRooted($configured)) { return $configured }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/'))
    if (-not $parent) { $parent = [IO.Path]::GetFullPath($PackageRoot) }
    return [IO.Path]::GetFullPath($configured, $parent)
}
function Import-TtgConfiguration {
    # Loads the configuration into the state. A configuration that cannot be read is shown, not thrown.
    $T = $script:Ttg
    try {
        $T.Config = if ($T.ConfigPath) { Import-TmtConfiguration -Path $T.ConfigPath } else { Import-TmtConfiguration }
        $T.ConfigError = $null
    } catch {
        $T.ConfigError = $_.Exception.Message
        $none = @{ Cloud = 'Global'; TenantId = ''; ClientId = ''; CertificateThumbprint = '' }
        $T.Config = @{ Output = @{ Root = '.\out' }; Store = @{ Path = ''; Partitions = 256 }; Logging = @{ RetentionDays = 14 }; Source = $none.Clone(); Target = $none.Clone(); Graph = @{}; Ghosts = @{} }
    }
    if ($T.Demo) {
        $T.Config.Source = @{ Cloud = 'Global'; TenantId = 'contoso-demo (synthetic)'; ClientId = '11111111-1111-1111-1111-111111111111'; CertificateThumbprint = 'DEMO0000000000000000000000000000000000AA' }
        $T.Config.Target = @{ Cloud = 'Global'; TenantId = 'northwind-demo (synthetic)'; ClientId = '22222222-2222-2222-2222-222222222222'; CertificateThumbprint = 'DEMO0000000000000000000000000000000000BB' }
        $T.Config.Store = @{ Path = ''; Partitions = 8 }
    }
    $T.OutRoot = if ($T.Demo) { $T.DemoRoot } else { Resolve-TtgOutRoot -Config $T.Config -PackageRoot $T.PackageRoot }
    $T.LogFolder = if ($T.Settings.LogFolder) { $T.Settings.LogFolder } elseif ($T.Demo) { Join-Path $T.DemoRoot 'logs' } elseif ($env:TEAMSTRANSFER_LOG_FOLDER) { $env:TEAMSTRANSFER_LOG_FOLDER } else { Join-Path $T.OutRoot 'logs' }
}

function Set-TtgStoreRoot {
    param([string]$Path)
    $T = $script:Ttg
    $T.StoreRoot = $Path
    Update-TtgTopBar
    if ($Path -and -not $T.Demo) {
        $T.Settings.StoreRoot = $Path
        $T.Settings.RecentStores = @(@($Path) + @($T.Settings.RecentStores | Where-Object { $_ -ne $Path }) | Select-Object -First 8)
        Save-TtgSettings
    }
}

function Test-TtgStoreExists {
    $T = $script:Ttg
    return [bool]($T.StoreRoot -and (Test-Path -LiteralPath (Join-Path $T.StoreRoot 'catalog.db')))
}
#endregion

#region Theme -------------------------------------------------------------------------------------

function Get-TtgWindowsTheme {
    # Light or Dark, from the Windows app theme. A missing preference means light (Windows default).
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', $false)
        if ($null -eq $key) { return 'Light' }
        try { $v = $key.GetValue('AppsUseLightTheme', $null) } finally { $key.Dispose() }
        if ($null -ne $v -and [int]$v -eq 0) { return 'Dark' }
    } catch { Write-Verbose "Theme read: $($_.Exception.Message)" }
    return 'Light'
}

function Set-TtgTheme {
    param([ValidateSet('System', 'Light', 'Dark')][string]$Requested = 'System')
    $T = $script:Ttg
    $effective = if ($Requested -eq 'System') { Get-TtgWindowsTheme } else { $Requested }
    Set-TtgPalette -Dark:($effective -eq 'Dark')
    $appTheme = if ($effective -eq 'Dark') { [Wpf.Ui.Appearance.ApplicationTheme]::Dark } else { [Wpf.Ui.Appearance.ApplicationTheme]::Light }
    # No Mica (a transparent window is not painted under a pwsh host: it shows black) and no system accent (it would pull Windows blue over the house brand).
    [Wpf.Ui.Appearance.ApplicationThemeManager]::Apply($appTheme, [Wpf.Ui.Controls.WindowBackdropType]::None, $false)
    $brand = $T.App.Resources['TmtBrand'].Color
    try { [Wpf.Ui.Appearance.ApplicationAccentColorManager]::Apply($brand, $appTheme, $false) } catch { Write-Verbose "accent manager: $($_.Exception.Message)" }
    $T.Settings.Theme = $Requested
    $T.EffectiveTheme = $effective
    Set-TtgPalette -Dark:($effective -eq 'Dark')
    if ($T.Window) { $T.Window.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'ApplicationBackgroundBrush') }
    Update-TtgWebViewTheme
    return $effective
}

function Set-TtgPalette {
    # The house palette of the other consoles (PRA.Gui Set-PraGuiTheme): the Fluent theme gives the surfaces, cards and text; only the brand and
    # status brushes are set on top, as [light, dark] pairs. Fallbacks apply only when the Fluent theme does not define the key.
    param([switch]$Dark)
    $T = $script:Ttg
    $colors = @{
        TmtBrand = @('#B11F4B', '#FD8EA1'); TmtBrandText = @('#B11F4B', '#FD8EA1'); TmtOnBrand = @('#FFFFFF', '#1B1B1B'); TmtAccentSoft = @('#14B11F4B', '#33FD8EA1')
        TmtCritical = @('#DC2626', '#F87171'); TmtSuccess = @('#16A34A', '#4ADE80'); TmtCaution = @('#B45309', '#FBBF24')
        TmtInfoBg = @('#F0EEEA', '#2E2E2E'); TmtSuccessBg = @('#EAF7EE', '#334ADE80'); TmtCautionBg = @('#FFF7E8', '#33FBBF24'); TmtCriticalBg = @('#FDECEC', '#33F87171')
        TmtTrack = @('#E6E3DE', '#4A4A4A'); ApplicationBackgroundBrush = @('#F7F4EF', '#202020')
        AccentFillColorDefaultBrush = @('#B11F4B', '#FD8EA1'); AccentButtonBackground = @('#B11F4B', '#FD8EA1'); AccentButtonBorderBrush = @('#B11F4B', '#FD8EA1')
    }
    $fallback = @{
        CardBackgroundFillColorDefaultBrush = @('#FFFFFF', '#2B2B2B'); CardStrokeColorDefaultBrush = @('#DEDEDE', '#3D3D3D')
        ControlFillColorDefaultBrush = @('#FFFFFF', '#2D2D2D'); ControlFillColorSecondaryBrush = @('#F5F5F5', '#363636'); DividerStrokeColorDefaultBrush = @('#DEDEDE', '#3D3D3D')
        LayerFillColorDefaultBrush = @('#FCFBF8', '#262626'); TextFillColorPrimaryBrush = @('#242424', '#FFFFFF'); TextFillColorSecondaryBrush = @('#5C5C5C', '#C5C5C5')
        TextFillColorTertiaryBrush = @('#8A8A8A', '#9A9A9A')
    }
    $i = [int][bool]$Dark
    $res = $T.App.Resources
    # Every accent-derived resource of Wpf.Ui is the house brand, so that no Windows blue remains anywhere.
    $brandColor = [System.Windows.Media.ColorConverter]::ConvertFromString($colors.TmtBrand[$i])
    foreach ($k in 'SystemAccentColor', 'SystemAccentColorPrimary', 'SystemAccentColorSecondary', 'SystemAccentColorTertiary', 'AccentFillColorDefault', 'AccentFillColorSecondary', 'AccentFillColorTertiary') { $res[$k] = $brandColor }
    foreach ($k in 'SystemAccentColorBrush', 'SystemAccentColorPrimaryBrush', 'SystemAccentColorSecondaryBrush', 'SystemAccentColorTertiaryBrush', 'AccentFillColorSecondaryBrush', 'AccentFillColorTertiaryBrush', 'AccentTextFillColorPrimaryBrush', 'AccentTextFillColorSecondaryBrush', 'AccentTextFillColorTertiaryBrush', 'ControlFillColorDefaultAccentBrush', 'ToggleSwitchFillOn', 'CheckBoxCheckBackgroundFillChecked', 'CheckBoxCheckBackgroundStrokeChecked', 'RadioButtonOuterEllipseCheckedFill', 'ProgressBarForeground') {
        $b = [System.Windows.Media.SolidColorBrush]::new($brandColor); $b.Freeze(); $res[$k] = $b
    }
    $onBrand = [System.Windows.Media.ColorConverter]::ConvertFromString($colors.TmtOnBrand[$i])
    foreach ($k in 'TextOnAccentFillColorPrimaryBrush', 'TextOnAccentFillColorSecondaryBrush') { $b = [System.Windows.Media.SolidColorBrush]::new($onBrand); $b.Freeze(); $res[$k] = $b }
    foreach ($key in $colors.Keys) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$key][$i])); $b.Freeze(); $res[$key] = $b
    }
    foreach ($key in $fallback.Keys) {
        if (-not $T.Fallbacks.ContainsKey($key) -and $null -ne $T.App.TryFindResource($key)) { continue }
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($fallback[$key][$i])); $b.Freeze(); $res[$key] = $b; $T.Fallbacks[$key] = $true
    }
}

function Set-TtgPill {
    # A status pill (PRA Set-PraGuiPill): Ok, Warn, Fail, Brand or neutral.
    param($Border, $Text, [string]$Level)
    $pair = switch ($Level) { 'Ok' { 'TmtSuccessBg', 'TmtSuccess' } 'Warn' { 'TmtCautionBg', 'TmtCaution' } 'Fail' { 'TmtCriticalBg', 'TmtCritical' } 'Brand' { 'TmtAccentSoft', 'TmtBrandText' } default { 'TmtInfoBg', 'TextFillColorSecondaryBrush' } }
    $Border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $pair[0])
    $Text.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $pair[1])
}
function Get-TtgBrush {
    param([Parameter(Mandatory)][string]$Key)
    $T = $script:Ttg
    $b = $null
    if ($T.Window) { $b = $T.Window.TryFindResource($Key) }
    if ($null -eq $b) { $b = [System.Windows.Media.Brushes]::Gray }
    return $b
}


function Set-TtgRef {
    # A brush that follows the theme: a resource reference (a brush taken once would keep the colours of the theme at that moment).
    param([Parameter(Mandatory)]$Element, [ValidateSet('Foreground', 'Background')][string]$Property, [Parameter(Mandatory)][string]$Key)
    $dp = if ($Property -eq 'Foreground') {
        if ($Element -is [System.Windows.Controls.TextBlock]) { [System.Windows.Controls.TextBlock]::ForegroundProperty } else { [System.Windows.Controls.Control]::ForegroundProperty }
    } else {
        if ($Element -is [System.Windows.Controls.Border]) { [System.Windows.Controls.Border]::BackgroundProperty } else { [System.Windows.Controls.Control]::BackgroundProperty }
    }
    $Element.SetResourceReference($dp, $Key)
}
function Set-TtgLight {
    # A traffic light: Green, Amber, Red or Gray.
    param([Parameter(Mandatory)]$Ellipse, [ValidateSet('Green', 'Amber', 'Red', 'Gray')][string]$State)
    $key = switch ($State) { 'Green' { 'TmtSuccess' } 'Amber' { 'TmtCaution' } 'Red' { 'TmtCritical' } default { 'TmtTrack' } }
    $Ellipse.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $key)
    $Ellipse.Tag = $State
}
#endregion

#region Background tasks --------------------------------------------------------------------------

function Start-TtgBackground {
    <#
    .SYNOPSIS
        Runs a script in its own runspace; the UI timer collects the result. OnDone gets (output array, error strings, tag); OnTick (optional) runs on every tick while it runs.
    #>
    param([Parameter(Mandatory)][string]$ScriptText, [object[]]$ArgumentList = @(), [scriptblock]$OnDone, [scriptblock]$OnTick, $Tag)
    $T = $script:Ttg
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::MTA
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptText)
    foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
    $task = @{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; OnTick = $OnTick; Tag = $Tag; Started = [DateTime]::UtcNow }
    $T.Tasks.Add($task)
    if (-not $T.Timer.IsEnabled) { $T.Timer.Start() }
    return $task
}

function Update-TtgTasks {
    # One tick of the UI timer (runs on the UI thread).
    $T = $script:Ttg
    foreach ($task in @($T.Tasks)) {
        if ($task.OnTick) { try { & $task.OnTick $task } catch { Add-TtgError $_ } }
        if (-not $task.Handle.IsCompleted) { continue }
        $out = @(); $errs = @()
        try { $out = @($task.Ps.EndInvoke($task.Handle)) } catch { $errs += $_.Exception.Message }
        foreach ($e in $task.Ps.Streams.Error) { $errs += [string]$e }
        try { $task.Ps.Dispose(); $task.Rs.Dispose() } catch { Write-Verbose "runspace dispose: $($_.Exception.Message)" }
        [void]$T.Tasks.Remove($task)
        if ($task.OnDone) { try { & $task.OnDone $out $errs $task.Tag } catch { Add-TtgError $_ } }
    }
    if ($T.Tasks.Count -eq 0) { $T.Timer.Stop() }
}

function Wait-TtgUi {
    <#
    .SYNOPSIS
        Pumps the dispatcher until the condition is true or the time is up (tests and screenshots). Returns the last value of the condition.
    #>
    param([scriptblock]$Until, [int]$TimeoutSeconds = 30, [int]$MinimumMilliseconds = 0)
    $T = $script:Ttg
    $dispatcher = $T.Window.Dispatcher
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        [void]$dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ $frame.Continue = $false }.GetNewClosure())
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        if ($Until) { $v = & $Until; if ($v -and $sw.ElapsedMilliseconds -ge $MinimumMilliseconds) { return $v } }
        elseif ($sw.ElapsedMilliseconds -ge $MinimumMilliseconds) { return $true }
        Start-Sleep -Milliseconds 20
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($Until) { return (& $Until) }
    return $true
}
#endregion

#region Dialogs -----------------------------------------------------------------------------------

function Confirm-TtgAction {
    # A yes / no question. Tests replace it through the state (ConfirmHook) and read what the console asked.
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Message, [switch]$Warning)
    $T = $script:Ttg
    $T.LastConfirm = @{ Title = $Title; Message = $Message }
    if ($T.ConfirmHook) { return [bool](& $T.ConfirmHook $Title $Message) }
    $icon = if ($Warning) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
    $r = [System.Windows.MessageBox]::Show($T.Window, $Message, $Title, [System.Windows.MessageBoxButton]::YesNo, $icon, [System.Windows.MessageBoxResult]::No)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

function Select-TtgFolder {
    param([string]$Description = 'Choose a folder', [string]$Initial)
    $T = $script:Ttg
    if ($T.FolderHook) { return & $T.FolderHook $Description }
    $dlg = [Microsoft.Win32.OpenFolderDialog]::new()
    $dlg.Title = $Description
    if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.InitialDirectory = $Initial }
    if ($dlg.ShowDialog($T.Window)) { return $dlg.FolderName }
    return $null
}

function Select-TtgFile {
    param([string]$Title = 'Choose a file', [string]$Filter = 'All files (*.*)|*.*')
    $T = $script:Ttg
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = $Title; $dlg.Filter = $Filter
    if ($dlg.ShowDialog($T.Window)) { return $dlg.FileName }
    return $null
}

function Open-TtgPath {
    # Opens a folder or a file with the shell (Explorer, the default browser). Nothing is run: only a path that exists.
    param([string]$Path)
    $T = $script:Ttg
    $T.LastOpened = $Path
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Set-TtgStatus "Not found: $Path"; return }
    if ($T.NoShell) { return }
    [void][Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{ FileName = $Path; UseShellExecute = $true })
}

function Set-TtgStatus {
    param([string]$Text, [string]$Right)
    $T = $script:Ttg
    if ($T.Ui.StatusText) { $T.Ui.StatusText.Text = $Text }
    if ($PSBoundParameters.ContainsKey('Right') -and $T.Ui.StatusRight) { $T.Ui.StatusRight.Text = $Right }
}
#endregion

#region Window and navigation ---------------------------------------------------------------------




function New-TtgSymbolIcon {
    param([string]$Name)
    $sym = [Wpf.Ui.Controls.SymbolRegular]::Circle24
    $parsed = [Wpf.Ui.Controls.SymbolRegular]::Circle24
    if ([Enum]::TryParse([Wpf.Ui.Controls.SymbolRegular], $Name, $true, [ref]$parsed)) { $sym = $parsed }
    $icon = [Wpf.Ui.Controls.SymbolIcon]::new()
    $icon.Symbol = $sym
    $icon.FontSize = 16
    return $icon
}

function Read-TtgXaml {
    param([Parameter(Mandatory)][string]$Name)
    $T = $script:Ttg
    $path = Join-Path (Join-Path $T.PackageRoot 'ui') $Name
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    if ($text -match '(?i)\sx:Class\s*=' -or $text -match '(?i)\s(Click|Loaded|Checked|Unchecked|SelectionChanged|Closed|Closing)\s*=') { throw "$Name must not contain code-behind or event attributes." }
    return [System.Windows.Markup.XamlReader]::Parse($text)
}





function Save-TtgWindowImage {
    <#
    .SYNOPSIS
        Writes a PNG of the window, rendered by WPF (deterministic; the real screen is never captured). The picture of a WebView2 control is taken from the control and drawn over its place.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$NoLive)
    $T = $script:Ttg
    $w = $T.Window
    $w.UpdateLayout()
    $width = [int][Math]::Ceiling($w.ActualWidth); $height = [int][Math]::Ceiling($w.ActualHeight)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    # The real window as the user sees it (DWM content, WebView2 included): PrintWindow with PW_RENDERFULLCONTENT, never the screen.
    if (-not $NoLive) {
        try {
            if (-not ('Ttg.Native' -as [type])) { Add-Type -Namespace Ttg -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr hwnd, System.IntPtr hdc, uint flags);[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT r);[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }' }
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle
            $r = [Ttg.Native+RECT]::new(); [void][Ttg.Native]::GetWindowRect($hwnd, [ref]$r)
            $pw = $r.Right - $r.Left; $ph = $r.Bottom - $r.Top
            if ($hwnd -ne [IntPtr]::Zero -and $pw -gt 100 -and $ph -gt 100) {
                $bmp = [System.Drawing.Bitmap]::new($pw, $ph)
                try {
                    $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
                    try { $okp = [Ttg.Native]::PrintWindow($hwnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
                    if ($okp) { $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); return $Path }
                } finally { $bmp.Dispose() }
            }
        } catch { Write-Verbose "PrintWindow: $($_.Exception.Message)" }
    }
    $background = $w.TryFindResource('ApplicationBackgroundBrush')
    if ($null -eq $background) { $background = [System.Windows.Media.Brushes]::Black }
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $ctx = $visual.RenderOpen()
    $ctx.DrawRectangle($background, $null, [System.Windows.Rect]::new(0, 0, $width, $height))
    $ctx.Close()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $bitmap.Render($w)
    # A WebView2 control is its own window: it is not part of a WPF render, so its picture is taken from the control and drawn over its place.
    $wv = $T.WebView
    if ($null -ne $wv -and $wv.Visibility -eq 'Visible' -and $null -ne $wv.CoreWebView2) {
        $ms = [IO.MemoryStream]::new()
        $task = $wv.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png, $ms)
        [void](Wait-TtgUi -Until { $task.IsCompleted } -TimeoutSeconds 20)
        if ($task.IsCompleted -and -not $task.IsFaulted) {
            $ms.Position = 0
            $img = [System.Windows.Media.Imaging.BitmapImage]::new(); $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.StreamSource = $ms; $img.EndInit(); $img.Freeze()
            $origin = $wv.TransformToAncestor($w).Transform([System.Windows.Point]::new(0, 0))
            $v2 = [System.Windows.Media.DrawingVisual]::new(); $c2 = $v2.RenderOpen()
            $c2.DrawImage($img, [System.Windows.Rect]::new($origin.X, $origin.Y, $wv.ActualWidth, $wv.ActualHeight)); $c2.Close()
            $bitmap.Render($v2)
        }
    }
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    return $Path
}

function Start-TtgConsole {
    <#
    .SYNOPSIS
        Builds the console and, unless -Harness, shows it until it is closed. With -Harness the window is returned unshown (tests, screenshots).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [switch]$Demo,
        [switch]$Harness,
        [string[]]$Support = @(),
        [string]$Theme,
        [string]$SettingsPath,
        [string]$ConfigPath,
        [string]$WebView2Error,
        [string]$DemoRoot,
        [int]$Width = 0, [int]$Height = 0
    )
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw 'The console needs an STA thread: start it with pwsh -STA (Start-TeamsTransferConsole.cmd does).' }
    $persist = [bool]$SettingsPath
    if (-not $SettingsPath) { $SettingsPath = Get-TtgDefaultSettingsPath }
    $script:Ttg = @{
        PackageRoot = $PackageRoot; Demo = [bool]$Demo; Support = $Support; SettingsPath = $SettingsPath; PersistSettings = $persist
        Settings = (Read-TtgSettings -Path $SettingsPath); Errors = [Collections.Generic.List[string]]::new(); Pages = @{}; Ui = @{}
        Tasks = [Collections.Generic.List[object]]::new(); NavDots = @{}; Job = $null; Window = $null; Current = $null; Suppress = $false
        WebView2Error = $WebView2Error; ConfigPath = $ConfigPath; StoreRoot = ''; Config = $null; ConfigError = $null
        ConfirmHook = $null; FolderHook = $null; NoShell = $false; LastConfirm = $null; LastOpened = $null; World = $null
        Fallbacks = @{}; DemoRoot = $DemoRoot; EffectiveTheme = 'Light'; Explorer = @{}; Checks = @{}
    }
    $T = $script:Ttg
    if ($ConfigPath) { $T.Settings.ConfigPath = $ConfigPath } elseif ($T.Settings.ConfigPath -and -not $Demo) { $T.ConfigPath = $T.Settings.ConfigPath }
    if ($Demo) {
        if (-not $T.DemoRoot) { $T.DemoRoot = Join-Path ([IO.Path]::GetTempPath()) ('TeamsTransferConsole-demo-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
        [void][IO.Directory]::CreateDirectory($T.DemoRoot)
        $T.World = New-TtgDemoWorld
        $T.StoreRoot = Join-Path $T.DemoRoot 'store'
        $T.DemoDefaults = Get-TtgDemoFormDefaults
    }
    Import-TtgConfiguration
    if ($Demo) { $T.World.Roles = @{ Source = @((Get-TtgRoleNeeds -Side 'Source').Keys); Target = @((Get-TtgRoleNeeds -Side 'Target').Keys) } }
    if (-not $Demo) { $initial = if ($T.Settings.StoreRoot) { $T.Settings.StoreRoot } elseif ($T.Config.Store.Path) { [string]$T.Config.Store.Path } else { Join-Path $T.OutRoot 'store' }; $T.StoreRoot = $initial }
    $T.JobsDir = Join-Path ([IO.Path]::GetTempPath()) 'TeamsTransferConsole'
    [void][IO.Directory]::CreateDirectory($T.JobsDir)

    # WPF application with the WPF-UI theme and control dictionaries (every control gets the Fluent templates).
    if ($null -eq [System.Windows.Application]::Current) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
        $app.Resources.MergedDictionaries.Add([Wpf.Ui.Markup.ThemesDictionary]::new())
        $app.Resources.MergedDictionaries.Add([Wpf.Ui.Markup.ControlsDictionary]::new())
        $T.App = $app
    } else { $T.App = [System.Windows.Application]::Current }
    $requested = if ($Theme) { $Theme } else { $T.Settings.Theme }
    $null = Set-TtgTheme -Requested $requested

    $window = New-TtgShell
    if ($Width -gt 0) { $window.Width = $Width }
    if ($Height -gt 0) { $window.Height = $Height }
    $T.Timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
    $T.Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    Add-TtgHandler $T.Timer 'Tick' { Update-TtgTasks }
    Initialize-TtgSteps
    Select-TtgStep 1

    Add-TtgHandler $window 'Closing' {
        param($s, $e)
        $t = Get-TtgState
        if ($t.Chain -and -not $t.Chain.Done) { $e.Cancel = $true; if (-not $t.NoShell) { [void][System.Windows.MessageBox]::Show($t.Window, 'A task is running. Stop it first (the requests in flight finish, nothing is lost), then close the console.', 'Teams Transfer', 'OK', 'Information') }; return }
        Stop-TtgConsole -Closing
    }
    if ($Harness) { return $T }
    try { [void]$window.ShowDialog() } finally { Stop-TtgConsole }
}

function Stop-TtgConsole {
    param([switch]$Closing)
    $T = $script:Ttg
    if ($null -eq $T) { return }
    if ($T.Chain -and $T.Chain.StopFile) { try { Set-Content -LiteralPath $T.Chain.StopFile -Value 'stop' } catch { Write-Verbose "stop file: $($_.Exception.Message)" } }
    foreach ($task in @($T.Tasks)) { try { $task.Ps.Stop() } catch { Write-Verbose "task stop: $($_.Exception.Message)" } }
    if ($T.Timer) { $T.Timer.Stop() }
    try { if ($T.WebView) { $T.WebView.Dispose() } } catch { Write-Verbose "webview dispose: $($_.Exception.Message)" }
    if (-not $Closing -and $T.Window) { try { $T.Window.Close() } catch { Write-Verbose "close: $($_.Exception.Message)" } }
}
#endregion

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBcnayWXAVwB9IY
# 5ZFHMOIh0703Xk73WpLBROkCCROeRqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYETCCGA0CAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCD1Exnw7zZ
# bmTGQDCFG8ZSvtZvBPyqM7F6h/ZoIjUpGjANBgkqhkiG9w0BAQEFAASCAgB54rYQ
# zH1i6392Jopu6yvIx1ovcfwTBfMMs978xm2G58hKRLgtsVC4kbbhB0glob0ze+qm
# CrvSE9f4DCenOuVaSQ9soWrrA9NCqf6GhiMGuVL3P0i9vX5WccUaPWjbMcEbITMu
# e3LvHyrC8dyGotj9WK7zzQitVeJkBlrlPyviBrNh0LF4gs3A6zcvOhLz6FV1uDYE
# iN+DLMmjwxvr6fi72S4F/MGHsSeDf/7ZKnmcVk5M/HqzxL4XS69+mwpnoN8AnO7I
# iDMVVoG5ndnSMgP/TedmPLtpj2vbbf3LfKCaJHuti79bNmE553kfR2rPdaFF7SCt
# k5JN4iH4kJkbuihz6kRquzG8tXu+bGA5GArsRKqUgPOFE+5+8wLC9tt5ZjVb7xxk
# lrOJtP5vwBh7/rc8IptbI+DiuiHbmxz0AZ3gr0899gIZ0D5yzPLh8Ww7v7dRRvC5
# Y5Y5kdHm9iaSZDn73eSIPrIYhnIUXlhoXboo4Fp04DawFRLeM348Oh2toBCWCq9J
# 89r9q+Jg95ufhrCjBU8OsWSpQtgyEWP+KrasVsWJO87bj9uloAs8NEPOTVkr8QBL
# GV4YQOOQsCRPVU0IvOSQd1zqtX3JAzCwrv4pjA7bGskquIW8fks7k/8DbnqAFVwK
# B1rUQb7KzzM0rCoTnOTnHkX+FvwLrKhxzuB+LaGCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIFllUgziSH2dmmoqqtx4mVZs1J2hvUcEI4Bjk/oICinlAgh03jGCzNkJ
# XhgPMjAyNjExMTExNzU3MThaMAMCAQECEAVzJA62rokIVn8N5Qjg3RGgghGnMIIE
# 8zCCAtugAwIBAgIQVEP4N71a7hgBhHK4XNqO4zANBgkqhkiG9w0BAQsFADByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyMB4XDTI2MDYxMjE3MjI0NloXDTM2MDYwOTE3MjI0NVow
# bjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBp
# bmcgVW5pdCAyMDI2IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6CWLuGYT
# LkiSOPMLNskOBthXsIhRSA46feOQwvSLcDaNh6vxUzBKEx1KdFBRFs7OHrnH/K0V
# A6MbDQIFpUg0PaOCAVIwggFOMB8GA1UdIwQYMBaAFHCaZcFDgKP86bFkiW7xMJwJ
# Icl8ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3Ns
# LmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1JLVIyLmNlcjBRBgNVHSAESjBIMDwG
# DCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29t
# L3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEIG
# A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNvbS10aW1l
# U3RhbXBpbmctSS1SMi5jcmwwHQYDVR0OBBYEFCesA1a6KGq6FzuDPUB/eagk7MM8
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT3ZuzvwDnsIZTXBn
# +hjmuBXgzB12fbYxT9uYe6ZvhvpbZWKcyDQgacETkPw8k6yeqnYCYyFZ063lMPEq
# AhAD2nMG614Zh7PtHW9DWqfsgivxbPYBeN+t7UxgkYT3expbWMdPEqBtWVyHOvLc
# KvMxgJWfJjANwVkwVDfky/j7cf28+iimN8PKc7S/u8/LenRRnV2W2YfncRnkz9Cf
# s5nRDzaZguiHrrp2GxwgnNQSH4GBjHOl3PzLsnVbGoZKi4ZEjgXups4mGGOK7+GB
# 2HAlQn+OS944cHqlkH0gElt2WezoCNRpELph9qaxuBnjSEqXWWfgE6yGBwO0uxKN
# qpWVTHmAwr6SvBPofxubXIuEn9ivR4CLOuAxUSrJ41ZBg/qqG0oJjF6GkRKbxq7c
# yWSkEZYJhmKCg2Hg5fXHagOxiwbmn5JPZ1vhWCrbk3v/dTx2gvTK5+erC5H9/rTc
# ljUI776yd2rfhjfkpvyAsbtXs4D7nrnw8i9wor5+fdtRSJBVxqzLmykFftoL0Up2
# Q++tyKCUdribdcnrB4HKS3s+t3AjdcbA06DCL8GifQi9fL0yRBRNlA4o6BP+Sr75
# 5MaCNjURYZDvDyxJHBBT7cqjZIwsiR8s+6860noFbBBtdge2Iw7CPC/1Q31I27hV
# olS7B0yao3v8X2MtWy3msZlXTcEwggXdMIIDxaADAgECAgh7LJvTFoAymTANBgkq
# hkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8GA1UEAwwo
# U1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAeFw0xNjAy
# MTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQI
# DAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0
# aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3Jp
# dHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/doyt9y9Aq
# /uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aUnheDhc5W
# 7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q6Pw/YUjt
# sAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg+sglkrRu
# eiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qhk4jrwZe8
# jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmylD0CGfAL0
# XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUuqfqeLLZR
# Rv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiYohgsQkCz
# +W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZTNTX8N+TD
# 9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZX5es6+8u
# yLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumamdu0bc+sa
# pQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYEFN0ECQei
# 9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU3QQJ
# B6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUA
# A4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9eGr0uYul
# lzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK3cT5lR+K
# OEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF9J1r/Blj
# naO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9hqTKWzN67
# 7WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg+/a1LRrm
# woWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP5UU/eNu6
# 0htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53eyoHWXtS2B
# iBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8PUkg9v2zY
# okQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaPzvDsbopX
# C4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOLYRu8+h+R
# K9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBsswggSzoAMC
# AQICEFKdu8K4iYf1g4DgsOuiBjYwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9T
# U0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0
# aW9uIEF1dGhvcml0eSBSU0EwHhcNMjYwNjEyMTY0MjE1WhcNNDEwMjEyMTczOTM5
# WjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFt
# cGluZyBJc3N1aW5nIFJTQSBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAny+r5nNNkLwxRps2B3laUGNU9y7vWiJ5013yf0iXz65bQdwa9bjj8l/S
# keXqHGqfSh2Foae+80E8mDEf93oIwjsy2CX2cXmKxqtF8HJGYB4f6yRhKED50wkb
# OysL02IXf+/EZna44jffhhVz4OU/k52xQ/PnIg/uFhc2Wk+Sc/CHqAr+lYVkPz7L
# y5RqB9f1RKGr9JC37W1LgVdHC50dNIdsa3QXPhltYZubR3npE4Bbfi0joUW5n5O0
# ayweN45R/YVLxA0YGlp1OHVfVnsqXq8bhnw1Lc4kjJ6XOgXlOlw/a8ze57TvbduZ
# l3ehewTmvO0Aky/nqOWDS9IPPxdxdG6vprBbSuHlxNANBAbHTiFgkfZmf0dZYlT/
# AnZIoFxAq0HILPolf4OgWgET76SiWSlm2XYRIXwVjpeqG0plvXwRIQBzSiEJj7Qe
# QFnCvHx4gQMINvN3+yG/1rxhEbajGve0tTP3lX4PPOHVAE0QJp4ZzPI1YYJkhVRr
# iVVxVRU4Fsg4BPwP6I+YLmHb1tZ4RLwOFNLh/gJYDgPlChCoxOogFxXgwPZZrDyE
# RYB0aeOexW0OKacN4RRu9cqF2KKu/Ab5AL7eYDLVGUPrEEyYbIMApVKqpebc0/jD
# QniC+3rkauRAjgVc8m1ip/CQgG1Dw4Z9ulVRAY9VR6Za26LsTbUCAwEAAaOCAVEw
# ggFNMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKS
# le44gCUNplkwTQYIKwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2Vy
# dC5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY2VyMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwQgYDVR0fBDswOTA3oDWgM4Yx
# aHR0cDovL2NybHMuc3NsLmNvbS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNy
# bDAdBgNVHQ4EFgQUcJplwUOAo/zpsWSJbvEwnAkhyXwwDgYDVR0PAQH/BAQDAgGG
# MA0GCSqGSIb3DQEBCwUAA4ICAQBlFFvNMemA6iBiBYo56IKQjWhWuQaYKuo4qpf0
# KJNERAt1gz+HsA2SL3xA/V+EA8SRPNP9SvX0is+5mDsppYvpKyYGqYP36YFW0mbF
# 1F0ZtXxumCUUO/ZV5mBNKDf5Q4PY7Qb0eWAepUc0rNJr/Mvn5ZiXfJPxDb2xmcg8
# aRD652/nr+Ork2UBP0E43iJdI4LF7Vs29R3SGRLYZOxM15DI4QebsKRl0KDlf4Om
# YGCKc7umTxibkZtN1C1KWgnf9jadU/JwnySaYEBgx6/v+FVC6SGONziY7TcvI9MV
# +qYxHUPlOm6AaQP2dS4bjWXnm86ldCbUkxtOACumSfT97077JNiVa7PZ1IBkd/2P
# E1AC8gs7U+/Yk1BN9XRPIi15k/uA1xF9oeee5KGjyiGKkqIT7W8QkgUT5zeCinFK
# kcKafZMcROSVYpXtmtQqGGR2g4uPYqJ0K1hms6gJXrHt/34p8M9PrV8oNWe0Zl1E
# rDMtXndUg3qhJL4pA3ZUlo7w5lM5ml+A7ijr/3Gk2v4QRoDeE2ShmTXdHgtqo8L/
# fT119mYcETycE2NYGRXsBl3N0rzDsHRr8P3TrprqhRrX04iS0P7eQ+lDxgS3yhGn
# 3OzWGhDt9Gf2x1qe0/qdhFAVOkXxzMZz4Uat6xsAfzX0+/m8GEKW5Ojw/HY+kLvV
# wzSPOzGCAlYwggJSAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMTE3NTcxOFowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEILu4
# jAn2XS1BGQeF7lz4ff1VoRSeFfnn11lWYIWg1fP6MIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiAk3TOAOIrdrzc/N2BplY1YcQ4CjhFmLXICSYg8qYeaIgIhAK5x
# vHAUPID3V/gKIlbGfWzeOLXqP1Z0kvQr8NHKYB9L
# SIG # End signature block
