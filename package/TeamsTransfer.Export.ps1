# TeamsTransfer - thin PowerShell surface over the C# inventory / assess / export / files engine.
# Dot-sourced by TeamsTransfer.psm1. All the logic lives in package\src\Engine.Inventory.cs and Engine.Export.cs; these functions only
# build objects, run the async engine, show a text progress line every -IntervalSeconds by POLLING (a PowerShell scriptblock cannot be
# called back from engine threads) and return the engine's result objects. Operator messages go through Write-Tmt* (console + log).
# The store is always passed in (-Store, an IExportStore; also an IStoreReader for the C strategy / channels / Auto): the real store
# (Open-TmtStore) or any other implementation.
# One name per concept, in every public function and in the entry script: -Users, -Teams, -Window, -From/-To, -Store, -StopFile, -IntervalSeconds.

function script:Get-TmtSetting {
    param($Table, [string]$Name, $Default)
    if ($null -ne $Table -and $Table -is [System.Collections.IDictionary] -and $Table.Contains($Name) -and $null -ne $Table[$Name] -and "$($Table[$Name])" -ne '') { return $Table[$Name] }
    return $Default
}

function New-TmtGraphClient {
    <#
    .SYNOPSIS
        Builds a GraphClient (certificate token provider + HTTP transport + adaptive rate limiter) from the configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration.
    .PARAMETER Side
        Source (read the tenant to export) or Target (write the tenant to import into).
    .PARAMETER Transport
        Test/demo seam: an IGraphTransport (for example a FakeGraphTransport) used instead of the real HTTP transport (no token needed).
    .OUTPUTS
        TeamsTransfer.GraphClient. A TeamsTransfer.GraphMetrics is attached (GraphMetrics.Of($client)) and counts requests / 429s.
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.GraphClient')]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][ValidateSet('Source', 'Target')][string]$Side,
        [object]$Transport
    )
    $g = if ($Configuration.ContainsKey('Graph')) { $Configuration.Graph } else { @{} }
    $options = [TeamsTransfer.GraphClientOptions]::new()
    $options.MaxAttempts = [int](Get-TmtSetting $g 'MaxAttempts' $options.MaxAttempts)
    $options.BaseBackoff = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'BaseBackoffSeconds' $options.BaseBackoff.TotalSeconds))
    $options.MaxBackoff = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'MaxBackoffSeconds' $options.MaxBackoff.TotalSeconds))
    $options.RequestTimeout = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'RequestTimeoutSeconds' $options.RequestTimeout.TotalSeconds))
    $options.ExportModel = [string](Get-TmtSetting $g 'ExportModel' $options.ExportModel)
    $options.MaxConcurrency = [int](Get-TmtSetting $g 'MaxConcurrency' $options.MaxConcurrency)

    $limiterOptions = $options.ToRateLimiterOptions()
    $limiterOptions.InitialRatePerSecond = [double](Get-TmtSetting $g 'InitialRatePerSecond' $limiterOptions.InitialRatePerSecond)
    $limiter = [TeamsTransfer.AdaptiveRateLimiter]::new($limiterOptions)

    if ($null -eq $Transport) {
        $s = if ($Configuration.ContainsKey($Side)) { $Configuration[$Side] } else { @{} }
        foreach ($k in 'TenantId', 'ClientId', 'CertificateThumbprint') {
            if (-not (Get-TmtSetting $s $k $null)) { throw "Configuration.$Side.$k is empty: fill it in config\TeamsTransfer.config.local.psd1." }
        }
        $cloud = [TeamsTransfer.GraphCloud](Get-TmtSetting $s 'Cloud' 'Global')
        $tokens = [TeamsTransfer.CertificateTokenProvider]::FromThumbprint([string]$s.TenantId, [string]$s.ClientId, [string]$s.CertificateThumbprint, $cloud, $null)
        $Transport = [TeamsTransfer.HttpGraphTransport]::new($tokens, $cloud, 64, $null)
    }
    $metrics = [TeamsTransfer.GraphMetrics]::new()
    $client = [TeamsTransfer.GraphClient]::new($Transport, $options, $limiter, [Action[TeamsTransfer.GraphEvent]]$metrics.OnEvent)
    $metrics.Attach($client)
    return $client
}

function script:New-TmtProgressSink {
    # For engine stages that only expose an OnProgress callback (called from engine threads): the callback is ConcurrentQueue.Enqueue (no
    # PowerShell code ever runs on an engine thread) and Latest drains the queue on the PowerShell thread.
    $queue = [Collections.Concurrent.ConcurrentQueue[TeamsTransfer.ProgressSnapshot]]::new()
    $state = @{ Last = $null }
    return [pscustomobject]@{
        Action = [Action[TeamsTransfer.ProgressSnapshot]]$queue.Enqueue
        Latest = { $x = $null; while ($queue.TryDequeue([ref]$x)) { $state.Last = $x }; $state.Last }.GetNewClosure()
    }
}

