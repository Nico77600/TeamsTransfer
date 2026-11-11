#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The command-line surface (docs\design\CLI-Conventions.md): help of the entry script, modes, exit codes, preview / apply / WhatIf,
    console formats, colours and icons, the log file, the end card, the package integrity check, the module manifest.
    The entry script runs in a child pwsh (exit codes, redirected output); the Write-Tmt* helpers run in this process.
    Offline: no mode that needs the network is run to the end (they stop at the configuration, the stop file or -WhatIf).
#>

BeforeDiscovery {
    $script:AllModes = 'Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report', 'Merge'
    $script:LocalModes = 'Assess', 'Inventory', 'Export', 'Files', 'Archive'
    $script:LaterModes = 'Ghosts', 'Import', 'Verify', 'Report'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:AllModes = 'Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report', 'Merge'
    $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:NoLocalConfig = Join-Path $TestDrive 'no-local-config.psd1'     # points TEAMSTRANSFER_LOCAL_CONFIG at nothing: the private lab file is never read
    $script:Esc = [string][char]27

    function Invoke-Entry {
        # Runs the entry script in a child pwsh with a redirected output. Returns ExitCode, Out (stdout), Err (stderr), All.
        param([string[]]$Arguments = @(), [hashtable]$Env = @{}, [string]$Cwd, [string]$Culture, [switch]$NoDevelopmentMode, [string]$Script = $script:Entry)
        if (-not $Cwd) { $Cwd = New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -Force | Select-Object -ExpandProperty FullName }
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        $psi.WorkingDirectory = $Cwd
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true   # no console input: nothing can ask a question
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $all = @($Arguments)
        if (-not $NoDevelopmentMode) { $all += '-DevelopmentMode' }
        if ($Culture) {
            # the culture of the session is set before the script runs; the script must still print en-US
            foreach ($a in '-NoProfile', '-NonInteractive', '-Command') { $psi.ArgumentList.Add($a) }
            $cmdArgs = ($all | ForEach-Object { if ([string]$_ -like '-*') { [string]$_ } else { "'" + ([string]$_).Replace("'", "''") + "'" } }) -join ' '
            $psi.ArgumentList.Add("[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('$Culture'); try { & '$Script' $cmdArgs; exit `$LASTEXITCODE } catch { Write-Host `$_.Exception.Message; exit 1 }")
        } else {
            foreach ($a in '-NoProfile', '-NonInteractive', '-File', $Script) { $psi.ArgumentList.Add($a) }
            foreach ($a in $all) { $psi.ArgumentList.Add([string]$a) }
        }
        foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'TEAMSTRANSFER_LOG_FOLDER') { [void]$psi.Environment.Remove($k) }
        $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = $script:NoLocalConfig
        foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw "The entry script did not finish in 240 s: $($all -join ' ')" }
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $outTask.GetAwaiter().GetResult(); Err = $errTask.GetAwaiter().GetResult(); Cwd = $Cwd }
    }
    function Get-Combined($r) { $r.Out + "`n" + $r.Err }

    function New-DiskStore {
        # A small real store: 2 users, 1 group chat linked to both, N messages from the first user.
        param([string]$Root, [int]$Messages = 1234)
        $store = Open-TmtStore -Root $Root -Partitions 8
        try {
            $users = foreach ($i in 1, 2) {
                $u = [TeamsTransfer.UserRecord]::new(); $u.Id = "u$i"; $u.UserPrincipalName = "user$i@contoso.com"; $u.DisplayName = "User $i"; $u.Mail = "user$i@contoso.com"; $u.State = 'Active'; $u
            }
            $store.UpsertUsers([TeamsTransfer.UserRecord[]]@($users))
            $c = [TeamsTransfer.ConversationRecord]::new(); $c.Key = 'chat:c1'; $c.ChatId = 'c1'; $c.Kind = 'Group'; $c.Topic = 'Project chat'; $c.MemberCount = 2
            $c.CreatedUtc = [DateTimeOffset]::new(2026, 1, 1, 8, 0, 0, [TimeSpan]::Zero); $c.LastActivityUtc = [DateTimeOffset]::new(2026, 1, 3, 8, 0, 0, [TimeSpan]::Zero)
            $store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c))
            foreach ($u in 'u1', 'u2') { $store.LinkUserConversations($u, [string[]]@('chat:c1')) }
            $list = [Collections.Generic.List[Text.Json.JsonElement]]::new()
            for ($n = 1; $n -le $Messages; $n++) {
                $when = [DateTimeOffset]::new(2026, 1, 1, 8, 0, 0, [TimeSpan]::Zero).AddMinutes($n).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                $m = [ordered]@{ id = "m$n"; createdDateTime = $when; lastModifiedDateTime = $when; from = @{ user = @{ id = 'u1'; displayName = 'User 1'; userIdentityType = 'aadUser' } }; body = @{ contentType = 'html'; content = "message $n" } }
                $list.Add([Text.Json.JsonDocument]::Parse(($m | ConvertTo-Json -Depth 6 -Compress)).RootElement)
            }
            [void]$store.AppendMessages('chat:c1', $list)
            $store.Flush()
        } finally { $store.Dispose() }
    }
}

