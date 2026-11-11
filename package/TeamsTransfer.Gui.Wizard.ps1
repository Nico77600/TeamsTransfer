# TeamsTransfer console - the guided flow (Setup, Task, Verify, Run, Next steps), the Explorer viewer and the shared helpers.
# Dot-sourced into the module TeamsTransferGui after TeamsTransfer.Gui.Core.ps1.

$script:TtgRoleCheckScript = @'
param($Pkg, $Config, $Side)
Import-Module (Join-Path $Pkg 'TeamsTransfer.psd1') -Force
Initialize-TmtEngine
$s = $Config[$Side]
foreach ($k in 'TenantId', 'ClientId', 'CertificateThumbprint') { if (-not $s[$k]) { throw "$Side.$k is empty: fill config\TeamsTransfer.config.local.psd1." } }
$cloud = [TeamsTransfer.GraphCloud]($(if ($s.Cloud) { $s.Cloud } else { 'Global' }))
$provider = [TeamsTransfer.CertificateTokenProvider]::FromThumbprint([string]$s.TenantId, [string]$s.ClientId, [string]$s.CertificateThumbprint, $cloud, $null)
$token = $provider.GetTokenAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
$payload = ($token -split '\.')[1].Replace('-', '+').Replace('_', '/')
$payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
# Only the roles leave this script: never the token.
[pscustomobject]@{ Roles = @($claims.roles | ForEach-Object { [string]$_ }); Expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).ToString('u') }
'@

$script:TtgArchiveScript = @'
param($Pkg, $Demo, $Support, $StoreRoot, $Out, $Users, $Conversation, $Viewer, $Title)
Import-Module (Join-Path $Pkg 'TeamsTransfer.psd1') -Force
if ($Demo) { Initialize-TmtEngine -AdditionalSource $Support } else { Initialize-TmtEngine }
$store = Open-TmtStore -Root $StoreRoot -ReadOnly
try {
    $a = @{ Store = $store; OutputPath = $Out; Title = $Title }
    if ($Users) { $a.Users = @($Users) }
    if ($Conversation) { $a.Conversation = @($Conversation) }
    if ($Viewer) { $a.Viewer = $Viewer }
    $r = Export-TmtArchive @a
    [pscustomobject]@{ Path = $Out; Index = (Join-Path $Out 'index.html'); Messages = $r.Messages; Conversations = $r.Conversations }
} finally { $store.Dispose() }
'@


function Get-TtgShown {
    # What the screen shows. In Demo mode the real machine, user and folders never appear (the screenshots are published): neutral names instead.
    param([string]$Text)
    $T = $script:Ttg
    if (-not $T.Demo -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $shown = $Text
    $pairs = @(
        @($T.DemoRoot, 'D:\TeamsTransfer'), @($T.JobsDir, 'D:\TeamsTransfer\tmp'), @($T.PackageRoot, 'D:\TeamsTransfer\package'),
        @([IO.Path]::GetTempPath().TrimEnd('\'), 'D:\TeamsTransfer\tmp'), @($env:LOCALAPPDATA, 'C:\Users\admin\AppData\Local'), @($env:USERPROFILE, 'C:\Users\admin'),
        @($env:COMPUTERNAME, 'ADMIN-WS01'), @($env:USERNAME, 'admin')
    )
    foreach ($p in $pairs) { if ($p[0]) { $shown = [regex]::Replace($shown, [regex]::Escape([string]$p[0]), [string]$p[1].Replace('$', '$$'), 'IgnoreCase') } }
    return $shown
}
function Get-TtgPermissionTable {
    # package\config\Permissions.psd1: the one table of the application permissions per mode (shared with the guide and Grant-LabConsent).
    $T = $script:Ttg
    if (-not $T.PermissionTable) { $T.PermissionTable = Import-PowerShellDataFile -LiteralPath (Join-Path $T.PackageRoot 'config\Permissions.psd1') }
    return $T.PermissionTable
}

function Get-TtgRoleNeeds {
    # Role -> the modes that need it (required permissions only), for one side, in the order of the modes.
    param([ValidateSet('Source', 'Target')][string]$Side)
    $table = Get-TtgPermissionTable
    $map = [ordered]@{}
    foreach ($mode in 'Assess', 'Inventory', 'Export', 'Files', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify') {
        $m = $table.Modes[$mode]
        if ($null -eq $m -or $m.Side -ne $Side) { continue }
        foreach ($p in $m.Required) { $map[$p.Name] = if ($map.Contains($p.Name)) { $map[$p.Name] + ', ' + $mode } else { $mode } }
    }
    return $map
}
function Test-TtgRoleGranted {
    # A role is granted when it is in the token, or when a broader one is (X.ReadWrite.All covers X.Read.All; X.Read.All covers X.ReadBasic.All).
    param([Parameter(Mandatory)][string]$Role, [string[]]$Granted = @())
    if ($Role -in $Granted) { return $true }
    if ($Role -like '*.ReadBasic.*' -and (($Role -replace '\.ReadBasic\.', '.Read.') -in $Granted -or ($Role -replace '\.ReadBasic\.', '.ReadWrite.') -in $Granted)) { return $true }
    if ($Role -like '*.Read.*' -and ($Role -replace '\.Read\.', '.ReadWrite.') -in $Granted) { return $true }
    return $false
}

function Get-TtgStoreSnapshot {
    # Opens the store read-only for a moment and returns Get-TmtStoreStatus (or $null). Never throws.
    $T = $script:Ttg
    if (-not (Test-TtgStoreExists)) { return $null }
    $store = $null
    try {
        $store = Open-TmtStore -Root $T.StoreRoot -ReadOnly
        return Get-TmtStoreStatus -Store $store
    } catch { $T.StoreReadError = $_.Exception.Message; return $null }
    finally { if ($null -ne $store) { try { $store.Dispose() } catch { Write-Verbose "store dispose: $($_.Exception.Message)" } } }
}

function Update-TtgTenant {
    param([ValidateSet('Source', 'Target')][string]$Side)
    $T = $script:Ttg
    $root = $T.Pages.Home.Root
    $s = $T.Config[$Side]
    $configured = [bool]($s.TenantId -and $s.ClientId -and $s.CertificateThumbprint)
    $info = $root.FindName("${Side}Info"); $state = $root.FindName("${Side}State"); $light = $root.FindName("${Side}Light")
    if ($configured) {
        $thumb = [string]$s.CertificateThumbprint
        $info.Text = "Tenant $($s.TenantId)`nApplication $($s.ClientId)`nCertificate $(if ($thumb.Length -gt 12) { $thumb.Substring(0, 8) + '...' + $thumb.Substring($thumb.Length - 4) } else { $thumb })"
    } else { $info.Text = 'Not configured. Fill the section in config\TeamsTransfer.config.local.psd1 (Settings shows the path).' }
    $check = $T.Checks[$Side]
    if (-not $configured) { Set-TtgLight $light 'Gray'; $state.Text = 'Not configured' }
    elseif ($null -eq $check) { Set-TtgLight $light 'Amber'; $state.Text = 'Configured, permissions not checked yet' }
    elseif ($check.Error) { Set-TtgLight $light 'Red'; $state.Text = "Check failed: $($check.Error)" }
    else {
        $missing = @($check.Missing)
        if ($missing.Count -eq 0) { Set-TtgLight $light 'Green'; $state.Text = "All permissions present (token valid until $($check.Expires))" }
        else { Set-TtgLight $light 'Red'; $state.Text = "$($missing.Count) permission(s) missing: $($missing -join ', ')" }
    }
    Show-TtgRoles -Side $Side
    $btn = $root.FindName("${Side}Check")
    $btn.IsEnabled = $configured
}

function Show-TtgRoles {
    param([ValidateSet('Source', 'Target')][string]$Side)
    $T = $script:Ttg
    $panel = $T.Pages.Home.Root.FindName("${Side}Roles")
    $panel.Children.Clear()
    $check = $T.Checks[$Side]
    foreach ($kv in (Get-TtgRoleNeeds -Side $Side).GetEnumerator()) {
        $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 9; $dot.Height = 9; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0); $dot.VerticalAlignment = 'Center'
        $state = 'Gray'
        if ($check -and -not $check.Error) { $state = if (Test-TtgRoleGranted -Role $kv.Key -Granted @($check.Roles)) { 'Green' } else { 'Red' } }
        Set-TtgLight $dot $state
        $name = [System.Windows.Controls.TextBlock]::new(); $name.Text = $kv.Key; $name.FontSize = 12; $name.Width = 190
        $modes = [System.Windows.Controls.TextBlock]::new(); $modes.Text = $kv.Value; $modes.FontSize = 12; Set-TtgRef ($modes) Foreground 'TextFillColorSecondaryBrush'
        [void]$row.Children.Add($dot); [void]$row.Children.Add($name); [void]$row.Children.Add($modes)
        [void]$panel.Children.Add($row)
    }
}

function Set-TtgCheckResult {
    param([string]$Side, $Roles, [string]$Expires, [string]$ErrorText)
    $T = $script:Ttg
    if ($ErrorText) { $T.Checks[$Side] = @{ Error = $ErrorText } }
    else {
        $granted = @($Roles | ForEach-Object { [string]$_ })
        $missing = @((Get-TtgRoleNeeds -Side $Side).Keys | Where-Object { -not (Test-TtgRoleGranted -Role $_ -Granted $granted) })
        $T.Checks[$Side] = @{ Roles = $granted; Missing = $missing; Expires = $Expires; Error = $null }
    }
    Update-TtgTenant -Side $Side
}

function Start-TtgRoleCheck {
    # Reads the roles of the application token (the token itself is never kept or shown).
    param([ValidateSet('Source', 'Target')][string]$Side)
    $T = $script:Ttg
    if ($T.Demo) {
        Set-TtgCheckResult -Side $Side -Roles $T.World.Roles[$Side] -Expires ((Get-Date).AddHours(1).ToUniversalTime().ToString('u'))
        Set-TtgStatus "$Side permissions checked (demo apps)"
        return
    }
    Set-TtgStatus "Checking the $Side permissions..."
    $cfg = @{ Source = $T.Config.Source; Target = $T.Config.Target }
    [void](Start-TtgBackground -ScriptText $script:TtgRoleCheckScript -ArgumentList @($T.PackageRoot, $cfg, $Side) -Tag $Side -OnDone {
            param($out, $errs, $side)
            if ($errs.Count -gt 0 -or $out.Count -eq 0) { Set-TtgCheckResult -Side $side -ErrorText ($(if ($errs.Count) { $errs[0] } else { 'no answer' }) -replace '\s+', ' ') }
            else { Set-TtgCheckResult -Side $side -Roles $out[0].Roles -Expires $out[0].Expires }
            Set-TtgStatus "$side permissions checked"
        })
}

function Read-TtgLogTail {
    # New lines of the house log since the job started (the file is shared and appended to, so it is read with sharing and from an offset).
    param($Job)
    if (-not (Test-Path -LiteralPath $Job.LogPath)) { return @() }
    $fs = $null
    try {
        $fs = [IO.FileStream]::new($Job.LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        if ($fs.Length -le $Job.LogOffset) { return @() }
        [void]$fs.Seek($Job.LogOffset, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int][Math]::Min($fs.Length - $Job.LogOffset, 1MB))
        $n = $fs.Read($buf, 0, $buf.Length)
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $cut = $text.LastIndexOf("`n")
        if ($cut -lt 0) { return @() }
        $Job.LogOffset += [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $cut + 1))
        return @($text.Substring(0, $cut) -split "`r?`n" | Where-Object { $_ })
    } catch { return @() }
    finally { if ($fs) { $fs.Dispose() } }
}

function Get-TtgApplyMessage {
    param([Parameter(Mandatory)][string]$Mode, [hashtable]$Params, [string]$StoreRoot, [string]$Tenant)
    $lot = if ($Params.Lot) { " of lot '$($Params.Lot)'" } else { '' }
    $what = switch ($Mode) {
        # $Params is a hashtable: $Params.Remove would be its Remove() method (always truthy) - index it.
        'Ghosts' { if ($Params['Remove']) { "DELETE the ghost accounts recorded in the catalog$lot" } else { "create disabled, unlicensed ghost accounts$lot" } }
        'CopyFiles' { "upload the exported files$lot into OneDrive and the channel libraries, and share them" }
        'Import' { "create the conversations and post the messages$lot" }
        default { "write$lot" }
    }
    $extra = if ($Mode -eq 'Import') { "`n`nAn imported conversation cannot be rolled back. Run the preview and review the plan first." } else { '' }
    return "This will $what.`n`nTarget tenant: $Tenant`nStore: $StoreRoot$extra`n`nContinue?"
}

function Get-TtgExitInfo {
    param([int]$ExitCode, [string]$Mode, [bool]$Preview)
    switch ($ExitCode) {
        0 { @{ Light = 'Green'; Title = $(if ($Preview) { 'Preview complete: nothing was written' } else { 'Complete' }) } }
        1 { @{ Light = 'Red'; Title = 'Failed' } }
        2 { @{ Light = 'Amber'; Title = 'Not complete: nothing was lost, run it again to continue' } }
        3 { @{ Light = 'Amber'; Title = $(if ($Mode -eq 'Plan') { 'The plan has blockers: fix them and plan again' } else { 'Uncertain items: settle them before running again' }) } }
        default { @{ Light = 'Gray'; Title = "Exit code $ExitCode" } }
    }
}

function Add-TtgKpi {
    # A card: label, big number, status pill (Level Ok / Warn / Fail; none for a plain number).
    param($Panel, [string]$Label, [string]$Value, [string]$Level, [string]$PillText)
    $b = [System.Windows.Controls.Border]::new()
    $b.Padding = [System.Windows.Thickness]::new(16, 10, 16, 10); $b.Margin = [System.Windows.Thickness]::new(0, 0, 12, 12); $b.CornerRadius = [System.Windows.CornerRadius]::new(10); $b.MinWidth = 150
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'CardBackgroundFillColorDefaultBrush')
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'CardStrokeColorDefaultBrush')
    $sp = [System.Windows.Controls.StackPanel]::new()
    $l = [System.Windows.Controls.TextBlock]::new(); $l.Text = $Label; $l.FontSize = 12; Set-TtgRef $l Foreground 'TextFillColorSecondaryBrush'
    $v = [System.Windows.Controls.TextBlock]::new(); $v.Text = $Value; $v.FontSize = 26; $v.FontWeight = [System.Windows.FontWeights]::SemiBold; Set-TtgRef $v Foreground 'TextFillColorPrimaryBrush'
    [void]$sp.Children.Add($l); [void]$sp.Children.Add($v)
    if ($Level) {
        $pb = [System.Windows.Controls.Border]::new(); $pb.CornerRadius = [System.Windows.CornerRadius]::new(9); $pb.Padding = [System.Windows.Thickness]::new(8, 1, 8, 1); $pb.HorizontalAlignment = 'Left'; $pb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        $pt = [System.Windows.Controls.TextBlock]::new(); $pt.Text = $PillText; $pt.FontSize = 11; $pt.FontWeight = [System.Windows.FontWeights]::SemiBold
        $pb.Child = $pt; Set-TtgPill $pb $pt $Level
        [void]$sp.Children.Add($pb)
    }
    $b.Child = $sp
    [void]$Panel.Children.Add($b)
}

