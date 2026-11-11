#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests of Engine.FileCopy.cs (FileCopier) and Invoke-TmtFileCopy: destinations (sender's OneDrive, service account, channel folder), small and
# large (upload session) uploads, resume after an interruption, dedup, sharing, exclusions, dry run (zero requests), failures that do not stop the run,
# and a generated 1 GiB file streamed with low memory. Fake Graph wrapped by GfGraphTransport + a real TmtStore in a temp folder.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ct = [Threading.CancellationToken]::None
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tmt-filecopy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:TempRoot)
    $script:Stores = [Collections.Generic.List[object]]::new()
    $script:Now = [datetimeoffset]::UtcNow

    function New-FcEnv {
        param([int]$MaxAttempts = 2, [switch]$RefuseAll)
        $tenant = [TeamsTransfer.Testing.FakeTenant]::new(11, 'target.example')
        $e = [ordered]@{ Tenant = $tenant }
        $e.Alice = $tenant.AddUser('alice@target.example', 'Alice A')
        $e.Bob = $tenant.AddUser('bob@target.example', 'Bob B')
        $e.Carol = $tenant.AddUser('carol@target.example', 'Carol C')
        $e.Svc = $tenant.AddUser('svc@target.example', 'Service Account')
        $e.Team = $tenant.AddTeam('Target Team', [TeamsTransfer.Testing.FakeUser[]]@($e.Alice, $e.Bob), $script:Now.AddYears(-3))
        $e.Chan = $tenant.AddChannel($e.Team, 'General', [TeamsTransfer.Testing.FakeChannelType]::Standard, $null, $script:Now.AddYears(-3))
        $e.Chat = $tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::Group, [TeamsTransfer.Testing.FakeUser[]]@($e.Alice, $e.Bob, $e.Carol), 'Project', $script:Now.AddYears(-1))
        $e.Chat2 = $tenant.AddChat([TeamsTransfer.Testing.FakeChatType]::Group, [TeamsTransfer.Testing.FakeUser[]]@($e.Alice, $e.Carol), 'Other', $script:Now.AddYears(-1))
        $fake = [TeamsTransfer.Testing.FakeGraphTransport]::new($tenant)
        $e.Gf = [TeamsTransfer.Testing.GfGraphTransport]::new($fake, $tenant)
        $o = [TeamsTransfer.GraphClientOptions]::new()
        $o.Clock = [TeamsTransfer.TestManualClock]::new(); $o.MaxAttempts = $MaxAttempts
        $o.BaseBackoff = [TimeSpan]::FromSeconds(1); $o.MaxBackoff = [TimeSpan]::FromSeconds(2); $o.Random = [TeamsTransfer.TestFuncs]::Const(0.0)
        $e.Client = [TeamsTransfer.GraphClient]::new($(if ($RefuseAll) { [TeamsTransfer.RefusingTransport]::new() } else { $e.Gf }), $o, $null)
        $root = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $e.Root = $root
        $e.Store = Open-TmtStore -Root $root -Partitions 4
        $script:Stores.Add($e.Store)
        $e.Ids = [TeamsTransfer.Testing.GfIdentityMap]::new(); $e.Targets = [TeamsTransfer.Testing.GfTargetMap]::new(); $e.Files = [TeamsTransfer.Testing.GfFileCopyMap]::new()
        [void]$e.Ids.Add('src-alice', 'Alice', [TeamsTransfer.IdentityKind]::Mapped, $e.Alice.Id)
        [void]$e.Ids.Add('src-bob', 'Bob', [TeamsTransfer.IdentityKind]::Same, $e.Bob.Id)
        $e.Ghost = $e.Gf.SeedUser('tt-ghost-0123456789abcdef@target.example', 'Gone Person (former)', $false, 'TeamsTransferGhost')
        [void]$e.Ids.Add('src-gone', 'Gone Person', [TeamsTransfer.IdentityKind]::Ghost, $e.Ghost.Id)
        [void]$e.Ids.Add('src-svc', 'Leaver', [TeamsTransfer.IdentityKind]::ServiceAccount, $e.Svc.Id)
        $e.Run = [TeamsTransfer.ImportRunOptions]::new(); $e.Run.ServiceAccountUserId = $e.Svc.Id
        $e.ChatKey = 'chat:SRC-CHAT-1'; $e.Chat2Key = 'chat:SRC-CHAT-2'; $e.ChanKey = 'channel:SRC-TEAM/SRC-CHAN'
        $t = [TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = $e.Chat.Id }
        $t.TargetMemberIds.AddRange([string[]]@($e.Alice.Id, $e.Bob.Id, $e.Carol.Id, $e.Ghost.Id, $e.Svc.Id)); $e.Targets.Upsert($t)
        $t2 = [TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.Chat2Key; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = $e.Chat2.Id }
        $t2.TargetMemberIds.AddRange([string[]]@($e.Alice.Id, $e.Carol.Id)); $e.Targets.Upsert($t2)
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChanKey; Kind = [TeamsTransfer.TargetKind]::ExistingChannel; TargetTeamId = $e.Team.Id; TargetChannelId = $e.Chan.Id })
        [pscustomobject]$e
    }

    function New-Bytes([int]$Length, [int]$Seed = 1) { $b = [byte[]]::new($Length); [Random]::new($Seed).NextBytes($b); , $b }

    function Add-Message($E, [string]$Key, [string]$Id, [datetimeoffset]$When, [string]$From) {
        $o = [ordered]@{ id = $Id; createdDateTime = $When.UtcDateTime.ToString('yyyy-MM-dd''T''HH:mm:ss.fff''Z'''); body = @{ contentType = 'html'; content = 'file' } }
        if ($From) { $o.from = @{ user = @{ id = $From; displayName = $From; userIdentityType = 'aadUser' } } }
        $l = [Collections.Generic.List[Text.Json.JsonElement]]::new()
        $l.Add([Text.Json.JsonDocument]::Parse(($o | ConvertTo-Json -Depth 6 -Compress)).RootElement)
        [void]$E.Store.AppendMessages($Key, $l)
    }

    # A message with one downloaded attachment: the content in the store, the FileRecord Downloaded. Returns the sha256.
    function Add-SourceFile {
        param($E, [string]$Key, [string]$MessageId, [string]$Name, $Bytes, [string]$From = 'src-alice', [datetimeoffset]$When = $script:Now.AddDays(-5), [string]$AttachmentId = 'att1', [long]$Size = -1, [switch]$NoContent, [string]$Sha)
        Add-Message $E $Key $MessageId $When $From
        if (-not $NoContent) {
            $ms = [IO.MemoryStream]::new([byte[]]$Bytes)
            $c = $E.Store.PutContent($ms, 'application/octet-stream'); $Sha = $c.Sha256; $len = $c.Length
        } else { $len = [long]$Size }
        $f = [TeamsTransfer.FileRecord]@{ ConversationKey = $Key; MessageId = $MessageId; AttachmentId = $AttachmentId; Name = $Name; Size = $len; Status = [TeamsTransfer.FileStatus]::Downloaded; Sha256 = $Sha }
        $E.Store.RecordFile($f)
        $Sha
    }

    function Invoke-Copy {
        param($E, [switch]$Apply, [scriptblock]$Configure, $Scopes = $null, [int]$Parallelism = 1)
        $E.Run.Apply = [bool]$Apply
        $o = [TeamsTransfer.FileCopyOptions]::new(); $o.Parallelism = $Parallelism
        if ($Configure) { & $Configure $o }
        $c = [TeamsTransfer.FileCopier]::new($E.Client, $E.Store, $E.Ids, $E.Targets, $E.Files, $E.Run, $o)
        $c.RunAsync($Scopes, $script:ct).GetAwaiter().GetResult()
    }
    function Get-FakeItem($E, $Record) { $E.Tenant.Drives[$Record.TargetDriveId].Items[$Record.TargetItemId] }
    function Get-Sha([byte[]]$b) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b)).ToLowerInvariant() }
    function Get-Grantees($E, $Item) { @($Item.Permissions | ForEach-Object { $E.Tenant.Users[$_.UserOrd].Id }) }
}

