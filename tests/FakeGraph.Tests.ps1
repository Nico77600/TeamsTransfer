#requires -Version 7.0
# Tests of the fake Microsoft Graph (package\demo\FakeGraph.*.cs) and of the synthetic tenant generator (SyntheticTenant.cs).
# The fake is driven directly through IGraphTransport.SendAsync with GraphRequest objects: no GraphClient involved.
# The 'Volume' test (>= 1,000,000 messages) is skipped unless TMT_VOLUME=1; run it with:
#   $env:TMT_VOLUME = '1'; Invoke-Pester -Path tests\FakeGraph.Tests.ps1 -TagFilter Volume

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function script:Invoke-Fake {
        param($Transport, [string]$Method = 'GET', [string]$Url, $Body, [hashtable]$Headers, [switch]$Anonymous, [byte[]]$Bytes)
        $req = [TeamsTransfer.GraphRequest]::new()
        $req.Method = [Net.Http.HttpMethod]::new($Method)
        $req.Url = $Url
        if ($null -ne $Body) { $req.BodyJson = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress } }
        if ($null -ne $Bytes) { $req.BodyBytes = $Bytes }
        if ($Headers) { foreach ($k in @($Headers.Keys)) { $req.Headers[$k] = $Headers[$k] } }
        $req.Anonymous = [bool]$Anonymous
        $resp = $Transport.SendAsync($req, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $ms = [IO.MemoryStream]::new()
        try { $resp.Content.CopyTo($ms) } finally { $resp.Content.Dispose() }
        $raw = $ms.ToArray()
        $text = [Text.Encoding]::UTF8.GetString($raw)
        $json = $null
        if ("$($resp.ContentType)" -like '*json*' -and $text) { $json = $text | ConvertFrom-Json -DateKind String -Depth 40 }
        [pscustomobject]@{ Status = $resp.StatusCode; Json = $json; Text = $text; Bytes = $raw; Headers = $resp.Headers; Response = $resp; ContentType = $resp.ContentType }
    }

    function script:Get-Pages {
        param($Transport, [string]$Url, [int]$Max = 100000)
        $items = [System.Collections.Generic.List[object]]::new(); $pages = 0
        while ($Url -and $pages -lt $Max) {
            $r = Invoke-Fake $Transport -Url $Url
            if ($r.Status -ne 200) { throw "GET $Url -> $($r.Status) $($r.Text)" }
            $pages++
            foreach ($v in $r.Json.value) { $items.Add($v) }
            $Url = $r.Json.'@odata.nextLink'
        }
        [pscustomobject]@{ Items = $items; Pages = $pages }
    }

    function script:New-Id([string]$b64) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($b64)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $script:EC = [TeamsTransfer.EndpointClass]
    $script:Gap = 'https://graph.microsoft.com/v1.0'
    $script:AppA = '11111111-1111-1111-1111-111111111111'
    $script:AppB = '22222222-2222-2222-2222-222222222222'
}

Describe 'Synthetic tenant generator' {
    BeforeAll {
        $script:tiny = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
    }

    It 'Tiny: 5 users, one departed, one federated, chats of every kind, a team with the three channel kinds' {
        $tiny.Users.Count | Should -Be 5
        @($tiny.Users | Where-Object Deleted).Count | Should -Be 1
        @($tiny.Users | Where-Object External).Count | Should -Be 1
        $types = $tiny.Chats | ForEach-Object { $_.TypeName } | Sort-Object -Unique
        $types | Should -Contain 'oneOnOne'; $types | Should -Contain 'group'; $types | Should -Contain 'meeting'
        $tiny.Teams.Count | Should -Be 1
        $kinds = $tiny.Teams[0].Channels | ForEach-Object { $_.TypeName } | Sort-Object -Unique
        $tiny.Teams[0].Channels.Count | Should -BeGreaterThan 2
        $tiny.MessageCount | Should -BeGreaterThan 100
    }

    It 'chat ids follow the Graph formats' {
        foreach ($c in $tiny.Chats) {
            if ($c.TypeName -eq 'oneOnOne') { $c.Id | Should -Match '^19:[0-9a-f-]{36}_[0-9a-f-]{36}@unq\.gbl\.spaces$' }
            else { $c.Id | Should -Match '^19:.+@thread\.v2$' }
        }
    }

    It 'is deterministic: the same seed gives the same fingerprint, another seed another one' {
        $a = [TeamsTransfer.Testing.SyntheticTenant]::Fingerprint([TeamsTransfer.Testing.SyntheticTenant]::Tiny(7))
        $b = [TeamsTransfer.Testing.SyntheticTenant]::Fingerprint([TeamsTransfer.Testing.SyntheticTenant]::Tiny(7))
        $c = [TeamsTransfer.Testing.SyntheticTenant]::Fingerprint([TeamsTransfer.Testing.SyntheticTenant]::Tiny(8))
        $a | Should -Be $b
        $a | Should -Not -Be $c
    }

    It 'is deterministic through the API too: same seed, same JSON hash over every page of a user' {
        $hashes = foreach ($i in 1..2) {
            $t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(11)
            $tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
            $uid = $t.Users[0].Id
            $all = Get-Pages $tr "v1.0/users/$uid/chats/getAllMessages?model=B&`$top=50"
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($all.Items | ConvertTo-Json -Depth 20 -Compress))))
        }
        $hashes[0] | Should -Be $hashes[1]
    }

    It 'plants the awkward cases: XSS, RTL, emoji, a 26 KB message, cards, system events, a bot, federated and departed authors, broken files' {
        $edge = $tiny.Chats | Where-Object { $_.Topic -like 'Edge cases*' } | Select-Object -First 1
        $edge | Should -Not -BeNullOrEmpty
        $tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($tiny)
        $msgs = (Get-Pages $tr "v1.0/chats/$($edge.Id)/messages?`$top=50").Items
        $bodies = $msgs | ForEach-Object { $_.body.content }
        ($bodies -match '<script>').Count | Should -BeGreaterThan 0
        ($bodies -match 'onerror=').Count | Should -BeGreaterThan 0
        ($bodies -match 'javascript:').Count | Should -BeGreaterThan 0
        ($bodies -match "مرحبا").Count | Should -BeGreaterThan 0
        ($bodies | Measure-Object -Property Length -Maximum).Maximum | Should -BeGreaterThan 25000
        ($bodies | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessThan 28672
        ($msgs | Where-Object messageType -eq 'systemEventMessage').Count | Should -BeGreaterOrEqual 3
        ($msgs.attachments | Where-Object contentType -like '*card.adaptive').Count | Should -BeGreaterThan 0
        ($msgs.attachments | Where-Object contentType -eq 'messageReference').Count | Should -Be 1
        ($msgs | Where-Object { $_.from.application }).Count | Should -Be 1
        $ext = $tiny.Users | Where-Object External; $dep = $tiny.Users | Where-Object Deleted
        ($msgs | Where-Object { $_.from.user.id -eq $ext.Id }).Count | Should -BeGreaterThan 0
        ($msgs | Where-Object { $_.from.user.id -eq $dep.Id }).Count | Should -BeGreaterThan 0
        ($msgs | Where-Object { $_.body.contentType -eq 'text' }).Count | Should -BeGreaterThan 0
        ($msgs | Where-Object { $_.deletedDateTime }).Count | Should -BeGreaterThan 0
        ($msgs | Where-Object { $_.lastEditedDateTime }).Count | Should -BeGreaterThan 0
        # files: real bytes, 1 GiB generated, deleted -> 404, forbidden -> 403
        $refs = $msgs.attachments | Where-Object contentType -eq 'reference'
        $codes = foreach ($a in $refs) {
            $enc = 'u!' + (New-Id $a.contentUrl)
            (Invoke-Fake $tr -Url "v1.0/shares/$enc/driveItem").Status
        }
        $codes | Should -Contain 200; $codes | Should -Contain 404; $codes | Should -Contain 403
    }

    It 'files: the same content is posted in several chats (dedup candidates) and sizes follow a distribution' {
        $p = [TeamsTransfer.Testing.SyntheticProfile]::Tiny(5)
        $p.Users = 12; $p.FilePct = 0.3; $p.MessagesPerChatMedian = 60; $p.PopularFilePct = 0.6; $p.EdgeCases = $false
        $t = [TeamsTransfer.Testing.SyntheticTenant]::Build($p).Tenant
        $files = $t.ItemsById.Values | Where-Object { -not $_.IsFolder }
        $files.Count | Should -BeGreaterThan 20
        $groups = $files | Group-Object { "$($_.Seed):$($_.Size)" } | Where-Object Count -gt 1
        $groups.Count | Should -BeGreaterThan 0
        ($files | Measure-Object Size -Maximum).Maximum | Should -BeGreaterThan ($files | Measure-Object Size -Minimum).Minimum
    }

    It 'Demo preset: readable English conversations with reactions, an image, a file, a meeting chat, channels with replies' {
        $d = [TeamsTransfer.Testing.SyntheticTenant]::Demo()
        $d.Users.Count | Should -Be 6
        @($d.Chats | Where-Object TypeName -eq 'meeting').Count | Should -Be 1
        $tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($d)
        $all = foreach ($c in $d.Chats) { (Get-Pages $tr "v1.0/chats/$($c.Id)/messages?`$top=50").Items }
        ($all | Where-Object { $_.reactions.Count -gt 0 }).Count | Should -BeGreaterThan 5
        ($all | Where-Object { $_.body.content -match '<img ' }).Count | Should -BeGreaterThan 1
        ($all | Where-Object { $_.attachments.contentType -contains 'reference' }).Count | Should -BeGreaterThan 1
        ($all | Where-Object messageType -eq 'systemEventMessage').Count | Should -Be 2
        ($all | Where-Object { $_.body.content -match 'Hi everyone' }).Count | Should -BeGreaterThan 0
        $team = $d.Teams[0]
        $team.Channels.Count | Should -Be 5
        ($team.Channels | ForEach-Object { $_.TypeName } | Sort-Object -Unique) -join ',' | Should -Be 'private,shared,standard'
        $replies = foreach ($ch in $team.Channels) { (Get-Pages $tr "v1.0/teams/$($team.Id)/channels/$($ch.Id)/messages").Items }
        $replies.Count | Should -BeGreaterThan 5
        $r1 = foreach ($ch in $team.Channels) { foreach ($m in (Get-Pages $tr "v1.0/teams/$($team.Id)/channels/$($ch.Id)/messages").Items) { (Get-Pages $tr "v1.0/teams/$($team.Id)/channels/$($ch.Id)/messages/$($m.id)/replies").Items } }
        @($r1).Count | Should -BeGreaterThan 5
    }

    It 'Small preset: about 200 users, departed and federated shares, meetings up to 200+ members, shared files' {
        $r = [TeamsTransfer.Testing.SyntheticTenant]::Build([TeamsTransfer.Testing.SyntheticProfile]::Small(1))
        $t = $r.Tenant
        $t.Users.Count | Should -Be 200
        @($t.Users | Where-Object Deleted).Count | Should -BeGreaterThan 8
        @($t.Users | Where-Object External).Count | Should -BeGreaterThan 3
        ($t.Chats | Where-Object TypeName -eq 'meeting' | ForEach-Object { $_.Members.Count } | Measure-Object -Maximum).Maximum | Should -BeGreaterThan 100
        $r.Stats.Messages | Should -BeGreaterThan 20000
        $r.Stats.SharedFileCopies | Should -BeGreaterThan 0
        $r.Stats.Reactions | Should -BeGreaterThan 100
        $t.Teams.Count | Should -Be 8
    }
}

