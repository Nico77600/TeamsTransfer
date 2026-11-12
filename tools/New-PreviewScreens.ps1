#Requires -Version 7.4
<#
.SYNOPSIS
    Generates the Demo-preset archive and captures the documentation screenshots of the preview (headless Edge/Chrome, 1440x900, light and dark).
.DESCRIPTION
    Builds SyntheticTenant.Demo() behind a MemoryStoreReader, exports it with Export-TmtArchive (folder archive in a temp folder), opens it from file://
    in a headless browser driven over the DevTools protocol and writes package\docs\images\preview-<scene>-light.png / -dark.png.
    Nothing leaves the machine. Needs Edge or Chrome.
.PARAMETER OutputDirectory
    Where the PNGs go (default package\docs\images).
.PARAMETER KeepArchive
    Keeps the generated archive and prints its path (to open it by hand).
.EXAMPLE
    pwsh -File tools\New-PreviewScreens.ps1
.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.1
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$KeepArchive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'package\docs\images' }
. (Join-Path $repo 'tests\TestHelpers.ps1')                   # module + engine + tests\support (MemoryStoreReader, SyntheticTenant)
. (Join-Path $repo 'tests\support\BrowserHarness.ps1')
if (-not (Find-TestBrowser)) { throw 'No Edge or Chrome found: cannot capture screenshots.' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$tenant = [TeamsTransfer.Testing.SyntheticTenant]::Demo()
$reader = [TeamsTransfer.Testing.MemoryStoreReader]::new($tenant)
$archive = Join-Path ([IO.Path]::GetTempPath()) ('tt-preview-screens-' + [guid]::NewGuid().ToString('N'))
$result = Export-TmtArchive -Store $reader -OutputPath $archive -Users 'camille.martin@contoso.com' 
Write-Host ("Archive: {0} conversations, {1} messages, {2} chunks -> {3}" -f $result.Conversations, $result.Messages, $result.Chunks, $archive)
$manifest = ([regex]::Match((Get-Content (Join-Path $archive 'index.html') -Raw), 'id="tt-manifest">(.*?)</script>', 'Singleline').Groups[1].Value) | ConvertFrom-Json
function Find-Conv([string]$Title) { ($manifest.conversations | Where-Object title -like $Title | Select-Object -First 1).id }
$ids = @{ group = (Find-Conv 'Project Moon*'); meeting = (Find-Conv 'Weekly product*'); channel = (Find-Conv 'Announcements'); chat = (Find-Conv 'Julien*') }
$url = ([Uri](Join-Path $archive 'index.html')).AbsoluteUri
$houseArchive = $archive + '-house'   # the Teams indigo accent (-Accent Teams)
[void](Export-TmtArchive -Store $reader -OutputPath $houseArchive -Users 'camille.martin@contoso.com' -Accent Teams)
$houseUrl = ([Uri](Join-Path $houseArchive 'index.html')).AbsoluteUri

[void](Start-TestBrowser -Width 1440 -Height 900)
try {
    $ready = 'document.documentElement.getAttribute("data-ready")==="1"'
    $settled = '!document.querySelector("#rows .skel") && Array.from(document.images).every(function(i){return i.complete}) && TT.api.stats().rendered>0'
    foreach ($scheme in 'light', 'dark') {
        Set-TestViewport -Width 1440 -Height 900 -Scheme $scheme
        $scenes = [ordered]@{
            'overview' = @{ hash = ''; js = $null }
            'group'    = @{ hash = "#c=$($ids.group)"; js = 'TT.api.goTo(0).then(function(){return 1})' }
            'chat'     = @{ hash = "#c=$($ids.chat)"; js = $null }
            'meeting'  = @{ hash = "#c=$($ids.meeting)"; js = $null }
            'channel'  = @{ hash = "#c=$($ids.channel)"; js = 'document.querySelectorAll("#rows .tbtn").forEach(function(b){b.click()}); 1' }
            'files'    = @{ hash = "#c=$($ids.group)"; js = 'TT.api.showTab("files"); 1' }
            'indigo'   = @{ hash = "#c=$($ids.group)"; js = $null; house = $true }
            'search'   = @{ hash = "#c=$($ids.group)"; js = 'document.getElementById("scope").value="all"; document.getElementById("scope").dispatchEvent(new Event("change")); document.getElementById("q").value="mockups"; TT.api.search("mockups").then(function(){return 1})' }
        }
        foreach ($name in $scenes.Keys) {
            $s = $scenes[$name]
            Open-TestPage -Url 'about:blank' -ReadyExpression 'true' | Out-Null   # a hash-only navigation would not reload the page
            $pageUrl = if ($s.ContainsKey("house")) { $houseUrl } else { $url }
            Open-TestPage -Url ($pageUrl + $s.hash) -ReadyExpression $ready | Out-Null
            if ($s.hash) { Wait-TestPage $settled | Out-Null }
            if ($s.js) { [void](Get-TestValue $s.js -TimeoutSec 60); Start-Sleep -Milliseconds 500; if ($s.hash) { Wait-TestPage $settled | Out-Null } }
            Start-Sleep -Milliseconds 1900   # lets the "flash" animation of a jump end
            $errors = @(Get-TestConsole | Where-Object { $_ -match '^\[(error|exception)\]' })
            if ($errors) { Write-Warning ("{0}/{1}: {2}" -f $name, $scheme, ($errors -join ' | ')) }
            $png = Join-Path $OutputDirectory "preview-$name-$scheme.png"
            Save-TestScreenshot -Path $png
            Write-Host "  $png" -ForegroundColor DarkGray
        }
    }
} finally {
    Stop-TestBrowser
    if ($KeepArchive) { Write-Host "Archive kept: $archive" } else { Remove-Item -LiteralPath $archive, $houseArchive -Recurse -Force -ErrorAction SilentlyContinue }
}