AfterAll {
    foreach ($s in $script:Stores) { try { $s.Dispose() } catch { } }
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Small files' {
    It 'puts a chat file in the sender''s OneDrive "Microsoft Teams Chat Files", then shares it read-only with the other members (no e-mail)' {
        $e = New-FcEnv
        $bytes = New-Bytes 20000 3
        $sha = Add-SourceFile $e $e.ChatKey 'm1' 'report.pdf' $bytes
        $r = Invoke-Copy $e -Apply
        $r.Files | Should -Be 1
        $r.Uploaded | Should -Be 1
        $r.Shared | Should -Be 1
        $r.Failed | Should -Be 0
        $rec = $e.Files.Get($e.ChatKey, 'm1', 'att1')
        [string]$rec.State | Should -Be 'Shared'
        $rec.Sha256 | Should -Be $sha
        $rec.TargetItemId | Should -Not -BeNullOrEmpty
        $rec.TargetWebUrl | Should -Match 'Microsoft%20Teams%20Chat%20Files/report\.pdf'
        $item = Get-FakeItem $e $rec
        $item.DriveId | Should -Be $e.Tenant.UserDrive($e.Alice).Id
        $item.FolderPath | Should -Be '/Microsoft Teams Chat Files'
        (Get-Sha $item.Bytes) | Should -Be $sha
        $g = Get-Grantees $e $item
        $g | Should -Contain $e.Bob.Id
        $g | Should -Contain $e.Carol.Id
        $g | Should -Not -Contain $e.Alice.Id             # the owner
        $g | Should -Not -Contain $e.Ghost.Id             # an unlicensed ghost cannot use it
        $g | Should -Not -Contain $e.Svc.Id
        foreach ($p in $item.Permissions) { $p.Roles | Should -Be 'read' }
        $inv = @($e.Gf.Requests | Where-Object { $_.Path -match '/invite$' })
        $inv.Count | Should -Be 1
        $inv[0].Body | Should -Match '"sendInvitation":false'
        $inv[0].Body | Should -Match '"requireSignIn":true'
    }
    It 'sends the file of a ghost or service-account sender to the service account''s OneDrive' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'g1' 'ghost.txt' (New-Bytes 500 4) 'src-gone')
        [void](Add-SourceFile $e $e.ChatKey 's1' 'svc.txt' (New-Bytes 500 5) 'src-svc')
        [void](Add-SourceFile $e $e.ChatKey 'u1' 'unknown.txt' (New-Bytes 500 6) 'src-nobody')
        $r = Invoke-Copy $e -Apply
        $r.Uploaded | Should -Be 3
        $svcDrive = $e.Tenant.UserDrive($e.Svc).Id
        foreach ($m in 'g1', 's1', 'u1') { (Get-FakeItem $e ($e.Files.Get($e.ChatKey, $m, 'att1'))).DriveId | Should -Be $svcDrive }
        (Get-Grantees $e (Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'g1', 'att1')))) | Should -Contain $e.Alice.Id
    }
    It 'puts a channel file in the target channel''s files folder and does not invite anybody (the folder permissions apply)' {
        $e = New-FcEnv
        $sha = Add-SourceFile $e $e.ChanKey 'c1' 'plan.docx' (New-Bytes 9000 7)
        $r = Invoke-Copy $e -Apply
        $r.Uploaded | Should -Be 1
        $r.Shared | Should -Be 1
        $rec = $e.Files.Get($e.ChanKey, 'c1', 'att1')
        [string]$rec.State | Should -Be 'Shared'
        $item = Get-FakeItem $e $rec
        $item.DriveId | Should -Be $e.Team.Drive.Id
        $item.FolderPath | Should -Be '/General'
        (Get-Sha $item.Bytes) | Should -Be $sha
        $e.Gf.Count('POST', '/invite$') | Should -Be 0
        $e.Gf.Count('GET', 'filesFolder$') | Should -Be 1
    }
    It 'sanitises a file name the service would refuse' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'n1' 'a:b*c?.txt  ' (New-Bytes 100 8))
        $r = Invoke-Copy $e -Apply
        $r.Failed | Should -Be 0
        (Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'n1', 'att1'))).Name | Should -Be 'a_b_c_.txt'
    }
}

