#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Export.cs (Exporter U / C / Auto, channels, hosted contents, files, Assess) against the fake Graph
# (Tiny / Small synthetic tenants) and tests\support\MemoryExportStore.cs.
# The 'Volume' test (>= 1,000,000 messages) is skipped unless TMT_VOLUME=1; run it with:
#   $env:TMT_VOLUME = '1'; Invoke-Pester -Path tests\Export.Tests.ps1 -TagFilter Volume

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None
    $script:FT = [TeamsTransfer.Testing.FakeTime]
    $script:Cls = [TeamsTransfer.EndpointClass]

    function New-Env {
        param($Tenant, [int]$MaxAttempts = 3, [switch]$WithLimiter, [switch]$HideImported, [switch]$KeepNoBodies, [switch]$ExpandReplies)
        $clock = [TeamsTransfer.TestManualClock]::new()
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($Tenant)
        $transport = if ($HideImported) { [TeamsTransfer.Testing.ImportedHidingTransport]::new($fake) } else { $fake }
        $expander = $null
        if ($ExpandReplies) { $expander = [TeamsTransfer.Testing.ExpandRepliesTransport]::new($transport); $transport = $expander }
        $strict = [TeamsTransfer.Testing.StrictFilterTransport]::new($transport); $transport = $strict
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = $clock; $o.MaxAttempts = $MaxAttempts
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(4)
        $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $lim = if ($WithLimiter) { [TeamsTransfer.AdaptiveRateLimiter]::new($o.ToRateLimiterOptions()) } else { $null }
        $metrics = [TeamsTransfer.GraphMetrics]::new()
        $client = [TeamsTransfer.GraphClient]::new($transport, $o, $lim, [Action[TeamsTransfer.GraphEvent]]$metrics.OnEvent)
        $metrics.Attach($client)
        $store = [TeamsTransfer.Testing.MemoryExportStore]::new()
        if ($KeepNoBodies) { $store.KeepBodies = $false }
        $now = [TeamsTransfer.Testing.TestNow]::new('2026-11-09T00:00:00Z')
        [pscustomobject]@{ Tenant = $Tenant; Fake = $fake; Strict = $strict; Expander = $expander; Transport = $transport; Client = $client; Clock = $clock; Metrics = $metrics; Store = $store; Now = $now }
    }
    function Invoke-Inventory($env) {
        $o = [TeamsTransfer.InventoryOptions]::new(); $o.Now = $env.Now.Func
        [TeamsTransfer.Inventory]::new($env.Client, $env.Store, $o).RunAsync($script:ct).GetAwaiter().GetResult()
    }
    function New-Exporter($env, [scriptblock]$Configure) {
        $o = [TeamsTransfer.ExportOptions]::new()
        $o.Now = $env.Now.Func
        if ($Configure) { & $Configure $o }
        [TeamsTransfer.Exporter]::new($env.Client, $env.Store, $o)
    }
    function Invoke-Export($env, [scriptblock]$Configure, $Users) {
        $x = New-Exporter $env $Configure
        $x.RunAsync($Users, $script:ct).GetAwaiter().GetResult()
    }
    function Test-Active($u) { -not $u.Deleted -and -not $u.External }
    function Get-ReachableChats($t) {
        @($t.Chats | Where-Object { $chat = $_; @($chat.Members | Where-Object { Test-Active $t.Users[$_.UserOrd] }).Count -gt 0 })
    }
    function Get-ChatMessageCount($t) { [long](($t.Chats | Where-Object { $chat = $_; @($chat.Members | Where-Object { Test-Active $t.Users[$_.UserOrd] }).Count -gt 0 } | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum) }
    function Get-ChannelMessageCount($t) { [long](($t.Teams | ForEach-Object { $_.Channels } | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum) }
    function Get-ExpectedChatIds($t) {
        $h = @{}
        foreach ($c in (Get-ReachableChats $t)) { $h["chat:$($c.Id)"] = @($c.Messages | ForEach-Object { $_.CreatedMs.ToString() } | Sort-Object) }
        $h
    }
    function Get-ActualIds($store) {
        $h = @{}
        foreach ($k in $store.ConversationKeysWithMessages()) { $h[$k] = @($store.MessageIds($k)) }
        $h
    }
    function Get-HostedCount($t, [bool]$chats = $true, [bool]$channels = $false) {
        $n = 0
        $threads = @()
        if ($chats) { $threads += Get-ReachableChats $t }
        if ($channels) { $threads += @($t.Teams | ForEach-Object { $_.Channels }) }
        foreach ($th in $threads) { foreach ($m in $th.Messages) { if ($m.X -and $m.X.Hosted) { $n += $m.X.Hosted.Length } } }
        $n
    }
    function New-ChatMessage($chat, [datetimeoffset]$when, [int]$seed = 777) {
        $m = [TeamsTransfer.Testing.FakeMessage]::new()
        $ms = $script:FT::ToMs($when)
        $m.CreatedMs = $ms; $m.ModifiedMs = $ms; $m.AuthorOrd = $chat.Members[0].UserOrd; $m.Seed = $seed
        $chat.AddUnique($m)
    }
}

Describe 'Window planning (incremental watermark arithmetic)' {
    BeforeAll {
        function Plan($from, $to, $bounded, $cov, $incr = $true, $created = $false) {
            $nc = $null
            $ranges = [TeamsTransfer.WindowPlanner]::Plan($from, [datetimeoffset]$to, $bounded, $cov, $incr, [TimeSpan]::FromMinutes(2), $created, [ref]$nc)
            [pscustomobject]@{ Ranges = @($ranges); Covered = $nc }
        }
        function Cov($f, $t) { $c = [TeamsTransfer.CoveredInterval]::new(); if ($f) { $c.From = [datetimeoffset]$f }; $c.To = [datetimeoffset]$t; $c }
    }
    It 'reads everything the first time' {
        $p = Plan $null '2026-11-09T00:00:00Z' $false $null
        $p.Ranges.Count | Should -Be 1
        $p.Ranges[0].From | Should -BeNullOrEmpty
        $p.Covered.To | Should -Be ([datetimeoffset]'2026-11-09T00:00:00Z')
    }
    It 'reads only the delta (minus the overlap) the second time and nothing when nothing is new' {
        $cov = Cov $null '2026-11-09T00:00:00Z'
        $p = Plan $null '2026-11-10T00:00:00Z' $false $cov
        $p.Ranges.Count | Should -Be 1
        $p.Ranges[0].From | Should -Be ([datetimeoffset]'2026-11-08T23:58:00Z')
        $p.Ranges[0].Delta | Should -BeTrue
        (Plan $null '2026-11-09T00:00:00Z' $false $cov).Ranges.Count | Should -Be 0
    }
    It 'extends a covered window backwards (wave 2) and forwards in two ranges' {
        $cov = Cov '2025-11-09T00:00:00Z' '2026-11-09T00:00:00Z'
        $p = Plan ([datetimeoffset]'2024-11-09T00:00:00Z') '2026-11-10T00:00:00Z' $false $cov
        $p.Ranges.Count | Should -Be 2
        $p.Ranges[0].To | Should -Be ([datetimeoffset]'2025-11-09T00:00:00Z')
        $p.Ranges[0].ToBounded | Should -BeTrue
        $p.Ranges[1].Delta | Should -BeTrue
        $p.Covered.From | Should -Be ([datetimeoffset]'2024-11-09T00:00:00Z')
    }
    It 'uses createdDateTime for the initial ranges of a conversation with imported content' {
        (Plan $null '2026-11-09T00:00:00Z' $false $null $true $true).Ranges[0].ByCreated | Should -BeTrue
        (Plan $null '2026-11-10T00:00:00Z' $false (Cov $null '2026-11-09T00:00:00Z') $true $true).Ranges[0].ByCreated | Should -BeFalse
    }
    It 're-reads the whole window when not incremental' {
        (Plan $null '2026-11-09T00:00:00Z' $false (Cov $null '2026-11-09T00:00:00Z') $false).Ranges.Count | Should -Be 1
    }
}

Describe 'Export - strategies U and C' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:eu = New-Env $t
        [void](Invoke-Inventory $eu)
        $script:ru = Invoke-Export $eu { param($o) $o.Strategy = 'U' }
        $script:ec = New-Env $t
        [void](Invoke-Inventory $ec)
        $script:rc = Invoke-Export $ec { param($o) $o.Strategy = 'C' }
    }
    It 'U exports every message of every reachable chat, once' {
        $ru.UnitsFailed | Should -Be 0
        $ru.MessagesNew | Should -Be (Get-ChatMessageCount $t)
        $eu.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $ru.MessagesUnchanged | Should -BeGreaterThan 0          # group chats are read by each member, the store deduplicates
        $ru.MessagesSeen | Should -Be ($ru.MessagesNew + $ru.MessagesUpdated + $ru.MessagesUnchanged)
    }
    It 'U and C give the same set of messages for natively posted chats' {
        $rc.UnitsFailed | Should -Be 0
        $a = Get-ActualIds $eu.Store; $b = Get-ActualIds $ec.Store
        $a.Keys.Count | Should -Be $b.Keys.Count
        foreach ($k in $a.Keys) { ($b[$k] -join ',') | Should -Be ($a[$k] -join ',') }
        $exp = Get-ExpectedChatIds $t
        foreach ($k in $exp.Keys) { ($a[$k] -join ',') | Should -Be ($exp[$k] -join ',') }
    }
    It 'C reads each conversation once (no repeated messages)' {
        $rc.MessagesSeen | Should -Be $rc.MessagesNew
        $rc.Conversations | Should -Be (Get-ReachableChats $t).Count
    }
    It 'U is much cheaper in calls than C per message page but reads group chats once per member' {
        $callsU = $eu.Fake.Counters.Calls($Cls::ChatGetAllMessages)
        $callsC = $ec.Fake.Counters.Calls($Cls::ChatMessages)
        $callsU | Should -BeGreaterThan 0
        $callsC | Should -BeGreaterThan 0
        $ru.MessagesSeen | Should -BeGreaterThan $rc.MessagesSeen
    }
    It 'keeps a per-user watermark and reports progress counters' {
        $eu.Store.GetCheckpoint("wm:u:$($t.Users[0].Id)") | Should -Match '^-\|20'
        $x = New-Exporter $eu
        $r = $x.ExportUsersAsync([string[]]@($t.Users[0].Id), $ct).GetAwaiter().GetResult()
        $x.Progress.Messages | Should -Be $r.MessagesSeen
        $x.Progress.UnitsDone | Should -Be 1
        $x.Progress.Final | Should -BeTrue
    }
    It 'treats a deleted user as gone, not as an error' {
        $deleted = $t.Users | Where-Object { $_.Deleted -and -not $_.External } | Select-Object -First 1
        $x = New-Exporter $eu
        $r = $x.ExportUsersAsync([string[]]@($deleted.Id), $ct).GetAwaiter().GetResult()
        $r.UsersGone | Should -Be 1
        $r.UnitsFailed | Should -Be 0
    }
}

