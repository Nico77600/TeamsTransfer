# Headless Edge / Chrome driven over the DevTools protocol (WebSocket on localhost). Used by Preview.Tests.ps1 and tools\New-PreviewScreens.ps1.
# Dot-source it:  . (Join-Path $PSScriptRoot 'support\BrowserHarness.ps1')
# Nothing leaves the machine: the browser listens on 127.0.0.1 only, on a random port, with a throw-away profile.

function Find-TestBrowser {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    foreach ($n in 'msedge', 'chrome', 'google-chrome', 'chromium') { $cmd = Get-Command $n -ErrorAction SilentlyContinue; if ($cmd) { return $cmd.Source } }
    return $null
}

function Start-TestBrowser {
    [CmdletBinding()] param([int]$Width = 1440, [int]$Height = 900, [string[]]$ExtraArgs = @())
    $exe = Find-TestBrowser
    if (-not $exe) { throw 'No Edge/Chrome found.' }
    $profile = Join-Path ([IO.Path]::GetTempPath()) ('tt-browser-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profile | Out-Null
    $argList = @('--headless=new', '--remote-debugging-port=0', "--user-data-dir=$profile", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
        '--disable-background-networking', '--disable-component-update', '--disable-features=msEdgeSync,msEdgeAutoSignIn,Translate', '--hide-scrollbars=false', "--window-size=$Width,$Height", '--force-device-scale-factor=1',
        '--allow-file-access-from-files=false') + $ExtraArgs + @('about:blank')
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    $portFile = Join-Path $profile 'DevToolsActivePort'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $portFile) -and [DateTime]::UtcNow -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $portFile)) { try { $proc.Kill($true) } catch { }; throw 'The browser did not publish its DevTools port.' }
    Start-Sleep -Milliseconds 200
    $port = [int](Get-Content -LiteralPath $portFile -TotalCount 1)
    $page = $null
    for ($i = 0; $i -lt 50 -and -not $page; $i++) {
        try { $page = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$port/json/new?about:blank" } catch { }
        if (-not $page) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $page) { try { $proc.Kill($true) } catch { }; throw 'No page target.' }
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $script:Cdp = [pscustomobject]@{ Process = $proc; Port = $port; Socket = $ws; Profile = $profile; Id = 0; Events = [System.Collections.Generic.List[object]]::new(); Dialogs = [System.Collections.Generic.List[string]]::new(); Exe = $exe }
    foreach ($d in 'Page.enable', 'Runtime.enable', 'Log.enable', 'Network.enable') { [void](Invoke-Cdp $d) }
    $script:Cdp
}

function Receive-CdpMessage {
    param([int]$TimeoutSec = 60)
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    $buf = New-Object byte[] 262144
    $ms = [IO.MemoryStream]::new()
    do {
        $seg = [ArraySegment[byte]]::new($buf)
        $r = $script:Cdp.Socket.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
        $ms.Write($buf, 0, $r.Count)
    } until ($r.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json -Depth 50
}

function Invoke-Cdp {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Method, [hashtable]$Params = @{}, [int]$TimeoutSec = 60)
    $c = $script:Cdp
    $id = ++$c.Id
    $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    [void]$c.Socket.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    while ($true) {
        $m = Receive-CdpMessage -TimeoutSec $TimeoutSec
        if ($m.PSObject.Properties.Name -contains 'id' -and $m.id -eq $id) {
            if ($m.PSObject.Properties.Name -contains 'error') { throw "CDP $Method failed: $($m.error.message)" }
            return $m.result
        }
        if ($m.PSObject.Properties.Name -contains 'method') {
            $c.Events.Add($m)
            if ($m.method -eq 'Page.javascriptDialogOpening') {
                $c.Dialogs.Add([string]$m.params.message)
                $hid = ++$c.Id
                $hj = @{ id = $hid; method = 'Page.handleJavaScriptDialog'; params = @{ accept = $true } } | ConvertTo-Json -Compress
                [void]$c.Socket.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($hj)), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            }
        }
    }
}

function Open-TestPage {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Url, [string]$ReadyExpression = 'document.documentElement.getAttribute("data-ready")==="1"', [int]$TimeoutSec = 60)
    # a navigation that only changes the hash does not reload the page: always go through about:blank first
    if ($Url -ne 'about:blank') { [void](Invoke-Cdp 'Page.navigate' @{ url = 'about:blank' }); Start-Sleep -Milliseconds 100 }
    $script:Cdp.Events.Clear()
    [void](Invoke-Cdp 'Page.navigate' @{ url = $Url })
    Wait-TestPage -Expression $ReadyExpression -TimeoutSec $TimeoutSec
}

function Get-TestValue {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Expression, [int]$TimeoutSec = 60)
    $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } -TimeoutSec $TimeoutSec
    if ($r.PSObject.Properties.Name -contains 'exceptionDetails') { throw "JS exception: $($r.exceptionDetails.text) $($r.exceptionDetails.exception.description)" }
    if ($r.result.PSObject.Properties.Name -contains 'value') { return $r.result.value }
    return $null
}

function Wait-TestPage {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Expression, [int]$TimeoutSec = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { if (Get-TestValue $Expression) { return $true } } catch { }
        Start-Sleep -Milliseconds 150
    }
    throw "Timeout waiting for: $Expression"
}

function Set-TestViewport {
    [CmdletBinding()] param([int]$Width = 1440, [int]$Height = 900, [ValidateSet('light', 'dark')][string]$Scheme = 'light')
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-Cdp 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = $Scheme }) })
}

function Save-TestScreenshot {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png'; captureBeyondViewport = $false }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($r.data))
}

function Get-TestConsole {
    # console / log / exception messages collected since the last Open-TestPage (CSP violations show up as Log.entryAdded)
    foreach ($e in $script:Cdp.Events) {
        if ($e.method -eq 'Log.entryAdded') { "[$($e.params.entry.level)] $($e.params.entry.text) $($e.params.entry.url)" }
        elseif ($e.method -eq 'Runtime.exceptionThrown') { "[exception] $($e.params.exceptionDetails.text) $($e.params.exceptionDetails.exception.description) line $($e.params.exceptionDetails.lineNumber)" }
        elseif ($e.method -eq 'Runtime.consoleAPICalled') { "[console.$($e.params.type)] " + (($e.params.args | ForEach-Object { $_.value }) -join ' ') }
    }
}
function Get-TestRequests {
    # every URL the page tried to load (Network.requestWillBeSent) since the last Open-TestPage
    $script:Cdp.Events | Where-Object method -eq 'Network.requestWillBeSent' | ForEach-Object { [string]$_.params.request.url }
}

function Stop-TestBrowser {
    $c = $script:Cdp
    if (-not $c) { return }
    try { $c.Socket.Dispose() } catch { }
    try { if (-not $c.Process.HasExited) { $c.Process.Kill($true) } } catch { }
    Start-Sleep -Milliseconds 300
    try { Remove-Item -LiteralPath $c.Profile -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $script:Cdp = $null
}
