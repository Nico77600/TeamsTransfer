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
    # -LotFile: CSV with the columns Type (User | Team | Chat | Channel), Identity and, optional, Priority (lower runs first, default 100). Design 3.7.
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
