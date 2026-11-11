#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Lot K (fixes from the first real import runs): cancelling a lot that has not started importing (TmtStore.CancelLot, -Mode Status -CancelLot),
    a failed Plan that must not leave conversations reserved, -Mode Export -Lot with chat / channel members (Invoke-TmtLotExport) and the
    Status lines (conversations inventoried vs with messages, lots with items and journal). Offline: real TmtStore in a temp folder, the SOURCE
    is SyntheticTenant.Tiny behind a fake Graph.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'support\PlanFixtures.ps1')
    $script:Temp = Join-Path $env:TEMP ('tmt-lots-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:Temp)
    $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:AsOf = [DateTimeOffset]::Parse('2026-11-09T00:00:00Z')

    function New-Root { Join-Path $script:Temp ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    function Member([string]$Type, [string]$Identity) { [TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::$Type, $Identity, 100) }
    function New-Lot($s, [string]$Name, $Members) {
        $o = [TeamsTransfer.LotOptions]::new(); $o.AsOfUtc = $script:AsOf
        $s.CreateLot($Name, [TeamsTransfer.LotMember[]]@($Members), $o)
    }
    function Add-Inventory($s) {
        $users = foreach ($u in 'u1', 'u2') { $r = [TeamsTransfer.UserRecord]::new(); $r.Id = $u; $r.UserPrincipalName = "$u@contoso.com"; $r.DisplayName = "User $u"; $r.State = 'Active'; $r }
        $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($users))
        $convs = foreach ($k in 'g1', 'o1', 'o2') {
            $c = [TeamsTransfer.ConversationRecord]::new(); $c.Key = "chat:$k"; $c.ChatId = $k; $c.Kind = 'Group'
            $c.CreatedUtc = [DateTimeOffset]::Parse('2023-01-01T00:00:00Z'); $c.LastActivityUtc = [DateTimeOffset]::Parse('2026-10-01T00:00:00Z'); $c
        }
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($convs))
        $s.LinkUserConversations('u1', [string[]]@('chat:g1', 'chat:o1', 'chat:o2'))
    }
    function Use-Store([scriptblock]$Body) {
        $s = [TeamsTransfer.TmtStore]::Open((New-Root), ([TeamsTransfer.StoreOptions]@{ Partitions = 8; FlushIntervalMs = 0 }))
        try { Add-Inventory $s; & $Body $s } finally { $s.Dispose() }
    }
    function Invoke-Entry {
        param([string[]]$Arguments)
        $cwd = New-Item -ItemType Directory -Path (Join-Path $script:Temp ('cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -Force | Select-Object -ExpandProperty FullName
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        $psi.WorkingDirectory = $cwd; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script:Entry) { $psi.ArgumentList.Add($a) }
        foreach ($a in $Arguments + '-DevelopmentMode' + '-LogFolder' + (Join-Path $cwd 'logs')) { $psi.ArgumentList.Add([string]$a) }
        foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'TEAMSTRANSFER_LOG_FOLDER') { [void]$psi.Environment.Remove($k) }
        $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = (Join-Path $script:Temp 'no-local-config.psd1')
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw "The entry script did not finish: $($Arguments -join ' ')" }
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $e.GetAwaiter().GetResult() }
    }
}

