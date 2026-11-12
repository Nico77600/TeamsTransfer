#Requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$configuration = Get-Content (Join-Path $root '.github\codeql\build.json') -Raw | ConvertFrom-Json
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $root $configuration.productionSourceRoot))
if ($sourceRoot -notin @((Join-Path $root 'package\src'), (Join-Path $root 'src'))) {
    throw 'Only the production src directory is supported.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root '.github\codeql\out' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and
    -not $OutputDirectory.StartsWith((Join-Path $root '.github\codeql\out') + '\', [StringComparison]::OrdinalIgnoreCase) -and
    $OutputDirectory -ne (Join-Path $root '.github\codeql\out')) {
    throw 'Analysis outputs must not enter the runtime package.'
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$sources = @(Get-ChildItem $sourceRoot -Recurse -File -Filter '*.cs' | Sort-Object FullName)
if (-not $sources.Count) { throw 'No production C# sources found.' }
# The Demo-mode engine (package\demo) ships with the package and is compiled with the engine in Demo mode: analyse it too.
$sources += @(Get-ChildItem (Join-Path $root 'package\demo') -Recurse -File -Filter '*.cs' | Sort-Object FullName)
$tracked = @(& git -C $root ls-files -- '*.cs')
if ($LASTEXITCODE) { throw 'Cannot inspect the tracked C# inventory.' }
$runtimeTracked = @($tracked | Where-Object { $_ -notmatch '^(tests|tools|\.github|lib)/' -and $_ -notmatch '^package/lib/' })
foreach ($relative in $runtimeTracked) {
    if ([IO.Path]::GetFullPath((Join-Path $root $relative)) -notin $sources.FullName) {
        throw "Production C# source omitted by the build: $relative"
    }
}
$references = @(Get-ChildItem (Join-Path $PSHOME 'ref') -File -Filter '*.dll' | Sort-Object Name)
if (-not $references.Count) { throw 'This PowerShell installation has no reference assemblies.' }
if ($configuration.requiresPowerShell) {
    $references += Get-Item (Join-Path $PSHOME 'System.Management.Automation.dll')
}
if ($configuration.requiresSqlite) {
    foreach ($name in 'Microsoft.Data.Sqlite', 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2') {
        $references += Get-Item (Join-Path $root "package\lib\sqlite\$name.dll")
    }
}
if ($configuration.requiresWpf) {
    foreach ($name in 'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Security.Cryptography.ProtectedData') {
        $references += Get-Item (Join-Path $PSHOME "$name.dll")
    }
}
# MSAL.NET is not part of the repository: Engine.Auth.cs is compiled against the library of the pinned Microsoft.Graph.Authentication module (CI_MSAL_PATH,
# the folder where the workflow saved it, else an installed copy). Analysis only: nothing is loaded or shipped.
$msalDirectory = ''
if ($configuration.requiresMsal) {
    $searchRoots = @($env:CI_MSAL_PATH) + @(Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | ForEach-Object { Split-Path (Split-Path $_.ModuleBase -Parent) -Parent }) | Where-Object { $_ }
    $msal = $null
    foreach ($searchRoot in $searchRoots) {
        $msal = Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter 'Microsoft.Identity.Client.dll' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Core\\' } | Select-Object -First 1
        if ($msal) { break }
    }
    if (-not $msal) { throw 'Microsoft.Identity.Client.dll (module Microsoft.Graph.Authentication) is needed to compile Engine.Auth.cs; the workflow saves the pinned module first.' }
    $abstractions = Join-Path (Split-Path (Split-Path $msal.FullName -Parent) -Parent) 'Microsoft.IdentityModel.Abstractions.dll'
    if (-not (Test-Path -LiteralPath $abstractions -PathType Leaf)) { throw 'Microsoft.IdentityModel.Abstractions.dll is missing next to the MSAL library.' }
    $msalDirectory = Join-Path $OutputDirectory 'msal'
    [void][IO.Directory]::CreateDirectory($msalDirectory)
    Copy-Item -LiteralPath $msal.FullName, $abstractions -Destination $msalDirectory -Force
    $references += Get-ChildItem -LiteralPath $msalDirectory -Filter '*.dll' -File
}
function Get-FileEvidence($File) {
    [ordered]@{
        file = $File.FullName.Substring($root.Length + 1)
        sha256 = (Get-FileHash $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$sourceEvidence = @($sources | ForEach-Object { Get-FileEvidence $_ })
$referenceEvidence = @($references | ForEach-Object {
    $assembly = [Reflection.AssemblyName]::GetAssemblyName($_.FullName)
    [ordered]@{
        name = $assembly.Name; version = $assembly.Version.ToString()
        path = $_.FullName; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$sdk = (& dotnet --version).Trim()
if ($LASTEXITCODE) { throw 'A .NET SDK is required for the existing Roslyn compiler task.' }
$manifest = [ordered]@{
    purpose = 'Analysis-only compilation; no runtime loading, restore, deployment or package changes.'
    powerShell = $PSVersionTable.PSVersion.ToString()
    framework = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    sdk = $sdk; sources = $sourceEvidence; references = $referenceEvidence
    compiledCount = 0; extractionProof = 'PENDING hosted CodeQL tracer and database validation.'
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'build-manifest.json') -Encoding utf8
$arguments = @(
    'msbuild', (Join-Path $root '.github\codeql\Production.proj'), '-nologo', '-verbosity:minimal',
    "-property:ProductionSourceRoot=$($configuration.productionSourceRoot)",
    "-property:PowerShellHome=$PSHOME",
    "-property:RequiresPowerShell=$($configuration.requiresPowerShell.ToString().ToLowerInvariant())",
    "-property:RequiresSqlite=$($configuration.requiresSqlite.ToString().ToLowerInvariant())",
    "-property:RequiresWpf=$([bool]$configuration.requiresWpf)".ToLowerInvariant(),
    "-property:MsalDirectory=$msalDirectory",
    "-property:OutputDirectory=$OutputDirectory"
)
& dotnet @arguments
if ($LASTEXITCODE) { throw "Analysis-only compilation failed with exit code $LASTEXITCODE." }
$compiled = @(Get-Content (Join-Path $OutputDirectory 'compiled-sources.txt') | Where-Object { $_ })
if (@(Compare-Object $sources.FullName $compiled).Count -ne 0) {
    throw 'Compiler source inventory does not equal the production inventory.'
}
$compiledReferences = @(Get-Content (Join-Path $OutputDirectory 'compiler-references.txt') | Where-Object { $_ })
if (@(Compare-Object $references.FullName $compiledReferences).Count -ne 0) {
    throw 'Compiler references do not equal the runtime reference inventory.'
}
$after = @($sources | ForEach-Object { Get-FileEvidence $_ })
if (($sourceEvidence | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) {
    throw 'Production source changed during analysis compilation.'
}
$manifest.compiledCount = $compiled.Count
$manifest['assemblySha256'] = (Get-FileHash (Join-Path $OutputDirectory 'Production.Analysis.dll')).Hash.ToLowerInvariant()
$manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'build-manifest.json') -Encoding utf8
Write-Output "Compiled $($compiled.Count) production C# files against exact runtime references; hosted extraction proof remains pending."
