#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Verify.cs (Verifier, VerifyReport), Invoke-TmtVerify and Invoke-TmtLotReport: a real TmtStore holds the source, the journal and the
# lot; the target is the fake Graph (messages added straight to its model, like the importer would have left them, wrapped by the strict-filter,
# expand-replies and request-log transports).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tmt-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:Stores = [Collections.Generic.List[object]]::new()
    $script:Now = [datetimeoffset]::Parse('2026-11-01T12:00:00Z')
    $script:FT = [TeamsTransfer.Testing.FakeTime]

    function New-VfEnv {
        param([int]$MaxAttempts = 2, [int]$Parallelism = 2)
        $tenant = [TeamsTransfer.Testing.FakeTenant]::new(21, 'target.example')
        $e = [ordered]@{ Tenant = $tenant }
        $e.Alice = $tenant.AddUser('alice@target.example', 'Alice A')
        $e.Bob = $tenant.AddUser('bob@target.example', 'Bob B')
        $e.Svc = $tenant.AddUser('svc@target.example', 'Service Account')
        $e.Ghost = $tenant.AddUser('tt-ghost-0123456789abcdef@target.example', 'Gone Person (former)')
        $e.Chat = $tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::Group, [TeamsTransfer.Testing.FakeUser[]]@($e.Alice, $e.Bob), 'Project', $script:Now.AddYears(-1))
        $e.Chat.MigrationMode = 'completed'
        $e.Team = $tenant.AddTeam('Target Team', [TeamsTransfer.Testing.FakeUser[]]@($e.Alice, $e.Bob), $script:Now.AddYears(-3))
        $e.Chan = $tenant.AddChannel($e.Team, 'General', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, $script:Now.AddYears(-3))
        $e.Chan.MigrationMode = 'completed'
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($tenant)
        $expand = [TeamsTransfer.Testing.ExpandRepliesTransport]::new($fake)
        $strict = [TeamsTransfer.Testing.StrictFilterTransport]::new($expand)
        $e.Gf = [TeamsTransfer.Testing.GfGraphTransport]::new($strict, $tenant)
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = [TeamsTransfer.TestManualClock]::new(); $o.MaxAttempts = $MaxAttempts
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(2); $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $e.Client = [TeamsTransfer.GraphClient]::new($e.Gf, $o, $null)
        $e.Root = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $e.Store = Open-TmtStore -Root $e.Root -Partitions 4
        $script:Stores.Add($e.Store)
        $e.Ids = [TeamsTransfer.Testing.GfIdentityMap]::new(); $e.Targets = [TeamsTransfer.Testing.GfTargetMap]::new()
        [void]$e.Ids.Add('src-alice', 'Alice', [TeamsTransfer.IdentityKind]::Mapped, $e.Alice.Id)
        [void]$e.Ids.Add('src-bob', 'Bob', [TeamsTransfer.IdentityKind]::Same, $e.Bob.Id)
        [void]$e.Ids.Add('src-gone', 'Gone Person', [TeamsTransfer.IdentityKind]::Ghost, $e.Ghost.Id)
        [void]$e.Ids.Add('src-left', 'Leaver', [TeamsTransfer.IdentityKind]::ServiceAccount, $e.Svc.Id)
        $e.Run = [TeamsTransfer.ImportRunOptions]::new(); $e.Run.ServiceAccountUserId = $e.Svc.Id
        $e.ChatKey = 'chat:SRC-CHAT'; $e.ChanKey = 'channel:SRC-TEAM/SRC-CHAN'
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = $e.Chat.Id })
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChanKey; Kind = [TeamsTransfer.TargetKind]::ExistingChannel; TargetTeamId = $e.Team.Id; TargetChannelId = $e.Chan.Id })
        $e.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@(
            [TeamsTransfer.ConversationRecord]@{ Key = $e.ChatKey; Kind = [TeamsTransfer.ConversationKind]::Group; ChatId = 'SRC-CHAT'; CreatedUtc = $script:Now.AddYears(-4); LastActivityUtc = $script:Now },
            [TeamsTransfer.ConversationRecord]@{ Key = $e.ChanKey; Kind = [TeamsTransfer.ConversationKind]::Channel; TeamId = 'SRC-TEAM'; ChannelId = 'SRC-CHAN'; CreatedUtc = $script:Now.AddYears(-4); LastActivityUtc = $script:Now }))
        $e.Parallelism = $Parallelism
        [pscustomobject]$e
    }

    function Get-Ms([datetimeoffset]$When) { $script:FT::ToMs($When) }
    function ConvertTo-Iso([datetimeoffset]$When) { $When.UtcDateTime.ToString('yyyy-MM-dd''T''HH:mm:ss.fff''Z''', [Globalization.CultureInfo]::InvariantCulture) }

    function Add-SourceMessage($E, [string]$Key, [datetimeoffset]$When, [string]$From, [string]$Html, [int]$Reactions = 0, [int]$Files = 0, [string]$ReplyTo) {
        $ms = Get-Ms $When
        $o = [ordered]@{ id = "$ms"; createdDateTime = (ConvertTo-Iso $When); body = @{ contentType = 'html'; content = $Html } }
        if ($ReplyTo) { $o.replyToId = $ReplyTo }
        if ($From) { $o.from = @{ user = @{ id = $From; displayName = $From; userIdentityType = 'aadUser' } } }
        if ($Reactions -gt 0) { $o.reactions = @(1..$Reactions | ForEach-Object { @{ reactionType = 'like'; createdDateTime = (ConvertTo-Iso $When) } }) }
        if ($Files -gt 0) { $o.attachments = @(1..$Files | ForEach-Object { @{ id = "att$_"; contentType = 'reference'; contentUrl = "https://src.invalid/f$_"; name = "f$_.docx" } }) }
        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
        $l.Add([Text.Json.JsonDocument]::Parse(($o | ConvertTo-Json -Depth 6 -Compress)).RootElement)
        [void]$E.Store.AppendMessages($Key, $l)
        "$ms"
    }

    function Add-TargetMessage($Thread, [datetimeoffset]$When, $Author, [string]$Html, [int]$Reactions = 0, [int]$Files = 0, [long]$ReplyTo = 0) {
        $ms = Get-Ms $When
        $m = [TeamsTransfer.Testing.FakeMessage]::new()
        $m.CreatedMs = $ms; $m.ModifiedMs = $ms; $m.AuthorOrd = $Author.Ordinal; $m.Flags = [byte]8
        $x = $m.Ext(); $x.Body = $Html; $x.ReplyTo = $ReplyTo
        if ($Reactions -gt 0) {
            $x.Reactions = [TeamsTransfer.Testing.FakeReaction[]]@(1..$Reactions | ForEach-Object { $r = [TeamsTransfer.Testing.FakeReaction]::new(); $r.Type = 'like'; $r.UserOrd = $Author.Ordinal; $r.CreatedMs = $ms; $r })
        }
        if ($Files -gt 0) {
            $x.Attachments = [TeamsTransfer.Testing.FakeAttachment[]]@(1..$Files | ForEach-Object { [TeamsTransfer.Testing.FakeAttachment]@{ Id = "new$_"; ContentType = 'reference'; ContentUrl = "https://target.invalid/f$_"; Name = "f$_.docx" } })
        }
        [void]$Thread.AddUnique($m)
        $ms
    }

    # A source message and its faithful copy on the target (+ the journal row is made later by Complete-Journal).
    function Add-Pair($E, [string]$Kind, [datetimeoffset]$When, [string]$From = 'src-alice', $TargetUser = $null, [string]$Html = $null, [string]$TargetHtml = $null, [int]$Reactions = 0, [int]$Files = 0, [int]$TargetReactions = -1, [int]$TargetFiles = -1, [switch]$SourceOnly, [string]$ReplyTo, [long]$TargetReplyTo = 0) {
        if (-not $Html) { $Html = '<p>Hello ' + $When.ToUnixTimeMilliseconds() + '</p>' }
        if (-not $TargetHtml) { $TargetHtml = $Html }
        if (-not $TargetUser) { $TargetUser = if ($From -eq 'src-bob') { $E.Bob } else { $E.Alice } }
        $key = if ($Kind -eq 'chat') { $E.ChatKey } else { $E.ChanKey }
        $id = Add-SourceMessage $E $key $When $From $Html $Reactions $Files $ReplyTo
        if (-not $SourceOnly) {
            $thread = if ($Kind -eq 'chat') { $E.Chat } else { $E.Chan }
            [void](Add-TargetMessage $thread $When $TargetUser $TargetHtml $(if ($TargetReactions -ge 0) { $TargetReactions } else { $Reactions }) $(if ($TargetFiles -ge 0) { $TargetFiles } else { $Files }) $TargetReplyTo)
        }
        $id
    }

    function Complete-Journal($E, [string]$Key, [int]$Slice = 1, [switch]$Pending, [string[]]$RejectIds, [switch]$NoSession) {
        $ids = @($E.Store.ReadMessages($Key) | ForEach-Object { $_.GetProperty('id').GetString() })
        [void]$E.Store.SeedJournal($Key, $Slice, [string[]]$ids)
        if (-not $Pending) {
            $marks = [Collections.Generic.List[TeamsTransfer.JournalMark]]::new()
            foreach ($id in $ids) {
                $m = [TeamsTransfer.JournalMark]@{ ConversationKey = $Key; SliceNo = $Slice; SourceMessageId = $id; Status = $(if ($RejectIds -contains $id) { [TeamsTransfer.JournalStatus]::Rejected } else { [TeamsTransfer.JournalStatus]::Imported }); TargetMessageId = $id }
                $marks.Add($m)
            }
            $E.Store.MarkJournal($marks)
        }
        if (-not $NoSession) {
            $sid = $E.Store.BeginImportSession($Key, $Slice, 'app-1', $script:Now.AddYears(-5), 'target')
            $E.Store.CompleteImportSession($sid)
        }
    }

    function New-Lot($E, [string]$Name = 'L1', [int[]]$Slices = @(1), [switch]$ChatOnly) {
        $members = [Collections.Generic.List[TeamsTransfer.LotMember]]::new()
        $members.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, $E.ChatKey))
        if (-not $ChatOnly) { $members.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Channel, $E.ChanKey)) }
        $id = $E.Store.CreateLot($Name, $members, [TeamsTransfer.LotOptions]@{ AsOfUtc = $script:Now })
        [void]$E.Store.ResolveLot($id, $Slices)
        $id
    }

    function Move-Lot($E, [long]$LotId, [string]$To = 'Completing') {
        $chain = 'Exporting', 'Exported', 'ImportPlanned', 'Importing', 'Completing'
        foreach ($st in $chain) {
            $s = [TeamsTransfer.LotState]$st
            [void]$E.Store.TransitionLot($LotId, $s, 'test')
            foreach ($i in $E.Store.ListItems($LotId)) { $E.Store.SetItemState($LotId, $i.ConversationKey, $i.SliceNo, $i.Fragment, $s) }
            if ($st -eq $To) { break }
        }
    }

    function Invoke-Verify($E, [long]$LotId, [int[]]$Slices = @(), [scriptblock]$Configure) {
        $o = [TeamsTransfer.VerifyOptions]::new(); $o.Parallelism = $E.Parallelism; $o.ResultsFolder = ''
        if ($Configure) { & $Configure $o }
        $v = [TeamsTransfer.Verifier]::new($E.Client, $E.Store, $E.Targets, $E.Run, $E.Ids, $o)
        $v.RunAsync($LotId, [int[]]$Slices, $script:ct).GetAwaiter().GetResult()
    }

    # The standard happy scenario: 12 chat messages, 4 channel roots with 2 replies each, everything on the target, journal complete, lot Completing.
    function New-HappyEnv {
        param([int]$Chat = 12, [int]$Roots = 4, [int]$Replies = 2)
        $e = New-VfEnv
        for ($i = 1; $i -le $Chat; $i++) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i).AddMilliseconds($i) $(if ($i % 3 -eq 0) { 'src-bob' } else { 'src-alice' }) -Reactions ($i % 2) -Files ($i % 4 -eq 0 ? 1 : 0)) }
        for ($r = 1; $r -le $Roots; $r++) {
            $rootWhen = $script:Now.AddDays(-10 * $r)
            $rid = Add-Pair $e 'chan' $rootWhen 'src-alice'
            for ($k = 1; $k -le $Replies; $k++) { [void](Add-Pair $e 'chan' $rootWhen.AddMinutes($k) 'src-bob' -ReplyTo $rid -TargetReplyTo ([long]$rid)) }
        }
        Complete-Journal $e $e.ChatKey; Complete-Journal $e $e.ChanKey
        $e | Add-Member -NotePropertyName LotId -NotePropertyValue (New-Lot $e) -PassThru
    }
}