Describe 'Large files: upload session' {
    It 'sends fragments that are multiples of 320 KiB (the last one excepted), anonymously, and the bytes arrive intact' {
        $e = New-FcEnv
        $bytes = New-Bytes (9 * 1024 * 1024 + 12345) 9
        $sha = Add-SourceFile $e $e.ChatKey 'big' 'video.bin' $bytes
        $r = Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 3 * 327680 }
        $r.Uploaded | Should -Be 1
        $r.Failed | Should -Be 0
        $r.Bytes | Should -Be $bytes.Length
        $sizes = @($e.Gf.FragmentSizes)
        $sizes.Count | Should -BeGreaterThan 8
        foreach ($s in $sizes[0..($sizes.Count - 2)]) { $s % 327680 | Should -Be 0; $s | Should -BeLessOrEqual (3 * 327680) }
        $e.Gf.SessionCreates | Should -Be 1
        $put = @($e.Gf.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Path -like '*up/*' })
        $put.Count | Should -Be $sizes.Count
        foreach ($p in $put) { $p.Anonymous | Should -BeTrue }
        foreach ($p in @($e.Gf.Requests | Where-Object { $_.Path -like 'drives/*' -or $_.Path -like 'users/*' })) { $p.Anonymous | Should -BeFalse }
        $item = Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'big', 'att1'))
        $item.Size | Should -Be $bytes.Length
        (Get-Sha $item.Bytes) | Should -Be $sha
    }
    It 'uses a session for everything above the small-file limit and a single PUT below it' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'a' 'small.bin' (New-Bytes 1000 1))
        [void](Add-SourceFile $e $e.ChatKey 'b' 'edge.bin' (New-Bytes 4096 2))
        $r = Invoke-Copy $e -Apply { param($o) $o.SmallFileLimit = 4096 }
        $r.Uploaded | Should -Be 2
        $e.Gf.SessionCreates | Should -Be 1                    # 4096 is not below the limit
        $e.Gf.Count('PUT', ':/content$') | Should -Be 1
    }
    It 'renames instead of overwriting when two different files have the same name in the same folder' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'x1' 'same.bin' (New-Bytes 2000 11))
        [void](Add-SourceFile $e $e.ChatKey 'x2' 'same.bin' (New-Bytes 2000 12))
        $r = Invoke-Copy $e -Apply { param($o) $o.SmallFileLimit = 0 }
        $r.Uploaded | Should -Be 2
        $names = @($e.Tenant.UserDrive($e.Alice).Items.Values | Where-Object { -not $_.IsFolder } | ForEach-Object Name | Sort-Object)
        $names | Should -Be @('same 1.bin', 'same.bin')
    }
}

