# TeamsTransfer console - the jobs. Dot-sourced twice: by the console (to describe the commands) and by every background runspace that
# runs a job. This file defines functions only and holds no WPF code, so a job (and the tests) run without a window.
#
# A job calls the SAME module functions as Invoke-TeamsTransfer.ps1 (Invoke-TmtExport, New-TmtImportPlan, Invoke-TmtImport ...) with the same
# arguments; it adds nothing of its own to what is read or written. Differences from the command line, all on the operator's side:
#   - there is no confirmation question: the console asks before it starts an Apply job (and shows what it will write and where);
#   - the progress lines go to the house log (Start-TmtLog), which the console shows in its log pane;
#   - in Demo mode the Graph clients are fake clients over the synthetic tenants (package\demo), never the network.

function New-TtgDemoClient {
    # A GraphClient over a FakeGraphTransport (the fake tenant of the Demo mode). The manual clock makes retries instant.
    # -Extended: the target side also answers users, groups and file uploads (GfGraphTransport of the demo sources), which the Ghosts and Copy files stages need.
    # The wrapper keeps the users and groups it creates (the ghost accounts): it is kept in -World so that every step of a run sees the same target tenant.
    param([Parameter(Mandatory)]$Tenant, [switch]$Extended, [hashtable]$World)
    $fake = $null
    if ($Extended -and $World -and $World.TargetTransport) { $fake = $World.TargetTransport }
    else {
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($Tenant)
        if ($Extended) { $fake = [TeamsTransfer.Testing.GfGraphTransport]::new($fake, $Tenant); if ($World) { $World.TargetTransport = $fake } }
    }
    $o = [TeamsTransfer.GraphClientOptions]::new()
    $o.Clock = [TeamsTransfer.TestManualClock]::new(); $o.MaxAttempts = 2
    $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(2); $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
    return [TeamsTransfer.GraphClient]::new($fake, $o, $null)
}

function Split-TtgList {
    # "a, b;c" -> @('a','b','c'). Empty -> empty array.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TtgModeNeeds {
    # Which tenant a mode talks to, whether it writes into the target tenant, and its title: one table for the pages, the confirmation and the tests.
    param([Parameter(Mandatory)][string]$Mode)
    switch ($Mode) {
        'Assess'    { @{ Side = 'Source'; Writes = $false; Store = $false; Title = 'Assess the source tenant' } }
        'Inventory' { @{ Side = 'Source'; Writes = $false; Store = $true; Title = 'Inventory' } }
        'Export'    { @{ Side = 'Source'; Writes = $false; Store = $true; Title = 'Export' } }
        'Files'     { @{ Side = 'Source'; Writes = $false; Store = $true; Title = 'Download files' } }
        'Plan'      { @{ Side = 'Target'; Writes = $false; Store = $true; Title = 'Plan and mapping' } }
        'Ghosts'    { @{ Side = 'Target'; Writes = $true; Store = $true; Title = 'Ghost accounts' } }
        'CopyFiles' { @{ Side = 'Target'; Writes = $true; Store = $true; Title = 'Copy files' } }
        'Import'    { @{ Side = 'Target'; Writes = $true; Store = $true; Title = 'Import' } }
        'Verify'    { @{ Side = 'Target'; Writes = $false; Store = $true; Title = 'Verify' } }
        'Report'    { @{ Side = $null; Writes = $false; Store = $true; Title = 'Reports' } }
        default { throw "Unknown mode '$Mode'." }
    }
}

function ConvertTo-TtgCommandLine {
    # The command line that does the same as the job, on one copyable line (shown on every page).
    param([Parameter(Mandatory)][string]$Mode, [hashtable]$Params = @{}, [string]$StoreRoot, [bool]$Apply)
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('.\Invoke-TeamsTransfer.ps1'); $parts.Add("-Mode $Mode")
    if ($StoreRoot -and $Mode -ne 'Assess') { $parts.Add("-StoreRoot $(if ($StoreRoot -match '\s') { "'$StoreRoot'" } else { $StoreRoot })") }
    foreach ($k in ($Params.Keys | Sort-Object)) {
        $v = $Params[$k]
        if ($v -is [bool]) { if ($v) { $parts.Add("-$k") }; continue }
        $text = (@($v) | ForEach-Object { [string]$_ }) -join ','
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '\s') { $text = "'" + $text.Replace("'", "''") + "'" }
        $parts.Add("-$k $text")
    }
    if ($Apply) { $parts.Add('-Apply') }
    return ($parts -join ' ')
}