function script:Wait-TmtEngineTask {
    # Runs an engine Task to completion on this thread: a dim progress line every -IntervalSeconds (console + log). Ctrl+C or the
    # appearance of the stop file stops after the requests in flight (the store stays consistent: run again to resume).
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][scriptblock]$Snapshot, [string]$Activity,
          [Threading.CancellationTokenSource]$Cts, [int]$IntervalSeconds = 5, $Stop, $Client)
    $metricsOf = { if ($Client) { $gm = [TeamsTransfer.GraphMetrics]::Of($Client); if ($gm) { $gm.Snapshot() } } }
    $next = [DateTime]::UtcNow.AddSeconds($IntervalSeconds)
    $stopShown = $false
    try {
        while (-not $Task.IsCompleted) {
            [void]$Task.Wait(500)
            if (-not $stopShown -and $Stop -and $Stop.IsRequested) {
                $stopShown = $true
                Write-TmtItem WARN 'stop requested: the requests in flight finish first, run the command again to resume'
            }
            if ([DateTime]::UtcNow -ge $next) {
                $next = [DateTime]::UtcNow.AddSeconds($IntervalSeconds)
                $s = & $Snapshot
                if ($null -ne $s) { Write-TmtProgress -Snapshot $s -Metrics (& $metricsOf) }
            }
        }
        $result = $Task.GetAwaiter().GetResult()
        $m = & $metricsOf
        if ($m -and ($m.Throttled429 -or $m.Throttled503)) {
            Write-TmtDetail ('{0}: throttled by the service: 429 x {1}, 503 x {2}, time waited {3} (Retry-After is honoured)' -f $Activity,
                (Format-TmtNumber $m.Throttled429), (Format-TmtNumber $m.Throttled503), (Format-TmtDuration $m.WaitedByServer.TotalSeconds))
        }
        return $result
    } finally {
        if (-not $Task.IsCompleted -and $Cts) {
            Write-TmtItem WARN 'stopping: the requests in flight finish first, run the command again to resume'
            $Cts.Cancel(); try { [void]$Task.Wait(120000) } catch { Write-Verbose "Task did not stop in time: $($_.Exception.Message)" }
        }
    }
}

function script:Resolve-TmtClient {
    param($Client, $Configuration, [string]$Side = 'Source')
    if ($Client) { return $Client }
    if ($Configuration) { return New-TmtGraphClient -Configuration $Configuration -Side $Side }
    throw 'Pass -Client (New-TmtGraphClient) or -Configuration.'
}

function script:New-TmtStopControl {
    param([string]$StopFile)
    $stop = [TeamsTransfer.StopControl]::new()
    if ($StopFile) { $stop.StopFile = $StopFile }
    return $stop
}

function Resolve-TmtWindow {
    <#
    .SYNOPSIS
        Turns -Window into a period: Nm (the last N months, 1 <= N <= 600) or <from>..<to> (ISO dates) gives @{ From; To }; an empty window gives nothing.
    .PARAMETER Window
        The text of -Window. Anything else is an error that states the accepted forms.
    #>
    # 'Nm' (the last N months, 1 <= N <= 600) or '<from>..<to>' (ISO dates) -> @{ From; To } (nullable datetimeoffset values); nothing for an empty window.
    # The message states exactly what is accepted.
    param([string]$Window)
    if (-not $Window) { return $null }
    $expected = "expected Nm with N from 1 to 600 (the last N months, for example 24m) or <from>..<to> (ISO dates, for example 2024-01-01..2025-12-31)"
    if ($Window -match '^(\d+)m$') {
        $n = [long]$Matches[1]
        if ($n -lt 1 -or $n -gt 600) { throw "Window '$Window': $expected." }
        return @{ From = [datetimeoffset]::UtcNow.AddMonths(-[int]$n); To = $null }
    }
    if ($Window -match '^(\d{4}-\d{2}-\d{2}(?:T[0-9:.]+Z?)?)\.\.(\d{4}-\d{2}-\d{2}(?:T[0-9:.]+Z?)?)$') {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $from = [datetimeoffset]::MinValue; $to = [datetimeoffset]::MinValue
        if (-not ([datetimeoffset]::TryParse($Matches[1], $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$from) -and [datetimeoffset]::TryParse($Matches[2], $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$to))) { throw "Window '$Window': $expected." }
        if ($from -gt $to) { throw "Window '$Window': the start date is after the end date." }
        return @{ From = $from; To = $to }
    }
    throw "Window '$Window': $expected."
}