Describe 'Export - incremental' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:e = New-Env $t
        [void](Invoke-Inventory $e)
        $script:r1 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        # the world changes after the first run: one message is edited, one is posted
        $chat = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $script:chat = $chat
        $script:edited = $chat.Messages | Where-Object { $_.ReplyTo -eq 0 -and -not $_.IsDeleted } | Select-Object -Skip 3 -First 1
        $edited.ModifiedMs = $FT::ToMs([datetimeoffset]'2026-11-09T10:00:00Z')
        $edited.Ext().EditedMs = $edited.ModifiedMs
        $chat.Touch()
        $script:posted = New-ChatMessage $chat ([datetimeoffset]'2026-11-09T11:00:00Z')
        $e.Now.Set('2026-11-10T00:00:00Z')
        $script:r2 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $script:r3 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
    }
    It 'the second pass picks only the edit and the new message' {
        $r2.UnitsFailed | Should -Be 0
        $r2.MessagesNew | Should -Be 1
        $r2.MessagesUpdated | Should -Be 1
        $r2.MessagesSeen | Should -BeLessThan 12            # a handful of messages (seen once per member), not the 230 of the tenant
        $key = "chat:$($chat.Id)"
        $e.Store.Versions($key, $edited.Id.ToString()) | Should -Be 2
        $e.Store.Versions($key, $posted.Id.ToString()) | Should -Be 1
        $e.Store.TotalMessages | Should -Be ((Get-ChatMessageCount $t))
    }
    It 'a third pass at the same instant has nothing to do' {
        $r3.MessagesSeen | Should -Be 0
        $r3.UnitsUpToDate | Should -BeGreaterThan 0
    }
    It 'Full re-reads the whole window, the store still deduplicates' {
        $r4 = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.Incremental = $false }
        $r4.MessagesSeen | Should -BeGreaterThan 200
        $r4.MessagesNew | Should -Be 0
        $r4.MessagesUpdated | Should -Be 0
    }
    It 'an explicit window selects by lastModifiedDateTime' {
        $env2 = New-Env $t
        [void](Invoke-Inventory $env2)
        $r = Invoke-Export $env2 { param($o) $o.Strategy = 'U'; $o.From = [datetimeoffset]'2026-11-09T00:00:00Z'; $o.To = [datetimeoffset]'2026-11-10T00:00:00Z' }
        $r.MessagesNew | Should -Be 2           # the edited and the posted message only
    }
    It 'an extension wave (older window) reads the older part only' {
        $env2 = New-Env $t
        $env2.Now.Set('2026-11-10T00:00:00Z')
        [void](Invoke-Inventory $env2)
        $mid = [datetimeoffset]'2026-10-20T00:00:00Z'
        $a = Invoke-Export $env2 { param($o) $o.Strategy = 'U'; $o.From = $mid }
        $b = Invoke-Export $env2 { param($o) $o.Strategy = 'U'; $o.From = [datetimeoffset]'2025-01-01T00:00:00Z' }
        $env2.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        ($a.MessagesNew + $b.MessagesNew) | Should -Be (Get-ChatMessageCount $t)
        $b.MessagesNew | Should -BeGreaterThan 0
    }
}

Describe 'Export - resume, errors, stop, throttling' {
    It 'resumes from the saved nextLink after a failure in the middle of a user' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 2
        [void](Invoke-Inventory $e)
        $victim = $t.Users | Where-Object { Test-Active $_ } | Sort-Object { ($t.ChatsByUser[$_.Ordinal] | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum } -Descending | Select-Object -First 1
        ($t.ChatsByUser[$victim.Ordinal] | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum | Should -BeGreaterThan 100
        [void]$e.Fake.Faults.FailUrl("users/$($victim.Id)/chats/getAllMessages.*skiptoken", 500, 'InternalServerError', 'GET', 2)
        $r1 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $r1.UnitsFailed | Should -Be 1
        $r1.FailedUnits | Should -Contain "u:$($victim.Id)"
        $r1.Errors[0].StatusCode | Should -Be 500
        $saved = $e.Store.GetCheckpoint("gam:$($victim.Id)")
        $saved | Should -Match 'skiptoken'
        $e.Store.GetCheckpoint("wm:u:$($victim.Id)") | Should -BeNullOrEmpty       # the watermark did not move
        $e.Store.GetCheckpoint("err:u:$($victim.Id)") | Should -Not -BeNullOrEmpty

        $e.Fake.Faults.Clear()
        $e.Fake.Counters.Reset(); $e.Fake.Counters.LogEnabled = $true
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $r2.UnitsFailed | Should -Be 0
        $e.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $first = $e.Fake.Counters.Log | Where-Object { $_.Url -match "users/$($victim.Id)/chats/getAllMessages" } | Select-Object -First 1
        $first.Url | Should -Match 'skiptoken'                   # the retry started at the saved page, not at the beginning
        $e.Store.GetCheckpoint("gam:$($victim.Id)") | Should -BeNullOrEmpty
        $e.Store.GetCheckpoint("err:u:$($victim.Id)") | Should -BeNullOrEmpty
        $e.Store.GetCheckpoint("wm:u:$($victim.Id)") | Should -Not -BeNullOrEmpty
    }
    It 'stops cleanly on request, then a second run completes the export' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $stop = [TeamsTransfer.StopControl]::new()
        [TeamsTransfer.Testing.StoreHooks]::StopAfterAppends($e.Store, $stop, 3)
        $r1 = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.UserParallelism = 1; $o.BatchSize = 20; $o.Stop = $stop }
        $r1.Stopped | Should -BeTrue
        $e.Store.TotalMessages | Should -BeLessThan (Get-ChatMessageCount $t)
        $e.Store.OnAppend = $null
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $r2.Stopped | Should -BeFalse
        $e.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
    }
    It 'stops on a stop file' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $file = Join-Path ([IO.Path]::GetTempPath()) ("tmt-stop-" + [guid]::NewGuid() + '.flag')
        New-Item -ItemType File -Path $file | Out-Null
        try {
            $stop = [TeamsTransfer.StopControl]::new(); $stop.StopFile = $file
            $r = Invoke-Export $e { param($o) $o.Stop = $stop }
            $r.Stopped | Should -BeTrue
            $e.Store.TotalMessages | Should -Be 0
        } finally { Remove-Item -LiteralPath $file -Force }
    }
    It 'honours cancellation' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
        $x = New-Exporter $e
        $task = $x.RunAsync($null, $cts.Token)
        { $task.GetAwaiter().GetResult() } | Should -Throw
    }
    It 'completes through a 429 storm, slower but with the same result' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 10 -WithLimiter
        [void](Invoke-Inventory $e)
        $before = $e.Clock.UtcNow
        [void]$e.Fake.Faults.ThrottleEveryNth($Cls::ChatGetAllMessages, 2, [TimeSpan]::FromSeconds(3))
        [void]$e.Fake.Faults.ThrottleEveryNth($Cls::HostedContent, 3, [TimeSpan]::FromSeconds(1))
        $r = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $r.UnitsFailed | Should -Be 0
        $e.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $e.Metrics.Snapshot().Throttled429 | Should -BeGreaterThan 5
        ($e.Clock.UtcNow - $before).TotalSeconds | Should -BeGreaterThan 10
        $r.HostedFailed | Should -Be 0
    }
    It 'a crash of the store is not swallowed (it is not a Graph problem)' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        [TeamsTransfer.Testing.StoreHooks]::ThrowAtAppend($e.Store, 2)
        { Invoke-Export $e { param($o) $o.Strategy = 'U' } } | Should -Throw '*simulated store crash*'
    }
}

