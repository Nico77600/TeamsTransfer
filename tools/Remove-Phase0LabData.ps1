#Requires -Version 7.4
<#
.SYNOPSIS
    Lab only (DELETE): removes what New-Phase0LabData.ps1 created, and only what tools\phase0-output\labdata.json lists.

.DESCRIPTION
    Reads labdata.json and, for each listed object created by the seeding script:
      - files uploaded to a sender's OneDrive: DELETE /users/{id}/drive/items/{id} (Writer app, Files.ReadWrite.All), only if
        the file name starts with "TT-Lab-";
      - chats: DELETE /chats/{id} (Writer app), only when created by the seeding (a 1:1 chat that already existed is NEVER
        deleted) and, for group chats, only if the topic starts with "TT-Lab". If your tenant refuses the chat deletion
        with an app-only token, delete the chats by hand (the ids are printed);
      - the team: deleted through the administrator context (Connect-MgGraph, the existing Get-MgContext is reused),
        because deleting a group needs Group.ReadWrite.All which the Writer app does not have; only if its display name starts
        with "TT-Lab". Deleting the team deletes its channels and the files of its channels. The group stays in the Entra
        recycle bin for 30 days (permanent removal: DELETE /directory/deletedItems/{id}).
    Entries that were deleted successfully are removed from labdata.json; the others stay, so the script can be run again.

    -WhatIf lists everything it would delete and does not contact the tenant at all (no sign-in).

.PARAMETER TenantId
    Lab tenant id. Default: lab-apps.json.

.PARAMETER WriterClientId
    Writer app id. Default: lab-apps.json.

.PARAMETER CertificateThumbprint
    Certificate thumbprint. Default: lab-apps.json.

.PARAMETER ConfigPath
    lab-apps.json (default tools\phase0-output\lab-apps.json).

.PARAMETER Cloud
    Global (default), USGov, USGovDoD, China.

.PARAMETER StatePath
    labdata.json (default tools\phase0-output\labdata.json).

.PARAMETER Scopes
    Optional scopes for Connect-MgGraph when no Microsoft Graph context exists.

.PARAMETER Force
    No confirmation prompt (ShouldProcess confirmation is still shown with -Confirm).

.EXAMPLE
    .\tools\Remove-Phase0LabData.ps1 -WhatIf

.EXAMPLE
    .\tools\Remove-Phase0LabData.ps1 -Force

.NOTES
    Author  : Nicolas Fabert
    Version : 0.1.0 (phase 0).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$WriterClientId,
    [string]$CertificateThumbprint,
    [string]$ConfigPath,
    [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
    [string]$StatePath,
    [string[]]$Scopes,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Phase0.LabCommon.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'phase0-output\lab-apps.json' }
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot 'phase0-output\labdata.json' }
if (-not (Test-Path -LiteralPath $StatePath)) { throw "$StatePath not found: nothing to remove." }
$State = Read-LabState $StatePath
$cfg = Read-LabConfig $ConfigPath
if (-not $TenantId) { $TenantId = if ($State.ContainsKey('tenantId')) { $State['tenantId'] } elseif ($cfg.ContainsKey('tenantId')) { $cfg['tenantId'] } }
if (-not $CertificateThumbprint -and $cfg.ContainsKey('certificateThumbprint')) { $CertificateThumbprint = $cfg['certificateThumbprint'] }
if (-not $WriterClientId -and $cfg.ContainsKey('writer')) { $WriterClientId = $cfg['writer']['appId'] }

# plan
$plan = [System.Collections.Generic.List[hashtable]]::new()
foreach ($k in $State['files'].Keys) { $f = $State['files'][$k]; if ($f['place'] -eq 'user') { $plan.Add(@{ kind = 'file'; key = $k; desc = "OneDrive file $($f['name']) of user $($f['ownerUserId'])"; item = $f }) } }
foreach ($k in $State['chats'].Keys) {
    $c = $State['chats'][$k]
    if ($c['created']) { $plan.Add(@{ kind = 'chat'; key = $k; desc = "chat $k ($($c['type'])) $($c['id'])"; item = $c }) }
    else { Write-Host "Chat $k pre-existed (real conversation): never deleted." -ForegroundColor Yellow }
}
if ($State['team']) { $plan.Add(@{ kind = 'team'; key = 'team'; desc = "team '$($State['team']['name'])' $($State['team']['id']) (with its channels and channel files)"; item = $State['team'] }) }
if ($plan.Count -eq 0) { Write-Host 'labdata.json lists nothing to delete.'; return }

