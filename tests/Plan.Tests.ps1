#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Engine.Plan.cs (ImportPlanner, TargetMapper through the planner), TeamsTransfer.Plan.ps1 (New-TmtImportPlan) and
    Invoke-TeamsTransfer.ps1 -Mode Plan. Offline: the SOURCE is SyntheticTenant.Tiny exported by the real exporter into a real TmtStore
    (temp folder); the TARGET is a second FakeTenant (or the source tenant itself for scenarios B and C) behind a GraphClient whose request
    log proves that a plan never writes to a tenant.
    SyntheticTenant.Tiny(3): 5 users (camille, julien, sophie active; marc deleted; lea external/federated), 8 chats (4 one-on-one, 3 group,
    1 meeting), 1 team with 3 channels, 174 messages of which 3 system events and 3 deleted ones cannot be imported.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'support\PlanFixtures.ps1')
    $script:Temp = Join-Path $env:TEMP ('tmt-plan-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:Temp)
    $script:Entry = Join-Path $script:PackageRoot 'Invoke-TeamsTransfer.ps1'
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function New-Root { Join-Path $script:Temp ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    function New-Source { [TeamsTransfer.Testing.SyntheticTenant]::Tiny(3) }
    function New-Csv { param([string]$Name, [string[]]$Lines) $p = Join-Path $script:Temp $Name; [IO.File]::WriteAllText($p, ($Lines -join "`r`n") + "`r`n"); $p }
    function Get-Opts {
        param([hashtable]$Domain, [string]$OutFolder)
        $o = [TeamsTransfer.PlanOptions]::new()
        foreach ($k in $Domain.Keys) { $o.Mapping.DomainMap[$k] = $Domain[$k] }
        if ($OutFolder) { $o.OutputFolder = $OutFolder }
        $o
    }
    function Test-HtmlBalanced {
        # Tag balance of a generated page (void elements aside): the page is well formed enough for any browser and any XML-ish checker.
        param([string]$Html)
        $void = 'meta', 'br', 'hr', 'img', 'input', 'link'
        $stack = [Collections.Generic.Stack[string]]::new()
        $clean = [regex]::Replace($Html, '<!--.*?-->|<!doctype[^>]*>|<style.*?</style>', '', 'Singleline,IgnoreCase')
        foreach ($m in [regex]::Matches($clean, '<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(/?)>')) {
            $close = $m.Groups[1].Value -eq '/'; $name = $m.Groups[2].Value.ToLowerInvariant()
            if ($m.Groups[3].Value -eq '/' -or $name -in $void) { continue }
            if (-not $close) { $stack.Push($name); continue }
            if ($stack.Count -eq 0 -or $stack.Pop() -ne $name) { return "unbalanced near </$name>" }
        }
        if ($stack.Count) { return "unclosed <$($stack.Peek())>" }
        return $null
    }
    function Invoke-Entry {
        param([string[]]$Arguments, [string]$Cwd)
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        $psi.WorkingDirectory = $Cwd; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script:Entry) { $psi.ArgumentList.Add($a) }
        # a relative Output.Root is now resolved next to the package: these tests point it at the working folder
        $outCfg = Join-Path $Cwd 'out-config.psd1'
        if ((Test-Path -LiteralPath $outCfg) -and $Arguments -notcontains '-ConfigPath') { $Arguments = @($Arguments) + @('-ConfigPath', $outCfg) }
        foreach ($a in $Arguments + '-DevelopmentMode') { $psi.ArgumentList.Add([string]$a) }
        foreach ($k in 'TMT_ICONS', 'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM') { [void]$psi.Environment.Remove($k) }
        $psi.Environment['TEAMSTRANSFER_LOCAL_CONFIG'] = (Join-Path $script:Temp 'no-local-config.psd1')
        $psi.Environment['TEAMSTRANSFER_LOG_FOLDER'] = (Join-Path $Cwd 'logs')
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch { }; throw "The entry script did not finish: $($Arguments -join ' ')" }
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $e.GetAwaiter().GetResult(); Cwd = $Cwd }
    }
}

