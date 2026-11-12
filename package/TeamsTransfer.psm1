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

# SIG # Begin signature block
# MIImKQYJKoZIhvcNAQcCoIImGjCCJhYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDeRpO3zdQMnDq+
# Fsj7aN1pnTU4NlSy3HHXQyi8nV+3taCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYEDCCGAwCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCEc1oEaZXP
# qWYFKg8grKftp+8a2Gr3jweVSyirdXwQTjANBgkqhkiG9w0BAQEFAASCAgCZKhG6
# NocBGDP2XnqBEIBJS44cctyB8Laya+16xEESUPGhNel8qjAXrsPpaO7Bf6P3BvvQ
# YxTSHV/1D4rJ5i5aZhtand4TGjuTboR5FCHdwptWgvxNp2Ie6uqH+5UgCIx0a3T9
# MN9LVYkQF3LcBmlYB1uljUqrQmfD2tRW6hq094j0UKwDM9zELnxPzPh6kHeQh2aH
# qBWd1i4GjKJ/TYQulad5L88jZNp0igv/AuGGS2z6NxCj/CK0a95hP67KerU2REO/
# GETLaOJ7eMqvw+v9yJhwMVeV43sb6E5gHx+BKlcsvQGs4Vbsdzw5TY7BZSS3fJVQ
# P7HGuN+G5cgThfVdqvunovU82yqoGVN9lclVoS1pRTUYPj9EM67sbCUvgMzoQnbI
# Goqh+stBOirWhy1KIZYOT/dkuO/F+4LYJtrxJu5138gHw/Pxyn0sHUco/tlEdLUD
# NY1tfWzdbVfWdwIxnGOy1wYYoa1PoZZFu2Lg3dDQvNac9RYJVplArhBovGFDKRhZ
# ZuegRmxqR6mPYN+o38Dega+FaSK0PbU986bZyXsi7KKvjOs+27Z69nRINGVXb3WK
# VtJtJmokqCKgDu6cnwKQhGST1/pDlgmTnfsJzQ8KlNzf8bVbtDT7Z74BZ9wPPGTX
# tYoA9R/UNgXnBug1XN09Mp6XnjRl5VUJivNPr6GCFM0wghTJBgorBgEEAYI3AwMB
# MYIUuTCCFLUGCSqGSIb3DQEHAqCCFKYwghSiAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIINYrKetJECQ4kESegtmVjPMHsJ0H835Iv+8cVY8Z1BgAgh1AcCffpx/
# fBgPMjAyNjExMTIxMjExMDhaMAMCAQECEA/PmM8J/y/Pb4v7TRysaS+gghGnMIIE
# 8zCCAtugAwIBAgIQVEP4N71a7hgBhHK4XNqO4zANBgkqhkiG9w0BAQsFADByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyMB4XDTI2MDYxMjE3MjI0NloXDTM2MDYwOTE3MjI0NVow
# bjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBp
# bmcgVW5pdCAyMDI2IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6CWLuGYT
# LkiSOPMLNskOBthXsIhRSA46feOQwvSLcDaNh6vxUzBKEx1KdFBRFs7OHrnH/K0V
# A6MbDQIFpUg0PaOCAVIwggFOMB8GA1UdIwQYMBaAFHCaZcFDgKP86bFkiW7xMJwJ
# Icl8ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3Ns
# LmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1JLVIyLmNlcjBRBgNVHSAESjBIMDwG
# DCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29t
# L3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEIG
# A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNvbS10aW1l
# U3RhbXBpbmctSS1SMi5jcmwwHQYDVR0OBBYEFCesA1a6KGq6FzuDPUB/eagk7MM8
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT3ZuzvwDnsIZTXBn
# +hjmuBXgzB12fbYxT9uYe6ZvhvpbZWKcyDQgacETkPw8k6yeqnYCYyFZ063lMPEq
# AhAD2nMG614Zh7PtHW9DWqfsgivxbPYBeN+t7UxgkYT3expbWMdPEqBtWVyHOvLc
# KvMxgJWfJjANwVkwVDfky/j7cf28+iimN8PKc7S/u8/LenRRnV2W2YfncRnkz9Cf
# s5nRDzaZguiHrrp2GxwgnNQSH4GBjHOl3PzLsnVbGoZKi4ZEjgXups4mGGOK7+GB
# 2HAlQn+OS944cHqlkH0gElt2WezoCNRpELph9qaxuBnjSEqXWWfgE6yGBwO0uxKN
# qpWVTHmAwr6SvBPofxubXIuEn9ivR4CLOuAxUSrJ41ZBg/qqG0oJjF6GkRKbxq7c
# yWSkEZYJhmKCg2Hg5fXHagOxiwbmn5JPZ1vhWCrbk3v/dTx2gvTK5+erC5H9/rTc
# ljUI776yd2rfhjfkpvyAsbtXs4D7nrnw8i9wor5+fdtRSJBVxqzLmykFftoL0Up2
# Q++tyKCUdribdcnrB4HKS3s+t3AjdcbA06DCL8GifQi9fL0yRBRNlA4o6BP+Sr75
# 5MaCNjURYZDvDyxJHBBT7cqjZIwsiR8s+6860noFbBBtdge2Iw7CPC/1Q31I27hV
# olS7B0yao3v8X2MtWy3msZlXTcEwggXdMIIDxaADAgECAgh7LJvTFoAymTANBgkq
# hkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8GA1UEAwwo
# U1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAeFw0xNjAy
# MTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQI
# DAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0
# aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3Jp
# dHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/doyt9y9Aq
# /uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aUnheDhc5W
# 7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q6Pw/YUjt
# sAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg+sglkrRu
# eiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qhk4jrwZe8
# jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmylD0CGfAL0
# XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUuqfqeLLZR
# Rv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiYohgsQkCz
# +W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZTNTX8N+TD
# 9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZX5es6+8u
# yLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumamdu0bc+sa
# pQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYEFN0ECQei
# 9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU3QQJ
# B6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUA
# A4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9eGr0uYul
# lzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK3cT5lR+K
# OEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF9J1r/Blj
# naO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9hqTKWzN67
# 7WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg+/a1LRrm
# woWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP5UU/eNu6
# 0htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53eyoHWXtS2B
# iBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8PUkg9v2zY
# okQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaPzvDsbopX
# C4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOLYRu8+h+R
# K9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBsswggSzoAMC
# AQICEFKdu8K4iYf1g4DgsOuiBjYwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9T
# U0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0
# aW9uIEF1dGhvcml0eSBSU0EwHhcNMjYwNjEyMTY0MjE1WhcNNDEwMjEyMTczOTM5
# WjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFt
# cGluZyBJc3N1aW5nIFJTQSBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAny+r5nNNkLwxRps2B3laUGNU9y7vWiJ5013yf0iXz65bQdwa9bjj8l/S
# keXqHGqfSh2Foae+80E8mDEf93oIwjsy2CX2cXmKxqtF8HJGYB4f6yRhKED50wkb
# OysL02IXf+/EZna44jffhhVz4OU/k52xQ/PnIg/uFhc2Wk+Sc/CHqAr+lYVkPz7L
# y5RqB9f1RKGr9JC37W1LgVdHC50dNIdsa3QXPhltYZubR3npE4Bbfi0joUW5n5O0
# ayweN45R/YVLxA0YGlp1OHVfVnsqXq8bhnw1Lc4kjJ6XOgXlOlw/a8ze57TvbduZ
# l3ehewTmvO0Aky/nqOWDS9IPPxdxdG6vprBbSuHlxNANBAbHTiFgkfZmf0dZYlT/
# AnZIoFxAq0HILPolf4OgWgET76SiWSlm2XYRIXwVjpeqG0plvXwRIQBzSiEJj7Qe
# QFnCvHx4gQMINvN3+yG/1rxhEbajGve0tTP3lX4PPOHVAE0QJp4ZzPI1YYJkhVRr
# iVVxVRU4Fsg4BPwP6I+YLmHb1tZ4RLwOFNLh/gJYDgPlChCoxOogFxXgwPZZrDyE
# RYB0aeOexW0OKacN4RRu9cqF2KKu/Ab5AL7eYDLVGUPrEEyYbIMApVKqpebc0/jD
# QniC+3rkauRAjgVc8m1ip/CQgG1Dw4Z9ulVRAY9VR6Za26LsTbUCAwEAAaOCAVEw
# ggFNMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKS
# le44gCUNplkwTQYIKwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2Vy
# dC5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY2VyMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwQgYDVR0fBDswOTA3oDWgM4Yx
# aHR0cDovL2NybHMuc3NsLmNvbS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNy
# bDAdBgNVHQ4EFgQUcJplwUOAo/zpsWSJbvEwnAkhyXwwDgYDVR0PAQH/BAQDAgGG
# MA0GCSqGSIb3DQEBCwUAA4ICAQBlFFvNMemA6iBiBYo56IKQjWhWuQaYKuo4qpf0
# KJNERAt1gz+HsA2SL3xA/V+EA8SRPNP9SvX0is+5mDsppYvpKyYGqYP36YFW0mbF
# 1F0ZtXxumCUUO/ZV5mBNKDf5Q4PY7Qb0eWAepUc0rNJr/Mvn5ZiXfJPxDb2xmcg8
# aRD652/nr+Ork2UBP0E43iJdI4LF7Vs29R3SGRLYZOxM15DI4QebsKRl0KDlf4Om
# YGCKc7umTxibkZtN1C1KWgnf9jadU/JwnySaYEBgx6/v+FVC6SGONziY7TcvI9MV
# +qYxHUPlOm6AaQP2dS4bjWXnm86ldCbUkxtOACumSfT97077JNiVa7PZ1IBkd/2P
# E1AC8gs7U+/Yk1BN9XRPIi15k/uA1xF9oeee5KGjyiGKkqIT7W8QkgUT5zeCinFK
# kcKafZMcROSVYpXtmtQqGGR2g4uPYqJ0K1hms6gJXrHt/34p8M9PrV8oNWe0Zl1E
# rDMtXndUg3qhJL4pA3ZUlo7w5lM5ml+A7ijr/3Gk2v4QRoDeE2ShmTXdHgtqo8L/
# fT119mYcETycE2NYGRXsBl3N0rzDsHRr8P3TrprqhRrX04iS0P7eQ+lDxgS3yhGn
# 3OzWGhDt9Gf2x1qe0/qdhFAVOkXxzMZz4Uat6xsAfzX0+/m8GEKW5Ojw/HY+kLvV
# wzSPOzGCAlUwggJRAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExMjEyMTEwOFowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIAGy
# Z3m8vcKK2O+OwuiiDi1p/wg9c7ojZo/eVgau9+HgMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERjBEAiBEytHDz+yeKysKQIz2CFzaZpzla/+qmO/ltvwLhES9igIgekvb
# NFOseY0V51FTfmys6YL/siOTKmxeOpcnwq0Iaao=
# SIG # End signature block
