#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Graph.cs: HttpGraphTransport (stub HTTP handler), GraphClient (scripted transport, virtual clock).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None

    function Wait-Task($t) { $t.GetAwaiter().GetResult() }
    function Get-Thrown([scriptblock]$Block) {
        try { & $Block; return $null } catch {
            $e = $_.Exception
            while ($e.InnerException -and ($e -is [Management.Automation.MethodInvocationException] -or $e -is [AggregateException])) { $e = $e.InnerException }
            return $e
        }
    }
    function New-Ctx([scriptblock]$Configure = $null, [switch]$WithLimiter) {
        $clock = [TeamsTransfer.TestManualClock]::new()
        $tr = [TeamsTransfer.ScriptedTransport]::new()
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = $clock
        $o.MaxAttempts = 5
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1)
        $o.MaxBackoff = [TimeSpan]::FromSeconds(8)
        $o.Random = [TeamsTransfer.TestFuncs]::Const(1.0)
        if ($Configure) { & $Configure $o }
        $ev = [TeamsTransfer.EventRecorder]::new()
        $lim = $null
        if ($WithLimiter) { $lim = [TeamsTransfer.AdaptiveRateLimiter]::new($o.ToRateLimiterOptions()) }
        $client = [TeamsTransfer.GraphClient]::new($tr, $o, $lim, $ev.Callback)
        [pscustomobject]@{ Clock = $clock; Transport = $tr; Client = $client; Events = $ev; Limiter = $lim; Options = $o }
    }
    function New-Items([int]$n, [string]$prefix = 'i') {
        $list = [Collections.Generic.List[TeamsTransfer.BatchItem]]::new()
        1..$n | ForEach-Object { $list.Add([TeamsTransfer.BatchItem]@{ Id = "$prefix$_"; Url = "/users/u$_" }) }
        , $list
    }
    function Get-Delays($ctx) { @($ctx.Clock.Delays | ForEach-Object { $_.TotalSeconds }) }
    $script:Users = [TeamsTransfer.EndpointClass]::Users
}

Describe 'HttpGraphTransport' {
    BeforeEach {
        $script:h = [TeamsTransfer.StubHttpHandler]::new()
        $script:tok = [TeamsTransfer.StaticTokenProvider]::new()
        $script:t = [TeamsTransfer.HttpGraphTransport]::new($script:tok, [TeamsTransfer.GraphCloud]::Global, 8, $script:h)
    }
    It 'adds the bearer token and a client-request-id, and resolves a relative URL against the Graph root' {
        $script:h.Enqueue(200, '{"ok":true}')
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'v1.0/users?$top=5'
        $resp = Wait-Task $script:t.SendAsync($r, $script:ct)
        $q = $script:h.Requests[0]
        $q.Uri | Should -Be 'https://graph.microsoft.com/v1.0/users?$top=5'
        $q.Authorization | Should -Be 'Bearer TEST-TOKEN'
        { [guid]::Parse($q.ClientRequestId) } | Should -Not -Throw
        $resp.StatusCode | Should -Be 200
        $resp.IsSuccess | Should -BeTrue
        (Wait-Task $resp.ReadAsStringAsync()) | Should -Be '{"ok":true}'
    }
    It 'uses the sovereign Graph root for a US Government cloud' {
        $t = [TeamsTransfer.HttpGraphTransport]::new($script:tok, [TeamsTransfer.GraphCloud]::USGov, 8, $script:h)
        $script:h.Enqueue(200, '{}')
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = '/v1.0/me'
        Wait-Task $t.SendAsync($r, $script:ct) | Out-Null
        $script:h.Requests[0].Uri | Should -Be 'https://graph.microsoft.us/v1.0/me'
    }
    It 'omits the Authorization header for an anonymous request (upload session URL)' {
        $script:h.Enqueue(202, '{}')
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'https://contoso.sharepoint.com/upload?tempauth=abc'; $r.Anonymous = $true
        $r.Method = [Net.Http.HttpMethod]::Put; $r.BodyBytes = [byte[]](1, 2, 3); $r.ContentType = 'application/octet-stream'
        Wait-Task $script:t.SendAsync($r, $script:ct) | Out-Null
        $script:h.Requests[0].Authorization | Should -BeNullOrEmpty
        $script:h.Requests[0].Method | Should -Be 'PUT'
        $script:h.Requests[0].ContentType | Should -Be 'application/octet-stream'
    }
    It 'refuses to send the token to a host that is not Graph' {
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'https://evil.example.com/v1.0/users'
        $e = Get-Thrown { Wait-Task $script:t.SendAsync($r, $script:ct) }
        $e | Should -BeOfType [InvalidOperationException]
        $script:h.Requests.Count | Should -Be 0
    }
    It 'sends BodyJson as application/json and copies status and headers' {
        $script:h.Enqueue(429, '{"error":{"code":"TooManyRequests"}}')
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'v1.0/chats'; $r.Method = [Net.Http.HttpMethod]::Post; $r.BodyJson = '{"a":1}'
        $r.Headers['Prefer'] = 'odata.maxpagesize=50'
        $resp = Wait-Task $script:t.SendAsync($r, $script:ct)
        $script:h.Requests[0].Body | Should -Be '{"a":1}'
        $script:h.Requests[0].ContentType | Should -Be 'application/json'
        $script:h.Requests[0].Headers['Prefer'] | Should -Be 'odata.maxpagesize=50'
        $resp.StatusCode | Should -Be 429
        $resp.ContentType | Should -Match 'application/json'
    }
    It 'does not dispose a caller-owned body stream (it must be replayable)' {
        $script:h.Enqueue(200, '{}')
        $ms = [IO.MemoryStream]::new([byte[]](1, 2, 3, 4))
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'v1.0/x'; $r.Method = [Net.Http.HttpMethod]::Put; $r.BodyStream = $ms
        Wait-Task $script:t.SendAsync($r, $script:ct) | Out-Null
        $ms.CanRead | Should -BeTrue
        $script:h.Requests[0].Body.Length | Should -Be 4
    }
}

