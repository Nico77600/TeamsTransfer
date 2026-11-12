#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Auth.cs: JWT client assertion, token cache/refresh, error handling without leaking secrets.

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
    function New-TestCert {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=TeamsTransfer-Test', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    }
    function ConvertFrom-B64Url([string]$s) {
        $s = $s.Replace('-', '+').Replace('_', '/')
        switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
        [Convert]::FromBase64String($s)
    }
    function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    function New-Http($handler) { [Net.Http.HttpClient]::new($handler) }
    $script:cert = New-TestCert
}

Describe 'CertificateTokenProvider - client assertion' {
    BeforeAll {
        $script:clock = [TeamsTransfer.TestManualClock]::new()
        $script:p = [TeamsTransfer.CertificateTokenProvider]::new('contoso.onmicrosoft.com', '11111111-2222-3333-4444-555555555555', $script:cert,
            [TeamsTransfer.GraphCloud]::Global, $null, $script:clock)
        $script:jwt = $script:p.BuildClientAssertion()
        $script:parts = $script:jwt.Split('.')
        $script:header = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $script:parts[0])) | ConvertFrom-Json
        $script:payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $script:parts[1])) | ConvertFrom-Json
    }

    It 'has three base64url parts without padding' {
        $script:parts.Count | Should -Be 3
        $script:jwt | Should -Not -Match '[=+/]'
    }
    It 'declares RS256 and both certificate thumbprint headers' {
        $script:header.alg | Should -Be 'RS256'
        $script:header.typ | Should -Be 'JWT'
        $sha1 = [Security.Cryptography.SHA1]::HashData($script:cert.RawData)
        $sha256 = [Security.Cryptography.SHA256]::HashData($script:cert.RawData)
        $script:header.x5t | Should -Be (ConvertTo-B64Url $sha1)
        $script:header.'x5t#S256' | Should -Be (ConvertTo-B64Url $sha256)
    }
    It 'sets aud, iss, sub, jti, nbf and a 10 minute exp' {
        $script:payload.aud | Should -Be 'https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token'
        $script:payload.iss | Should -Be '11111111-2222-3333-4444-555555555555'
        $script:payload.sub | Should -Be '11111111-2222-3333-4444-555555555555'
        { [guid]::Parse($script:payload.jti) } | Should -Not -Throw
        $script:payload.nbf | Should -Be $script:clock.UtcNow.ToUnixTimeSeconds()
        ($script:payload.exp - $script:payload.nbf) | Should -Be 600
    }
    It 'uses a new jti for every assertion' {
        $other = ([Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $script:p.BuildClientAssertion().Split('.')[1])) | ConvertFrom-Json).jti
        $other | Should -Not -Be $script:payload.jti
    }
    It 'carries a signature verifiable with the certificate public key' {
        $data = [Text.Encoding]::ASCII.GetBytes($script:parts[0] + '.' + $script:parts[1])
        $sig = ConvertFrom-B64Url $script:parts[2]
        $pub = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:cert)
        $pub.VerifyData($data, $sig, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) | Should -BeTrue
        # tampering breaks it
        $bad = [Text.Encoding]::ASCII.GetBytes($script:parts[0] + '.' + $script:parts[1] + 'x')
        $pub.VerifyData($bad, $sig, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) | Should -BeFalse
    }
    It 'rejects a certificate without private key' {
        $pubOnly = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:cert.RawData)
        { [TeamsTransfer.CertificateTokenProvider]::new('t', 'c', $pubOnly) } | Should -Throw '*private key*'
    }
    It 'FindCertificate fails clearly for an unknown thumbprint' {
        $e = Get-Thrown { [TeamsTransfer.CertificateTokenProvider]::FindCertificate('00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01') }
        $e | Should -BeOfType [InvalidOperationException]
        $e.Message | Should -Match 'not found'
    }
}

