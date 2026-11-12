# TeamsTransfer - thin PowerShell surface over the C# ghost / file copy / verify engine.
# Dot-sourced by TeamsTransfer.psm1. All the logic lives in package\src\Engine.Ghosts.cs, Engine.FileCopy.cs and Engine.Verify.cs; these
# functions build the option objects, run the async engine, show a progress line every -IntervalSeconds by POLLING (see Wait-TmtEngineTask in
# TeamsTransfer.Export.ps1) and return the engine's result objects. Operator messages go through Write-Tmt* (console + log).
# The maps (identities, target conversations, file copies) are the store itself (TmtStore implements IIdentityMap, ITargetMap, IFileCopyMap) or any
# other implementation passed with -IdentityMap / -TargetMap / -FileCopyMap.
# Write modes (ghosts, file copy) are DRY RUNS unless -Apply: a dry run reads the target when it must (to know what exists) and writes nothing.
# A ghost password is generated inside the engine, sent once to Graph and never returned, logged or written to any report.

function script:Resolve-TmtMap {
    param($Explicit, $Store, [string]$InterfaceName, [string]$Parameter)
    $type = [type]"TeamsTransfer.$InterfaceName"
    $map = if ($null -ne $Explicit) { $Explicit } else { $Store }
    if ($map -isnot $type) { throw "The store does not implement $InterfaceName (the import catalog is not available): pass -$Parameter." }
    return $map
}

function script:Get-TmtServiceAccountChoice {
    # THE fallback order of the service account, shared by Plan, Ghosts, CopyFiles, Import and Verify:
    #   1. the -ServiceAccount parameter, 2. Target.ServiceAccountUserId of the configuration, 3. the service account the plan recorded
    #   (checkpoint plan:lot<id>), 4. the ServiceAccount identity of the identity map. Returns Value (UPN or object id) and Source, or $null.
    param($Store, [string]$Lot, $Configuration, [string]$ServiceAccount, $IdentityMap)
    if ($ServiceAccount) { return [pscustomobject]@{ Value = $ServiceAccount.Trim(); Source = 'parameter' } }
    if ($Configuration -and $Configuration.Target -is [System.Collections.IDictionary]) {
        $c = [string](Get-TmtSetting $Configuration.Target 'ServiceAccountUserId' '')
        if ($c.Trim()) { return [pscustomobject]@{ Value = $c.Trim(); Source = 'configuration' } }
    }
    if ($Store -and $Lot) {
        try {
            $info = $Store.GetLot($Lot)
            $cp = if ($info) { [string]$Store.GetCheckpoint("plan:lot$($info.Id)") } else { '' }
            if ($cp) {
                $j = $cp | ConvertFrom-Json
                foreach ($n in 'serviceAccountUserId', 'serviceAccount') { if ($j.PSObject.Properties[$n] -and $j.$n) { return [pscustomobject]@{ Value = [string]$j.$n; Source = 'plan' } } }
            }
        } catch { Write-Verbose "Plan checkpoint not readable: $($_.Exception.Message)" }
    }
    $map = if ($null -ne $IdentityMap) { $IdentityMap } elseif ($Store -is [TeamsTransfer.IIdentityMap]) { $Store } else { $null }
    $found = [TeamsTransfer.Importer]::FindServiceAccountId($map)
    if ($found) { return [pscustomobject]@{ Value = [string]$found; Source = 'map' } }
    return $null
}

