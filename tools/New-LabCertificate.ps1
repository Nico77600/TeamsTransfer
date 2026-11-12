#Requires -Version 7.4
<#
.SYNOPSIS
    Lab only: creates a self-signed certificate for the Phase 0 app registrations and exports its PUBLIC part (.cer).

.DESCRIPTION
    Creates an RSA certificate (2048 bits or more, 1 year by default) in Cert:\CurrentUser\My. The private key is NOT
    exportable by default: it never leaves the Windows key store of the current user, and Invoke-Phase0.ps1 signs its
    client assertion with it in place. Only the public certificate is written to disk (a .cer file), to be uploaded to the
    two app registrations (Grant-LabConsent.ps1 does it).

    A .pfx file is written only with -ExportPfx and a SecureString -PfxPassword. In that case the key is created
    exportable (encrypted export policy). Nothing secret is ever printed: the output is the subject, the thumbprint, the
    validity dates and the path of the .cer.

    Running it again creates a NEW certificate (new thumbprint); remove old ones with certmgr.msc or Remove-Item.

.PARAMETER Subject
    Certificate subject. Default: CN=TT-Lab-TeamsTransfer.

.PARAMETER KeyLength
    RSA key length: 2048 (default), 3072 or 4096.

.PARAMETER ValidityDays
    Validity in days. Default 365.

.PARAMETER OutputFolder
    Folder of the .cer (and of the optional .pfx). Default: tools\phase0-output\certs (git-ignored).

.PARAMETER ExportPfx
    Also writes a password-protected .pfx. Requires -PfxPassword. Off by default.

.PARAMETER PfxPassword
    SecureString protecting the .pfx (only with -ExportPfx).

.EXAMPLE
    .\tools\New-LabCertificate.ps1

.EXAMPLE
    $pwd = Read-Host -AsSecureString 'PFX password'
    .\tools\New-LabCertificate.ps1 -ExportPfx -PfxPassword $pwd

.NOTES
    Author  : Nicolas Fabert
    Version : 0.1.0 (phase 0). Windows only (uses the PKI module).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Subject = 'CN=TT-Lab-TeamsTransfer',
    [ValidateSet(2048, 3072, 4096)][int]$KeyLength = 2048,
    [ValidateRange(1, 825)][int]$ValidityDays = 365,
    [string]$OutputFolder,
    [switch]$ExportPfx,
    [securestring]$PfxPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'New-LabCertificate.ps1 needs Windows (Cert:\CurrentUser\My).' }
if ($ExportPfx -and -not $PfxPassword) { throw '-ExportPfx needs -PfxPassword (a SecureString). No password-less .pfx is ever written.' }
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot 'phase0-output\certs' }

$policy = if ($ExportPfx) { 'ExportableEncrypted' } else { 'NonExportable' }
if (-not $PSCmdlet.ShouldProcess("Cert:\CurrentUser\My ($Subject, RSA $KeyLength, $ValidityDays days, key $policy)", 'Create self-signed certificate')) { return }

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$cert = New-SelfSignedCertificate -Subject $Subject -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA -KeyLength $KeyLength -HashAlgorithm SHA256 -KeySpec Signature `
    -KeyExportPolicy $policy -KeyUsage DigitalSignature -NotAfter (Get-Date).AddDays($ValidityDays) `
    -FriendlyName 'TeamsTransfer Phase 0 (lab)'

$cerPath = Join-Path $OutputFolder "$($cert.Thumbprint).cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null

$pfxPath = $null
if ($ExportPfx) {
    $pfxPath = Join-Path $OutputFolder "$($cert.Thumbprint).pfx"
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $PfxPassword | Out-Null
}

[pscustomobject]@{
    Subject    = $cert.Subject
    Thumbprint = $cert.Thumbprint
    NotBefore  = $cert.NotBefore
    NotAfter   = $cert.NotAfter
    KeyLength  = $KeyLength
    PrivateKey = if ($ExportPfx) { 'exportable (encrypted), .pfx written' } else { 'non-exportable, stays in CurrentUser\My' }
    PublicCer  = $cerPath
    Pfx        = $pfxPath
}
Write-Host ''
Write-Host "Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
Write-Host 'Next: .\tools\Grant-LabConsent.ps1 -TenantId <tenant> -CertificatePath' $cerPath
