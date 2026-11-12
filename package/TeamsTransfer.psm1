#Requires -Version 7.4
<#
.SYNOPSIS
    TeamsTransfer - root module: the engine (C# compiled in memory), the configuration, the console and log helpers, and the Tmt* commands.
.DESCRIPTION
    Regions, in the order of execution:
      1. Engine sources   the C# files compiled together (src\Engine.*.cs)
      2. Compilation      SQLite (lib\sqlite) + in-memory compilation, once per process (Initialize-TmtEngine)
      3. Configuration    config\TeamsTransfer.config.psd1 (data, never executed) + config\TeamsTransfer.config.local.psd1 on top
      4. Store            Open-TmtStore, Get-TmtStoreStatus
      5. Dot-sourced      TeamsTransfer.Console.ps1 (banner, steps, log, formats), TeamsTransfer.Export.ps1 (Inventory, Assess, Export, Files),
                          TeamsTransfer.Archive.ps1 (offline HTML archive)
    The package integrity check belongs to the entry script (Invoke-TeamsTransfer.ps1), which runs it before this module is loaded.
    Public functions are prefixed Tmt. Operator messages go through the Write-Tmt* helpers (console + log), never through Write-Progress,
    Write-Information or Write-Warning.
.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    History : see CHANGELOG.md

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolRoot = $PSScriptRoot

#region 1. Engine sources ----------------------------------------------------------------------
# Order matters only for readability; all files are compiled in one unit.
# One file per line; add new engine files at the end of their group.
$script:EngineFiles = @(
    'Engine.Contracts.cs'
    'Engine.StoreContracts.cs'
    'Engine.ImportContracts.cs'
    # --- Auth, Graph, throttling ---
    'Engine.Throttle.cs'
    'Engine.Auth.cs'
    'Engine.Graph.cs'
    # --- Store and catalog ---
    'Engine.Store.cs'
    'Engine.Catalog.cs'
    # --- Inventory, assess, export, files ---
    'Engine.Inventory.cs'
    'Engine.Export.cs'
    # --- Offline HTML archive ---
    'Engine.Preview.cs'
    # --- Mapping + Plan (lot H) ---
    'Engine.CatalogImport.cs'
    'Engine.Mapping.cs'
    'Engine.Plan.cs'
    # --- Importer (lot I) ---
    'Engine.Import.cs'
    # --- Ghosts + FileCopy + Verify (lot J) ---
    'Engine.Ghosts.cs'
    'Engine.FileCopy.cs'
    'Engine.Verify.cs'
)
#endregion

#region 2. Compilation ---------------------------------------------------------------------------

function Get-TmtSourceHash {
    <#
    .SYNOPSIS
        SHA256 of a list of source files (name and bytes), used to detect an engine compiled from other sources in the same process.
    .PARAMETER Path
        The files to hash, in order.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($file in $Path) {
            $sha.AppendData([Text.Encoding]::UTF8.GetBytes((Split-Path -Leaf $file) + "`n"))
            $sha.AppendData([IO.File]::ReadAllBytes($file))
        }
        return [BitConverter]::ToString($sha.GetHashAndReset()).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Initialize-TmtEngine {
    <#
    .SYNOPSIS
        Loads SQLite (lib\sqlite) and compiles the engine sources in memory, once per process.
    .PARAMETER AdditionalSource
        More C# files compiled in the same unit (tests\support). An in-memory assembly cannot be referenced by a
        later Add-Type, so test helpers must be compiled together with the engine.
    #>
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot, [string[]]$AdditionalSource = @())

    $sources = @(foreach ($name in $script:EngineFiles) {
        $file = Join-Path $Root "src\$name"
        if (-not (Test-Path -LiteralPath $file)) { throw "Engine source file not found: $file" }
        $file
    })
    $expected = Get-TmtSourceHash -Path (@($sources) + @($AdditionalSource | Where-Object { $_ }))
    if ('TeamsTransfer.GraphCloudEndpoints' -as [type]) {
        $loaded = [AppDomain]::CurrentDomain.GetData('TeamsTransfer.Engine.SourceHash')
        if ($loaded -eq $expected) { return }
        throw ('The TeamsTransfer engine loaded in this PowerShell session was compiled from other sources. ' +
            'A compiled engine cannot be replaced in a running process: open a new PowerShell session (pwsh).')
    }

    $lib = Join-Path $Root 'lib\sqlite'
    $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
    $native = Join-Path $lib "runtimes\$arch\native\e_sqlite3.dll"
    if (-not (Test-Path -LiteralPath $native)) { $native = Join-Path $lib "runtimes\$arch\e_sqlite3.dll" }
    if (-not (Test-Path -LiteralPath $native)) { throw "SQLite native library not found under $lib\runtimes\$arch" }
    [void][Runtime.InteropServices.NativeLibrary]::Load($native)
    foreach ($name in 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2', 'Microsoft.Data.Sqlite') {
        Add-Type -LiteralPath (Join-Path $lib "$name.dll")
    }
    [SQLitePCL.Batteries_V2]::Init()

    $references = @((Join-Path $lib 'Microsoft.Data.Sqlite.dll'), (Join-Path $lib 'SQLitePCLRaw.core.dll'),
        'System.Data.Common', 'System.Buffers', 'System.IO', 'System.IO.Compression', 'System.Runtime.InteropServices', 'System.Net.Http',
        'System.Net.Http.Json', 'System.Text.Json', 'System.Collections', 'System.Linq', 'System.Runtime', 'System.Memory',
        'System.Security.Cryptography', 'System.Security.Cryptography.X509Certificates', 'System.Text.RegularExpressions',
        'System.Threading', 'System.Threading.Tasks', 'System.Threading.Thread', 'System.Threading.Channels',
        'netstandard', 'System.Net.Primitives', 'System.IO.FileSystem', 'System.Console', 'System.Text.Encoding.Extensions',
        'System.Runtime.Extensions', 'System.Collections.Concurrent', 'System.Diagnostics.Process', 'System.Web.HttpUtility',
        'System.Private.Uri', 'System.Collections.NonGeneric', 'System.Net.Security', 'System.Linq.Expressions', 'System.ComponentModel.Primitives')
    Add-Type -LiteralPath (@($sources) + @($AdditionalSource | Where-Object { $_ })) -ReferencedAssemblies $references -IgnoreWarnings -WarningAction SilentlyContinue
    [AppDomain]::CurrentDomain.SetData('TeamsTransfer.Engine.SourceHash', $expected)
}
#endregion

#region 3. Configuration -------------------------------------------------------------------------

function script:Get-TmtDefaultConfiguration {
    # Built-in defaults: a section or key missing from the file is never a KeyNotFound error.
    return @{
        Source  = @{ Cloud = 'Global'; TenantId = ''; ClientId = ''; CertificateThumbprint = '' }
        Target  = @{ Cloud = 'Global'; TenantId = ''; ClientId = ''; CertificateThumbprint = ''; ServiceAccountUserId = '' }
        Graph   = @{ MaxAttempts = 8; BaseBackoffSeconds = 2; MaxBackoffSeconds = 120; RequestTimeoutSeconds = 300; ExportModel = 'B'; InitialRatePerSecond = 20; MaxConcurrency = 32 }
        Store   = @{ Path = ''; Partitions = 256 }
        Output  = @{ Root = '.\out' }
        Logging = @{ RetentionDays = 14 }
    }
}

function script:Merge-TmtConfiguration {
    param([hashtable]$Base, [hashtable]$Override)
    foreach ($section in $Override.Keys) {
        if ($Base.ContainsKey($section) -and $Base[$section] -is [hashtable] -and $Override[$section] -is [hashtable]) {
            foreach ($k in $Override[$section].Keys) { $Base[$section][$k] = $Override[$section][$k] }
        } else { $Base[$section] = $Override[$section] }
    }
}

function script:Read-TmtConfigurationFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path. Use -ConfigPath, or restore config\TeamsTransfer.config.psd1." }
    try { return Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "Configuration file $Path cannot be read as data: $($_.Exception.Message) Fix the syntax (a .psd1 holds data only, never code)." }
}