Describe 'Routing, errors and users' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:dep = $t.Users | Where-Object Deleted
        $script:ext = $t.Users | Where-Object External
    }

    It 'accepts absolute, relative and version-less URLs' {
        (Invoke-Fake $tr -Url 'https://graph.microsoft.com/v1.0/users').Status | Should -Be 200
        (Invoke-Fake $tr -Url 'v1.0/users').Status | Should -Be 200
        (Invoke-Fake $tr -Url 'beta/users').Status | Should -Be 200
        (Invoke-Fake $tr -Url 'users').Status | Should -Be 200
    }

    It 'lists only directory users (no departed, no federated) and resolves a user by id or UPN' {
        $r = Invoke-Fake $tr -Url 'v1.0/users'
        $r.Json.value.Count | Should -Be 3
        $r.Json.value.id | Should -Not -Contain $dep.Id
        $u = $t.Users[0]
        (Invoke-Fake $tr -Url "v1.0/users/$($u.Id)").Json.userPrincipalName | Should -Be $u.Upn
        (Invoke-Fake $tr -Url "v1.0/users/$([uri]::EscapeDataString($u.Upn))").Json.id | Should -Be $u.Id
        (Invoke-Fake $tr -Url "v1.0/users/$($u.Id)?`$select=id,displayName").Json.PSObject.Properties.Name | Should -Not -Contain 'mail'
    }

    It 'departed users: 404 on /users, listed under directory/deletedItems; federated users are not in the directory' {
        $r = Invoke-Fake $tr -Url "v1.0/users/$($dep.Id)"
        $r.Status | Should -Be 404; $r.Json.error.code | Should -Be 'Request_ResourceNotFound'
        (Invoke-Fake $tr -Url "v1.0/users/$($ext.Id)").Status | Should -Be 404
        $d = Invoke-Fake $tr -Url 'v1.0/directory/deletedItems/microsoft.graph.user'
        $d.Json.value.id | Should -Contain $dep.Id
        (Invoke-Fake $tr -Url "v1.0/directory/deletedItems/$($dep.Id)").Status | Should -Be 200
    }

    It 'errors have the Graph shape and a request-id header; wrong verb is 405; unknown segment is 400' {
        $r = Invoke-Fake $tr -Url 'v1.0/chats/19:nope@thread.v2'
        $r.Status | Should -Be 404
        $r.Json.error.code | Should -Not -BeNullOrEmpty; $r.Json.error.message | Should -Not -BeNullOrEmpty
        $r.Json.error.innerError.'request-id' | Should -Be $r.Headers['request-id']
        $r.Json.error.innerError.date | Should -Match '^\d{4}-\d{2}-\d{2}T'
        (Invoke-Fake $tr -Method DELETE -Url 'v1.0/users').Status | Should -Be 405
        $u = Invoke-Fake $tr -Url 'v1.0/whatever/else'
        $u.Status | Should -Be 400; $u.Json.error.message | Should -Match 'segment'
    }

    It 'pages users with an opaque skiptoken and a deterministic order' {
        $p = [TeamsTransfer.Testing.SyntheticProfile]::Small(2)
        $big = [TeamsTransfer.Testing.SyntheticTenant]::Build($p).Tenant
        $tb = [TeamsTransfer.Testing.FakeGraphTransport]::new($big)
        $first = Invoke-Fake $tb -Url 'v1.0/users?$top=50'
        $first.Json.value.Count | Should -Be 50
        $first.Json.'@odata.nextLink' | Should -Match 'skiptoken='
        $all = Get-Pages $tb 'v1.0/users?$top=50'
        $all.Pages | Should -BeGreaterThan 3
        $all.Items.Count | Should -Be (@($big.Users | Where-Object { -not $_.Deleted -and -not $_.External }).Count)
        ($all.Items.id | Select-Object -Unique).Count | Should -Be $all.Items.Count
        (Invoke-Fake $tb -Url 'v1.0/users?$skiptoken=garbage').Status | Should -Be 400
    }

    It 'filters users by userPrincipalName' {
        $u = $t.Users[1]
        $r = Invoke-Fake $tr -Url ("v1.0/users?`$filter=userPrincipalName eq '{0}'" -f $u.Upn)
        $r.Json.value.Count | Should -Be 1; $r.Json.value[0].id | Should -Be $u.Id
    }
}

