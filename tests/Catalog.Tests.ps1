#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.Catalog.cs (partial class TmtStore): lots and slices, coverage, lifecycle, work leases,
# import journal, ghost accounts, merge of another store.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    if (-not ('TmtTestClock' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
public sealed class TmtTestClock
{
    public DateTimeOffset Now = new DateTimeOffset(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);
    public Func<DateTimeOffset> Fn;
    public TmtTestClock() { Fn = () => Now; }
    public void Advance(TimeSpan t) { Now = Now + t; }
}
'@
    }
    $script:TempRoot = Join-Path $env:TEMP ('tmt-catalog-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:AsOf = [DateTimeOffset]::Parse('2026-11-09T00:00:00Z')

    function New-Root { Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    function New-Opts([int]$Partitions = 8, $Clock = $null) {
        $o = [TeamsTransfer.StoreOptions]::new(); $o.Partitions = $Partitions; $o.FlushIntervalMs = 0
        if ($Clock) { $o.Clock = $Clock.Fn }
        $o
    }
    function Use-Store([scriptblock]$Body, $Clock = $null) {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 8 $Clock))
        try { & $Body $s $root } finally { $s.Dispose() }
    }
    function New-Msg([string]$Id, [string]$Created, [string]$Lm = $null, [string]$Body = 'hello', [string]$From = $null, [string]$FromType = 'aadUser') {
        $o = [ordered]@{ id = $Id; createdDateTime = $Created }
        if ($Lm) { $o.lastModifiedDateTime = $Lm }
        if ($From) { $o.from = @{ user = @{ id = $From; displayName = "User $From"; userIdentityType = $FromType } } }
        $o.body = @{ contentType = 'html'; content = $Body }
        [Text.Json.JsonDocument]::Parse(($o | ConvertTo-Json -Depth 6 -Compress)).RootElement
    }
    function Add-Msgs($Store, [string]$Key, $Messages) {
        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
        foreach ($m in $Messages) { $l.Add($m) }
        $Store.AppendMessages($Key, $l)
    }
    function Get-Ids($Store, [string]$Key) { @($Store.ReadMessages($Key) | ForEach-Object { $_.GetProperty('id').GetString() }) }
    function Member([string]$Type, [string]$Identity, [int]$Priority = 100) { [TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::$Type, $Identity, $Priority) }
    function Lot($s, [string]$Name, $Members, $AsOf = $script:AsOf) {
        $o = [TeamsTransfer.LotOptions]::new(); $o.AsOfUtc = $AsOf
        $s.CreateLot($Name, [TeamsTransfer.LotMember[]]@($Members), $o)
    }
    function Conv([string]$Key, [string]$Kind, [string]$Created, [string]$Last, [string]$Team = $null, [string]$Channel = $null) {
        $c = [TeamsTransfer.ConversationRecord]::new(); $c.Key = $Key; $c.Kind = $Kind; $c.TeamId = $Team; $c.ChannelId = $Channel
        if ($Created) { $c.CreatedUtc = [DateTimeOffset]::Parse($Created) }
        if ($Last) { $c.LastActivityUtc = [DateTimeOffset]::Parse($Last) }
        $c
    }
    function Initialize-Inventory($s) {
        $users = foreach ($u in 'u1', 'u2', 'u3') { $r = [TeamsTransfer.UserRecord]::new(); $r.Id = $u; $r.UserPrincipalName = "$u@contoso.com"; $r.DisplayName = "User $u"; $r.State = 'Active'; $r }
        $del = [TeamsTransfer.UserRecord]::new(); $del.Id = 'del1'; $del.DisplayName = 'Deleted One'; $del.State = 'Deleted'
        $s.UpsertUsers([TeamsTransfer.UserRecord[]]@($users + $del))
        $convs = @(
            (Conv 'chat:g1' 'Group' '2023-01-01T00:00:00Z' '2026-10-01T00:00:00Z'),
            (Conv 'chat:o1' 'OneOnOne' '2022-01-01T00:00:00Z' '2026-09-01T00:00:00Z'),
            (Conv 'chat:old' 'OneOnOne' '2021-01-01T00:00:00Z' '2023-06-01T00:00:00Z'),
            (Conv 'chat:mid' 'OneOnOne' '2023-01-01T00:00:00Z' '2025-06-01T00:00:00Z'),    # last activity 2025-06: in wave 1 and wave 2? (2024-11-09 .. open) -> wave 1 only
            (Conv 'chat:mid2' 'OneOnOne' '2023-01-01T00:00:00Z' '2024-06-01T00:00:00Z'),   # last activity 2024-06: wave 2 only (2023-11-09 .. 2024-11-09)
            (Conv 'chat:new' 'OneOnOne' '2026-10-01T00:00:00Z' '2026-10-20T00:00:00Z'),
            (Conv 'channel:T1/C1' 'Channel' '2022-01-01T00:00:00Z' '2026-10-05T00:00:00Z' 'T1' 'C1'),
            (Conv 'channel:T1/C2' 'Channel' '2022-01-01T00:00:00Z' '2026-10-05T00:00:00Z' 'T1' 'C2'),
            (Conv 'channel:T2/C9' 'Channel' '2022-01-01T00:00:00Z' '2026-10-05T00:00:00Z' 'T2' 'C9'))
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]$convs)
        $s.LinkUserConversations('u1', [string[]]@('chat:g1', 'chat:o1', 'chat:old', 'chat:mid', 'chat:mid2', 'chat:new', 'channel:T1/C1', 'channel:T1/C2'))
        $s.LinkUserConversations('u2', [string[]]@('chat:g1', 'channel:T1/C1'))
        $s.LinkUserConversations('u3', [string[]]@('chat:o1'))
    }
    function Keys($items) { @($items | ForEach-Object { "$($_.ConversationKey)#$($_.SliceNo)" } | Sort-Object) }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Lots and slices' {
    It 'freezes the slices at creation: wave 1 = last 24 months (open ended), then 25-36, 37-48, 49-60' {
        Use-Store {
            param($s)
            $id = Lot $s 'L1' @((Member User 'u1'))
            $sl = @($s.ListSlices($id))
            $sl.Count | Should -Be 4
            $sl[0].FromUtc | Should -Be $script:AsOf.AddMonths(-24); $sl[0].ToUtc | Should -BeNullOrEmpty
            $sl[1].FromUtc | Should -Be $script:AsOf.AddMonths(-36); $sl[1].ToUtc | Should -Be $script:AsOf.AddMonths(-24)
            $sl[3].FromUtc | Should -Be $script:AsOf.AddMonths(-60); $sl[3].ToUtc | Should -Be $script:AsOf.AddMonths(-48)
            $s.GetLot($id).State | Should -Be 'Planned'
            $s.GetLot('L1').Id | Should -Be $id
            @($s.ListLotMembers($id)).Count | Should -Be 1
            # configurable
            $o = [TeamsTransfer.LotOptions]::new(); $o.AsOfUtc = $script:AsOf; $o.Boundaries = [int[]]@(12, 24)
            $id2 = $s.CreateLot('L2', [TeamsTransfer.LotMember[]]@((Member User 'u1')), $o)
            @($s.ListSlices($id2)).Count | Should -Be 2
            @($s.ListSlices($id2))[0].FromUtc | Should -Be $script:AsOf.AddMonths(-12)
        }
    }

    It 'refuses duplicate names, empty lots and bad boundaries' {
        Use-Store {
            param($s)
            Lot $s 'L1' @((Member User 'u1')) | Out-Null
            { Lot $s 'L1' @((Member User 'u2')) } | Should -Throw '*already exists*'
            { $s.CreateLot('E', [TeamsTransfer.LotMember[]]@(), $null) } | Should -Throw '*at least one member*'
            $o = [TeamsTransfer.LotOptions]::new(); $o.Boundaries = [int[]]@(24, 12)
            { $s.CreateLot('B', [TeamsTransfer.LotMember[]]@((Member User 'u1')), $o) } | Should -Throw '*increasing*'
        }
    }

    It 'resolves a user lot into conversations x slice 1, skipping conversations with nothing in the slice' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'U1' @((Member User 'u1'))
            $r = $s.ResolveLot($id)
            $r.ConversationsMatched | Should -Be 8
            Keys ($s.ListItems($id)) | Should -Be @('channel:T1/C1#1', 'channel:T1/C2#1', 'chat:g1#1', 'chat:mid#1', 'chat:new#1', 'chat:o1#1')
            $r.Planned | Should -Be 6
            $r.NothingInSlice | Should -Be 2          # old (silent since 2023-06) and mid2 (silent since 2024-06) have nothing in the last 24 months
        }
    }

    It 'plans a conversation created inside the window and ignores wave-2 only conversations in wave 1' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'U1' @((Member User 'u1'))
            $s.ResolveLot($id, 1) | Out-Null
            $k = Keys ($s.ListItems($id, 1))
            $k | Should -Contain 'chat:new#1'
            $k | Should -Not -Contain 'chat:mid2#1'
            $k | Should -Not -Contain 'chat:old#1'
            $r2 = $s.ResolveLot($id, 2)
            Keys ($s.ListItems($id, 2)) | Should -Be @('channel:T1/C1#2', 'channel:T1/C2#2', 'chat:g1#2', 'chat:mid#2', 'chat:mid2#2', 'chat:o1#2')    # not new (created after the slice) nor old (silent before it)
            $r2.Slices | Should -Be @(2)
        }
    }

    It 'resolves Team, Chat and Channel members, handles id/UPN/prefixed identities and reports unknown ones' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'Mixed' @((Member Team 'T1'), (Member Chat 'g1'), (Member Chat 'chat:o1'), (Member Channel 'T2/C9'), (Member User 'U3@CONTOSO.COM'), (Member User 'ghost-user'), (Member Channel 'T9/C9'))
            $r = $s.ResolveLot($id)
            Keys ($s.ListItems($id)) | Should -Be @('channel:T1/C1#1', 'channel:T1/C2#1', 'channel:T2/C9#1', 'chat:g1#1', 'chat:o1#1')
            ($r.Unresolved | Sort-Object) | Should -Be @('Channel:T9/C9', 'User:ghost-user')
        }
    }

    It 'orders by priority (lower first) and keeps the smallest priority of a conversation reached twice' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'Prio' @((Member User 'u1' 50), (Member Chat 'o1' 1), (Member Team 'T1' 10))
            $s.ResolveLot($id) | Out-Null
            $items = @($s.ListItems($id))
            $items[0].ConversationKey | Should -Be 'chat:o1'; $items[0].Priority | Should -Be 1
            ($items | Where-Object ConversationKey -eq 'channel:T1/C1').Priority | Should -Be 10
            ($items | Where-Object ConversationKey -eq 'chat:g1').Priority | Should -Be 50
            ($items.Priority | Select-Object -First 3) | Should -Be @(1, 10, 10)
        }
    }

    It 'never plans a conversation/slice twice across overlapping lots ("covered")' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $a = Lot $s 'A' @((Member User 'u1'))
            $b = Lot $s 'B' @((Member User 'u2'), (Member Team 'T1'))
            $ra = $s.ResolveLot($a)
            $rb = $s.ResolveLot($b)
            $ra.Planned | Should -Be 6
            # u2: chat:g1 + channel:T1/C1 ; team T1: C1 + C2 : all three conversations are already covered by A
            $rb.Planned | Should -Be 0
            $rb.CoveredByOtherLot | Should -Be 3
            @($s.ListItems($b)).Count | Should -Be 0
            # re-resolving the same lot changes nothing
            $ra2 = $s.ResolveLot($a)
            $ra2.Planned | Should -Be 0; $ra2.AlreadyPlanned | Should -Be 6
            # a lot built first would have won: order decides, never both
            $others = @($s.ItemsOfConversation('chat:g1'))
            $others.Count | Should -Be 1
            $others[0].LotId | Should -Be $a
            # a deleted planned lot releases its coverage
            $s.DeletePlannedLot($a)
            $s.ResolveLot($b).Planned | Should -Be 3
        }
    }

    It 'cuts a slice into fragments when another lot covers only part of its interval' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $a = Lot $s 'A' @((Member Chat 'g1'))
            $s.ResolveLot($a) | Out-Null          # covers [asOf-24m, open)
            $c = Lot $s 'C' @((Member Chat 'g1')) $script:AsOf.AddMonths(-6)    # wave 1 of C = [asOf-30m, open)
            $r = $s.ResolveLot($c)
            $r.Planned | Should -Be 1
            $it = @($s.ListItems($c))[0]
            $it.FromUtc | Should -Be $script:AsOf.AddMonths(-30)
            $it.ToUtc | Should -Be $script:AsOf.AddMonths(-24)
            # the middle of a covered range is left out: A' covers [-30m,-24m), D wants [-36m, -24m) in its wave 2 -> only [-36m,-30m) is new
        }
    }

    It 'estimates the messages held for a lot' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            Add-Msgs $s 'chat:g1' @(1..30 | ForEach-Object { New-Msg "m$_" '2026-01-01T00:00:00Z' }) | Out-Null
            Add-Msgs $s 'chat:o1' @(1..12 | ForEach-Object { New-Msg "m$_" '2026-01-01T00:00:00Z' }) | Out-Null
            $id = Lot $s 'U1' @((Member User 'u1'))
            $s.ResolveLot($id) | Out-Null
            $s.EstimateLotMessages($id) | Should -Be 42
        }
    }

    It 'reopens a Closed lot to Planned when an extension wave is resolved' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'Ext' @((Member User 'u1'))
            $s.ResolveLot($id, 1) | Out-Null
            foreach ($st in 'Exporting', 'Exported', 'ImportPlanned', 'Importing', 'Completing', 'Verified', 'Closed') { $s.TransitionLot($id, $st) | Out-Null }
            $s.GetLot($id).State | Should -Be 'Closed'
            $r = $s.ResolveLot($id, 2)
            $r.Reopened | Should -BeTrue
            $s.GetLot($id).State | Should -Be 'Planned'
            (@($s.LotHistory($id)) | Select-Object -Last 1).Note | Should -BeLike 'reopened*'
        }
    }
}