Describe 'Export: window filters and edge cases' {
    It 'getAllMessages filters are always two-sided (the strict test transport would answer 400 otherwise)' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $e.Fake.Counters.Reset(); $e.Fake.Counters.LogEnabled = $true
        $r = Invoke-Export $e { param($o) $o.IncludeChannels = $true; $o.Strategy = 'U' }
        $r.UnitsFailed | Should -Be 0
        $e.Strict.Rejected | Should -Be 0
        $e.Strict.Checked | Should -BeGreaterThan 3
        $urls = @($e.Fake.Counters.Log | Where-Object { $_.Url -match 'getAllMessages' -and $_.Url -notmatch 'skiptoken' } | ForEach-Object { [uri]::UnescapeDataString($_.Url) })
        $urls.Count | Should -BeGreaterThan 3
        foreach ($u in $urls) { $u | Should -Match 'lastModifiedDateTime gt .* and lastModifiedDateTime lt ' }
        # no lower bound requested: a safe minimum is sent, and no upper bound: now + 5 minutes
        $urls[0] | Should -Match 'gt 1999-12-31T23:59:59\.999Z'
        $urls[0] | Should -Match 'lt 2026-11-09T00:05:00\.000Z'
        # an explicit window is used as given; the delta keeps both bounds too
        $e.Now.Set('2026-11-10T00:00:00Z')
        $e.Fake.Counters.Reset(); $e.Fake.Counters.LogEnabled = $true
        [void](Invoke-Export $e { param($o) $o.IncludeChannels = $true; $o.Strategy = 'U' })
        $e.Strict.Rejected | Should -Be 0
        $e.Fake.Counters.Log | Where-Object { $_.Url -match 'getAllMessages' } | ForEach-Object { [uri]::UnescapeDataString($_.Url) } | ForEach-Object { $_ | Should -Match 'lt 2026-11-10T00:05:00' }
    }
    It 'the strict transport itself rejects a one-sided filter' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $strict = [TeamsTransfer.Testing.StrictFilterTransport]::new([TeamsTransfer.Testing.FakeGraphTransport]::new($t))
        $u = $t.Users[0].Id
        $req = [TeamsTransfer.GraphRequest]::new(); $req.Url = "v1.0/users/$u/chats/getAllMessages?model=B&`$filter=lastModifiedDateTime%20gt%202020-01-01T00:00:00Z"
        $strict.SendAsync($req, $ct).GetAwaiter().GetResult().StatusCode | Should -Be 400
        $req2 = [TeamsTransfer.GraphRequest]::new(); $req2.Url = "v1.0/users/$u/chats/getAllMessages?model=B&`$filter=lastModifiedDateTime%20gt%202020-01-01T00:00:00Z%20and%20lastModifiedDateTime%20lt%202030-01-01T00:00:00Z"
        $strict.SendAsync($req2, $ct).GetAwaiter().GetResult().StatusCode | Should -Be 200
    }
    It 'by default only the users the inventory covered are exported (linked to a conversation, not deleted)' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $one = $t.Users | Where-Object { Test-Active $_ } | Select-Object -First 1
        $o = [TeamsTransfer.InventoryOptions]::new(); $o.Now = $e.Now.Func; $o.OnlyUsers = [string[]]@($one.Upn); $o.IncludeTeams = $false
        [void][TeamsTransfer.Inventory]::new($e.Client, $e.Store, $o).RunAsync($ct).GetAwaiter().GetResult()
        $e.Store.UserCount | Should -BeGreaterThan 3                     # the directory users were all stored...
        $r = Invoke-Export $e { param($o) $o.Strategy = 'U' }
        $r.UnitsDone | Should -Be 1                                       # ...but only the covered one is exported
        $r.Conversations + $r.MessagesNew | Should -BeGreaterThan 0
        $x = New-Exporter $e
        @($x.ResolveDefaultUsers($false)) | Should -Be @($one.Id)
        @($x.ResolveDefaultUsers($true)).Count | Should -BeGreaterThan 1
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.AllStoreUsers = $true }
        $r2.UnitsDone + $r2.UnitsUpToDate + $r2.UsersGone | Should -BeGreaterThan 1
    }
    It 'warns when more than 1000 users would be exported without -Users' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $users = 1..1500 | ForEach-Object { $u = [TeamsTransfer.UserRecord]::new(); $u.Id = "ghost-$_"; $u.State = 'Active'; $u }
        $e.Store.UpsertUsers([TeamsTransfer.UserRecord[]]$users)
        $fc = [TeamsTransfer.ConversationRecord]::new(); $fc.Key = 'chat:fake'; $fc.ChatId = 'fake'; $e.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($fc))
        foreach ($u in $users) { $e.Store.LinkUserConversations($u.Id, [string[]]@('chat:fake')) }
        $r = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.IncludeChats = $true }
        $r.Warnings -join ' ' | Should -Match '1500 users linked'
        $r.UsersGone | Should -Be 1500                                    # unknown to the directory: gone, not an error
        $r.UnitsFailed | Should -Be 0
    }
    It 'the circuit breaker stops a run where the same error hits the first units with no success' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $e = New-Env $t -MaxAttempts 2
        [void](Invoke-Inventory $e)
        [void]$e.Fake.Faults.FailUrl('chats/getAllMessages', 403, 'Forbidden', 'GET', 0)
        $ex = $null
        try { Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.UserParallelism = 4 } } catch { $ex = $_.Exception }
        $ex | Should -Not -BeNullOrEmpty
        $ex.ToString() | Should -Match 'systematic failure: 403 Forbidden .* on users\.chats\.getAllMessages; nothing exported; fix the cause and run again'
        $e.Fake.Counters.Calls($Cls::ChatGetAllMessages) | Should -BeLessThan 60       # 25 units, not the 170 users of the tenant
    }
    It 'a few failing users do not stop the run' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 2
        [void](Invoke-Inventory $e)
        [void]$e.Fake.Faults.FailUrl('chats/getAllMessages', 403, 'Forbidden', 'GET', 0)
        $r = Invoke-Export $e { param($o) $o.Strategy = 'U' }       # 3 users, all failing: below the 25-unit threshold
        $r.UnitsFailed | Should -Be 3
        $r.Errors[0].StatusCode | Should -Be 403
    }
    It 'a failing minority after a success does not trip the breaker even with a low threshold' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 2
        [void](Invoke-Inventory $e)
        $ids = [string[]]@($t.Users | Where-Object { Test-Active $_ } | ForEach-Object Id); [Array]::Sort($ids, [StringComparer]::Ordinal)
        $victims = @($ids | Select-Object -Skip 1)
        foreach ($v in $victims) { [void]$e.Fake.Faults.FailUrl("users/$v/chats/getAllMessages", 403, 'Forbidden', 'GET', 0) }
        $r = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.UserParallelism = 1; $o.CircuitBreakerUnits = 2 }
        $r.UnitsFailed | Should -Be $victims.Count
        $r.UnitsDone | Should -Be 1
    }
}

