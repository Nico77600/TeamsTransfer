#Requires -Version 7.4
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Lab only: creates (or updates) the two Phase 0 app registrations, uploads the certificate and grants admin consent.

.DESCRIPTION
    Reuses the current Get-MgContext when there is one for the tenant, otherwise calls Connect-MgGraph -TenantId -NoWelcome (cached administrator, no forced interactive or device-code flow; -Scopes can be given when a fresh consent is needed). Delegated administrator: Application Administrator or Cloud Application
    Administrator for the apps, Privileged Role Administrator or Global Administrator for the consent of application
    permissions). Then, for each app:

      "TT-Lab TeamsTransfer Reader"  application permissions: Chat.Read.All, ChannelMessage.Read.All, ChatMember.Read.All,
                                  Team.ReadBasic.All, Channel.ReadBasic.All, ChannelMember.Read.All, User.Read.All,
                                  Files.Read.All, Sites.Read.All
      "TT-Lab TeamsTransfer Writer"  application permissions: Teamwork.Migrate.All, Chat.Create, Chat.ReadWrite.All,
                                  ChatMember.ReadWrite.All, Channel.Create, ChannelMember.ReadWrite.All, Team.Create,
                                  TeamMember.ReadWrite.All, Files.ReadWrite.All, Sites.ReadWrite.All, User.Read.All

    1. finds the application by display name, or creates it (single tenant, no secret, no redirect URI);
    2. adds the missing Microsoft Graph application permissions to requiredResourceAccess (existing ones are kept);
    3. adds the public certificate (-CertificatePath .cer, or -CertificateThumbprint read from CurrentUser\My) to
       keyCredentials unless it is already there (existing keys are kept);
    4. creates the service principal if needed;
    5. grants admin consent: one app role assignment per missing permission, on the Microsoft Graph service principal.

    Permission ids are NEVER hard-coded: each name is resolved at run time from the appRoles of the Microsoft Graph
    service principal of the tenant (a name that does not exist is reported and stops the script).

    Idempotent: running it again changes nothing. -WhatIf shows every change without making it (the read calls still run,
    so the sign-in is needed). Nothing is deleted. Optional -SecondWriter also creates "TT-Lab TeamsTransfer Writer B" with the
    Writer permissions, used by probe W4 (same-app ownership) as the "other" application.

    The ids needed by Invoke-Phase0.ps1 (tenant id, application ids, thumbprint, cloud) are written to
    tools\phase0-output\lab-apps.json (git-ignored; no secret in it).

    PROTECTED APIS: Chat.Read.All and ChannelMessage.Read.All in application mode (getAllMessages, messages of any chat)
    belong to the Teams "protected APIs". Microsoft documents (and has changed over time) a request form
    (https://aka.ms/teamsgraph/requestaccess) - see docs\design\Phase0-Runbook.md. Without it, calls may return 403 even
    though the permission is consented.

.PARAMETER TenantId
    Tenant id or domain of the LAB tenant (mandatory).

.PARAMETER CertificatePath
    Public .cer produced by New-LabCertificate.ps1.

.PARAMETER CertificateThumbprint
    Alternative to -CertificatePath: thumbprint of a certificate in Cert:\CurrentUser\My (only the public part is read).

.PARAMETER Cloud
    Global (default), USGov, USGovDoD or China.

.PARAMETER ReaderName
    Display name of the read-only app. Default "TT-Lab TeamsTransfer Reader".

.PARAMETER WriterName
    Display name of the import app. Default "TT-Lab TeamsTransfer Writer".

.PARAMETER Only
    Both (default), Reader or Writer.

.PARAMETER SecondWriter
    Also creates "TT-Lab TeamsTransfer Writer B" (same permissions as the Writer), for probe W4.

.PARAMETER Scopes
    Optional delegated scopes passed to Connect-MgGraph when no usable context exists (default: none, the cached token is used).

.PARAMETER NoConsent
    Creates/updates the apps and the certificate but does not grant admin consent.

.PARAMETER OutputPath
    Where the ids are written. Default tools\phase0-output\lab-apps.json.

.EXAMPLE
    .\tools\Grant-LabConsent.ps1 -TenantId contoso-lab.onmicrosoft.com -CertificatePath .\tools\phase0-output\certs\ABC.cer -WhatIf

.EXAMPLE
    .\tools\Grant-LabConsent.ps1 -TenantId contoso-lab.onmicrosoft.com -CertificateThumbprint ABCDEF... -SecondWriter

.NOTES
    Author  : Nicolas Fabert
    Version : 0.1.0 (phase 0). The administrator consents to Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All and
    Directory.Read.All for Microsoft Graph PowerShell the first time.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$CertificatePath,
    [string]$CertificateThumbprint,
    [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
    [string]$ReaderName = 'TT-Lab TeamsTransfer Reader',
    [string]$WriterName = 'TT-Lab TeamsTransfer Writer',
    [ValidateSet('Both', 'Reader', 'Writer')][string]$Only = 'Both',
    [switch]$SecondWriter,
    [switch]$NoConsent,
    [string[]]$Scopes,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$readerPermissions = @('Chat.Read.All', 'ChannelMessage.Read.All', 'ChatMember.Read.All', 'Team.ReadBasic.All', 'TeamMember.Read.All',
    'Channel.ReadBasic.All', 'ChannelMember.Read.All', 'User.Read.All', 'Files.Read.All', 'Sites.Read.All')
$writerPermissions = @('Teamwork.Migrate.All', 'Chat.Create', 'Chat.ReadWrite.All', 'ChatMember.ReadWrite.All',
    'Channel.Create', 'ChannelMember.ReadWrite.All', 'Team.Create', 'TeamMember.ReadWrite.All',
    'Files.ReadWrite.All', 'Sites.ReadWrite.All', 'User.Read.All',
    'Team.ReadBasic.All', 'Channel.ReadBasic.All',   # read back migrationMode of channels (403 without them, lab 2026-11-09)
    'User.ReadWrite.All', 'Group.Read.All', 'GroupMember.ReadWrite.All', 'ChannelMessage.Read.All')   # ghost accounts, ghost tracking group, verify (2026-11-10)

$graphHost = @{ Global = 'https://graph.microsoft.com'; USGov = 'https://graph.microsoft.us'; USGovDoD = 'https://dod-graph.microsoft.us'; China = 'https://microsoftgraph.chinacloudapi.cn' }[$Cloud]
$graphAppId = '00000003-0000-0000-c000-000000000000'
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'phase0-output\lab-apps.json' }

# --- certificate (public part only) ---------------------------------------------------------------------------------
$cert = $null
if ($CertificatePath) { $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path $CertificatePath).Path) }
elseif ($CertificateThumbprint) {
    $found = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $found) { throw "Certificate $CertificateThumbprint not found in Cert:\CurrentUser\My." }
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($found.RawData)
}
if (-not $cert) { throw 'Give -CertificatePath (.cer) or -CertificateThumbprint.' }
if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $($cert.Thumbprint) is expired." }

