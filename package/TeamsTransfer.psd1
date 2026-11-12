@{
    RootModule            = 'TeamsTransfer.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '7d3b1c52-4e0a-4f6e-9a1d-5c2e8b9f0a47'
    Author                = 'Nicolas Fabert'
    CompanyName           = 'Nicolas Fabert'
    Copyright             = '(c) Nicolas Fabert. MIT License.'
    Description           = 'TeamsTransfer: exports Microsoft Teams chats and channels (messages, reactions, files) from a tenant into a local store, previews them offline as a Teams-like HTML archive, and imports them into a tenant with the Microsoft Graph Teams migration API.'
    PowerShellVersion     = '7.4'
    CompatiblePSEditions  = @('Core')
    FunctionsToExport     = @(
        'Initialize-TmtEngine', 'Import-TmtConfiguration', 'Get-TmtSourceHash', 'Open-TmtStore', 'Get-TmtStoreStatus', 'New-TmtGraphClient'
        'Invoke-TmtInventory', 'Invoke-TmtAssess', 'Invoke-TmtExport', 'Invoke-TmtLotExport', 'Invoke-TmtFiles', 'Export-TmtArchive'
        'Initialize-TmtConsole', 'Write-TmtBanner', 'Write-TmtStep', 'Write-TmtItem', 'Write-TmtInfo', 'Write-TmtOk', 'Write-TmtWarn', 'Write-TmtFail', 'Write-TmtDetail'
        'Write-TmtProgress', 'Write-TmtSummary', 'Write-TmtEndCard', 'Write-TmtLog', 'Start-TmtLog', 'Stop-TmtLog', 'Get-TmtLogPath', 'Reset-TmtRunIssues'
        'Format-TmtNumber', 'Format-TmtBytes', 'Format-TmtDuration', 'Format-TmtRate', 'Format-TmtProgressLine', 'Get-TmtExitMeaning'
        'Invoke-TmtGhosts', 'Invoke-TmtFileCopy', 'Invoke-TmtVerify', 'Invoke-TmtLotReport'
        'Invoke-TmtImport', 'Write-TmtImportReport', 'Get-TmtImportExitCode'
        'New-TmtImportPlan'
        'Merge-TmtStore', 'Resolve-TmtWindow', 'ConvertTo-TmtWindowBoundaries', 'Get-TmtLotMembers', 'Initialize-TmtLot'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags       = @('Teams', 'Graph', 'Migration', 'Export', 'Archive')
            ProjectUri = 'https://github.com/Nico77600/TeamsTransfer'
        }
    }
}
