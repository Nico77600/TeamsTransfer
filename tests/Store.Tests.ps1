#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Store.cs (TmtStore): messages (dedup, versions, ordering, filters), content-addressed blobs,
# concurrency, crash safety, refusal rules, catalog tables of the exporter contract.
# The 'Volume' test (>= 2,000,000 messages from SyntheticTenant) is skipped unless TMT_VOLUME=1:
#   $env:TMT_VOLUME = '1'; Invoke-Pester -Path tests\Store.Tests.ps1 -TagFilter Volume

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    if (-not ('TmtGenStream' -as [type])) {
        # Pure BCL helper (not part of the engine): a deterministic stream of N bytes that tracks the process working set while it is read.
        Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class TmtGenStream : Stream
{
    long _len, _pos, _next; ulong _x = 88172645463325252UL;
    public long MaxWorkingSet;
    public TmtGenStream(long length) { _len = length; }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { return _len; } }
    public override long Position { get { return _pos; } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count)
    {
        long left = _len - _pos; if (left <= 0) return 0;
        int n = (int)Math.Min(count, left);
        for (int i = 0; i < n; i++) { _x ^= _x << 13; _x ^= _x >> 7; _x ^= _x << 17; buffer[offset + i] = (byte)_x; }
        _pos += n;
        if (_pos >= _next) { _next = _pos + (8 << 20); long ws = Environment.WorkingSet; if (ws > MaxWorkingSet) MaxWorkingSet = ws; }
        return n;
    }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
'@
    }
    $script:TempRoot = Join-Path $env:TEMP ('tmt-store-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:PackageRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'package'
    $script:ModulePath = Join-Path $script:PackageRoot 'TeamsTransfer.psm1'

    function New-Root { Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    function New-Opts([int]$Partitions = 8) {
        $o = [TeamsTransfer.StoreOptions]::new(); $o.Partitions = $Partitions; $o.FlushIntervalMs = 0; $o
    }
    function New-Msg([string]$Id, [string]$Created, [string]$Lm = $null, [string]$Body = 'hello', [string]$Reply = $null, [string]$Etag = $null, [string]$From = $null, [switch]$Deleted) {
        $o = [ordered]@{ id = $Id; createdDateTime = $Created }
        if ($Reply) { $o.replyToId = $Reply }
        if ($Lm) { $o.lastModifiedDateTime = $Lm }
        if ($Etag) { $o.etag = $Etag }
        if ($From) { $o.from = @{ user = @{ id = $From; displayName = "User $From"; userIdentityType = 'aadUser' } } }
        if ($Deleted) { $o.deletedDateTime = $Lm }
        $o.body = @{ contentType = 'html'; content = $Body }
        [Text.Json.JsonDocument]::Parse(($o | ConvertTo-Json -Depth 6 -Compress)).RootElement
    }
    function Add-Msgs($Store, [string]$Key, $Messages) {
        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
        foreach ($m in $Messages) { $l.Add($m) }
        $Store.AppendMessages($Key, $l)
    }
    function Get-Ids($Store, [string]$Key, $From = $null, $To = $null) {
        @($Store.ReadMessages($Key, $From, $To) | ForEach-Object { $_.GetProperty('id').GetString() })
    }
    function Get-Body($Store, [string]$Key, [string]$Id) {
        foreach ($m in $Store.ReadMessages($Key)) { if ($m.GetProperty('id').GetString() -eq $Id) { return $m.GetProperty('body').GetProperty('content').GetString() } }
    }
    function Get-DirBytes([string]$Path) { [long](Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object Length -Sum).Sum }
    function Use-Store([scriptblock]$Body, [int]$Partitions = 8, [scriptblock]$Configure = $null) {
        $root = New-Root
        $o = New-Opts $Partitions
        if ($Configure) { & $Configure $o }
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)
        try { & $Body $s $root } finally { $s.Dispose() }
    }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Messages: append, dedup, versions' {
    It 'stores new messages, ignores an identical re-append and survives a reopen' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try {
            $msgs = 1..5 | ForEach-Object { New-Msg "$_" "2026-01-0$_`T10:00:00.000Z" "2026-01-0$_`T10:00:00.000Z" "body $_" }
            $r = Add-Msgs $s 'chat:a' $msgs
            @($r.New, $r.Updated, $r.Unchanged) | Should -Be @(5, 0, 0)
            $r = Add-Msgs $s 'chat:a' $msgs
            @($r.New, $r.Updated, $r.Unchanged) | Should -Be @(0, 0, 5)
            $s.CountMessages('chat:a') | Should -Be 5
            $s.CountMessages('chat:other') | Should -Be 0
            Get-Ids $s 'chat:a' | Should -Be @('1', '2', '3', '4', '5')
        } finally { $s.Dispose() }
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try {
            Get-Ids $s 'chat:a' | Should -Be @('1', '2', '3', '4', '5')
            Get-Body $s 'chat:a' '3' | Should -Be 'body 3'
        } finally { $s.Dispose() }
    }

    It 'keeps the latest version of an edit, ignores an older one, counts versions' {
        Use-Store {
            param($s)
            Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T10:00:00Z' 'v1') | Out-Null
            $r = Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-02T10:00:00Z' 'v2 edited')
            $r.Updated | Should -Be 1
            $r = Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T09:00:00Z' 'older')
            $r.Unchanged | Should -Be 1
            Get-Body $s 'chat:a' '1' | Should -Be 'v2 edited'
            $s.GetMessageInfo('chat:a', '1').Versions | Should -Be 2
            $s.CountMessages('chat:a') | Should -Be 1
        }
    }

    It 'treats a reaction change and a deletion (new lastModifiedDateTime) as new versions' {
        Use-Store {
            param($s)
            Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T10:00:00Z' 'text') | Out-Null
            $withReaction = [Text.Json.JsonDocument]::Parse('{"id":"1","createdDateTime":"2026-01-01T10:00:00Z","lastModifiedDateTime":"2026-01-01T11:00:00Z","body":{"content":"text"},"reactions":[{"reactionType":"like"}]}').RootElement
            (Add-Msgs $s 'chat:a' @($withReaction)).Updated | Should -Be 1
            (Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T12:00:00Z' '' -Deleted)).Updated | Should -Be 1
            $s.GetMessageInfo('chat:a', '1').Versions | Should -Be 3
            $m = @($s.ReadMessages('chat:a'))
            $m.Count | Should -Be 1
            $m[0].TryGetProperty('deletedDateTime', [ref]([Text.Json.JsonElement]::new())) | Should -BeTrue
        }
    }

    It 'handles imported messages (lastModifiedDateTime 0001-01-01): a valid value, never older than "no value"' {
        Use-Store {
            param($s)
            $zero = '0001-01-01T00:00:00Z'
            (Add-Msgs $s 'chat:i' @(New-Msg '1' '2024-05-01T08:00:00Z' $zero 'imported' -Etag 'e1')).New | Should -Be 1
            $s.GetMessageInfo('chat:i', '1').LastModifiedUtc.UtcTicks | Should -Be 0
            # same service version (same etag) with another JSON projection: unchanged
            (Add-Msgs $s 'chat:i' @(New-Msg '1' '2024-05-01T08:00:00Z' $zero 'imported (other projection)' -Etag 'e1')).Unchanged | Should -Be 1
            # same 0001 value but another etag: a change that lastModifiedDateTime cannot express
            (Add-Msgs $s 'chat:i' @(New-Msg '1' '2024-05-01T08:00:00Z' $zero 'imported then reacted' -Etag 'e2')).Updated | Should -Be 1
            # no lastModifiedDateTime at all is older than 0001-01-01
            (Add-Msgs $s 'chat:i' @(New-Msg '1' '2024-05-01T08:00:00Z' $null 'no lm' -Etag 'e3')).Unchanged | Should -Be 1
            # a real date is newer than 0001-01-01
            (Add-Msgs $s 'chat:i' @(New-Msg '1' '2024-05-01T08:00:00Z' '2025-01-01T00:00:00Z' 'edited in Teams' -Etag 'e4')).Updated | Should -Be 1
            Get-Body $s 'chat:i' '1' | Should -Be 'edited in Teams'
            # absent first, then 0001 -> newer
            Add-Msgs $s 'chat:i' @(New-Msg '2' '2024-05-01T09:00:00Z' $null 'none') | Out-Null
            (Add-Msgs $s 'chat:i' @(New-Msg '2' '2024-05-01T09:00:00Z' $zero 'zero')).Updated | Should -Be 1
        }
    }

    It 'resolves versions of the same message inside one batch and across the buffer boundary' {
        Use-Store {
            param($s)
            $r = Add-Msgs $s 'chat:a' @(
                (New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T10:00:00Z' 'a'),
                (New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-03T10:00:00Z' 'c'),
                (New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-02T10:00:00Z' 'b'))
            @($r.New, $r.Updated, $r.Unchanged) | Should -Be @(1, 1, 1)
            $s.Flush()
            Get-Body $s 'chat:a' '1' | Should -Be 'c'
            $s.GetMessageInfo('chat:a', '1').Versions | Should -Be 2
        }
    }

    It 'rejects a message without id or a non-object' {
        Use-Store {
            param($s)
            { Add-Msgs $s 'chat:a' @([Text.Json.JsonDocument]::Parse('{"createdDateTime":"2026-01-01T00:00:00Z"}').RootElement) } | Should -Throw '*no ''id''*'
            { Add-Msgs $s 'chat:a' @([Text.Json.JsonDocument]::Parse('[1]').RootElement) } | Should -Throw '*not a JSON object*'
        }
    }

    It 'stores the raw bytes unchanged and writes valid jsonl.gz segments (multi-member gzip)' {
        Use-Store {
            param($s, $root)
            $raw = '{"id":"7","createdDateTime":"2026-03-05T10:00:00Z","body":{"content":"caf\u00e9 \ud83d\ude00 <b>x</b>"},"n":1.50}'
            $el = [Text.Json.JsonDocument]::Parse($raw).RootElement
            Add-Msgs $s 'chat:raw' @($el) | Out-Null
            $s.Flush()
            @($s.ReadMessages('chat:raw'))[0].GetRawText() | Should -BeExactly $raw
            $seg = Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz'
            $seg.Count | Should -Be 1
            $seg.Name | Should -Be '2026-03-1.jsonl.gz'
            $fs = [IO.FileStream]::new($seg.FullName, "Open", "Read", "ReadWrite")
            $gz = [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Decompress)
            $sr = [IO.StreamReader]::new($gz, [Text.Encoding]::UTF8)
            try { $sr.ReadToEnd().TrimEnd("`n") | Should -BeExactly $raw } finally { $sr.Dispose() }
        }
    }

    It 'splits segments by month and rolls to a new file at SegmentMaxBytes; everything stays readable' {
        Use-Store {
            param($s, $root)
            $body = ('lorem ipsum dolor sit amet ' * 20)
            $msgs = foreach ($i in 1..120) { $mo = if ($i % 2) { '01' } else { '02' }; New-Msg ('{0:D4}' -f $i) ("2026-$mo-01T10:{0:D2}:{1:D2}Z" -f [int][math]::Floor($i / 60), ($i % 60)) $null $body }
            Add-Msgs $s 'chat:roll' $msgs | Out-Null
            $s.Flush()
            $names = @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz' | ForEach-Object Name | Sort-Object)
            ($names | Where-Object { $_ -like '2026-01-*' }).Count | Should -BeGreaterThan 1
            ($names | Where-Object { $_ -like '2026-02-*' }).Count | Should -BeGreaterThan 1
            @(Get-Ids $s 'chat:roll').Count | Should -Be 120
            $v = $s.Verify($true)
            $v.Consistent | Should -BeTrue
            $v.DeepChecked | Should -Be 120
        } -Configure { param($o) $o.SegmentMaxBytes = 8000; $o.BlockBytes = 2000 }
    }

    It 'rejects appends on a read-only store but reads fine' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        Add-Msgs $s 'chat:a' @(New-Msg '1' '2026-01-01T10:00:00Z' '2026-01-01T10:00:00Z') | Out-Null
        $s.Dispose()
        $o = New-Opts; $o.ReadOnly = $true
        $ro = [TeamsTransfer.TmtStore]::Open($root, $o)
        try {
            Get-Ids $ro 'chat:a' | Should -Be @('1')
            { Add-Msgs $ro 'chat:a' @(New-Msg '2' '2026-01-01T10:00:00Z') } | Should -Throw '*read-only*'
            $ro.CountMessages('chat:a') | Should -Be 1
        } finally { $ro.Dispose() }
    }
}

Describe 'Messages: ordering and time filters' {
    It 'orders by createdDateTime then id' {
        Use-Store {
            param($s)
            Add-Msgs $s 'chat:o' @(
                (New-Msg 'b' '2026-01-01T10:00:00Z'), (New-Msg 'a' '2026-01-01T10:00:00Z'), (New-Msg 'z' '2025-12-31T23:59:59Z'), (New-Msg 'c' '2026-01-02T00:00:00Z')) | Out-Null
            Get-Ids $s 'chat:o' | Should -Be @('z', 'a', 'b', 'c')
        }
    }

    It 'places each channel reply right after its root; orphan replies by their own date' {
        Use-Store {
            param($s)
            $k = 'channel:T1/C1'
            Add-Msgs $s $k @(
                (New-Msg 'a' '2026-02-01T10:10:00Z' -Reply 'R1'),
                (New-Msg 'R2' '2026-02-01T10:05:00Z'),
                (New-Msg 'orph' '2026-02-01T10:03:00Z' -Reply 'GONE'),
                (New-Msg 'c' '2026-02-01T10:02:00Z' -Reply 'R1'),
                (New-Msg 'R1' '2026-02-01T10:00:00Z'),
                (New-Msg 'b' '2026-02-01T10:06:00Z' -Reply 'R2')) | Out-Null
            Get-Ids $s $k | Should -Be @('R1', 'c', 'a', 'orph', 'R2', 'b')
            # root outside the range: its replies in range are placed by their own date
            $from = [DateTimeOffset]::Parse('2026-02-01T10:01:00Z'); $to = [DateTimeOffset]::Parse('2026-02-01T10:06:00Z')
            Get-Ids $s $k $from $to | Should -Be @('c', 'orph', 'R2')
        }
    }

    It 'filters by time (from inclusive, to exclusive) and returns nothing for an unknown conversation' {
        Use-Store {
            param($s)
            Add-Msgs $s 'chat:t' @(1..10 | ForEach-Object { New-Msg "m$_" ("2026-03-{0:D2}T00:00:00Z" -f $_) }) | Out-Null
            $f = [DateTimeOffset]::Parse('2026-03-03T00:00:00Z'); $t = [DateTimeOffset]::Parse('2026-03-06T00:00:00Z')
            Get-Ids $s 'chat:t' $f $t | Should -Be @('m3', 'm4', 'm5')
            Get-Ids $s 'chat:t' $f $null | Should -Be @('m3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10')
            Get-Ids $s 'chat:t' $null $t | Should -Be @('m1', 'm2', 'm3', 'm4', 'm5')
            @(Get-Ids $s 'chat:nope').Count | Should -Be 0
        }
    }

    It 'streams a large conversation without materializing it (memory stays flat while enumerating)' {
        Use-Store {
            param($s)
            $body = 'x' * 600
            foreach ($page in 0..39) {
                Add-Msgs $s 'chat:big' @(1..500 | ForEach-Object { $n = $page * 500 + $_; New-Msg ('{0:D6}' -f $n) ([DateTimeOffset]::Parse('2026-01-01T00:00:00Z').AddSeconds($n).ToString('o')) $null $body }) | Out-Null
            }
            $s.Flush()
            [GC]::Collect(); $before = [GC]::GetTotalMemory($true)
            $n = 0; $peak = 0L; $last = ''
            foreach ($m in $s.ReadMessages('chat:big')) {
                $id = $m.GetProperty('id').GetString()
                if ($id -le $last) { throw "order broken at $id" }
                $last = $id; $n++
                if ($n % 4000 -eq 0) { $peak = [Math]::Max($peak, [GC]::GetTotalMemory($false) - $before) }
            }
            $n | Should -Be 20000
            ($peak / 1MB) | Should -BeLessThan 64
        }
    }
}

Describe 'Content-addressed blobs' {
    It 'writes content\ab\cd\<sha256>, deduplicates and leaves no temp file' {
        Use-Store {
            param($s, $root)
            $bytes = [Text.Encoding]::UTF8.GetBytes('the same picture')
            $sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '')).ToLowerInvariant()
            $r1 = $s.PutContent([IO.MemoryStream]::new($bytes), 'image/png')
            $r1.Sha256 | Should -Be $sha
            $r1.Length | Should -Be $bytes.Length
            $r1.AlreadyPresent | Should -BeFalse
            $r2 = $s.PutContent([IO.MemoryStream]::new($bytes), 'image/png')
            $r2.AlreadyPresent | Should -BeTrue
            Test-Path (Join-Path $root "content\$($sha.Substring(0,2))\$($sha.Substring(2,2))\$sha") | Should -BeTrue
            @(Get-ChildItem (Join-Path $root 'content') -Recurse -File | Where-Object { $_.Name -ne $sha }).Count | Should -Be 0
            $s.HasContent($sha) | Should -BeTrue
            $s.HasContent('0' * 64) | Should -BeFalse
            $s.HasContent('../../etc/passwd') | Should -BeFalse
            $s.OpenContent('0' * 64) | Should -BeNullOrEmpty
            $in = $s.OpenContent($sha)
            try { $ms = [IO.MemoryStream]::new(); $in.CopyTo($ms); [Text.Encoding]::UTF8.GetString($ms.ToArray()) | Should -Be 'the same picture' } finally { $in.Dispose() }
            $s.PutContent([IO.MemoryStream]::new([byte[]]@()), $null).Length | Should -Be 0
        }
    }

    It 'streams 1 GB through PutContent with a flat working set and a correct hash' {
        Use-Store {
            param($s, $root)
            $size = 1GB
            $gen = [TmtGenStream]::new($size)
            $before = [Environment]::WorkingSet
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = $s.PutContent($gen, 'application/octet-stream')
            $put = $sw.Elapsed.TotalSeconds
            $r.Length | Should -Be $size
            $growthMb = ($gen.MaxWorkingSet - $before) / 1MB
            Write-Host ("  1 GB PutContent: {0:N1}s ({1:N0} MB/s), working set growth {2:N0} MB" -f $put, ($size / 1MB / $put), $growthMb)
            $growthMb | Should -BeLessThan 200
            # independent hash of the same deterministic stream
            $h = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            $g2 = [TmtGenStream]::new($size); $buf = [byte[]]::new(1MB)
            while (($n = $g2.Read($buf, 0, $buf.Length)) -gt 0) { $h.AppendData($buf, 0, $n) }
            $expected = ([BitConverter]::ToString($h.GetHashAndReset()).Replace('-', '')).ToLowerInvariant()
            $r.Sha256 | Should -Be $expected
            (Get-Item (Join-Path $root "content\$($expected.Substring(0,2))\$($expected.Substring(2,2))\$expected")).Length | Should -Be $size
            $in = $s.OpenContent($expected)
            try { $in.Length | Should -Be $size } finally { $in.Dispose() }
            Remove-Item (Join-Path $root 'content') -Recurse -Force
        }
    }
}

Describe 'Concurrency' {
    It 'accepts 8 concurrent writers, including several on the same conversation' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 16))
        try {
            1..8 | ForEach-Object -ThrottleLimit 8 -Parallel {
                $store = $using:s; $w = $_
                function J($id, $c, $b) { [Text.Json.JsonDocument]::Parse("{`"id`":`"$id`",`"createdDateTime`":`"$c`",`"lastModifiedDateTime`":`"$c`",`"body`":{`"content`":`"$b`"}}").RootElement }
                $base = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
                # own conversations
                foreach ($c in 1..10) {
                    foreach ($page in 0..3) {
                        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                        foreach ($i in 1..50) { $n = $page * 50 + $i; $l.Add((J ('{0:D5}' -f $n) ($base.AddSeconds($n).ToString('o')) "w$w c$c n$n")) }
                        [void]$store.AppendMessages("chat:w$w-c$c", $l)
                    }
                }
                # one shared conversation: each writer appends its own 100 ids
                foreach ($page in 0..1) {
                    $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                    foreach ($i in 1..50) { $n = $w * 1000 + $page * 50 + $i; $l.Add((J ('{0:D6}' -f $n) ($base.AddSeconds($n).ToString('o')) "shared $n")) }
                    [void]$store.AppendMessages('chat:shared', $l)
                }
            }
            foreach ($w in 1..8) { foreach ($c in 1..10) { $s.CountMessages("chat:w$w-c$c") | Should -Be 200 } }
            $s.CountMessages('chat:shared') | Should -Be 800
            $ids = Get-Ids $s 'chat:shared'
            $ids.Count | Should -Be 800
            ($ids | Sort-Object) | Should -Be $ids
            $s.GetStats().Messages | Should -Be (8 * 10 * 200 + 800)
            $s.Verify($true).Consistent | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'sustains the append throughput target with 8 writers (reported; floor asserted loosely)' {
        $root = New-Root
        $o = New-Opts 256
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)
        try {
            $barrier = [Threading.Barrier]::new(8)
            $perWriter = 25000
            $res = 1..8 | ForEach-Object -ThrottleLimit 8 -Parallel {
                $store = $using:s; $w = $_; $perWriter = $using:perWriter; $barrier = $using:barrier
                $words = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.Split(' ')
                $base = [DateTimeOffset]::Parse('2026-02-01T00:00:00Z')
                $pages = [Collections.Generic.List[object]]::new()
                $convCount = 100; $perConv = $perWriter / $convCount
                foreach ($c in 1..$convCount) {
                    $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                    foreach ($i in 1..$perConv) {
                        $text = (1..40 | ForEach-Object { $words[($i * 7 + $_ * 13 + $c) % $words.Count] }) -join ' '
                        $ts = $base.AddSeconds($i * 30 + $c).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                        $l.Add([Text.Json.JsonDocument]::Parse("{`"id`":`"$($w * 100000 + $c * 1000 + $i)`",`"messageType`":`"message`",`"createdDateTime`":`"$ts`",`"lastModifiedDateTime`":`"$ts`",`"etag`":`"$($i)`",`"from`":{`"user`":{`"id`":`"u$w`",`"displayName`":`"Writer $w`",`"userIdentityType`":`"aadUser`"}},`"body`":{`"contentType`":`"html`",`"content`":`"<p>$text</p>`"},`"reactions`":[],`"mentions`":[],`"attachments`":[],`"importance`":`"normal`"}").RootElement)
                    }
                    $pages.Add(@{ Key = "chat:perf-$w-$c"; Msgs = $l })
                }
                [void]$barrier.SignalAndWait()
                $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
                foreach ($p in $pages) {
                    $m = $p.Msgs
                    for ($o = 0; $o -lt $m.Count; $o += 50) {
                        $chunk = [Collections.Generic.List[Text.Json.JsonElement]]::new($m.GetRange($o, [Math]::Min(50, $m.Count - $o)))
                        [void]$store.AppendMessages($p.Key, $chunk)
                    }
                }
                $t1 = [Diagnostics.Stopwatch]::GetTimestamp()
                [pscustomobject]@{ T0 = $t0; T1 = $t1 }
            }
            $s.Flush()
            $swFlushStart = [Diagnostics.Stopwatch]::GetTimestamp()
            $first = ($res | Measure-Object T0 -Minimum).Minimum; $last = ($res | Measure-Object T1 -Maximum).Maximum
            $secs = ($last - $first) / [Diagnostics.Stopwatch]::Frequency
            $total = 8 * $perWriter
            $rate = $total / $secs
            Write-Host ("  APPEND THROUGHPUT: {0:N0} messages in {1:N2}s = {2:N0} msg/s with 8 writers (50 msgs per call, 256 partitions)" -f $total, $secs, $rate)
            $s.GetStats().Messages | Should -Be $total
            $rate | Should -BeGreaterThan 8000
        } finally { $s.Dispose() }
    }
}

Describe 'Crash safety' {
    It 'recovers when a segment lost its tail: index entries beyond the end are removed, the rest reads fine' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            Add-Msgs $s 'chat:c' @(1..50 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-04-01T10:00:00Z' $null "first $_" }) | Out-Null
            $s.Flush()
            Add-Msgs $s 'chat:c' @(51..100 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-04-02T10:00:00Z' $null "second $_" }) | Out-Null
            $s.Flush()
        } finally { $s.Dispose() }
        $seg = Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '2026-04-1.jsonl.gz'
        $fs = [IO.File]::Open($seg.FullName, 'Open', 'ReadWrite'); $fs.SetLength($fs.Length - 25); $fs.Dispose()
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            $ids = Get-Ids $s 'chat:c'     # first use of the partition triggers the recovery
            $s.RecoveryLog.Count | Should -BeGreaterThan 0
            $s.RecoveryLog[0] | Should -BeLike '*message index entries removed*'
            $ids.Count | Should -Be 50
            $ids[0] | Should -Be '001'
            $s.CountMessages('chat:c') | Should -Be 50
            $v = $s.Verify($true)
            $v.Consistent | Should -BeTrue
            $v.DanglingBlocks | Should -Be 0
            # the lost messages can be exported again
            (Add-Msgs $s 'chat:c' @(51..100 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-04-02T10:00:00Z' $null "second $_" })).New | Should -Be 50
            (Get-Ids $s 'chat:c').Count | Should -Be 100
        } finally { $s.Dispose() }
    }

    It 'ignores an orphan tail (bytes after the last commit), reports it, and keeps appending safely' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try { Add-Msgs $s 'chat:c' @(1..10 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-04-01T10:00:00Z' $null "m $_" }) | Out-Null } finally { $s.Dispose() }
        $seg = Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '2026-04-1.jsonl.gz'
        $before = $seg.Length
        $garbage = 'PARTIAL-BLOCK-WRITTEN-BY-A-KILLED-WRITER'; $gl = $garbage.Length
        [IO.File]::AppendAllText($seg.FullName, $garbage)
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            (Get-Ids $s 'chat:c').Count | Should -Be 10
            $v = $s.Verify($true)
            $v.OrphanTails | Should -Be 1
            $v.OrphanTailBytes | Should -Be $gl
            $v.Consistent | Should -BeTrue
            Add-Msgs $s 'chat:c' @(11..20 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-04-01T11:00:00Z' $null "m $_" }) | Out-Null
            (Get-Ids $s 'chat:c').Count | Should -Be 20
            $s.Verify($true).Consistent | Should -BeTrue
            # new data went to a new segment, the damaged one is untouched
            (Get-Item $seg.FullName).Length | Should -Be ($before + $gl)
            @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '2026-04-*.jsonl.gz').Count | Should -Be 2
            $r = $s.Verify($false, $true)
            (Get-Item $seg.FullName).Length | Should -Be $before
            $s.Verify($true).OrphanTailBytes | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'reports a segment file unknown to the index (created by a writer killed before its first commit)' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            Add-Msgs $s 'chat:c' @(New-Msg '1' '2026-04-01T10:00:00Z') | Out-Null
            $s.Flush()
            [IO.File]::WriteAllBytes((Join-Path (Split-Path (Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz')[0].FullName) '2026-04-9.jsonl.gz'), [byte[]](1, 2, 3))
            $v = $s.Verify()
            $v.OrphanFiles | Should -Be 1
            $v.Consistent | Should -BeTrue
            $s.Verify($false, $true) | Out-Null
            $s.Verify().OrphanFiles | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'detects a corrupted block with a deep verify' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            Add-Msgs $s "chat:c" @(1..30 | ForEach-Object { New-Msg ("{0:D3}" -f $_) "2026-04-01T10:00:00Z" $null ("payload " * 30) }) | Out-Null
        } finally { $s.Dispose() }
        $seg = Get-ChildItem (Join-Path $root "parts") -Recurse -Filter "*.jsonl.gz"
        $fs = [IO.FileStream]::new($seg.FullName, "Open", "ReadWrite", "ReadWrite")
        try { $mid = [long]($fs.Length / 2); $fs.Position = $mid; $x = $fs.ReadByte(); $fs.Position = $mid; $fs.WriteByte([byte]($x -bxor 0xFF)) } finally { $fs.Dispose() }
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 1))
        try {
            $v = $s.Verify($true)
            $v.HashMismatches | Should -BeGreaterThan 0
            $v.Consistent | Should -BeFalse
        } finally { $s.Dispose() }
    }

    It 'survives kill -9 of a writer process in the middle of writes' {
        $root = New-Root
        $child = Join-Path $script:TempRoot 'child-writer.ps1'
        @'
param($Root, $ModulePath, $PackageRoot)
Import-Module $ModulePath -Force
Initialize-TmtEngine -Root $PackageRoot
$o = [TeamsTransfer.StoreOptions]::new(); $o.Partitions = 4; $o.FlushIntervalMs = 0; $o.BatchSize = 1000000
$s = [TeamsTransfer.TmtStore]::Open($Root, $o)
$seq = @{}; $page = 0
$base = [DateTimeOffset]::Parse('2026-05-01T00:00:00Z')
while ($true) {
    $conv = 'chat:k' + ($page % 10)
    $n0 = if ($seq.ContainsKey($conv)) { $seq[$conv] } else { 0 }
    $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
    foreach ($i in 1..40) {
        $n = $n0 + $i
        $l.Add([Text.Json.JsonDocument]::Parse("{`"id`":`"$('{0:D8}' -f $n)`",`"createdDateTime`":`"$($base.AddSeconds($n).ToString('o'))`",`"body`":{`"content`":`"message $n of $conv with some text to compress`"}}").RootElement)
    }
    [void]$s.AppendMessages($conv, $l)
    $seq[$conv] = $n0 + 40
    $page++
    if ($page % 25 -eq 0) { $s.Flush(); if ($page -eq 100) { [Console]::Out.WriteLine('READY'); [Console]::Out.Flush() } }
}
'@ | Set-Content -LiteralPath $child -Encoding utf8
        $pwsh = (Get-Process -Id $PID).Path
        $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($a in '-NoProfile', '-File', $child, '-Root', $root, '-ModulePath', $script:ModulePath, '-PackageRoot', $script:PackageRoot) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $p = [Diagnostics.Process]::Start($psi)
        try {
            $ready = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            $task = $p.StandardOutput.ReadLineAsync()
            while ([DateTime]::UtcNow -lt $deadline -and -not $p.HasExited) {
                if ($task.Wait(500)) { if ($task.Result -eq 'READY') { $ready = $true; break }; $task = $p.StandardOutput.ReadLineAsync() }
            }
            if (-not $ready) { throw "child writer never became ready: $($p.StandardError.ReadToEnd())" }
            Start-Sleep -Milliseconds 300
            $p.Kill($true); [void]$p.WaitForExit(15000)
        } finally { if (-not $p.HasExited) { $p.Kill($true) } }

        $o = New-Opts 4
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)    # also proves the OS released the lock of the killed process
        try {
            $total = 0
            foreach ($c in 0..9) {
                $ids = Get-Ids $s "chat:k$c"
                $ids.Count | Should -BeGreaterOrEqual 400          # the 100 pages flushed before READY were committed
                for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i] -ne ('{0:D8}' -f ($i + 1))) { throw "conversation k${c}: gap or reorder at position $i ($($ids[$i]))" } }
                $s.CountMessages("chat:k$c") | Should -Be $ids.Count
                $total += $ids.Count
            }
            $v = $s.Verify($true)
            $v.Consistent | Should -BeTrue
            $v.DanglingBlocks | Should -Be 0
            $v.DeepChecked | Should -Be $total
            Write-Host ("  after kill -9: {0} messages intact, orphan tail bytes ignored: {1}, orphan files: {2}" -f $total, $v.OrphanTailBytes, $v.OrphanFiles)
            # and the store keeps working
            (Add-Msgs $s 'chat:k0' @(New-Msg 'zzz' '2026-06-01T00:00:00Z')).New | Should -Be 1
        } finally { $s.Dispose() }
    }
}