function New-TtgRunFolder {
    # <OutRoot>\reports\yyyy-MM-dd_HHmmss_<Mode>, -1, -2 on a collision (same rule as the command line).
    param([Parameter(Mandatory)][string]$OutRoot, [Parameter(Mandatory)][string]$Mode)
    $name = '{0}_{1}' -f (Get-Date).ToString('yyyy-MM-dd_HHmmss', [Globalization.CultureInfo]::InvariantCulture), $Mode
    $base = Join-Path (Join-Path $OutRoot 'reports') $name
    $path = $base; $i = 0
    while (Test-Path -LiteralPath $path) { $i++; $path = "$base-$i" }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Save-TtgRunReport {
    # TeamsTransfer_<Mode>.csv (counters), .json (detail) and .html (readable summary), UTF-8 without BOM: the layout of the command line.
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][System.Collections.IDictionary]$Counts, $Detail, [string[]]$Notes = @(), [string]$StoreRoot)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $stem = Join-Path $Folder "TeamsTransfer_$Mode"
    $csv = [Collections.Generic.List[string]]::new(); $csv.Add('Name,Value')
    foreach ($k in $Counts.Keys) { $csv.Add(('"{0}","{1}"' -f ([string]$k).Replace('"', '""'), ([string]$Counts[$k]).Replace('"', '""'))) }
    [IO.File]::WriteAllText("$stem.csv", ($csv -join "`r`n") + "`r`n", $utf8)
    if ($null -ne $Detail) { try { [IO.File]::WriteAllText("$stem.json", ($Detail | ConvertTo-Json -Depth 6), $utf8) } catch { Write-TmtLog WARN "Detail file not written: $($_.Exception.Message)" } }
    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $rows = ($Counts.Keys | ForEach-Object { '<tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (& $enc $_), (& $enc $(if ($Counts[$_] -is [long] -or $Counts[$_] -is [int]) { Format-TmtNumber $Counts[$_] } else { $Counts[$_] })) }) -join "`n"
    $noteHtml = if ($Notes) { '<h2>Notes</h2><pre>' + (& $enc ($Notes -join "`n")) + '</pre>' } else { '' }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teams Transfer - $(& $enc $Mode) report</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1b1b1f;--muted:#5f6368;--line:#d9dbe0}
@media (prefers-color-scheme:dark){:root{--bg:#1b1b1f;--fg:#ececf1;--muted:#a0a3ab;--line:#3a3b42}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif;margin:0 auto;padding:24px 16px;max-width:760px}
h1{font-size:22px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px}table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}th{font-weight:600;width:55%}td{font-variant-numeric:tabular-nums}
pre{white-space:pre-wrap;border:1px solid var(--line);padding:10px;border-radius:6px}
</style></head><body>
<h1>Teams Transfer - $(& $enc $Mode)</h1>
<p>Console run &middot; $(& $enc (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)) &middot; store $(& $enc $StoreRoot)</p>
<table>
$rows
</table>
$noteHtml
</body></html>
"@
    [IO.File]::WriteAllText("$stem.html", $html, $utf8)
}

function Invoke-TtgJobBody {
    <#
    .SYNOPSIS
        Runs one mode of Teams Transfer for the console: the same module function and the same arguments as Invoke-TeamsTransfer.ps1.
    .DESCRIPTION
        Meant for a background runspace (and for the tests). Returns an object: Mode, ExitCode (0 complete, 1 failed, 2 resumable, 3 uncertain),
        Failure, Counts, Report (folder), Log, Next, Lines. It never throws for an operational failure: the failure is in the result.
    .PARAMETER Job
        Hashtable: Mode, Params (CLI parameter names), Apply, StopFile, PackageRoot, StoreRoot, OutRoot, LogFolder, ConfigPath, IntervalSeconds,
        Demo (bool), Support (C# files of the Demo mode), World (@{ Source; Target } fake tenants of the Demo mode).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    $J = $Job
    $mode = [string]$J.Mode
    $P = if ($J.Params) { $J.Params } else { @{} }
    $apply = [bool]$J.Apply
    $stopFile = [string]$J.StopFile
    $interval = if ($J.IntervalSeconds) { [int]$J.IntervalSeconds } else { 1 }
    $needs = Get-TtgModeNeeds $mode
    $dryRun = $needs.Writes -and -not $apply
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $counts = [ordered]@{}
    $previewTitle = ''; $previewLines = @(); $issues = @(); $exit = 0; $failure = $null; $reportPath = $null; $next = $null; $store = $null; $detail = $null; $notes = @()
    $logPath = $null; $lastLot = ''
    $en = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    [Threading.Thread]::CurrentThread.CurrentCulture = $en; [Threading.Thread]::CurrentThread.CurrentUICulture = $en
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'
    try {
        Import-Module (Join-Path $J.PackageRoot 'TeamsTransfer.psd1') -Force
        if ($J.Demo) { Initialize-TmtEngine -AdditionalSource @($J.Support) } else { Initialize-TmtEngine }
        $logPath = Start-TmtLog -Directory $J.LogFolder -RetentionDays 14
        Reset-TmtRunIssues
        Write-TmtLog STEP ("Console job: {0}{1}" -f $mode, $(if ($needs.Writes) { $(if ($dryRun) { ' (preview, nothing is written)' } else { ' (APPLY)' }) } else { '' }))

        $config = if ($J.Demo) {
            @{ Source = @{ Cloud = 'Global'; TenantId = 'demo-source-tenant'; ClientId = 'demo-source-app'; CertificateThumbprint = 'DEMO' }
               Target = @{ Cloud = 'Global'; TenantId = 'demo-target-tenant'; ClientId = 'demo-target-app'; CertificateThumbprint = 'DEMO' }
               Graph = @{}; Store = @{ Path = ''; Partitions = 8 }; Output = @{ Root = [string]$J.OutRoot }; Logging = @{ RetentionDays = 14 }; Ghosts = @{} }
        } elseif ($J.ConfigPath) { Import-TmtConfiguration -Path $J.ConfigPath } else { Import-TmtConfiguration }
        $partitions = [int]$config.Store.Partitions
        $newClient = {
            param([string]$Side)
            if ($J.Demo) { if ($Side -eq 'Source') { return New-TtgDemoClient -Tenant $J.World.Source }; return New-TtgDemoClient -Tenant $J.World.Target -Extended -World $J.World }
            return New-TmtGraphClient -Configuration $config -Side $Side
        }
        $assertNotStopped = {
            if ($stopFile -and (Test-Path -LiteralPath $stopFile)) {
                Write-TmtItem WARN 'stop requested: the requests in flight finish first, run the same job again to resume'
                throw [OperationCanceledException]::new('Stop requested.')
            }
        }
        $stopRequested = { [bool]($stopFile -and (Test-Path -LiteralPath $stopFile)) }
        $openStore = {
            param([switch]$ReadOnly, [switch]$MustExist)
            $catalog = Join-Path $J.StoreRoot 'catalog.db'
            if (($ReadOnly -or $MustExist) -and -not (Test-Path -LiteralPath $catalog)) { throw "No store at $($J.StoreRoot): run Inventory or Export first, or choose another store." }
            if ($ReadOnly) { return Open-TmtStore -Root $J.StoreRoot -ReadOnly }
            return Open-TmtStore -Root $J.StoreRoot -Partitions $partitions
        }
        $lotScope = {
            param($Store, [string]$Name)
            $info = $Store.GetLot($Name)
            if ($null -eq $info) { throw "Lot '$Name' not found in the store." }
            $members = @($Store.ListLotMembers($info.Id))
            [pscustomobject]@{ Users = @($members | Where-Object { [string]$_.Type -eq 'User' } | ForEach-Object { $_.Identity }); Teams = @($members | Where-Object { [string]$_.Type -eq 'Team' } | ForEach-Object { $_.Identity }) }
        }
        $users = Split-TtgList ([string]($P.Users -join ','))
        $teams = Split-TtgList ([string]($P.Teams -join ','))
        $lot = [string]$P.Lot
        $excl = Split-TtgList ([string]($P.ExcludeExtensions -join ','))
        $maxMb = if ($P.MaxFileSizeMB) { [int]$P.MaxFileSizeMB } else { 0 }
        $report = $null

        switch ($mode) {
            'Assess' {
                & $assertNotStopped
                $client = & $newClient 'Source'
                $r = Invoke-TmtAssess -Client $client -SampleUsers ([int]$P.SampleUsers) -SampleTeams ([int]$P.SampleTeams) -HistoryMonths ([int]$P.HistoryMonths) -StopFile $stopFile -IntervalSeconds $interval
                foreach ($line in ($r.ToText() -split "`r?`n" | Where-Object { $_ })) { Write-TmtInfo $line }
                $counts.users = [long]$r.TotalUsers; $counts.sampled = [long]$r.SampledUsers; $counts.chats = [long][Math]::Round($r.Chats); $counts.messages = [long][Math]::Round($r.Messages); $counts.errors = [long]$r.SampleErrors
                $detail = $r.ToJson() | ConvertFrom-Json; $notes = @($r.ToText() -split "`r?`n")
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                [IO.File]::WriteAllText((Join-Path $reportPath 'TeamsTransfer_Assess.txt'), $r.ToText(), [Text.UTF8Encoding]::new($false))
                if (& $stopRequested) { $exit = 2 }
                $next = 'Inventory'
            }
            'Inventory' {
                & $assertNotStopped
                $store = & $openStore
                $client = & $newClient 'Source'
                $ia = @{ Store = $store; Client = $client; SkipChats = [bool]$P.SkipChats; StopFile = $stopFile; IntervalSeconds = $interval }
                if ($P['UserParallelism']) { $ia.UserParallelism = [int]$P['UserParallelism'] }
                if ($users) { $ia.Users = $users }
                if ($teams) { $ia.Teams = $teams }
                $r = Invoke-TmtInventory @ia
                $detail = $r
                $counts.users = [long]$r.Users; $counts.chats = [long]$r.Chats; $counts.teams = [long]$r.Teams; $counts.channels = [long]$r.Channels; $counts.errors = [long]$r.Errors.Count
                Write-TmtOk "$(Format-TmtNumber $r.Users) users ($(Format-TmtNumber $r.DeletedUsers) deleted, $(Format-TmtNumber $r.GuestUsers) guests), $(Format-TmtNumber $r.Chats) chats, $(Format-TmtNumber $r.Teams) teams, $(Format-TmtNumber $r.Channels) channels" -Icon Chat
                foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                if ($r.Stopped -or (& $stopRequested) -or $r.Errors.Count -gt 0) { $exit = 2 }
                $next = 'Export'
            }
            'Export' {
                & $assertNotStopped
                $store = & $openStore
                $eu = $users; $et = $teams
                if ($lot) {
                    $scope = & $lotScope $store $lot
                    $eu = $scope.Users; $et = $scope.Teams
                    Write-TmtInfo "Lot ${lot}: $(Format-TmtNumber @($eu).Count) user(s), $(Format-TmtNumber @($et).Count) team(s)"
                }
                $client = & $newClient 'Source'
                $ea = @{
                    Store = $store; Client = $client; Strategy = $(if ($P.Strategy) { [string]$P.Strategy } else { 'Auto' }); IncludeChannels = [bool]$P.IncludeChannels; SkipChats = [bool]$P.SkipChats; AllStoreUsers = [bool]$P.AllStoreUsers
                    IncludeFiles = [bool]$P.IncludeFiles; SkipFileDownload = [bool]$P.SkipFileDownload; NoHostedContents = [bool]$P.NoHostedContents; Full = [bool]$P.Full
                    MaxFileSizeMB = $maxMb; StopFile = $stopFile; IntervalSeconds = $interval
                }
                foreach ($k in 'UserParallelism', 'ConversationParallelism') { if ($P[$k]) { $ea[$k] = [int]$P[$k] } }
                if ($eu) { $ea.Users = $eu }
                if ($et) { $ea.Teams = $et }
                if ($P.Window) { $ea.Window = [string]$P.Window }
                if ($excl) { $ea.ExcludeExtensions = $excl }
                $r = Invoke-TmtExport @ea
                $detail = $r
                $counts.conversations = [long]$r.Conversations; $counts.messages = [long]$r.MessagesSeen; $counts.new = [long]$r.MessagesNew; $counts.updated = [long]$r.MessagesUpdated; $counts.errors = [long]$r.Errors.Count
                Write-TmtOk "$(Format-TmtNumber $r.Conversations) conversations, $(Format-TmtNumber $r.MessagesSeen) messages seen ($(Format-TmtNumber $r.MessagesNew) new, $(Format-TmtNumber $r.MessagesUpdated) updated, $(Format-TmtNumber $r.MessagesUnchanged) unchanged), $(Format-TmtBytes $r.ContentBytes) of content" -Icon Chat
                if ($r.UnitsFailed -gt 0 -or $r.Errors.Count -gt 0) {
                    Write-TmtWarn "$(Format-TmtNumber $r.UnitsFailed) unit(s) failed, $(Format-TmtNumber $r.Errors.Count) error(s): retried by the next run"
                    foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtDetail "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                }
                if ($r.PSObject.Properties['Files'] -and $r.Files) {
                    $f = $r.Files
                    $counts.files = [long]$f.Downloaded; $counts.fileBytes = Format-TmtBytes $f.Bytes
                    Write-TmtOk "Files: $(Format-TmtNumber $f.Downloaded) downloaded ($(Format-TmtBytes $f.Bytes)), $(Format-TmtNumber $f.Deduplicated) already there, $(Format-TmtNumber $f.Failed) failed" -Icon File
                    if ($f.Failed -gt 0 -or $f.Stopped) { $exit = 2 }
                }
                if ($r.Stopped -or (& $stopRequested) -or $r.UnitsFailed -gt 0 -or $r.Errors.Count -gt 0) { $exit = 2 }
                $store.Flush()
                $check = $store.Verify($false, $false)
                if ($check.Consistent) { Write-TmtOk "Store consistent: $(Format-TmtNumber $check.Messages) messages in $(Format-TmtNumber $check.Segments) segments checked" -Icon Store }
                else { foreach ($p in ($check.Problems | Select-Object -First 3)) { Write-TmtFail $p }; throw "The store check found $(Format-TmtNumber $check.Problems.Count) problem(s): see the log." }
                $next = 'Explorer'
            }
            'Files' {
                & $assertNotStopped
                $store = & $openStore -MustExist
                $client = & $newClient 'Source'
                $fa = @{ Store = $store; Client = $client; MaxFileSizeMB = $maxMb; StopFile = $stopFile; IntervalSeconds = $interval }
                if ($excl) { $fa.ExcludeExtensions = $excl }
                $f = Invoke-TmtFiles @fa
                $detail = $f
                $counts.files = [long]$f.Downloaded; $counts.deduplicated = [long]$f.Deduplicated; $counts.failed = [long]$f.Failed
                Write-TmtOk "$(Format-TmtNumber $f.Downloaded) downloaded ($(Format-TmtBytes $f.Bytes)), $(Format-TmtNumber $f.Deduplicated) already there, $(Format-TmtNumber $f.Failed) failed" -Icon File
                if ($f.Stopped -or (& $stopRequested) -or $f.Failed -gt 0) { $exit = 2 }
            }
            'Plan' {
                & $assertNotStopped
                $store = & $openStore -MustExist
                $planClient = $null
                if ($P.SkipTargetLookup) { Write-TmtItem SKIP 'Offline plan: the target tenant is not looked up.' } else { $planClient = & $newClient 'Target' }
                $sliceNumbers = @(Split-TtgList ([string]($P.Slices -join ',')) | ForEach-Object { if ($_ -notmatch '^[1-4]$') { throw "Slices '$_': expected 1, 2, 3 or 4 (one or more, comma separated)." }; [int]$_ })
                if (-not $sliceNumbers) { $sliceNumbers = @(1) }
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                $pa = @{
                    Store = $store; Scenario = $(if ($P.Scenario) { [string]$P.Scenario } else { 'TenantToTenant' }); Slices = [int[]]$sliceNumbers
                    DeletedAuthors = $(if ($P.DeletedAuthors) { [string]$P.DeletedAuthors } else { 'Auto' }); ConfirmGhostCount = [bool]$P.ConfirmGhostCount
                    OutputFolder = $reportPath; StopFile = $stopFile; IntervalSeconds = $interval
                }
                if ($P.GhostThreshold) { $pa.GhostThreshold = [int]$P.GhostThreshold }
                if ($planClient) { $pa.Client = $planClient } else { $pa.Offline = $true }
                if ($lot) { $pa.Lot = $lot }
                if ($users) { $pa.Users = $users }
                if ($teams) { $pa.Teams = $teams }
                if ($P.Window -and -not $lot) { $pa.Window = [string]$P.Window }
                if ($P.IdentityMap) { $pa.IdentityMap = [string]$P.IdentityMap }
                if ($P.TeamMap) { $pa.TeamMap = [string]$P.TeamMap }
                $dm = Split-TtgList ([string]($P.DomainMap -join ',')); if ($dm) { $pa.DomainMap = $dm }
                if ($P.ServiceAccount) { $pa.ServiceAccount = [string]$P.ServiceAccount }
                if ($P.GhostDomain) { $pa.GhostDomain = [string]$P.GhostDomain }
                elseif ($config.ContainsKey('Ghosts') -and $config.Ghosts.DomainName) { $pa.GhostDomain = [string]$config.Ghosts.DomainName }
                if ($config.ContainsKey('Ghosts') -and $config.Ghosts.DisplayNameFormat) { $pa.GhostDisplayNameFormat = [string]$config.Ghosts.DisplayNameFormat }
                $ao = Split-TtgList ([string]($P.ArchiveOwners -join ',')); if ($ao) { $pa.ArchiveOwners = $ao }
                $planned = New-TmtImportPlan @pa
                $pl = $planned.Plan
                $detail = $pl
                Write-TmtOk "$(Format-TmtNumber $pl.Conversations) conversations, $(Format-TmtNumber $pl.Messages) messages to import ($(Format-TmtNumber $pl.MessagesSkipped) not importable) in lot $($pl.LotName)" -Icon Chat
                Write-TmtInfo "Targets: $(Format-TmtNumber $pl.NewChats) new chats, $(Format-TmtNumber $pl.ExistingChats) existing chats, $(Format-TmtNumber $pl.NewChannels) new channels, $(Format-TmtNumber $pl.ExistingChannels) existing channels, $(Format-TmtNumber $pl.ArchiveChannels) archive channels"
                Write-TmtInfo "Identities: $(Format-TmtNumber $pl.GhostsToCreate) ghosts to create, $(Format-TmtNumber $pl.ServiceAccountAuthors) on the service account, $(Format-TmtNumber $pl.UnresolvedIdentities) unresolved"
                Write-TmtInfo "Files: $(Format-TmtNumber $pl.FilesToCopy) to copy ($(Format-TmtBytes $pl.FileBytesToCopy)); estimated import duration $(Format-TmtDuration $pl.EstimatedDuration.TotalSeconds)"
                foreach ($w in ($pl.Warnings | Select-Object -First 10)) { Write-TmtWarn $w }
                foreach ($b in $pl.Blockers) { Write-TmtFail "Blocker: $b" }
                $counts.lot = [string]$pl.LotName; $counts.conversations = [long]$pl.Conversations; $counts.messages = [long]$pl.Messages; $counts.ghosts = [long]$pl.GhostsToCreate
                $counts.unresolved = [long]$pl.UnresolvedIdentities; $counts.files = [long]$pl.FilesToCopy; $counts.blockers = [long]$pl.Blockers.Count
                $notes = @($pl.Blockers | ForEach-Object { "BLOCKER: $_" }) + @($pl.Warnings | ForEach-Object { "Warning: $_" }); $issues = $notes
                if ($pl.IsBlocked) { $exit = 3; $failure = "The plan has $($pl.Blockers.Count) blocker(s): fix them (see issues.csv) and plan again; nothing was written to any tenant." }
                else { $next = 'Import' }
                $lastLot = [string]$planned.LotName
            }
            'Ghosts' {
                & $assertNotStopped
                $store = if ($dryRun) { & $openStore -ReadOnly } else { & $openStore -MustExist }
                if (-not ($store -is [TeamsTransfer.IIdentityMap])) { throw 'The store holds no identity map: run Plan first.' }
                if ($lot -and $null -eq $store.GetLot($lot)) { throw "Lot '$lot' not found in the store." }
                $client = & $newClient 'Target'
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                $ga = @{ Store = $store; Client = $client; Configuration = $config; Apply = (-not $dryRun); ReportFolder = $reportPath; StopFile = $stopFile; IntervalSeconds = $interval }
                if ($P.GhostThreshold) { $ga.GhostThreshold = [int]$P.GhostThreshold }
                if ($P.ConfirmGhostCount) { $ga.ConfirmGhostCount = $true }
                if ($P.GhostDomain) { $ga.GhostDomain = [string]$P.GhostDomain }
                if ($P.ServiceAccount) { $ga.ServiceAccount = [string]$P.ServiceAccount }
                if ($P.CreateTrackingGroup) { $ga.CreateTrackingGroup = $true }
                if ($P.UsageLocation) { $ga.UsageLocation = [string]$P.UsageLocation }
                if ($P['Remove']) { $ga.Remove = $true }
                if ($P.Purge) { $ga.Purge = $true }
                if ($users) { $ga.Users = $users }
                if ($lot) { $ga.Lot = $lot; $ga.AdvanceLot = $true }
                & $assertNotStopped
                $r = Invoke-TmtGhosts @ga
                $detail = $r
                $counts.candidates = [long]$r.Candidates
                if ($P['Remove']) { $counts.removed = [long]$r.Removed; $counts.refused = [long]$r.Refused; $counts.failed = [long]$r.Failed }
                else {
                    if ($r.DryRun) { $counts.toCreate = [long]$r.ToCreate } else { $counts.created = [long]$r.Created }
                    $counts.linked = [long]$r.LinkedExisting; $counts.fallback = [long]$r.FallbackToServiceAccount; $counts.failed = [long]$r.Failed
                }
                Write-TmtOk "$(Format-TmtNumber $r.Candidates) identit(ies) to place: $(if ($r.DryRun) { "$(Format-TmtNumber $r.ToCreate) would be created" } else { "$(Format-TmtNumber $r.Created) created" }), $(Format-TmtNumber $r.LinkedExisting) already existed, $(Format-TmtNumber $r.FallbackToServiceAccount) on the service account, $(Format-TmtNumber $r.Failed) failed" -Icon Team
                if ($r.DryRun -and -not $P['Remove']) { $previewTitle = 'Ghost accounts that would be created'; $previewLines = @($r.Items | Select-Object -First 10 | ForEach-Object { '{0}|{1}' -f $_.UserPrincipalName, [string]$_.Action }) }
                foreach ($b in $r.Blockers) { Write-TmtFail "Blocker: $b" }
                foreach ($w in $r.Warnings) { Write-TmtWarn $w }
                if ($r.IsBlocked) { $failure = "The ghost stage is blocked ($($r.Blockers.Count) blocker(s)): nothing was written to the target tenant." }
                if ($r.IsBlocked -or $r.Reactivated -gt 0) { $exit = 3 } elseif ($r.Stopped -or (& $stopRequested) -or $r.Failed -gt 0 -or $r.GroupMembershipFailed -gt 0) { $exit = 2 }
                $notes = @($r.Blockers | ForEach-Object { "BLOCKER: $_" }) + @($r.Warnings | ForEach-Object { "Warning: $_" }); $issues = $notes
                $next = 'CopyFiles'
            }
            'CopyFiles' {
                & $assertNotStopped
                $store = if ($dryRun) { & $openStore -ReadOnly } else { & $openStore -MustExist }
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run Plan first.' }
                if ($lot -and $null -eq $store.GetLot($lot)) { throw "Lot '$lot' not found in the store." }
                $copyClient = if ($dryRun) { $null } else { & $newClient 'Target' }
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                $ca = @{ Store = $store; Apply = (-not $dryRun); ReportFolder = $reportPath; StopFile = $stopFile; IntervalSeconds = $interval
                    MaxFileSizeMB = $maxMb }
                if ($copyClient) { $ca.Client = $copyClient }
                if ($P.NoShare) { $ca.NoShare = $true }
                if ($excl) { $ca.ExcludeExtensions = $excl }
                # A preview sends no request: a service account given as a UPN would need a lookup in the target tenant, so only an object id is used.
                if ($P.ServiceAccount -and (-not $dryRun -or [string]$P.ServiceAccount -notmatch '@')) { $ca.ServiceAccount = [string]$P.ServiceAccount }
                if ($lot) { $ca.Lot = $lot; $ca.AdvanceLot = $true }
                $sl = @(Split-TtgList ([string]($P.Slices -join ',')) | ForEach-Object { [int]$_ }); if ($sl) { $ca.Slices = [int[]]$sl }
                & $assertNotStopped
                $r = Invoke-TmtFileCopy @ca
                $detail = $r
                $counts.files = [long]$r.Files
                if ($r.DryRun) {
                    $counts.bytes = Format-TmtBytes $r.Bytes
                    $previewTitle = 'Files that would be copied, per destination'; $previewLines = @($r.Destinations | Sort-Object Bytes -Descending | Select-Object -First 10 | ForEach-Object { '{0}|{1} file(s), {2}' -f $_.Destination, (Format-TmtNumber $_.Files), (Format-TmtBytes $_.Bytes) })
                    Write-TmtOk "$(Format-TmtNumber $r.Files) file(s) in scope, $(Format-TmtBytes $r.Bytes) to upload, $(Format-TmtNumber $r.AlreadyDone) already copied, $(Format-TmtNumber $r.Skipped) excluded" -Icon File
                } else {
                    $counts.uploaded = [long]$r.Uploaded; $counts.reused = [long]$r.Reused; $counts.shared = [long]$r.Shared; $counts.skipped = [long]$r.Skipped; $counts.failed = [long]$r.Failed; $counts.bytes = Format-TmtBytes $r.Bytes
                    Write-TmtOk "$(Format-TmtNumber $r.Uploaded) uploaded ($(Format-TmtBytes $r.Bytes)), $(Format-TmtNumber $r.Reused) reused, $(Format-TmtNumber $r.Shared) shared, $(Format-TmtNumber $r.Skipped) skipped, $(Format-TmtNumber $r.AlreadyDone) already done, $(Format-TmtNumber $r.Failed) failed" -Icon File
                }
                foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)" }
                if (-not $r.DryRun -and ($r.Stopped -or (& $stopRequested) -or $r.Failed -gt 0 -or $r.WaitingForTarget -gt 0 -or $r.SharingIncomplete -gt 0 -or $r.NoDestination -gt 0)) { $exit = 2 }
                $notes = @($r.Warnings | ForEach-Object { "Warning: $_" }); $issues = $notes
                $next = 'Import'
            }
            'Import' {
                & $assertNotStopped
                if (-not $lot) { throw 'Name the planned lot to import.' }
                $store = if ($dryRun) { & $openStore -ReadOnly } else { & $openStore -MustExist }
                $lotInfo = $store.GetLot($lot)
                if ($null -eq $lotInfo) { throw "Lot '$lot' not found in the store." }
                if ([string]$lotInfo.State -notin 'ImportPlanned', 'Ghosts', 'Files', 'Importing', 'Completing', 'Verified') {
                    throw "Lot '$lot' is $($lotInfo.State): the import needs a planned lot (state ImportPlanned). Run Plan first; a plan with blockers never reaches that state."
                }
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run Plan first.' }
                $sl = @(Split-TtgList ([string]($P.Slices -join ',')) | ForEach-Object { [int]$_ })
                $items = @($store.ListItems($lotInfo.Id) | Where-Object { -not $sl -or [int]$_.SliceNo -in $sl })
                Write-TmtInfo "Lot $lot ($($lotInfo.State)): $(Format-TmtNumber $items.Count) item(s) (conversation x slice)"
                $counts.items = [long]$items.Count
                $ia = @{ Store = $store; Lot = $lot; StopFile = $stopFile; IntervalSeconds = $interval }
                if ($J.Demo) { $ia.Client = & $newClient 'Target'; $ia.AppId = 'demo-target-app' } else { $ia.Configuration = $config }
                if ($sl) { $ia.Slices = [int[]]$sl }
                if ($P.ConversationParallelism) { $ia.ConversationParallelism = [int]$P.ConversationParallelism }
                if ($P.ServiceAccount) { $ia.ServiceAccount = [string]$P.ServiceAccount }
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                & $assertNotStopped
                if ($dryRun) {
                    $r = Invoke-TmtImport @ia
                    $detail = $r
                    $d = $r.DryRun
                    $counts.messages = [long]$d.MessagesToImport; $counts.requests = [long]$d.TotalRequests; $counts.conversationsToCreate = [long]$d.ConversationsToCreate
                    Write-TmtOk "$(Format-TmtNumber $d.MessagesToImport) message(s) to import, $(Format-TmtNumber $d.MessagesSkipped) skipped, $(Format-TmtNumber $d.MessagesRejected) without a usable author; $(Format-TmtNumber $d.TotalRequests) request(s), $(Format-TmtNumber $d.ConversationsToCreate) conversation(s) to create" -Icon Chat
                    foreach ($k in $d.RequestsByEndpoint.Keys) { Write-TmtDetail ('{0,12}  {1}' -f (Format-TmtNumber $d.RequestsByEndpoint[$k]), $k) }
                    $previewTitle = 'Requests that would be sent'; $previewLines = @($d.RequestsByEndpoint.Keys | ForEach-Object { '{0}|{1}' -f $_, (Format-TmtNumber $d.RequestsByEndpoint[$_]) })
                    if ($d.FilesToCopy) { Write-TmtInfo "$(Format-TmtNumber $d.FilesToCopy) file(s) ($(Format-TmtBytes $d.FileBytesToCopy)) would be copied to the target" }
                    Write-TmtInfo "Estimated duration $(Format-TmtDuration $d.EstimatedDuration.TotalSeconds) at the measured rates"
                    if ($r.ItemsFailed -gt 0) { Write-TmtWarn "$(Format-TmtNumber $r.ItemsFailed) item(s) cannot be imported as planned (no target): see conversations.csv and plan again" }
                } else {
                    $r = Invoke-TmtImport @ia -Apply
                    $detail = $r
                    $counts.imported = [long]$r.MessagesImported; $counts.already = [long]$r.MessagesConflict409; $counts.rejected = [long]$r.MessagesRejectedTotal
                    $counts.skipped = [long]$r.MessagesSkipped; $counts.items = [long]$r.ItemsTotal; $counts.completed = [long]$r.ItemsCompleted
                    Write-TmtOk "$(Format-TmtNumber $r.MessagesImported) message(s) imported ($(Format-TmtNumber $r.MessagesConflict409) already there), $(Format-TmtNumber $r.MessagesSkipped) skipped, $(Format-TmtNumber $r.MessagesRejectedTotal) rejected; $(Format-TmtNumber $r.MessagesPerSecond) msg/s" -Icon Chat
                    Write-TmtInfo "Items: $(Format-TmtNumber $r.ItemsCompleted) completed, $(Format-TmtNumber $r.ItemsIncomplete) incomplete, $(Format-TmtNumber $r.ItemsFailed) failed, $(Format-TmtNumber $r.ItemsUncertain) uncertain"
                    foreach ($e in ($r.Errors | Select-Object -First 5)) { Write-TmtWarn "$($e.Scope): $($e.ErrorCode) $($e.Message)"; $issues += "Warning: $($e.Scope): $($e.ErrorCode) $($e.Message)" }
                    $exit = Get-TmtImportExitCode -Result $r
                    if ($r.Stopped -or (& $stopRequested)) { $exit = [Math]::Max($exit, 2) }
                }
                [void](Write-TmtImportReport -Result $r -Folder $reportPath -Store $store)
                $next = 'Verify'
            }
            'Verify' {
                & $assertNotStopped
                if (-not $lot) { throw 'Name the imported lot to verify.' }
                $store = if ($P.NoLotUpdate) { & $openStore -ReadOnly } else { & $openStore -MustExist }
                $lotInfo = $store.GetLot($lot)
                if ($null -eq $lotInfo) { throw "Lot '$lot' not found in the store." }
                if (-not ($store -is [TeamsTransfer.ITargetMap])) { throw 'The store holds no import maps: run Plan and Import first.' }
                $client = & $newClient 'Target'
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                $va = @{ Store = $store; Client = $client; Lot = $lot; SampleSize = $(if ($null -ne $P.SampleSize -and "$($P.SampleSize)" -ne '') { [int]$P.SampleSize } else { 10 }); StopFile = $stopFile; IntervalSeconds = $interval
                    Strict = [bool]$P.StrictCounts; AllowExtra = [bool]$P.AllowExtra; NoLotUpdate = [bool]$P.NoLotUpdate; ReportFolder = $reportPath }
                $sl = @(Split-TtgList ([string]($P.Slices -join ',')) | ForEach-Object { [int]$_ }); if ($sl) { $va.Slices = [int[]]$sl }
                if ($P.Scenario) { $va.Scenario = [string]$P.Scenario }
                if ($P.ServiceAccount) { $va.ServiceAccount = [string]$P.ServiceAccount }
                & $assertNotStopped
                $r = Invoke-TmtVerify @va
                $counts.conversations = [long]$r.Items.Count; $counts.ok = [long]$r.Ok; $counts.mismatch = [long]$r.Mismatch; $counts.missing = [long]$r.Missing; $counts.notCompleted = [long]$r.NotCompleted; $counts.unverified = [long]$r.Unverified
                $detail = [pscustomobject]@{ Lot = $r.LotName; Ok = $r.Ok; Mismatch = $r.Mismatch; Missing = $r.Missing; NotCompleted = $r.NotCompleted; Unverified = $r.Unverified; SourceMessages = $r.SourceMessages; TargetMessages = $r.TargetMessages; LotStateBefore = [string]$r.LotStateBefore; LotStateAfter = [string]$r.LotStateAfter }
                Write-TmtOk "$(Format-TmtNumber $r.Items.Count) conversation-slice(s): $(Format-TmtNumber $r.Ok) OK, $(Format-TmtNumber $r.Mismatch) mismatch, $(Format-TmtNumber $r.Missing) missing, $(Format-TmtNumber $r.NotCompleted) not completed, $(Format-TmtNumber $r.Unverified) unverified; $(Format-TmtNumber $r.SourceMessages) source / $(Format-TmtNumber $r.TargetMessages) target message(s)" -Icon Chat
                foreach ($i in ($r.Items | Where-Object { [string]$_.Outcome -ne 'OK' } | Select-Object -First 8)) { Write-TmtWarn "$($i.ConversationKey) slice $($i.SliceNo): $($i.Outcome) - $($i.Detail)"; $issues += "$($i.ConversationKey) slice $($i.SliceNo): $($i.Outcome) - $($i.Detail)" }
                if ($r.Mismatch -gt 0 -or $r.Missing -gt 0) { $exit = 3; $failure = "$(Format-TmtNumber ($r.Mismatch + $r.Missing)) conversation-slice(s) do not match the source: see verify.csv." }
                elseif ($r.NotCompleted -gt 0 -or $r.Unverified -gt 0 -or (& $stopRequested)) { $exit = 2 }
                $notes = @($r.ToText())
                $next = 'Report'
            }
            'Report' {
                & $assertNotStopped
                $store = & $openStore -ReadOnly
                $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode
                $ra = @{ Store = $store; Folder = $reportPath }
                if ($lot) { $ra.Lot = $lot }
                $reports = @(Invoke-TmtLotReport @ra)
                $detail = $reports
                $counts.lots = [long]$reports.Count
                if ($reports.Count -eq 0) { Write-TmtItem SKIP 'No lot in the store yet: run Plan first.' }
                foreach ($x in $reports) { Write-TmtOk "Lot $($x.Lot): $($x.State)$(if ($x.Verified) { ", verification $($x.Verified) OK" })" -Icon Report }
            }
            default { throw "Mode '$mode' is not a console job." }
        }
        if (-not $reportPath) { $reportPath = New-TtgRunFolder -OutRoot $J.OutRoot -Mode $mode }
        if (-not (Test-Path -LiteralPath (Join-Path $reportPath "TeamsTransfer_$mode.html"))) {
            Save-TtgRunReport -Folder $reportPath -Mode $mode -Counts $counts -Detail $detail -Notes $notes -StoreRoot $J.StoreRoot
        }
    } catch {
        if ($_.Exception -is [OperationCanceledException] -or $_.Exception -is [System.Management.Automation.PipelineStoppedException]) { $exit = 2 }
        else {
            $exit = 1; $failure = $_.Exception.Message
            if (Get-Command Write-TmtLog -ErrorAction SilentlyContinue) { Write-TmtLog FAIL $failure }
        }
    } finally {
        if ($null -ne $store) { try { $store.Dispose() } catch { Write-Verbose "Store close: $($_.Exception.Message)" } }
        try {
            if (Get-Command Write-TmtEndCard -ErrorAction SilentlyContinue) {
                Write-TmtEndCard -Mode $mode -ExitCode $exit -Failure $failure -Counts $counts -Planned:$dryRun -Report $reportPath -Next $(if ($next) { "next page: $next" } else { '' }) -DurationSeconds $clock.Elapsed.TotalSeconds -StoreRoot $J.StoreRoot
            }
        } catch { Write-Verbose "End card: $($_.Exception.Message)" }
        if (Get-Command Stop-TmtLog -ErrorAction SilentlyContinue) { Stop-TmtLog }
    }
    return [pscustomobject][ordered]@{
        Mode = $mode; ExitCode = $exit; Failure = $failure; Counts = $counts; Report = $reportPath; Log = $logPath; Next = $next
        Preview = [bool]$dryRun; PreviewTitle = $previewTitle; PreviewLines = $previewLines; Issues = $issues; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); Lot = $lastLot
    }
}

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA3GJwlKKDfmB+U
# 92wiiYWkEap7k3GFHjzfegvrPt1hfaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAOatmk+0Y6
# OM4ptAAAm7swa1k574Hcd6iiNz0CKCvJsjANBgkqhkiG9w0BAQEFAASCAgBd+Yw1
# gTKthOzH6XPCS2ciHHaBabJR7ErjdxyHgMaqF6V4FTskacjGtLsF11oqlj+E5piL
# GWmXwM3phsCpb3EU35uoGHtbaS8Is+ZstQ7eySUov1zPkiiEAibC/STpOXqCT6NU
# Mc8w4SSgeWdX7mGSRfeGDVbthMd2kXHeGVrIVQjAvCCfptYOk1WXlncwKtr4Diks
# J+dzeNBZPfAv5RWRuoD8tQV2aKx3zvUBLnpylPjzxzd5sLS1dZjD2TMSk1E9QFad
# 9Mpi/901tLn6Jg0ArKEakFUXpHCqN6d82fC6GakeMLbPIIgYxbc9DHl6DmVZsp+3
# AYCRzA4XONPMHCdmBZC8zv3ajpxJvRDOxSQPtB5FtHD4BmWJDcYOKHDbaoVRwIuP
# zBPTNwpykQT2QLcpnjrALiaczL4gOjLNivg+MnDAEVP2JPVrPImxIwrREI2yCKBw
# bSBCFQ6kXlHYm1MoyMChQhEsZ5y6uL08L8ncDjAJPN5Vjh68pLRdGTMF/4OrM9e2
# nIY5EjhxXhubrSkUsowoYyJFTVx0ru7jSs/LdlIf1jpOgKCcR5k2qlXgD2hg2EsF
# YKKbUGVA7iW6ReR3sARRg4uAVX+P5aruQeNhlI/nd6WIClMC8Tut+Iqh5/ubU1v0
# X9KbdPYyvITbYnNiPSeWUd+Q0qJ1lfd4+8DkuqGCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIKCegKXKUCkmISa4/DIoathrkPc5U1F9V0QVhoj95+20AggDybwSk3Pv
# BRgPMjAyNjExMTExNzU3MjZaMAMCAQECEAffR1nBrbvK5I7eo1eu6i6gghGnMIIE
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
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMTE3NTcyNlowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIOzh
# 1MdL38gXo1/sN1fEmtsP9dsKnh6BStPtw8AU+wJ8MIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiBIBjRar2pow3MF2C3OsGfj/J7I99T7pTNMERUUc2lClQIhAPzH
# miGPiGEzj1n6PXw2/uAw7fyBzcd2RzT4BXboQwXG
# SIG # End signature block
