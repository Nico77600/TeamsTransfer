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

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDsEf9Z74KUd399
# JTdcKcE0UW1P3vaYl8DlwUdCKOB1YaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBtRC/JYyTg
# kKTPWX6yLACPRuxWXaWMexrZpuKXuZvR8jANBgkqhkiG9w0BAQEFAASCAgB9/LUs
# SK5W59dx+kUHacwXsQPI3BTFC1Pr7Gl9V1n69q2GolSmHUtc2Ry+F1L+bFJCXoUy
# 6a6ix2FEG4wCJbvtLg7cZjguZEjAfISbsjPEafjEphS6ZUN/O8jFkLHrNd9EUrxY
# jU6kCr5zhFkYBt+14kM3mhBOWjZD2Wq+9OpWo3kxei7nEBvG5+FQvCC5h3+uPntx
# l/aTvmDxOdt2WQ58QX/xdp+Id9WV3PBEaLrG/tKF8wt1/MoFM6Kp2CC2txWzU+0t
# aioI7gy4fo2wGs30MuuBGTu0Mx60bRYzllKrgPAKLkF7wYSuYwRxLbu9qdy3hJwG
# 6+li2BOJU3YZvCCmk0VFSgDeWF3IQ4VAHehN1Pby5q6JlnA2KZQCS9mACpgAooxv
# YX7cupsvqnqlnZJ4ak589a4h3CFyVNXrTp1h2QbbB3ywzVrxSfCMz5mwIaexa8gv
# iCOkwhwuHXiYCLZC/OW0W7mf1IvWlELKDpnp5VjgA2b115eYJRVchRpknB3mqiIA
# GtJ50K3CbZoictsURrJ2Q9DRYxJ2hnIWlKqZk+Re4no2nahlA1YgaU/JkvCXtyC2
# QFv18cNq5in7Pm6bMqPw8JZ7ZqS9n3L4Roif7pl6o43fhAESXNakU3zVvD3tQ13p
# 8OJvAR4pwZefZ2fSbsTkK0gY3uiZRDyaE20D16GCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIGK6OAJcav0JF5RGEmm9chZHL0kDE+bJ50Yszfh2wTr3AgghyeWSP9sU
# hxgPMjAyNjExMTExNzU3MzZaMAMCAQECEGeMB/OwY77Ofv4YF957DCqgghGnMIIE
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
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMTE3NTczNlowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIIeV
# xcXCRKtsw94yxzp4ptR2iX+MqFaRJIkWXh6DapqOMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiBM10KPVxVU3GE9Ukbep51eZF4oLTfEysjRfpB9iB8v3gIhALL9
# MK0TFeMa2dbjuUY7+EpMw+13o99mF7FvfOFSvooX
# SIG # End signature block