function Get-TtgConversationTitle {
    param($Conversation)
    $topic = [string]$Conversation.Topic
    if ([string]$Conversation.Kind -eq 'Channel') { return ("{0} / {1}" -f $Conversation.TeamDisplayName, $(if ($topic) { $topic } else { 'channel' })) }
    if ($topic) { return $topic }
    $names = @()
    try { $names = @(($Conversation.MembersJson | ConvertFrom-Json) | ForEach-Object { [string]$_.displayName } | Where-Object { $_ } | Select-Object -First 3) } catch { Write-Verbose "members: $($_.Exception.Message)" }
    if ($names) { return $names -join ', ' }
    return [string]$Conversation.Key
}

function Read-TtgExplorerItems {
    # Users and conversations of the store (read only), as light display records. Never throws.
    $T = $script:Ttg
    $items = [Collections.Generic.List[object]]::new()
    if (-not (Test-TtgStoreExists)) { return @() }
    $store = $null
    try {
        $store = Open-TmtStore -Root $T.StoreRoot -ReadOnly
        foreach ($u in @($store.ListUsers() | Sort-Object DisplayName)) {
            $items.Add([pscustomobject]@{ Kind = 'User'; Key = [string]$u.UserPrincipalName; Id = [string]$u.Id; Title = [string]$u.DisplayName; Subtitle = ("{0} - {1}" -f $u.UserPrincipalName, $u.State)
                    Search = ("$($u.DisplayName) $($u.UserPrincipalName) $($u.Mail)").ToLowerInvariant() })
        }
        foreach ($c in @($store.ListConversations() | Sort-Object LastActivityUtc -Descending)) {
            $title = Get-TtgConversationTitle $c
            $items.Add([pscustomobject]@{ Kind = 'Chat'; Key = [string]$c.Key; Id = [string]$c.Key; Title = $title; Subtitle = ("{0}, {1} member(s)" -f $c.Kind, $c.MemberCount); Search = ("$title $($c.Key) $($c.Kind)").ToLowerInvariant() })
        }
    } catch { $T.Errors.Add("Explorer list: $($_.Exception.Message)") }
    finally { if ($null -ne $store) { try { $store.Dispose() } catch { Write-Verbose "store dispose: $($_.Exception.Message)" } } }
    return $items.ToArray()
}

function Update-TtgExplorerList {
    $T = $script:Ttg
    $root = $T.Pages.Explorer.Root
    $list = $root.FindName('ExplorerList')
    $q = $root.FindName('ExplorerSearch').Text.Trim().ToLowerInvariant()
    $kind = if ($T.Explorer.Mode -eq 'Chats') { 'Chat' } else { 'User' }
    $match = @($T.Explorer.Items | Where-Object { $_.Kind -eq $kind -and (-not $q -or $_.Search.Contains($q)) })
    $T.Suppress = $true
    try {
        $list.Items.Clear()
        foreach ($m in ($match | Select-Object -First 400)) {
            $sp = [System.Windows.Controls.StackPanel]::new()
            $a = [System.Windows.Controls.TextBlock]::new(); $a.Text = $m.Title; $a.FontWeight = [System.Windows.FontWeights]::SemiBold; $a.TextTrimming = 'CharacterEllipsis'
            $b = [System.Windows.Controls.TextBlock]::new(); $b.Text = $m.Subtitle; $b.FontSize = 11; $b.TextTrimming = 'CharacterEllipsis'; Set-TtgRef ($b) Foreground 'TextFillColorSecondaryBrush'
            [void]$sp.Children.Add($a); [void]$sp.Children.Add($b)
            $item = [System.Windows.Controls.ListBoxItem]::new(); $item.Content = $sp; $item.Tag = $m
            [System.Windows.Automation.AutomationProperties]::SetName($item, $m.Title)
            [void]$list.Items.Add($item)
        }
    } finally { $T.Suppress = $false }
    $root.FindName('ExplorerCount').Text = if ($match.Count -gt 400) { "$(Format-TmtNumber $match.Count) found, the first 400 are shown: refine the search" } else { "$(Format-TmtNumber $match.Count) found" }
}

function Set-TtgExplorerMessage {
    param([string]$Text, [string]$Icon = 'Chat24', [switch]$Hide)
    $T = $script:Ttg
    $root = $T.Pages.Explorer.Root
    $panel = $root.FindName('ExplorerMessage')
    if ($Hide) { $panel.Visibility = 'Collapsed'; return }
    $root.FindName('ExplorerMessageText').Text = $Text
    $parsed = [Wpf.Ui.Controls.SymbolRegular]::Chat24
    if ([Enum]::TryParse([Wpf.Ui.Controls.SymbolRegular], $Icon, $true, [ref]$parsed)) { $root.FindName('ExplorerMessageIcon').Symbol = $parsed }
    $panel.Visibility = 'Visible'
    if ($T.WebView) { $T.WebView.Visibility = 'Collapsed' }
}

function Test-TtgRuntimeWebView2 {
    # The WebView2 runtime (Evergreen) version, or $null. Never throws.
    try { return [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() } catch { return $null }
}

function Confirm-TtgExternalLink {
    param([string]$Uri)
    $T = $script:Ttg
    $T.Explorer.Blocked.Add($Uri)
    if ($Uri -notmatch '^https?://') { return }
    if (Confirm-TtgAction -Title 'Open an external link' -Message "This link is outside the archive:`n$Uri`n`nOpen it in your default browser?" -Warning) { Open-TtgPath $Uri }
}

function Initialize-TtgWebView {
    $T = $script:Ttg
    if ($T.WebView -or $T.WebViewTried) { return }
    $T.WebViewTried = $true
    if (-not $T.WebView2Error -and -not ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) { $T.WebView2Error = 'The WebView2 libraries are missing (run tools\Get-TeamsTransferDependencies.ps1).' }
    if (-not $T.WebView2Error) {
        $version = Test-TtgRuntimeWebView2
        if (-not $version) { $T.WebView2Error = 'The Microsoft Edge WebView2 runtime is not installed. Install it from https://developer.microsoft.com/microsoft-edge/webview2/ (it ships with Windows 11 and Microsoft 365). The rest of the console works without it.' }
        else { $T.WebView2Runtime = $version }
    }
    if ($T.WebView2Error) { Set-TtgExplorerMessage -Text $T.WebView2Error -Icon 'Warning24'; return }
    try {
        $wv = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
        $props = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
        $props.UserDataFolder = if ($T.Demo) { Join-Path $T.DemoRoot 'webview2' } else { Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }) 'TeamsTransfer\webview2' }
        $wv.CreationProperties = $props
        $wv.Visibility = 'Collapsed'
        Add-TtgHandler $wv 'CoreWebView2InitializationCompleted' {
            param($s, $e)
            $t = Get-TtgState
            if (-not $e.IsSuccess) { $t.WebView2Error = "The viewer could not start: $($e.InitializationException.Message)"; Set-TtgExplorerMessage -Text $t.WebView2Error -Icon 'Warning24'; return }
            $core = $s.CoreWebView2
            $debug = [bool]$env:TEAMSTRANSFER_GUI_DEBUG
            $core.Settings.AreDevToolsEnabled = $debug
            $core.Settings.AreDefaultContextMenusEnabled = $debug
            $core.Settings.IsStatusBarEnabled = $false
            $core.Settings.IsZoomControlEnabled = $false
            $core.Settings.AreBrowserAcceleratorKeysEnabled = $debug
            $core.Settings.IsPasswordAutosaveEnabled = $false; $core.Settings.IsGeneralAutofillEnabled = $false
            $t.Explorer.Ready = $true
            Update-TtgWebViewTheme
            $core.add_NewWindowRequested({ param($cs, $ce) $ce.Handled = $true; try { Confirm-TtgExternalLink -Uri $ce.Uri } catch { Add-TtgError $_ } })
            if ($t.Explorer.Pending) { $u = $t.Explorer.Pending; $t.Explorer.Pending = $null; Set-TtgExplorerMessage -Hide; $s.Visibility = 'Visible'; $core.Navigate($u) }
        }
        Add-TtgHandler $wv 'NavigationStarting' {
            param($s, $e)
            $t = Get-TtgState
            $ok = $false
            try {
                $u = [Uri]$e.Uri
                if ($u.IsFile -and $t.Explorer.ArchiveRoot) {
                    $root = [IO.Path]::GetFullPath($t.Explorer.ArchiveRoot).TrimEnd('\') + '\'
                    $ok = [IO.Path]::GetFullPath($u.LocalPath).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
                } elseif ($u.AbsoluteUri -eq 'about:blank') { $ok = $true }
            } catch { $ok = $false }
            if ($ok) { $t.Explorer.Navigations.Add([string]$e.Uri); return }
            $e.Cancel = $true
            Confirm-TtgExternalLink -Uri ([string]$e.Uri)
        }
        Add-TtgHandler $wv 'NavigationCompleted' { param($s, $e) $t = Get-TtgState; $t.Explorer.LastNavigationOk = [bool]$e.IsSuccess; $t.Explorer.LastNavigationUri = [string]$s.Source }
        $T.Pages.Explorer.Root.FindName('WebHost').Child = $wv
        $T.WebView = $wv
        # EnsureCoreWebView2Async refuses to run before the dispatcher loop runs: start it from the loop.
        [void]$T.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ try { [void](Get-TtgState).WebView.EnsureCoreWebView2Async($null) } catch { Add-TtgError $_; (Get-TtgState).WebView2Error = "The viewer could not start: $($_.Exception.Message)"; Set-TtgExplorerMessage -Text (Get-TtgState).WebView2Error -Icon 'Warning24' } })
    } catch {
        $T.WebView2Error = "The viewer could not start: $($_.Exception.Message)"
        Set-TtgExplorerMessage -Text $T.WebView2Error -Icon 'Warning24'
    }
}

function Update-TtgWebViewTheme {
    $T = $script:Ttg
    if ($null -eq $T -or $null -eq $T.WebView -or $null -eq $T.WebView.CoreWebView2) { return }
    try {
        $scheme = if ($T.EffectiveTheme -eq 'Dark') { [Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme]::Dark } else { [Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme]::Light }
        $T.WebView.CoreWebView2.Profile.PreferredColorScheme = $scheme
    } catch { Write-Verbose "webview theme: $($_.Exception.Message)" }
}

function Show-TtgArchiveUrl {
    param([Parameter(Mandatory)][string]$Index)
    $T = $script:Ttg
    if ($T.WebView2Error) { Set-TtgExplorerMessage -Text "The archive was built, but it cannot be shown here: $($T.WebView2Error)`nIt is in $($T.Explorer.ArchiveRoot). Use Open in browser." -Icon 'Warning24'; return }
    $uri = [Uri]::new($Index)
    $wv = $T.WebView
    if ($null -ne $wv -and $null -ne $wv.CoreWebView2) {
        Set-TtgExplorerMessage -Hide
        $wv.Visibility = 'Visible'
        $wv.CoreWebView2.Navigate($uri.AbsoluteUri)
    } else {
        $T.Explorer.Pending = $uri.AbsoluteUri
        Set-TtgExplorerMessage -Text 'Starting the viewer...' -Icon 'ArrowSync24'
    }
}

function New-TtgField {
    # One labelled control. Returns @{ Panel; Control; Type }.
    param([Parameter(Mandatory)][hashtable]$Spec, $Default)
    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Width = 252; $panel.Margin = [System.Windows.Thickness]::new(0, 0, 18, $(if ($Spec.Type -eq 'check') { 4 } else { 10 }))
    $type = $Spec.Type
    $ctl = $null
    if ($type -ne 'check') {
        $lab = [System.Windows.Controls.TextBlock]::new(); $lab.Text = $Spec.Label; $lab.FontSize = 12; $lab.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
        Set-TtgRef ($lab) Foreground 'TextFillColorSecondaryBrush'
        [void]$panel.Children.Add($lab)
    }
    switch ($type) {
        'check' {
            $ctl = [System.Windows.Controls.CheckBox]::new(); $ctl.Content = $Spec.Label; $ctl.IsChecked = [bool]$Default
            $ctl.Margin = [System.Windows.Thickness]::new(0, 0, 0, 0)
            [void]$panel.Children.Add($ctl)
        }
        'choice' {
            $ctl = [System.Windows.Controls.ComboBox]::new()
            foreach ($c in $Spec.Choices) { [void]$ctl.Items.Add($c) }
            $ctl.SelectedItem = [string]$Default
            if ($null -eq $ctl.SelectedItem -and $ctl.Items.Count) { $ctl.SelectedIndex = 0 }
            [void]$panel.Children.Add($ctl)
        }
        'lot' {
            $ctl = [System.Windows.Controls.ComboBox]::new(); $ctl.IsEditable = $true; $ctl.Text = [string]$Default
            [void]$panel.Children.Add($ctl)
        }
        'file' {
            $g = [System.Windows.Controls.Grid]::new()
            $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(1, 'Star')
            $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::Auto
            $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
            $ctl = [System.Windows.Controls.TextBox]::new(); $ctl.Text = [string]$Default
            $btn = [Wpf.Ui.Controls.Button]::new(); $btn.Content = '...'; $btn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0); $btn.Tag = $ctl
            [System.Windows.Automation.AutomationProperties]::SetName($btn, "Browse for $($Spec.Label)")
            [System.Windows.Controls.Grid]::SetColumn($btn, 1)
            Add-TtgHandler $btn 'Click' { param($s, $e) $p = Select-TtgFile -Title 'Choose a CSV file' -Filter 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'; if ($p) { $s.Tag.Text = $p } }
            [void]$g.Children.Add($ctl); [void]$g.Children.Add($btn)
            [void]$panel.Children.Add($g)
        }
        default {
            $ctl = [System.Windows.Controls.TextBox]::new(); $ctl.Text = [string]$Default
            [void]$panel.Children.Add($ctl)
        }
    }
    [System.Windows.Automation.AutomationProperties]::SetName($ctl, [string]$Spec.Label)
    if ($Spec.Hint -and $type -ne 'check') {
        $h = [System.Windows.Controls.TextBlock]::new(); $h.Text = $Spec.Hint; $h.FontSize = 11; $h.TextWrapping = 'Wrap'
        Set-TtgRef ($h) Foreground 'TextFillColorTertiaryBrush'; $h.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        [void]$panel.Children.Add($h)
    }
    return @{ Panel = $panel; Control = $ctl; Type = $type }
}

function Get-TtgFieldValue {
    param($Field)
    $c = $Field.Control
    switch ($Field.Type) {
        'check' { return [bool]$c.IsChecked }
        'choice' { return [string]$c.SelectedItem }
        'int' {
            $t = $c.Text.Trim()
            if ($t -eq '') { return $null }
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n)) { throw "$($Field.Spec.Label): '$t' is not a number." }
            return $n
        }
        default { return $c.Text.Trim() }
    }
}

function Add-TtgTile {
    # A KPI card of the Home page (same card as the run pages), with its status pill.
    param($Panel, [string]$Label, [string]$Value)
    $level = 'Ok'; $pill = 'OK'
    switch ($Label) {
        'Users' { $pill = 'Inventoried' } 'Conversations' { $pill = 'Inventoried' } 'Exported messages' { $pill = 'Exported' }
        'Files waiting' { if ($Value -ne '0') { $level = 'Warn'; $pill = 'Run Files' } }
        'Store size' { $level = ''; $pill = '' }
    }
    Add-TtgKpi $Panel $Label $Value $level $pill
}