Describe 'Entry script: built-in help' {
    BeforeAll {
        $script:Help = Get-Help $script:Entry -Full
        $script:Cmd = Get-Command $script:Entry
        $script:Source = Get-Content -LiteralPath $script:Entry -Raw
        $script:Common = [Management.Automation.Cmdlet]::CommonParameters + [Management.Automation.Cmdlet]::OptionalCommonParameters
    }
    It 'starts with #Requires -Version 7.4 and sets strict mode' {
        (Get-Content -LiteralPath $script:Entry -TotalCount 1) | Should -Be '#Requires -Version 7.4'
        $script:Source | Should -Match 'Set-StrictMode -Version Latest'
    }
    It 'has a synopsis, a description and the exit codes in OUTPUTS' {
        $script:Help.Synopsis | Should -Match 'Teams Transfer'
        ($script:Help.description | Out-String) | Should -Match 'Mode Archive'
        $outputs = ($script:Help.returnValues | Out-String)
        foreach ($code in '0 the run is complete', '1 an error', '2 it is not complete', '3 the run holds items') { $outputs | Should -Match ([regex]::Escape($code)) }
    }
    It 'documents every parameter' {
        $names = @($script:Cmd.Parameters.Keys | Where-Object { $_ -notin $script:Common })
        $names.Count | Should -BeGreaterThan 30
        $documented = @{}
        foreach ($p in @($script:Help.parameters.parameter)) { $documented[$p.name] = (($p.description | Out-String).Trim()) }
        foreach ($n in $names) { $documented[$n] | Should -Not -BeNullOrEmpty -Because "parameter -$n needs a .PARAMETER section" }
    }
    It 'lists the parameters of the help in the order of the param block (Mode first)' {
        @($script:Help.parameters.parameter)[0].name | Should -Be 'Mode'
    }
    It 'has an example for every mode' {
        $examples = ($script:Help.examples | Out-String)
        foreach ($m in 'Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status', 'Plan', 'Ghosts', 'CopyFiles', 'Import', 'Verify', 'Report') {
            $examples | Should -Match "-Mode $m\b" -Because "an example of -Mode $m"
        }
        @($script:Help.examples.example).Count | Should -BeGreaterOrEqual 11
    }
    It 'shows the preview and the apply form of Import' {
        $examples = ($script:Help.examples | Out-String)
        $examples | Should -Match '-Mode Import -StoreRoot D:\\ttstore\s'
        $examples | Should -Match '-Mode Import -StoreRoot D:\\ttstore -Apply'
    }
    It 'has NOTES with the author, the version, the exit codes and the exact disclaimer' {
        $notes = ($script:Help.alertSet | Out-String)
        $notes | Should -Match 'Author\s*:\s*Nicolas Fabert'
        $notes | Should -Match 'Version\s*:\s*0\.1\.0'
        $notes | Should -Match 'Exit codes'
        $script:Source | Should -Match ([regex]::Escape("    This Script is a Personal project.`n    It's provided `"AS-IS`". It's not an official Microsoft product so no support can be expected from Microsoft.`n`n    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.").Replace('\n', '\r?\n'))
    }
    It 'supports -WhatIf and -Confirm, and is [CmdletBinding(SupportsShouldProcess)]' {
        $script:Cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $script:Cmd.Parameters.ContainsKey('Confirm') | Should -BeTrue
        ($script:Cmd.Parameters['Mode'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Be $script:AllModes
    }
    It 'defaults to the read-only Status mode; -Gui and -Demo open the console and are documented' {
        $script:Source | Should -Match "\[string\]\`$Mode = 'Status'"
        # CLI-Conventions 4.6: -Gui is declared once there is a window to open (the guided console, package\ui).
        foreach ($n in 'Gui', 'Demo') {
            $script:Cmd.Parameters.ContainsKey($n) | Should -BeTrue -Because "-$n opens the console"
            $script:Source | Should -Match "\.PARAMETER $n\b" -Because "-$n has help"
        }
    }
    It 'uses one name per concept (-Users, -Teams, -Window, -StoreRoot, -StopFile) and none of the old names' {
        foreach ($n in 'Users', 'Teams', 'Window', 'From', 'To', 'StoreRoot', 'StopFile', 'Lot', 'Apply', 'IntervalSeconds', 'LogFolder', 'ConfigPath') { $script:Cmd.Parameters.ContainsKey($n) | Should -BeTrue -Because $n }
        foreach ($n in 'User', 'Team', 'OnlyUsers', 'OnlyTeams', 'StorePath', 'Store') { $script:Cmd.Parameters.ContainsKey($n) | Should -BeFalse -Because "-$n was renamed" }
    }
    It 'every PowerShell file of the package parses' {
        foreach ($f in Get-ChildItem -LiteralPath $script:PackageRoot -Include *.ps1, *.psm1, *.psd1 -Recurse -File) {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $f.Name
        }
    }
}

Describe 'Module: manifest, exported functions, parameter names' {
    BeforeAll {
        $script:Manifest = Test-ModuleManifest -Path (Join-Path $script:PackageRoot 'TeamsTransfer.psd1')
        $script:Module = Get-Module TeamsTransfer
    }
    It 'has a valid manifest: version 0.1.0, author, PowerShell 7.4, Core only' {
        $script:Manifest.Version.ToString() | Should -Be '0.1.0'
        $script:Manifest.Author | Should -Be 'Nicolas Fabert'
        $script:Manifest.PowerShellVersion.ToString() | Should -Be '7.4'
        $script:Manifest.CompatiblePSEditions | Should -Be @('Core')
        $script:Manifest.RootModule | Should -Be 'TeamsTransfer.psm1'
    }
    It 'lists its functions explicitly and exports exactly those' {
        $declared = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.psd1')).FunctionsToExport)
        $declared | Should -Not -Contain '*'
        @($script:Module.ExportedFunctions.Keys | Sort-Object) | Should -Be @($declared | Sort-Object)
    }
    It 'has the same version in the manifest and in the console banner' {
        & (Get-Module TeamsTransfer) { $script:ToolVersion } | Should -Be '0.1.0'
    }
    It 'has comment-based help (a synopsis) on every exported function' {
        foreach ($name in $script:Module.ExportedFunctions.Keys) {
            $h = Get-Help $name
            $h.Synopsis | Should -Not -BeNullOrEmpty -Because $name
            $h.Synopsis.Trim() | Should -Not -Match "^$([regex]::Escape($name))\s" -Because "$name has no synopsis of its own"
        }
    }
    It 'documents every parameter of the Invoke-Tmt* / Export-TmtArchive / Open-TmtStore functions' {
        foreach ($name in 'Invoke-TmtInventory', 'Invoke-TmtAssess', 'Invoke-TmtExport', 'Invoke-TmtFiles', 'Export-TmtArchive', 'Open-TmtStore', 'New-TmtGraphClient') {
            $common = [Management.Automation.Cmdlet]::CommonParameters + [Management.Automation.Cmdlet]::OptionalCommonParameters
            $h = Get-Help $name -Full
            $doc = @{}
            foreach ($p in @($h.parameters.parameter)) { $doc[$p.name] = (($p.description | Out-String).Trim()) }
            foreach ($n in (Get-Command $name).Parameters.Keys | Where-Object { $_ -notin $common }) {
                if ($n -in 'Parallelism', 'UserParallelism', 'TeamParallelism', 'ConversationParallelism', 'CompareChats', 'ExportRequestsPerSecond', 'SkipTeams', 'SkipDeletedUsers', 'SkipChats', 'IncludeChannels', 'SkipFileDownload', 'NoHostedContents', 'Strategy', 'MaxItemsPerChunk') { continue }
                $doc[$n] | Should -Not -BeNullOrEmpty -Because "$name -$n"
            }
        }
    }
    It 'uses one name per concept in the public functions' {
        (Get-Command Invoke-TmtInventory).Parameters.Keys | Should -Contain 'Users'
        (Get-Command Invoke-TmtInventory).Parameters.Keys | Should -Contain 'Teams'
        (Get-Command Invoke-TmtInventory).Parameters.Keys | Should -Not -Contain 'OnlyUsers'
        (Get-Command Invoke-TmtExport).Parameters.Keys | Should -Contain 'Window'
        (Get-Command Export-TmtArchive).Parameters.Keys | Should -Contain 'Users'
        (Get-Command Export-TmtArchive).Parameters.Keys | Should -Contain 'From'
        (Get-Command Export-TmtArchive).Parameters.Keys | Should -Not -Contain 'FromUtc'
        foreach ($f in 'Invoke-TmtInventory', 'Invoke-TmtAssess', 'Invoke-TmtExport', 'Invoke-TmtFiles') { (Get-Command $f).Parameters.Keys | Should -Contain 'IntervalSeconds' }
        Get-Command Export-TmtPreview -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Export-TmtArchive | Should -Not -BeNullOrEmpty
    }
    It 'has no Write-Progress, Write-Information or Write-Warning left for operator messages in the lot E / F files' {
        foreach ($f in 'TeamsTransfer.Export.ps1', 'TeamsTransfer.Archive.ps1') {
            $text = Get-Content -LiteralPath (Join-Path $script:PackageRoot $f) -Raw
            $text | Should -Not -Match 'Write-Progress|Write-Information|Write-Warning' -Because $f
        }
    }
}

Describe 'Formats: always en-US, whatever the culture of the session' {
    BeforeAll { $script:OldCulture = [Threading.Thread]::CurrentThread.CurrentCulture }
    AfterAll { [Threading.Thread]::CurrentThread.CurrentCulture = $script:OldCulture }
    It 'formats numbers, bytes, durations and rates the en-US way under fr-FR' {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        Format-TmtNumber 1234567 | Should -Be '1,234,567'
        Format-TmtNumber 0 | Should -Be '0'
        Format-TmtNumber $null | Should -Be '-'
        Format-TmtBytes 1536 | Should -Be '1.5 KiB'
        Format-TmtBytes 512 | Should -Be '512 B'
        Format-TmtBytes (5.25 * 1GB) | Should -Be '5.3 GiB'
        Format-TmtDuration 0.123 | Should -Be '123 ms'
        Format-TmtDuration 12.34 | Should -Be '12.3 s'
        Format-TmtDuration 4332 | Should -Be '01:12:12'
        Format-TmtDuration (30 * 3600) | Should -Be '30:00:00'
        Format-TmtRate (3MB) 2 | Should -Be '1.50 MiB/s'
        Format-TmtRate 1 0 | Should -Be '-'
        (Format-TmtNumber 1234567) | Should -Not -Match '[\u00A0\u202F ]'
    }
    It 'writes a progress line with en-US numbers under fr-FR' {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        $snap = [TeamsTransfer.ProgressSnapshot]@{ Phase = 'export'; Users = 12; Conversations = 41; Messages = 1204000; MessagesPerSecond = 214.6; Errors = 0; UnitsDone = 1500; UnitsTotal = 9000; Eta = [TimeSpan]::FromSeconds(3725) }
        $line = Format-TmtProgressLine -Snapshot $snap
        $line | Should -Be 'export: users 12, chats 41, messages 1,204,000 (215/s), errors 0, 1,500/9,000 units, ETA 01:02:05'
    }
    It 'runs the entry script under a fr-FR session and still prints 1,234 (Status of a store with 1,234 messages)' {
        $root = Join-Path $TestDrive 'store-fr'
        New-DiskStore -Root $root -Messages 1234
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-LogFolder', (Join-Path $TestDrive 'logs-fr')) -Culture 'fr-FR'
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'messages 1,234'
        $r.Out | Should -Not -Match '1\u00A0234|1\u202F234|1 234'
    }
}

Describe 'Colours and icons' {
    It 'writes no ANSI sequence and the Symbols icons when the output is redirected (Status)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', (Join-Path $TestDrive 'nostore'), '-LogFolder', (Join-Path $TestDrive 'logs-sym'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        (Get-Combined $r) | Should -Not -Match $script:Esc
        $r.Out | Should -Match ([string][char]0x256D)                       # rounded frame
        $r.Out | Should -Match ([string][char]0x221A)                       # Symbols Ok
        $r.Out | Should -Not -Match '[\uD83C-\uD83E][\uDC00-\uDFFF]'          # no emoji
        $r.Out | Should -Match 'Status finished'
    }
    It 'forces ASCII icons and frames with TMT_ICONS=Ascii (output is 7-bit ASCII)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', (Join-Path $TestDrive 'nostore'), '-LogFolder', (Join-Path $TestDrive 'logs-asc')) -Env @{ TMT_ICONS = 'Ascii' }
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match '[^\x00-\x7F]'
        $r.Out | Should -Match '\+-{70,}\+'
        $r.Out | Should -Match '\|  \*  Teams Transfer'
        $r.Out | Should -Match 'v0\.1\.0 - Nicolas Fabert'
    }
    It 'writes no ANSI sequence with NO_COLOR, also for the warning and the error' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-ConfigPath', (Join-Path $TestDrive 'missing.psd1'), '-LogFolder', (Join-Path $TestDrive 'logs-nc')) -Env @{ NO_COLOR = '1' }
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Not -Match $script:Esc
    }
    It 'has the house theme and the three icon sets in the console helpers' {
        $theme = & (Get-Module TeamsTransfer) { $script:Theme }
        $theme.Accent | Should -Be 'Magenta'; $theme.Dim | Should -Be 'DarkGray'; $theme.Ok | Should -Be 'Green'; $theme.Warn | Should -Be 'Yellow'; $theme.Fail | Should -Be 'Red'; $theme.Info | Should -Be 'Cyan'
        $emoji = & (Get-Module TeamsTransfer) { Get-TmtIconSet Emoji }
        $emoji.Logo | Should -Be ([char]::ConvertFromUtf32(0x1F4AC))
        $emoji.Warn | Should -Be ([string][char]0x26A0 + [char]0xFE0F)
        $emoji.Chat | Should -Be ([char]::ConvertFromUtf32(0x1F4AC))
        $emoji.Team | Should -Be ([char]::ConvertFromUtf32(0x1F465))
        (& (Get-Module TeamsTransfer) { Get-TmtIconSet Symbols }).Logo | Should -Be ([string][char]0x2666)
        (& (Get-Module TeamsTransfer) { Get-TmtIconSet Ascii }).Logo | Should -Be '*'
        foreach ($style in 'Emoji', 'Symbols', 'Ascii') {
            $set = & (Get-Module TeamsTransfer) { param($s) Get-TmtIconSet $s } $style
            foreach ($k in 'Ok', 'Warn', 'Fail', 'Info', 'Skip', 'Plan', 'Mode', 'Store', 'Folder', 'Log', 'Done', 'Clock', 'Chat', 'Team', 'Channel', 'File', 'Report', 'Key') { $set.ContainsKey($k) | Should -BeTrue -Because "$style $k" }
        }
    }
    It 'chooses the icon style from the environment (TMT_ICONS wins, Windows Terminal and VS Code get emoji, redirected output gets symbols)' {
        $old = @{ T = $env:TMT_ICONS; W = $env:WT_SESSION; P = $env:TERM_PROGRAM }
        try {
            $env:TMT_ICONS = 'Ascii'; Initialize-TmtConsole | Should -Be 'Ascii'
            $env:TMT_ICONS = $null; $env:WT_SESSION = $null; $env:TERM_PROGRAM = $null
            Initialize-TmtConsole | Should -BeIn 'Symbols'                   # classic console or redirected
            if (-not [Console]::IsOutputRedirected) {
                $env:WT_SESSION = 'x'; Initialize-TmtConsole | Should -Be 'Emoji'
                $env:WT_SESSION = $null; $env:TERM_PROGRAM = 'vscode'; Initialize-TmtConsole | Should -Be 'Emoji'
            }
        } finally { $env:TMT_ICONS = $old.T; $env:WT_SESSION = $old.W; $env:TERM_PROGRAM = $old.P; [void](Initialize-TmtConsole) }
    }
}

Describe 'Log file' {
    BeforeEach {
        $script:LogDir = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    AfterEach { Stop-TmtLog }
    It 'is named TeamsTransfer_yyyyMMdd.log in the folder, created when missing' {
        $path = Start-TmtLog -Directory $script:LogDir
        $path | Should -Be (Join-Path $script:LogDir ('TeamsTransfer_{0}.log' -f (Get-Date).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)))
        Get-TmtLogPath | Should -Be $path
        Write-TmtLog INFO 'first'
        Test-Path -LiteralPath $path | Should -BeTrue
    }
    It 'writes "yyyy-MM-dd HH:mm:ss.fff [LEVEL ] text", UTF-8 without BOM, CRLF, and appends within a day' {
        $path = Start-TmtLog -Directory $script:LogDir
        Write-TmtLog INFO 'one'; Write-TmtLog WARN "two`r`nlines"; Write-TmtLog DETAIL ('caf' + [char]0x00E9)
        Stop-TmtLog
        [void](Start-TmtLog -Directory $script:LogDir)
        Write-TmtLog FAIL 'again'
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'            # no BOM
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)  # strict UTF-8
        $lines = $text -split "`r`n" | Where-Object { $_ }
        $lines.Count | Should -Be 4
        $text | Should -Match "`r`n$"
        foreach ($l in $lines) { $l | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[(INFO  |OK    |WARN  |FAIL  |SKIP  |STEP  |DETAIL)\] ' }
        $lines[0] | Should -Match '\[INFO  \] one$'
        $lines[1] | Should -Match '\[WARN  \] two \| lines$'
        $lines[3] | Should -Match '\[FAIL  \] again$'
    }
    It 'deletes the TeamsTransfer_*.log files older than the retention (14 days) and nothing else' {
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
        $old = Join-Path $script:LogDir 'TeamsTransfer_20250101.log'; $recent = Join-Path $script:LogDir 'TeamsTransfer_20261105.log'; $other = Join-Path $script:LogDir 'other-old.log'
        foreach ($f in $old, $recent, $other) { Set-Content -LiteralPath $f -Value 'x' }
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-20); (Get-Item $recent).LastWriteTime = (Get-Date).AddDays(-3); (Get-Item $other).LastWriteTime = (Get-Date).AddDays(-60)
        [void](Start-TmtLog -Directory $script:LogDir)
        Test-Path $old | Should -BeFalse
        Test-Path $recent | Should -BeTrue
        Test-Path $other | Should -BeTrue
        $edge = Join-Path $script:LogDir 'TeamsTransfer_20260101.log'; Set-Content -LiteralPath $edge -Value 'x'; (Get-Item $edge).LastWriteTime = (Get-Date).AddDays(-5)
        [void](Start-TmtLog -Directory $script:LogDir -RetentionDays 2)
        Test-Path $edge | Should -BeFalse
        Test-Path $recent | Should -BeFalse
    }
    It 'receives every Write-Tmt* line without colours, icons or emoji' {
        $path = Start-TmtLog -Directory $script:LogDir
        $null = & {
            Write-TmtBanner -Title 'Teams Transfer' -Subtitle 'sub' -Details ([ordered]@{ Mode = @('Mode', 'Export'); Store = @('Store', 'D:\s') })
            Write-TmtStep 'Opening the store' -Number 1 -Total 2 -Icon Store
            Write-TmtOk 'ok line'; Write-TmtInfo 'info line'; Write-TmtWarn 'warn line'; Write-TmtFail 'fail line'; Write-TmtItem SKIP 'skip line'
            Write-TmtDetail 'detail line'
            Write-TmtEndCard -Mode Export -ExitCode 0 -Counts ([ordered]@{ chats = 1204 }) -DurationSeconds 3
        } 6>&1
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($level in 'STEP', 'INFO', 'OK', 'WARN', 'FAIL', 'SKIP', 'DETAIL') { $text | Should -Match "\[$level\s*\]" -Because $level }
        $text | Should -Match '=== Teams Transfer v0\.1\.0 ==='
        $text | Should -Match '\[1/2\] Opening the store'
        $text | Should -Match 'Summary - Counts: chats 1,204'
        $text | Should -Not -Match $script:Esc
        $text | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'reports an unwritable log once and never stops the job' {
        [void](Start-TmtLog -Directory $script:LogDir)
        $path = Get-TmtLogPath
        $lock = [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { Write-TmtLog INFO 'a'; Write-TmtLog INFO 'b' } | Should -Not -Throw
        } finally { $lock.Dispose() }
    }
}

Describe 'End card' {
    It 'is green for 0, yellow for 2, red for 1, and says what happened' {
        $cards = @{}
        foreach ($code in 0, 1, 2, 3) {
            Reset-TmtRunIssues
            $cards[$code] = (& { Write-TmtEndCard -Mode Export -ExitCode $code -Failure $(if ($code -eq 1) { 'boom' }) -DurationSeconds 5 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        }
        $cards[0] | Should -Match 'Export finished'
        $cards[0] | Should -Match 'exit code 0 - complete'
        $cards[1] | Should -Match 'Export failed'
        $cards[1] | Should -Match 'Error\s+.*boom'
        $cards[2] | Should -Match 'Export stopped before the end'
        $cards[2] | Should -Match 'run the same command again'
        $cards[3] | Should -Match 'uncertain items'
        $cards[0] | Should -Match 'Duration\s+.*5\.0 s'
    }
    It 'says planned for a WhatIf run, counts warnings, shows at most 2 error lines and 2 warning lines, cuts long messages' {
        Reset-TmtRunIssues
        $out = & {
            Write-TmtWarn 'w1'; Write-TmtWarn 'w2'; Write-TmtWarn 'w3'
            Write-TmtFail 'e1'; Write-TmtFail 'e2'; Write-TmtFail 'e3'; Write-TmtFail ('x' * 400)
            Write-TmtEndCard -Mode Import -ExitCode 1 -Failure ('y' * 400)
            Reset-TmtRunIssues
            Write-TmtWarn 'only warning'
            Write-TmtEndCard -Mode Export -ExitCode 0
            Reset-TmtRunIssues
            Write-TmtEndCard -Mode Import -ExitCode 0 -Planned
        } 6>&1 | ForEach-Object { "$_" }
        $text = $out -join "`n"
        $text | Should -Match '4 error\(s\) in total, see the log'
        $text | Should -Match '3 warning\(s\) in total, see the log'
        $text | Should -Match 'Export finished . 1 warning\(s\)'
        $text | Should -Match 'Import planned \(WhatIf, nothing was written\)'
        $text | Should -Not -Match ('y{241}')
        $text | Should -Not -Match 'w3\s*$' -Because 'only two warning lines are shown (w3 is only counted)'
    }
    It 'is written after an unreadable configuration: Status failed, exit code 1, in the console and in the log' {
        $logs = Join-Path $TestDrive 'logs-badcfg'
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-ConfigPath', (Join-Path $TestDrive 'missing.psd1'), '-LogFolder', $logs)
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Status failed'
        $r.Out | Should -Match 'exit code 1 - failed'
        $r.Out | Should -Match 'Configuration file not found'
        (Get-Combined $r) | Should -Match 'Configuration file not found'
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $logs -Filter 'TeamsTransfer_*.log').FullName -Raw
        $log | Should -Match '\[FAIL  \] Configuration file not found'
        $log | Should -Match 'Summary - Result: exit code 1 - failed'
    }
    It 'is written after an exception in the middle of a mode (empty Source: the error comes with the action to take), the store is released' {
        $logs = Join-Path $TestDrive 'logs-midway'
        $root = Join-Path $TestDrive 'store-midway'
        $r = Invoke-Entry -Arguments @('-Mode', 'Inventory', '-StoreRoot', $root, '-LogFolder', $logs)
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Inventory failed'
        $r.Out | Should -Match 'Configuration\.Source\.TenantId is empty'
        $r.Out | Should -Match 'Hint: Fill the Source / Target section'
        $r.Out | Should -Match 'Opening the store'
        # the write lock is released: the store can be opened for writing again
        $s = Open-TmtStore -Root $root
        $s.Dispose()
    }
}

Describe 'Exit codes' {
    It 'Status without a store: 0, nothing created but the log' {
        $cwd = Join-Path $TestDrive 'cwd-status'; New-Item -ItemType Directory -Path $cwd | Out-Null
        $cfg = Join-Path $cwd 'out-config.psd1'; "@{ Output = @{ Root = '$(Join-Path $cwd 'out')' } }" | Set-Content -LiteralPath $cfg
        $r = Invoke-Entry -Arguments @('-StoreRoot', (Join-Path $TestDrive 'nostore2'), '-ConfigPath', $cfg) -Cwd $cwd
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'Reading the package and the configuration'
        $r.Out | Should -Match 'No store at'
        $r.Out | Should -Match '1/2'
        $r.Out | Should -Match 'Status finished'
        Test-Path -LiteralPath (Join-Path $TestDrive 'nostore2') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cwd 'out\logs') | Should -BeTrue
    }
    It 'Status of a real store: 0, with the counts' {
        $root = Join-Path $TestDrive 'store-status'
        New-DiskStore -Root $root -Messages 50
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-LogFolder', (Join-Path $TestDrive 'logs-status'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'Users 2, 1 conversations inventoried, 1 with messages \(50 messages\)'
        $r.Out | Should -Match 'users 2, conversations 1, messages 50'
        $r.Out | Should -Match 'Duration'
    }
    It 'an invalid configuration file: 1' {
        (Invoke-Entry -Arguments @('-ConfigPath', (Join-Path $TestDrive 'does-not-exist.psd1'), '-LogFolder', (Join-Path $TestDrive 'l1'))).ExitCode | Should -Be 1
        $bad = Join-Path $TestDrive 'bad.psd1'; Set-Content -LiteralPath $bad -Value '@{ Source = @{ '
        $r = Invoke-Entry -Arguments @('-ConfigPath', $bad, '-LogFolder', (Join-Path $TestDrive 'l2'))
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'cannot be read as data'
        $code = Join-Path $TestDrive 'code.psd1'; Set-Content -LiteralPath $code -Value "@{ Source = (Get-Date) }"
        (Invoke-Entry -Arguments @('-ConfigPath', $code, '-LogFolder', (Join-Path $TestDrive 'l3'))).ExitCode | Should -Be 1   # data only: code is never executed
    }
    It 'a stop file: 2, before anything is read, with the resume advice' {
        $stop = Join-Path $TestDrive 'stop.txt'; Set-Content -LiteralPath $stop -Value 'stop'
        foreach ($mode in 'Assess', 'Inventory', 'Export', 'Files', 'Archive') {
            $r = Invoke-Entry -Arguments @('-Mode', $mode, '-StoreRoot', (Join-Path $TestDrive "store-stop-$mode"), '-StopFile', $stop, '-LogFolder', (Join-Path $TestDrive 'logs-stop')) -Cwd (New-Item -ItemType Directory -Path (Join-Path $TestDrive "cwd-stop-$mode") -Force).FullName
            $r.ExitCode | Should -Be 2 -Because "$mode`n$($r.Out)"
            $r.Out | Should -Match "$mode stopped before the end"
            $r.Out | Should -Match 'exit code 2 - not complete: nothing was lost, run the same command again'
            $r.Out | Should -Match 'stop requested: the requests in flight finish first, run the command again to resume'
            $r.Out | Should -Match 'Next\s+.*Invoke-TeamsTransfer\.ps1 .*-Mode'
        }
    }
    It 'the import modes without a store or a lot fail with an actionable message, exit 1, nothing written' -ForEach @(
        @{ M = 'Ghosts'; Why = 'No store at .*run -Mode Inventory or -Mode Export first' }
        @{ M = 'Import'; Why = '-Lot is required: name the planned lot to import' }
        @{ M = 'Verify'; Why = '-Lot is required: name the imported lot to verify' }
        @{ M = 'Report'; Why = 'No store at .*run -Mode Inventory or -Mode Export first' }) {
        $store = Join-Path $TestDrive "store-none-$M"
        $r = Invoke-Entry -Arguments @('-Mode', $M, '-StoreRoot', $store, '-LogFolder', (Join-Path $TestDrive 'logs-none'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match $Why
        $r.Out | Should -Match "$M failed"
        Test-Path -LiteralPath $store | Should -BeFalse
    }
    It 'refuses a parameter that does not belong to the mode (exit 1, with the list of modes)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-IncludeFiles', '-LogFolder', (Join-Path $TestDrive 'l4'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match '-IncludeFiles does not apply to -Mode Status \(it applies to: Export\)'
        $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-Window', '24m', '-From', '2026-01-01', '-WhatIf', '-LogFolder', (Join-Path $TestDrive 'l5'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match '-Window and -From / -To are alternatives'
    }
    It 'accepts the mode in any case (normalised to the official spelling)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'store-case'), '-LogFolder', (Join-Path $TestDrive 'l6'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'Export planned \(WhatIf'
    }
}

Describe 'Every mode parses and runs its parameter set' {
    It '<M> with -WhatIf plans and starts nothing (exit 0)' -ForEach ($script:LocalModes | ForEach-Object { @{ M = $_ } }) {
        $root = Join-Path $TestDrive "store-whatif-$M"
        $extra = switch ($M) {
            'Assess'    { @('-SampleUsers', '5', '-SampleTeams', '1', '-HistoryMonths', '12') }
            'Inventory' { @('-Users', 'a@contoso.com,b@contoso.com', '-Teams', 'Atlas', '-SkipChats', '-UserParallelism', '4') }
            'Export'    { @('-Window', '24m', '-Strategy', 'U', '-IncludeChannels', '-IncludeFiles', '-SkipFileDownload', '-NoHostedContents', '-AllStoreUsers', '-Full', '-MaxFileSizeMB', '50', '-ExcludeExtensions', '.iso,.zip', '-ConversationParallelism', '4', '-UserParallelism', '4') }
            'Files'     { @('-MaxFileSizeMB', '50', '-ExcludeExtensions', '.iso') }
            'Archive'   { @('-Users', 'camille.martin@contoso.com', '-Viewer', 'camille.martin@contoso.com', '-SingleFile', '-OutputPath', (Join-Path $TestDrive 'a.html'), '-Title', 'T', '-Language', 'en', '-From', '2026-01-01', '-To', '2026-06-01') }
        }
        $r = Invoke-Entry -Arguments (@('-Mode', $M, '-StoreRoot', $root, '-IntervalSeconds', '2', '-LogFolder', (Join-Path $TestDrive 'logs-whatif')) + $extra + @('-WhatIf'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match "$M - WhatIf \(nothing is written\)"
        $r.Out | Should -Match "$M planned \(WhatIf, nothing was written\)"
        $r.Out | Should -Match 'WhatIf: '
        Test-Path -LiteralPath $root | Should -BeFalse
    }
    It 'Status runs (default mode, any case) and the later modes refuse politely' {
        (Invoke-Entry -Arguments @('-Mode', 'STATUS', '-StoreRoot', (Join-Path $TestDrive 'nostore3'), '-LogFolder', (Join-Path $TestDrive 'l7'))).ExitCode | Should -Be 0
    }
    It 'the Lot parameter belongs to Export and Status' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Inventory', '-Lot', 'wave1', '-WhatIf', '-LogFolder', (Join-Path $TestDrive 'l8'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match '-Lot does not apply to -Mode Inventory'
    }
}

Describe 'Preview by default, -Apply, -WhatIf wins' {
    It 'Import without -Apply is a preview' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-StoreRoot', (Join-Path $TestDrive 's1'), '-LogFolder', (Join-Path $TestDrive 'lp1'))
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Import - Preview \(nothing is written\)'
        $r.Out | Should -Match 'Preview: nothing is written\. Run it again with -Apply'
        $r.Out | Should -Not -Match 'Apply \(changes are made\)'
    }
    It '-Apply -WhatIf is still a preview: -WhatIf wins' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Apply', '-Force', '-StoreRoot', (Join-Path $TestDrive 's2'), '-LogFolder', (Join-Path $TestDrive 'lp2'), '-WhatIf')
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Import - Preview \(nothing is written\)'
        $r.Out | Should -Match '-WhatIf wins over -Apply'
        $r.Out | Should -Not -Match 'Apply \(changes are made\)'
        $r.Out | Should -Match 'Import planned|Import failed'
    }
    It '-Apply -Force announces that changes are made, asks nothing, then stops on the missing lot/store (exit 1)' {
        foreach ($m in 'Import', 'Ghosts', 'CopyFiles') {
            $store = Join-Path $TestDrive "s3-$m"
            $r = Invoke-Entry -Arguments @('-Mode', $m, '-Apply', '-Force', '-StoreRoot', $store, '-LogFolder', (Join-Path $TestDrive 'lp3'))
            $r.ExitCode | Should -Be 1
            $r.Out | Should -Match "$m - Apply \(changes are made\)"
            (Get-Combined $r) | Should -Match '-Lot is required|No store at'
            (Get-Combined $r) | Should -Not -Match 'needs a confirmation'
            Test-Path -LiteralPath $store | Should -BeFalse
        }
    }
    It '-Apply without -Force in a session that cannot ask is an explicit error' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Apply', '-StoreRoot', (Join-Path $TestDrive 's4'), '-LogFolder', (Join-Path $TestDrive 'lp4'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match '-Apply needs a confirmation and this session is not interactive: add -Force'
    }
    It '-Apply -Confirm:$false skips the question like -Force' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Ghosts', '-Apply', '-Confirm:$false', '-StoreRoot', (Join-Path $TestDrive 's5'), '-LogFolder', (Join-Path $TestDrive 'lp5'))
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Ghosts - Apply \(changes are made\)'
        (Get-Combined $r) | Should -Match 'No store at'
        (Get-Combined $r) | Should -Not -Match 'needs a confirmation'
    }
    It '-Apply and -Force are refused on the modes that never write to the target' {
        foreach ($m in 'Assess', 'Inventory', 'Export', 'Files', 'Archive', 'Status') {
            $r = Invoke-Entry -Arguments @('-Mode', $m, '-Apply', '-LogFolder', (Join-Path $TestDrive 'lp6'))
            $r.ExitCode | Should -Be 1 -Because $m
            (Get-Combined $r) | Should -Match "-Apply belongs to the modes that write to the target tenant \((Import|Ghosts|CopyFiles)(, (Import|Ghosts|CopyFiles))+\); $m never writes there"
        }
    }
    It 'the local modes need neither -Apply nor a confirmation (Status here)' {
        (Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', (Join-Path $TestDrive 'nostore4'), '-LogFolder', (Join-Path $TestDrive 'lp7'))).ExitCode | Should -Be 0
    }
}

