#Requires -Version 7.4
<#
.SYNOPSIS
    Lab only (WRITE): seeds the lab tenant with French test conversations imported with the Writer app (Teams import API).

.DESCRIPTION
    Creates, with the Writer app (app-only, certificate) and the migration (import) API:
      - one group chat "TT-Lab Equipe Atlas - discussion" between the -Members;
      - one 1:1 chat between Members[0] and each other member (at most 2);
      - a team "TT-Lab Projet Atlas" (-TeamName) with a standard channel "TT-Lab Planning" and a private channel
        "TT-Lab Direction". The team is created app-only when Team.Create allows it, otherwise (or with
        -TeamCreator Delegated) by the administrator through Connect-MgGraph (the existing Get-MgContext is reused, else
        Connect-MgGraph -TenantId -NoWelcome with the cached administrator; no forced interactive flow);
      - back-dated French messages spread over -Months months (startMigration, import, completeMigration):
        text, @mentions, reactions, an inline image (hostedContents), a file uploaded to the sender's OneDrive (chats) or to the
        team's channel folder (channel) and referenced as a "reference" attachment, and channel replies.

    SHARED TENANT SAFETY: every object created carries the prefix "TT-Lab" in its display name (apps excepted: they come from
    Grant-LabConsent.ps1; 1:1 chats and files in OneDrive cannot be renamed: files are named TT-Lab-*.txt and 1:1 chats are
    listed in labdata.json). Only the explicit -Members are used. A 1:1 chat that ALREADY exists between two members (real
    conversation) is never imported into (unless -AllowExistingChats) and is never deleted by Remove-Phase0LabData.ps1.

    IDEMPOTENT: tools\phase0-output\labdata.json records every created id and every imported message key. A re-run creates
    nothing twice and only imports the missing messages (a conversation already complete is skipped). Delete that file only
    after Remove-Phase0LabData.ps1.

    -AllowWrite is mandatory. -DryRun prints every request (bodies redacted) without any network access or sign-in.
    Imported conversations cannot be rolled back except by deletion (Remove-Phase0LabData.ps1 -WhatIf first).

.PARAMETER TenantId
    Lab tenant id. Default: lab-apps.json.

.PARAMETER WriterClientId
    Application id of the Writer app. Default: lab-apps.json.

.PARAMETER CertificateThumbprint
    Certificate in Cert:\CurrentUser\My. Default: lab-apps.json.

.PARAMETER ConfigPath
    lab-apps.json (default tools\phase0-output\lab-apps.json).

.PARAMETER Cloud
    Global (default), USGov, USGovDoD, China.

.PARAMETER Members
    UPNs of the lab users (at least 3 for the group chat and the private channel). The first one is the main owner.

.PARAMETER AllowWrite
    Required.

.PARAMETER Force
    No confirmation prompt.

.PARAMETER DryRun
    Print the requests, send nothing.

.PARAMETER TeamName
    Must start with "TT-Lab". Default "TT-Lab Projet Atlas".

.PARAMETER Months
    Messages are dated over the last N months (default 4).

.PARAMETER TeamCreator
    Auto (default: app-only first, delegated fallback), App or Delegated.

.PARAMETER Scopes
    Optional scopes for Connect-MgGraph when no Microsoft Graph context exists (Delegated team creation).

.PARAMETER SkipChats
    Do not create/import chats.

.PARAMETER SkipTeam
    Do not create/import the team and channels.

.PARAMETER AllowExistingChats
    Also import into a 1:1 chat that already existed (NOT recommended in a shared tenant).

.PARAMETER DelayMs
    Pause between two imported messages (default 400 ms).

.PARAMETER StatePath
    labdata.json location (default tools\phase0-output\labdata.json).

.EXAMPLE
    .\tools\New-Phase0LabData.ps1 -DryRun -AllowWrite -Members a@lab.onmicrosoft.com,b@lab.onmicrosoft.com,c@lab.onmicrosoft.com

