#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Ghosts.cs (GhostProvisioner) and Invoke-TmtGhosts: against the fake Graph wrapped by GfGraphTransport (users, groups,
# $batch emulation) and a real TmtStore in a temp folder. In-memory identity map (tests\support\GhostFileTestMaps.cs).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tmt-ghosts-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:Stores = [Collections.Generic.List[object]]::new()

    function New-GhostEnv {
        param([int]$Ghosts = 3, [switch]$NoService, [int]$Threshold = 5000, [switch]$SeedGroup)
        $tenant = [TeamsTransfer.Testing.FakeTenant]::new(7, 'target.example')
        $svc = $tenant.AddUser('svc@target.example', 'Service Account')
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($tenant)
        $gf = [TeamsTransfer.Testing.GfGraphTransport]::new($fake, $tenant)
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = [TeamsTransfer.TestManualClock]::new(); $o.MaxAttempts = 3
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(4); $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $log = [TeamsTransfer.Testing.GfEventLog]::new()
        $client = [TeamsTransfer.GraphClient]::new($gf, $o, $null, [Action[TeamsTransfer.GraphEvent]]$log.OnEvent)
        $root = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $store = Open-TmtStore -Root $root -Partitions 4
        $script:Stores.Add($store)
        $map = [TeamsTransfer.Testing.GfIdentityMap]::new()
        for ($i = 1; $i -le $Ghosts; $i++) { [void]$map.Add("src-$i", "Person $i", [TeamsTransfer.IdentityKind]::Ghost) }
        $run = [TeamsTransfer.ImportRunOptions]::new()
        $run.GhostDomain = 'target.example'; $run.GhostConfirmThreshold = $Threshold
        if (-not $NoService) { $run.ServiceAccountUserId = $svc.Id }
        if ($SeedGroup) { [void]$gf.SeedGroup('TeamsTransfer - Ghost accounts') }
        [pscustomobject]@{ Tenant = $tenant; Svc = $svc; Gf = $gf; Client = $client; Log = $log; Store = $store; Root = $root; Map = $map; Run = $run }
    }

    function Invoke-Ghosts {
        param($E, [switch]$Apply, [switch]$CreateGroup, [int]$Parallelism = 1, [switch]$Remove, [string[]]$Only, [switch]$NoCheck, [string]$Usage = 'FR')
        $E.Run.Apply = [bool]$Apply
        $o = [TeamsTransfer.GhostOptions]::new()
        $o.CreateTrackingGroup = [bool]$CreateGroup; $o.Parallelism = $Parallelism; $o.UsageLocation = $Usage
        $o.GroupRetryDelay = [TimeSpan]::Zero; $o.CheckReactivated = -not $NoCheck
        $p = [TeamsTransfer.GhostProvisioner]::new($E.Client, $E.Store, $E.Map, $E.Run, $o)
        if ($Remove) { return $p.RemoveAsync([string[]]$Only, $script:ct).GetAwaiter().GetResult() }
        return $p.RunAsync($script:ct).GetAwaiter().GetResult()
    }
    function Get-StoreText($E) {
        $E.Store.Flush()
        $sb = [Text.StringBuilder]::new()
        foreach ($f in Get-ChildItem -LiteralPath $E.Root -Recurse -File -Force) {
            try { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); try { $b = [byte[]]::new($fs.Length); [void]$fs.Read($b, 0, $b.Length); [void]$sb.Append([Text.Encoding]::Latin1.GetString($b)) } finally { $fs.Dispose() } } catch { }
        }
        $sb.ToString()
    }
}