Describe 'GraphClient - retry' {
    It 'returns the parsed JSON of a 200' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, '{"id":"u1"}')
        $doc = Wait-Task $c.Client.GetJsonAsync('v1.0/users/u1', $Users, $null, $script:ct)
        $doc.RootElement.GetProperty('id').GetString() | Should -Be 'u1'
        $c.Transport.Requests[0].EndpointClass | Should -Be 'users'
        $c.Events.Events[0].Kind | Should -Be ([TeamsTransfer.GraphEventKind]::Request)
    }
    It 'falls back to Classify when no endpoint class is given' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/chats/19:a@thread.v2/members', $null, $null, $script:ct) | Out-Null
        $c.Transport.Requests[0].EndpointClass | Should -Be 'chats.members'
        $c.Events.Events[0].EndpointClass | Should -Be 'chats.members'
    }
    It 'returns null for an empty 204 answer' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(204, $null)
        (Wait-Task $c.Client.PostJsonAsync('v1.0/chats/c1/completeMigration', '{}', $null, $null, $script:ct)) | Should -BeNullOrEmpty
    }
    It 'honours Retry-After in seconds exactly' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(429, '{"error":{"code":"TooManyRequests","message":"slow down"}}', '7')
        $c.Transport.EnqueueJson(200, '{"ok":1}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        Get-Delays $c | Should -Be @(7)
        $c.Transport.Requests.Count | Should -Be 2
        $ev = $c.Events.Events | Where-Object Kind -eq ([TeamsTransfer.GraphEventKind]::Throttled)
        $ev.StatusCode | Should -Be 429
        $ev.Delay.TotalSeconds | Should -Be 7
        $ev.Attempt | Should -Be 1
    }
    It 'honours Retry-After given as an HTTP date' {
        $c = New-Ctx
        $date = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('r', [Globalization.CultureInfo]::InvariantCulture)
        $c.Transport.EnqueueJson(503, '{}', $date)
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        $d = (Get-Delays $c)[0]
        $d | Should -BeGreaterThan 27
        $d | Should -BeLessOrEqual 30
    }
    It 'tells the rate limiter about a 429 (rate halves, class paused)' {
        $c = New-Ctx -WithLimiter
        $c.Transport.EnqueueJson(429, '{}', '5')
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        $s = $c.Limiter.Snapshot().Classes | Where-Object EndpointClass -eq 'users'
        $s.Throttled | Should -Be 1
        $s.RatePerSecond | Should -Be 10
        $s.Successes | Should -Be 1
    }
    It 'uses exponential backoff within [BaseBackoff, MaxBackoff] when there is no Retry-After (jitter at its maximum)' {
        $c = New-Ctx { param($o) $o.MaxAttempts = 6 }
        1..5 | ForEach-Object { $c.Transport.EnqueueJson(503, '{}') }
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        Get-Delays $c | Should -Be @(1, 2, 4, 8, 8)
    }
    It 'uses the base backoff when the jitter is at its minimum' {
        $c = New-Ctx { param($o) $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0) }
        1..3 | ForEach-Object { $c.Transport.EnqueueJson(502, '{}') }
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        Get-Delays $c | Should -Be @(1, 1, 1)
    }
    It 'draws every real jittered delay inside the bounds' {
        $c = New-Ctx { param($o) $o.MaxAttempts = 40; $o.Random = [TeamsTransfer.TestFuncs]::Uniform() }
        1..30 | ForEach-Object { $c.Transport.EnqueueJson(504, '{}') }
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) | Out-Null
        $i = 0
        foreach ($d in (Get-Delays $c)) {
            $i++
            $cap = [Math]::Min(8, [Math]::Pow(2, $i - 1))
            $d | Should -BeGreaterOrEqual 1
            $d | Should -BeLessOrEqual $cap
        }
    }
    It 'retries 500, 502, 503, 504 and 429 and then gives up with a GraphException after MaxAttempts' {
        $c = New-Ctx { param($o) $o.MaxAttempts = 3 }
        $c.Transport.EnqueueJson(500, '{}'); $c.Transport.EnqueueJson(502, '{}')
        $c.Transport.EnqueueJson(504, '{"error":{"code":"GatewayTimeout","message":"upstream"}}', $null, 'rid-9')
        $e = Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) }
        $e | Should -BeOfType [TeamsTransfer.GraphException]
        $e.StatusCode | Should -Be 504
        $e.ErrorCode | Should -Be 'GatewayTimeout'
        $e.RequestId | Should -Be 'rid-9'
        $c.Transport.Requests.Count | Should -Be 3
        ($c.Events.Events | Select-Object -Last 1).Kind | Should -Be ([TeamsTransfer.GraphEventKind]::Error)
    }
    It 'does not retry a non-retryable 4xx and parses code, message and request-id' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(404, '{"error":{"code":"ResourceNotFound","message":"Chat not found."}}', $null, 'req-123')
        $e = Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/chats/x/messages?$top=50&$skiptoken=SECRET', $null, $null, $script:ct) }
        $e | Should -BeOfType [TeamsTransfer.GraphException]
        $e.StatusCode | Should -Be 404
        $e.ErrorCode | Should -Be 'ResourceNotFound'
        $e.RequestId | Should -Be 'req-123'
        $e.Message | Should -Match 'Chat not found'
        $e.Url | Should -Be 'v1.0/chats/x/messages'
        $e.Message | Should -Not -Match 'SECRET'
        $c.Transport.Requests.Count | Should -Be 1
        $c.Clock.Delays.Count | Should -Be 0
    }
    It 'falls back to innerError.request-id and to HTTP<status> when the body has no code' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(400, '{"error":{"code":"BadRequest","message":"m","innerError":{"request-id":"inner-1"}}}')
        (Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) }).RequestId | Should -Be 'inner-1'
        $c.Transport.EnqueueJson(403, '<html>Forbidden</html>')
        $e = Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) }
        $e.ErrorCode | Should -Be 'HTTP403'
    }
    It 'retries network errors and timeouts' {
        $c = New-Ctx
        $c.Transport.EnqueueThrow([Net.Http.HttpRequestException]::new('connection reset'))
        $c.Transport.EnqueueThrow([OperationCanceledException]::new('attempt timed out'))
        $c.Transport.EnqueueJson(200, '{"ok":1}')
        $doc = Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct)
        $doc.RootElement.GetProperty('ok').GetInt32() | Should -Be 1
        $c.Transport.Requests.Count | Should -Be 3
        ($c.Events.Events | Where-Object Kind -eq ([TeamsTransfer.GraphEventKind]::Retry)).Count | Should -Be 2
    }
    It 'wraps an exhausted network error in a GraphException with status 0' {
        $c = New-Ctx { param($o) $o.MaxAttempts = 2 }
        1..2 | ForEach-Object { $c.Transport.EnqueueThrow([Net.Http.HttpRequestException]::new('down')) }
        $e = Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $script:ct) }
        $e | Should -BeOfType [TeamsTransfer.GraphException]
        $e.StatusCode | Should -Be 0
        $e.ErrorCode | Should -Be 'NetworkError'
    }
    It 'does not retry when the caller cancels' {
        $c = New-Ctx
        $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
        $e = Get-Thrown { Wait-Task $c.Client.GetJsonAsync('v1.0/users', $Users, $null, $cts.Token) }
        $e | Should -BeOfType [OperationCanceledException]
        $c.Transport.Requests.Count | Should -Be 0
    }
    It 'resends the JSON body unchanged on retry' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(503, '{}', '1')
        $c.Transport.EnqueueJson(200, '{"id":"m1"}')
        Wait-Task $c.Client.PostJsonAsync('v1.0/chats/c/messages', '{"body":{"content":"hi"}}', 'migration.importMessage', 'c', $script:ct) | Out-Null
        $c.Transport.Requests[0].BodyJson | Should -Be '{"body":{"content":"hi"}}'
        $c.Transport.Requests[1].BodyJson | Should -Be '{"body":{"content":"hi"}}'
        $c.Transport.Requests[1].ThreadKey | Should -Be 'c'
    }
    It 'rewinds a seekable body stream before every retry' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(503, '{}', '0')
        $c.Transport.EnqueueJson(200, '{}')
        $ms = [IO.MemoryStream]::new([byte[]](1..100))
        $ms.Position = 10
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'https://x.sharepoint.com/up'; $r.Anonymous = $true
        $r.Method = [Net.Http.HttpMethod]::Put; $r.BodyStream = $ms
        Wait-Task $c.Client.SendJsonAsync($r, $script:ct) | Out-Null
        $c.Transport.BodyStreamPositions | Should -Be @(10, 10)
    }
    It 'does not retry a request whose body stream cannot be replayed' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(503, '{}', '0')
        $c.Transport.EnqueueJson(200, '{}')
        $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'https://x.sharepoint.com/up'; $r.Anonymous = $true
        $r.Method = [Net.Http.HttpMethod]::Put; $r.BodyStream = [IO.Stream]::Null   # seekable, replaced below by a non-seekable one
        $nonSeekable = [IO.Compression.DeflateStream]::new([IO.MemoryStream]::new([byte[]](120, 156, 3, 0, 0, 0, 0, 1)), [IO.Compression.CompressionMode]::Decompress)
        $r.BodyStream = $nonSeekable
        $e = Get-Thrown { Wait-Task $c.Client.SendAsync($r, $script:ct) }
        $e | Should -BeOfType [TeamsTransfer.GraphException]
        $e.StatusCode | Should -Be 503
        $c.Transport.Requests.Count | Should -Be 1
    }
    It 'never puts the query string in an event or the token in anything' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(429, '{}', '1')
        $c.Transport.EnqueueJson(200, '{}')
        Wait-Task $c.Client.GetJsonAsync('v1.0/chats/c/messages?$skiptoken=TOPSECRET&$top=5', $null, $null, $script:ct) | Out-Null
        foreach ($e in $c.Events.Events) {
            $e.Url | Should -Be 'v1.0/chats/c/messages'
            ($e | ConvertTo-Json -Depth 3) | Should -Not -Match 'TOPSECRET'
        }
    }
    It 'SendAsync returns the live response for the caller to read' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, 'raw body')
        $resp = Wait-Task $c.Client.SendAsync([TeamsTransfer.GraphRequest]@{ Url = 'v1.0/x' }, $script:ct)
        (Wait-Task $resp.ReadAsStringAsync()) | Should -Be 'raw body'
    }
}

