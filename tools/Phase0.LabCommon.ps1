#Requires -Version 7.4
<#
.SYNOPSIS
    Shared helpers of New-Phase0LabData.ps1 and Remove-Phase0LabData.ps1 (dot-source it; not meant to be run alone).

.DESCRIPTION
    App-only sign-in with a certificate (JWT client assertion built here: RS256, x5t#S256, private key used in place),
    a small Graph request function with retry on 429/5xx and -DryRun support (prints, sends nothing), and the labdata.json
    state helpers. Standalone: no dependency on the TeamsTransfer engine. Tokens and keys are never printed or stored.

.PARAMETER None
    This file only defines functions.

.EXAMPLE
    . "$PSScriptRoot\Phase0.LabCommon.ps1"; Initialize-LabAuth -TenantId $t -Cloud Global -Thumbprint $thumb -DryRun:$false
#>
Set-StrictMode -Version Latest

$script:LabCloudMap = @{
    Global   = @{ Login = 'https://login.microsoftonline.com'; Graph = 'https://graph.microsoft.com' }
    USGov    = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://graph.microsoft.us' }
    USGovDoD = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://dod-graph.microsoft.us' }
    China    = @{ Login = 'https://login.partner.microsoftonline.cn'; Graph = 'https://microsoftgraph.chinacloudapi.cn' }
}
$script:Lab = $null

function ConvertTo-LabBase64Url([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function New-LabClientAssertion {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [string]$ClientId, [string]$Audience)
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw "Certificate $($Certificate.Thumbprint) has no usable RSA private key." }
    try {
        $now = [DateTimeOffset]::UtcNow
        $h = [ordered]@{ alg = 'RS256'; typ = 'JWT'; 'x5t#S256' = (ConvertTo-LabBase64Url ([System.Security.Cryptography.SHA256]::HashData($Certificate.RawData))) }
        $p = [ordered]@{ aud = $Audience; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now.AddSeconds(-30).ToUnixTimeSeconds(); iat = $now.ToUnixTimeSeconds(); exp = $now.AddSeconds(600).ToUnixTimeSeconds() }
        $si = (ConvertTo-LabBase64Url ([Text.Encoding]::UTF8.GetBytes(($h | ConvertTo-Json -Compress)))) + '.' + (ConvertTo-LabBase64Url ([Text.Encoding]::UTF8.GetBytes(($p | ConvertTo-Json -Compress))))
        $sig = $rsa.SignData([Text.Encoding]::ASCII.GetBytes($si), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        "$si.$(ConvertTo-LabBase64Url $sig)"
    }
    finally { $rsa.Dispose() }
}

function Initialize-LabAuth {
    param([string]$TenantId, [string]$Cloud = 'Global', [string]$Thumbprint, [switch]$DryRun)
    $cert = $null
    if (-not $DryRun) {
        $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction SilentlyContinue
        if (-not $cert -or -not $cert.HasPrivateKey) { throw "Certificate $Thumbprint with a private key not found in Cert:\CurrentUser\My." }
    }
    $script:Lab = @{ TenantId = $TenantId; Cloud = $Cloud; Login = $script:LabCloudMap[$Cloud].Login; Graph = $script:LabCloudMap[$Cloud].Graph; Cert = $cert; Tokens = @{}; DryRun = [bool]$DryRun; Plan = [System.Collections.Generic.List[string]]::new() }
    $script:Lab.G = "$($script:Lab.Graph)/v1.0"
}

function Confirm-LabAction {
    # One confirmation for a run that writes to a tenant: skipped by -Force; refused in a session that cannot ask (add -Force there).
    param([Parameter(Mandatory)]$Cmdlet, [Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string]$Caption, [switch]$Force)
    if ($Force) { return $true }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { throw 'A confirmation is needed and this session is not interactive: add -Force for an unattended run.' }
    return $Cmdlet.ShouldContinue($Query, $Caption)
}

function Read-LabConfig {
    # Returns the lab-apps.json written by Grant-LabConsent.ps1 (or an empty hashtable).
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) }
    @{}
}