function Invoke-TmtInventory {
    <#
    .SYNOPSIS
        Inventories the tenant into the store: users (incl. deleted, guests), chats (deduplicated across users), teams, channels, members.
    .DESCRIPTION
        Resumable: an interrupted pass continues where it stopped, a finished one is followed by a new pass. A failing user or team is
        recorded in the result and retried by the next run. A progress line is written every -IntervalSeconds.
    .PARAMETER Store
        The store to write (an IExportStore, see Open-TmtStore).
    .PARAMETER Client
        A Graph client (New-TmtGraphClient). Alternative: -Configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Source side is used to build the client.
    .PARAMETER Users
        Limit the pass to these users: ids / UPNs, or the path of a CSV with an Id / Identity / UserPrincipalName / Mail column.
    .PARAMETER Teams
        Limit the pass to these teams: ids / exact display names, or a CSV with an Id / TeamId / DisplayName column.
    .PARAMETER NoResume
        Start a new pass even if an interrupted one could be continued.
    .PARAMETER StopFile
        When this file exists the pass stops after the requests in flight (run again to resume).
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        TeamsTransfer.InventoryResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.InventoryResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        [object]$Users,
        [object]$Teams,
        [switch]$SkipChats,
        [switch]$SkipTeams,
        [switch]$SkipDeletedUsers,
        [switch]$NoResume,
        [ValidateRange(1, 64)][int]$UserParallelism = 8,
        [ValidateRange(1, 64)][int]$TeamParallelism = 4,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration
    $o = [TeamsTransfer.InventoryOptions]::new()
    $o.UserParallelism = $UserParallelism; $o.TeamParallelism = $TeamParallelism
    $o.IncludeChats = -not $SkipChats; $o.IncludeTeams = -not $SkipTeams; $o.IncludeDeletedUsers = -not $SkipDeletedUsers
    $o.Resume = -not $NoResume
    $userList = Get-TmtUserList $Users
    $teamList = Get-TmtUserList $Teams 'Id', 'TeamId', 'DisplayName'
    if ($userList) { $o.OnlyUsers = [string[]]$userList }
    if ($teamList) { $o.OnlyTeams = [string[]]$teamList }
    $o.Stop = New-TmtStopControl $StopFile
    $inv = [TeamsTransfer.Inventory]::new($client, $Store, $o)
    $cts = [Threading.CancellationTokenSource]::new()
    $task = $inv.RunAsync($cts.Token)
    Wait-TmtEngineTask -Task $task -Snapshot { $inv.Progress } -Activity 'Inventory' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $o.Stop -Client $client
}