Describe 'Lifecycle' {
    It 'walks Planned -> ... -> Closed with timestamps and history' {
        $clock = [TmtTestClock]::new()
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts 8 $clock))
        try {
            $id = Lot $s 'Life' @((Member User 'u1'))
            $chain = 'Exporting', 'Exported', 'ImportPlanned', 'Ghosts', 'Files', 'Importing', 'Completing', 'Verified', 'Closed'
            foreach ($st in $chain) { $clock.Advance([TimeSpan]::FromMinutes(5)); $s.TransitionLot($id, $st, "to $st").State | Should -Be $st }
            $h = @($s.LotHistory($id))
            $h.Count | Should -Be 10
            $h[0].From | Should -BeNullOrEmpty; $h[0].To | Should -Be 'Planned'
            $h[-1].To | Should -Be 'Closed'; $h[-1].From | Should -Be 'Verified'
            $h[-1].AtUtc | Should -BeGreaterThan $h[1].AtUtc
            $s.GetLot($id).StateChangedUtc | Should -Be $clock.Now
        } finally { $s.Dispose() }
    }

    It 'allows skipping Ghosts/Files and a delta pass, and refuses illegal transitions' {
        Use-Store {
            param($s)
            $id = Lot $s 'Rules' @((Member User 'u1'))
            { $s.TransitionLot($id, 'Importing') } | Should -Throw '*Illegal lot transition Planned -> Importing*'
            { $s.TransitionLot($id, 'Planned') } | Should -Throw '*Illegal*'
            { $s.TransitionLot($id, 'Closed') } | Should -Throw '*Illegal*'
            $s.TransitionLot($id, 'Exporting') | Out-Null
            { $s.TransitionLot($id, 'Verified') } | Should -Throw '*Illegal*'
            $s.TransitionLot($id, 'Exported') | Out-Null
            $s.TransitionLot($id, 'Exporting', 'delta pass') | Out-Null          # allowed
            $s.TransitionLot($id, 'Exported') | Out-Null
            $s.TransitionLot($id, 'ImportPlanned') | Out-Null
            $s.TransitionLot($id, 'Importing') | Out-Null                         # Ghosts and Files skipped
            { $s.TransitionLot($id, 'Verified') } | Should -Throw '*Illegal*'    # Completing first
            $s.TransitionLot($id, 'Completing') | Out-Null
            $s.TransitionLot($id, 'Importing', 'more messages') | Out-Null       # re-run
            $s.GetLot($id).State | Should -Be 'Importing'
            { $s.TransitionLot($id, 'Importing') } | Should -Throw '*Illegal*'
            { $s.TransitionLot($id, 'Exported', 'x', 'Planned') } | Should -Throw '*expected Planned*'
            { $s.TransitionLot(9999, 'Exporting') } | Should -Throw '*No lot*'
        }
    }

    It 'pauses and resumes only where it was; Failed retries where it was or restarts at Planned; Closed is final' {
        Use-Store {
            param($s)
            $id = Lot $s 'PF' @((Member User 'u1'))
            $s.TransitionLot($id, 'Exporting') | Out-Null
            $s.TransitionLot($id, 'Paused') | Out-Null
            { $s.TransitionLot($id, 'Exported') } | Should -Throw '*Illegal*'
            { $s.TransitionLot($id, 'Planned') } | Should -Throw '*Illegal*'
            $s.TransitionLot($id, 'Exporting') | Out-Null
            $s.TransitionLot($id, 'Failed', 'boom') | Out-Null
            $s.GetLot($id).PreviousState | Should -Be 'Exporting'
            { $s.TransitionLot($id, 'Exported') } | Should -Throw '*Illegal*'
            $s.TransitionLot($id, 'Planned', 'restart') | Out-Null
            $s.TransitionLot($id, 'Exporting') | Out-Null
            $s.TransitionLot($id, 'Failed') | Out-Null
            $s.TransitionLot($id, 'Exporting', 'retry') | Out-Null
            foreach ($st in 'Exported', 'ImportPlanned', 'Importing', 'Completing', 'Verified', 'Closed') { $s.TransitionLot($id, $st) | Out-Null }
            foreach ($st in 'Planned', 'Paused', 'Failed', 'Importing') { { $s.TransitionLot($id, $st) } | Should -Throw '*Illegal*' }
            { $s.DeletePlannedLot($id) } | Should -Throw '*Only a Planned lot*'
        }
    }

    It 'applies the lifecycle to items too' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            $id = Lot $s 'Items' @((Member Chat 'g1'))
            $s.ResolveLot($id) | Out-Null
            $s.SetItemState($id, 'chat:g1', 1, 0, 'Exporting')
            { $s.SetItemState($id, 'chat:g1', 1, 0, 'Closed') } | Should -Throw '*Illegal item transition*'
            $s.SetItemState($id, 'chat:g1', 1, 0, 'Exported')
            @($s.ListItems($id, $null, 'Exported')).Count | Should -Be 1
            @($s.ListItems($id, $null, 'Planned')).Count | Should -Be 0
            { $s.SetItemState($id, 'chat:nope', 1, 0, 'Exporting') } | Should -Throw '*No such item*'
        }
    }

    It 'persists lots across a reopen' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try { Initialize-Inventory $s; $id = Lot $s 'Keep' @((Member User 'u1')); $s.ResolveLot($id) | Out-Null; $s.TransitionLot($id, 'Exporting') | Out-Null } finally { $s.Dispose() }
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try {
            $l = $s.GetLot('Keep'); $l.State | Should -Be 'Exporting'
            @($s.ListItems($l.Id)).Count | Should -Be 6
        } finally { $s.Dispose() }
    }
}