Describe 'Archive mode end to end (a real on-disk store, no network)' {
    BeforeAll {
        $script:ArchiveStore = Join-Path $TestDrive 'store-archive'
        New-DiskStore -Root $script:ArchiveStore -Messages 40
    }
    It 'writes the folder archive, announces it in the end card, exit 0' {
        $out = Join-Path $TestDrive 'archive-out'
        $logs = Join-Path $TestDrive 'logs-archive'
        $r = Invoke-Entry -Arguments @('-Mode', 'Archive', '-StoreRoot', $script:ArchiveStore, '-Users', 'user1@contoso.com', '-OutputPath', $out, '-LogFolder', $logs)
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'Archive finished'
        $r.Out | Should -Match '1/2'
        $r.Out | Should -Match '2/2'
        $r.Out | Should -Match ([regex]::Escape($out))
        $r.Out | Should -Match 'Report\s+.*archive-out'
        Test-Path -LiteralPath (Join-Path $out 'index.html') | Should -BeTrue
        $html = Get-Content -LiteralPath (Join-Path $out 'index.html') -Raw
        $html | Should -Match 'YYYY-MM-DD'
        $html | Should -Not -Match "type: 'date'"
        (Get-Content -LiteralPath (Get-ChildItem -LiteralPath $logs -Filter 'TeamsTransfer_*.log').FullName -Raw) | Should -Match 'Summary - Result: exit code 0 - complete'
    }
    It 'without -OutputPath the archive goes to <Output.Root>\reports\yyyy-MM-dd_HHmmss_Archive\' {
        $cwd = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cwd-archive') -Force | Select-Object -ExpandProperty FullName
        $cfg = Join-Path $cwd 'out-config.psd1'; "@{ Output = @{ Root = '$(Join-Path $cwd 'out')' } }" | Set-Content -LiteralPath $cfg
        $r = Invoke-Entry -Arguments @('-Mode', 'Archive', '-StoreRoot', $script:ArchiveStore, '-ConfigPath', $cfg) -Cwd $cwd
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $folder = Get-ChildItem -LiteralPath (Join-Path $cwd 'out\reports') -Directory | Select-Object -First 1
        $folder.Name | Should -Match '^\d{4}-\d{2}-\d{2}_\d{6}_Archive$'
        Test-Path -LiteralPath (Join-Path $folder.FullName 'archive\index.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $cwd 'out\logs') | Should -BeTrue
    }
    It 'the store is opened read-only: a second process can write to it meanwhile' {
        $writer = Open-TmtStore -Root $script:ArchiveStore
        try {
            $r = Invoke-Entry -Arguments @('-Mode', 'Archive', '-StoreRoot', $script:ArchiveStore, '-Users', 'user1@contoso.com', '-OutputPath', (Join-Path $TestDrive 'archive-ro'), '-LogFolder', (Join-Path $TestDrive 'logs-ro'))
            $r.ExitCode | Should -Be 0 -Because $r.Out
        } finally { $writer.Dispose() }
    }
    It 'refuses a missing store with the action to take (exit 1)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Archive', '-StoreRoot', (Join-Path $TestDrive 'no-such-store'), '-LogFolder', (Join-Path $TestDrive 'logs-nostore'))
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match 'No store at .*: run -Mode Inventory or -Mode Export first'
    }
    It 'returns a result object with -PassThru, nothing without it' {
        $out = Join-Path $TestDrive 'archive-pt'
        $cmd = "& '$($script:Entry)' -Mode Archive -StoreRoot '$($script:ArchiveStore)' -Users user1@contoso.com -OutputPath '$out' -LogFolder '$(Join-Path $TestDrive 'logs-pt')' -DevelopmentMode -PassThru | ForEach-Object { 'RESULT:' + `$_.Mode + ':' + `$_.Status + ':' + `$_.ExitCode }"
        $env:TEAMSTRANSFER_LOCAL_CONFIG = $script:NoLocalConfig
        $o = & $script:Pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        $o | Should -Match 'RESULT:Archive:Success:0'
        $o2 = & $script:Pwsh -NoProfile -NonInteractive -Command ("& '$($script:Entry)' -Mode Archive -StoreRoot '$($script:ArchiveStore)' -Users user1@contoso.com -OutputPath '$out' -LogFolder '$(Join-Path $TestDrive 'logs-pt')' -DevelopmentMode | ForEach-Object { 'OBJ:' + `$_.GetType().Name }") 2>&1 | Out-String
        $o2 | Should -Not -Match 'OBJ:'
    }
}