function Show-TtgExplorer {
    $T = $script:Ttg
    if ($T.Explorer.Version -ne [int]$T.StoreVersion -or $T.Explorer.Root -ne $T.StoreRoot) {
        $T.Explorer.Items = Read-TtgExplorerItems
        $T.Explorer.Version = [int]$T.StoreVersion
        $T.Explorer.Root = $T.StoreRoot
    }
    Update-TtgExplorerList
    Initialize-TtgWebView
    $root = $T.Pages.Explorer.Root
    if (@($T.Explorer.Items).Count -eq 0) { Set-TtgExplorerMessage -Text $(if (Test-TtgStoreExists) { 'The store holds no user or conversation yet. Run Inventory and Export.' } else { "No store at $($T.StoreRoot) yet. Run Inventory and Export first." }) -Icon 'Database24' }
}

function Open-TtgArchiveFor {
    # Generates the archive of a user or a conversation (Export-TmtArchive, folder mode, in a temporary folder) and shows it.
    param([Parameter(Mandatory)]$Entry)
    $T = $script:Ttg
    $x = $T.Explorer
    if ($x.Busy) { return }
    $x.Busy = $true
    $x.Archives = [int]$x.Archives + 1
    $out = Join-Path $T.JobsDir ('archive-{0}-{1}' -f $PID, $x.Archives)
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue }
    $root = $T.Pages.Explorer.Root
    $root.FindName('ExplorerTitle').Text = "$($Entry.Title) - building the preview..."
    Set-TtgExplorerMessage -Text 'Building the preview from the store...' -Icon 'ArrowSync24'
    Set-TtgStatus "Explorer: building the archive of $($Entry.Title)"
    $users = if ($Entry.Kind -eq 'User') { @($Entry.Key) } else { @() }
    $conv = if ($Entry.Kind -eq 'Chat') { @($Entry.Key) } else { @() }
    $viewer = if ($Entry.Kind -eq 'User') { $Entry.Key } else { '' }
    [void](Start-TtgBackground -ScriptText $script:TtgArchiveScript -ArgumentList @($T.PackageRoot, $T.Demo, $T.Support, $T.StoreRoot, $out, $users, $conv, $viewer, "Teams Transfer - $($Entry.Title)") -Tag $Entry -OnDone {
            param($o, $errs, $entry)
            $t = Get-TtgState
            $t.Explorer.Busy = $false
            $r = $o | Where-Object { $_ -and $_.PSObject.Properties['Index'] } | Select-Object -Last 1
            $root = $t.Pages.Explorer.Root
            if ($null -eq $r -or -not (Test-Path -LiteralPath $r.Index)) {
                $root.FindName('ExplorerTitle').Text = $entry.Title
                Set-TtgExplorerMessage -Text ("The preview could not be built: " + $(if ($errs.Count) { $errs[0] } else { 'no archive was written.' })) -Icon 'ErrorCircle24'
                return
            }
            $t.Explorer.ArchiveRoot = [string]$r.Path
            $t.Explorer.ArchiveIndex = [string]$r.Index
            $t.Explorer.LastInfo = $r
            $root.FindName('ExplorerTitle').Text = "$($entry.Title) - $(Format-TmtNumber $r.Messages) message(s)"
            $root.FindName('ExplorerOpenFolder').IsEnabled = $true; $root.FindName('ExplorerOpenBrowser').IsEnabled = $true
            Show-TtgArchiveUrl -Index ([string]$r.Index)
        })
}

function New-TtgExplorerPage {
    param([Parameter(Mandatory)]$Entry)
    $T = $script:Ttg
    $root = Read-TtgXaml 'Page.Explorer.xaml'
    $T.Pages[$Entry.Key] = @{ Key = $Entry.Key; Title = $Entry.Title; Root = $root; OnShow = { Show-TtgExplorer } }
    $T.Explorer = @{ Items = @(); Version = -1; Mode = 'Users'; Pending = $null; Archives = 0; Navigations = [Collections.Generic.List[string]]::new(); Blocked = [Collections.Generic.List[string]]::new() }
    Add-TtgHandler ($root.FindName('ExplorerSearch')) 'TextChanged' { Update-TtgExplorerList }
    Add-TtgHandler ($root.FindName('ModeUsers')) 'Click' { (Get-TtgState).Explorer.Mode = 'Users'; Update-TtgExplorerList }
    Add-TtgHandler ($root.FindName('ModeChats')) 'Click' { (Get-TtgState).Explorer.Mode = 'Chats'; Update-TtgExplorerList }
    Add-TtgHandler ($root.FindName('ExplorerList')) 'SelectionChanged' {
        param($s, $e)
        $item = $s.SelectedItem
        if ($null -ne $item -and $item.Tag) { Open-TtgArchiveFor -Entry $item.Tag }
    }
    Add-TtgHandler ($root.FindName('ExplorerOpenFolder')) 'Click' { Open-TtgPath ((Get-TtgState).Explorer.ArchiveRoot) }
    Add-TtgHandler ($root.FindName('ExplorerOpenBrowser')) 'Click' {
        $t = Get-TtgState
        if ($t.Explorer.ArchiveIndex -and (Confirm-TtgAction -Title 'Open in the default browser' -Message "Open the offline archive in your default browser?`n$($t.Explorer.ArchiveIndex)")) { Open-TtgPath $t.Explorer.ArchiveIndex }
    }
}



#region Tasks and forms ---------------------------------------------------------------------------

function Get-TtgTaskCatalog {
    @(
        @{ Key = 'Estimate'; Name = 'Estimate'; Code = 'ASSESS'; Icon = 'Gauge24'; Sentence = 'Sample the source tenant and estimate the volume, the duration and the waves. Read only.' }
        @{ Key = 'Export'; Name = 'Export conversations'; Code = 'EXPORT'; Icon = 'ArrowDownload24'; Sentence = 'Copy chats, channels and their files from the source tenant into the local store.' }
        @{ Key = 'Browse'; Name = 'Browse the archive'; Code = 'ARCHIVE'; Icon = 'Chat24'; Sentence = 'Read the exported conversations as in Teams, offline, before importing anything.' }
        @{ Key = 'Import'; Name = 'Import a lot'; Code = 'IMPORT'; Icon = 'ArrowUpload24'; Sentence = 'Plan, create the ghost accounts, copy the files and import a lot into the target tenant.' }
        @{ Key = 'Verify'; Name = 'Verify a lot'; Code = 'VERIFY'; Icon = 'CheckmarkCircle24'; Sentence = 'Compare the target tenant with the source and write the reports.' }
    )
}

function Get-TtgTaskInfo { param([string]$Key) Get-TtgTaskCatalog | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }

function Get-TtgTaskDefinition {
    # The scope choices ("On what?") and the options of each task. Field specs: Name = the CLI parameter.
    param([Parameter(Mandatory)][string]$Task)
    $f = { param($n, $l, $t, $d, $h, $c) @{ Name = $n; Label = $l; Type = $t; Default = $d; Hint = $h; Choices = $c } }
    $T = $script:Ttg
    $demo = if ($T.Demo) { $T.DemoDefaults } else { @{ Plan = @{}; Ghosts = @{} } }
    $dm = [string]$demo.Plan.DomainMap; $sa = [string]$demo.Plan.ServiceAccount; $gd = [string]$demo.Plan.GhostDomain
    switch ($Task) {
        'Estimate' {
            @{ ScopeTitle = 'How many to sample?'
               Scopes = @(@{ Key = 'sample'; Label = 'Sample'; Fields = @((& $f 'SampleUsers' 'Users to sample' 'int' $(if ($T.Demo) { 4 } else { 20 }) 'Default 20'), (& $f 'SampleTeams' 'Teams to sample' 'int' 0 '0 = none (channel messages are then not counted)')) })
               More = @((& $f 'HistoryMonths' 'History to extrapolate (months)' 'int' 60 'Default 60')) }
        }
        'Export' {
            @{ ScopeTitle = 'On what?'
               Scopes = @(
                @{ Key = 'user'; Label = 'Single user (test)'; Fields = @((& $f 'Users' 'User' 'text' '' 'UPN or id, comma separated')) }
                @{ Key = 'csv'; Label = 'Users from a CSV'; Fields = @((& $f 'Users' 'CSV file' 'file' '' 'Column Id, Identity or UserPrincipalName')) }
                @{ Key = 'team'; Label = 'A team'; Fields = @((& $f 'Teams' 'Team' 'text' '' 'Exact name or id')) }
                @{ Key = 'lot'; Label = 'Existing lot'; Fields = @((& $f 'Lot' 'Lot' 'lot' '' 'Exports the users and teams of this lot')) }
                @{ Key = 'all'; Label = 'Everyone in the store'; Fields = @() })
               More = @((& $f 'Window' 'Period' 'text' '' '24m, 60m or 2024-01-01..2025-12-31; empty = all')
                        (& $f 'IncludeChannels' 'Include the channels' 'check' $true ''), (& $f 'IncludeFiles' 'Download the files too' 'check' $true ''), (& $f 'Full' 'Read everything again' 'check' $false '')) }
        }
        'Browse' {
            @{ ScopeTitle = 'What to open?'; Scopes = @(@{ Key = 'view'; Label = 'The store'; Fields = @() }); More = @() }
        }
        'Import' {
            @{ ScopeTitle = 'On what?'
               Scopes = @(
                @{ Key = 'user'; Label = 'Single user (test)'; Fields = @((& $f 'Users' 'User' 'text' '' 'UPN or id, comma separated')) }
                @{ Key = 'csv'; Label = 'Users from a CSV'; Fields = @((& $f 'Users' 'CSV file' 'file' '' 'Column Id, Identity or UserPrincipalName')) }
                @{ Key = 'team'; Label = 'A team'; Fields = @((& $f 'Teams' 'Team' 'text' '' 'Exact name or id')) }
                @{ Key = 'lot'; Label = 'Existing lot'; Fields = @((& $f 'Lot' 'Lot' 'lot' '' 'A lot of the store')) })
               More = @((& $f 'DomainMap' 'Domain rule' 'text' $dm 'source.com=target.com')
                        (& $f 'ServiceAccount' 'Service account' 'text' $sa 'UPN: fallback author, owner of created teams')
                        (& $f 'GhostDomain' 'Ghost domain' 'text' $gd 'Domain of the ghost accounts')
                        (& $f 'IdentityMap' 'User mapping (CSV)' 'file' '' 'SourceUpn, TargetUpn ...'), (& $f 'TeamMap' 'Team mapping (CSV)' 'file' '' 'SourceTeam, TargetTeam ...')
                        (& $f 'Window' 'Window (new lot)' 'text' '' '24m, 36m, 48m or 60m'), (& $f 'Slices' 'Waves' 'text' '1' '1 = last 24 months; 2, 3, 4 = older')
                        (& $f 'Scenario' 'Scenario' 'choice' 'TenantToTenant' 'A, B (restore) or C (archive)' @('TenantToTenant', 'SameTenantRestore', 'DepartedArchive'))
                        (& $f 'DeletedAuthors' 'Deleted authors' 'choice' 'Auto' 'Ghost or service account' @('Auto', 'Ghost', 'ServiceAccount'))
                        (& $f 'CreateTrackingGroup' 'Create the ghost tracking group' 'check' ([bool]$T.Demo) '')) }
        }
        'Verify' {
            @{ ScopeTitle = 'Which lot?'
               Scopes = @(@{ Key = 'lot'; Label = 'Existing lot'; Fields = @((& $f 'Lot' 'Lot (imported)' 'lot' '' 'Required')) })
               More = @((& $f 'SampleSize' 'Messages compared per conversation' 'int' 10 '0 to 1000'), (& $f 'Slices' 'Waves' 'text' '' 'Empty = all')
                        (& $f 'ServiceAccount' 'Service account' 'text' $sa ''), (& $f 'StrictCounts' 'Strict counts' 'check' $false '')) }
        }
    }
}

function Initialize-TtgTaskForms {
    # Every field of every task is built once; the scope choice only decides which ones are shown.
    $T = $script:Ttg
    $T.Form = @{}; $T.TaskDef = @{}; $T.Scope = @{}
    foreach ($task in (Get-TtgTaskCatalog)) {
        $def = Get-TtgTaskDefinition -Task $task.Key
        $T.TaskDef[$task.Key] = $def
        $form = @{ Scopes = @{}; More = [ordered]@{} }
        foreach ($s in $def.Scopes) {
            $list = [ordered]@{}
            foreach ($fs in $s.Fields) { $fld = New-TtgField -Spec $fs -Default $fs.Default; $fld.Spec = $fs; $fld.Control.Tag = 'form'; $list[$fs.Name] = $fld; Add-TtgFieldHandler $fld }
            $form.Scopes[$s.Key] = $list
        }
        foreach ($fs in $def.More) { $fld = New-TtgField -Spec $fs -Default $fs.Default; $fld.Spec = $fs; $fld.Control.Tag = 'form'; $form.More[$fs.Name] = $fld; Add-TtgFieldHandler $fld }
        $T.Form[$task.Key] = $form
        $T.Scope[$task.Key] = $def.Scopes[0].Key
    }
}

function Add-TtgFieldHandler {
    param($Field)
    $c = $Field.Control
    switch ($Field.Type) {
        'check' { Add-TtgHandler $c 'Click' { Update-TtgTaskText } }
        'choice' { Add-TtgHandler $c 'SelectionChanged' { Update-TtgTaskText } }
        'lot' { Add-TtgHandler $c 'SelectionChanged' { Update-TtgTaskText }; Add-TtgHandler $c 'LostKeyboardFocus' { Update-TtgTaskText } }
        default { Add-TtgHandler $c 'LostKeyboardFocus' { Update-TtgTaskText } }
    }
}

function Get-TtgTaskParams {
    # The form of the chosen task -> CLI parameters. Returns @{ Params; Error; Summary }.
    $T = $script:Ttg
    $task = $T.Task; $scope = $T.Scope[$task]
    $form = $T.Form[$task]
    $params = @{}
    $err = $null
    try {
        $all = @($form.Scopes[$scope].Values) + @($form.More.Values)
        foreach ($f in $all) {
            $v = Get-TtgFieldValue $f
            if ($f.Type -eq 'check') { if ($v) { $params[$f.Spec.Name] = $true }; continue }
            if ($null -eq $v -or "$v" -eq '') { continue }
            $params[$f.Spec.Name] = $v
        }
        if ($scope -eq 'all') { $params.AllStoreUsers = $true }
        $required = switch ($scope) { 'user' { 'Users' } 'csv' { 'Users' } 'team' { 'Teams' } 'lot' { 'Lot' } default { $null } }
        if ($required -and -not $params[$required]) { $err = switch ($required) { 'Users' { $(if ($scope -eq 'csv') { 'Choose the CSV file.' } else { 'Type the user to use.' }) } 'Teams' { 'Type the team to use.' } default { 'Choose a lot.' } } }
        if ($scope -eq 'csv' -and -not $err -and -not (Test-Path -LiteralPath ([string]$params.Users) -PathType Leaf)) { $err = "CSV file not found: $($params.Users)" }
    } catch { $err = $_.Exception.Message }
    $summary = switch ($scope) { 'user' { "user $(if ($params.Users) { $params.Users } else { '(to type)' })" } 'csv' { "users of $(Split-Path -Leaf ([string]$params.Users))" } 'team' { "team $($params.Teams)" } 'lot' { "lot $($params.Lot)" } 'all' { 'everyone in the store' } 'sample' { "sample of $($params.SampleUsers) user(s)" } default { 'the store' } }
    return @{ Params = $params; Error = $err; Summary = $summary }
}