function script:Resolve-TmtServiceAccount {
    # The service account as an object id. A GUID is taken as it is; a UPN is looked up in the target tenant (-Client). Without a client a UPN
    # is an error, unless -AllowUnresolved (a preview sends no request: the UPN is kept as it is). -Validate also checks that a GUID exists.
    param($Store, [string]$Lot, $Configuration, [string]$ServiceAccount, $IdentityMap, $Client, [switch]$Validate, [switch]$AllowUnresolved)
    $choice = Get-TmtServiceAccountChoice -Store $Store -Lot $Lot -Configuration $Configuration -ServiceAccount $ServiceAccount -IdentityMap $IdentityMap
    if ($null -eq $choice) { return $null }
    $isGuid = $choice.Value -match '^[0-9a-fA-F-]{36}$'
    if ($Client -and ($Validate -or -not $isGuid)) {
        $id = if ($Validate) { [string][TeamsTransfer.ImportPlanner]::ResolveServiceAccountAsync($Client, $choice.Value, [Threading.CancellationToken]::None).GetAwaiter().GetResult().Id }
        else { [string][TeamsTransfer.Importer]::ResolveUserIdAsync($Client, $choice.Value, [Threading.CancellationToken]::None).GetAwaiter().GetResult() }
        if (-not $id) { throw "The service account '$($choice.Value)' (from the $($choice.Source)) cannot be resolved in the target tenant (GET /users): give its object id or a valid UPN." }
        return [pscustomobject]@{ Id = $id; Value = $choice.Value; Source = $choice.Source }
    }
    if (-not $isGuid -and -not $AllowUnresolved) { throw "The service account '$($choice.Value)' (from the $($choice.Source)) must be an object id (a GUID) when the target tenant is not looked up: give its object id." }
    return [pscustomobject]@{ Id = $choice.Value; Value = $choice.Value; Source = $choice.Source }
}

function script:New-TmtRunOptions {
    # An ImportRunOptions for the stage: -Run (shared with the plan / import) or a new one; the explicit parameters override it.
    param($Run, [bool]$Apply, [string]$ServiceAccountUserId, [string]$GhostDomain, [string]$GhostDisplayNameFormat, [Nullable[int]]$GhostThreshold, [bool]$ConfirmGhostCount, [string]$StopFile,
          $Store, $Client, [string]$ServiceAccount, [string]$Scenario, $Configuration, [string]$Lot, [switch]$AllowUnresolved)
    $o = if ($null -ne $Run) { $Run } else { [TeamsTransfer.ImportRunOptions]::new() }
    $o.Apply = $Apply
    if ($Scenario) { $o.Scenario = [TeamsTransfer.ImportScenario]$Scenario }
    if ($ServiceAccountUserId) { $o.ServiceAccountUserId = $ServiceAccountUserId }
    elseif (-not $o.ServiceAccountUserId) {
        $svc = Resolve-TmtServiceAccount -Store $Store -Lot $Lot -Configuration $Configuration -ServiceAccount $ServiceAccount -Client $Client -AllowUnresolved:$AllowUnresolved
        if ($svc) { $o.ServiceAccountUserId = $svc.Id }
    }
    if ($GhostDomain) { $o.GhostDomain = $GhostDomain.TrimStart('@') }
    if ($GhostDisplayNameFormat) { $o.GhostDisplayNameFormat = $GhostDisplayNameFormat }
    if ($null -ne $GhostThreshold) { $o.GhostConfirmThreshold = [int]$GhostThreshold }
    if ($ConfirmGhostCount) { $o.ConfirmGhostCount = $true }
    if ($StopFile -or $null -eq $o.Stop) { $o.Stop = New-TmtStopControl $StopFile }
    return $o
}

function script:Get-TmtGraphRoot {
    param([hashtable]$Configuration)
    $cloud = 'Global'
    if ($Configuration -and $Configuration.ContainsKey('Target') -and $Configuration.Target -is [System.Collections.IDictionary]) { $cloud = [string](Get-TmtSetting $Configuration.Target 'Cloud' 'Global') }
    return [TeamsTransfer.GraphCloudEndpoints]::GraphRoot([TeamsTransfer.GraphCloud]$cloud)
}

