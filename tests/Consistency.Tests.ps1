#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Product consistency fixes found while documenting v0.1.0: one fallback order for the service account, one rule for -Window, messages that
    name real parameters, one documented default per mode for the parallelism, named lots (-Lot / -LotFile), the default output folder next to
    the package, the SQLite licence texts and their lock, the release builder, -Mode Merge and the English-only preview schema.
    Offline: real stores in a temp folder, the entry script in a child pwsh, no tenant.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Temp = Join-Path $env:TEMP ('tmt-consistency-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:Temp)
    $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:Guid = '11111111-1111-1111-1111-111111111111'

    function New-Root { Join-Path $script:Temp ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    function Invoke-Entry {
        param([string[]]$Arguments, [string]$Cwd)
        if (-not $Cwd) { $Cwd = New-Item -ItemType Directory -Path (New-Root) -Force | Select-Object -ExpandProperty FullName }
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        $psi.WorkingDirectory = $Cwd; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script:Entry) { $psi.ArgumentList.Add($a) }
        foreach ($a in $Arguments + '-DevelopmentMode' + '-LogFolder' + (Join-Path $script:Temp 'logs')) { $psi.ArgumentList.Add([string]$a) }
        foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'TEAMSTRANSFER_LOG_FOLDER') { [void]$psi.Environment.Remove($k) }
        $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = (Join-Path $script:Temp 'no-local-config.psd1')
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw "The entry script did not finish: $($Arguments -join ' ')" }
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $e.GetAwaiter().GetResult(); All = ($o.GetAwaiter().GetResult() + "`n" + $e.GetAwaiter().GetResult()) }
    }
    function New-Conv([string]$Key, [string]$Kind = 'Group') {
        $c = [TeamsTransfer.ConversationRecord]::new(); $c.Key = $Key; $c.Kind = $Kind
        $c.CreatedUtc = [DateTimeOffset]::Parse('2025-01-01T00:00:00Z'); $c.LastActivityUtc = [DateTimeOffset]::Parse('2026-10-01T00:00:00Z'); $c
    }
    function New-InventoryStore {
        # 2 users, 2 group chats linked to u1, one channel of the team 'Team One'
        $s = Open-TmtStore -Root (New-Root) -Partitions 8
        $users = foreach ($u in 'u1', 'u2') { $r = [TeamsTransfer.UserRecord]::new(); $r.Id = $u; $r.UserPrincipalName = "$u@contoso.com"; $r.DisplayName = "User $u"; $r.State = 'Active'; $r }
        $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($users))
        $chats = foreach ($k in 'g1', 'o1') { $c = New-Conv "chat:$k"; $c.ChatId = $k; $c }
        $ch = New-Conv 'channel:t1/c1' 'Channel'; $ch.TeamId = 't1'; $ch.ChannelId = 'c1'; $ch.TeamDisplayName = 'Team One'
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($chats + $ch))
        $s.LinkUserConversations('u1', [string[]]@('chat:g1', 'chat:o1'))
        return $s
    }
    function New-MessageStore {
        # a store with one chat of N messages (for Merge); partitions = 8
        param([string]$Root, [int]$Messages = 25, [int]$Partitions = 8, [string]$Chat = 'c1')
        $s = Open-TmtStore -Root $Root -Partitions $Partitions
        try {
            $u = [TeamsTransfer.UserRecord]::new(); $u.Id = 'u1'; $u.UserPrincipalName = 'user1@contoso.com'; $u.DisplayName = 'User 1'; $u.State = 'Active'
            $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($u))
            $c = New-Conv "chat:$Chat"; $c.ChatId = $Chat
            $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c))
            $s.LinkUserConversations('u1', [string[]]@("chat:$Chat"))
            $list = [Collections.Generic.List[Text.Json.JsonElement]]::new()
            for ($n = 1; $n -le $Messages; $n++) {
                $when = [DateTimeOffset]::new(2026, 1, 1, 8, 0, 0, [TimeSpan]::Zero).AddMinutes($n).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                $m = [ordered]@{ id = "$Chat-m$n"; createdDateTime = $when; lastModifiedDateTime = $when; from = @{ user = @{ id = 'u1'; displayName = 'User 1'; userIdentityType = 'aadUser' } }; body = @{ contentType = 'html'; content = "message $n" } }
                $list.Add([Text.Json.JsonDocument]::Parse(($m | ConvertTo-Json -Depth 6 -Compress)).RootElement)
            }
            [void]$s.AppendMessages("chat:$Chat", $list)
            $s.Flush()
        } finally { $s.Dispose() }
    }
}

