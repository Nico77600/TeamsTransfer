#Requires -Version 7.4
<#
.SYNOPSIS
    Phase 0 (lab): answers the Go/No-go questions of TeamsTransfer against a LAB Microsoft 365 tenant with independent
    probes (read-only R1-R7, write W1-W4) and writes structured evidence.

.DESCRIPTION
    Standalone: plain PowerShell 7 + HttpClient, no dependency on the TeamsTransfer engine.

    Authentication is app-only with a certificate: the script builds the JWT client assertion itself (RS256 over
    base64url(header).base64url(payload), header x5t#S256, signed with the private key of the certificate found in
    Cert:\CurrentUser\My - the key is used in place and never exported) and posts it to the token endpoint of the selected
    cloud (-Cloud Global|USGov|USGovDoD|China). Tokens, assertions and keys are never printed or written.

    PROBES (-Probe, default R1..R6, all read-only):
      R1  Token and roles           roles claim of each app token vs the expected permissions
      R2  Export strategy U         /users/{id}/chats/getAllMessages (window, paging, $top, model A/B, no model)
      R3  Export strategy C         /users/{id}/chats then /chats/{id}/messages per chat, $filter/$orderby, dedup vs R2
      R4  Channels                  channels (membershipType), channels/getAllMessages, per-channel messages + replies
      R5  Hosted contents           download an inline image of a chat message and of a channel message
      R6  Files                     reference attachment -> /shares/u!.../driveItem -> content, size, SHA-256; deleted identity
      R7  Throughput sampler        (NOT in the default set) bounded concurrency ramp on one endpoint, stops at sustained 429
      W1  Chat import               startMigration, 5 back-dated messages, duplicate/future date, rate burst, complete, history
      W2  Departed/external author  from.user = deleted / disabled / guest / unknown id
      W3  Channel import            startMigration on a channel, root message + replies, complete (standard, optional private)
      W4  Same-app ownership        another app tries to import/complete on a thread started by the Writer app

    WRITE probes (W*) only run with -AllowWrite AND explicit lab objects (-TestChatMembers / -TestChatId / -TestTeamId ...)
    and a confirmation prompt (skipped with -Force). They only touch objects they created plus the ones passed explicitly.
    Imported chats/channels cannot be rolled back: created objects are listed in created-objects.json for manual cleanup.

    EVIDENCE goes to tools\phase0-output\<timestamp>\ : one JSON per probe, Phase0-Report.md (summary, answers, request
    table), Timings.csv, run-info.json. Message bodies, subjects and image bytes are REDACTED unless -IncludeContent
    (lab only; image bytes are always summarised). Each probe has a status: Pass, Fail or Inconclusive (DryRun in -DryRun).

    -DryRun prints every request that would be sent (method, URL, body with redacted content) without any network access
    (no sign-in either) and runs every selected probe end to end on placeholder data, so the plan can be reviewed first.

    IMPORTANT: R7 and W1 consume Teams API quota of the tenant (keep to a lab tenant, outside business hours).

.PARAMETER TenantId
    Lab tenant id or domain. Default: read from lab-apps.json (written by Grant-LabConsent.ps1).

.PARAMETER ReaderClientId
    Application id of "TT-Lab TeamsTransfer Reader". Default: lab-apps.json.

.PARAMETER WriterClientId
    Application id of "TT-Lab TeamsTransfer Writer". Default: lab-apps.json.

.PARAMETER OtherAppClientId
    Application used by W4 as "the other app". Default: writerB of lab-apps.json, else the Reader app (W4 is then
    inconclusive on ownership because the Reader lacks Teamwork.Migrate.All: the 403 would be about permissions).

.PARAMETER CertificateThumbprint
    Thumbprint of the certificate in Cert:\CurrentUser\My. Default: lab-apps.json.

.PARAMETER ConfigPath
    Alternative lab-apps.json. Default tools\phase0-output\lab-apps.json.

.PARAMETER Cloud
    Global (default), USGov, USGovDoD, China. Selects the token endpoint and the Graph host.

.PARAMETER Probe
    Probe ids (R1..R7, W1..W4). Default: R1,R2,R3,R4,R5,R6.

.PARAMETER TestUserId
    User (object id or UPN) whose chats are exported by R2/R3 (R5/R6 look for samples there too, R7 target).

.PARAMETER TestChatId
    Existing lab chat: reused by R5/R6/R7 (read) and by W1/W2/W4 (write, an import is started on it!).

.PARAMETER TestChatMembers
    User ids/UPNs (at least 2, 3 recommended) used by W1/W2/W4 to create a new GROUP chat when -TestChatId is not given.

.PARAMETER SenderUserId
    Author of the imported messages (from.user). Default: first of -TestChatMembers. Needs a OneDrive for W1 file upload.

.PARAMETER TestTeamId
    Lab team for R4 and W3.

.PARAMETER TestChannelId
    Existing standard channel of the team for W3. Default: a new standard channel created by the probe.

.PARAMETER TestPrivateChannelId
    Existing private channel of the team: W3 also runs on it (optional).

.PARAMETER DeletedUserId
    Id of a deleted user (W2 a, and R6 deleted identity lookup).

.PARAMETER DisabledUserId
    Id of a disabled or unlicensed user (W2 b).

.PARAMETER GuestUserId
    Id of a guest/external user (W2 c).

.PARAMETER DepartedFileUrl
    contentUrl (sharing URL) of a file stored in a departed user's OneDrive (R6).

.PARAMETER WindowDays
    Export window (lastModifiedDateTime) in days before now. Default 30. -From/-To override.

.PARAMETER MaxPages
    Page cap per paged read (bounds duration and quota). Default 10.

.PARAMETER MaxChats
    Number of chats read one by one by R3. Default 25.

.PARAMETER MaxChannels
    Number of channels read one by one by R4. Default 5.

.PARAMETER R7Target
    ChatList, ChatMessages (default), GetAllMessages, ChannelMessages or Custom (-R7Url, relative to /v1.0).

.PARAMETER MaxSeconds
    R7: total duration cap of the ramp. Default 60.

.PARAMETER MaxConcurrency
    R7: highest concurrency level (levels 1,2,4,8,16...). Default 16.

.PARAMETER ImportBurst
    W1: number of messages posted in a row on one thread to measure the import rate. Default 30.

.PARAMETER SkipVisibleHistory
    W1: skips the remove/re-add of a member with visibleHistoryStartDateTime.

.PARAMETER AllowWrite
    Required for any W probe.

.PARAMETER Force
    No confirmation prompt (write probes, R7).

.PARAMETER IncludeContent
    Keep message bodies/subjects in the evidence (lab only).

.PARAMETER DryRun
    Print the requests, send nothing.

.PARAMETER OutputRoot
    Root of the evidence folders. Default tools\phase0-output.

.EXAMPLE
    .\tools\Invoke-Phase0.ps1 -DryRun -Probe R1,R2,R3,R4,R5,R6,R7 -TestUserId alice@lab.onmicrosoft.com -TestTeamId 11111111-1111-1111-1111-111111111111

.EXAMPLE
    .\tools\Invoke-Phase0.ps1 -Probe R1,R2,R3 -TestUserId alice@lab.onmicrosoft.com -WindowDays 60

.EXAMPLE
    .\tools\Invoke-Phase0.ps1 -Probe W1,W2 -AllowWrite -TestChatMembers $a,$b,$c -DeletedUserId $d -GuestUserId $g

.NOTES
    Author  : Nicolas Fabert
    Version : 0.1.0 (phase 0). -WhatIf is the same as -DryRun (no network access, nothing sent). Nothing here was run against a real tenant by the author: request shapes come from the
    Microsoft documentation read on 2026-11-09 (see docs\design\Phase0-Questions.md).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$ReaderClientId,
    [string]$WriterClientId,
    [string]$OtherAppClientId,
    [string]$CertificateThumbprint,
    [string]$ConfigPath,
    [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
    [ValidateSet('R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'W1', 'W2', 'W3', 'W4')][string[]]$Probe,
    [string]$TestUserId,
    [string]$TestChatId,
    [string[]]$TestChatMembers,
    [string]$SenderUserId,
    [string]$TestTeamId,
    [string]$TestChannelId,
    [string]$TestPrivateChannelId,
    [string]$DeletedUserId,
    [string]$DisabledUserId,
    [string]$GuestUserId,
    [string]$DepartedFileUrl,
    [ValidateRange(1, 3650)][int]$WindowDays = 30,
    [datetime]$From,
    [datetime]$To,
    [ValidateRange(1, 1000)][int]$MaxPages = 10,
    [ValidateRange(1, 500)][int]$MaxChats = 25,
    [ValidateRange(1, 100)][int]$MaxChannels = 5,
    [ValidateSet('ChatList', 'ChatMessages', 'GetAllMessages', 'ChannelMessages', 'Custom')][string]$R7Target = 'ChatMessages',
    [string]$R7Url,
    [ValidateRange(5, 600)][int]$MaxSeconds = 60,
    [ValidateRange(1, 64)][int]$MaxConcurrency = 16,
    [ValidateRange(6, 500)][int]$ImportBurst = 30,
    [switch]$SkipVisibleHistory,
    [switch]$AllowWrite,
    [switch]$Force,
    [switch]$IncludeContent,
    [switch]$DryRun,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# -WhatIf is -DryRun: the requests are printed, nothing is sent. The evidence folder is written in both cases.
if ($WhatIfPreference) { $DryRun = [switch]$true }
$WhatIfPreference = $false
$script:ToolCmdlet = $PSCmdlet

#region configuration ---------------------------------------------------------------------------------------------------
$CloudMap = @{
    Global   = @{ Login = 'https://login.microsoftonline.com'; Graph = 'https://graph.microsoft.com' }
    USGov    = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://graph.microsoft.us' }
    USGovDoD = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://dod-graph.microsoft.us' }
    China    = @{ Login = 'https://login.partner.microsoftonline.cn'; Graph = 'https://microsoftgraph.chinacloudapi.cn' }
}
$GraphHost = $CloudMap[$Cloud].Graph
$G = "$GraphHost/v1.0"

$ExpectedRoles = @{
    Reader = @('Chat.Read.All', 'ChannelMessage.Read.All', 'ChatMember.Read.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All',
        'ChannelMember.Read.All', 'User.Read.All', 'Files.Read.All', 'Sites.Read.All')
    Writer = @('Teamwork.Migrate.All', 'Chat.Create', 'Chat.ReadWrite.All', 'ChatMember.ReadWrite.All', 'Channel.Create',
        'ChannelMember.ReadWrite.All', 'Team.Create', 'TeamMember.ReadWrite.All', 'Files.ReadWrite.All', 'Sites.ReadWrite.All', 'User.Read.All')
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'phase0-output\lab-apps.json' }
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $TenantId -and $cfg.ContainsKey('tenantId')) { $TenantId = $cfg['tenantId'] }
    if (-not $CertificateThumbprint -and $cfg.ContainsKey('certificateThumbprint')) { $CertificateThumbprint = $cfg['certificateThumbprint'] }
    if (-not $ReaderClientId -and $cfg.ContainsKey('reader')) { $ReaderClientId = $cfg['reader']['appId'] }
    if (-not $WriterClientId -and $cfg.ContainsKey('writer')) { $WriterClientId = $cfg['writer']['appId'] }
    if (-not $OtherAppClientId -and $cfg.ContainsKey('writerB')) { $OtherAppClientId = $cfg['writerB']['appId'] }
}
if (-not $OtherAppClientId) { $OtherAppClientId = $ReaderClientId }
if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot 'phase0-output' }

$Selected = if ($Probe) { @($Probe | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique) } else { @('R1', 'R2', 'R3', 'R4', 'R5', 'R6') }
$WriteSelected = @($Selected | Where-Object { $_ -like 'W*' })

if (-not $From) { $From = (Get-Date).ToUniversalTime().AddDays(-$WindowDays) }
if (-not $To) { $To = (Get-Date).ToUniversalTime() }

$RedactKeys = @('content', 'subject', 'summary')
$AlwaysRedactKeys = @('contentBytes')
#endregion

#region small helpers ---------------------------------------------------------------------------------------------------
function Get-V {
    # Safe nested read on hashtables (strict-mode friendly): Get-V $obj 'a' 'b'
    param($Obj, [Parameter(ValueFromRemainingArguments)][string[]]$Path)
    $cur = $Obj
    foreach ($p in $Path) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) { if ($cur.Contains($p)) { $cur = $cur[$p] } else { return $null } }
        else { return $null }
    }
    $cur
}
function Get-ValueList {
    param($Json, [string]$Key = 'value')
    $v = Get-V $Json $Key
    if ($null -eq $v) { return , @() }
    , @($v)
}
function Format-Dt($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return $v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
    [string]$v
}
function ConvertTo-DateUtc($v) {
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetime]::Parse([string]$v, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}
function ConvertTo-Base64Url([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function ConvertFrom-Base64Url([string]$Text) {
    $t = $Text.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    [Convert]::FromBase64String($t)
}
function Get-Redacted {
    param($V, [int]$Depth = 0)
    if ($null -eq $V) { return $null }
    if ($Depth -gt 14) { return '[depth limit]' }
    if ($V -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $V.Keys) {
            $val = $V[$k]
            if ($val -is [string] -and ([string]$k -in $AlwaysRedactKeys -or (-not $IncludeContent -and [string]$k -in $RedactKeys))) { $o[[string]$k] = "[redacted $($val.Length) chars]" }
            else { $o[[string]$k] = Get-Redacted $val ($Depth + 1) }
        }
        return $o
    }
    if ($V -is [string]) { return $V }
    if ($V -is [datetime]) { return (Format-Dt $V) }
    if ($V -is [System.Collections.IEnumerable]) {
        $l = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $V) { $l.Add((Get-Redacted $i ($Depth + 1))) }
        return , $l.ToArray()
    }
    $V
}
function ConvertTo-RedactedJson($V, [switch]$Compress) { (Get-Redacted $V) | ConvertTo-Json -Depth 20 -Compress:$Compress }
function Get-IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function Write-P0 {
    param([string]$Message, [string]$Color)
    $tag = if ($script:Cur) { "[$($script:Cur.Id)] " } else { '' }
    if ($Color) { Write-Host "$tag$Message" -ForegroundColor $Color } else { Write-Host "$tag$Message" }
}
$script:Plan = [System.Collections.Generic.List[string]]::new()
function Write-P0Plan([string]$Line) { $script:Plan.Add($Line); Write-Host $Line -ForegroundColor DarkGray }
#endregion

