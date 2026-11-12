# TeamsTransfer - console and log (house style of Mailbox Transfer / PRA Remote Mailbox / Exchange Log Report).
# Dot-sourced by TeamsTransfer.psm1, so every $script: variable below lives in the module scope.
#   - icons: emoji in Windows Terminal and VS Code, characters of the classic console fonts elsewhere; TMT_ICONS = Emoji | Symbols | Ascii forces a style.
#   - colours: none when the output is redirected (a scheduled task) or when NO_COLOR is set. Console colours only, never an ANSI sequence.
#   - every line that matters is also written to the log file (Start-TmtLog), without colours or icons.
#   - numbers, sizes and durations are always shown the en-US way, whatever the culture of the session.

#region 1. Console ---------------------------------------------------------------------------

$script:ToolVersion = '1.0.2'
$script:ToolAuthor = 'Nicolas Fabert'
$script:EnUs = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$script:LogPath = $null
$script:LogFailed = $false
$script:RunIssues = @{ Warn = [Collections.Generic.List[string]]::new(); Fail = [Collections.Generic.List[string]]::new() }

function Get-TmtIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' { return @{
                Logo = & $u 0x1F4AC; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C; Info = & $u 0x1F539; Skip = & $u 0x23E9
                Plan = & $u 0x1F50E; Mode = & $u 0x1F3AF; Store = & $u 0x1F4BE; Folder = & $u 0x1F4C1; Log = & $u 0x1F4DD; Done = & $u 0x1F389; Clock = & $u 0x23F3
                Chat = & $u 0x1F4AC; Team = & $u 0x1F465; Channel = & $u 0x1F4E2; File = & $u 0x1F4C4; Report = & $u 0x1F4CA; Key = & $u 0x1F510
            } }
        'Symbols' { return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022; Skip = & $u 0x00BB
                Plan = & $u 0x25BA; Mode = & $u 0x25D9; Store = & $u 0x25A0; Folder = & $u 0x2302; Log = & $u 0x00B6; Done = & $u 0x221A; Clock = & $u 0x25CB
                Chat = & $u 0x2194; Team = & $u 0x2192; Channel = '#'; File = & $u 0x25AC; Report = & $u 0x2261; Key = & $u 0x00A7
            } }
        default { return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Plan = '?'; Mode = 'o'; Store = '#'; Folder = '>'; Log = '='; Done = '*'; Clock = '~'
                Chat = '@'; Team = '&'; Channel = '#'; File = '-'; Report = '='; Key = '$'
            } }
    }
}

function Get-TmtFrameSet {
    <# Frame characters: rounded corners, ASCII for the Ascii style. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    if ($Style -eq 'Ascii') { return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' } }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

function Initialize-TmtConsole {
    <#
    .SYNOPSIS
        Chooses the console style (icons, frames, padding) from the environment. Called when the module loads; call it again after changing TMT_ICONS in a test.
    .DESCRIPTION
        TMT_ICONS (Emoji, Symbols or Ascii) wins; otherwise Symbols when the output is redirected, Emoji in Windows Terminal (WT_SESSION) and VS Code,
        Symbols in the classic console. Emoji are never forced in a classic console.
    .OUTPUTS
        The style name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:IconStyle = if ($env:TMT_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:TMT_ICONS }
        elseif ([Console]::IsOutputRedirected) { 'Symbols' }
        elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
        else { 'Symbols' }
    $script:Icons = Get-TmtIconSet $script:IconStyle
    $script:Frame = Get-TmtFrameSet $script:IconStyle
    # The middle dot between facts (banner, warnings in the title): a plain hyphen in the ASCII style.
    $script:Dot = if ($script:IconStyle -eq 'Ascii') { '-' } else { [string][char]0x00B7 }
    # Emoji are two columns wide, symbols one: pad symbols so that the text stays aligned.
    $script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }
    return $script:IconStyle
}

