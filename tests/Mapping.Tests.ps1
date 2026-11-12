#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Engine.CatalogImport.cs (identity_map / target_map / file_copy_map in catalog.db) and Engine.Mapping.cs (CSV reader,
    TargetDirectory look-ups, IdentityMapper). Offline: the target tenant is a second FakeTenant behind a GraphClient; the store is a real
    TmtStore in a temp folder. The conversation mapping (TargetMapper) is exercised through the planner in Plan.Tests.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'support\PlanFixtures.ps1')
    $script:Temp = Join-Path $env:TEMP ('tmt-mapping-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:Temp)

    function New-TestStore { Open-TmtStore -Root (Join-Path $script:Temp ([guid]::NewGuid().ToString('N').Substring(0, 8))) -Partitions 4 }
    function New-Src {
        param([string]$Id, [string]$Upn, [string]$Name = $null, [string]$State = 'Active', [string]$Type = $null, [string]$Mail = $null)
        $s = [TeamsTransfer.SourceIdentity]::new()
        $s.Id = $Id; $s.UserPrincipalName = $Upn; $s.DisplayName = $(if ($Name) { $Name } else { $Id }); $s.State = $State; $s.Mail = $Mail
        if ($Type) { $s.IdentityType = $Type }
        $s
    }
    function New-Mapper {
        param($Store, $Run, $Options, $Client)
        if (-not $Options) { $Options = [TeamsTransfer.MappingOptions]::new() }
        [TeamsTransfer.IdentityMapper]::new($Store, $Run, $Options, [TeamsTransfer.TargetDirectory]::new($Client))
    }
    function Resolve-Ids {
        param($Mapper, [TeamsTransfer.SourceIdentity[]]$Sources, [string]$Scenario = 'TenantToTenant')
        @($Mapper.ResolveAsync($Sources, [TeamsTransfer.ImportScenario]$Scenario, $script:Ct).GetAwaiter().GetResult())
    }
    function New-Csv { param([string]$Name, [string[]]$Lines) $p = Join-Path $script:Temp $Name; [IO.File]::WriteAllText($p, ($Lines -join "`r`n") + "`r`n"); $p }
}