.EXAMPLE
    .\tools\New-Phase0LabData.ps1 -AllowWrite -Members a@lab.onmicrosoft.com,b@lab.onmicrosoft.com,c@lab.onmicrosoft.com

.NOTES
    Author  : Nicolas Fabert
    Version : 0.1.0 (phase 0). -WhatIf is the same as -DryRun (no network access, nothing sent). Request shapes come from the Microsoft documentation of 2026-11-09; nothing was run against a
    real tenant by the author.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$WriterClientId,
    [string]$CertificateThumbprint,
    [string]$ConfigPath,
    [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
    [Parameter(Mandatory)][ValidateCount(3, 10)][string[]]$Members,
    [switch]$AllowWrite,
    [switch]$Force,
    [switch]$DryRun,
    [string]$TeamName = 'TT-Lab Projet Atlas',
    [ValidateRange(1, 24)][int]$Months = 4,
    [ValidateSet('Auto', 'App', 'Delegated')][string]$TeamCreator = 'Auto',
    [string[]]$Scopes,
    [switch]$SkipChats,
    [switch]$SkipTeam,
    [switch]$AllowExistingChats,
    [ValidateRange(0, 5000)][int]$DelayMs = 400,
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# -WhatIf is -DryRun: the requests are printed, nothing is sent.
if ($WhatIfPreference) { $DryRun = [switch]$true }
$WhatIfPreference = $false
. (Join-Path $PSScriptRoot 'Phase0.LabCommon.ps1')

if (-not $AllowWrite) { throw 'New-Phase0LabData.ps1 writes to the tenant: -AllowWrite is required.' }
if ($TeamName -notlike 'TT-Lab*') { throw "-TeamName must start with 'TT-Lab' (shared tenant)." }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'phase0-output\lab-apps.json' }
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot 'phase0-output\labdata.json' }
$cfg = Read-LabConfig $ConfigPath
if (-not $TenantId -and $cfg.ContainsKey('tenantId')) { $TenantId = $cfg['tenantId'] }
if (-not $CertificateThumbprint -and $cfg.ContainsKey('certificateThumbprint')) { $CertificateThumbprint = $cfg['certificateThumbprint'] }
if (-not $WriterClientId -and $cfg.ContainsKey('writer')) { $WriterClientId = $cfg['writer']['appId'] }
if ($DryRun) { if (-not $TenantId) { $TenantId = '{tenant-id}' }; if (-not $WriterClientId) { $WriterClientId = '{writer-app-id}' } }
elseif (-not ($TenantId -and $WriterClientId -and $CertificateThumbprint)) { throw 'TenantId, WriterClientId and CertificateThumbprint are needed (run Grant-LabConsent.ps1 first, or pass them).' }

Initialize-LabAuth -TenantId $TenantId -Cloud $Cloud -Thumbprint $CertificateThumbprint -DryRun:$DryRun
$G = $script:Lab.G
$State = Read-LabState $StatePath
if ($DryRun) { $StatePath = Join-Path ([IO.Path]::GetTempPath()) 'labdata-dryrun.json'; $State = Read-LabState $StatePath }
$State['tenantId'] = $TenantId
if (-not $State.ContainsKey('baseDate')) { $State['baseDate'] = (Get-Date).ToUniversalTime().Date.AddMonths(-$Months).ToString('o') }
$Base = ConvertTo-LabDateUtc $State['baseDate']
$Span = $Months * 30 - 3
function Save { if (-not $DryRun) { Save-LabState $State $StatePath } }

Write-Host ''
Write-Host 'LAB DATA SEEDING (WRITE)' -ForegroundColor Yellow
Write-Host "  Tenant: $TenantId ($Cloud) - members: $($Members -join ', ')"
Write-Host "  Creates: $(if (-not $SkipChats) { 'group chat + 1:1 chats; ' })$(if (-not $SkipTeam) { "team '$TeamName' with a standard and a private channel; " })French messages imported over $Months months; files named TT-Lab-*.txt"
Write-Host "  State: $StatePath"
if (-not $DryRun -and -not (Confirm-LabAction -Cmdlet $PSCmdlet -Query "Create lab data in tenant $TenantId? Imports cannot be rolled back." -Caption 'New-Phase0LabData' -Force:$Force)) { throw 'Cancelled by the operator.' }