Describe 'Imported conversations found by the inventory (no Assess needed)' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $chat = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $script:chat = $chat; $script:key = "chat:$($chat.Id)"
        $min = $FT::ToMs([datetimeoffset]::MinValue)
        foreach ($m in @($chat.Messages | Where-Object { $_.ReplyTo -eq 0 } | Select-Object -First 5)) {
            $m.ModifiedMs = $min; $m.Flags = [byte]($m.Flags -bor [TeamsTransfer.Testing.FakeMessage]::FlagImported)
        }
        $chat.MigrationMode = 'completed'      # what real Graph reports on a chat that went through the import API
        $chat.Touch()
    }
    It 'Auto exports them by C because the inventory flagged them, without any Assess' {
        $e = New-Env $t -HideImported
        $inv = Invoke-Inventory $e
        $e.Store.GetConversation($key).HasImportedContent | Should -BeTrue
        $r = Invoke-Export $e { param($o) $o.Strategy = 'Auto' }
        $e.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $e.Store.CountMessages($key) | Should -Be $chat.Messages.Count
        $r.Conversations | Should -Be 1
    }
    It 'U alone misses them (control)' {
        $e = New-Env $t -HideImported
        [void](Invoke-Inventory $e)
        [void](Invoke-Export $e { param($o) $o.Strategy = 'U' })
        $e.Store.CountMessages($key) | Should -Be ($chat.Messages.Count - 5)
    }
    It 'an Assess comparison that finds nothing never clears a flag set by the inventory' {
        $clean = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' -and $_.Id -ne $chat.Id } | Select-Object -First 1
        $clean.MigrationMode = 'completed'          # flagged by the service but with no hidden message: the comparison finds nothing
        try {
            $e = New-Env $t -HideImported
            [void](Invoke-Inventory $e)
            $ao = [TeamsTransfer.AssessOptions]::new(); $ao.SampleUsers = 100; $ao.CompareChats = 100; $ao.Now = $e.Now.Func; $ao.ExportRequestsPerSecond = 10
            $rep = [TeamsTransfer.Assessor]::new($e.Client, $ao, $e.Store).RunAsync($ct).GetAwaiter().GetResult()
            ($rep.Comparisons | Where-Object Conversation -eq "chat:$($clean.Id)").ImportedContent | Should -BeFalse
            $e.Store.GetConversation("chat:$($clean.Id)").HasImportedContent | Should -BeTrue
            $e.Store.GetConversation($key).HasImportedContent | Should -BeTrue
        } finally { $clean.MigrationMode = $null }
    }
    It 'a flagged channel is read channel by channel (the team stream does not return imported messages)' {
        $ts = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $team = $ts.Teams[1]; $ch = $team.Channels[0]
        $ch.MigrationMode = 'completed'
        $e = New-Env $ts
        [void](Invoke-Inventory $e)
        $e.Store.GetConversation("channel:$($team.Id)/$($ch.Id)").HasImportedContent | Should -BeTrue
        $x = New-Exporter $e { param($o) $o.IncludeChannels = $true }
        $r = $x.ExportTeamsAsync([string[]]@($team.Id), $ct).GetAwaiter().GetResult()
        $e.Store.TotalMessages | Should -Be (($team.Channels | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum)
        $e.Fake.Counters.Calls($Cls::ChannelMessages) | Should -BeGreaterThan 0
    }
}

Describe 'Auto with scoped users reads the flagged chats of those users by C' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $chat = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $script:chat = $chat; $script:key = "chat:$($chat.Id)"
        $min = $FT::ToMs([datetimeoffset]::MinValue)
        $script:nHidden = 0
        foreach ($m in @($chat.Messages | Where-Object { $_.ReplyTo -eq 0 } | Select-Object -First 6)) {
            $m.ModifiedMs = $min; $m.Flags = [byte]($m.Flags -bor [TeamsTransfer.Testing.FakeMessage]::FlagImported); $nHidden++
        }
        $chat.MigrationMode = 'completed'
        $chat.Touch()
        $script:member = $t.Users[$chat.Members[0].UserOrd]
    }
    It 'users given as UPNs, window 36m, a flagged chat of a scoped user: C reads it in full, the summary says so' {
        $e = New-Env $t -HideImported
        [void](Invoke-Inventory $e)
        $e.Store.GetConversation($key).HasImportedContent | Should -BeTrue
        $upn = [string[]]@($member.Upn)
        $r = Invoke-Export $e { param($o) $o.Strategy = 'Auto'; $o.From = ([datetimeoffset]'2026-11-09T00:00:00Z').AddMonths(-36); $o.IncludeChannels = $false } $upn
        $r.UnitsFailed | Should -Be 0
        $r.ConversationsViaC | Should -BeGreaterOrEqual 1
        $r.Summary | Should -Match 'read with strategy C'
        $e.Store.CountMessages($key) | Should -Be $chat.Messages.Count          # the imported messages are there
        $e.Strict.Rejected | Should -Be 0                                       # and no createdDateTime filter was sent
        # the watermark is keyed by id, not by the identity typed
        $e.Store.GetCheckpoint("wm:u:$($member.Id)") | Should -Not -BeNullOrEmpty
        $e.Store.GetCheckpoint("wm:u:$($member.Upn)") | Should -BeNullOrEmpty
    }
    It 'the same with ids, and C is idempotent on a second run' {
        $e = New-Env $t -HideImported
        [void](Invoke-Inventory $e)
        $r1 = Invoke-Export $e { param($o) $o.Strategy = 'Auto' } ([string[]]@($member.Id))
        $e.Store.CountMessages($key) | Should -Be $chat.Messages.Count
        $e.Now.Set('2026-11-10T00:00:00Z')
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'Auto' } ([string[]]@($member.Id))
        $r2.MessagesNew | Should -Be 0
        $e.Store.CountMessages($key) | Should -Be $chat.Messages.Count
    }
    It 'a user who is not a member of the flagged chat does not trigger its C read' {
        $ts = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $gc = Get-ReachableChats $ts | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $gc.MigrationMode = 'completed'
        $memberOrds = @($gc.Members | ForEach-Object UserOrd)
        $other = $ts.Users | Where-Object { (Test-Active $_) -and ($memberOrds -notcontains $_.Ordinal) -and @($ts.ChatsByUser[$_.Ordinal]).Count -gt 0 } | Select-Object -First 1
        $e = New-Env $ts
        [void](Invoke-Inventory $e)
        $e.Store.GetConversation("chat:$($gc.Id)").HasImportedContent | Should -BeTrue
        $r = Invoke-Export $e { param($o) $o.Strategy = 'Auto' } ([string[]]@($other.Id))
        $r.ConversationsViaC | Should -Be 0
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'Auto' } ([string[]]@($ts.Users[$memberOrds[0]].Id))
        $r2.ConversationsViaC | Should -BeGreaterOrEqual 1
    }
}