AfterAll {
    foreach ($s in $script:Stores) { try { $s.Dispose() } catch { } }
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Ghost UPN, name and password' {
    It 'derives the UPN deterministically from the source user id' {
        $a = [TeamsTransfer.GhostProvisioner]::UpnFor('11111111-2222-3333-4444-555555555555', 'target.example')
        $a | Should -Match '^tt-ghost-[0-9a-f]{16}@target\.example$'
        [TeamsTransfer.GhostProvisioner]::UpnFor('11111111-2222-3333-4444-555555555555', 'target.example') | Should -Be $a
        [TeamsTransfer.GhostProvisioner]::UpnFor('11111111-2222-3333-4444-555555555555'.ToUpperInvariant(), '@target.example') | Should -Be $a
        [TeamsTransfer.GhostProvisioner]::UpnFor('11111111-2222-3333-4444-555555555556', 'target.example') | Should -Not -Be $a
        $sha = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('abc'))
        $hex = [Convert]::ToHexString($sha).ToLowerInvariant().Substring(0, 16)
        [TeamsTransfer.GhostProvisioner]::ShortHash('ABC') | Should -Be $hex
    }
    It 'formats the display name and survives an empty name or a broken format' {
        [TeamsTransfer.GhostProvisioner]::DisplayNameFor('{0} (former)', 'Camille Martin') | Should -Be 'Camille Martin (former)'
        [TeamsTransfer.GhostProvisioner]::DisplayNameFor('{0} (left the company)', 'A B') | Should -Be 'A B (left the company)'
        [TeamsTransfer.GhostProvisioner]::DisplayNameFor('{0} (former)', '') | Should -Be 'Unknown user (former)'
        [TeamsTransfer.GhostProvisioner]::DisplayNameFor('{0', 'X') | Should -Be 'X (former)'
    }
    It 'generates passwords of 40 characters, with every class, never twice the same' {
        $set = 1..50 | ForEach-Object { [TeamsTransfer.GhostProvisioner]::GeneratePassword() }
        ($set | Select-Object -Unique).Count | Should -Be 50
        foreach ($p in $set) { $p.Length | Should -BeGreaterOrEqual 32; $p | Should -Match '[a-z]'; $p | Should -Match '[A-Z]'; $p | Should -Match '\d'; $p | Should -Match '[^a-zA-Z0-9]' }
    }
}