# Console colours of the theme. Accent = frames and step headers.
$script:Theme = @{ Accent = 'Magenta'; Dim = 'DarkGray'; Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red'; Info = 'Cyan' }
[void](Initialize-TmtConsole)

function Get-TmtIcon {
    <# An icon of the current style followed by its padding. Unknown names fall back to Info. #>
    param([Parameter(Mandatory)][string]$Name)
    $icon = $script:Icons[$Name]
    if (-not $icon) { $icon = $script:Icons['Info'] }
    return $icon + $script:IconPad
}

function Write-TmtHost {
    <# One console line in one colour (empty: the console default). Console output only. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Single console writer of the tool.')]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Color)
    if ($Color -and -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Get-TmtDisplayWidth {
    <# Width in console columns of a string that holds at most one emoji (two columns). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($script:IconStyle -ne 'Emoji') { return $Text.Length }
    $extra = 0
    foreach ($m in [regex]::Matches($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]|⚠️|✅|❌|⏩|⏳')) { $extra += $m.Length - 2 }
    return $Text.Length - $extra
}
#endregion

#region 2. Formats (always en-US) ----------------------------------------------------------------

function Format-TmtNumber {
    <#
    .SYNOPSIS
        A whole number with thousands separators, always the same way (en-US): 1,234 and 0.5, never 1 234 or 0,5.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($null -eq $Value) { return '-' }
    return ([long][Math]::Round([double]$Value)).ToString('N0', $script:EnUs)
}

function Format-TmtBytes {
    <#
    .SYNOPSIS
        Bytes as B, KiB, MiB, GiB or TiB with one decimal (en-US).
    #>
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -lt 0) { return '-' }
    $units = 'B', 'KiB', 'MiB', 'GiB', 'TiB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return $Bytes.ToString('0', $script:EnUs) + ' B' }
    return $Bytes.ToString('0.0', $script:EnUs) + ' ' + $units[$i]
}

function Format-TmtDuration {
    <#
    .SYNOPSIS
        Under one second 123 ms, under 120 s 12.3 s, otherwise hh:mm:ss (hours are not wrapped at 24).
    #>
    param([Parameter(Mandatory)][double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 1) { return ($Seconds * 1000).ToString('0', $script:EnUs) + ' ms' }
    if ($Seconds -lt 120) { return $Seconds.ToString('0.0', $script:EnUs) + ' s' }
    $t = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    return '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function Format-TmtRate {
    <#
    .SYNOPSIS
        Throughput in MiB/s (en-US).
    #>
    param([Parameter(Mandatory)][double]$Bytes, [Parameter(Mandatory)][double]$Seconds)
    if ($Seconds -le 0) { return '-' }
    return ($Bytes / 1MB / $Seconds).ToString('0.00', $script:EnUs) + ' MiB/s'
}
#endregion

#region 3. Log -------------------------------------------------------------------------------------

function Start-TmtLog {
    <#
    .SYNOPSIS
        Opens (or continues) today's log file in a folder and deletes the log files older than the retention. Returns the path.
    .DESCRIPTION
        TeamsTransfer_yyyyMMdd.log, one line per message: "2026-11-09 14:03:12.481 [WARN  ] text". The runs of a day append to the
        same file. The log never contains colours, icons or a secret.
    .PARAMETER Directory
        Log folder (created when missing).
    .PARAMETER RetentionDays
        Log files older than this are deleted (default 14).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [ValidateRange(1, 3650)][int]$RetentionDays = 14)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('TeamsTransfer_{0}.log' -f (Get-Date).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture))
    $script:LogFailed = $false
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'TeamsTransfer_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -LT $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    return $script:LogPath
}

function Stop-TmtLog {
    <#
    .SYNOPSIS
        Closes the log (later Write-Tmt* calls write to the console only).
    #>
    $script:LogPath = $null
}

function Get-TmtLogPath {
    <#
    .SYNOPSIS
        The path of the open log file, or nothing.
    #>
    return $script:LogPath
}

function Write-TmtLog {
    <#
    .SYNOPSIS
        One line in the log file only (nothing when no log is open). A log that cannot be written is reported once and never stops a long job.
    #>
    param([ValidateSet('INFO', 'OK', 'WARN', 'FAIL', 'SKIP', 'STEP', 'DETAIL')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if (-not $script:LogPath) { return }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
    $line = '{0} [{1,-6}] {2}' -f $stamp, $Level, ($Message -replace '[\r\n]+', ' | ')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + "`r`n")
    # Several runs (a scheduled task and an operator's Status) append to the same daily log; a reader that does not
    # share write access (backup, antivirus, a viewer) can hold it for a moment: retry briefly before giving up.
    for ($attempt = 1; ; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return
        } catch [System.IO.IOException] {
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (25 * $attempt); continue }
            if (-not $script:LogFailed) { $script:LogFailed = $true; Write-Warning "The log file cannot be written ($($script:LogPath)): $($_.Exception.Message)" }
            return
        } catch {
            if (-not $script:LogFailed) { $script:LogFailed = $true; Write-Warning "The log file cannot be written ($($script:LogPath)): $($_.Exception.Message)" }
            return
        }
    }
}
#endregion

#region 4. Banner, steps, lines, end card --------------------------------------------------------

function Write-TmtBanner {
    <#
    .SYNOPSIS
        Title card at the start of an execution: a rounded frame with the title, the version and the author, an optional subtitle, then one row per detail.
    .PARAMETER Details
        Ordered list of rows: key = label, value = @(IconName, Text) or plain text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle, [System.Collections.Specialized.OrderedDictionary]$Details)
    $F = $script:Frame; $width = 76
    $right = "v$($script:ToolVersion) $($script:Dot) $($script:ToolAuthor)"
    $left = "  $($script:Icons.Logo)  $Title"
    $visible = Get-TmtDisplayWidth $left
    $gap = [Math]::Max(1, $width - $visible - $right.Length - 2)
    Write-Host ''
    Write-TmtHost ('  ' + $F.TopLeft + ([string]$F.Horizontal * $width) + $F.TopRight) $script:Theme.Accent
    Write-TmtHost ('  ' + $F.Vertical + $left + (' ' * $gap) + $right + '  ' + $F.Vertical) $script:Theme.Accent
    if ($Subtitle) {
        $sub = '     ' + $Subtitle
        if ($sub.Length -gt $width) { $sub = $sub.Substring(0, $width) }
        Write-TmtHost ('  ' + $F.Vertical + $sub.PadRight($width) + $F.Vertical) $script:Theme.Accent
    }
    Write-TmtHost ('  ' + $F.BottomLeft + ([string]$F.Horizontal * $width) + $F.BottomRight) $script:Theme.Accent
    Write-TmtLog STEP "=== $Title v$($script:ToolVersion) ==="
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon = '   '; $text = $value
            if ($value -is [array]) { $icon = Get-TmtIcon $value[0]; $text = $value[1] }
            Write-Host ('     {0}{1,-11} {2}' -f $icon, $key, $text)
            Write-TmtLog INFO ('{0}: {1}' -f $key, $text)
        }
    }
}