Describe 'Per-channel reading uses no $filter and no $orderby (real Graph rejects both)' {
    It 'the strict transport rejects them on channel messages and replies' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $strict = [TeamsTransfer.Testing.StrictFilterTransport]::new([TeamsTransfer.Testing.FakeGraphTransport]::new($t))
        $team = $t.Teams[0]; $ch = $team.Channels[0]
        $req = [TeamsTransfer.GraphRequest]::new(); $req.Url = "v1.0/teams/$($team.Id)/channels/$($ch.Id)/messages?`$top=50&`$orderby=lastModifiedDateTime%20desc"
        $strict.SendAsync($req, $ct).GetAwaiter().GetResult().StatusCode | Should -Be 400
        $req2 = [TeamsTransfer.GraphRequest]::new(); $req2.Url = "v1.0/teams/$($team.Id)/channels/$($ch.Id)/messages?`$top=50"
        $strict.SendAsync($req2, $ct).GetAwaiter().GetResult().StatusCode | Should -Be 200
    }
    It 'full and incremental per-channel passes work, with the window applied on the client' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $r1 = Invoke-Export $e { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel' }
        $r1.UnitsFailed | Should -Be 0
        $e.Store.TotalMessages | Should -Be (Get-ChannelMessageCount $t)
        # a root is edited after the first pass
        $ch = $t.Teams[0].Channels[0]
        $root = $ch.Messages | Where-Object { $_.ReplyTo -eq 0 -and -not $_.IsDeleted } | Select-Object -First 1
        $root.ModifiedMs = $FT::ToMs([datetimeoffset]'2026-11-09T10:00:00Z'); $root.Ext().EditedMs = $root.ModifiedMs
        $ch.Touch()
        $e.Now.Set('2026-11-10T00:00:00Z')
        $e.Fake.Counters.Reset()
        $r2 = Invoke-Export $e { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel' }
        $r2.UnitsFailed | Should -Be 0
        $r2.MessagesUpdated | Should -Be 1
        $r2.MessagesNew | Should -Be 0
        $e.Strict.Rejected | Should -Be 0
        $r3 = Invoke-Export $e { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel' }
        $r3.MessagesSeen | Should -Be 0
    }
    It 'a flagged channel (full read) works through the strict transport too' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $team = $t.Teams[1]; $team.Channels[0].MigrationMode = 'completed'
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $x = New-Exporter $e { param($o) $o.IncludeChannels = $true; $o.From = [datetimeoffset]'2025-01-01T00:00:00Z' }
        $r = $x.ExportTeamsAsync([string[]]@($team.Id), $ct).GetAwaiter().GetResult()
        $r.UnitsFailed | Should -Be 0
        $e.Strict.Rejected | Should -Be 0
        $e.Store.TotalMessages | Should -Be (($team.Channels | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum)
    }
}

Describe 'Channel reading performance' {
    BeforeAll { $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1) }
    It 'with $expand=replies honoured, no replies call is made and the stored messages are the same' {
        $e1 = New-Env $t
        [void](Invoke-Inventory $e1)
        [void](Invoke-Export $e1 { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel'; $o.ExpandReplies = $false })
        $e2 = New-Env $t -ExpandReplies
        [void](Invoke-Inventory $e2)
        $r2 = Invoke-Export $e2 { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel' }
        $r2.UnitsFailed | Should -Be 0
        $e2.Expander.Expanded | Should -BeGreaterThan 100
        $e2.Fake.Counters.Calls($Cls::ChannelReplies) | Should -Be $e2.Expander.Expanded        # only the emulated expansion called the replies route
        $e1.Fake.Counters.Calls($Cls::ChannelReplies) | Should -BeGreaterThan 100            # control: one call per root without expansion
        $a = Get-ActualIds $e1.Store; $b = Get-ActualIds $e2.Store
        $a.Keys.Count | Should -Be $b.Keys.Count
        foreach ($k in $a.Keys) { ($b[$k] -join ',') | Should -Be ($a[$k] -join ',') }
        $e2.Store.TotalMessages | Should -Be (Get-ChannelMessageCount $t)
        # the expanded replies are not kept inside the stored root
        $team = $t.Teams[0]; $ch = $team.Channels[0]
        $root = @($e2.Store.ReadMessages("channel:$($team.Id)/$($ch.Id)") | Where-Object { $_.GetProperty('replyToId').ValueKind -eq 'Null' })[0]
        @($root.EnumerateObject() | ForEach-Object { $_.Name }) | Should -Not -Contain 'replies'
    }
    It 'channels of a team are read in parallel and a failing channel does not fail the team' {
        $e = New-Env $t -MaxAttempts 2
        [void](Invoke-Inventory $e)
        $team = $t.Teams[0]; $bad = $team.Channels[1]
        [void]$e.Fake.Faults.FailUrl("channels/$([regex]::Escape($bad.Id))/messages", 500, 'InternalServerError', 'GET', 0)
        $r = Invoke-Export $e { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel'; $o.ChannelParallelism = 4 }
        $r.UnitsFailed | Should -Be 1
        $r.FailedUnits | Should -Contain "c:channel:$($team.Id)/$($bad.Id)"
        $e.Store.TotalMessages | Should -Be ((Get-ChannelMessageCount $t) - $bad.Messages.Count)
    }
    It 'a flagged channel already read in full is not re-read on later passes (the team stream carries its delta)' {
        $ts = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $team = $ts.Teams[1]; $team.Channels[0].MigrationMode = 'completed'
        $e = New-Env $ts
        [void](Invoke-Inventory $e)
        $x = New-Exporter $e { param($o) $o.IncludeChannels = $true }
        [void]$x.ExportTeamsAsync([string[]]@($team.Id), $ct).GetAwaiter().GetResult()
        $e.Fake.Counters.Calls($Cls::ChannelMessages) | Should -BeGreaterThan 0
        $e.Now.Set('2026-11-10T00:00:00Z'); $e.Fake.Counters.Reset()
        $x2 = New-Exporter $e { param($o) $o.IncludeChannels = $true }
        [void]$x2.ExportTeamsAsync([string[]]@($team.Id), $ct).GetAwaiter().GetResult()
        $e.Fake.Counters.Calls($Cls::ChannelMessages) | Should -Be 0
        $e.Fake.Counters.Calls($Cls::ChannelGetAllMessages) | Should -BeGreaterThan 0
    }
    It 'the result carries the Graph metrics and the slowest units' {
        $t2 = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t2
        [void](Invoke-Inventory $e)
        $r = Invoke-Export $e { param($o) $o.IncludeChannels = $true }
        $r.Metrics.Requests | Should -BeGreaterThan 5
        $r.Metrics.ByClass.ContainsKey($Cls::ChatGetAllMessages) | Should -BeTrue
        $r.Metrics.Throttled429 | Should -Be 0
        $r.SlowestUnits.Count | Should -BeGreaterThan 0
        $r.SlowestUnits[0].Scope | Should -Not -BeNullOrEmpty
    }
}

Describe 'Export - hosted contents' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:e = New-Env $t
        [void](Invoke-Inventory $e)
        $script:r = Invoke-Export $e { param($o) $o.Strategy = 'U' }
    }
    It 'downloads each hosted content once although group chats are read by every member' {
        $expected = Get-HostedCount $t
        $expected | Should -BeGreaterThan 5
        $r.HostedDownloaded | Should -Be $expected
        $e.Store.HostedCount | Should -Be $expected
        $e.Fake.Counters.Calls($Cls::HostedContent) | Should -Be $expected
        $r.HostedFailed | Should -Be 0
        $e.Store.PutContentCalls | Should -Be $expected
        $e.Store.DistinctContentCount | Should -BeLessOrEqual $expected      # identical images share one blob
    }
    It 'does not download them again on a Full pass' {
        $calls = $e.Fake.Counters.Calls($Cls::HostedContent)
        [void](Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.Incremental = $false })
        $e.Fake.Counters.Calls($Cls::HostedContent) | Should -Be $calls
    }
    It 'records the content under the message that references it' {
        $m = Get-ReachableChats $t | ForEach-Object { $c = $_; $_.Messages | Where-Object { $_.X -and $_.X.Hosted } | ForEach-Object { [pscustomobject]@{ Key = "chat:$($c.Id)"; Msg = $_ } } } | Select-Object -First 1
        $h = $m.Msg.X.Hosted[0]
        $sha = $e.Store.FindHostedContent($m.Key, $m.Msg.Id.ToString(), $h.Id)
        $sha | Should -Not -BeNullOrEmpty
        $bytes = [byte[]]::new($h.Bytes.Length)
        $stream = $e.Store.OpenContent($sha); try { [void]$stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        ($bytes -join ',') | Should -Be ($h.Bytes -join ',')
    }
    It 'can be switched off' {
        $e2 = New-Env $t
        [void](Invoke-Inventory $e2)
        $r2 = Invoke-Export $e2 { param($o) $o.Strategy = 'U'; $o.IncludeHostedContents = $false }
        $r2.HostedDownloaded | Should -Be 0
        $e2.Fake.Counters.Calls($Cls::HostedContent) | Should -Be 0
    }
    It 'survives a truncated download by trying again' {
        $e2 = New-Env $t
        [void](Invoke-Inventory $e2)
        [void]$e2.Fake.Faults.TruncateDownloads($Cls::HostedContent, 0.5, $true, 1.0, 0, 2)
        $r2 = Invoke-Export $e2 { param($o) $o.Strategy = 'U' }
        $r2.HostedDownloaded | Should -Be (Get-HostedCount $t)
        $r2.HostedFailed | Should -Be 0
    }
}

Describe 'Export - file references and the Files stage' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:owner = $t.Users | Where-Object { Test-Active $_ } | Select-Object -First 1
        $script:chat = $t.ChatsByUser[$owner.Ordinal] | Select-Object -First 1
        $drive = $t.UserDrive($owner)
        $when = [datetimeoffset]'2026-10-01T09:00:00Z'
        $script:items = @{
            ok     = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'rapport-ok.txt', 4096, 11, $owner, $when)
            big    = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'big-video.bin', 20MB, 12, $owner, $when)
            denied = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'denied.docx', 2048, 13, $owner, $when)
            gone   = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'gone.docx', 2048, 14, $owner, $when)
            exe    = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'setup.EXE', 2048, 15, $owner, $when)
        }
        $items.denied.AccessDenied = $true
        $items.gone.Deleted = $true
        $i = 0
        foreach ($spec in @('ok', 'ok', 'big', 'denied', 'gone', 'exe')) {
            $i++
            $m = New-ChatMessage $chat $when.AddMinutes($i) (900 + $i)
            $a = [TeamsTransfer.Testing.FakeAttachment]::new()
            $a.Id = "att$i"; $a.ContentType = 'reference'; $a.ContentUrl = $items[$spec].WebUrl; $a.Name = $items[$spec].Name
            $m.Ext().Attachments = [TeamsTransfer.Testing.FakeAttachment[]]@($a)
        }
        $chat.Touch()
        $script:e = New-Env $t
        [void](Invoke-Inventory $e)
        $script:r = Invoke-Export $e { param($o) $o.Strategy = 'U'; $o.IncludeFiles = $true; $o.ExcludedExtensions = [string[]]@('.exe') }
    }
    It 'records the references during the export (pending, or excluded by extension)' {
        $mine = @($e.Store.AllFiles | Where-Object { $_.ConversationKey -eq "chat:$($chat.Id)" -and $_.AttachmentId -like 'att*' })
        $mine.Count | Should -Be 6
        @($mine | Where-Object Status -eq 'Excluded').Count | Should -Be 1
        @($mine | Where-Object Status -eq 'Pending').Count | Should -Be 5
        $r.FilesRecorded | Should -BeGreaterOrEqual 6
    }
    It 'downloads Pending files: dedup, NotFound, Forbidden, TooLarge, Excluded' {
        $fo = [TeamsTransfer.FilesOptions]::new()
        $fo.MaxFileBytes = 10MB; $fo.Parallelism = 1; $fo.ExcludedExtensions = [string[]]@('exe')
        $calls0 = $e.Fake.Counters.Calls($Cls::DriveContent)
        $stage = [TeamsTransfer.FilesStage]::new($e.Client, $e.Store, $fo)
        $fr = $stage.RunAsync($ct).GetAwaiter().GetResult()
        $mine = @($e.Store.AllFiles | Where-Object { $_.ConversationKey -eq "chat:$($chat.Id)" -and $_.AttachmentId -like 'att*' })
        $st = $mine | Group-Object { $_.Name } -AsHashTable -AsString
        $st['rapport-ok.txt'].Status | ForEach-Object { $_ | Should -Be 'Downloaded' }
        @($st['rapport-ok.txt']).Count | Should -Be 2
        $st['big-video.bin'].Status | Should -Be 'TooLarge'
        $st['denied.docx'].Status | Should -Be 'Forbidden'
        $st['gone.docx'].Status | Should -Be 'NotFound'
        $st['setup.EXE'].Status | Should -Be 'Excluded'
        $fr.TooLarge | Should -BeGreaterOrEqual 1
        $fr.Forbidden | Should -BeGreaterOrEqual 1
        $fr.NotFound | Should -BeGreaterOrEqual 1
        $fr.Failed | Should -Be 0
        # the same drive item referenced by two messages is downloaded once
        $st['rapport-ok.txt'][0].Sha256 | Should -Be $st['rapport-ok.txt'][1].Sha256
        $st['rapport-ok.txt'][0].DriveId | Should -Not -BeNullOrEmpty
        $st['rapport-ok.txt'][0].Size | Should -Be 4096
        $fr.Deduplicated | Should -BeGreaterOrEqual 1
        $e.Store.PendingFiles(100).Count | Should -Be 0
    }
    It 'leaves a second run with nothing to do' {
        $stage = [TeamsTransfer.FilesStage]::new($e.Client, $e.Store, [TeamsTransfer.FilesOptions]::new())
        $stage.RunAsync($ct).GetAwaiter().GetResult().Processed | Should -Be 0
    }
    It 'tries again after a truncated download (connection cut and short body)' {
        $e2 = New-Env $t
        [void](Invoke-Inventory $e2)
        [void](Invoke-Export $e2 { param($o) $o.Strategy = 'U'; $o.IncludeFiles = $true })
        [void]$e2.Fake.Faults.TruncateDownloads($Cls::DriveContent, 0.5, $true, 1.0, 0, 1)
        [void]$e2.Fake.Faults.TruncateDownloads($Cls::DriveContent, 0.5, $false, 1.0, 0, 1)
        $fo = [TeamsTransfer.FilesOptions]::new(); $fo.Parallelism = 1; $fo.MaxFileBytes = 10MB; $fo.Attempts = 4
        $fr = [TeamsTransfer.FilesStage]::new($e2.Client, $e2.Store, $fo).RunAsync($ct).GetAwaiter().GetResult()
        $fr.Failed | Should -Be 0
        $fr.Downloaded | Should -BeGreaterThan 0
        $e2.Fake.Counters.TruncatedDownloads | Should -BeGreaterOrEqual 1
    }
    It 'streams a 1 GiB file without holding it in memory' {
        $drive = $t.UserDrive($owner)
        $huge = $t.AddGeneratedFile($drive, '/Microsoft Teams Chat Files', 'huge-archive.bin', 1GB, 424242, $owner, [datetimeoffset]'2026-10-02T09:00:00Z')
        $m = New-ChatMessage $chat ([datetimeoffset]'2026-10-02T10:00:00Z') 5151
        $a = [TeamsTransfer.Testing.FakeAttachment]::new(); $a.Id = 'huge1'; $a.ContentType = 'reference'; $a.ContentUrl = $huge.WebUrl; $a.Name = $huge.Name
        $m.Ext().Attachments = [TeamsTransfer.Testing.FakeAttachment[]]@($a)
        $chat.Touch()
        $e3 = New-Env $t
        [void](Invoke-Inventory $e3)
        $e3.Store.MaxRetainedContentBytes = 1MB
        $e3.Now.Set('2026-11-09T00:00:00Z')
        [void](Invoke-Export $e3 { param($o) $o.Strategy = 'U'; $o.IncludeFiles = $true; $o.IncludeHostedContents = $false; $o.UserParallelism = 1; $o.From = [datetimeoffset]'2026-10-02T00:00:00Z'; $o.To = [datetimeoffset]'2026-10-03T00:00:00Z' })
        $proc = [Diagnostics.Process]::GetCurrentProcess()
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $gcBefore = [GC]::GetTotalMemory($true)
        $wsBefore = $proc.PeakWorkingSet64
        $fo = [TeamsTransfer.FilesOptions]::new(); $fo.Parallelism = 1
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fr = [TeamsTransfer.FilesStage]::new($e3.Client, $e3.Store, $fo).RunAsync($ct).GetAwaiter().GetResult()
        $sw.Stop()
        $proc.Refresh()
        $gcAfter = [GC]::GetTotalMemory($true)
        $f = @($e3.Store.AllFiles | Where-Object AttachmentId -eq 'huge1')[0]
        $f.Status | Should -Be 'Downloaded'
        $f.Size | Should -Be 1GB
        $e3.Store.ContentBytesRead | Should -BeGreaterOrEqual 1GB
        $f.Sha256 | Should -Be $huge.Sha256Hex().ToLowerInvariant()
        $e3.Store.PeakPutBufferBytes | Should -BeLessOrEqual 1MB        # the gigabyte itself was never buffered
        ($gcAfter - $gcBefore) / 1MB | Should -BeLessThan 64
        ($proc.PeakWorkingSet64 - $wsBefore) / 1MB | Should -BeLessThan 400
        Write-Host ("  1 GiB streamed in {0:N1}s ({1:N0} MB/s); managed heap delta {2:N1} MB; peak working set delta {3:N0} MB" -f $sw.Elapsed.TotalSeconds, (1024 / $sw.Elapsed.TotalSeconds), (($gcAfter - $gcBefore) / 1MB), (($proc.PeakWorkingSet64 - $wsBefore) / 1MB))
    }
}