AfterAll {
    if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'TmtStore.CancelLot' {
    It 'releases the items and the coverage, keeps the lot row and its history (state Cancelled) and frees the name' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1'))
            [void]$s.ResolveLot($a, 1)
            @($s.ListItems($a)).Count | Should -Be 3
            $b = New-Lot $s 'L2' @((Member User 'u1'))
            $s.ResolveLot($b, 1).CoveredByOtherLot | Should -Be 3

            $r = $s.CancelLot('L1', 'wrong scope')
            [string]$r.State | Should -Be 'Cancelled'
            $r.Id | Should -Be $a
            $r.Name | Should -Be "L1~cancelled-$a"
            $s.GetLot('L1') | Should -BeNullOrEmpty
            @($s.ListItems($a)).Count | Should -Be 0
            $h = @($s.LotHistory($a))
            [string]$h[-1].To | Should -Be 'Cancelled'
            [string]$h[-1].From | Should -Be 'Planned'
            $h[-1].Note | Should -Be 'wrong scope'
            @($s.ListLotMembers($a)).Count | Should -Be 1

            # the conversations are free again, and the name can be used again
            $s.ResolveLot($b, 1).Planned | Should -Be 3
            { New-Lot $s 'L1' @((Member User 'u1')) } | Should -Not -Throw
        }
    }
    It 'works by id, from Exported and ImportPlanned, and refuses a second cancel' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1'))
            [void]$s.ResolveLot($a, 1)
            foreach ($st in 'Exporting', 'Exported', 'ImportPlanned') { [void]$s.TransitionLot($a, $st) }
            [string]$s.CancelLot([long]$a, $null).State | Should -Be 'Cancelled'
            @($s.LotHistory($a))[-1].Note | Should -Be 'cancelled'
            { $s.CancelLot([long]$a, 'again') } | Should -Throw '*already Cancelled*'
        }
    }
    It 'works on a Paused or Failed lot' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1')); [void]$s.TransitionLot($a, 'Failed')
            [string]$s.CancelLot('L1', 'x').State | Should -Be 'Cancelled'
            $b = New-Lot $s 'L2' @((Member User 'u2')); [void]$s.TransitionLot($b, 'Paused')
            [string]$s.CancelLot('L2', 'x').State | Should -Be 'Cancelled'
        }
    }
    It 'refuses a lot that has started importing (an import session exists for its items), with a clear message' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1'))
            [void]$s.ResolveLot($a, 1)
            [void]$s.BeginImportSession('chat:g1', 1, 'app-1', [DateTimeOffset]::Parse('2022-12-31T23:59:59Z'), 'target-1')
            $s.CountImportSessions($a) | Should -Be 1
            { $s.CancelLot('L1', 'x') } | Should -Throw '*lot L1 has started importing (1 session): it cannot be cancelled; finish or verify it*'
            [string]$s.GetLot('L1').State | Should -Be 'Planned'
            @($s.ListItems($a)).Count | Should -Be 3
        }
    }
    It 'refuses the states after ImportPlanned and unknown lots; Cancelled is final and no plan can resolve it' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1'))
            foreach ($st in 'Exporting', 'Exported', 'ImportPlanned', 'Importing') { [void]$s.TransitionLot($a, $st) }
            { $s.CancelLot('L1', 'x') } | Should -Throw '*cannot be cancelled*'
            { $s.CancelLot('nope', 'x') } | Should -Throw '*No lot*'
            [TeamsTransfer.TmtStore]::IsLegalTransition('Planned', 'Cancelled', $null) | Should -BeFalse
            [TeamsTransfer.TmtStore]::IsLegalTransition('Cancelled', 'Planned', $null) | Should -BeFalse
            [TeamsTransfer.TmtStore]::IsLegalTransition('Cancelled', 'Paused', $null) | Should -BeFalse
            $c = New-Lot $s 'L3' @((Member User 'u2'))
            [void]$s.CancelLot('L3', 'x')
            { $s.ResolveLot($c, 1) } | Should -Throw '*Cancelled*'
            { $s.TransitionLot($c, 'Exporting') } | Should -Throw '*Illegal*'
        }
    }
    It 'removes the Pending journal rows seeded by a plan for the cancelled items' {
        Use-Store {
            param($s)
            $a = New-Lot $s 'L1' @((Member User 'u1'))
            [void]$s.ResolveLot($a, 1)
            $s.GetLotJournalSummary($a)[[TeamsTransfer.JournalStatus]::Pending] | Should -Be 0
            [void]$s.CancelLot('L1', 'x')
            $s.GetLotJournalSummary($a)[[TeamsTransfer.JournalStatus]::Pending] | Should -Be 0
        }
    }
}