Describe 'Token endpoint call, cache and refresh' {
    BeforeEach {
        $script:clock = [TeamsTransfer.TestManualClock]::new()
        $script:handler = [TeamsTransfer.StubHttpHandler]::new()
        $script:p = [TeamsTransfer.CertificateTokenProvider]::new('tenant-1', 'client-1', $script:cert,
            [TeamsTransfer.GraphCloud]::Global, (New-Http $script:handler), $script:clock)
    }

    It 'posts the client-credentials form to the tenant token endpoint with the .default scope' {
        $script:handler.Enqueue(200, '{"token_type":"Bearer","expires_in":3599,"access_token":"AT-1"}')
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-1'
        $r = $script:handler.Requests[0]
        $r.Method | Should -Be 'POST'
        $r.Uri | Should -Be 'https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token'
        $form = [Web.HttpUtility]::ParseQueryString($r.Body)
        $form['grant_type'] | Should -Be 'client_credentials'
        $form['client_id'] | Should -Be 'client-1'
        $form['scope'] | Should -Be 'https://graph.microsoft.com/.default'
        $form['client_assertion_type'] | Should -Be 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $form['client_assertion'].Split('.').Count | Should -Be 3
    }
    It 'uses the sovereign authority and Graph root for a US Government tenant' {
        $h = [TeamsTransfer.StubHttpHandler]::new()
        $h.Enqueue(200, '{"expires_in":3600,"access_token":"AT"}')
        $gov = [TeamsTransfer.CertificateTokenProvider]::new('t', 'c', $script:cert, [TeamsTransfer.GraphCloud]::USGov, (New-Http $h), $script:clock)
        Wait-Task $gov.GetTokenAsync($script:ct) | Out-Null
        $h.Requests[0].Uri | Should -Be 'https://login.microsoftonline.us/t/oauth2/v2.0/token'
        ([Web.HttpUtility]::ParseQueryString($h.Requests[0].Body))['scope'] | Should -Be 'https://graph.microsoft.us/.default'
    }
    It 'serves the token from the cache until 5 minutes before expiry, then refreshes' {
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-1"}')
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-2"}')
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-1'
        $script:clock.Advance([TimeSpan]::FromMinutes(54))
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-1'
        $script:handler.Requests.Count | Should -Be 1
        $script:clock.Advance([TimeSpan]::FromMinutes(2))      # 56 min: inside the 5 min margin
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-2'
        $script:handler.Requests.Count | Should -Be 2
    }
    It 'accepts expires_in sent as a string' {
        $script:handler.Enqueue(200, '{"expires_in":"3600","access_token":"AT-S"}')
        Wait-Task $script:p.GetTokenAsync($script:ct) | Out-Null
        $script:clock.Advance([TimeSpan]::FromMinutes(30))
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-S'
        $script:handler.Requests.Count | Should -Be 1
    }
    It 'does a single refresh when many callers ask at once' {
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-1"}')
        $tasks = 1..20 | ForEach-Object { $script:p.GetTokenAsync($script:ct) }
        [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
        ($tasks | ForEach-Object { $_.Result } | Sort-Object -Unique) | Should -Be 'AT-1'
        $script:handler.Requests.Count | Should -Be 1
    }
    It 'retries a transient 503 on the token endpoint' {
        $script:handler.Enqueue(503, '{"error":"temporarily_unavailable"}')
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-R"}')
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-R'
        $script:handler.Requests.Count | Should -Be 2
        $script:clock.Delays.Count | Should -Be 1
    }
    It 'raises AuthException with the AAD error code and no assertion in the message' {
        $script:handler.Enqueue(401, '{"error":"invalid_client","error_description":"AADSTS700027: Client assertion contains an invalid signature.\r\nTrace ID: x"}')
        $e = Get-Thrown { Wait-Task $script:p.GetTokenAsync($script:ct) }
        $e | Should -BeOfType [TeamsTransfer.AuthException]
        $e.ErrorCode | Should -Be 'invalid_client'
        $e.StatusCode | Should -Be 401
        $e.Message | Should -Match 'AADSTS700027'
        $e.Message | Should -Not -Match 'Trace ID'
        $e.Message | Should -Not -Match 'eyJ'
        $script:handler.Requests.Count | Should -Be 1        # 401 is not retried
    }
    It 'does not echo an unparsable answer (it could contain a token)' {
        $script:handler.Enqueue(200, 'not json AT-SECRET-TOKEN')
        $e = Get-Thrown { Wait-Task $script:p.GetTokenAsync($script:ct) }
        $e | Should -BeOfType [TeamsTransfer.AuthException]
        $e.Message | Should -Not -Match 'AT-SECRET-TOKEN'
    }
    It 'Invalidate forces a new request' {
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-1"}')
        $script:handler.Enqueue(200, '{"expires_in":3600,"access_token":"AT-2"}')
        Wait-Task $script:p.GetTokenAsync($script:ct) | Out-Null
        $script:p.Invalidate()
        (Wait-Task $script:p.GetTokenAsync($script:ct)) | Should -Be 'AT-2'
    }
}

Describe 'ClientSecretTokenProvider (lab only)' {
    It 'sends client_secret and never leaks it in an error' {
        $clock = [TeamsTransfer.TestManualClock]::new()
        $h = [TeamsTransfer.StubHttpHandler]::new()
        $secret = ConvertTo-SecureString 'S3cr3t-Value-123' -AsPlainText -Force
        $p = [TeamsTransfer.ClientSecretTokenProvider]::new('tenant-1', 'client-1', $secret, [TeamsTransfer.GraphCloud]::Global, (New-Http $h), $clock)
        $h.Enqueue(200, '{"expires_in":3600,"access_token":"AT-1"}')
        Wait-Task $p.GetTokenAsync($script:ct) | Out-Null
        $form = [Web.HttpUtility]::ParseQueryString($h.Requests[0].Body)
        $form['client_secret'] | Should -Be 'S3cr3t-Value-123'
        $form['client_assertion'] | Should -BeNullOrEmpty

        $p.Invalidate()
        $h.Enqueue(401, '{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided."}')
        $e = Get-Thrown { Wait-Task $p.GetTokenAsync($script:ct) }
        $e.Message | Should -Not -Match 'S3cr3t-Value-123'
        $p.ToString() | Should -Not -Match 'S3cr3t'
    }
    It 'accepts a plain string secret' {
        $h = [TeamsTransfer.StubHttpHandler]::new()
        $h.Enqueue(200, '{"expires_in":3600,"access_token":"AT"}')
        $p = [TeamsTransfer.ClientSecretTokenProvider]::new('t', 'c', 'plain-secret', [TeamsTransfer.GraphCloud]::Global, (New-Http $h), [TeamsTransfer.TestManualClock]::new())
        Wait-Task $p.GetTokenAsync($script:ct) | Out-Null
        ([Web.HttpUtility]::ParseQueryString($h.Requests[0].Body))['client_secret'] | Should -Be 'plain-secret'
    }
}
