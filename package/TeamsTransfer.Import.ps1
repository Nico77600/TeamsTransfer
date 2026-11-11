# TeamsTransfer - thin PowerShell surface over the C# Importer (package\src\Engine.Import.cs).
# Dot-sourced by TeamsTransfer.psm1. All the logic lives in the engine; these functions build the run options, run the async engine,
# show a progress line every -IntervalSeconds by POLLING (a PowerShell scriptblock cannot be called back from engine threads), write the
# report folder (summary.html, conversations.csv, rejected.csv) and map the result onto the exit codes of the entry script.
# The preview is the default: without -Apply nothing is sent to the target tenant and nothing is written to the journal.

function script:New-TmtImportClient {
    # The Target client of an import: same construction as New-TmtGraphClient (certificate, transport, retry) but the rate limiter starts the
    # import class at Graph.ImportRatePerSecond (default 60, the measured ceiling is 60-90 msg/s per application) instead of the general rate;
    # the 5 requests per second per conversation are enforced per ThreadKey by the limiter. AIMD still halves the rate on a 429.
    param([Parameter(Mandatory)][hashtable]$Configuration)
    $g = if ($Configuration.ContainsKey('Graph')) { $Configuration.Graph } else { @{} }
    $options = [TeamsTransfer.GraphClientOptions]::new()
    $options.MaxAttempts = [int](Get-TmtSetting $g 'MaxAttempts' $options.MaxAttempts)
    $options.BaseBackoff = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'BaseBackoffSeconds' $options.BaseBackoff.TotalSeconds))
    $options.MaxBackoff = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'MaxBackoffSeconds' $options.MaxBackoff.TotalSeconds))
    $options.RequestTimeout = [TimeSpan]::FromSeconds([double](Get-TmtSetting $g 'RequestTimeoutSeconds' $options.RequestTimeout.TotalSeconds))
    $options.MaxConcurrency = [int](Get-TmtSetting $g 'ImportMaxConcurrency' ([Math]::Max(64, [int](Get-TmtSetting $g 'MaxConcurrency' $options.MaxConcurrency))))
    $lo = $options.ToRateLimiterOptions()
    $lo.InitialRatePerSecond = [double](Get-TmtSetting $g 'InitialRatePerSecond' $lo.InitialRatePerSecond)
    $lo.InitialRateByClass[[TeamsTransfer.EndpointClass]::ImportMessage] = [double](Get-TmtSetting $g 'ImportRatePerSecond' 60)
    $limiter = [TeamsTransfer.AdaptiveRateLimiter]::new($lo)
    $s = if ($Configuration.ContainsKey('Target')) { $Configuration.Target } else { @{} }
    foreach ($k in 'TenantId', 'ClientId', 'CertificateThumbprint') {
        if (-not (Get-TmtSetting $s $k $null)) { throw "Configuration.Target.$k is empty: fill it in config\TeamsTransfer.config.local.psd1." }
    }
    $cloud = [TeamsTransfer.GraphCloud](Get-TmtSetting $s 'Cloud' 'Global')
    $tokens = [TeamsTransfer.CertificateTokenProvider]::FromThumbprint([string]$s.TenantId, [string]$s.ClientId, [string]$s.CertificateThumbprint, $cloud, $null)
    $transport = [TeamsTransfer.HttpGraphTransport]::new($tokens, $cloud, 128, $null)
    $metrics = [TeamsTransfer.GraphMetrics]::new()
    $client = [TeamsTransfer.GraphClient]::new($transport, $options, $limiter, [Action[TeamsTransfer.GraphEvent]]$metrics.OnEvent)
    $metrics.Attach($client)
    return $client
}