#region JWT client assertion + token ------------------------------------------------------------------------------------
function New-ClientAssertion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Audience,
        [int]$LifetimeSeconds = 600
    )
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw "Certificate $($Certificate.Thumbprint) has no usable RSA private key in this user's store." }
    try {
        $x5tS256 = ConvertTo-Base64Url ([System.Security.Cryptography.SHA256]::HashData($Certificate.RawData))
        $now = [DateTimeOffset]::UtcNow
        $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; 'x5t#S256' = $x5tS256 }
        $payload = [ordered]@{
            aud = $Audience; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString()
            nbf = $now.AddSeconds(-30).ToUnixTimeSeconds(); iat = $now.ToUnixTimeSeconds(); exp = $now.AddSeconds($LifetimeSeconds).ToUnixTimeSeconds()
        }
        $h = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
        $p = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
        $signingInput = "$h.$p"
        $sig = $rsa.SignData([System.Text.Encoding]::ASCII.GetBytes($signingInput), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        "$signingInput.$(ConvertTo-Base64Url $sig)"
    }
    finally { $rsa.Dispose() }
}
function ConvertFrom-JwtPayload([string]$Jwt) {
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { throw 'Not a JWT.' }
    [System.Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json -AsHashtable
}
#endregion

#region HTTP -------------------------------------------------------------------------------------------------------------
$script:Http = $null
$script:Tokens = @{}
$script:Timings = [System.Collections.Generic.List[object]]::new()
function Get-Http {
    if (-not $script:Http) {
        $h = [System.Net.Http.SocketsHttpHandler]::new()
        $h.MaxConnectionsPerServer = 64
        $h.AutomaticDecompression = [System.Net.DecompressionMethods]::All
        $script:Http = [System.Net.Http.HttpClient]::new($h)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(180)
    }
    $script:Http
}
function New-DryJson {
    # One placeholder object that satisfies every property the probes read when nothing is sent.
    $item = @{
        id = '{id}'; chatId = '{chatId}'; replyToId = $null; messageType = 'message'; createdDateTime = '2026-01-01T00:00:00.000Z'
        lastModifiedDateTime = '2026-01-01T00:00:00.000Z'; membershipType = 'standard'; displayName = '{displayName}'
        userId = '{userId}'; visibleHistoryStartDateTime = $null; roles = @('owner'); chatType = 'group'; migrationMode = 'inProgress'
        channelIdentity = @{ teamId = '{teamId}'; channelId = '{channelId}' }
        from = @{ user = @{ id = '{userId}'; displayName = '{displayName}'; userIdentityType = 'aadUser' } }
        body = @{ contentType = 'html'; content = '<div>x<img src="https://example.invalid/chats/c/messages/m/hostedContents/{hostedId}/$value"></div>' }
        attachments = @(@{ contentType = 'reference'; contentUrl = 'https://example.invalid/sites/s/Shared%20Documents/file.txt'; name = 'file.txt' })
        members = @(@{ id = '{membershipId}'; userId = '{userId}'; displayName = '{displayName}'; roles = @('owner') })
    }
    $top = @{} + $item
    $top.value = @($item)
    $top.webUrl = 'https://example.invalid/{webUrl}'; $top.eTag = '"{00000000-0000-0000-0000-000000000000},1"'; $top.size = 3; $top.name = 'file.txt'
    $top.file = @{ mimeType = 'text/plain' }; $top.parentReference = @{ driveId = '{driveId}' }
    $top
}
function Invoke-P0Request {
    [CmdletBinding()]
    param(
        [string]$Method = 'GET', [Parameter(Mandatory)][string]$Url, $Body, [byte[]]$BodyBytes, [string]$ContentType,
        [hashtable]$Form, [string]$Token, [switch]$AsBytes, [switch]$NoRetry, [long]$MaxBytes = 52428800, [string]$Label = ''
    )
    $res = [ordered]@{
        Method = $Method; Url = $Url; Label = $Label; Status = 0; Ok = $false; Json = $null; Bytes = $null; ContentType = $null; Length = 0
        ErrorCode = $null; ErrorMessage = $null; RequestId = $null; ElapsedMs = 0; Retries429 = 0; RetryAfter = @(); DryRun = $false; Truncated = $false
        Date = $null
    }
    if ($DryRun) {
        $line = "[DRYRUN] $Method $Url"
        if ($Form) { $line += "  (form-encoded: " + (($Form.Keys | Where-Object { $_ -ne 'client_assertion' }) -join ', ') + ", client_assertion=<redacted JWT>)" }
        Write-P0Plan $line
        if ($null -ne $Body) { Write-P0Plan ('           body: ' + (ConvertTo-RedactedJson $Body -Compress)) }
        if ($BodyBytes) { Write-P0Plan "           body: $($BodyBytes.Length) bytes ($ContentType)" }
        $res.DryRun = $true; $res.Status = 0; $res.Ok = $true
        $res.Json = New-DryJson
        if ($AsBytes) { $res.Bytes = [byte[]](1, 2, 3, 4); $res.Length = 4; $res.ContentType = 'image/png' }
        $res.Url = $Url
        if ($script:Cur) { $script:Cur.Requests.Add([ordered]@{ method = $Method; url = $Url; label = $Label; dryRun = $true }) }
        return $res
    }
    $client = Get-Http
    $attempt = 0
    $ra = [System.Collections.Generic.List[double]]::new()
    $cid = [guid]::NewGuid().ToString()
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $attempt++
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        if ($Token) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") }
        [void]$req.Headers.TryAddWithoutValidation('client-request-id', $cid)
        if ($Form) {
            $fd = [System.Collections.Generic.Dictionary[string, string]]::new()
            foreach ($fk in $Form.Keys) { $fd[[string]$fk] = [string]$Form[$fk] }
            $req.Content = [System.Net.Http.FormUrlEncodedContent]::new($fd)
        }
        elseif ($null -ne $Body) { $req.Content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress), [System.Text.Encoding]::UTF8, 'application/json') }
        elseif ($BodyBytes) { $req.Content = [System.Net.Http.ByteArrayContent]::new($BodyBytes); $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType) }
        $resp = $null; $text = $null; $transport = $null
        try {
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $res.Status = [int]$resp.StatusCode
            $res.ContentType = if ($resp.Content.Headers.ContentType) { $resp.Content.Headers.ContentType.MediaType } else { $null }
            $vals = $null
            if ($resp.Headers.TryGetValues('request-id', [ref]$vals)) { $res.RequestId = @($vals)[0] }
            elseif ($resp.Headers.TryGetValues('x-ms-request-id', [ref]$vals)) { $res.RequestId = @($vals)[0] }
            if ($resp.Headers.Date) { $res.Date = $resp.Headers.Date.UtcDateTime.ToString('o') }
            $delta = $null
            if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $delta = $resp.Headers.RetryAfter.Delta.TotalSeconds }
            if ($null -ne $delta) { $ra.Add($delta) }
            if ($AsBytes -and $resp.IsSuccessStatusCode) {
                $ms = [System.IO.MemoryStream]::new()
                $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $buf = [byte[]]::new(81920)
                while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                    $ms.Write($buf, 0, $n)
                    if ($ms.Length -ge $MaxBytes) { $res.Truncated = $true; break }
                }
                $res.Bytes = $ms.ToArray(); $res.Length = $res.Bytes.Length
                $stream.Dispose(); $ms.Dispose()
            }
            else {
                $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $res.Length = $text.Length
            }
        }
        catch { $transport = $_.Exception.Message; $res.Status = 0 }
        finally { if ($resp) { $resp.Dispose() }; $req.Dispose() }

        $retryable = ($res.Status -in 429, 502, 503, 504) -or ($transport -and $attempt -le 2)
        if ($res.Status -eq 429) { $res.Retries429++ }
        if ($retryable -and -not $NoRetry -and $attempt -lt 7) {
            $wait = if ($ra.Count -gt 0 -and $res.Status -eq 429) { [math]::Min(90, $ra[$ra.Count - 1]) } else { [math]::Min(30, [math]::Pow(2, $attempt)) }
            Write-P0 "HTTP $($res.Status) on $Method $Label - waiting $([math]::Round($wait, 1)) s (attempt $attempt)" 'Yellow'
            Start-Sleep -Milliseconds ([int]($wait * 1000))
            continue
        }
        if ($transport) { $res.ErrorCode = 'TransportError'; $res.ErrorMessage = $transport }
        break
    }
    $swTotal.Stop()
    $res.ElapsedMs = [int]$swTotal.ElapsedMilliseconds
    $res.RetryAfter = @($ra)
    $res.Ok = ($res.Status -ge 200 -and $res.Status -lt 300)
    if ($text) {
        try { $res.Json = $text | ConvertFrom-Json -AsHashtable -Depth 40 } catch { $res.Json = $null }
        if ($res.Json -is [System.Collections.IDictionary] -and $res.Json.Contains('error')) {
            $e = $res.Json['error']
            if ($e -is [System.Collections.IDictionary]) {
                $res.ErrorCode = [string](Get-V $e 'code'); $res.ErrorMessage = [string](Get-V $e 'message')
                $rid = Get-V $e 'innerError' 'request-id'; if ($rid -and -not $res.RequestId) { $res.RequestId = [string]$rid }
            }
            else { $res.ErrorCode = [string]$e; $res.ErrorMessage = ([string](Get-V $res.Json 'error_description') -split "`n")[0] }
        }
        elseif (-not $res.Ok -and -not $res.ErrorCode) { $res.ErrorCode = "HTTP$($res.Status)"; $res.ErrorMessage = $text.Substring(0, [math]::Min(200, $text.Length)) }
    }
    elseif (-not $res.Ok -and -not $res.ErrorCode) { $res.ErrorCode = "HTTP$($res.Status)" }
    if ($res.ErrorMessage -and $res.ErrorMessage.Length -gt 300) { $res.ErrorMessage = $res.ErrorMessage.Substring(0, 300) }

    $probeId = if ($script:Cur) { $script:Cur.Id } else { '' }
    if ($script:Cur) {
        $script:Cur.Requests.Add([ordered]@{
                method = $Method; url = $Url; label = $Label; status = $res.Status; errorCode = $res.ErrorCode; errorMessage = $res.ErrorMessage
                requestId = $res.RequestId; clientRequestId = $cid; ms = $res.ElapsedMs; retries429 = $res.Retries429; retryAfter = $res.RetryAfter; bytes = $res.Length; date = $res.Date
            })
    }
    $script:Timings.Add([pscustomobject]@{
            Probe = $probeId; Step = $Label; Method = $Method; Url = $Url; Status = $res.Status; ErrorCode = $res.ErrorCode
            DurationMs = $res.ElapsedMs; Retries429 = $res.Retries429; Bytes = $res.Length; TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        })
    $res
}
function Get-AppToken {
    param([string]$ClientId)
    if (-not $ClientId) { throw 'Client id missing (give -ReaderClientId/-WriterClientId or run Grant-LabConsent.ps1 first).' }
    if (-not $TenantId) { throw 'TenantId missing.' }
    $tokenUrl = "$($CloudMap[$Cloud].Login)/$TenantId/oauth2/v2.0/token"
    if ($DryRun) {
        $null = Invoke-P0Request -Method POST -Url $tokenUrl -Form @{ grant_type = 'client_credentials'; client_id = $ClientId; scope = "$GraphHost/.default"; client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = '<JWT RS256, x5t#S256>' } -Label 'token'
        return 'DRYRUN-TOKEN'
    }
    $c = $script:Tokens[$ClientId]
    if ($c -and $c.Expires -gt (Get-Date).AddMinutes(5)) { return $c.Token }
    if (-not $script:Cert) { throw 'No certificate loaded (give -CertificateThumbprint).' }
    $assertion = New-ClientAssertion -Certificate $script:Cert -ClientId $ClientId -Audience $tokenUrl
    $r = Invoke-P0Request -Method POST -Url $tokenUrl -NoRetry -Label 'token' -Form @{
        grant_type = 'client_credentials'; client_id = $ClientId; scope = "$GraphHost/.default"
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = $assertion
    }
    if (-not $r.Ok) { throw "Token request for client $ClientId failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
    $tok = [string](Get-V $r.Json 'access_token')
    $script:Tokens[$ClientId] = @{ Token = $tok; Expires = (Get-Date).AddSeconds([int](Get-V $r.Json 'expires_in')) }
    $tok
}
function Invoke-P0Paged {
    param([string]$Url, [string]$Token, [int]$Pages = $MaxPages, [scriptblock]$Project, [string]$Label = 'page')
    $items = [System.Collections.Generic.List[object]]::new()
    $n = 0; $u = $Url; $first = -1; $last = $null; $trunc = $false; $sw = [System.Diagnostics.Stopwatch]::StartNew(); $rl = 0
    while ($u) {
        $r = Invoke-P0Request -Method GET -Url $u -Token $Token -Label "$Label#$($n + 1)"
        $last = $r
        $rl += $r.Retries429
        if (-not $r.Ok) { break }
        $n++
        $vals = Get-ValueList $r.Json
        foreach ($v in $vals) { $items.Add($(if ($Project) { & $Project $v } else { $v })) }
        if ($n -eq 1) { $first = $vals.Count }
        if ($r.DryRun) { break }
        $u = Get-V $r.Json '@odata.nextLink'
        if ($u -and $n -ge $Pages) { $trunc = $true; break }
    }
    $sw.Stop()
    [pscustomobject]@{ Items = $items; Pages = $n; FirstPageCount = $first; Truncated = $trunc; Last = $last; Ok = ($null -ne $last -and $last.Ok); ElapsedMs = [int]$sw.ElapsedMilliseconds; Retries429 = $rl }
}
function ConvertTo-MsgSummary($m) {
    $body = [string](Get-V $m 'body' 'content')
    $hosted = @([regex]::Matches($body, 'hostedContents/([^/"]+)/\$value') | ForEach-Object { $_.Groups[1].Value })
    $refs = @()
    foreach ($a in @(Get-V $m 'attachments')) {
        if ($a -and (Get-V $a 'contentType') -eq 'reference' -and (Get-V $a 'contentUrl')) { $refs += @{ name = (Get-V $a 'name'); contentUrl = (Get-V $a 'contentUrl') } }
    }
    $chatId = Get-V $m 'chatId'; $teamId = Get-V $m 'channelIdentity' 'teamId'; $channelId = Get-V $m 'channelIdentity' 'channelId'
    @{
        id = [string](Get-V $m 'id'); chatId = $chatId; teamId = $teamId; channelId = $channelId; replyToId = Get-V $m 'replyToId'
        type = Get-V $m 'messageType'; created = Format-Dt (Get-V $m 'createdDateTime'); modified = Format-Dt (Get-V $m 'lastModifiedDateTime')
        fromId = Get-V $m 'from' 'user' 'id'; fromType = Get-V $m 'from' 'user' 'userIdentityType'; bodyLen = $body.Length
        hosted = $hosted; refs = $refs; key = "$chatId|$teamId|$channelId|$([string](Get-V $m 'id'))"
    }
}
function Get-QueryWindow {
    $f = Format-Dt $From; $t = Format-Dt $To
    '$filter=' + [uri]::EscapeDataString("lastModifiedDateTime gt $f and lastModifiedDateTime lt $t")
}
function Format-UserSegment([string]$User) { [uri]::EscapeDataString($User) }
#endregion

#region probe framework -----------------------------------------------------------------------------------------------
$script:Cur = $null
$script:Results = [ordered]@{}
$script:Seen = [System.Collections.Generic.List[object]]::new()   # message summaries seen by R2/R3/R4 (for R5/R6)
$script:UKeys = $null; $script:UChatIds = $null
$script:Created = [System.Collections.Generic.List[object]]::new()
$script:WriteChatId = $null
$script:OutDir = $null

function Start-Probe {
    param([string]$Id, [string]$Name, [string]$Question)
    $script:Cur = @{
        Id = $Id; Name = $Name; Question = $Question; Status = 'Inconclusive'; Answer = ''; Done = $false
        Observations = [ordered]@{}; Steps = [System.Collections.Generic.List[object]]::new(); Requests = [System.Collections.Generic.List[object]]::new()
        Notes = [System.Collections.Generic.List[string]]::new(); StartedUtc = (Get-Date).ToUniversalTime().ToString('o'); DurationMs = 0
        _sw = [System.Diagnostics.Stopwatch]::StartNew()
    }
    Write-Host ''
    Write-Host "=== $Id - $Name ===" -ForegroundColor Cyan
}
function Add-Obs([string]$Key, $Value) { $script:Cur.Observations[$Key] = $Value }
function Add-Note([string]$Text) { $script:Cur.Notes.Add($Text); Write-P0 $Text 'DarkYellow' }
function Add-Step {
    param([string]$Name, $R, [string]$Expect = '')
    $s = [ordered]@{ step = $Name; status = $R.Status; ok = $R.Ok; errorCode = $R.ErrorCode; errorMessage = $R.ErrorMessage; requestId = $R.RequestId; ms = $R.ElapsedMs; retries429 = $R.Retries429; expect = $Expect }
    $script:Cur.Steps.Add($s)
    $col = if ($R.Ok) { 'DarkGreen' } else { 'DarkYellow' }
    Write-P0 ("{0}: HTTP {1} {2} {3}ms {4}" -f $Name, $R.Status, $R.ErrorCode, $R.ElapsedMs, $(if ($Expect) { "(expected: $Expect)" } else { '' })) $col
}
function Stop-Probe {
    param([ValidateSet('Pass', 'Fail', 'Inconclusive')][string]$Status, [string]$Answer)
    $c = $script:Cur
    if ($c.Done) { return }
    $c.Done = $true
    $c._sw.Stop(); $c.DurationMs = [int]$c._sw.ElapsedMilliseconds; $c.Remove('_sw')
    $c.Status = if ($DryRun) { 'DryRun' } else { $Status }
    $c.Answer = $(if ($DryRun) { 'dry run - requests printed only, nothing sent' } else { $Answer })
    $c.FinishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $script:Results[$c.Id] = $c
    $col = switch ($c.Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'DryRun' { 'Cyan' } default { 'Yellow' } }
    Write-Host "[$($c.Id)] $($c.Status): $($c.Answer)" -ForegroundColor $col
    ConvertTo-RedactedJson $c | Set-Content -LiteralPath (Join-Path $script:OutDir "$($c.Id).json") -Encoding utf8
}
function Get-ReaderToken { Get-AppToken $ReaderClientId }
function Get-WriterToken { Get-AppToken $WriterClientId }
function Get-ErrBrief($r) { if ($r.Ok) { 'ok' } else { "HTTP $($r.Status) $($r.ErrorCode)" } }
#endregion

#region read probes ------------------------------------------------------------------------------------------------------
function Invoke-ProbeR1 {
    Start-Probe 'R1' 'Token and roles' 'Does each app get a token (certificate assertion) with exactly the expected application roles?'
    $apps = [ordered]@{ Reader = $ReaderClientId; Writer = $WriterClientId }
    if ($OtherAppClientId -and $OtherAppClientId -ne $ReaderClientId -and $OtherAppClientId -ne $WriterClientId) { $apps['Other'] = $OtherAppClientId }
    $allOk = $true; $any = $false; $summary = @()
    foreach ($name in $apps.Keys) {
        $cid = $apps[$name]
        if (-not $cid) { Add-Obs $name @{ skipped = 'no client id' }; continue }
        $any = $true
        try {
            $tok = Get-AppToken $cid
            if ($DryRun) { Add-Obs $name @{ plan = 'decode roles claim, compare with expected' }; continue }
            $claims = ConvertFrom-JwtPayload $tok
            $roles = @(Get-V $claims 'roles')
            $exp = if ($name -eq 'Other') { @() } else { $ExpectedRoles[$name] }
            $missing = @($exp | Where-Object { $_ -notin $roles })
            $extra = @($roles | Where-Object { $_ -and $_ -notin $exp })
            $o = [ordered]@{
                appid = Get-V $claims 'appid'; tid = Get-V $claims 'tid'; aud = Get-V $claims 'aud'; idtyp = Get-V $claims 'idtyp'
                expiresUtc = ([DateTimeOffset]::FromUnixTimeSeconds([long](Get-V $claims 'exp'))).UtcDateTime.ToString('o')
                roles = $roles; missing = $missing; extra = $extra
            }
            if ($name -eq 'Other') { $o.hasTeamworkMigrateAll = ('Teamwork.Migrate.All' -in $roles) }
            Add-Obs $name $o
            if ($name -ne 'Other' -and $missing.Count -gt 0) { $allOk = $false; $summary += "$name missing: $($missing -join ', ')" }
            if ($name -ne 'Other' -and $TenantId -match '^[0-9a-fA-F-]{36}$' -and (Get-V $claims 'tid') -ne $TenantId) { $allOk = $false; $summary += "$name token tid differs from -TenantId" }
        }
        catch { $allOk = $false; Add-Obs $name @{ error = $_.Exception.Message }; $summary += "$name token failed: $($_.Exception.Message)" }
    }
    if (-not $any) { Stop-Probe 'Inconclusive' 'No client id available.'; return }
    if ($allOk) { Stop-Probe 'Pass' 'Tokens obtained with certificate assertion; all expected application roles are present.' }
    else { Stop-Probe 'Fail' ($summary -join ' | ') }
}

function Invoke-ProbeR2 {
    Start-Probe 'R2' 'Export strategy U (per user getAllMessages)' 'Is /users/{id}/chats/getAllMessages usable app-only? Throughput, pages, is $top honoured, behaviour without model / model=A / model=B?'
    if (-not $TestUserId) { Stop-Probe 'Inconclusive' '-TestUserId missing.'; return }
    $tok = Get-ReaderToken
    $base = "$G/users/$(Format-UserSegment $TestUserId)/chats/getAllMessages"
    $win = Get-QueryWindow
    Add-Obs 'window' @{ from = (Format-Dt $From); to = (Format-Dt $To); maxPagesPerVariant = $MaxPages }
    $variants = @(@{ Name = 'noModel'; Q = '' }, @{ Name = 'modelB'; Q = '&model=B' }, @{ Name = 'modelA'; Q = '&model=A' })
    $okNames = @(); $first = $null
    foreach ($v in $variants) {
        $url = $base + '?$top=50' + $v.Q + '&' + $win
        $p = Invoke-P0Paged -Url $url -Token $tok -Label "getAllMessages-$($v.Name)" -Project { param($m) ConvertTo-MsgSummary $m }
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($i in $p.Items) { if ($i.chatId) { [void]$keys.Add($i.key) } }
        $rate = if ($p.ElapsedMs -gt 0) { [math]::Round($p.Items.Count / ($p.ElapsedMs / 1000.0), 1) } else { 0 }
        Add-Obs $v.Name ([ordered]@{
                ok = $p.Ok; status = $p.Last.Status; errorCode = $p.Last.ErrorCode; errorMessage = $p.Last.ErrorMessage; requestId = $p.Last.RequestId
                pages = $p.Pages; firstPageCount = $p.FirstPageCount; messages = $p.Items.Count; distinctChatMessages = $keys.Count
                truncatedByMaxPages = $p.Truncated; elapsedMs = $p.ElapsedMs; messagesPerSecond = $rate; throttled429 = $p.Retries429
                sampleHeader = @{ contentType = $p.Last.ContentType; date = $p.Last.Date }
            })
        Add-Step "getAllMessages-$($v.Name)" $p.Last
        if ($p.Ok) {
            $okNames += $v.Name
            if (-not $first) {
                $first = $v.Name; $script:UKeys = $keys
                $script:UChatIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($p.Items | Where-Object { $_.chatId } | ForEach-Object { [string]$_.chatId }))
                foreach ($i in $p.Items) { $script:Seen.Add($i) }
            }
        }
    }
    foreach ($t in 20, 100) {
        $r = Invoke-P0Request -Method GET -Url ($base + '?$top=' + $t + '&' + $win) -Token $tok -Label "top$t"
        $cnt = if ($r.Ok) { (Get-ValueList $r.Json).Count } else { -1 }
        Add-Obs "top$t" ([ordered]@{ status = $r.Status; errorCode = $r.ErrorCode; returned = $cnt; honoured = ($cnt -ge 0 -and $cnt -le $t) })
        Add-Step "top=$t" $r
    }
    if ($okNames.Count -eq 0) {
        $c = $script:Cur.Observations['noModel']
        Stop-Probe 'Fail' "getAllMessages refused for every variant (noModel: HTTP $($c['status']) $($c['errorCode'])). 403 usually means the protected-API access or the consent is missing; 402/429 may signal evaluation/metering."
        return
    }
    $nm = $script:Cur.Observations['noModel']
    $ans = "Allowed app-only for: $($okNames -join ', '). Without model: HTTP $($nm['status']) $($nm['errorCode']) ($($nm['messages']) msgs, $($nm['pages']) pages, $($nm['messagesPerSecond']) msg/s)."
    Stop-Probe 'Pass' $ans
}