Describe 'Chats and messages (export side)' {
    BeforeAll {
        $p = [TeamsTransfer.Testing.SyntheticProfile]::Tiny(3)
        $p.MessagesPerChatMedian = 300; $p.MessagesPerChatSigma = 0.3; $p.EdgeCases = $false
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Build($p).Tenant
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:u0 = $t.Users[0]
        $script:chat = $t.Chats | Where-Object { $_.TypeName -eq 'group' } | Select-Object -First 1
    }

    It 'lists the chats of a user with $expand=members and filters by chatType' {
        $all = (Get-Pages $tr "v1.0/users/$($u0.Id)/chats?`$expand=members").Items
        $all.Count | Should -Be (@($t.ChatsByUser[$u0.Ordinal]).Count)
        $all[0].members.Count | Should -BeGreaterThan 1
        $all[0].members[0].'@odata.type' | Should -Be '#microsoft.graph.aadUserConversationMember'
        $groups = (Get-Pages $tr "v1.0/users/$($u0.Id)/chats?`$filter=chatType eq 'group'").Items
        @($groups | Where-Object chatType -ne 'group').Count | Should -Be 0
        $groups.Count | Should -BeGreaterThan 0
        (Invoke-Fake $tr -Url "v1.0/users/$($t.Users | Where-Object Deleted | ForEach-Object Id)/chats").Status | Should -Be 404
    }

    It 'chats/{id}, with and without members, and chats/{id}/members' {
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)").Json.chatType | Should -Be 'group'
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)").Json.PSObject.Properties.Name | Should -Not -Contain 'members'
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)?`$expand=members").Json.members.Count | Should -Be $chat.Members.Count
        $m = Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/members"
        $m.Json.value.Count | Should -Be $chat.Members.Count
        $m.Json.value[0].visibleHistoryStartDateTime | Should -Be '0001-01-01T00:00:00Z'
    }

    It 'chat messages: default 20 per page, $top up to 50, 51 rejected, newest modification first, nextLink to the end' {
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages").Json.value.Count | Should -Be 20
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages?`$top=50").Json.value.Count | Should -Be 50
        $bad = Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages?`$top=51"
        $bad.Status | Should -Be 400
        $all = Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50"
        $all.Items.Count | Should -Be $chat.Messages.Count
        $mods = $all.Items.lastModifiedDateTime
        ($mods | Sort-Object -Descending) -join ',' | Should -Be ($mods -join ',')
        ($all.Items.id | Select-Object -Unique).Count | Should -Be $all.Items.Count
    }

    It 'chat messages: lastModifiedDateTime filters (gt / lt / both) and $orderby' {
        $all = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50").Items
        $mid = $all[[int]($all.Count / 2)].lastModifiedDateTime
        $gt = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50&`$filter=lastModifiedDateTime gt $mid").Items
        $gt.Count | Should -Be (@($all | Where-Object { $_.lastModifiedDateTime -gt $mid }).Count)
        $lt = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50&`$filter=lastModifiedDateTime lt $mid").Items
        $lt.Count | Should -Be (@($all | Where-Object { $_.lastModifiedDateTime -lt $mid }).Count)
        $q = $all[[int]($all.Count / 4)].lastModifiedDateTime
        $both = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50&`$filter=lastModifiedDateTime gt $mid and lastModifiedDateTime lt $q").Items
        $both.Count | Should -Be (@($all | Where-Object { $_.lastModifiedDateTime -gt $mid -and $_.lastModifiedDateTime -lt $q }).Count)
        $c = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50&`$orderby=createdDateTime desc").Items
        ($c.createdDateTime | Sort-Object -Descending) -join ',' | Should -Be ($c.createdDateTime -join ',')
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages?`$orderby=createdDateTime asc").Status | Should -Be 400
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages?`$filter=foo gt 1").Status | Should -Be 400
    }

    It 'one message: shape, 404, edits, deletions' {
        $page = (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages?`$top=50").Json.value
        $m = $page[0]
        $one = Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages/$($m.id)"
        $one.Status | Should -Be 200
        $one.Json.id | Should -Be $m.id; $one.Json.chatId | Should -Be $chat.Id; $one.Json.from.user.userIdentityType | Should -Be 'aadUser'
        $one.Json.body.contentType | Should -BeIn 'html', 'text'
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages/12345").Status | Should -Be 404
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/messages/abc").Status | Should -Be 400
        $all = (Get-Pages $tr "v1.0/chats/$($chat.Id)/messages?`$top=50").Items
        @($all | Where-Object { $_.deletedDateTime }).Count | Should -BeGreaterOrEqual 0
        @($all | Where-Object { $_.lastEditedDateTime -and $_.lastModifiedDateTime -eq $_.lastEditedDateTime }).Count | Should -Be @($all | Where-Object { $_.lastEditedDateTime }).Count
    }

    It 'getAllMessages with a model: every message of the user once, filters and paging' {
        $expected = 0; foreach ($c in $t.ChatsByUser[$u0.Ordinal]) { $expected += $c.Messages.Count }
        $expected | Should -BeGreaterThan 500
        $all = Get-Pages $tr "v1.0/users/$($u0.Id)/chats/getAllMessages?model=B&`$top=50"
        $all.Items.Count | Should -Be $expected
        $all.Items.Count | Should -Be (($all.Items | ForEach-Object { "$($_.chatId)/$($_.id)" } | Select-Object -Unique).Count)
        $mods = $all.Items.lastModifiedDateTime
        ($mods | Sort-Object -Descending) -join ',' | Should -Be ($mods -join ',')
        (Get-Pages $tr "v1.0/users/$($u0.Id)/chats/getAllMessages?model=A&`$top=50").Items.Count | Should -Be $expected
        $lo = $mods[[int]($mods.Count * 0.6)]; $hi = $mods[[int]($mods.Count * 0.2)]
        $win = Get-Pages $tr "v1.0/users/$($u0.Id)/chats/getAllMessages?model=B&`$top=50&`$filter=lastModifiedDateTime gt $lo and lastModifiedDateTime lt $hi"
        $win.Items.Count | Should -Be (@($mods | Where-Object { $_ -gt $lo -and $_ -lt $hi }).Count)
        (Invoke-Fake $tr -Url "v1.0/users/$($u0.Id)/chats/getAllMessages?model=B&`$top=51").Status | Should -Be 400
    }

    It 'getAllMessages without a valid model = evaluation mode: capped at 500 messages and a Warning header' {
        foreach ($suffix in '', '&model=Z', '&model=') {
            $before = $tr.Counters.EvaluationModeResponses
            $first = Invoke-Fake $tr -Url "v1.0/users/$($u0.Id)/chats/getAllMessages?`$top=50$suffix"
            $first.Status | Should -Be 200
            $first.Headers['Warning'] | Should -Match 'Evaluation mode'
            $tr.Counters.EvaluationModeResponses | Should -BeGreaterThan $before
            $all = Get-Pages $tr "v1.0/users/$($u0.Id)/chats/getAllMessages?`$top=50$suffix"
            $all.Items.Count | Should -Be 500
        }
        $ok = Invoke-Fake $tr -Url "v1.0/users/$($u0.Id)/chats/getAllMessages?model=B&`$top=50"
        $ok.Headers.ContainsKey('Warning') | Should -BeFalse
    }

    It 'hostedContents: list, metadata and $value bytes of an inline image' {
        $withImg = $null
        foreach ($c in $t.Chats) { $withImg = $c.Messages | Where-Object { $_.X -and $_.X.Hosted } | Select-Object -First 1; if ($withImg) { $thread = $c; break } }
        $withImg | Should -Not -BeNullOrEmpty
        $base = "v1.0/chats/$($thread.Id)/messages/$($withImg.CreatedMs)"
        $list = Invoke-Fake $tr -Url "$base/hostedContents"
        $list.Json.value.Count | Should -Be 1
        $hid = $list.Json.value[0].id
        (Invoke-Fake $tr -Url "$base/hostedContents/$hid").Json.contentBytes | Should -Not -BeNullOrEmpty
        $v = Invoke-Fake $tr -Url "$base/hostedContents/$hid/`$value"
        $v.Status | Should -Be 200; $v.ContentType | Should -Be 'image/png'
        ($v.Bytes[1..3] | ForEach-Object { [char]$_ }) -join '' | Should -Be 'PNG'
        (Invoke-Fake $tr -Url "$base/hostedContents/nope/`$value").Status | Should -Be 404
        $msg = (Invoke-Fake $tr -Url $base).Json
        $msg.body.content | Should -Match ([regex]::Escape("hostedContents/$hid/`$value"))
    }
}

Describe 'Teams and channels (export side)' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Demo()
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:team = $t.Teams[0]
        $script:priv = $team.Channels | Where-Object { $_.TypeName -eq 'private' }
        $script:shared = $team.Channels | Where-Object { $_.TypeName -eq 'shared' }
        $script:std = $team.Channels | Where-Object { $_.Id -eq ($team.Channels | Where-Object DisplayName -eq 'Announcements').Id }
    }

    It 'groups with the Team provisioning filter and teams list both return the team' {
        $g = Invoke-Fake $tr -Url "v1.0/groups?`$filter=resourceProvisioningOptions/Any(x:x eq 'Team')"
        $g.Json.value[0].id | Should -Be $team.Id
        $g.Json.value[0].resourceProvisioningOptions | Should -Contain 'Team'
        (Invoke-Fake $tr -Url 'v1.0/teams').Json.value[0].id | Should -Be $team.Id
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)").Json.displayName | Should -Be $team.DisplayName
        $t.TeamsListEndpointEnabled = $false
        (Invoke-Fake $tr -Url 'v1.0/teams').Status | Should -Be 400
        (Invoke-Fake $tr -Url "v1.0/groups?`$filter=resourceProvisioningOptions/Any(x:x eq 'Team')").Status | Should -Be 200
        $t.TeamsListEndpointEnabled = $true
        (Invoke-Fake $tr -Url "v1.0/teams/nope").Status | Should -Be 404
    }

    It 'channels include private and shared ones, filterable by membershipType' {
        $ch = (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels").Json.value
        ($ch.membershipType | Sort-Object -Unique) -join ',' | Should -Be 'private,shared,standard'
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels?`$filter=membershipType eq 'private'").Json.value.Count | Should -Be 1
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($priv.Id)").Json.displayName | Should -Be 'Management'
    }

    It 'channel members: private and shared have their own, standard shows the team members' {
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($priv.Id)/members").Json.value.Count | Should -Be 2
        $sm = (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($shared.Id)/members").Json.value
        $sm.Count | Should -Be 3
        $sm.tenantId | Select-Object -Unique | Measure-Object | ForEach-Object Count | Should -Be 2
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($std.Id)/members").Json.value.Count | Should -Be 4
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/members").Json.value.Count | Should -Be 4
    }

    It 'channel messages are roots only, replies come from /replies, getAllMessages returns both' {
        $roots = (Get-Pages $tr "v1.0/teams/$($team.Id)/channels/$($std.Id)/messages?`$top=50").Items
        $roots.Count | Should -Be 2
        $roots.replyToId | Where-Object { $_ } | Should -BeNullOrEmpty
        $n = 0
        foreach ($m in $roots) {
            $rep = (Get-Pages $tr "v1.0/teams/$($team.Id)/channels/$($std.Id)/messages/$($m.id)/replies").Items
            $n += $rep.Count
            foreach ($r in $rep) { $r.replyToId | Should -Be $m.id; $r.channelIdentity.channelId | Should -Be $std.Id }
        }
        $n | Should -Be 4
        $all = Get-Pages $tr "v1.0/teams/$($team.Id)/channels/getAllMessages?model=B&`$top=50"
        $all.Items.Count | Should -Be ($t.MessageCount - (($t.Chats | ForEach-Object { $_.Messages.Count } | Measure-Object -Sum).Sum))
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/getAllMessages?`$top=50").Headers['Warning'] | Should -Match 'Evaluation'
        $one = (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($std.Id)/messages/$($roots[0].id)").Json
        $one.id | Should -Be $roots[0].id
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($std.Id)/messages/$($roots[0].id)/replies/999").Status | Should -Be 404
    }

    It 'hostedContents of a channel message and of a channel file folder' {
        $design = $team.Channels | Where-Object DisplayName -eq 'Design'
        $m = (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($design.Id)/messages").Json.value[0]
        $hc = Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($design.Id)/messages/$($m.id)/hostedContents"
        $hc.Json.value.Count | Should -Be 1
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($design.Id)/messages/$($m.id)/hostedContents/$($hc.Json.value[0].id)/`$value").Bytes.Length | Should -BeGreaterThan 100
        $ff = Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($std.Id)/filesFolder"
        $ff.Json.name | Should -Be 'Announcements'; $ff.Json.parentReference.driveId | Should -Not -BeNullOrEmpty
    }
}