Describe 'Work leases' {
    BeforeEach {
        $script:clock = [TmtTestClock]::new()
        $script:root = New-Root
        $script:s = [TeamsTransfer.TmtStore]::Open($script:root, (New-Opts 8 $script:clock))
        $convs = 1..25 | ForEach-Object { Conv "chat:c$_" 'Group' '2025-01-01T00:00:00Z' '2026-10-01T00:00:00Z' }
        $script:s.UpsertConversations([TeamsTransfer.ConversationRecord[]]$convs)
        $script:s.LinkUserConversations('u1', [string[]]($convs | ForEach-Object Key))
        $script:lot = Lot $script:s 'Leased' @((Member User 'u1'))
        $script:s.ResolveLot($script:lot) | Out-Null
    }
    AfterEach { $script:s.Dispose() }

    It 'cuts the lot into units of N conversations and hands them out once each' {
        $s = $script:s
        $s.PlanWorkUnits($script:lot, 'Export', 10) | Should -Be 3
        $s.PlanWorkUnits($script:lot, 'Export', 10) | Should -Be 0       # idempotent
        $ttl = [TimeSpan]::FromMinutes(10)
        $l1 = $s.AcquireLease('worker-1', 'Export', $ttl)
        $l2 = $s.AcquireLease('worker-2', 'Export', $ttl)
        $l3 = $s.AcquireLease('worker-1', 'Export', $ttl)
        $s.AcquireLease('worker-3', 'Export', $ttl) | Should -BeNullOrEmpty
        $s.AcquireLease('worker-3', 'Import', $ttl) | Should -BeNullOrEmpty
        @($l1.Id, $l2.Id, $l3.Id | Sort-Object -Unique).Count | Should -Be 3
        $l1.Attempt | Should -Be 1; $l1.LotId | Should -Be $script:lot
        $keys = foreach ($l in $l1, $l2, $l3) { (ConvertFrom-Json $l.PayloadJson).items | ForEach-Object { $_[0] } }
        @($keys).Count | Should -Be 25
        @($keys | Sort-Object -Unique).Count | Should -Be 25            # no conversation in two units
        $p = $s.GetWorkProgress()[0]
        $p.Kind | Should -Be 'Export'; $p.Leased | Should -Be 3; $p.Available | Should -Be 0
        $s.ReleaseLease($l1) | Should -BeTrue
        $s.GetWorkProgress()[0].Done | Should -Be 1
        $s.AcquireLease('worker-1', 'Export', $ttl) | Should -BeNullOrEmpty
    }

    It 'reclaims an expired lease for another worker and fences the stale one' {
        $s = $script:s
        $s.PlanWorkUnits($script:lot, 'Export', 100) | Out-Null
        $a = $s.AcquireLease('A', 'Export', [TimeSpan]::FromMinutes(5))
        $s.AcquireLease('B', 'Export', [TimeSpan]::FromMinutes(5)) | Should -BeNullOrEmpty       # still leased
        $script:clock.Advance([TimeSpan]::FromMinutes(3))
        $s.RenewLease($a, [TimeSpan]::FromMinutes(5)) | Should -BeTrue                            # worker is alive: extended to +8 min from t0
        $script:clock.Advance([TimeSpan]::FromMinutes(4))
        $s.AcquireLease('B', 'Export', [TimeSpan]::FromMinutes(5)) | Should -BeNullOrEmpty       # +7 min: renewed lease still valid
        $script:clock.Advance([TimeSpan]::FromMinutes(2))                                         # +9 min: expired
        $s.GetWorkProgress()[0].Expired | Should -Be 1
        $b = $s.AcquireLease('B', 'Export', [TimeSpan]::FromMinutes(5))
        $b.Id | Should -Be $a.Id; $b.Attempt | Should -Be 2; $b.WorkerId | Should -Be 'B'
        $s.RenewLease($a, [TimeSpan]::FromMinutes(5)) | Should -BeFalse                           # A lost it
        $s.ReleaseLease($a) | Should -BeFalse
        $s.RenewLease($b, [TimeSpan]::FromMinutes(5)) | Should -BeTrue
        $s.ReleaseLease($b) | Should -BeTrue
        $s.ReleaseLease($b) | Should -BeFalse                                                     # already done
        $s.AcquireLease('A', 'Export', [TimeSpan]::FromMinutes(5)) | Should -BeNullOrEmpty
    }

    It 'ReclaimExpiredLeases, Retry and Failed outcomes' {
        $s = $script:s
        $s.PlanWorkUnits($script:lot, 'Export', 10) | Out-Null
        $a = $s.AcquireLease('A', 'Export', [TimeSpan]::FromMinutes(1))
        $b = $s.AcquireLease('B', 'Export', [TimeSpan]::FromMinutes(1))
        $c = $s.AcquireLease('C', 'Export', [TimeSpan]::FromMinutes(1))
        $s.ReleaseLease($a, 'Retry', 'network down') | Should -BeTrue
        $s.ReleaseLease($b, 'Failed', 'bad data') | Should -BeTrue
        $script:clock.Advance([TimeSpan]::FromMinutes(2))
        $s.ReclaimExpiredLeases() | Should -Be 1            # c
        $p = $s.GetWorkProgress()[0]
        $p.Available | Should -Be 2; $p.Failed | Should -Be 1
        $again = $s.AcquireLease('D', 'Export', [TimeSpan]::FromMinutes(1))
        $again.Id | Should -Be $a.Id                         # lowest order first; the Failed unit is never handed out
        $again.Attempt | Should -Be 2
        $s.ResetWorkUnit($b.Id)
        $s.GetWorkProgress()[0].Failed | Should -Be 0
    }

    It 'does not hand out units of a Paused lot, and resumes after' {
        $s = $script:s
        $s.PlanWorkUnits($script:lot, 'Export', 100) | Out-Null
        $s.TransitionLot($script:lot, 'Paused') | Out-Null
        $s.AcquireLease('A', 'Export', [TimeSpan]::FromMinutes(5)) | Should -BeNullOrEmpty
        $s.TransitionLot($script:lot, 'Planned') | Out-Null
        $s.AcquireLease('A', 'Export', [TimeSpan]::FromMinutes(5)) | Should -Not -BeNullOrEmpty
    }

    It 'serves priorities first and mixes global units (partition ranges)' {
        $s = $script:s
        $s.PlanPartitionUnits('Verify', 3) | Should -Be 3       # 8 partitions: 0-2, 3-5, 6-7
        $s.PlanPartitionUnits('Verify', 3) | Should -Be 0
        $u = $s.AcquireLease('W', 'Verify', [TimeSpan]::FromMinutes(5))
        (ConvertFrom-Json $u.PayloadJson).partitions | Should -Be @(0, 2)
        $u.LotId | Should -BeNullOrEmpty
        $s.AddWorkUnit('Export', 'urgent', '{"x":1}', $null, 1, 99) | Should -BeGreaterThan 0
        $s.AddWorkUnit('Export', 'urgent', '{"x":1}', $null, 1, 99) | Should -Be 0
        $s.PlanWorkUnits($script:lot, 'Export', 100) | Out-Null
        $s.AcquireLease('W', 'Export', [TimeSpan]::FromMinutes(5)).UnitKey | Should -Be 'urgent'
    }

    It 'round-trips a lease as the work order file handed to a remote worker' {
        $s = $script:s
        $s.PlanWorkUnits($script:lot, 'Export', 5) | Out-Null
        $l = $s.AcquireLease('machine-2', 'Export', [TimeSpan]::FromHours(1))
        $back = [TeamsTransfer.WorkLease]::FromJson($l.ToJson())
        $back.Id | Should -Be $l.Id; $back.WorkerId | Should -Be 'machine-2'; $back.Attempt | Should -Be 1; $back.LotId | Should -Be $script:lot
        $back.ExpiresUtc | Should -Be $l.ExpiresUtc
        (ConvertFrom-Json $back.PayloadJson).items.Count | Should -Be 5
        $s.ReleaseLease($back) | Should -BeTrue
    }
}