function Invoke-ProbeR3 {
    Start-Probe 'R3' 'Export strategy C (per chat, dedup)' 'Can chats be listed and read per chat app-only? Are $filter/$orderby on lastModifiedDateTime supported? Page size max? Same messages as strategy U?'
    if (-not $TestUserId) { Stop-Probe 'Inconclusive' '-TestUserId missing.'; return }
    $tok = Get-ReaderToken
    $lst = Invoke-P0Paged -Url ("$G/users/$(Format-UserSegment $TestUserId)/chats?`$expand=members&`$top=50") -Token $tok -Label 'chats' -Project {
        param($c) @{ id = [string](Get-V $c 'id'); chatType = Get-V $c 'chatType'; members = @(Get-V $c 'members').Count; topic = $null }
    }
    Add-Step 'list chats ($expand=members)' $lst.Last
    Add-Obs 'chatList' ([ordered]@{ ok = $lst.Ok; status = $lst.Last.Status; errorCode = $lst.Last.ErrorCode; chats = $lst.Items.Count; pages = $lst.Pages; firstPageCount = $lst.FirstPageCount; elapsedMs = $lst.ElapsedMs; truncatedByMaxPages = $lst.Truncated })
    if (-not $lst.Ok) { Stop-Probe 'Fail' "Chat list refused app-only: HTTP $($lst.Last.Status) $($lst.Last.ErrorCode)."; return }
    $byType = @{}; $mem = 0
    foreach ($c in $lst.Items) { $t = [string]$c.chatType; $byType[$t] = 1 + $(if ($byType.ContainsKey($t)) { $byType[$t] } else { 0 }); $mem += [int]$c.members }
    Add-Obs 'chatTypes' $byType
    Add-Obs 'averageMembersPerChat' $(if ($lst.Items.Count -gt 0) { [math]::Round($mem / $lst.Items.Count, 2) } else { 0 })

    $sample = @($lst.Items | Select-Object -First $MaxChats)
    $win = Get-QueryWindow
    $cKeys = [System.Collections.Generic.HashSet[string]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $msgCount = 0; $reqCount = 0; $allowed = $null
    foreach ($c in $sample) {
        $u = "$G/chats/$([uri]::EscapeDataString($c.id))/messages?`$top=50&`$orderby=lastModifiedDateTime desc&" + $win
        $u = $u.Replace(' ', '%20')
        $p = Invoke-P0Paged -Url $u -Token $tok -Pages 5 -Label 'chat-messages' -Project { param($m) ConvertTo-MsgSummary $m }
        $reqCount += $p.Pages
        if ($null -eq $allowed) { $allowed = $p.Ok; Add-Step 'chat messages (orderby+filter)' $p.Last }
        if ($p.Ok) { foreach ($i in $p.Items) { [void]$cKeys.Add($i.key); $script:Seen.Add($i); $msgCount++ } }
    }
    $sw.Stop()
    Add-Obs 'perChat' ([ordered]@{ allowedAppOnly = $allowed; chatsRead = $sample.Count; messages = $msgCount; distinctMessages = $cKeys.Count; requests = $reqCount; elapsedMs = [int]$sw.ElapsedMilliseconds })
    if ($sample.Count -eq 0) { Stop-Probe 'Inconclusive' 'The user has no chat.'; return }
    if (-not $allowed) { Stop-Probe 'Fail' "GET /chats/{id}/messages refused app-only: see steps (ChatMessage.Read.Chat is RSC-only; Chat.Read.All may need protected-API access)."; return }

    # query option behaviour on the first chat
    $cid = [uri]::EscapeDataString($sample[0].id)
    $tests = [ordered]@{
        orderbyFilter    = "`$top=50&`$orderby=lastModifiedDateTime desc&$win"
        filterNoOrderby  = "`$top=50&$win"
        noQuery          = '$top=50'
        top100           = '$top=100'
        orderbyAsc       = '$orderby=lastModifiedDateTime asc&$top=5'
        orderbyCreated   = '$orderby=createdDateTime desc&$top=5'
    }
    $counts = [ordered]@{}
    foreach ($k in $tests.Keys) {
        $u = ("$G/chats/$cid/messages?" + $tests[$k]).Replace(' ', '%20')
        $p = Invoke-P0Paged -Url $u -Token $tok -Pages 3 -Label "q-$k"
        $counts[$k] = [ordered]@{ status = $p.Last.Status; errorCode = $p.Last.ErrorCode; messages = $p.Items.Count; firstPageCount = $p.FirstPageCount }
        Add-Step "query-$k" $p.Last
    }
    Add-Obs 'queryOptions' $counts
    $fi = $counts['filterNoOrderby']; $nq = $counts['noQuery']
    Add-Obs 'filterIgnoredWithoutOrderby' $(if ($fi.status -eq 200 -and $nq.status -eq 200) { $fi.messages -eq $nq.messages } else { 'undetermined' })
    Add-Obs 'pageSizeMax' $(if ($counts['top100'].status -eq 200) { $counts['top100'].firstPageCount } else { "top=100 -> HTTP $($counts['top100'].status) $($counts['top100'].errorCode)" })

    # dedup proof vs strategy U on the same chats
    if ($script:UKeys) {
        $chatIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sample | ForEach-Object { [string]$_.id }))
        $uKeys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($k in $script:UKeys) { $cidPart = $k.Split('|')[0]; if ($chatIds.Contains($cidPart)) { [void]$uKeys.Add($k) } }
        $onlyC = @($cKeys | Where-Object { -not $uKeys.Contains($_) }).Count
        $onlyU = @($uKeys | Where-Object { -not $cKeys.Contains($_) }).Count
        Add-Obs 'comparisonWithR2' ([ordered]@{ strategyC = $cKeys.Count; strategyU = $uKeys.Count; onlyInC = $onlyC; onlyInU = $onlyU; identical = ($onlyC -eq 0 -and $onlyU -eq 0) })
        $cmp = "C vs U on the same $($sample.Count) chats: $($cKeys.Count) vs $($uKeys.Count) messages, onlyC=$onlyC, onlyU=$onlyU."
    }
    else { $cmp = 'R2 was not run (or failed) in this run: no U/C comparison.'; Add-Note $cmp }
    Stop-Probe 'Pass' "Per-chat read allowed app-only. $cmp Distinct chats listed: $($lst.Items.Count); average members per chat: $($script:Cur.Observations['averageMembersPerChat'])."
}