function Invoke-TmtAssess {
    <#
    .SYNOPSIS
        Samples users (and optionally teams), measures, and extrapolates volume, duration and per-wave estimates to the whole tenant.
    .PARAMETER Client
        A Graph client (New-TmtGraphClient). Alternative: -Configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Source side is used to build the client.
    .PARAMETER Store
        Optional store: when it holds an inventory the sample is drawn from it instead of the directory.
    .PARAMETER SampleUsers
        Number of users to sample (default 20).
    .PARAMETER SampleTeams
        Number of teams to sample (default 0: none).
    .PARAMETER HistoryMonths
        Depth of history to extrapolate over, in months (default 60).
    .PARAMETER StopFile
        When this file exists the assessment stops after the requests in flight.
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        TeamsTransfer.AssessmentReport (use .ToText() for a summary, .ToJson() for the file).
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.AssessmentReport')]
    param(
        $Client,
        [hashtable]$Configuration,
        $Store,
        [ValidateRange(1, 10000)][int]$SampleUsers = 20,
        [ValidateRange(0, 10000)][int]$SampleTeams = 0,
        [ValidateRange(1, 600)][int]$HistoryMonths = 60,
        [ValidateRange(0, 1000)][int]$CompareChats = 6,
        [ValidateRange(1, 64)][int]$Parallelism = 4,
        [Nullable[double]]$ExportRequestsPerSecond,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration
    $o = [TeamsTransfer.AssessOptions]::new()
    $o.SampleUsers = $SampleUsers; $o.SampleTeams = $SampleTeams; $o.HistoryMonths = $HistoryMonths
    $o.CompareChats = $CompareChats; $o.Parallelism = $Parallelism
    if ($null -ne $ExportRequestsPerSecond) { $o.ExportRequestsPerSecond = $ExportRequestsPerSecond }
    $o.Stop = New-TmtStopControl $StopFile
    $a = [TeamsTransfer.Assessor]::new($client, $o, $Store)
    $cts = [Threading.CancellationTokenSource]::new()
    $task = $a.RunAsync($cts.Token)
    Wait-TmtEngineTask -Task $task -Snapshot { $a.Progress } -Activity 'Assess' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $o.Stop -Client $client
}

function script:Get-TmtUserList {
    param($Users, [string[]]$Columns = @('Id', 'Identity', 'UserPrincipalName', 'Upn', 'Mail'))
    if ($null -eq $Users) { return $null }
    $list = @($Users)
    if ($list.Count -eq 1 -and ($list[0] -is [string]) -and (Test-Path -LiteralPath $list[0] -PathType Leaf)) {
        $rows = Import-Csv -LiteralPath $list[0]
        $col = foreach ($c in $Columns) { if ($rows -and $rows[0].PSObject.Properties[$c]) { $c; break } }
        if (-not $col) { throw "CSV $($list[0]): expected a column $($Columns -join ', ')." }
        return @($rows | ForEach-Object { $_.$col } | Where-Object { $_ })
    }
    return $list
}

function Invoke-TmtExport {
    <#
    .SYNOPSIS
        Exports chats (and optionally channels) to the store. Strategy U (per user), C (per chat) or Auto (U, then C for the conversations
        flagged as containing imported messages). Incremental by default: a second run reads only what changed.
    .PARAMETER Store
        The store to write (an IExportStore; also an IStoreReader for the C strategy, channels and Auto), see Open-TmtStore.
    .PARAMETER Client
        A Graph client (New-TmtGraphClient). Alternative: -Configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Source side is used to build the client.
    .PARAMETER Window
        '24m' / '60m' (the last N months, on lastModifiedDateTime) or 'from..to' (ISO dates). Alternative to -From / -To.
    .PARAMETER From
        Start of the period (read on lastModifiedDateTime).
    .PARAMETER To
        End of the period.
    .PARAMETER Users
        User ids / UPNs, or the path of a CSV with an Id / Identity / UserPrincipalName / Mail column. Default: every user of the store.
    .PARAMETER Teams
        Team ids / display names, or a CSV with an Id / TeamId / DisplayName column: restricts the channel export to them (default: all teams of the store).
    .PARAMETER Conversations
        Conversation keys (chat:<id>, channel:<id>): exports exactly these conversations with strategy C (one by one) and nothing else (-Users, -Teams, -IncludeChannels are not used).
    .PARAMETER AllStoreUsers
        Without -Users, export every non-deleted user of the store instead of only the users linked to a conversation (the ones the inventory covered).
    .PARAMETER IncludeFiles
        Records the file references during the export, then runs the Files stage (download), unless -SkipFileDownload.
    .PARAMETER Full
        Read everything again instead of only what changed since the last run.
    .PARAMETER MaxFileSizeMB
        Files larger than this are not downloaded (0 = no limit).
    .PARAMETER ExcludeExtensions
        File extensions that are not downloaded (for example .iso, .zip).
    .PARAMETER StopFile
        When this file exists the export stops after the requests in flight (run again to resume).
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        TeamsTransfer.ExportResult (with a Files property when the Files stage ran).
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.ExportResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        [ValidateSet('U', 'C', 'Auto')][string]$Strategy = 'Auto',
        [Nullable[datetimeoffset]]$From,
        [Nullable[datetimeoffset]]$To,
        [string]$Window,
        [object]$Users,
        [object]$Teams,
        [switch]$IncludeChannels,
        [switch]$SkipChats,
        [string[]]$Conversations,
        [switch]$AllStoreUsers,
        [switch]$IncludeFiles,
        [switch]$SkipFileDownload,
        [switch]$NoHostedContents,
        [switch]$Full,
        [ValidateRange(1, 64)][int]$UserParallelism = 8,
        [ValidateRange(1, 64)][int]$ConversationParallelism = 8,
        [ValidateRange(0, 100000)][int]$MaxFileSizeMB = 0,
        [string[]]$ExcludeExtensions,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration
    $o = [TeamsTransfer.ExportOptions]::new()
    $o.Strategy = [TeamsTransfer.ExportStrategy]$Strategy
    $o.IncludeChannels = [bool]$IncludeChannels
    $o.IncludeChats = -not $SkipChats
    $o.AllStoreUsers = [bool]$AllStoreUsers
    $o.IncludeFiles = [bool]$IncludeFiles
    $o.IncludeHostedContents = -not $NoHostedContents
    $o.Incremental = -not $Full
    $o.UserParallelism = $UserParallelism; $o.ConversationParallelism = $ConversationParallelism
    if ($ExcludeExtensions) { $o.ExcludedExtensions = $ExcludeExtensions }
    $range = Resolve-TmtWindow $Window
    if ($range) { $o.From = $range.From; if ($null -ne $range.To) { $o.To = $range.To } }
    if ($null -ne $From) { $o.From = $From }
    if ($null -ne $To) { $o.To = $To }
    $o.Stop = New-TmtStopControl $StopFile
    $userList = Get-TmtUserList $Users
    $teamList = Get-TmtUserList $Teams 'Id', 'TeamId', 'DisplayName'
    if ($teamList) { $o.Teams = [string[]]$teamList }

    $exporter = [TeamsTransfer.Exporter]::new($client, $Store, $o, $(if ($Store -is [TeamsTransfer.IStoreReader]) { $Store } else { $null }))
    $cts = [Threading.CancellationTokenSource]::new()
    $shown = [Collections.Generic.HashSet[string]]::new()
    if ($Conversations) { $o.Strategy = [TeamsTransfer.ExportStrategy]::C }
    if (-not $Conversations -and $null -eq $userList -and $o.IncludeChats -and $o.Strategy -ne [TeamsTransfer.ExportStrategy]::C -and $Store -is [TeamsTransfer.IStoreReader]) {
        $resolved = $exporter.ResolveDefaultUsers([bool]$AllStoreUsers)
        if ($resolved.Count -eq 0) {
            $m = 'No user is linked to a conversation in the store: run Inventory first, or pass -Users / -AllStoreUsers.'
            [void]$shown.Add($m); Write-TmtWarn $m
        } elseif ($resolved.Count -gt 1000) {
            $m = 'No -Users given: exporting {0} users {1}. Pass -Users to scope the run.' -f (Format-TmtNumber $resolved.Count), $(if ($AllStoreUsers) { '(-AllStoreUsers)' } else { 'linked to a conversation in the store' })
            [void]$shown.Add($m); Write-TmtWarn $m
        }
        $userList = [string[]]$resolved.ToArray()
    }
    $task = if ($Conversations) { $exporter.ExportConversationsAsync([string[]]@($Conversations | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }), $cts.Token) } else { $exporter.RunAsync([string[]]$userList, $cts.Token) }
    $result = Wait-TmtEngineTask -Task $task -Snapshot { $exporter.Progress } -Activity 'Export' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $o.Stop -Client $client
    Write-TmtDetail $result.Summary
    foreach ($w in $result.Warnings) { if ($shown.Add([string]$w)) { Write-TmtWarn ([string]$w) } }

    if ($IncludeFiles -and -not $SkipFileDownload -and -not $o.Stop.IsRequested) {
        $sink = New-TmtProgressSink
        $fo = [TeamsTransfer.FilesOptions]::new()
        $fo.MaxFileBytes = [int64]$MaxFileSizeMB * 1MB
        if ($ExcludeExtensions) { $fo.ExcludedExtensions = $ExcludeExtensions }
        $fo.Stop = $o.Stop
        $fo.OnProgress = $sink.Action
        $stage = [TeamsTransfer.FilesStage]::new($client, $Store, $fo)
        $t2 = $stage.RunAsync($cts.Token)
        $files = [TeamsTransfer.FilesResult](Wait-TmtEngineTask -Task $t2 -Snapshot $sink.Latest -Activity 'Files' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $o.Stop -Client $client)
        Add-Member -InputObject $result -NotePropertyName Files -NotePropertyValue $files -Force
    }
    return $result
}