Describe 'Refusal rules' {
    It 'refuses a store inside the package folder' {
        $inside = Join-Path $script:PackageRoot 'tmt-store-must-not-exist'
        { [TeamsTransfer.TmtStore]::Open($inside, (New-Opts)) } | Should -Throw '*inside the package folder*'
        { [TeamsTransfer.TmtStore]::Open((Join-Path $script:PackageRoot 'a\b\c'), (New-Opts)) } | Should -Throw '*package folder*'
        Test-Path -LiteralPath $inside | Should -BeFalse
        $o = New-Opts; $o.PackageRoot = $script:TempRoot
        { [TeamsTransfer.TmtStore]::Open((Join-Path $script:TempRoot 'explicit'), $o) } | Should -Throw '*package folder*'
    }

    It 'refuses a UNC path (SQLite over SMB is unsafe) without touching it' {
        { [TeamsTransfer.TmtStore]::Open('\\localhost\c$\tmt-never-created', (New-Opts)) } | Should -Throw '*SMB*'
        { [TeamsTransfer.TmtStore]::Open('\\?\UNC\server\share\tmt', (New-Opts)) } | Should -Throw '*SMB*'
        Test-Path '\\localhost\c$\tmt-never-created' | Should -BeFalse
    }

    It 'refuses a partition-count mismatch and reports the recorded count' {
        $root = New-Root
        [TeamsTransfer.TmtStore]::Open($root, (New-Opts 4)).Dispose()
        [TeamsTransfer.TmtStore]::PeekPartitions($root) | Should -Be 4
        { [TeamsTransfer.TmtStore]::Open($root, (New-Opts 8)) } | Should -Throw '*Partition count mismatch*created with 4*'
        [TeamsTransfer.TmtStore]::Open($root, (New-Opts 4)).Dispose()
        [TeamsTransfer.TmtStore]::PeekPartitions((New-Root)) | Should -Be 0
    }

    It 'allows a single writer: a second open of the same root fails, a reopen after dispose works' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        { [TeamsTransfer.TmtStore]::Open($root, (New-Opts)) } | Should -Throw '*already open*'
        $s.Dispose()
        [TeamsTransfer.TmtStore]::Open($root, (New-Opts)).Dispose()
    }

    It 'places conversations on a stable partition' {
        [TeamsTransfer.TmtStore]::PartitionOf('chat:19:abc@thread.v2', 256) | Should -Be ([TeamsTransfer.TmtStore]::PartitionOf('chat:19:abc@thread.v2', 256))
        $spread = 1..5000 | ForEach-Object { [TeamsTransfer.TmtStore]::PartitionOf("chat:19:$_@thread.v2", 256) } | Group-Object
        $spread.Count | Should -Be 256
        ($spread | Measure-Object Count -Maximum).Maximum | Should -BeLessThan 50
    }
}