function Invoke-G {
    param([string]$Method = 'GET', [string]$Path, $Body)
    $p = @{ Method = $Method; Uri = "$graphHost/v1.0$Path"; OutputType = 'HashTable' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Get-All([string]$Path) {
    $r = Invoke-G -Path $Path
    $all = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        foreach ($v in @($r['value'])) { if ($null -ne $v) { $all.Add($v) } }
        if (-not $r.ContainsKey('@odata.nextLink')) { break }
        $r = Invoke-MgGraphRequest -Method GET -Uri $r['@odata.nextLink'] -OutputType HashTable
    }
    , $all.ToArray()
}

$ctx = Get-MgContext
$tenantMatches = $ctx -and ($ctx.TenantId -eq $TenantId -or $TenantId -notmatch '^[0-9a-fA-F-]{36}$')
if ($ctx -and $tenantMatches) { Write-Host "Reusing the existing Microsoft Graph context ($($ctx.Account))." -ForegroundColor DarkGray }
else {
    Write-Host "Connecting to tenant $TenantId ($Cloud) with the cached administrator (no prompt if a cached sign-in exists)..." -ForegroundColor Cyan
    $connect = @{ TenantId = $TenantId; Environment = $Cloud; NoWelcome = $true }
    if ($Scopes) { $connect.Scopes = $Scopes }
    Connect-MgGraph @connect | Out-Null
    $ctx = Get-MgContext
}
$resolvedTenant = $ctx.TenantId
Write-Host "Signed in as $($ctx.Account), tenant $resolvedTenant" -ForegroundColor DarkGray
# --- Microsoft Graph service principal: permission names -> app role ids (runtime, no hard-coded GUID) -----------------
$graphSp = (Invoke-G -Path "/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,appId,appRoles")['value'][0]
$roleByName = @{}
foreach ($r in $graphSp['appRoles']) {
    if ($r['isEnabled'] -and ($r['allowedMemberTypes'] -contains 'Application')) { $roleByName[$r['value']] = $r['id'] }
}

function Resolve-Roles([string[]]$Names) {
    $missing = @($Names | Where-Object { -not $roleByName.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "These application permissions do not exist on Microsoft Graph in this tenant/cloud: $($missing -join ', ')" }
    $Names | ForEach-Object { [pscustomobject]@{ Name = $_; Id = $roleByName[$_] } }
}

function Sync-LabApp {
    param([string]$DisplayName, [string[]]$Permissions)
    Write-Host ''
    Write-Host "== $DisplayName ==" -ForegroundColor Cyan
    $roles = @(Resolve-Roles $Permissions)
    $result = [ordered]@{ displayName = $DisplayName; appId = $null; objectId = $null; servicePrincipalId = $null; changes = [System.Collections.Generic.List[string]]::new() }

    # 1. application
    $safeName = $DisplayName.Replace("'", "''")
    $apps = @((Invoke-G -Path "/applications?`$filter=displayName eq '$safeName'&`$select=id,appId,displayName,requiredResourceAccess,keyCredentials")['value'])
    if ($apps.Count -gt 1) { throw "More than one application is called '$DisplayName' ($($apps.Count)). Rename or delete the extra ones first." }
    $app = if ($apps.Count -eq 1) { $apps[0] } else { $null }
    $desiredAccess = @($roles | ForEach-Object { @{ id = $_.Id; type = 'Role' } })

    if (-not $app) {
        if ($PSCmdlet.ShouldProcess($DisplayName, 'Create application')) {
            $app = Invoke-G -Method POST -Path '/applications' -Body @{
                displayName            = $DisplayName
                signInAudience         = 'AzureADMyOrg'
                requiredResourceAccess = @(@{ resourceAppId = $graphAppId; resourceAccess = $desiredAccess })
            }
            $result.changes.Add('application created')
            Write-Host "  created application $($app['appId'])" -ForegroundColor Green
            $app['keyCredentials'] = @()
        }
        else { $result.changes.Add('WOULD create application') }
    }
    else {
        Write-Host "  application exists: $($app['appId'])" -ForegroundColor DarkGray
        $rra = @($app['requiredResourceAccess'])
        $graphEntry = $rra | Where-Object { $_['resourceAppId'] -eq $graphAppId } | Select-Object -First 1
        $have = if ($graphEntry) { @($graphEntry['resourceAccess'] | ForEach-Object { $_['id'] }) } else { @() }
        $toAdd = @($roles | Where-Object { $_.Id -notin $have })
        if ($toAdd.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($DisplayName, "Add required permissions: $($toAdd.Name -join ', ')")) {
                $newRra = [System.Collections.Generic.List[object]]::new()
                foreach ($e in $rra) {
                    if ($e['resourceAppId'] -ne $graphAppId) { $newRra.Add(@{ resourceAppId = $e['resourceAppId']; resourceAccess = @($e['resourceAccess'] | ForEach-Object { @{ id = $_['id']; type = $_['type'] } }) }) }
                }
                $keep = if ($graphEntry) { @($graphEntry['resourceAccess'] | ForEach-Object { @{ id = $_['id']; type = $_['type'] } }) } else { @() }
                $newRra.Add(@{ resourceAppId = $graphAppId; resourceAccess = @($keep + @($toAdd | ForEach-Object { @{ id = $_.Id; type = 'Role' } })) })
                Invoke-G -Method PATCH -Path "/applications/$($app['id'])" -Body @{ requiredResourceAccess = @($newRra) } | Out-Null
                $result.changes.Add("permissions added: $($toAdd.Name -join ', ')")
                Write-Host "  permissions added: $($toAdd.Name -join ', ')" -ForegroundColor Green
            }
            else { $result.changes.Add("WOULD add permissions: $($toAdd.Name -join ', ')") }
        }
        else { Write-Host '  required permissions: already complete' -ForegroundColor DarkGray }
    }

    # 2. certificate
    if ($app) {
        $hasCert = $false
        foreach ($k in @($app['keyCredentials'])) {
            if ($k -and $k['customKeyIdentifier']) {
                # Graph returns the thumbprint itself as hex (lab 10/11/2026); older answers were base64 of the bytes: accept both.
                $id = [string]$k['customKeyIdentifier']
                if ($id -eq $cert.Thumbprint) { $hasCert = $true }
                else { try { if ([Convert]::ToHexString([Convert]::FromBase64String($id)) -eq $cert.Thumbprint) { $hasCert = $true } } catch { } }
            }
        }
        if ($hasCert) { Write-Host "  certificate $($cert.Thumbprint): already uploaded" -ForegroundColor DarkGray }
        elseif ($PSCmdlet.ShouldProcess($DisplayName, "Upload certificate $($cert.Thumbprint)")) {
            $keys = [System.Collections.Generic.List[object]]::new()
            foreach ($k in @($app['keyCredentials'])) {
                if ($k) { $keys.Add(@{ customKeyIdentifier = $k['customKeyIdentifier']; displayName = $k['displayName']; endDateTime = $k['endDateTime']; keyId = $k['keyId']; startDateTime = $k['startDateTime']; type = $k['type']; usage = $k['usage']; key = $null }) }
            }
            $keys.Add(@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = "TT-Lab TeamsTransfer $($cert.Thumbprint.Substring(0, 8))"; key = [Convert]::ToBase64String($cert.RawData) })
            Invoke-G -Method PATCH -Path "/applications/$($app['id'])" -Body @{ keyCredentials = @($keys) } | Out-Null
            $result.changes.Add("certificate uploaded: $($cert.Thumbprint)")
            Write-Host "  certificate uploaded: $($cert.Thumbprint)" -ForegroundColor Green
        }
        else { $result.changes.Add('WOULD upload certificate') }
        $result.appId = $app['appId']; $result.objectId = $app['id']
    }

    # 3. service principal
    $sp = $null
    if ($app) {
        $sps = @((Invoke-G -Path "/servicePrincipals?`$filter=appId eq '$($app['appId'])'&`$select=id,appId")['value'])
        if ($sps.Count -gt 0) { $sp = $sps[0] }
        elseif ($PSCmdlet.ShouldProcess($DisplayName, 'Create service principal')) {
            $sp = Invoke-G -Method POST -Path '/servicePrincipals' -Body @{ appId = $app['appId'] }
            $result.changes.Add('service principal created')
            Write-Host '  service principal created' -ForegroundColor Green
        }
        else { $result.changes.Add('WOULD create service principal') }
    }

    # 4. admin consent = app role assignments
    if ($sp -and -not $NoConsent) {
        $result.servicePrincipalId = $sp['id']
        $assigned = @((Get-All "/servicePrincipals/$($sp['id'])/appRoleAssignments") | Where-Object { $_['resourceId'] -eq $graphSp['id'] } | ForEach-Object { $_['appRoleId'] })
        $missing = @($roles | Where-Object { $_.Id -notin $assigned })
        if ($missing.Count -eq 0) { Write-Host '  admin consent: already complete' -ForegroundColor DarkGray }
        foreach ($m in $missing) {
            if ($PSCmdlet.ShouldProcess($DisplayName, "Grant admin consent: $($m.Name)")) {
                Invoke-G -Method POST -Path "/servicePrincipals/$($sp['id'])/appRoleAssignments" -Body @{ principalId = $sp['id']; resourceId = $graphSp['id']; appRoleId = $m.Id } | Out-Null
                $result.changes.Add("consent granted: $($m.Name)")
                Write-Host "  consent granted: $($m.Name)" -ForegroundColor Green
            }
            else { $result.changes.Add("WOULD grant consent: $($m.Name)") }
        }
    }
    elseif (-not $sp -and -not $NoConsent) { $result.changes.Add('WOULD grant admin consent (service principal does not exist yet)') }
    if ($result.changes.Count -eq 0) { Write-Host '  nothing to change' -ForegroundColor DarkGray }
    [pscustomobject]$result
}