function Import-TmtConfiguration {
    <#
    .SYNOPSIS
        Reads the configuration as data (never executed): built-in defaults, then config\TeamsTransfer.config.psd1, then the local file on top, section by section.
    .DESCRIPTION
        The local file is config\TeamsTransfer.config.local.psd1 next to the configuration file (private values of the machine), or the file named by the
        environment variable TEAMSTRANSFER_LOCAL_CONFIG (tests). Sections: Source, Target, Graph, Store, Output, Logging.
    .PARAMETER Path
        Configuration file (default: config\TeamsTransfer.config.psd1 of the package).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path = (Join-Path $script:ToolRoot 'config\TeamsTransfer.config.psd1'))
    $config = Get-TmtDefaultConfiguration
    Merge-TmtConfiguration $config (Read-TmtConfigurationFile $Path)
    $local = if ($env:TEAMSTRANSFER_LOCAL_CONFIG) { $env:TEAMSTRANSFER_LOCAL_CONFIG } else { [IO.Path]::ChangeExtension($Path, '.local.psd1') }
    if (Test-Path -LiteralPath $local -PathType Leaf) { Merge-TmtConfiguration $config (Read-TmtConfigurationFile $local) }
    return $config
}
#endregion

#region 4. Store ----------------------------------------------------------------------------------