Describe 'Ghost creation' {
    It 'dry run: reads the target, lists exactly what would be created and writes nothing anywhere' {
        $e = New-GhostEnv -Ghosts 3
        $r = Invoke-Ghosts $e -CreateGroup
        $r.DryRun | Should -BeTrue
        $r.Candidates | Should -Be 3
        $r.ToCreate | Should -Be 3
        $r.Created | Should -Be 0
        @($r.Items | Where-Object { [string]$_.Action -eq 'Create' }).Count | Should -Be 3
        @($r.Items.UserPrincipalName | Sort-Object -Unique).Count | Should -Be 3
        $e.Gf.WriteCount | Should -Be 0
        $e.Gf.Users.Count | Should -Be 0
        $e.Gf.Groups.Count | Should -Be 0
        @($e.Store.ListGhosts()).Count | Should -Be 0
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::Ghost)) { $m.TargetUserId | Should -BeNullOrEmpty }
        $e.Map.Upserts | Should -Be 3          # only the three the test itself added
    }
    It 'creates disabled, unlicensed ghosts with the marker, a former name, a random password and the tracking group' {
        $e = New-GhostEnv -Ghosts 3
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Created | Should -Be 3
        $r.TrackingGroupCreated | Should -BeTrue
        $r.Failed | Should -Be 0
        $e.Gf.Users.Count | Should -Be 3
        foreach ($u in $e.Gf.Users) {
            $u.Enabled | Should -BeFalse
            $u.Licensed | Should -BeFalse
            $u.EmployeeType | Should -Be 'TeamsTransferGhost'
            $u.Upn | Should -Match '^tt-ghost-[0-9a-f]{16}@target\.example$'
            $u.DisplayName | Should -Match '^Person \d \(former\)$'
            $u.UsageLocation | Should -Be 'FR'
        }
        @($e.Gf.Passwords).Count | Should -Be 3
        foreach ($p in $e.Gf.Passwords) { $p.Length | Should -BeGreaterOrEqual 32 }
        $e.Gf.Groups.Count | Should -Be 1
        $e.Gf.Groups[0].DisplayName | Should -Be 'TeamsTransfer - Ghost accounts'
        $e.Gf.Groups[0].Members.Count | Should -Be 3
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::Ghost)) {
            $m.TargetUserId | Should -Not -BeNullOrEmpty
            $m.Rule | Should -Be 'ghost'
            $g = $e.Store.GetGhost($m.SourceUserId)
            [string]$g.State | Should -Be 'Created'
            $g.GhostId | Should -Be $m.TargetUserId
            $g.UserPrincipalName | Should -Be ([TeamsTransfer.GhostProvisioner]::UpnFor($m.SourceUserId, 'target.example'))
        }
        $e.Gf.Count('PATCH', '.') | Should -Be 0     # never enables, never licenses
        $e.Gf.Count('POST', 'assignLicense') | Should -Be 0
    }
    It 'is idempotent: a second run creates nothing and sends no write' {
        $e = New-GhostEnv -Ghosts 4
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        $e.Gf.ClearLog()
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Candidates | Should -Be 0
        $r.Created | Should -Be 0
        $e.Gf.WriteCount | Should -Be 0
        $e.Gf.Users.Count | Should -Be 4
    }
    It 'finds the ghost under its deterministic UPN when the catalog lost it (an interrupted run), without creating a second account' {
        $e = New-GhostEnv -Ghosts 2
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        $ids = @($e.Map.List([TeamsTransfer.IdentityKind]::Ghost) | ForEach-Object { $_.TargetUserId })
        # the mapping and the catalog are gone, the accounts are not
        $e2 = New-GhostEnv -Ghosts 2
        foreach ($u in $e.Gf.Users) { [void]$e2.Gf.SeedUser($u.Upn, $u.DisplayName, $false, 'TeamsTransferGhost', $u.Id) }
        [void]$e2.Gf.SeedGroup('TeamsTransfer - Ghost accounts')
        $r = Invoke-Ghosts $e2 -Apply
        $r.Created | Should -Be 0
        $r.LinkedExisting | Should -Be 2
        $e2.Gf.Count('POST', '^users$') | Should -Be 0
        @($e2.Map.List([TeamsTransfer.IdentityKind]::Ghost) | ForEach-Object { $_.TargetUserId } | Sort-Object) | Should -Be @($ids | Sort-Object)
        $e2.Gf.Groups[0].Members.Count | Should -Be 2
    }
    It 'completes the mapping from the catalog without any network write' {
        $e = New-GhostEnv -Ghosts 2
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::Ghost)) { $m.TargetUserId = $null; $e.Map.Upsert($m) }
        $e.Gf.ClearLog()
        $r = Invoke-Ghosts $e -Apply
        $r.Created | Should -Be 0
        $r.LinkedExisting | Should -Be 2
        $e.Gf.WriteCount | Should -Be 0
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::Ghost)) { $m.TargetUserId | Should -Not -BeNullOrEmpty }
    }
    It 'never adopts an existing account that is not a ghost' {
        $e = New-GhostEnv -Ghosts 1
        $upn = [TeamsTransfer.GhostProvisioner]::UpnFor('src-1', 'target.example')
        $real = $e.Gf.SeedUser($upn, 'A real colleague', $true, 'Employee')
        [void]$e.Gf.SeedGroup('TeamsTransfer - Ghost accounts')
        $r = Invoke-Ghosts $e -Apply
        $r.Created | Should -Be 0
        $r.Refused | Should -Be 1
        [string]$r.Items[0].Action | Should -Be 'Refused'
        $e.Map.Get('src-1').TargetUserId | Should -BeNullOrEmpty
        $e.Gf.UserById($real.Id).Enabled | Should -BeTrue
        $e.Gf.Groups[0].Members.Count | Should -Be 0
    }
    It 'creates only the missing ones when some already exist' {
        $e = New-GhostEnv -Ghosts 3
        [void]$e.Gf.SeedUser([TeamsTransfer.GhostProvisioner]::UpnFor('src-2', 'target.example'), 'Person 2 (former)', $false, 'TeamsTransferGhost')
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Created | Should -Be 2
        $r.LinkedExisting | Should -Be 1
        $e.Gf.Users.Count | Should -Be 3
    }
    It 'retries a transient 5xx on the creation and a directory replication delay on the group, and still creates once' {
        $e = New-GhostEnv -Ghosts 2
        $e.Gf.TransientCreateFailures = 1
        $e.Gf.MembershipLag = 2
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Created | Should -Be 2
        $r.GroupMembershipFailed | Should -Be 0
        $e.Gf.Users.Count | Should -Be 2
        $e.Gf.Groups[0].Members.Count | Should -Be 2
    }
    It 'reports a group membership that could not be completed and finishes it on the next run' {
        $e = New-GhostEnv -Ghosts 1
        $e.Gf.MembershipLag = 50
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Created | Should -Be 1
        $r.GroupMembershipFailed | Should -Be 1
        $r.Warnings.Count | Should -BeGreaterThan 0
    }
    It 'scales: 400 ghosts are looked up in $batch calls, created once, and a rerun is free' {
        $e = New-GhostEnv -Ghosts 400
        $r = Invoke-Ghosts $e -Apply -CreateGroup -Parallelism 8
        $r.Created | Should -Be 400
        $e.Gf.Users.Count | Should -Be 400
        @($e.Gf.Users.Upn | Sort-Object -Unique).Count | Should -Be 400
        $e.Gf.Count('BATCH', '.') | Should -BeGreaterOrEqual 20
        $e.Gf.Groups[0].Members.Count | Should -Be 400
        $e.Gf.ClearLog()
        $r2 = Invoke-Ghosts $e -Apply -Parallelism 8
        $r2.Created | Should -Be 0
        $e.Gf.WriteCount | Should -Be 0
    }
}