function Invoke-ProbeR4 {
    Start-Probe 'R4' 'Channels' 'Channel inventory (standard/private/shared), channel getAllMessages, per-channel messages and replies.'
    if (-not $TestTeamId) { Stop-Probe 'Inconclusive' '-TestTeamId missing.'; return }
    $tok = Get-ReaderToken
    $t = [uri]::EscapeDataString($TestTeamId)
    $ch = Invoke-P0Paged -Url "$G/teams/$t/channels" -Token $tok -Label 'channels' -Project { param($c) @{ id = [string](Get-V $c 'id'); name = Get-V $c 'displayName'; type = [string](Get-V $c 'membershipType') } }
    Add-Step 'list channels' $ch.Last
    $types = @{}; foreach ($c in $ch.Items) { $k = [string]$c.type; $types[$k] = 1 + $(if ($types.ContainsKey($k)) { $types[$k] } else { 0 }) }
    Add-Obs 'channels' ([ordered]@{ ok = $ch.Ok; status = $ch.Last.Status; errorCode = $ch.Last.ErrorCode; count = $ch.Items.Count; byMembershipType = $types })
    if (-not $ch.Ok) { Stop-Probe 'Fail' "Channel list refused: HTTP $($ch.Last.Status) $($ch.Last.ErrorCode)."; return }
    $all = Invoke-P0Request -Method GET -Url "$G/teams/$t/allChannels?`$select=id,displayName,membershipType" -Token $tok -Label 'allChannels'
    Add-Step 'allChannels (incl. shared)' $all
    Add-Obs 'allChannels' ([ordered]@{ status = $all.Status; errorCode = $all.ErrorCode; count = $(if ($all.Ok) { (Get-ValueList $all.Json).Count } else { -1 }) })

    $win = Get-QueryWindow
    $gam = Invoke-P0Paged -Url ("$G/teams/$t/channels/getAllMessages?`$top=50&" + $win) -Token $tok -Label 'channels-getAllMessages' -Project { param($m) ConvertTo-MsgSummary $m }
    Add-Step 'channels/getAllMessages' $gam.Last
    $gamKeys = [System.Collections.Generic.HashSet[string]]::new(); foreach ($i in $gam.Items) { [void]$gamKeys.Add($i.key); $script:Seen.Add($i) }
    $gamB = Invoke-P0Request -Method GET -Url ("$G/teams/$t/channels/getAllMessages?`$top=5&model=B&" + $win) -Token $tok -Label 'channels-getAllMessages-modelB'
    Add-Step 'channels/getAllMessages?model=B' $gamB
    Add-Obs 'getAllMessages' ([ordered]@{ ok = $gam.Ok; status = $gam.Last.Status; errorCode = $gam.Last.ErrorCode; pages = $gam.Pages; firstPageCount = $gam.FirstPageCount; messages = $gam.Items.Count; distinct = $gamKeys.Count; elapsedMs = $gam.ElapsedMs; truncatedByMaxPages = $gam.Truncated; modelBStatus = $gamB.Status; modelBErrorCode = $gamB.ErrorCode })

    $perKeys = [System.Collections.Generic.HashSet[string]]::new(); $per = @(); $replyTotal = 0
    foreach ($c in @($ch.Items | Select-Object -First $MaxChannels)) {
        $cid = [uri]::EscapeDataString($c.id)
        $m = Invoke-P0Paged -Url "$G/teams/$t/channels/$cid/messages?`$top=50" -Token $tok -Pages 5 -Label 'channel-messages' -Project { param($x) ConvertTo-MsgSummary $x }
        Add-Step "messages of channel $($c.name) [$($c.type)]" $m.Last
        $rep = 0; $repStatus = $null
        if ($m.Ok) {
            foreach ($i in $m.Items) { [void]$perKeys.Add($i.key); $script:Seen.Add($i) }
            foreach ($root in @($m.Items | Where-Object { -not $_.replyToId } | Select-Object -First 5)) {
                $rp = Invoke-P0Paged -Url "$G/teams/$t/channels/$cid/messages/$([uri]::EscapeDataString($root.id))/replies?`$top=50" -Token $tok -Pages 3 -Label 'replies' -Project { param($x) ConvertTo-MsgSummary $x }
                $repStatus = $rp.Last.Status
                if ($rp.Ok) { $rep += $rp.Items.Count; foreach ($i in $rp.Items) { [void]$perKeys.Add($i.key); $script:Seen.Add($i) } }
            }
        }
        $replyTotal += $rep
        $mem = $null
        if ([string]$c.type -ne 'standard') {
            $mr = Invoke-P0Request -Method GET -Url "$G/teams/$t/channels/$cid/members" -Token $tok -Label 'channel-members'
            Add-Step "members of $($c.type) channel" $mr
            $mem = [ordered]@{ status = $mr.Status; errorCode = $mr.ErrorCode; count = $(if ($mr.Ok) { (Get-ValueList $mr.Json).Count } else { -1 }) }
        }
        $per += [ordered]@{ channel = $c.name; type = $c.type; messagesStatus = $m.Last.Status; errorCode = $m.Last.ErrorCode; rootsAndRepliesOnPage = $m.Items.Count; repliesRead = $rep; repliesStatus = $repStatus; members = $mem }
    }
    Add-Obs 'perChannel' $per
    Add-Obs 'perChannelDistinctMessages' $perKeys.Count
    $inter = @($perKeys | Where-Object { $gamKeys.Contains($_) }).Count
    Add-Obs 'comparisonGetAllMessagesVsPerChannel' ([ordered]@{ getAllMessages = $gamKeys.Count; perChannel = $perKeys.Count; common = $inter; note = 'Per-channel read is bounded by MaxChannels/MaxPages, so perChannel can be smaller.' })
    $ans = "Channels: $($ch.Items.Count) ($(($types.Keys | ForEach-Object { "$_=$($types[$_])" }) -join ', ')). getAllMessages: HTTP $($gam.Last.Status) $($gam.Last.ErrorCode), $($gam.Items.Count) msgs. Per channel: $($perKeys.Count) distinct msgs incl. $replyTotal replies."
    if ($gam.Ok -or $perKeys.Count -gt 0) { Stop-Probe 'Pass' $ans } else { Stop-Probe 'Fail' $ans }
}

function Find-SampleMessage {
    # Finds a message summary matching $Predicate: first in what R2/R3/R4 saw, then by a small scan of the lab objects.
    param([ValidateSet('Chat', 'Channel')][string]$Kind, [scriptblock]$Predicate, [string]$Token)
    foreach ($i in $script:Seen) {
        $isChat = [bool]$i.chatId
        if (($Kind -eq 'Chat') -eq $isChat -and (& $Predicate $i)) { return $i }
    }
    $proj = { param($x) ConvertTo-MsgSummary $x }
    if ($Kind -eq 'Chat') {
        $chatIds = @()
        if ($TestChatId) { $chatIds = @($TestChatId) }
        elseif ($TestUserId) {
            $cl = Invoke-P0Request -Method GET -Url ("$G/users/$(Format-UserSegment $TestUserId)/chats?`$top=20") -Token $Token -Label 'scan-chats'
            if ($cl.Ok) { $chatIds = @(Get-ValueList $cl.Json | ForEach-Object { [string](Get-V $_ 'id') }) }
        }
        foreach ($cid in $chatIds) {
            $p = Invoke-P0Paged -Url "$G/chats/$([uri]::EscapeDataString($cid))/messages?`$top=50" -Token $Token -Pages 2 -Label 'scan-chat' -Project $proj
            foreach ($i in $p.Items) { if (& $Predicate $i) { return $i } }
        }
    }
    elseif ($TestTeamId) {
        $t = [uri]::EscapeDataString($TestTeamId)
        $cl = Invoke-P0Request -Method GET -Url "$G/teams/$t/channels?`$select=id" -Token $Token -Label 'scan-channels'
        if ($cl.Ok) {
            foreach ($c in @(Get-ValueList $cl.Json | Select-Object -First 5)) {
                $p = Invoke-P0Paged -Url "$G/teams/$t/channels/$([uri]::EscapeDataString([string](Get-V $c 'id')))/messages?`$top=50" -Token $Token -Pages 2 -Label 'scan-channel' -Project $proj
                foreach ($i in $p.Items) { if (& $Predicate $i) { return $i } }
            }
        }
    }
    $null
}
function Get-MessageBaseUrl($m) {
    if ($m.chatId) { return "$G/chats/$([uri]::EscapeDataString($m.chatId))/messages/$([uri]::EscapeDataString($m.id))" }
    $b = "$G/teams/$([uri]::EscapeDataString($m.teamId))/channels/$([uri]::EscapeDataString($m.channelId))/messages"
    if ($m.replyToId) { return "$b/$([uri]::EscapeDataString([string]$m.replyToId))/replies/$([uri]::EscapeDataString($m.id))" }
    "$b/$([uri]::EscapeDataString($m.id))"
}