Describe 'GraphClient - paging' {
    BeforeEach {
        $script:p1 = '{"value":[{"id":"1"},{"id":"2"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/chats?$skiptoken=P2"}'
        $script:p2 = '{"value":[{"id":"3"},{"id":"4"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/chats?$skiptoken=P3"}'
        $script:p3 = '{"value":[{"id":"5"}]}'
    }
    It 'follows @odata.nextLink and yields every element' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, $script:p1); $c.Transport.EnqueueJson(200, $script:p2); $c.Transport.EnqueueJson(200, $script:p3)
        $rec = [TeamsTransfer.LinkRecorder]::new()
        $items = Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/chats', 'chats', $rec.Callback, $null, $null, $script:ct)))
        ($items | ForEach-Object { $_.GetProperty('id').GetString() }) -join ',' | Should -Be '1,2,3,4,5'
        $rec.Links.Count | Should -Be 2
        $c.Transport.Requests[1].Url | Should -Be $rec.Links[0]
        $c.Transport.Requests[2].Url | Should -Be $rec.Links[1]
    }
    It 'yields elements that stay valid after their page is released' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, $script:p3)
        $items = @(Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/chats', 'chats', $null, $null, $null, $script:ct))))
        [GC]::Collect()
        $items[0].GetProperty('id').GetString() | Should -Be '5'
    }
    It 'hands the next link over only after the page was consumed, and resumes from a saved link' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, $script:p1); $c.Transport.EnqueueJson(200, $script:p2)
        $rec = [TeamsTransfer.LinkRecorder]::new()
        # the consumer stops after 3 items: page 1 fully delivered (checkpoint P2 saved), page 2 half read
        $first = Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/chats', 'chats', $rec.Callback, $null, $null, $script:ct), 3))
        $first.Count | Should -Be 3
        $rec.Links.Count | Should -Be 1
        $rec.Links[0] | Should -Match 'skiptoken=P2'

        $c2 = New-Ctx
        $c2.Transport.EnqueueJson(200, $script:p2); $c2.Transport.EnqueueJson(200, $script:p3)
        $rec2 = [TeamsTransfer.LinkRecorder]::new()
        $rest = Wait-Task ([TeamsTransfer.TestAsync]::Collect($c2.Client.GetPagedAsync('ignored', 'chats', $rec2.Callback, $rec.Links[0], $null, $script:ct)))
        ($rest | ForEach-Object { $_.GetProperty('id').GetString() }) -join ',' | Should -Be '3,4,5'
        $c2.Transport.Requests[0].Url | Should -Be $rec.Links[0]
        $c2.Transport.Requests.Count | Should -Be 2
    }
    It 'retries a failing page transparently' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, $script:p1); $c.Transport.EnqueueJson(429, '{}', '2'); $c.Transport.EnqueueJson(200, $script:p3.Replace('"5"', '"9"'))
        $items = @(Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/chats', 'chats', $null, $null, $null, $script:ct))))
        $items.Count | Should -Be 3
        Get-Delays $c | Should -Be @(2)
    }
    It 'handles an empty page and a missing value array' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, '{"value":[]}')
        (Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/chats', 'chats', $null, $null, $null, $script:ct)))).Count | Should -Be 0
    }
    It 'appends model=B to getAllMessages once' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(200, '{"value":[]}'); $c.Transport.EnqueueJson(200, '{"value":[]}')
        Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/users/u/chats/getAllMessages', $null, $null, $null, $null, $script:ct))) | Out-Null
        Wait-Task ([TeamsTransfer.TestAsync]::Collect($c.Client.GetPagedAsync('v1.0/users/u/chats/getAllMessages?model=B&$top=50', $null, $null, $null, $null, $script:ct))) | Out-Null
        $c.Transport.Requests[0].Url | Should -Be 'v1.0/users/u/chats/getAllMessages?model=B'
        $c.Transport.Requests[1].Url | Should -Be 'v1.0/users/u/chats/getAllMessages?model=B&$top=50'
        $c.Transport.Requests[0].EndpointClass | Should -Be 'users.chats.getAllMessages'
    }
}