Describe 'Blockers' {
    It 'blocks above the threshold, writes nothing even with -Apply, and goes ahead once the count is confirmed' {
        $e = New-GhostEnv -Ghosts 3 -Threshold 2
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.IsBlocked | Should -BeTrue
        ($r.Blockers -join ' ') | Should -Match 'threshold'
        $r.Created | Should -Be 0
        $e.Gf.WriteCount | Should -Be 0
        $e.Run.ConfirmGhostCount = $true
        $r2 = Invoke-Ghosts $e -Apply -CreateGroup
        $r2.IsBlocked | Should -BeFalse
        $r2.Created | Should -Be 3
    }
    It 'blocks when the tracking group is missing and the tool may not create it; uses an existing one without creating' {
        $e = New-GhostEnv -Ghosts 2
        $r = Invoke-Ghosts $e -Apply
        $r.IsBlocked | Should -BeTrue
        ($r.Blockers -join ' ') | Should -Match 'tracking group'
        $e.Gf.WriteCount | Should -Be 0
        [void]$e.Gf.SeedGroup('TeamsTransfer - Ghost accounts')
        $r2 = Invoke-Ghosts $e -Apply
        $r2.IsBlocked | Should -BeFalse
        $r2.Created | Should -Be 2
        $e.Gf.Count('POST', '^groups$') | Should -Be 0
    }
    It 'blocks when no ghost domain is configured' {
        $e = New-GhostEnv -Ghosts 1
        $e.Run.GhostDomain = ''
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.IsBlocked | Should -BeTrue
        ($r.Blockers -join ' ') | Should -Match 'GhostDomain'
        $e.Gf.WriteCount | Should -Be 0
    }
}

