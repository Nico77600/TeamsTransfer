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
