#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The documentation (docs\design\... is not covered: it is the design record, not a shipped document).
    Offline, no network, no tenant. What is checked:
      - every link and every image of the Markdown files resolves (files, and the heading anchors of the target file);
      - every -Mode and every parameter that the guides show exists in Invoke-TeamsTransfer.ps1, and the reference guide names every parameter and mode;
      - the disclaimer is word for word in both READMEs, with the author line, the release link and the banner;
      - no French word (a short list of whole words, and any accented letter) and no customer or lab identifier;
      - the versions agree (module, guides, changelog, readmes);
      - the HTML guides build (images embedded, no remote resource) and the committed HTML files are up to date.
#>

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:MarkdownFiles = @(
        'README.md', 'SECURITY.md', 'package\README.md', 'package\CHANGELOG.md', 'package\SECURITY.md', 'package\THIRD-PARTY-NOTICES.md',
        'package\docs\TeamsTransfer-UserGuide.md', 'package\docs\TeamsTransfer-Guide.md'
    ) | ForEach-Object { @{ Name = $_; Path = (Join-Path $repo $_) } }
    $script:Guides = @('TeamsTransfer-UserGuide', 'TeamsTransfer-Guide') | ForEach-Object { @{ Name = $_ } }
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Package = Join-Path $script:Repo 'package'
    $script:Docs = Join-Path $script:Package 'docs'
    $script:Entry = Join-Path $script:Package 'Invoke-TeamsTransfer.ps1'
    $script:Pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function Read-Text([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n") }

    # The parameters and the modes of the entry script, from its syntax tree (nothing is run).
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Entry, [ref]$null, [ref]$null)
    $script:EntryParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $modeParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
    $validateSet = $modeParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
    $script:EntryModes = @($validateSet.PositionalArguments | ForEach-Object { $_.Value })
    # Parameters of other programs that appear next to the entry script on a command line (pwsh itself) and the common parameters.
    $script:Foreign = @('NoProfile', 'NoLogo', 'STA', 'File', 'Command', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'InformationVariable', 'ProgressAction', 'WhatIf', 'Confirm',
        # parameters of the other scripts that the reference guide names (Test-PackageIntegrity, Get-TeamsTransferDependencies, New-LabCertificate)
        'Distribution', 'Verify', 'UpdateLock', 'ExportPfx', 'Stage', 'Package', 'SkipTests', 'RequireSignature')

    # A Markdown file as lines with a flag "inside a fenced code block" (a fence may sit inside a quote: "> ```powershell").
    function Get-MarkdownLines([string]$Text) {
        $inFence = $false
        foreach ($line in $Text.Split("`n")) {
            $plain = ($line -replace '^\s*>\s?', '')
            if ($plain -match '^\s*```') { $inFence = -not $inFence; [pscustomobject]@{ Text = $plain; Code = $true; Fence = $true }; continue }
            [pscustomobject]@{ Text = $plain; Code = $inFence; Fence = $false }
        }
    }

    function ConvertTo-Slug([string]$Heading) {
        # GitHub anchors: lower case, formatting and punctuation removed, spaces become hyphens, duplicates get -1, -2 (handled by the caller).
        $t = $Heading.Trim().ToLowerInvariant()
        $t = [regex]::Replace($t, '\[([^\]]*)\]\([^)]*\)', '$1')
        $t = $t -replace '[`*]', ''
        $t = [regex]::Replace($t, '[^\p{L}\p{N}\s\-_]', '')
        return ($t -replace '\s', '-')
    }

    function Get-Anchors([string]$Path) {
        $seen = @{}
        $anchors = [Collections.Generic.HashSet[string]]::new()
        foreach ($l in (Get-MarkdownLines (Read-Text $Path))) {
            if ($l.Code) { continue }
            if ($l.Text -match '^#{1,6}\s+(.+?)\s*#*\s*$') {
                $slug = ConvertTo-Slug $Matches[1]
                if ($seen.ContainsKey($slug)) { $seen[$slug]++; [void]$anchors.Add("$slug-$($seen[$slug])") } else { $seen[$slug] = 0; [void]$anchors.Add($slug) }
            }
        }
        return $anchors
    }

    function Get-MarkdownLinks([string]$Path) {
        # Links and images outside code, plus src / srcset of the HTML of the READMEs (the banner).
        $out = [Collections.Generic.List[object]]::new()
        foreach ($l in (Get-MarkdownLines (Read-Text $Path))) {
            if ($l.Code) { continue }
            $text = [regex]::Replace($l.Text, '(`+)[^`]*?\1', '')
            foreach ($m in [regex]::Matches($text, '!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) { $out.Add($m.Groups[1].Value) }
            foreach ($m in [regex]::Matches($text, '\b(?:src|srcset)="([^"]+)"')) { $out.Add($m.Groups[1].Value) }
        }
        return $out.ToArray()
    }
}

Describe 'Documentation files' {
    It 'exist: the package documents, the guides, the banners and the HTML guides' {
        $needed = @('README.md', 'SECURITY.md', 'package\README.md', 'package\CHANGELOG.md', 'package\SECURITY.md', 'package\LICENSE', 'package\THIRD-PARTY-NOTICES.md',
            'package\docs\TeamsTransfer-UserGuide.md', 'package\docs\TeamsTransfer-Guide.md', 'package\docs\TeamsTransfer-UserGuide.html', 'package\docs\TeamsTransfer-Guide.html',
            'package\docs\images\readme-banner-light.svg', 'package\docs\images\readme-banner-dark.svg', 'tools\Build-Documentation.ps1')
        foreach ($n in $needed) { (Join-Path $script:Repo $n) | Should -Exist }
    }

    It 'the entry script was parsed: its parameters and the thirteen modes' {
        $script:EntryParameters.Count | Should -BeGreaterThan 60
        $script:EntryModes | Should -HaveCount 13
        $script:EntryModes | Should -Contain 'Verify'
        $script:EntryModes | Should -Contain 'Merge'
    }
}

Describe 'Links and images: <Name>' -ForEach $script:MarkdownFiles {
    BeforeAll {
        $script:File = $Path
        $script:Dir = Split-Path -Parent $Path
        $script:Links = @(Get-MarkdownLinks $Path)
    }

    It 'every relative link and image resolves to a file or folder' {
        $broken = foreach ($link in $script:Links) {
            if ($link -match '^(?i:https?|mailto):') { continue }
            $target = ($link -split '#', 2)[0]
            if (-not $target) { continue }
            $full = [IO.Path]::GetFullPath((Join-Path $script:Dir ([Uri]::UnescapeDataString($target))))
            if (-not (Test-Path -LiteralPath $full)) { "$link -> $full" }
        }
        $broken | Should -BeNullOrEmpty
    }

    It 'every #anchor points to an existing heading of the target Markdown file' {
        $broken = foreach ($link in $script:Links) {
            if ($link -match '^(?i:https?|mailto):' -or $link -notmatch '#') { continue }
            $target, $fragment = $link -split '#', 2
            $file = if ($target) { [IO.Path]::GetFullPath((Join-Path $script:Dir $target)) } else { $script:File }
            if ($file -notmatch '\.md$' -or -not (Test-Path -LiteralPath $file)) { continue }
            if (-not (Get-Anchors $file).Contains($fragment)) { "$link (in $([IO.Path]::GetFileName($file)))" }
        }
        $broken | Should -BeNullOrEmpty
    }
}

Describe 'Images: light and dark' {
    It 'every light screenshot used by a guide has its dark twin on disk' {
        $missing = foreach ($f in @('package\docs\TeamsTransfer-UserGuide.md', 'package\docs\TeamsTransfer-Guide.md')) {
            foreach ($link in (Get-MarkdownLinks (Join-Path $script:Repo $f))) {
                if ($link -match '-light\.png$') {
                    $dark = Join-Path $script:Docs ($link -replace '-light\.png$', '-dark.png')
                    if (-not (Test-Path -LiteralPath $dark)) { $link }
                }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'the user guide has one picture per step: at least 20 console screenshots and 5 views of the archive' {
        $links = @(Get-MarkdownLinks (Join-Path $script:Docs 'TeamsTransfer-UserGuide.md'))
        @($links | Where-Object { $_ -match 'images/console-' }).Count | Should -BeGreaterOrEqual 20
        @($links | Where-Object { $_ -match 'images/preview-' }).Count | Should -BeGreaterOrEqual 5
    }
}

Describe 'Modes and parameters named in the guides exist in the entry script' {
    BeforeAll {
        # Everything the guides show as code that starts with a dash, and every command line of the entry script (fenced or inline).
        $script:Named = [Collections.Generic.List[object]]::new()
        $script:NamedModes = [Collections.Generic.List[object]]::new()
        foreach ($f in @('README.md', 'package\README.md', 'package\docs\TeamsTransfer-UserGuide.md', 'package\docs\TeamsTransfer-Guide.md')) {
            $lines = @(Get-MarkdownLines (Read-Text (Join-Path $script:Repo $f)))
            # code blocks: join the lines that end with a backtick, then keep the command lines of the entry script
            $codeLines = [Collections.Generic.List[string]]::new(); $buffer = ''
            foreach ($l in $lines) {
                if (-not $l.Code -or $l.Fence) { continue }
                $t = $l.Text.TrimEnd()
                if ($t.EndsWith('`')) { $buffer += ' ' + $t.TrimEnd('`'); continue }
                $codeLines.Add(($buffer + ' ' + $t).Trim()); $buffer = ''
            }
            $inlineSpans = foreach ($l in $lines) { if (-not $l.Code) { foreach ($m in [regex]::Matches($l.Text, '`([^`]+)`')) { $m.Groups[1].Value } } }
            $commands = @($codeLines | Where-Object { $_ -match 'Invoke-TeamsTransfer\.ps1' }) + @($inlineSpans | Where-Object { $_ -match 'Invoke-TeamsTransfer\.ps1' })
            foreach ($c in $commands) {
                foreach ($m in [regex]::Matches($c, '(?<![\w.\\\-])-([A-Za-z]+)\b')) { $script:Named.Add(@{ File = $f; Name = $m.Groups[1].Value; Where = $c }) }
                foreach ($m in [regex]::Matches($c, '-Mode\s+([A-Za-z]+)')) { $script:NamedModes.Add(@{ File = $f; Name = $m.Groups[1].Value; Where = $c }) }
            }
            # inline spans that are a parameter on their own: `-Apply`, `-Lot <name>`, `-Mode Plan`
            foreach ($s in $inlineSpans) {
                if ($s -match '^-([A-Z][A-Za-z]+)\b') { $script:Named.Add(@{ File = $f; Name = $Matches[1]; Where = $s }) }
                foreach ($m in [regex]::Matches($s, '-Mode\s+([A-Za-z]+)')) { $script:NamedModes.Add(@{ File = $f; Name = $m.Groups[1].Value; Where = $s }) }
            }
        }
    }

    It 'finds the command lines of the guides (the check is not empty)' {
        $script:Named.Count | Should -BeGreaterThan 100
        $script:NamedModes.Count | Should -BeGreaterThan 30
    }

    It 'every parameter shown on an Invoke-TeamsTransfer.ps1 command line exists' {
        $unknown = $script:Named | Where-Object { $_.Name -notin $script:EntryParameters -and $_.Name -notin $script:Foreign } |
            ForEach-Object { "-$($_.Name) in $($_.File): $($_.Where)" } | Select-Object -Unique
        $unknown | Should -BeNullOrEmpty
    }

    It 'every -Mode value shown is one of the thirteen modes' {
        $unknown = $script:NamedModes | Where-Object { $_.Name -notin $script:EntryModes } | ForEach-Object { "$($_.Name) in $($_.File): $($_.Where)" } | Select-Object -Unique
        $unknown | Should -BeNullOrEmpty
    }

    It 'the reference guide names every parameter of the entry script' {
        $text = Read-Text (Join-Path $script:Docs 'TeamsTransfer-Guide.md')
        $missing = $script:EntryParameters | Where-Object { $text -notmatch ('`-' + $_ + '\b') }
        $missing | Should -BeNullOrEmpty
    }

    It 'the reference guide and the user guide name every mode' {
        foreach ($f in 'TeamsTransfer-Guide.md', 'TeamsTransfer-UserGuide.md') {
            $text = Read-Text (Join-Path $script:Docs $f)
            $missing = $script:EntryModes | Where-Object { $text -notmatch ('-Mode ' + $_ + '\b') }
            if ($f -eq 'TeamsTransfer-Guide.md') { $missing = $script:EntryModes | Where-Object { $text -notmatch ('`' + $_ + '`') } }
            $missing | Should -BeNullOrEmpty -Because $f
        }
    }

    It 'the guides use the exit codes of the entry script (0, 1, 2, 3)' {
        foreach ($f in 'TeamsTransfer-Guide.md', 'TeamsTransfer-UserGuide.md') {
            $text = Read-Text (Join-Path $script:Docs $f)
            foreach ($code in '0', '1', '2', '3') { $text | Should -Match ('\|\s*\*\*' + $code + '\*\*\s*\|') -Because "$f exit code $code" }
        }
    }
}

Describe 'Permissions: the reference guide matches package\config\Permissions.psd1' {
    BeforeAll {
        $script:Perm = Import-PowerShellDataFile -LiteralPath (Join-Path $script:Package 'config\Permissions.psd1')
        $guide = (Read-Text (Join-Path $script:Docs 'TeamsTransfer-Guide.md')).Split("`n")
        # The table that follows a heading: header row = Permission | modes... | Used for ; cells R (required), o (optional) or empty.
        function Read-PermissionTable([string]$Heading) {
            $start = [array]::IndexOf($guide, $Heading)
            if ($start -lt 0) { throw "heading not found: $Heading" }
            $rows = @{}; $modes = $null
            for ($i = $start + 1; $i -lt $guide.Count; $i++) {
                $l = $guide[$i]
                if ($l -match '^#{2,3} ') { break }
                if ($l -notmatch '^\|') { continue }
                $cells = @($l.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
                if ($cells[0] -eq 'Permission') { $modes = $cells[1..($cells.Count - 2)]; continue }
                if ($cells[0] -match '^---') { continue }
                $name = $cells[0].Trim('`')
                for ($m = 0; $m -lt $modes.Count; $m++) { if ($cells[$m + 1]) { $rows["$($modes[$m])|$name"] = $cells[$m + 1] } }
            }
            return $rows
        }
        $script:GuideSource = Read-PermissionTable '### Source app (read only)'
        $script:GuideTarget = Read-PermissionTable '### Target app (read and write)'
        function Expected([string]$Side) {
            $e = @{}
            foreach ($mode in $script:Perm.Modes.Keys) {
                if ($script:Perm.Modes[$mode].Side -ne $Side) { continue }
                foreach ($p in $script:Perm.Modes[$mode].Required) { $e["$mode|$($p.Name)"] = 'R' }
                foreach ($p in $script:Perm.Modes[$mode].Optional) { $e["$mode|$($p.Name)"] = 'o' }
            }
            return $e
        }
        $script:ExpectedSource = Expected 'Source'
        $script:ExpectedTarget = Expected 'Target'
    }

    It 'the source table is exactly the Source modes of Permissions.psd1' {
        $diff = Compare-Object @($script:ExpectedSource.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) @($script:GuideSource.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        $diff | Should -BeNullOrEmpty
    }

    It 'the target table is exactly the Target modes of Permissions.psd1' {
        $diff = Compare-Object @($script:ExpectedTarget.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) @($script:GuideTarget.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        $diff | Should -BeNullOrEmpty
    }

    It 'every mode of Permissions.psd1 is a mode of the entry script' {
        $script:Perm.Modes.Keys | Where-Object { $_ -notin $script:EntryModes } | Should -BeNullOrEmpty
    }

    It 'the user guide asks for every required permission, on the right side' {
        $text = Read-Text (Join-Path $script:Docs 'TeamsTransfer-UserGuide.md')
        $reader = $text.Substring($text.IndexOf('### Step B'), $text.IndexOf('### Step C') - $text.IndexOf('### Step B'))
        $writer = $text.Substring($text.IndexOf('### Step C'), $text.IndexOf('### Step D') - $text.IndexOf('### Step C'))
        $missing = foreach ($mode in $script:Perm.Modes.Keys) {
            $section = if ($script:Perm.Modes[$mode].Side -eq 'Source') { $reader } else { $writer }
            foreach ($p in $script:Perm.Modes[$mode].Required) { if ($section -notmatch ('`' + [regex]::Escape($p.Name) + '`')) { "$mode needs $($p.Name)" } }
        }
        $missing | Should -BeNullOrEmpty
    }
}
Describe 'READMEs' {
    BeforeAll {
        # The disclaimer of the documentation standard, word for word, then the paragraph of this project.
        $script:Disclaimer = @"
This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
"@.Replace("`r`n", "`n")
        $script:ProjectParagraph = 'Import creates conversations in the target tenant and an imported conversation cannot be rolled back: run the preview, review the plan and test in a lab before using it on real data.'
        $script:Readmes = @('README.md', 'package\README.md')
    }

    It 'the disclaimer is word for word under a Disclaimer heading in <_>' -ForEach @('README.md', 'package\README.md') {
        $text = Read-Text (Join-Path $script:Repo $_)
        $text | Should -Match '(?m)^## Disclaimer$'
        $section = $text.Substring($text.IndexOf("## Disclaimer`n"))
        $section.Contains($script:Disclaimer) | Should -BeTrue
        $section.Contains($script:ProjectParagraph) | Should -BeTrue
    }

    It 'the disclaimer is the last section of <_>' -ForEach @('README.md', 'package\README.md') {
        $text = (Read-Text (Join-Path $script:Repo $_)).TrimEnd()
        $text.EndsWith($script:ProjectParagraph) | Should -BeTrue
    }

    It 'carry the author line, the latest release link, the light and dark banner in <_>' -ForEach @('README.md', 'package\README.md') {
        $text = Read-Text (Join-Path $script:Repo $_)
        $text | Should -Match '\*\*Author: Nicolas Fabert \(Nico77600\)\*\*'
        $text | Should -Match 'https://github\.com/Nico77600/TeamsTransfer/releases/latest'
        $text | Should -Match '<picture>'
        $text | Should -Match 'readme-banner-dark\.svg'
        $text | Should -Match 'readme-banner-light\.svg'
        $text | Should -Match 'Version 1\.0\.0'
    }

    It 'the package README has the house sections' {
        $text = Read-Text (Join-Path $script:Package 'README.md')
        foreach ($h in 'Requirements', 'Quick start', 'How it works', 'Content', 'Documentation', 'Data handling', 'Disclaimer') { $text | Should -Match "(?m)^## $h$" }
        # a list, not a table: a three-column table is cut off on a 400 px screen
        $text | Should -Not -Match '(?m)^\| You want to \|'
        $text | Should -Match '(?m)^  - Run: `'
        $text | Should -Match '(?m)^  - You get: '
        $text | Should -Match 'Unblock-File'
        $text | Should -Match 'Digital Signatures'
        $text | Should -Match 'Start-TeamsTransferConsole\.cmd'
    }

    It 'the repository README has the standard sections, in order, each once, and no link to a folder or to the design record' {
        $text = Read-Text (Join-Path $script:Repo 'README.md')
        $headings = @([regex]::Matches($text, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $headings | Should -Be @('Why', 'How it works', 'Reports', 'Requirements', 'Quick start', 'Documentation', 'Tests', 'License', 'Disclaimer')
        $text | Should -Match '(?s)^\s*<p align="center">\s*<picture>'
        ([regex]::Matches($text, '<a\s+href="#')).Count | Should -BeGreaterOrEqual 3
        $text | Should -Match '\]\(package/README\.md\)'
        $text | Should -Not -Match 'docs[\\/]design'
        $text | Should -Not -Match '\]\((?:[^)#]*/)?\)'
        $text | Should -Not -Match '\]\((?:package|package/docs|docs|tests|tools)\)'
    }

    It 'the root SECURITY.md is the house policy, identical to the package one' {
        (Read-Text (Join-Path $script:Repo 'SECURITY.md')) | Should -Be (Read-Text (Join-Path $script:Package 'SECURITY.md'))
    }
    It 'the banners are text only SVG files without any Microsoft mark or script' {
        foreach ($n in 'light', 'dark') {
            $svg = Read-Text (Join-Path $script:Docs "images\readme-banner-$n.svg")
            $svg | Should -Match '^<svg '
            $svg | Should -Match '#b11f4b|#fd8ea1'
            $svg | Should -Not -Match '(?i)<script|<image|href=|microsoft'
            { [xml]$svg } | Should -Not -Throw
        }
    }

    It 'the LICENSE is MIT for Nicolas Fabert, 2026, and SECURITY.md is the house policy' {
        $license = Read-Text (Join-Path $script:Package 'LICENSE')
        $license | Should -Match '^MIT License'
        $license | Should -Match 'Copyright \(c\) 2026 Nicolas Fabert'
        $security = Read-Text (Join-Path $script:Package 'SECURITY.md')
        $security | Should -Match '## Reporting a vulnerability'
        $security | Should -Match '## Release integrity'
    }

    It 'THIRD-PARTY-NOTICES names SQLite, WebView2 and WPF-UI' {
        $text = Read-Text (Join-Path $script:Package 'THIRD-PARTY-NOTICES.md')
        foreach ($n in 'Microsoft.Data.Sqlite', 'SQLitePCLRaw', 'SQLite', 'Microsoft.Web.WebView2', 'WPF-UI') { $text | Should -Match ([regex]::Escape($n)) }
    }
}

Describe 'Versions agree' {
    It 'the module, the guides, the readmes and the changelog all say the module version' {
        $version = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:Package 'TeamsTransfer.psd1')).ModuleVersion
        foreach ($g in 'TeamsTransfer-UserGuide.md', 'TeamsTransfer-Guide.md') { (Read-Text (Join-Path $script:Docs $g)) | Should -Match "(?m)^version: $([regex]::Escape($version))$" }
        (Read-Text (Join-Path $script:Package 'CHANGELOG.md')) | Should -Match "(?m)^## $([regex]::Escape($version)) "
        (Read-Text (Join-Path $script:Package 'README.md')) | Should -Match "Version $([regex]::Escape($version))"
        (Read-Text (Join-Path $script:Repo 'README.md')) | Should -Match "Version $([regex]::Escape($version))"
    }
}

Describe 'English only, no identifier of a customer or of the lab: <Name>' -ForEach $script:MarkdownFiles {
    BeforeAll { $script:Text = Read-Text $Path }

    It 'has no accented letter and none of the common French words' {
        $accent = [regex]::Matches($script:Text, '[àâäçéèêëîïôöùûüÿœæÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŸŒÆ]') | ForEach-Object { $_.Value } | Select-Object -Unique
        $accent | Should -BeNullOrEmpty
        $words = 'bonjour', 'merci', 'avec', 'pour', 'dans', 'sont', 'vous', 'nous', 'cette', 'ces', 'des', 'les', 'une', 'fichier', 'fichiers', 'utilisateur', 'utilisateurs', 'equipe', 'boite', 'sauvegarde', 'configuration(?=s? du)', 'lancer', 'ouvrir'
        $found = foreach ($w in $words) { if ($script:Text -cmatch "(?i)\b$w\b") { $w } }
        $found | Should -BeNullOrEmpty
    }

    It 'names no customer or lab tenant, no machine and no person of the author organisation' {
        $script:Text | Should -Not -Match '(?i)M365CPI|nfabert|DESKTOP-|REDMOND|\\Users\\[a-z]+\\AppData'
        # tenant names in examples are contoso, fabrikam (and northwind in the synthetic demo only)
        $tenants = [regex]::Matches($script:Text, '(?i)\b[a-z0-9\-]+\.onmicrosoft\.com') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique
        $tenants | Where-Object { $_ -notmatch '^(contoso|fabrikam)(-[a-z]+)?\.onmicrosoft\.com$' } | Should -BeNullOrEmpty
    }
}

Describe 'The HTML guides' {
    BeforeAll {
        $script:Out = Join-Path $TestDrive 'html'
        New-Item -ItemType Directory -Path $script:Out | Out-Null
        $script:Built = @{}
        foreach ($name in 'TeamsTransfer-UserGuide', 'TeamsTransfer-Guide') {
            $dest = Join-Path $script:Out ($name + '.html')
            $output = & $script:Pwsh -NoProfile -File (Join-Path $script:Repo 'tools\Build-Documentation.ps1') -Source (Join-Path $script:Docs ($name + '.md')) -Destination $dest -ImageRoot $script:Docs 2>&1
            $script:Built[$name] = @{ Exit = $LASTEXITCODE; Output = ($output | Out-String); Path = $dest }
        }
    }

    It 'build from the Markdown: <Name>' -ForEach $script:Guides {
        $script:Built[$Name].Exit | Should -Be 0 -Because $script:Built[$Name].Output
        $script:Built[$Name].Path | Should -Exist
    }

    It 'are self-contained: no remote script, style, image or font, a content security policy, the disclaimer: <Name>' -ForEach $script:Guides {
        $html = Read-Text $script:Built[$Name].Path
        $html | Should -Match '(?i)^<!doctype html>'
        $html | Should -Not -Match '(?i)<script[^>]+src=|<link[^>]+href=|<img[^>]+src="https?:|@import|url\(\s*["'']?https?:'
        $html | Should -Match "default-src 'none'"
        $html | Should -Match 'id="disclaimer"'
        $html | Should -Match 'This Script is a Personal project\.'
        $html | Should -Match "It&#39;s provided &quot;AS-IS&quot;"
        $html | Should -Not -Match 'Image not available'
    }

    It 'embed every image of the Markdown file: <Name>' -ForEach $script:Guides {
        $links = @(Get-MarkdownLinks (Join-Path $script:Docs ($Name + '.md')) | Where-Object { $_ -match '\.png$' })
        $html = Read-Text $script:Built[$Name].Path
        $embedded = ([regex]::Matches($html, '<img loading="lazy" src="data:image/png;base64,')).Count
        $embedded | Should -Be $links.Count
    }

    It 'have a section for every chapter and the light and dark theme: <Name>' -ForEach $script:Guides {
        $md = Read-Text (Join-Path $script:Docs ($Name + '.md'))
        $chapters = ([regex]::Matches($md, '(?m)^## (\d+\.|Annex)')).Count
        $html = Read-Text $script:Built[$Name].Path
        ([regex]::Matches($html, '<section class="section"')).Count | Should -Be $chapters
        $html | Should -Match 'data-theme'
        $html | Should -Match 'prefers-color-scheme'
    }

    It 'the committed HTML file is up to date with its Markdown (rebuild with tools\Build-Documentation.ps1): <Name>' -ForEach $script:Guides {
        $committed = Join-Path $script:Docs ($Name + '.html')
        $committed | Should -Exist
        (Get-FileHash -LiteralPath $committed -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $script:Built[$Name].Path -Algorithm SHA256).Hash
    }

    It 'in-page links of the HTML guides point to ids that exist: <Name>' -ForEach $script:Guides {
        $html = Read-Text $script:Built[$Name].Path
        $ids = [Collections.Generic.HashSet[string]]::new([string[]]@([regex]::Matches($html, '\bid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }))
        $broken = [regex]::Matches($html, '<a href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { -not $ids.Contains($_) } | Select-Object -Unique
        $broken | Should -BeNullOrEmpty
    }
}
