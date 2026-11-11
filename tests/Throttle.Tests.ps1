#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Throttle.cs on virtual time (TestManualClock): AIMD, pause, pacing, per-thread 5 rps, eviction, gate.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None

    function Wait-Task($t) { $t.GetAwaiter().GetResult() }
    function New-Limiter([scriptblock]$Configure = $null) {
        $clock = [TeamsTransfer.TestManualClock]::new()
        $o = [TeamsTransfer.RateLimiterOptions]::new()
        $o.Clock = $clock
        if ($Configure) { & $Configure $o }
        [pscustomobject]@{ Clock = $clock; Limiter = [TeamsTransfer.AdaptiveRateLimiter]::new($o); Options = $o }
    }
    function Get-Rate($limiter, [string]$cls) {
        ($limiter.Snapshot().Classes | Where-Object EndpointClass -eq $cls).RatePerSecond
    }
    function Invoke-Acquire($ctx, [string]$cls, [string]$threadKey = $null) {
        (Wait-Task $ctx.Limiter.AcquireAsync($cls, $threadKey, $script:ct)).Dispose()
    }
    $script:Users = [TeamsTransfer.EndpointClass]::Users
    $script:Import = [TeamsTransfer.EndpointClass]::ImportMessage
}

Describe 'AIMD' {
    It 'halves the rate on a throttle, once per pause window' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 20 }
        Invoke-Acquire $c $Users
        Get-Rate $c.Limiter $Users | Should -Be 20
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(2))
        Get-Rate $c.Limiter $Users | Should -Be 10
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(2))      # same pause window: no second halving
        Get-Rate $c.Limiter $Users | Should -Be 10
        $c.Clock.Advance([TimeSpan]::FromSeconds(3))
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(1))
        Get-Rate $c.Limiter $Users | Should -Be 5
    }
    It 'never goes below the floor of 0.5 rps' {
        $c = New-Limiter
        Invoke-Acquire $c $Users
        1..20 | ForEach-Object { $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(1)); $c.Clock.Advance([TimeSpan]::FromSeconds(2)) }
        Get-Rate $c.Limiter $Users | Should -Be 0.5
    }
    It 'pauses the class for the Retry-After delay and reports it in the snapshot' {
        $c = New-Limiter
        Invoke-Acquire $c $Users
        $t0 = $c.Clock.UtcNow
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(30))
        $s = $c.Limiter.Snapshot().Classes | Where-Object EndpointClass -eq $Users
        $s.PausedUntil | Should -Be $t0.AddSeconds(30)
        $s.Throttled | Should -Be 1
        Invoke-Acquire $c $Users
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeGreaterOrEqual 30
        ($c.Limiter.Snapshot().Classes | Where-Object EndpointClass -eq $Users).PausedUntil | Should -BeNullOrEmpty
    }
    It 'applies the default pause when Retry-After is absent' {
        $c = New-Limiter
        $c.Limiter.OnThrottled($Users, $null)
        $t0 = $c.Clock.UtcNow
        Invoke-Acquire $c $Users
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeGreaterOrEqual 1
    }
    It 'does not slow other classes down' {
        $c = New-Limiter
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(60))
        $t0 = $c.Clock.UtcNow
        Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::Teams)
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -Be 0
        Get-Rate $c.Limiter ([TeamsTransfer.EndpointClass]::Teams) | Should -Be 20
    }
    It 'adds 1 rps after N consecutive successes, up to the ceiling' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 10; $o.SuccessesBeforeIncrease = 50; $o.MaxRatePerSecond = 12 }
        Invoke-Acquire $c $Users
        1..49 | ForEach-Object { $c.Limiter.OnSuccess($Users) }
        Get-Rate $c.Limiter $Users | Should -Be 10
        $c.Limiter.OnSuccess($Users)
        Get-Rate $c.Limiter $Users | Should -Be 11
        1..500 | ForEach-Object { $c.Limiter.OnSuccess($Users) }
        Get-Rate $c.Limiter $Users | Should -Be 12
    }
    It 'resets the success streak on a throttle' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 10; $o.SuccessesBeforeIncrease = 5 }
        1..4 | ForEach-Object { $c.Limiter.OnSuccess($Users) }
        $c.Limiter.OnThrottled($Users, [TimeSpan]::Zero)      # 10 -> 5
        $c.Limiter.OnSuccess($Users)
        Get-Rate $c.Limiter $Users | Should -Be 5            # streak restarted: 1 success is not enough
        1..4 | ForEach-Object { $c.Limiter.OnSuccess($Users) }
        Get-Rate $c.Limiter $Users | Should -Be 6
    }
    It 'recovers after a halving: 50 successes per step' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 20 }
        $c.Limiter.OnThrottled($Users, [TimeSpan]::Zero)
        Get-Rate $c.Limiter $Users | Should -Be 10
        1..100 | ForEach-Object { $c.Limiter.OnSuccess($Users) }
        Get-Rate $c.Limiter $Users | Should -Be 12
    }
}

Describe 'Pacing' {
    It 'spaces requests of a class at its rate' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 10 }
        $t0 = $c.Clock.UtcNow
        1..11 | ForEach-Object { Invoke-Acquire $c $Users }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -Be 1.0
    }
    It 'honours a per-class initial rate' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 100; $o.InitialRateByClass[[TeamsTransfer.EndpointClass]::Teams] = 2 }
        Get-Rate $c.Limiter $Users | Should -Be $null     # not created yet
        Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::Teams)
        Get-Rate $c.Limiter ([TeamsTransfer.EndpointClass]::Teams) | Should -Be 2
    }
}