function Get-TtgWillHappen {
    $T = $script:Ttg
    $p = Get-TtgTaskParams
    $store = $T.StoreRoot
    $src = [string]$T.Config.Source.TenantId; $tgt = [string]$T.Config.Target.TenantId
    switch ($T.Task) {
        'Estimate' { "Reads $(if ($p.Params.SampleUsers) { $p.Params.SampleUsers } else { 20 }) sampled user(s) of the SOURCE tenant $src (read only) and writes a report. Nothing is written to any tenant." }
        'Export' { "Reads the chats$(if ($p.Params.IncludeChannels) { ', channels' }) of $($p.Summary) from the SOURCE tenant $src (read only) into the local store $store$(if ($p.Params.IncludeFiles) { ', with their files' }). Nothing is written to any tenant." }
        'Browse' { "Opens the exported conversations of the store $store in a Teams-like viewer. Offline and read only: no tenant is contacted." }
        'Import' { "Plans the import of $($p.Summary), then, only after your preview and your explicit Apply, creates the ghost accounts, copies the files and imports the messages into the TARGET tenant $tgt. Until then nothing is written to any tenant." }
        'Verify' { "Compares $($p.Summary) on the TARGET tenant $tgt with the store (read only) and writes the verification reports." }
    }
}

function Update-TtgTaskText {
    $T = $script:Ttg
    if ($null -eq $T.Pages.Task) { return }
    $T.Pages.Task.Root.FindName('WillHappenText').Text = Get-TtgShown (Get-TtgWillHappen)
    Update-TtgContext
    if ($T.Step -eq 2) { Update-TtgBottomBar }
}

function Set-TtgTask {
    param([Parameter(Mandatory)][string]$Key)
    $T = $script:Ttg
    $T.Task = $Key
    $root = $T.Pages.Task.Root
    foreach ($c in $root.FindName('TaskCards').Children) {
        $sel = ($c.Tag -eq $Key)
        $c.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $(if ($sel) { 'TmtBrand' } else { 'CardStrokeColorDefaultBrush' }))
        $c.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($sel) { 'TmtAccentSoft' } else { 'CardBackgroundFillColorDefaultBrush' }))
        $c.BorderThickness = [System.Windows.Thickness]::new($(if ($sel) { 2 } else { 1 }))
    }
    $def = $T.TaskDef[$Key]
    $root.FindName('ScopeTitle').Text = $def.ScopeTitle
    $choices = $root.FindName('ScopeChoices'); $choices.Children.Clear()
    $single = ($def.Scopes.Count -le 1)
    foreach ($s in $def.Scopes) {
        if ($single) { break }
        $rb = [System.Windows.Controls.RadioButton]::new(); $rb.Content = $s.Label; $rb.GroupName = 'Scope'; $rb.Tag = $s.Key; $rb.Padding = [System.Windows.Thickness]::new(14, 5, 14, 5); $rb.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $rb.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'TtSeg')
        $rb.IsChecked = ($s.Key -eq $T.Scope[$Key])
        [System.Windows.Automation.AutomationProperties]::SetName($rb, "Scope: $($s.Label)")
        Add-TtgHandler $rb 'Click' { param($sn, $e) Set-TtgScope -Key ([string]$sn.Tag) }
        [void]$choices.Children.Add($rb)
    }
    $choices.Visibility = if ($single) { 'Collapsed' } else { 'Visible' }
    Set-TtgScope -Key $T.Scope[$Key] -NoChoices
    $more = $root.FindName('MoreFields'); $more.Children.Clear()
    foreach ($f in $T.Form[$Key].More.Values) { [void]$more.Children.Add($f.Panel) }
    $root.FindName('MoreExpander').Visibility = if ($T.Form[$Key].More.Count) { 'Visible' } else { 'Collapsed' }
    # A task without any field to fill (Browse: the viewer picks the user or the conversation itself) shows no empty "On what?" box.
    $hasFields = (@($def.Scopes | Where-Object { @($_.Fields).Count -gt 0 }).Count -gt 0) -or ($def.More.Count -gt 0)
    $root.FindName('ScopeCard').Visibility = if ($hasFields) { 'Visible' } else { 'Collapsed' }
    $T.Preview = $null
    Update-TtgTaskText
}

function Set-TtgScope {
    param([Parameter(Mandatory)][string]$Key, [switch]$NoChoices)
    $T = $script:Ttg
    $T.Scope[$T.Task] = $Key
    $root = $T.Pages.Task.Root
    $hostPanel = $root.FindName('ScopeFields'); $hostPanel.Children.Clear()
    foreach ($f in $T.Form[$T.Task].Scopes[$Key].Values) { [void]$hostPanel.Children.Add($f.Panel) }
    if (-not $NoChoices) { foreach ($rb in $root.FindName('ScopeChoices').Children) { $rb.IsChecked = ($rb.Tag -eq $Key) } }
    foreach ($f in $T.Form[$T.Task].Scopes[$Key].Values) { if ($f.Type -eq 'lot') { Update-TtgLotItems $f.Control } }
    $T.Preview = $null
    Update-TtgTaskText
}

function Update-TtgLotItems {
    param($Combo)
    $text = $Combo.Text
    $snap = Get-TtgStoreSnapshot
    $script:Ttg.Snapshot = $snap
    $Combo.Items.Clear()
    if ($snap) { foreach ($l in $snap.Lots) { [void]$Combo.Items.Add($l.Name) } }
    if (-not $text -and $script:Ttg.LastLot -and $script:Ttg.Task -in 'Import', 'Verify') { $text = $script:Ttg.LastLot }
    $Combo.Text = $text
}

function New-TtgTaskPanel {
    $T = $script:Ttg
    $root = Read-TtgXaml 'Step.Task.xaml'
    $T.Pages.Task = @{ Root = $root }
    $cards = $root.FindName('TaskCards')
    foreach ($t in (Get-TtgTaskCatalog)) {
        $b = [System.Windows.Controls.Border]::new(); $b.Tag = $t.Key; $b.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $b.Padding = [System.Windows.Thickness]::new(16, 14, 16, 14)
        $b.CornerRadius = [System.Windows.CornerRadius]::new(10); $b.BorderThickness = [System.Windows.Thickness]::new(1); $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'CardBackgroundFillColorDefaultBrush')
        $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'CardStrokeColorDefaultBrush')
        $sp = [System.Windows.Controls.StackPanel]::new()
        $tile = [System.Windows.Controls.Border]::new(); $tile.Width = 40; $tile.Height = 40; $tile.CornerRadius = [System.Windows.CornerRadius]::new(9); $tile.HorizontalAlignment = 'Left'
        $tile.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'TmtAccentSoft')
        $ic = New-TtgSymbolIcon $t.Icon; $ic.FontSize = 22; $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'; $ic.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TmtBrandText'); $tile.Child = $ic
        $n = [System.Windows.Controls.TextBlock]::new(); $n.Text = $t.Name; $n.FontSize = 16; $n.FontWeight = [System.Windows.FontWeights]::SemiBold; $n.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0); $n.TextWrapping = 'Wrap'; Set-TtgRef $n Foreground 'TextFillColorPrimaryBrush'
        $cd = [System.Windows.Controls.TextBlock]::new(); $cd.Text = $t.Code; $cd.FontSize = 11; $cd.FontWeight = [System.Windows.FontWeights]::SemiBold; Set-TtgRef $cd Foreground 'TmtBrandText'
        $s = [System.Windows.Controls.TextBlock]::new(); $s.Text = $t.Sentence; $s.FontSize = 12; $s.TextWrapping = 'Wrap'; $s.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0); Set-TtgRef $s Foreground 'TextFillColorSecondaryBrush'
        foreach ($e in $tile, $n, $cd, $s) { [void]$sp.Children.Add($e) }
        $b.Child = $sp
        [System.Windows.Automation.AutomationProperties]::SetName($b, "Task: $($t.Name)")
        Add-TtgHandler $b 'MouseLeftButtonUp' { param($sn, $e) Set-TtgTask -Key ([string]$sn.Tag) }
        [void]$cards.Children.Add($b)
    }
}
#endregion

#region Setup ---------------------------------------------------------------------------------------

function New-TtgSetupPanel {
    $T = $script:Ttg
    $root = Read-TtgXaml 'Step.Setup.xaml'
    $T.Pages.Home = @{ Root = $root }
    Add-TtgHandler ($root.FindName('StoreBrowse')) 'Click' { $t = Get-TtgState; $p = Select-TtgFolder -Description 'Choose the store folder' -Initial $t.StoreRoot; if ($p) { Set-TtgStoreRoot $p; Update-TtgSetup } }
    Add-TtgHandler ($root.FindName('StoreRefresh')) 'Click' {
        $t = Get-TtgState; $text = $t.Pages.Home.Root.FindName('StoreCombo').Text
        if ($text -and $text -ne $t.StoreRoot) { Set-TtgStoreRoot $text }
        Update-TtgSetup
    }
    Add-TtgHandler ($root.FindName('SourceCheck')) 'Click' { Start-TtgRoleCheck -Side 'Source' }
    Add-TtgHandler ($root.FindName('TargetCheck')) 'Click' { Start-TtgRoleCheck -Side 'Target' }
    Add-TtgHandler ($root.FindName('SetConfigBrowse')) 'Click' { $p = Select-TtgFile -Title 'Choose the configuration file' -Filter 'Configuration (*.psd1)|*.psd1|All files (*.*)|*.*'; if ($p) { (Get-TtgState).Pages.Home.Root.FindName('SetConfigPath').Text = $p } }
    Add-TtgHandler ($root.FindName('SetConfigReload')) 'Click' {
        $t = Get-TtgState
        $p = $t.Pages.Home.Root.FindName('SetConfigPath').Text.Trim()
        $t.ConfigPath = $p; if (-not $t.Demo) { $t.Settings.ConfigPath = $p; Save-TtgSettings }
        Import-TtgConfiguration; Update-TtgSetup
    }
    Add-TtgHandler ($root.FindName('SetLocalOpen')) 'Click' { Open-TtgPath ([IO.Path]::ChangeExtension((Get-TtgConfigFile), '.local.psd1')) }
    Add-TtgHandler ($root.FindName('SetLogOpen')) 'Click' { Open-TtgPath ((Get-TtgState).LogFolder) }
    Add-TtgHandler ($root.FindName('SetOutOpen')) 'Click' { Open-TtgPath (Join-Path (Get-TtgState).OutRoot 'reports') }
    foreach ($side in 'Source', 'Target') { Show-TtgRoles -Side $side }
}

function Get-TtgConfigFile {
    $T = $script:Ttg
    if ($T.ConfigPath) { return $T.ConfigPath }
    return (Join-Path $T.PackageRoot 'config\TeamsTransfer.config.psd1')
}

function Update-TtgSetup {
    $T = $script:Ttg
    $root = $T.Pages.Home.Root
    $combo = $root.FindName('StoreCombo'); $combo.Items.Clear()
    foreach ($r in @($T.StoreRoot) + @($T.Settings.RecentStores)) { $rs = Get-TtgShown $r; if ($rs -and $rs -notin @($combo.Items)) { [void]$combo.Items.Add($rs) } }
    $combo.Text = Get-TtgShown $T.StoreRoot
    $combo.IsEnabled = -not $T.Demo; $root.FindName('StoreBrowse').IsEnabled = -not $T.Demo
    $root.FindName('SetConfigPath').Text = Get-TtgShown (Get-TtgConfigFile)
    $tiles = $root.FindName('StatTiles'); $tiles.Children.Clear()
    $info = $root.FindName('StoreInfo')
    $snap = Get-TtgStoreSnapshot
    $T.Snapshot = $snap
    if ($null -eq $snap) { $info.Text = Get-TtgShown $(if ($T.StoreReadError) { "The store cannot be read: $($T.StoreReadError)" } else { "No store at $($T.StoreRoot) yet: the export creates it." }) }
    else {
        $T.StoreReadError = $null
        $info.Text = "Store id $($snap.StoreId), inventory pass: $(if ($snap.InventoryState) { $snap.InventoryState } else { 'never run' })"
        Add-TtgTile $tiles 'Users' (Format-TmtNumber $snap.Users); Add-TtgTile $tiles 'Conversations' (Format-TmtNumber $snap.InventoriedConversations)
        Add-TtgTile $tiles 'Exported messages' (Format-TmtNumber $snap.Messages); Add-TtgTile $tiles 'Store size' (Format-TmtBytes $snap.SegmentBytes)
        Add-TtgTile $tiles 'Files waiting' $(if ($snap.PendingFiles -gt 100000) { '100,000+' } else { Format-TmtNumber $snap.PendingFiles })
    }
    Update-TtgTenant -Side 'Source'; Update-TtgTenant -Side 'Target'
    $notice = $root.FindName('HomeNotice')
    if ($T.ConfigError) { $notice.Severity = 'Error'; $notice.Title = 'Configuration'; $notice.Message = $T.ConfigError; $notice.IsOpen = $true }
    elseif ($T.Demo) { $notice.Severity = 'Warning'; $notice.Title = 'Demo mode'; $notice.Message = 'Synthetic tenants (Contoso to Northwind) and a temporary store: nothing leaves this machine.'; $notice.IsOpen = $true }
    else { $notice.IsOpen = $false }
}
#endregion

#region Checks (step 3) ----------------------------------------------------------------------------

function Get-TtgTaskRoles {
    # Role -> modes, restricted to the modes of the task; plus the side.
    param([string]$Task)
    $modes = switch ($Task) { 'Estimate' { @('Assess') } 'Export' { @('Inventory', 'Export', 'Files') } 'Import' { @('Plan', 'Ghosts', 'CopyFiles', 'Import') } 'Verify' { @('Verify') } default { @() } }
    $side = switch ($Task) { 'Estimate' { 'Source' } 'Export' { 'Source' } 'Import' { 'Target' } 'Verify' { 'Target' } default { $null } }
    if (-not $side) { return @{ Side = $null; Roles = @() } }
    $needs = Get-TtgRoleNeeds -Side $side
    $roles = @($needs.Keys | Where-Object { $txt = $needs[$_]; @($modes | Where-Object { $txt -match ('\b' + [regex]::Escape($_) + '\b') }).Count -gt 0 })
    return @{ Side = $side; Roles = $roles }
}