Describe 'Resume' {
    It 'continues an interrupted upload from the session''s next range after a restart (the session is not recreated)' {
        $e = New-FcEnv
        $bytes = New-Bytes (6 * 1024 * 1024) 13
        $sha = Add-SourceFile $e $e.ChatKey 'big' 'archive.bin' $bytes
        $total = [math]::Ceiling($bytes.Length / (2 * 327680))
        $e.Gf.FailFragmentsAfter = 3
        $r1 = Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 2 * 327680; $o.FragmentAttempts = 2 }
        $r1.Failed | Should -Be 1
        [string]$e.Files.Get($e.ChatKey, 'big', 'att1').State | Should -Be 'Failed'
        $e.Gf.FragmentsOk | Should -Be 3
        $e.Gf.SessionCreates | Should -Be 1
        $e.Tenant.UserDrive($e.Alice).Items.Values | Where-Object { $_.Name -eq 'archive.bin' } | Should -BeNullOrEmpty
        # the process "restarts": a new FileCopier over the same store and maps, the network is back
        $e.Gf.FailFragmentsAfter = -1
        $r2 = Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 2 * 327680 }
        $r2.Failed | Should -Be 0
        $r2.Uploaded | Should -Be 1
        $r2.ResumedUploads | Should -Be 1
        $e.Gf.SessionCreates | Should -Be 1
        $e.Gf.FragmentsOk | Should -Be $total               # the first three fragments were not sent again
        $item = Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'big', 'att1'))
        (Get-Sha $item.Bytes) | Should -Be $sha
        [string]$e.Files.Get($e.ChatKey, 'big', 'att1').State | Should -Be 'Shared'
    }
    It 'starts a new session when the saved one has expired' {
        $e = New-FcEnv
        $bytes = New-Bytes (5 * 1024 * 1024) 14
        $sha = Add-SourceFile $e $e.ChatKey 'big' 'old.bin' $bytes
        $e.Gf.FailFragmentsAfter = 2
        [void](Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 2 * 327680; $o.FragmentAttempts = 2 })
        $e.Gf.FailFragmentsAfter = -1; $e.Gf.ExpireSessions = $true
        $r = Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 2 * 327680 }
        $r.Failed | Should -Be 0
        $r.ResumedUploads | Should -Be 0
        $e.Gf.SessionCreates | Should -Be 2
        (Get-Sha (Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'big', 'att1'))).Bytes) | Should -Be $sha
    }
    It 'survives failed fragments inside a run (status query, then the fragment is sent again) without failing the file' {
        $e = New-FcEnv -MaxAttempts 1
        $bytes = New-Bytes (5 * 1024 * 1024) 15
        $sha = Add-SourceFile $e $e.ChatKey 'big' 'flaky.bin' $bytes
        $e.Gf.FragmentFailuresLeft = 2
        $r = Invoke-Copy $e -Apply { param($o) $o.ChunkBytes = 2 * 327680; $o.FragmentAttempts = 5 }
        $r.Failed | Should -Be 0
        $r.Uploaded | Should -Be 1
        $e.Gf.UploadStatusGets | Should -BeGreaterOrEqual 2
        $e.Gf.SessionCreates | Should -Be 1
        (Get-Sha (Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'big', 'att1'))).Bytes) | Should -Be $sha
    }
    It 'leaves Shared records alone on a rerun (no request at all)' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.txt' (New-Bytes 100 1))
        [void](Invoke-Copy $e -Apply)
        $e.Gf.ClearLog()
        $r = Invoke-Copy $e -Apply
        $r.AlreadyDone | Should -Be 1
        $r.Uploaded | Should -Be 0
        $e.Gf.Requests.Count | Should -Be 0
    }
    It 'only shares a record that was uploaded but not shared (an earlier run was cut)' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.txt' (New-Bytes 100 1))
        [void](Invoke-Copy $e -Apply)
        $rec = $e.Files.Get($e.ChatKey, 'm1', 'att1')
        $rec.State = [TeamsTransfer.FileCopyState]::Uploaded; $e.Files.Upsert($rec)
        $e.Gf.ClearLog()
        $r = Invoke-Copy $e -Apply
        $r.Uploaded | Should -Be 0
        $r.Shared | Should -Be 1
        $e.Gf.Count('PUT', '.') | Should -Be 0
        $e.Gf.Count('POST', 'invite') | Should -BeGreaterThan 0
        [string]$e.Files.Get($e.ChatKey, 'm1', 'att1').State | Should -Be 'Shared'
    }
}