AfterAll {
    if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Plan - scenario A (tenant to tenant): CSV, domain rule, ghost, service account' {
    BeforeAll {
        $script:SrcA = New-Source
        $script:FxA = New-ExportedStore -Tenant $script:SrcA -Root (New-Root)
        $script:TgtA = New-TargetTenant -SourceTenant $script:SrcA
        $script:SvcA = New-ServiceAccount -Tenant $script:TgtA
        $script:ClA = New-FixtureClient -Tenant $script:TgtA
        $script:OutA = Join-Path $script:Temp 'planA'
        $script:RunA = New-PlanRun -ServiceAccountId $script:SvcA.Id -GhostDomain 'northwind.com'
        $script:ResA = Invoke-Plan -Fixture $script:FxA -Client $script:ClA.Client -Run $script:RunA -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' } $script:OutA)
        $script:PlanA = $script:ResA.Plan
        $script:Upn = @{}; foreach ($u in $script:SrcA.Users) { $script:Upn[$u.Id] = $u.Upn }
    }
    AfterAll { $script:FxA.Store.Dispose() }

    It 'counts conversations and messages: what is imported plus what cannot be equals what the store holds' {
        $script:PlanA.Conversations | Should -Be 11
        ($script:PlanA.Messages + $script:PlanA.MessagesSkipped) | Should -Be 174
        $script:PlanA.MessagesSkipped | Should -Be 6
        $script:ResA.SkippedByReason.Count | Should -Be 2
        @($script:ResA.SkippedByReason.GetEnumerator() | Where-Object { $_.Key -match 'system' }).Value | Should -Be 3
        @($script:ResA.SkippedByReason.GetEnumerator() | Where-Object { $_.Key -match 'deleted' }).Value | Should -Be 3
        $script:ResA.SliceStats.Count | Should -Be 1
        $script:ResA.SliceStats[0].Messages | Should -Be $script:PlanA.Messages
    }
    It 'maps every conversation: 8 new chats (meeting included), 3 new channels, nothing existing' {
        $script:PlanA.NewChats | Should -Be 8
        $script:PlanA.NewChannels | Should -Be 3
        ($script:PlanA.ExistingChats + $script:PlanA.ExistingChannels + $script:PlanA.ArchiveChannels) | Should -Be 0
        @($script:FxA.Store.ListTargets()).Count | Should -Be 11
    }
    It 'maps the identities: 3 by the domain rule, 1 ghost to create (no target id yet), 1 federated author on the service account' {
        $script:PlanA.UnresolvedIdentities | Should -Be 0
        $script:PlanA.GhostsToCreate | Should -Be 1
        $script:PlanA.ServiceAccountAuthors | Should -Be 1
        @($script:ResA.Identities | Where-Object { $_.Kind -eq 'Mapped' -and $_.Rule -eq 'domain-rule' }).Count | Should -Be 3
        $g = $script:ResA.Identities | Where-Object Kind -eq 'Ghost'
        $g.SourceUserPrincipalName | Should -Be 'marc.dubois@contoso.com'; $g.TargetUserId | Should -BeNullOrEmpty; $g.TargetDisplayName | Should -Be 'Marc Dubois (former)'
        ($script:ResA.Identities | Where-Object Kind -eq 'ServiceAccount').TargetUserId | Should -Be $script:SvcA.Id
        @($script:FxA.Store.ListIdentities()).Count | Should -Be 5
        $script:ResA.Ghosts.Count | Should -Be 1
        $script:ResA.Ghosts[0].GhostUserPrincipalName | Should -Match '^tt-ghost-[0-9a-f]{16}@northwind\.com$'
    }
    It 'writes the planned ghost into the store (the Ghosts stage input) and moves the lot to ImportPlanned' {
        $gh = @($script:FxA.Store.ListGhosts())
        $gh.Count | Should -Be 1; [string]$gh[0].State | Should -Be 'Planned'; $gh[0].UserPrincipalName | Should -Be $script:ResA.Ghosts[0].GhostUserPrincipalName
        [string]$script:FxA.Store.GetLot('wave1').State | Should -Be 'ImportPlanned'
        $chk = $script:FxA.Store.GetCheckpoint('plan:lot' + $script:FxA.LotId) | ConvertFrom-Json
        $chk.blocked | Should -BeFalse; $chk.scenario | Should -Be 'TenantToTenant'; $chk.messages | Should -Be $script:PlanA.Messages
    }
    It 'has no blocker; warns about the ghost, the service account, the meeting chat, the skipped messages and the team to create' {
        $script:PlanA.IsBlocked | Should -BeFalse
        $w = $script:PlanA.Warnings -join "`n"
        $w | Should -Match 'ghost account\(s\) will be created'
        $w | Should -Match 'fall back to the service account'
        $w | Should -Match '1 meeting chat'
        $w | Should -Match 'system events'
        $w | Should -Match 'deleted at the source'
        $w | Should -Match 'team\(s\) will be created'
        $script:ResA.MeetingChats | Should -Be 1
    }
    It 'maps a meeting chat to a NEW group chat that keeps the meeting title, with a note' {
        $t = @($script:FxA.Store.ListTargets()) | Where-Object { $_.SourceConversationKey -like 'chat:19:meeting*' }
        $t.Kind | Should -Be 'NewChat'; $t.CreateMembershipType | Should -Be 'group'; $t.CreateTopic | Should -Be 'Meeting: Office move'; $t.Note | Should -Match 'meeting chat'
    }
    It 'gives a new chat the mapped members: target ids, a ghost: placeholder for a planned ghost, the service account for a federated member' {
        $t = @($script:FxA.Store.ListTargets()) | Where-Object { $_.CreateTopic -eq 'Production incident' }
        $t.Kind | Should -Be 'NewChat'; $t.CreateMembershipType | Should -Be 'group'
        $marc = ($script:SrcA.Users | Where-Object { $_.Upn -like 'marc*' }).Id
        $t.TargetMemberIds | Should -Contain "ghost:$marc"
        $t.TargetMemberIds | Should -Contain $script:SvcA.Id
        $sophie = $script:TgtA.FindUser('sophie.bernard@northwind.com').Id
        $t.TargetMemberIds | Should -Contain $sophie
        $t.TargetMemberIds.Count | Should -Be 3
        $one = @($script:FxA.Store.ListTargets()) | Where-Object { $_.CreateMembershipType -eq 'oneOnOne' } | Select-Object -First 1
        $one.CreateTopic | Should -BeNullOrEmpty
    }
    It 'creates the missing team (one member at creation: the service account) and its standard channels, keeping the channel names' {
        $ch = @($script:FxA.Store.ListTargets([TeamsTransfer.TargetKind]::NewChannel))
        $ch.Count | Should -Be 3
        ($ch.CreateTeamName | Select-Object -Unique) | Should -Be 'Product Team'
        $ch.TargetTeamId | Where-Object { $_ } | Should -BeNullOrEmpty
        ($ch.CreateTopic | Sort-Object) | Should -Be @('Announcements', 'Engineering', 'General')
        ($ch.CreateMembershipType | Select-Object -Unique) | Should -Be 'standard'
        $ch[0].TargetMemberIds.Count | Should -Be 0
        $ch[0].Note | Should -Match 'ONE member'
        $script:ResA.TeamsToCreate['Product Team'] | Should -Be 3
    }
    It 'never writes to a tenant: only GET and $batch reads reach the target' {
        $log = $script:ClA.Counters.Log
        $log.Count | Should -BeGreaterThan 0
        (Get-WriteRequests $script:ClA.Counters).Count | Should -Be 0
        @($log | Where-Object { $_.Method -ne 'GET' -and $_.Url -notmatch '\$batch' }).Count | Should -Be 0
        $script:ClA.Counters.Calls('$batch') | Should -BeGreaterThan 0
    }
    It 'seeds the import journal at plan time: every importable message Pending, in order, once' {
        $script:ResA.JournalSeeded | Should -BeTrue
        $script:ResA.JournalRowsAdded | Should -Be $script:PlanA.Messages
        $pending = 0
        foreach ($t in $script:FxA.Store.ListTargets()) { $pending += $script:FxA.Store.GetJournalSummary($t.SourceConversationKey, 1)['Pending'] }
        $pending | Should -Be $script:PlanA.Messages
        # a second plan changes nothing: same counts, no row added, lot state kept
        $again = Invoke-Plan -Fixture $script:FxA -Client $script:ClA.Client -Run $script:RunA -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
        $again.JournalRowsAdded | Should -Be 0
        $again.Plan.Messages | Should -Be $script:PlanA.Messages
        @($script:FxA.Store.ListGhosts()).Count | Should -Be 1
        @($script:FxA.Store.ListTargets()).Count | Should -Be 11
    }
    It 'estimates the duration from 5 msg/s per conversation, the application ceiling and the parallelism' {
        # biggest conversation (39 messages) / 5 per second = 7.8 s dominates 168 messages at 75 per second
        $script:PlanA.EstimatedDuration.TotalSeconds | Should -BeGreaterThan 7.7
        $script:PlanA.EstimatedDuration.TotalSeconds | Should -BeLessThan 7.9
        $run = New-PlanRun -ServiceAccountId $script:SvcA.Id -GhostDomain 'northwind.com'; $run.ConversationParallelism = 2     # 2 x 5 = 10 msg/s
        $r = Invoke-Plan -Fixture $script:FxA -Client $script:ClA.Client -Run $run -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
        $r.Plan.EstimatedDuration.TotalSeconds | Should -BeGreaterThan ($r.Plan.Messages / 10 - 0.1)
        $po = Get-Opts @{ 'contoso.com' = 'northwind.com' }; $po.AppCeilingMessagesPerSecond = 2
        $r2 = Invoke-Plan -Fixture $script:FxA -Client $script:ClA.Client -Run $script:RunA -PlanOptions $po
        $r2.Plan.EstimatedDuration.TotalSeconds | Should -BeGreaterThan ($r2.Plan.Messages / 2 - 0.1)
    }
}