function Get-TtgChecks {
    # Checks for step 3: what must be true before the task. Level Ok / Warn / Fail, Pill text, Fix = the action when it is not OK.
    $T = $script:Ttg
    $list = [Collections.Generic.List[object]]::new()
    $add = { param($Text, $Level, $Pill, $Fix) $list.Add(@{ Text = $Text; Level = $Level; Pill = $Pill; Fix = $Fix }) }
    $task = $T.Task
    $p = Get-TtgTaskParams
    if ($p.Error) { & $add $p.Error 'Fail' 'Blocked' 'Go back and complete the scope.' }
    if ($task -in 'Browse', 'Verify', 'Import') {
        if (Test-TtgStoreExists) { & $add 'The store is open' 'Ok' 'OK' } else { & $add "No store at $($T.StoreRoot)" 'Fail' 'Blocked' 'Run Export first, or choose the store on Setup.' }
    } elseif ($task -eq 'Export') { & $add "The store $($T.StoreRoot) $(if (Test-TtgStoreExists) { 'exists and is resumed' } else { 'will be created' })" 'Ok' 'OK' }
    $snap = $T.Snapshot
    if ($task -eq 'Browse') { if ($snap -and $snap.Messages) { & $add "$(Format-TmtNumber $snap.Messages) exported message(s) to browse" 'Ok' 'OK' } else { & $add 'Nothing exported yet' 'Fail' 'Blocked' 'Run Export first.' } }
    if ($task -eq 'Verify') {
        $lot = if ($p.Params.Lot -and $snap) { @($snap.Lots | Where-Object { $_.Name -eq $p.Params.Lot }) | Select-Object -First 1 } else { $null }
        if ($lot) { if ([string]$lot.State -in 'Importing', 'Completing', 'Verified', 'Closed') { & $add "Lot '$($lot.Name)' is $($lot.State)" 'Ok' 'OK' } else { & $add "Lot '$($lot.Name)' is $($lot.State): not imported yet" 'Warn' 'Run Import' 'Import the lot first.' } }
        elseif ($p.Params.Lot) { & $add "Lot '$($p.Params.Lot)' is not in the store" 'Fail' 'Blocked' 'Choose a lot of the store.' }
    }
    if ($task -eq 'Import') {
        if ($snap -and $snap.Messages) { & $add "$(Format-TmtNumber $snap.Messages) exported message(s) to plan" 'Ok' 'OK' } else { & $add 'Nothing exported yet' 'Fail' 'Blocked' 'Run Export first.' }
        if ($p.Params.Lot -and $snap) {
            $lot = @($snap.Lots | Where-Object { $_.Name -eq $p.Params.Lot }) | Select-Object -First 1
            if ($lot) { & $add "Lot '$($lot.Name)' is $($lot.State)" 'Ok' 'OK' } else { & $add "Lot '$($p.Params.Lot)' is not in the store" 'Fail' 'Blocked' 'Choose a lot of the store.' }
        }
    }
    $r = Get-TtgTaskRoles -Task $task
    if ($r.Side) {
        $check = $T.Checks[$r.Side]
        if ($null -eq $check) { & $add "$($r.Side) tenant: permissions not checked yet" 'Warn' 'Check on Setup' 'Use Check permissions on Setup.' }
        elseif ($check.Error) { & $add "$($r.Side) tenant: $($check.Error)" 'Fail' 'Blocked' 'Fix the sign-in (Setup).' }
        else {
            $missing = @($r.Roles | Where-Object { $check.Missing -contains $_ })
            if ($missing.Count) { & $add "$($r.Side) tenant: permission(s) missing: $($missing -join ', ')" 'Fail' 'Blocked' 'Grant them with administrator consent.' } else { & $add "$($r.Side) tenant: permissions for this task" 'Ok' 'OK' }
        }
    }
    if ($task -eq 'Import' -and $T.Preview) {
        $pv = $T.Preview
        if ($pv.Blocked) { & $add 'The plan has blockers' 'Fail' 'Blocked' 'See "To fix first".' } else { & $add 'The plan has no blocker' 'Ok' 'OK' }
        if ($pv.Ghosts -gt 0) { & $add "$($pv.Ghosts) ghost account(s) will be created for deleted authors" 'Warn' 'At Apply' }
        if ($pv.Unresolved -gt 0) { & $add "$($pv.Unresolved) author(s) not mapped" 'Fail' 'Blocked' 'Add them to the user mapping.' }
        if ($pv.Files -gt 0) { & $add "$($pv.Files) file(s) to copy" 'Warn' 'At Apply' }
    }
    return $list.ToArray()
}

function Show-TtgChecks {
    $T = $script:Ttg
    $root = $T.Pages.Verify.Root
    $checks = @(Get-TtgChecks)
    $T.LastChecks = $checks
    $host1 = $root.FindName('ChecksHost'); $host1.Children.Clear()
    $info = Get-TtgTaskInfo $T.Task
    $root.FindName('ChecksTitle').Text = "Checks before $($info.Name.ToLowerInvariant())"
    foreach ($c in $checks) {
        $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
        foreach ($w in 'Auto', 'Star', 'Auto') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq 'Star') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }; $g.ColumnDefinitions.Add($cd) }
        $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 10; $dot.Height = 10; $dot.VerticalAlignment = 'Center'; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
        Set-TtgLight $dot $(switch ($c.Level) { 'Ok' { 'Green' } 'Warn' { 'Amber' } default { 'Red' } })
        $tx = [System.Windows.Controls.TextBlock]::new(); $tx.Text = Get-TtgShown $c.Text; Set-TtgRef $tx Foreground 'TextFillColorPrimaryBrush'; [System.Windows.Controls.Grid]::SetColumn($tx, 1)
        $pb = [System.Windows.Controls.Border]::new(); $pb.CornerRadius = [System.Windows.CornerRadius]::new(9); $pb.Padding = [System.Windows.Thickness]::new(10, 1, 10, 1); [System.Windows.Controls.Grid]::SetColumn($pb, 2)
        $pt = [System.Windows.Controls.TextBlock]::new(); $pt.Text = $c.Pill; $pt.FontSize = 11; $pt.FontWeight = [System.Windows.FontWeights]::SemiBold; $pb.Child = $pt; Set-TtgPill $pb $pt $c.Level
        [void]$g.Children.Add($dot); [void]$g.Children.Add($tx); [void]$g.Children.Add($pb); [void]$host1.Children.Add($g)
    }
    $bh = $root.FindName('BlockersHost'); $bh.Children.Clear()
    $blockers = @($checks | Where-Object { $_.Level -eq 'Fail' })
    $planBlockers = if ($T.Preview) { @($T.Preview.Issues | Where-Object { $_ -like 'BLOCKER:*' }) } else { @() }
    foreach ($b in $blockers) { $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.TextWrapping = 'Wrap'; $t1.Text = Get-TtgShown "$($b.Text)$(if ($b.Fix) { ' -> ' + $b.Fix })"; Set-TtgRef $t1 Foreground 'TextFillColorPrimaryBrush'; [void]$bh.Children.Add($t1) }
    foreach ($b in $planBlockers) { $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.TextWrapping = 'Wrap'; $t1.Text = "$b -> fix it (mapping, service account, ghost domain) and run the preview again."; Set-TtgRef $t1 Foreground 'TextFillColorPrimaryBrush'; [void]$bh.Children.Add($t1) }
    $root.FindName('BlockersCard').Visibility = if ($bh.Children.Count) { 'Visible' } else { 'Collapsed' }
    return $checks
}
#endregion

#region Chains: the steps of a task, run one after the other in background runspaces ---------------

function New-TtgStep {
    param([string]$Id, [string]$Title, [string]$Description, [string]$Mode, [hashtable]$Params = @{}, [bool]$Apply = $false)
    @{ Id = $Id; Title = $Title; Description = $Description; Mode = $Mode; Params = $Params; Apply = $Apply; Status = 'Pending'; Seconds = 0; Progress = 0; Result = $null; Log = [Text.StringBuilder]::new(); Started = $null; Detail = '' }
}

function Get-TtgChainSteps {
    # The steps of the task, all known before the start. Kind: Preview (Import only) or Run.
    param([string]$Kind)
    $T = $script:Ttg
    $p = (Get-TtgTaskParams).Params
    $steps = [Collections.Generic.List[object]]::new()
    $pick = { param([string[]]$n) $h = @{}; foreach ($k in $n) { if ($p.ContainsKey($k)) { $h[$k] = $p[$k] } }; $h }
    switch ($T.Task) {
        'Estimate' { $steps.Add((New-TtgStep 'assess' 'Sample the source tenant' 'Reads a sample of users (and teams), measures the messages and extrapolates volume, duration and waves. Read only.' 'Assess' (& $pick 'SampleUsers', 'SampleTeams', 'HistoryMonths'))) }
        'Export' {
            $steps.Add((New-TtgStep 'inventory' 'Inventory' 'Lists users (deleted and guests included), chats, teams, channels and members into the store. Read only on the tenant.' 'Inventory' (& $pick 'Users', 'Teams')))
            $steps.Add((New-TtgStep 'export' 'Export the messages' 'Reads the messages of the chats and channels into the store. Incremental: a second run reads only what changed.' 'Export' (& $pick 'Users', 'Teams', 'Lot', 'AllStoreUsers', 'Window', 'IncludeChannels', 'IncludeFiles', 'Full')))
            $steps.Add((New-TtgStep 'files' 'Download the files' 'Downloads the file references that the exported messages record as pending.' 'Files' @{}))
        }
        'Import' {
            $plan = & $pick 'Users', 'Teams', 'Lot', 'DomainMap', 'ServiceAccount', 'GhostDomain', 'IdentityMap', 'TeamMap', 'Window', 'Slices', 'Scenario', 'DeletedAuthors'
            $steps.Add((New-TtgStep 'plan' 'Plan the import' 'Builds the dry-run plan: where each conversation goes, how every author is mapped, ghosts, files, blockers. Read only on the target tenant; writes plan.html and the local maps.' 'Plan' $plan))
            $gh = @{}; foreach ($k in 'GhostDomain', 'ServiceAccount', 'CreateTrackingGroup') { if ($p.ContainsKey($k)) { $gh[$k] = $p[$k] } }
            $apply = ($Kind -eq 'Run')
            $steps.Add((New-TtgStep 'ghosts' 'Ghost accounts' $(if ($apply) { 'Creates the ghost accounts of the deleted authors in the target tenant (disabled, unlicensed).' } else { 'Reads the target tenant and lists the ghost accounts that would be created.' }) 'Ghosts' $gh $apply))
            $cf = @{}; if ($p.ContainsKey('ServiceAccount')) { $cf.ServiceAccount = $p.ServiceAccount }
            $steps.Add((New-TtgStep 'copyfiles' 'Copy the files' $(if ($apply) { 'Uploads the exported files into OneDrive and the channel libraries of the target tenant and shares them.' } else { 'Counts the files and bytes per destination. No request is sent.' }) 'CopyFiles' $cf $apply))
            $imp = @{}; if ($p.ContainsKey('ServiceAccount')) { $imp.ServiceAccount = $p.ServiceAccount }; if ($p.ContainsKey('Slices')) { $imp.Slices = $p.Slices }
            $steps.Add((New-TtgStep 'import' 'Import the messages' $(if ($apply) { 'Creates the conversations and posts the messages with the Teams migration API. Resumable: a message is never sent twice.' } else { 'Counts the exact requests per endpoint, keeps the first payloads (redacted) and sends nothing.' }) 'Import' $imp $apply))
            if ($apply) { $steps.Add((New-TtgStep 'copyfiles2' 'Copy the files of the new conversations' 'Files that wait for a channel are copied now that the conversations exist. Nothing to do when every file was copied before.' 'CopyFiles' $cf $true)) }
        }
        'Verify' {
            $vp = & $pick 'Lot', 'SampleSize', 'Slices', 'ServiceAccount', 'StrictCounts'
            $steps.Add((New-TtgStep 'verify' 'Verify the target tenant' 'Compares the target tenant (read only) with the journal and the source, conversation by conversation.' 'Verify' $vp))
            $steps.Add((New-TtgStep 'report' 'Write the reports' 'Rebuilds the HTML reports of the lot from the catalog.' 'Report' (& $pick 'Lot')))
        }
    }
    return $steps.ToArray()
}

function Start-TtgChain {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][object[]]$Steps, [string]$Title)
    $T = $script:Ttg
    $chain = @{ Kind = $Kind; Steps = $Steps; Index = -1; Task = $T.Task; Stopping = $false; Done = $false; Started = [DateTime]::UtcNow; StopFile = Join-Path $T.JobsDir ('stop-' + [guid]::NewGuid().ToString('N') + '.flag')
        Lot = $(if ($T.Preview -and $Kind -eq 'Run') { [string]$T.Preview.Lot } else { [string](Get-TtgTaskParams).Params.Lot }); Title = $Title; Apply = ($Kind -eq 'Run' -and $T.Task -eq 'Import'); Selected = 0; Id = [guid]::NewGuid().ToString('N') }
    # The plan of an applied import is the one the preview made: its step is shown as done.
    if ($Kind -eq 'Run' -and $T.Task -eq 'Import' -and $T.Preview) {
        $first = $chain.Steps[0]
        if ($first.Id -eq 'plan') { $first.Status = 'Done'; $first.Result = $T.Preview.PlanResult; $first.Detail = 'Done in the preview'; $first.Progress = 100; $first.Seconds = $T.Preview.PlanResult.Seconds }
    }
    $T.Chain = $chain
    Set-TtgBusy $true
    Start-TtgNextStep
}