Describe 'Creation refused (403): fallback to the service account' {
    It 'maps each identity to the service account with a clear message, and stops asking after the first refusal' {
        $e = New-GhostEnv -Ghosts 3
        $e.Gf.RefuseUserCreation = $true
        $r = Invoke-Ghosts $e -Apply -CreateGroup -Parallelism 1
        $r.Created | Should -Be 0
        $r.FallbackToServiceAccount | Should -Be 3
        ($r.Warnings -join ' ') | Should -Match 'User\.ReadWrite\.All'
        $e.Gf.Count('POST', '^users$') | Should -Be 1
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::ServiceAccount)) { $m.TargetUserId | Should -Be $e.Svc.Id; $m.Note | Should -Match '403' }
        @($e.Map.List([TeamsTransfer.IdentityKind]::ServiceAccount)).Count | Should -Be 3
        @($e.Map.List([TeamsTransfer.IdentityKind]::Ghost)).Count | Should -Be 0
    }
    It 'reports the identities as failed (and leaves them untouched) when no service account is configured' {
        $e = New-GhostEnv -Ghosts 2 -NoService
        $e.Gf.RefuseUserCreation = $true
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.FallbackToServiceAccount | Should -Be 0
        $r.Failed | Should -Be 2
        ($r.Errors | ForEach-Object Message) -join ' ' | Should -Match 'service account'
        @($e.Map.List([TeamsTransfer.IdentityKind]::Ghost)).Count | Should -Be 2
    }
}

Describe 'Reactivated ghosts' {
    It 'reports a ghost found enabled under its UPN and still maps it, without ever changing the account' {
        $e = New-GhostEnv -Ghosts 1
        $u = $e.Gf.SeedUser([TeamsTransfer.GhostProvisioner]::UpnFor('src-1', 'target.example'), 'Person 1 (former)', $true, 'TeamsTransferGhost')
        [void]$e.Gf.SeedGroup('TeamsTransfer - Ghost accounts')
        $r = Invoke-Ghosts $e -Apply
        $r.Reactivated | Should -Be 1
        $r.ReactivatedGhosts.Count | Should -Be 1
        [string]$e.Store.GetGhost('src-1').State | Should -Be 'Reactivated'
        $e.Map.Get('src-1').TargetUserId | Should -Be $u.Id
        $e.Gf.UserById($u.Id).Enabled | Should -BeTrue
        $e.Gf.Count('PATCH', '.') | Should -Be 0
    }
    It 'detects a created ghost that somebody enabled afterwards, on the next run, and records it' {
        $e = New-GhostEnv -Ghosts 2
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        $victim = $e.Gf.Users[0]
        $victim.Enabled = $true
        $r = Invoke-Ghosts $e -Apply
        $r.Reactivated | Should -Be 1
        $r.ReactivatedGhosts[0].GhostId | Should -Be $victim.Id
        [string]($e.Store.ListGhosts() | Where-Object GhostId -eq $victim.Id).State | Should -Be 'Reactivated'
        $r.Created | Should -Be 0
        # disabled again by the operator: the next run clears the state
        $victim.Enabled = $false
        $r3 = Invoke-Ghosts $e -Apply
        $r3.Reactivated | Should -Be 0
        [string]($e.Store.ListGhosts() | Where-Object GhostId -eq $victim.Id).State | Should -Be 'Created'
    }
    It 'a dry run reports the reactivated ghosts but records nothing' {
        $e = New-GhostEnv -Ghosts 1
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        $e.Gf.Users[0].Enabled = $true
        $r = Invoke-Ghosts $e
        $r.Reactivated | Should -Be 1
        [string]$e.Store.ListGhosts()[0].State | Should -Be 'Created'
    }
}

