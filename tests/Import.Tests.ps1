#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Offline tests of the Importer (package\src\Engine.Import.cs, lot I) and of its PowerShell surface (TeamsTransfer.Import.ps1, the Import mode
    of the entry script). The target tenant is FakeGraph wrapped in ImportRealismTransport (tests\support\ImportTestTransports.cs), which makes the
    fake behave like the real service where Phase0-Results.md says they differ (409 on a duplicate date, reopening a completed thread, eventual
    consistency of migrationMode, lost responses, a "kill" between a POST and its journal entry). The maps are in memory
    (tests\support\ImportTestMaps.cs). The source is a real TmtStore on a temporary disk folder (journal, lots, items, messages).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:TempRoot = Join-Path $env:TEMP ('tmt-import-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:Envs = [Collections.Generic.List[object]]::new()
    $script:T0 = [datetimeoffset]::Parse('2026-02-01T09:00:00Z')
    $script:ct = [Threading.CancellationToken]::None
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'

    function At([int]$n) { $script:T0.AddSeconds(30 * $n) }
    function Iso([datetimeoffset]$d) { $d.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) }

    function New-Msg {
        param([string]$Id, [datetimeoffset]$At, [string]$From = 'src-alice', [string]$Body = '<p>hello</p>', [string]$ReplyTo, [hashtable]$Extra = @{},
            [string]$Type = 'message', [string]$ContentType = 'html', [string]$Deleted, [string]$CreatedText)
        if (-not $Id) { $Id = [string]$At.ToUnixTimeMilliseconds() }
        $iso = if ($CreatedText) { $CreatedText } else { Iso $At }
        $o = [ordered]@{ id = $Id; messageType = $Type; createdDateTime = $iso; lastModifiedDateTime = $iso; deletedDateTime = $(if ($Deleted) { $Deleted } else { $null }) }
        if ($ReplyTo) { $o.replyToId = $ReplyTo }
        if ($From) { $o.from = @{ user = @{ id = $From; displayName = "User $From"; userIdentityType = 'aadUser' } } }
        $o.body = @{ contentType = $ContentType; content = $Body }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        [Text.Json.JsonDocument]::Parse(($o | ConvertTo-Json -Depth 12 -Compress)).RootElement
    }

    function New-Env {
        param([switch]$WithLimiter, [int]$MaxAttempts = 4, [double]$PerThreadRate = 0, [switch]$RealTime)
        $root = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $so = [TeamsTransfer.StoreOptions]::new(); $so.Partitions = 8; $so.FlushIntervalMs = 0
        $store = [TeamsTransfer.TmtStore]::Open($root, $so)
        $tenant = [TeamsTransfer.Testing.FakeTenant]::new(7)
        $users = @{}
        foreach ($n in 'alice', 'bob', 'carol', 'ghost', 'svc') { $users[$n] = $tenant.AddUser("$n@contoso.com", "$n User") }
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($tenant)
        $fake.Counters.LogEnabled = $true
        $clock = [TeamsTransfer.TestManualClock]::new()
        $real = if ($RealTime) { [TeamsTransfer.Testing.ImportRealismTransport]::new($fake) } else { [TeamsTransfer.Testing.ImportRealismTransport]::new($fake, $clock) }
        $go = [TeamsTransfer.GraphClientOptions]::new()
        $go.Clock = $(if ($RealTime) { [TeamsTransfer.SystemClock]::Instance } else { $clock }); $go.MaxAttempts = $MaxAttempts
        $go.BaseBackoff = [TimeSpan]::FromSeconds(1); $go.MaxBackoff = [TimeSpan]::FromSeconds(4)
        $go.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $go.MaxConcurrency = 64
        $limiter = $null
        if ($WithLimiter) {
            $lo = $go.ToRateLimiterOptions()
            if ($PerThreadRate -gt 0) { $lo.PerThreadRatePerSecond = $PerThreadRate }
            $limiter = [TeamsTransfer.AdaptiveRateLimiter]::new($lo)
            if (-not $RealTime) { $real.AlignFaultsTo($clock) }
        }
        $metrics = [TeamsTransfer.GraphMetrics]::new()
        $client = [TeamsTransfer.GraphClient]::new($real, $go, $limiter, [Action[TeamsTransfer.GraphEvent]]$metrics.OnEvent)
        $metrics.Attach($client)
        $e = [pscustomobject]@{
            Root = $root; Store = $store; Tenant = $tenant; Users = $users; Fake = $fake; Real = $real; Clock = $clock; Client = $client; Metrics = $metrics
            Ids = [TeamsTransfer.Testing.MemoryIdentityMap]::new(); Targets = [TeamsTransfer.Testing.MemoryTargetMap]::new(); Files = [TeamsTransfer.Testing.MemoryFileCopyMap]::new()
        }
        $script:Envs.Add($e)
        $e
    }

    function Set-Ident($e) {
        $e.Ids.Set('src-alice', 'Mapped', $e.Users.alice.Id, 'Alice Src', 'alice@src.com')
        $e.Ids.Set('src-bob', 'Mapped', $e.Users.bob.Id, 'Bob Src', 'bob@src.com')
        $e.Ids.Set('src-carol', 'Mapped', $e.Users.carol.Id, 'Carol Src', 'carol@src.com')
    }

    function Add-Source {
        param($Env, [string]$Key, [string]$Kind, $Messages, [string]$Topic, [string]$Team, [string]$Chan, [string]$Membership)
        $c = [TeamsTransfer.ConversationRecord]::new()
        $c.Key = $Key; $c.Kind = $Kind; $c.Topic = $Topic; $c.TeamId = $Team; $c.ChannelId = $Chan; $c.MembershipType = $Membership
        $c.CreatedUtc = [datetimeoffset]::Parse('2022-01-01T00:00:00Z'); $c.LastActivityUtc = [datetimeoffset]::Parse('2026-10-01T00:00:00Z')
        $Env.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c))
        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
        foreach ($m in $Messages) { $l.Add($m) }
        [void]$Env.Store.AppendMessages($Key, $l)
    }

    function New-Tgt {
        param([string]$Key, [string]$Kind, [string]$ChatId, [string]$TeamId, [string]$ChannelId, [string[]]$Members = @(), [string]$Topic, [string]$Membership, [string]$TeamName)
        $t = [TeamsTransfer.TargetMapping]::new()
        $t.SourceConversationKey = $Key; $t.Kind = $Kind; $t.TargetChatId = $ChatId; $t.TargetTeamId = $TeamId; $t.TargetChannelId = $ChannelId
        $t.CreateTopic = $Topic; $t.CreateMembershipType = $Membership; $t.CreateTeamName = $TeamName
        foreach ($m in $Members) { $t.TargetMemberIds.Add($m) }
        $t
    }

    function New-LotFor {
        param($Env, [string]$Name, [string[]]$Keys, [int[]]$Slices = @(1), [switch]$KeepPlanned)
        $members = foreach ($k in $Keys) { [TeamsTransfer.LotMember]::new($(if ($k.StartsWith('chat:')) { [TeamsTransfer.LotMemberType]::Chat } else { [TeamsTransfer.LotMemberType]::Channel }), $k, 100) }
        $opt = [TeamsTransfer.LotOptions]::new(); $opt.AsOfUtc = [datetimeoffset]::Parse('2026-11-09T00:00:00Z')
        $id = $Env.Store.CreateLot($Name, [TeamsTransfer.LotMember[]]@($members), $opt)
        [void]$Env.Store.ResolveLot($id, [int[]]$Slices)
        if (-not $KeepPlanned) { foreach ($st in 'Exporting', 'Exported', 'ImportPlanned') { [void]$Env.Store.TransitionLot($id, [TeamsTransfer.LotState]::$st) } }
        $id
    }

    function New-Imp {
        param($Env, [scriptblock]$Configure, [switch]$DryRun, [switch]$NoClient, [scriptblock]$Tune)
        $o = [TeamsTransfer.ImportRunOptions]::new()
        $o.Apply = -not $DryRun; $o.ServiceAccountUserId = $Env.Users.svc.Id; $o.ConversationParallelism = 4
        if ($Configure) { & $Configure $o }
        $client = if ($NoClient) { $null } else { $Env.Client }
        $imp = [TeamsTransfer.Importer]::new($client, $Env.Store, $Env.Ids, $Env.Targets, $Env.Files, $o, 'app-1')
        $t = [TeamsTransfer.ImportTuning]::new(); $t.Clock = $Env.Clock
        $t.InFlightPerConversation = 1          # one send at a time unless a test asks for the pipeline: exact journal states after a kill or a stop
        if ($Tune) { & $Tune $t }
        $imp.Tuning = $t
        $imp
    }

    function Invoke-Imp($imp, [long]$LotId, [int[]]$Slices = @()) { $imp.RunAsync($LotId, $Slices, $script:ct).GetAwaiter().GetResult() }

    function Get-Journal($e, [string]$Key, [int]$Slice = 1) { @($e.Store.ListJournal($Key, $Slice)) }
    function Get-States($e, [string]$Key, [int]$Slice = 1) { @(Get-Journal $e $Key $Slice | ForEach-Object { [string]$_.Status }) }
    function New-Group($e, [string]$Name = 'g') {
        $e.Tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::Group, [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice, $e.Users.bob), $Name, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
    }
    function Use-Chat($e, [string]$Key, $Messages, [string]$Name = 'g') {
        # a source group chat, an existing target chat, the identities, the mapping and a planned lot
        Set-Ident $e
        $chat = New-Group $e $Name
        Add-Source $e $Key 'Group' $Messages
        $e.Targets.Upsert((New-Tgt -Key $Key -Kind ExistingChat -ChatId $chat.Id))
        $lot = New-LotFor $e ('L-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) @($Key)
        [pscustomobject]@{ Chat = $chat; Lot = $lot }
    }
}