function Start-TtgNextStep {
    $T = $script:Ttg
    $chain = $T.Chain
    $next = -1
    for ($i = 0; $i -lt $chain.Steps.Count; $i++) { if ($chain.Steps[$i].Status -eq 'Pending') { $next = $i; break } }
    if ($next -lt 0 -or $chain.Stopping) { Complete-TtgChain; return }
    $chain.Index = $next
    $s = $chain.Steps[$next]
    if ($chain.Lot -and -not $s.Params.Lot -and $s.Mode -in 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report') { $s.Params.Lot = $chain.Lot }
    $s.Status = 'Running'; $s.Started = [DateTime]::UtcNow
    if ($chain.Kind -eq 'Run') { $chain.Selected = $next }
    $logPath = Join-Path $T.LogFolder ('TeamsTransfer_{0}.log' -f (Get-Date).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture))
    $s.LogState = @{ LogPath = $logPath; LogOffset = $(if (Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0L }) }
    $job = @{ Mode = $s.Mode; Params = $s.Params; Apply = $s.Apply; StopFile = $chain.StopFile; PackageRoot = $T.PackageRoot; StoreRoot = $T.StoreRoot; OutRoot = $T.OutRoot; LogFolder = $T.LogFolder
        ConfigPath = $T.ConfigPath; IntervalSeconds = 1; Demo = $T.Demo; Support = $T.Support; World = $T.World }
    Update-TtgChainUi
    $jobsFile = Join-Path $T.PackageRoot 'TeamsTransfer.Gui.Jobs.ps1'
    [void](Start-TtgBackground -ScriptText 'param($J, $JobsFile) . $JobsFile; Invoke-TtgJobBody -Job $J' -ArgumentList @($job, $jobsFile) -Tag $s `
            -OnTick { param($task) Update-TtgChainTick } -OnDone { param($out, $errs, $step) Complete-TtgChainStep -Step $step -Output $out -Errors $errs })
}

function Update-TtgChainTick {
    $T = $script:Ttg
    $chain = $T.Chain
    if ($null -eq $chain -or $chain.Index -lt 0) { return }
    $s = $chain.Steps[$chain.Index]
    if ($s.Status -ne 'Running') { return }
    $lines = @(Read-TtgLogTail -Job $s.LogState)
    foreach ($l in $lines) {
        [void]$s.Log.AppendLine($l)
        if ($l -match '(\d[\d,]*)/(\d[\d,]*) units') { $d = [double]($Matches[1] -replace ',', ''); $tt = [double]($Matches[2] -replace ',', ''); if ($tt -gt 0) { $s.Progress = [Math]::Min(99, 100 * $d / $tt) } }
        if ($l -match '\[DETAIL\]\s+(.+)$') { $s.Detail = $Matches[1] }
    }
    $s.Seconds = ([DateTime]::UtcNow - $s.Started).TotalSeconds
    Update-TtgChainUi
}

function Complete-TtgChainStep {
    param($Step, $Output, $Errors)
    $T = $script:Ttg
    $chain = $T.Chain
    if ($null -eq $chain) { return }
    foreach ($l in @(Read-TtgLogTail -Job $Step.LogState)) { [void]$Step.Log.AppendLine($l) }
    $result = $Output | Where-Object { $_ -and $_.PSObject.Properties['ExitCode'] } | Select-Object -Last 1
    if ($null -eq $result) { $result = [pscustomobject]@{ Mode = $Step.Mode; ExitCode = 1; Failure = $(if ($Errors.Count) { $Errors[0] } else { 'The step returned no result.' }); Counts = [ordered]@{}; Report = $null; Preview = $false; Lot = ''; Issues = @(); PreviewLines = @(); PreviewTitle = ''; Seconds = 0 } }
    $Step.Result = $result
    $Step.Seconds = ([DateTime]::UtcNow - $Step.Started).TotalSeconds
    $Step.Progress = 100
    $code = [int]$result.ExitCode
    $Step.Status = switch ($code) { 0 { 'Done' } 1 { 'Failed' } 2 { if ($Step.Mode -eq 'CopyFiles' -and $Step.Id -eq 'copyfiles' -and -not $chain.Stopping) { 'Waiting' } else { 'Incomplete' } } 3 { if ($Step.Mode -eq 'Verify') { 'Mismatch' } else { 'Blocked' } } default { 'Failed' } }
    if ($result.Lot) { $chain.Lot = [string]$result.Lot; $T.LastLot = [string]$result.Lot }
    $stopChain = ($code -eq 1) -or ($code -eq 2 -and $Step.Status -ne 'Waiting') -or ($code -eq 3 -and $Step.Mode -ne 'Verify')
    if ($stopChain) { foreach ($x in $chain.Steps) { if ($x.Status -eq 'Pending') { $x.Status = 'NotRun' } } }
    Update-TtgChainUi
    Start-TtgNextStep
}

function Complete-TtgChain {
    $T = $script:Ttg
    $chain = $T.Chain
    $chain.Done = $true; $chain.Finished = [DateTime]::UtcNow
    foreach ($x in $chain.Steps) { if ($x.Status -eq 'Pending') { $x.Status = 'NotRun' } }
    try { [IO.File]::Delete($chain.StopFile) } catch { Write-Verbose "stop file: $($_.Exception.Message)" }
    Set-TtgBusy $false
    $codes = @($chain.Steps | Where-Object { $_.Result -and $_.Status -ne 'Waiting' } | ForEach-Object { [int]$_.Result.ExitCode })
    $chain.Exit = if ($codes -contains 1) { 1 } elseif ($codes -contains 3) { 3 } elseif ($codes -contains 2 -or $chain.Stopping) { 2 } else { 0 }
    $T.StoreVersion = [int]$T.StoreVersion + 1
    if ($chain.Kind -eq 'Preview') { Complete-TtgPreview } else { $T.LastChain = $chain; Update-TtgChainUi }
    Update-TtgBottomBar
    if ($T.OnChainDone) { try { & $T.OnChainDone } catch { Add-TtgError $_ } }
}

function Set-TtgBusy {
    param([bool]$Busy)
    $script:Ttg.Busy = $Busy
}

function Stop-TtgChain {
    $T = $script:Ttg
    $chain = $T.Chain
    if ($null -eq $chain -or $chain.Done) { return }
    $chain.Stopping = $true
    try { Set-Content -LiteralPath $chain.StopFile -Value 'stop' } catch { Add-TtgError $_ }
    Update-TtgBottomBar
}
#endregion

#region Step 3: preview and Apply ------------------------------------------------------------------

function Show-TtgVerifyStep {
    $T = $script:Ttg
    $root = $T.Pages.Verify.Root
    $info = Get-TtgTaskInfo $T.Task
    $writes = ($T.Task -eq 'Import')
    $root.FindName('VerifyTitle').Text = switch ($T.Task) { 'Import' { 'Preview the import before anything is written' } 'Browse' { 'Before the viewer opens' } default { "Before $($info.Name.ToLowerInvariant())" } }
    $root.FindName('VerifyHint').Text = Get-TtgShown (Get-TtgWillHappen)
    $pill = $root.FindName('ModePill'); $pt = $root.FindName('ModePillText')
    if ($writes -and $T.Preview) { $pt.Text = "Preview done $([char]0x00B7) nothing is written yet"; Set-TtgPill $pill $pt 'Brand' }
    elseif ($writes) { $pt.Text = "Preview $([char]0x00B7) nothing is written"; Set-TtgPill $pill $pt 'Brand' }
    else { $pt.Text = switch ($T.Task) { 'Export' { 'Read only on the source tenant' } 'Estimate' { 'Read only on the source tenant' } 'Verify' { 'Read only on the target tenant' } default { 'Read only · offline' } }; Set-TtgPill $pill $pt 'neutral' }
    Show-TtgPreviewResults
    [void](Show-TtgChecks)
    $card = $root.FindName('ApplyCard')
    $card.Visibility = if ($writes -and $T.Preview -and -not $T.Preview.Blocked) { 'Visible' } else { 'Collapsed' }
    $tenant = [string]$T.Config.Target.TenantId
    $root.FindName('ApplyToggle').Content = "Apply: write to tenant $tenant"
    $root.FindName('ApplyText').Text = 'Creates the ghost accounts, copies the files and imports the messages into this tenant. You will be asked to confirm. An imported conversation cannot be rolled back.'
    $root.FindName('CommandText').Text = Get-TtgShown (((Get-TtgChainSteps -Kind $(if ($writes) { 'Preview' } else { 'Run' })) | ForEach-Object { ConvertTo-TtgCommandLine -Mode $_.Mode -Params $_.Params -StoreRoot $T.StoreRoot -Apply $false }) -join "`n")
    $root.FindName('PreviewProgress').Visibility = if ($T.Chain -and $T.Chain.Kind -eq 'Preview' -and -not $T.Chain.Done) { 'Visible' } else { 'Collapsed' }
    Update-TtgVerifyKpis
}

function Update-TtgVerifyKpis {
    $T = $script:Ttg
    $host1 = $T.Pages.Verify.Root.FindName('KpiHost'); $host1.Children.Clear()
    if ($T.Task -eq 'Import' -and $T.Preview) {
        $pv = $T.Preview
        Add-TtgKpi $host1 'Conversations' (Format-TmtNumber $pv.Conversations) 'Ok' 'Planned'
        Add-TtgKpi $host1 'Messages to import' (Format-TmtNumber $pv.Messages) 'Ok' 'Planned'
        Add-TtgKpi $host1 'Ghost accounts' (Format-TmtNumber $pv.Ghosts) $(if ($pv.Ghosts) { 'Warn' } else { 'Ok' }) $(if ($pv.Ghosts) { 'At Apply' } else { 'None' })
        Add-TtgKpi $host1 'Files to copy' (Format-TmtNumber $pv.Files) $(if ($pv.Files) { 'Warn' } else { 'Ok' }) $(if ($pv.Files) { 'At Apply' } else { 'None' })
        Add-TtgKpi $host1 'Blockers' (Format-TmtNumber $pv.BlockerCount) $(if ($pv.BlockerCount) { 'Fail' } else { 'Ok' }) $(if ($pv.BlockerCount) { 'Fix' } else { 'OK' })
        return
    }
    $snap = $T.Snapshot
    if ($snap) {
        Add-TtgKpi $host1 'Users' (Format-TmtNumber $snap.Users); Add-TtgKpi $host1 'Conversations' (Format-TmtNumber $snap.InventoriedConversations)
        Add-TtgKpi $host1 'Exported messages' (Format-TmtNumber $snap.Messages); Add-TtgKpi $host1 'Lots' (Format-TmtNumber @($snap.Lots).Count)
    }
}

function Show-TtgPreviewResults {
    $T = $script:Ttg
    $root = $T.Pages.Verify.Root
    $card = $root.FindName('PreviewCard'); $host1 = $root.FindName('PreviewHost'); $host1.Children.Clear()
    if ($null -eq $T.Preview -or -not @($T.Preview.Lines).Count) { $card.Visibility = 'Collapsed'; return }
    $root.FindName('PreviewTitle').Text = [string]$T.Preview.Title
    foreach ($l in @($T.Preview.Lines)) {
        $name, $value = ([string]$l) -split '\|', 2
        $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(1, 'Star'); $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::Auto
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
        $a = [System.Windows.Controls.TextBlock]::new(); $a.Text = $name; $a.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas'); $a.TextTrimming = 'CharacterEllipsis'; Set-TtgRef $a Foreground 'TextFillColorPrimaryBrush'
        $b = [System.Windows.Controls.TextBlock]::new(); $b.Text = $value; $b.FontWeight = [System.Windows.FontWeights]::SemiBold; $b.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0); Set-TtgRef $b Foreground 'TextFillColorPrimaryBrush'; [System.Windows.Controls.Grid]::SetColumn($b, 1)
        [void]$g.Children.Add($a); [void]$g.Children.Add($b); [void]$host1.Children.Add($g)
    }
    $card.Visibility = 'Visible'
}

function Start-TtgPreview {
    $T = $script:Ttg
    $T.Preview = $null
    $steps = Get-TtgChainSteps -Kind 'Preview'
    $root = $T.Pages.Verify.Root
    $root.FindName('PreviewProgress').Visibility = 'Visible'
    $root.FindName('PreviewProgressText').Text = 'Planning and previewing: nothing is written to any tenant...'
    Start-TtgChain -Kind 'Preview' -Steps $steps -Title 'Preview'
    Update-TtgBottomBar
}

function Complete-TtgPreview {
    $T = $script:Ttg
    $chain = $T.Chain
    $get = { param($id) $chain.Steps | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
    $plan = & $get 'plan'; $imp = & $get 'import'; $cf = & $get 'copyfiles'
    $pr = $plan.Result
    $issues = @(); foreach ($s in $chain.Steps) { if ($s.Result) { $issues += @($s.Result.Issues) } }
    $blocked = ($plan.Status -ne 'Done') -or [bool]($chain.Steps | Where-Object { $_.Status -in 'Failed', 'Blocked' } | Select-Object -First 1)
    $lines = @(); if ($imp.Result) { $lines = @($imp.Result.PreviewLines) }
    if (-not $lines.Count -and $cf.Result) { $lines = @($cf.Result.PreviewLines) }
    $counts = if ($pr) { $pr.Counts } else { @{} }
    $T.Preview = @{
        Lot = [string]$chain.Lot; Blocked = [bool]$blocked; Issues = $issues; BlockerCount = @($issues | Where-Object { $_ -like 'BLOCKER:*' }).Count
        Conversations = [long]$counts.conversations; Messages = [long]$counts.messages; Ghosts = [long]$counts.ghosts; Files = [long]$counts.files; Unresolved = [long]$counts.unresolved
        Lines = $lines; Title = $(if ($imp.Result -and $imp.Result.PreviewTitle) { [string]$imp.Result.PreviewTitle } else { 'Requests that would be sent' }); PlanResult = $pr; Steps = $chain.Steps
    }
    if ($plan.Status -eq 'Failed') { $T.Preview.Issues += "BLOCKER: $($pr.Failure)"; $T.Preview.BlockerCount = [Math]::Max(1, $T.Preview.BlockerCount) }
    $T.Chain = $null
    $T.Pages.Verify.Root.FindName('PreviewProgress').Visibility = 'Collapsed'
    if ($T.Step -eq 3) { Show-TtgVerifyStep }
    Update-TtgBottomBar
}
#endregion

#region Step 4: run ------------------------------------------------------------------------------

function Get-TtgStatusInfo {
    param([string]$Status)
    switch ($Status) {
        'Pending' { @{ Glyph = [string][char]0x25CB; Level = 'neutral'; Text = 'Waiting' } } 'Running' { @{ Glyph = [string][char]0x25B6; Level = 'Brand'; Text = 'Running' } }
        'Done' { @{ Glyph = [string][char]0x2713; Level = 'Ok'; Text = 'Done' } } 'Failed' { @{ Glyph = [string][char]0x2717; Level = 'Fail'; Text = 'Failed' } }
        'Incomplete' { @{ Glyph = [string][char]0x25D0; Level = 'Warn'; Text = 'Stopped' } } 'Waiting' { @{ Glyph = [string][char]0x25D0; Level = 'Warn'; Text = 'Waits for the target' } } 'Blocked' { @{ Glyph = [string][char]0x2717; Level = 'Fail'; Text = 'Blocked' } }
        'Mismatch' { @{ Glyph = [string][char]0x2717; Level = 'Warn'; Text = 'Mismatch' } } default { @{ Glyph = [string][char]0x2013; Level = 'neutral'; Text = 'Not run' } }
    }
}

function Get-TtgLevelBrush { param([string]$Level) switch ($Level) { 'Ok' { 'TmtSuccess' } 'Fail' { 'TmtCritical' } 'Warn' { 'TmtCaution' } 'Brand' { 'TmtBrand' } default { 'TextFillColorSecondaryBrush' } } }

function Initialize-TtgRunStep {
    # The steps list is built once, when the run starts: every step is known before the start.
    $T = $script:Ttg
    $root = $T.Pages.Run.Root
    $chain = $T.Chain
    $list = $root.FindName('StepsList'); $list.Items.Clear()
    $root.FindName('StepsTitle').Text = "Steps ($(@($chain.Steps).Count), all known before the start)"
    $n = 0
    foreach ($s in $chain.Steps) {
        $n++
        $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        foreach ($w in 'Auto', 'Star', 'Auto') { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($w -eq 'Star') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }; $g.ColumnDefinitions.Add($cd) }
        $rd = [System.Windows.Controls.RowDefinition]::new(); $rd.Height = [System.Windows.GridLength]::Auto; $g.RowDefinitions.Add($rd); $rd2 = [System.Windows.Controls.RowDefinition]::new(); $rd2.Height = [System.Windows.GridLength]::Auto; $g.RowDefinitions.Add($rd2)
        $gl = [System.Windows.Controls.TextBlock]::new(); $gl.Width = 22; $gl.FontSize = 14; $gl.VerticalAlignment = 'Top'
        $ti = [System.Windows.Controls.TextBlock]::new(); $ti.Text = "$n. $($s.Title)"; $ti.TextWrapping = 'Wrap'; Set-TtgRef $ti Foreground 'TextFillColorPrimaryBrush'; [System.Windows.Controls.Grid]::SetColumn($ti, 1)
        $tm = [System.Windows.Controls.TextBlock]::new(); $tm.FontSize = 12; $tm.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0); Set-TtgRef $tm Foreground 'TextFillColorSecondaryBrush'; [System.Windows.Controls.Grid]::SetColumn($tm, 2)
        $bar = [System.Windows.Controls.ProgressBar]::new(); $bar.Height = 4; $bar.Minimum = 0; $bar.Maximum = 100; $bar.Margin = [System.Windows.Thickness]::new(22, 4, 0, 0); [System.Windows.Controls.Grid]::SetRow($bar, 1); [System.Windows.Controls.Grid]::SetColumnSpan($bar, 3)
        foreach ($e in $gl, $ti, $tm, $bar) { [void]$g.Children.Add($e) }
        $item = [System.Windows.Controls.ListBoxItem]::new(); $item.Content = $g; $item.Tag = @{ Step = $s; Glyph = $gl; Time = $tm; Bar = $bar; Index = $n - 1 }
        $item.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
        [System.Windows.Automation.AutomationProperties]::SetName($item, "Step $n $($s.Title)")
        [void]$list.Items.Add($item)
    }
    $T.Run = @{ UserSelected = $false }
}

function Get-TtgModeNeedsForTask { param([string]$Task) switch ($Task) { 'Estimate' { 'Source' } 'Export' { 'Source' } 'Import' { 'Target' } 'Verify' { 'Target' } default { '' } } }