AfterAll {
    if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe '1. Service account: one fallback order everywhere' {
    It 'the shipped configuration has Target.ServiceAccountUserId (empty, commented)' {
        $path = Join-Path $script:PackageRoot 'config\TeamsTransfer.config.psd1'
        $cfg = Import-PowerShellDataFile -LiteralPath $path
        $cfg.Target.ContainsKey('ServiceAccountUserId') | Should -BeTrue
        $cfg.Target.ServiceAccountUserId | Should -BeExactly ''
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'ServiceAccountUserId\s*=\s*''''\s*#.*UPN or object id'
        (Import-TmtConfiguration -Path $path).Target.ContainsKey('ServiceAccountUserId') | Should -BeTrue
    }
    It 'the order is parameter, configuration, plan checkpoint, identity map' {
        InModuleScope TeamsTransfer -Parameters @{ Root = (Join-Path $env:TEMP ('tmt-sa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) } {
            param($Root)
            $s = Open-TmtStore -Root $Root -Partitions 8
            try {
                $lo = [TeamsTransfer.LotOptions]::new()
                $id = $s.CreateLot('L1', [TeamsTransfer.LotMember[]]@([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::User, 'u1', 100)), $lo)
                $cfg = @{ Target = @{ ServiceAccountUserId = 'cfg@contoso.com' } }
                # nothing known
                Get-TmtServiceAccountChoice -Store $s -Lot 'L1' -Configuration @{ Target = @{} } -ServiceAccount '' | Should -BeNullOrEmpty
                # 4. the identity map
                $m = [TeamsTransfer.IdentityMapping]::new(); $m.SourceUserId = 'src-svc'; $m.Kind = [TeamsTransfer.IdentityKind]::ServiceAccount; $m.TargetUserId = 'map-id'
                ([TeamsTransfer.IIdentityMap]$s).Upsert($m)
                $c = Get-TmtServiceAccountChoice -Store $s -Lot 'L1' -Configuration @{ Target = @{} } -ServiceAccount ''
                $c.Value | Should -Be 'map-id'; $c.Source | Should -Be 'map'
                # 3. the plan checkpoint wins over the map
                $s.SetCheckpoint("plan:lot$id", '{"serviceAccountUserId":"plan-id"}')
                $c = Get-TmtServiceAccountChoice -Store $s -Lot 'L1' -Configuration @{ Target = @{} } -ServiceAccount ''
                $c.Value | Should -Be 'plan-id'; $c.Source | Should -Be 'plan'
                # 2. the configuration wins over the checkpoint
                $c = Get-TmtServiceAccountChoice -Store $s -Lot 'L1' -Configuration $cfg -ServiceAccount ''
                $c.Value | Should -Be 'cfg@contoso.com'; $c.Source | Should -Be 'configuration'
                # 1. the parameter wins over everything
                $c = Get-TmtServiceAccountChoice -Store $s -Lot 'L1' -Configuration $cfg -ServiceAccount 'param@contoso.com'
                $c.Value | Should -Be 'param@contoso.com'; $c.Source | Should -Be 'parameter'
            } finally { $s.Dispose(); Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'a GUID is kept, a UPN needs the target (or -AllowUnresolved for a preview), nothing known gives nothing' {
        InModuleScope TeamsTransfer -Parameters @{ Guid = $script:Guid } {
            param($Guid)
            (Resolve-TmtServiceAccount -Configuration @{ Target = @{ ServiceAccountUserId = $Guid } }).Id | Should -Be $Guid
            { Resolve-TmtServiceAccount -ServiceAccount 'svc@contoso.com' } | Should -Throw '*must be an object id (a GUID)*'
            (Resolve-TmtServiceAccount -ServiceAccount 'svc@contoso.com' -AllowUnresolved).Id | Should -Be 'svc@contoso.com'
            Resolve-TmtServiceAccount -Configuration @{ Target = @{} } | Should -BeNullOrEmpty
        }
    }
    It 'Plan, Import, Ghosts, CopyFiles and Verify all go through the same helper' {
        $verify = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Verify.ps1') -Raw
        $verify | Should -Match '(?s)function script:Resolve-TmtServiceAccount\b'
        # the three stages build their run options with the configuration and the lot
        ([regex]::Matches($verify, 'New-TmtRunOptions [^\n]*\n?[^\n]*-Configuration \$Configuration -Lot \$Lot')).Count | Should -Be 3
        (Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Plan.ps1') -Raw) | Should -Match 'Resolve-TmtServiceAccount -Store \$Store -Lot \$lotName -Configuration \$Configuration'
        (Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Import.ps1') -Raw) | Should -Match 'Resolve-TmtServiceAccount -Store \$Store -Lot \$Lot -Configuration \$Configuration'
        # and the entry script hands the configuration to every one of them
        $entry = Get-Content -LiteralPath $script:Entry -Raw
        foreach ($needle in '$planArgs.Configuration = $config', '$copyArgs = @{ Store = $store; Configuration = $config;', '$verifyArgs = @{ Store = $store; Client = $verifyClient; Configuration = $config;', '$ghostArgs = @{ Store = $store; Client = $ghostClient; Configuration = $config;', '$importArgs = @{ Store = $store; Lot = $Lot; Configuration = $config;') {
            $entry.Contains($needle) | Should -BeTrue -Because $needle
        }
    }
    It 'CopyFiles takes Target.ServiceAccountUserId from the configuration in a preview (no client, no request)' {
        $s = New-InventoryStore
        try {
            $run = [TeamsTransfer.ImportRunOptions]::new()
            [void](Invoke-TmtFileCopy -Store $s -Configuration @{ Target = @{ ServiceAccountUserId = $script:Guid } } -Run $run -IntervalSeconds 1)
            $run.ServiceAccountUserId | Should -Be $script:Guid
            $run2 = [TeamsTransfer.ImportRunOptions]::new()
            [void](Invoke-TmtFileCopy -Store $s -Configuration @{ Target = @{ ServiceAccountUserId = 'cfg@contoso.com' } } -ServiceAccount '22222222-2222-2222-2222-222222222222' -Run $run2 -IntervalSeconds 1)
            $run2.ServiceAccountUserId | Should -Be '22222222-2222-2222-2222-222222222222'
        } finally { $s.Dispose() }
    }
    It 'Plan: the configuration is used, and an offline plan with a UPN names the right thing (no -Offline in the message)' {
        $s = New-InventoryStore
        try {
            $r = New-TmtImportPlan -Store $s -Lot 'sa-lot' -Users 'u1' -Offline -OutputFolder (New-Root) -Configuration @{ Target = @{ ServiceAccountUserId = $script:Guid } }
            $cp = $s.GetCheckpoint("plan:lot$($s.GetLot('sa-lot').Id)") | ConvertFrom-Json
            $cp.serviceAccountUserId | Should -Be $script:Guid
            $err = { New-TmtImportPlan -Store $s -Lot 'sa-lot2' -Users 'u1' -Offline -OutputFolder (New-Root) -ServiceAccount 'svc@contoso.com' } | Should -Throw '*must be an object id (a GUID)*' -PassThru
            $err.Exception.Message | Should -Not -Match '-Offline'
        } finally { $s.Dispose() }
    }
}

Describe '2. -Window: the message and the validation agree' {
    It 'Resolve-TmtWindow accepts Nm with 1 <= N <= 600 and ISO date ranges' {
        InModuleScope TeamsTransfer {
            foreach ($w in '1m', '7m', '24m', '36m', '600m') { { Resolve-TmtWindow $w } | Should -Not -Throw -Because $w }
            (Resolve-TmtWindow '12m').From | Should -BeGreaterThan ([datetimeoffset]::UtcNow.AddMonths(-13))
            $r = Resolve-TmtWindow '2024-01-01..2025-12-31'
            $r.From.Year | Should -Be 2024; $r.To.Year | Should -Be 2025
            Resolve-TmtWindow '' | Should -BeNullOrEmpty
        }
    }
    It 'Resolve-TmtWindow refuses everything else with a message that states the rule' {
        InModuleScope TeamsTransfer {
            foreach ($w in '0m', '601m', '99999m', '24', 'abc', '24 months', '2024-01-01', '2025-12-31..2024-01-01', '2024-13-45..2025-01-01') {
                { Resolve-TmtWindow $w } | Should -Throw -Because $w
            }
            { Resolve-TmtWindow '601m' } | Should -Throw '*Nm with N from 1 to 600*<from>..<to>*'
            $msg = try { Resolve-TmtWindow '601m'; '' } catch { $_.Exception.Message }
            $msg | Should -Not -Match '24m, 60m'
        }
    }
    It 'a lot is cut in waves of months: Nm from 1 to 600, the message says exactly that' {
        InModuleScope TeamsTransfer {
            (ConvertTo-TmtWindowBoundaries '7m') | Should -Be @(7)
            (ConvertTo-TmtWindowBoundaries '24m') | Should -Be @(24)
            (ConvertTo-TmtWindowBoundaries '60m') | Should -Be @(24, 36, 48, 60)
            (ConvertTo-TmtWindowBoundaries '600m').Count | Should -BeGreaterThan 40
            foreach ($w in '0m', '601m', '5y', '2024-01-01..2025-12-31', '') {
                $msg = try { ConvertTo-TmtWindowBoundaries $w; '' } catch { $_.Exception.Message }
                $msg | Should -Match 'Nm with N from 1 to 600' -Because $w
                $msg | Should -Not -Match '24m, 36m, 48m or 60m'
            }
        }
    }
    It 'the entry script refuses a bad -Window before it opens anything (exit 1, the rule in the message)' {
        $r = Invoke-Entry @('-Mode', 'Plan', '-Users', 'a@b.c', '-Window', '700m')
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match 'Nm with N from 1 to 600'
        $r = Invoke-Entry @('-Mode', 'Export', '-Window', '0m')
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match 'Nm with N from 1 to 600 .*<from>\.\.<to>'
        $r = Invoke-Entry @('-Mode', 'Archive', '-Window', 'nope')
        $r.ExitCode | Should -Be 1
    }
    It 'the help states the same rule and no longer says 24m, 36m, 48m or 60m' {
        $help = (Get-Help $script:Entry -Full | Out-String)
        $help | Should -Match 'Nm with N from 1 to 600'
        $help | Should -Not -Match '24m, 36m, 48m or 60m'
    }
}

Describe '3. Messages and help name real parameters' {
    BeforeAll {
        $script:EntryParams = @((Get-Command $script:Entry).Parameters.Keys)
        $script:Common = [Management.Automation.Cmdlet]::CommonParameters + [Management.Automation.Cmdlet]::OptionalCommonParameters
        # not parameters of the entry script, and legitimate in a message or in the help: PowerShell operators and cmdlet parameters inside
        # $( ) of a message, the parameters of pwsh in an example, and the parameters of the module functions that a message of the module names.
        $script:Allowed = @(
            'and', 'or', 'not', 'xor', 'eq', 'ne', 'gt', 'ge', 'lt', 'le', 'like', 'notlike', 'match', 'notmatch', 'join', 'split', 'replace', 'is', 'isnot', 'as', 'in', 'notin', 'contains', 'f', 'imatch', 'ceq', 'cin'
            'LiteralPath', 'Path', 'Format', 'Last', 'First'
            'STA', 'File', 'NoProfile', 'NoLogo', 'Command', 'Version'                 # pwsh and #Requires
            'Client', 'Configuration', 'Distribution'                                   # the module API (New-TmtGraphClient, Resolve-TmtClient) and the verifier
        )
        function Get-ParameterTokens([string]$Text) {
            foreach ($m in [regex]::Matches($Text, '(?<![\w\-<>.\\/])-([A-Za-z][A-Za-z0-9]+)\b')) { $m.Groups[1].Value }
        }
        function Get-MessageTokens {
            # every -Name written in a throw, a Write-Tmt* or Write-Warning message of the package (the console files excluded), and in the help block of the entry script
            $files = Get-ChildItem -LiteralPath $script:PackageRoot -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.Name -notmatch '^TeamsTransfer\.Gui' -and $_.FullName -notmatch '\\(demo|ui|lib)\\' }
            foreach ($f in $files) {
                $t = $null; $e = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
                $nodes = $ast.FindAll({ param($n) ($n -is [Management.Automation.Language.ThrowStatementAst]) -or ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^Write-Tmt|^Write-Warning$') }, $true)
                foreach ($n in $nodes) {
                    foreach ($s in $n.FindAll({ param($x) $x -is [Management.Automation.Language.StringConstantExpressionAst] -or $x -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
                        foreach ($tok in (Get-ParameterTokens $s.Value)) { [pscustomobject]@{ Token = $tok; Where = "$($f.Name):$($n.Extent.StartLineNumber)" } }
                    }
                }
            }
            $raw = Get-Content -LiteralPath $script:Entry -Raw
            foreach ($tok in (Get-ParameterTokens $raw.Substring(0, $raw.IndexOf('#>')))) { [pscustomobject]@{ Token = $tok; Where = 'help of the entry script' } }
        }
    }
    It 'the scan sees the parameter names of messages and of the help (positive control)' {
        $tokens = @(Get-MessageTokens)
        $tokens.Count | Should -BeGreaterThan 100
        ($tokens | Where-Object Token -eq 'SkipTargetLookup') | Should -Not -BeNullOrEmpty
        @(Get-ParameterTokens 'it needs -Offline and -Apply') | Should -Contain 'Offline'
    }
    It 'every -Name in a message, an error or the help is a real parameter of the entry script' {
        $bad = @(Get-MessageTokens | Where-Object { $_.Token -notin $script:EntryParams -and $_.Token -notin $script:Common -and $_.Token -notin $script:Allowed } | ForEach-Object { "-$($_.Token) ($($_.Where))" } | Sort-Object -Unique)
        $bad | Should -BeNullOrEmpty -Because "these parameters do not exist: $($bad -join '; ')"
    }
    It 'the offline plan message names -SkipTargetLookup, never -Offline' {
        $plan = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Plan.ps1') -Raw
        $verify = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TeamsTransfer.Verify.ps1') -Raw
        # no throw or message of the package says -Offline any more (the parameter belongs to the module function only)
        (Get-MessageTokens | Where-Object Token -eq 'Offline') | Should -BeNullOrEmpty
        $plan | Should -Not -Match 'throw "-Offline'
        (Get-Help $script:Entry -Parameter SkipTargetLookup | Out-String) | Should -Match 'offline plan'
    }
}

Describe '4. Parallelism: one documented default per mode' {
    BeforeAll {
        function Get-ParamDefault([string]$File, [string]$Function, [string]$Name) {
            $t = $null; $e = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PackageRoot $File), [ref]$t, [ref]$e)
            $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true)[0]
            $p = $fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
            if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
        }
    }
    It 'the parameters of the entry script have no default of their own; the help and the table of the script say the defaults' {
        $cmd = Get-Command $script:Entry
        foreach ($n in 'UserParallelism', 'ConversationParallelism') {
            $t = $null; $e = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Entry, [ref]$t, [ref]$e)
            $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $n }
            $p.DefaultValue | Should -BeNullOrEmpty -Because "-$n gets its default from the mode"
        }
        $help = (Get-Help $script:Entry -Full | Out-String) -replace '\s+', ' '
        $help | Should -Match 'Export 8, Import 32, Verify 8'
        $help | Should -Match 'Default 8 in every one of these modes'
        (Get-Content -LiteralPath $script:Entry -Raw) | Should -Match 'UserParallelism = @\{ Inventory = 8; Export = 8; Ghosts = 8 \}; ConversationParallelism = @\{ Export = 8; Import = 32; Verify = 8 \}'
    }
    It 'the module functions use exactly those defaults' {
        Get-ParamDefault 'TeamsTransfer.Export.ps1' 'Invoke-TmtExport' 'ConversationParallelism' | Should -Be '8'
        Get-ParamDefault 'TeamsTransfer.Export.ps1' 'Invoke-TmtExport' 'UserParallelism' | Should -Be '8'
        Get-ParamDefault 'TeamsTransfer.Export.ps1' 'Invoke-TmtInventory' 'UserParallelism' | Should -Be '8'
        Get-ParamDefault 'TeamsTransfer.Import.ps1' 'Invoke-TmtImport' 'ConversationParallelism' | Should -Be '32'
        Get-ParamDefault 'TeamsTransfer.Verify.ps1' 'Invoke-TmtVerify' 'ConversationParallelism' | Should -Be '8'
        [TeamsTransfer.ImportRunOptions]::new().ConversationParallelism | Should -Be 32
        [TeamsTransfer.ExportOptions]::new().ConversationParallelism | Should -Be 8
        [TeamsTransfer.ExportOptions]::new().UserParallelism | Should -Be 8
    }
    It 'Import passes its parameter always (32 unless given), and Ghosts is no longer capped silently at 32' {
        $src = Get-Content -LiteralPath $script:Entry -Raw
        $src | Should -Match '\$importArgs\.ConversationParallelism = \$ConversationParallelism'
        $src | Should -Not -Match 'Math\]::Min\(32, \$UserParallelism\)'
        $r = Invoke-Entry @('-Mode', 'Ghosts', '-UserParallelism', '40')
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match 'with -Mode Ghosts the value is 1 to 32'
    }
}

Describe '5. Named lots: -Lot <name> with -Users / -Teams / -LotFile' {
    BeforeAll {
        $script:SvcArgs = @{ Offline = $true; ServiceAccount = $script:Guid }
    }
    It 'Plan -Lot <name> -Users creates the lot with that name, plans it, and runs again on the same members without error' {
        $s = New-InventoryStore
        try {
            $r = New-TmtImportPlan -Store $s -Lot 'wave-a' -Users 'u1' -OutputFolder (New-Root) @script:SvcArgs
            $r.Created | Should -BeTrue
            $r.LotName | Should -Be 'wave-a'
            [string]$s.GetLot('wave-a').State | Should -Be 'ImportPlanned'
            @($s.ListLotMembers($s.GetLot('wave-a').Id) | ForEach-Object { "$($_.Type):$($_.Identity)" }) | Should -Be @('User:u1')
            $again = New-TmtImportPlan -Store $s -Lot 'wave-a' -Users 'u1' -OutputFolder (New-Root) @script:SvcArgs
            $again.Created | Should -BeFalse
            @($s.ListLots() | Where-Object Name -like 'wave-a*').Count | Should -Be 1
        } finally { $s.Dispose() }
    }
    It 'refuses a lot that exists with different members (nothing is changed)' {
        $s = New-InventoryStore
        try {
            [void](New-TmtImportPlan -Store $s -Lot 'wave-a' -Users 'u1' -OutputFolder (New-Root) @script:SvcArgs)
            { New-TmtImportPlan -Store $s -Lot 'wave-a' -Users 'u2' -OutputFolder (New-Root) @script:SvcArgs } | Should -Throw '*already exists with different members*'
            { New-TmtImportPlan -Store $s -Lot 'wave-a' -Users 'u1', 'u2' -OutputFolder (New-Root) @script:SvcArgs } | Should -Throw '*already exists with different members*'
            @($s.ListLotMembers($s.GetLot('wave-a').Id)).Count | Should -Be 1
            [string]$s.GetLot('wave-a').State | Should -Be 'ImportPlanned'
        } finally { $s.Dispose() }
    }
    It 'keeps the automatic name when -Lot is omitted' {
        $s = New-InventoryStore
        try {
            $r = New-TmtImportPlan -Store $s -Users 'u1' -OutputFolder (New-Root) @script:SvcArgs
            $r.Created | Should -BeTrue
            $r.LotName | Should -Match '^plan-\d{8}-\d{6}$'
        } finally { $s.Dispose() }
    }
    It '-LotFile: Type, Identity, Priority (optional); teams by name are resolved with the inventory; -Teams with -Lot works too' {
        $s = New-InventoryStore
        try {
            $csv = Join-Path (New-Root) 'lot.csv'; [void](New-Item -ItemType Directory -Path (Split-Path $csv))
            "Type,Identity,Priority`nuser,u2@contoso.com,5`nTeam,Team One,`nChat,chat:g1,7`nChannel,t1/c1,`n" | Set-Content -LiteralPath $csv -Encoding utf8
            $r = New-TmtImportPlan -Store $s -Lot 'from-file' -LotFile $csv -OutputFolder (New-Root) @script:SvcArgs
            $r.Created | Should -BeTrue
            $m = @($s.ListLotMembers($s.GetLot('from-file').Id))
            $m.Count | Should -Be 4
            ($m | Where-Object { [string]$_.Type -eq 'User' }).Priority | Should -Be 5
            ($m | Where-Object { [string]$_.Type -eq 'Team' }).Identity | Should -Be 't1'
            ($m | Where-Object { [string]$_.Type -eq 'Team' }).Priority | Should -Be 100
            ($m | Where-Object { [string]$_.Type -eq 'Chat' }).Priority | Should -Be 7
            # the same file again: used as it is; a different file: refused
            (New-TmtImportPlan -Store $s -Lot 'from-file' -LotFile $csv -OutputFolder (New-Root) @script:SvcArgs).Created | Should -BeFalse
            "Type,Identity`nUser,u1`n" | Set-Content -LiteralPath $csv -Encoding utf8
            { New-TmtImportPlan -Store $s -Lot 'from-file' -LotFile $csv -OutputFolder (New-Root) @script:SvcArgs } | Should -Throw '*already exists with different members*'
            # -Teams with a name
            $t = New-TmtImportPlan -Store $s -Lot 'by-team' -Teams 'Team One' -OutputFolder (New-Root) @script:SvcArgs
            ($s.ListLotMembers($s.GetLot('by-team').Id) | Select-Object -First 1).Identity | Should -Be 't1'
        } finally { $s.Dispose() }
    }
    It '-LotFile errors are exact (file, column, type, identity, priority, empty)' {
        InModuleScope TeamsTransfer -Parameters @{ Dir = (New-Root) } {
            param($Dir)
            [void](New-Item -ItemType Directory -Path $Dir)
            $f = Join-Path $Dir 'x.csv'
            { Read-TmtLotFile (Join-Path $Dir 'missing.csv') } | Should -Throw '*file not found*'
            "Type,Identity`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*has no row*'
            "Kind,Identity`nUser,a`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*the column Type is missing*'
            "Type,Name`nUser,a`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*the column Identity is missing*'
            "Type,Identity`nUser,a`nGroup,b`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*line 3: Type ''Group'' is not User, Team, Chat or Channel*'
            "Type,Identity`n5,b`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*Type ''5''*'
            "Type,Identity`nUser,`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*line 2: Identity is empty*'
            "Type,Identity,Priority`nUser,a,high`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*Priority ''high''*'
            "Type,Identity,Priority`nUser,a,-3`n" | Set-Content $f; { Read-TmtLotFile $f } | Should -Throw '*Priority ''-3''*'
            "type,identity,priority`nuser,a,3`nCHANNEL,t/c,`n" | Set-Content $f
            $rows = @(Read-TmtLotFile $f); $rows.Count | Should -Be 2; $rows[0].Type | Should -Be 'User'; $rows[1].Type | Should -Be 'Channel'; $rows[1].Priority | Should -Be 100
        }
    }
    It 'Export -Lot <name> -LotFile creates the lot and exports it; another file for the same name is refused before anything runs' {
        $s = New-InventoryStore
        try {
            $csv = Join-Path (New-Root) 'lot.csv'; [void](New-Item -ItemType Directory -Path (Split-Path $csv))
            "Type,Identity,Priority`nChat,chat:g1,1`n" | Set-Content -LiteralPath $csv -Encoding utf8
            $client = InModuleScope TeamsTransfer { Resolve-TmtDryClient }     # a client whose transport refuses every request: the unit fails, the lot is created and stays Exporting
            try { [void](Invoke-TmtLotExport -Store $s -Lot 'exp-lot' -LotFile $csv -ExportArguments @{ Client = $client; IntervalSeconds = 1 }) } catch { Write-Verbose "refused client: $($_.Exception.Message)" }
            $info = $s.GetLot('exp-lot')
            [string]$info.State | Should -Be 'Exporting'
            @($s.ListLotMembers($info.Id) | ForEach-Object { "$($_.Type):$($_.Identity):$($_.Priority)" }) | Should -Be @('Chat:chat:g1:1')
            @($s.ListSlices($info.Id)).Count | Should -Be 4
            "Type,Identity`nChat,chat:o1`n" | Set-Content -LiteralPath $csv -Encoding utf8
            { Invoke-TmtLotExport -Store $s -Lot 'exp-lot' -LotFile $csv -ExportArguments @{ Client = $client; IntervalSeconds = 1 } } | Should -Throw '*already exists with different members*'
            # -Window Nm gives the waves of the new lot
            "Type,Identity`nChat,chat:o1`n" | Set-Content -LiteralPath $csv -Encoding utf8
            try { [void](Invoke-TmtLotExport -Store $s -Lot 'exp-lot2' -LotFile $csv -ExportArguments @{ Client = $client; IntervalSeconds = 1; Window = '60m' }) } catch { Write-Verbose 'refused client' }
            @($s.ListSlices($s.GetLot('exp-lot2').Id)).Count | Should -Be 4
            try { [void](Invoke-TmtLotExport -Store $s -Lot 'exp-lot3' -LotFile $csv -ExportArguments @{ Client = $client; IntervalSeconds = 1; Window = '12m' }) } catch { Write-Verbose 'refused client' }
            @($s.ListSlices($s.GetLot('exp-lot3').Id)).Count | Should -Be 1
        } finally { $s.Dispose() }
    }
    It 'the entry script: -LotFile needs -Lot with Export, belongs to Export and Plan only, and -Lot -Users is allowed with Plan only' {
        $r = Invoke-Entry @('-Mode', 'Export', '-LotFile', (Join-Path $script:Temp 'nope.csv'))
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-LotFile needs the name of the lot to create'
        $r = Invoke-Entry @('-Mode', 'Status', '-LotFile', (Join-Path $script:Temp 'nope.csv'))
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-LotFile does not apply to -Mode Status'
        $r = Invoke-Entry @('-Mode', 'Export', '-Lot', 'x', '-Users', 'a@b.c')
        $r.ExitCode | Should -Be 1; $r.All | Should -Match 'with -Mode Plan they create the lot; with -Mode Export use -LotFile'
        $r = Invoke-Entry @('-Mode', 'Plan', '-Lot', 'x', '-LotFile', (Join-Path $script:Temp 'nope.csv'))
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-LotFile: file not found'
    }
}

Describe '6. The default output folder is next to the package, never inside it' {
    It 'a relative Output.Root is resolved against the parent folder of the package, whatever the current folder' {
        $parent = Split-Path -Parent $script:PackageRoot
        $expected = Join-Path $parent 'out'
        $r = Invoke-Entry @('-Mode', 'Status') -Cwd $script:PackageRoot
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match ([regex]::Escape($expected))
        $r.Out | Should -Match ([regex]::Escape((Join-Path $expected 'store')))
        $r.Out | Should -Not -Match ([regex]::Escape((Join-Path $script:PackageRoot 'out')))
        $r.Out | Should -Match 'next to the package folder'
        # from another folder: the same place
        $r2 = Invoke-Entry @('-Mode', 'Status') -Cwd $script:Temp
        $r2.Out | Should -Match ([regex]::Escape((Join-Path $expected 'store')))
        $r2.Out | Should -Not -Match ([regex]::Escape((Join-Path $script:Temp 'out')))
    }
    It 'an absolute Output.Root is kept as it is' {
        $cfg = Join-Path $script:Temp 'abs.config.psd1'
        $abs = Join-Path $script:Temp 'elsewhere'
        "@{ Output = @{ Root = '$abs' } }" | Set-Content -LiteralPath $cfg -Encoding utf8
        $r = Invoke-Entry @('-Mode', 'Status', '-ConfigPath', $cfg)
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match ([regex]::Escape((Join-Path $abs 'store')))
    }
    It 'the configuration comment and the help say where it is' {
        (Get-Content -LiteralPath (Join-Path $script:PackageRoot 'config\TeamsTransfer.config.psd1') -Raw) | Should -Match 'PARENT folder of the package'
        (Get-Help $script:Entry -Parameter StoreRoot | Out-String) -replace '\s+', ' ' | Should -Match 'parent folder of the package'
    }
}

Describe '7. SQLite licence texts and the lock' {
    BeforeAll {
        $script:Lock = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'dependency-lock.json') -Raw | ConvertFrom-Json
    }
    It 'the three licence texts are retained under lib\licenses' {
        $mit = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'lib\licenses\Microsoft.Data.Sqlite\LICENSE.txt') -Raw
        $mit | Should -Match 'The MIT License \(MIT\)'; $mit | Should -Match 'Permission is hereby granted, free of charge'
        $apache = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'lib\licenses\SQLitePCLRaw\LICENSE.TXT') -Raw
        $apache | Should -Match 'Apache License\s+Version 2\.0, January 2004'
        $pd = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'lib\licenses\SQLite\PUBLIC-DOMAIN.txt') -Raw
        $pd | Should -Match 'SQLite Is Public Domain'; $pd | Should -Match 'https://www.sqlite.org/copyright.html'
    }
    It 'the lock pins the SQLite packages (SHA-512 of the package, SHA-256 of every shipped file) and the notices' {
        foreach ($id in 'Microsoft.Data.Sqlite.Core', 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.bundle_e_sqlite3', 'SQLitePCLRaw.lib.e_sqlite3') {
            $p = $script:Lock.packages | Where-Object id -eq $id
            $p | Should -Not -BeNullOrEmpty -Because $id
            $p.sha512 | Should -Match '^[A-Za-z0-9+/]{86}==$'
            $p.sha512Source | Should -Match 'nuget.org'
        }
        $locked = @($script:Lock.packages | ForEach-Object { $_.selectedFiles } | Where-Object { $_.target -like 'lib\sqlite\*' })
        $locked.Count | Should -Be 6
        foreach ($f in $locked) {
            $path = Join-Path $script:PackageRoot $f.target
            (Test-Path -LiteralPath $path) | Should -BeTrue -Because $f.target
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.sha256 -Because $f.target
        }
        # nothing of lib\sqlite is left out of the lock
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $script:PackageRoot 'lib\sqlite') -Recurse -File | ForEach-Object { $_.FullName.Substring($script:PackageRoot.Length + 1) })
        $onDisk | Where-Object { $_ -notin $locked.target } | Should -BeNullOrEmpty
        @($script:Lock.notices).Count | Should -Be 3
        foreach ($n in $script:Lock.notices) {
            (Get-FileHash -LiteralPath (Join-Path $script:PackageRoot $n.target) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $n.sha256 -Because $n.target
            $n.source | Should -Match '^https://'
        }
    }
    It 'the shipped DLLs are the versions the notices announce' {
        (Get-Item (Join-Path $script:PackageRoot 'lib\sqlite\Microsoft.Data.Sqlite.dll')).VersionInfo.ProductVersion | Should -Be '10.0.12'
        (Get-Item (Join-Path $script:PackageRoot 'lib\sqlite\SQLitePCLRaw.core.dll')).VersionInfo.ProductVersion | Should -Be '2.1.12'
        $notices = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'THIRD-PARTY-NOTICES.md') -Raw
        $notices | Should -Not -Match 'not yet copied'
        $notices | Should -Match 'lib/licenses/SQLite/PUBLIC-DOMAIN.txt'
    }
    It 'tools\Get-TeamsTransferDependencies.ps1 -Verify checks the SQLite files and the licence texts offline' {
        $out = & $script:Pwsh -NoProfile -File (Join-Path $script:RepoRoot 'tools\Get-TeamsTransferDependencies.ps1') -Verify 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'lib\\sqlite\\Microsoft\.Data\.Sqlite\.dll'
        $out | Should -Match 'lib\\sqlite\\runtimes\\win-x64\\e_sqlite3\.dll'
        $out | Should -Match 'lib\\licenses\\SQLite\\PUBLIC-DOMAIN\.txt'
    }
    It '-Verify fails on a changed licence text' {
        $copy = Join-Path $script:Temp 'lockcopy'
        [void](New-Item -ItemType Directory -Path (Join-Path $copy 'package\lib') -Force)
        Copy-Item -LiteralPath (Join-Path $script:PackageRoot 'lib\licenses') -Destination (Join-Path $copy 'package\lib\licenses') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:PackageRoot 'lib\sqlite') -Destination (Join-Path $copy 'package\lib\sqlite') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:PackageRoot 'lib\gui') -Destination (Join-Path $copy 'package\lib\gui') -Recurse -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $script:PackageRoot 'dependency-lock.json') -Destination (Join-Path $copy 'package\dependency-lock.json')
        Add-Content -LiteralPath (Join-Path $copy 'package\lib\licenses\SQLite\PUBLIC-DOMAIN.txt') -Value 'tampered'
        $out = & $script:Pwsh -NoProfile -File (Join-Path $script:RepoRoot 'tools\Get-TeamsTransferDependencies.ps1') -PackageRoot (Join-Path $copy 'package') -Verify 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match '\[HASH\]\s+lib\\licenses\\SQLite\\PUBLIC-DOMAIN\.txt'
    }
}

Describe '8. tools\Build-Package.ps1' {
    BeforeAll {
        function New-BuildCopy {
            $t = New-Root; [void](New-Item -ItemType Directory -Path $t)
            Copy-Item -LiteralPath $script:PackageRoot -Destination (Join-Path $t 'package') -Recurse
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tools') -Destination (Join-Path $t 'tools') -Recurse -Exclude 'phase0-output'
            return $t
        }
        function Invoke-Build([string]$Tree, [string[]]$Arguments) {
            $out = & $script:Pwsh -NoProfile -File (Join-Path $Tree 'tools\Build-Package.ps1') @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Out = $out }
        }
    }
    It 'builds the ZIP with exactly the package content, and SHA256SUMS.txt, on a temp copy (-SkipTests)' {
        $t = New-BuildCopy
        # things that must never be shipped
        [void](New-Item -ItemType Directory -Path (Join-Path $t 'package\out'), (Join-Path $t 'package\logs') -Force)
        Set-Content -LiteralPath (Join-Path $t 'package\out\junk.txt') -Value 'x'; Set-Content -LiteralPath (Join-Path $t 'package\logs\a.log') -Value 'x'
        Set-Content -LiteralPath (Join-Path $t 'package\config\TeamsTransfer.config.local.psd1') -Value '@{ Source = @{ TenantId = "private" } }'
        $b = Invoke-Build $t @('-SkipTests')
        $b.ExitCode | Should -Be 0 -Because $b.Out
        $b.Out | Should -Match 'SkipTests'
        $b.Out | Should -Match 'UNSIGNED development ZIP'
        $zipPath = Join-Path $t 'out\release\TeamsTransfer-1.0.1-win-x64.zip'
        Test-Path -LiteralPath $zipPath | Should -BeTrue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try { $names = @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
        $top = 'TeamsTransfer-1.0.1/'
        $names | Where-Object { -not $_.StartsWith($top) } | Should -BeNullOrEmpty
        $rel = @($names | ForEach-Object { $_.Substring($top.Length) })
        # exactly the package content: the manifest files + the manifest + the editable configuration
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $t 'package\PackageIntegrity.psd1')
        $expected = @($manifest.Files | ForEach-Object { $_.Path.Replace('\', '/') }) + 'PackageIntegrity.psd1' + 'config/TeamsTransfer.config.psd1'
        @($rel | Sort-Object) | Should -Be @($expected | Sort-Object)
        # and nothing that must not ship
        $rel | Should -Contain 'Invoke-TeamsTransfer.ps1'
        $rel | Should -Contain 'PackageIntegrity.psd1'
        $rel | Should -Contain 'config/TeamsTransfer.config.psd1'
        $rel | Should -Contain 'lib/licenses/SQLite/PUBLIC-DOMAIN.txt'
        $rel | Should -Contain 'dependency-lock.json'
        $rel | Where-Object { $_ -match '\.local\.psd1$|^out/|^logs/|^store/|^reports/|^tests/|^tools/|docs/design|\.local-test-data|\.log$' } | Should -BeNullOrEmpty
        $rel | Where-Object { $_ -match '^docs/' } | Should -Not -BeNullOrEmpty
        # SHA256SUMS.txt
        $sums = Get-Content -LiteralPath (Join-Path $t 'out\release\SHA256SUMS.txt') -Raw
        $sums | Should -Be ("{0}  TeamsTransfer-1.0.1-win-x64.zip`n" -f (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant())
        # the manifest it wrote verifies (development mode) and the second run needs -Force
        (& (Join-Path $t 'package\src\Test-PackageIntegrity.ps1') -Root (Join-Path $t 'package') -DevelopmentMode).Status | Should -Be 'UnsignedDevelopmentPackage'
        (Invoke-Build $t @('-SkipTests', '-Stage', 'Package')).ExitCode | Should -Not -Be 0
        (Invoke-Build $t @('-SkipTests', '-Stage', 'Package', '-Force')).ExitCode | Should -Be 0
        # a signature is required for a release
        $rq = Invoke-Build $t @('-Stage', 'Package', '-Force', '-RequireSignature')
        $rq.ExitCode | Should -Not -Be 0
        $rq.Out | Should -Match 'signature|signed'
    }
    It 'refuses a package that holds a store, reports, .local-test-data or a stray *.local.psd1, and refuses to run without tests unless -SkipTests is explicit' {
        $t = New-BuildCopy
        $noTests = Invoke-Build $t @()
        $noTests.ExitCode | Should -Not -Be 0
        $noTests.Out | Should -Match '(?s)tests folder is not there.*-SkipTests'
        foreach ($name in 'store', 'reports', '.local-test-data') {
            [void](New-Item -ItemType Directory -Path (Join-Path $t "package\$name") -Force)
            $b = Invoke-Build $t @('-SkipTests')
            $b.ExitCode | Should -Not -Be 0 -Because $name
            $b.Out | Should -Match "holds '$([regex]::Escape($name))'"
            Remove-Item -LiteralPath (Join-Path $t "package\$name") -Recurse -Force
        }
        Set-Content -LiteralPath (Join-Path $t 'package\config\Other.local.psd1') -Value '@{}'
        $b = Invoke-Build $t @('-SkipTests')
        $b.ExitCode | Should -Not -Be 0
        $b.Out | Should -Match 'Private configuration file'
    }
    It 'the help documents the signing order and the stages' {
        $help = (Get-Help (Join-Path $script:RepoRoot 'tools\Build-Package.ps1') -Full | Out-String) -replace '\s+', ' '
        $help | Should -Match 'sign|signs'
        $help | Should -Match 'Build-PackageManifest'
        $help | Should -Match '-Stage Prepare'
        $help | Should -Match '-Stage Package -RequireSignature'
        $help | Should -Match 'SHA256SUMS\.txt'
        $help | Should -Match 'SkipTests'
    }
}

Describe '9. -Mode Merge' {
    It 'folds another store into a new one, never modifies the other store, and a second run changes nothing' {
        $a = Join-Path (New-Root) 'a'; $b = Join-Path (New-Root) 'b'
        New-MessageStore -Root $b -Messages 25 -Chat 'c1'
        $snapshot = { Get-ChildItem -LiteralPath $b -Recurse -File | Where-Object { $_.Name -notmatch '-(shm|wal)$' } | Sort-Object FullName | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } }
        $before = & $snapshot
        $r1 = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $b)
        $r1.ExitCode | Should -Be 0 -Because $r1.All
        $r1.Out | Should -Match '25 message\(s\) new, 0 updated, 0 unchanged'
        $r1.Out | Should -Match 'Store consistent'
        $r1.Out | Should -Match 'Lots, leases and import sessions are not merged'
        (& $snapshot) | Should -Be $before
        $r2 = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $b)
        $r2.ExitCode | Should -Be 0 -Because $r2.All
        $r2.Out | Should -Match '0 message\(s\) new, 0 updated, 25 unchanged'
        $r2.Out | Should -Match 'Nothing new'
        (& $snapshot) | Should -Be $before
        $s = Open-TmtStore -Root $a -ReadOnly
        try { $s.CountMessages('chat:c1') | Should -Be 25; (Get-TmtStoreStatus -Store $s).Users | Should -Be 1 } finally { $s.Dispose() }
    }
    It 'merges two workstations that exported disjoint chats into one coordinator store' {
        $a = Join-Path (New-Root) 'coord'; $w1 = Join-Path (New-Root) 'ws1'; $w2 = Join-Path (New-Root) 'ws2'
        New-MessageStore -Root $w1 -Messages 10 -Chat 'c1'
        New-MessageStore -Root $w2 -Messages 7 -Chat 'c2'
        (Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $w1)).ExitCode | Should -Be 0
        (Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $w2)).ExitCode | Should -Be 0
        $s = Open-TmtStore -Root $a -ReadOnly
        try { $s.CountMessages('chat:c1') | Should -Be 10; $s.CountMessages('chat:c2') | Should -Be 7 } finally { $s.Dispose() }
    }
    It 'refuses: no -FromStore, no store there, the same store, nested stores, a different partition count, other modes' {
        $a = Join-Path (New-Root) 'a'; $b = Join-Path (New-Root) 'b'; $c = Join-Path (New-Root) 'c'
        New-MessageStore -Root $a -Messages 3; New-MessageStore -Root $b -Messages 3 -Chat 'c9'; New-MessageStore -Root $c -Messages 3 -Partitions 16 -Chat 'c8'
        $r = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a)
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-FromStore is required with -Mode Merge'
        $r = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', (Join-Path $script:Temp 'nothing-here'))
        $r.ExitCode | Should -Be 1; $r.All | Should -Match 'No store at .* \(-FromStore\)'
        $r = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $a)
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-FromStore is this store'
        $r = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', (Join-Path $a 'inside'))
        $r.ExitCode | Should -Be 1; $r.All | Should -Match 'overlap'
        $r = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', $a, '-FromStore', $c)
        $r.ExitCode | Should -Be 1; $r.All | Should -Match 'do not have the same number of partitions: .* has 8, .* has 16'
        $r = Invoke-Entry @('-Mode', 'Status', '-StoreRoot', $a, '-FromStore', $b)
        $r.ExitCode | Should -Be 1; $r.All | Should -Match '-FromStore does not apply to -Mode Status'
        # -WhatIf starts nothing and writes nothing
        $w = Invoke-Entry @('-Mode', 'Merge', '-StoreRoot', (Join-Path (New-Root) 'new'), '-FromStore', $b, '-WhatIf')
        $w.ExitCode | Should -Be 0; $w.Out | Should -Match 'WhatIf: it would fold the store'
    }
    It 'the help documents Merge and the multi-workstation procedure' {
        $help = (Get-Help $script:Entry -Full | Out-String) -replace '\s+', ' '
        $help | Should -Match 'Mode Merge'
        $help | Should -Match 'each workstation exports a DISJOINT lot'
        $help | Should -Match '-Mode Merge -StoreRoot'
        (Get-Command $script:Entry).Parameters['Mode'].Attributes.ValidValues | Should -Contain 'Merge'
    }
}

Describe '10. The preview schema is English only' {
    It 'preview-v1.schema.json allows language en only' {
        $schema = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'schemas\preview-v1.schema.json') -Raw
        $j = $schema | ConvertFrom-Json
        @($j.properties.language.enum) | Should -Be @('en')
        $schema | Should -Not -Match '"fr"'
        $j.required | Should -Contain 'language'
    }
}

Describe '11. PowerShell files of the package: UTF-8 with BOM and CRLF (Authenticode in Windows PowerShell 5.1 and 7)' {
    BeforeAll {
        $script:PsFiles = @(Get-ChildItem -LiteralPath $script:PackageRoot -Recurse -File -Include *.ps1, *.psm1, *.psd1 |
            Where-Object { $_.FullName -notmatch '[\\/](out|logs|store|reports|\.local-test-data)[\\/]' -and $_.Name -notmatch '\.local\.psd1$' })
    }
    It 'there are PowerShell files to check' { $script:PsFiles.Count | Should -BeGreaterThan 10 }
    It 'every file starts with the UTF-8 BOM (the generated ASCII manifest excepted), is valid UTF-8 and uses CRLF on every line' {
        $bad = foreach ($f in $script:PsFiles) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            $why = @()
            if ($f.Name -ceq 'PackageIntegrity.psd1' -and $f.DirectoryName -eq ([IO.Path]::GetFullPath($script:PackageRoot).TrimEnd('\'))) {
                # Generated by tools\Build-PackageManifest.ps1: pure ASCII without BOM (the same bytes in every encoding), signed as is.
                if (@($b | Where-Object { $_ -gt 127 }).Count) { $why += 'manifest not pure ASCII' }
            } elseif ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $why += 'no BOM' }
            try { [void][Text.UTF8Encoding]::new($false, $true).GetString($b) } catch { $why += 'not valid UTF-8' }
            $lf = 0; $crlf = 0; $cr = 0
            for ($i = 0; $i -lt $b.Length; $i++) {
                if ($b[$i] -eq 10) { if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ } }
                elseif ($b[$i] -eq 13 -and ($i + 1 -ge $b.Length -or $b[$i + 1] -ne 10)) { $cr++ }
            }
            if ($lf -or $cr) { $why += "mixed or bare line endings (LF $lf, CR $cr, CRLF $crlf)" }
            if ($why) { '{0}: {1}' -f $f.Name, ($why -join ', ') }
        }
        $bad | Should -BeNullOrEmpty
    }
}