function Invoke-ProbeR5 {
    Start-Probe 'R5' 'Hosted contents' 'Can an inline image (hostedContents) be downloaded app-only for a chat message and a channel message?'
    $tok = Get-ReaderToken
    $results = [ordered]@{}; $okCount = 0; $tested = 0
    foreach ($kind in 'Chat', 'Channel') {
        $m = Find-SampleMessage -Kind $kind -Token $tok -Predicate { param($i) $i.hosted.Count -gt 0 }
        if (-not $m) { $results[$kind] = 'no message with an inline image found (post one in the lab chat/channel, or give -TestChatId/-TestTeamId)'; Add-Note "$kind`: no sample." ; continue }
        $tested++
        $base = Get-MessageBaseUrl $m
        $lr = Invoke-P0Request -Method GET -Url "$base/hostedContents" -Token $tok -Label "$kind-hostedContents-list"
        Add-Step "$kind hostedContents list" $lr
        $hid = $m.hosted[0]
        $dr = Invoke-P0Request -Method GET -Url ("$base/hostedContents/$([uri]::EscapeDataString($hid))/" + '$value') -Token $tok -AsBytes -Label "$kind-hostedContent-value"
        Add-Step "$kind hostedContent `$value" $dr
        $sha = if ($dr.Ok -and $dr.Bytes) { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($dr.Bytes)) } else { $null }
        $results[$kind] = [ordered]@{ listStatus = $lr.Status; downloadStatus = $dr.Status; errorCode = $dr.ErrorCode; contentType = $dr.ContentType; bytes = $dr.Length; sha256 = $sha; hostedIdsInMessage = $m.hosted.Count; isReply = [bool]$m.replyToId }
        if ($dr.Ok) { $okCount++ }
    }
    Add-Obs 'samples' $results
    if ($tested -eq 0) { Stop-Probe 'Inconclusive' 'No message with an inline image found.'; return }
    if ($okCount -eq $tested) { Stop-Probe 'Pass' "Inline images downloaded for $okCount/$tested kind(s) (chat/channel) with the Reader app." }
    elseif ($okCount -gt 0) { Stop-Probe 'Inconclusive' "Only $okCount/$tested kind(s) downloaded: see steps." }
    else { Stop-Probe 'Fail' 'hostedContents download refused for all tested messages.' }
}

function Resolve-SharedFile {
    param([string]$ContentUrl, [string]$Token, [string]$Tag)
    $shareId = 'u!' + (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($ContentUrl)))
    $di = Invoke-P0Request -Method GET -Url "$G/shares/$shareId/driveItem?`$select=id,name,size,file,parentReference,webUrl,lastModifiedDateTime" -Token $Token -Label "$Tag-driveItem"
    Add-Step "$Tag resolve /shares/u!.../driveItem" $di
    $o = [ordered]@{ resolveStatus = $di.Status; errorCode = $di.ErrorCode }
    if ($di.Ok) {
        $o.name = Get-V $di.Json 'name'; $o.sizeReported = Get-V $di.Json 'size'; $o.mimeType = Get-V $di.Json 'file' 'mimeType'
        $o.driveId = Get-V $di.Json 'parentReference' 'driveId'; $o.itemId = Get-V $di.Json 'id'
        $dl = Invoke-P0Request -Method GET -Url "$G/shares/$shareId/driveItem/content" -Token $Token -AsBytes -Label "$Tag-content"
        Add-Step "$Tag download content" $dl
        $o.downloadStatus = $dl.Status; $o.downloadError = $dl.ErrorCode; $o.bytesDownloaded = $dl.Length; $o.truncated = $dl.Truncated; $o.downloadMs = $dl.ElapsedMs
        if ($dl.Ok -and $dl.Bytes) { $o.sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($dl.Bytes)) }
        $o.ok = $dl.Ok
    }
    else { $o.ok = $false }
    $o
}
function Invoke-ProbeR6 {
    Start-Probe 'R6' 'Files (reference attachments)' 'Can a reference attachment be resolved to a driveItem and downloaded app-only? Size/hash. Departed owner? Deleted identity lookup?'
    $tok = Get-ReaderToken
    $res = [ordered]@{}; $okCount = 0; $tested = 0
    foreach ($kind in 'Chat', 'Channel') {
        $m = Find-SampleMessage -Kind $kind -Token $tok -Predicate { param($i) $i.refs.Count -gt 0 }
        if (-not $m) { $res[$kind] = 'no message with a reference attachment found'; Add-Note "$kind`: no file sample."; continue }
        $tested++
        $o = Resolve-SharedFile -ContentUrl $m.refs[0].contentUrl -Token $tok -Tag $kind
        $o.attachmentName = $m.refs[0].name
        $res[$kind] = $o
        if ($o.ok) { $okCount++ }
    }
    if ($DepartedFileUrl) {
        $o = Resolve-SharedFile -ContentUrl $DepartedFileUrl -Token $tok -Tag 'departed'
        $res['DepartedOwnerFile'] = $o
    }
    else { Add-Note 'No -DepartedFileUrl: the departed-user OneDrive case was not tested.' }
    if ($DeletedUserId) {
        $d = Invoke-P0Request -Method GET -Url "$G/directory/deletedItems/microsoft.graph.user/$([uri]::EscapeDataString($DeletedUserId))?`$select=id,displayName,userPrincipalName,deletedDateTime" -Token $tok -Label 'deleted-identity'
        Add-Step 'deleted user via directory/deletedItems' $d
        $u = Invoke-P0Request -Method GET -Url "$G/users/$([uri]::EscapeDataString($DeletedUserId))?`$select=id,displayName" -Token $tok -Label 'deleted-identity-users'
        Add-Step 'deleted user via /users/{id}' $u
        $res['DeletedIdentity'] = [ordered]@{ deletedItemsStatus = $d.Status; deletedItemsError = $d.ErrorCode; displayNameResolved = [bool](Get-V $d.Json 'displayName'); usersEndpointStatus = $u.Status }
    }
    Add-Obs 'samples' $res
    if ($tested -eq 0 -and -not $DepartedFileUrl) { Stop-Probe 'Inconclusive' 'No reference attachment found (post a file in the lab chat and channel).'; return }
    if ($okCount -gt 0) { Stop-Probe 'Pass' "Reference attachments resolved and downloaded for $okCount/$tested kind(s)." } else { Stop-Probe 'Fail' 'No reference attachment could be downloaded with the Reader app (Files.Read.All/Sites.Read.All): see steps.' }
}

function Invoke-ProbeR7 {
    Start-Probe 'R7' 'Throughput sampler' 'Which request rate does an endpoint sustain with increasing concurrency before the first 429 / sustained 429?'
    $u = switch ($R7Target) {
        'ChatList' { if ($TestUserId) { "$G/users/$(Format-UserSegment $TestUserId)/chats?`$top=1" } }
        'ChatMessages' { if ($TestChatId) { "$G/chats/$([uri]::EscapeDataString($TestChatId))/messages?`$top=1" } }
        'GetAllMessages' { if ($TestUserId) { "$G/users/$(Format-UserSegment $TestUserId)/chats/getAllMessages?`$top=1" } }
        'ChannelMessages' { if ($TestTeamId -and $TestChannelId) { "$G/teams/$([uri]::EscapeDataString($TestTeamId))/channels/$([uri]::EscapeDataString($TestChannelId))/messages?`$top=1" } }
        'Custom' { if ($R7Url) { "$G/" + $R7Url.TrimStart('/') } }
    }
    if (-not $u) { Stop-Probe 'Inconclusive' "Target $R7Target needs its ids (-TestChatId / -TestUserId / -TestTeamId+-TestChannelId / -R7Url)."; return }
    $levels = @(); $c = 1; while ($c -le $MaxConcurrency) { $levels += $c; $c *= 2 }
    Write-Host "WARNING: R7 deliberately pushes request volume on $R7Target for up to $MaxSeconds s and CONSUMES TENANT QUOTA. Lab tenant only." -ForegroundColor Yellow
    if ($DryRun) {
        Write-P0Plan "[DRYRUN] R7 ramp on GET $u : concurrency levels $($levels -join ',') for at most $MaxSeconds s in total; stops at the first sustained 429 window (>=50% 429 over two 2-s slices)."
        Write-P0Plan "[DRYRUN] GET $u  (x concurrent workers, no retry on 429)"
        Add-Obs 'plan' @{ url = $u; levels = $levels; maxSeconds = $MaxSeconds }
        Stop-Probe 'Inconclusive' 'dry run'; return
    }
    if (-not (Confirm-LabAction -Cmdlet $script:ToolCmdlet -Query "R7 pushes request volume on $R7Target for up to $MaxSeconds s and consumes tenant quota. Continue?" -Caption 'Invoke-Phase0 - throughput sampler' -Force:$Force)) { Stop-Probe 'Inconclusive' 'Cancelled by the operator.'; return }
    $tok = Get-ReaderToken
    $client = Get-Http
    $deadline = [DateTime]::UtcNow.AddSeconds($MaxSeconds)
    $slice = [math]::Max(3, [math]::Floor($MaxSeconds / $levels.Count))
    $out = @(); $stop = $null; $first429 = $null; $retryAfters = [System.Collections.Generic.List[double]]::new(); $bestClean = 0.0
    foreach ($lvl in $levels) {
        if ([DateTime]::UtcNow -ge $deadline) { $stop = 'time budget reached'; break }
        $levelEnd = [DateTime]::UtcNow.AddSeconds($slice); if ($levelEnd -gt $deadline) { $levelEnd = $deadline }
        $inflight = [System.Collections.Generic.List[object]]::new()   # @{Task;Start}
        $codes = @{}; $lat = [System.Collections.Generic.List[double]]::new(); $n = 0; $n429 = 0
        $sliceStart = [DateTime]::UtcNow; $sTot = 0; $s429 = 0; $bad = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $startOne = {
            $rq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $u)
            [void]$rq.Headers.TryAddWithoutValidation('Authorization', "Bearer $tok")
            @{ Task = $client.SendAsync($rq); Start = [System.Diagnostics.Stopwatch]::GetTimestamp() }
        }
        for ($i = 0; $i -lt $lvl; $i++) { $inflight.Add((& $startOne)) }
        while ($inflight.Count -gt 0) {
            $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($inflight | ForEach-Object { $_.Task }), 250)
            foreach ($f in @($inflight | Where-Object { $_.Task.IsCompleted })) {
                [void]$inflight.Remove($f)
                $code = 0
                if ($f.Task.Status -eq 'RanToCompletion') {
                    $resp = $f.Task.Result; $code = [int]$resp.StatusCode
                    if ($code -eq 429 -and $resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $retryAfters.Add($resp.Headers.RetryAfter.Delta.TotalSeconds) }
                    $resp.Dispose()
                }
                $lat.Add([System.Diagnostics.Stopwatch]::GetElapsedTime($f.Start).TotalMilliseconds)
                $codes["$code"] = 1 + $(if ($codes.ContainsKey("$code")) { $codes["$code"] } else { 0 })
                $n++; $sTot++
                if ($code -eq 429) { $n429++; $s429++; if (-not $first429) { $first429 = @{ concurrency = $lvl; afterRequests = $n; atSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) } } }
                if ([DateTime]::UtcNow -lt $levelEnd -and -not $stop) { $inflight.Add((& $startOne)) }
            }
            if (([DateTime]::UtcNow - $sliceStart).TotalSeconds -ge 2) {
                if ($sTot -ge 5 -and ($s429 / $sTot) -ge 0.5) { $bad++ } else { $bad = 0 }
                if ($bad -ge 2) { $stop = "sustained 429 window at concurrency $lvl" }
                $sliceStart = [DateTime]::UtcNow; $sTot = 0; $s429 = 0
            }
            if ($n -ge 5 -and @($codes.Keys | Where-Object { $_ -notin '200', '429' }).Count -gt 0 -and $codes.ContainsKey('200') -eq $false) { $stop = "endpoint not usable: $((($codes.Keys | Sort-Object) -join ','))" }
            if ([DateTime]::UtcNow -ge $deadline -and -not $stop) { $stop = 'time budget reached' }
        }
        $sw.Stop()
        $sorted = @($lat | Sort-Object)
        $p = { param($q) if ($sorted.Count -eq 0) { $null } else { [math]::Round($sorted[[math]::Min($sorted.Count - 1, [int][math]::Floor($q * $sorted.Count))], 0) } }
        $rps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($n / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
        $out += [ordered]@{ concurrency = $lvl; requests = $n; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); requestsPerSecond = $rps; statusCodes = $codes; throttled429 = $n429; p50ms = (& $p 0.5); p95ms = (& $p 0.95) }
        if ($n429 -eq 0 -and $rps -gt $bestClean) { $bestClean = $rps }
        Write-P0 ("concurrency {0}: {1} req in {2}s = {3} req/s, 429={4}" -f $lvl, $n, [math]::Round($sw.Elapsed.TotalSeconds, 1), $rps, $n429)
        if ($stop) { break }
    }
    Add-Obs 'target' @{ kind = $R7Target; url = $u }
    Add-Obs 'levels' $out
    Add-Obs 'first429' $first429
    Add-Obs 'retryAfterSeconds' @($retryAfters)
    Add-Obs 'stoppedBecause' $(if ($stop) { $stop } else { 'all levels completed' })
    Add-Obs 'bestRateWithoutAny429' $bestClean
    $ans = "Best rate with no 429: $bestClean req/s. First 429: $(if ($first429) { "at concurrency $($first429.concurrency) after $($first429.afterRequests) requests" } else { 'none' }). Retry-After: $(if ($retryAfters.Count) { ($retryAfters | Select-Object -Unique) -join ',' } else { 'n/a' }) s. Stop: $(if ($stop) { $stop } else { 'completed' })."
    Stop-Probe 'Pass' $ans
}
#endregion