Describe 'Import journal' {
    It 'resumes: next N pending messages of a conversation in a slice, in import order' {
        Use-Store {
            param($s)
            $ids = 1..10 | ForEach-Object { "m$_" }
            $s.SeedJournal('chat:g1', 1, [string[]]$ids) | Should -Be 10
            $s.SeedJournal('chat:g1', 1, [string[]]$ids) | Should -Be 0                   # idempotent
            $s.SeedJournal('chat:g1', 2, [string[]]@('old1', 'old2')) | Should -Be 2
            (@($s.NextPending('chat:g1', 1, 3)) | ForEach-Object SourceMessageId) | Should -Be @('m1', 'm2', 'm3')
            $sess = $s.BeginImportSession('chat:g1', 1, 'app-1', [DateTimeOffset]::Parse('2022-12-31T23:59:59Z'), 'target-chat-9')
            $s.MarkJournal([TeamsTransfer.JournalMark[]]@(
                    [TeamsTransfer.JournalMark]@{ ConversationKey = 'chat:g1'; SliceNo = 1; SourceMessageId = 'm1'; Status = 'Imported'; TargetMessageId = 't1'; SessionId = $sess },
                    [TeamsTransfer.JournalMark]@{ ConversationKey = 'chat:g1'; SliceNo = 1; SourceMessageId = 'm2'; Status = 'Conflict409TreatedAsImported'; ErrorCode = '409'; SessionId = $sess },
                    [TeamsTransfer.JournalMark]@{ ConversationKey = 'chat:g1'; SliceNo = 1; SourceMessageId = 'm3'; Status = 'Rejected'; ErrorCode = 'BadRequest' },
                    [TeamsTransfer.JournalMark]@{ ConversationKey = 'chat:g1'; SliceNo = 1; SourceMessageId = 'm4'; Status = 'Skipped'; ErrorCode = 'federated' }))
            (@($s.NextPending('chat:g1', 1, 3)) | ForEach-Object SourceMessageId) | Should -Be @('m5', 'm6', 'm7')
            @($s.NextPending('chat:g1', 1, 100)).Count | Should -Be 6
            (@($s.NextPending('chat:g1', 2, 100)) | ForEach-Object SourceMessageId) | Should -Be @('old1', 'old2')
            $sum = $s.GetJournalSummary('chat:g1', 1)
            function Cnt($n) { $sum[[TeamsTransfer.JournalStatus]$n] }
            (Cnt 'Imported') | Should -Be 1; (Cnt 'Conflict409TreatedAsImported') | Should -Be 1; (Cnt 'Rejected') | Should -Be 1; (Cnt 'Skipped') | Should -Be 1; (Cnt 'Pending') | Should -Be 6
            $e = $s.GetJournalEntry('chat:g1', 'm1')
            $e.TargetMessageId | Should -Be 't1'; $e.Attempts | Should -Be 1; $e.SessionId | Should -Be $sess
            $s.GetJournalEntry('chat:g1', 'm2').ErrorCode | Should -Be '409'
            $s.GetJournalEntry('chat:g1', 'm3').ErrorCode | Should -Be 'BadRequest'
        }
    }

    It 'never downgrades an imported message and keeps its target id' {
        Use-Store {
            param($s)
            $s.SeedJournal('chat:g1', 1, [string[]]@('m1', 'm2')) | Out-Null
            function Mark($id, $st, $t = $null) { $s.MarkJournal([TeamsTransfer.JournalMark]@{ ConversationKey = 'chat:g1'; SliceNo = 1; SourceMessageId = $id; Status = $st; TargetMessageId = $t }) }
            Mark 'm1' 'Imported' 'T1'
            Mark 'm1' 'Pending'; Mark 'm1' 'Rejected'; Mark 'm1' 'Skipped'
            $e = $s.GetJournalEntry('chat:g1', 'm1'); $e.Status | Should -Be 'Imported'; $e.TargetMessageId | Should -Be 'T1'
            Mark 'm1' 'Conflict409TreatedAsImported'           # still an imported status: allowed
            $s.GetJournalEntry('chat:g1', 'm1').Status | Should -Be 'Conflict409TreatedAsImported'
            $s.GetJournalEntry('chat:g1', 'm1').TargetMessageId | Should -Be 'T1'
            Mark 'm2' 'Rejected'; Mark 'm2' 'Pending'          # a rejected one may be retried
            $s.GetJournalEntry('chat:g1', 'm2').Status | Should -Be 'Pending'
            Mark 'late' 'Imported' 'T9'                        # not seeded: added
            $s.GetJournalEntry('chat:g1', 'late').Status | Should -Be 'Imported'
        }
    }

    It 'records migration sessions with owner app and creation date, and survives a reopen' {
        $root = New-Root
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try {
            $s.GetLatestImportSession('chat:g1', 1) | Should -BeNullOrEmpty
            $id1 = $s.BeginImportSession('chat:g1', 1, 'app-1', [DateTimeOffset]::Parse('2022-12-31T23:59:59Z'), 'tc')
            $s.CompleteImportSession($id1, 'Failed', 'timeout')
            $id2 = $s.BeginImportSession('chat:g1', 1, 'app-1', [DateTimeOffset]::Parse('2022-12-31T23:59:58Z'))
            $s.SeedJournal('chat:g1', 1, [string[]]@('a', 'b')) | Out-Null
        } finally { $s.Dispose() }
        $s = [TeamsTransfer.TmtStore]::Open($root, (New-Opts))
        try {
            $latest = $s.GetLatestImportSession('chat:g1', 1)
            $latest.State | Should -Be 'Started'; $latest.AppId | Should -Be 'app-1'; $latest.CompletedUtc | Should -BeNullOrEmpty
            $latest.ConversationCreationUtc | Should -Be ([DateTimeOffset]::Parse('2022-12-31T23:59:58Z'))
            $all = @($s.ListImportSessions('chat:g1'))
            $all.Count | Should -Be 2
            $all[0].State | Should -Be 'Failed'; $all[0].TargetConversationId | Should -Be 'tc'; $all[0].Note | Should -Be 'timeout'
            $s.CompleteImportSession($latest.Id)
            $s.GetLatestImportSession('chat:g1', 1).State | Should -Be 'Completed'
            (@($s.NextPending('chat:g1', 1, 10)) | ForEach-Object SourceMessageId) | Should -Be @('a', 'b')
        } finally { $s.Dispose() }
    }
}