AfterAll {
    foreach ($s in $script:Stores) { try { $s.Dispose() } catch { } }
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Body normalisation' {
    BeforeAll {
        $vne = New-VfEnv
        $script:vn = [TeamsTransfer.Verifier]::new($vne.Client, $vne.Store, $vne.Targets, [TeamsTransfer.ImportRunOptions]::new())
    }
    It 'ignores tags, entities, whitespace, images, attachment markers and mention markup' {
        $a = $script:vn.NormalizeBody('<p>Hello&nbsp;<b>wor ld</b></p><img src="https://x/y.png"><attachment id="a1"></attachment><p>bye</p>', $false)
        $a | Should -Be 'Hello wor ld bye'
        $script:vn.NormalizeBody('<p>Hello <at id="0">Alice</at>,  ok&amp;go</p>', $false) | Should -Be 'Hello Alice , ok&go'
        $script:vn.BodyHash("Hello`r`n  World", $false) | Should -Be $script:vn.BodyHash('<div>hello world</div>', $true)
    }
}

Describe 'Verify: everything agrees' {
    It 'finds every conversation-slice OK, reads each target page client-side, and moves the lot and its items to Verified through legal transitions' {
        $e = New-HappyEnv
        Move-Lot $e $e.LotId 'Completing'
        $r = Invoke-Verify $e $e.LotId
        $r.Items.Count | Should -Be 2
        foreach ($i in $r.Items) { [string]$i.Outcome | Should -Be 'OK'; $i.Detail | Should -BeNullOrEmpty -Because $i.Detail }
        $r.AllOk | Should -BeTrue
        $r.Ok | Should -Be 2
        $chat = $r.Items | Where-Object ConversationKey -eq $e.ChatKey
        $chat.SourceMessages | Should -Be 12
        $chat.JournalImported | Should -Be 12
        $chat.TargetMessages | Should -Be 12
        $chat.SamplesChecked | Should -Be 10
        $chan = $r.Items | Where-Object ConversationKey -eq $e.ChanKey
        $chan.TargetMessages | Should -Be 12            # 4 roots + 8 replies
        $chan.SourceMessages | Should -Be 12
        [string]$r.LotStateBefore | Should -Be 'Completing'
        [string]$r.LotStateAfter | Should -Be 'Verified'
        $r.ItemsSetVerified | Should -Be 2
        foreach ($i in $e.Store.ListItems($e.LotId)) { [string]$i.State | Should -Be 'Verified' }
        $hist = @($e.Store.LotHistory($e.LotId) | ForEach-Object { [string]$_.To })
        $hist[-1] | Should -Be 'Verified'
        $hist[-2] | Should -Be 'Completing'
        # the target was read the way phase 0 requires: pages of 50, no $filter / $orderby, replies expanded for channels
        $urls = @($e.Gf.Requests | ForEach-Object { [Uri]::UnescapeDataString($_.Url) })
        @($urls | Where-Object { $_ -match '/messages' -and $_ -match 'filter|orderby' }).Count | Should -Be 0
        @($urls | Where-Object { $_ -match 'chats/.*/messages\?\$top=50' }).Count | Should -BeGreaterOrEqual 1
        @($urls | Where-Object { $_ -match 'channels/.*/messages\?\$top=50&\$expand=replies' }).Count | Should -BeGreaterOrEqual 1
        $e.Gf.WriteCount | Should -Be 0
    }
    It 'walks Importing -> Completing -> Verified when the importer left the lot in Importing' {
        $e = New-HappyEnv
        Move-Lot $e $e.LotId 'Importing'
        $r = Invoke-Verify $e $e.LotId
        $r.AllOk | Should -BeTrue
        [string]$r.LotStateAfter | Should -Be 'Verified'
        $hist = @($e.Store.LotHistory($e.LotId) | ForEach-Object { [string]$_.To })
        ($hist -join '>') | Should -Match 'Importing>Completing>Verified$'
    }
    It 'does not touch the states with -NoLotUpdate' {
        $e = New-HappyEnv
        Move-Lot $e $e.LotId 'Completing'
        $r = Invoke-Verify $e $e.LotId -Configure { param($o) $o.UpdateLotState = $false }
        $r.AllOk | Should -BeTrue
        [string]$e.Store.GetLot($e.LotId).State | Should -Be 'Completing'
        foreach ($i in $e.Store.ListItems($e.LotId)) { [string]$i.State | Should -Be 'Completing' }
    }
    It 'reads a large chat page by page (600 messages, 12 pages of 50)' {
        $e = New-VfEnv
        foreach ($i in 1..600) { [void](Add-Pair $e 'chat' $script:Now.AddMinutes(-$i)) }
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'OK'
        $r.Items[0].TargetMessages | Should -Be 600
        @($e.Gf.Requests | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '^chats/[^/]+/messages$' }).Count | Should -Be 12
    }
    It 'treats a Skip target as nothing to verify' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -SourceOnly)
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::Skip; Note = 'out of scope' })
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'OK'
        $r.Items[0].Detail | Should -Match 'Skip'
    }
}