function script:Read-TmtLotFile {
    # -LotFile: CSV with the columns Type (User | Team | Chat | Channel), Identity and, optional, Priority (lower runs first, default 100).
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "-LotFile: file not found: $Path" }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "-LotFile $Path has no row: expected the columns Type (User | Team | Chat | Channel), Identity and, optional, Priority." }
    foreach ($c in 'Type', 'Identity') {
        if (-not $rows[0].PSObject.Properties[$c]) { throw "-LotFile $Path : the column $c is missing (expected Type, Identity and, optional, Priority)." }
    }
    $hasPriority = [bool]$rows[0].PSObject.Properties['Priority']
    $line = 1
    foreach ($r in $rows) {
        $line++
        $type = $null
        if (-not [Enum]::TryParse([TeamsTransfer.LotMemberType], ([string]$r.Type).Trim(), $true, [ref]$type) -or ([string]$r.Type).Trim() -match '^\d+$') {
            throw "-LotFile $Path line ${line}: Type '$($r.Type)' is not User, Team, Chat or Channel."
        }
        $identity = ([string]$r.Identity).Trim()
        if (-not $identity) { throw "-LotFile $Path line ${line}: Identity is empty." }
        $priority = 100
        if ($hasPriority -and ([string]$r.Priority).Trim()) {
            if (-not [int]::TryParse(([string]$r.Priority).Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$priority) -or $priority -lt 0) {
                throw "-LotFile $Path line ${line}: Priority '$($r.Priority)' is not a whole number of 0 or more."
            }
        }
        [pscustomobject]@{ Type = [string]$type; Identity = $identity; Priority = $priority }
    }
}