Describe 'Ghost accounts' {
    It 'detects authors that are deleted or unknown, ignores known users and guests' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            Add-Msgs $s 'chat:g1' @(
                (New-Msg '1' '2026-01-01T00:00:00Z' -From 'u1'),
                (New-Msg '2' '2026-01-01T00:01:00Z' -From 'del1'),
                (New-Msg '3' '2026-01-01T00:02:00Z' -From 'gone-9'),
                (New-Msg '4' '2026-01-01T00:03:00Z' -From 'guest-1' -FromType 'anonymousGuest'),
                (New-Msg '5' '2026-01-01T00:04:00Z' -From 'gone-9')) | Out-Null
            $c = @($s.FindGhostCandidates())
            ($c.UserId | Sort-Object) | Should -Be @('del1', 'gone-9')
            ($c | Where-Object UserId -eq 'del1').Reason | Should -Be 'Deleted'
            ($c | Where-Object UserId -eq 'gone-9').Reason | Should -Be 'NotInInventory'
            ($c | Where-Object UserId -eq 'gone-9').FirstConversation | Should -Be 'chat:g1'
            ($c | Where-Object UserId -eq 'gone-9').DisplayName | Should -Be 'User gone-9'
            # direct feed (importer / other sources)
            $tl = [System.Collections.Generic.List[ValueTuple[string, string, string]]]::new(); $tl.Add([ValueTuple[string, string, string]]::new('other-1', 'Other One', 'aadUser')); $s.RegisterAuthors($tl)
            @($s.FindGhostCandidates()).Count | Should -Be 3
        }
    }

    It 'maps a deleted source user to ONE ghost for the whole project, with state and CSV export' {
        Use-Store {
            param($s)
            Initialize-Inventory $s
            Add-Msgs $s 'chat:g1' @((New-Msg '2' '2026-01-01T00:01:00Z' -From 'del1'), (New-Msg '3' '2026-01-01T00:02:00Z' -From 'gone-9')) | Out-Null
            $g = [TeamsTransfer.GhostRecord]::new(); $g.SourceUserId = 'del1'; $g.DisplayName = 'Deleted One (ancien)'; $g.State = 'Planned'; $g.UserPrincipalName = 'tt-ghost-ab12@target.com'
            $s.UpsertGhost($g)
            $s.GetGhost('del1').State | Should -Be 'Planned'; $s.GetGhost('del1').GhostId | Should -BeNullOrEmpty
            @($s.FindGhostCandidates() | ForEach-Object UserId) | Should -Be @('gone-9')       # planned ghost: already handled
            @($s.FindGhostCandidates($false) | ForEach-Object UserId | Sort-Object) | Should -Be @('del1', 'gone-9')
            $g.GhostId = 'ghost-aaa'; $g.State = 'Created'
            $s.UpsertGhost($g)
            $r = $s.GetGhost('del1'); $r.GhostId | Should -Be 'ghost-aaa'; $r.State | Should -Be 'Created'; $r.CreatedUtc | Should -Not -BeNullOrEmpty
            $g.GhostId = 'ghost-bbb'
            { $s.UpsertGhost($g) } | Should -Throw '*already has ghost ghost-aaa*'
            $g.GhostId = 'GHOST-AAA'; $s.UpsertGhost($g)       # same id: fine
            $s.SetGhostState('del1', 'Reactivated', 'found enabled')
            @($s.ListGhosts('Reactivated')).Count | Should -Be 1
            @($s.ListGhosts('Created')).Count | Should -Be 0
            { $s.SetGhostState('nobody', 'Failed') } | Should -Throw '*No ghost*'
            $csv = Join-Path $script:TempRoot 'ghosts.csv'
            $s.ExportGhostsCsv($csv) | Should -Be 1
            $rows = Import-Csv $csv
            $rows[0].SourceUserId | Should -Be 'del1'; $rows[0].GhostId | Should -Be 'ghost-aaa'; $rows[0].State | Should -Be 'Reactivated'; $rows[0].Error | Should -Be 'found enabled'
        }
    }
}

