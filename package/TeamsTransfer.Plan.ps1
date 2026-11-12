# TeamsTransfer - thin PowerShell surface over the C# mapping / plan engine.
# Dot-sourced by TeamsTransfer.psm1. All the logic lives in package\src\Engine.Mapping.cs, Engine.Plan.cs and Engine.CatalogImport.cs; this
# file builds the options, creates a lot on the fly when asked, runs the async planner, shows a text progress line every -IntervalSeconds by
# POLLING (Wait-TmtEngineTask, TeamsTransfer.Export.ps1) and returns the engine's result. The plan never writes to a tenant: the target is read
# only (users, teams, channels, chats); what it writes is local (identity / target maps, import journal, plan folder, lot state).

function script:ConvertTo-TmtDomainMap {
    # 'src.com=dst.com' (one or more) -> ordered dictionary src -> dst. A bad item is an error, never silently ignored.
    param([string[]]$DomainMap)
    $map = [ordered]@{}
    foreach ($item in @($DomainMap | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($item -notmatch '^\s*([^=\s]+)\s*=\s*([^=\s]+)\s*$') { throw "-DomainMap '$item': expected 'source.domain=target.domain'." }
        $map[$Matches[1].TrimStart('@')] = $Matches[2].TrimStart('@')
    }
    return $map
}

function ConvertTo-TmtWindowBoundaries {
    <#
    .SYNOPSIS
        Waves of a lot from -Window Nm (1 <= N <= 600): 24m gives 24; 60m gives 24, 36, 48, 60 (24 months, then 12 months each).
    .PARAMETER Window
        Nm only (a lot is cut in waves of months).
    #>
    # -Window for a lot created on the fly: '24m' -> 24; '60m' -> 24,36,48,60 (the waves: 24 months, then 12 months each).
    param([string]$Window)
    # A lot is cut in waves of months: Nm only (a date range <from>..<to> has no waves, it applies to Export and Archive).
    $expected = "expected Nm with N from 1 to 600 (the last N months, for example 24m or 60m; a lot is cut in waves of months, so a <from>..<to> date range is not accepted here)"
    if ($Window -notmatch '^(\d{1,6})m$') { throw "-Window '$Window': $expected." }
    $n = [int]$Matches[1]
    if ($n -lt 1 -or $n -gt 600) { throw "-Window '$Window': $expected." }
    if ($n -le 24) { return @($n) }
    $b = [Collections.Generic.List[int]]::new(); $b.Add(24)
    for ($m = 36; $m -lt $n; $m += 12) { $b.Add($m) }
    $b.Add($n)
    return $b.ToArray()
}

function New-TmtImportPlan {
    <#
    .SYNOPSIS
        Builds the dry-run import plan of a lot: conversations, messages, identities (mapped, ghost, service account, unresolved), target
        conversations, files, ghosts, blockers, estimated duration. Writes plan.json, conversations.csv, identities.csv, ghosts.csv,
        issues.csv and plan.html to a folder. Nothing is written to any tenant.
    .DESCRIPTION
        Read-only on the target tenant (it resolves users, teams, channels and chats through $batch). Local effects: the identity and target
        maps and the import journal (seeded here, so Import only reads it) in the store, the ghost table, the lot state Exported -> ImportPlanned
        (only when the plan has no blocker), and the plan folder. A plan with a blocker (unresolved identity, ghost count above the threshold,
        no service account where one is needed, lot not exported) cannot be imported: fix it and plan again.
        The lot is an existing one (-Lot) or is created on the fly over what the store already holds (-Users and / or -Teams, -Window).
        -Offline plans without reading the target tenant: CSV targets given as ids are trusted, other users stay unresolved (scenario A) or
        are assumed to exist (scenarios B and C).
    .PARAMETER Store
        An open writable TeamsTransfer.TmtStore (Open-TmtStore).
    .PARAMETER Lot
        Name of a lot of the store. Alone: an existing lot. With -Users / -Teams / -LotFile: the lot is created with that name when it does
        not exist (and planned), used as it is when it exists with the same members, and refused when it exists with different members.
        Without -Lot, -Users / -Teams / -LotFile create a lot with an automatic name (plan-yyyyMMdd-HHmmss).
    .PARAMETER Users
        Create a lot: users (ids / UPNs, or a CSV). Combine with -Teams / -LotFile.
    .PARAMETER Teams
        Create a lot: teams (ids / exact display names, or a CSV).
    .PARAMETER LotFile
        Create a lot: CSV with the columns Type (User | Team | Chat | Channel), Identity and Priority (optional, lower runs first, default 100).
    .PARAMETER Window
        Lot that is created: Nm with N from 1 to 600 (the last N months, for example 24m or 60m), cut in waves of 24 months, then 12 months each.
        Default 24m. A <from>..<to> date range is not accepted here (a lot is cut in waves of months).
    .PARAMETER Slices
        The waves to plan: 1 = the last 24 months, 2 = 25-36, 3 = 37-48, 4 = 49-60 (default 1).
    .PARAMETER Scenario
        TenantToTenant (A), SameTenantRestore (B) or DepartedArchive (C).
    .PARAMETER IdentityMap
        CSV: SourceUpn and / or SourceId, TargetUpn and / or TargetId.
    .PARAMETER TeamMap
        CSV: SourceTeamId and / or SourceTeam (name), TargetTeamId and / or TargetTeam (name).
    .PARAMETER DomainMap
        'source.com=target.com' (one or more): a user a@source.com is looked up as a@target.com in the target tenant.
    .PARAMETER ServiceAccount
        UPN or object id of the service account: fallback author and owner of the created teams.
    .PARAMETER GhostDomain
        Domain of the ghost accounts (tt-ghost-<hash>@domain). Without it, deleted authors fall back to the service account.
    .PARAMETER DeletedAuthors
        Auto (ghost when -GhostDomain is set, else service account), Ghost or ServiceAccount.
    .PARAMETER ConfirmGhostCount
        Accept a ghost count above the threshold (-GhostThreshold, default 5000).
    .PARAMETER ArchiveOwners
        Scenario C: owners of the archive channels (UPNs or ids); the service account is added.
    .PARAMETER ArchiveTeamPrefix
        Scenario C: archive teams are named '<prefix> NN' (default 'Teams Archive').
    .PARAMETER ChannelsPerArchiveTeam
        Scenario C: channels per archive team (1 to 1000, default 200; Teams allows 1000 including deleted channels).
    .PARAMETER OutputFolder
        Folder of the plan files (default: a plan-<lot> folder under the store).
    .PARAMETER Client
        A Graph client of the TARGET tenant (New-TmtGraphClient -Side Target). Alternative: -Configuration, or -Offline.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Target side is used to build the client.
    .PARAMETER Offline
        Do not read the target tenant.
    .PARAMETER StopFile
        When this file exists the plan stops after the current conversation (nothing is lost, run it again).
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        PSCustomObject: Result (TeamsTransfer.PlanResult), Plan (TeamsTransfer.ImportPlan), Folder, Blocked, LotName, Created (the lot was created by this call).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store,
        [string]$Lot,
        [object]$Users,
        [object]$Teams,
        [string]$LotFile,
        [string]$Window,
        [ValidateRange(1, 4)][int[]]$Slices = @(1),
        [ValidateSet('TenantToTenant', 'SameTenantRestore', 'DepartedArchive')][string]$Scenario = 'TenantToTenant',
        [string]$IdentityMap,
        [string]$TeamMap,
        [string[]]$DomainMap,
        [string]$ServiceAccount,
        [string]$GhostDomain,
        # Display name format of the ghosts ({0} = source display name); the entry script passes Ghosts.DisplayNameFormat of the
        # configuration so that the plan announces the name the Ghosts stage creates.
        [string]$GhostDisplayNameFormat,
        [ValidateSet('Auto', 'Ghost', 'ServiceAccount')][string]$DeletedAuthors = 'Auto',
        [switch]$ConfirmGhostCount,
        [ValidateRange(1, 1000000)][int]$GhostThreshold = 5000,
        [string[]]$ArchiveOwners,
        [string]$ArchiveTeamPrefix = 'Teams Archive',
        [ValidateRange(1, 1000)][int]$ChannelsPerArchiveTeam = 200,
        [ValidateRange(1, 100000)][double]$AppCeiling = 75,
        [string]$OutputFolder,
        $Client,
        [hashtable]$Configuration,
        [switch]$Offline,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $selection = [bool]($Users -or $Teams -or $LotFile)
    if (-not $Lot -and -not $selection) { throw 'Name the lot to plan (-Lot), or give the users / teams / lot file to plan (-Users / -Teams / -LotFile).' }
    if ($Lot -and $Window -and -not $selection) { throw '-Window applies to a lot that is created (-Users / -Teams / -LotFile, with or without -Lot <name>); the waves of an existing lot are chosen with -Slices.' }
    if ($IdentityMap -and -not (Test-Path -LiteralPath $IdentityMap -PathType Leaf)) { throw "-IdentityMap: file not found: $IdentityMap" }
    if ($TeamMap -and -not (Test-Path -LiteralPath $TeamMap -PathType Leaf)) { throw "-TeamMap: file not found: $TeamMap" }
    $domains = ConvertTo-TmtDomainMap $DomainMap

    $created = $false
    $lotName = $Lot
    # A lot created on the fly belongs to this run: if the run throws before the lot reaches ImportPlanned, the lot is cancelled (its conversations are
    # released, an audit row stays) so that the next Plan does not find them 'already covered by another lot'. A lot given with -Lot is never cancelled here.
    try {
    if ($selection) {
        # A lot over -Users / -Teams / -LotFile: named (-Lot <name>: created when it does not exist, refused when it exists with other members)
        # or, without -Lot, with an automatic name.
        $members = Get-TmtLotMembers -Store $Store -Users $Users -Teams $Teams -LotFile $LotFile
        $bounds = [int[]](ConvertTo-TmtWindowBoundaries $(if ($Window) { $Window } else { '24m' }))
        $lotName = if ($Lot) { $Lot } else { 'plan-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) }
        if (-not $Lot) {
            # an automatic name is never reused: two plans in the same second get plan-...-2, -3
            $base = $lotName; $n = 1
            while ($null -ne $Store.GetLot($lotName)) { $n++; $lotName = "$base-$n" }
        }
        $made = Initialize-TmtLot -Store $Store -Name $lotName -Members $members -Boundaries $bounds -Notes 'created by -Mode Plan over the store as it is'
        if ($made.Created) {
            $created = $true
            # the conversations of the lot are the ones the store already holds: the lot is moved to Exported so that it can be planned
            [void]$Store.TransitionLot($made.Id, 'Exporting', 'created by Plan over the exported store')
            [void]$Store.TransitionLot($made.Id, 'Exported', 'created by Plan over the exported store')
        } elseif ($Window -and $made.SliceCount -ne $bounds.Count) { throw "Lot '$lotName' already exists with $($made.SliceCount) wave(s) and -Window $Window defines $($bounds.Count): the waves of an existing lot are fixed." }
        if (@($Slices | Where-Object { $_ -gt $made.SliceCount }).Count) { throw "-Slices $($Slices -join ',') but the lot '$lotName' has $($made.SliceCount) wave(s) (-Window $(if ($Window) { $Window } else { '24m' }) for a new lot)." }
    } elseif ($null -eq $Store.GetLot($Lot)) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }

    $run = [TeamsTransfer.ImportRunOptions]::new()
    $run.Scenario = [TeamsTransfer.ImportScenario]$Scenario
    if ($GhostDomain) { $run.GhostDomain = $GhostDomain.TrimStart('@') }
    if ($GhostDisplayNameFormat) { $run.GhostDisplayNameFormat = $GhostDisplayNameFormat }
    $run.GhostConfirmThreshold = $GhostThreshold
    $run.ConfirmGhostCount = [bool]$ConfirmGhostCount

    $targetClient = $null
    if (-not $Offline) { $targetClient = Resolve-TmtClient $Client $Configuration 'Target' }
    # Same fallback order as Ghosts / CopyFiles / Import / Verify: parameter, configuration, plan checkpoint, identity map.
    $svc = Resolve-TmtServiceAccount -Store $Store -Lot $lotName -Configuration $Configuration -ServiceAccount $ServiceAccount -Client $targetClient -Validate
    if ($svc) { $run.ServiceAccountUserId = $svc.Id }

    $po = [TeamsTransfer.PlanOptions]::new()
    $po.AppCeilingMessagesPerSecond = $AppCeiling
    $m = $po.Mapping
    if ($IdentityMap) { $m.IdentityCsvPath = (Resolve-Path -LiteralPath $IdentityMap).ProviderPath }
    if ($TeamMap) { $m.TeamMapCsvPath = (Resolve-Path -LiteralPath $TeamMap).ProviderPath }
    foreach ($k in $domains.Keys) { $m.DomainMap[$k] = $domains[$k] }
    $m.DeletedAuthors = [TeamsTransfer.DeletedAuthorPolicy]$DeletedAuthors
    $m.ArchiveTeamPrefix = $ArchiveTeamPrefix
    $m.ChannelsPerArchiveTeam = $ChannelsPerArchiveTeam
    foreach ($o in @($ArchiveOwners | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { $m.ArchiveOwners.Add($o) }
    if (-not $OutputFolder) { $OutputFolder = Join-Path $Store.Root "plans\$lotName" }
    $po.OutputFolder = $OutputFolder
    $reporter = [TeamsTransfer.ProgressReporter]::new('Plan', $null)
    $po.Progress = $reporter

    $stop = New-TmtStopControl $StopFile
    $po.Stop = $stop
    $cts = [Threading.CancellationTokenSource]::new()
    $task = [TeamsTransfer.ImportPlanner]::BuildDetailedAsync($Store, $lotName, [int[]]$Slices, $run, $targetClient, $cts.Token, $po)
    try {
        $result = Wait-TmtEngineTask -Task $task -Snapshot { $reporter.Snapshot() } -Activity 'Plan' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $stop -Client $targetClient
    } finally { $cts.Dispose() }
    $ret = [pscustomobject][ordered]@{
        Result = $result; Plan = $result.Plan; Folder = $result.Folder; Blocked = [bool]$result.Plan.IsBlocked; LotName = $lotName; Created = $created
    }
    return $ret
    } catch {
        $failure = $_
        if ($created) {
            try {
                $cur = $Store.GetLot($lotName)
                if ($cur -and [string]$cur.State -ne 'ImportPlanned') { [void]$Store.CancelLot($lotName, 'Plan failed: ' + $failure.Exception.Message) ; Write-TmtWarn "Lot $lotName (created by this Plan) cancelled: its conversations are free again." }
            } catch { Write-TmtWarn "Lot $lotName could not be cancelled after the failure: $($_.Exception.Message)" }
        }
        throw $failure
    }
}

# Cumulative with the Export-ModuleMember of TeamsTransfer.psm1.
Export-ModuleMember -Function New-TmtImportPlan