AfterAll {
    foreach ($e in $script:Envs) { try { $e.Store.Dispose() } catch { } }
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Full flow per conversation type' {
    It '1:1 chat: dates, authors, journal, session, item and lot states' {
        $e = New-Env; Set-Ident $e
        $chat = $e.Tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::OneOnOne, [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice, $e.Users.bob), $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $msgs = 1..5 | ForEach-Object { New-Msg -At (At $_) -From $(if ($_ % 2) { 'src-alice' } else { 'src-bob' }) -Body "<p>m$_</p>" }
        Add-Source $e 'chat:S1' 'OneOnOne' $msgs
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id))
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $r = Invoke-Imp (New-Imp $e) $lot

        $r.MessagesImported | Should -Be 5
        $r.MessagesRejected | Should -Be 0
        $r.Stopped | Should -BeFalse
        $chat.MigrationMode | Should -Be 'completed'
        @($chat.Messages).Count | Should -Be 5
        @($chat.Messages | ForEach-Object CreatedMs) | Should -Be @(1..5 | ForEach-Object { (At $_).ToUnixTimeMilliseconds() })
        $chat.Messages[0].AuthorOrd | Should -Be $e.Users.alice.Ordinal
        $chat.Messages[1].AuthorOrd | Should -Be $e.Users.bob.Ordinal
        $chat.CreatedMs | Should -Be ((At 1).ToUnixTimeMilliseconds() - 1000)         # conversationCreationDateTime = oldest message - 1 s
        (Get-States $e 'chat:S1' | Sort-Object -Unique) | Should -Be 'Imported'
        (Get-Journal $e 'chat:S1' | Where-Object { -not $_.TargetMessageId }).Count | Should -Be 0
        $s = $e.Store.GetLatestImportSession('chat:S1', 1)
        [string]$s.State | Should -Be 'Completed'
        $s.AppId | Should -Be 'app-1'
        $s.ConversationCreationUtc | Should -Be ((At 1).AddSeconds(-1))
        [string]($e.Store.ListItems($lot) | Select-Object -First 1).State | Should -Be 'Completing'
        [string]$e.Store.GetLot($lot).State | Should -Be 'Completing'
        $r.ItemsCompleted | Should -Be 1
        $r.RequestsByClass['migration.importMessage'] | Should -Be 5
        $r.RequestsByClass['migration.start'] | Should -Be 1
        $r.RequestsByClass['migration.complete'] | Should -Be 1
    }

    It 'a second run finds nothing left to do and sends nothing' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        [void](Invoke-Imp (New-Imp $e) $c.Lot)
        $e.Fake.Counters.Reset()
        $r2 = Invoke-Imp (New-Imp $e) $c.Lot
        $r2.MessagesImported | Should -Be 0
        $e.Fake.Counters.TotalCalls | Should -Be 0
        @($c.Chat.Messages).Count | Should -Be 3
    }

    It 'NewChat: a group chat is created with the mapped members, ids are recorded back, then imported' {
        $e = New-Env; Set-Ident $e
        Add-Source $e 'chat:G1' 'Group' (1..4 | ForEach-Object { New-Msg -At (At $_) -From 'src-carol' }) -Topic 'Project'
        $e.Targets.Upsert((New-Tgt -Key 'chat:G1' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id, $e.Users.carol.Id) -Topic 'Project'))
        $lot = New-LotFor $e 'L1' @('chat:G1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.ChatsCreated | Should -Be 1
        @($e.Tenant.Chats).Count | Should -Be 1
        $chat = $e.Tenant.Chats[0]
        $chat.TypeName | Should -Be 'group'
        $chat.Topic | Should -Be 'Project'
        @($chat.Members).Count | Should -Be 3
        $tm = $e.Targets.Get('chat:G1')
        [string]$tm.State | Should -Be 'Created'
        $tm.TargetChatId | Should -Be $chat.Id
        @($chat.Messages).Count | Should -Be 4
        $chat.MigrationMode | Should -Be 'completed'
    }

    It 'NewChat 1:1: the API returns the existing chat, no second chat is made' {
        $e = New-Env; Set-Ident $e
        $existing = $e.Tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::OneOnOne, [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice, $e.Users.bob), $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        Add-Source $e 'chat:O1' 'OneOnOne' (1..2 | ForEach-Object { New-Msg -At (At $_) })
        $e.Targets.Upsert((New-Tgt -Key 'chat:O1' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('chat:O1')
        [void](Invoke-Imp (New-Imp $e) $lot)
        @($e.Tenant.Chats).Count | Should -Be 1
        $e.Targets.Get('chat:O1').TargetChatId | Should -Be $existing.Id
        @($existing.Messages).Count | Should -Be 2
    }

    It 'departed members: ghosts are never added as members; a 1:1 with a departed person becomes a group chat with the service account' {
        $e = New-Env; Set-Ident $e
        $e.Ids.Set('src-gone', 'Ghost', $e.Users.ghost.Id, 'Gone Person', 'gone@src.com', 'Gone Person (former)')
        # 1:1 with the departed person, planned before the ghost existed: placeholder "ghost:<source id>"
        Add-Source $e 'chat:O2' 'OneOnOne' (1..2 | ForEach-Object { New-Msg -At (At $_) -From $(if ($_ -eq 1) { 'src-gone' } else { 'src-alice' }) })
        $e.Targets.Upsert((New-Tgt -Key 'chat:O2' -Kind NewChat -Members @($e.Users.alice.Id, 'ghost:src-gone')))
        # group chat whose planned members include the created ghost's target id
        Add-Source $e 'chat:G2' 'Group' (1..2 | ForEach-Object { New-Msg -At (At $_) })
        $e.Targets.Upsert((New-Tgt -Key 'chat:G2' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id, $e.Users.ghost.Id) -Topic 'Project'))
        $lot = New-LotFor $e 'L1' @('chat:O2', 'chat:G2')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesRejected | Should -Be 0
        $r.MessagesImported | Should -Be 4
        $o2 = @($e.Tenant.Chats) | Where-Object { $_.Id -eq $e.Targets.Get('chat:O2').TargetChatId }
        [string]$o2.ChatType | Should -Be 'Group'
        $o2.Topic | Should -Be 'Archived chat with Gone Person'
        @($o2.Members | ForEach-Object { $_.UserOrd }) | Should -Not -Contain $e.Users.ghost.Ordinal
        @($o2.Members | ForEach-Object { $_.UserOrd }) | Should -Contain $e.Users.svc.Ordinal
        $g2 = @($e.Tenant.Chats) | Where-Object { $_.Id -eq $e.Targets.Get('chat:G2').TargetChatId }
        @($g2.Members | ForEach-Object { $_.UserOrd }) | Should -Not -Contain $e.Users.ghost.Ordinal
        $o2.Messages[0].AuthorOrd | Should -Be $e.Users.ghost.Ordinal          # the ghost stays the author
        @($r.Warnings | Where-Object { $_ -match 'departed member' }).Count | Should -BeGreaterThan 0
    }

    It 'channel with replies: replies follow their root through /replies and are linked to it' {
        $e = New-Env; Set-Ident $e
        $team = $e.Tenant.AddTeam('Atlas', [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice), [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $ch = $e.Tenant.AddChannel($team, 'General2', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $m = @(
            (New-Msg -Id 'r1' -At (At 1) -Body '<p>root 1</p>')
            (New-Msg -Id 'a1' -At (At 2) -ReplyTo 'r1' -From 'src-bob')
            (New-Msg -Id 'a2' -At (At 3) -ReplyTo 'r1')
            (New-Msg -Id 'r2' -At (At 4) -Body '<p>root 2</p>')
            (New-Msg -Id 'b1' -At (At 5) -ReplyTo 'r2' -From 'src-carol'))
        Add-Source $e 'channel:ST/SC' 'Channel' $m -Team 'ST' -Chan 'SC' -Membership 'standard'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/SC' -Kind ExistingChannel -TeamId $team.Id -ChannelId $ch.Id))
        $lot = New-LotFor $e 'L1' @('channel:ST/SC')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesImported | Should -Be 5
        $r.MessagesRejected | Should -Be 0
        @($ch.Messages).Count | Should -Be 5
        $r1 = $ch.Messages | Where-Object { $_.CreatedMs -eq (At 1).ToUnixTimeMilliseconds() }
        $r2 = $ch.Messages | Where-Object { $_.CreatedMs -eq (At 4).ToUnixTimeMilliseconds() }
        @($ch.Messages | Where-Object { $_.ReplyTo -eq $r1.CreatedMs }).Count | Should -Be 2
        @($ch.Messages | Where-Object { $_.ReplyTo -eq $r2.CreatedMs }).Count | Should -Be 1
        $ch.MigrationMode | Should -Be 'completed'
        (Get-Journal $e 'channel:ST/SC' | Where-Object { -not $_.TargetMessageId }).Count | Should -Be 0
    }

    It 'a reply dated at or before its root is shifted just after it (and the shift is recorded)' {
        $e = New-Env; Set-Ident $e
        $team = $e.Tenant.AddTeam('Atlas', [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice), [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $ch = $e.Tenant.AddChannel($team, 'C2', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $m = @((New-Msg -Id 'r1' -At (At 1)), (New-Msg -Id 'a1' -At (At 1) -ReplyTo 'r1'))
        Add-Source $e 'channel:ST/SC' 'Channel' $m -Team 'ST' -Chan 'SC'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/SC' -Kind ExistingChannel -TeamId $team.Id -ChannelId $ch.Id))
        $lot = New-LotFor $e 'L1' @('channel:ST/SC')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesRejected | Should -Be 0
        $r.DateShifts | Should -Be 1
        $rep = $ch.Messages | Where-Object { $_.ReplyTo -ne 0 }
        $rep.CreatedMs | Should -Be ((At 1).ToUnixTimeMilliseconds() + 1)
    }

    It 'NewChannel: the team is created with ONE member, the channel and the members follow, ids are recorded; two channels of one team make one team' {
        $e = New-Env; Set-Ident $e
        foreach ($k in 'channel:ST/C1', 'channel:ST/C2') {
            Add-Source $e $k 'Channel' (1..3 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan $k.Split('/')[1] -Membership 'private'
            $e.Targets.Upsert((New-Tgt -Key $k -Kind NewChannel -TeamName 'Atlas migrated' -Topic ('chan-' + $k.Split('/')[1]) -Membership private -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        }
        $lot = New-LotFor $e 'L1' @('channel:ST/C1', 'channel:ST/C2')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.TeamsCreated | Should -Be 1
        $r.ChannelsCreated | Should -Be 2
        @($e.Tenant.Teams).Count | Should -Be 1
        $team = $e.Tenant.Teams[0]
        @($team.Members).Count | Should -Be 3                          # created with ONE member (phase 0), the planned members are added to the TEAM before the private channels
        $privates = @($team.Channels | Where-Object { $_.TypeName -eq 'private' })
        $privates.Count | Should -Be 2
        foreach ($c in $privates) { @($c.Members).Count | Should -Be 3; @($c.Messages).Count | Should -Be 3; $c.MigrationMode | Should -Be 'completed' }
        foreach ($k in 'channel:ST/C1', 'channel:ST/C2') {
            $t = $e.Targets.Get($k)
            [string]$t.State | Should -Be 'Created'
            $t.TargetTeamId | Should -Be $team.Id
            $t.TargetChannelId | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Message content' {
    It 'inline image: re-attached from the store as hostedContents with a temporaryId, src rewritten; a missing image is dropped with a reason' {
        $e = New-Env
        $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4)
        $ref = $e.Store.PutContent([IO.MemoryStream]::new($png), 'image/png')
        $body1 = '<p>look</p><img src="https://graph.microsoft.com/v1.0/chats/19:x/messages/m1/hostedContents/HID1/$value" alt="i">'
        $body2 = '<p>gone</p><img src="https://graph.microsoft.com/v1.0/chats/19:x/messages/m2/hostedContents/HID2/$value">'
        $c = Use-Chat $e 'chat:S1' @((New-Msg -Id 'm1' -At (At 1) -Body $body1), (New-Msg -Id 'm2' -At (At 2) -Body $body2))
        $e.Store.RecordHostedContent('chat:S1', 'm1', 'HID1', $ref)
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesImported | Should -Be 2
        $m1 = $c.Chat.Messages[0]; $m2 = $c.Chat.Messages[1]
        @($m1.X.Hosted).Count | Should -Be 1
        $m1.X.Hosted[0].Bytes | Should -Be $png
        $m1.X.Hosted[0].ContentType | Should -Be 'image/png'
        $m1.X.Body | Should -Match ('hostedContents/' + [regex]::Escape($m1.X.Hosted[0].Id) + '/\$value')
        $m1.X.Body | Should -Not -Match 'HID1'
        $m2.X.Hosted | Should -BeNullOrEmpty
        $m2.X.Body | Should -Match 'image not available'
        $r.DroppedByReason['HostedContentMissing'] | Should -Be 1
    }

    It 'mentions: a mapped user is re-pointed to the target user, an unmapped one becomes plain text with a reason' {
        $e = New-Env
        $ments = @(
            @{ id = 0; mentionText = 'Bob'; mentioned = @{ user = @{ id = 'src-bob'; displayName = 'Bob Src'; userIdentityType = 'aadUser' } } }
            @{ id = 1; mentionText = 'Zed'; mentioned = @{ user = @{ id = 'src-zed'; displayName = 'Zed'; userIdentityType = 'aadUser' } } })
        $c = Use-Chat $e 'chat:S1' @((New-Msg -At (At 1) -Body '<p><at id="0">Bob</at> and <at id="1">Zed</at></p>' -Extra @{ mentions = $ments }))
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $m = $c.Chat.Messages[0]
        @($m.X.Mentions).Count | Should -Be 1
        $m.X.Mentions[0].UserOrd | Should -Be $e.Users.bob.Ordinal
        $m.X.Body | Should -Match '<at id="0">Bob</at>'
        $m.X.Body | Should -Not -Match '<at id="1">'
        $m.X.Body | Should -Match 'Zed'
        $r.DroppedByReason['MentionUnmapped'] | Should -Be 1
    }

    It 'reactions: mapped users only, at most 250' {
        $e = New-Env
        $react = { param($u, $t) @{ reactionType = $t; createdDateTime = '2026-02-01T09:05:00.000Z'; user = @{ user = @{ id = $u; displayName = $u; userIdentityType = 'aadUser' } } } }
        $three = @((& $react 'src-alice' 'like'), (& $react 'src-bob' 'heart'), (& $react 'src-zed' 'like'))
        $many = @(1..260 | ForEach-Object { & $react $(if ($_ % 2) { 'src-alice' } else { 'src-bob' }) 'like' })
        $c = Use-Chat $e 'chat:S1' @((New-Msg -At (At 1) -Extra @{ reactions = $three }), (New-Msg -At (At 2) -Extra @{ reactions = $many }))
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesRejected | Should -Be 0
        @($c.Chat.Messages[0].X.Reactions).Count | Should -Be 2
        @($c.Chat.Messages[1].X.Reactions).Count | Should -Be 250
        $r.DroppedByReason['ReactionUnmapped'] | Should -Be 1
        $r.DroppedByReason['ReactionsTruncated'] | Should -Be 1
    }

    It 'reference attachment: pointed to the copied file; a file that was not copied is skipped with a note' {
        $e = New-Env
        $g1 = [guid]::NewGuid().ToString(); $g2 = [guid]::NewGuid().ToString()
        $atts = @(@{ id = $g1; contentType = 'reference'; contentUrl = 'https://src.sharepoint.com/f1.docx'; name = 'f1.docx' }, @{ id = $g2; contentType = 'reference'; contentUrl = 'https://src.sharepoint.com/f2.docx'; name = 'f2.docx' })
        $body = "<p>files</p><attachment id=`"$g1`"></attachment><attachment id=`"$g2`"></attachment>"
        $c = Use-Chat $e 'chat:S1' @((New-Msg -Id 'm1' -At (At 1) -Body $body -Extra @{ attachments = $atts }))
        $e.Files.Upsert([TeamsTransfer.FileCopyRecord]@{ ConversationKey = 'chat:S1'; MessageId = 'm1'; AttachmentId = $g1; Name = 'f1.docx'; TargetWebUrl = 'https://tgt.sharepoint.com/f1.docx'; State = 'Uploaded' })
        $e.Files.Upsert([TeamsTransfer.FileCopyRecord]@{ ConversationKey = 'chat:S1'; MessageId = 'm1'; AttachmentId = $g2; Name = 'f2.docx'; State = 'Failed'; Error = 'locked' })
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $m = $c.Chat.Messages[0]
        @($m.X.Attachments).Count | Should -Be 1
        $m.X.Attachments[0].ContentUrl | Should -Be 'https://tgt.sharepoint.com/f1.docx'
        $m.X.Attachments[0].Id | Should -Be $g1
        $m.X.Body | Should -Match $g1
        $m.X.Body | Should -Not -Match $g2
        $m.X.Body | Should -Match 'Attachment not copied: f2.docx'
        $r.DroppedByReason['AttachmentNotCopied'] | Should -Be 1
    }

    It 'authors: ghost keeps the name, the service account gets the banner, an unresolved author is rejected, system events and deleted messages are skipped' {
        $e = New-Env; Set-Ident $e
        $e.Ids.Set('src-gone', 'Ghost', $e.Users.ghost.Id, 'Gone Person', 'gone@src.com', 'Gone Person (former)')
        $e.Ids.Set('src-dan', 'ServiceAccount', $e.Users.svc.Id, 'Dan Departed', 'dan@src.com')
        $chat = New-Group $e
        $m = @(
            (New-Msg -Id 'g' -At (At 1) -From 'src-gone')
            (New-Msg -Id 's' -At (At 2) -From 'src-dan' -Body '<p>bye</p>')
            (New-Msg -Id 't' -At (At 3) -From 'src-dan' -Body 'plain text' -ContentType text)
            (New-Msg -Id 'u' -At (At 4) -From 'src-nobody')
            (New-Msg -Id 'x' -At (At 5) -Type 'systemEventMessage' -From '')
            (New-Msg -Id 'd' -At (At 6) -Deleted '2026-02-02T00:00:00Z'))
        Add-Source $e 'chat:S1' 'Group' $m
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id))
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesImported | Should -Be 3
        $r.MessagesRejected | Should -Be 1
        $r.MessagesSkipped | Should -Be 2
        $byId = @{}; foreach ($j in (Get-Journal $e 'chat:S1')) { $byId[$j.SourceMessageId] = $j }
        [string]$byId['u'].Status | Should -Be 'Rejected'
        $byId['u'].ErrorCode | Should -Be 'IdentityUnresolved'
        [string]$byId['x'].Status | Should -Be 'Skipped'
        [string]$byId['d'].Status | Should -Be 'Skipped'
        $chat.Messages[0].AuthorOrd | Should -Be $e.Users.ghost.Ordinal
        $chat.Messages[1].AuthorOrd | Should -Be $e.Users.svc.Ordinal
        $chat.Messages[1].X.Body | Should -Be ('<p><em>Original message from Dan Departed (dan@src.com), 2026-02-01 09:01 UTC</em></p><p>bye</p>')
        $chat.Messages[2].X.Body | Should -Match '^<p><em>Original message from Dan Departed'
        $chat.Messages[2].X.Body | Should -Match '<p>plain text</p>$'
        (Get-TmtImportExitCode -Result $r) | Should -Be 3
    }

    It 'collision: messages with the same millisecond are shifted by +1 ms each and the shift is journaled' {
        $e = New-Env
        $same = '2026-02-01T09:00:00.1234567Z'     # sub-millisecond digits are truncated, never rounded
        $m = @((New-Msg -Id 'a' -At $script:T0 -CreatedText $same), (New-Msg -Id 'b' -At $script:T0 -CreatedText $same), (New-Msg -Id 'c' -At $script:T0 -CreatedText '2026-02-01T09:00:00.123Z'))
        $c = Use-Chat $e 'chat:S1' $m
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $base = $script:T0.ToUnixTimeMilliseconds() + 123
        @($c.Chat.Messages | ForEach-Object CreatedMs) | Should -Be @($base, ($base + 1), ($base + 2))
        $r.DateShifts | Should -Be 2
        $r.MessagesRejected | Should -Be 0
        $j = @{}; foreach ($x in (Get-Journal $e 'chat:S1')) { $j[$x.SourceMessageId] = $x }
        # the store orders by the exact date (c = .1230000 comes first), then by id: c keeps its date, a and b are pushed by 1 and 2 ms
        $j['c'].ErrorCode | Should -BeNullOrEmpty
        $j['a'].ErrorCode | Should -Match 'shift\+1ms'
        $j['b'].ErrorCode | Should -Match 'shift\+2ms'
    }
}

Describe 'Idempotency and resume' {
    It 'kill between a POST and its journal entry: the next run meets the 409, treats it as imported and sends nothing twice' {
        $e = New-Env
        # collisions in the data: the +1 ms shifts must be recomputed identically by the resumed run
        $m = @(1..9 | ForEach-Object { New-Msg -Id "m$_" -At (At ([math]::Ceiling($_ / 2))) }) + @(New-Msg -Id 'm10' -At (At 9))
        $c = Use-Chat $e 'chat:S1' $m
        $cts = [Threading.CancellationTokenSource]::new()
        $e.Real.KillAfterPost = 3; $e.Real.KillSource = $cts
        $threw = $false
        try { [void](New-Imp $e).RunAsync($c.Lot, [int[]]@(), $cts.Token).GetAwaiter().GetResult() } catch { $threw = $true }
        $threw | Should -BeTrue
        @($c.Chat.Messages).Count | Should -Be 3                                  # the service executed the third POST
        @(Get-States $e 'chat:S1' | Where-Object { $_ -eq 'Imported' }).Count | Should -Be 2    # ... but it was never journaled
        @(Get-States $e 'chat:S1' | Where-Object { $_ -eq 'Pending' }).Count | Should -Be 8

        $e.Real.KillAfterPost = 0
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesConflict409 | Should -Be 1
        $r.MessagesImported | Should -Be 7
        $r.MessagesRejected | Should -Be 0
        @($c.Chat.Messages).Count | Should -Be 10
        @($c.Chat.Messages | ForEach-Object CreatedMs | Sort-Object -Unique).Count | Should -Be 10
        $st = Get-States $e 'chat:S1'
        @($st | Where-Object { $_ -eq 'Imported' }).Count | Should -Be 9
        @($st | Where-Object { $_ -eq 'Conflict409TreatedAsImported' }).Count | Should -Be 1
        @($e.Store.ListImportSessions('chat:S1', 1)).Count | Should -Be 1         # the Started session was reused
        [string]$e.Store.GetLatestImportSession('chat:S1', 1).State | Should -Be 'Completed'
        $c.Chat.MigrationMode | Should -Be 'completed'
        [string]($e.Store.ListItems($c.Lot) | Select-Object -First 1).State | Should -Be 'Completing'
    }

    It 'a response lost after the service executed the POST: the GraphClient retry meets the 409 and the message is not duplicated' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..4 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.LoseResponseOnPost = 2
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesConflict409 | Should -Be 1
        $r.MessagesImported | Should -Be 3
        @($c.Chat.Messages).Count | Should -Be 4
        $r.Status409 | Should -Be 1
    }

    It 'a channel root whose response was lost (409 on the retry) still gets its replies: the root id is resolved by its date' {
        $e = New-Env; Set-Ident $e
        $team = $e.Tenant.AddTeam('Atlas', [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice), [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $ch = $e.Tenant.AddChannel($team, 'C3', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $m = @((New-Msg -Id 'r1' -At (At 1)), (New-Msg -Id 'a1' -At (At 2) -ReplyTo 'r1'), (New-Msg -Id 'a2' -At (At 3) -ReplyTo 'r1'))
        Add-Source $e 'channel:ST/SC' 'Channel' $m -Team 'ST' -Chan 'SC'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/SC' -Kind ExistingChannel -TeamId $team.Id -ChannelId $ch.Id))
        $lot = New-LotFor $e 'L1' @('channel:ST/SC')
        $e.Real.LoseResponseOnPost = 1
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesConflict409 | Should -Be 1
        $r.MessagesImported | Should -Be 2
        $r.MessagesRejected | Should -Be 0
        @($ch.Messages).Count | Should -Be 3
        @($ch.Messages | Where-Object { $_.ReplyTo -ne 0 }).Count | Should -Be 2
        $root = (Get-Journal $e 'channel:ST/SC' | Where-Object { $_.SourceMessageId -eq 'r1' })
        [string]$root.Status | Should -Be 'Conflict409TreatedAsImported'
        $root.TargetMessageId | Should -Be ([string](At 1).ToUnixTimeMilliseconds())
    }
    It 'pipeline: up to 3 sends in flight per conversation, never more, and the journal is complete' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..12 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.LatencyMs = 40
        $imp = New-Imp $e -Tune { param($t) $t.InFlightPerConversation = 3 }
        $r = Invoke-Imp $imp $c.Lot
        $r.MessagesImported | Should -Be 12
        $r.MessagesRejected | Should -Be 0
        $e.Real.MaxConcurrentPosts | Should -Be 3
        @($c.Chat.Messages | ForEach-Object CreatedMs | Sort-Object -Unique).Count | Should -Be 12
        (Get-States $e 'chat:S1' | Sort-Object -Unique) | Should -Be 'Imported'
        $imp.Progress.Phase | Should -Match 'msg/s each'
        $e2 = New-Env
        $c2 = Use-Chat $e2 'chat:S1' @(1..6 | ForEach-Object { New-Msg -At (At $_) })
        $e2.Real.LatencyMs = 20
        [void](Invoke-Imp (New-Imp $e2) $c2.Lot)
        $e2.Real.MaxConcurrentPosts | Should -Be 1                       # InFlightPerConversation = 1 is the old sequential behaviour
    }

    It 'pipeline: a kill with several sends in flight is resolved by the 409 on resume, nothing is duplicated' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..12 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.LatencyMs = 20
        $cts = [Threading.CancellationTokenSource]::new()
        $e.Real.KillAfterPost = 5; $e.Real.KillSource = $cts
        $threw = $false
        try { [void](New-Imp $e -Tune { param($t) $t.InFlightPerConversation = 3 }).RunAsync($c.Lot, [int[]]@(), $cts.Token).GetAwaiter().GetResult() } catch { $threw = $true }
        $threw | Should -BeTrue
        $e.Real.KillAfterPost = 0; $e.Real.LatencyMs = 0
        $r = Invoke-Imp (New-Imp $e -Tune { param($t) $t.InFlightPerConversation = 3 }) $c.Lot
        $r.MessagesRejected | Should -Be 0
        @($c.Chat.Messages).Count | Should -Be 12
        @($c.Chat.Messages | ForEach-Object CreatedMs | Sort-Object -Unique).Count | Should -Be 12
        @(Get-States $e 'chat:S1' | Where-Object { $_ -notin 'Imported', 'Conflict409TreatedAsImported' }).Count | Should -Be 0
        $r.MessagesConflict409 | Should -BeGreaterThan 0
        $c.Chat.MigrationMode | Should -Be 'completed'
    }

    It 'pipeline on a channel: replies wait for the target id of their root, links are right' {
        $e = New-Env; Set-Ident $e
        $team = $e.Tenant.AddTeam('Atlas', [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice), [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $ch = $e.Tenant.AddChannel($team, 'C4', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
        $m = @(); foreach ($i in 0..2) { $m += (New-Msg -Id "r$i" -At (At (1 + $i * 10))); $m += (New-Msg -Id "a$i" -At (At (2 + $i * 10)) -ReplyTo "r$i"); $m += (New-Msg -Id "b$i" -At (At (3 + $i * 10)) -ReplyTo "r$i") }
        Add-Source $e 'channel:ST/SC' 'Channel' $m -Team 'ST' -Chan 'SC'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/SC' -Kind ExistingChannel -TeamId $team.Id -ChannelId $ch.Id))
        $lot = New-LotFor $e 'L1' @('channel:ST/SC')
        $e.Real.LatencyMs = 30
        $r = Invoke-Imp (New-Imp $e -Tune { param($t) $t.InFlightPerConversation = 3 }) $lot
        $r.MessagesImported | Should -Be 9
        $r.MessagesRejected | Should -Be 0
        foreach ($i in 0..2) {
            $rootMs = (At (1 + $i * 10)).ToUnixTimeMilliseconds()
            @($ch.Messages | Where-Object { $_.ReplyTo -eq $rootMs }).Count | Should -Be 2
        }
    }

    It 'pipeline stays under the 5 requests per second per conversation (real time, limiter on)' {
        $e = New-Env -WithLimiter -RealTime
        $e.Fake.Faults.ImportLimitPerThread = 5
        $c = Use-Chat $e 'chat:S1' @(1..12 | ForEach-Object { New-Msg -At (At $_) })
        # Latency longer than the limiter spacing (200 ms at 5/s), as on the real service (~0.8 s): only then can POSTs overlap.
        # With 30 ms they never did, and the concurrency assertion depended on scheduler luck.
        $e.Real.LatencyMs = 400
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Imp (New-Imp $e -Tune { param($t) $t.InFlightPerConversation = 3 }) $c.Lot
        $sw.Stop()
        $r.MessagesImported | Should -Be 12
        $r.MessagesRejected | Should -Be 0
        $e.Real.MaxConcurrentPosts | Should -BeGreaterThan 1
        $e.Real.MaxPostsPerWindow() | Should -BeLessOrEqual 6          # 5 per second plus timer jitter
        $e.Fake.Counters.Total429 | Should -BeLessOrEqual 2
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 1.8              # 12 messages cannot go faster than 5 per second
    }

    It 'a stop request between two messages leaves the thread in migration mode (exit 2), the next run resumes and completes (exit 0)' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..10 | ForEach-Object { New-Msg -At (At $_) })
        $stop = [TeamsTransfer.StopControl]::new()
        $e.Real.StopAfterPosts = 4; $e.Real.StopControlToRequest = $stop
        $cfg = { param($o) $o.Stop = $stop }.GetNewClosure()
        $r1 = Invoke-Imp (New-Imp $e -Configure $cfg) $c.Lot
        $r1.Stopped | Should -BeTrue
        $r1.MessagesImported | Should -Be 4
        $r1.MessagesPending | Should -Be 6
        (Get-TmtImportExitCode -Result $r1) | Should -Be 2
        $c.Chat.MigrationMode | Should -Be 'inProgress'
        [string]($e.Store.ListItems($c.Lot) | Select-Object -First 1).State | Should -Be 'Importing'
        [string]$e.Store.GetLot($c.Lot).State | Should -Be 'Importing'

        $e.Real.StopAfterPosts = 0
        $r2 = Invoke-Imp (New-Imp $e) $c.Lot
        $r2.Stopped | Should -BeFalse
        $r2.MessagesImported | Should -Be 6
        (Get-TmtImportExitCode -Result $r2) | Should -Be 0
        @($c.Chat.Messages).Count | Should -Be 10
        $c.Chat.MigrationMode | Should -Be 'completed'
        @($e.Store.ListImportSessions('chat:S1', 1)).Count | Should -Be 1
    }

    It 'two waves on one conversation: the second (older) wave reopens the thread with an even earlier creation date' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $wave1 = 1..3 | ForEach-Object { New-Msg -At (At $_) }
        $old = [datetimeoffset]::Parse('2024-03-01T10:00:00Z')
        $wave2 = 1..3 | ForEach-Object { New-Msg -At $old.AddMinutes($_) }
        Add-Source $e 'chat:S1' 'Group' (@($wave1) + @($wave2))
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id))
        $lot = New-LotFor $e 'L1' @('chat:S1') -Slices @(1)
        $r1 = Invoke-Imp (New-Imp $e) $lot
        $r1.MessagesImported | Should -Be 3
        $chat.MigrationMode | Should -Be 'completed'
        $createdAfterWave1 = $chat.CreatedMs

        [void]$e.Store.ResolveLot($lot, [int[]]@(2))
        $r2 = Invoke-Imp (New-Imp $e) $lot @(2)
        $r2.MessagesImported | Should -Be 3
        @($chat.Messages).Count | Should -Be 6
        $chat.MigrationMode | Should -Be 'completed'
        $chat.CreatedMs | Should -BeLessThan $createdAfterWave1
        $chat.CreatedMs | Should -Be ($old.AddMinutes(1).ToUnixTimeMilliseconds() - 1000)
        $s1 = $e.Store.GetLatestImportSession('chat:S1', 1); $s2 = $e.Store.GetLatestImportSession('chat:S1', 2)
        $s2.ConversationCreationUtc | Should -BeLessThan $s1.ConversationCreationUtc
        [string]$s2.State | Should -Be 'Completed'
        @($e.Store.ListItems($lot) | ForEach-Object { [string]$_.State } | Sort-Object -Unique) | Should -Be 'Completing'
    }
}

Describe 'Lab regressions: chats, teams, members' {
    It 'a new group chat is created WITHOUT visibleHistoryStartDateTime (the service refuses it); members are then removed and re-added with it, paced at 4 requests/min' {
        $e = New-Env; Set-Ident $e
        Add-Source $e 'chat:G1' 'Group' (1..3 | ForEach-Object { New-Msg -At (At $_) -From 'src-carol' }) -Topic 'Project'
        $e.Targets.Upsert((New-Tgt -Key 'chat:G1' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id, $e.Users.carol.Id) -Topic 'Project'))
        $lot = New-LotFor $e 'L1' @('chat:G1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.ChatsCreated | Should -Be 1
        $r.ItemsFailed | Should -Be 0
        $r.MessagesImported | Should -Be 3
        $chat = $e.Tenant.Chats[0]
        @($chat.Members).Count | Should -Be 3
        foreach ($mem in $chat.Members) { $mem.VisibleHistoryStartMs | Should -Be ([TeamsTransfer.Testing.FakeMember]::AllHistory) }
        @($e.Real.Records | Where-Object { $_.Method -eq 'DELETE' }).Count | Should -Be 3
        (@($e.Clock.Delays | Where-Object { $_.TotalSeconds -eq 15 })).Count | Should -BeGreaterOrEqual 6
        $e.Targets.Get('chat:G1').Note | Should -Match 'history-restored'
        @($r.Warnings).Count | Should -Be 0
        # a second run does not touch the members again
        $e.Real.Records | Out-Null
        $before = @($e.Real.Records | Where-Object { $_.Method -eq 'DELETE' }).Count
        [void](Invoke-Imp (New-Imp $e) $lot)
        @($e.Real.Records | Where-Object { $_.Method -eq 'DELETE' }).Count | Should -Be $before
    }

    It 'history restore can be switched off, and is never done for a 1:1 chat' {
        $e = New-Env; Set-Ident $e
        Add-Source $e 'chat:O1' 'OneOnOne' (1..2 | ForEach-Object { New-Msg -At (At $_) })
        $e.Targets.Upsert((New-Tgt -Key 'chat:O1' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.carol.Id)))
        Add-Source $e 'chat:G2' 'Group' (1..2 | ForEach-Object { New-Msg -At (At $_) })
        $e.Targets.Upsert((New-Tgt -Key 'chat:G2' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id, $e.Users.carol.Id)))
        $lot = New-LotFor $e 'L1' @('chat:O1', 'chat:G2')
        [void](Invoke-Imp (New-Imp $e -Tune { param($t) $t.RestoreGroupHistory = $false }) $lot)
        @($e.Real.Records | Where-Object { $_.Method -eq 'DELETE' }).Count | Should -Be 0
        $e2 = New-Env; Set-Ident $e2
        Add-Source $e2 'chat:O1' 'OneOnOne' (1..2 | ForEach-Object { New-Msg -At (At $_) })
        $e2.Targets.Upsert((New-Tgt -Key 'chat:O1' -Kind NewChat -Members @($e2.Users.alice.Id, $e2.Users.carol.Id)))
        $lot2 = New-LotFor $e2 'L1' @('chat:O1')
        $r2 = Invoke-Imp (New-Imp $e2) $lot2
        $r2.ItemsFailed | Should -Be 0
        @($e2.Real.Records | Where-Object { $_.Method -eq 'DELETE' }).Count | Should -Be 0
    }

    It 'a standard channel of a new team: the owner is the service account, and every planned member of every channel is added to the TEAM first' {
        $e = New-Env; Set-Ident $e
        $e.Tenant | Out-Null
        Add-Source $e 'channel:ST/C1' 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan 'C1' -Membership 'standard'
        Add-Source $e 'channel:ST/C2' 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan 'C2' -Membership 'private'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'Atlas migrated' -Topic 'std' -Membership standard))            # a standard channel lists no members
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C2' -Kind NewChannel -TeamName 'Atlas migrated' -Topic 'priv' -Membership private -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('channel:ST/C1', 'channel:ST/C2')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.ItemsFailed | Should -Be 0
        $r.TeamsCreated | Should -Be 1
        $team = $e.Tenant.Teams[0]
        $owners = @($team.Members | Where-Object { $_.Roles -eq 'owner' })
        $owners.Count | Should -Be 1
        $owners[0].UserOrd | Should -Be $e.Users.svc.Ordinal
        @($team.Members | ForEach-Object UserOrd | Sort-Object) | Should -Be @(@($e.Users.alice.Ordinal, $e.Users.bob.Ordinal, $e.Users.svc.Ordinal) | Sort-Object)
        $priv = $team.Channels | Where-Object { $_.TypeName -eq 'private' }
        @($priv.Members).Count | Should -Be 3
        @($priv.Messages).Count | Should -Be 2
        @($r.Warnings).Count | Should -Be 0
    }

    It 'without a service account the owner of a new team is a planned member of ANY of its channels (not only the first channel''s list)' {
        $e = New-Env; Set-Ident $e
        foreach ($k in 'channel:ST/C1', 'channel:ST/C2') { Add-Source $e $k 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan $k.Split('/')[1] }
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'T' -Topic 'one' -Membership standard))
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C2' -Kind NewChannel -TeamName 'T' -Topic 'two' -Membership standard -Members @($e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('channel:ST/C1', 'channel:ST/C2')
        $r = Invoke-Imp (New-Imp $e -Configure { param($o) $o.ServiceAccountUserId = $null }) $lot
        $r.ItemsFailed | Should -Be 0
        @($e.Tenant.Teams).Count | Should -Be 1
        $e.Tenant.Teams[0].Members[0].UserOrd | Should -Be $e.Users.bob.Ordinal
        @($e.Tenant.Teams[0].Channels | Where-Object { -not $_.IsGeneral }).Count | Should -Be 2
    }

    It 'no service account and nobody planned for a new team: refused at the start, once, before anything is sent or the lot moves' {
        $e = New-Env; Set-Ident $e
        Add-Source $e 'channel:ST/C1' 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan 'C1'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'T' -Topic 'one' -Membership standard))
        $lot = New-LotFor $e 'L1' @('channel:ST/C1')
        { Invoke-Imp (New-Imp $e -Configure { param($o) $o.ServiceAccountUserId = $null }) $lot } | Should -Throw '*No service account*'
        $e.Fake.Counters.TotalCalls | Should -Be 0
        [string]$e.Store.GetLot($lot).State | Should -Be 'ImportPlanned'
    }

    It 'Importer.ResolveUserIdAsync: an object id is kept, a UPN is resolved with GET /users, an unknown UPN gives null' {
        $e = New-Env
        $guid = [guid]::NewGuid().ToString()
        [TeamsTransfer.Importer]::ResolveUserIdAsync($e.Client, $guid, $script:ct).GetAwaiter().GetResult() | Should -Be $guid
        [TeamsTransfer.Importer]::ResolveUserIdAsync($e.Client, 'svc@contoso.com', $script:ct).GetAwaiter().GetResult() | Should -Be $e.Users.svc.Id
        [TeamsTransfer.Importer]::ResolveUserIdAsync($e.Client, 'nobody@contoso.com', $script:ct).GetAwaiter().GetResult() | Should -BeNullOrEmpty
    }

    It 'Invoke-TmtImport finds the service account: parameter (UPN resolved), configuration, then the ServiceAccount identity of the plan' {
        $e = New-Env; Set-Ident $e
        Add-Source $e 'channel:ST/C1' 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan 'C1'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'T' -Topic 'one' -Membership standard))
        $lot = New-LotFor $e 'L1' @('channel:ST/C1')
        $name = $e.Store.GetLot($lot).Name
        $common = @{ Store = $e.Store; Lot = $name; Client = $e.Client; IdentityMap = $e.Ids; TargetMap = $e.Targets; FileMap = $e.Files; Apply = $true; AppId = 'app-1' }
        { Invoke-TmtImport @common } | Should -Throw '*No service account*'
        $r = Invoke-TmtImport @common -ServiceAccount 'svc@contoso.com'
        $r.ItemsFailed | Should -Be 0
        $e.Tenant.Teams[0].Members[0].UserOrd | Should -Be $e.Users.svc.Ordinal
        $e2 = New-Env; Set-Ident $e2
        $e2.Ids.Set('src-svc', 'ServiceAccount', $e2.Users.svc.Id, 'Svc', 'svc@src.com')
        Add-Source $e2 'channel:ST/C1' 'Channel' (1..2 | ForEach-Object { New-Msg -At (At $_) }) -Team 'ST' -Chan 'C1'
        $e2.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'T' -Topic 'one' -Membership standard))
        $lot2 = New-LotFor $e2 'L1' @('channel:ST/C1')
        $r2 = Invoke-TmtImport -Store $e2.Store -Lot ($e2.Store.GetLot($lot2).Name) -Client $e2.Client -IdentityMap $e2.Ids -TargetMap $e2.Targets -FileMap $e2.Files -Apply -AppId 'app-1' -Configuration @{ Target = @{ ServiceAccountUserId = 'svc@contoso.com' } }
        $r2.ItemsFailed | Should -Be 0
        $e2.Tenant.Teams[0].Members[0].UserOrd | Should -Be $e2.Users.svc.Ordinal
    }
}