AfterAll {
    if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Catalog persistence of the import maps (Engine.CatalogImport.cs)' {
    It 'creates the three tables and their indexes idempotently, also after a reopen' {
        $root = Join-Path $script:Temp 'persist'
        $s = Open-TmtStore -Root $root -Partitions 4
        try { $s.EnsureImportSchema() | Should -BeTrue; $s.EnsureImportSchema() | Should -BeTrue; $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'u1'; Kind = 'Same' }) } finally { $s.Dispose() }
        $s = Open-TmtStore -Root $root -Partitions 4
        try { $s.EnsureImportSchema() | Should -BeTrue; $s.GetIdentity('u1').Kind | Should -Be 'Same' } finally { $s.Dispose() }
        $c = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$root\catalog.db;Mode=ReadOnly;Pooling=False")
        $c.Open()
        try {
            $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT name FROM sqlite_master WHERE name IN ('identity_map','target_map','file_copy_map','ix_idmap_kind','ix_idmap_target','ix_target_kind','ix_target_state','ix_target_archive','ix_fcm_state','ix_fcm_sha')"
            $r = $cmd.ExecuteReader(); $names = @(); while ($r.Read()) { $names += $r.GetString(0) }; $r.Dispose()
            $names.Count | Should -Be 10
        } finally { $c.Dispose() }
    }
    It 'round-trips identity mappings and lists them by kind' {
        $s = New-TestStore
        try {
            $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'a'; SourceDisplayName = 'Ana'; SourceUserPrincipalName = 'ana@x.com'; Kind = 'Mapped'; TargetUserId = 't-a'; TargetDisplayName = 'Ana T'; Rule = 'csv'; Note = 'n' })
            $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'b'; Kind = 'Ghost'; Rule = 'ghost' })
            $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'c'; Kind = 'Unresolved' })
            $a = $s.GetIdentity('a')
            $a.SourceDisplayName | Should -Be 'Ana'; $a.SourceUserPrincipalName | Should -Be 'ana@x.com'; $a.TargetUserId | Should -Be 't-a'; $a.Rule | Should -Be 'csv'; $a.Note | Should -Be 'n'
            $s.GetIdentity('b').TargetUserId | Should -BeNullOrEmpty
            $s.GetIdentity('nope') | Should -BeNullOrEmpty
            @($s.ListIdentities()).Count | Should -Be 3
            @($s.ListIdentities([TeamsTransfer.IdentityKind]::Ghost)).SourceUserId | Should -Be 'b'
            $sum = $s.GetIdentitySummary(); $sum['Mapped'] | Should -Be 1; $sum['Unresolved'] | Should -Be 1; $sum['Same'] | Should -Be 0
            # Upsert replaces the row
            $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'c'; Kind = 'Same'; TargetUserId = 'c' })
            $s.GetIdentity('c').Kind | Should -Be 'Same'
            @($s.ListIdentities()).Count | Should -Be 3
        } finally { $s.Dispose() }
    }
    It 'is reachable through the three interfaces (the contract of the Importer, the Ghosts and the Verify stages)' {
        $s = New-TestStore
        try {
            $s -is [TeamsTransfer.IIdentityMap] | Should -BeTrue
            $s -is [TeamsTransfer.ITargetMap] | Should -BeTrue
            $s -is [TeamsTransfer.IFileCopyMap] | Should -BeTrue
            # the interface members are explicit implementations: call them through the interface types (reflection)
            $call = { param([type]$t, [string]$m, $o, [object[]]$a) $t.GetMethod($m).Invoke($o, $a) }
            [void](& $call ([TeamsTransfer.IIdentityMap]) 'Upsert' $s @([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'x'; Kind = 'Same' }))
            (& $call ([TeamsTransfer.IIdentityMap]) 'Get' $s @('x')).Kind | Should -Be 'Same'
            [void](& $call ([TeamsTransfer.ITargetMap]) 'Upsert' $s @([TeamsTransfer.TargetMapping]@{ SourceConversationKey = 'chat:1'; Kind = 'NewChat' }))
            (& $call ([TeamsTransfer.ITargetMap]) 'Get' $s @('chat:1')).Kind | Should -Be 'NewChat'
            [void](& $call ([TeamsTransfer.IFileCopyMap]) 'Upsert' $s @([TeamsTransfer.FileCopyRecord]@{ ConversationKey = 'chat:1'; MessageId = 'm'; AttachmentId = 'a' }))
            (& $call ([TeamsTransfer.IFileCopyMap]) 'Get' $s @('chat:1', 'm', 'a')).State | Should -Be 'Pending'
            @(& $call ([TeamsTransfer.IIdentityMap]) 'List' $s @($null)).Count | Should -Be 1
        } finally { $s.Dispose() }
    }
    It 'round-trips target mappings (members, state), lists by kind and state, and updates the state' {
        $s = New-TestStore
        try {
            $t = [TeamsTransfer.TargetMapping]::new(); $t.SourceConversationKey = 'chat:1'; $t.Kind = 'NewChat'; $t.CreateTopic = 'Topic é'; $t.CreateMembershipType = 'group'
            $t.TargetMemberIds.AddRange([string[]]@('m1', 'ghost:g1')); $t.Note = 'note'
            $c = [TeamsTransfer.TargetMapping]@{ SourceConversationKey = 'channel:t/c'; Kind = 'ArchiveChannel'; CreateTeamName = 'Teams Archive 01'; CreateTopic = 'Ana'; CreateMembershipType = 'private' }
            $s.UpsertTargets([TeamsTransfer.TargetMapping[]]@($t, $c))
            $g = $s.GetTarget('chat:1')
            $g.CreateTopic | Should -Be 'Topic é'; $g.TargetMemberIds | Should -Be @('m1', 'ghost:g1'); $g.State | Should -Be 'Planned'; $g.Note | Should -Be 'note'
            @($s.ListTargets()).Count | Should -Be 2
            @($s.ListTargets([TeamsTransfer.TargetKind]::ArchiveChannel)).SourceConversationKey | Should -Be 'channel:t/c'
            $s.SetTargetState('chat:1', 'Created', 'chat-id-9')
            $g = $s.GetTarget('chat:1'); $g.State | Should -Be 'Created'; $g.TargetChatId | Should -Be 'chat-id-9'; $g.CreateTopic | Should -Be 'Topic é'
            @($s.ListTargets($null, [TeamsTransfer.TargetState]::Created)).Count | Should -Be 1
            { $s.SetTargetState('chat:none', 'Failed') } | Should -Throw '*No target mapping*'
        } finally { $s.Dispose() }
    }
    It 'round-trips file-copy records, lists by conversation and state, finds an uploaded copy by SHA-256' {
        $s = New-TestStore
        try {
            $rec = {
                param($conv, $msg, $att, $state, $sha)
                [TeamsTransfer.FileCopyRecord]@{ ConversationKey = $conv; MessageId = $msg; AttachmentId = $att; State = $state; Sha256 = $sha; Name = "$att.docx"; TargetDriveId = 'd'; TargetItemId = "i-$att"; TargetWebUrl = "https://x/$att" }
            }
            $s.UpsertFileCopies([TeamsTransfer.FileCopyRecord[]]@((& $rec 'chat:1' 'm1' 'a1' 'Pending' 'aa'), (& $rec 'chat:1' 'm2' 'a2' 'Uploaded' 'bb'), (& $rec 'chat:2' 'm3' 'a3' 'Failed' 'cc')))
            @($s.ListFileCopies()).Count | Should -Be 3
            @($s.ListFileCopies('chat:1')).Count | Should -Be 2
            @($s.ListFileCopies($null, [TeamsTransfer.FileCopyState]::Failed)).AttachmentId | Should -Be 'a3'
            $s.GetFileCopy('chat:1', 'm2', 'a2').TargetWebUrl | Should -Be 'https://x/a2'
            $s.FindUploadedBySha256('bb').AttachmentId | Should -Be 'a2'
            $s.FindUploadedBySha256('aa') | Should -BeNullOrEmpty          # Pending: nothing uploaded yet
            $s.UpsertFileCopy((& $rec 'chat:1' 'm1' 'a1' 'Shared' 'aa'))
            $s.FindUploadedBySha256('aa').State | Should -Be 'Shared'
            @($s.ListFileCopies()).Count | Should -Be 3
        } finally { $s.Dispose() }
    }
    It 'upserts 20,000 identities in one transaction in a few seconds' {
        $s = New-TestStore
        try {
            $list = [Collections.Generic.List[TeamsTransfer.IdentityMapping]]::new()
            1..20000 | ForEach-Object { $list.Add([TeamsTransfer.IdentityMapping]@{ SourceUserId = "user-$_"; SourceUserPrincipalName = "u$_@contoso.com"; Kind = 'Mapped'; TargetUserId = "t-$_"; Rule = 'domain-rule' }) }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $s.UpsertIdentities($list)
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
            $s.GetIdentitySummary()['Mapped'] | Should -Be 20000
            $s.GetIdentity('user-19999').TargetUserId | Should -Be 't-19999'
        } finally { $s.Dispose() }
    }
    It 'reads nothing and never creates tables from a store opened read-only (older catalog without the maps)' {
        $root = Join-Path $script:Temp 'ro'
        $s = Open-TmtStore -Root $root -Partitions 4; $s.Dispose()       # no map method was called: the tables do not exist
        $ro = Open-TmtStore -Root $root -ReadOnly
        try {
            $ro.EnsureImportSchema() | Should -BeFalse
            @($ro.ListIdentities()).Count | Should -Be 0
            $ro.GetIdentity('x') | Should -BeNullOrEmpty
            @($ro.ListTargets()).Count | Should -Be 0
            { $ro.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'x'; Kind = 'Same' }) } | Should -Throw '*read-only*'
        } finally { $ro.Dispose() }
    }
}