$tok = Get-LabToken $WriterClientId

# --- members --------------------------------------------------------------------------------------------------------------
$U = @()
foreach ($upn in $Members) {
    $r = Invoke-LabGraph -Path "/users/$([uri]::EscapeDataString($upn))?`$select=id,displayName,userPrincipalName" -Token $tok
    if (-not $r.Ok) { throw "Member $upn not found: HTTP $($r.Status) $($r.ErrorCode)" }
    $m = @{ upn = $upn; id = [string]$r.Json['id']; name = [string]$r.Json['displayName'] }
    $State['members'][$upn] = $m
    $U += , $m
}
Save

# --- message catalogue (French) ----------------------------------------------------------------------------------------
function New-Msg { param([string]$Key, [int]$A, [string]$Html, $Mention = $null, $React = @(), [switch]$Image, [string]$File = '', [string]$Reply = '')
    @{ key = $Key; a = $A; html = $Html; mention = $Mention; react = $React; image = [bool]$Image; file = $File; reply = $Reply } }
function New-React([string]$T, [int]$By) { @{ t = $T; by = $By } }

$GroupMsgs = @(
    (New-Msg 'g1.01' 0 'Hello everyone, this is the discussion channel for the Atlas project. The launch is planned this week.')
    (New-Msg 'g1.02' 1 'Thanks {@}, I am preparing the detailed schedule and will share it tomorrow.' -Mention 0)
    (New-Msg 'g1.03' 2 'Received. I will handle the validation on the finance side.' -React @(New-React 'like' 0))
    (New-Msg 'g1.04' 0 'Here is the mock-up approved in this morning''s meeting.' -Image)
    (New-Msg 'g1.05' 1 'Great, it is very clear!' -React @(New-React 'heart' 2))
    (New-Msg 'g1.06' 2 'The meeting minutes are available here.' -File 'chat-compte-rendu')
    (New-Msg 'g1.07' 0 'Can you review the document before Friday? {@}' -Mention 1)
    (New-Msg 'g1.08' 1 'Done, I added a few remarks as comments.')
    (New-Msg 'g1.09' 2 'Progress review on Thursday at 10:00, Seine room. Please confirm your attendance.' -React @((New-React 'like' 0), (New-React 'like' 1)))
    (New-Msg 'g1.10' 0 'Confirmed on my side.')
    (New-Msg 'g1.11' 1 'I will join by video, sorry for the inconvenience.')
    (New-Msg 'g1.12' 2 'The budget is approved. We can move on to the next phase.')
)
function Get-OneToOneMsgs([string]$P) {
    # authors alternate between the two members of the pair: a=0 is Members[0], a=1 is the other member
    @(
        (New-Msg "$P.01" 0 'Hi, do you have five minutes to talk about the Atlas file?')
        (New-Msg "$P.02" 1 'Yes, I will call you in a moment.')
        (New-Msg "$P.03" 1 'I updated the tracking sheet, have a look when you can.' -React @(New-React 'like' 0))
        (New-Msg "$P.04" 0 'Thanks, that is perfect. I will add it to the weekly report.')
        (New-Msg "$P.05" 0 'Do not forget tomorrow''s meeting at 9:00.')
        (New-Msg "$P.06" 1 'Noted, see you tomorrow!')
    )
}
$PlanningMsgs = @(
    (New-Msg 'c1.r1' 0 'Opening the Planning channel: objectives, milestones and responsibilities for the Atlas project.' -React @(New-React 'like' 1))
    (New-Msg 'c1.r1.a' 1 'The milestones are in the attached file.' -File 'canal-jalons' -Reply 'c1.r1')
    (New-Msg 'c1.r1.b' 2 'I confirm milestone 2 for the end of the month.' -Reply 'c1.r1')
    (New-Msg 'c1.r2' 1 'First sprint retrospective: {@}, can you present the results?' -Mention 2 -Image)
    (New-Msg 'c1.r2.a' 2 'Yes, I am preparing a short presentation.' -Reply 'c1.r2')
    (New-Msg 'c1.r2.b' 0 'Thanks. We will go through it at Thursday''s review.' -Reply 'c1.r2')
    (New-Msg 'c1.r3' 2 'Identified risks: late supplier deliveries and team availability in August.' -React @((New-React 'like' 0), (New-React 'heart' 1)))
    (New-Msg 'c1.r3.a' 0 'I suggest a fallback plan, I will detail it tomorrow.' -Reply 'c1.r3')
)
$DirectionMsgs = @(
    (New-Msg 'c2.r1' 0 'Confidential topic: budget trade-offs for the Atlas project.')
    (New-Msg 'c2.r1.a' 1 'Agreed, I am preparing the figures.' -Reply 'c2.r1')
    (New-Msg 'c2.r2' 1 'Consolidated figures sent to management.' -React @(New-React 'like' 0))
    (New-Msg 'c2.r2.a' 0 'Thanks, we will approve on Monday.' -Reply 'c2.r2')
)