Describe 'Files copied inline (lot J FileCopier) before the messages' {
    BeforeAll {
        function Add-FileMessage($e, [string]$Key, [string]$MsgId, [datetimeoffset]$At, [string]$Name, [byte[]]$Bytes, [string]$AttId, [switch]$NoContent) {
            $body = "<p>file</p><attachment id=`"$AttId`"></attachment>"
            $atts = @(@{ id = $AttId; contentType = 'reference'; contentUrl = "https://src.sharepoint.com/$Name"; name = $Name })
            $msg = New-Msg -Id $MsgId -At $At -Body $body -Extra @{ attachments = $atts }
            $sha = 'f' * 64; $len = [long]$Bytes.Length
            if (-not $NoContent) { $c = $e.Store.PutContent([IO.MemoryStream]::new($Bytes), 'application/octet-stream'); $sha = $c.Sha256; $len = $c.Length }
            $f = [TeamsTransfer.FileRecord]@{ ConversationKey = $Key; MessageId = $MsgId; AttachmentId = $AttId; Name = $Name; Size = $len; Status = [TeamsTransfer.FileStatus]::Downloaded; Sha256 = $sha }
            $e.Store.RecordFile($f)
            $msg
        }
    }

    It 'a chat: the file is uploaded and shared before the message, and the imported attachment points to it' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $bytes = [byte[]](1..200 | ForEach-Object { $_ % 251 })
        $g = [guid]::NewGuid().ToString()
        $m = Add-FileMessage $e 'chat:S1' 'm1' (At 1) 'report.pdf' $bytes $g
        Add-Source $e 'chat:S1' 'Group' @($m)
        $t = New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id -Members @($e.Users.alice.Id, $e.Users.bob.Id)
        $e.Targets.Upsert($t)
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesImported | Should -Be 1
        $r.FilesCopied | Should -Be 1
        $r.FilesFailed | Should -Be 0
        $rec = $e.Files.Get('chat:S1', 'm1', $g)
        ([string]$rec.State) | Should -BeIn 'Uploaded', 'Shared'
        $msg = $chat.Messages[0]
        @($msg.X.Attachments).Count | Should -Be 1
        $msg.X.Attachments[0].ContentUrl | Should -Be $rec.TargetWebUrl
        $r.DroppedByReason.ContainsKey('AttachmentNotCopied') | Should -BeFalse
        # the upload (PUT / createUploadSession) came before the first message POST
        $recs = $e.Real.Records
        $firstPost = [array]::IndexOf($recs, ($recs | Where-Object { [TeamsTransfer.Testing.ImportRealismTransport]::IsImportPost($_.Method, $_.Url) } | Select-Object -First 1))
        $upload = [array]::IndexOf($recs, ($recs | Where-Object { $_.Method -eq 'PUT' -or $_.Url -match 'createUploadSession' } | Select-Object -First 1))
        $upload | Should -BeGreaterOrEqual 0
        $upload | Should -BeLessThan $firstPost
        # a second run copies nothing again
        $e.Real.Records | Out-Null
        $puts = @($e.Real.Records | Where-Object { $_.Method -eq 'PUT' }).Count
        [void](Invoke-Imp (New-Imp $e) $lot)
        @($e.Real.Records | Where-Object { $_.Method -eq 'PUT' }).Count | Should -Be $puts
    }

    It 'a source attachment id that is not a GUID is posted as a deterministic GUID, and the attachment tag of the body follows (real 400: Invalid GUID a1)' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $bytes = [byte[]](1..90 | ForEach-Object { $_ % 241 })
        $m = Add-FileMessage $e 'chat:S1' 'm1' (At 1) 'notes.txt' $bytes 'a1'
        Add-Source $e 'chat:S1' 'Group' @($m)
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.MessagesImported | Should -Be 1
        $r.MessagesRejected | Should -Be 0
        $att = $chat.Messages[0].X.Attachments[0]
        $parsed = [guid]::Empty
        [guid]::TryParse($att.Id, [ref]$parsed) | Should -BeTrue
        $att.Id | Should -Be ([TeamsTransfer.Importer]::AttachmentGuid('a1'))
        [TeamsTransfer.Importer]::AttachmentGuid('a1') | Should -Be ([TeamsTransfer.Importer]::AttachmentGuid('a1'))
        [TeamsTransfer.Importer]::AttachmentGuid('a2') | Should -Not -Be ([TeamsTransfer.Importer]::AttachmentGuid('a1'))
        $chat.Messages[0].X.Body | Should -Match ('<attachment id="' + $att.Id + '"')
        $chat.Messages[0].X.Body | Should -Not -Match 'id="a1"'
        # a real GUID is kept as it is
        $g = [guid]::NewGuid().ToString('D').ToUpperInvariant()
        [TeamsTransfer.Importer]::AttachmentGuid($g) | Should -Be $g
    }
    It 'a channel created by the import: the files go to the channel folder that exists only now' {
        $e = New-Env; Set-Ident $e
        $bytes = [byte[]](1..120 | ForEach-Object { ($_ * 7) % 251 })
        $g = [guid]::NewGuid().ToString()
        $m = Add-FileMessage $e 'channel:ST/C1' 'm1' (At 1) 'plan.docx' $bytes $g
        Add-Source $e 'channel:ST/C1' 'Channel' @($m) -Team 'ST' -Chan 'C1' -Membership 'standard'
        $e.Targets.Upsert((New-Tgt -Key 'channel:ST/C1' -Kind NewChannel -TeamName 'Atlas' -Topic 'docs' -Membership standard -Members @($e.Users.alice.Id)))
        $lot = New-LotFor $e 'L1' @('channel:ST/C1')
        $r = Invoke-Imp (New-Imp $e) $lot
        $r.ItemsFailed | Should -Be 0
        $r.MessagesImported | Should -Be 1
        $r.FilesCopied | Should -Be 1
        $ch = $e.Tenant.Teams[0].Channels | Where-Object { -not $_.IsGeneral } | Select-Object -First 1
        @($ch.Messages[0].X.Attachments).Count | Should -Be 1
        $ch.Messages[0].X.Attachments[0].ContentUrl | Should -Be $e.Files.Get('channel:ST/C1', 'm1', $g).TargetWebUrl
    }

    It 'CopyFilesInline off: nothing is uploaded and the attachment is dropped with the existing reason; a file that cannot be copied is a warning' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $g = [guid]::NewGuid().ToString()
        $m = Add-FileMessage $e 'chat:S1' 'm1' (At 1) 'a.bin' ([byte[]](1..50)) $g
        Add-Source $e 'chat:S1' 'Group' @($m)
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $r = Invoke-Imp (New-Imp $e -Tune { param($t) $t.CopyFilesInline = $false }) $lot
        $r.FilesCopied | Should -Be 0
        @($e.Real.Records | Where-Object { $_.Method -eq 'PUT' }).Count | Should -Be 0
        $r.DroppedByReason['AttachmentNotCopied'] | Should -Be 1
        $chat.Messages[0].X.Attachments | Should -BeNullOrEmpty

        # content missing from the store: the copy fails, the message is still imported, the attachment dropped
        $e2 = New-Env; Set-Ident $e2
        $chat2 = New-Group $e2
        $g2 = [guid]::NewGuid().ToString()
        $m2 = Add-FileMessage $e2 'chat:S1' 'm1' (At 1) 'lost.bin' ([byte[]](1..50)) $g2 -NoContent
        Add-Source $e2 'chat:S1' 'Group' @($m2)
        $e2.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat2.Id -Members @($e2.Users.alice.Id, $e2.Users.bob.Id)))
        $lot2 = New-LotFor $e2 'L1' @('chat:S1')
        $r2 = Invoke-Imp (New-Imp $e2) $lot2
        $r2.MessagesImported | Should -Be 1
        $r2.MessagesRejected | Should -Be 0
        $r2.DroppedByReason['AttachmentNotCopied'] | Should -Be 1
        $r2.FilesFailed | Should -BeGreaterThan 0
        @($r2.Warnings | Where-Object { $_ -match 'Files of chat:S1' }).Count | Should -BeGreaterThan 0
    }

    It 'dry run: counts the files and bytes to copy, sends nothing' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $m = Add-FileMessage $e 'chat:S1' 'm1' (At 1) 'a.bin' ([byte[]](1..300 | ForEach-Object { $_ % 200 })) ([guid]::NewGuid().ToString())
        Add-Source $e 'chat:S1' 'Group' @($m)
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id -Members @($e.Users.alice.Id, $e.Users.bob.Id)))
        $lot = New-LotFor $e 'L1' @('chat:S1')
        $e.Fake.Counters.Reset()
        $r = Invoke-Imp (New-Imp $e -DryRun) $lot
        $r.DryRun.FilesToCopy | Should -Be 1
        $r.DryRun.FileBytesToCopy | Should -Be 300
        $e.Fake.Counters.TotalCalls | Should -Be 0
    }
}
Describe 'Eventual consistency of migrationMode' {
    It 'polls until inProgress is visible and retries completeMigration with an increasing delay' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.ModeLagAfterStart = 3
        $e.Real.CompleteFailures = 4
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesImported | Should -Be 3
        $r.ItemsCompleted | Should -Be 1
        $c.Chat.MigrationMode | Should -Be 'completed'
        $delays = @($e.Clock.Delays | Where-Object { $_ -gt [TimeSpan]::Zero } | ForEach-Object { $_.TotalSeconds })
        ($delays | Where-Object { $_ -ge 4 }).Count | Should -BeGreaterThan 0               # the completeMigration back-off grew (2, 4, 8, 16 s)
        @($e.Real.Records | Where-Object { $_.Method -eq 'GET' }).Count | Should -BeGreaterThan 4
        @($e.Real.Records | Where-Object { $_.Url -match 'completeMigration' }).Count | Should -Be 5
        # no message was sent before inProgress was visible
        $first = ($e.Real.Records | Where-Object { [TeamsTransfer.Testing.ImportRealismTransport]::IsImportPost($_.Method, $_.Url) } | Select-Object -First 1)
        $firstIdx = [array]::IndexOf($e.Real.Records, $first)
        @($e.Real.Records[0..$firstIdx] | Where-Object { $_.Method -eq 'GET' }).Count | Should -BeGreaterThan 3
    }

    It 'gives up politely when the service does not converge: resumable, no message lost, the next run completes' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.ModeLagAfterStart = 6
        $r1 = Invoke-Imp (New-Imp $e -Tune { param($t) $t.PollMaxAttempts = 3 }) $c.Lot
        $r1.ItemsIncomplete | Should -Be 1
        $r1.MessagesImported | Should -Be 0
        (Get-TmtImportExitCode -Result $r1) | Should -Be 2
        @($c.Chat.Messages).Count | Should -Be 0
        [string]$e.Store.GetLatestImportSession('chat:S1', 1).State | Should -Be 'Started'
        $r2 = Invoke-Imp (New-Imp $e) $c.Lot
        $r2.MessagesImported | Should -Be 3
        $r2.ItemsCompleted | Should -Be 1
        @($e.Store.ListImportSessions('chat:S1', 1)).Count | Should -Be 1
        $c.Chat.MigrationMode | Should -Be 'completed'
    }

    It 'completeMigration still refused after the last attempt: uncertain (exit 3), settled by the next run' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        $e.Real.CompleteFailures = 1000
        $r1 = Invoke-Imp (New-Imp $e -Tune { param($t) $t.CompleteMaxAttempts = 3 }) $c.Lot
        $r1.ItemsUncertain | Should -Be 1
        $r1.MessagesImported | Should -Be 3
        (Get-TmtImportExitCode -Result $r1) | Should -Be 3
        $c.Chat.MigrationMode | Should -Be 'inProgress'
        $e.Real.CompleteFailures = 0
        $r2 = Invoke-Imp (New-Imp $e) $c.Lot
        $r2.ItemsUncertain | Should -Be 0
        $r2.MessagesImported | Should -Be 0
        $c.Chat.MigrationMode | Should -Be 'completed'
        [string]$e.Store.GetLatestImportSession('chat:S1', 1).State | Should -Be 'Completed'
        [string]($e.Store.ListItems($c.Lot) | Select-Object -First 1).State | Should -Be 'Completing'
        (Get-TmtImportExitCode -Result $r2) | Should -Be 0
    }
}

Describe 'Rate limits' {
    It '429 per conversation: the limiter keeps one conversation at 5 requests per second and the service never throttles' {
        $e = New-Env -WithLimiter
        $e.Fake.Faults.ImportLimitPerThread = 5
        $c = Use-Chat $e 'chat:S1' @(1..20 | ForEach-Object { New-Msg -At (At $_) })
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesImported | Should -Be 20
        $e.Fake.Counters.Total429 | Should -Be 0
        $e.Real.MaxPostsPerWindow() | Should -BeLessOrEqual 5
        # 20 messages at 5 per second take about 4 s of (virtual) time
        $posts = @($e.Real.Records | Where-Object { [TeamsTransfer.Testing.ImportRealismTransport]::IsImportPost($_.Method, $_.Url) })
        ($posts[-1].At - $posts[0].At).TotalSeconds | Should -BeGreaterOrEqual 3.5
    }

    It 'a client that paces too fast gets 429, honours Retry-After and still imports everything exactly once' {
        $e = New-Env -WithLimiter -PerThreadRate 50 -MaxAttempts 8
        $e.Fake.Faults.ImportLimitPerThread = 5
        $c = Use-Chat $e 'chat:S1' @(1..15 | ForEach-Object { New-Msg -At (At $_) })
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $e.Fake.Counters.Total429 | Should -BeGreaterThan 0
        $r.MessagesImported + $r.MessagesConflict409 | Should -Be 15
        $r.MessagesRejected | Should -Be 0
        @($c.Chat.Messages).Count | Should -Be 15
        $r.Throttled429 | Should -BeGreaterThan 0
    }
}

Describe 'Dry run' {
    It 'sends no request at all, writes no journal, and reports the exact requests per endpoint with redacted samples' {
        $e = New-Env; Set-Ident $e
        $chat = New-Group $e
        $m = @(
            (New-Msg -Id 'a' -At (At 1) -Body '<p>secret text</p>')
            (New-Msg -Id 'b' -At (At 2) -From 'src-nobody')
            (New-Msg -Id 'c' -At (At 3) -Type 'systemEventMessage' -From '')
            (New-Msg -Id 'd' -At (At 4)))
        Add-Source $e 'chat:S1' 'Group' $m
        Add-Source $e 'chat:N1' 'Group' (@(New-Msg -At (At 1)))
        $e.Targets.Upsert((New-Tgt -Key 'chat:S1' -Kind ExistingChat -ChatId $chat.Id))
        $e.Targets.Upsert((New-Tgt -Key 'chat:N1' -Kind NewChat -Members @($e.Users.alice.Id, $e.Users.bob.Id, $e.Users.carol.Id)))
        $lot = New-LotFor $e 'L1' @('chat:S1', 'chat:N1')
        $e.Fake.Counters.Reset()
        $r = Invoke-Imp (New-Imp $e -DryRun) $lot

        $e.Fake.Counters.TotalCalls | Should -Be 0
        @($e.Fake.Counters.Log).Count | Should -Be 0
        @($e.Real.Records).Count | Should -Be 0
        @($e.Store.ListJournal('chat:S1', 1)).Count | Should -Be 0
        @($e.Store.ListImportSessions('chat:S1', 1)).Count | Should -Be 0
        @($e.Tenant.Chats).Count | Should -Be 1
        [string]$e.Store.GetLot($lot).State | Should -Be 'ImportPlanned'
        [string]($e.Store.ListItems($lot) | Select-Object -First 1).State | Should -Be 'Planned'

        $r.Applied | Should -BeFalse
        $d = $r.DryRun
        $d.MessagesToImport | Should -Be 3                          # a, d, and the message of the new chat
        $d.MessagesSkipped | Should -Be 1
        $d.MessagesRejected | Should -Be 1
        $d.RequestsByEndpoint['POST /chats'] | Should -Be 1
        $d.RequestsByEndpoint['POST /chats/{chatId}/messages'] | Should -Be 3
        $d.RequestsByEndpoint['POST /chats/{chatId}/startMigration'] | Should -Be 2
        $d.RequestsByEndpoint['POST /chats/{chatId}/completeMigration'] | Should -Be 2
        $d.TotalRequests | Should -Be (1 + 3 + 2 + 2 + 4)             # + the GETs (poll and verify, 2 per conversation)
        $d.ConversationsToCreate | Should -Be 1
        @($d.Conversations).Count | Should -Be 2
        $d.EstimatedDuration | Should -BeGreaterThan ([TimeSpan]::Zero)
        $sample = $d.Samples | Select-Object -First 1
        $sample.Method | Should -Be 'POST'
        $sample.Url | Should -Match '^v1\.0/chats/\{chatId\}/messages$'
        $sample.BodyJson | Should -Not -Match 'secret text'
        $sample.BodyJson | Should -Match 'redacted'
        $sample.BodyJson | Should -Match 'createdDateTime'
        $d.DroppedByReason['Rejected:IdentityUnresolved'] | Should -Be 1
    }

    It 'also works without any target client' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        $r = Invoke-Imp (New-Imp $e -DryRun -NoClient) $c.Lot
        $r.DryRun.MessagesToImport | Should -Be 3
        $e.Fake.Counters.TotalCalls | Should -Be 0
    }

    It 'a lot that is not planned is refused, with and without Apply' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(New-Msg -At (At 1))
        $lot2 = New-LotFor $e 'unplanned' @('chat:S1') -KeepPlanned
        { Invoke-Imp (New-Imp $e) $lot2 } | Should -Throw '*Planned*'
        { Invoke-Imp (New-Imp $e -DryRun) $lot2 } | Should -Throw '*planned lot*'
        $e.Fake.Counters.TotalCalls | Should -Be 0
    }
}

Describe 'Errors of the service' {
    It 'another application owns the migration: the conversation fails (resumable, exit 2), nothing is rejected' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        # the thread was started by another application, with a creation date old enough to be adopted: the first POST is refused (403, another application)
        $c.Chat.CreatedMs = [datetimeoffset]::Parse('2026-01-01T00:00:00Z').ToUnixTimeMilliseconds()
        $c.Chat.MigrationMode = 'inProgress'; $c.Chat.MigrationOwnerAppId = 'someone-else'
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesRejected | Should -Be 0
        $r.MessagesImported | Should -Be 0
        (Get-States $e 'chat:S1' | Sort-Object -Unique) | Should -Be 'Pending'
        ($r.ItemsFailed + $r.ItemsIncomplete) | Should -Be 1
        (Get-TmtImportExitCode -Result $r) | Should -Be 2
    }

    It 'a message the service refuses (400) is rejected with its code, the others go on (exit 3)' {
        $e = New-Env
        $big = '<p>' + ('x' * 40000) + '</p>'      # above the 28 KB limit
        $c = Use-Chat $e 'chat:S1' @((New-Msg -Id 'a' -At (At 1)), (New-Msg -Id 'big' -At (At 2) -Body $big), (New-Msg -Id 'c' -At (At 3)))
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $r.MessagesImported | Should -Be 2
        $r.MessagesRejected | Should -Be 1
        $r.Status400 | Should -Be 1
        $j = Get-Journal $e 'chat:S1' | Where-Object { $_.SourceMessageId -eq 'big' }
        [string]$j.Status | Should -Be 'Rejected'
        $j.ErrorCode | Should -Match '^400 BadRequest'
        $r.ItemsCompleted | Should -Be 1
        (Get-TmtImportExitCode -Result $r) | Should -Be 3
        # a rerun does not retry the rejected message
        $e.Fake.Counters.Reset()
        $r2 = Invoke-Imp (New-Imp $e) $c.Lot
        $e.Fake.Counters.TotalCalls | Should -Be 0
        $r2.MessagesRejectedTotal | Should -Be 1
    }
}

Describe 'Throughput' {
    It '50 conversations x 200 messages on the fake, 16 conversations at a time: reports msgs/s' {
        $e = New-Env
        Set-Ident $e
        $keys = @()
        foreach ($i in 1..50) {
            $key = "chat:T$i"
            $chat = $e.Tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::Group, [TeamsTransfer.Testing.FakeUser[]]@($e.Users.alice, $e.Users.bob), "t$i", [datetimeoffset]::Parse('2026-06-01T00:00:00Z'))
            $base = $script:T0.AddHours($i)
            $msgs = 1..200 | ForEach-Object { New-Msg -Id "m$_" -At $base.AddSeconds($_) -From $(if ($_ % 2) { 'src-alice' } else { 'src-bob' }) }
            Add-Source $e $key 'Group' $msgs
            $e.Targets.Upsert((New-Tgt -Key $key -Kind ExistingChat -ChatId $chat.Id))
            $keys += $key
        }
        $lot = New-LotFor $e 'Big' $keys
        $r = Invoke-Imp (New-Imp $e -Configure { param($o) $o.ConversationParallelism = 16 }) $lot
        Write-Host ('    throughput: {0:N0} messages in {1:N1} s = {2:N0} msg/s on the fake (16 conversations at a time, journal on disk)' -f $r.MessagesImported, $r.Elapsed.TotalSeconds, $r.MessagesPerSecond)
        $r.MessagesImported | Should -Be 10000
        $r.MessagesRejected | Should -Be 0
        $r.ItemsCompleted | Should -Be 50
        $e.Fake.Counters.ImportedMessages | Should -Be 10000
        @($r.Slowest).Count | Should -BeGreaterThan 0
        $r.MessagesPerSecond | Should -BeGreaterThan 50
        foreach ($t in $e.Tenant.Chats) { @($t.Messages).Count | Should -Be 200; $t.MigrationMode | Should -Be 'completed' }
    }
}

Describe 'PowerShell surface and entry script' {
    BeforeAll {
        function Invoke-Entry {
            param([string[]]$Arguments, [string]$Cwd)
            if (-not $Cwd) { $Cwd = (New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ('cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -Force).FullName }
            $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            $psi.WorkingDirectory = $Cwd
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script:Entry) { $psi.ArgumentList.Add($a) }
            foreach ($a in $Arguments) { $psi.ArgumentList.Add([string]$a) }
            $psi.ArgumentList.Add('-DevelopmentMode')
            foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'TEAMSTRANSFER_LOG_FOLDER') { [void]$psi.Environment.Remove($k) }
            $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = (Join-Path $script:TempRoot 'no-local-config.psd1')
            $p = [Diagnostics.Process]::Start($psi)
            $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw 'The entry script did not finish in 240 s.' }
            $p.WaitForExit()
            [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $er.GetAwaiter().GetResult(); Cwd = $Cwd }
        }
        # a store on disk with one planned lot (two chats, one of them with a message of an unmapped author), maps held by the store itself
        function New-DiskLot {
            param([string]$Name = 'wave1', [switch]$Plan)
            $root = Join-Path $script:TempRoot ('disk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $store = Open-TmtStore -Root $root -Partitions 8
            try {
                $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                foreach ($i in 1..3) { $l.Add((New-Msg -At (At $i))) }
                foreach ($key in 'chat:D1', 'chat:D2') {
                    $c = [TeamsTransfer.ConversationRecord]::new(); $c.Key = $key; $c.Kind = 'Group'
                    $c.CreatedUtc = [datetimeoffset]::Parse('2022-01-01T00:00:00Z'); $c.LastActivityUtc = [datetimeoffset]::Parse('2026-10-01T00:00:00Z')
                    $store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c))
                    [void]$store.AppendMessages($key, $l)
                    $t = [TeamsTransfer.TargetMapping]::new(); $t.SourceConversationKey = $key; $t.Kind = 'ExistingChat'; $t.TargetChatId = "19:$($key.Substring(5))@thread.v2"
                    $store.UpsertTargets([TeamsTransfer.TargetMapping[]]@($t))
                }
                $i1 = [TeamsTransfer.IdentityMapping]::new(); $i1.SourceUserId = 'src-alice'; $i1.Kind = 'Mapped'; $i1.TargetUserId = 'tgt-alice'
                $store.UpsertIdentities([TeamsTransfer.IdentityMapping[]]@($i1))
                $opt = [TeamsTransfer.LotOptions]::new(); $opt.AsOfUtc = [datetimeoffset]::Parse('2026-11-09T00:00:00Z')
                $m = @([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, 'chat:D1', 100), [TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, 'chat:D2', 100))
                $id = $store.CreateLot($Name, [TeamsTransfer.LotMember[]]$m, $opt)
                [void]$store.ResolveLot($id, [int[]]@(1))
                if ($Plan) { foreach ($st in 'Exporting', 'Exported', 'ImportPlanned') { [void]$store.TransitionLot($id, [TeamsTransfer.LotState]::$st) } }
            } finally { $store.Dispose() }
            $root
        }
    }

    It 'the preview of a planned lot: exit 0, report folder with summary.html, conversations.csv, rejected.csv; nothing is sent or journaled' {
        $root = New-DiskLot -Plan
        $out = Join-Path $script:TempRoot 'out1'
        $cfg = Join-Path $script:TempRoot 'cfg1.psd1'
        Set-Content -LiteralPath $cfg -Value "@{ Output = @{ Root = '$($out.Replace("'", "''"))' } }"
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'wave1', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs1'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'Import - Preview \(nothing is written\)'
        $r.Out | Should -Match 'Preview: nothing is written\. Run it again with -Apply'
        $r.Out | Should -Match '6 message\(s\) to import'
        $r.Out | Should -Match 'Import planned'
        $folder = Get-ChildItem -LiteralPath (Join-Path $out 'reports') -Directory | Where-Object Name -match '_Import' | Select-Object -First 1
        $folder | Should -Not -BeNullOrEmpty
        foreach ($f in 'summary.html', 'conversations.csv', 'rejected.csv') { Test-Path -LiteralPath (Join-Path $folder.FullName $f) | Should -BeTrue -Because $f }
        (Get-Content -LiteralPath (Join-Path $folder.FullName 'conversations.csv')).Count | Should -Be 3
        $samples = Get-Content -Raw -LiteralPath (Join-Path $folder.FullName 'samples.json') | ConvertFrom-Json
        @($samples).Count | Should -BeGreaterThan 0
        $samples[0].url | Should -Be 'v1.0/chats/{chatId}/messages'
        $samples[0].body.body.content | Should -Match 'redacted'
        (Get-Content -Raw -LiteralPath (Join-Path $folder.FullName 'samples.json')) | Should -Match '2026-02-01T09:00:30\.000Z'
        (Get-Content -LiteralPath (Join-Path $folder.FullName 'requests.csv')) -join '|' | Should -Match 'POST /chats/\{chatId\}/messages","6'
        # the journal is untouched
        $s = Open-TmtStore -Root $root -ReadOnly
        try { @($s.ListJournal('chat:D1', 1)).Count | Should -Be 0 } finally { $s.Dispose() }
    }

    It '-WhatIf wins over -Apply: still a preview, exit 0' {
        $root = New-DiskLot -Plan
        $out = Join-Path $script:TempRoot 'out2'
        $cfg = Join-Path $script:TempRoot 'cfg2.psd1'
        Set-Content -LiteralPath $cfg -Value "@{ Output = @{ Root = '$($out.Replace("'", "''"))' } }"
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'wave1', '-Apply', '-Force', '-WhatIf', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs2'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '-WhatIf wins over -Apply'
        $r.Out | Should -Not -Match 'Apply \(changes are made\)'
    }

    It 'refuses a lot that is not planned (exit 1) and a missing lot, before anything is sent' {
        $root = New-DiskLot -Name 'raw'
        $out = Join-Path $script:TempRoot 'out3'
        $cfg = Join-Path $script:TempRoot 'cfg3.psd1'
        Set-Content -LiteralPath $cfg -Value "@{ Output = @{ Root = '$($out.Replace("'", "''"))' } }"
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'raw', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs3'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'the import needs a planned lot'
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'nope', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs3'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match "Lot 'nope' not found"
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs3'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match '-Lot is required'
    }

    It '-Apply with a stop file already there: exit 2 before anything is sent; -Apply with no Target configured: exit 1' {
        $root = New-DiskLot -Plan
        $out = Join-Path $script:TempRoot 'out4'
        $cfg = Join-Path $script:TempRoot 'cfg4.psd1'
        Set-Content -LiteralPath $cfg -Value "@{ Output = @{ Root = '$($out.Replace("'", "''"))' } }"
        $stop = Join-Path $script:TempRoot 'stop.txt'; Set-Content -LiteralPath $stop -Value 'stop'
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'wave1', '-Apply', '-Force', '-StopFile', $stop, '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs4'))
        $r.ExitCode | Should -Be 2 -Because $r.Out
        $r.Out | Should -Match 'exit code 2 - not complete'
        Remove-Item -LiteralPath $stop
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'wave1', '-Apply', '-Force', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs4'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'Configuration\.Target\.\w+ is empty'
        $s = Open-TmtStore -Root $root -ReadOnly
        try { @($s.ListJournal('chat:D1', 1)).Count | Should -Be 0 } finally { $s.Dispose() }
    }

    It 'Slices and ConversationParallelism belong to Import and Plan; Lot belongs to Import' {
        $root = New-DiskLot -Plan
        $out = Join-Path $script:TempRoot 'out5'
        $cfg = Join-Path $script:TempRoot 'cfg5.psd1'
        Set-Content -LiteralPath $cfg -Value "@{ Output = @{ Root = '$($out.Replace("'", "''"))' } }"
        $r = Invoke-Entry -Arguments @('-Mode', 'Import', '-Lot', 'wave1', '-Slices', '1', '-ConversationParallelism', '4', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs5'))
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r = Invoke-Entry -Arguments @('-Mode', 'Status', '-Slices', '1', '-StoreRoot', $root, '-ConfigPath', $cfg, '-LogFolder', (Join-Path $script:TempRoot 'logs5'))
        $r.ExitCode | Should -Be 1
    }

    It 'Invoke-TmtImport and Write-TmtImportReport: an applied run writes the three files, rejected.csv lists the journal' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @((New-Msg -Id 'a' -At (At 1)), (New-Msg -Id 'z' -At (At 2) -From 'src-nobody'))
        $r = Invoke-Imp (New-Imp $e) $c.Lot
        $folder = Join-Path $script:TempRoot 'report-direct'
        [void](Write-TmtImportReport -Result $r -Folder $folder -Store $e.Store)
        $rej = Import-Csv -LiteralPath (Join-Path $folder 'rejected.csv')
        @($rej).Count | Should -Be 1
        $rej[0].MessageId | Should -Be 'z'
        $rej[0].Code | Should -Be 'IdentityUnresolved'
        (Import-Csv -LiteralPath (Join-Path $folder 'conversations.csv'))[0].State | Should -Be 'Completed'
        (Get-Content -Raw -LiteralPath (Join-Path $folder 'summary.html')) | Should -Match 'Messages imported'
        (Get-TmtImportExitCode -Result $r) | Should -Be 3
    }

    It 'Invoke-TmtImport runs end to end through the module (store maps by default would be used; explicit maps here), with a client and a stop file' {
        $e = New-Env
        $c = Use-Chat $e 'chat:S1' @(1..3 | ForEach-Object { New-Msg -At (At $_) })
        $r = Invoke-TmtImport -Store $e.Store -Lot ($e.Store.GetLot($c.Lot).Name) -Client $e.Client -IdentityMap $e.Ids -TargetMap $e.Targets -FileMap $e.Files -Apply -AppId 'app-1' -ServiceAccountUserId $e.Users.svc.Id -ConversationParallelism 2 -IntervalSeconds 1
        $r.MessagesImported | Should -Be 3
        $r.Applied | Should -BeTrue
        @($c.Chat.Messages).Count | Should -Be 3
        { Invoke-TmtImport -Store $e.Store -Lot 'does-not-exist' -IdentityMap $e.Ids -TargetMap $e.Targets -FileMap $e.Files } | Should -Throw "*not found*"
    }
}
