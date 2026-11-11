# TeamsTransfer - thin PowerShell surface over the C# mapping / plan engine (lot H).
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
    # -Window for a lot created on the fly: '24m' -> 24; '60m' -> 24,36,48,60 (the waves of design 3.7: 24 months, then 12 months each).
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

# Cumulative with the Export-ModuleMember of TeamsTransfer.psm1 (lot H owns this file only).
Export-ModuleMember -Function New-TmtImportPlan

# SIG # Begin signature block
# MIImKQYJKoZIhvcNAQcCoIImGjCCJhYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCIJvTxJeNlH3nC
# qvJlmSqoDX1NPsGF9BygawzyrkMmQqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIYEDCCGAwCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBKfxWfWieL
# Wg0V4u6qyrnOGzHnxu1lmsqxmGgBwBayPTANBgkqhkiG9w0BAQEFAASCAgADNQjR
# l8GWSOALXHgVSVmfM+Vk98n3kp8J+vIP8KPY0wkQ2m8o4QZ7Ntvz23S0VdTC/YHy
# PQ0rujGJKKitYU554uUQyDIDMOren6WB+fGuFjKMLimqE1C6Ktm8SgpdDnwSQQKT
# TjA3ZZetTzU/+tcybKYc68HxO7Y2GwLH3TMWUdRC+zwx+uAaxSXQt8DVhtp6u1M1
# vHJJo6l0X9rQfc/8+c4Py9TuVdgcRasBNYVpHmuMtoD0+X7OIlJG69iSeqX+HQ44
# /ZUTDwyM9DmF6c9cYS4jvW577lmiqf+6CC0Tc5t8xZ+edbW0xG5rZbycH90K0elD
# FSihCm24rbDfZrAKJLse4GMDg6cJEpKtW9TUMGVwsTCmartCVQR8tkqSbMydTVFf
# HD/NNz4cDYSH5NsKKqbk90nT2F82aji34Z0mAcA0mxBV2fXhnZcbsvpm0fkSdKG2
# dPgcuVU1QE1WfgpdXINi96VnedSJajr4owBx5WROpy7C+x6iY6706+dkA9tLtKxO
# iLmZh9+EX2k3KEQnceIhESbjTUivtI2YeDj4wphwRlU+2RpVQc1I3ozhUTWot+UH
# oRgQXK14gyYJVS83XQFDPIvhT4OJnpnZuY8MRmAlkSU4YeWTA2fWY11Qd3XLzWRa
# Rm4CRWEeyBqw4X//VJ3gU5FAI8/zZxC8M4vj9qGCFM0wghTJBgorBgEEAYI3AwMB
# MYIUuTCCFLUGCSqGSIb3DQEHAqCCFKYwghSiAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIJhz7Nh6yQGg64mUZHBOvH+ARvlgWH1HuyPgdC/YjUNwAghfAIRsZb8Y
# ZxgPMjAyNjExMTExNzU3MzlaMAMCAQECEB/86kTML3S4i8AcYibHrzegghGnMIIE
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
# wzSPOzGCAlUwggJRAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMTE3NTczOVowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIIwm
# GfNroWHliBOm58WN96orzutiw8FctaSyL7kpW2L4MIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERjBEAiBKtDTEB1hFyuvZjjID1AGFkCuHclvyaDksLTySG/MRjQIgDTy7
# cTOvf3aMxnAXsxFyxj1pIfmWPpMD2FkfJKCpJCc=
# SIG # End signature block