function Write-TmtStep {
    <#
    .SYNOPSIS
        The title of a phase: an empty line, then "n/N  <icon> Title" in the accent colour; also written to the log.
    #>
    param([Parameter(Mandatory)][string]$Text, [int]$Number, [int]$Total, [string]$Icon = 'Plan')
    $label = if ($Number -gt 0 -and $Total -gt 0) { '{0,5}  ' -f ('{0}/{1}' -f $Number, $Total) } else { '       ' }
    Write-Host ''
    Write-TmtHost ('  ' + $label + (Get-TmtIcon $Icon) + $Text) $script:Theme.Accent
    Write-TmtLog STEP $(if ($Number -gt 0 -and $Total -gt 0) { "[$Number/$Total] $Text" } else { $Text })
}

function Write-TmtItem {
    <#
    .SYNOPSIS
        One indented result line with a status icon (OK, WARN, FAIL, INFO, SKIP), also written to the log. Warnings, failures and skipped lines are coloured.
    #>
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL', 'INFO', 'SKIP')][string]$Status, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    $key = @{ OK = 'Ok'; WARN = 'Warn'; FAIL = 'Fail'; INFO = 'Info'; SKIP = 'Skip' }[$Status]
    $color = switch ($Status) { 'WARN' { $script:Theme.Warn } 'FAIL' { $script:Theme.Fail } 'SKIP' { $script:Theme.Dim } default { '' } }
    Write-TmtHost ('      ' + (Get-TmtIcon $(if ($Icon) { $Icon } else { $key })) + $Text) $color
    Write-TmtLog $Status $Text
    if ($Status -eq 'WARN') { $script:RunIssues.Warn.Add($Text) }
    elseif ($Status -eq 'FAIL') { $script:RunIssues.Fail.Add($Text) }
}

function Write-TmtInfo {
    <#
    .SYNOPSIS
        An information line (Info icon, default colour).
    .PARAMETER Text
        The message.
    .PARAMETER Icon
        Name of another icon of the set (default: the icon of the status).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    Write-TmtItem -Status INFO -Text $Text -Icon $Icon
}
function Write-TmtOk {
    <#
    .SYNOPSIS
        A success line (Ok icon, default colour).
    .PARAMETER Text
        The message.
    .PARAMETER Icon
        Name of another icon of the set (default: the icon of the status).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    Write-TmtItem -Status OK -Text $Text -Icon $Icon
}
function Write-TmtWarn {
    <#
    .SYNOPSIS
        A warning line (Warn icon, yellow). Counted in the end card.
    .PARAMETER Text
        The message.
    .PARAMETER Icon
        Name of another icon of the set (default: the icon of the status).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    Write-TmtItem -Status WARN -Text $Text -Icon $Icon
}
function Write-TmtFail {
    <#
    .SYNOPSIS
        An error line (Fail icon, red). Counted in the end card.
    .PARAMETER Text
        The message.
    .PARAMETER Icon
        Name of another icon of the set (default: the icon of the status).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    Write-TmtItem -Status FAIL -Text $Text -Icon $Icon
}

