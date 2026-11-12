# Shared by tests\Mapping.Tests.ps1 and tests\Plan.Tests.ps1: a real TmtStore in a temp folder filled by the real exporter
# against the fake SOURCE tenant (SyntheticTenant.Tiny), and a fake TARGET tenant (a second FakeTenant) behind a GraphClient.
# Dot-source it AFTER tests\TestHelpers.ps1 (the engine and the fake are compiled together).

$script:Ct = [Threading.CancellationToken]::None

function New-FixtureClient {
    # A GraphClient over a FakeGraphTransport (request log ON: tests assert that a plan never writes). Returns Client, Fake, Counters.
    param([Parameter(Mandatory)]$Tenant)
    $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($Tenant)
    $fake.Counters.LogEnabled = $true
    $o = [TeamsTransfer.GraphClientOptions]::new()
    $o.Clock = [TeamsTransfer.TestManualClock]::new(); $o.MaxAttempts = 2
    $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(2); $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
    $client = [TeamsTransfer.GraphClient]::new($fake, $o, $null)
    [pscustomobject]@{ Client = $client; Fake = $fake; Tenant = $Tenant; Counters = $fake.Counters }
}

function New-ExportedStore {
    # Inventories and exports (chats + channels) the source tenant into a NEW store, then creates a lot over every user and the team,
    # moves it to Exported. Returns Store (open, writable), Root, Lot (name), Env (the source client).
    param([Parameter(Mandatory)]$Tenant, [Parameter(Mandatory)][string]$Root, [string]$LotName = 'wave1', [switch]$NoLotState, [string[]]$UserUpns, [int[]]$Boundaries, [datetimeoffset]$AsOf = [datetimeoffset]'2026-11-09T00:00:00Z')
    $src = New-FixtureClient -Tenant $Tenant
    $store = Open-TmtStore -Root $Root -Partitions 8
    $now = [datetimeoffset]'2026-11-09T00:00:00Z'
    $io = [TeamsTransfer.InventoryOptions]::new(); $io.Now = [Func[datetimeoffset]]{ $now }.GetNewClosure()
    [void][TeamsTransfer.Inventory]::new($src.Client, $store, $io).RunAsync($script:Ct).GetAwaiter().GetResult()
    $eo = [TeamsTransfer.ExportOptions]::new(); $eo.Now = $io.Now; $eo.IncludeChannels = $true; $eo.IncludeFiles = $true
    [void][TeamsTransfer.Exporter]::new($src.Client, $store, $eo).RunAsync($null, $script:Ct).GetAwaiter().GetResult()
    $store.Flush()
    $members = [Collections.Generic.List[TeamsTransfer.LotMember]]::new()
    $upns = if ($UserUpns) { $UserUpns } else { @($Tenant.Users | Where-Object { -not $_.External } | ForEach-Object { $_.Upn }) }
    foreach ($u in $upns) { $members.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::User, $u, 100)) }
    foreach ($t in $Tenant.Teams) { $members.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Team, $t.Id, 100)) }
    $lo = [TeamsTransfer.LotOptions]::new(); $lo.AsOfUtc = $AsOf
    if ($Boundaries) { $lo.Boundaries = [int[]]$Boundaries }
    $id = $store.CreateLot($LotName, $members.ToArray(), $lo)
    [void]$store.ResolveLot($id, $(if ($Boundaries) { 1..$Boundaries.Count } else { 1 }))
    if (-not $NoLotState) {
        [void]$store.TransitionLot($id, 'Exporting'); [void]$store.TransitionLot($id, 'Exported')
    }
    [pscustomobject]@{ Store = $store; Root = $Root; Lot = $LotName; LotId = $id; Source = $src }
}

function New-TargetTenant {
    # A second tenant whose users carry the source local parts on another domain (the domain rule), optionally a subset.
    param($SourceTenant, [string]$Domain = 'northwind.com', [string[]]$Skip = @(), [switch]$Disabled, [switch]$SameIds)
    $t = [TeamsTransfer.Testing.FakeTenant]::new(99, $Domain)
    foreach ($u in $SourceTenant.Users) {
        if ($u.Deleted -or $u.External) { continue }
        $local = ($u.Upn -split '@')[0]
        if ($local -in $Skip) { continue }
        if ($SameIds) { [void]$t.AddUser("$local@$Domain", $u.DisplayName, $false, $false, 'Member', $u.Id) }
        else { [void]$t.AddUser("$local@$Domain", $u.DisplayName) }
    }
    $t
}

function New-ServiceAccount {
    param($Tenant, [string]$Upn = 'svc-migration@northwind.com')
    $Tenant.AddUser($Upn, 'Migration service account')
}

function New-PlanRun {
    param([string]$Scenario = 'TenantToTenant', [string]$ServiceAccountId, [string]$GhostDomain, [int]$GhostThreshold = 5000, [switch]$ConfirmGhostCount)
    $r = [TeamsTransfer.ImportRunOptions]::new()
    $r.Scenario = $Scenario
    if ($ServiceAccountId) { $r.ServiceAccountUserId = $ServiceAccountId }
    if ($GhostDomain) { $r.GhostDomain = $GhostDomain }
    $r.GhostConfirmThreshold = $GhostThreshold
    $r.ConfirmGhostCount = [bool]$ConfirmGhostCount
    $r
}

function Invoke-Plan {
    param($Fixture, $Client, $Run, $PlanOptions, [int[]]$Slices = @(1))
    if (-not $PlanOptions) { $PlanOptions = [TeamsTransfer.PlanOptions]::new() }
    [TeamsTransfer.ImportPlanner]::BuildDetailedAsync($Fixture.Store, $Fixture.Lot, $Slices, $Run, $Client, $script:Ct, $PlanOptions).GetAwaiter().GetResult()
}

function Get-WriteRequests {
    # Requests that are not reads: any POST / PATCH / PUT / DELETE except the $batch envelope (a batch of reads).
    param($Counters)
    @($Counters.Log | Where-Object { $_.Method -in 'POST', 'PATCH', 'PUT', 'DELETE' -and $_.Url -notmatch '/\$batch(\?|$)' })
}
