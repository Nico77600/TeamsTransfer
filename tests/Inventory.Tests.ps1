#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Inventory.cs against the fake Graph (Tiny / Small synthetic tenants) and tests\support\MemoryExportStore.cs.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None

    function New-Env {
        param($Tenant, [int]$MaxAttempts = 3, [switch]$WithLimiter)
        $clock = [TeamsTransfer.TestManualClock]::new()
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($Tenant)
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = $clock; $o.MaxAttempts = $MaxAttempts
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(4)
        $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $lim = if ($WithLimiter) { [TeamsTransfer.AdaptiveRateLimiter]::new($o.ToRateLimiterOptions()) } else { $null }
        $metrics = [TeamsTransfer.GraphMetrics]::new()
        $client = [TeamsTransfer.GraphClient]::new($fake, $o, $lim, [Action[TeamsTransfer.GraphEvent]]$metrics.OnEvent)
        $metrics.Attach($client)
        [pscustomobject]@{ Tenant = $Tenant; Fake = $fake; Client = $client; Clock = $clock; Metrics = $metrics; Store = [TeamsTransfer.Testing.MemoryExportStore]::new() }
    }
    function Invoke-Inventory($env, [scriptblock]$Configure) {
        $o = [TeamsTransfer.InventoryOptions]::new()
        if ($Configure) { & $Configure $o }
        $inv = [TeamsTransfer.Inventory]::new($env.Client, $env.Store, $o)
        $inv.RunAsync($script:ct).GetAwaiter().GetResult()
    }
    function Test-Active($t, $u) { -not $u.Deleted -and -not $u.External }
    function Get-ReachableChats($t) {
        @($t.Chats | Where-Object { $chat = $_; @($chat.Members | Where-Object { Test-Active $t $t.Users[$_.UserOrd] }).Count -gt 0 })
    }
}

Describe 'Inventory - users' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        [void]$t.AddUser('guest.partner@fabrikam.com', 'Partner Guest', $false, $false, 'Guest')   # a B2B guest that lives in the directory
        $script:e = New-Env $t
        $script:r = Invoke-Inventory $e
    }
    It 'lists the directory users, the guests and the deleted users with their state' {
        $states = $e.Store.AllUsers | Group-Object State -AsHashTable -AsString
        @($states['Deleted']).Count | Should -Be @($t.Users | Where-Object Deleted).Count
        @($states['Guest']).Count | Should -Be 1
        $r.GuestUsers | Should -Be 1
        $r.DeletedUsers | Should -Be @($t.Users | Where-Object { $_.Deleted -and -not $_.External }).Count
        $r.Users | Should -Be @($t.Users | Where-Object { -not $_.Deleted -and -not $_.External }).Count
    }
    It 'records federated members (not in the directory) as External users' {
        $ext = @($e.Store.AllUsers | Where-Object State -eq 'External')
        $ext.Count | Should -BeGreaterThan 0
        $ext[0].TenantId | Should -Not -BeNullOrEmpty
        $r.OtherMembers | Should -BeGreaterOrEqual $ext.Count
    }
    It 'reports no error and a complete pass' {
        $r.Errors.Count | Should -Be 0
        $r.Stopped | Should -BeFalse
        $e.Store.GetCheckpoint('inv:state') | Should -Be 'complete'
    }
}

Describe 'Inventory - chats are deduplicated across users' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:e = New-Env $t
        $script:r = Invoke-Inventory $e
    }
    It 'creates one conversation per chat id although group and meeting chats are listed by every member' {
        $reachable = Get-ReachableChats $t
        $r.Chats | Should -Be $reachable.Count
        $chatKeys = @($e.Store.ListConversations() | Where-Object { $_.Kind -ne 'Channel' })
        $chatKeys.Count | Should -Be $reachable.Count
        ($chatKeys.Key | Sort-Object -Unique).Count | Should -Be $reachable.Count
        $r.ChatMemberships | Should -BeGreaterThan $r.Chats      # shared chats were listed several times...
    }
    It 'counts the kinds' {
        $r.OneOnOneChats + $r.GroupChats + $r.MeetingChats | Should -Be $r.Chats
        $r.MeetingChats | Should -Be @(Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Meeting' }).Count
    }
    It 'keeps the raw members of each chat' {
        $chat = Get-ReachableChats $t | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $rec = $e.Store.GetConversation("chat:$($chat.Id)")
        $rec.Kind | Should -Be 'Group'
        $rec.MemberCount | Should -Be $chat.Members.Count
        @(($rec.MembersJson | ConvertFrom-Json)).Count | Should -Be $chat.Members.Count
    }
    It 'links each user to all the conversations they belong to' {
        foreach ($u in $t.Users | Where-Object { Test-Active $t $_ }) {
            $expected = @($t.ChatsByUser[$u.Ordinal] | ForEach-Object { "chat:$($_.Id)" }) + @(
                $t.Teams | ForEach-Object { $tm = $_; $_.Channels | Where-Object { $ch = $_; $m = if ($ch.TypeName -eq 'standard') { $tm.Members } else { $ch.Members }; @($m | Where-Object UserOrd -eq $u.Ordinal).Count -gt 0 } | ForEach-Object { "channel:$($tm.Id)/$($_.Id)" } })
            $actual = @($e.Store.ListConversations($u.Id) | ForEach-Object Key)
            ($actual | Sort-Object) | Should -Be ($expected | Sort-Object)
        }
    }
}