function Update-TtgChainUi {
    $T = $script:Ttg
    $chain = $T.Chain
    if ($null -eq $chain) { $chain = $T.LastChain }
    if ($null -eq $chain) { return }
    if ($chain.Kind -eq 'Preview') {
        $cur = if ($chain.Index -ge 0) { $chain.Steps[$chain.Index] } else { $null }
        if ($cur) { $T.Pages.Verify.Root.FindName('PreviewProgressText').Text = "$($cur.Title)$(if ($cur.Detail) { ': ' + $cur.Detail })" }
        return
    }
    $root = $T.Pages.Run.Root
    $list = $root.FindName('StepsList')
    $done = 0.0
    foreach ($item in $list.Items) {
        $d = $item.Tag; $s = $d.Step; $inf = Get-TtgStatusInfo $s.Status
        $d.Glyph.Text = $inf.Glyph
        $d.Glyph.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, (Get-TtgLevelBrush $inf.Level))
        $d.Time.Text = if ($s.Status -in 'Pending', 'NotRun') { '' } else { Format-TmtDuration $s.Seconds }
        $d.Bar.Value = if ($s.Status -eq 'Done') { 100 } else { $s.Progress }
        $d.Bar.IsIndeterminate = ($s.Status -eq 'Running' -and $s.Progress -le 0)
        if ($s.Status -in 'Done', 'Failed', 'Incomplete', 'Blocked', 'Mismatch', 'NotRun', 'Waiting') { $done += 1 } elseif ($s.Status -eq 'Running') { $done += [Math]::Min(0.95, $s.Progress / 100) }
    }
    $total = [Math]::Max(1, @($chain.Steps).Count)
    $root.FindName('RunProgress').Value = [Math]::Min(100, 100 * $done / $total)
    $elapsed = if ($chain.Done) { ($chain.Finished - $chain.Started).TotalSeconds } else { ([DateTime]::UtcNow - $chain.Started).TotalSeconds }
    $root.FindName('RunCount').Text = "$total step(s) $([char]0x00B7) $(Format-TmtDuration $elapsed)"
    $info = Get-TtgTaskInfo $chain.Task
    $root.FindName('RunTitle').Text = "$($info.Name)$(if ($chain.Lot) { " $([char]0x00B7) lot $($chain.Lot)" })"
    $tenant = switch ((Get-TtgModeNeedsForTask $chain.Task)) { 'Source' { [string]$T.Config.Source.TenantId } 'Target' { [string]$T.Config.Target.TenantId } default { 'local store' } }
    $root.FindName('RunSub').Text = Get-TtgShown "$(if ($chain.Apply) { 'Apply' } else { 'Run' }) $([char]0x00B7) $tenant $([char]0x00B7) started $($chain.Started.ToLocalTime().ToString('HH:mm')) on $env:COMPUTERNAME"
    $pill = $root.FindName('RunPill'); $pt = $root.FindName('RunPillText')
    if (-not $chain.Done) { $pt.Text = if ($chain.Stopping) { 'Stopping' } else { 'Running' }; Set-TtgPill $pill $pt 'Brand' }
    else { $pt.Text = switch ($chain.Exit) { 0 { 'Done' } 1 { 'Failed' } 2 { 'Stopped' } default { 'Check' } }; Set-TtgPill $pill $pt $(switch ($chain.Exit) { 0 { 'Ok' } 1 { 'Fail' } default { 'Warn' } }) }
    if (-not $T.Run.UserSelected -and $list.Items.Count) { $T.Suppress = $true; try { $list.SelectedIndex = [Math]::Max(0, [Math]::Min($chain.Selected, $list.Items.Count - 1)) } finally { $T.Suppress = $false } }
    Update-TtgRunDetail
}

function Update-TtgRunDetail {
    $T = $script:Ttg
    $chain = if ($T.Chain) { $T.Chain } else { $T.LastChain }
    if ($null -eq $chain -or $chain.Kind -eq 'Preview') { return }
    $root = $T.Pages.Run.Root
    $sel = $root.FindName('StepsList').SelectedItem
    if ($null -eq $sel) { return }
    $s = $sel.Tag.Step
    $inf = Get-TtgStatusInfo $s.Status
    $root.FindName('DetailTitle').Text = "$($sel.Tag.Index + 1). $($s.Title)"
    $root.FindName('DetailText').Text = $s.Description
    $pt = $root.FindName('DetailPillText'); $pt.Text = $inf.Text; Set-TtgPill $root.FindName('DetailPill') $pt $inf.Level
    $counts = $root.FindName('DetailCounts'); $counts.Children.Clear()
    if ($s.Result) {
        foreach ($kv in $s.Result.Counts.GetEnumerator()) {
            $tb = [System.Windows.Controls.Border]::new(); $tb.CornerRadius = [System.Windows.CornerRadius]::new(6); $tb.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4); $tb.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6); $tb.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'TmtInfoBg')
            $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = "$($kv.Key) $($kv.Value)"; Set-TtgRef $t1 Foreground 'TextFillColorPrimaryBrush'; $tb.Child = $t1; [void]$counts.Children.Add($tb)
        }
    } elseif ($s.Status -eq 'Running' -and $s.Detail) { $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = $s.Detail; $t1.TextWrapping = 'Wrap'; Set-TtgRef $t1 Foreground 'TextFillColorSecondaryBrush'; [void]$counts.Children.Add($t1) }
    $issues = if ($s.Result) { @($s.Result.Issues) } else { @() }
    if ($s.Result -and $s.Result.Failure) { $issues = @("Error: $($s.Result.Failure)") + $issues }
    $root.FindName('DetailIssues').Text = Get-TtgShown $(if ($issues.Count) { $issues -join "`n" } else { 'Nothing to report so far.' })
    $root.FindName('TechBox').Text = Get-TtgShown $(if ($s.Result) { "Exit code $($s.Result.ExitCode) - $(Get-TmtExitMeaning -ExitCode ([int]$s.Result.ExitCode))`r`n$($s.Result.Failure)" } else { '' })
    $log = $root.FindName('LogBox'); $txt = Get-TtgShown ($s.Log.ToString())
    if ($log.Text.Length -ne $txt.Length) { $log.Text = $txt; $log.ScrollToEnd() }
    $jh = $root.FindName('JourneyHost'); $jh.Children.Clear()
    $root.FindName('JourneyTitle').Text = if ($chain.Lot) { "Lot $($chain.Lot)" } else { (Get-TtgTaskInfo $chain.Task).Name }
    $root.FindName('JourneySub').Text = (Get-TtgTaskParams).Summary
    foreach ($x in $chain.Steps) {
        $xi = Get-TtgStatusInfo $x.Status
        $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
        $gl = [System.Windows.Controls.TextBlock]::new(); $gl.Text = $xi.Glyph; $gl.Width = 20; $gl.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, (Get-TtgLevelBrush $xi.Level))
        $sp = [System.Windows.Controls.StackPanel]::new()
        $a = [System.Windows.Controls.TextBlock]::new(); $a.Text = $x.Title; Set-TtgRef $a Foreground 'TextFillColorPrimaryBrush'
        $b = [System.Windows.Controls.TextBlock]::new(); $b.FontSize = 12; Set-TtgRef $b Foreground 'TextFillColorSecondaryBrush'; $b.TextWrapping = 'Wrap'
        $b.Text = if ($x.Result) { (@($x.Result.Counts.GetEnumerator() | Select-Object -First 3 | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ') } else { $xi.Text }
        [void]$sp.Children.Add($a); [void]$sp.Children.Add($b); [void]$row.Children.Add($gl); [void]$row.Children.Add($sp); [void]$jh.Children.Add($row)
    }
    $last = @($chain.Steps | Where-Object { $_.Result -and $_.Result.Report } | Select-Object -Last 1)
    $rp = if ($s.Result -and $s.Result.Report) { [string]$s.Result.Report } elseif ($last) { [string]$last.Result.Report } else { '' }
    $root.FindName('ReportPath').Text = if ($rp) { Get-TtgShown $rp } else { 'Not written yet.' }
    $T.Run.ReportPath = $rp
    $allIssues = @($chain.Steps | Where-Object { $_.Result } | ForEach-Object { @($_.Result.Issues) | Where-Object { $_ -like 'Warning*' } })
    $root.FindName('JourneyWarnings').Text = Get-TtgShown $(if ($allIssues.Count) { ($allIssues | Select-Object -First 6) -join "`n" } else { 'None.' })
}

function New-TtgRunPanel {
    $T = $script:Ttg
    $root = Read-TtgXaml 'Step.Run.xaml'
    $T.Pages.Run = @{ Root = $root }
    $T.Run = @{ UserSelected = $false }
    Add-TtgHandler ($root.FindName('StepsList')) 'SelectionChanged' { param($s, $e) $t = Get-TtgState; if ($t.Suppress) { return }; if ($s.IsKeyboardFocusWithin -or $s.IsMouseOver) { $t.Run.UserSelected = $true }; Update-TtgRunDetail }
    Add-TtgHandler ($root.FindName('ReportOpen')) 'Click' { Open-TtgPath ((Get-TtgState).Run.ReportPath) }
    Add-TtgHandler ($root.FindName('ReportCopy')) 'Click' { $p = (Get-TtgState).Run.ReportPath; if ($p) { [System.Windows.Clipboard]::SetText($p); Set-TtgStatus 'Path copied' } }
}
#endregion

#region Step 5: next steps ----------------------------------------------------------------------------

function Show-TtgNextStep {
    $T = $script:Ttg
    $root = $T.Pages.Next.Root
    $chain = $T.LastChain
    $task = $T.Task
    $info = Get-TtgTaskInfo $task
    $exit = if ($chain) { [int]$chain.Exit } else { 0 }
    Set-TtgLight ($root.FindName('NextLight')) $(switch ($exit) { 0 { 'Green' } 1 { 'Red' } default { 'Amber' } })
    $root.FindName('NextTitle').Text = if ($task -eq 'Browse') { 'Archive browsed' } else { switch ($exit) { 0 { "$($info.Name): done" } 1 { "$($info.Name): failed" } 2 { "$($info.Name): stopped, nothing was lost" } default { "$($info.Name): finished with items to check" } } }
    $root.FindName('NextText').Text = switch ($exit) { 0 { 'Everything ran to the end.' } 1 { 'A step failed. Read the error below and the log, fix the cause, then run the task again.' } 2 { 'Run the same task again to resume: a message is never sent twice.' } default { 'Some items are uncertain or did not match. Read the reports before going on.' } }
    $kp = $root.FindName('NextKpis'); $kp.Children.Clear()
    $root.FindName('NextFailure').Text = ''
    if ($chain) {
        $show = @($chain.Steps | Where-Object { $_.Result -and $_.Mode -in 'Export', 'Import', 'Verify', 'Assess' } | Select-Object -Last 1)
        if ($show) { foreach ($kv in ($show[0].Result.Counts.GetEnumerator() | Select-Object -First 6)) { Add-TtgKpi $kp ([string]$kv.Key) ([string]$kv.Value) } }
        $fail = @($chain.Steps | Where-Object { $_.Result -and $_.Result.Failure } | Select-Object -First 1)
        if ($fail) { $root.FindName('NextFailure').Text = Get-TtgShown ([string]$fail[0].Result.Failure) }
    }
    $lot = if ($chain) { [string]$chain.Lot } else { '' }
    $advice = ''; $buttons = @()
    switch ($task) {
        'Estimate' { $advice = 'You now know the volume. Export the conversations you want to migrate.'; $buttons = @(@{ Text = 'Export conversations'; Task = 'Export' }) }
        'Export' { $advice = 'The conversations are in the store. Browse them offline to check the content, then plan the import.'; $buttons = @(@{ Text = 'Browse the archive'; Task = 'Browse' }, @{ Text = 'Import a lot'; Task = 'Import' }) }
        'Browse' { $advice = 'If the archive looks right, plan the import of the users or teams you chose.'; $buttons = @(@{ Text = 'Import a lot'; Task = 'Import' }, @{ Text = 'Export more'; Task = 'Export' }) }
        'Import' { $advice = if ($exit -eq 0) { "The lot $lot is imported. Verify it against the source." } else { 'Fix what the reports show, then run the import again.' }; $buttons = @(@{ Text = 'Verify this lot'; Task = 'Verify'; Lot = $lot }) }
        'Verify' { $advice = if ($exit -eq 0) { "The lot $lot matches the source. The reports are ready to keep." } else { 'Open verify.html: it lists the conversations that differ.' }; $buttons = @(@{ Text = 'Start another task'; Task = 'Export' }) }
    }
    $root.FindName('NextAdvice').Text = $advice
    $nb = $root.FindName('NextButtons'); $nb.Children.Clear()
    foreach ($b in $buttons) {
        $btn = [Wpf.Ui.Controls.Button]::new(); $btn.Content = $b.Text; $btn.Tag = $b; $btn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0); $btn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
        if ($b -eq $buttons[0]) { $btn.Appearance = [Wpf.Ui.Controls.ControlAppearance]::Primary }
        Add-TtgHandler $btn 'Click' { param($s, $e) Switch-TtgTask -Spec $s.Tag }
        [void]$nb.Children.Add($btn)
    }
    $cm = $root.FindName('NextCommands'); $cm.Children.Clear()
    if ($chain) {
        foreach ($s in $chain.Steps) {
            $params = @{}; foreach ($k in $s.Params.Keys) { $params[$k] = $s.Params[$k] }
            if ($lot -and $s.Mode -in 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report') { $params.Lot = $lot }
            $line = ConvertTo-TtgCommandLine -Mode $s.Mode -Params $params -StoreRoot $T.StoreRoot -Apply ([bool]$s.Apply)
            $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
            $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(1, 'Star'); $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
            $tb = [System.Windows.Controls.TextBlock]::new(); $tb.Text = Get-TtgShown $line; $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas'); $tb.FontSize = 12; $tb.TextWrapping = 'Wrap'; $tb.VerticalAlignment = 'Center'; Set-TtgRef $tb Foreground 'TextFillColorPrimaryBrush'
            $cb = [Wpf.Ui.Controls.Button]::new(); $cb.Content = 'Copy'; $cb.Tag = (Get-TtgShown $line); $cb.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0); [System.Windows.Controls.Grid]::SetColumn($cb, 1)
            [System.Windows.Automation.AutomationProperties]::SetName($cb, "Copy the command of $($s.Title)")
            Add-TtgHandler $cb 'Click' { param($s2, $e) [System.Windows.Clipboard]::SetText([string]$s2.Tag); Set-TtgStatus 'Command copied' }
            [void]$g.Children.Add($tb); [void]$g.Children.Add($cb); [void]$cm.Children.Add($g)
        }
    } else { $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = 'The viewer runs no command.'; Set-TtgRef $t1 Foreground 'TextFillColorSecondaryBrush'; [void]$cm.Children.Add($t1) }
    $lk = $root.FindName('NextLinks'); $lk.Children.Clear()
    $folders = @(); if ($chain) { $folders = @($chain.Steps | Where-Object { $_.Result -and $_.Result.Report } | ForEach-Object { [string]$_.Result.Report }) }
    if ($task -eq 'Browse' -and $T.Explorer.ArchiveRoot) { $folders = @([string]$T.Explorer.ArchiveRoot) }
    foreach ($fo in $folders) {
        if (-not (Test-Path -LiteralPath $fo)) { continue }
        $b = [Wpf.Ui.Controls.Button]::new(); $b.Content = "Open $(Split-Path -Leaf $fo)"; $b.Tag = $fo; $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 6)
        Add-TtgHandler $b 'Click' { param($s, $e) Open-TtgPath ([string]$s.Tag) }
        [void]$lk.Children.Add($b)
        foreach ($h in @(Get-ChildItem -LiteralPath $fo -Filter *.html -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'TeamsTransfer_*' -or $_.Name -like 'TeamsTransfer_Lot*' } | Select-Object -First 3)) {
            $hb = [Wpf.Ui.Controls.Button]::new(); $hb.Content = "Open $($h.Name)"; $hb.Tag = $h.FullName; $hb.Margin = [System.Windows.Thickness]::new(0, 0, 8, 6)
            Add-TtgHandler $hb 'Click' { param($s, $e) Open-TtgPath ([string]$s.Tag) }
            [void]$lk.Children.Add($hb)
        }
    }
    if (-not $lk.Children.Count) { $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = 'No report was written by this task.'; Set-TtgRef $t1 Foreground 'TextFillColorSecondaryBrush'; [void]$lk.Children.Add($t1) }
}

