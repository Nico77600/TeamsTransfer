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