Describe 'Files: shares, drive items, content, uploads, sharing' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:owner = $t.Users[0]
        $script:drive = $t.UserDrive($owner)
        $script:small = $drive.Items.Values | Where-Object Name -eq 'Read-me.txt'
        $script:big = $drive.Items.Values | Where-Object Name -eq 'Large_file_1GB.bin'
    }

    It 'resolves a sharing url (u!base64url) to a driveItem with a downloadUrl, then downloads it' {
        $enc = 'u!' + (New-Id $small.WebUrl)
        $di = Invoke-Fake $tr -Url "v1.0/shares/$enc/driveItem"
        $di.Status | Should -Be 200
        $di.Json.id | Should -Be $small.Id; $di.Json.name | Should -Be 'Read-me.txt'; $di.Json.size | Should -Be $small.Size
        $di.Json.parentReference.driveId | Should -Be $drive.Id
        $di.Json.file.mimeType | Should -Be 'text/plain'
        $di.Json.'@microsoft.graph.downloadUrl' | Should -Match '^https://download\.'
        $c = Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($small.Id)/content"
        $c.Status | Should -Be 200
        [Text.Encoding]::UTF8.GetString($c.Bytes) | Should -Match 'Test file'
        $dl = Invoke-Fake $tr -Url $di.Json.'@microsoft.graph.downloadUrl' -Anonymous
        $dl.Bytes.Length | Should -Be $small.Size
        (Invoke-Fake $tr -Url "v1.0/shares/$enc/driveItem/content").Bytes.Length | Should -Be $small.Size
        (Invoke-Fake $tr -Url 'v1.0/shares/u!bm9wZQ/driveItem').Status | Should -Be 404
        (Invoke-Fake $tr -Url 'v1.0/shares/xyz/driveItem').Status | Should -Be 400
    }

    It 'a 1 GiB generated file costs no memory: ranges are served, the SHA-256 of a range matches the model' {
        $r = Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($big.Id)/content" -Headers @{ Range = 'bytes=1000-1099' }
        $r.Status | Should -Be 206
        $r.Bytes.Length | Should -Be 100
        $r.Headers['Content-Range'] | Should -Be 'bytes 1000-1099/1073741824'
        $ref = [byte[]]::new(100); $s = $big.OpenRead(); $s.Position = 1000; [void]$s.Read($ref, 0, 100); $s.Dispose()
        [Convert]::ToHexString($r.Bytes) | Should -Be ([Convert]::ToHexString($ref))
        (Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($big.Id)").Json.size | Should -Be 1073741824
    }

    It 'deleted file -> 404 itemNotFound, access denied file -> 403 accessDenied, folder by path, children' {
        $gone = $drive.Items.Values | Where-Object Name -eq 'Deleted.docx'
        $den = $drive.Items.Values | Where-Object Name -eq 'Confidential.pdf'
        $r = Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($gone.Id)"
        $r.Status | Should -Be 404; $r.Json.error.code | Should -Be 'itemNotFound'
        $d = Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($den.Id)/content"
        $d.Status | Should -Be 403; $d.Json.error.code | Should -Be 'accessDenied'
        $f = Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/root:/Microsoft%20Teams%20Chat%20Files"
        $f.Status | Should -Be 200; $f.Json.folder.childCount | Should -BeGreaterThan 1
        (Invoke-Fake $tr -Url "v1.0/drives/$($drive.Id)/items/$($f.Json.id)/children").Json.value.name | Should -Contain 'Read-me.txt'
        (Invoke-Fake $tr -Url "v1.0/users/$($owner.Id)/drive").Json.id | Should -Be $drive.Id
        (Invoke-Fake $tr -Url "v1.0/users/$($owner.Id)/drive/root:/Microsoft Teams Chat Files/Read-me.txt:/content").Bytes.Length | Should -Be $small.Size
    }

    It 'upload session: fragments of 320 KiB multiples, anonymous PUT, contiguity, final 201 with the item and the right bytes' {
        $target = $t.Users[1]; $dr = $t.UserDrive($target)
        $total = 327680 + 1234
        $data = [byte[]]::new($total); [Random]::new(5).NextBytes($data)
        $s = Invoke-Fake $tr -Method POST -Url "v1.0/drives/$($dr.Id)/root:/Microsoft Teams Chat Files/Rapport.bin:/createUploadSession" -Body @{ item = @{ '@microsoft.graph.conflictBehavior' = 'replace' } }
        $s.Status | Should -Be 200
        $url = $s.Json.uploadUrl; $s.Json.nextExpectedRanges | Should -Be '0-'
        $chunk1 = $data[0..327679]; $chunk2 = $data[327680..($total - 1)]
        (Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk1 -Headers @{ 'Content-Range' = "bytes 0-327679/$total" }).Status | Should -Be 401   # not anonymous
        $bad = Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk2 -Headers @{ 'Content-Range' = "bytes 327680-$($total - 1)/$total" } -Anonymous
        $bad.Status | Should -Be 416
        $odd = Invoke-Fake $tr -Method PUT -Url $url -Bytes $data[0..99999] -Headers @{ 'Content-Range' = "bytes 0-99999/$total" } -Anonymous
        $odd.Status | Should -Be 400; $odd.Json.error.code | Should -Be 'invalidRange'
        (Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk1 -Headers @{} -Anonymous).Status | Should -Be 400
        $r1 = Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk1 -Headers @{ 'Content-Range' = "bytes 0-327679/$total" } -Anonymous
        $r1.Status | Should -Be 202; $r1.Json.nextExpectedRanges | Should -Be '327680-'
        (Invoke-Fake $tr -Url $url -Anonymous).Json.nextExpectedRanges | Should -Be '327680-'
        $r2 = Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk2 -Headers @{ 'Content-Range' = "bytes 327680-$($total - 1)/$total" } -Anonymous
        $r2.Status | Should -Be 201
        $r2.Json.name | Should -Be 'Rapport.bin'; $r2.Json.size | Should -Be $total
        $got = Invoke-Fake $tr -Url "v1.0/drives/$($dr.Id)/items/$($r2.Json.id)/content"
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($got.Bytes)) | Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)))
        (Invoke-Fake $tr -Url "v1.0/shares/u!$(New-Id $r2.Json.webUrl)/driveItem").Json.id | Should -Be $r2.Json.id
        (Invoke-Fake $tr -Method PUT -Url $url -Bytes $chunk1 -Headers @{ 'Content-Range' = "bytes 0-327679/$total" } -Anonymous).Status | Should -Be 404   # session closed
        $tr.Counters.Calls($EC::DriveUpload) | Should -BeGreaterThan 5
    }

    It 'upload session conflict behaviours and a graph request marked anonymous is refused' {
        $dr = $t.UserDrive($t.Users[2])
        $mk = { param($mode) Invoke-Fake $tr -Method POST -Url "v1.0/drives/$($dr.Id)/root:/Doc/a.txt:/createUploadSession" -Body @{ item = @{ '@microsoft.graph.conflictBehavior' = $mode } } }
        $put = { param($url) Invoke-Fake $tr -Method PUT -Url $url -Bytes ([byte[]](1..10)) -Headers @{ 'Content-Range' = 'bytes 0-9/10' } -Anonymous }
        (& $put (& $mk 'replace').Json.uploadUrl).Status | Should -Be 201
        (& $put (& $mk 'replace').Json.uploadUrl).Status | Should -Be 200
        (& $mk 'fail').Status | Should -Be 409
        $ren = & $put (& $mk 'rename').Json.uploadUrl
        $ren.Json.name | Should -Be 'a 1.txt'
        (Invoke-Fake $tr -Url 'v1.0/users' -Anonymous).Status | Should -Be 401
    }

    It 'simple upload (PUT content) and invite / createLink / permissions' {
        $dr = $t.UserDrive($t.Users[0])
        $p = Invoke-Fake $tr -Method PUT -Url "v1.0/drives/$($dr.Id)/root:/Microsoft Teams Chat Files/petit.txt:/content" -Bytes ([Text.Encoding]::UTF8.GetBytes('bonjour'))
        $p.Status | Should -Be 201; $p.Json.size | Should -Be 7
        $inv = Invoke-Fake $tr -Method POST -Url "v1.0/drives/$($dr.Id)/items/$($p.Json.id)/invite" -Body @{ recipients = @(@{ objectId = $t.Users[1].Id }); roles = @('read'); requireSignIn = $true; sendInvitation = $false }
        $inv.Status | Should -Be 200; $inv.Json.value[0].roles | Should -Be 'read'; $inv.Json.value[0].grantedToV2.user.id | Should -Be $t.Users[1].Id
        (Invoke-Fake $tr -Method POST -Url "v1.0/drives/$($dr.Id)/items/$($p.Json.id)/invite" -Body @{ recipients = @(@{ email = $t.Users | Where-Object Deleted | ForEach-Object Upn }) }).Status | Should -Be 400
        $l = Invoke-Fake $tr -Method POST -Url "v1.0/drives/$($dr.Id)/items/$($p.Json.id)/createLink" -Body @{ type = 'view'; scope = 'users' }
        $l.Status | Should -Be 201; $l.Json.link.webUrl | Should -Match '^https://'
        (Invoke-Fake $tr -Url "v1.0/drives/$($dr.Id)/items/$($p.Json.id)/permissions").Json.value.Count | Should -Be 2
    }
}