Describe 'Dedup' {
    It 'uploads the same content once per destination folder and still shares it with each chat''s members' {
        $e = New-FcEnv
        $bytes = New-Bytes 30000 21
        $sha1 = Add-SourceFile $e $e.ChatKey 'm1' 'copy.pdf' $bytes
        $sha2 = Add-SourceFile $e $e.Chat2Key 'm2' 'copy.pdf' $bytes
        $sha3 = Add-SourceFile $e $e.ChatKey 'm3' 'copy.pdf' $bytes 'src-bob'          # another sender: another folder
        $sha1 | Should -Be $sha2
        $r = Invoke-Copy $e -Apply
        $r.Files | Should -Be 3
        $r.Uploaded | Should -Be 2
        $r.Reused | Should -Be 1
        $a = $e.Files.Get($e.ChatKey, 'm1', 'att1'); $b = $e.Files.Get($e.Chat2Key, 'm2', 'att1'); $c = $e.Files.Get($e.ChatKey, 'm3', 'att1')
        $b.TargetItemId | Should -Be $a.TargetItemId
        $c.TargetItemId | Should -Not -Be $a.TargetItemId
        foreach ($x in $a, $b, $c) { [string]$x.State | Should -Be 'Shared' }
        $items = @($e.Tenant.UserDrive($e.Alice).Items.Values | Where-Object { -not $_.IsFolder })
        $items.Count | Should -Be 1
        $g = Get-Grantees $e $items[0]
        $g | Should -Contain $e.Bob.Id       # from the first chat
        $g | Should -Contain $e.Carol.Id     # from both
    }
    It 'reuses an item uploaded by an earlier run (checkpoint), after checking that it still exists, and uploads again when it is gone' {
        $e = New-FcEnv
        $bytes = New-Bytes 5000 22
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'x.bin' $bytes)
        [void](Invoke-Copy $e -Apply)
        [void](Add-SourceFile $e $e.Chat2Key 'm2' 'x.bin' $bytes)
        $e.Gf.ClearLog()
        $r = Invoke-Copy $e -Apply
        $r.Reused | Should -Be 1
        $r.Uploaded | Should -Be 0
        $e.Gf.Count('PUT', '.') | Should -Be 0
        # the item is deleted by somebody: the next file with the same content is uploaded again
        $first = Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'm1', 'att1'))
        $e.Tenant.RemoveItem($first)
        [void](Add-SourceFile $e $e.ChatKey 'm9' 'x.bin' $bytes)
        $r3 = Invoke-Copy $e -Apply
        $r3.Uploaded | Should -Be 1
    }
    It 'shares one in-flight upload between parallel workers' {
        $e = New-FcEnv
        $bytes = New-Bytes 8000 23
        foreach ($i in 1..8) { [void](Add-SourceFile $e $e.ChatKey "m$i" "same$i.bin" $bytes) }
        $r = Invoke-Copy $e -Apply -Parallelism 4
        $r.Failed | Should -Be 0
        ($r.Uploaded + $r.Reused) | Should -Be 8
        $r.Uploaded | Should -BeLessThan 8
    }
}

Describe 'Exclusions' {
    It 'honours the extension and size exclusions: Skipped records, nothing uploaded, and a rerun leaves them alone' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'i1' 'image.iso' (New-Bytes 100 1))
        [void](Add-SourceFile $e $e.ChatKey 'z1' 'big.bin' (New-Bytes 50000 2))
        [void](Add-SourceFile $e $e.ChatKey 'k1' 'keep.txt' (New-Bytes 100 3))
        $r = Invoke-Copy $e -Apply { param($o) $o.ExcludedExtensions = @('.iso'); $o.MaxFileBytes = 10000 }
        $r.Excluded | Should -Be 1
        $r.TooLarge | Should -Be 1
        $r.Skipped | Should -Be 2
        $r.Uploaded | Should -Be 1
        [string]$e.Files.Get($e.ChatKey, 'i1', 'att1').State | Should -Be 'Skipped'
        $e.Files.Get($e.ChatKey, 'i1', 'att1').Error | Should -Match 'excluded'
        [string]$e.Files.Get($e.ChatKey, 'z1', 'att1').State | Should -Be 'Skipped'
        [string]$e.Files.Get($e.ChatKey, 'k1', 'att1').State | Should -Be 'Shared'
        $r2 = Invoke-Copy $e -Apply { param($o) $o.ExcludedExtensions = @('.iso'); $o.MaxFileBytes = 10000 }
        $r2.AlreadyDone | Should -Be 3
    }
    It 'ignores a file that was not downloaded (NotFound, Forbidden...) and counts it' {
        $e = New-FcEnv
        Add-Message $e $e.ChatKey 'nf' $script:Now.AddDays(-1) 'src-alice'
        $e.Store.RecordFile([TeamsTransfer.FileRecord]@{ ConversationKey = $e.ChatKey; MessageId = 'nf'; AttachmentId = 'att1'; Name = 'lost.doc'; Status = [TeamsTransfer.FileStatus]::NotFound })
        $r = Invoke-Copy $e -Apply
        $r.Files | Should -Be 0
        $r.NotDownloaded | Should -Be 1
    }
}