function Get-MsgDate($Msgs, $M) {
    $roots = @($Msgs | Where-Object { -not $_.reply })
    if ($M.reply) {
        $root = $Msgs | Where-Object { $_.key -eq $M.reply } | Select-Object -First 1
        $rootDate = Get-MsgDate $Msgs $root
        $k = @($Msgs | Where-Object { $_.reply -eq $M.reply }).IndexOf($M)
        return $rootDate.AddMinutes(47 * ($k + 1)).AddMilliseconds(5 + $k)
    }
    $ord = $roots.IndexOf($M)
    $Base.AddDays([math]::Floor($ord * $Span / $roots.Count)).AddMinutes(510 + (($ord * 37) % 480)).AddMilliseconds(100 + $ord)
}

# --- files ---------------------------------------------------------------------------------------------------------------
$FileText = @{
    'chat-compte-rendu' = "Minutes of the Atlas project kick-off meeting (TT-Lab test document).`nDecisions: schedule approved, budget pending approval."
    'canal-jalons'      = "Atlas project milestones (TT-Lab test document).`nM1: scoping. M2: prototype. M3: go-live."
}
function Ensure-LabFile {
    param([string]$Key, [string]$Place, [int]$OwnerIdx = 0)
    if ($State['files'].ContainsKey($Key)) { return $State['files'][$Key] }
    $name = "TT-Lab-$Key.txt"
    $bytes = [Text.Encoding]::UTF8.GetBytes($FileText[$Key])
    if ($Place -eq 'user') { $path = "/users/$([uri]::EscapeDataString($U[$OwnerIdx].id))/drive/root:/Microsoft%20Teams%20Chat%20Files/${name}:/content" }
    else { $path = "/groups/$([uri]::EscapeDataString($State['team']['id']))/drive/root:/$([uri]::EscapeDataString('TT-Lab Planning'))/${name}:/content" }
    $r = Invoke-LabGraph -Method PUT -Path $path -BodyBytes $bytes -ContentType 'text/plain' -Token $tok
    if (-not $r.Ok) { throw "Upload of $name failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
    $etag = [string]$r.Json['eTag']; $gm = [regex]::Match($etag, '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}')
    $f = @{ name = $name; itemId = [string]$r.Json['id']; webUrl = [string]$r.Json['webUrl']; attId = $(if ($gm.Success) { $gm.Value } else { [guid]::NewGuid().ToString() }); place = $Place; ownerUserId = $(if ($Place -eq 'user') { $U[$OwnerIdx].id } else { $null }); groupId = $(if ($Place -eq 'group') { $State['team']['id'] } else { $null }) }
    $State['files'][$Key] = $f; Save
    $f
}

# --- import of one conversation -------------------------------------------------------------------------------------------
$PngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
function New-MsgBody {
    param($Msgs, $M, [string]$FilePlace)
    $ai = if ($M.ContainsKey('_pair')) { $M._pair[$M.a] } else { $M.a % $U.Count }
    $a = $U[$ai]
    $html = [string]$M.html
    $body = @{ createdDateTime = (Format-LabDt (Get-MsgDate $Msgs $M)); from = @{ user = @{ id = $a.id; displayName = $a.name; userIdentityType = 'aadUser' } } }
    if ($null -ne $M.mention) {
        $t = $U[[int]$M.mention]
        $html = $html.Replace('{@}', "<at id=`"0`">$($t.name)</at>")
        $body.mentions = @(@{ id = 0; mentionText = $t.name; mentioned = @{ user = @{ id = $t.id; displayName = $t.name; userIdentityType = 'aadUser' } } })
    }
    $html = "<p>$html</p>"
    if ($M.image) {
        $html += '<p><img height="1" width="1" src="../hostedContents/1/$value"></p>'
        $body.hostedContents = @(@{ '@microsoft.graph.temporaryId' = '1'; contentBytes = $PngBase64; contentType = 'image/png' })
    }
    if ($M.file) {
        $f = Ensure-LabFile -Key $M.file -Place $FilePlace -OwnerIdx $ai
        $html += "<attachment id=`"$($f.attId)`"></attachment>"
        $body.attachments = @(@{ id = $f.attId; contentType = 'reference'; contentUrl = $f.webUrl; name = $f.name })
    }
    if (@($M.react).Count -gt 0) {
        $d = Get-MsgDate $Msgs $M; $i = 0
        $body.reactions = @(foreach ($rc in $M.react) { $i++; $ru = $U[[int]$rc.by]; @{ reactionType = $rc.t; createdDateTime = (Format-LabDt $d.AddMinutes(3 * $i)); user = @{ user = @{ id = $ru.id; displayName = $ru.name; userIdentityType = 'aadUser' } } } })
    }
    $body.body = @{ contentType = 'html'; content = $html }
    $body
}
function Import-Conversation {
    param([string]$Label, [string]$ConvPath, $Msgs, [string]$FilePlace)
    $pending = @($Msgs | Where-Object { -not $State['messages'].ContainsKey($_.key) })
    if ($pending.Count -eq 0) { Write-Host "  [$Label] already fully imported - skipped" -ForegroundColor DarkGray; return }
    Write-Host "  [$Label] importing $($pending.Count) message(s)..." -ForegroundColor Cyan
    $c = Invoke-LabGraph -Path $ConvPath -Token $tok
    if (-not $c.Ok) { throw "[$Label] GET conversation failed: HTTP $($c.Status) $($c.ErrorCode)" }
    $created = ConvertTo-LabDateUtc $c.Json['createdDateTime']
    if ([string]$c.Json['migrationMode'] -ne 'inProgress') {
        $first = ($pending | ForEach-Object { Get-MsgDate $Msgs $_ } | Sort-Object | Select-Object -First 1).AddDays(-1)
        $start = if ($first -lt $created) { $first } else { $created.AddSeconds(-1) }
        $s = Invoke-LabGraph -Method POST -Path "$ConvPath/startMigration" -Body @{ conversationCreationDateTime = (Format-LabDt $start) } -Token $tok
        if (-not $s.Ok) { throw "[$Label] startMigration failed: HTTP $($s.Status) $($s.ErrorCode) $($s.ErrorMessage)" }
    }
    try {
        foreach ($m in @($pending | Sort-Object { Get-MsgDate $Msgs $_ })) {
            $body = New-MsgBody -Msgs $Msgs -M $m -FilePlace $FilePlace
            $path = "$ConvPath/messages"
            if ($m.reply) {
                $rootId = Get-LabV $State['messages'] $m.reply 'id'
                if (-not $rootId) { throw "[$Label] root message $($m.reply) was not imported; cannot import its reply $($m.key)." }
                $path = "$ConvPath/messages/$([uri]::EscapeDataString([string]$rootId))/replies"
            }
            $r = Invoke-LabGraph -Method POST -Path $path -Body $body -Token $tok
            if (-not $r.Ok) { throw "[$Label] import of $($m.key) failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
            $State['messages'][$m.key] = @{ id = [string]$r.Json['id']; created = $body.createdDateTime }
            Save
            if ($DelayMs -gt 0 -and -not $DryRun) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    finally {
        $cm = Invoke-LabGraph -Method POST -Path "$ConvPath/completeMigration" -Token $tok
        if (-not $cm.Ok) { Write-Warning "[$Label] completeMigration failed: HTTP $($cm.Status) $($cm.ErrorCode). Run the script again to retry." }
        else { Write-Host "  [$Label] migration completed" -ForegroundColor Green }
    }
}

function New-MemberBinding([int]$Idx, [string]$Role) { @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @($Role); 'user@odata.bind' = "$G/users('$($U[$Idx].id)')" } }

# --- chats ------------------------------------------------------------------------------------------------------------------
if (-not $SkipChats) {
    Write-Host '== Chats ==' -ForegroundColor Cyan
    $chatDefs = @(@{ key = 'g1'; type = 'group'; idx = @(0..($U.Count - 1)); topic = 'TT-Lab Equipe Atlas - discussion'; msgs = $GroupMsgs })
    for ($j = 1; $j -le [math]::Min(2, $U.Count - 1); $j++) {
        $pairMsgs = @(Get-OneToOneMsgs "o$j" | ForEach-Object { $_._pair = @(0, $j); $_ })
        $chatDefs += @{ key = "o$j"; type = 'oneOnOne'; idx = @(0, $j); topic = $null; msgs = $pairMsgs }
    }
    foreach ($d in $chatDefs) {
        $rec = $State['chats'][$d.key]
        if (-not $rec) {
            $body = @{ chatType = $d.type; members = @($d.idx | ForEach-Object { New-MemberBinding $_ 'owner' }) }
            if ($d.topic) { $body.topic = $d.topic }
            $r = Invoke-LabGraph -Method POST -Path '/chats' -Body $body -Token $tok
            if (-not $r.Ok) { throw "Creation of chat $($d.key) failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
            $rec = @{ id = [string]$r.Json['id']; type = $d.type; topic = $d.topic; created = ($r.Status -ne 200); createdUtc = (Get-Date).ToUniversalTime().ToString('o') }
            $State['chats'][$d.key] = $rec; Save
            Write-Host "  chat $($d.key): $(if ($rec.created) { 'created' } else { 'ALREADY EXISTED (real conversation)' }) $($rec.id)" -ForegroundColor $(if ($rec.created) { 'Green' } else { 'Yellow' })
        }
        if (-not $rec.created -and -not $AllowExistingChats) { Write-Host "  chat $($d.key): pre-existing conversation, not imported into (use -AllowExistingChats to override)" -ForegroundColor Yellow; continue }
        Import-Conversation -Label "chat $($d.key)" -ConvPath "/chats/$([uri]::EscapeDataString($rec.id))" -Msgs $d.msgs -FilePlace 'user'
    }
}

# --- team and channels ----------------------------------------------------------------------------------------------------------
function Get-MgReady {
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { throw 'Microsoft.Graph.Authentication is needed for -TeamCreator Delegated.' }
    if ($DryRun) { return }
    if (-not (Get-MgContext)) { $p = @{ TenantId = $TenantId; NoWelcome = $true }; if ($Scopes) { $p.Scopes = $Scopes }; Connect-MgGraph @p | Out-Null }
}
function Ensure-Team {
    if ($State['team']) {
        $chk = Invoke-LabGraph -Path "/teams/$([uri]::EscapeDataString($State['team']['id']))?`$select=id,displayName" -Token $tok
        if ($chk.Ok) { Write-Host "  team exists: $($State['team']['id'])" -ForegroundColor DarkGray; Add-TeamMembers -TeamId $State['team']['id']; return }
        # Only a real 404 means "gone". A 403 (missing Team.ReadBasic.All) created a duplicate team on 09/11/2026.
        if ($chk.Status -ne 404) { throw "The team of labdata.json could not be read (HTTP $($chk.Status) $($chk.ErrorCode)): it is NOT recreated. Check the permissions of the Writer app." }
        Write-Warning 'The team of labdata.json no longer exists: it will be created again.'
        $State['team'] = $null; $State['channels'] = @{}
    }
    # POST /teams accepts ONE member at creation ("Adding more than one member is not supported", lab 09/11/2026):
    # the first member is the owner, the others are added once the team exists (Add-TeamMembers below).
    $members = @(New-MemberBinding 0 'owner')
    $body = @{ 'template@odata.bind' = "$G/teamsTemplates('standard')"; displayName = $TeamName; description = 'Equipe de test TT-Lab pour TeamsTransfer (donnees fictives).'; members = $members }
    $teamId = $null; $via = $null
    if ($TeamCreator -in 'Auto', 'App') {
        $r = Invoke-LabGraph -Method POST -Path '/teams' -Body $body -Token $tok
        if ($r.Status -eq 202 -or ($DryRun -and $r.Ok)) {
            $via = 'app'
            $teamId = if ($r.Location -match "teams\('([0-9a-fA-F-]{36})'\)") { $Matches[1] } elseif ($DryRun) { '{teamId}' } else { $null }
        }
        elseif ($TeamCreator -eq 'App') { throw "App-only team creation refused: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
        else { Write-Host "  app-only team creation refused (HTTP $($r.Status) $($r.ErrorCode)): falling back to the delegated administrator" -ForegroundColor Yellow }
    }
    if (-not $teamId) {
        Get-MgReady
        $via = 'delegated'
        $safe = $TeamName.Replace("'", "''")
        if ($DryRun) {
            Write-Host "[DRYRUN] (Connect-MgGraph context) POST $G/teams  body: displayName=$TeamName, $($U.Count) members" -ForegroundColor DarkGray
            Write-Host "[DRYRUN] (Connect-MgGraph context) GET $G/groups?`$filter=displayName eq '$safe'  (poll until the team exists)" -ForegroundColor DarkGray
            $teamId = '{teamId}'
        }
        else {
            $dup = @((Invoke-MgGraphRequest -Method GET -Uri "$G/groups?`$filter=displayName eq '$safe'&`$select=id" -OutputType HashTable)['value'])
            if ($dup.Count -gt 0) { throw "A group named '$TeamName' already exists ($($dup[0]['id'])) but is not in labdata.json: delete it or choose another -TeamName." }
            Invoke-MgGraphRequest -Method POST -Uri "$G/teams" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
            for ($i = 0; $i -lt 40 -and -not $teamId; $i++) {
                Start-Sleep -Seconds 5
                $grp = @((Invoke-MgGraphRequest -Method GET -Uri "$G/groups?`$filter=displayName eq '$safe'&`$select=id,resourceProvisioningOptions" -OutputType HashTable)['value'])
                if ($grp.Count -gt 0 -and @($grp[0]['resourceProvisioningOptions']) -contains 'Team') { $teamId = $grp[0]['id'] }
            }
        }
    }
    if (-not $teamId) { throw 'The team id could not be determined (creation still pending?). Wait, then run the script again after adding it to labdata.json.' }
    for ($i = 0; $i -lt 30 -and -not $DryRun; $i++) {
        $p = Invoke-LabGraph -Path "/teams/$teamId/channels?`$select=id" -Token $tok -NoRetry
        if ($p.Ok) { break }
        Start-Sleep -Seconds 5
    }
    $State['team'] = @{ id = $teamId; name = $TeamName; createdVia = $via; created = $true; createdUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save
    Write-Host "  team created ($via): $teamId" -ForegroundColor Green
    Add-TeamMembers -TeamId $teamId
}
function Add-TeamMembers {
    # Members 1..n of -Members (member 0 is the owner given at creation); member 1 is a second owner. Idempotent: 409/400
    # "already a member" is ignored.
    param([string]$TeamId)
    for ($i = 1; $i -lt $U.Count; $i++) {
        $role = if ($i -eq 1) { 'owner' } else { 'member' }
        $b = New-MemberBinding $i $role
        if ($role -eq 'member') { $b.roles = @() }
        $r = Invoke-LabGraph -Method POST -Path "/teams/$TeamId/members" -Body $b -Token $tok
        if ($r.Ok) { Write-Host "  team member added: $($U[$i].upn) ($role)" -ForegroundColor Green }
        elseif ($r.Status -in 400, 409 -and "$($r.ErrorMessage)" -match 'already|exist') { Write-Host "  team member already present: $($U[$i].upn)" -ForegroundColor DarkGray }
        else { Write-Warning "  team member $($U[$i].upn) not added: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
    }
}
function Ensure-Channel {
    param([string]$Key, [string]$Name, [string]$Type)
    if ($State['channels'].ContainsKey($Key)) { return $State['channels'][$Key]['id'] }
    $t = $State['team']['id']
    $body = @{ displayName = $Name; description = 'Canal de test TT-Lab'; membershipType = $Type }
    if ($Type -eq 'private') { $body.'@odata.type' = '#Microsoft.Graph.channel'; $body.members = @(0..($U.Count - 1) | ForEach-Object { New-MemberBinding $_ $(if ($_ -eq 0) { 'owner' } else { 'member' }) }) }
    $id = $null
    for ($i = 0; $i -lt 4 -and -not $id; $i++) {
        $r = Invoke-LabGraph -Method POST -Path "/teams/$t/channels" -Body $body -Token $tok
        if ($r.Ok -and $r.Json['id'] -and $r.Json['id'] -ne '{id}') { $id = [string]$r.Json['id'] }
        elseif ($DryRun) { $id = "{channel:$Key}" }
        elseif ($r.Status -eq 202) {
            for ($k = 0; $k -lt 12 -and -not $id; $k++) {
                Start-Sleep -Seconds 5
                $l = Invoke-LabGraph -Path "/teams/$t/channels?`$filter=displayName eq '$($Name.Replace("'", "''"))'&`$select=id" -Token $tok
                if ($l.Ok -and @($l.Json['value']).Count -gt 0) { $id = [string]$l.Json['value'][0]['id'] }
            }
        }
        elseif ($r.Status -eq 404 -or $r.Status -eq 409) { Start-Sleep -Seconds 10 }
        else { throw "Creation of channel '$Name' failed: HTTP $($r.Status) $($r.ErrorCode) $($r.ErrorMessage)" }
    }
    if (-not $id) { throw "Channel '$Name' could not be created." }
    $State['channels'][$Key] = @{ id = $id; name = $Name; type = $Type; created = $true }; Save
    Write-Host "  channel '$Name' ($Type): $id" -ForegroundColor Green
    $id
}
if (-not $SkipTeam) {
    Write-Host '== Team ==' -ForegroundColor Cyan
    Ensure-Team
    $t = $State['team']['id']
    $c1 = Ensure-Channel -Key 'c1' -Name 'TT-Lab Planning' -Type 'standard'
    $c2 = Ensure-Channel -Key 'c2' -Name 'TT-Lab Direction' -Type 'private'
    Import-Conversation -Label 'channel Planning' -ConvPath "/teams/$t/channels/$([uri]::EscapeDataString($c1))" -Msgs $PlanningMsgs -FilePlace 'group'
    Import-Conversation -Label 'channel Direction' -ConvPath "/teams/$t/channels/$([uri]::EscapeDataString($c2))" -Msgs $DirectionMsgs -FilePlace 'group'
}

Write-Host ''
Write-Host "Done. State: $StatePath" -ForegroundColor Green
Write-Host 'Clean up with: .\tools\Remove-Phase0LabData.ps1 -WhatIf  (then without -WhatIf)' -ForegroundColor DarkGray
if ($DryRun) { $script:Lab.Plan | Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'labdata-dryrun-plan.txt') -Encoding utf8 }