Describe 'Verify: Mismatch' {
    It 'flags a message that never reached the target, names how many, and leaves the lot Completing' {
        $e = New-VfEnv
        foreach ($i in 1..6) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i) -SourceOnly:($i -eq 4)) }
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        Move-Lot $e $lot 'Completing'
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        [string]$x.Outcome | Should -Be 'Mismatch'
        $x.SourceMessages | Should -Be 6
        $x.TargetMessages | Should -Be 5
        $x.MissingOnTarget | Should -Be 1
        $x.Detail | Should -Match '1 imported message\(s\) not found'
        $r.Mismatch | Should -Be 1
        $r.AllOk | Should -BeFalse
        [string]$e.Store.GetLot($lot).State | Should -Be 'Completing'
        [string]$e.Store.ListItems($lot)[0].State | Should -Be 'Completing'
    }
    It 'compares a sample message by message: the body, the author, and the createdDateTime key' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -Html '<p>original text</p>' -TargetHtml '<p>some other text</p>')
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-2) -From 'src-alice' -TargetUser $e.Bob)
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-3))
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        [string]$x.Outcome | Should -Be 'Mismatch'
        $x.SamplesChecked | Should -Be 3
        $x.SamplesFailed | Should -Be 2
        $x.Detail | Should -Match 'body differs'
        $x.Detail | Should -Match 'author'
        $x.TargetMessages | Should -Be 3        # the counts agree: only the sample finds the problem
    }
    It 'accepts the importer''s known rewrites: the fallback banner, a service-account author, entities, images and tag differences' {
        $e = New-VfEnv
        $banner = '<p><em>Original message from Leaver (leaver@src.invalid), 2026-10-31 10:00 UTC</em></p>'
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -From 'src-left' -TargetUser $e.Svc -Html '<p>Please review <b>this</b> file</p>' -TargetHtml ($banner + '<p>Please&nbsp;review  <strong>this</strong> file</p><img src="https://graph.microsoft.com/v1.0/chats/x/messages/1/hostedContents/9/$value">'))
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-2) -From 'src-gone' -TargetUser $e.Ghost -Html '<p>Bye &amp; thanks</p>' -TargetHtml '<p>Bye &amp; thanks</p>')
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'OK' -Because $r.Items[0].Detail
    }
    It 'reports reactions and file attachment differences without failing, unless strict' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -Reactions 3 -Files 2 -TargetReactions 1 -TargetFiles 0)
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        [string]$x.Outcome | Should -Be 'OK'
        $x.ReactionsExpected | Should -Be 3
        $x.ReactionsTarget | Should -Be 1
        $x.FileRefsExpected | Should -Be 2
        $x.FileRefsTarget | Should -Be 0
        $x.Detail | Should -Match 'reactions: 1 on the target, 3 expected'
        $x.Detail | Should -Match 'file attachments: 0 on the target, 2 expected'
        $s = Invoke-Verify $e $lot -Configure { param($o) $o.ReactionsAndFilesStrict = $true }
        [string]$s.Items[0].Outcome | Should -Be 'Mismatch'
    }
    It 'flags a message rejected by the service and a journal that does not cover the source' {
        $e = New-VfEnv
        $ids = foreach ($i in 1..4) { Add-Pair $e 'chat' $script:Now.AddDays(-$i) -SourceOnly:($i -eq 2) }
        Complete-Journal $e $e.ChatKey -RejectIds @($ids[1])
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'Mismatch'
        $r.Items[0].JournalRejected | Should -Be 1
        $r.Items[0].Detail | Should -Match 'rejected'
        # a source message that the journal never saw
        [void](Add-SourceMessage $e $e.ChatKey $script:Now.AddDays(-9) 'src-alice' '<p>late</p>')
        $r2 = Invoke-Verify $e $lot
        $r2.Items[0].Detail | Should -Match 'journal covers 4 of 5'
    }
    It 'treats an extra message on the target as a mismatch, except in a restore where messages were already there' {
        $e = New-VfEnv
        foreach ($i in 1..3) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i)) }
        Complete-Journal $e $e.ChatKey
        [void](Add-TargetMessage $e.Chat $script:Now.AddDays(-5) $e.Alice '<p>was already there</p>')
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'Mismatch'
        $r.Items[0].ExtraOnTarget | Should -Be 1
        $e.Run.Scenario = [TeamsTransfer.ImportScenario]::SameTenantRestore
        $r2 = Invoke-Verify $e $lot
        [string]$r2.Items[0].Outcome | Should -Be 'OK'
        $r2.Items[0].Detail | Should -Match 'already on the target'
    }
}