Describe 'Inventory - teams and channels' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $script:e = New-Env $t
        $script:r = Invoke-Inventory $e { param($o) $o.UserParallelism = 8; $o.TeamParallelism = 4 }
    }
    It 'lists every team and channel, private and shared included' {
        $r.Teams | Should -Be $t.Teams.Count
        $nCh = ($t.Teams | ForEach-Object { $_.Channels.Count } | Measure-Object -Sum).Sum
        $r.Channels | Should -Be $nCh
        $r.PrivateChannels | Should -BeGreaterThan 0
        $r.SharedChannels | Should -BeGreaterThan 0
        $chans = @($e.Store.ListConversations().Where({ $_.Kind -eq 'Channel' }))
        $chans.Count | Should -Be $nCh
        ($chans | Where-Object MembershipType -eq 'private').Count | Should -Be @($t.Teams.Channels | Where-Object TypeName -eq 'private').Count
        ($chans | Where-Object MembershipType -eq 'shared').Count | Should -Be @($t.Teams.Channels | Where-Object TypeName -eq 'shared').Count
    }
    It 'gives a private channel its own members and a standard channel the members of the team' {
        $team = $t.Teams | Where-Object { $_.Channels.TypeName -contains 'private' } | Select-Object -First 1
        $priv = $team.Channels | Where-Object TypeName -eq 'private' | Select-Object -First 1
        $std = $team.Channels | Where-Object TypeName -eq 'standard' | Select-Object -First 1
        $pr = $e.Store.GetConversation("channel:$($team.Id)/$($priv.Id)")
        $pr.MemberCount | Should -Be $priv.Members.Count
        $pr.TeamId | Should -Be $team.Id
        $pr.Topic | Should -Be $priv.DisplayName
        $pr.TeamDisplayName | Should -Be $team.DisplayName
        $sr = $e.Store.GetConversation("channel:$($team.Id)/$($std.Id)")
        $sr.MemberCount | Should -Be $team.Members.Count
    }
    It 'also dedups chats on a bigger tenant' {
        $r.Chats | Should -Be (Get-ReachableChats $t).Count
        $r.Errors.Count | Should -Be 0
    }
}