Describe 'The password never leaks' {
    It 'is in no event, result, error, warning, catalog file or exception' {
        $e = New-GhostEnv -Ghosts 6
        $e.Gf.TransientCreateFailures = 2
        $e.Gf.MembershipLag = 1
        $r = Invoke-Ghosts $e -Apply -CreateGroup -Parallelism 3
        $r.Created | Should -Be 6
        $pwds = @($e.Gf.Passwords)
        $pwds.Count | Should -BeGreaterOrEqual 6
        $text = $e.Log.Text + "`n" + ($r | ConvertTo-Json -Depth 6) + "`n" + ($r.Errors | Out-String) + "`n" + ($r.Warnings -join "`n") + "`n" + (Get-StoreText $e)
        $text += "`n" + (($e.Map.List([TeamsTransfer.IdentityKind]::Ghost) | ConvertTo-Json -Depth 4))
        $text += "`n" + (($e.Store.ListGhosts() | ConvertTo-Json -Depth 4))
        $e.Log.Count | Should -BeGreaterThan 0
        foreach ($p in $pwds) { $text.Contains($p) | Should -BeFalse }
    }
    It 'is not in the error of a failed creation either' {
        $e = New-GhostEnv -Ghosts 2
        $e.Gf.TransientCreateFailures = 50      # more than the retries: the creation fails
        $r = Invoke-Ghosts $e -Apply -CreateGroup
        $r.Failed | Should -Be 2
        $r.Created | Should -Be 0
        $text = $e.Log.Text + "`n" + ($r | ConvertTo-Json -Depth 6) + "`n" + (Get-StoreText $e) + "`n" + ($e.Store.ListGhosts() | ConvertTo-Json -Depth 4)
        foreach ($p in @($e.Gf.Passwords)) { $text.Contains($p) | Should -BeFalse }
        foreach ($g in $e.Store.ListGhosts()) { [string]$g.State | Should -Be 'Failed' }
    }
}

Describe 'Remove (lab cleanup)' {
    It 'previews, then deletes only the ghosts of the catalog, and refuses an account that is not a ghost' {
        $e = New-GhostEnv -Ghosts 3
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        # a catalog entry that points to a real, non-ghost account must be refused
        $real = $e.Gf.SeedUser('real.person@target.example', 'Real Person', $true, 'Employee')
        $e.Store.UpsertGhost([TeamsTransfer.GhostRecord]@{ SourceUserId = 'src-evil'; GhostId = $real.Id; DisplayName = 'Real'; UserPrincipalName = 'real.person@target.example'; State = [TeamsTransfer.GhostState]::Created })
        $e.Gf.ClearLog()
        $dry = Invoke-Ghosts $e -Remove -NoCheck
        $dry.DryRun | Should -BeTrue
        @($dry.Items | Where-Object { [string]$_.Action -eq 'Remove' }).Count | Should -Be 3
        $dry.Refused | Should -Be 1
        $e.Gf.WriteCount | Should -Be 0
        $r = Invoke-Ghosts $e -Apply -Remove -NoCheck
        $r.Removed | Should -Be 3
        $r.Refused | Should -Be 1
        @($e.Gf.Users | Where-Object { -not $_.Deleted }).Count | Should -Be 1
        $e.Gf.UserById($real.Id).Deleted | Should -BeFalse
        @($e.Store.ListGhosts([TeamsTransfer.GhostState]::Deleted)).Count | Should -Be 3
        foreach ($m in $e.Map.List([TeamsTransfer.IdentityKind]::Ghost)) { $m.TargetUserId | Should -BeNullOrEmpty }
    }
    It 'limits the removal to the source users asked for' {
        $e = New-GhostEnv -Ghosts 3
        [void](Invoke-Ghosts $e -Apply -CreateGroup)
        $r = Invoke-Ghosts $e -Apply -Remove -Only 'src-2' -NoCheck
        $r.Removed | Should -Be 1
        @($e.Gf.Users | Where-Object { -not $_.Deleted }).Count | Should -Be 2
    }
}