Describe 'A Plan that fails does not leave conversations reserved' {
    BeforeAll {
        $script:Src = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(3)
        $script:Tgt = New-TargetTenant -SourceTenant $script:Src; $script:Svc = New-ServiceAccount -Tenant $script:Tgt
        $script:Cl = New-FixtureClient -Tenant $script:Tgt
        $script:StoreP = Open-TmtStore -Root (New-Root) -Partitions 8
        $src = New-FixtureClient -Tenant $script:Src
        $now = [datetimeoffset]'2026-11-09T00:00:00Z'
        $io = [TeamsTransfer.InventoryOptions]::new(); $io.Now = [Func[datetimeoffset]]{ $now }.GetNewClosure()
        [void][TeamsTransfer.Inventory]::new($src.Client, $script:StoreP, $io).RunAsync($script:Ct).GetAwaiter().GetResult()
        $eo = [TeamsTransfer.ExportOptions]::new(); $eo.Now = $io.Now; $eo.IncludeChannels = $true
        [void][TeamsTransfer.Exporter]::new($src.Client, $script:StoreP, $eo).RunAsync($null, $script:Ct).GetAwaiter().GetResult()
        $script:StoreP.Flush()
        $script:PlanArgs = @{ Client = $script:Cl.Client; DomainMap = 'contoso.com=northwind.com'; GhostDomain = 'northwind.com'; IntervalSeconds = 1 }
    }
    AfterAll { $script:StoreP.Dispose() }

    It 'cancels the lot it created on the fly when the run throws, so that the next Plan finds the conversations free' {
        $before = @($script:StoreP.ListLots()).Count
        { New-TmtImportPlan -Store $script:StoreP -Users 'camille.martin@contoso.com' -ServiceAccount 'nobody@northwind.com' -OutputFolder (Join-Path $script:Temp 'p1') @script:PlanArgs } | Should -Throw '*does not exist in the target tenant*'
        $lots = @($script:StoreP.ListLots())
        $lots.Count | Should -Be ($before + 1)
        [string]$lots[-1].State | Should -Be 'Cancelled'
        $lots[-1].Name | Should -Match '^plan-\d{8}-\d{6}~cancelled-\d+$'
        @($script:StoreP.ListItems($lots[-1].Id)).Count | Should -Be 0
        @($script:StoreP.LotHistory($lots[-1].Id))[-1].Note | Should -Match '^Plan failed: .*does not exist'

        $ok = New-TmtImportPlan -Store $script:StoreP -Users 'camille.martin@contoso.com' -ServiceAccount 'svc-migration@northwind.com' -OutputFolder (Join-Path $script:Temp 'p2') @script:PlanArgs
        $ok.Created | Should -BeTrue
        $ok.Plan.Conversations | Should -BeGreaterThan 0
        ($ok.Plan.Warnings -join "`n") | Should -Not -Match 'already covered by another lot'
        [string]$script:StoreP.GetLot($ok.LotName).State | Should -Be 'ImportPlanned'
    }
    It 'never cancels a lot named by the operator (-Lot), whatever happens' {
        $id = New-Lot $script:StoreP 'explicit' @((Member User 'julien.lefevre@contoso.com'))
        [void]$script:StoreP.TransitionLot($id, 'Exporting'); [void]$script:StoreP.TransitionLot($id, 'Exported')
        { New-TmtImportPlan -Store $script:StoreP -Lot 'explicit' -ServiceAccount 'nobody@northwind.com' -OutputFolder (Join-Path $script:Temp 'p3') @script:PlanArgs } | Should -Throw '*does not exist in the target tenant*'
        [string]$script:StoreP.GetLot('explicit').State | Should -Be 'Exported'
    }
    It 'a plan with a blocker is not an error: the lot created on the fly stays for the operator to fix' {
        $r = New-TmtImportPlan -Store $script:StoreP -Users 'sophie.bernard@contoso.com' -OutputFolder (Join-Path $script:Temp 'p4') -Offline
        $r.Created | Should -BeTrue
        [string]$script:StoreP.GetLot($r.LotName).State | Should -Not -Be 'Cancelled'
    }
}

