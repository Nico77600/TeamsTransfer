#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Hygiene of the published sources: comments, help blocks, test names and documentation describe the product as it is, never the way it
    was developed. The public files (tools\Get-PublicFileList.ps1 when it is present, otherwise every file under the repository root) are
    scanned for the wording of a development history: internal batch names, references to a private design record, lab narratives,
    "not yet measured" statements, remarks about reviews or tools, work markers.
    The product word "lot" (an import lot, -Lot, CancelLot) is legitimate: only a batch letter after it ("lot" and one capital letter) is a hit.
    Offline, no network, no tenant. This file is not scanned (it has to spell the patterns); the patterns are written so that they do not match themselves.
#>

BeforeDiscovery {
    $script:Rules = @(
        @{ Name = 'a reference to a lab phase';           Pattern = '(?i)phase ?[0]|phase[0]' }
        @{ Name = 'a reference to the design record';     Pattern = '(?i)\bdesign (\d|record\b|doc\b|document\b)|docs[\\/]desig[n]' }
        @{ Name = 'a development batch of the code';      Pattern = '(?-i:\b[Ll]ots? [A-Z]\b)|(?-i:\b[Ll]ots [A-Z] (and|or) [A-Z]\b)|(?i)\b(engine|fake Microsoft Graph|lot [A-Z]),? part \d' }
        @{ Name = 'a part number of a source file';       Pattern = '(?i)\bpart \d+[a-c]?:' }
        @{ Name = 'a lab narrative';                      Pattern = '(?i)\b(on|in) the lab\b|real-lab|lab run \d|happened (on|in) the|was broken|before the fix|fixed in\b' }
        @{ Name = 'an unmeasured or assumed behaviour';   Pattern = '(?i)unknown until|must confirm|not yet measured|ASSUMED BEHAVIOUR' }
        @{ Name = 'a work marker';                        Pattern = '(?-i:\b(TODO|FIXME|XXX|HACK)\b)' }
        @{ Name = 'a remark about a tool or a review';    Pattern = '(?i)\b(opus|sonnet|claude|anthropic)\b|(?-i:\bG\d\d\b)' }
    ) | ForEach-Object { @{ Name = $_.Name; Pattern = $_.Pattern } }
    # private names (lab tenant, lab lots, accounts): the git-ignored tests\privacy-denylist.local.txt, one term per line, never in a public file
    $deny = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\privacy-denylist.local.txt'
    if (Test-Path -LiteralPath $deny) {
        $terms = @(Get-Content -LiteralPath $deny | Where-Object { $_.Trim() } | ForEach-Object { [regex]::Escape($_.Trim()) })
        if ($terms) { $script:Rules += @{ Name = 'a private name of the local deny-list'; Pattern = '(?i)' + ($terms -join '|') } }
    }
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $self = [IO.Path]::GetFullPath($PSCommandPath)
    $lister = Join-Path $script:Repo 'tools\Get-PublicFileList.ps1'
    if (Test-Path -LiteralPath $lister) {
        $relative = @(& (Get-Process -Id $PID).Path -NoProfile -File $lister -RepositoryPath $script:Repo)
        if ($LASTEXITCODE -ne 0 -or $relative.Count -eq 0) { throw 'tools\Get-PublicFileList.ps1 did not return the public files.' }
    } else {
        $relative = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object { $_.FullName.Substring($script:Repo.Length + 1).Replace('\', '/') })
    }
    $textExtensions = '\.(ps1|psm1|psd1|cs|js|xaml|html|md|json|cmd|yml|yaml|txt|gitignore|gitattributes)$'
    $script:Files = @($relative | Where-Object { $_ -match $textExtensions -and $_ -notmatch '^package/lib/' } |
        ForEach-Object { Join-Path $script:Repo ($_ -replace '/', '\') } |
        Where-Object { [IO.Path]::GetFullPath($_) -ne $self -and (Test-Path -LiteralPath $_) })

    # The hits of one rule: "file:line: text". A signature block ("# SIG #" base64) is never read; a line that names the build folder
    # of the raw lab output (.gitignore, the CI copy and the release test exclude it by name) is not a development remark.
    function Get-Hit([string]$Pattern) {
        foreach ($file in $script:Files) {
            $number = 0
            foreach ($line in [IO.File]::ReadLines($file)) {
                $number++
                if ($line -match '^# SIG # ' -or $line -match '^[A-Za-z0-9+/=]{60,}$' -or $line -match 'base64,' -or $line -match 'phase0-output') { continue }
                if ($line -match $Pattern) {
                    $short = $line.Trim(); if ($short.Length -gt 140) { $short = $short.Substring(0, 140) }
                    '{0}:{1}: {2}' -f $file.Substring($script:Repo.Length + 1), $number, $short
                }
            }
        }
    }
}

Describe 'Published files carry no development history' {
    It 'scans the public files' {
        $script:Files.Count | Should -BeGreaterThan 100
        $script:Files | Should -Contain (Join-Path $script:Repo 'package\Invoke-TeamsTransfer.ps1')
        $script:Files | Should -Contain (Join-Path $script:Repo 'package\demo\FakeGraph.Transport.cs')
    }

    It 'does not publish the lab tools' {
        $lab = 'Invoke-Phase0', 'Grant-LabConsent', 'New-LabCertificate', 'New-Phase0LabData', 'Remove-Phase0LabData', 'Phase0.LabCommon'
        foreach ($name in $lab) { $script:Files | Where-Object { $_ -like "*\tools\$name.ps1" } | Should -BeNullOrEmpty }
    }

    It 'has no <Name>' -ForEach $script:Rules {
        $hits = @(Get-Hit $Pattern)
        $hits | Should -BeNullOrEmpty -Because ("these lines read like development notes:`n" + (($hits | Select-Object -First 40) -join "`n"))
    }

    It 'keeps the product word "lot" legitimate (the batch rule only matches a batch letter)' -ForEach @($script:Rules | Where-Object { $_.Name -eq 'a development batch of the code' }) {
        foreach ($ok in 'import a lot', 'Lot plan-20261110', '-Lot wave1', 'CancelLot', 'the lot report', 'a lot of messages') { $ok | Should -Not -Match $Pattern }
        foreach ($bad in 'lot H owns this file', '(lot J)', 'lots I and J', 'engine, lot E part 2') { $bad | Should -Match $Pattern }
    }
}