function script:Get-TmtLotMemberKey {
    param([string]$Type, [string]$Identity)
    $id = $Identity.Trim()
    foreach ($p in 'chat:', 'channel:') { if ($id.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { $id = $id.Substring($p.Length); break } }
    return ('{0}|{1}' -f $Type, $id.ToLowerInvariant())
}

function Get-TmtLotMembers {
    <#
    .SYNOPSIS
        The members of a new lot from -Users, -Teams (ids / UPNs / names, or a CSV) and / or -LotFile (CSV: Type, Identity, Priority). Duplicates are removed.
    .DESCRIPTION
        A team given by name is turned into its id with the inventory of the store (a name that is not in the inventory is an error).
    .PARAMETER Store
        An open TeamsTransfer.TmtStore.
    .PARAMETER Users
        Users (ids / UPNs, or the path of a CSV).
    .PARAMETER Teams
        Teams (ids / exact display names, or the path of a CSV).
    .PARAMETER LotFile
        CSV with the columns Type (User | Team | Chat | Channel), Identity and Priority (optional).
    .OUTPUTS
        TeamsTransfer.LotMember[]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [object]$Users, [object]$Teams, [string]$LotFile)
    $members = [Collections.Generic.List[TeamsTransfer.LotMember]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new()
    $byName = @{}
    $resolveTeam = {
        param([string]$Team)
        if ($byName.Count -eq 0) {
            foreach ($c in $Store.ListConversations()) {
                if ($c.TeamId -and [string]$c.Kind -eq 'Channel') { $byName[$c.TeamId] = $c.TeamId; if ($c.TeamDisplayName -and -not $byName.ContainsKey($c.TeamDisplayName)) { $byName[$c.TeamDisplayName] = $c.TeamId } }
            }
        }
        if (-not $byName.ContainsKey($Team)) { throw "Team '$Team' is not in the inventory of the store: run -Mode Inventory first, or check the name." }
        return [string]$byName[$Team]
    }
    $add = {
        param([string]$Type, [string]$Identity, [int]$Priority)
        if ($seen.Add((Get-TmtLotMemberKey $Type $Identity))) { $members.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::$Type, $Identity, $Priority)) }
    }
    foreach ($u in @(Get-TmtUserList $Users)) { if ($u) { & $add 'User' ([string]$u) 100 } }
    foreach ($t in @(Get-TmtUserList $Teams 'Id', 'TeamId', 'DisplayName')) { if ($t) { & $add 'Team' (& $resolveTeam ([string]$t)) 100 } }
    if ($LotFile) {
        foreach ($r in @(Read-TmtLotFile $LotFile)) {
            $identity = if ($r.Type -eq 'Team') { & $resolveTeam $r.Identity } else { $r.Identity }
            & $add $r.Type $identity $r.Priority
        }
    }
    if ($members.Count -eq 0) { throw 'The lot has no member: give -Users, -Teams or a -LotFile with at least one row.' }
    return , $members.ToArray()
}

function Initialize-TmtLot {
    <#
    .SYNOPSIS
        Creates the lot <Name> with these members, or, when it already exists with the SAME members, returns it as it is (idempotent). A lot that
        exists with different members is refused.
    .PARAMETER Store
        An open writable TeamsTransfer.TmtStore.
    .PARAMETER Name
        The name of the lot.
    .PARAMETER Members
        TeamsTransfer.LotMember[] (see Get-TmtLotMembers).
    .PARAMETER Boundaries
        Cumulative wave boundaries in months for a new lot (for example 24, 36, 48, 60).
    .PARAMETER Notes
        Note stored with a new lot.
    .OUTPUTS
        PSCustomObject: Id, Name, Created, SliceCount.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Members, [int[]]$Boundaries = @(24, 36, 48, 60), [string]$Notes)
    $existing = $Store.GetLot($Name)
    if ($existing) {
        $have = @($Store.ListLotMembers($existing.Id) | ForEach-Object { Get-TmtLotMemberKey ([string]$_.Type) ([string]$_.Identity) } | Sort-Object -Unique)
        $want = @($Members | ForEach-Object { Get-TmtLotMemberKey ([string]$_.Type) ([string]$_.Identity) } | Sort-Object -Unique)
        $diff = @(Compare-Object -ReferenceObject $have -DifferenceObject $want)
        if ($diff.Count) {
            $first = $diff[0]
            throw "Lot '$Name' already exists with different members ($($have.Count) in the lot, $($want.Count) requested; for example '$($first.InputObject)' is only $(if ($first.SideIndicator -eq '<=') { 'in the lot' } else { 'in the request' })): use another -Lot name, or leave -Users / -Teams / -LotFile out to use the lot as it is."
        }
        return [pscustomobject]@{ Id = $existing.Id; Name = $Name; Created = $false; SliceCount = @($Store.ListSlices($existing.Id)).Count }
    }
    $lo = [TeamsTransfer.LotOptions]::new()
    $lo.Boundaries = [int[]]$Boundaries
    if ($Notes) { $lo.Notes = $Notes }
    $id = $Store.CreateLot($Name, [TeamsTransfer.LotMember[]]@($Members), $lo)
    return [pscustomobject]@{ Id = $id; Name = $Name; Created = $true; SliceCount = $lo.Boundaries.Count }
}