Describe 'Migration (import) API' {
    BeforeEach {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $script:u0 = $t.Users[0]; $script:u1 = $t.Users[1]; $script:u2 = $t.Users[2]
        $script:dep = $t.Users | Where-Object Deleted
        $script:ext = $t.Users | Where-Object External
        $mem = { param($u) @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u.Id)')" } }
        $c = Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'group'; topic = 'Import'; members = @((& $mem $u0), (& $mem $u1), (& $mem $u2)) }
        $script:chatId = $c.Json.id
        $script:post = {
            param($when, $user, $extra = @{}, $cid = $script:chatId, $tr2 = $script:tr)
            $b = @{ createdDateTime = $when; from = @{ user = @{ id = $user.Id } }; body = @{ contentType = 'html'; content = '<p>Bonjour</p>' } }
            foreach ($k in $extra.Keys) { $b[$k] = $extra[$k] }
            Invoke-Fake $tr2 -Method POST -Url "v1.0/chats/$cid/messages" -Body $b
        }
        $script:start = { param($when = '2020-01-01T09:59:59Z', $cid = $script:chatId, $tr2 = $script:tr) Invoke-Fake $tr2 -Method POST -Url "v1.0/chats/$cid/startMigration" -Body @{ conversationCreationDateTime = $when } }
    }

    It 'creates a group chat, starts migration, imports with the original author and date, completes' {
        $c = Invoke-Fake $tr -Url "v1.0/chats/${chatId}?`$expand=members"
        $c.Json.chatType | Should -Be 'group'; $c.Json.members.Count | Should -Be 3
        $c.Json.PSObject.Properties.Name | Should -Not -Contain 'migrationMode'
        (& $start).Status | Should -Be 204
        $g = Invoke-Fake $tr -Url "v1.0/chats/$chatId"
        $g.Json.migrationMode | Should -Be 'inProgress'
        $g.Json.createdDateTime | Should -Be '2020-01-01T09:59:59.000Z'
        $m = & $post '2020-01-01T10:00:00.5Z' $u1
        $m.Status | Should -Be 201
        $m.Json.createdDateTime | Should -Be '2020-01-01T10:00:00.500Z'
        $m.Json.from.user.id | Should -Be $u1.Id; $m.Json.id | Should -Be '1577872800500'
        (Invoke-Fake $tr -Url "v1.0/chats/$chatId/messages/$($m.Json.id)").Json.body.content | Should -Be '<p>Bonjour</p>'
        $done = Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration"
        $done.Status | Should -Be 204
        (Invoke-Fake $tr -Url "v1.0/chats/$chatId").Json.migrationMode | Should -Be 'completed'
        $tr.Counters.ImportedMessages | Should -Be 1
        $tr.Counters.Calls($EC::MigrationStart) | Should -Be 1
        $tr.Counters.Calls($EC::MigrationComplete) | Should -Be 1
    }

    It 'startMigration rules: date must precede createdDateTime, required, not twice, not after completion' {
        (& $start '2999-01-01T00:00:00Z').Status | Should -Be 400
        $created = (Invoke-Fake $tr -Url "v1.0/chats/$chatId").Json.createdDateTime
        (& $start $created).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/startMigration" -Body @{}).Status | Should -Be 400
        (& $start).Status | Should -Be 204
        (& $start).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration").Status | Should -Be 204
        (& $start).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration").Status | Should -Be 400
    }

    It 'rejects createdDateTime in the future, before the conversation, and duplicates at millisecond precision (sub-ms truncated)' {
        [void](& $start)
        $f = & $post '2999-01-01T00:00:00Z' $u0
        $f.Status | Should -Be 400; $f.Json.error.code | Should -Be 'BadRequest'; $f.Json.error.message | Should -Match 'future'
        $e = & $post '2019-12-31T23:59:59Z' $u0
        $e.Status | Should -Be 400; $e.Json.error.message | Should -Match 'earlier than the creation'
        (& $post '2020-01-01T10:00:00.1239Z' $u0).Json.createdDateTime | Should -Be '2020-01-01T10:00:00.123Z'
        $dup = & $post '2020-01-01T10:00:00.123Z' $u1
        $dup.Status | Should -Be 400; $dup.Json.error.message | Should -Match 'already exists'
        (& $post '2020-01-01T10:00:00.124Z' $u1).Status | Should -Be 201
        (& $post $null $u0).Status | Should -Be 400
    }

    It 'rejects federated authors, departed authors (unless the tenant accepts them), unknown authors and a missing from' {
        [void](& $start)
        $x = & $post '2020-01-01T10:00:01Z' $ext
        $x.Status | Should -Be 400; $x.Json.error.message | Should -Match 'federated'
        (& $post '2020-01-01T10:00:02Z' $dep).Status | Should -Be 400
        $t.DeletedAuthorsAccepted = $true
        (& $post '2020-01-01T10:00:02Z' $dep).Status | Should -Be 201
        $t.DeletedAuthorsAccepted = $false
        (& $post '2020-01-01T10:00:03Z' ([pscustomobject]@{ Id = [guid]::NewGuid().ToString() })).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/messages" -Body @{ createdDateTime = '2020-01-01T10:00:04Z'; body = @{ content = 'x' } }).Status | Should -Be 400
    }

    It 'reactions above 250 are rejected, 250 accepted; body size limit; mentions and attachments are kept' {
        [void](& $start)
        $r = @(1..251 | ForEach-Object { @{ reactionType = 'like'; user = @{ user = @{ id = $u1.Id } } } })
        (& $post '2020-01-01T10:00:05Z' $u0 @{ reactions = $r }).Status | Should -Be 400
        $ok = & $post '2020-01-01T10:00:06Z' $u0 @{ reactions = @($r | Select-Object -First 250) }
        $ok.Status | Should -Be 201; $ok.Json.reactions.Count | Should -Be 250
        $huge = & $post '2020-01-01T10:00:07Z' $u0 @{ body = @{ contentType = 'html'; content = ('x' * 30000) } }
        $huge.Status | Should -Be 400; $huge.Json.error.message | Should -Match 'too large'
        $bad = & $post '2020-01-01T10:00:07Z' $u0 @{ attachments = @(@{ id = 'a1'; contentType = 'reference'; contentUrl = 'https://contoso-my.sharepoint.com/personal/x/Documents/a.docx'; name = 'a.docx' }) }
        $bad.Status | Should -Be 400; $bad.Json.error.message | Should -Match "Invalid GUID 'a1' for file attachment"
        $aid = [guid]::NewGuid().ToString()
        $rich = & $post '2020-01-01T10:00:08Z' $u0 @{
            body = @{ contentType = 'html'; content = "<p><at id=`"0`">Julien</at> voir fichier</p><attachment id=`"$aid`"></attachment>" }
            mentions = @(@{ id = 0; mentionText = 'Julien'; mentioned = @{ user = @{ id = $u1.Id } } })
            attachments = @(@{ id = $aid; contentType = 'reference'; contentUrl = 'https://contoso-my.sharepoint.com/personal/x/Documents/a.docx'; name = 'a.docx' })
            subject = $null
        }
        $rich.Status | Should -Be 201
        $rich.Json.mentions[0].mentioned.user.id | Should -Be $u1.Id; $rich.Json.attachments[0].name | Should -Be 'a.docx'
    }

    It 'inline images: temporaryId + ../hostedContents/N/$value is rewritten and the bytes are downloadable; dangling references are rejected' {
        [void](& $start)
        $png = [TeamsTransfer.Testing.FakePng]::Gradient(3)
        $m = & $post '2020-01-01T10:00:09Z' $u0 @{
            body = @{ contentType = 'html'; content = '<p>Image :</p><img src="../hostedContents/1/$value" width="96" height="64">' }
            hostedContents = @(@{ '@microsoft.graph.temporaryId' = '1'; contentBytes = [Convert]::ToBase64String($png); contentType = 'image/png' })
        }
        $m.Status | Should -Be 201
        $m.Json.body.content | Should -Not -Match '\.\./hostedContents'
        $m.Json.body.content | Should -Match "https://graph\.microsoft\.com/v1\.0/chats/.+/messages/$($m.Json.id)/hostedContents/.+/\`$value"
        $list = Invoke-Fake $tr -Url "v1.0/chats/$chatId/messages/$($m.Json.id)/hostedContents"
        $v = Invoke-Fake $tr -Url "v1.0/chats/$chatId/messages/$($m.Json.id)/hostedContents/$($list.Json.value[0].id)/`$value"
        [Convert]::ToHexString($v.Bytes) | Should -Be ([Convert]::ToHexString($png))
        $dangling = & $post '2020-01-01T10:00:10Z' $u0 @{ body = @{ contentType = 'html'; content = '<img src="../hostedContents/9/$value">' } }
        $dangling.Status | Should -Be 400
        (& $post '2020-01-01T10:00:11Z' $u0 @{ hostedContents = @(@{ '@microsoft.graph.temporaryId' = '1'; contentBytes = '***'; contentType = 'image/png' }) }).Status | Should -Be 400
    }

    It 'posting outside migration mode is refused with 403 (with or without createdDateTime); after completion too' {
        $r = & $post '2020-01-01T10:00:00Z' $u0
        $r.Status | Should -Be 403; $r.Json.error.code | Should -Be 'Forbidden'; $r.Json.error.message | Should -Match 'migration mode'
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/messages" -Body @{ body = @{ content = 'hello' } }).Status | Should -Be 403
        [void](& $start)
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration").Status | Should -Be 204
        (& $post '2020-01-01T10:00:00Z' $u0).Status | Should -Be 403
    }

    It 'the application that started the migration owns it: start / import / complete by another application -> 403' {
        $other = $tr.ForApp($AppB)
        (& $start).Status | Should -Be 204
        $blocked = & $post '2020-01-01T10:00:00Z' $u0 @{} $chatId $other
        $blocked.Status | Should -Be 403; $blocked.Json.error.message | Should -Match 'another application'
        (& $start '2019-01-01T00:00:00Z' $chatId $other).Status | Should -Be 403
        (Invoke-Fake $other -Method POST -Url "v1.0/chats/$chatId/completeMigration").Status | Should -Be 403
        (& $post '2020-01-01T10:00:00Z' $u0).Status | Should -Be 201
        # per-request override of the calling app on the same transport
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration" -Headers @{ 'X-Fake-AppId' = $AppB }).Status | Should -Be 403
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/completeMigration").Status | Should -Be 204
    }

    It 'POST chats: a oneOnOne for an existing pair returns the existing chat; a new pair creates one; bad requests are 400/404' {
        $mem = { param($u) @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u.Id)')" } }
        $a = $u0; $b = $u1
        $pairKey = [TeamsTransfer.Testing.FakeTenant]::PairKey($a.Ordinal, $b.Ordinal)
        if (-not $t.OneOnOneByPair.ContainsKey($pairKey)) { $null = Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'oneOnOne'; members = @((& $mem $a), (& $mem $b)) } }
        $existing = $t.OneOnOneByPair[$pairKey]
        $r = Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'oneOnOne'; members = @((& $mem $a), (& $mem $b)) }
        $r.Status | Should -Be 201; $r.Json.id | Should -Be $existing.Id
        $before = $t.Chats.Count
        $free = $null
        foreach ($x in $t.Users | Where-Object { -not $_.Deleted -and -not $_.External }) { foreach ($y in $t.Users | Where-Object { -not $_.Deleted -and -not $_.External }) {
            if ($x.Ordinal -lt $y.Ordinal -and -not $t.OneOnOneByPair.ContainsKey([TeamsTransfer.Testing.FakeTenant]::PairKey($x.Ordinal, $y.Ordinal))) { $free = @($x, $y) } } }
        if ($free) {
            $n = Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'oneOnOne'; members = @((& $mem $free[0]), (& $mem $free[1])) }
            $n.Status | Should -Be 201; $n.Json.id | Should -Match '@unq\.gbl\.spaces$'; $t.Chats.Count | Should -Be ($before + 1)
        }
        (Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'oneOnOne'; members = @((& $mem $a)) }).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'group'; members = @((& $mem $u0), (& $mem $dep)) }).Status | Should -Be 404
        (Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'group'; members = @((& $mem $u0), (& $mem $ext)) }).Status | Should -Be 404
        (Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body '{oops').Status | Should -Be 400
    }

    It 'group members: remove then add back with visibleHistoryStartDateTime; oneOnOne and duplicates refused' {
        $members = (Invoke-Fake $tr -Url "v1.0/chats/$chatId/members").Json.value
        $m2 = $members | Where-Object userId -eq $u2.Id
        (Invoke-Fake $tr -Method DELETE -Url "v1.0/chats/$chatId/members/$($m2.id)").Status | Should -Be 204
        (Invoke-Fake $tr -Url "v1.0/chats/$chatId/members").Json.value.Count | Should -Be 2
        (Invoke-Fake $tr -Method DELETE -Url "v1.0/chats/$chatId/members/$($m2.id)").Status | Should -Be 404
        $add = Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/members" -Body @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u2.Id)')"; visibleHistoryStartDateTime = '2020-01-01T10:00:00Z' }
        $add.Status | Should -Be 201; $add.Json.visibleHistoryStartDateTime | Should -Be '2020-01-01T10:00:00.000Z'
        $back = (Invoke-Fake $tr -Url "v1.0/chats/$chatId/members").Json.value | Where-Object userId -eq $u2.Id
        $back.visibleHistoryStartDateTime | Should -Be '2020-01-01T10:00:00.000Z'
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$chatId/members" -Body @{ 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u2.Id)')" }).Status | Should -Be 409
        $one = $t.Chats | Where-Object { $_.TypeName -eq 'oneOnOne' } | Select-Object -First 1
        (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$($one.Id)/members" -Body @{ 'user@odata.bind' = "users('$($u2.Id)')" }).Status | Should -Be 400
        (Invoke-Fake $tr -Method DELETE -Url "v1.0/chats/$($one.Id)/members/x").Status | Should -Be 400
        # the user's chat list follows membership changes
        (Get-Pages $tr "v1.0/users/$($u2.Id)/chats").Items.id | Should -Contain $chatId
    }

    It 'channel flow: team created in migration mode, channels, root + replies, completion order' {
        $created = '2021-03-01T08:00:00Z'
        $mem = { param($u, $role = 'owner') @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @($role); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u.Id)')" } }
        $c = Invoke-Fake $tr -Method POST -Url 'v1.0/teams' -Body @{ displayName = 'Import team'; description = 'x'; '@microsoft.graph.teamCreationMode' = 'migration'; createdDateTime = $created }
        $c.Status | Should -Be 202
        $teamId = [regex]::Match($c.Headers['Content-Location'], "teams\('([^']+)'\)").Groups[1].Value
        (Invoke-Fake $tr -Url "v1.0/teams/$teamId").Json.migrationMode | Should -Be 'inProgress'
        (Invoke-Fake $tr -Method POST -Url 'v1.0/teams' -Body @{ displayName = 'x'; '@microsoft.graph.teamCreationMode' = 'migration' }).Status | Should -Be 400
        $gen = (Invoke-Fake $tr -Url "v1.0/teams/$teamId/channels").Json.value[0]
        $gen.migrationMode | Should -Be 'inProgress'
        $ch = Invoke-Fake $tr -Method POST -Url "v1.0/teams/$teamId/channels" -Body @{ displayName = 'Projets'; membershipType = 'private'; '@microsoft.graph.channelCreationMode' = 'migration'; createdDateTime = $created; members = @((& $mem $u0)) }
        $ch.Status | Should -Be 201; $ch.Json.membershipType | Should -Be 'private'; $ch.Json.migrationMode | Should -Be 'inProgress'
        (Invoke-Fake $tr -Method POST -Url "v1.0/teams/$teamId/channels" -Body @{ displayName = 'Projets' }).Status | Should -Be 409
        $base = "v1.0/teams/$teamId/channels/$($ch.Json.id)"
        $root = Invoke-Fake $tr -Method POST -Url "$base/messages" -Body @{ createdDateTime = '2021-03-02T09:00:00.250Z'; subject = 'Sujet'; from = @{ user = @{ id = $u1.Id } }; body = @{ contentType = 'html'; content = '<p>Racine</p>' } }
        $root.Status | Should -Be 201; $root.Json.subject | Should -Be 'Sujet'; $root.Json.channelIdentity.teamId | Should -Be $teamId
        $rep = Invoke-Fake $tr -Method POST -Url "$base/messages/$($root.Json.id)/replies" -Body @{ createdDateTime = '2021-03-02T09:05:00Z'; from = @{ user = @{ id = $u0.Id } }; body = @{ content = 'Réponse' } }
        $rep.Status | Should -Be 201; $rep.Json.replyToId | Should -Be $root.Json.id
        (Invoke-Fake $tr -Method POST -Url "$base/messages/$($root.Json.id)/replies" -Body @{ createdDateTime = '2021-03-02T09:00:00.250Z'; from = @{ user = @{ id = $u0.Id } }; body = @{ content = 'avant' } }).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url "$base/messages/999/replies" -Body @{ createdDateTime = '2021-03-02T09:06:00Z'; from = @{ user = @{ id = $u0.Id } }; body = @{ content = 'x' } }).Status | Should -Be 404
        (Get-Pages $tr "$base/messages").Items.Count | Should -Be 1
        (Get-Pages $tr "$base/messages/$($root.Json.id)/replies").Items.Count | Should -Be 1
        (Invoke-Fake $tr -Method POST -Url "v1.0/teams/$teamId/completeMigration").Status | Should -Be 400    # channels first
        (Invoke-Fake $tr -Method POST -Url "$base/completeMigration").Status | Should -Be 204
        (Invoke-Fake $tr -Method POST -Url "v1.0/teams/$teamId/channels/$($gen.id)/completeMigration").Status | Should -Be 204
        (Invoke-Fake $tr -Method POST -Url "v1.0/teams/$teamId/completeMigration").Status | Should -Be 204
        (Invoke-Fake $tr -Method POST -Url "$base/messages" -Body @{ createdDateTime = '2021-03-03T09:00:00Z'; from = @{ user = @{ id = $u1.Id } }; body = @{ content = 'x' } }).Status | Should -Be 403
    }

    It 'startMigration on an existing channel: date must precede its creation' {
        $team = $t.Teams[0]; $ch = $team.Channels[1]
        $url = "v1.0/teams/$($team.Id)/channels/$($ch.Id)/startMigration"
        (Invoke-Fake $tr -Method POST -Url $url -Body @{ conversationCreationDateTime = '2999-01-01T00:00:00Z' }).Status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url $url -Body @{ conversationCreationDateTime = '2000-01-01T00:00:00Z' }).Status | Should -Be 204
        (Invoke-Fake $tr -Url "v1.0/teams/$($team.Id)/channels/$($ch.Id)").Json.migrationMode | Should -Be 'inProgress'
    }
}