function Open-TmtStore {
    <#
    .SYNOPSIS
        Opens (or creates) the local store of a folder. The store is refused inside the package folder and on a network share.
    .PARAMETER Root
        Folder of the store.
    .PARAMETER Partitions
        Number of message partitions of a NEW store (default 256); an existing store keeps its own.
    .PARAMETER ReadOnly
        Opens an existing store without taking the write lock (Status, Archive).
    .OUTPUTS
        TeamsTransfer.TmtStore (dispose it when done).
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.TmtStore')]
    param([Parameter(Mandatory)][string]$Root, [ValidateRange(1, 4096)][int]$Partitions = 256, [switch]$ReadOnly)
    if (-not ('TeamsTransfer.TmtStore' -as [type])) { Initialize-TmtEngine }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $o = [TeamsTransfer.StoreOptions]::new()
    $o.PackageRoot = $script:ToolRoot
    $o.ReadOnly = [bool]$ReadOnly
    $existing = [TeamsTransfer.TmtStore]::PeekPartitions($full)
    $o.Partitions = if ($existing -gt 0) { $existing } else { $Partitions }
    return [TeamsTransfer.TmtStore]::Open($full, $o)
}

function Get-TmtStoreStatus {
    <#
    .SYNOPSIS
        The state of an open store: counts, segments, inventory pass, pending files and lots (items per state, import sessions, journal summary).
    .PARAMETER Store
        An open TeamsTransfer.TmtStore.
    .OUTPUTS
        PSCustomObject (Root, StoreId, Partitions, PartitionsUsed, Users, InventoriedConversations, Conversations (= with messages), Messages, Segments, SegmentBytes, InventoryState, PendingFiles,
        Lots: Id, Name, State, ChangedUtc, Items, ItemsByState (ordered name -> count), Sessions, Journal (Imported, Conflict409, Rejected, Pending, Skipped)).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store)
    $stats = $Store.GetStats()
    $pending = 0
    foreach ($f in $Store.PendingFiles(100001)) { $pending++ }
    $lots = @($Store.ListLots() | ForEach-Object {
            $byState = [ordered]@{}
            $n = 0
            foreach ($g in @($Store.ListItems($_.Id) | Group-Object { [string]$_.State } | Sort-Object Name)) { $byState[$g.Name] = $g.Count; $n += $g.Count }
            $js = $Store.GetLotJournalSummary($_.Id)
            [pscustomobject][ordered]@{
                Id = $_.Id; Name = $_.Name; State = [string]$_.State; ChangedUtc = $_.StateChangedUtc
                Items = $n; ItemsByState = $byState; Sessions = $Store.CountImportSessions($_.Id)
                Journal = [pscustomobject][ordered]@{
                    Imported = [int]$js[[TeamsTransfer.JournalStatus]::Imported]; Conflict409 = [int]$js[[TeamsTransfer.JournalStatus]::Conflict409TreatedAsImported]
                    Rejected = [int]$js[[TeamsTransfer.JournalStatus]::Rejected]; Pending = [int]$js[[TeamsTransfer.JournalStatus]::Pending]; Skipped = [int]$js[[TeamsTransfer.JournalStatus]::Skipped]
                }
            }
        })
    [pscustomobject][ordered]@{
        Root = $Store.Root; StoreId = $Store.StoreId; Partitions = $stats.Partitions; PartitionsUsed = $stats.PartitionsUsed
        Users = $stats.Users; InventoriedConversations = $Store.CountInventoriedConversations(); Conversations = $stats.Conversations; Messages = $stats.Messages
        Segments = $stats.Segments; SegmentBytes = $stats.SegmentBytes
        InventoryState = [string]$Store.GetCheckpoint('inv:state'); PendingFiles = $pending; Lots = $lots
    }
}