Describe 'CSV reader (MapCsv)' {
    It 'reads quotes, doubled quotes, embedded line breaks, a BOM and the semicolon delimiter' {
        $p = Join-Path $script:Temp 'q.csv'
        [IO.File]::WriteAllText($p, "`u{FEFF}SourceUpn;TargetUpn`r`n`"a;b@x.com`";`"say `"`"hi`"`"`"`r`nc@x.com;d@y.com`r`n`r`n", [Text.UTF8Encoding]::new($false))
        $rows = [TeamsTransfer.MapCsv]::Read($p)
        $rows.Count | Should -Be 2
        $rows[0]['SourceUpn'] | Should -Be 'a;b@x.com'
        $rows[0]['targetupn'] | Should -Be 'say "hi"'            # header look-up is case-insensitive
        $rows[1]['TargetUpn'] | Should -Be 'd@y.com'
        ([TeamsTransfer.MapCsv]::Parse("a,b`r`n`"x`ny`",2")).Count | Should -Be 2
    }
    It 'quotes a cell and neutralises a formula (CSV injection)' {
        [TeamsTransfer.MapCsv]::Quote('a,b') | Should -Be '"a,b"'
        [TeamsTransfer.MapCsv]::Quote('say "x"') | Should -Be '"say ""x"""'
        [TeamsTransfer.MapCsv]::Quote('=HYPERLINK("http://evil")') | Should -Match "^`"?'="
        [TeamsTransfer.MapCsv]::Quote('-5') | Should -Be '-5'
        [TeamsTransfer.MapCsv]::Line('a', $null, 3) | Should -Be 'a,,3'
    }
    It 'refuses a missing file' {
        { [TeamsTransfer.MapCsv]::Read((Join-Path $script:Temp 'nope.csv')) } | Should -Throw '*not found*'
    }
}

Describe 'Ghost UPN and channel names' {
    It 'derives a stable tt-ghost-<hash>@domain UPN per source id' {
        $a = [TeamsTransfer.IdentityMapper]::GhostUpn('3EF277F7-FCAA-4816-BCE9-E2A62CE56173', 'contoso.com')
        $a | Should -Be ([TeamsTransfer.GhostProvisioner]::UpnFor('3EF277F7-FCAA-4816-BCE9-E2A62CE56173', 'contoso.com'))   # the plan announces the account the Ghosts stage creates
        $a | Should -Match '^tt-ghost-[0-9a-f]{16}@contoso\.com$'
        [TeamsTransfer.IdentityMapper]::GhostUpn('3ef277f7-fcaa-4816-bce9-e2a62ce56173', '@contoso.com') | Should -Be $a    # case-insensitive id, leading @ tolerated
        [TeamsTransfer.IdentityMapper]::GhostUpn('another', 'contoso.com') | Should -Not -Be $a
        [TeamsTransfer.IdentityMapper]::GhostUpn('x', '') | Should -BeNullOrEmpty
    }
    It 'sanitises a channel name to the Teams rules' {
        [TeamsTransfer.TargetMapper]::SanitizeChannelName('Q&A: plans / 2026?') | Should -Be 'Q A plans 2026'
        [TeamsTransfer.TargetMapper]::SanitizeChannelName('_hidden.') | Should -Be 'hidden'
        [TeamsTransfer.TargetMapper]::SanitizeChannelName('x' * 80).Length | Should -Be 50
        [TeamsTransfer.TargetMapper]::SanitizeChannelName('***') | Should -Be 'Channel'
    }
}

Describe 'IdentityMapper - scenario A (tenant to tenant)' {
    BeforeEach {
        $script:Src = [TeamsTransfer.Testing.FakeTenant]::new(7, 'contoso.com')
        $script:Tgt = [TeamsTransfer.Testing.FakeTenant]::new(8, 'northwind.com')
        $script:Svc = $script:Tgt.AddUser('svc@northwind.com', 'Service account')
        $script:Cl = New-FixtureClient -Tenant $script:Tgt
        $script:Store = New-TestStore
        $script:Run = New-PlanRun -ServiceAccountId $script:Svc.Id -GhostDomain 'northwind.com'
    }
    AfterEach { $script:Store.Dispose() }

    It 'maps by CSV on the source UPN, on the source id with a target id, and by target UPN' {
        $ana = $script:Tgt.AddUser('ana.t@northwind.com', 'Ana T'); $bob = $script:Tgt.AddUser('bob.t@northwind.com', 'Bob T')
        $csv = New-Csv 'ids.csv' @('SourceUpn,SourceId,TargetUpn,TargetId', 'ana@contoso.com,,ana.t@northwind.com,', (',src-bob,,' + $bob.Id))
        $o = [TeamsTransfer.MappingOptions]::new(); $o.IdentityCsvPath = $csv
        $m = New-Mapper $script:Store $script:Run $o $script:Cl.Client
        $r = Resolve-Ids $m @((New-Src 'src-ana' 'ana@contoso.com' 'Ana'), (New-Src 'src-bob' 'bob@contoso.com' 'Bob'))
        $r[0].Kind | Should -Be 'Mapped'; $r[0].TargetUserId | Should -Be $ana.Id; $r[0].Rule | Should -Be 'csv'; $r[0].TargetDisplayName | Should -Be 'Ana T'
        $r[1].Kind | Should -Be 'Mapped'; $r[1].TargetUserId | Should -Be $bob.Id; $r[1].Rule | Should -Be 'csv'
    }
    It 'leaves a CSV row whose target does not exist Unresolved (a blocker, never a guess)' {
        $csv = New-Csv 'ids2.csv' @('SourceUpn,TargetUpn', 'ana@contoso.com,ghostly@northwind.com')
        $o = [TeamsTransfer.MappingOptions]::new(); $o.IdentityCsvPath = $csv; $o.DomainMap['contoso.com'] = 'northwind.com'
        $script:Tgt.AddUser('ana@northwind.com', 'Ana (would match the domain rule)') | Out-Null
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $o $script:Cl.Client) @((New-Src 'src-ana' 'ana@contoso.com'))
        $r[0].Kind | Should -Be 'Unresolved'; $r[0].Note | Should -Match 'does not exist'
    }
    It 'applies the domain rule (UPN first, then mail) and falls back to the same UPN' {
        $a = $script:Tgt.AddUser('ana@northwind.com', 'Ana'); $same = $script:Tgt.AddUser('carl@contoso.com', 'Carl same UPN')
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DomainMap['contoso.com'] = 'northwind.com'
        $m = New-Mapper $script:Store $script:Run $o $script:Cl.Client
        $r = Resolve-Ids $m @((New-Src 'src-ana' 'ana@contoso.com'), (New-Src 'src-carl' 'carl@contoso.com'), (New-Src 'src-dan' 'dan@contoso.com'))
        $r[0].Kind | Should -Be 'Mapped'; $r[0].Rule | Should -Be 'domain-rule'; $r[0].TargetUserId | Should -Be $a.Id
        $r[1].Kind | Should -Be 'Mapped'; $r[1].Rule | Should -Be 'upn-match'; $r[1].TargetUserId | Should -Be $same.Id
        $r[2].Kind | Should -Be 'Unresolved'; $r[2].Note | Should -Match 'dan@northwind.com'
    }
    It 'matches on the mail address when the UPN differs (domain rule on the mail)' {
        $u = $script:Tgt.AddUser('e.martin@northwind.com', 'Eve Martin'); $u.Mail = 'eve@northwind.com'
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DomainMap['contoso.com'] = 'northwind.com'
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $o $script:Cl.Client) @((New-Src 'src-eve' 'eve.m@contoso.com' 'Eve' -Mail 'eve@contoso.com'))
        $r[0].Kind | Should -Be 'Mapped'; $r[0].TargetUserId | Should -Be $u.Id
    }
    It 'does not guess when MatchBySameUpn is off and there is no rule' {
        $script:Tgt.AddUser('carl@contoso.com', 'Carl') | Out-Null
        $o = [TeamsTransfer.MappingOptions]::new(); $o.MatchBySameUpn = $false
        (Resolve-Ids (New-Mapper $script:Store $script:Run $o $script:Cl.Client) @((New-Src 'src-carl' 'carl@contoso.com')))[0].Kind | Should -Be 'Unresolved'
    }
    It 'sends a deleted author to a ghost (planned: no target id yet) when a ghost domain is set' {
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $null $script:Cl.Client) @((New-Src 'src-marc' 'marc@contoso.com' 'Marc Dubois' 'Deleted'))
        $r[0].Kind | Should -Be 'Ghost'; $r[0].TargetUserId | Should -BeNullOrEmpty; $r[0].TargetDisplayName | Should -Be 'Marc Dubois (former)'
        $r[0].Rule | Should -Be 'ghost'; $r[0].Note | Should -Match ([regex]::Escape([TeamsTransfer.IdentityMapper]::GhostUpn('src-marc', 'northwind.com')))
    }
    It 'falls back to the service account for a deleted author without a ghost domain, or when the policy says so' {
        $run = New-PlanRun -ServiceAccountId $script:Svc.Id
        $r = Resolve-Ids (New-Mapper $script:Store $run $null $script:Cl.Client) @((New-Src 'm' 'marc@contoso.com' 'Marc' 'Deleted'))
        $r[0].Kind | Should -Be 'ServiceAccount'; $r[0].TargetUserId | Should -Be $script:Svc.Id
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DeletedAuthors = 'ServiceAccount'
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $o $script:Cl.Client) @((New-Src 'm' 'marc@contoso.com' 'Marc' 'Deleted'))
        $r[0].Kind | Should -Be 'ServiceAccount'
    }
    It 'leaves a deleted author Unresolved when neither a ghost domain nor a service account exists, or the Ghost policy has no domain' {
        $r = Resolve-Ids (New-Mapper $script:Store (New-PlanRun) $null $script:Cl.Client) @((New-Src 'm' 'marc@contoso.com' 'Marc' 'Deleted'))
        $r[0].Kind | Should -Be 'Unresolved'; $r[0].Note | Should -Match 'service account'
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DeletedAuthors = 'Ghost'
        $r = Resolve-Ids (New-Mapper $script:Store (New-PlanRun -ServiceAccountId $script:Svc.Id) $o $script:Cl.Client) @((New-Src 'm' 'marc@contoso.com' 'Marc' 'Deleted'))
        $r[0].Kind | Should -Be 'Unresolved'; $r[0].Note | Should -Match 'ghost domain'
    }
    It 'sends a federated or external author to the service account (its content cannot be imported as that person)' {
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $null $script:Cl.Client) @((New-Src 'f1' 'lea@fabrikam.com' 'Lea' 'External'), (New-Src 'f2' $null 'Fed' 'Active' 'federatedUser'))
        $r.Kind | Should -Be @('ServiceAccount', 'ServiceAccount'); $r[0].Rule | Should -Be 'service-account'; $r[0].TargetUserId | Should -Be $script:Svc.Id
        $r2 = Resolve-Ids (New-Mapper $script:Store (New-PlanRun) $null $script:Cl.Client) @((New-Src 'f1' 'lea@fabrikam.com' 'Lea' 'External'))
        $r2[0].Kind | Should -Be 'Unresolved'
    }
    It 'stores every decision in the identity map and keeps manual decisions and created ghosts on a second run' {
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DomainMap['contoso.com'] = 'northwind.com'
        $script:Tgt.AddUser('ana@northwind.com', 'Ana') | Out-Null
        $script:Store.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'src-x'; Kind = 'Mapped'; TargetUserId = 'chosen'; Rule = 'manual' })
        $script:Store.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'src-g'; Kind = 'Ghost'; TargetUserId = 'ghost-created'; Rule = 'ghost' })
        $m = New-Mapper $script:Store $script:Run $o $script:Cl.Client
        $srcs = @((New-Src 'src-ana' 'ana@contoso.com'), (New-Src 'src-x' 'x@contoso.com'), (New-Src 'src-g' 'g@contoso.com' 'G' 'Deleted'))
        $r = Resolve-Ids $m $srcs
        $r[1].TargetUserId | Should -Be 'chosen'; $r[2].TargetUserId | Should -Be 'ghost-created'
        @($script:Store.ListIdentities()).Count | Should -Be 3
        $script:Store.GetIdentity('src-ana').Kind | Should -Be 'Mapped'
        (Resolve-Ids $m $srcs)[0].Kind | Should -Be 'Mapped'     # idempotent
        @($script:Store.ListIdentities()).Count | Should -Be 3
    }
    It 'batches the look-ups with $batch (20 per call) and sends reads only' {
        1..45 | ForEach-Object { $script:Tgt.AddUser("user$_@northwind.com", "User $_") | Out-Null }
        $o = [TeamsTransfer.MappingOptions]::new(); $o.DomainMap['contoso.com'] = 'northwind.com'
        $srcs = [TeamsTransfer.SourceIdentity[]]@(1..45 | ForEach-Object { New-Src "s$_" "user$_@contoso.com" })
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $o $script:Cl.Client) $srcs
        @($r | Where-Object Kind -eq 'Mapped').Count | Should -Be 45
        $script:Cl.Counters.Calls('$batch') | Should -BeGreaterThan 2
        $script:Cl.Counters.Calls('$batch') | Should -BeLessThan 12     # ~90 sub-requests in chunks of 20: far fewer calls than users
        (Get-WriteRequests $script:Cl.Counters).Count | Should -Be 0
    }
}