function Invoke-TmtImport {
    <#
    .SYNOPSIS
        Imports the messages of a lot into the target tenant with the Teams migration API (startMigration, import, completeMigration), or previews it.
    .DESCRIPTION
        Resumable and idempotent: a journal in the store records every message (Imported, Conflict409TreatedAsImported, Rejected, Skipped);
        a message is never sent twice, and a message sent before an interruption is recognised by the 409 the service answers on the second try.
        Conversations are imported in parallel (-ConversationParallelism), each at no more than 5 requests per second. The lot must be planned
        (state ImportPlanned or later, see the Plan mode). Without -Apply the cmdlet only previews: it builds the exact requests, counts them per
        endpoint, keeps the first payloads (redacted) and sends nothing.
    .PARAMETER Store
        An open TeamsTransfer.TmtStore (Open-TmtStore). It also serves the identity, target and file maps unless they are passed.
    .PARAMETER Lot
        Name of the lot to import.
    .PARAMETER Slices
        Numbers of the time slices to import (default: all). Wave 1 is slice 1; later waves are older.
    .PARAMETER Apply
        Perform the import. Without it, the preview.
    .PARAMETER Client
        A Graph client of the TARGET tenant (New-TmtGraphClient -Side Target). Alternative: -Configuration. Optional for a preview.
    .PARAMETER Configuration
        The hashtable returned by Import-TmtConfiguration; the Target side is used to build the client and its ClientId is the owner application of the sessions.
    .PARAMETER ConversationParallelism
        Conversations imported at the same time (default 32). The per-conversation limit stays 5 requests per second.
    .PARAMETER StopFile
        When this file exists the import stops between two messages (the conversation stays in migration mode, run the same command again to resume).
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .PARAMETER IdentityMap
        Identity map (default: the store).
    .PARAMETER TargetMap
        Target map (default: the store).
    .PARAMETER FileMap
        File copy map (default: the store).
    .PARAMETER ServiceAccount
        Object id or UPN of the service account: fallback author, owner of the teams the import creates. Default: Target.ServiceAccountUserId of the configuration, else the target id of the first identity of kind ServiceAccount.
    .PARAMETER AppId
        Application id of the target app (recorded in the journal; the same application must start, import and complete). Default: Target.ClientId of the configuration.
    .PARAMETER Tuning
        A TeamsTransfer.ImportTuning (waiting times, batch size). Tests only.
    .OUTPUTS
        TeamsTransfer.ImportResult
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.ImportResult')]
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Lot,
        [int[]]$Slices,
        [switch]$Apply,
        $Client,
        [hashtable]$Configuration,
        [ValidateRange(1, 256)][int]$ConversationParallelism = 32,
        [string]$StopFile,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5,
        $IdentityMap,
        $TargetMap,
        $FileMap,
        [Alias('ServiceAccountUserId')][string]$ServiceAccount,
        [string]$AppId,
        [ValidateSet('TenantToTenant', 'SameTenantRestore', 'DepartedArchive')][string]$Scenario = 'TenantToTenant',
        [string]$FallbackBannerFormat,
        $Tuning
    )
    $info = $Store.GetLot($Lot)
    if ($null -eq $info) { throw "Lot '$Lot' not found in the store: check the name (-Mode Status lists the lots)." }
    foreach ($m in @(@('IdentityMap', 'IIdentityMap'), @('TargetMap', 'ITargetMap'), @('FileMap', 'IFileCopyMap'))) {
        $given = Get-Variable -Name $m[0] -ValueOnly
        if ($null -eq $given) {
            if ($Store -is [type]("TeamsTransfer.$($m[1])")) { Set-Variable -Name $m[0] -Value $Store }
            else { throw "No $($m[0]): the store does not hold the import maps. Run the Plan mode first, or pass -$($m[0])." }
        }
    }
    $client = $Client
    if ($null -eq $client -and $Configuration -and $Apply) { $client = New-TmtImportClient -Configuration $Configuration }
    if ($Apply -and $null -eq $client) { throw 'Apply needs the Target Graph client: pass -Client, or -Configuration with the Target section filled.' }
    if (-not $AppId -and $Configuration -and $Configuration.Target -is [System.Collections.IDictionary]) { $AppId = [string](Get-TmtSetting $Configuration.Target 'ClientId' '') }
    if (-not $AppId) { $AppId = 'target-app' }
    # The service account (owner of the teams the import creates, fallback author): parameter, then Target.ServiceAccountUserId of the configuration,
    # then the plan checkpoint, then the planner's ServiceAccount identity. A UPN is resolved with GET /users when a client is available.
    $svc = Resolve-TmtServiceAccount -Store $Store -Lot $Lot -Configuration $Configuration -ServiceAccount $ServiceAccount -IdentityMap $IdentityMap -Client $client -AllowUnresolved
    $ServiceAccount = if ($svc) { $svc.Id } else { '' }
    if (-not $ServiceAccount) { Write-Verbose 'No service account known: the engine refuses to start if a team has to be created without any planned member.' }
    $o = [TeamsTransfer.ImportRunOptions]::new()
    $o.Apply = [bool]$Apply
    $o.Scenario = [TeamsTransfer.ImportScenario]$Scenario
    $o.ConversationParallelism = $ConversationParallelism
    if ($ServiceAccount) { $o.ServiceAccountUserId = $ServiceAccount }
    if ($FallbackBannerFormat) { $o.FallbackBannerFormat = $FallbackBannerFormat }
    $o.Stop = New-TmtStopControl $StopFile

    $imp = [TeamsTransfer.Importer]::new($client, $Store, $IdentityMap, $TargetMap, $FileMap, $o, $AppId)
    if ($Tuning) { $imp.Tuning = $Tuning }
    $cts = [Threading.CancellationTokenSource]::new()
    $sliceArray = if ($Slices) { [int[]]$Slices } else { [int[]]@() }
    $task = $imp.RunAsync([long]$info.Id, $sliceArray, $cts.Token)
    $result = Wait-TmtEngineTask -Task $task -Snapshot { $imp.Progress } -Activity 'Import' -Cts $cts -IntervalSeconds $IntervalSeconds -Stop $o.Stop -Client $client
    foreach ($w in $result.Warnings) { Write-TmtWarn ([string]$w) }
    return $result
}