Describe 'Export - channels' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $script:ep = New-Env $t
        [void](Invoke-Inventory $ep)
        $script:rp = Invoke-Export $ep { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerTeam' }
        $script:ec = New-Env $t
        [void](Invoke-Inventory $ec)
        $script:rc = Invoke-Export $ec { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.ChannelMode = 'PerChannel' }
    }
    It 'exports roots and replies of every channel (private and shared included) with one stream per team' {
        $rp.UnitsFailed | Should -Be 0
        $ep.Store.TotalMessages | Should -Be (Get-ChannelMessageCount $t)
        $ep.Fake.Counters.Calls($Cls::ChannelGetAllMessages) | Should -BeLessThan ($ep.Store.TotalMessages / 20)
        $ep.Fake.Counters.Calls($Cls::ChannelReplies) | Should -Be 0
    }
    It 'per channel (roots + replies) gives the same messages, with many more calls' {
        $rc.UnitsFailed | Should -Be 0
        $ec.Store.TotalMessages | Should -Be (Get-ChannelMessageCount $t)
        $a = Get-ActualIds $ep.Store; $b = Get-ActualIds $ec.Store
        $a.Keys.Count | Should -Be $b.Keys.Count
        foreach ($k in $a.Keys) { ($b[$k] -join ',') | Should -Be ($a[$k] -join ',') }
        $calls = $ec.Fake.Counters.Calls($Cls::ChannelMessages) + $ec.Fake.Counters.Calls($Cls::ChannelReplies)
        $calls | Should -BeGreaterThan ($ep.Fake.Counters.Calls($Cls::ChannelGetAllMessages) * 2)
    }
    It 'is incremental: a new reply is picked by the second pass' {
        $team = $t.Teams[0]; $ch = $team.Channels[0]
        $root = $ch.Messages | Where-Object { $_.ReplyTo -eq 0 } | Select-Object -First 1
        $reply = [TeamsTransfer.Testing.FakeMessage]::new()
        $ms = $FT::ToMs([datetimeoffset]'2026-11-09T12:00:00Z')
        $reply.CreatedMs = $ms; $reply.ModifiedMs = $ms; $reply.AuthorOrd = $root.AuthorOrd; $reply.Seed = 31337; $reply.Ext().ReplyTo = $root.Id
        $ch.AddUnique($reply)
        $ep.Now.Set('2026-11-10T00:00:00Z')
        $r = Invoke-Export $ep { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true }
        $r.MessagesNew | Should -Be 1
        $r.MessagesSeen | Should -BeLessThan 5
    }
    It 'falls back to per-channel reading when the team stream is refused' {
        $e2 = New-Env $t
        [void](Invoke-Inventory $e2)
        [void]$e2.Fake.Faults.FailUrl('channels/getAllMessages', 403, 'Forbidden', 'GET', 0)
        $team = $t.Teams[1]
        $x = New-Exporter $e2 { param($o) $o.IncludeChannels = $true }
        $r = $x.ExportTeamsAsync([string[]]@($team.Id), $ct).GetAwaiter().GetResult()
        $r.UnitsFailed | Should -Be 0
        $n = ($team.Channels | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum
        $e2.Store.TotalMessages | Should -Be $n
    }
}