Describe 'GraphClient - download' {
    BeforeAll { $script:data = [byte[]](1..40) }

    It 'copies the body to the destination stream' {
        $c = New-Ctx
        $c.Transport.EnqueueBytes(200, $script:data)
        $dest = [IO.MemoryStream]::new()
        Wait-Task $c.Client.DownloadToStreamAsync('v1.0/drives/d/items/i/content', $dest, 'drive.content', $null, $script:ct)
        $dest.ToArray() | Should -Be $script:data
        $c.Transport.Requests[0].EndpointClass | Should -Be 'drive.content'
    }
    It 'truncates the destination and restarts after a mid-transfer failure' {
        $c = New-Ctx
        $c.Transport.EnqueueBytes(200, $script:data, 10)     # IOException after 10 bytes
        $c.Transport.EnqueueBytes(200, $script:data)
        $dest = [IO.MemoryStream]::new()
        $dest.Write([byte[]](200, 201, 202), 0, 3)           # something before: must be kept
        Wait-Task $c.Client.DownloadToStreamAsync('v1.0/drives/d/items/i/content', $dest, 'drive.content', $null, $script:ct)
        $dest.ToArray() | Should -Be (@(200, 201, 202) + $script:data)
        $c.Transport.Requests.Count | Should -Be 2
    }
    It 'retries a throttled download' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(429, '{}', '3')
        $c.Transport.EnqueueBytes(200, $script:data)
        $dest = [IO.MemoryStream]::new()
        Wait-Task $c.Client.DownloadToStreamAsync('v1.0/drives/d/items/i/content', $dest, 'drive.content', $null, $script:ct)
        $dest.Length | Should -Be 40
        Get-Delays $c | Should -Be @(3)
    }
    It 'does not retry a partial transfer into a non-seekable destination' {
        $c = New-Ctx
        $c.Transport.EnqueueBytes(200, $script:data, 10)
        $c.Transport.EnqueueBytes(200, $script:data)
        $dest = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new(), [IO.Compression.CompressionMode]::Compress)
        $e = Get-Thrown { Wait-Task $c.Client.DownloadToStreamAsync('v1.0/drives/d/items/i/content', $dest, 'drive.content', $null, $script:ct) }
        $e | Should -BeOfType [TeamsTransfer.GraphException]
        $e.ErrorCode | Should -Be 'NetworkError'
        $c.Transport.Requests.Count | Should -Be 1
    }
    It 'throws the Graph error of a failed download' {
        $c = New-Ctx
        $c.Transport.EnqueueJson(404, '{"error":{"code":"itemNotFound","message":"gone"}}', $null, 'r-1')
        $e = Get-Thrown { Wait-Task $c.Client.DownloadToStreamAsync('v1.0/drives/d/items/i/content', [IO.MemoryStream]::new(), 'drive.content', $null, $script:ct) }
        $e.ErrorCode | Should -Be 'itemNotFound'
        $e.RequestId | Should -Be 'r-1'
    }
}