Describe 'Catalog tables of the exporter contract' {
    It 'upserts users and conversations without losing known data; lists by user, kind and team' {
        Use-Store {
            param($s)
            $u = [TeamsTransfer.UserRecord]::new(); $u.Id = 'u1'; $u.UserPrincipalName = 'a@x.com'; $u.DisplayName = 'Alice'; $u.State = 'Active'
            $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($u))
            $u2 = [TeamsTransfer.UserRecord]::new(); $u2.Id = 'u1'; $u2.Mail = 'alice@x.com'     # State Unknown must not overwrite Active
            $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($u2))
            $got = @($s.ListUsers())
            $got.Count | Should -Be 1
            $got[0].DisplayName | Should -Be 'Alice'; $got[0].Mail | Should -Be 'alice@x.com'; $got[0].State | Should -Be 'Active'

            $c1 = [TeamsTransfer.ConversationRecord]::new(); $c1.Key = 'chat:1'; $c1.Kind = 'Group'; $c1.ChatId = '1'; $c1.Topic = 'Team lunch'; $c1.MembersJson = '[{"id":"u1"}]'; $c1.MemberCount = 1
            $c1.CreatedUtc = [DateTimeOffset]::Parse('2025-01-01T00:00:00Z'); $c1.LastActivityUtc = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
            $c2 = [TeamsTransfer.ConversationRecord]::new(); $c2.Key = 'channel:T/C'; $c2.Kind = 'Channel'; $c2.TeamId = 'T'; $c2.ChannelId = 'C'; $c2.MembershipType = 'standard'
            $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c1, $c2))
            $c1b = [TeamsTransfer.ConversationRecord]::new(); $c1b.Key = 'chat:1'; $c1b.Kind = 'Group'; $c1b.LastActivityUtc = [DateTimeOffset]::Parse('2025-06-01T00:00:00Z'); $c1b.HasImportedContent = $true
            $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@($c1b))
            $g = $s.GetConversation('chat:1')
            $g.Topic | Should -Be 'Team lunch'; $g.MemberCount | Should -Be 1; $g.HasImportedContent | Should -BeTrue
            $g.LastActivityUtc.Year | Should -Be 2026          # never goes backwards
            $s.GetConversation('chat:nope') | Should -BeNullOrEmpty
            $s.LinkUserConversations("u1", [string[]]@("chat:1", "channel:T/C", "chat:1"))
            @($s.ListConversations('u1')).Count | Should -Be 2
            @($s.ListConversations($null, 'Channel')).Count | Should -Be 1
            @($s.ListConversations($null, $null, 'T'))[0].Key | Should -Be 'channel:T/C'
            @($s.ListConversations('nobody')).Count | Should -Be 0
        }
    }

    It 'saves checkpoints and makes them a barrier: buffered messages are on disk before the checkpoint' {
        $root = New-Root
        $o = New-Opts; $o.BatchSize = 1000000; $o.MaxPendingBytes = 1GB
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)
        try {
            $s.GetCheckpoint('gam:u1') | Should -BeNullOrEmpty
            Add-Msgs $s 'chat:c' @(New-Msg '1' '2026-01-01T00:00:00Z') | Out-Null
            @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz' -ErrorAction SilentlyContinue).Count | Should -Be 0     # still buffered
            $s.SetCheckpoint('gam:u1', 'https://graph.microsoft.com/next?x=1')
            @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz').Count | Should -Be 1
            $s.GetCheckpoint('gam:u1') | Should -Be 'https://graph.microsoft.com/next?x=1'
            $s.SetCheckpoint('gam:u1', 'v2'); $s.GetCheckpoint('gam:u1') | Should -Be 'v2'
        } finally { $s.Dispose() }
    }

    It 'flushes buffered messages on a timer' {
        $root = New-Root
        $o = New-Opts; $o.FlushIntervalMs = 100; $o.BatchSize = 1000000
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)
        try {
            Add-Msgs $s 'chat:c' @(New-Msg '1' '2026-01-01T00:00:00Z') | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline -and @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz' -ErrorAction SilentlyContinue).Count -eq 0) { Start-Sleep -Milliseconds 100 }
            @(Get-ChildItem (Join-Path $root 'parts') -Recurse -Filter '*.jsonl.gz').Count | Should -Be 1
        } finally { $s.Dispose() }
    }

    It 'records files (Pending/Failed with retries left are pending; Downloaded never regresses) and hosted contents' {
        Use-Store {
            param($s)
            function F($att, $status, $sha = $null) { $f = [TeamsTransfer.FileRecord]::new(); $f.ConversationKey = 'chat:1'; $f.MessageId = 'm1'; $f.AttachmentId = $att; $f.Name = "$att.docx"; $f.Status = $status; $f.Sha256 = $sha; $f }
            $s.RecordFile((F 'a1' 'Pending')); $s.RecordFile((F 'a2' 'Pending')); $s.RecordFile((F 'a3' 'Downloaded' ('ab' * 32))); $s.RecordFile((F 'a4' 'NotFound'))
            @($s.PendingFiles(10) | ForEach-Object AttachmentId) | Should -Be @('a1', 'a2')
            @($s.PendingFiles(1)).Count | Should -Be 1
            foreach ($i in 1..3) { $s.RecordFile((F 'a2' 'Failed')) }
            @($s.PendingFiles(10) | ForEach-Object AttachmentId) | Should -Be @('a1')       # a2 failed 3 times: no retries left
            $s.RecordFile((F 'a3' 'Pending'))                                               # re-seen by the exporter
            @($s.ListFiles('chat:1') | Where-Object AttachmentId -eq 'a3')[0].Status | Should -Be 'Downloaded'
            @($s.ListFiles('chat:1')).Count | Should -Be 4
            @($s.ListFiles('chat:other')).Count | Should -Be 0

            $ref = $s.PutContent([IO.MemoryStream]::new([byte[]](1, 2, 3)), 'image/png')
            $s.RecordHostedContent('chat:1', 'm1', 'h1', $ref)
            $s.FindHostedContent('chat:1', 'm1', 'h1') | Should -Be $ref.Sha256
            $s.FindHostedContent('chat:1', 'm1', 'zz') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Volume' -Tag 'Volume' {
    It 'appends >= 2,000,000 synthetic messages with 8 writers and reports msg/s, bytes/message and RAM' -Skip:($env:TMT_VOLUME -ne '1') {
        $target = 2000000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = [TeamsTransfer.Testing.SyntheticTenant]::Build([TeamsTransfer.Testing.SyntheticProfile]::Volume([long]($target * 1.1), 1))
        $genSecs = $sw.Elapsed.TotalSeconds
        $t = $r.Tenant
        Write-Host ("  generated {0:N0} messages ({1:N0} in chats) in {2:N0}s" -f $r.Stats.Messages, $r.Stats.ChatMessages, $genSecs)
        $r.Stats.ChatMessages | Should -BeGreaterOrEqual $target

        $root = New-Root
        $o = New-Opts 256
        $s = [TeamsTransfer.TmtStore]::Open($root, $o)
        $tr = [TeamsTransfer.Testing.FakeGraphTransport]::new($t)
        $peakWs = 0L; $rawBytes = 0L; $rawSample = 0
        $appended = 0L; $appendSecs = 0.0; $pageSecs = 0.0
        try {
            $chats = @($t.Chats)
            $i = 0
            while ($i -lt $chats.Count) {
                # 1) pull a chunk of pages from the fake service (not measured as store time)
                $sw.Restart()
                $work = [Collections.Generic.List[object]]::new(); $docs = [Collections.Generic.List[object]]::new(); $chunkMsgs = 0
                while ($i -lt $chats.Count -and $chunkMsgs -lt 150000) {
                    $chat = $chats[$i++]
                    $url = "v1.0/chats/$($chat.Id)/messages?`$top=50"
                    while ($url) {
                        $q = [TeamsTransfer.GraphRequest]::new(); $q.Url = $url
                        $resp = $tr.SendAsync($q, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
                        $doc = [Text.Json.JsonDocument]::Parse($resp.Content); $resp.Dispose(); $docs.Add($doc)
                        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
                        foreach ($e in $doc.RootElement.GetProperty('value').EnumerateArray()) { $l.Add($e) }
                        if ($l.Count -gt 0) {
                            $work.Add(@{ Key = (([TeamsTransfer.ConversationKeys]::ForChat($chat.Id))); Msgs = $l }); $chunkMsgs += $l.Count
                            if ($rawSample -lt 20000) { foreach ($e in $l) { $rawBytes += $e.GetRawText().Length; $rawSample++ } }
                        }
                        $nl = [Text.Json.JsonElement]::new()
                        $url = if ($doc.RootElement.TryGetProperty([string]'@odata.nextLink', [ref]$nl)) { $nl.GetString() } else { $null }
                    }
                }
                $pageSecs += $sw.Elapsed.TotalSeconds
                # 2) append with 8 writers (measured)
                $sw.Restart()
                $work | ForEach-Object -ThrottleLimit 8 -Parallel { [void]($using:s).AppendMessages($_.Key, $_.Msgs) }
                $appendSecs += $sw.Elapsed.TotalSeconds
                $appended += $chunkMsgs
                foreach ($d in $docs) { $d.Dispose() }
                $peakWs = [Math]::Max($peakWs, [Diagnostics.Process]::GetCurrentProcess().WorkingSet64)
            }
            $sw.Restart(); $s.Flush(); $appendSecs += $sw.Elapsed.TotalSeconds
            $stats = $s.GetStats()
            $disk = Get-DirBytes $root
            $rate = $appended / $appendSecs
            $avgRaw = if ($rawSample) { $rawBytes / $rawSample } else { 0 }
            $report = "VOLUME-STORE: appended={0} conversations={1} appendTime={2:N1}s rate={3:N0} msg/s serviceReadTime={4:N0}s storeOnDisk={5:N0}MB bytesPerMessageOnDisk={6:N0} avgRawJsonBytes={7:N0} peakWorkingSet={8:N0}MB (tenant held in RAM) heapAfter={9:N0}MB" -f `
                $appended, $stats.Conversations, $appendSecs, $rate, $pageSecs, ($disk / 1MB), ($disk / $appended), $avgRaw, ($peakWs / 1MB), ([GC]::GetTotalMemory($false) / 1MB)
            Write-Host $report
            $report | Out-File -FilePath (Join-Path ([IO.Path]::GetTempPath()) 'TeamsTransfer-Store-volume.txt') -Encoding utf8
            $stats.Messages | Should -Be $appended
            $appended | Should -BeGreaterOrEqual $target

            # spot checks: reads back identical JSON for a sample of chats, ordered
            foreach ($chat in ($chats | Get-Random -Count 5 -SetSeed 7)) {
                $key = [TeamsTransfer.ConversationKeys]::ForChat($chat.Id)
                $n = 0; $prev = ''
                foreach ($m in $s.ReadMessages($key)) { $n++; $c = $m.GetProperty('createdDateTime').GetString(); if ($c -lt $prev) { throw "order broken in $key" }; $prev = $c }
                $n | Should -Be $chat.Messages.Count
            }
            $s.Verify($false).Consistent | Should -BeTrue
        } finally { $s.Dispose() }
    }
}