Describe 'Invoke-TmtLotExport: lots with chat and channel members' {
    BeforeAll {
        function New-LotStore {
            # inventory only (no message yet): the lot export is what reads the messages
            $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(3)
            $src = New-FixtureClient -Tenant $t
            $store = Open-TmtStore -Root (New-Root) -Partitions 8
            $now = [datetimeoffset]'2026-11-09T00:00:00Z'
            $io = [TeamsTransfer.InventoryOptions]::new(); $io.Now = [Func[datetimeoffset]]{ $now }.GetNewClosure()
            [void][TeamsTransfer.Inventory]::new($src.Client, $store, $io).RunAsync($script:Ct).GetAwaiter().GetResult()
            [pscustomobject]@{ Store = $store; Src = $src; Tenant = $t }
        }
    }

    It 'exports exactly the chat and channel members with strategy C and moves the lot Planned -> Exporting -> Exported' {
        $e = New-LotStore
        try {
            $chats = @($e.Store.ListConversations() | Where-Object { [string]$_.Kind -ne 'Channel' })
            $channel = @($e.Store.ListConversations() | Where-Object { [string]$_.Kind -eq 'Channel' })[0]
            $c1 = $chats[0]; $c2 = $chats[1]; $other = $chats[2]
            $id = New-Lot $e.Store 'chat-lot' @((Member Chat $c1.Key), (Member Chat ($c2.Key -replace '^chat:', '')), (Member Channel $channel.Key))
            $r = Invoke-TmtLotExport -Store $e.Store -Lot 'chat-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1 }
            $r.Complete | Should -BeTrue
            $r.StateMoved | Should -BeTrue
            @($r.Results).Count | Should -Be 1
            $r.Results[0].Strategy | Should -Be 'C'
            $r.Results[0].UnitsFailed | Should -Be 0
            [string]$e.Store.GetLot('chat-lot').State | Should -Be 'Exported'
            $h = @($e.Store.LotHistory($id) | ForEach-Object { [string]$_.To })
            $h | Should -Be @('Planned', 'Exporting', 'Exported')
            $e.Store.CountMessages($c1.Key) | Should -BeGreaterThan 0
            $e.Store.CountMessages($c2.Key) | Should -BeGreaterThan 0
            $e.Store.CountMessages($channel.Key) | Should -BeGreaterThan 0
            $e.Store.CountMessages($other.Key) | Should -Be 0     # a lot only exports its own members
        } finally { $e.Store.Dispose() }
    }
    It 'stays Exporting when a unit fails, and moves to Exported when the same command is run again' {
        $e = New-LotStore
        try {
            $c1 = @($e.Store.ListConversations() | Where-Object { [string]$_.Kind -ne 'Channel' })[0]
            [void](New-Lot $e.Store 'retry-lot' @((Member Chat $c1.Key)))
            $rule = $e.Src.Fake.Faults.FailUrl('chats/.*/messages', 403, 'Forbidden', 'GET', 0)
            $r1 = Invoke-TmtLotExport -Store $e.Store -Lot 'retry-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1 }
            $r1.Complete | Should -BeFalse
            [string]$e.Store.GetLot('retry-lot').State | Should -Be 'Exporting'
            $e.Src.Fake.Faults.Clear()
            $r2 = Invoke-TmtLotExport -Store $e.Store -Lot 'retry-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1 }
            $r2.Complete | Should -BeTrue
            [string]$e.Store.GetLot('retry-lot').State | Should -Be 'Exported'
        } finally { $e.Store.Dispose() }
    }
    It 'keeps user members working (strategy U for their chats)' {
        $e = New-LotStore
        try {
            [void](New-Lot $e.Store 'user-lot' @((Member User 'camille.martin@contoso.com')))
            $r = Invoke-TmtLotExport -Store $e.Store -Lot 'user-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1 }
            $r.Complete | Should -BeTrue
            $r.Results[0].Strategy | Should -Be 'Auto'
            $r.Results[0].MessagesSeen | Should -BeGreaterThan 0
            [string]$e.Store.GetLot('user-lot').State | Should -Be 'Exported'
        } finally { $e.Store.Dispose() }
    }
    It 'a team member needs -IncludeChannels to be complete; a lot already planned for import keeps its state' {
        $e = New-LotStore
        try {
            $team = @($e.Store.ListConversations() | Where-Object { [string]$_.Kind -eq 'Channel' })[0].TeamId
            [void](New-Lot $e.Store 'team-lot' @((Member Team $team)))
            $r = Invoke-TmtLotExport -Store $e.Store -Lot 'team-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1 }
            $r.Complete | Should -BeFalse
            ($r.Warnings -join ' ') | Should -Match 'IncludeChannels'
            [string]$e.Store.GetLot('team-lot').State | Should -Be 'Exporting'
            $r = Invoke-TmtLotExport -Store $e.Store -Lot 'team-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1; IncludeChannels = $true }
            $r.Complete | Should -BeTrue
            [string]$e.Store.GetLot('team-lot').State | Should -Be 'Exported'
            $id = $e.Store.GetLot('team-lot').Id
            [void]$e.Store.TransitionLot($id, 'ImportPlanned')
            $r = Invoke-TmtLotExport -Store $e.Store -Lot 'team-lot' -ExportArguments @{ Client = $e.Src.Client; IntervalSeconds = 1; IncludeChannels = $true }
            $r.StateMoved | Should -BeFalse
            [string]$e.Store.GetLot('team-lot').State | Should -Be 'ImportPlanned'
            { Invoke-TmtLotExport -Store $e.Store -Lot 'nope' -ExportArguments @{} } | Should -Throw '*not found*'
        } finally { $e.Store.Dispose() }
    }
}