Describe 'Per-thread limit (Teams import: 5 rps per conversation)' {
    It 'limits one conversation to 5 rps even when the class rate is much higher' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 200 }
        $t0 = $c.Clock.UtcNow
        1..11 | ForEach-Object { Invoke-Acquire $c $Import 'chat-A' }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeGreaterOrEqual 1.99
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeLessThan 2.1
    }
    It 'lets different conversations proceed in parallel' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 200 }
        $t0 = $c.Clock.UtcNow
        1..6 | ForEach-Object { Invoke-Acquire $c $Import 'chat-A'; Invoke-Acquire $c $Import 'chat-B' }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeLessThan 1.1      # 6 each at 5 rps = 1 s, not 2.4 s
    }
    It 'is not applied without a ThreadKey' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 200 }
        $t0 = $c.Clock.UtcNow
        1..11 | ForEach-Object { Invoke-Acquire $c $Import }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeLessThan 0.1
    }
    It 'is not applied to classes outside the configured set' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 200 }
        $t0 = $c.Clock.UtcNow
        1..11 | ForEach-Object { Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::ChatMessages) 'chat-A' }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeLessThan 0.1
        $c.Limiter.Snapshot().ThreadBuckets | Should -Be 0
    }
    It 'applies to channel replies by default and to a class added to the set' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 200; $o.PerThreadClasses.Add([TeamsTransfer.EndpointClass]::ChatMessages) | Out-Null }
        $t0 = $c.Clock.UtcNow
        1..6 | ForEach-Object { Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::ChannelReplies) 'team/chan' }
        ($c.Clock.UtcNow - $t0).TotalSeconds | Should -BeGreaterOrEqual 0.99
        $t1 = $c.Clock.UtcNow
        1..6 | ForEach-Object { Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::ChatMessages) 'chat-Z' }
        ($c.Clock.UtcNow - $t1).TotalSeconds | Should -BeGreaterOrEqual 0.99
    }
    It 'evicts idle thread buckets so memory stays bounded' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 1000; $o.MaxRatePerSecond = 1000 }
        1..1000 | ForEach-Object { Invoke-Acquire $c $Import "chat-$_" }
        $c.Limiter.Snapshot().ThreadBuckets | Should -Be 1000
        $c.Clock.Advance([TimeSpan]::FromMinutes(5))
        Invoke-Acquire $c $Import 'chat-new'                   # the periodic sweep runs inside Acquire
        $c.Limiter.Snapshot().ThreadBuckets | Should -Be 1
    }
    It 'EvictIdleThreadBuckets keeps recently used buckets' {
        $c = New-Limiter { param($o) $o.InitialRatePerSecond = 1000; $o.MaxRatePerSecond = 1000 }
        Invoke-Acquire $c $Import 'old'
        $c.Clock.Advance([TimeSpan]::FromMinutes(5))
        Invoke-Acquire $c $Import 'fresh'
        $c.Limiter.EvictIdleThreadBuckets() | Should -BeLessOrEqual 1
        $c.Limiter.Snapshot().ThreadBuckets | Should -Be 1
    }
}

Describe 'Concurrency gate' {
    It 'blocks the request beyond MaxConcurrency until a lease is released' {
        $c = New-Limiter { param($o) $o.MaxConcurrency = 2 }
        $l1 = Wait-Task $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $l2 = Wait-Task $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $c.Limiter.Snapshot().InFlight | Should -Be 2
        $t3 = $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $t3.Wait(100) | Should -BeFalse
        $l1.Dispose()
        $t3.Wait(2000) | Should -BeTrue
        $c.Limiter.Snapshot().InFlight | Should -Be 2
        $l2.Dispose(); $t3.Result.Dispose()
        $c.Limiter.Snapshot().InFlight | Should -Be 0
    }
    It 'releases the slot only once when a lease is disposed twice' {
        $c = New-Limiter { param($o) $o.MaxConcurrency = 1 }
        $l1 = Wait-Task $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $l1.Dispose(); $l1.Dispose()
        $l2 = Wait-Task $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $t3 = $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $t3.Wait(100) | Should -BeFalse
        $l2.Dispose(); $t3.Wait(2000) | Should -BeTrue
        $t3.Result.Dispose()
    }
    It 'honours cancellation while waiting' {
        $c = New-Limiter { param($o) $o.MaxConcurrency = 1 }
        $l1 = Wait-Task $c.Limiter.AcquireAsync($Users, $null, $script:ct)
        $cts = [Threading.CancellationTokenSource]::new()
        $t = $c.Limiter.AcquireAsync($Users, $null, $cts.Token)
        $cts.Cancel()
        { $t.GetAwaiter().GetResult() } | Should -Throw
        $t.IsCanceled | Should -BeTrue
        $l1.Dispose()
    }
    It 'rejects an already cancelled token' {
        $c = New-Limiter
        $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
        { Wait-Task $c.Limiter.AcquireAsync($Users, $null, $cts.Token) } | Should -Throw
    }
}

Describe 'Snapshot' {
    It 'reports rate, requests, successes and throttles per class, sorted' {
        $c = New-Limiter
        Invoke-Acquire $c ([TeamsTransfer.EndpointClass]::Teams)
        Invoke-Acquire $c $Users; Invoke-Acquire $c $Users
        $c.Limiter.OnSuccess($Users)
        $c.Limiter.OnThrottled($Users, [TimeSpan]::FromSeconds(5))
        $s = $c.Limiter.Snapshot()
        $s.Classes.Count | Should -Be 2
        $s.Classes[0].EndpointClass | Should -Be 'teams'
        $u = $s.Classes | Where-Object EndpointClass -eq $Users
        $u.Requests | Should -Be 2
        $u.Successes | Should -Be 1
        $u.Throttled | Should -Be 1
        $u.RatePerSecond | Should -Be 10
        $s.MaxConcurrency | Should -Be 32
    }
}
