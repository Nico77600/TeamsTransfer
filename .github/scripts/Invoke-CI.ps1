#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Analyze', 'Test', 'Package')][string]$Stage,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ModuleDirectory = $env:CI_MODULE_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$configuration = Get-Content -LiteralPath (Join-Path $root '.github\ci.json') -Raw | ConvertFrom-Json
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)

if ($ModuleDirectory) {
    $env:PSModulePath = $ModuleDirectory + [IO.Path]::PathSeparator + $env:PSModulePath
}

function Resolve-RepositoryFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'A repository-relative path is required.' }
    $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Repository file missing or outside the repository: $RelativePath"
    }
    $path
}

switch ($Stage) {
    'Analyze' {
        Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -ErrorAction Stop
        $tracked = @(git -C $root ls-files -- '*.ps1' '*.psm1' '*.psd1')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate the tracked PowerShell sources.' }
        $runtime = [string]$configuration.runtimeRoot
        $runtimeFiles = @($tracked | Where-Object {
            ($_ -notmatch '^(tests|tools|lib|\.github)/') -and
            ($runtime -eq '.' -or $_.StartsWith($runtime.TrimEnd('/') + '/', [StringComparison]::Ordinal))
        })
        if ($runtimeFiles.Count -eq 0) { throw 'No tracked runtime PowerShell sources were found.' }
        # Tests and tools are analysed too (advisory, same policy as the runtime); they are not part of the package.
        $supportFiles = @($tracked | Where-Object { $_ -match '^(tests|tools)/' })
        $files = @($runtimeFiles) + @($supportFiles)
        $parseFailures = @()
        $findings = @(foreach ($relative in $files) {
            $path = Resolve-RepositoryFile $relative
            $tokens = $null
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            foreach ($errorItem in $parseErrors) {
                $parseFailures += [pscustomobject]@{
                    File = $relative; Line = $errorItem.Extent.StartLineNumber; Message = $errorItem.Message
                }
            }
            foreach ($finding in @(Invoke-ScriptAnalyzer -Path $path -ErrorAction Stop)) {
                [pscustomobject]@{
                    File = $relative; Scope = $(if ($relative -in $runtimeFiles) { 'runtime' } else { 'tests-tools' }); Line = $finding.Line; Column = $finding.Column
                    Severity = [string]$finding.Severity; Rule = $finding.RuleName; Message = $finding.Message
                }
            }
        })
        ConvertTo-Json -InputObject $findings -Depth 5 |
            Out-File -LiteralPath (Join-Path $OutputDirectory 'script-analyzer.json') -Encoding utf8
        ConvertTo-Json -InputObject $parseFailures -Depth 5 |
            Out-File -LiteralPath (Join-Path $OutputDirectory 'syntax-errors.json') -Encoding utf8
        $summary = [ordered]@{
            Files = $files.Count; RuntimeFiles = $runtimeFiles.Count; TestAndToolFiles = $supportFiles.Count; Analyzer = '1.25.0'; SyntaxErrors = $parseFailures.Count
            Errors = @($findings | Where-Object Severity -eq 'Error').Count
            Warnings = @($findings | Where-Object Severity -eq 'Warning').Count
            Informative = @($findings | Where-Object Severity -eq 'Information').Count
            DiagnosticsPolicy = 'Advisory; syntax or analyzer execution failures still fail the job.'
        }
        $summary | ConvertTo-Json |
            Out-File -LiteralPath (Join-Path $OutputDirectory 'analysis-summary.json') -Encoding utf8
        Write-Output ($summary | ConvertTo-Json -Compress)
        if ($parseFailures.Count) { throw 'PowerShell sources (runtime, tests or tools) contain syntax errors.' }
    }
    'Test' {
        Import-Module Pester -RequiredVersion 6.1.0 -Force -ErrorAction Stop
        if ($configuration.testMode -eq 'gate') {
            $gate = Resolve-RepositoryFile $configuration.testEntry
            $executable = Join-Path $PSHOME 'pwsh.exe'
            & $executable -NoProfile -NonInteractive -File $gate
            if ($LASTEXITCODE -ne 0) { throw "The existing project test gate failed with exit code $LASTEXITCODE." }
        } elseif ($configuration.testMode -eq 'runner') {
            $runner = Resolve-RepositoryFile $configuration.testEntry
            & {
                # Preserve the existing runner's normal caller semantics.
                Set-StrictMode -Off
                & $runner
            }
        } elseif ($configuration.testMode -eq 'pester') {
            $testFiles = @($configuration.tests | ForEach-Object { Resolve-RepositoryFile $_ })
            if ($testFiles.Count -eq 0) { throw 'No test files were configured.' }
            $pester = New-PesterConfiguration
            $pester.Run.Path = $testFiles
            $pester.Run.PassThru = $true
            $pester.Run.Exit = $false
            $pester.Output.Verbosity = 'Normal'
            $pester.TestResult.Enabled = $true
            $pester.TestResult.OutputFormat = 'NUnitXml'
            $pester.TestResult.OutputPath = Join-Path $OutputDirectory 'pester-results.xml'
            $result = & {
                # Do not impose this wrapper's StrictMode on existing tests.
                Set-StrictMode -Off
                Invoke-Pester -Configuration $pester
            }
            if ($null -eq $result -or $result.TotalCount -le 0 -or $result.PassedCount -le 0 -or
                $result.FailedCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or
                $result.FailedContainersCount -gt 0 -or [string]$result.Result -ne 'Passed') {
                throw 'The project tests did not complete successfully.'
            }
            [ordered]@{
                Total = $result.TotalCount; Passed = $result.PassedCount
                Failed = $result.FailedCount; Skipped = $result.SkippedCount
            } | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutputDirectory 'test-summary.json') -Encoding utf8
        } else { throw "Unsupported test mode: $($configuration.testMode)" }
    }
    'Package' {
        if (-not $configuration.packageBuilder) { throw 'This project has no package builder configured.' }
        $builder = Resolve-RepositoryFile $configuration.packageBuilder
        $destination = Join-Path $OutputDirectory 'package'
        if (Test-Path -LiteralPath $destination) { throw 'The package output already exists; it will not be overwritten.' }
        & {
            Set-StrictMode -Off
            & $builder -Destination $destination
        }
        $entry = Join-Path $destination $configuration.packageEntry
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
            throw "The existing package builder did not produce the expected entry point: $entry"
        }
        $files = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
        if ($files.Count -eq 0) { throw 'The built package is empty.' }
        $inventory = @(foreach ($file in $files) {
            [pscustomobject]@{
                File = $file.FullName.Substring($destination.Length + 1)
                Bytes = $file.Length
                SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        ConvertTo-Json -InputObject $inventory -Depth 5 |
            Out-File -LiteralPath (Join-Path $OutputDirectory 'package-inventory.json') -Encoding utf8
        Write-Output ('Existing package builder completed: {0} files.' -f $files.Count)
    }
}