$out = [ordered]@{ tenantId = $resolvedTenant; cloud = $Cloud; certificateThumbprint = $cert.Thumbprint; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
$summary = @()
if ($Only -in 'Both', 'Reader') { $r = Sync-LabApp -DisplayName $ReaderName -Permissions $readerPermissions; $out.reader = @{ appId = $r.appId; displayName = $r.displayName }; $summary += $r }
if ($Only -in 'Both', 'Writer') { $w = Sync-LabApp -DisplayName $WriterName -Permissions $writerPermissions; $out.writer = @{ appId = $w.appId; displayName = $w.displayName }; $summary += $w }
if ($SecondWriter) { $w2 = Sync-LabApp -DisplayName "$WriterName B" -Permissions $writerPermissions; $out.writerB = @{ appId = $w2.appId; displayName = $w2.displayName }; $summary += $w2 }

if (-not $WhatIfPreference) {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath) | Out-Null
    $out | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host ''
    Write-Host "Ids written to $OutputPath (no secret in it)." -ForegroundColor Green
}

Write-Host ''
Write-Host 'REMINDER - Teams protected APIs' -ForegroundColor Yellow
Write-Host '  Chat.Read.All and ChannelMessage.Read.All used in APPLICATION mode (getAllMessages, messages of any chat/channel) are'
Write-Host '  "protected APIs". Microsoft documents a request form: https://aka.ms/teamsgraph/requestaccess (see'
Write-Host '  https://learn.microsoft.com/graph/teams-protected-apis; check whether the request is still required for your tenant).'
Write-Host '  Until approved, probes R2/R3/R4 can return 403 even though the consent is granted.'
Write-Host '  Admin consent can take a few minutes to propagate: wait before running Invoke-Phase0.ps1 (probe R1 checks the token).'
$summary