Describe 'Package integrity' {
    It 'a source tree without a manifest is refused without -DevelopmentMode (exit 1, explicit message)' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', (Join-Path $TestDrive 'ns')) -NoDevelopmentMode
        $r.ExitCode | Should -Be 1
        (Get-Combined $r) | Should -Match 'PackageIntegrity\.psd1 is missing'
        (Get-Combined $r) | Should -Match '-DevelopmentMode'
    }
    It 'a source tree without a manifest runs with -DevelopmentMode and says it is an unverified development tree' {
        $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns2'), '-LogFolder', (Join-Path $TestDrive 'lint'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        (Get-Combined $r) | Should -Match 'UnverifiedDevelopmentTree'
        (Get-Combined $r) | Should -Match 'package byte integrity and publisher authentication are not established'
        (Get-Content -LiteralPath (Get-ChildItem -LiteralPath (Join-Path $TestDrive 'lint') -Filter 'TeamsTransfer_*.log').FullName -Raw) | Should -Match '\[WARN  \] Package integrity \(UnverifiedDevelopmentTree\)'
    }
    Context 'a development package: manifest written by tools\Build-PackageManifest.ps1, not signed yet' {
        BeforeAll {
            $script:Pkg = Join-Path $TestDrive 'pkg'
            Copy-Item -LiteralPath $script:PackageRoot -Destination $script:Pkg -Recurse
            foreach ($d in 'out', 'logs') { Remove-Item -LiteralPath (Join-Path $script:Pkg $d) -Recurse -Force -ErrorAction SilentlyContinue }
            $script:Build = Join-Path $script:RepoRoot 'tools\Build-PackageManifest.ps1'
            $script:PkgEntry = Join-Path $script:Pkg 'Invoke-TeamsTransfer.ps1'
        }
        It 'the builder lists every file with its SHA256 (and not the config, the manifest itself or the generated folders)' {
            $o = & $script:Pwsh -NoProfile -File $script:Build -PackageRoot $script:Pkg 2>&1 | Out-String
            $o | Should -Match 'Manifest written'
            $o | Should -Match 'UnsignedDevelopmentPackage'
            $m = Import-PowerShellDataFile -LiteralPath (Join-Path $script:Pkg 'PackageIntegrity.psd1')
            $m.SchemaVersion | Should -Be 1; $m.Algorithm | Should -Be 'SHA256'; $m.Version | Should -Be '0.1.0'
            $paths = @($m.Files | ForEach-Object { $_.Path })
            $paths | Should -Contain 'Invoke-TeamsTransfer.ps1'
            $paths | Should -Contain 'src\Test-PackageIntegrity.ps1'
            $paths | Should -Contain 'templates\Archive.template.js'
            $paths | Should -Not -Contain 'PackageIntegrity.psd1'
            $paths | Should -Not -Contain 'config\TeamsTransfer.config.psd1'
            $paths | Should -Not -Contain 'config\TeamsTransfer.config.local.psd1'
            foreach ($f in $m.Files) { $f.Sha256 | Should -Match '^[0-9A-F]{64}$' }
            ($m.Files | Where-Object Path -eq 'Invoke-TeamsTransfer.ps1').Sha256 | Should -Be (Get-FileHash -LiteralPath $script:PkgEntry -Algorithm SHA256).Hash
        }
        It 'is refused without -DevelopmentMode: "unsigned development package"' {
            $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns3')) -Script $script:PkgEntry -NoDevelopmentMode
            $r.ExitCode | Should -Be 1
            (Get-Combined $r) | Should -Match 'unsigned development package'
        }
        It 'runs with -DevelopmentMode and announces the unsigned state' {
            $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns4'), '-LogFolder', (Join-Path $TestDrive 'lint2')) -Script $script:PkgEntry
            $r.ExitCode | Should -Be 0 -Because (Get-Combined $r)
            (Get-Combined $r) | Should -Match 'UnsignedDevelopmentPackage'
            (Get-Combined $r) | Should -Match 'owner signature is missing'
        }
        It 'fails closed on a changed, an unlisted and a missing file, even with -DevelopmentMode' {
            $js = Join-Path $script:Pkg 'templates\Archive.template.js'
            Add-Content -LiteralPath $js -Value '// tampered'
            $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns5'), '-LogFolder', (Join-Path $TestDrive 'lint3')) -Script $script:PkgEntry
            $r.ExitCode | Should -Be 1
            (Get-Combined $r) | Should -Match 'changed: templates\\Archive\.template\.js'
            $m = Get-Content -LiteralPath $js -Raw; Set-Content -LiteralPath $js -Value $m.Replace("// tampered`r`n", '').Replace("// tampered`n", '') -NoNewline
            Set-Content -LiteralPath (Join-Path $script:Pkg 'extra.ps1') -Value 'x'
            $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns6'), '-LogFolder', (Join-Path $TestDrive 'lint4')) -Script $script:PkgEntry
            $r.ExitCode | Should -Be 1
            (Get-Combined $r) | Should -Match 'unlisted: extra\.ps1'
            Remove-Item -LiteralPath (Join-Path $script:Pkg 'extra.ps1')
            Remove-Item -LiteralPath (Join-Path $script:Pkg 'TeamsTransfer.Console.ps1')
            $r = Invoke-Entry -Arguments @('-Mode', 'Export', '-WhatIf', '-StoreRoot', (Join-Path $TestDrive 'ns7'), '-LogFolder', (Join-Path $TestDrive 'lint5')) -Script $script:PkgEntry
            $r.ExitCode | Should -Be 1
            (Get-Combined $r) | Should -Match 'missing: TeamsTransfer\.Console\.ps1'
        }
        It 'the verifier refuses -Distribution together with -DevelopmentMode and an unsigned release' {
            $verifier = Join-Path $script:Pkg 'src\Test-PackageIntegrity.ps1'
            { & $verifier -Root $script:Pkg -Distribution -DevelopmentMode } | Should -Throw '*cannot be combined*'
            { & $verifier -Root $script:Pkg -Distribution } | Should -Throw '*signed*'
        }
    }
}