Describe '$batch' {
    BeforeAll {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
    }
    It 'dispatches each item with its own status and body' {
        $u = $t.Users[0]; $c = $t.Chats[0]
        $b = @{ requests = @(
                @{ id = '1'; method = 'GET'; url = "/users/$($u.Id)" },
                @{ id = '2'; method = 'GET'; url = "/chats/$($c.Id)/members" },
                @{ id = '3'; method = 'GET'; url = '/users/00000000-0000-0000-0000-000000000000' },
                @{ id = '4'; method = 'GET'; url = '/nothing' },
                @{ id = '5'; method = 'GET'; url = "/chats/$($c.Id)/messages?`$top=3" } ) }
        $r = Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body $b
        $r.Status | Should -Be 200
        $by = @{}; foreach ($x in $r.Json.responses) { $by[$x.id] = $x }
        $by['1'].status | Should -Be 200; $by['1'].body.id | Should -Be $u.Id
        $by['2'].status | Should -Be 200; $by['2'].body.value.Count | Should -Be $c.Members.Count
        $by['3'].status | Should -Be 404; $by['3'].body.error.code | Should -Be 'Request_ResourceNotFound'
        $by['4'].status | Should -Be 400
        $by['5'].body.value.Count | Should -Be 3
        $tr.Counters.Calls($EC::Batch) | Should -Be 1
        $tr.Counters.Calls($EC::Users) | Should -BeGreaterOrEqual 2
    }
    It 'refuses more than 20 requests, nested batches, duplicate ids; supports POST with a body' {
        $many = @{ requests = @(1..21 | ForEach-Object { @{ id = "$_"; method = 'GET'; url = '/users' } }) }
        (Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body $many).Status | Should -Be 400
        $twenty = @{ requests = @(1..20 | ForEach-Object { @{ id = "$_"; method = 'GET'; url = '/users' } }) }
        (Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body $twenty).Json.responses.Count | Should -Be 20
        $nested = Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body @{ requests = @(@{ id = '1'; method = 'POST'; url = '/$batch'; body = @{ requests = @() } }) }
        $nested.Json.responses[0].status | Should -Be 400
        (Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body @{ requests = @(@{ id = 'a'; method = 'GET'; url = '/users' }, @{ id = 'a'; method = 'GET'; url = '/users' }) }).Status | Should -Be 400
        $u0 = $t.Users[0]; $u1 = $t.Users[1]
        $mem = { param($u) @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u.Id)')" } }
        $post = Invoke-Fake $tr -Method POST -Url 'v1.0/$batch' -Body @{ requests = @(@{ id = 'p'; method = 'POST'; url = '/chats'; headers = @{ 'Content-Type' = 'application/json' }; body = @{ chatType = 'group'; members = @((& $mem $u0), (& $mem $u1)) } }) }
        $post.Json.responses[0].status | Should -Be 201
        $post.Json.responses[0].body.chatType | Should -Be 'group'
    }
    It 'a fault hits one item and not the others' {
        $tr2 = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        [void]$tr2.Faults.ThrottleNext($EC::Teams, 1, [TimeSpan]::FromSeconds(3), [TeamsTransfer.Testing.RetryAfterFormat]::Seconds, 0)
        $r = Invoke-Fake $tr2 -Method POST -Url 'v1.0/$batch' -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups' }, @{ id = '2'; method = 'GET'; url = '/users' }, @{ id = '3'; method = 'GET'; url = '/teams' }) }
        $r.Status | Should -Be 200
        $r.Json.responses[0].status | Should -Be 429
        $r.Json.responses[0].headers.'Retry-After' | Should -Be '3'
        $r.Json.responses[1].status | Should -Be 200
        $r.Json.responses[2].status | Should -Be 200
    }
}