function Get-LabToken {
    param([string]$ClientId)
    $L = $script:Lab
    if ($L.DryRun) { Write-Host "[DRYRUN] token for client $ClientId (JWT client assertion signed with the certificate, scope $($L.Graph)/.default)" -ForegroundColor DarkGray; return 'DRYRUN-TOKEN' }
    $c = $L.Tokens[$ClientId]
    if ($c -and $c.Expires -gt (Get-Date).AddMinutes(5)) { return $c.Token }
    $url = "$($L.Login)/$($L.TenantId)/oauth2/v2.0/token"
    $form = @{ grant_type = 'client_credentials'; client_id = $ClientId; scope = "$($L.Graph)/.default"; client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = (New-LabClientAssertion -Certificate $L.Cert -ClientId $ClientId -Audience $url) }
    $r = Invoke-WebRequest -Method Post -Uri $url -Body $form -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck
    $j = $r.Content | ConvertFrom-Json -AsHashtable
    if ($r.StatusCode -ne 200) { throw "Token request failed for $ClientId : HTTP $($r.StatusCode) $($j['error']) $((([string]$j['error_description']) -split "`n")[0])" }
    $L.Tokens[$ClientId] = @{ Token = $j['access_token']; Expires = (Get-Date).AddSeconds([int]$j['expires_in']) }
    $j['access_token']
}

function Get-LabRedacted {
    param($V)
    if ($null -eq $V) { return $null }
    if ($V -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $V.Keys) { if ($V[$k] -is [string] -and [string]$k -in 'content', 'contentBytes') { $o[[string]$k] = "[redacted $($V[$k].Length) chars]" } else { $o[[string]$k] = Get-LabRedacted $V[$k] } }
        return $o
    }
    if ($V -is [string]) { return $V }
    if ($V -is [System.Collections.IEnumerable]) { return , @($V | ForEach-Object { Get-LabRedacted $_ }) }
    $V
}

function Invoke-LabGraph {
    # Path is relative to /v1.0 (or a full URL). Returns Status, Ok, Json, Location, ErrorCode, ErrorMessage, RequestId.
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body, [byte[]]$BodyBytes, [string]$ContentType, [string]$Token, [switch]$NoRetry)
    $L = $script:Lab
    $url = if ($Path -match '^https?://') { $Path } else { "$($L.G)$Path" }
    $res = @{ Method = $Method; Url = $url; Status = 0; Ok = $false; Json = $null; Location = $null; ErrorCode = $null; ErrorMessage = $null; RequestId = $null; DryRun = $L.DryRun }
    if ($L.DryRun) {
        $line = "[DRYRUN] $Method $url"
        $L.Plan.Add($line); Write-Host $line -ForegroundColor DarkGray
        if ($null -ne $Body) { $b = '           body: ' + ((Get-LabRedacted $Body) | ConvertTo-Json -Depth 20 -Compress); $L.Plan.Add($b); Write-Host $b -ForegroundColor DarkGray }
        if ($BodyBytes) { $b = "           body: $($BodyBytes.Length) bytes ($ContentType)"; $L.Plan.Add($b); Write-Host $b -ForegroundColor DarkGray }
        $fake = @{ id = '{id}'; createdDateTime = '2026-01-01T00:00:00.000Z'; migrationMode = 'none'; displayName = '{displayName}'; webUrl = 'https://example.invalid/f.txt'; eTag = '"{00000000-0000-0000-0000-000000000000},1"'; value = @() }
        if ($Path -match '/users/([^/?]+)') { $fake.id = "{id:$([uri]::UnescapeDataString($Matches[1]))}" }
        $res.Ok = $true; $res.Json = $fake; $res.Location = "/teams('{teamId}')/operations('{operationId}')"
        return $res
    }
    $attempt = 0
    while ($true) {
        $attempt++
        $p = @{ Method = $Method; Uri = $url; SkipHttpErrorCheck = $true; Headers = @{ Authorization = "Bearer $Token" } }
        if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $p.ContentType = 'application/json; charset=utf-8' }
        elseif ($BodyBytes) { $p.Body = $BodyBytes; $p.ContentType = $ContentType }
        $r = Invoke-WebRequest @p
        $res.Status = [int]$r.StatusCode
        if ($res.Status -in 429, 502, 503, 504 -and -not $NoRetry -and $attempt -lt 7) {
            $ra = 0; if ($r.Headers.ContainsKey('Retry-After')) { [void][double]::TryParse(@($r.Headers['Retry-After'])[0], [ref]$ra) }
            $wait = if ($ra -gt 0) { [math]::Min(90, $ra) } else { [math]::Min(30, [math]::Pow(2, $attempt)) }
            Write-Host "  HTTP $($res.Status) - waiting $wait s" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
            continue
        }
        break
    }
    $res.Ok = $res.Status -ge 200 -and $res.Status -lt 300
    if ($r.Headers.ContainsKey('Location')) { $res.Location = [string]@($r.Headers['Location'])[0] }
    if ($r.Headers.ContainsKey('request-id')) { $res.RequestId = [string]@($r.Headers['request-id'])[0] }
    if ($r.Content) {
        try { $res.Json = $r.Content | ConvertFrom-Json -AsHashtable -Depth 30 } catch { $res.Json = $null }
        if ($res.Json -is [System.Collections.IDictionary] -and $res.Json.ContainsKey('error') -and $res.Json['error'] -is [System.Collections.IDictionary]) {
            $res.ErrorCode = [string]$res.Json['error']['code']; $res.ErrorMessage = [string]$res.Json['error']['message']
        }
    }
    if (-not $res.Ok -and -not $res.ErrorCode) { $res.ErrorCode = "HTTP$($res.Status)" }
    $res
}

function Get-LabV {
    param($Obj, [Parameter(ValueFromRemainingArguments)][string[]]$Path)
    $cur = $Obj
    foreach ($p in $Path) {
        if ($null -eq $cur -or $cur -isnot [System.Collections.IDictionary] -or -not $cur.Contains($p)) { return $null }
        $cur = $cur[$p]
    }
    $cur
}

function Read-LabState {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) }
    @{ version = 1; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); members = @{}; chats = @{}; team = $null; channels = @{}; messages = @{}; files = @{} }
}
function Save-LabState {
    param($State, [string]$Path)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $tmp = "$Path.tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Format-LabDt([datetime]$D) { $D.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function ConvertTo-LabDateUtc($v) {
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetime]::Parse([string]$v, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}