Describe 'Plan - blockers and warnings' {
    BeforeEach {
        $script:Src = New-Source
        $script:Fx = New-ExportedStore -Tenant $script:Src -Root (New-Root)
        $script:Tgt = New-TargetTenant -SourceTenant $script:Src
        $script:Svc = New-ServiceAccount -Tenant $script:Tgt
        $script:Cl = New-FixtureClient -Tenant $script:Tgt
    }
    AfterEach { $script:Fx.Store.Dispose() }

    It 'blocks on unresolved identities (no rule, no CSV, nothing in the target) and leaves the lot Exported with no ghost written' {
        $tgt = [TeamsTransfer.Testing.FakeTenant]::new(50, 'northwind.com'); $svc = $tgt.AddUser('svc@northwind.com', 'Service')
        $c = New-FixtureClient -Tenant $tgt
        $r = Invoke-Plan -Fixture $script:Fx -Client $c.Client -Run (New-PlanRun -ServiceAccountId $svc.Id -GhostDomain 'northwind.com')
        $r.Plan.IsBlocked | Should -BeTrue
        $r.Plan.UnresolvedIdentities | Should -Be 3
        ($r.Plan.Blockers -join "`n") | Should -Match '3 unresolved identities'
        [string]$script:Fx.Store.GetLot('wave1').State | Should -Be 'Exported'
        @($script:Fx.Store.ListGhosts()).Count | Should -Be 0
        @($script:Fx.Store.ListIdentities([TeamsTransfer.IdentityKind]::Unresolved)).Count | Should -Be 3
        ($script:Fx.Store.GetCheckpoint('plan:lot' + $script:Fx.LotId) | ConvertFrom-Json).blocked | Should -BeTrue
        (Get-WriteRequests $c.Counters).Count | Should -Be 0
    }
    It 'is unblocked by an identity CSV that decides them' {
        $tgt = [TeamsTransfer.Testing.FakeTenant]::new(51, 'northwind.com'); $svc = $tgt.AddUser('svc@northwind.com', 'Service')
        $rows = @('SourceUpn,TargetUpn')
        foreach ($n in 'camille.martin', 'julien.lefevre', 'sophie.bernard') { [void]$tgt.AddUser("$n.new@northwind.com", $n); $rows += "$n@contoso.com,$n.new@northwind.com" }
        $csv = New-Csv 'idmap-plan.csv' $rows
        $po = [TeamsTransfer.PlanOptions]::new(); $po.Mapping.IdentityCsvPath = $csv
        $c = New-FixtureClient -Tenant $tgt
        $r = Invoke-Plan -Fixture $script:Fx -Client $c.Client -Run (New-PlanRun -ServiceAccountId $svc.Id -GhostDomain 'northwind.com') -PlanOptions $po
        $r.Plan.IsBlocked | Should -BeFalse
        @($r.Identities | Where-Object { $_.Rule -eq 'csv' }).Count | Should -Be 3
        [string]$script:Fx.Store.GetLot('wave1').State | Should -Be 'ImportPlanned'
    }
    It 'blocks above the ghost threshold unless the count is confirmed' {
        $po = Get-Opts @{ 'contoso.com' = 'northwind.com' }
        $r = Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id -GhostDomain 'northwind.com' -GhostThreshold 0) -PlanOptions $po
        $r.Plan.GhostsToCreate | Should -Be 1
        $r.Plan.IsBlocked | Should -BeTrue
        ($r.Plan.Blockers -join "`n") | Should -Match 'above the threshold of 0'
        $r2 = Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id -GhostDomain 'northwind.com' -GhostThreshold 0 -ConfirmGhostCount) -PlanOptions $po
        $r2.Plan.IsBlocked | Should -BeFalse
        $r3 = Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id -GhostDomain 'northwind.com' -GhostThreshold 1) -PlanOptions $po
        $r3.Plan.IsBlocked | Should -BeFalse     # exactly the threshold is allowed
    }
    It 'blocks when federated authors and application messages need a service account that is not configured' {
        $r = Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -GhostDomain 'northwind.com') -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
        $r.Plan.IsBlocked | Should -BeTrue
        $r.Plan.UnresolvedIdentities | Should -Be 1       # the federated author
        $r.Plan.GhostsToCreate | Should -Be 1
        ($r.Plan.Blockers -join "`n") | Should -Match 'unresolved identit'
        ($r.Plan.Blockers -join "`n") | Should -Match 'no user author'
    }
    It 'without a ghost domain a deleted author falls back to the service account (no ghost, no blocker)' {
        $r = Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id) -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
        $r.Plan.IsBlocked | Should -BeFalse
        $r.Plan.GhostsToCreate | Should -Be 0
        $r.Plan.ServiceAccountAuthors | Should -Be 2
    }
    It 'blocks a lot that is not exported yet and plans nothing for it' {
        $fx2 = New-ExportedStore -Tenant $script:Src -Root (New-Root) -LotName 'early' -NoLotState
        try {
            $r = Invoke-Plan -Fixture $fx2 -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id -GhostDomain 'northwind.com') -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
            $r.Plan.IsBlocked | Should -BeTrue
            ($r.Plan.Blockers -join "`n") | Should -Match 'Planned: finish the export first'
            [string]$fx2.Store.GetLot('early').State | Should -Be 'Planned'
        } finally { $fx2.Store.Dispose() }
    }
    It 'refuses an unknown lot' {
        { [TeamsTransfer.ImportPlanner]::BuildDetailedAsync($script:Fx.Store, 'nope', [int[]]@(1), (New-PlanRun), $null, $script:Ct, $null).GetAwaiter().GetResult() } | Should -Throw '*No lot*'
    }
    It 'stops after the current conversation on a stop request (nothing is lost)' {
        $po = Get-Opts @{ 'contoso.com' = 'northwind.com' }
        $po.Stop = [TeamsTransfer.StopControl]::new(); $po.Stop.Request()
        { Invoke-Plan -Fixture $script:Fx -Client $script:Cl.Client -Run (New-PlanRun -ServiceAccountId $script:Svc.Id) -PlanOptions $po } | Should -Throw '*Stop requested*'
        [string]$script:Fx.Store.GetLot('wave1').State | Should -Be 'Exported'
    }
}