function Invoke-TmtLotExport {
    <#
    .SYNOPSIS
        Exports the members of a lot and moves the lot Planned -> Exporting -> Exported when everything succeeded.
    .DESCRIPTION
        User and team members are exported like -Users / -Teams of Invoke-TmtExport (strategy U for the chats, channels with -IncludeChannels);
        chat and channel members are exported one by one with strategy C. A lot only exports its own members: without a user member the chats
        of the other users of the store are not read. The lot moves to Exported only when no unit failed, nothing was stopped and the channels
        of its teams were exported (-IncludeChannels); otherwise it stays Exporting and the same command can be run again. A lot in another state
        (ImportPlanned and later) is exported (delta) but its state is left as it is.
    .PARAMETER Store
        An open writable TeamsTransfer.TmtStore.
    .PARAMETER Lot
        Name of the lot.
    .PARAMETER ExportArguments
        The other arguments of Invoke-TmtExport (Client, Strategy, IncludeChannels, Window, parallelism, ...), as a hashtable. Users, Teams and Conversations are set from the lot.
    .PARAMETER LotFile
        CSV with the columns Type (User | Team | Chat | Channel), Identity and Priority (optional): the lot is created with the name -Lot when it does not
        exist, then exported. A lot that exists with other members is refused.
    .OUTPUTS
        PSCustomObject: Scope (LotId, State, Users, Teams, ConversationKeys), Results (one TeamsTransfer.ExportResult per run), Complete, StateMoved, Warnings, LotCreated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Lot, [hashtable]$ExportArguments = @{}, [string]$LotFile)
    $lotCreated = $false
    if ($LotFile) {
        # -LotFile: the lot is created with this name when it does not exist (waves from -Window Nm, else the default 24 / 36 / 48 / 60 months);
        # an existing lot with the same members is exported as it is, an existing lot with other members is refused.
        $w = if ($ExportArguments.ContainsKey('Window')) { [string]$ExportArguments.Window } else { '' }
        $bounds = if ($w -match '^\d+m$') { [int[]](ConvertTo-TmtWindowBoundaries $w) } else { [int[]]@(24, 36, 48, 60) }
        $made = Initialize-TmtLot -Store $Store -Name $Lot -Members (Get-TmtLotMembers -Store $Store -LotFile $LotFile) -Boundaries $bounds -Notes 'created by -Mode Export from a lot file'
        $lotCreated = [bool]$made.Created
    }
    $info = $Store.GetLot($Lot)
    if ($null -eq $info) { throw "Lot '$Lot' not found in the store: check the name (-Mode Status lists the lots)." }
    $members = @($Store.ListLotMembers($info.Id))
    $users = @($members | Where-Object { [string]$_.Type -eq 'User' } | ForEach-Object { $_.Identity })
    $teams = @($members | Where-Object { [string]$_.Type -eq 'Team' } | ForEach-Object { $_.Identity })
    $keys = @($members | Where-Object { [string]$_.Type -in 'Chat', 'Channel' } | ForEach-Object {
            $id = ([string]$_.Identity).Trim(); $prefix = if ([string]$_.Type -eq 'Chat') { 'chat:' } else { 'channel:' }
            if ($id.StartsWith($prefix, [StringComparison]::Ordinal)) { $id } else { $prefix + $id } })
    $scope = [pscustomobject]@{ LotId = $info.Id; State = [string]$info.State; Users = $users; Teams = $teams; ConversationKeys = $keys }
    if (-not $users -and -not $teams -and -not $keys) { throw "Lot '$Lot' has no member to export." }
    $warnings = [Collections.Generic.List[string]]::new()
    $moves = [string]$info.State -in 'Planned', 'Exporting', 'Exported'
    if ($moves) {
        if ([string]$info.State -ne 'Exporting') { [void]$Store.TransitionLot($info.Id, [TeamsTransfer.LotState]::Exporting, 'Export started') }
    } else { $warnings.Add("Lot $Lot is $($info.State): the export reads what changed, the lot state is left as it is.") }
    $complete = $true
    if ($teams -and -not ($ExportArguments.ContainsKey('IncludeChannels') -and $ExportArguments.IncludeChannels)) { $complete = $false; $warnings.Add("Lot $Lot has team member(s): add -IncludeChannels to export their channels (the lot is not marked Exported without them).") }
    $results = [Collections.Generic.List[object]]::new()
    if ($users -or $teams) {
        $a = $ExportArguments.Clone(); $a.Store = $Store
        if ($users) { $a.Users = $users } else { [void]$a.Remove('Users'); $a.SkipChats = $true }
        if ($teams) { $a.Teams = $teams } else { [void]$a.Remove('Teams') }
        $results.Add((Invoke-TmtExport @a))
    }
    if ($keys -and -not ($results.Count -and $results[$results.Count - 1].Stopped)) {
        $a = $ExportArguments.Clone(); $a.Store = $Store
        foreach ($k in 'Users', 'Teams') { [void]$a.Remove($k) }
        $a.Conversations = [string[]]$keys; $a.IncludeChannels = $false
        $results.Add((Invoke-TmtExport @a))
    } elseif ($keys) { $complete = $false }
    foreach ($r in $results) {
        if ($r.Stopped -or $r.UnitsFailed -gt 0 -or $r.Errors.Count -gt 0) { $complete = $false }
        if ($r.PSObject.Properties['Files'] -and $r.Files -and ($r.Files.Failed -gt 0 -or $r.Files.Stopped)) { $complete = $false }
    }
    if ($moves -and $complete) { [void]$Store.TransitionLot($info.Id, [TeamsTransfer.LotState]::Exported, 'Export complete: every unit of the lot succeeded') }
    [pscustomobject][ordered]@{ Scope = $scope; Results = $results.ToArray(); Complete = $complete; StateMoved = $moves; Warnings = $warnings.ToArray(); LotCreated = $lotCreated }
}
function Invoke-TmtFiles {
    <#
    .SYNOPSIS
        Files stage on its own: downloads the file references recorded Pending by the export (resolve via /shares, stream to the store).
    .PARAMETER Store
        The store to write (an IExportStore), see Open-TmtStore.
    .PARAMETER Client
        A Graph client (New-TmtGraphClient). Alternative: -Configuration.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Source side is used to build the client.
    .PARAMETER MaxFileSizeMB
        Files larger than this are recorded as too large and not downloaded (0 = no limit).
    .PARAMETER ExcludeExtensions
        File extensions that are not downloaded.
    .PARAMETER StopFile
        When this file exists the stage stops after the requests in flight (run again to resume).
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        TeamsTransfer.FilesResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.FilesResult')]
    param(
        [Parameter(Mandatory)]$Store,
        $Client,
        [hashtable]$Configuration,
        [ValidateRange(0, 100000)][int]$MaxFileSizeMB = 0,
        [string[]]$ExcludeExtensions,
        [ValidateRange(1, 64)][int]$Parallelism = 4,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    $client = Resolve-TmtClient $Client $Configuration
    $sink = New-TmtProgressSink
    $fo = [TeamsTransfer.FilesOptions]::new()
    $fo.MaxFileBytes = [int64]$MaxFileSizeMB * 1MB
    $fo.Parallelism = $Parallelism
    if ($ExcludeExtensions) { $fo.ExcludedExtensions = $ExcludeExtensions }
    $fo.Stop = New-TmtStopControl $StopFile
    $fo.OnProgress = $sink.Action
    $stage = [TeamsTransfer.FilesStage]::new($client, $Store, $fo)
    $cts = [Threading.CancellationTokenSource]::new()
    Wait-TmtEngineTask -Task $stage.RunAsync($cts.Token) -Snapshot $sink.Latest -Activity 'Files' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $fo.Stop -Client $client
}

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBLeXN5f49lUzTv
# Jf5eiB2zfmEqLn6iX3HGvnv0oUHzLaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBTgpOow/UI
# Vlr/nMBTLS3d6vxMD/i/WJ2M6yzI/PgBbTANBgkqhkiG9w0BAQEFAASCAgBMqd4H
# TLpFsSak9vvRkO+Judf2vFEBq9vCyM/39+5RnVloyaA/BiYSYGp6wqiiCakX4XXf
# JKKzU3769MGhPq6I1zIGdA4m/qfn1U+FpQsL0e4vO6g4cL4bKswONtgxaoYSDj5J
# WHWGAzkQF+jBC1O8uinspUl7GtqR5s0g/xNg+VKIcW/TJSYcBpYewgSiCMHqTjqL
# I3Vz4OHaccSCBgOvDYTfbSbuWKpR5x68d1irCdxG5aeMuSfN59uwSCWiRrWebz/x
# lBwsQSIN1KEren7+dNWapotuHhZ2cdAOYkf8/oERd/C0QCI1Ih7YgixpVMDS08g/
# 8UB4pZprNuXMN3DG5DrgpoQwFS65w6doATKsFJlvch0BU58y0zsz7kqi3IgXEEml
# +QSN4lalsdW4mPyWbjECP4OaqsQfSdxkm+VJLPBJy1IPEQ7a0kA/Pvgy1ah24Nyd
# /S/8GMUz4if6BxgAp9w2K9SMvruj2tGtR6eUNAEXgQwNNjIcd2rG7VmdNA8xD7FY
# 0zJ9oibGy9XF9Hs9SxVfzvx1Mm1YgE8Jx5oaFesKYrcsbg8IXGAFqi3er7REMFfg
# oR2TK5ULbVAFM/kuqsDwik1l6fD+LBSWSXimLaYzJKNbqnlVGuomApO84Dg7ZPgK
# v9uWMIZff5tsSvKRrAJLOFnNXxuPQJZDK/y8n6GCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIKuR9Z81T+U8zG+jDVjhjhykXFP78IWEYGeomreSpXYIAggt3Ne/IT/E
# 7BgPMjAyNjExMTIxNzI0NDdaMAMCAQECEC3wZyMYyveyMnqxzMxNAYugghGnMIIE
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
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMjE3MjQ0N1owKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIPeT
# kTDXuTVg0gaJ3KA31hKzGBD4SH7Sb3/sDsGhpcpMMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiEAmuoMtDlzdoW6yHu0K2O8E4eQb9q3GLztzXa5a541Gc4CIDO0
# Iykef+/NJlu2pqU15WshQpVNdEsq8leuvyT0sMV6
# SIG # End signature block