Describe 'Merge' {
    BeforeAll {
        function New-Worker([string]$Root, [switch]$Overlap) {
            $w = [TeamsTransfer.TmtStore]::Open($Root, (New-Opts 8))
            try {
                Initialize-Inventory $w
                $u9 = [TeamsTransfer.UserRecord]::new(); $u9.Id = 'u9'; $u9.DisplayName = 'Worker user'; $u9.State = 'Active'; $w.UpsertUsers([TeamsTransfer.UserRecord[]]@($u9))
                Add-Msgs $w 'chat:wk1' @(1..40 | ForEach-Object { New-Msg ('{0:D3}' -f $_) '2026-02-01T00:00:00Z' '2026-02-01T00:00:00Z' "worker $_" -From 'gone-9' }) | Out-Null
                Add-Msgs $w 'channel:T1/C1' @((New-Msg 'r1' '2026-02-01T10:00:00Z' '2026-02-01T10:00:00Z' 'root'), ([Text.Json.JsonDocument]::Parse('{"id":"r1a","replyToId":"r1","createdDateTime":"2026-02-01T10:05:00Z","body":{"content":"reply"}}').RootElement)) | Out-Null
                if ($Overlap) {
                    Add-Msgs $w 'chat:shared' @((New-Msg 'a' '2026-02-02T00:00:00Z' '2026-02-05T00:00:00Z' 'a newer on worker'), (New-Msg 'b' '2026-02-02T00:01:00Z' '2026-02-02T00:01:00Z' 'b same'), (New-Msg 'c' '2026-02-02T00:02:00Z' '2026-02-02T00:02:00Z' 'c only on worker')) | Out-Null
                }
                $ref = $w.PutContent([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('worker image')), 'image/png')
                $w.RecordHostedContent('chat:wk1', '001', 'h1', $ref)
                $f = [TeamsTransfer.FileRecord]::new(); $f.ConversationKey = 'chat:wk1'; $f.MessageId = '001'; $f.AttachmentId = 'att1'; $f.Status = 'Downloaded'; $f.Sha256 = $ref.Sha256; $f.Name = 'x.docx'
                $w.RecordFile($f)
                $w.SetCheckpoint('gam:u9', 'worker-link')
                $w.SetCheckpoint('gam:u1', 'worker-link-u1')
                $ref.Sha256
            } finally { $w.Dispose() }
        }
    }

    It 'folds a worker store into the coordinator: catalog, messages (version rules), content, files; twice changes nothing' {
        $rootA = New-Root; $rootB = New-Root
        $shaB = New-Worker $rootB -Overlap
        $a = [TeamsTransfer.TmtStore]::Open($rootA, (New-Opts 8))
        try {
            Add-Msgs $a 'chat:shared' @((New-Msg 'a' '2026-02-02T00:00:00Z' '2026-02-02T00:00:00Z' 'a old on coordinator'), (New-Msg 'b' '2026-02-02T00:01:00Z' '2026-02-02T00:01:00Z' 'b same'), (New-Msg 'z' '2026-02-02T00:03:00Z' '2026-02-02T00:03:00Z' 'z only on coordinator')) | Out-Null
            $a.SetCheckpoint('gam:u1', 'coordinator-link')
            $r = $a.Merge($rootB)
            $r.MessagesNew | Should -Be (40 + 2 + 1)         # wk1 + channel root/reply + shared/c
            $r.MessagesUpdated | Should -Be 1                # shared/a: the worker has the newer edit
            $r.MessagesUnchanged | Should -Be 1              # shared/b
            $r.ContentCopied | Should -Be 1
            $r.PartitionsMerged | Should -BeGreaterThan 0
            $r.Users | Should -BeGreaterThan 0; $r.Conversations | Should -BeGreaterThan 0

            $a.CountMessages('chat:wk1') | Should -Be 40
            Get-Ids $a 'chat:shared' | Should -Be @('a', 'b', 'c', 'z')
            ($a.ReadMessages('chat:shared') | Select-Object -First 1).GetProperty('body').GetProperty('content').GetString() | Should -Be 'a newer on worker'
            $a.GetMessageInfo('chat:shared', 'a').Versions | Should -Be 2
            Get-Ids $a 'channel:T1/C1' | Should -Be @('r1', 'r1a')
            @($a.ListUsers() | Where-Object Id -eq 'u9').Count | Should -Be 1
            $a.GetConversation('channel:T1/C1').TeamId | Should -Be 'T1'
            @($a.ListConversations('u1')).Count | Should -Be 8
            $a.GetCheckpoint('gam:u9') | Should -Be 'worker-link'
            $a.GetCheckpoint('gam:u1') | Should -Be 'coordinator-link'        # the coordinator wins
            $a.HasContent($shaB) | Should -BeTrue
            $a.FindHostedContent('chat:wk1', '001', 'h1') | Should -Be $shaB
            @($a.ListFiles('chat:wk1'))[0].Status | Should -Be 'Downloaded'
            @($a.FindGhostCandidates() | ForEach-Object UserId) | Should -Be @('gone-9')

            # idempotent
            $r2 = $a.Merge($rootB)
            $r2.MessagesNew | Should -Be 0; $r2.MessagesUpdated | Should -Be 0; $r2.MessagesUnchanged | Should -Be (40 + 2 + 3)
            $r2.ContentCopied | Should -Be 0; $r2.ContentPresent | Should -Be 1
            $a.CountMessages('chat:wk1') | Should -Be 40
            $a.GetMessageInfo('chat:shared', 'a').Versions | Should -Be 2
            $a.Verify($true).Consistent | Should -BeTrue
        } finally { $a.Dispose() }
        # the merged data is on disk
        $a = [TeamsTransfer.TmtStore]::Open($rootA, (New-Opts 8))
        try { $a.CountMessages('chat:wk1') | Should -Be 40; $a.GetStats().Messages | Should -Be (40 + 2 + 4) } finally { $a.Dispose() }
    }

    It 'merges two workers one after the other (disjoint conversations)' {
        $rootA = New-Root; $rootB = New-Root; $rootC = New-Root
        New-Worker $rootB | Out-Null
        $c = [TeamsTransfer.TmtStore]::Open($rootC, (New-Opts 8))
        try { Add-Msgs $c 'chat:wk2' @(1..10 | ForEach-Object { New-Msg "x$_" '2026-03-01T00:00:00Z' }) | Out-Null } finally { $c.Dispose() }
        $a = [TeamsTransfer.TmtStore]::Open($rootA, (New-Opts 8))
        try {
            $a.Merge($rootB) | Out-Null; $a.Merge($rootC) | Out-Null
            $a.CountMessages('chat:wk1') | Should -Be 40; $a.CountMessages('chat:wk2') | Should -Be 10
        } finally { $a.Dispose() }
    }

    It 'refuses a self-merge, a missing store and a partition-count mismatch' {
        $rootA = New-Root; $rootB = New-Root
        $a = [TeamsTransfer.TmtStore]::Open($rootA, (New-Opts 8))
        try {
            { $a.Merge($rootA) } | Should -Throw '*into itself*'
            { $a.Merge((New-Root)) } | Should -Throw '*No store*'
            [TeamsTransfer.TmtStore]::Open($rootB, (New-Opts 4)).Dispose()
            { $a.Merge($rootB) } | Should -Throw '*Partition count mismatch*'
        } finally { $a.Dispose() }
    }
}