function Write-TmtDetail {
    <#
    .SYNOPSIS
        A secondary line, indented and dimmed, also written to the log.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-TmtHost "         $Text" $script:Theme.Dim
    Write-TmtLog DETAIL $Text
}

function Format-TmtProgressLine {
    <#
    .SYNOPSIS
        The text of one progress line from an engine ProgressSnapshot (and, when known, the Graph metrics): counts, rate, 429/503, ETA.
    #>
    param([Parameter(Mandatory)]$Snapshot, $Metrics)
    $s = $Snapshot
    $parts = [Collections.Generic.List[string]]::new()
    if ($s.Users) { $parts.Add('users ' + (Format-TmtNumber $s.Users)) }
    if ($s.Conversations) { $parts.Add('chats ' + (Format-TmtNumber $s.Conversations)) }
    if ($s.Teams) { $parts.Add('teams ' + (Format-TmtNumber $s.Teams)) }
    if ($s.Channels) { $parts.Add('channels ' + (Format-TmtNumber $s.Channels)) }
    if ($s.Messages) { $parts.Add(('messages {0} ({1}/s)' -f (Format-TmtNumber $s.Messages), (Format-TmtNumber $s.MessagesPerSecond))) }
    if ($s.FilesDownloaded) { $parts.Add('files ' + (Format-TmtNumber $s.FilesDownloaded)) }
    if ($s.Bytes) { $parts.Add('content ' + (Format-TmtBytes $s.Bytes)) }
    $parts.Add('errors ' + (Format-TmtNumber $s.Errors))
    if ($null -ne $Metrics -and ($Metrics.Throttled429 -or $Metrics.Throttled503)) {
        $parts.Add(('429 {0}, 503 {1}, waited {2}' -f (Format-TmtNumber $Metrics.Throttled429), (Format-TmtNumber $Metrics.Throttled503), (Format-TmtDuration $Metrics.WaitedByServer.TotalSeconds)))
    }
    if ($s.UnitsTotal -gt 0) { $parts.Add(('{0}/{1} units' -f (Format-TmtNumber $s.UnitsDone), (Format-TmtNumber $s.UnitsTotal))) }
    if ($s.Eta) { $parts.Add('ETA ' + (Format-TmtDuration $s.Eta.TotalSeconds)) }
    $phase = if ($s.Phase) { "$($s.Phase): " } else { '' }
    return $phase + ($parts -join ', ')
}

function Write-TmtProgress {
    <#
    .SYNOPSIS
        One progress line of a long job: dimmed, also written to the log (use it every few seconds, not in a tight loop).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, $Metrics)
    Write-TmtDetail (Format-TmtProgressLine -Snapshot $Snapshot -Metrics $Metrics)
}

function Write-TmtSummary {
    <#
    .SYNOPSIS
        Final summary card of a run: a frame in the colour of the outcome (green, yellow, red) with one row per value.
    .PARAMETER Values
        Ordered list: key = label, value = @(IconName, Text) or plain text. A text can be an array (several lines under the same label).
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values, [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok')
    $F = $script:Frame; $width = 76
    $color = $script:Theme[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - (Get-TmtDisplayWidth $head))
    Write-Host ''
    Write-TmtHost ('  ' + $F.TopLeft + $F.Horizontal + $head + ([string]$F.Horizontal * $rest) + $F.TopRight) $color
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon = '   '; $text = $value
        if ($value -is [array] -and $value.Count -eq 2 -and $script:Icons.ContainsKey([string]$value[0])) { $rowIcon = Get-TmtIcon $value[0]; $text = $value[1] }
        $first = $true
        foreach ($line in @($text)) {
            $label = if ($first) { '{0,-11}' -f $key } else { ' ' * 11 }
            Write-Host ('     {0}{1} {2}' -f $(if ($first) { $rowIcon } else { '   ' }), $label, $line)
            Write-TmtLog INFO ('Summary - {0}: {1}' -f $key, $line)
            $first = $false
        }
    }
    Write-TmtHost ('  ' + $F.BottomLeft + ([string]$F.Horizontal * $width) + $F.BottomRight) $color
}