function Switch-TtgTask {
    # A button of the Next steps page: reset the run, choose the next task (with its lot) and go to step 2.
    param($Spec)
    $T = $script:Ttg
    Reset-TtgRun
    Set-TtgTask -Key $Spec.Task
    if ($Spec.Lot -and $T.Form[$Spec.Task].Scopes.ContainsKey('lot')) {
        Set-TtgScope -Key 'lot'
        foreach ($fl in $T.Form[$Spec.Task].Scopes['lot'].Values) { $fl.Control.Text = [string]$Spec.Lot }
    }
    Select-TtgStep 2
}

function Reset-TtgRun {
    $T = $script:Ttg
    $T.Chain = $null; $T.LastChain = $null; $T.Preview = $null
}
#endregion

#region Navigation: stepper, bottom bar, steps --------------------------------------------------------

function Get-TtgStepNames { @('Setup', 'Task', 'Verify', 'Run', 'Next steps') }

function Update-TtgStepper {
    $T = $script:Ttg
    foreach ($child in $T.Ui.StepperHost.Children) {
        if ($child.Tag -isnot [int]) { continue }
        $cur = ([int]$child.Tag -eq $T.Step)
        $child.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($cur) { 'TmtAccentSoft' } else { 'CardBackgroundFillColorDefaultBrush' }))
        $badge = $child.Child.Children[0]
        $badge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($cur) { 'TmtBrand' } else { 'TmtTrack' }))
        $badge.Child.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($cur) { 'TmtOnBrand' } else { 'TextFillColorSecondaryBrush' }))
        $lab = $child.Child.Children[1]
        $lab.FontWeight = if ($cur) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
        $lab.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($cur) { 'TextFillColorPrimaryBrush' } else { 'TextFillColorSecondaryBrush' }))
    }
}

function Update-TtgContext {
    $T = $script:Ttg
    if (-not $T.Ui.ContextText) { return }
    $text = if (-not $T.Task -or $null -eq $T.Form) { 'No task chosen yet' } else { $p = Get-TtgTaskParams; "$((Get-TtgTaskInfo $T.Task).Name) $([char]0x00B7) $($p.Summary)" }
    $T.Ui.ContextText.Text = (@($text, $(if ($T.Demo) { 'DEMO' })) | Where-Object { $_ }) -join " $([char]0x00B7) "
}

function Update-TtgBottomBar {
    $T = $script:Ttg
    $ui = $T.Ui
    if (-not $ui.PrimaryButton) { return }
    $running = [bool]($T.Chain -and -not $T.Chain.Done)
    $back = $ui.BackButton; $prim = $ui.PrimaryButton; $sec = $ui.SecondaryButton
    $back.Visibility = 'Visible'
    $back.IsEnabled = (($T.Step -in 2, 3) -and -not $running) -or ($T.Step -eq 5) -or ($T.Step -eq 4 -and $T.Task -eq 'Browse')
    $sec.Visibility = if ($running -and $T.Step -eq 4) { 'Visible' } else { 'Collapsed' }
    $sec.IsEnabled = $running -and -not $T.Chain.Stopping
    $prim.IsEnabled = $true
    switch ($T.Step) {
        1 { $ui.BottomText.Text = 'Check the lights and the store. Changes here are for this session only.'; $prim.Content = 'Choose a task'; $back.Visibility = 'Hidden' }
        2 {
            $p = Get-TtgTaskParams
            $ui.BottomText.Text = if ($T.Task) { if ($p.Error) { $p.Error } else { 'Next: the checks, and the preview when the task writes to a tenant.' } } else { 'Choose a task above.' }
            $prim.Content = if ($T.Task -eq 'Browse') { 'Continue' } else { 'Continue to verification' }
            $prim.IsEnabled = [bool]$T.Task -and -not $p.Error
        }
        3 {
            $blocked = @($T.LastChecks | Where-Object { $_.Level -eq 'Fail' }).Count -gt 0
            if ($T.Task -eq 'Import') {
                if ($running) { $prim.Content = 'Previewing...'; $prim.IsEnabled = $false; $ui.BottomText.Text = 'The preview plans and counts; nothing is written to any tenant.' }
                elseif (-not $T.Preview) { $prim.Content = 'Run preview'; $prim.IsEnabled = -not $blocked; $ui.BottomText.Text = if ($blocked) { 'Fix the red checks first.' } else { 'The preview plans the lot and counts the requests. Nothing is written.' } }
                elseif ($T.Preview.Blocked) { $prim.Content = 'Run preview again'; $prim.IsEnabled = $true; $ui.BottomText.Text = 'The plan has blockers: fix them, then preview again.' }
                else {
                    $ok = [bool]$T.Pages.Verify.Root.FindName('ApplyToggle').IsChecked
                    $prim.Content = 'Apply now'; $prim.IsEnabled = $ok
                    $ui.BottomText.Text = if ($ok) { "Applying writes to the target tenant $($T.Config.Target.TenantId)." } else { 'Tick Apply above to write to the target tenant. Otherwise nothing is written.' }
                }
            } elseif ($T.Task -eq 'Browse') { $prim.Content = 'Open the viewer'; $prim.IsEnabled = -not $blocked; $ui.BottomText.Text = 'Offline and read only.' }
            else { $prim.Content = "Start $((Get-TtgTaskInfo $T.Task).Name.ToLowerInvariant())"; $prim.IsEnabled = -not $blocked; $ui.BottomText.Text = if ($blocked) { 'Fix the red checks first.' } else { 'Nothing is written to any tenant.' } }
        }
        4 {
            if ($T.Task -eq 'Browse') { $prim.Content = 'What next?'; $ui.BottomText.Text = 'Pick a user or a conversation. Links outside the archive ask before they open.' }
            else {
                $back.Visibility = 'Hidden'
                $prim.Content = 'What next?'; $prim.IsEnabled = -not $running
                $ui.BottomText.Text = if ($running) { if ($T.Chain.Stopping) { 'Stopping: the requests in flight finish first. Run the task again to resume.' } else { 'Running. Stop ends the run after the requests in flight; nothing is lost.' } } else { 'Finished. The next page says what to do.' }
            }
        }
        5 { $prim.Content = 'Start another task'; $ui.BottomText.Text = 'Every run is also an ordinary command line: copy it from above.' }
    }
}

function Select-TtgStep {
    param([Parameter(Mandatory)][ValidateRange(1, 5)][int]$Number)
    $T = $script:Ttg
    $T.Step = $Number
    $panel = switch ($Number) { 1 { $T.Pages.Home.Root } 2 { $T.Pages.Task.Root } 3 { $T.Pages.Verify.Root } 4 { if ($T.Task -eq 'Browse') { $T.Pages.Explorer.Root } else { $T.Pages.Run.Root } } 5 { $T.Pages.Next.Root } }
    $T.Ui.StepHost.Content = $panel
    switch ($Number) {
        1 { Update-TtgSetup }
        2 { foreach ($f in $T.Form[$T.Task].Scopes[$T.Scope[$T.Task]].Values) { if ($f.Type -eq 'lot') { Update-TtgLotItems $f.Control } }; Update-TtgTaskText }
        3 { $T.Snapshot = Get-TtgStoreSnapshot; Show-TtgVerifyStep }
        4 { if ($T.Task -eq 'Browse') { Show-TtgExplorer } }
        5 { Show-TtgNextStep }
    }
    Update-TtgStepper; Update-TtgContext; Update-TtgBottomBar
    Set-TtgStatus "Step $Number of 5: $((Get-TtgStepNames)[$Number - 1])"
}

function Invoke-TtgPrimary {
    $T = $script:Ttg
    switch ($T.Step) {
        1 { Select-TtgStep 2 }
        2 { if (-not $T.Task) { return }; if ((Get-TtgTaskParams).Error) { return }; $T.Preview = $null; Select-TtgStep 3 }
        3 {
            if ($T.Task -eq 'Browse') { Select-TtgStep 4; return }
            if ($T.Task -eq 'Import') {
                if (-not $T.Preview -or $T.Preview.Blocked) { if (-not ($T.Chain -and -not $T.Chain.Done)) { Start-TtgPreview }; return }
                if (-not [bool]$T.Pages.Verify.Root.FindName('ApplyToggle').IsChecked) { return }
                $msg = Get-TtgApplyMessage -Mode 'Import' -Params @{ Lot = $T.Preview.Lot } -StoreRoot $T.StoreRoot -Tenant ([string]$T.Config.Target.TenantId)
                if (-not (Confirm-TtgAction -Title 'Teams Transfer - Apply the import' -Message $msg -Warning)) { Set-TtgStatus 'Cancelled: nothing was written.'; return }
                Start-TtgRunChain @(Get-TtgChainSteps -Kind 'Run')
                return
            }
            Start-TtgRunChain @(Get-TtgChainSteps -Kind 'Run')
        }
        4 { if ($T.Task -eq 'Browse') { $T.LastChain = $null; Select-TtgStep 5 } elseif ($T.Chain -and $T.Chain.Done) { $T.LastChain = $T.Chain; Select-TtgStep 5 } elseif ($T.LastChain) { Select-TtgStep 5 } }
        5 { Reset-TtgRun; Select-TtgStep 2 }
    }
}

function Start-TtgRunChain {
    param([object[]]$Steps)
    $T = $script:Ttg
    Start-TtgChain -Kind 'Run' -Steps $Steps -Title 'Run'
    Initialize-TtgRunStep
    Select-TtgStep 4
    Update-TtgChainUi
}

function Invoke-TtgBack {
    $T = $script:Ttg
    if ($T.Chain -and -not $T.Chain.Done) { return }
    switch ($T.Step) { 2 { Select-TtgStep 1 } 3 { Select-TtgStep 2 } 4 { Select-TtgStep 3 } 5 { Select-TtgStep 2 } }
}

function New-TtgShell {
    $T = $script:Ttg
    $window = Read-TtgXaml 'MainWindow.xaml'
    if ($window -isnot [Wpf.Ui.Controls.FluentWindow]) { throw 'The main window must be a WPF-UI FluentWindow.' }
    $T.Window = $window
    foreach ($n in 'StepperHost', 'ContextText', 'StepHost', 'BackButton', 'PrimaryButton', 'SecondaryButton', 'BottomText', 'DemoBadge', 'VersionText', 'TtTitleBar', 'ThemeSystem', 'ThemeLight', 'ThemeDark') { $T.Ui[$n] = $window.FindName($n) }
    $T.Ui.StatusText = [System.Windows.Controls.TextBlock]::new()
    $T.WindowTitle = if ($T.Demo) { 'Teams Transfer Console - DEMO' } else { 'Teams Transfer Console' }
    $window.Title = $T.WindowTitle; $T.Ui.TtTitleBar.Title = $T.WindowTitle
    $ver = (Import-PowerShellDataFile -LiteralPath (Join-Path $T.PackageRoot 'TeamsTransfer.psd1')).ModuleVersion
    $T.Ui.VersionText.Text = "v$ver $([char]0x00B7) Nicolas Fabert"
    if ($T.Demo) { $T.Ui.DemoBadge.Visibility = 'Visible' }
    $names = Get-TtgStepNames
    for ($i = 1; $i -le 5; $i++) {
        $b = [System.Windows.Controls.Border]::new(); $b.Tag = $i; $b.CornerRadius = [System.Windows.CornerRadius]::new(18); $b.Padding = [System.Windows.Thickness]::new(8, 4, 14, 4); $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = 'Horizontal'
        $badge = [System.Windows.Controls.Border]::new(); $badge.Width = 24; $badge.Height = 24; $badge.CornerRadius = [System.Windows.CornerRadius]::new(12); $badge.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $nt = [System.Windows.Controls.TextBlock]::new(); $nt.Text = [string]$i; $nt.FontSize = 11; $nt.FontWeight = [System.Windows.FontWeights]::SemiBold; $nt.HorizontalAlignment = 'Center'; $nt.VerticalAlignment = 'Center'; $badge.Child = $nt
        $lb = [System.Windows.Controls.TextBlock]::new(); $lb.Text = $names[$i - 1]; $lb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($badge); [void]$sp.Children.Add($lb); $b.Child = $sp
        [System.Windows.Automation.AutomationProperties]::SetName($b, "Step $i $($names[$i - 1])")
        Add-TtgHandler $b 'MouseLeftButtonUp' { param($s, $e) $t = Get-TtgState; $n = [int]$s.Tag; if ($t.Chain -and -not $t.Chain.Done) { return }; if ($n -in 1, 2 -or ($n -eq 3 -and $t.Task -and $n -le $t.Step)) { Select-TtgStep $n } }
        [void]$T.Ui.StepperHost.Children.Add($b)
        if ($i -lt 5) { $ch = [System.Windows.Controls.TextBlock]::new(); $ch.Text = [string][char]0x203A; $ch.FontSize = 16; $ch.VerticalAlignment = 'Center'; $ch.Margin = [System.Windows.Thickness]::new(4, 0, 4, 0); Set-TtgRef $ch Foreground 'TextFillColorSecondaryBrush'; [void]$T.Ui.StepperHost.Children.Add($ch) }
    }
    Add-TtgHandler $T.Ui.PrimaryButton 'Click' { Invoke-TtgPrimary }
    Add-TtgHandler $T.Ui.BackButton 'Click' { Invoke-TtgBack }
    Add-TtgHandler $T.Ui.SecondaryButton 'Click' { Stop-TtgChain }
    foreach ($n in 'System', 'Light', 'Dark') {
        $rb = $T.Ui["Theme$n"]; $rb.Tag = $n
        Add-TtgHandler $rb 'Click' { param($s, $e) [void](Set-TtgTheme -Requested ([string]$s.Tag)); Save-TtgSettings; foreach ($side in 'Source', 'Target') { Show-TtgRoles -Side $side } }
    }
    return $window
}

function Initialize-TtgSteps {
    $T = $script:Ttg
    New-TtgSetupPanel
    Initialize-TtgTaskForms
    New-TtgTaskPanel
    $T.Pages.Verify = @{ Root = (Read-TtgXaml 'Step.Verify.xaml') }
    Add-TtgHandler ($T.Pages.Verify.Root.FindName('ApplyToggle')) 'Click' { Update-TtgBottomBar }
    New-TtgRunPanel
    $T.Pages.Next = @{ Root = (Read-TtgXaml 'Step.Next.xaml') }
    New-TtgExplorerPage -Entry @{ Key = 'Explorer'; Title = 'Explorer' }
    $T.Ui["Theme$($T.Settings.Theme)"].IsChecked = $true
    Set-TtgTask -Key 'Export'
}
#endregion