Describe 'IdentityMapper - scenarios B and C (same tenant)' {
    BeforeEach {
        $script:Tgt = [TeamsTransfer.Testing.FakeTenant]::new(9, 'contoso.com')
        $script:Svc = $script:Tgt.AddUser('svc@contoso.com', 'Service account')
        $script:Cl = New-FixtureClient -Tenant $script:Tgt
        $script:Store = New-TestStore
        $script:Run = New-PlanRun -Scenario SameTenantRestore -ServiceAccountId $script:Svc.Id -GhostDomain 'contoso.com'
    }
    AfterEach { $script:Store.Dispose() }

    It 'keeps the same id when the user still exists; a guest is a valid author' {
        $ana = $script:Tgt.AddUser('ana@contoso.com', 'Ana'); $gst = $script:Tgt.AddUser('guest_x#EXT#@contoso.com', 'Guest X', $false, $false, 'Guest')
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $null $script:Cl.Client) @((New-Src $ana.Id 'ana@contoso.com'), (New-Src $gst.Id 'guest_x#EXT#@contoso.com' 'Guest X' 'Guest')) SameTenantRestore
        $r[0].Kind | Should -Be 'Same'; $r[0].TargetUserId | Should -Be $ana.Id; $r[0].Rule | Should -Be 'same-id'
        $r[1].Kind | Should -Be 'Same'; $r[1].Note | Should -Match 'guest'
    }
    It 'finds a recreated account by UPN (old object id -> new)' {
        $new = $script:Tgt.AddUser('ana@contoso.com', 'Ana')
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $null $script:Cl.Client) @((New-Src 'old-object-id' 'ana@contoso.com')) SameTenantRestore
        $r[0].Kind | Should -Be 'Mapped'; $r[0].Rule | Should -Be 'upn-match'; $r[0].TargetUserId | Should -Be $new.Id
        $r[0].Note | Should -Match 'recreated'
    }
    It 'sends a user that is gone to a ghost; a user marked Deleted in the store is also looked up by UPN first' {
        $new = $script:Tgt.AddUser('back@contoso.com', 'Back')
        $r = Resolve-Ids (New-Mapper $script:Store $script:Run $null $script:Cl.Client) @((New-Src 'gone-id' 'gone@contoso.com' 'Gone' 'Active'), (New-Src 'del-id' 'back@contoso.com' 'Back' 'Deleted'), (New-Src 'del2' 'nobody@contoso.com' 'Nobody' 'Deleted')) SameTenantRestore
        $r[0].Kind | Should -Be 'Ghost'; $r[0].Note | Should -Match 'no longer in the tenant'
        $r[1].Kind | Should -Be 'Mapped'; $r[1].TargetUserId | Should -Be $new.Id
        $r[2].Kind | Should -Be 'Ghost'
    }
    It 'scenario C resolves like B (the departed author is deleted: ghost or service account)' {
        $r = Resolve-Ids (New-Mapper $script:Store (New-PlanRun -Scenario DepartedArchive -ServiceAccountId $script:Svc.Id) $null $script:Cl.Client) @((New-Src 'dep' 'dep@contoso.com' 'Departed' 'Deleted')) DepartedArchive
        $r[0].Kind | Should -Be 'ServiceAccount'
    }
    It 'offline: same-id is assumed for a live user, a deleted one is a ghost, scenario A stays unresolved, a CSV target id is trusted' {
        $off = [TeamsTransfer.TargetDirectory]::new($null)
        $m = [TeamsTransfer.IdentityMapper]::new($script:Store, $script:Run, [TeamsTransfer.MappingOptions]::new(), $off)
        $r = Resolve-Ids $m @((New-Src 'u1' 'u1@contoso.com'), (New-Src 'u2' 'u2@contoso.com' 'U2' 'Deleted')) SameTenantRestore
        $r[0].Kind | Should -Be 'Same'; $r[0].Note | Should -Match 'offline'; $r[1].Kind | Should -Be 'Ghost'
        $r = Resolve-Ids $m @((New-Src 'u1' 'u1@contoso.com')) TenantToTenant
        $r[0].Kind | Should -Be 'Unresolved'; $r[0].Note | Should -Match 'offline'
        $o = [TeamsTransfer.MappingOptions]::new(); $o.IdentityCsvPath = (New-Csv 'off.csv' @('SourceUpn,TargetId', 'u1@contoso.com,11111111-1111-1111-1111-111111111111'))
        $m2 = [TeamsTransfer.IdentityMapper]::new($script:Store, $script:Run, $o, $off)
        $r = Resolve-Ids $m2 @((New-Src 'u1' 'u1@contoso.com')) TenantToTenant
        $r[0].Kind | Should -Be 'Mapped'; $r[0].TargetUserId | Should -Be '11111111-1111-1111-1111-111111111111'
    }
}
