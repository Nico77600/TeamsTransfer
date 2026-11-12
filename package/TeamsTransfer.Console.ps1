# TeamsTransfer - console and log (house style of Mailbox Transfer / PRA Remote Mailbox / Exchange Log Report).
# Dot-sourced by TeamsTransfer.psm1, so every $script: variable below lives in the module scope.
#   - icons: emoji in Windows Terminal and VS Code, characters of the classic console fonts elsewhere; TMT_ICONS = Emoji | Symbols | Ascii forces a style.
#   - colours: none when the output is redirected (a scheduled task) or when NO_COLOR is set. Console colours only, never an ANSI sequence.
#   - every line that matters is also written to the log file (Start-TmtLog), without colours or icons.
#   - numbers, sizes and durations are always shown the en-US way, whatever the culture of the session.
# Normative reference: docs\design\CLI-Conventions.md (chapter 8).

#region 1. Console ---------------------------------------------------------------------------

$script:ToolVersion = '0.1.0'
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

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCpeSuHkeZTPRV+
# 3mdAqgEl8/ej2UxUmFoWlR0u8xVuT6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAVWKBNt/4t
# cICoAYfEDPT6+xiFMlS9okC3PqKMszdBdjANBgkqhkiG9w0BAQEFAASCAgCYZzxf
# 5HJ37/N6Pqx6rgJowI6QC6x0VtOaQVQpG3OhPJft2XAI1jB09nDDu5jfxCDWqPr/
# 939t6Wlnt/mDb/tX4boxjvAvqMJE5RHsFWm0DYPzntDLPrX8upwpuAURXIr9yNir
# exiQmMSCVpEjMcGay01rCzhww7bGdBzYZLGLrh3xKa50w7SYdX2+MCoWVnLYyqVc
# ZeS6mvY5M93IPAWFi7NISYGH3eHV/KbxMpxVxz2cshfsH2YkabcBEPOP62ID5zXL
# GanqkPJQtMwrxtbgZN3ENlK2AUsw3NMN9/On237lBAaE0BiaHmU0Kg4NeJ16rgQD
# HX/aPtM2+HM4eOh7MtoVu4XEKur/4wv4kWt7R9C8+C6GJm0kVw1p7nCKQg5dLgt5
# yZcekbwcrzYfpy6PEzmnq/eeptqCDnzlz7rBiKcR2Ue5zOHDbMCd6hyXDvMGiQ2V
# nPSRYqfpd/+iJr1uvFhrmsh1/YNKBDdIwuNmrzBjM/fLeQ5zNl5MbflVQLIU4nC/
# 7g1jTvndFczMBYxYUnCBZLFlaQUiIrU3wwl3Q1vEC1FXhAW1zG7AwLIih0vE/2ey
# NsDoZ9KmXiGDa57+Wl62sHBHU4LLgB67NnURU8wg8wLMHzhhvCwPOvD+E4IiSuw0
# LoR3t843kpfn4vB/MBRIE8JZVeq2oe3szqAC9KGCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIAp4I/RaUBv4AZQvG4rAE+fL/RinGSNOdCeUIYWLnVy1Aggl8/5R5Rpk
# HhgPMjAyNjExMTExNzU3MDlaMAMCAQECEAM9JpNbgykXGFunGpk9ygegghGnMIIE
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
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMTE3NTcwOVowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIB39
# 86m0sfXrpj1VJZTdRp5OkwJDFObxtjJXAylbgUVqMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiEAva0OW9FDm6BL10GiLNHWQvLYImY/s9vAfIk73q9v6u4CIDQc
# 7nRLhWBdEmHkQYwMizhCdqYrAi6hk1TJ6r1sbf0W
# SIG # End signature block