function script:Write-TmtUtf8Csv {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()]$Rows)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    $list = @($Rows)
    if ($list.Count -eq 0) { [IO.File]::WriteAllText($Path, "`r`n", [Text.UTF8Encoding]::new($false)); return }
    $csv = $list | ConvertTo-Csv -NoTypeInformation
    [IO.File]::WriteAllText($Path, (($csv -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
}

function script:Step-TmtLot {
    # Moves the lot one stage forward along the lifecycle (legal transitions only; a lot that is not where the stage expects it is left alone).
    param($Store, [string]$Lot, [Parameter(Mandatory)][ValidateSet('Ghosts', 'Files')][string]$To, [string]$Note)
    $info = $Store.GetLot($Lot)
    if ($null -eq $info) { return }
    $from = [string]$info.State
    $ok = switch ($To) { 'Ghosts' { $from -eq 'ImportPlanned' } 'Files' { $from -in 'ImportPlanned', 'Ghosts' } }
    if ($ok) { [void]$Store.TransitionLot($info.Id, [TeamsTransfer.LotState]$To, $Note) }
}

function Invoke-TmtGhosts {
    <#
    .SYNOPSIS
        Creates (or previews) the ghost accounts of the deleted authors in the TARGET tenant, or removes them (lab cleanup).
    .DESCRIPTION
        For every identity of the map with Kind = Ghost and no target id: looks the deterministic UPN tt-ghost-<hash>@<domain> up, creates the account
        only when absent (disabled, unlicensed, random password never stored, employeeType TeamsTransferGhost), adds it to the tracking group
        "TeamsTransfer - Ghost accounts" and records the catalog and the mapping. A dry run (no -Apply) reads the target and writes nothing; its
        result lists exactly what would be created. Above the threshold (5,000) nothing is created unless -ConfirmGhostCount. When the target refuses
        the creation (403) the identity falls back to the service account. Ghosts found enabled are reported as reactivated.
        -Remove deletes only ghosts recorded in the catalog whose employeeType and UPN prefix are re-checked in the tenant.
    .PARAMETER Store
        An open TeamsTransfer.TmtStore (also the default identity map).
    .PARAMETER Client
        A Graph client of the TARGET tenant (New-TmtGraphClient -Side Target). Alternative: -Configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Target side builds the client, the Ghosts section gives the defaults.
    .PARAMETER Run
        A TeamsTransfer.ImportRunOptions shared with the plan and the import; the explicit parameters below override it.
    .PARAMETER Apply
        Perform the changes. Without it the stage is a preview.
    .PARAMETER Remove
        Delete the ghosts of the catalog instead of creating them (dry run unless -Apply).
    .PARAMETER Purge
        With -Remove: also purge the deleted ghosts from the recycle bin.
    .PARAMETER GhostDomain
        Domain of the ghost UPNs (a verified domain or the onmicrosoft.com domain of the target tenant).
    .PARAMETER GhostThreshold
        Above this many ghosts to create the stage is blocked unless -ConfirmGhostCount (default 5,000).
    .PARAMETER ConfirmGhostCount
        Accept the number of ghosts above the threshold.
    .PARAMETER CreateTrackingGroup
        Allow the stage to create the tracking group when it does not exist (otherwise a blocker).
    .PARAMETER UsageLocation
        ISO 3166-1 alpha-2 usageLocation set on the ghost (for example FR).
    .PARAMETER Users
        With -Remove: only these source user ids.
    .PARAMETER ReportFolder
        Writes ghosts.csv (one line per identity and action, never a password) in this folder.
    .OUTPUTS
        TeamsTransfer.GhostResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.GhostResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        $IdentityMap,
        $Run,
        [switch]$Apply,
        [switch]$Remove,
        [switch]$Purge,
        [string]$GhostDomain,
        [string]$GhostDisplayNameFormat,
        [string]$ServiceAccountUserId,
        [string]$ServiceAccount,
        [string]$Lot,
        [switch]$AdvanceLot,
        [Nullable[int]]$GhostThreshold,
        [switch]$ConfirmGhostCount,
        [switch]$CreateTrackingGroup,
        [string]$TrackingGroupName,
        [string]$UsageLocation,
        [string[]]$Users,
        [ValidateRange(1, 32)][int]$Parallelism = 4,
        [string]$ReportFolder,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration 'Target'
    $map = Resolve-TmtMap $IdentityMap $Store 'IIdentityMap' 'IdentityMap'
    $g = if ($Configuration -and $Configuration.ContainsKey('Ghosts') -and $Configuration.Ghosts -is [System.Collections.IDictionary]) { $Configuration.Ghosts } else { @{} }
    if (-not $GhostDomain) { $GhostDomain = [string](Get-TmtSetting $g 'DomainName' '') }
    if (-not $GhostDisplayNameFormat) { $GhostDisplayNameFormat = [string](Get-TmtSetting $g 'DisplayNameFormat' '') }
    if ($null -eq $GhostThreshold -and $g.ContainsKey('ConfirmThreshold')) { $GhostThreshold = [int]$g.ConfirmThreshold }
    $runOptions = New-TmtRunOptions -Run $Run -Apply ([bool]$Apply) -ServiceAccountUserId $ServiceAccountUserId -GhostDomain $GhostDomain -GhostDisplayNameFormat $GhostDisplayNameFormat `
        -GhostThreshold $GhostThreshold -ConfirmGhostCount ([bool]$ConfirmGhostCount) -StopFile $StopFile -Store $Store -Client $client -ServiceAccount $ServiceAccount -Configuration $Configuration -Lot $Lot

    $o = [TeamsTransfer.GhostOptions]::new()
    $o.Parallelism = $Parallelism
    $o.CreateTrackingGroup = [bool]$CreateTrackingGroup -or [bool](Get-TmtSetting $g 'CreateTrackingGroup' $false)
    $tg = if ($TrackingGroupName) { $TrackingGroupName } else { [string](Get-TmtSetting $g 'TrackingGroupName' '') }
    if ($tg) { $o.TrackingGroupName = $tg }
    $ul = if ($UsageLocation) { $UsageLocation } else { [string](Get-TmtSetting $g 'UsageLocation' '') }
    if ($ul) { $o.UsageLocation = $ul }
    $o.GraphRoot = Get-TmtGraphRoot $Configuration
    $o.PurgeDeleted = [bool]$Purge
    $sink = New-TmtProgressSink
    $o.OnProgress = $sink.Action
    $prov = [TeamsTransfer.GhostProvisioner]::new($client, $Store, $map, $runOptions, $o)
    $cts = [Threading.CancellationTokenSource]::new()
    $task = if ($Remove) { $prov.RemoveAsync([string[]]$Users, $cts.Token) } else { $prov.RunAsync($cts.Token) }
    $result = Wait-TmtEngineTask -Task $task -Snapshot $sink.Latest -Activity 'Ghosts' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $runOptions.Stop -Client $client
    if ($Apply -and $AdvanceLot -and $Lot -and -not $Remove -and -not $result.IsBlocked -and -not $result.Stopped -and $result.Failed -eq 0 -and $result.GroupMembershipFailed -eq 0) {
        Step-TmtLot -Store $Store -Lot $Lot -To Ghosts -Note ('ghosts: {0} created, {1} linked, {2} on the service account' -f $result.Created, $result.LinkedExisting, $result.FallbackToServiceAccount)
    }
    if ($ReportFolder) {
        $rows = @($result.Items | ForEach-Object { [pscustomobject][ordered]@{ SourceUserId = $_.SourceUserId; SourceDisplayName = $_.SourceDisplayName; GhostDisplayName = $_.DisplayName; UserPrincipalName = $_.UserPrincipalName; GhostId = $_.GhostId; Action = [string]$_.Action; Detail = $_.Detail } })
        Write-TmtUtf8Csv -Path (Join-Path $ReportFolder 'ghosts.csv') -Rows $rows
    }
    return $result
}

function Invoke-TmtFileCopy {
    <#
    .SYNOPSIS
        Copies the exported files into the TARGET tenant (chat files into the sender's OneDrive, channel files into the channel folder) and shares them.
    .DESCRIPTION
        For every Downloaded file of the conversations in scope: small files (< 4 MB) with one PUT, larger ones with an upload session streamed from the
        store in fragments of a multiple of 320 KiB (resumable after a stop or a crash), conflict behaviour rename, the same content in the same folder
        uploaded once, chat files shared read-only (no e-mail) with the target chat members. Failures are recorded per file and never stop the run.
        A dry run (no -Apply) makes no request at all: it counts files and bytes per destination.
    .PARAMETER Store
        An open TeamsTransfer.TmtStore (also the default identity, target and file-copy maps).
    .PARAMETER Client
        A Graph client of the TARGET tenant. Alternative: -Configuration.
    .PARAMETER Lot
        The name of a lot: only the conversations (and the time windows) of its items are covered. Default: every planned conversation of the target map.
    .PARAMETER Slices
        With -Lot: only these slices.
    .PARAMETER Run
        A TeamsTransfer.ImportRunOptions shared with the plan and the import.
    .PARAMETER Apply
        Perform the copy. Without it the stage is a preview.
    .PARAMETER MaxFileSizeMB
        Files larger than this are skipped (0 = no limit).
    .PARAMETER ExcludeExtensions
        File extensions that are skipped.
    .PARAMETER ChunkSizeMB
        Fragment size of an upload session in MB (rounded to a multiple of 320 KiB, default 10).
    .PARAMETER NoShare
        Do not share chat files with the chat members.
    .PARAMETER ReportFolder
        Writes filecopy.csv (counts and bytes per destination) and filecopy-errors.csv in this folder.
    .OUTPUTS
        TeamsTransfer.FileCopyResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.FileCopyResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        $IdentityMap,
        $TargetMap,
        $FileCopyMap,
        $Run,
        [string]$Lot,
        [int[]]$Slices,
        [switch]$Apply,
        [switch]$AdvanceLot,
        [string]$ServiceAccountUserId,
        [string]$ServiceAccount,
        [ValidateRange(0, 100000)][int]$MaxFileSizeMB = 0,
        [string[]]$ExcludeExtensions,
        [ValidateRange(1, 64)][int]$Parallelism = 4,
        [ValidateRange(1, 60)][int]$ChunkSizeMB = 10,
        [switch]$NoShare,
        [string]$ReportFolder,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $ids = Resolve-TmtMap $IdentityMap $Store 'IIdentityMap' 'IdentityMap'
    $targets = Resolve-TmtMap $TargetMap $Store 'ITargetMap' 'TargetMap'
    $files = Resolve-TmtMap $FileCopyMap $Store 'IFileCopyMap' 'FileCopyMap'
    # A dry run needs no request, hence no client: the engine never touches it.
    $client = if ($Apply -or $Client) { Resolve-TmtClient $Client $Configuration 'Target' } else { Resolve-TmtDryClient }
    $runOptions = New-TmtRunOptions -Run $Run -Apply ([bool]$Apply) -ServiceAccountUserId $ServiceAccountUserId -StopFile $StopFile -Store $Store -Client $(if ($Apply -or $Client) { $client }) -ServiceAccount $ServiceAccount `
        -Configuration $Configuration -Lot $Lot -AllowUnresolved:(-not ($Apply -or $Client))
    $o = [TeamsTransfer.FileCopyOptions]::new()
    $o.Parallelism = $Parallelism
    $o.MaxFileBytes = [int64]$MaxFileSizeMB * 1MB
    if ($ExcludeExtensions) { $o.ExcludedExtensions = $ExcludeExtensions }
    $o.ChunkBytes = [int]($ChunkSizeMB * 1MB)
    $o.ShareChats = -not $NoShare
    $sink = New-TmtProgressSink
    $o.OnProgress = $sink.Action
    $scopes = $null
    if ($Lot) {
        $info = $Store.GetLot($Lot)
        if ($null -eq $info) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
        $scopes = [Collections.Generic.List[TeamsTransfer.FileCopyScope]]::new()
        foreach ($i in $Store.ListItems($info.Id)) {
            if ($Slices -and [int]$i.SliceNo -notin $Slices) { continue }
            $s = [TeamsTransfer.FileCopyScope]::new(); $s.ConversationKey = $i.ConversationKey; $s.FromUtc = $i.FromUtc
            if ($null -ne $i.ToUtc) { $s.ToUtc = $i.ToUtc }
            $scopes.Add($s)
        }
    }
    $copier = [TeamsTransfer.FileCopier]::new($client, $Store, $ids, $targets, $files, $runOptions, $o)
    $cts = [Threading.CancellationTokenSource]::new()
    $task = $copier.RunAsync($scopes, $cts.Token)
    $result = Wait-TmtEngineTask -Task $task -Snapshot $sink.Latest -Activity 'File copy' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $runOptions.Stop -Client $(if ($Apply) { $client })
    if ($Apply -and $AdvanceLot -and $Lot -and -not $result.Stopped -and $result.Failed -eq 0 -and $result.WaitingForTarget -eq 0 -and $result.SharingIncomplete -eq 0 -and $result.NoDestination -eq 0) {
        Step-TmtLot -Store $Store -Lot $Lot -To Files -Note ('files: {0} uploaded, {1} reused, {2} shared, {3} skipped' -f $result.Uploaded, $result.Reused, $result.Shared, $result.Skipped)
    }
    if ($ReportFolder) {
        $rows = @($result.Destinations | ForEach-Object { [pscustomobject][ordered]@{ Destination = $_.Destination; Files = $_.Files; Bytes = $_.Bytes; Duplicates = $_.Duplicates } })
        Write-TmtUtf8Csv -Path (Join-Path $ReportFolder 'filecopy.csv') -Rows $rows
        if ($result.Errors.Count -gt 0) {
            Write-TmtUtf8Csv -Path (Join-Path $ReportFolder 'filecopy-errors.csv') -Rows @($result.Errors | ForEach-Object { [pscustomobject][ordered]@{ Scope = $_.Scope; Operation = $_.Operation; StatusCode = $_.StatusCode; ErrorCode = $_.ErrorCode; Message = $_.Message } })
        }
    }
    return $result
}

function script:Resolve-TmtDryClient {
    # A GraphClient over a transport that refuses every request: the dry run of the file copy must not send any.
    $transport = [TeamsTransfer.RefusingTransport]::new()
    return [TeamsTransfer.GraphClient]::new($transport, [TeamsTransfer.GraphClientOptions]::new(), $null)
}

function Invoke-TmtVerify {
    <#
    .SYNOPSIS
        Verifies an imported lot: per conversation and slice, the target against the journal, the source counts and a sample; sets the lot Verified when all is OK.
    .DESCRIPTION
        Reads the target conversation by conversation (imported messages are invisible to getAllMessages): chats /chats/{id}/messages page by page with the
        slice windows applied client-side, channels with $top=50 and $expand=replies. Compares counts, a random sample (createdDateTime, author, body hash after
        normalisation), reactions and file attachments, and checks that migrationMode is completed. Outcome per conversation-slice: OK, Mismatch, Missing,
        NotCompleted. The items and the lot move to Verified (legal transitions only) when every item is OK. Read only on the target.
    .PARAMETER Store
        An open TeamsTransfer.TmtStore (read-write: the lot state and the results are saved).
    .PARAMETER Client
        A Graph client of the TARGET tenant. Alternative: -Configuration.
    .PARAMETER Lot
        The lot to verify.
    .PARAMETER Slices
        Only these slices (default: all the slices of the lot).
    .PARAMETER SampleSize
        Messages compared one by one per slice (default 10).
    .PARAMETER Strict
        Reactions and file attachment totals that differ become a Mismatch (otherwise they are only reported).
    .PARAMETER AllowExtra
        Messages already on the target are not a mismatch (default for the restore scenario only).
    .PARAMETER NoLotUpdate
        Do not change the state of the items and of the lot.
    .PARAMETER ReportFolder
        Writes verify.csv, verify.html and verify-summary.txt in this folder.
    .OUTPUTS
        TeamsTransfer.VerifyResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.VerifyResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        $IdentityMap,
        $TargetMap,
        $Run,
        [Parameter(Mandatory)][string]$Lot,
        [int[]]$Slices,
        [ValidateRange(0, 1000)][int]$SampleSize = 10,
        [switch]$Strict,
        [switch]$AllowExtra,
        [switch]$NoLotUpdate,
        [ValidateRange(1, 64)][int]$ConversationParallelism = 8,
        [string]$ServiceAccountUserId,
        [string]$ServiceAccount,
        [ValidateSet('TenantToTenant', 'SameTenantRestore', 'DepartedArchive')][string]$Scenario,
        [string]$ReportFolder,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration 'Target'
    $targets = Resolve-TmtMap $TargetMap $Store 'ITargetMap' 'TargetMap'
    $ids = if ($null -ne $IdentityMap) { $IdentityMap } elseif ($Store -is [TeamsTransfer.IIdentityMap]) { $Store } else { $null }
    $runOptions = New-TmtRunOptions -Run $Run -Apply $false -ServiceAccountUserId $ServiceAccountUserId -StopFile $StopFile -Store $Store -Client $client -ServiceAccount $ServiceAccount -Scenario $Scenario -Configuration $Configuration -Lot $Lot
    $o = [TeamsTransfer.VerifyOptions]::new()
    $o.Parallelism = $ConversationParallelism
    $o.SampleSize = $SampleSize
    $o.ReactionsAndFilesStrict = [bool]$Strict
    if ($AllowExtra) { $o.AllowExtraOnTarget = $true }
    $o.UpdateLotState = -not $NoLotUpdate
    $sink = New-TmtProgressSink
    $o.OnProgress = $sink.Action
    $v = [TeamsTransfer.Verifier]::new($client, $Store, $targets, $runOptions, $ids, $o)
    $cts = [Threading.CancellationTokenSource]::new()
    $task = $v.RunAsync($Lot, [int[]]$Slices, $cts.Token)
    $result = Wait-TmtEngineTask -Task $task -Snapshot $sink.Latest -Activity 'Verify' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $runOptions.Stop -Client $client
    if ($ReportFolder) {
        [void][IO.Directory]::CreateDirectory($ReportFolder)
        [TeamsTransfer.VerifyReport]::WriteCsv((Join-Path $ReportFolder 'verify.csv'), $result.Items)
        [TeamsTransfer.VerifyReport]::WriteHtml((Join-Path $ReportFolder 'verify.html'), $result.LotName, $result.Items, [datetimeoffset]::UtcNow, $null)
        [IO.File]::WriteAllText((Join-Path $ReportFolder 'verify-summary.txt'), $result.ToText() + "`r`n", [Text.UTF8Encoding]::new($false))
    }
    return $result
}

function Invoke-TmtLotReport {
    <#
    .SYNOPSIS
        Rebuilds the HTML reports of a lot from the catalog: lot state and history, items per slice and state, journal totals, ghosts, file copies, last verification.
    .PARAMETER Store
        An open TeamsTransfer.TmtStore (read-only is enough).
    .PARAMETER Lot
        The lot (name). Default: every lot of the store.
    .PARAMETER Folder
        Where the files are written: TeamsTransfer_Lot_<name>.html per lot, and verify.csv + verify.html when a verification was saved for it.
    .OUTPUTS
        One object per lot: Lot, State, Html, VerifyCsv, VerifyHtml, Verified (rows OK / rows).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [string]$Lot, [Parameter(Mandatory)][string]$Folder, $FileCopyMap)
    [void][IO.Directory]::CreateDirectory($Folder)
    $lots = if ($Lot) {
        $one = $Store.GetLot($Lot)
        if ($null -eq $one) { throw "Lot '$Lot' not found in the store (-Mode Status lists the lots)." }
        @($one)
    } else { @($Store.ListLots()) }
    $files = if ($null -ne $FileCopyMap) { $FileCopyMap } elseif ($Store -is [TeamsTransfer.IFileCopyMap]) { $Store } else { $null }
    $version = $null
    $vv = Get-Variable -Name ToolVersionText -Scope Script -ErrorAction SilentlyContinue
    if ($vv) { $version = [string]$vv.Value }
    foreach ($l in $lots) {
        $safe =($l.Name -replace '[^\w\.-]', '_')
        $html = Join-Path $Folder "TeamsTransfer_Lot_$safe.html"
        [void][TeamsTransfer.VerifyReport]::WriteLotReport($Store, $l.Id, $html, $files, $version)
        $rows = [TeamsTransfer.VerifyReport]::LoadRows([TeamsTransfer.VerifyReport]::RowsFileOf($Store, $l.Name))
        $vcsv = $null; $vhtml = $null
        if ($rows.Count -gt 0) {
            $vcsv = Join-Path $Folder "verify_$safe.csv"; $vhtml = Join-Path $Folder "verify_$safe.html"
            [TeamsTransfer.VerifyReport]::WriteCsv($vcsv, $rows)
            [TeamsTransfer.VerifyReport]::WriteHtml($vhtml, $l.Name, $rows, [datetimeoffset]::UtcNow, $null)
        }
        [pscustomobject][ordered]@{
            Lot = $l.Name; State = [string]$l.State; Html = $html; VerifyCsv = $vcsv; VerifyHtml = $vhtml
            Verified = if ($rows.Count -gt 0) { '{0}/{1}' -f @($rows | Where-Object { [string]$_.Outcome -eq 'OK' }).Count, $rows.Count } else { '' }
        }
    }
}