Describe 'Plan - slices (waves)' {
    BeforeAll {
        $script:SrcS = New-Source
        # wave 1 = from 2026-09-01 (open ended), wave 2 = 2025-10-01 .. 2026-09-01: the 3 months of data straddle the two
        $script:FxS = New-ExportedStore -Tenant $script:SrcS -Root (New-Root) -Boundaries 1, 12 -AsOf ([datetimeoffset]'2026-10-01T00:00:00Z')
        $script:TgtS = New-TargetTenant -SourceTenant $script:SrcS; $script:SvcS = New-ServiceAccount -Tenant $script:TgtS
        $script:ClS = New-FixtureClient -Tenant $script:TgtS
        $script:RunS = New-PlanRun -ServiceAccountId $script:SvcS.Id -GhostDomain 'northwind.com'
        $script:P1 = (Invoke-Plan -Fixture $script:FxS -Client $script:ClS.Client -Run $script:RunS -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' }) -Slices 1)
        $script:P2 = (Invoke-Plan -Fixture $script:FxS -Client $script:ClS.Client -Run $script:RunS -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' }) -Slices 2)
        $script:P12 = (Invoke-Plan -Fixture $script:FxS -Client $script:ClS.Client -Run $script:RunS -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' }) -Slices 1, 2)
    }
    AfterAll { $script:FxS.Store.Dispose() }

    It 'splits the messages by the createdDateTime window of each slice, without loss or overlap' {
        $script:P1.Plan.Messages | Should -BeGreaterThan 0
        $script:P2.Plan.Messages | Should -BeGreaterThan 0
        ($script:P1.Plan.Messages + $script:P2.Plan.Messages) | Should -Be $script:P12.Plan.Messages
        ($script:P12.Plan.Messages + $script:P12.Plan.MessagesSkipped) | Should -Be 174
        $script:P12.SliceStats.Count | Should -Be 2
        $script:P12.SliceStats[0].Messages | Should -Be $script:P1.Plan.Messages
        $script:P12.SliceStats[1].Messages | Should -Be $script:P2.Plan.Messages
        @($script:P12.Plan.Slices) | Should -Be @(1, 2)
    }
    It 'seeds the journal per (conversation, slice) and warns that an extension wave reopens conversations' {
        $k = $script:P2.Conversations[0].Key
        $n2 = $script:FxS.Store.GetJournalSummary($k, 2)['Pending']; $n2 | Should -BeGreaterOrEqual 0
        $total = 0; foreach ($t in $script:FxS.Store.ListTargets()) { foreach ($s in 1, 2) { $total += $script:FxS.Store.GetJournalSummary($t.SourceConversationKey, $s)['Pending'] } }
        $total | Should -Be $script:P12.Plan.Messages
        ($script:P2.Plan.Warnings -join "`n") | Should -Match 'Extension wave'
    }
    It 'refuses a slice the lot does not define' {
        { Invoke-Plan -Fixture $script:FxS -Client $script:ClS.Client -Run $script:RunS -Slices 4 } | Should -Throw '*has no slice 4*'
    }
    It 'plans an empty slice as a warning, not an error' {
        $fx = New-ExportedStore -Tenant (New-Source) -Root (New-Root) -Boundaries 24, 36 -AsOf ([datetimeoffset]'2026-11-09T00:00:00Z')
        try {
            $r = Invoke-Plan -Fixture $fx -Client $script:ClS.Client -Run $script:RunS -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' }) -Slices 2
            $r.Plan.Conversations | Should -Be 0; $r.Plan.Messages | Should -Be 0
            ($r.Plan.Warnings -join "`n") | Should -Match 'Nothing is planned'
        } finally { $fx.Store.Dispose() }
    }
}

Describe 'Plan - scenario B (restore in the same tenant)' {
    BeforeAll {
        $script:SrcB = New-Source
        $script:FxB = New-ExportedStore -Tenant $script:SrcB -Root (New-Root)
        # the target IS the source tenant. One chat disappears after the export; the service account is a live user.
        $script:Gone = $script:SrcB.Chats | Where-Object { $_.Topic -eq 'Production incident' }
        $script:GoneKey = 'chat:' + $script:Gone.Id
        [void]$script:SrcB.Chats.Remove($script:Gone); [void]$script:SrcB.ChatsById.Remove($script:Gone.Id)
        $script:SvcB = $script:SrcB.FindUser('camille.martin@contoso.com')
        $script:ClB = New-FixtureClient -Tenant $script:SrcB
        $script:RunB = New-PlanRun -Scenario SameTenantRestore -ServiceAccountId $script:SvcB.Id -GhostDomain 'contoso.com'
        $script:ResB = Invoke-Plan -Fixture $script:FxB -Client $script:ClB.Client -Run $script:RunB
        $script:PlanB = $script:ResB.Plan
    }
    AfterAll { $script:FxB.Store.Dispose() }

    It 'appends to the chats and channels that still exist and recreates the one that is gone' {
        $script:PlanB.ExistingChats | Should -Be 7
        $script:PlanB.NewChats | Should -Be 1
        $script:PlanB.ExistingChannels | Should -Be 3
        $script:PlanB.NewChannels | Should -Be 0
        $t = $script:FxB.Store.GetTarget($script:GoneKey)
        $t.Kind | Should -Be 'NewChat'; $t.CreateTopic | Should -Be 'Production incident'; $t.Note | Should -Match 'no longer exists'
        $e = @($script:FxB.Store.ListTargets([TeamsTransfer.TargetKind]::ExistingChat))[0]
        $e.TargetChatId | Should -Be ($e.SourceConversationKey -replace '^chat:', '')
        $c = @($script:FxB.Store.ListTargets([TeamsTransfer.TargetKind]::ExistingChannel))[0]
        $c.TargetTeamId | Should -Not -BeNullOrEmpty; $c.TargetChannelId | Should -Not -BeNullOrEmpty
    }
    It 'keeps the same id for live users, sends the deleted author to a ghost and the federated one to the service account' {
        @($script:ResB.Identities | Where-Object Kind -eq 'Same').Count | Should -Be 3
        @($script:ResB.Identities | Where-Object { $_.Kind -eq 'Same' -and $_.Rule -eq 'same-id' }).Count | Should -Be 3
        $script:PlanB.GhostsToCreate | Should -Be 1
        $script:PlanB.ServiceAccountAuthors | Should -Be 1
        $script:PlanB.IsBlocked | Should -BeFalse
    }
    It 'reads the target only' {
        (Get-WriteRequests $script:ClB.Counters).Count | Should -Be 0
    }
    It 'offline: assumes every chat and channel still exists, with a warning, and does not call any tenant' {
        $fx = New-ExportedStore -Tenant (New-Source) -Root (New-Root)
        try {
            $run = New-PlanRun -Scenario SameTenantRestore -ServiceAccountId '11111111-1111-1111-1111-111111111111' -GhostDomain 'contoso.com'
            $r = Invoke-Plan -Fixture $fx -Client $null -Run $run
            $r.Offline | Should -BeTrue
            $r.Plan.ExistingChats | Should -Be 8; $r.Plan.ExistingChannels | Should -Be 3
            ($r.Plan.Warnings -join "`n") | Should -Match 'Offline plan'
            $r.Plan.IsBlocked | Should -BeFalse
        } finally { $fx.Store.Dispose() }
    }
}

Describe 'Plan - scenario C (archive of departed users)' {
    BeforeAll {
        $script:SrcC = New-Source
        $script:FxC = New-ExportedStore -Tenant $script:SrcC -Root (New-Root) -UserUpns @('camille.martin@contoso.com', 'julien.lefevre@contoso.com', 'sophie.bernard@contoso.com')
        $script:SvcC = $script:SrcC.FindUser('camille.martin@contoso.com')
        $script:ClC = New-FixtureClient -Tenant $script:SrcC
        $script:RunC = New-PlanRun -Scenario DepartedArchive -ServiceAccountId $script:SvcC.Id -GhostDomain 'contoso.com'
        $poC = [TeamsTransfer.PlanOptions]::new(); $poC.Mapping.ChannelsPerArchiveTeam = 2
        $script:ResC = Invoke-Plan -Fixture $script:FxC -Client $script:ClC.Client -Run $script:RunC -PlanOptions $poC
    }
    AfterAll { $script:FxC.Store.Dispose() }

    It 'archives every conversation: one private channel per user, shared by all their conversations' {
        $script:ResC.Plan.ArchiveChannels | Should -Be 11
        ($script:ResC.Plan.NewChats + $script:ResC.Plan.NewChannels + $script:ResC.Plan.ExistingChats + $script:ResC.Plan.ExistingChannels) | Should -Be 0
        $t = @($script:FxC.Store.ListTargets([TeamsTransfer.TargetKind]::ArchiveChannel))
        $t.Count | Should -Be 11
        ($t.CreateMembershipType | Select-Object -Unique) | Should -Be 'private'
        $channels = @($t | Select-Object CreateTeamName, CreateTopic -Unique)
        $channels.Count | Should -BeGreaterOrEqual 2
        $channels.Count | Should -BeLessOrEqual 3
        foreach ($g in ($t | Group-Object { $_.CreateTeamName + '|' + $_.CreateTopic })) { @($g.Group | ForEach-Object { $_.Note -replace ';.*', '' } | Select-Object -Unique).Count | Should -Be 1 }
        $t[0].Note | Should -Match '^archive:'
    }
    It 'shards the channels over archive teams named prefix NN with at most N channels per team, owners = the service account' {
        $t = @($script:FxC.Store.ListTargets([TeamsTransfer.TargetKind]::ArchiveChannel))
        $teams = @($t | Select-Object -ExpandProperty CreateTeamName -Unique | Sort-Object)
        $teams | Should -Be @('Teams Archive 01', 'Teams Archive 02')
        foreach ($tm in $teams) { @($t | Where-Object CreateTeamName -eq $tm | Select-Object CreateTopic -Unique).Count | Should -BeLessOrEqual 2 }
        $script:ResC.ArchiveTeams.Count | Should -Be 2
        ($script:ResC.ArchiveTeams.Values | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 2
        $script:ResC.TeamsToCreate.Count | Should -Be 2
        foreach ($x in $t) { $x.TargetMemberIds | Should -Contain $script:SvcC.Id }
    }
    It 'keeps the placement of an earlier plan (a conversation never moves to another archive team)' {
        $before = @{}; foreach ($x in $script:FxC.Store.ListTargets()) { $before[$x.SourceConversationKey] = $x.CreateTeamName + '|' + $x.CreateTopic }
        $o = [TeamsTransfer.PlanOptions]::new(); $o.Mapping.ChannelsPerArchiveTeam = 2
        [void](Invoke-Plan -Fixture $script:FxC -Client $script:ClC.Client -Run $script:RunC -PlanOptions $o)
        foreach ($x in $script:FxC.Store.ListTargets()) { ($x.CreateTeamName + '|' + $x.CreateTopic) | Should -Be $before[$x.SourceConversationKey] }
    }
    It 'counts the channels already in an archive team of the target against its capacity' {
        $tgt = [TeamsTransfer.Testing.FakeTenant]::new(61, 'contoso.com')
        $svc = $tgt.AddUser('svc@contoso.com', 'Service')
        $team = $tgt.AddTeam('Teams Archive 01', [TeamsTransfer.Testing.FakeUser[]]@($svc), [datetimeoffset]'2026-01-01T00:00:00Z')
        foreach ($n in 'Old A', 'Old B') { [void]$tgt.AddChannel($team, $n, [TeamsTransfer.Testing.FakeChannelType]::Private, [TeamsTransfer.Testing.FakeUser[]]@($svc), [datetimeoffset]'2026-01-01T00:00:00Z') }
        $fx = New-ExportedStore -Tenant (New-Source) -Root (New-Root) -UserUpns @('camille.martin@contoso.com', 'julien.lefevre@contoso.com', 'sophie.bernard@contoso.com')
        try {
            $c = New-FixtureClient -Tenant $tgt
            $o = [TeamsTransfer.PlanOptions]::new(); $o.Mapping.ChannelsPerArchiveTeam = 2
            $r = Invoke-Plan -Fixture $fx -Client $c.Client -Run (New-PlanRun -Scenario DepartedArchive -ServiceAccountId $svc.Id) -PlanOptions $o
            $t = @($fx.Store.ListTargets([TeamsTransfer.TargetKind]::ArchiveChannel))
            ($t.CreateTeamName | Select-Object -Unique) | Should -Not -Contain 'Teams Archive 01'
            (Get-WriteRequests $c.Counters).Count | Should -Be 0
        } finally { $fx.Store.Dispose() }
    }
    It 'blocks without an owner, and above the Teams limit of 1000 channels per team' {
        $fx = New-ExportedStore -Tenant (New-Source) -Root (New-Root) -UserUpns @('camille.martin@contoso.com')
        try {
            $r = Invoke-Plan -Fixture $fx -Client $script:ClC.Client -Run (New-PlanRun -Scenario DepartedArchive -GhostDomain 'contoso.com')
            ($r.Plan.Blockers -join "`n") | Should -Match 'at least one owner'
            $o = [TeamsTransfer.PlanOptions]::new(); $o.Mapping.ChannelsPerArchiveTeam = 1500
            $r2 = Invoke-Plan -Fixture $fx -Client $script:ClC.Client -Run $script:RunC -PlanOptions $o
            ($r2.Plan.Blockers -join "`n") | Should -Match '1000 channels per team'
        } finally { $fx.Store.Dispose() }
    }
}

Describe 'Plan - artefacts (plan.json, CSV files, plan.html)' {
    BeforeAll {
        $script:SrcF = New-Source
        $script:FxF = New-ExportedStore -Tenant $script:SrcF -Root (New-Root)
        # hostile text in a topic: it must be escaped in the HTML and neutralised in the CSV
        $hostile = $script:FxF.Store.ListConversations() | Where-Object { $_.Topic -eq 'Office move' } | Select-Object -First 1
        $hostile.Topic = '=SUM(1+1)<script>alert(1)</script>'
        $script:FxF.Store.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($hostile))
        $script:TgtF = New-TargetTenant -SourceTenant $script:SrcF; $script:SvcF = New-ServiceAccount -Tenant $script:TgtF
        $script:ClF = New-FixtureClient -Tenant $script:TgtF
        $script:OutF = Join-Path $script:Temp 'artefacts'
        $script:ResF = Invoke-Plan -Fixture $script:FxF -Client $script:ClF.Client -Run (New-PlanRun -ServiceAccountId $script:SvcF.Id -GhostDomain 'northwind.com') -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' } $script:OutF)
    }
    AfterAll { $script:FxF.Store.Dispose() }

    It 'writes the six files' {
        foreach ($n in 'plan.json', 'plan.html', 'conversations.csv', 'identities.csv', 'ghosts.csv', 'issues.csv') { Join-Path $script:OutF $n | Should -Exist }
        $script:ResF.Folder | Should -Be $script:OutF
        $script:ResF.Files.Keys | Should -Contain 'plan.html'
    }
    It 'has the documented CSV columns and one row per conversation / identity / ghost' {
        $c = Import-Csv (Join-Path $script:OutF 'conversations.csv')
        ($c[0].PSObject.Properties.Name -join ',') | Should -Be 'SourceKey,Kind,Topic,Team,TargetKind,TargetChatId,TargetTeamId,TargetChannelId,CreateTeamName,CreateTopic,MembershipType,Messages,MessagesSkipped,FirstUtc,LastUtc,Files,FileBytes,Authors,Slices,Note'
        $c.Count | Should -Be 11
        ($c | Measure-Object -Property Messages -Sum).Sum | Should -Be $script:ResF.Plan.Messages
        $i = Import-Csv (Join-Path $script:OutF 'identities.csv')
        ($i[0].PSObject.Properties.Name -join ',') | Should -Be 'SourceUserId,SourceUpn,SourceDisplayName,Kind,TargetUserId,TargetDisplayName,Rule,Messages,Note'
        $i.Count | Should -Be 5
        $g = Import-Csv (Join-Path $script:OutF 'ghosts.csv')
        ($g[0].PSObject.Properties.Name -join ',') | Should -Be 'SourceUserId,SourceUpn,SourceDisplayName,GhostDisplayName,GhostUpn,Messages'
        $g.Count | Should -Be 1; $g[0].GhostUpn | Should -Match '^tt-ghost-'
        $x = Import-Csv (Join-Path $script:OutF 'issues.csv')
        ($x[0].PSObject.Properties.Name -join ',') | Should -Be 'Level,Message'
        @($x | Where-Object Level -eq 'Warning').Count | Should -Be $script:ResF.Plan.Warnings.Count
    }
    It 'neutralises a formula in a CSV cell' {
        $row = Import-Csv (Join-Path $script:OutF 'conversations.csv') | Where-Object { $_.Topic -like '*alert*' }
        $row.Topic | Should -Match "^'=SUM"
        (Get-Content -LiteralPath (Join-Path $script:OutF 'conversations.csv') -Raw) | Should -Not -Match '(^|,)=SUM'
    }
    It 'writes a plan.json that parses, with the plan counters and the rates' {
        $j = Get-Content -LiteralPath (Join-Path $script:OutF 'plan.json') -Raw | ConvertFrom-Json
        $j.schema | Should -Be 'plan-v1'
        $j.plan.LotName | Should -Be 'wave1'; $j.plan.Scenario | Should -Be 'TenantToTenant'
        $j.plan.Messages | Should -Be $script:ResF.Plan.Messages; $j.plan.GhostsToCreate | Should -Be 1; $j.plan.NewChats | Should -Be 8
        $j.blocked | Should -BeFalse
        $j.rates.perConversation | Should -Be 5; $j.rates.applicationCeiling | Should -Be 75
        $j.estimatedDurationSeconds | Should -BeGreaterThan 7
        $j.slices.Count | Should -Be 1
        $j.journalSeeded | Should -BeTrue
        $j.identities.Mapped | Should -Be 3
        $j.artefacts | Should -Contain 'plan.html'
    }
    It 'writes a self-contained, well-formed plan.html that escapes the data and loads nothing remote' {
        $h = Get-Content -LiteralPath (Join-Path $script:OutF 'plan.html') -Raw
        Test-HtmlBalanced $h | Should -BeNullOrEmpty
        $h | Should -Match '<title>Teams Transfer - import plan</title>'
        $h | Should -Match 'Ready to import'
        $h | Should -Match 'ghosts to create'
        $h | Should -Not -Match '<script'
        $h | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $h | Should -Not -Match '(src|href)="https?://'
        $h | Should -Not -Match '@import|<link'
    }
    It 'says Blocked in the HTML and lists the blockers when the plan is blocked' {
        $tgt = [TeamsTransfer.Testing.FakeTenant]::new(70, 'northwind.com'); $svc = $tgt.AddUser('svc@northwind.com', 'S')
        $c = New-FixtureClient -Tenant $tgt
        $out = Join-Path $script:Temp 'artefacts-blocked'
        $r = Invoke-Plan -Fixture $script:FxF -Client $c.Client -Run (New-PlanRun -ServiceAccountId $svc.Id) -PlanOptions (Get-Opts @{} $out)
        $r.Plan.IsBlocked | Should -BeTrue
        $h = Get-Content -LiteralPath (Join-Path $out 'plan.html') -Raw
        Test-HtmlBalanced $h | Should -BeNullOrEmpty
        $h | Should -Match 'Blocked: \d+ blocker'
        $h | Should -Match 'unresolved identit'
        (Import-Csv (Join-Path $out 'issues.csv') | Where-Object Level -eq 'Blocker').Count | Should -Be $r.Plan.Blockers.Count
        ((Get-Content -LiteralPath (Join-Path $out 'plan.json') -Raw | ConvertFrom-Json).blocked) | Should -BeTrue
    }
    It 'does not write any artefact without an output folder' {
        $r = Invoke-Plan -Fixture $script:FxF -Client $script:ClF.Client -Run (New-PlanRun -ServiceAccountId $script:SvcF.Id -GhostDomain 'northwind.com') -PlanOptions (Get-Opts @{ 'contoso.com' = 'northwind.com' })
        $r.Folder | Should -BeNullOrEmpty; $r.Files.Count | Should -Be 0
    }
}

Describe 'New-TmtImportPlan (PowerShell surface)' {
    BeforeAll {
        $script:SrcP = New-Source
        $script:TgtP = New-TargetTenant -SourceTenant $script:SrcP; $script:SvcP = New-ServiceAccount -Tenant $script:TgtP
        $script:ClP = New-FixtureClient -Tenant $script:TgtP
        $script:StoreP = Open-TmtStore -Root (New-Root) -Partitions 8
        $src = New-FixtureClient -Tenant $script:SrcP
        $now = [datetimeoffset]'2026-11-09T00:00:00Z'
        $io = [TeamsTransfer.InventoryOptions]::new(); $io.Now = [Func[datetimeoffset]]{ $now }.GetNewClosure()
        [void][TeamsTransfer.Inventory]::new($src.Client, $script:StoreP, $io).RunAsync($script:Ct).GetAwaiter().GetResult()
        $eo = [TeamsTransfer.ExportOptions]::new(); $eo.Now = $io.Now; $eo.IncludeChannels = $true
        [void][TeamsTransfer.Exporter]::new($src.Client, $script:StoreP, $eo).RunAsync($null, $script:Ct).GetAwaiter().GetResult()
        $script:StoreP.Flush()
    }
    AfterAll { $script:StoreP.Dispose() }

    It 'creates a lot on the fly over -Users and -Teams (by name), plans it and returns the result' {
        $r = New-TmtImportPlan -Store $script:StoreP -Users 'camille.martin@contoso.com', 'julien.lefevre@contoso.com', 'sophie.bernard@contoso.com' -Teams 'Product Team' -Client $script:ClP.Client `
            -DomainMap 'contoso.com=northwind.com' -ServiceAccount 'svc-migration@northwind.com' -GhostDomain northwind.com -OutputFolder (Join-Path $script:Temp 'fly') -IntervalSeconds 1
        $r.Created | Should -BeTrue
        $r.LotName | Should -Match '^plan-\d{8}-\d{6}$'
        $r.Plan.Conversations | Should -Be 11
        $r.Blocked | Should -BeFalse
        $r.Folder | Should -Be (Join-Path $script:Temp 'fly')
        [string]$script:StoreP.GetLot($r.LotName).State | Should -Be 'ImportPlanned'
        (Get-WriteRequests $script:ClP.Counters).Count | Should -Be 0
    }
    It 'cuts a lot created with -Window 60m in four waves (24 months, then 12 months each)' {
        $r = New-TmtImportPlan -Store $script:StoreP -Users 'camille.martin@contoso.com' -Window 60m -Slices 1, 2 -Client $script:ClP.Client -DomainMap 'contoso.com=northwind.com' -ServiceAccount 'svc-migration@northwind.com' -GhostDomain northwind.com -OutputFolder (Join-Path $script:Temp 'fly2')
        @($script:StoreP.ListSlices($script:StoreP.GetLot($r.LotName).Id)).Count | Should -Be 4
        $r.Plan.Slices | Should -Be @(1, 2)
    }
    It 'resolves the service account by UPN (read) and fails clearly when it does not exist' {
        { New-TmtImportPlan -Store $script:StoreP -Lot (@($script:StoreP.ListLots())[0].Name) -Client $script:ClP.Client -ServiceAccount 'nobody@northwind.com' -OutputFolder (Join-Path $script:Temp 'x') } | Should -Throw '*does not exist in the target tenant*'
    }
    It 'rejects wrong arguments before doing anything' {
        { New-TmtImportPlan -Store $script:StoreP -Client $script:ClP.Client } | Should -Throw '*Name the lot*'
        { New-TmtImportPlan -Store $script:StoreP -Lot nope -Client $script:ClP.Client } | Should -Throw '*not found in the store*'
        { New-TmtImportPlan -Store $script:StoreP -Lot (@($script:StoreP.ListLots())[0].Name) -Client $script:ClP.Client -DomainMap 'bad' } | Should -Throw '*expected ''source.domain=target.domain''*'
        { New-TmtImportPlan -Store $script:StoreP -Lot (@($script:StoreP.ListLots())[0].Name) -Client $script:ClP.Client -IdentityMap (Join-Path $script:Temp 'nope.csv') } | Should -Throw '*file not found*'
        { New-TmtImportPlan -Store $script:StoreP -Users x -Teams 'No such team' -Client $script:ClP.Client } | Should -Throw '*not in the inventory*'
        { New-TmtImportPlan -Store $script:StoreP -Users 'camille.martin@contoso.com' -Window 'forever' -Client $script:ClP.Client } | Should -Throw '*waves of months*'
        { New-TmtImportPlan -Store $script:StoreP -Lot (@($script:StoreP.ListLots())[0].Name) -Window 24m -Client $script:ClP.Client } | Should -Throw '*applies to a lot that is created*'
    }
    It 'offline needs the service account as an object id' {
        { New-TmtImportPlan -Store $script:StoreP -Lot (@($script:StoreP.ListLots())[0].Name) -Offline -ServiceAccount 'svc@northwind.com' } | Should -Throw '*object id*'
    }
}

Describe 'Invoke-TeamsTransfer.ps1 -Mode Plan' {
    BeforeAll {
        $script:EntryRoot = New-Root
        New-Item -ItemType Directory -Path $script:EntryRoot | Out-Null
        $fx = New-ExportedStore -Tenant (New-Source) -Root (Join-Path $script:EntryRoot 'store')
        $fx.Store.Dispose()
        $script:EntryCwd = Join-Path $script:EntryRoot 'cwd'; New-Item -ItemType Directory -Path $script:EntryCwd | Out-Null
        "@{ Output = @{ Root = '$(Join-Path $script:EntryCwd 'out')' } }" | Set-Content -LiteralPath (Join-Path $script:EntryCwd 'out-config.psd1')
        $script:StoreArg = Join-Path $script:EntryRoot 'store'
    }

    It 'exits 0 with the steps, the end card and a report folder reports\<date>_Plan (offline, same tenant)' {
        $r = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', $script:StoreArg, '-Lot', 'wave1', '-Scenario', 'SameTenantRestore', '-SkipTargetLookup', '-ServiceAccount', '11111111-1111-1111-1111-111111111111', '-GhostDomain', 'contoso.com')
        $r.ExitCode | Should -Be 0
        $t = $r.Out + $r.Err
        $t | Should -Match '1/5'; $t | Should -Match '5/5'
        $t | Should -Match 'Plan finished'
        $t | Should -Match 'exit code 0 - complete'
        $t | Should -Match '168 messages to import'
        $folder = @(Get-ChildItem (Join-Path $script:EntryCwd 'out\reports') -Directory | Where-Object Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_Plan$')
        $folder.Count | Should -Be 1
        foreach ($n in 'plan.html', 'plan.json', 'conversations.csv', 'identities.csv', 'ghosts.csv', 'issues.csv', 'TeamsTransfer_Plan.html', 'TeamsTransfer_Plan.csv', 'TeamsTransfer_Plan.json') { Join-Path $folder[0].FullName $n | Should -Exist }
        (Get-Content -LiteralPath (Join-Path $folder[0].FullName 'plan.json') -Raw | ConvertFrom-Json).blocked | Should -BeFalse
        $t | Should -Match 'Invoke-TeamsTransfer.ps1 -Mode Import'
    }
    It 'exits 3 when the plan has blockers (scenario A offline: nothing can be resolved), and says so in the card' {
        $r = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', $script:StoreArg, '-Lot', 'wave1', '-SkipTargetLookup')
        $r.ExitCode | Should -Be 3
        $t = $r.Out + $r.Err
        $t | Should -Match 'exit code 3'
        $t | Should -Match 'Blocker: \d+ unresolved identit'
        $t | Should -Match 'The plan has \d+ blocker'
        $t | Should -Match 'Plan stopped before the end'
        @(Get-ChildItem (Join-Path $script:EntryCwd 'out\reports') -Directory).Count | Should -Be 2
    }
    It 'refuses -Apply (the plan never writes to a tenant) and a missing store, with exit code 1' {
        $r = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', $script:StoreArg, '-Lot', 'wave1', '-Apply')
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'never writes'
        $r2 = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', (Join-Path $script:EntryRoot 'nostore'), '-Lot', 'wave1', '-SkipTargetLookup')
        $r2.ExitCode | Should -Be 1
        ($r2.Out + $r2.Err) | Should -Match 'No store at'
    }
    It 'rejects a plan parameter used with another mode and a plan without a lot' {
        $r = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Status', '-StoreRoot', $script:StoreArg, '-Scenario', 'SameTenantRestore')
        $r.ExitCode | Should -Be 1; ($r.Out + $r.Err) | Should -Match 'does not apply to -Mode Status'
        $r2 = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', $script:StoreArg, '-SkipTargetLookup')
        $r2.ExitCode | Should -Be 1; ($r2.Out + $r2.Err) | Should -Match 'Name the lot'
    }
    It '-WhatIf shows the plan of the run and starts nothing' {
        $r = Invoke-Entry -Cwd $script:EntryCwd -Arguments @('-Mode', 'Plan', '-StoreRoot', $script:StoreArg, '-Lot', 'wave1', '-Slices', '1,2', '-WhatIf')
        $r.ExitCode | Should -Be 0
        ($r.Out + $r.Err) | Should -Match 'WhatIf: it would plan the import of lot wave1 \(TenantToTenant, slice\(s\) 1,2\)'
    }
}