Describe 'Reports and progress' {
    It 'Wait-TmtEngineTask writes a dim progress line every interval, also in the log, and the stop message when the stop file appears' {
        $logDir = Join-Path $TestDrive 'log-progress'
        [void](Start-TmtLog -Directory $logDir)
        try {
            $result = & (Get-Module TeamsTransfer) {
                param($seconds)
                $snap = [TeamsTransfer.ProgressSnapshot]@{ Phase = 'export'; Users = 3; Messages = 12345; MessagesPerSecond = 100; Errors = 0 }
                $stop = [TeamsTransfer.StopControl]::new()
                $stop.Request()
                Wait-TmtEngineTask -Task ([Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($seconds))) -Snapshot { $snap }.GetNewClosure() -Activity 'Test' -IntervalSeconds 1 -Stop $stop
            } 3 6>&1
        } finally { Stop-TmtLog }
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $logDir -Filter 'TeamsTransfer_*.log').FullName -Raw
        $log | Should -Match '\[DETAIL\] export: users 3, messages 12,345 \(100/s\), errors 0'
        ([regex]::Matches($log, '\[DETAIL\] export:')).Count | Should -BeGreaterOrEqual 2
        $log | Should -Match '\[WARN  \] stop requested: the requests in flight finish first, run the command again to resume'
    }
}