#region write probes -----------------------------------------------------------------------------------------------------
$script:UserNames = @{}
function Get-UserDisplayName([string]$Id, [string]$Token) {
    if ($script:UserNames.ContainsKey($Id)) { return $script:UserNames[$Id] }
    $r = Invoke-P0Request -Method GET -Url "$G/users/$([uri]::EscapeDataString($Id))?`$select=id,displayName" -Token $Token -Label 'user-displayName'
    $n = if ($r.Ok -and (Get-V $r.Json 'displayName')) { [string](Get-V $r.Json 'displayName') } else { 'Phase0 Sender' }
    $script:UserNames[$Id] = $n
    $n
}
function Get-SenderId { if ($SenderUserId) { $SenderUserId } elseif ($TestChatMembers) { @($TestChatMembers)[0] } else { $null } }
function Get-Sender([string]$Token) {
    $id = Get-SenderId
    # from.user needs the object id: resolve a UPN through /users/{upn}
    $r = Invoke-P0Request -Method GET -Url "$G/users/$([uri]::EscapeDataString($id))?`$select=id,displayName" -Token $Token -Label 'sender-lookup'
    if ($r.Ok) { @{ id = [string](Get-V $r.Json 'id'); name = [string](Get-V $r.Json 'displayName') } } else { throw "Sender $id cannot be resolved: HTTP $($r.Status) $($r.ErrorCode)" }
}
function New-FromUser($Id, $Name, [string]$Type = 'aadUser') { @{ user = @{ id = $Id; displayName = $Name; userIdentityType = $Type } } }
function Resolve-WriteChat {
    param([string]$Token)
    if ($TestChatId) { return $TestChatId }
    if ($script:WriteChatId) { return $script:WriteChatId }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $members = @(@($TestChatMembers) | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "$G/users('$_')" } })
    $r = Invoke-P0Request -Method POST -Url "$G/chats" -Token $Token -Label 'create-chat' -Body @{ chatType = 'group'; topic = "TT-Lab Phase0 $stamp"; members = $members }
    Add-Step 'create group chat (app-only)' $r '201'
    if (-not $r.Ok) { throw "Chat creation failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
    $script:WriteChatId = [string](Get-V $r.Json 'id')
    $script:Created.Add(@{ type = 'chat'; id = $script:WriteChatId; topic = "TT-Lab Phase0 $stamp"; createdUtc = Get-IsoNow })
    $script:WriteChatId
}
function Start-ChatImport {
    # startMigration with conversationCreationDateTime = chat.createdDateTime - DaysBack. Returns @{ Start; Ok }.
    param([string]$ChatId, [string]$Token, [int]$DaysBack)
    $c = Invoke-P0Request -Method GET -Url "$G/chats/$([uri]::EscapeDataString($ChatId))" -Token $Token -Label 'get-chat'
    Add-Step 'GET chat (createdDateTime)' $c
    if (-not $c.Ok) { throw "GET chat failed: HTTP $($c.Status) $($c.ErrorCode)" }
    $created = ConvertTo-DateUtc (Get-V $c.Json 'createdDateTime')
    $convStart = $created.AddDays(-$DaysBack)
    $s = Invoke-P0Request -Method POST -Url "$G/chats/$([uri]::EscapeDataString($ChatId))/startMigration" -Token $Token -Label 'startMigration' -Body @{ conversationCreationDateTime = (Format-Dt $convStart) }
    Add-Step 'chat startMigration' $s '204'
    $m = Invoke-P0Request -Method GET -Url "$G/chats/$([uri]::EscapeDataString($ChatId))" -Token $Token -Label 'get-chat-mode'
    $mode = Get-V $m.Json 'migrationMode'
    Add-Step "GET chat migrationMode=$mode" $m 'inProgress'
    @{ Start = $convStart; Ok = $s.Ok; Mode = $mode; ChatCreated = $created; StartResult = $s }
}
function Complete-ChatImport {
    param([string]$ChatId, [string]$Token)
    $r = Invoke-P0Request -Method POST -Url "$G/chats/$([uri]::EscapeDataString($ChatId))/completeMigration" -Token $Token -Label 'completeMigration'
    Add-Step 'chat completeMigration' $r '204'
    $m = Invoke-P0Request -Method GET -Url "$G/chats/$([uri]::EscapeDataString($ChatId))" -Token $Token -Label 'get-chat-mode-final'
    $mode = Get-V $m.Json 'migrationMode'
    Add-Step "GET chat migrationMode=$mode" $m 'completed'
    @{ Ok = $r.Ok; Mode = $mode }
}
function Import-ChatMessage {
    param([string]$ChatId, [string]$Token, $Body, [string]$Label)
    Invoke-P0Request -Method POST -Url "$G/chats/$([uri]::EscapeDataString($ChatId))/messages" -Token $Token -Body $Body -Label $Label
}

function Invoke-ProbeW1 {
    Start-Probe 'W1' 'Chat import' 'Does the import API accept back-dated text/image/mention/reaction/file messages in a chat, enforce unique and non-future dates, at which rate, and can history visibility be restored?'
    $tok = Get-WriterToken
    $chatId = Resolve-WriteChat $tok
    Add-Obs 'chatId' $chatId
    $sender = Get-Sender $tok
    $ms = Start-ChatImport -ChatId $chatId -Token $tok -DaysBack 400
    Add-Obs 'migrationModeAfterStart' $ms.Mode
    Add-Obs 'conversationCreationDateTime' (Format-Dt $ms.Start)
    $core = [ordered]@{ start = $ms.Ok; modeInProgress = ($ms.Mode -eq 'inProgress') }
    $imported = [System.Collections.Generic.List[string]]::new()
    $from = New-FromUser $sender.id $sender.name
    $t0 = $ms.Start.AddDays(1)
    try {
        if ($ms.Ok) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            # 1 text
            $c1 = Format-Dt $t0.AddMilliseconds(123)
            $r1 = Import-ChatMessage $chatId $tok @{ createdDateTime = $c1; from = $from; body = @{ contentType = 'html'; content = '<p>Phase0 import - text message</p>' } } 'import-text'
            Add-Step 'import text' $r1 '200/201'; $core.text = $r1.Ok; if ($r1.Ok) { $imported.Add($c1) }
            # 2 inline image (1x1 PNG) through hostedContents + temporaryId
            $png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
            $c2 = Format-Dt $t0.AddSeconds(1).AddMilliseconds(223)
            $r2 = Import-ChatMessage $chatId $tok @{
                createdDateTime = $c2; from = $from
                body = @{ contentType = 'html'; content = '<div><span><img height="1" width="1" src="../hostedContents/1/$value"></span></div>' }
                hostedContents = @(@{ '@microsoft.graph.temporaryId' = '1'; contentBytes = $png; contentType = 'image/png' })
            } 'import-inline-image'
            Add-Step 'import inline image (hostedContents temporaryId)' $r2 '200/201'; if ($r2.Ok) { $imported.Add($c2) }
            # 3 mention
            $c3 = Format-Dt $t0.AddSeconds(2).AddMilliseconds(323)
            $r3 = Import-ChatMessage $chatId $tok @{
                createdDateTime = $c3; from = $from
                body = @{ contentType = 'html'; content = "<p>Hello <at id=`"0`">$($sender.name)</at></p>" }
                mentions = @(@{ id = 0; mentionText = $sender.name; mentioned = @{ user = @{ id = $sender.id; displayName = $sender.name; userIdentityType = 'aadUser' } } })
            } 'import-mention'
            Add-Step 'import mention' $r3 '200/201'; if ($r3.Ok) { $imported.Add($c3) }
            # 4 reactions
            $c4 = Format-Dt $t0.AddSeconds(3).AddMilliseconds(423)
            $r4 = Import-ChatMessage $chatId $tok @{
                createdDateTime = $c4; from = $from
                body = @{ contentType = 'html'; content = '<p>Phase0 import - message with reactions</p>' }
                reactions = @(@{ reactionType = 'like'; createdDateTime = (Format-Dt $t0.AddSeconds(4)); user = @{ user = @{ id = $sender.id; displayName = $sender.name; userIdentityType = 'aadUser' } } })
            } 'import-reaction'
            Add-Step 'import reactions' $r4 '200/201'; if ($r4.Ok) { $imported.Add($c4) }
            # 5 reference attachment to a file uploaded to the sender's OneDrive
            $fn = "TT-Lab-phase0-$stamp.txt"
            $up = Invoke-P0Request -Method PUT -Url ("$G/users/$([uri]::EscapeDataString($sender.id))/drive/root:/Microsoft%20Teams%20Chat%20Files/$fn" + ':/content') -Token $tok -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes("TeamsTransfer phase 0 test file $stamp")) -ContentType 'text/plain' -Label 'upload-onedrive-file'
            Add-Step "upload file to sender's OneDrive (Microsoft Teams Chat Files)" $up '200/201'
            Add-Obs 'oneDriveUpload' @{ status = $up.Status; errorCode = $up.ErrorCode }
            if ($up.Ok) {
                $script:Created.Add(@{ type = 'driveItem'; user = $sender.id; id = (Get-V $up.Json 'id'); name = $fn })
                $etag = [string](Get-V $up.Json 'eTag'); $gm = [regex]::Match($etag, '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}')
                $attId = if ($gm.Success) { $gm.Value } else { [guid]::NewGuid().ToString() }
                $c5 = Format-Dt $t0.AddSeconds(5).AddMilliseconds(523)
                $r5 = Import-ChatMessage $chatId $tok @{
                    createdDateTime = $c5; from = $from
                    body = @{ contentType = 'html'; content = "<p>Phase0 import - file</p><attachment id=`"$attId`"></attachment>" }
                    attachments = @(@{ id = $attId; contentType = 'reference'; contentUrl = [string](Get-V $up.Json 'webUrl'); name = $fn })
                } 'import-reference-attachment'
                Add-Step 'import reference attachment' $r5 '200/201'; if ($r5.Ok) { $imported.Add($c5) }
            }
            else { Add-Note "File upload failed (sender without OneDrive, or Files.ReadWrite.All not effective): the reference attachment case was skipped." }
            # duplicate createdDateTime (same ms as message 1) and future date
            $rd = Import-ChatMessage $chatId $tok @{ createdDateTime = $c1; from = $from; body = @{ contentType = 'html'; content = '<p>duplicate createdDateTime</p>' } } 'import-duplicate-date'
            Add-Step 'duplicate createdDateTime' $rd '400'
            $rf = Import-ChatMessage $chatId $tok @{ createdDateTime = (Format-Dt ([DateTime]::UtcNow.AddDays(1))); from = $from; body = @{ contentType = 'html'; content = '<p>future createdDateTime</p>' } } 'import-future-date'
            Add-Step 'future createdDateTime' $rf '400'
            Add-Obs 'duplicateDate' @{ status = $rd.Status; errorCode = $rd.ErrorCode; errorMessage = $rd.ErrorMessage; expected400 = ($rd.Status -eq 400) }
            Add-Obs 'futureDate' @{ status = $rf.Status; errorCode = $rf.ErrorCode; errorMessage = $rf.ErrorMessage; expected400 = ($rf.Status -eq 400) }
            # sustained rate on one thread
            $burstBase = $t0.AddDays(2); $okN = 0; $n429 = 0; $firstThrottleAt = $null; $swB = [System.Diagnostics.Stopwatch]::StartNew(); $lat = @()
            for ($k = 1; $k -le $ImportBurst; $k++) {
                $cb = Format-Dt $burstBase.AddSeconds($k).AddMilliseconds(7)
                $rb = Import-ChatMessage $chatId $tok @{ createdDateTime = $cb; from = $from; body = @{ contentType = 'html'; content = "<p>Phase0 burst $k</p>" } } 'import-burst'
                if ($rb.Ok) { $okN++; $imported.Add($cb) }
                $lat += $rb.ElapsedMs
                if ($rb.Retries429 -gt 0) { $n429 += $rb.Retries429; if (-not $firstThrottleAt) { $firstThrottleAt = $k } }
                if (-not $rb.Ok -and $rb.Status -ne 429) { Add-Step "burst message $k" $rb; break }
            }
            $swB.Stop()
            $rate = if ($swB.Elapsed.TotalSeconds -gt 0) { [math]::Round($okN / $swB.Elapsed.TotalSeconds, 2) } else { 0 }
            Add-Obs 'importRate' ([ordered]@{ messages = $okN; seconds = [math]::Round($swB.Elapsed.TotalSeconds, 1); messagesPerSecondEffective = $rate; throttled429 = $n429; firstThrottledAtMessage = $firstThrottleAt; documentedRps = '5 per channel (import page); 1 rps per chat on POST /chats/{id}/messages (throttling page)'; avgLatencyMs = $(if ($lat.Count) { [math]::Round(($lat | Measure-Object -Average).Average, 0) } else { 0 }) })
            Add-Note "Import rate on one chat thread: $rate msg/s effective ($n429 x 429)."
        }
    }
    finally {
        if ($ms.Ok) {
            $cm = Complete-ChatImport -ChatId $chatId -Token $tok
            $core.complete = $cm.Ok; $core.modeCompleted = ($cm.Mode -eq 'completed')
            Add-Obs 'migrationModeAfterComplete' $cm.Mode
        }
    }
    # verify
    $v = Invoke-P0Paged -Url "$G/chats/$([uri]::EscapeDataString($chatId))/messages?`$top=50" -Token $tok -Pages 5 -Label 'verify-messages' -Project { param($m) ConvertTo-MsgSummary $m }
    Add-Step 'verify: list messages' $v.Last
    $found = @($v.Items | Where-Object { $_.created -in $imported }).Count
    Add-Obs 'verify' @{ importedAccepted = $imported.Count; foundInListFirstPages = $found; listedMessages = $v.Items.Count; note = 'createdDateTime echoed with ms precision; list limited to MaxPages-less 5 pages of 50' }
    # visibleHistoryStartDateTime
    if ($SkipVisibleHistory) { Add-Note 'visibleHistoryStartDateTime step skipped (-SkipVisibleHistory).' }
    elseif ($ms.Ok) {
        $mr = Invoke-P0Request -Method GET -Url "$G/chats/$([uri]::EscapeDataString($chatId))/members" -Token $tok -Label 'list-members'
        Add-Step 'list chat members' $mr
        $members = @(Get-ValueList $mr.Json)
        $victim = @($members | Where-Object { (Get-V $_ 'userId') -and (Get-V $_ 'userId') -ne $sender.id } | Select-Object -Last 1)
        if ($members.Count -lt 3 -or $victim.Count -eq 0) { Add-Note 'Fewer than 3 members: visibleHistoryStartDateTime test skipped (needs a group chat with 3+ members).' }
        else {
            $mem = $victim[0]; $uid = [string](Get-V $mem 'userId')
            $dr = Invoke-P0Request -Method DELETE -Url "$G/chats/$([uri]::EscapeDataString($chatId))/members/$([uri]::EscapeDataString([string](Get-V $mem 'id')))" -Token $tok -Label 'remove-member'
            Add-Step 'remove one member' $dr '204'
            $ar = Invoke-P0Request -Method POST -Url "$G/chats/$([uri]::EscapeDataString($chatId))/members" -Token $tok -Label 're-add-member' -Body @{
                '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "$G/users('$uid')"
                visibleHistoryStartDateTime = (Format-Dt $ms.Start)
            }
            Add-Step 're-add member with older visibleHistoryStartDateTime' $ar '201'
            $back = Invoke-P0Request -Method GET -Url "$G/chats/$([uri]::EscapeDataString($chatId))/members" -Token $tok -Label 'list-members-after'
            $mine = @(Get-ValueList $back.Json | Where-Object { (Get-V $_ 'userId') -eq $uid })
            Add-Obs 'visibleHistory' ([ordered]@{ removeStatus = $dr.Status; addStatus = $ar.Status; addError = $ar.ErrorCode; requested = (Format-Dt $ms.Start); readBack = $(if ($mine.Count) { Format-Dt (Get-V $mine[0] 'visibleHistoryStartDateTime') } else { $null }); accepted = $ar.Ok })
        }
    }
    $coreOk = $core.start -and $core.modeInProgress -and (Get-V $core 'text') -and (Get-V $core 'complete') -and (Get-V $core 'modeCompleted')
    $dupOk = [bool](Get-V $script:Cur.Observations 'duplicateDate' 'expected400'); $futOk = [bool](Get-V $script:Cur.Observations 'futureDate' 'expected400')
    $ans = "start=$($core.start), mode after start=$($ms.Mode), imported=$($imported.Count) msgs, duplicate date -> HTTP $(Get-V $script:Cur.Observations 'duplicateDate' 'status'), future date -> HTTP $(Get-V $script:Cur.Observations 'futureDate' 'status'), rate=$(Get-V $script:Cur.Observations 'importRate' 'messagesPerSecondEffective') msg/s, final mode=$(Get-V $script:Cur.Observations 'migrationModeAfterComplete'), visibleHistory accepted=$(Get-V $script:Cur.Observations 'visibleHistory' 'accepted')."
    if (-not $coreOk) { Stop-Probe 'Fail' $ans } elseif (-not ($dupOk -and $futOk)) { Stop-Probe 'Inconclusive' ($ans + ' (duplicate/future date not both rejected with 400)') } else { Stop-Probe 'Pass' $ans }
}

