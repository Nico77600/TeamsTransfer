#Requires -Version 7.4
<#
.SYNOPSIS
    Regenerates the drawings of the documentation (package\docs\images\readme-*-<theme>.png and the README banner), light and dark, from fixed texts.

.DESCRIPTION
    No tenant, no network and no console are needed. Two kinds of pictures are made here:

      1. Drawings, readme-<subject>-<theme>.png: small diagrams drawn with WPF classes and the colours of the console (the raspberry accent #B11F4B):
         why, path, how, principles, waves, permissions. They are 2160 px wide, like the pictures of the sibling projects.
      2. The README banner, readme-banner-<theme>.svg: an SVG with the template of the ExchangeLogReport hero (canvas, frame, accent bar, tint,
         icon, eyebrow, title, lead, pills, footer line and stat cards). The icon is the chat bubbles of Teams Transfer.

    The window pictures (console-*.png) and the archive pictures (preview-*.png) are made by tools\New-ConsoleScreens.ps1 and
    tools\New-PreviewScreens.ps1; this script does not touch them.

    The permission drawing is read from package\config\Permissions.psd1 (the single table of the product), never typed by hand.

    Privacy: every text of a drawing is checked before it is saved. A text that holds a GUID, a tenant name other than contoso, an e-mail domain
    other than contoso, fabrikam or northwind, or a term of the optional private deny-list (tests\privacy-denylist.local.txt, git-ignored) stops the script.

.PARAMETER OutDir
    Default: package\docs\images.

.PARAMETER Version
    The version written in the banner (default: ModuleVersion of the manifest).

.PARAMETER Name
    Only the pictures whose file name starts with one of these words (for instance readme-path, readme-banner).

.EXAMPLE
    .\tools\New-DocumentationImages.ps1
    .\tools\New-DocumentationImages.ps1 -Name readme-permissions

.NOTES
    Author  : Nicolas Fabert
    Part of : Teams Transfer (repository tool, not in the package)
    Needs   : Windows with WPF, PowerShell 7.4 or later; Segoe UI Variable and Segoe Fluent Icons (Windows 11) for the exact look.
#>
[CmdletBinding()]
param([string]$OutDir, [string]$Version, [string[]]$Name)

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $a = @('-NoProfile', '-STA', '-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) { $a += "-$k"; $a += (@($PSBoundParameters[$k]) -join ',') }
    & (Get-Process -Id $PID).Path @a
    exit $LASTEXITCODE
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$package = Join-Path $repo 'package'
if (-not $OutDir) { $OutDir = Join-Path $package 'docs\images' }
$null = New-Item -ItemType Directory -Force -Path $OutDir
$Name = @($Name | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $Version) { $Version = (Import-PowerShellDataFile -LiteralPath (Join-Path $package 'TeamsTransfer.psd1')).ModuleVersion }
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

function Test-Wanted([string]$File) { (-not $Name) -or [bool]($Name | Where-Object { $File -like "$_*" }) }

# ---- privacy check ------------------------------------------------------------------------------------------------------------------------
$script:Deny = @()
$denyFile = Join-Path $repo 'tests\privacy-denylist.local.txt'
if (Test-Path -LiteralPath $denyFile) { $script:Deny = @(Get-Content -LiteralPath $denyFile | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }) }
function Assert-PublicText([string]$Text) {
    if ($Text -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') { throw 'A picture text holds a GUID.' }
    if ($Text -match '(?i)\b(?!(?:contoso|fabrikam|northwind)\b)[a-z0-9-]+\.onmicrosoft\.com') { throw 'A picture text names a tenant other than contoso, fabrikam or northwind.' }
    if ($Text -match '(?i)@(?!(?:contoso|fabrikam|northwind)\.)[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}') { throw 'A picture text holds an e-mail domain other than contoso, fabrikam or northwind.' }
    foreach ($t in $script:Deny) { if ($Text.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'A picture text holds a term of the private deny-list.' } }
}

# ---- a small toolkit over WPF -----------------------------------------------------------------------------------------------------------------
$palettes = @{
    light = @{ bg = '#FFFFFF'; card = '#FFFFFF'; stroke = '#DEDEDE'; text = '#242424'; text2 = '#5C5C5C'; text3 = '#8A8A8A'; accent = '#B11F4B'; accentText = '#9A1A41'; soft = '#F7E4EA'
        onAccent = '#FFFFFF'; ok = '#15803D'; okBg = '#EAF7EE'; warn = '#92400E'; warnBg = '#FFF7E8'; bad = '#B91C1C'; badBg = '#FDECEC'; info = '#F3F3F3'; panel = '#F6F6F6'; white = '#FFFFFF'; bar = '#B11F4B'; barSoft = '#E7B9C7' }
    dark  = @{ bg = '#0D1117'; card = '#2B2B2B'; stroke = '#3D3D3D'; text = '#FFFFFF'; text2 = '#C5C5C5'; text3 = '#9A9A9A'; accent = '#FD8EA1'; accentText = '#FD8EA1'; soft = '#40303A'
        onAccent = '#0D1117'; ok = '#4ADE80'; okBg = '#24362B'; warn = '#FBBF24'; warnBg = '#3A3322'; bad = '#F87171'; badBg = '#3A2626'; info = '#2E2E2E'; panel = '#161B22'; white = '#FFFFFF'; bar = '#FD8EA1'; barSoft = '#6B4450' }
}
$script:Canvas = $null; $script:Pal = $null; $script:Brush = @{}
function Get-B([string]$Key) {
    if (-not $script:Brush.ContainsKey($Key)) {
        $hex = if ($script:Pal.ContainsKey($Key)) { $script:Pal[$Key] } else { $Key }
        $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $script:Brush[$Key] = $b
    }
    $script:Brush[$Key]
}
function Set-Pos($El, [double]$X, [double]$Y) { [Windows.Controls.Canvas]::SetLeft($El, $X); [Windows.Controls.Canvas]::SetTop($El, $Y); [void]$script:Canvas.Children.Add($El) }
function Add-Rect([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Fill = 'card', [string]$Stroke = 'stroke', [double]$Radius = 12, [double]$Thickness = 1, [switch]$Dash) {
    $r = [Windows.Shapes.Rectangle]::new(); $r.Width = $W; $r.Height = $H; $r.RadiusX = $Radius; $r.RadiusY = $Radius
    if ($Fill) { $r.Fill = Get-B $Fill }
    if ($Stroke) { $r.Stroke = Get-B $Stroke; $r.StrokeThickness = $Thickness }
    if ($Dash) { $r.StrokeDashArray = [Windows.Media.DoubleCollection]::new([double[]]@(4, 3)) }
    Set-Pos $r $X $Y
}
function Add-Circle([double]$X, [double]$Y, [double]$D, [string]$Fill = 'accent', [string]$Stroke = '') {
    $e = [Windows.Shapes.Ellipse]::new(); $e.Width = $D; $e.Height = $D
    if ($Fill) { $e.Fill = Get-B $Fill }
    if ($Stroke) { $e.Stroke = Get-B $Stroke; $e.StrokeThickness = 1.5 }
    Set-Pos $e $X $Y
}
function Add-Text([string]$Text, [double]$X, [double]$Y, [double]$Size = 16, [string]$Color = 'text', [string]$Weight = 'Normal', [double]$W = 0, [string]$Align = 'Left') {
    Assert-PublicText $Text
    $t = [Windows.Controls.TextBlock]::new(); $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-B $Color
    $t.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI')
    $t.FontWeight = [Windows.FontWeights]::$Weight
    if ($W -gt 0) { $t.Width = $W; $t.TextWrapping = 'Wrap'; $t.TextAlignment = $Align }
    Set-Pos $t $X $Y
    $t.Measure([Windows.Size]::new(10000, 10000))
    return $t.DesiredSize
}
function Add-Icon([int]$Code, [double]$X, [double]$Y, [double]$Size = 24, [string]$Color = 'accent') {
    $t = [Windows.Controls.TextBlock]::new(); $t.Text = [string][char]$Code; $t.FontSize = $Size; $t.Foreground = Get-B $Color
    $t.FontFamily = [Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
    Set-Pos $t $X $Y
}
function Add-Tile([int]$Code, [double]$X, [double]$Y, [double]$D = 56, [string]$Fill = 'soft', [string]$Color = 'accent') {
    Add-Rect $X $Y $D $D $Fill '' ($D / 4)
    Add-Icon $Code ($X + $D * 0.24) ($Y + $D * 0.2) ($D * 0.5) $Color
}
function Add-Pill([string]$Text, [double]$X, [double]$Y, [string]$Fill = 'okBg', [string]$Ink = 'ok', [double]$Size = 14) {
    $m = [Windows.Controls.TextBlock]::new(); $m.Text = $Text; $m.FontSize = $Size; $m.FontWeight = [Windows.FontWeights]::SemiBold
    $m.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI'); $m.Measure([Windows.Size]::new(10000, 10000))
    $w = $m.DesiredSize.Width + 22; $h = $m.DesiredSize.Height + 8
    Add-Rect $X $Y $w $h $Fill '' ($h / 2)
    [void](Add-Text $Text ($X + 11) ($Y + 4) $Size $Ink 'SemiBold')
    return $w
}
function Add-Badge([string]$Text, [double]$X, [double]$Y, [switch]$Filled, [double]$Size = 15) {
    $m = [Windows.Controls.TextBlock]::new(); $m.Text = $Text; $m.FontSize = $Size
    $m.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI'); $m.Measure([Windows.Size]::new(10000, 10000))
    $w = $m.DesiredSize.Width + 28; $h = $m.DesiredSize.Height + 14
    if ($Filled) { Add-Rect $X $Y $w $h 'accent' '' ($h / 2); [void](Add-Text $Text ($X + 14) ($Y + 7) $Size 'onAccent' 'SemiBold') }
    else { Add-Rect $X $Y $w $h 'card' 'stroke' ($h / 2) 1.2; [void](Add-Text $Text ($X + 14) ($Y + 7) $Size 'text2') }
    return $w
}
function Add-Arrow([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Color = 'text3', [double]$Thickness = 2.5, [switch]$Dash) {
    $l = [Windows.Shapes.Line]::new(); $l.X1 = $X1; $l.Y1 = $Y1; $l.X2 = $X2; $l.Y2 = $Y2; $l.Stroke = Get-B $Color; $l.StrokeThickness = $Thickness
    if ($Dash) { $l.StrokeDashArray = [Windows.Media.DoubleCollection]::new([double[]]@(3, 3)) }
    [void]$script:Canvas.Children.Add($l)
    $ang = [Math]::Atan2($Y2 - $Y1, $X2 - $X1); $s = 11
    $p = [Windows.Shapes.Polygon]::new(); $p.Fill = Get-B $Color
    foreach ($d in 0.45, -0.45) { $p.Points.Add([Windows.Point]::new($X2 - $s * [Math]::Cos($ang + $d), $Y2 - $s * [Math]::Sin($ang + $d))) }
    $p.Points.Add([Windows.Point]::new($X2, $Y2)); [void]$script:Canvas.Children.Add($p)
}
function Add-Line([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Color = 'stroke', [double]$Thickness = 1) {
    $l = [Windows.Shapes.Line]::new(); $l.X1 = $X1; $l.Y1 = $Y1; $l.X2 = $X2; $l.Y2 = $Y2; $l.Stroke = Get-B $Color; $l.StrokeThickness = $Thickness
    [void]$script:Canvas.Children.Add($l)
}
function Add-Card([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Fill = 'card', [string]$Stroke = 'stroke') { Add-Rect $X $Y $W $H $Fill $Stroke 14 1 }
function Add-Step([int]$N, [double]$X, [double]$Y, [double]$D = 44, [string]$Fill = 'accent') {
    Add-Circle $X $Y $D $Fill
    [void](Add-Text ([string]$N) $X ($Y + $D * 0.2) ($D * 0.42) 'white' 'Bold' $D 'Center')
}

function Save-Drawing([string]$Base, [string]$Theme, [int]$W, [int]$H, [int]$PixelWidth = 2160) {
    # The house size of a README picture: 2160 px wide (PraRemoteMailbox, ExchangeLogReport).
    $s = $PixelWidth / [double]$W
    $pxH = [int][Math]::Ceiling($H * $s)
    $c = $script:Canvas; $c.Width = $W; $c.Height = $pxH / $s
    $c.Measure([Windows.Size]::new($W, $c.Height)); $c.Arrange([Windows.Rect]::new(0, 0, $W, $c.Height)); $c.UpdateLayout()
    $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new($PixelWidth, $pxH, 96 * $s, 96 * $s, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($c)
    $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $file = Join-Path $OutDir ('{0}-{1}.png' -f $Base, $Theme)
    $fs = [IO.File]::Create($file); try { $enc.Save($fs) } finally { $fs.Dispose() }
    Write-Host "drawing $([IO.Path]::GetFileName($file))"
}

function Add-Eyebrow([string]$Head, [string]$Rest, [double]$X, [double]$Y) {
    $s = Add-Text $Head $X $Y 18 'accentText' 'Bold'
    [void](Add-Text (' · ' + $Rest) ($X + $s.Width) ($Y + 1) 18 'text2')
}
function Add-Node([int]$Code, [string]$Title, [string]$Sub, [double]$X, [double]$Y, [double]$W, [double]$H = 84) {
    Add-Card $X $Y $W $H
    Add-Tile $Code ($X + 16) ($Y + ($H - 56) / 2) 56
    [void](Add-Text $Title ($X + 92) ($Y + 14) 20 'text' 'SemiBold' ($W - 108))
    [void](Add-Text $Sub ($X + 92) ($Y + 44) 15.5 'text2' 'Normal' ($W - 108))
}
function Add-Label([string]$Text, [double]$X, [double]$Y, [string]$Color = 'accentText') { [void](Add-Text $Text $X $Y 16 $Color 'SemiBold') }

# ---- the drawings -----------------------------------------------------------------------------------------------------------------------------
$drawings = [ordered]@{}

$drawings['readme-why'] = @{ W = 1280; H = 470; Draw = {
        Add-Rect 0 0 1280 470 'bg' '' 0
        $items = @(
            @(0xE8BD, 'Source tenant', ('Chats, channel posts,' + [char]10 + 'reactions, images, files'), 'read only', 'okBg', 'ok'),
            @(0xE8B7, 'Local store and archive', ('Checked and de-duplicated,' + [char]10 + 'readable offline'), 'on your disk', 'okBg', 'ok'),
            @(0xE8BD, 'Target tenant', ('Ghost accounts, then the messages,' + [char]10 + 'authors and dates kept'), 'writes with -Apply', 'warnBg', 'warn'))
        $x = 60
        for ($i = 0; $i -lt 3; $i++) {
            Add-Card $x 60 320 260
            Add-Tile $items[$i][0] ($x + 132) 88 56
            [void](Add-Text $items[$i][1] ($x + 10) 166 23 'text' 'SemiBold' 300 'Center')
            [void](Add-Text $items[$i][2] ($x + 10) 204 17 'text2' 'Normal' 300 'Center')
            [void](Add-Pill $items[$i][3] ($x + 160 - ($items[$i][3].Length * 3.5 + 11)) 276 $items[$i][4] $items[$i][5])
            if ($i -lt 2) { Add-Arrow ($x + 328) 190 ($x + 392) 190 'accent' 4 }
            $x += 400
        }
        [void](Add-Text 'export' 380 156 16 'accentText' 'SemiBold' 80 'Center')
        [void](Add-Text 'import' 780 156 16 'accentText' 'SemiBold' 80 'Center')
        [void](Add-Text 'Made for the long, careful job: years of history, in lots and waves, resumable.' 60 372 22 'text2' 'Normal' 1160 'Center')
        [void](Add-Text 'What you do not re-import stays readable in the offline archive.' 60 410 18 'text3' 'Normal' 1160 'Center')
    } }

$drawings['readme-path'] = @{ W = 1280; H = 560; Draw = {
        Add-Rect 0 0 1280 560 'bg' '' 0
        Add-Rect 10 10 1260 540 'panel' 'stroke' 18 1.5 -Dash
        Add-Icon 0xE713 36 28 20 'accentText'
        [void](Add-Text 'GET READY, ONCE' 66 28 18 'accentText' 'Bold')
        $once = @(@('Get your rights', 'ask your administrator'), @('Put the tool on the PC', 'unzip, then unblock'), @('Fill in the settings file', 'ids and thumbprints'), @('Open the console', 'double-click the .cmd'))
        for ($i = 0; $i -lt 4; $i++) {
            $x = 36 + $i * 305
            Add-Card $x 66 285 80
            Add-Step ($i + 1) ($x + 14) 86 40
            [void](Add-Text $once[$i][0] ($x + 64) 80 18 'text' 'SemiBold' 215)
            [void](Add-Text $once[$i][1] ($x + 64) 108 16 'text2' 'Normal' 215)
            if ($i -lt 3) { Add-Arrow ($x + 289) 106 ($x + 300) 106 'text3' 2 }
        }
        $branches = @(
            @('A', 0xE896, 'Export and read offline', @(@('Estimate and inventory', 'reads only, nothing is changed'), @('Export', '24 months, channels and files'), @('Open the archive', 'offline, by double-click'))),
            @('B', 0xE898, 'Import into a tenant', @(@('Plan a lot', 'a dry run: read plan.html'), @('Ghosts, files, messages', 'a preview first, then -Apply'), @('Verify', 'read verify.html')))
        )
        for ($b = 0; $b -lt 2; $b++) {
            $x = 36 + $b * 620
            Add-Arrow ($x + 295) 154 ($x + 295) 192 'accent' 2
            Add-Rect $x 196 590 70 'accent' '' 16
            Add-Rect $x 201 590 335 'card' 'stroke' 16 1.2
            Add-Rect ($x + 20) 218 44 44 'text' '' 10
            [void](Add-Text $branches[$b][0] ($x + 20) 224 24 'bg' 'Bold' 44 'Center')
            Add-Tile $branches[$b][1] ($x + 76) 218 44 'soft' 'accent'
            [void](Add-Text $branches[$b][2] ($x + 134) 226 22 'text' 'SemiBold' 440)
            for ($i = 0; $i -lt 3; $i++) {
                $y = 296 + $i * 78
                Add-Step ($i + 5) ($x + 24) $y 38
                [void](Add-Text $branches[$b][3][$i][0] ($x + 80) ($y - 2) 18 'text' 'SemiBold' 480)
                [void](Add-Text $branches[$b][3][$i][1] ($x + 80) ($y + 25) 15.5 'text2' 'Normal' 480)
            }
        }
    } }

$drawings['readme-how'] = @{ W = 1280; H = 800; Draw = {
        Add-Rect 0 0 1280 800 'bg' '' 0
        Add-Eyebrow 'ONE TOOL' 'from the source tenant to the reports' 12 8
        Add-Eyebrow 'THE MODES' 'preview by default, -Apply to write' 660 8
        Add-Rect 10 44 630 748 'panel' 'stroke' 18 1.5 -Dash
        $nodes = @(
            @(0xE753, 'Source tenant', 'chats and channels, read with a certificate'),
            @(0xE896, 'Export', 'obeys the throttling, only what changed'),
            @(0xE8B7, 'Local store', 'SQLite catalog, compressed segments, files'),
            @(0xE8A5, 'Archive and plan', 'offline Teams-like archive, lots, dry run'),
            @(0xE753, 'Target tenant', 'ghosts, files, startMigration, messages, completeMigration'),
            @(0xE73E, 'Verify and reports', 'read back, compared with the journal'))
        $links = @('reads only', 'writes locally', 'reads the store', 'with -Apply', 'reads back')
        for ($i = 0; $i -lt 6; $i++) {
            $y = 66 + $i * 124
            Add-Node $nodes[$i][0] $nodes[$i][1] $nodes[$i][2] 36 $y 580 86
            if ($i -lt 5) { Add-Arrow 70 ($y + 90) 70 ($y + 120) 'accent' 2.5; Add-Label $links[$i] 84 ($y + 90) }
        }
        $cards = @(
            @(0xE721, 'Read the source', 'read only', 'okBg', 'ok', 'Estimate, list, export, download the files. Nothing changes in the tenant.', @('Assess', 'Inventory', 'Export', 'Files')),
            @(0xE8B7, 'Work offline', 'local only', 'okBg', 'ok', 'From the store: the archive, the state, the reports, another store folded in.', @('Archive', 'Status', 'Report', 'Merge')),
            @(0xE9D5, 'Prepare and check the target', 'read only', 'okBg', 'ok', 'The plan is a dry run. Verify reads the target back and compares.', @('Plan', 'Verify')),
            @(0xE898, 'Write to the target', 'changes', 'warnBg', 'warn', 'A preview unless you add -Apply. An imported conversation cannot be rolled back.', @('Ghosts', 'CopyFiles', 'Import')))
        for ($i = 0; $i -lt 4; $i++) {
            $y = 44 + $i * 188; $c = $cards[$i]
            Add-Card 660 $y 610 172
            Add-Tile $c[0] 680 ($y + 20) 56
            $s = Add-Text $c[1] 756 ($y + 16) 22 'text' 'SemiBold'
            [void](Add-Pill $c[2] (766 + $s.Width) ($y + 20) $c[3] $c[4])
            [void](Add-Text $c[5] 756 ($y + 54) 16.5 'text2' 'Normal' 490)
            $cx = 756
            foreach ($m in $c[6]) { $cx += (Add-Pill $m $cx ($y + 128) 'info' 'text' 15) + 8 }
        }
    } }

$drawings['readme-principles'] = @{ W = 1280; H = 360; Draw = {
        Add-Rect 0 0 1280 360 'bg' '' 0
        $p = @(@(0xE7B3, 'Preview first', ('Every writing mode is a preview unless you add ' + [char]0x2011 + 'Apply.')),
            @(0xE8FD, 'Nothing is sent twice', 'A journal makes each run idempotent: run it again, only what is left is done.'),
            @(0xE77B, 'The author is kept', 'A deleted author gets one disabled, unlicensed ghost account.'),
            @(0xE895, 'A long job survives', 'Stop, sleep or power cut: run the same command again.'),
            @(0xE73E, 'The result is verified', 'The target is read back chat by chat and compared.'))
        $x = 24
        foreach ($t in $p) {
            Add-Card $x 50 232 260
            Add-Tile $t[0] ($x + 88) 76 56
            [void](Add-Text $t[1] ($x + 12) 150 19 'text' 'SemiBold' 208 'Center')
            [void](Add-Text $t[2] ($x + 16) 214 16 'text2' 'Normal' 200 'Center')
            $x += 248
        }
    } }

$drawings['readme-waves'] = @{ W = 1280; H = 560; Draw = {
        Add-Rect 0 0 1280 560 'bg' '' 0
        Add-Card 40 30 1200 290
        [void](Add-Text 'Lots and waves' 70 48 24 'text' 'SemiBold')
        [void](Add-Text 'How far back each wave reaches, counted in months from today' 70 82 16 'text2')
        $x0 = 100.0; $sc = 1080 / 60.0
        $waves = @(@(0, 24, 'Wave 1', 'the last 24 months', 'bar', 'onAccent'), @(24, 36, 'Wave 2', 'months 25 to 36', 'barSoft', 'text'), @(36, 48, 'Wave 3', 'months 37 to 48', 'barSoft', 'text'), @(48, 60, 'Wave 4', 'months 49 to 60', 'barSoft', 'text'))
        foreach ($w in $waves) {
            $bx = $x0 + $w[0] * $sc; $bw = ($w[1] - $w[0]) * $sc - 4
            Add-Rect $bx 130 $bw 66 $w[4] '' 10
            [void](Add-Text $w[2] ($bx + 8) 136 19 $w[5] 'Bold' ($bw - 16) 'Center')
            [void](Add-Text $w[3] ($bx + 6) 164 15 $w[5] 'Normal' ($bw - 12) 'Center')
        }
        Add-Line $x0 214 ($x0 + 1080) 214 'text3' 1.5
        foreach ($m in 0, 12, 24, 36, 48, 60) {
            Add-Line ($x0 + $m * $sc) 208 ($x0 + $m * $sc) 222 'text3' 1.5
            [void](Add-Text $(if ($m -eq 0) { 'today' } else { "$m" }) ($x0 + $m * $sc - 40) 226 15 'text3' 'Normal' 80 'Center')
        }
        [void](Add-Text 'A finished conversation is reopened with an earlier start date and filled with older messages. Further waves are possible if configured.' 70 262 17 'text2' 'Normal' 1100)
        $c = @(@(0xE916, 'About 5 messages per second', 'per conversation: the limit of the service'), @(0xE9D9, 'About 60 to 90 per second', 'per application, as measured in the lab'), @(0xE81C, 'Weeks or months', 'for years of history: re-import what matters, the rest stays in the archive'))
        $x = 40
        foreach ($t in $c) {
            Add-Card $x 350 385 170
            Add-Tile $t[0] ($x + 20) 370 52
            [void](Add-Text $t[1] ($x + 88) 380 20 'text' 'SemiBold' 280)
            [void](Add-Text $t[2] ($x + 20) 436 16.5 'text2' 'Normal' 345)
            $x += 407.5
        }
    } }

$drawings['readme-permissions'] = @{ W = 1280; H = 790; Draw = {
        Add-Rect 0 0 1280 790 'bg' '' 0
        $perm = Import-PowerShellDataFile -LiteralPath (Join-Path $package 'config\Permissions.psd1')
        $sides = @(
            @{ Title = 'Source app'; Sub = 'read only'; Modes = @('Assess', 'Inventory', 'Export', 'Files'); X = 20; W = 520; Ink = 'ok'; Bg = 'okBg' },
            @{ Title = 'Target app'; Sub = 'reads and writes'; Modes = @('Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify'); X = 560; W = 700; Ink = 'warn'; Bg = 'warnBg' })
        $bottoms = @()
        foreach ($side in $sides) {
            $modes = $side.Modes; $x0 = $side.X
            $names = @($modes | ForEach-Object { @($perm.Modes[$_].Required) + @($perm.Modes[$_].Optional) } | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $h = 120 + $names.Count * 30 + 24
            Add-Card $x0 20 $side.W $h
            $s = Add-Text $side.Title ($x0 + 24) 36 23 'text' 'SemiBold'
            [void](Add-Pill $side.Sub ($x0 + 40 + $s.Width) 40 $side.Bg $side.Ink)
            $nameW = $(if ($modes.Count -eq 4) { 215 } else { 250 }); $cw = ($side.W - 24 - $nameW - 10) / $modes.Count
            for ($i = 0; $i -lt $modes.Count; $i++) {
                [void](Add-Text $modes[$i] ($x0 + 24 + $nameW + $i * $cw) 84 13 'text2' 'SemiBold' $cw 'Center')
            }
            Add-Line ($x0 + 16) 112 ($x0 + $side.W - 16) 112 'stroke' 1
            for ($r = 0; $r -lt $names.Count; $r++) {
                $y = 120 + $r * 30; $n = $names[$r]
                if ($r % 2 -eq 0) { Add-Rect ($x0 + 12) $y ($side.W - 24) 30 'info' '' 6 }
                [void](Add-Text $n ($x0 + 24) ($y + 4) 15 'text' 'Normal' $nameW)
                for ($i = 0; $i -lt $modes.Count; $i++) {
                    $m = $perm.Modes[$modes[$i]]; $cx = $x0 + 24 + $nameW + $i * $cw + $cw / 2 - 8
                    if (@($m.Required | ForEach-Object { $_.Name }) -contains $n) { Add-Circle $cx ($y + 7) 16 'accent' }
                    elseif (@($m.Optional | ForEach-Object { $_.Name }) -contains $n) { Add-Circle $cx ($y + 7) 16 '' 'accent' }
                }
            }
            $bottoms += (20 + $h)
        }
        $ly = $bottoms[0] + 24
        Add-Circle 44 ($ly + 2) 16 'accent'; [void](Add-Text 'required by the mode' 68 $ly 15 'text2')
        Add-Circle 44 ($ly + 34) 16 '' 'accent'; [void](Add-Text 'only for an option of the mode (for instance -IncludeFiles)' 68 ($ly + 32) 15 'text2' 'Normal' 450)
        [void](Add-Text 'Application permissions (Microsoft Graph), with admin consent. A broader permission also satisfies a narrower one: X.ReadWrite.All covers X.Read.All. One certificate per app registration, no secret.' 40 ($ly + 76) 15 'text2' 'Normal' 480)
    } }
$drawings['guide-dictionary'] = @{ W = 1280; H = 470; Draw = {
        Add-Rect 0 0 1280 470 'bg' '' 0
        $w = @(@(0xE8B7, 'Store', 'The folder on your disk where the exported conversations live, checked.'), @(0xE8A5, 'Archive', 'A Teams-like page you open offline, from the store.'),
            @(0xE8FD, 'Lot', 'A list of conversations imported together.'), @(0xE81C, 'Wave', 'A period of a lot: the last 24 months first, older history later.'),
            @(0xE9D5, 'Plan', 'The dry run of an import. Read it, then apply.'), @(0xE77B, 'Ghost account', 'A disabled account that stands for an author who left.'),
            @(0xE8F1, 'Journal', 'The list of every message sent: no message goes twice.'), @(0xE916, 'Throttling', 'Microsoft slows us down. Normal: the tool waits.'))
        for ($i = 0; $i -lt 8; $i++) {
            $x = 30 + ($i % 4) * 305; $y = 30 + [Math]::Floor($i / 4) * 220
            Add-Card $x $y 285 200
            Add-Tile $w[$i][0] ($x + 20) ($y + 22) 52
            [void](Add-Text $w[$i][1] ($x + 20) ($y + 92) 22 'text' 'SemiBold' 250)
            [void](Add-Text $w[$i][2] ($x + 20) ($y + 130) 16 'text2' 'Normal' 250)
        }
    } }

# ---- the README banner (hero): an SVG, the template of the ExchangeLogReport hero (1600 x 490, same coordinates, same sizes) -----------------------
# Same file kind as ExchangeLogReport (readme-banner-light.svg / readme-banner-dark.svg, <picture> in the README). Only the words change; the texts are
# checked for privacy like every picture text, and measured so that a line cannot run into the stat cards (a 12 % margin for a reader without Segoe UI).
$hero = [ordered]@{
    Title    = 'Teams Transfer'
    Eyebrow  = ('TEAMS CHATS AND CHANNELS ' + [char]0xB7 + ' EXPORT, ARCHIVE, IMPORT')
    Sub      = 'Move Teams chats and channels between tenants.'
    Lines    = @('Export to a verified local store, read it offline, import in lots and waves.', 'Ghost accounts keep the original authors; every write is previewed first.')
    Pills    = @("Version $Version", 'PowerShell 7.4+', 'Preview before every write', 'MIT license')
    Footer   = 'Nicolas Fabert / Windows x64'
    Desc     = "Teams Transfer ${Version}: export Teams chats and channels to a verified local store, read them offline, import them into a tenant in lots and waves, with a ghost account for every deleted author, and verify the result."
    Stats    = @(
        @{ N = '13'; Label = 'Modes in one tool'; Sub = 'From estimate to verify' }
        @{ N = '5'; Label = 'Messages per second'; Sub = 'Limit of the service per chat' }
        @{ N = '0'; Label = 'Messages sent twice'; Sub = 'A journal makes runs resumable' }
    )
}
$heroColors = @{
    light = @{ S0 = '#ffffff'; S1 = '#f9eff2'; Line = '#dddddd'; Accent = '#b11f4b'; Ring = '.08'; Text = '#242424'; Text2 = '#535353'; Card = '#ffffff'; OnAccent = '#ffffff' }
    dark  = @{ S0 = '#262626'; S1 = '#46353b'; Line = '#535353'; Accent = '#fd8ea1'; Ring = '.1'; Text = '#f5f5f5'; Text2 = '#d1d1d1'; Card = '#262626'; OnAccent = '#242424' }
}
function Get-HeroTextWidth([string]$Text, [double]$Size, [string]$Weight = 'Normal', [double]$Spacing = 0) {
    $m = [Windows.Controls.TextBlock]::new(); $m.Text = $Text; $m.FontSize = $Size; $m.FontWeight = [Windows.FontWeights]::$Weight
    $m.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'); $m.Measure([Windows.Size]::new(10000, 10000))
    return $m.DesiredSize.Width + $Spacing * $Text.Length
}
function Assert-HeroFits([string]$Text, [double]$Size, [double]$Available, [string]$Weight = 'Normal', [double]$Spacing = 0) {
    $w = (Get-HeroTextWidth $Text $Size $Weight $Spacing) * 1.12
    if ($w -gt $Available) { throw "The banner text '$Text' is too wide ($([int]$w) px for $Available)." }
}
function New-HeroSvg([string]$Theme) {
    $c = $heroColors[$Theme]; $h = $hero
    $all = @($h.Title, $h.Eyebrow, $h.Sub, $h.Footer, $h.Desc) + $h.Lines + $h.Pills + @($h.Stats | ForEach-Object { $_.N; $_.Label; $_.Sub })
    foreach ($s in $all) { Assert-PublicText $s }
    Assert-HeroFits $h.Eyebrow 16 840 'Bold' 2; Assert-HeroFits $h.Title 43 880 'Bold'; Assert-HeroFits $h.Sub 27 990
    foreach ($l in $h.Lines) { Assert-HeroFits $l 23 990 }
    foreach ($s in $h.Stats) { Assert-HeroFits $s.Label 21 320 'SemiBold'; Assert-HeroFits $s.Sub 19 320; Assert-HeroFits $s.N 32 80 'Bold' }
    # the pills: 13 px apart from x = 55, 48 px high; the first one (filled) is 212 px wide as in ExchangeLogReport, the others fit their text
    $x = 55; $pills = [Text.StringBuilder]::new()
    for ($k = 0; $k -lt $h.Pills.Count; $k++) {
        $txt = $h.Pills[$k]
        $w = if ($k -eq 0) { [Math]::Max(212, [int][Math]::Ceiling((Get-HeroTextWidth $txt 19 'SemiBold') + 60)) } else { [int][Math]::Ceiling((Get-HeroTextWidth $txt 19) + 60) }
        $cx = [int]($x + $w / 2)
        if ($k -eq 0) {
            [void]$pills.AppendLine("    <rect x=""$x"" y=""335"" width=""$w"" height=""48"" rx=""24"" fill=""$($c.Accent)""/>")
            [void]$pills.AppendLine("    <text x=""$cx"" y=""365"" text-anchor=""middle"" fill=""$($c.OnAccent)"" font-size=""19"" font-weight=""600"">$txt</text>")
        } else {
            [void]$pills.AppendLine("    <rect x=""$x"" y=""335"" width=""$w"" height=""48"" rx=""24"" fill=""$($c.Card)"" stroke=""$($c.Line)""/>")
            [void]$pills.AppendLine("    <text x=""$cx"" y=""365"" text-anchor=""middle"" fill=""$($c.Text2)"" font-size=""19"">$txt</text>")
        }
        $x += $w + 13
    }
    if ($x - 13 -gt 1040) { throw 'The banner pills run into the stat cards.' }
    $rows = 0..2 | ForEach-Object { 75 + 120 * $_ }
    $cards = ($rows | ForEach-Object { "      <rect x=""1080"" y=""$_"" width=""455"" height=""100"" rx=""22""/>" }) -join "`n"
    $nums = (0..2 | ForEach-Object { "<text x=""1110"" y=""$($rows[$_] + 61)"">$($h.Stats[$_].N)</text>" }) -join ''
    $labels = (0..2 | ForEach-Object { "<text x=""1200"" y=""$($rows[$_] + 44)"">$($h.Stats[$_].Label)</text>" }) -join ''
    $subs = (0..2 | ForEach-Object { "<text x=""1200"" y=""$($rows[$_] + 75)"">$($h.Stats[$_].Sub)</text>" }) -join ''
    @"
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="490" viewBox="0 0 1600 490" role="img" aria-labelledby="title desc">
  <title id="title">$($h.Title)</title>
  <desc id="desc">$($h.Desc)</desc>
  <defs>
    <linearGradient id="surface" x1="0" y1="0" x2="1" y2="1">
      <stop stop-color="$($c.S0)"/><stop offset="1" stop-color="$($c.S1)"/>
    </linearGradient>
    <clipPath id="card"><rect x="10" y="10" width="1580" height="470" rx="26"/></clipPath>
  </defs>
  <rect x="10" y="10" width="1580" height="470" rx="26" fill="url(#surface)" stroke="$($c.Line)" stroke-width="2"/>
  <g clip-path="url(#card)"><circle cx="1430" cy="40" r="235" fill="none" stroke="$($c.Accent)" stroke-opacity="$($c.Ring)" stroke-width="70"/></g>
  <path d="M37 13H1563" stroke="$($c.Accent)" stroke-width="5" stroke-linecap="round"/>
  <g font-family="Segoe UI, Arial, sans-serif">
    <rect x="55" y="55" width="88" height="88" rx="24" fill="$($c.Accent)"/>
    <g fill="none" stroke="$($c.OnAccent)" stroke-width="3.5" stroke-linejoin="round" stroke-linecap="round"><path d="M72 68h34a5 5 0 0 1 5 5v15a5 5 0 0 1-5 5H88l-9 8v-8h-7a5 5 0 0 1-5-5V73a5 5 0 0 1 5-5z"/><path d="M99 106h26a5 5 0 0 1 5 5v12a5 5 0 0 1-5 5h-3v7l-8-7H99a5 5 0 0 1-5-5v-12a5 5 0 0 1 5-5z"/></g>
    <text x="170" y="77" fill="$($c.Accent)" font-size="16" font-weight="700" letter-spacing="2">$($h.Eyebrow)</text>
    <text x="170" y="126" fill="$($c.Text)" font-size="43" font-weight="700">$($h.Title)</text>
    <text x="55" y="205" fill="$($c.Text)" font-size="27">$($h.Sub)</text>
    <text x="55" y="252" fill="$($c.Text2)" font-size="23">$($h.Lines[0])</text>
    <text x="55" y="286" fill="$($c.Text2)" font-size="23">$($h.Lines[1])</text>
$($pills.ToString().TrimEnd())
    <text x="55" y="435" fill="$($c.Text2)" font-size="17">$($h.Footer)</text>
    <g fill="$($c.Card)" stroke="$($c.Line)" stroke-width="2">
$cards
    </g>
    <g fill="$($c.Accent)" font-weight="700" font-size="32">$nums</g>
    <g fill="$($c.Text)" font-size="21" font-weight="600">$labels</g>
    <g fill="$($c.Text2)" font-size="19">$subs</g>
  </g>
</svg>
"@
}
foreach ($theme in 'light', 'dark') {
    if (-not (Test-Wanted "readme-banner-$theme")) { continue }
    $file = Join-Path $OutDir "readme-banner-$theme.svg"
    [IO.File]::WriteAllText($file, ((New-HeroSvg $theme).Replace("`r`n", "`n").TrimEnd() + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Host "banner  $([IO.Path]::GetFileName($file))"
}
foreach ($key in $drawings.Keys) {
    if (-not (Test-Wanted "$key-light")) { continue }
    $d = $drawings[$key]
    foreach ($theme in 'light', 'dark') {
        $script:Pal = $palettes[$theme]; $script:Brush = @{}
        $script:Canvas = [Windows.Controls.Canvas]::new()
        $script:Canvas.Background = Get-B 'bg'
        & $d.Draw
        $pw = if ($d.ContainsKey('PixelWidth')) { $d.PixelWidth } else { 2160 }
        Save-Drawing $key $theme $d.W $d.H $pw
    }
}