Describe 'Export - team scoping' {
    It 'Teams restricts the channel export (id or display name); default is all teams' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $e = New-Env $t
        [void](Invoke-Inventory $e)
        $a = $t.Teams[0]; $b = $t.Teams[3]
        $r = Invoke-Export $e { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true; $o.Teams = [string[]]@($a.Id, $b.DisplayName) }
        $n = ($a.Channels + $b.Channels | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum
        $e.Store.TotalMessages | Should -Be $n
        $r.UnitsDone + $r.UnitsUpToDate | Should -Be 2
        $e2 = New-Env $t
        [void](Invoke-Inventory $e2)
        [void](Invoke-Export $e2 { param($o) $o.IncludeChats = $false; $o.IncludeChannels = $true })
        $e2.Store.TotalMessages | Should -Be (Get-ChannelMessageCount $t)
    }
    It 'Invoke-TmtExport -Teams reads ids from a CSV' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $client = New-TmtGraphClient -Configuration (Import-TmtConfiguration) -Side Source -Transport $fake
        $store = [TeamsTransfer.Testing.MemoryExportStore]::new()
        [void](Invoke-TmtInventory -Store $store -Client $client -Teams $t.Teams[1].DisplayName -SkipChats)
        $store.ListConversations().Where({ $_.Kind -eq 'Channel' }).Count | Should -Be $t.Teams[1].Channels.Count
        $csv = Join-Path ([IO.Path]::GetTempPath()) ("tmt-teams-" + [guid]::NewGuid() + '.csv')
        "TeamId`n$($t.Teams[1].Id)" | Set-Content -LiteralPath $csv
        try {
            $r = Invoke-TmtExport -Store $store -Client $client -Teams $csv -IncludeChannels -SkipChats -NoHostedContents
            $store.TotalMessages | Should -Be (($t.Teams[1].Channels | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum)
        } finally { Remove-Item -LiteralPath $csv -Force }
    }
}

Describe 'Messages imported by a migration (invisible to getAllMessages)' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $chat = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $script:chat = $chat
        $min = $FT::ToMs([datetimeoffset]::MinValue)
        $script:hidden = @()
        foreach ($m in @($chat.Messages | Where-Object { $_.ReplyTo -eq 0 } | Select-Object -First 4)) {
            $m.ModifiedMs = $min; $m.Flags = [byte]($m.Flags -bor [TeamsTransfer.Testing.FakeMessage]::FlagImported)
            $hidden += $m
        }
        $chat.Touch()
        $script:key = "chat:$($chat.Id)"
    }
    It 'U misses them, C sees them' {
        $eu = New-Env $t -HideImported
        [void](Invoke-Inventory $eu)
        [void](Invoke-Export $eu { param($o) $o.Strategy = 'U' })
        $eu.Store.TotalMessages | Should -Be ((Get-ChatMessageCount $t) - 4)
        $ec = New-Env $t -HideImported
        [void](Invoke-Inventory $ec)
        [void](Invoke-Export $ec { param($o) $o.Strategy = 'C' })
        $ec.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $ec.Store.CountMessages($key) | Should -Be $chat.Messages.Count
    }
    It 'Assess detects the conversation and flags it, then Auto exports it by C' {
        $e = New-Env $t -HideImported
        [void](Invoke-Inventory $e)
        $ao = [TeamsTransfer.AssessOptions]::new()
        $ao.SampleUsers = 100; $ao.CompareChats = 100; $ao.HistoryMonths = 36; $ao.Now = $e.Now.Func; $ao.ExportRequestsPerSecond = 10
        $rep = [TeamsTransfer.Assessor]::new($e.Client, $ao, $e.Store).RunAsync($ct).GetAwaiter().GetResult()
        $rep.ImportedContentDetected | Should -BeTrue
        $rep.ChatsWithImportedContent | Should -Be 1
        $cmp = $rep.Comparisons | Where-Object Conversation -eq $key
        $cmp.ImportedContent | Should -BeTrue
        $cmp.MissingFromU | Should -Be 4
        $cmp.ModifiedMinValue | Should -Be 4
        ($rep.Comparisons | Where-Object { $_.Conversation -ne $key -and $_.ImportedContent }) | Should -BeNullOrEmpty
        $e.Store.GetConversation($key).HasImportedContent | Should -BeTrue
        $rep.Notes -join ' ' | Should -Match 'strategy C'

        $r = Invoke-Export $e { param($o) $o.Strategy = 'Auto' }
        $e.Store.TotalMessages | Should -Be (Get-ChatMessageCount $t)
        $r.Conversations | Should -Be 1                           # only the flagged chat went through C
        $e.Fake.Counters.Calls($Cls::ChatMessages) | Should -BeGreaterThan 0
        $r2 = Invoke-Export $e { param($o) $o.Strategy = 'Auto' }
        $r2.MessagesSeen | Should -Be 0
    }
    It 'a window on a flagged chat is applied on createdDateTime' {
        $e = New-Env $t -HideImported
        [void](Invoke-Inventory $e)
        $rec = $e.Store.GetConversation($key); $rec.HasImportedContent = $true
        $e.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($rec))
        $r = Invoke-Export $e { param($o) $o.Strategy = 'C'; $o.From = [datetimeoffset]'2025-01-01T00:00:00Z' }
        $e.Store.CountMessages($key) | Should -Be $chat.Messages.Count
    }
}