Describe 'Inventory - resume, errors, stop, idempotence' {
    It 'records a failing user, goes on, and a second run resumes the pass and only redoes that user' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 2
        $victim = $t.Users | Where-Object { Test-Active $t $_ } | Select-Object -Skip 1 -First 1
        [void]$e.Fake.Faults.FailUrl("users/$($victim.Id)/chats", 500, 'InternalServerError', 'GET', 2)
        $r1 = Invoke-Inventory $e
        $r1.Errors.Count | Should -Be 1
        $r1.Errors[0].Scope | Should -Be "u:$($victim.Id)"
        $e.Store.GetCheckpoint('inv:state') | Should -Be 'running'      # not complete: a unit failed
        $e.Store.GetCheckpoint("err:inv:u:$($victim.Id)") | Should -Not -BeNullOrEmpty

        $before = $e.Fake.Counters.Calls([TeamsTransfer.EndpointClass]::UserChats)
        $r2 = Invoke-Inventory $e
        $r2.Resumed | Should -BeTrue
        $r2.PassId | Should -Be $r1.PassId
        $r2.Errors.Count | Should -Be 0
        $r2.UsersSkipped | Should -BeGreaterThan 0                       # the users done by the first run are not listed again
        $calls = $e.Fake.Counters.Calls([TeamsTransfer.EndpointClass]::UserChats) - $before
        $calls | Should -BeLessThan $before
        $e.Store.GetCheckpoint('inv:state') | Should -Be 'complete'
        $e.Store.GetCheckpoint("err:inv:u:$($victim.Id)") | Should -BeNullOrEmpty
        $e.Store.ListConversations() | Where-Object { $_.Kind -ne 'Channel' } | Measure-Object | ForEach-Object Count | Should -Be (Get-ReachableChats $t).Count
    }
    It 'starts a new pass after a complete one, with the same result and without losing the HasImportedContent flag' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $r1 = Invoke-Inventory $e
        $rec = $e.Store.ListConversations() | Where-Object { $_.Kind -eq 'Group' } | Select-Object -First 1
        $rec.HasImportedContent = $true
        $e.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($rec))
        $r2 = Invoke-Inventory $e
        $r2.Resumed | Should -BeFalse
        $r2.PassId | Should -Not -Be $r1.PassId
        $r2.Chats | Should -Be $r1.Chats
        $e.Store.GetConversation($rec.Key).HasImportedContent | Should -BeTrue
    }
    It 'stops cleanly when asked (stop control)' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $stop = [TeamsTransfer.StopControl]::new(); $stop.Request()
        $r = Invoke-Inventory $e { param($o) $o.Stop = $stop }
        $r.Stopped | Should -BeTrue
        $e.Store.GetCheckpoint('inv:state') | Should -Be 'running'
        $r2 = Invoke-Inventory $e
        $r2.Resumed | Should -BeTrue
        $r2.Chats | Should -Be (Get-ReachableChats $t).Count
    }
    It 'stops on a stop file' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $file = Join-Path ([IO.Path]::GetTempPath()) ("tmt-stop-" + [guid]::NewGuid() + '.flag')
        New-Item -ItemType File -Path $file | Out-Null
        try {
            $stop = [TeamsTransfer.StopControl]::new(); $stop.StopFile = $file
            (Invoke-Inventory $e { param($o) $o.Stop = $stop }).Stopped | Should -BeTrue
        } finally { Remove-Item -LiteralPath $file -Force }
    }
    It 'restricts the chat listing to the requested users' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t
        $one = $t.Users | Where-Object { Test-Active $t $_ } | Select-Object -First 1
        $r = Invoke-Inventory $e { param($o) $o.OnlyUsers = [string[]]@($one.Upn); $o.IncludeTeams = $false }
        $r.Chats | Should -Be @($t.ChatsByUser[$one.Ordinal]).Count
        $r.UsersSkipped | Should -BeGreaterThan 0
    }
    It 'completes through a 429 storm' {
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $e = New-Env $t -MaxAttempts 8 -WithLimiter
        [void]$e.Fake.Faults.ThrottleEveryNth([TeamsTransfer.EndpointClass]::UserChats, 2, [TimeSpan]::FromSeconds(2))
        [void]$e.Fake.Faults.ThrottleEveryNth([TeamsTransfer.EndpointClass]::Channels, 2, [TimeSpan]::FromSeconds(2))
        $r = Invoke-Inventory $e
        $r.Errors.Count | Should -Be 0
        $r.Chats | Should -Be (Get-ReachableChats $t).Count
        $e.Metrics.Snapshot().Throttled429 | Should -BeGreaterThan 0
        $e.Clock.UtcNow | Should -BeGreaterThan ([datetimeoffset]'2026-11-09T08:00:02Z')   # the virtual clock waited for Retry-After
    }
}

Describe 'Inventory - team scoping' {
    BeforeAll { $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1) }
    It 'OnlyTeams keeps the teams given by id or by exact display name' {
        $e = New-Env $t
        $a = $t.Teams[0]; $b = $t.Teams[2]
        $r = Invoke-Inventory $e { param($o) $o.IncludeChats = $false; $o.OnlyTeams = [string[]]@($a.Id, $b.DisplayName) }
        $r.Teams | Should -Be 2
        $r.Channels | Should -Be ($a.Channels.Count + $b.Channels.Count)
        @($e.Store.ListConversations().Where({ $_.Kind -eq 'Channel' }).TeamId | Sort-Object -Unique) | Should -Be (@($a.Id, $b.Id) | Sort-Object)
    }
    It 'a partial display name matches nothing' {
        $e = New-Env $t
        (Invoke-Inventory $e { param($o) $o.IncludeChats = $false; $o.OnlyTeams = [string[]]@($t.Teams[0].DisplayName.Substring(0, 4)) }).Teams | Should -Be 0
    }
    It 'OnlyUsers without OnlyTeams still inventories every team' {
        $e = New-Env $t
        $one = $t.Users | Where-Object { Test-Active $t $_ } | Select-Object -First 1
        $r = Invoke-Inventory $e { param($o) $o.OnlyUsers = [string[]]@($one.Upn) }
        $r.Teams | Should -Be $t.Teams.Count
    }
}