function Get-TmtExitMeaning {
    <#
    .SYNOPSIS
        The words that follow "exit code N" in the end card.
    #>
    param([Parameter(Mandatory)][int]$ExitCode)
    switch ($ExitCode) {
        0 { 'complete' }
        1 { 'failed' }
        2 { 'not complete: nothing was lost, run the same command again to continue' }
        3 { 'uncertain items: settle them before running again (see -Mode Status)' }
        default { 'see the messages above' }
    }
}

function Reset-TmtRunIssues {
    <#
    .SYNOPSIS
        Forgets the warnings and errors counted so far (start of a run).
    #>
    $script:RunIssues.Warn.Clear(); $script:RunIssues.Fail.Clear()
}

function Write-TmtEndCard {
    <#
    .SYNOPSIS
        The card that ends every run (success, resumable stop, failure, plan): outcome colour, result, error, counts, report, log, duration, next command.
    .DESCRIPTION
        Exit code rule: 3 uncertain items, 2 resumable, 1 error, 0 complete. At most two error lines and two warning lines are shown, each cut to
        240 characters. A run that succeeds with warnings is yellow and says how many; its exit code does not change.
    .PARAMETER Counts
        Ordered or plain hashtable of counters, shown as "label value, label value".
    .PARAMETER Planned
        The run only planned (WhatIf or a preview): the title says nothing was written.
    .PARAMETER Report
        Full path of a report or archive produced by the run.
    .PARAMETER Next
        The command to run next, on one copyable line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Failure,
        [System.Collections.IDictionary]$Counts,
        [switch]$Planned,
        [string]$Report,
        [string]$Next,
        [double]$DurationSeconds = -1,
        [string]$StoreRoot
    )
    $warnCount = $script:RunIssues.Warn.Count
    $status = switch ($ExitCode) { 0 { if ($warnCount) { 'Warn' } else { 'Ok' } } 1 { 'Fail' } default { 'Warn' } }
    $title = switch ($ExitCode) { 0 { "$Mode finished" } 1 { "$Mode failed" } default { "$Mode stopped before the end" } }
    if ($Planned -and $ExitCode -eq 0) { $title = "$Mode planned (WhatIf, nothing was written)" }
    if ($ExitCode -eq 0 -and $warnCount) { $title += " $($script:Dot) $warnCount warning(s)" }
    $cut = { param([string]$m) if ($m.Length -gt 240) { $m.Substring(0, 237) + '...' } else { $m } }
    $resultIcon = switch ($ExitCode) { 0 { 'Ok' } 1 { 'Fail' } default { 'Warn' } }
    $values = [ordered]@{ Result = @($resultIcon, "exit code $ExitCode - $(Get-TmtExitMeaning $ExitCode)") }
    if ($Failure) { $values.Error = @('Fail', (& $cut $Failure)) }
    $errs = @($script:RunIssues.Fail | Where-Object { $_ -ne $Failure })
    if ($errs.Count -gt 0) {
        $values.Errors = @('Fail', (@("$($errs.Count) error(s) in total, see the log") + @($errs | Select-Object -First 2 | ForEach-Object { & $cut $_ })))
    }
    if ($warnCount -gt 0) {
        $values.Warnings = @('Warn', (@("$warnCount warning(s) in total, see the log") + @($script:RunIssues.Warn | Select-Object -First 2 | ForEach-Object { & $cut $_ })))
    }
    if ($Counts -and $Counts.Count -gt 0) {
        $parts = @(foreach ($k in $Counts.Keys) { $v = $Counts[$k]; '{0} {1}' -f $k, $(if ($v -is [long] -or $v -is [int]) { Format-TmtNumber $v } else { $v }) })
        $values.Counts = @('Store', ($parts -join ', '))
    } elseif ($StoreRoot) { $values.Store = @('Store', $StoreRoot) }
    if ($Report) { $values.Report = @('Report', $Report) }
    $log = Get-TmtLogPath
    if ($log) { $values.Log = @('Log', $log) }
    if ($DurationSeconds -ge 0) { $values.Duration = @('Clock', (Format-TmtDuration $DurationSeconds)) }
    if ($Next) { $values.Next = @('Plan', $Next) }
    Write-TmtSummary -Title $title -Values $values -Status $status
}
#endregion