function Invoke-ProbeW2 {
    Start-Probe 'W2' 'Departed / external author' 'Does the import accept from.user for a deleted, disabled or guest user (decides: keep original author vs service account)?'
    $cases = [ordered]@{}
    if ($DeletedUserId) { $cases['deleted'] = @{ id = $DeletedUserId; type = 'aadUser' } }
    if ($DisabledUserId) { $cases['disabled'] = @{ id = $DisabledUserId; type = 'aadUser' } }
    if ($GuestUserId) { $cases['guest'] = @{ id = $GuestUserId; type = 'aadUser' } }
    if ($cases.Count -eq 0) { Stop-Probe 'Inconclusive' 'Give at least one of -DeletedUserId, -DisabledUserId, -GuestUserId.'; return }
    $cases['neverExisted'] = @{ id = [guid]::NewGuid().ToString(); type = 'aadUser' }
    $tok = Get-WriterToken
    $chatId = Resolve-WriteChat $tok
    Add-Obs 'chatId' $chatId
    $ms = Start-ChatImport -ChatId $chatId -Token $tok -DaysBack 30
    $out = [ordered]@{}; $i = 0
    try {
        if ($ms.Ok) {
            foreach ($k in $cases.Keys) {
                $i++
                $c = Format-Dt $ms.Start.AddDays(1).AddSeconds($i).AddMilliseconds(11)
                $r = Import-ChatMessage $chatId $tok @{ createdDateTime = $c; from = (New-FromUser $cases[$k].id "Phase0 $k author" $cases[$k].type); body = @{ contentType = 'html'; content = "<p>Phase0 W2 author case: $k</p>" } } "import-author-$k"
                Add-Step "author = $k" $r
                $echo = if ($r.Ok) { @{ fromId = Get-V $r.Json 'from' 'user' 'id'; fromDisplayName = Get-V $r.Json 'from' 'user' 'displayName'; identityType = Get-V $r.Json 'from' 'user' 'userIdentityType' } } else { $null }
                $out[$k] = [ordered]@{ userId = $cases[$k].id; accepted = $r.Ok; status = $r.Status; errorCode = $r.ErrorCode; errorMessage = $r.ErrorMessage; requestId = $r.RequestId; echoedFrom = $echo }
            }
            # control: application as author (bot-like identity) - informational
        }
    }
    finally { if ($ms.Ok) { $cm = Complete-ChatImport -ChatId $chatId -Token $tok; Add-Obs 'migrationModeAfterComplete' $cm.Mode } }
    Add-Obs 'cases' $out
    if (-not $ms.Ok) { Stop-Probe 'Fail' 'startMigration failed, nothing tested.'; return }
    $acc = @($out.Keys | Where-Object { $out[$_].accepted }); $rej = @($out.Keys | Where-Object { -not $out[$_].accepted })
    Stop-Probe 'Pass' "Accepted: $(if ($acc) { $acc -join ', ' } else { 'none' }). Rejected: $(if ($rej) { ($rej | ForEach-Object { "$_ ($($out[$_].status) $($out[$_].errorCode))" }) -join '; ' } else { 'none' })."
}

function Invoke-ChannelImportCase {
    param([string]$TeamId, [string]$ChannelId, [string]$Kind, [string]$Token, $Sender)
    $t = [uri]::EscapeDataString($TeamId); $c = [uri]::EscapeDataString($ChannelId)
    $case = [ordered]@{ kind = $Kind; channelId = $ChannelId }
    $chanResp = Invoke-P0Request -Method GET -Url "$G/teams/$t/channels/$c" -Token $Token -Label "get-channel-$Kind"
    Add-Step "$Kind GET channel" $chanResp
    if (-not $chanResp.Ok) { $case.error = "GET channel HTTP $($chanResp.Status) $($chanResp.ErrorCode)"; return $case }
    $created = ConvertTo-DateUtc (Get-V $chanResp.Json 'createdDateTime')
    $convStart = $created.AddDays(-60)
    $s = Invoke-P0Request -Method POST -Url "$G/teams/$t/channels/$c/startMigration" -Token $Token -Label "startMigration-$Kind" -Body @{ conversationCreationDateTime = (Format-Dt $convStart) }
    Add-Step "$Kind channel startMigration" $s '204'
    $case.startStatus = $s.Status; $case.startError = $s.ErrorCode
    $mode = Get-V (Invoke-P0Request -Method GET -Url "$G/teams/$t/channels/$c" -Token $Token -Label "get-channel-mode-$Kind").Json 'migrationMode'
    $case.modeAfterStart = $mode
    $from = New-FromUser $Sender.id $Sender.name
    $rootId = $null
    try {
        if ($s.Ok) {
            $c1 = Format-Dt $convStart.AddDays(1).AddMilliseconds(101)
            $r = Invoke-P0Request -Method POST -Url "$G/teams/$t/channels/$c/messages" -Token $Token -Label "import-root-$Kind" -Body @{ createdDateTime = $c1; from = $from; body = @{ contentType = 'html'; content = '<p>Phase0 W3 root message</p>' } }
            Add-Step "$Kind import root message" $r '200/201'
            $case.rootStatus = $r.Status; $case.rootError = $r.ErrorCode
            if ($r.Ok) { $rootId = [string](Get-V $r.Json 'id') }
            $ok = 0
            if ($rootId) {
                foreach ($k in 1, 2) {
                    $cr = Format-Dt $convStart.AddDays(1).AddSeconds($k * 60).AddMilliseconds(202)
                    $rr = Invoke-P0Request -Method POST -Url "$G/teams/$t/channels/$c/messages/$([uri]::EscapeDataString($rootId))/replies" -Token $Token -Label "import-reply-$Kind" -Body @{ createdDateTime = $cr; from = $from; body = @{ contentType = 'html'; content = "<p>Phase0 W3 reply $k</p>" } }
                    Add-Step "$Kind import reply $k" $rr '200/201'
                    if ($rr.Ok) { $ok++ } else { $case.replyError = "$($rr.Status) $($rr.ErrorCode)" }
                }
            }
            $case.repliesImported = $ok
        }
    }
    finally {
        if ($s.Ok) {
            $cm = Invoke-P0Request -Method POST -Url "$G/teams/$t/channels/$c/completeMigration" -Token $Token -Label "completeMigration-$Kind"
            Add-Step "$Kind channel completeMigration" $cm '204'
            $case.completeStatus = $cm.Status; $case.completeError = $cm.ErrorCode
            $case.modeAfterComplete = Get-V (Invoke-P0Request -Method GET -Url "$G/teams/$t/channels/$c" -Token $Token -Label "get-channel-mode-final-$Kind").Json 'migrationMode'
        }
    }
    if ($rootId) {
        $vr = Invoke-P0Request -Method GET -Url "$G/teams/$t/channels/$c/messages/$([uri]::EscapeDataString($rootId))/replies?`$top=50" -Token $Token -Label "verify-replies-$Kind"
        $case.repliesVisible = if ($vr.Ok) { (Get-ValueList $vr.Json).Count } else { -1 }
    }
    $case.success = ($s.Ok -and $null -ne $rootId -and $case['repliesImported'] -eq 2 -and (Get-V $case 'completeStatus') -in 200, 204)
    $case
}
function Invoke-ProbeW3 {
    Start-Probe 'W3' 'Channel import' 'Does startMigration/import/replies/completeMigration work on an existing standard channel (and a private one)?'
    $tok = Get-WriterToken
    $sender = Get-Sender $tok
    $cases = @()
    $chan = $TestChannelId
    if (-not $chan) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $cr = Invoke-P0Request -Method POST -Url "$G/teams/$([uri]::EscapeDataString($TestTeamId))/channels" -Token $tok -Label 'create-channel' -Body @{ displayName = "TT-Lab Phase0 import $stamp"; membershipType = 'standard' }
        Add-Step 'create standard channel' $cr '201'
        if (-not $cr.Ok) { Stop-Probe 'Fail' "Cannot create the test channel: HTTP $($cr.Status) $($cr.ErrorCode). Pass -TestChannelId instead."; return }
        $chan = [string](Get-V $cr.Json 'id')
        $script:Created.Add(@{ type = 'channel'; teamId = $TestTeamId; id = $chan; createdUtc = Get-IsoNow })
    }
    $cases += , (Invoke-ChannelImportCase -TeamId $TestTeamId -ChannelId $chan -Kind 'standard' -Token $tok -Sender $sender)
    if ($TestPrivateChannelId) { $cases += , (Invoke-ChannelImportCase -TeamId $TestTeamId -ChannelId $TestPrivateChannelId -Kind 'private' -Token $tok -Sender $sender) }
    Add-Obs 'cases' $cases
    $okAll = @($cases | Where-Object { $_.success }).Count -eq $cases.Count
    $ans = ($cases | ForEach-Object { "$($_.kind): start HTTP $($_.startStatus), root HTTP $($_.rootStatus), replies $($_.repliesImported), complete HTTP $($_.completeStatus), mode $($_.modeAfterComplete)" }) -join ' | '
    if ($okAll) { Stop-Probe 'Pass' $ans } else { Stop-Probe 'Fail' $ans }
}