Describe 'Failures never stop the run' {
    It 'records each failure on its file and carries on with the others' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'ok1' 'good1.txt' (New-Bytes 100 1))
        [void](Add-SourceFile $e $e.ChatKey 'lost' 'lost.txt' $null -NoContent -Size 100 -Sha ('a' * 64))           # content missing from the store
        [void]$e.Ids.Add('src-ghostless', 'Nobody', [TeamsTransfer.IdentityKind]::Mapped, '00000000-0000-0000-0000-000000000001')   # a target user that does not exist
        [void](Add-SourceFile $e $e.ChatKey 'nodrive' 'nodrive.txt' (New-Bytes 100 2) 'src-ghostless')
        [void](Add-SourceFile $e $e.ChatKey 'ok2' 'good2.txt' (New-Bytes 100 3))
        $r = Invoke-Copy $e -Apply
        $r.Files | Should -Be 4
        $r.Failed | Should -Be 2
        $r.Uploaded | Should -Be 2
        $r.Errors.Count | Should -Be 2
        [string]$e.Files.Get($e.ChatKey, 'lost', 'att1').State | Should -Be 'Failed'
        $e.Files.Get($e.ChatKey, 'lost', 'att1').Error | Should -Match 'not in the store'
        [string]$e.Files.Get($e.ChatKey, 'nodrive', 'att1').State | Should -Be 'Failed'
        $e.Files.Get($e.ChatKey, 'nodrive', 'att1').Error | Should -Match 'OneDrive'
        [string]$e.Files.Get($e.ChatKey, 'ok1', 'att1').State | Should -Be 'Shared'
        [string]$e.Files.Get($e.ChatKey, 'ok2', 'att1').State | Should -Be 'Shared'
    }
    It 'tries a Failed record again on the next run' {
        $e = New-FcEnv
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.txt' (New-Bytes 100 1))
        $e.Gf.FailFragmentsAfter = 0
        $e.Gf.TransientCreateFailures = 0
        # the small PUT is not a fragment: make the whole chat unreachable instead
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = $e.Chat.Id })
        $e.Ids.Add('src-alice', 'Alice', [TeamsTransfer.IdentityKind]::Mapped, '00000000-0000-0000-0000-0000000000aa') | Out-Null
        $r1 = Invoke-Copy $e -Apply
        $r1.Failed | Should -Be 1
        [void]$e.Ids.Add('src-alice', 'Alice', [TeamsTransfer.IdentityKind]::Mapped, $e.Alice.Id)
        $r2 = Invoke-Copy $e -Apply
        $r2.Failed | Should -Be 0
        $r2.Uploaded | Should -Be 1
        [string]$e.Files.Get($e.ChatKey, 'm1', 'att1').State | Should -Be 'Shared'
    }
    It 'leaves a file of a channel that does not exist yet Pending, with the reason' {
        $e = New-FcEnv
        $e.Targets.Upsert([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChanKey; Kind = [TeamsTransfer.TargetKind]::NewChannel; CreateTopic = 'New' })
        [void](Add-SourceFile $e $e.ChanKey 'c1' 'plan.docx' (New-Bytes 100 1))
        $r = Invoke-Copy $e -Apply
        $r.WaitingForTarget | Should -Be 1
        $r.Failed | Should -Be 0
        [string]$e.Files.Get($e.ChanKey, 'c1', 'att1').State | Should -Be 'Pending'
        $e.Files.Get($e.ChanKey, 'c1', 'att1').Error | Should -Match 'does not exist yet'
    }
    It 'fails a file whose sender cannot be placed when no service account is configured' {
        $e = New-FcEnv
        $e.Run.ServiceAccountUserId = $null
        [void]$e.Ids.Add('src-svc', 'Leaver', [TeamsTransfer.IdentityKind]::Unresolved)
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.txt' (New-Bytes 100 1) 'src-svc')
        $r = Invoke-Copy $e -Apply
        $r.NoDestination | Should -Be 1
        $r.Failed | Should -Be 1
        $e.Files.Get($e.ChatKey, 'm1', 'att1').Error | Should -Match 'no destination'
    }
    It 'stops cleanly when a stop is requested' {
        $e = New-FcEnv
        foreach ($i in 1..5) { [void](Add-SourceFile $e $e.ChatKey "m$i" "f$i.txt" (New-Bytes 100 $i)) }
        $e.Run.Stop = [TeamsTransfer.StopControl]::new(); $e.Run.Stop.Request()
        $r = Invoke-Copy $e -Apply
        $r.Stopped | Should -BeTrue
        $r.Uploaded | Should -Be 0
        $e.Gf.WriteCount | Should -Be 0
    }
}