Write-Host 'Will delete (only what labdata.json lists):' -ForegroundColor Yellow
$plan | ForEach-Object { Write-Host "  - $($_.desc)" }
if ($WhatIfPreference) { Write-Host '-WhatIf: nothing contacted, nothing deleted.' -ForegroundColor Cyan; return }
if (-not $Force -and -not $PSCmdlet.ShouldContinue("Delete $($plan.Count) lab object(s) from tenant $TenantId ?", 'Remove-Phase0LabData')) { return }

if (-not ($TenantId -and $WriterClientId -and $CertificateThumbprint)) { throw 'TenantId, WriterClientId and CertificateThumbprint are needed.' }
Initialize-LabAuth -TenantId $TenantId -Cloud $Cloud -Thumbprint $CertificateThumbprint
$G = $script:Lab.G
$tok = Get-LabToken $WriterClientId

foreach ($p in $plan) {
    switch ($p.kind) {
        'file' {
            $f = $p.item
            if (([string]$f['name']) -notlike 'TT-Lab-*') { Write-Warning "Skipped $($f['name']): not a TT-Lab file."; continue }
            $r = Invoke-LabGraph -Method DELETE -Path "/users/$([uri]::EscapeDataString([string]$f['ownerUserId']))/drive/items/$([uri]::EscapeDataString([string]$f['itemId']))" -Token $tok
            if ($r.Ok -or $r.Status -eq 404) { $State['files'].Remove($p.key); Write-Host "  deleted $($p.desc)" -ForegroundColor Green } else { Write-Warning "  $($p.desc): HTTP $($r.Status) $($r.ErrorCode)" }
        }
        'chat' {
            $c = $p.item
            if ($c['type'] -eq 'group' -and -not ([string]$c['topic']).StartsWith('TT-Lab')) { Write-Warning "Skipped chat $($p.key): topic does not start with TT-Lab."; continue }
            $r = Invoke-LabGraph -Method DELETE -Path "/chats/$([uri]::EscapeDataString([string]$c['id']))" -Token $tok
            if ($r.Ok -or $r.Status -eq 404) { $State['chats'].Remove($p.key); foreach ($mk in @($State['messages'].Keys)) { if ($mk.StartsWith("$($p.key).")) { $State['messages'].Remove($mk) } }; Write-Host "  deleted $($p.desc)" -ForegroundColor Green }
            else { Write-Warning "  $($p.desc): HTTP $($r.Status) $($r.ErrorCode) - delete it by hand if needed." }
        }
        'team' {
            if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { Write-Warning 'Microsoft.Graph.Authentication missing: delete the team by hand.'; continue }
            if (-not (Get-MgContext)) { $cp = @{ TenantId = $TenantId; NoWelcome = $true }; if ($Scopes) { $cp.Scopes = $Scopes }; Connect-MgGraph @cp | Out-Null }
            $id = [string]$p.item['id']
            try { $grp = Invoke-MgGraphRequest -Method GET -Uri "$G/groups/$id`?`$select=id,displayName" -OutputType HashTable }
            catch { Write-Host '  team already gone.'; $State['team'] = $null; $State['channels'] = @{}; continue }
            if (-not ([string]$grp['displayName']).StartsWith('TT-Lab')) { Write-Warning "Skipped team ${id}: display name '$($grp['displayName'])' does not start with TT-Lab."; continue }
            if ($PSCmdlet.ShouldProcess($grp['displayName'], 'Delete group/team')) {
                Invoke-MgGraphRequest -Method DELETE -Uri "$G/groups/$id" | Out-Null
                $State['team'] = $null; $State['channels'] = @{}
                foreach ($mk in @($State['messages'].Keys)) { if ($mk -match '^c[12]\.') { $State['messages'].Remove($mk) } }
                foreach ($fk in @($State['files'].Keys)) { if ($State['files'][$fk]['place'] -eq 'group') { $State['files'].Remove($fk) } }
                Write-Host "  deleted team '$($grp['displayName'])'" -ForegroundColor Green
            }
        }
    }
    Save-LabState $State $StatePath
}
Write-Host ''
Write-Host "labdata.json updated: $StatePath" -ForegroundColor Green