Describe 'Invoke-TmtGhosts' {
    It 'previews by default, writes ghosts.csv without any password, and applies with -Apply' {
        $e = New-GhostEnv -Ghosts 3
        $folder = Join-Path $script:TempRoot 'report-ghosts'
        $r = Invoke-TmtGhosts -Store $e.Store -Client $e.Client -Run $e.Run -IdentityMap $e.Map -ReportFolder $folder -CreateTrackingGroup
        $r.DryRun | Should -BeTrue
        $e.Gf.WriteCount | Should -Be 0
        $csv = Import-Csv -LiteralPath (Join-Path $folder 'ghosts.csv')
        @($csv).Count | Should -Be 3
        $csv[0].Action | Should -Be 'Create'
        $r2 = Invoke-TmtGhosts -Store $e.Store -Client $e.Client -Run $e.Run -IdentityMap $e.Map -Apply -CreateTrackingGroup -UsageLocation FR -ReportFolder $folder
        $r2.DryRun | Should -BeFalse
        $r2.Created | Should -Be 3
        $text = Get-Content -LiteralPath (Join-Path $folder 'ghosts.csv') -Raw
        foreach ($p in @($e.Gf.Passwords)) { $text.Contains($p) | Should -BeFalse }
        (Import-Csv -LiteralPath (Join-Path $folder 'ghosts.csv') | Where-Object Action -eq 'Created').Count | Should -Be 3
    }
    It 'uses the real store as the identity map' {
        $e = New-GhostEnv -Ghosts 0
        foreach ($i in 1..2) {
            $m = [TeamsTransfer.IdentityMapping]@{ SourceUserId = "real-$i"; SourceDisplayName = "Real $i"; Kind = [TeamsTransfer.IdentityKind]::Ghost }
            $e.Store.UpsertIdentity($m)
        }
        $r = Invoke-TmtGhosts -Store $e.Store -Client $e.Client -Run $e.Run -Apply -CreateTrackingGroup
        $r.Created | Should -Be 2
        foreach ($m in $e.Store.ListIdentities([TeamsTransfer.IdentityKind]::Ghost)) { $m.TargetUserId | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Lot lifecycle: Ghosts' {
    It 'moves an ImportPlanned lot to Ghosts after a clean apply, and leaves it alone otherwise' {
        $e = New-GhostEnv -Ghosts 2
        $s = $e.Store
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@([TeamsTransfer.ConversationRecord]@{ Key = 'chat:c1'; Kind = [TeamsTransfer.ConversationKind]::Group; ChatId = 'c1'; CreatedUtc = [datetimeoffset]::UtcNow.AddYears(-1); LastActivityUtc = [datetimeoffset]::UtcNow }))
        $m = [Collections.Generic.List[TeamsTransfer.LotMember]]::new(); $m.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, 'chat:c1'))
        $id = $s.CreateLot('lot-g', $m, [TeamsTransfer.LotOptions]::new())
        [void]$s.ResolveLot($id, [int[]]@(1))
        foreach ($st in 'Exporting', 'Exported', 'ImportPlanned') { [void]$s.TransitionLot($id, [TeamsTransfer.LotState]$st, 'test') }
        # a preview never moves it
        [void](Invoke-TmtGhosts -Store $s -Client $e.Client -Run $e.Run -IdentityMap $e.Map -CreateTrackingGroup -Lot 'lot-g' -AdvanceLot)
        [string]$s.GetLot($id).State | Should -Be 'ImportPlanned'
        $r = Invoke-TmtGhosts -Store $s -Client $e.Client -Run $e.Run -IdentityMap $e.Map -CreateTrackingGroup -Apply -Lot 'lot-g' -AdvanceLot
        $r.Created | Should -Be 2
        [string]$s.GetLot($id).State | Should -Be 'Ghosts'
        # a second apply (lot already past the stage) is not an error and moves nothing
        [void](Invoke-TmtGhosts -Store $s -Client $e.Client -Run $e.Run -IdentityMap $e.Map -Apply -Lot 'lot-g' -AdvanceLot)
        [string]$s.GetLot($id).State | Should -Be 'Ghosts'
    }
}