Describe 'Verify: Missing' {
    It 'is Missing when the target conversation answers 404' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -SourceOnly)
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = '19:doesnotexist@thread.v2' })
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'Missing'
        $r.Items[0].Detail | Should -Match '404'
        $r.Missing | Should -Be 1
    }
    It 'is Missing when there is no target mapping or no target id (the conversation was never created)' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1) -SourceOnly)
        [void](Add-Pair $e 'chan' $script:Now.AddDays(-1) -SourceOnly)
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChanKey; Kind = [TeamsTransfer.TargetKind]::NewChannel })
        $lot = New-Lot $e
        $e2 = $e
        $e.Targets = [TeamsTransfer.Testing.GfTargetMap]::new()          # the chat has no mapping at all, the channel one has no id
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChanKey; Kind = [TeamsTransfer.TargetKind]::NewChannel })
        $r = Invoke-Verify $e $lot
        foreach ($i in $r.Items) { [string]$i.Outcome | Should -Be 'Missing' }
        ($r.Items | Where-Object ConversationKey -eq $e.ChatKey).Detail | Should -Match 'no target mapping'
        ($r.Items | Where-Object ConversationKey -eq $e.ChanKey).Detail | Should -Match 'not created'
    }
    It 'is Missing when the journal says imported and the target holds nothing in the window' {
        $e = New-VfEnv
        foreach ($i in 1..3) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i) -SourceOnly) }
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'Missing'
        $r.Items[0].TargetMessages | Should -Be 0
    }
}