Describe 'Fault injection and counters' {
    BeforeEach {
        $script:t = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(1)
        $script:tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t, 99)
    }

    It '429 with Retry-After in seconds or HTTP-date form, parsed by GraphResponse.RetryAfter' {
        [void]$tr.Faults.Throttle($EC::Users, 1.0, [TimeSpan]::FromSeconds(7), [TeamsTransfer.Testing.RetryAfterFormat]::Seconds, 0)
        $r = Invoke-Fake $tr -Url 'v1.0/users'
        $r.Status | Should -Be 429
        $r.Headers['Retry-After'] | Should -Be '7'
        $r.Response.RetryAfter.TotalSeconds | Should -Be 7
        $r.Json.error.code | Should -Be 'TooManyRequests'
        (Invoke-Fake $tr -Url "v1.0/users/$($t.Users[0].Id)").Status | Should -Be 429   # the same class: users
        (Invoke-Fake $tr -Url 'v1.0/groups').Status | Should -Be 200                    # another class
        $tr.Faults.Clear()
        [void]$tr.Faults.Throttle($EC::Users, 1.0, [TimeSpan]::FromSeconds(30), [TeamsTransfer.Testing.RetryAfterFormat]::HttpDate, 0)
        $d = Invoke-Fake $tr -Url 'v1.0/users'
        $d.Headers['Retry-After'] | Should -Match 'GMT$'
        $d.Response.RetryAfter.TotalSeconds | Should -BeGreaterThan 25
        $d.Response.RetryAfter.TotalSeconds | Should -BeLessOrEqual 31
    }

    It 'every Nth call, a burst of N, and a probability with a seed (deterministic)' {
        [void]$tr.Faults.ThrottleEveryNth($EC::Users, 3, $null, [TeamsTransfer.Testing.RetryAfterFormat]::Seconds)
        $codes = 1..9 | ForEach-Object { (Invoke-Fake $tr -Url 'v1.0/users').Status }
        $codes -join ',' | Should -Be '200,200,429,200,200,429,200,200,429'
        $tr.Faults.Clear()
        [void]$tr.Faults.ThrottleNext($EC::Users, 2, $null, [TeamsTransfer.Testing.RetryAfterFormat]::Seconds, 1)
        (1..5 | ForEach-Object { (Invoke-Fake $tr -Url 'v1.0/users').Status }) -join ',' | Should -Be '200,429,429,200,200'
        $seq = foreach ($i in 1..2) {
            $x = [TeamsTransfer.Testing.FakeGraphTransport]::new($t, 1234)
            [void]$x.Faults.Throttle($EC::Users, 0.3, $null, [TeamsTransfer.Testing.RetryAfterFormat]::Seconds, 0)
            (1..60 | ForEach-Object { (Invoke-Fake $x -Url 'v1.0/users').Status }) -join ','
        }
        $seq[0] | Should -Be $seq[1]
        ($seq[0] -split ',' | Where-Object { $_ -eq '429' }).Count | Should -BeGreaterThan 5
        $other = [TeamsTransfer.Testing.FakeGraphTransport]::new($t, 4321)
        [void]$other.Faults.Throttle($EC::Users, 0.3, $null, [TeamsTransfer.Testing.RetryAfterFormat]::Seconds, 0)
        ((1..60 | ForEach-Object { (Invoke-Fake $other -Url 'v1.0/users').Status }) -join ',') | Should -Not -Be $seq[0]
    }

    It 'simulated quota per endpoint class and for the whole app (sliding one-second window, driven by a manual clock)' {
        $clock = $tr.Faults.UseManualTime()
        $tr.Faults.SetQuota($EC::UserChats, 5)
        $u = $t.Users[0].Id
        $res = 1..7 | ForEach-Object { Invoke-Fake $tr -Url "v1.0/users/$u/chats" }
        ($res.Status) -join ',' | Should -Be '200,200,200,200,200,429,429'
        $res[5].Response.RetryAfter.TotalSeconds | Should -BeGreaterOrEqual 1
        (Invoke-Fake $tr -Url 'v1.0/users').Status | Should -Be 200            # other class unaffected
        $clock.Advance(1.01)
        (Invoke-Fake $tr -Url "v1.0/users/$u/chats").Status | Should -Be 200
        $tr.Faults.SetQuota($EC::UserChats, 0)
        $tr.Faults.SetQuota($null, 3)
        $clock.Advance(1.5)
        ((1..4 | ForEach-Object { (Invoke-Fake $tr -Url 'v1.0/groups').Status }) -join ',') | Should -Be '200,200,200,429'
        $tr.Counters.Total429 | Should -Be 3
        $tr.Counters.Throttled($EC::Teams) | Should -Be 1
    }

    It 'the import limit of 5 requests per second per conversation (other conversations unaffected)' {
        $clock = $tr.Faults.UseManualTime(); $tr.Faults.ImportLimitPerThread = 5
        $u0 = $t.Users[0]; $u1 = $t.Users[1]
        $mem = { param($u) @{ 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($u.Id)')" } }
        $ids = 1..2 | ForEach-Object { (Invoke-Fake $tr -Method POST -Url 'v1.0/chats' -Body @{ chatType = 'group'; members = @((& $mem $u0), (& $mem $u1)) }).Json.id }
        foreach ($id in $ids) { (Invoke-Fake $tr -Method POST -Url "v1.0/chats/$id/startMigration" -Body @{ conversationCreationDateTime = '2020-01-01T00:00:00Z' }).Status | Should -Be 204 }
        $send = { param($id, $n) Invoke-Fake $tr -Method POST -Url "v1.0/chats/$id/messages" -Body @{ createdDateTime = ('2020-01-02T00:00:{0:D2}.000Z' -f $n); from = @{ user = @{ id = $u0.Id } }; body = @{ content = 'x' } } }
        $first = 1..7 | ForEach-Object { (& $send $ids[0] $_).Status }
        $first -join ',' | Should -Be '201,201,201,201,201,429,429'
        (& $send $ids[1] 1).Status | Should -Be 201
        $clock.Advance(1.1)
        (& $send $ids[0] 6).Status | Should -Be 201
        $tr.Counters.Throttled($EC::ImportMessage) | Should -Be 2
    }

    It '503 / 504 bursts, forced failure on a URL, latency through an injectable delay' {
        [void]$tr.Faults.ServerErrorBurst($EC::Users, 3, 503, [TimeSpan]::FromSeconds(2), 0)
        ((1..5 | ForEach-Object { (Invoke-Fake $tr -Url 'v1.0/users').Status }) -join ',') | Should -Be '503,503,503,200,200'
        $tr.Counters.Total5xx | Should -Be 3
        $tr.Faults.Clear()
        [void]$tr.Faults.ServerErrorBurst($EC::Teams, 1, 504, $null, 0)
        $g = Invoke-Fake $tr -Url 'v1.0/groups'
        $g.Status | Should -Be 504; $g.Json.error.code | Should -Be 'GatewayTimeout'
        $tr.Faults.Clear()
        $chat = $t.Chats[0]
        [void]$tr.Faults.FailUrl('/chats/[^/]+/members', 403, 'Forbidden', 'GET', 0)
        $f = Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)/members"
        $f.Status | Should -Be 403; $f.Json.error.code | Should -Be 'Forbidden'
        (Invoke-Fake $tr -Url "v1.0/chats/$($chat.Id)").Status | Should -Be 200
        $tr.Faults.Clear()
        $clock = $tr.Faults.UseManualTime()
        [void]$tr.Faults.Latency($EC::Users, [TimeSpan]::FromMilliseconds(1500), 1.0)
        [void](Invoke-Fake $tr -Url 'v1.0/users'); [void](Invoke-Fake $tr -Url 'v1.0/users')
        $clock.Seconds | Should -Be 3
    }

    It 'connection reset throws HttpRequestException (also every Nth)' {
        [void]$tr.Faults.ResetConnections($EC::Users, 1.0, 0, 1, 0)
        $ex = try { Invoke-Fake $tr -Url 'v1.0/users'; $null } catch { $_.Exception }
        $ex | Should -Not -BeNullOrEmpty
        $ex.InnerException | Should -BeOfType ([Net.Http.HttpRequestException])
        (Invoke-Fake $tr -Url 'v1.0/users').Status | Should -Be 200     # MaxFires = 1
        $tr.Counters.ConnectionResets | Should -Be 1
        $tr.Faults.Clear()
        [void]$tr.Faults.ResetConnections($EC::Users, 1.0, 2, 0, 0)
        $out = 1..4 | ForEach-Object { try { (Invoke-Fake $tr -Url 'v1.0/users').Status } catch { 'reset' } }
        $out -join ',' | Should -Be '200,reset,200,reset'
    }

    It 'truncated downloads: IOException by default, silent short read on request; counters track bytes served' {
        $drive = $t.UserDrive($t.Users[0]); $small = $drive.Items.Values | Where-Object Name -eq 'Read-me.txt'
        $url = "v1.0/drives/$($drive.Id)/items/$($small.Id)/content"
        [void]$tr.Faults.TruncateDownloads($EC::DriveContent, 0.5, $true, 1.0, 0, 1)
        $req = [TeamsTransfer.GraphRequest]::new(); $req.Url = $url
        $resp = $tr.SendAsync($req, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $resp.Headers['Content-Length'] | Should -Be "$($small.Size)"
        $buf = [byte[]]::new(4096); $cnt = @{ n = 0 }
        { while (($n = $resp.Content.Read($buf, 0, 4096)) -gt 0) { $cnt.n += $n } } | Should -Throw
        $cnt.n | Should -Be ([int]($small.Size / 2))
        $resp.Dispose()
        $tr.Counters.TruncatedDownloads | Should -Be 1
        $tr.Faults.Clear()
        [void]$tr.Faults.TruncateDownloads($EC::DriveContent, 0.25, $false, 1.0, 0, 0)
        (Invoke-Fake $tr -Url $url).Bytes.Length | Should -Be ([int]($small.Size * 0.25))
        $tr.Faults.Clear()
        $before = $tr.Counters.BytesServed
        (Invoke-Fake $tr -Url $url).Bytes.Length | Should -Be $small.Size
        ($tr.Counters.BytesServed - $before) | Should -Be $small.Size
    }

    It 'counters: calls per endpoint class, 429 sent, snapshot, request log, reset' {
        $tr.Counters.LogEnabled = $true
        $u = $t.Users[0]
        [void](Invoke-Fake $tr -Url 'v1.0/users'); [void](Invoke-Fake $tr -Url "v1.0/users/$($u.Id)/chats"); [void](Invoke-Fake $tr -Url "v1.0/users/$($u.Id)/chats")
        [void](Invoke-Fake $tr -Url "v1.0/chats/$($t.Chats[0].Id)/messages"); [void](Invoke-Fake $tr -Url 'v1.0/groups'); [void](Invoke-Fake $tr -Url 'v1.0/nope')
        $c = $tr.Counters
        $c.Calls($EC::Users) | Should -Be 1; $c.Calls($EC::UserChats) | Should -Be 2; $c.Calls($EC::ChatMessages) | Should -Be 1
        $c.Calls($EC::Teams) | Should -Be 1; $c.Calls($EC::Other) | Should -Be 1
        $c.TotalCalls | Should -Be 6
        $c.BytesServed | Should -BeGreaterThan 1000
        $c.WithStatus(200) | Should -Be 5; $c.WithStatus(400) | Should -Be 1
        $snap = $c.Snapshot()
        $snap['calls.users.chats'] | Should -Be 2; $snap['totalCalls'] | Should -Be 6
        $c.Log.Count | Should -Be 6
        $c.Log[1].EndpointClass | Should -Be 'users.chats'; $c.Log[1].Status | Should -Be 200
        $c.Reset(); $c.TotalCalls | Should -Be 0; $c.Calls($EC::Users) | Should -Be 0
    }
}

Describe 'Volume' -Tag 'Volume' {
    It 'generates >= 1,000,000 messages and pages through one large user''s getAllMessages' -Skip:($env:TMT_VOLUME -ne '1') {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $before = [GC]::GetTotalMemory($true)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = [TeamsTransfer.Testing.SyntheticTenant]::Build([TeamsTransfer.Testing.SyntheticProfile]::Volume(1000000, 1))
        $gen = $sw.Elapsed.TotalSeconds
        $t = $r.Tenant
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $ramMb = ([GC]::GetTotalMemory($true) - $before) / 1MB
        $ws = [Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
        $r.Stats.Messages | Should -BeGreaterOrEqual 1000000

        # the largest user by number of messages
        $best = $null; $bestN = 0
        foreach ($i in 0..([Math]::Min(4, $t.Users.Count - 1))) {
            $n = 0; foreach ($c in $t.ChatsByUser[$i]) { $n += $c.Messages.Count }
            if ($n -gt $bestN) { $bestN = $n; $best = $t.Users[$i] }
        }
        $tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $sw.Restart()
        $url = "v1.0/users/$($best.Id)/chats/getAllMessages?model=B&`$top=50"
        $count = 0; $pages = 0; $prev = [long]::MaxValue; $ordered = $true
        while ($url) {
            $q = [TeamsTransfer.GraphRequest]::new(); $q.Url = $url
            $resp = $tr.SendAsync($q, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $doc = [Text.Json.JsonDocument]::Parse($resp.Content)
            $resp.Dispose()
            $pages++
            $arr = $doc.RootElement.GetProperty('value')
            $count += $arr.GetArrayLength()
            $lp = [Text.Json.JsonElement]::new()
            $url = if ($doc.RootElement.TryGetProperty([string]'@odata.nextLink', [ref]$lp)) { $lp.GetString() } else { $null }
            $doc.Dispose()
        }
        $page = $sw.Elapsed.TotalSeconds
        $count | Should -Be $bestN
        $report = "VOLUME: messages=$($r.Stats.Messages) users=$($r.Stats.Users) chats=$($r.Stats.Chats) teams=$($r.Stats.Teams) files=$($r.Stats.DriveFiles) generation=$([Math]::Round($gen,1))s heapDelta=$([Math]::Round($ramMb))MB workingSet=$([Math]::Round($ws))MB largeUserMessages=$bestN pages=$pages pagingTime=$([Math]::Round($page,1))s bytesServed=$([Math]::Round($tr.Counters.BytesServed/1MB))MB"
        Write-Host $report
        $report | Out-File -FilePath (Join-Path ([IO.Path]::GetTempPath()) 'TeamsTransfer-FakeGraph-volume.txt') -Encoding utf8
    }
}