Describe 'Dry run' {
    It 'makes no request at all (a transport that refuses everything) and writes no record, but counts files and bytes per destination' {
        $e = New-FcEnv -RefuseAll
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.bin' (New-Bytes 1000 1))
        [void](Add-SourceFile $e $e.ChatKey 'm2' 'b.bin' (New-Bytes 3000 2))
        [void](Add-SourceFile $e $e.ChatKey 'm3' 'dup.bin' (New-Bytes 1000 1))                        # same content as a.bin, same folder
        [void](Add-SourceFile $e $e.ChatKey 'm4' 'g.bin' (New-Bytes 500 4) 'src-gone')
        [void](Add-SourceFile $e $e.ChanKey 'c1' 'c.bin' (New-Bytes 700 5))
        $r = Invoke-Copy $e
        $r.DryRun | Should -BeTrue
        $r.Files | Should -Be 5
        $r.Failed | Should -Be 0
        @($e.Files.List()).Count | Should -Be 0
        $r.Bytes | Should -Be 5200
        $d = @{}; foreach ($x in $r.Destinations) { $d[$x.Destination] = $x }
        $d["OneDrive:$($e.Alice.Id)"].Files | Should -Be 3
        $d["OneDrive:$($e.Alice.Id)"].Bytes | Should -Be 4000
        $d["OneDrive:$($e.Alice.Id)"].Duplicates | Should -Be 1
        $d["OneDrive:$($e.Svc.Id) (service account)"].Files | Should -Be 1
        $d["Channel:$($e.Team.Id)/$($e.Chan.Id)"].Bytes | Should -Be 700
    }
    It 'limits the dry run to the time window of a scope' {
        $e = New-FcEnv -RefuseAll
        [void](Add-SourceFile $e $e.ChatKey 'recent' 'recent.txt' (New-Bytes 100 1) 'src-alice' $script:Now.AddDays(-10))
        [void](Add-SourceFile $e $e.ChatKey 'old' 'old.txt' (New-Bytes 100 2) 'src-alice' $script:Now.AddDays(-900) 'att2')
        $scope = [TeamsTransfer.FileCopyScope]@{ ConversationKey = $e.ChatKey; FromUtc = $script:Now.AddDays(-30); ToUtc = $null }
        $r = Invoke-Copy $e -Scopes ([Collections.Generic.List[TeamsTransfer.FileCopyScope]]@($scope))
        $r.Files | Should -Be 1
        $r.Bytes | Should -Be 100
    }
}

Describe 'Invoke-TmtFileCopy' {
    It 'works on a lot (time windows from its items) with the real store as the maps, previews by default and applies with -Apply' {
        $e = New-FcEnv
        $s = $e.Store
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@(
            [TeamsTransfer.ConversationRecord]@{ Key = $e.ChatKey; Kind = [TeamsTransfer.ConversationKind]::Group; ChatId = 'SRC-CHAT-1'; CreatedUtc = $script:Now.AddYears(-4); LastActivityUtc = $script:Now.AddDays(-1) }))
        $recent = Add-SourceFile $e $e.ChatKey 'recent' 'recent.txt' (New-Bytes 300 1) 'src-alice' $script:Now.AddDays(-10)
        $old = Add-SourceFile $e $e.ChatKey 'old' 'old.txt' (New-Bytes 300 2) 'src-alice' $script:Now.AddDays(-900) 'att2'
        $recent | Should -Not -Be $old
        $lotId = $s.CreateLot("wave1", [Collections.Generic.List[TeamsTransfer.LotMember]]@([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, $e.ChatKey)), [TeamsTransfer.LotOptions]@{ AsOfUtc = $script:Now })
        [void]$s.ResolveLot($lotId, [int[]]@(1))
        # identity / target maps live in the store too
        $s.UpsertIdentity([TeamsTransfer.IdentityMapping]@{ SourceUserId = 'src-alice'; Kind = [TeamsTransfer.IdentityKind]::Mapped; TargetUserId = $e.Alice.Id })
        $s.UpsertTarget([TeamsTransfer.TargetMapping]@{ SourceConversationKey = $e.ChatKey; Kind = [TeamsTransfer.TargetKind]::ExistingChat; TargetChatId = $e.Chat.Id })
        $folder = Join-Path $script:TempRoot 'report-copy'
        $e.Run.ServiceAccountUserId = $e.Svc.Id
        $dry = Invoke-TmtFileCopy -Store $s -Lot 'wave1' -Run $e.Run -ReportFolder $folder
        $dry.DryRun | Should -BeTrue
        $dry.Files | Should -Be 1
        @($s.ListFileCopies()).Count | Should -Be 0
        (Import-Csv -LiteralPath (Join-Path $folder 'filecopy.csv')).Files | Should -Be 1
        $r = Invoke-TmtFileCopy -Store $s -Client $e.Client -Lot 'wave1' -Run $e.Run -Apply -ReportFolder $folder
        $r.Uploaded | Should -Be 1
        @($s.ListFileCopies()).Count | Should -Be 1
        [string]($s.ListFileCopies())[0].State | Should -Be 'Shared'
        $e.Gf.Count('PUT', 'recent\.txt') | Should -Be 1
    }
}