Describe 'Entry script: -Mode Status and -CancelLot' {
    BeforeAll {
        function New-DiskStore2([string]$Root) {
            $s = Open-TmtStore -Root $Root -Partitions 8
            try {
                Add-Inventory $s
                $list = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                foreach ($n in 1..5) { $list.Add([Text.Json.JsonDocument]::Parse((@{ id = "m$n"; createdDateTime = "2026-01-01T08:0$n`:00.000Z"; lastModifiedDateTime = "2026-01-01T08:0$n`:00.000Z"; body = @{ contentType = 'html'; content = "m$n" } } | ConvertTo-Json -Depth 5 -Compress)).RootElement) }
                [void]$s.AppendMessages('chat:g1', $list)
                $a = New-Lot $s 'lot-a' @((Member User 'u1')); [void]$s.ResolveLot($a, 1)
                $b = New-Lot $s 'lot-b' @((Member Chat 'chat:zzz'))
                $s.Flush()
            } finally { $s.Dispose() }
        }
    }
    It 'shows the conversations inventoried and the ones with messages, and every lot with its items per state and journal summary' {
        $root = Join-Path $script:Temp 'st1'; New-DiskStore2 $root
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root)
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '3 conversations inventoried, 1 with messages \(5 messages\)'
        $r.Out | Should -Match 'lot lot-a: Planned, 3 item\(s\) \(3 Planned\)'
        $r.Out | Should -Match 'lot lot-b: Planned, no item'
    }
    It 'the status object exposes Id, Items, ItemsByState, Sessions and Journal per lot (what the console reads)' {
        $root = Join-Path $script:Temp 'st2'; New-DiskStore2 $root
        $s = Open-TmtStore -Root $root -ReadOnly
        try {
            $st = Get-TmtStoreStatus -Store $s
            $st.InventoriedConversations | Should -Be 3
            $st.Conversations | Should -Be 1
            $l = $st.Lots | Where-Object Name -eq 'lot-a'
            $l.Items | Should -Be 3
            $l.ItemsByState['Planned'] | Should -Be 3
            $l.Sessions | Should -Be 0
            $l.Journal.Imported | Should -Be 0
            $l.Journal.Pending | Should -Be 0
            $l.Id | Should -BeGreaterThan 0
        } finally { $s.Dispose() }
    }
    It '-CancelLot -Force cancels the lot, says so and lists it as Cancelled; the store keeps the audit row' {
        $root = Join-Path $script:Temp 'st3'; New-DiskStore2 $root
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-Lot', 'lot-a', '-CancelLot', '-Reason', 'wrong scope', '-Force')
        $r.ExitCode | Should -Be 0 -Because ($r.Out + $r.Err)
        $r.Out | Should -Match 'Lot lot-a cancelled \(3 item\(s\)'
        $r.Out | Should -Match 'Cancelled, no item'
        $s = Open-TmtStore -Root $root -ReadOnly
        try {
            $l = @($s.ListLots() | Where-Object { [string]$_.State -eq 'Cancelled' })
            $l.Count | Should -Be 1
            @($s.LotHistory($l[0].Id))[-1].Note | Should -Be 'wrong scope'
        } finally { $s.Dispose() }
    }
    It '-CancelLot without -Force in a session that cannot ask: refused, the lot is unchanged' {
        $root = Join-Path $script:Temp 'st4'; New-DiskStore2 $root
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-Lot', 'lot-a', '-CancelLot')
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'needs a confirmation'
        $s = Open-TmtStore -Root $root -ReadOnly
        try { [string]$s.GetLot('lot-a').State | Should -Be 'Planned' } finally { $s.Dispose() }
    }
    It '-CancelLot on a lot that started importing: refused with the clear message' {
        $root = Join-Path $script:Temp 'st5'; New-DiskStore2 $root
        $s = Open-TmtStore -Root $root
        try { [void]$s.BeginImportSession('chat:g1', 1, 'app-1', [DateTimeOffset]::Parse('2022-12-31T23:59:59Z'), 't1') } finally { $s.Dispose() }
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-Lot', 'lot-a', '-CancelLot', '-Force')
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'lot lot-a has started importing \(1 session\): it cannot be cancelled; finish or verify it'
    }
    It 'refuses wrong combinations before touching the store' {
        $root = Join-Path $script:Temp 'st6'; New-DiskStore2 $root
        (Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-CancelLot')).Out | Should -Match '-CancelLot needs the lot'
        (Invoke-Entry -Arguments @('-Mode', 'Status', '-StoreRoot', $root, '-Force')).Out | Should -Match '-Force applies to -Mode Status only with -CancelLot'
        (Invoke-Entry -Arguments @('-Mode', 'Plan', '-StoreRoot', $root, '-CancelLot', '-Lot', 'x')).Out | Should -Match '-CancelLot does not apply to -Mode Plan'
    }
}