Describe 'GraphClient - $batch' {
    BeforeEach {
        $script:resp = [TeamsTransfer.BatchResponder]::new()
    }
    It 'splits 45 items into batches of 20, 20 and 5 and keeps the input order' {
        $c = New-Ctx
        $c.Transport.DefaultHandler = $script:resp.Handler
        $res = Wait-Task $c.Client.BatchAsync((New-Items 45), $script:ct)
        $res.Count | Should -Be 45
        $script:resp.BatchSizes | Should -Be @(20, 20, 5)
        ($res | ForEach-Object Id) -join ',' | Should -Be ((1..45 | ForEach-Object { "i$_" }) -join ',')
        ($res | Where-Object { -not $_.IsSuccess }).Count | Should -Be 0
        $c.Transport.Requests[0].Url | Should -Be 'v1.0/$batch'
        $c.Transport.Requests[0].EndpointClass | Should -Be '$batch'
    }
    It 'resends only the individually throttled item, after its Retry-After' {
        $c = New-Ctx
        $c.Transport.DefaultHandler = $script:resp.Handler
        $script:resp.Plan('i2', '429:4')
        $res = Wait-Task $c.Client.BatchAsync((New-Items 3), $script:ct)
        $res[1].StatusCode | Should -Be 200
        $res[1].Attempts | Should -Be 2
        $res[0].Attempts | Should -Be 1
        $script:resp.BatchSizes | Should -Be @(3, 1)
        $script:resp.BatchIds[1] | Should -Be @('i2')
        Get-Delays $c | Should -Be @(4)
        (($res[1].ParseBody()).RootElement.GetProperty('id').GetString()) | Should -Be 'i2'
    }
    It 'waits for the longest Retry-After among throttled items and tells the limiter' {
        $c = New-Ctx -WithLimiter
        $c.Transport.DefaultHandler = $script:resp.Handler
        $script:resp.Plan('i1', '429:2'); $script:resp.Plan('i3', '503:9')
        $res = Wait-Task $c.Client.BatchAsync((New-Items 3), $script:ct)
        ($res | Where-Object { -not $_.IsSuccess }).Count | Should -Be 0
        $script:resp.BatchSizes | Should -Be @(3, 2)
        Get-Delays $c | Should -Contain 9
        ($c.Limiter.Snapshot().Classes | Where-Object EndpointClass -eq 'users').Throttled | Should -Be 2
    }
    It 'reports an item still throttled after MaxAttempts instead of throwing' {
        $c = New-Ctx { param($o) $o.MaxAttempts = 3 }
        $c.Transport.DefaultHandler = $script:resp.Handler
        $script:resp.Plan('i1', '429:1', '429:1', '429:1', '429:1')
        $res = Wait-Task $c.Client.BatchAsync((New-Items 2), $script:ct)
        $res[0].StatusCode | Should -Be 429
        $res[0].Attempts | Should -Be 3
        $res[0].ErrorCode | Should -Be 'E429'
        $res[1].IsSuccess | Should -BeTrue
        $script:resp.BatchSizes.Count | Should -Be 3
    }
    It 'does not retry a 404 item and exposes its error' {
        $c = New-Ctx
        $c.Transport.DefaultHandler = $script:resp.Handler
        $script:resp.Plan('i1', '404')
        $res = Wait-Task $c.Client.BatchAsync((New-Items 1), $script:ct)
        $res[0].StatusCode | Should -Be 404
        $res[0].ErrorCode | Should -Be 'E404'
        $res[0].ErrorMessage | Should -Be 'item failed'
        $script:resp.BatchSizes.Count | Should -Be 1
    }
    It 'serialises method, url, headers and JSON body of an item' {
        $c = New-Ctx
        $c.Transport.DefaultHandler = $script:resp.Handler
        $item = [TeamsTransfer.BatchItem]@{ Id = 'p'; Method = 'POST'; Url = '/chats'; BodyJson = '{"chatType":"group"}' }
        $item.Headers['ConsistencyLevel'] = 'eventual'
        $list = [Collections.Generic.List[TeamsTransfer.BatchItem]]::new(); $list.Add($item)
        Wait-Task $c.Client.BatchAsync($list, $script:ct) | Out-Null
        $sent = ($c.Transport.Requests[0].BodyJson | ConvertFrom-Json).requests[0]
        $sent.id | Should -Be 'p'
        $sent.method | Should -Be 'POST'
        $sent.url | Should -Be '/chats'
        $sent.body.chatType | Should -Be 'group'
        $sent.headers.'Content-Type' | Should -Be 'application/json'
        $sent.headers.ConsistencyLevel | Should -Be 'eventual'
    }
    It 'rejects duplicate or missing ids' {
        $c = New-Ctx
        $list = [Collections.Generic.List[TeamsTransfer.BatchItem]]::new()
        $list.Add([TeamsTransfer.BatchItem]@{ Id = 'a'; Url = '/x' }); $list.Add([TeamsTransfer.BatchItem]@{ Id = 'a'; Url = '/y' })
        (Get-Thrown { Wait-Task $c.Client.BatchAsync($list, $script:ct) }) | Should -BeOfType [ArgumentException]
    }
}