Describe 'Verify: NotCompleted' {
    It 'is NotCompleted while migrationMode is inProgress' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1))
        Complete-Journal $e $e.ChatKey
        $e.Chat.MigrationMode = 'inProgress'
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        [string]$r.Items[0].Outcome | Should -Be 'NotCompleted'
        $r.Items[0].MigrationMode | Should -Be 'inProgress'
        $r.NotCompleted | Should -Be 1
    }
    It 'is NotCompleted while the journal still has pending messages, or nothing was imported' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1))
        [void](Add-Pair $e 'chan' $script:Now.AddDays(-1))
        Complete-Journal $e $e.ChatKey -Pending
        $lot = New-Lot $e
        $r = Invoke-Verify $e $lot
        $c = $r.Items | Where-Object ConversationKey -eq $e.ChatKey
        [string]$c.Outcome | Should -Be 'NotCompleted'
        $c.Detail | Should -Match 'still pending'
        $d = $r.Items | Where-Object ConversationKey -eq $e.ChanKey
        [string]$d.Outcome | Should -Be 'NotCompleted'
        $d.Detail | Should -Match 'nothing was imported yet'
        [string]$e.Store.GetLot($lot).State | Should -Be 'Planned'
    }
    It 'accepts an absent migrationMode only when the import session is recorded Completed' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1))
        Complete-Journal $e $e.ChatKey
        $e.Chat.MigrationMode = $null
        $lot = New-Lot $e -ChatOnly
        [string](Invoke-Verify $e $lot).Items[0].Outcome | Should -Be 'OK'
        $e2 = New-VfEnv
        [void](Add-Pair $e2 'chat' $script:Now.AddDays(-1))
        Complete-Journal $e2 $e2.ChatKey -NoSession
        $e2.Chat.MigrationMode = $null
        $lot2 = New-Lot $e2 -ChatOnly
        $x = (Invoke-Verify $e2 $lot2).Items[0]
        [string]$x.Outcome | Should -Be 'NotCompleted'
        $x.Detail | Should -Match 'no import session'
    }
}

Describe 'Verify: slices and client-side windows' {
    It 'buckets the target messages by the slice windows on createdDateTime and ignores what is outside the lot' {
        $e = New-VfEnv
        foreach ($i in 1..4) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i)) }                       # wave 1 (< 24 months)
        foreach ($i in 1..3) { [void](Add-Pair $e 'chat' $script:Now.AddMonths(-26).AddDays(-$i)) }          # wave 2 (24-36 months)
        foreach ($i in 1..2) { [void](Add-TargetMessage $e.Chat $script:Now.AddMonths(-50).AddDays(-$i) $e.Alice '<p>older than the lot</p>') }
        # the journal of each slice only knows its own messages
        $w1 = @($e.Store.ReadMessages($e.ChatKey, $script:Now.AddMonths(-24), $null) | ForEach-Object { $_.GetProperty('id').GetString() })
        $w2 = @($e.Store.ReadMessages($e.ChatKey, $script:Now.AddMonths(-36), $script:Now.AddMonths(-24)) | ForEach-Object { $_.GetProperty('id').GetString() })
        $w1.Count | Should -Be 4; $w2.Count | Should -Be 3
        foreach ($pair in @(@(1, $w1), @(2, $w2))) {
            [void]$e.Store.SeedJournal($e.ChatKey, $pair[0], [string[]]$pair[1])
            $marks = [Collections.Generic.List[TeamsTransfer.JournalMark]]::new()
            foreach ($id in $pair[1]) { $marks.Add([TeamsTransfer.JournalMark]@{ ConversationKey = $e.ChatKey; SliceNo = $pair[0]; SourceMessageId = $id; Status = [TeamsTransfer.JournalStatus]::Imported }) }
            $e.Store.MarkJournal($marks)
            $sid = $e.Store.BeginImportSession($e.ChatKey, $pair[0], 'app-1', $script:Now.AddYears(-6), 'x'); $e.Store.CompleteImportSession($sid)
        }
        $lot = New-Lot $e -Slices @(1, 2) -ChatOnly
        $r = Invoke-Verify $e $lot
        $r.Items.Count | Should -Be 2
        foreach ($i in $r.Items) { [string]$i.Outcome | Should -Be 'OK' -Because $i.Detail }
        ($r.Items | Where-Object SliceNo -eq 1).TargetMessages | Should -Be 4
        ($r.Items | Where-Object SliceNo -eq 2).TargetMessages | Should -Be 3
        # one slice only
        $r1 = Invoke-Verify $e $lot @(2)
        $r1.Items.Count | Should -Be 1
        $r1.Items[0].SliceNo | Should -Be 2
        $r1.Items[0].SourceMessages | Should -Be 3
    }
    It 'sets only the verified items Verified and leaves the lot alone when another item fails' {
        $e = New-VfEnv
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-1))
        [void](Add-Pair $e 'chan' $script:Now.AddDays(-1) -SourceOnly)
        Complete-Journal $e $e.ChatKey; Complete-Journal $e $e.ChanKey
        $lot = New-Lot $e
        Move-Lot $e $lot 'Completing'
        $r = Invoke-Verify $e $lot
        $r.Ok | Should -Be 1
        $r.Missing | Should -Be 1
        [string]$e.Store.GetLot($lot).State | Should -Be 'Completing'
        $states = @{}; foreach ($i in $e.Store.ListItems($lot)) { $states[$i.ConversationKey] = [string]$i.State }
        $states[$e.ChatKey] | Should -Be 'Verified'
        $states[$e.ChanKey] | Should -Be 'Completing'
        # the missing message arrives, the next run completes the lot
        [void](Add-TargetMessage $e.Chan $script:Now.AddDays(-1) $e.Alice ('<p>Hello ' + (Get-Ms $script:Now.AddDays(-1)) + '</p>'))
        $r2 = Invoke-Verify $e $lot
        $r2.AllOk | Should -BeTrue
        [string]$e.Store.GetLot($lot).State | Should -Be 'Verified'
    }
}