function Get-TmtImportExitCode {
    <#
    .SYNOPSIS
        The exit code of an import run: 3 rejected messages or uncertain items, 2 stopped or not complete (resumable), 0 complete or preview.
    .DESCRIPTION
        Order 3, 2, 0 (1 is raised by the caller when the run itself failed). A preview always exits 0.
    .PARAMETER Result
        The TeamsTransfer.ImportResult returned by Invoke-TmtImport.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Result)
    if (-not $Result.Applied) { return 0 }
    if ($Result.MessagesRejectedTotal -gt 0 -or $Result.MessagesRejected -gt 0 -or $Result.ItemsUncertain -gt 0) { return 3 }
    if ($Result.Stopped -or $Result.ItemsIncomplete -gt 0 -or $Result.ItemsFailed -gt 0) { return 2 }
    return 0
}

function script:ConvertTo-TmtCsvLine {
    param([object[]]$Values)
    ($Values | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ','
}

function Write-TmtImportReport {
    <#
    .SYNOPSIS
        Writes the report folder of an import run: summary.html, conversations.csv, rejected.csv (and, for a preview, requests.csv and samples.json).
    .PARAMETER Result
        The TeamsTransfer.ImportResult.
    .PARAMETER Folder
        The folder to write (created when missing), usually reports\yyyy-MM-dd_HHmmss_Import.
    .PARAMETER Store
        The store, to list the rejected messages of the journal.
    .OUTPUTS
        System.String - the folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Folder, $Store)
    [void][IO.Directory]::CreateDirectory($Folder)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $inv = [Globalization.CultureInfo]::InvariantCulture

    # conversations.csv
    $lines = [Collections.Generic.List[string]]::new()
    if ($Result.Applied) {
        $lines.Add('Conversation,Slice,Fragment,TargetKind,TargetId,State,Imported,Conflict409,Rejected,Skipped,Pending,Seconds,MessagesPerSecond,Error')
        foreach ($c in $Result.Conversations) {
            $lines.Add((ConvertTo-TmtCsvLine @($c.ConversationKey, $c.SliceNo, $c.Fragment, $c.TargetKind, $c.TargetId, $c.State, $c.Imported, $c.Conflicts, $c.Rejected, $c.Skipped, $c.Pending,
                    $c.Seconds.ToString('0.0', $inv), $c.MessagesPerSecond.ToString('0.0', $inv), $c.Error)))
        }
    } else {
        $lines.Add('Conversation,Slice,TargetKind,Messages,Replies,Skipped,Rejected,Requests,EstimatedSeconds')
        foreach ($c in $Result.DryRun.Conversations) {
            $lines.Add((ConvertTo-TmtCsvLine @($c.ConversationKey, $c.SliceNo, $c.TargetKind, $c.Messages, $c.Replies, $c.Skipped, $c.Rejected, $c.Requests, $c.EstimatedSeconds.ToString('0.0', $inv))))
        }
    }
    [IO.File]::WriteAllText((Join-Path $Folder 'conversations.csv'), ($lines -join "`r`n") + "`r`n", $utf8)

    # rejected.csv: the journal is the source of truth (this run and the earlier ones)
    $rej = [Collections.Generic.List[string]]::new()
    $rej.Add('Conversation,Slice,MessageId,Code')
    if ($Result.Applied -and $null -ne $Store) {
        $seen = [Collections.Generic.HashSet[string]]::new()
        foreach ($c in $Result.Conversations) {
            if (-not $seen.Add("$($c.ConversationKey)#$($c.SliceNo)")) { continue }
            foreach ($e in $Store.ListJournal($c.ConversationKey, [int]$c.SliceNo, [TeamsTransfer.JournalStatus]::Rejected)) {
                $rej.Add((ConvertTo-TmtCsvLine @($e.ConversationKey, $e.SliceNo, $e.SourceMessageId, $e.ErrorCode)))
            }
        }
    }
    [IO.File]::WriteAllText((Join-Path $Folder 'rejected.csv'), ($rej -join "`r`n") + "`r`n", $utf8)

    # preview extras
    if (-not $Result.Applied -and $Result.DryRun) {
        $req = [Collections.Generic.List[string]]::new(); $req.Add('Endpoint,Requests')
        foreach ($k in $Result.DryRun.RequestsByEndpoint.Keys) { $req.Add((ConvertTo-TmtCsvLine @($k, $Result.DryRun.RequestsByEndpoint[$k]))) }
        [IO.File]::WriteAllText((Join-Path $Folder 'requests.csv'), ($req -join "`r`n") + "`r`n", $utf8)
        # the redacted body is embedded as it is (ConvertFrom-Json would turn the dates into DateTime values and lose the milliseconds)
        $samples = @($Result.DryRun.Samples | ForEach-Object {
                '  {{"method":{0},"url":{1},"conversation":{2},"body":{3}}}' -f (ConvertTo-Json -InputObject $_.Method -Compress), (ConvertTo-Json -InputObject $_.Url -Compress), (ConvertTo-Json -InputObject $_.ConversationKey -Compress), $_.BodyJson
            })
        [IO.File]::WriteAllText((Join-Path $Folder 'samples.json'), "[`r`n" + ($samples -join ",`r`n") + "`r`n]`r`n", $utf8)
    }

    # summary.html
    $row = { param($k, $v) '<tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (& $enc $k), (& $enc $(if ($v -is [long] -or $v -is [int]) { Format-TmtNumber $v } else { $v })) }
    $rows = [Collections.Generic.List[string]]::new()
    $rows.Add((& $row 'Lot' $Result.LotName))
    $rows.Add((& $row 'Mode' $(if ($Result.Applied) { 'Apply' } else { 'Preview (nothing was sent)' })))
    $rows.Add((& $row 'Duration' (Format-TmtDuration $Result.Elapsed.TotalSeconds)))
    $rows.Add((& $row 'Items' "$($Result.ItemsTotal) ($($Result.ItemsCompleted) completed, $($Result.ItemsIncomplete) incomplete, $($Result.ItemsFailed) failed, $($Result.ItemsUncertain) uncertain, $($Result.ItemsSkipped) skipped)"))
    if ($Result.Applied) {
        foreach ($p in @(@('Messages imported', $Result.MessagesImported), @('Already imported (409)', $Result.MessagesConflict409), @('Rejected', $Result.MessagesRejected),
                @('Skipped (system events, deleted)', $Result.MessagesSkipped), @('Still pending', $Result.MessagesPending), @('Date shifts (+1 ms)', $Result.DateShifts),
                @('Files copied before the messages', $Result.FilesCopied), @('Files not copied', $Result.FilesFailed), @('Chats created', $Result.ChatsCreated), @('Teams created', $Result.TeamsCreated), @('Channels created', $Result.ChannelsCreated),
                @('Answers 400 / 403 / 409', "$($Result.Status400) / $($Result.Status403) / $($Result.Status409)"),
                @('Throttled 429 / 503', "$($Result.Throttled429) / $($Result.Throttled503)"),
                @('Messages per second', $Result.MessagesPerSecond.ToString('0.0', $inv)))) { $rows.Add((& $row $p[0] $p[1])) }
        foreach ($k in ($Result.RequestsByClass.Keys | Sort-Object)) { $rows.Add((& $row "Requests $k" $Result.RequestsByClass[$k])) }
        foreach ($k in ($Result.DroppedByReason.Keys | Sort-Object)) { $rows.Add((& $row "Dropped $k" $Result.DroppedByReason[$k])) }
    } else {
        $d = $Result.DryRun
        foreach ($p in @(@('Messages to import', $d.MessagesToImport), @('Messages skipped', $d.MessagesSkipped), @('Messages rejected (no author)', $d.MessagesRejected),
                @('Conversations to create', $d.ConversationsToCreate), @('Files to copy', $d.FilesToCopy), @('Requests', $d.TotalRequests), @('Estimated duration', (Format-TmtDuration $d.EstimatedDuration.TotalSeconds)))) { $rows.Add((& $row $p[0] $p[1])) }
        foreach ($k in $d.RequestsByEndpoint.Keys) { $rows.Add((& $row $k $d.RequestsByEndpoint[$k])) }
        foreach ($k in $d.DroppedByReason.Keys) { $rows.Add((& $row "Dropped $k" $d.DroppedByReason[$k])) }
    }
    $slow = ''
    if ($Result.Slowest.Count -gt 0) {
        $slow = '<h2>Slowest conversations</h2><table>' + (($Result.Slowest | ForEach-Object { '<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f (& $enc $_.ConversationKey), (& $enc (Format-TmtNumber ($_.Imported + $_.Conflicts))), (& $enc (Format-TmtDuration $_.Seconds)) }) -join "`n") + '</table>'
    }
    $err = ''
    if ($Result.Errors.Count -gt 0) { $err = '<h2>Errors</h2><pre>' + (& $enc ((@($Result.Errors | Select-Object -First 50 | ForEach-Object { $_.ToString() })) -join "`n")) + '</pre>' }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teams Transfer - Import report</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1b1b1f;--muted:#5f6368;--line:#d9dbe0}
@media (prefers-color-scheme:dark){:root{--bg:#1b1b1f;--fg:#ececf1;--muted:#a0a3ab;--line:#3a3b42}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif;margin:0 auto;padding:24px 16px;max-width:820px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:24px 0 6px}p{color:var(--muted);margin:0 0 20px}table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}th{font-weight:600;width:50%}td{font-variant-numeric:tabular-nums}
pre{white-space:pre-wrap;border:1px solid var(--line);padding:10px;border-radius:6px}
</style></head><body>
<h1>Teams Transfer - Import$(if (-not $Result.Applied) { ' (preview)' })</h1>
<p>Lot $(& $enc $Result.LotName) &middot; $(& $enc ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $inv)))</p>
<table>
$($rows -join "`n")
</table>
$slow
$err
<p>conversations.csv lists every conversation; rejected.csv lists the messages the service refused (with its code).</p>
</body></html>
"@
    [IO.File]::WriteAllText((Join-Path $Folder 'summary.html'), $html, $utf8)
    return $Folder
}