function Merge-TmtStore {
    <#
    .SYNOPSIS
        Folds another store (the store of another workstation) into this one: catalog inventory, files, authors, ghosts, every message and the content blobs.
    .DESCRIPTION
        The other store is opened read-only and never modified; this store is written. Idempotent: a second run changes nothing (a newer version of a message wins,
        an identical one is counted unchanged). Lots, leases and import sessions are not merged: this store (the coordinator) is authoritative for them. Both
        stores must have the same partition count. Use it after each workstation exported a DISJOINT lot into its own store.
    .PARAMETER Store
        An open writable TeamsTransfer.TmtStore (the destination).
    .PARAMETER FromStore
        Root folder of the other store.
    .OUTPUTS
        TeamsTransfer.StoreMergeReport (Users, Conversations, Links, Files, HostedContents, Checkpoints, Authors, Ghosts, PartitionsMerged, MessagesNew, MessagesUpdated, MessagesUnchanged, ContentCopied, ContentPresent).
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.StoreMergeReport')]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$FromStore)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FromStore)
    if (-not (Test-Path -LiteralPath (Join-Path $full 'catalog.db') -PathType Leaf)) { throw "No store at $full (-FromStore): give the root folder of the other store, the one that holds catalog.db." }
    return $Store.Merge($full)
}
#endregion

. (Join-Path $PSScriptRoot 'TeamsTransfer.Console.ps1')
. (Join-Path $PSScriptRoot 'TeamsTransfer.Export.ps1')
. (Join-Path $PSScriptRoot 'TeamsTransfer.Archive.ps1')
. (Join-Path $PSScriptRoot 'TeamsTransfer.Verify.ps1')
Export-ModuleMember -Function Invoke-TmtGhosts, Invoke-TmtFileCopy, Invoke-TmtVerify, Invoke-TmtLotReport   # lot J (several Export-ModuleMember calls add up)
. (Join-Path $PSScriptRoot 'TeamsTransfer.Import.ps1')
. (Join-Path $PSScriptRoot 'TeamsTransfer.Plan.ps1')

Export-ModuleMember -Function Initialize-TmtEngine, Import-TmtConfiguration, Get-TmtSourceHash, Open-TmtStore, Get-TmtStoreStatus, New-TmtGraphClient,
    Invoke-TmtInventory, Invoke-TmtAssess, Invoke-TmtExport, Invoke-TmtLotExport, Invoke-TmtFiles, Export-TmtArchive,
    Initialize-TmtConsole, Write-TmtBanner, Write-TmtStep, Write-TmtItem, Write-TmtInfo, Write-TmtOk, Write-TmtWarn, Write-TmtFail, Write-TmtDetail,
    Write-TmtProgress, Write-TmtSummary, Write-TmtEndCard, Write-TmtLog, Start-TmtLog, Stop-TmtLog, Get-TmtLogPath, Reset-TmtRunIssues,
    Format-TmtNumber, Format-TmtBytes, Format-TmtDuration, Format-TmtRate, Format-TmtProgressLine, Get-TmtExitMeaning,
    Invoke-TmtImport, Write-TmtImportReport, Get-TmtImportExitCode,
    Merge-TmtStore, Resolve-TmtWindow, ConvertTo-TmtWindowBoundaries, Get-TmtLotMembers, Initialize-TmtLot