Describe 'Reports and persistence' {
    It 'writes verify.csv and verify.html (non-OK rows first), persists the rows, and reads them back' {
        $e = New-VfEnv
        foreach ($i in 1..3) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i) -SourceOnly:($i -eq 2) -Html ('<p>Hi, "quoted" <b>' + $i + '</b></p>')) }
        Complete-Journal $e $e.ChatKey
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot -Configure { param($o) $o.ResultsFolder = (Join-Path $e.Store.Root 'verify') }
        $r.ResultsFile | Should -Exist
        $folder = Join-Path $script:TempRoot 'vreport'
        [TeamsTransfer.VerifyReport]::WriteCsv((Join-Path $folder 'verify.csv'), $r.Items)
        [TeamsTransfer.VerifyReport]::WriteHtml((Join-Path $folder 'verify.html'), 'L1', $r.Items, $script:Now, '1.0.1')
        $csv = Import-Csv -LiteralPath (Join-Path $folder 'verify.csv')
        @($csv).Count | Should -Be 1
        $csv[0].Outcome | Should -Be 'Mismatch'
        $csv[0].ConversationKey | Should -Be $e.ChatKey
        [int]$csv[0].MissingOnTarget | Should -Be 1
        $html = Get-Content -LiteralPath (Join-Path $folder 'verify.html') -Raw
        $html | Should -Match '<title>Teams Transfer - Verify</title>'
        $html | Should -Match 'prefers-color-scheme:dark'
        $html | Should -Match 'Mismatch'
        $html | Should -Match 'normalisation'
        $back = [TeamsTransfer.VerifyReport]::LoadRows($r.ResultsFile)
        $back.Count | Should -Be 1
        $back[0].Detail | Should -Be $r.Items[0].Detail
        $back[0].SourceMessages | Should -Be 3
        # a second run for the same key replaces the row, it does not duplicate it
        [void](Invoke-Verify $e $lot -Configure { param($o) $o.ResultsFolder = (Join-Path $e.Store.Root 'verify') })
        [TeamsTransfer.VerifyReport]::LoadRows($r.ResultsFile).Count | Should -Be 1
    }
    It 'Invoke-TmtVerify returns the result, writes the report folder, and Invoke-TmtLotReport rebuilds the lot report from the catalog' {
        $e = New-HappyEnv
        Move-Lot $e $e.LotId 'Completing'
        $folder = Join-Path $script:TempRoot 'ps-verify'
        $r = Invoke-TmtVerify -Store $e.Store -Client $e.Client -Run $e.Run -TargetMap $e.Targets -IdentityMap $e.Ids -Lot 'L1' -ReportFolder $folder -SampleSize 5
        $r.AllOk | Should -BeTrue
        foreach ($f in 'verify.csv', 'verify.html', 'verify-summary.txt') { (Join-Path $folder $f) | Should -Exist }
        (Get-Content -LiteralPath (Join-Path $folder 'verify-summary.txt') -Raw) | Should -Match 'OK 2, Mismatch 0, Missing 0, NotCompleted 0'
        ($r.Items | Where-Object ConversationKey -eq $e.ChatKey).SamplesChecked | Should -Be 5
        $out = Join-Path $script:TempRoot 'ps-lotreport'
        $rep = @(Invoke-TmtLotReport -Store $e.Store -Folder $out)
        $rep.Count | Should -Be 1
        $rep[0].Lot | Should -Be 'L1'
        $rep[0].State | Should -Be 'Verified'
        $rep[0].Verified | Should -Be '2/2'
        $rep[0].Html | Should -Exist
        $html = Get-Content -LiteralPath $rep[0].Html -Raw
        $html | Should -Match 'Lot L1'
        $html | Should -Match 'Verified'
        $html | Should -Match 'Import journal'
        $html | Should -Match 'History'
        $rep[0].VerifyCsv | Should -Exist
        $rep[0].VerifyHtml | Should -Exist
        { Invoke-TmtLotReport -Store $e.Store -Folder $out -Lot 'nope' } | Should -Throw '*not found*'
    }
    It 'Invoke-TmtVerify refuses an unknown lot with a clear message' {
        $e = New-VfEnv
        { Invoke-TmtVerify -Store $e.Store -Client $e.Client -Run $e.Run -TargetMap $e.Targets -Lot 'nope' } | Should -Throw '*nope*'
    }
}