Describe 'Assess' {
    BeforeAll {
        $p = [TeamsTransfer.Testing.SyntheticProfile]::Small(3)
        $p.Years = 3.5; $p.Users = 80
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Build($p).Tenant
        $script:e = New-Env $t
        function Invoke-Assess($env, [scriptblock]$Configure) {
            $o = [TeamsTransfer.AssessOptions]::new(); $o.Now = $env.Now.Func
            if ($Configure) { & $Configure $o }
            [TeamsTransfer.Assessor]::new($env.Client, $o, $null).RunAsync($script:ct).GetAwaiter().GetResult()
        }
        $script:all = Invoke-Assess $e { param($o) $o.SampleUsers = 100000; $o.SampleTeams = 100000; $o.CompareChats = 10; $o.ExportRequestsPerSecond = 20 }
        $script:half = Invoke-Assess $e { param($o) $o.SampleUsers = 30; $o.SampleTeams = 3; $o.CompareChats = 3; $o.ExportRequestsPerSecond = 20 }
    }
    It 'sampling everyone gives the exact figures (deduplicated chats, channels included)' {
        $all.UserWeight | Should -Be 1
        $all.SampledUsers | Should -Be $all.TotalUsers
        [Math]::Abs($all.ChatMessages - (Get-ChatMessageCount $t)) | Should -BeLessThan 0.001
        [Math]::Abs($all.ChannelMessages - (Get-ChannelMessageCount $t)) | Should -BeLessThan 0.001
        [Math]::Abs($all.Messages - ((Get-ChatMessageCount $t) + (Get-ChannelMessageCount $t))) | Should -BeLessThan 0.01
        [Math]::Abs($all.Chats - (Get-ReachableChats $t).Count) | Should -BeLessThan 0.001
        $all.ReadAmplificationU | Should -BeGreaterThan 1.2         # group chats are read by several members
    }
    It 'the months, the waves and the total agree' {
        $sumMonths = ($all.MessagesByMonth.Values | Measure-Object -Sum).Sum
        [Math]::Abs($sumMonths - $all.Messages) | Should -BeLessThan 0.01
        $all.Waves.Count | Should -Be 4
        $all.Waves[0].Name | Should -Match 'wave 1 \(0-24'
        $all.Waves[1].Name | Should -Match '25-36'
        $all.Waves[2].Name | Should -Match '37-48'
        [Math]::Abs((($all.Waves | Measure-Object Messages -Sum).Sum) - $all.Messages) | Should -BeLessThan 0.01
        $all.Waves[0].Messages | Should -BeGreaterThan ($all.Waves[1].Messages * 0.5)
        $all.Waves[2].Messages | Should -BeGreaterThan 0         # 3.5 years of history reaches the 37-48 month wave
    }
    It 'durations follow from the measured rate and the import rates of the service' {
        $all.ImportDaysCentral | Should -BeGreaterThan 0
        [Math]::Abs($all.ImportDaysCentral - $all.Messages / 75 / 86400) | Should -BeLessThan 1e-9
        [Math]::Abs($all.ImportDaysLow - $all.Messages / 90 / 86400) | Should -BeLessThan 1e-9
        [Math]::Abs($all.ImportDaysHigh - $all.Messages / 60 / 86400) | Should -BeLessThan 1e-9
        $all.ImportDaysLow | Should -BeLessThan $all.ImportDaysCentral
        $all.ImportDaysCentral | Should -BeLessThan $all.ImportDaysHigh
        [Math]::Abs($all.ExportDays - $all.ExportRequests / 20 / 86400) | Should -BeLessThan 1e-9
        $all.ExportRequests | Should -BeGreaterThan ($all.ChatMessageReadsStrategyU / 50)
        [Math]::Abs((($all.Waves | Measure-Object ImportDaysCentral -Sum).Sum) - $all.ImportDaysCentral) | Should -BeLessThan 1e-9
        $all.ImportDaysFloorLongestConversation | Should -BeGreaterThan 0
    }
    It 'measures the throughput of the sampling itself' {
        $all.MeasuredRequests | Should -BeGreaterThan 50
        $all.MeasuredRequestsPerSecond | Should -BeGreaterThan 0
    }
    It 'a partial sample extrapolates within a reasonable error and reports its weights' {
        $half.SampledUsers | Should -Be 30
        $half.UserWeight | Should -BeGreaterThan 1
        $truth = (Get-ChatMessageCount $t) + (Get-ChannelMessageCount $t)
        $ratio = $half.ChatMessages / (Get-ChatMessageCount $t)
        $ratio | Should -BeGreaterThan 0.5
        $ratio | Should -BeLessThan 2.0
        $half.ChannelMessages | Should -BeGreaterThan 0
        $half.ChatMessageReadsStrategyU | Should -BeGreaterThan $half.ChatMessages
        Write-Host ("  assess 30/{0} users, 3/{1} teams: chat messages x{2:N2} of truth, JSON {3:N0} MB" -f $half.TotalUsers, $half.TotalTeams, $ratio, ($half.JsonBytes / 1MB))
    }
    It 'finds no imported content on a tenant that was never migrated and renders text and JSON' {
        $all.ImportedContentDetected | Should -BeFalse
        $all.ChatsCompared | Should -Be 10
        $all.ToText() | Should -Match 'unique messages'
        ($all.ToJson() | ConvertFrom-Json).TotalUsers | Should -Be $all.TotalUsers
    }
    It 'measures hosted contents and file sizes on a sample' {
        $all.HostedContents | Should -BeGreaterThan 0
        $all.AverageHostedBytes | Should -BeGreaterThan 0
        $all.AverageHostedBytes | Should -Not -Be 150KB
        $all.FileReferences | Should -BeGreaterThan 0
        $all.AverageFileBytes | Should -Not -Be 2MB
    }
}

Describe 'PowerShell surface' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:cfg = Import-TmtConfiguration
        $script:client = New-TmtGraphClient -Configuration $cfg -Side Source -Transport $fake
        $script:store = [TeamsTransfer.Testing.MemoryExportStore]::new()
    }
    It 'New-TmtGraphClient builds a client with metrics from the configuration' {
        $client | Should -BeOfType ([TeamsTransfer.GraphClient])
        [TeamsTransfer.GraphMetrics]::Of($client) | Should -Not -BeNullOrEmpty
        $client.Options.ExportModel | Should -Be 'B'
        { New-TmtGraphClient -Configuration @{ Source = @{ TenantId = ''; ClientId = ''; CertificateThumbprint = '' } } -Side Source } | Should -Throw '*TenantId is empty*'
    }
    It 'Invoke-TmtInventory then Invoke-TmtExport (window, channels, files) fill the store' {
        $i = Invoke-TmtInventory -Store $store -Client $client
        $i.Chats | Should -Be (Get-ReachableChats $t).Count
        $r = Invoke-TmtExport -Store $store -Client $client -Strategy Auto -Window 24m -IncludeChannels -IncludeFiles -MaxFileSizeMB 20
        $r.MessagesNew | Should -Be ((Get-ChatMessageCount $t) + (Get-ChannelMessageCount $t))
        $r.Files.Downloaded | Should -BeGreaterThan 0
    }
    It 'Invoke-TmtExport takes users from a list or a CSV, and -Full re-reads' {
        $csv = Join-Path ([IO.Path]::GetTempPath()) ("tmt-users-" + [guid]::NewGuid() + '.csv')
        "Id`n$($t.Users[1].Id)" | Set-Content -LiteralPath $csv
        try {
            $r = Invoke-TmtExport -Store $store -Client $client -Users $csv -Strategy U -Full -NoHostedContents
            $r.UnitsDone | Should -Be 1
            $r.MessagesSeen | Should -BeGreaterThan 0
        } finally { Remove-Item -LiteralPath $csv -Force }
    }
    It 'Invoke-TmtAssess returns the report' {
        $a = Invoke-TmtAssess -Client $client -SampleUsers 2 -SampleTeams 1
        $a.SampledUsers | Should -Be 2
        $a.Messages | Should -BeGreaterThan 0
    }
}

Describe 'Volume' -Tag Volume {
    It 'exports a tenant of >= 1,000,000 messages into a counting store' -Skip:($env:TMT_VOLUME -ne '1') {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = [TeamsTransfer.Testing.SyntheticTenant]::Build([TeamsTransfer.Testing.SyntheticProfile]::Volume(1000000, 1))
        $gen = $sw.Elapsed.TotalSeconds
        $t = $r.Tenant
        $r.Stats.Messages | Should -BeGreaterOrEqual 1000000
        $proc = [Diagnostics.Process]::GetCurrentProcess()
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $wsAfterGen = $proc.WorkingSet64 / 1MB

        $e = New-Env $t -KeepNoBodies
        $swInv = [Diagnostics.Stopwatch]::StartNew()
        $inv = Invoke-Inventory $e
        $invSec = $swInv.Elapsed.TotalSeconds
        $sw.Restart()
        $x = New-Exporter $e { param($o) $o.Strategy = 'U'; $o.IncludeChannels = $true; $o.IncludeHostedContents = $false; $o.UserParallelism = 16; $o.TeamParallelism = 4 }
        $res = $x.RunAsync($null, $ct).GetAwaiter().GetResult()
        $sec = $sw.Elapsed.TotalSeconds
        $proc.Refresh()
        $peak = $proc.PeakWorkingSet64 / 1MB
        $expected = (Get-ChatMessageCount $t) + (Get-ChannelMessageCount $t)
        Write-Host ("  VOLUME generation {0:N0}s; inventory {1:N1}s ({2} users, {3} chats, {4} channels); export {5:N0}s: {6:N0} messages read, {7:N0} distinct ({8:N0} msgs/s read), working set after generation {9:N0} MB, peak {10:N0} MB, errors {11}" -f $gen, $invSec, $inv.Users, $inv.Chats, $inv.Channels, $sec, $res.MessagesSeen, $e.Store.TotalMessages, ($res.MessagesSeen / $sec), $wsAfterGen, $peak, $res.UnitsFailed)
        $res.UnitsFailed | Should -Be 0
        $e.Store.TotalMessages | Should -Be $expected
        $e.Store.TotalMessages | Should -BeGreaterOrEqual 990000   # reachable messages; the rest sit in chats whose members are all deleted or federated
    }
}