function Invoke-ProbeW4 {
    Start-Probe 'W4' 'Same-app ownership' 'What happens when another app tries to import into / complete a thread whose migration was started by the Writer app?'
    $tok = Get-WriterToken
    $other = Get-AppToken $OtherAppClientId
    $sender = Get-Sender $tok
    $chatId = Resolve-WriteChat $tok
    $otherHasRole = $null
    if (-not $DryRun) { $otherHasRole = ('Teamwork.Migrate.All' -in @(Get-V (ConvertFrom-JwtPayload $other) 'roles')) }
    Add-Obs 'otherAppHasTeamworkMigrateAll' $otherHasRole
    Add-Obs 'otherAppIsReader' ($OtherAppClientId -eq $ReaderClientId)
    $ms = Start-ChatImport -ChatId $chatId -Token $tok -DaysBack 20
    $imp = $null; $cmp = $null
    try {
        if ($ms.Ok) {
            $c = Format-Dt $ms.Start.AddDays(1).AddMilliseconds(55)
            $imp = Import-ChatMessage $chatId $other @{ createdDateTime = $c; from = (New-FromUser $sender.id $sender.name); body = @{ contentType = 'html'; content = '<p>Phase0 W4 other app import</p>' } } 'other-app-import'
            Add-Step 'OTHER app: import message' $imp 'error (not owner)'
            $cmp = Invoke-P0Request -Method POST -Url "$G/chats/$([uri]::EscapeDataString($chatId))/completeMigration" -Token $other -Label 'other-app-complete'
            Add-Step 'OTHER app: completeMigration' $cmp 'error (not owner)'
        }
    }
    finally { if ($ms.Ok) { [void](Complete-ChatImport -ChatId $chatId -Token $tok) } }
    if (-not $ms.Ok) { Stop-Probe 'Fail' 'startMigration by the Writer failed.'; return }
    Add-Obs 'otherImport' @{ status = $imp.Status; errorCode = $imp.ErrorCode; errorMessage = $imp.ErrorMessage; requestId = $imp.RequestId }
    Add-Obs 'otherComplete' @{ status = $cmp.Status; errorCode = $cmp.ErrorCode; errorMessage = $cmp.ErrorMessage; requestId = $cmp.RequestId }
    $ans = "Other app import: HTTP $($imp.Status) $($imp.ErrorCode); complete: HTTP $($cmp.Status) $($cmp.ErrorCode)."
    if ($OtherAppClientId -eq $WriterClientId) { Stop-Probe 'Inconclusive' ($ans + ' The "other" app is the Writer itself: pass -OtherAppClientId of a second app (Grant-LabConsent.ps1 -SecondWriter).') }
    elseif ($otherHasRole -eq $false) { Stop-Probe 'Inconclusive' ($ans + ' The other app lacks Teamwork.Migrate.All, so the error may be about permissions, not ownership: re-run with -OtherAppClientId of a second Writer app (Grant-LabConsent.ps1 -SecondWriter).') }
    elseif ($imp.Ok -or $cmp.Ok) { Stop-Probe 'Fail' ($ans + ' The other app was ACCEPTED: the same-app rule documented by Microsoft is not enforced.') }
    else { Stop-Probe 'Pass' ($ans + ' Ownership is enforced (error recorded).') }
}
#endregion

#region report -----------------------------------------------------------------------------------------------------------
function Write-Report {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# TeamsTransfer - Phase 0 report')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Generated (UTC): $((Get-Date).ToUniversalTime().ToString('o'))")
    [void]$sb.AppendLine("- Mode: $(if ($DryRun) { 'DRY RUN (nothing sent)' } else { 'real run' }) - cloud: $Cloud - tenant: $TenantId")
    [void]$sb.AppendLine("- Host: PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)")
    [void]$sb.AppendLine("- Probes: $($Selected -join ', ') - writes allowed: $([bool]$AllowWrite) - content kept in evidence: $([bool]$IncludeContent) (otherwise bodies/subjects are redacted)")
    [void]$sb.AppendLine("- Window (lastModifiedDateTime): $(Format-Dt $From) to $(Format-Dt $To); MaxPages=$MaxPages")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Probe | Name | Status | Answer |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($k in $script:Results.Keys) {
        $r = $script:Results[$k]
        [void]$sb.AppendLine("| $k | $($r.Name) | **$($r.Status)** | $(([string]$r.Answer).Replace('|', '/').Replace("`n", ' ')) |")
    }
    foreach ($k in $script:Results.Keys) {
        $r = $script:Results[$k]
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("## $k - $($r.Name)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Question: $($r.Question)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Status: **$($r.Status)** ($($r.DurationMs) ms)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Answer: $($r.Answer)")
        if ($r.Notes.Count -gt 0) { [void]$sb.AppendLine(''); foreach ($n in $r.Notes) { [void]$sb.AppendLine("- Note: $n") } }
        if ($r.Steps.Count -gt 0) {
            [void]$sb.AppendLine(''); [void]$sb.AppendLine('| Step | HTTP | Error code | ms | Expected | Request id |'); [void]$sb.AppendLine('|---|---|---|---|---|---|')
            foreach ($s in $r.Steps) { [void]$sb.AppendLine("| $(([string]$s.step).Replace('|', '/')) | $($s.status) | $($s.errorCode) | $($s.ms) | $($s.expect) | $($s.requestId) |") }
        }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('<details><summary>Observations (JSON)</summary>'); [void]$sb.AppendLine(''); [void]$sb.AppendLine('```json')
        [void]$sb.AppendLine((ConvertTo-RedactedJson $r.Observations)); [void]$sb.AppendLine('```'); [void]$sb.AppendLine(''); [void]$sb.AppendLine('</details>')
        [void]$sb.AppendLine(''); [void]$sb.AppendLine("Requests: $($r.Requests.Count) (details in $k.json and Timings.csv)")
    }
    if ($script:Created.Count -gt 0) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Objects created by the write probes (clean up manually)'); [void]$sb.AppendLine('')
        foreach ($c in $script:Created) { [void]$sb.AppendLine("- $(($c.Keys | ForEach-Object { "$_=$($c[$_])" }) -join ', ')") }
    }
    Set-Content -LiteralPath (Join-Path $script:OutDir 'Phase0-Report.md') -Value $sb.ToString() -Encoding utf8
}
#endregion

#region main -------------------------------------------------------------------------------------------------------------
$stampDir = (Get-Date).ToString('yyyyMMdd-HHmmss') + $(if ($DryRun) { '-dryrun' } else { '' })
$script:OutDir = Join-Path $OutputRoot $stampDir
New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
Write-Host "Evidence folder: $script:OutDir" -ForegroundColor DarkGray
if ($DryRun) { Write-Host 'DRY RUN: no network access, no sign-in; requests are only printed.' -ForegroundColor Cyan }

# write-probe guard rails (before anything is sent)
if ($WriteSelected.Count -gt 0) {
    if (-not $AllowWrite) { throw "Write probes ($($WriteSelected -join ', ')) need -AllowWrite and explicit lab objects." }
    $needs = @()
    $haveChat = [bool]$TestChatId -or (@($TestChatMembers).Count -ge 2)
    $willCreateChat = ($WriteSelected -contains 'W1') -and -not $TestChatId
    if (($WriteSelected | Where-Object { $_ -in 'W1', 'W2', 'W4' }) -and -not $haveChat) { $needs += 'a chat: -TestChatId or -TestChatMembers (2+ user ids)' }
    if (($WriteSelected | Where-Object { $_ -in 'W1', 'W2', 'W3', 'W4' }) -and -not (Get-SenderId)) { $needs += 'a sender: -SenderUserId or -TestChatMembers' }
    if (($WriteSelected -contains 'W3') -and -not $TestTeamId) { $needs += '-TestTeamId' }
    if (($WriteSelected -contains 'W2') -and -not ($DeletedUserId -or $DisabledUserId -or $GuestUserId)) { $needs += 'one of -DeletedUserId / -DisabledUserId / -GuestUserId' }
    if ($needs.Count -gt 0) { throw "Write probes refused, missing: $($needs -join '; ')" }
    Write-Host ''
    Write-Host 'WRITE PROBES SELECTED' -ForegroundColor Yellow
    Write-Host "  Probes: $($WriteSelected -join ', ')"
    Write-Host "  Chat: $(if ($TestChatId) { "existing $TestChatId (an import session WILL be started on it)" } else { "a new group chat will be CREATED with members: $(@($TestChatMembers) -join ', ')" })"
    if ($WriteSelected -contains 'W3') { Write-Host "  Team: $TestTeamId - channel: $(if ($TestChannelId) { $TestChannelId } else { 'a new standard channel will be created' })$(if ($TestPrivateChannelId) { " + private channel $TestPrivateChannelId" })" }
    if ($WriteSelected -contains 'W1') { Write-Host "  W1 also uploads a file to the OneDrive of $(Get-SenderId) and removes/re-adds one chat member$(if ($SkipVisibleHistory) { ' (skipped)' })." }
    Write-Host '  Imports cannot be rolled back (delete and recreate is the only fix).'
    if (-not $DryRun -and -not (Confirm-LabAction -Cmdlet $script:ToolCmdlet -Query "Run the write probes ($($WriteSelected -join ', ')) against tenant $TenantId? Imports cannot be rolled back." -Caption 'Invoke-Phase0 - write probes' -Force:$Force)) { throw 'Cancelled by the operator.' }
}

$script:Cert = $null
if (-not $DryRun) {
    if (-not $CertificateThumbprint) { throw 'CertificateThumbprint missing (parameter or lab-apps.json).' }
    $script:Cert = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $script:Cert -or -not $script:Cert.HasPrivateKey) { throw "Certificate $CertificateThumbprint with a private key not found in Cert:\CurrentUser\My." }
}
elseif (-not $TenantId) { $TenantId = '{tenant-id}'; $ReaderClientId = $(if ($ReaderClientId) { $ReaderClientId } else { '{reader-app-id}' }); $WriterClientId = $(if ($WriterClientId) { $WriterClientId } else { '{writer-app-id}' }); if (-not $OtherAppClientId) { $OtherAppClientId = $ReaderClientId } }
else {
    if (-not $ReaderClientId) { $ReaderClientId = '{reader-app-id}' }
    if (-not $WriterClientId) { $WriterClientId = '{writer-app-id}' }
    if (-not $OtherAppClientId) { $OtherAppClientId = $ReaderClientId }
}

foreach ($id in 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'W1', 'W2', 'W3', 'W4') {
    if ($Selected -notcontains $id) { continue }
    try { & "Invoke-Probe$id" }
    catch {
        if (-not $script:Cur -or $script:Cur.Id -ne $id) { Start-Probe $id "Probe $id" 'n/a' }
        $script:Cur.Notes.Add("Unhandled error: $($_.Exception.Message)")
        Stop-Probe 'Fail' "Unhandled error: $($_.Exception.Message)"
    }
}

$script:Timings | Export-Csv -LiteralPath (Join-Path $script:OutDir 'Timings.csv') -NoTypeInformation -Encoding utf8
if ($script:Created.Count -gt 0) { $script:Created | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:OutDir 'created-objects.json') -Encoding utf8 }
if ($DryRun) { $script:Plan | Set-Content -LiteralPath (Join-Path $script:OutDir 'DryRun-Plan.txt') -Encoding utf8 }
@{ generatedUtc = (Get-Date).ToUniversalTime().ToString('o'); dryRun = [bool]$DryRun; cloud = $Cloud; tenantId = $TenantId; probes = $Selected; powershell = "$($PSVersionTable.PSVersion)"; includeContent = [bool]$IncludeContent } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:OutDir 'run-info.json') -Encoding utf8
Write-Report
Write-Host ''
Write-Host "Report: $(Join-Path $script:OutDir 'Phase0-Report.md')" -ForegroundColor Green
$script:Results.Values | ForEach-Object { [pscustomobject]@{ Probe = $_.Id; Status = $_.Status; Answer = $_.Answer } } | Format-Table -AutoSize -Wrap
#endregion