Describe 'GraphClient.Classify' {
    It 'maps <Url> to <Expected>' -ForEach @(
        @{ Url = 'v1.0/users?$top=100'; Expected = 'users' }
        @{ Url = 'v1.0/users/abc'; Expected = 'users' }
        @{ Url = 'https://graph.microsoft.com/v1.0/users/abc/chats?$expand=members'; Expected = 'users.chats' }
        @{ Url = 'beta/users/abc/chats/getAllMessages?model=B'; Expected = 'users.chats.getAllMessages' }
        @{ Url = 'v1.0/chats/getAllMessages'; Expected = 'users.chats.getAllMessages' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2'; Expected = 'chats' }
        @{ Url = 'v1.0/chats'; Expected = 'chats' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2/members'; Expected = 'chats.members' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2/messages?$top=50'; Expected = 'chats.messages' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2/messages/1616990032035'; Expected = 'chats.messages' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2/messages/1616990032035/hostedContents'; Expected = 'hostedContents' }
        @{ Url = 'v1.0/chats/19:abc@thread.v2/messages/1616990032035/hostedContents/aWQ9/$value'; Expected = 'hostedContents' }
        @{ Url = 'v1.0/teams'; Expected = 'teams' }
        @{ Url = 'v1.0/teams/t1'; Expected = 'teams' }
        @{ Url = 'v1.0/teams/t1/members'; Expected = 'teams' }
        @{ Url = 'v1.0/teams/t1/channels'; Expected = 'teams.channels' }
        @{ Url = 'v1.0/teams/t1/channels/19:c@thread.tacv2'; Expected = 'teams.channels' }
        @{ Url = 'v1.0/teams/t1/channels/19:c@thread.tacv2/members'; Expected = 'teams.channels.members' }
        @{ Url = 'v1.0/teams/t1/channels/getAllMessages?model=B'; Expected = 'teams.channels.getAllMessages' }
        @{ Url = 'v1.0/teams/getAllMessages?model=B'; Expected = 'teams.channels.getAllMessages' }
        @{ Url = 'v1.0/teams/t1/channels/c1/messages'; Expected = 'teams.channels.messages' }
        @{ Url = 'v1.0/teams/t1/channels/c1/messages/m1'; Expected = 'teams.channels.messages' }
        @{ Url = 'v1.0/teams/t1/channels/c1/messages/m1/replies'; Expected = 'teams.channels.messages.replies' }
        @{ Url = 'v1.0/teams/t1/channels/c1/messages/m1/replies/r1'; Expected = 'teams.channels.messages.replies' }
        @{ Url = 'v1.0/teams/t1/channels/c1/messages/m1/hostedContents/h1/$value'; Expected = 'hostedContents' }
        @{ Url = 'v1.0/drives/d1/items/i1'; Expected = 'drive.items' }
        @{ Url = 'v1.0/drives/d1/items/i1/content'; Expected = 'drive.content' }
        @{ Url = 'v1.0/shares/u!aHR0cHM/driveItem'; Expected = 'drive.items' }
        @{ Url = 'v1.0/shares/u!aHR0cHM/driveItem/content'; Expected = 'drive.content' }
        @{ Url = 'v1.0/users/u1/drive/root:/Microsoft Teams Chat Files/a.docx:/content'; Expected = 'drive.content' }
        @{ Url = 'v1.0/drives/d1/items/i1/createUploadSession'; Expected = 'drive.upload' }
        @{ Url = 'v1.0/chats/c1/startMigration'; Expected = 'migration.start' }
        @{ Url = 'v1.0/chats/c1/completeMigration'; Expected = 'migration.complete' }
        @{ Url = 'v1.0/teams/t1/channels/c1/completeMigration'; Expected = 'migration.complete' }
        @{ Url = 'v1.0/$batch'; Expected = '$batch' }
        @{ Url = 'https://graph.microsoft.us/v1.0/chats/c1/messages?$top=5'; Expected = 'chats.messages' }
        @{ Url = 'https://graph.microsoft.com/beta/teams/t1/channels'; Expected = 'teams.channels' }
        @{ Url = '/v1.0/organization'; Expected = 'other' }
        @{ Url = ''; Expected = 'other' }
    ) {
        [TeamsTransfer.GraphClient]::Classify($Url) | Should -Be $Expected
    }
}

Describe 'HttpGraphTransport - refresh once on 401' {
    BeforeEach {
        $script:th = [TeamsTransfer.StubHttpHandler]::new()      # token endpoint
        $script:th.Enqueue(200, '{"expires_in":3600,"access_token":"AT-1"}')
        $script:th.Enqueue(200, '{"expires_in":3600,"access_token":"AT-2"}')
        $script:prov = [TeamsTransfer.ClientSecretTokenProvider]::new('t', 'c', 'sec', [TeamsTransfer.GraphCloud]::Global,
            [Net.Http.HttpClient]::new($script:th), [TeamsTransfer.TestManualClock]::new())
        $script:gh = [TeamsTransfer.StubHttpHandler]::new()      # Graph
        $script:gh.DefaultOkBody = '{}'
        $script:gt = [TeamsTransfer.HttpGraphTransport]::new($script:prov, [TeamsTransfer.GraphCloud]::Global, 8, $script:gh)
        function script:New-Req { $r = [TeamsTransfer.GraphRequest]::new(); $r.Url = 'v1.0/users'; $r }
    }
    It 'refreshes the token and resends once after a 401' {
        $script:gh.RejectToken = 'AT-1'
        $script:gh.Enqueue(200, '{"ok":1}')
        $resp = Wait-Task $script:gt.SendAsync((New-Req), $script:ct)
        $resp.StatusCode | Should -Be 200
        $script:gh.Requests.Count | Should -Be 2
        $script:gh.Requests[0].Authorization | Should -Be 'Bearer AT-1'
        $script:gh.Requests[1].Authorization | Should -Be 'Bearer AT-2'
        $script:th.Requests.Count | Should -Be 2
    }
    It 'resends a JSON body unchanged' {
        $script:gh.RejectToken = 'AT-1'
        $script:gh.Enqueue(200, '{}')
        $r = New-Req; $r.Method = [Net.Http.HttpMethod]::Post; $r.BodyJson = '{"a":1}'
        Wait-Task $script:gt.SendAsync($r, $script:ct) | Out-Null
        $script:gh.Requests[1].Body | Should -Be '{"a":1}'
    }
    It 'surfaces a second 401 as is, after a single resend' {
        $script:gh.RejectToken = '*'
        $resp = Wait-Task $script:gt.SendAsync((New-Req), $script:ct)
        $resp.StatusCode | Should -Be 401
        $script:gh.Requests.Count | Should -Be 2
        $script:th.Requests.Count | Should -Be 2
    }
    It 'does not retry a 401 on an anonymous request' {
        $script:gh.RejectToken = '*'
        $r = New-Req; $r.Anonymous = $true
        (Wait-Task $script:gt.SendAsync($r, $script:ct)).StatusCode | Should -Be 200
        $script:th.Requests.Count | Should -Be 0
    }
    It 'does not resend a non-seekable body' {
        $script:gh.RejectToken = '*'
        $r = New-Req; $r.Method = [Net.Http.HttpMethod]::Put
        $r.BodyStream = [IO.Compression.DeflateStream]::new([IO.MemoryStream]::new([byte[]](3, 0)), [IO.Compression.CompressionMode]::Decompress)
        (Wait-Task $script:gt.SendAsync($r, $script:ct)).StatusCode | Should -Be 401
        $script:gh.Requests.Count | Should -Be 1
    }
    It 'triggers one token refresh for 20 parallel 401s' {
        Wait-Task $script:prov.GetTokenAsync($script:ct) | Out-Null     # everybody holds AT-1
        $script:gh.RejectToken = 'AT-1'
        $st = Wait-Task ([TeamsTransfer.TestAsync]::ParallelStatuses($script:gt, "v1.0/users", 20))
        ($st | Sort-Object -Unique) | Should -Be 200
        $script:th.Requests.Count | Should -Be 2
    }
}