Describe 'Inventory - team listing and permissions' {
    BeforeAll { $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1) }
    It 'lists teams with GET teams by default (no Group.Read.All needed)' {
        $e = New-Env $t
        $e.Fake.Counters.LogEnabled = $true
        $r = Invoke-Inventory $e { param($o) $o.IncludeChats = $false }
        $r.Teams | Should -Be $t.Teams.Count
        $urls = @($e.Fake.Counters.Log | ForEach-Object Url)
        @($urls | Where-Object { $_ -match '^v1\.0/teams(\?|$)' }).Count | Should -BeGreaterThan 0
        @($urls | Where-Object { $_ -match 'groups' }).Count | Should -Be 0
    }
    It 'falls back to groups when GET teams answers 400/404, and says so' {
        $t2 = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $t2.TeamsListEndpointEnabled = $false
        $e = New-Env $t2
        $r = Invoke-Inventory $e { param($o) $o.IncludeChats = $false }
        $r.Teams | Should -Be 1
        $r.Warnings -join ' ' | Should -Match 'through groups'
    }
    It 'does not fail a team whose members cannot be read: channels kept, the missing permission reported once' {
        $e = New-Env $t -MaxAttempts 2
        [void]$e.Fake.Faults.FailUrl('teams/[^/]+/members', 403, 'Authorization_RequestDenied', 'GET', 0)
        $r = Invoke-Inventory $e { param($o) $o.IncludeChats = $false }
        $r.Errors.Count | Should -Be 0
        $r.Teams | Should -Be $t.Teams.Count
        $r.Channels | Should -Be (($t.Teams | ForEach-Object { $_.Channels.Count } | Measure-Object -Sum).Sum)
        @($r.Warnings | Where-Object { $_ -match 'TeamMember.Read.All' }).Count | Should -Be 1      # once, not once per team
        $std = $e.Store.ListConversations().Where({ $_.MembershipType -eq 'standard' })[0]
        $std.MemberCount | Should -Be 0
        $e.Store.GetCheckpoint('inv:state') | Should -Be 'complete'
    }
}

Describe 'Inventory - previously imported conversations (migrationMode)' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Small(1)
        $reach = Get-ReachableChats $t
        $script:done = $reach | Where-Object { $_.ChatType -eq 'Group' } | Select-Object -First 1
        $script:running = $reach | Where-Object { $_.ChatType -eq 'OneOnOne' } | Select-Object -First 1
        $done.MigrationMode = 'completed'
        $running.MigrationMode = 'inProgress'
        $script:chan = $t.Teams[0].Channels | Select-Object -Skip 1 -First 1
        $chan.MigrationMode = 'completed'
        $script:e = New-Env $t
        $script:r = Invoke-Inventory $e
    }
    It 'flags chats and channels that report a migrationMode as HasImportedContent' {
        $e.Store.GetConversation("chat:$($done.Id)").HasImportedContent | Should -BeTrue
        $e.Store.GetConversation("chat:$($running.Id)").HasImportedContent | Should -BeTrue
        $e.Store.GetConversation("channel:$($t.Teams[0].Id)/$($chan.Id)").HasImportedContent | Should -BeTrue
        $r.ImportedConversations | Should -Be 3
        @($e.Store.ListConversations() | Where-Object { $_.HasImportedContent -eq $true }).Count | Should -Be 3
    }
    It 'reports the conversations whose migration is still in progress (export may be incomplete)' {
        $r.MigrationsInProgress | Should -Be @("chat:$($running.Id)")
        ($r.Warnings -join ' ') | Should -Match 'migration is in progress'
    }
    It 'a flag never goes back to false, even when the service stops reporting a migrationMode' {
        $done.MigrationMode = $null
        $r2 = Invoke-Inventory $e
        $e.Store.GetConversation("chat:$($done.Id)").HasImportedContent | Should -BeTrue
        $done.MigrationMode = 'completed'
    }
}