Describe 'Large generated file' -Tag 'Large' {
    It 'streams a 1 GiB file from the store in fragments with a bounded memory footprint' {
        $e = New-FcEnv
        $e.Tenant.MaxRetainedUploadBytes = 1MB            # the fake keeps only length + SHA-256 above this
        $gen = [TeamsTransfer.Testing.GfGenStream]::new(1GB)
        $c = $e.Store.PutContent($gen, 'application/octet-stream')
        $c.Length | Should -Be 1GB
        Add-Message $e $e.ChatKey 'huge' $script:Now.AddDays(-2) 'src-alice'
        $e.Store.RecordFile([TeamsTransfer.FileRecord]@{ ConversationKey = $e.ChatKey; MessageId = 'huge'; AttachmentId = 'att1'; Name = 'huge.bin'; Size = 1GB; Status = [TeamsTransfer.FileStatus]::Downloaded; Sha256 = $c.Sha256 })
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $before = [Environment]::WorkingSet
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Copy $e -Apply
        $sw.Stop()
        $r.Failed | Should -Be 0
        $r.Uploaded | Should -Be 1
        $r.Bytes | Should -Be 1GB
        $r.BytesPerSecond | Should -BeGreaterThan 0
        $e.Gf.FragmentsOk | Should -Be 103                 # ceil(1 GiB / 10 MiB)
        $e.Gf.MaxFragmentBytes | Should -BeLessOrEqual (10MB)
        ($e.Gf.MaxWorkingSet - $before) | Should -BeLessThan 200MB
        $item = Get-FakeItem $e ($e.Files.Get($e.ChatKey, 'huge', 'att1'))
        $item.Size | Should -Be 1GB
        $item.UploadedSha256 | Should -Be $c.Sha256
    }
}

Describe 'Lot lifecycle: CopyFiles' {
    It 'moves an ImportPlanned (or Ghosts) lot to Files after a clean apply, not after a failure' {
        $e = New-FcEnv
        $s = $e.Store
        $s.UpsertConversations([TeamsTransfer.ConversationRecord[]]@([TeamsTransfer.ConversationRecord]@{ Key = $e.ChatKey; Kind = [TeamsTransfer.ConversationKind]::Group; ChatId = 'SRC-CHAT-1'; CreatedUtc = $script:Now.AddYears(-1); LastActivityUtc = $script:Now }))
        $m = [Collections.Generic.List[TeamsTransfer.LotMember]]::new(); $m.Add([TeamsTransfer.LotMember]::new([TeamsTransfer.LotMemberType]::Chat, $e.ChatKey))
        $id = $s.CreateLot('lot-f', $m, [TeamsTransfer.LotOptions]@{ AsOfUtc = $script:Now })
        [void]$s.ResolveLot($id, [int[]]@(1))
        foreach ($st in 'Exporting', 'Exported', 'ImportPlanned', 'Ghosts') { [void]$s.TransitionLot($id, [TeamsTransfer.LotState]$st, 'test') }
        [void](Add-SourceFile $e $e.ChatKey 'm1' 'a.txt' (New-Bytes 100 1))
        [void](Add-SourceFile $e $e.ChatKey 'lost' 'lost.txt' $null -NoContent -Size 100 -Sha ('b' * 64))
        $r1 = Invoke-TmtFileCopy -Store $s -Client $e.Client -Run $e.Run -IdentityMap $e.Ids -TargetMap $e.Targets -FileCopyMap $e.Files -Lot 'lot-f' -Apply -AdvanceLot
        $r1.Failed | Should -Be 1
        [string]$s.GetLot($id).State | Should -Be 'Ghosts'
        $e.Files.Upsert([TeamsTransfer.FileCopyRecord]@{ ConversationKey = $e.ChatKey; MessageId = 'lost'; AttachmentId = 'att1'; State = [TeamsTransfer.FileCopyState]::Skipped })
        $r2 = Invoke-TmtFileCopy -Store $s -Client $e.Client -Run $e.Run -IdentityMap $e.Ids -TargetMap $e.Targets -FileCopyMap $e.Files -Lot 'lot-f' -Apply -AdvanceLot
        $r2.Failed | Should -Be 0
        [string]$s.GetLot($id).State | Should -Be 'Files'
    }
}