Describe 'Entry script: Ghosts, CopyFiles, Verify and Report modes' {
    BeforeAll {
        $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'
        $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script:NoLocalConfig = Join-Path $script:TempRoot 'no-local-config.psd1'
        function Invoke-Entry([string[]]$Arguments) {
            $cwd = New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ('cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -Force | Select-Object -ExpandProperty FullName
            $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            $psi.WorkingDirectory = $cwd
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script:Entry) { $psi.ArgumentList.Add($a) }
            foreach ($a in $Arguments + '-DevelopmentMode') { $psi.ArgumentList.Add([string]$a) }
            foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'TEAMSTRANSFER_LOG_FOLDER') { [void]$psi.Environment.Remove($k) }
            $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = $script:NoLocalConfig
            $p = [Diagnostics.Process]::Start($psi)
            $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw "The entry script did not finish: $($Arguments -join ' ')" }
            $p.WaitForExit()
            $out = $o.GetAwaiter().GetResult(); $err = $er.GetAwaiter().GetResult()
            [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err; All = $out + "`n" + $err }
        }
        # a closed store with a lot, an import catalog and downloaded files, for the child processes
        $script:CliStore = Join-Path $script:TempRoot 'cli-store'
        $s = Open-TmtStore -Root $script:CliStore -Partitions 4
        try {
            $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@([TeamsTransfer.ConversationRecord]@{ Key = 'chat:SRC-CHAT'; Kind = [TeamsTransfer.ConversationKind]::Group; ChatId = 'SRC-CHAT'; CreatedUtc = [datetimeoffset]::UtcNow.AddYears(-3); LastActivityUtc = [datetimeoffset]::UtcNow }))
            $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
            $when = [datetimeoffset]::UtcNow.AddDays(-3)
            $l.Add([Text.Json.JsonDocument]::Parse((@{ id = '1'; createdDateTime = $when.UtcDateTime.ToString('yyyy-MM-dd''T''HH:mm:ss.fff''Z'''); from = @{ user = @{ id = 'src-alice' } }; body = @{ contentType = 'html'; content = 'hi' } } | ConvertTo-Json -Depth 5 -Compress)).RootElement)
            [void]$s.AppendMessages('chat:SRC-CHAT', $l)
            $c = $s.PutContent([IO.MemoryStream]::new([byte[]](1..200)), 'application/octet-stream')
            $s.RecordFile([TeamsTransfer.FileRecord]@{ ConversationKey = 'chat:SRC-CHAT'; MessageId = '1'; AttachmentId = 'a1'; Name = 'x.bin'; Size = 200; Status = [TeamsTransfer.FileStatus]::Downloaded; Sha256 = $c.Sha256 })
            $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'src-alice'; Kind = [TeamsTransfer.IdentityKind]::Mapped; TargetUserId = '11111111-1111-1111-1111-111111111111' })
            $s.UpsertTarget([TeamsTransfer.TargetMapping]@{ SourceConversationKey = 'chat:SRC-CHAT'; Kind = [TeamsTransfer.TargetKind]::NewChat })
            $m = [Collections.Generic.List[TeamsTransfer.LotMember]]::new(); $m.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, 'chat:SRC-CHAT'))
            $id = $s.CreateLot('wave1', $m, [TeamsTransfer.LotOptions]::new())
            [void]$s.ResolveLot($id, [int[]]@(1))
        } finally { $s.Dispose() }
    }

    It 'CopyFiles previews without any request or tenant configuration: counts, destinations, report, exit 0' {
        $r = Invoke-Entry @('-Mode', 'CopyFiles', '-StoreRoot', $script:CliStore, '-Lot', 'wave1', '-LogFolder', (Join-Path $script:TempRoot 'logs-cf'))
        $r.ExitCode | Should -Be 0 -Because $r.All
        $r.Out | Should -Match 'CopyFiles - Preview \(nothing is written\)'
        $r.Out | Should -Match '1 file\(s\) in scope'
        $r.Out | Should -Match 'OneDrive:11111111-1111-1111-1111-111111111111'
        $folder = ([regex]::Match($r.Out, '[A-Za-z]:\\[^\r\n ]*_CopyFiles')).Value
        $folder | Should -Not -BeNullOrEmpty
        (Join-Path $folder 'filecopy.csv') | Should -Exist
        (Join-Path $folder 'TeamsTransfer_CopyFiles.html') | Should -Exist
    }
    It 'Report rebuilds the lot report from the catalog, read only, without a network' {
        $r = Invoke-Entry @('-Mode', 'Report', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-rp'))
        $r.ExitCode | Should -Be 0 -Because $r.All
        $r.Out | Should -Match 'Lot wave1: Planned'
        $folder = ([regex]::Match($r.Out, '[A-Za-z]:\\[^\r\n ]*_Report')).Value
        (Join-Path $folder 'TeamsTransfer_Lot_wave1.html') | Should -Exist
        (Get-Content -LiteralPath (Join-Path $folder 'TeamsTransfer_Lot_wave1.html') -Raw) | Should -Match 'Lot wave1'
    }
    It 'Verify needs a lot, a configured target and refuses -Apply; Ghosts refuses what does not belong to it' {
        $r = Invoke-Entry @('-Mode', 'Verify', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-v1'))
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match '-Lot is required'
        $r = Invoke-Entry @('-Mode', 'Verify', '-Lot', 'wave1', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-v2'))
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match 'Configuration\.Target\.TenantId is empty'
        $r = Invoke-Entry @('-Mode', 'Verify', '-Apply', '-LogFolder', (Join-Path $script:TempRoot 'logs-v3'))
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match 'belongs to the modes that write to the target tenant \(Import, Ghosts, CopyFiles\)'
        $r = Invoke-Entry @('-Mode', 'Verify', '-Remove', '-LogFolder', (Join-Path $script:TempRoot 'logs-v4'))
        $r.All | Should -Match '-Remove does not apply to -Mode Verify'
        $r = Invoke-Entry @('-Mode', 'Ghosts', '-Purge', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-v5'))
        $r.ExitCode | Should -Be 1
        $r.All | Should -Match '-Purge goes with -Remove'
        $r = Invoke-Entry @('-Mode', 'Ghosts', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-v6'))
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Match 'Ghosts - Preview \(nothing is written\)'
        $r.All | Should -Match 'Configuration\.Target\.TenantId is empty'
    }
    It '-WhatIf Verify and Report plan without starting the engine' {
        $r = Invoke-Entry @('-Mode', 'Verify', '-Lot', 'wave1', '-WhatIf', '-StoreRoot', $script:CliStore, '-LogFolder', (Join-Path $script:TempRoot 'logs-w1'))
        $r.ExitCode | Should -Be 0 -Because $r.All
        $r.Out | Should -Match 'WhatIf: it would verify lot wave1'
    }
}

Describe 'Verify: real-lab findings (unreadable target, system events, sampling, dropped parts)' {
    It 'reports a 403 on the target read as Unverified (permission named), not Mismatch, and leaves the lot alone' {
        $e = New-HappyEnv
        Move-Lot $e $e.LotId 'Completing'
        $e.Gf.DenyPathRegex = '^teams/.+/messages'
        $r = Invoke-Verify $e $e.LotId
        $chan = $r.Items | Where-Object ConversationKey -eq $e.ChanKey
        [string]$chan.Outcome | Should -Be 'Unverified'
        $chan.Detail | Should -Match 'ChannelMessage\.Read\.All'
        [string]($r.Items | Where-Object ConversationKey -eq $e.ChatKey).Outcome | Should -Be 'OK'
        $r.Unverified | Should -Be 1
        $r.Mismatch | Should -Be 0
        $r.AllOk | Should -BeFalse
        [string]$e.Store.GetLot($e.LotId).State | Should -Be 'Completing'
        $r.ToText() | Should -Match 'Unverified 1'
        $csv = Join-Path $script:TempRoot 'unv.csv'
        [TeamsTransfer.VerifyReport]::WriteCsv($csv, $r.Items)
        (Import-Csv $csv | Where-Object Outcome -eq 'Unverified').Count | Should -Be 1
    }
    It 'counts only messageType message on the target and reports system events as info' {
        $e = New-VfEnv
        foreach ($i in 1..3) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i)) }
        Complete-Journal $e $e.ChatKey
        foreach ($i in 1..4) { $ms = Add-TargetMessage $e.Chat $script:Now.AddDays(-$i).AddHours(1) $e.Alice '<systemEventMessageTitle>x</systemEventMessageTitle>'; $m = $e.Chat.Find([long]$ms); $m.Flags = [byte](8 -bor 4) }
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        [string]$x.Outcome | Should -Be 'OK' -Because $x.Detail
        $x.TargetMessages | Should -Be 3
        $x.TargetSystemEvents | Should -Be 4
        $x.Detail | Should -Match 'info: 4 system event'
    }
    It 'never samples a message the journal skipped or rejected' {
        $e = New-VfEnv
        foreach ($i in 1..6) { [void](Add-Pair $e 'chat' $script:Now.AddDays(-$i) -SourceOnly:($i -in 2, 5)) }
        $ids = @($e.Store.ReadMessages($e.ChatKey) | ForEach-Object { $_.GetProperty('id').GetString() })
        [void]$e.Store.SeedJournal($e.ChatKey, 1, [string[]]$ids)
        $skipped = @((Get-Ms $script:Now.AddDays(-2)).ToString(), (Get-Ms $script:Now.AddDays(-5)).ToString())
        $marks = [Collections.Generic.List[TeamsTransfer.JournalMark]]::new()
        foreach ($id in $ids) { $marks.Add([TeamsTransfer.JournalMark]@{ ConversationKey = $e.ChatKey; SliceNo = 1; SourceMessageId = $id; Status = $(if ($skipped -contains $id) { [TeamsTransfer.JournalStatus]::Skipped } else { [TeamsTransfer.JournalStatus]::Imported }) }) }
        $e.Store.MarkJournal($marks)
        $sid = $e.Store.BeginImportSession($e.ChatKey, 1, 'a', $script:Now.AddYears(-5), 't'); $e.Store.CompleteImportSession($sid)
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        [string]$x.Outcome | Should -Be 'OK' -Because $x.Detail
        $x.SamplesChecked | Should -Be 4
        $x.TargetMessages | Should -Be 4
    }
    It 'compares a body without the parts the journal says were dropped, and reports them as info' {
        $e = New-VfEnv
        $id = Add-Pair $e 'chat' $script:Now.AddDays(-1) -Html '<p>see the report</p><attachment id="a"></attachment> report.docx' -TargetHtml '<p>see the report</p>' -Files 1
        [void](Add-Pair $e 'chat' $script:Now.AddDays(-2) -Html '<p>plain</p>' -TargetHtml '<p>totally different</p>')
        Complete-Journal $e $e.ChatKey
        $e.Store.MarkJournal([TeamsTransfer.JournalMark]@{ ConversationKey = $e.ChatKey; SliceNo = 1; SourceMessageId = $id; Status = [TeamsTransfer.JournalStatus]::Imported; ErrorCode = 'AttachmentNotCopied' })
        $lot = New-Lot $e -ChatOnly
        $r = Invoke-Verify $e $lot
        $x = $r.Items[0]
        $x.SamplesFailed | Should -Be 1                     # only the genuinely different body
        $x.Detail | Should -Match 'info: 1 sampled message\(s\) had dropped parts \(AttachmentNotCopied\)'
        $x.Detail | Should -Match 'body differs'
        # without the journal note the same message is a difference
        $e.Store.MarkJournal([TeamsTransfer.JournalMark]@{ ConversationKey = $e.ChatKey; SliceNo = 1; SourceMessageId = $id; Status = [TeamsTransfer.JournalStatus]::Imported })
        (Invoke-Verify $e $lot).Items[0].SamplesFailed | Should -Be 2
    }
}
