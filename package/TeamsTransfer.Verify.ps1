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

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAwe5syPCu2V1rs
# /jtZPqlS5pft18Ix3Y556iS9/mQgj6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYETCCGA0CAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDhCQnUWi/x
# JHyQ9WE9hU6k5Lr24vPkkxKtczXhlWmDAjANBgkqhkiG9w0BAQEFAASCAgBolbka
# ul8qBkqzkFw6994F/Wd8X3egUp6xocd6m54HOH6rqvNJ+74PCjiBmS2S+yGTtop5
# W+NzCpKmlKRnT+xE+V9f/S5fofenrf2jGqeZJrLJRPFswfo3jmCnRrrFlzxZ+vkW
# tyViVPhU/xLen6P1geRNBqdv2GuaYQtmibBgDv7ow57q9ple3qzwoPn+uZAZEgCs
# LJWyJzSa/6LXwTRqUsg2GzgwLavPkpt7B3YqK44zETvjW7e7Kmch/DnBCG6UV+zd
# nQLdLQY7TNZ02FcsCqK60eISgbdDpn+NaZHNbOVcvObkVvu0Opp6Zv+2cWXXOCJi
# nmK2f8j7KO6nf2PjQjMfupXhGKloQErwkPGt8HgYYbdsjfW6nEKIim9oQgHzzOrL
# yXH5qEmnivEKN1dXlTKQ00K0kUz9QS/bne7Oy2jcpV6QTaiaLCwv6A4i6FhhPi39
# YgiuIrAI6oVY3g57eFrdLWxjpG1NCKBpWCn5r3csIaZpHtxo8fZvyAZSC/RnfeWp
# cdC/GXF7BEXMx5VEr6LvS/BDm/ODO/zLPgnXxuwf67HqzTjZz6CCtMU47ms5UxAQ
# iLdvBdxvGjEVtpM/TP3NSWYVrt19ywg5nJ+xxXCg4Qsx9si8tSdnwcPOrvd50XxR
# kCvysd0b9gSt0PIlQhUdDixOfVlCMAwDGndeIqGCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIFbRpK+5WVA4cjqwghHR6FRgNxc9JSckvpGD9TarINOQAghr1rtFL/5p
# qhgPMjAyNjExMTIxNzI2MDJaMAMCAQECEDuHU21WLGmnAcwrmL7o/SOgghGnMIIE
# 8zCCAtugAwIBAgIQVEP4N71a7hgBhHK4XNqO4zANBgkqhkiG9w0BAQsFADByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyMB4XDTI2MDYxMjE3MjI0NloXDTM2MDYwOTE3MjI0NVow
# bjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBp
# bmcgVW5pdCAyMDI2IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6CWLuGYT
# LkiSOPMLNskOBthXsIhRSA46feOQwvSLcDaNh6vxUzBKEx1KdFBRFs7OHrnH/K0V
# A6MbDQIFpUg0PaOCAVIwggFOMB8GA1UdIwQYMBaAFHCaZcFDgKP86bFkiW7xMJwJ
# Icl8ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3Ns
# LmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1JLVIyLmNlcjBRBgNVHSAESjBIMDwG
# DCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29t
# L3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEIG
# A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNvbS10aW1l
# U3RhbXBpbmctSS1SMi5jcmwwHQYDVR0OBBYEFCesA1a6KGq6FzuDPUB/eagk7MM8
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT3ZuzvwDnsIZTXBn
# +hjmuBXgzB12fbYxT9uYe6ZvhvpbZWKcyDQgacETkPw8k6yeqnYCYyFZ063lMPEq
# AhAD2nMG614Zh7PtHW9DWqfsgivxbPYBeN+t7UxgkYT3expbWMdPEqBtWVyHOvLc
# KvMxgJWfJjANwVkwVDfky/j7cf28+iimN8PKc7S/u8/LenRRnV2W2YfncRnkz9Cf
# s5nRDzaZguiHrrp2GxwgnNQSH4GBjHOl3PzLsnVbGoZKi4ZEjgXups4mGGOK7+GB
# 2HAlQn+OS944cHqlkH0gElt2WezoCNRpELph9qaxuBnjSEqXWWfgE6yGBwO0uxKN
# qpWVTHmAwr6SvBPofxubXIuEn9ivR4CLOuAxUSrJ41ZBg/qqG0oJjF6GkRKbxq7c
# yWSkEZYJhmKCg2Hg5fXHagOxiwbmn5JPZ1vhWCrbk3v/dTx2gvTK5+erC5H9/rTc
# ljUI776yd2rfhjfkpvyAsbtXs4D7nrnw8i9wor5+fdtRSJBVxqzLmykFftoL0Up2
# Q++tyKCUdribdcnrB4HKS3s+t3AjdcbA06DCL8GifQi9fL0yRBRNlA4o6BP+Sr75
# 5MaCNjURYZDvDyxJHBBT7cqjZIwsiR8s+6860noFbBBtdge2Iw7CPC/1Q31I27hV
# olS7B0yao3v8X2MtWy3msZlXTcEwggXdMIIDxaADAgECAgh7LJvTFoAymTANBgkq
# hkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8GA1UEAwwo
# U1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAeFw0xNjAy
# MTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQI
# DAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0
# aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3Jp
# dHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/doyt9y9Aq
# /uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aUnheDhc5W
# 7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q6Pw/YUjt
# sAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg+sglkrRu
# eiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qhk4jrwZe8
# jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmylD0CGfAL0
# XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUuqfqeLLZR
# Rv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiYohgsQkCz
# +W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZTNTX8N+TD
# 9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZX5es6+8u
# yLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumamdu0bc+sa
# pQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYEFN0ECQei
# 9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU3QQJ
# B6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUA
# A4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9eGr0uYul
# lzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK3cT5lR+K
# OEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF9J1r/Blj
# naO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9hqTKWzN67
# 7WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg+/a1LRrm
# woWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP5UU/eNu6
# 0htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53eyoHWXtS2B
# iBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8PUkg9v2zY
# okQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaPzvDsbopX
# C4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOLYRu8+h+R
# K9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBsswggSzoAMC
# AQICEFKdu8K4iYf1g4DgsOuiBjYwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9T
# U0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0
# aW9uIEF1dGhvcml0eSBSU0EwHhcNMjYwNjEyMTY0MjE1WhcNNDEwMjEyMTczOTM5
# WjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFt
# cGluZyBJc3N1aW5nIFJTQSBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAny+r5nNNkLwxRps2B3laUGNU9y7vWiJ5013yf0iXz65bQdwa9bjj8l/S
# keXqHGqfSh2Foae+80E8mDEf93oIwjsy2CX2cXmKxqtF8HJGYB4f6yRhKED50wkb
# OysL02IXf+/EZna44jffhhVz4OU/k52xQ/PnIg/uFhc2Wk+Sc/CHqAr+lYVkPz7L
# y5RqB9f1RKGr9JC37W1LgVdHC50dNIdsa3QXPhltYZubR3npE4Bbfi0joUW5n5O0
# ayweN45R/YVLxA0YGlp1OHVfVnsqXq8bhnw1Lc4kjJ6XOgXlOlw/a8ze57TvbduZ
# l3ehewTmvO0Aky/nqOWDS9IPPxdxdG6vprBbSuHlxNANBAbHTiFgkfZmf0dZYlT/
# AnZIoFxAq0HILPolf4OgWgET76SiWSlm2XYRIXwVjpeqG0plvXwRIQBzSiEJj7Qe
# QFnCvHx4gQMINvN3+yG/1rxhEbajGve0tTP3lX4PPOHVAE0QJp4ZzPI1YYJkhVRr
# iVVxVRU4Fsg4BPwP6I+YLmHb1tZ4RLwOFNLh/gJYDgPlChCoxOogFxXgwPZZrDyE
# RYB0aeOexW0OKacN4RRu9cqF2KKu/Ab5AL7eYDLVGUPrEEyYbIMApVKqpebc0/jD
# QniC+3rkauRAjgVc8m1ip/CQgG1Dw4Z9ulVRAY9VR6Za26LsTbUCAwEAAaOCAVEw
# ggFNMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKS
# le44gCUNplkwTQYIKwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2Vy
# dC5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY2VyMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwQgYDVR0fBDswOTA3oDWgM4Yx
# aHR0cDovL2NybHMuc3NsLmNvbS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNy
# bDAdBgNVHQ4EFgQUcJplwUOAo/zpsWSJbvEwnAkhyXwwDgYDVR0PAQH/BAQDAgGG
# MA0GCSqGSIb3DQEBCwUAA4ICAQBlFFvNMemA6iBiBYo56IKQjWhWuQaYKuo4qpf0
# KJNERAt1gz+HsA2SL3xA/V+EA8SRPNP9SvX0is+5mDsppYvpKyYGqYP36YFW0mbF
# 1F0ZtXxumCUUO/ZV5mBNKDf5Q4PY7Qb0eWAepUc0rNJr/Mvn5ZiXfJPxDb2xmcg8
# aRD652/nr+Ork2UBP0E43iJdI4LF7Vs29R3SGRLYZOxM15DI4QebsKRl0KDlf4Om
# YGCKc7umTxibkZtN1C1KWgnf9jadU/JwnySaYEBgx6/v+FVC6SGONziY7TcvI9MV
# +qYxHUPlOm6AaQP2dS4bjWXnm86ldCbUkxtOACumSfT97077JNiVa7PZ1IBkd/2P
# E1AC8gs7U+/Yk1BN9XRPIi15k/uA1xF9oeee5KGjyiGKkqIT7W8QkgUT5zeCinFK
# kcKafZMcROSVYpXtmtQqGGR2g4uPYqJ0K1hms6gJXrHt/34p8M9PrV8oNWe0Zl1E
# rDMtXndUg3qhJL4pA3ZUlo7w5lM5ml+A7ijr/3Gk2v4QRoDeE2ShmTXdHgtqo8L/
# fT119mYcETycE2NYGRXsBl3N0rzDsHRr8P3TrprqhRrX04iS0P7eQ+lDxgS3yhGn
# 3OzWGhDt9Gf2x1qe0/qdhFAVOkXxzMZz4Uat6xsAfzX0+/m8GEKW5Ojw/HY+kLvV
# wzSPOzGCAlYwggJSAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMjE3MjYwMlowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIOH7
# j70iaGWLdHxqQ8LCig5LGO4ois/yGrculpu5KZ9CMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiEA+/kal68GPnwoTYdNXpQuG6SJU4VWAWJIcUyXil+MHbYCIFpE
# 3dImNmal7Cgiu40eP5stIa2TxA8n138Mrjb9hUCP
# SIG # End signature block
