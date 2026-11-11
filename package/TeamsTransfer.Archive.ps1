# TeamsTransfer - Teams-like offline HTML archive (Mode Archive). Dot-sourced by TeamsTransfer.psm1.
# The viewer page is package\templates\Archive.template.html / .js, English only.

function Export-TmtArchive {
    <#
    .SYNOPSIS
        Writes an offline, Teams-like HTML archive of exported conversations (read-only, no network, no external resource).
    .DESCRIPTION
        Reads an IStoreReader (the local store) and writes
          - a FOLDER archive (default): <OutputPath>\index.html + data\ + search\ + content\ ; opens by double-click;
          - a SINGLE self-contained .html file (-SingleFile): chunks, search index and images embedded (gzip + base64), within a size budget.
        Scope: all the conversations of a user (-Users), a list of conversation keys (-Conversation), the channels of a team (-Teams),
        or the whole store when none is given. -Viewer chooses whose messages are shown on the right (defaults to the user).
        Nothing is written to a tenant. Progress lines are written every -IntervalSeconds.
    .PARAMETER Store
        An IStoreReader (TeamsTransfer.IStoreReader).
    .PARAMETER OutputPath
        Folder (folder archive) or .html file (-SingleFile).
    .PARAMETER Users
        One user id, UPN or mail: every conversation this user is a member of. This version archives one user at a time.
    .PARAMETER Conversation
        One or more conversation keys (chat:<id> or channel:<team>/<channel>).
    .PARAMETER Teams
        One team id: its channels. This version archives one team at a time.
    .PARAMETER Viewer
        User id, UPN or mail whose messages are drawn on the right.
    .PARAMETER SingleFile
        One .html file instead of a folder.
    .PARAMETER Language
        UI language of the page (English only for now; the page keeps an i18n table so a translation can be added).
    .PARAMETER Title
        Title of the archive page (default: derived from the scope).
    .PARAMETER Window
        '24m' / '60m' (the messages of the last N months) or 'from..to' (ISO dates). Alternative to -From / -To.
    .PARAMETER From
        Only the messages created on or after this moment.
    .PARAMETER To
        Only the messages created before this moment.
    .PARAMETER Accent
        Colour scheme of the viewer: House (the product raspberry, default) or Teams (indigo). Recorded in the manifest.
    .PARAMETER ContentBudgetMB
        Single file only: total size of images and files embedded in the page (default 128). The rest is shown as "not embedded".
    .PARAMETER IntervalSeconds
        Seconds between two progress lines (default 5).
    .OUTPUTS
        TeamsTransfer.PreviewResult (OutputPath, Mode, Conversations, Messages, Chunks, Files, FilesExported, Images, ImagesMissing, OutputBytes, Seconds, Warnings).
    .EXAMPLE
        Export-TmtArchive -Store $reader -Users camille.martin@contoso.com -OutputPath C:\Archives\camille
    .EXAMPLE
        Export-TmtArchive -Store $reader -Teams $teamId -OutputPath C:\Archives\team.html -SingleFile
    #>
    [CmdletBinding()]
    [OutputType('TeamsTransfer.PreviewResult')]
    param(
        [Parameter(Mandatory)][TeamsTransfer.IStoreReader]$Store,
        [Parameter(Mandatory)][string]$OutputPath,
        [string[]]$Users,
        [string[]]$Conversation,
        [string[]]$Teams,
        [string]$Viewer,
        [switch]$SingleFile,
        [ValidateSet('en')][string]$Language = 'en',
        [ValidateSet('House', 'Teams')][string]$Accent = 'House',
        [string]$Title,
        [string]$Window,
        [Nullable[datetimeoffset]]$From,
        [Nullable[datetimeoffset]]$To,
        [ValidateRange(0, 100000)][int]$ContentBudgetMB = 128,
        [ValidateRange(50, 100000)][int]$MaxItemsPerChunk = 2000,
        [ValidateRange(1, 3600)][int]$IntervalSeconds = 5
    )
    if (-not ('TeamsTransfer.PreviewExporter' -as [type])) { Initialize-TmtEngine }
    $user = $null; $team = $null
    if ($Users) {
        if (@($Users).Count -gt 1) { throw 'Archive takes one user at a time in this version: pass a single -Users value, or -Conversation with several keys.' }
        $user = [string]@($Users)[0]
    }
    if ($Teams) {
        if (@($Teams).Count -gt 1) { throw 'Archive takes one team at a time in this version: pass a single -Teams value.' }
        $team = [string]@($Teams)[0]
    }
    $scope = if ($user) { "user $user" }
        elseif ($Conversation) { "selected conversations ($(@($Conversation).Count))" }
        elseif ($team) { "team $team" }
        else { 'every conversation of the store' }
    $o = [TeamsTransfer.PreviewOptions]::new()
    $o.OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $o.SingleFile = [bool]$SingleFile
    $o.User = $user
    $o.ConversationKeys = $Conversation
    $o.TeamId = $team
    $o.Viewer = $Viewer
    $o.Language = $Language
    $o.Accent = $Accent
    $o.Title = $Title
    $o.ScopeLabel = $scope
    $o.TemplateDirectory = Join-Path $PSScriptRoot 'templates'
    $o.ContentBudgetBytes = [long]$ContentBudgetMB * 1MB
    $o.MaxItemsPerChunk = $MaxItemsPerChunk
    $range = Resolve-TmtWindow $Window
    if ($range) { $o.FromUtc = $range.From.ToUniversalTime(); if ($null -ne $range.To) { $o.ToUtc = $range.To.ToUniversalTime() } }
    if ($null -ne $From) { $o.FromUtc = $From.Value.ToUniversalTime() }
    if ($null -ne $To) { $o.ToUtc = $To.Value.ToUniversalTime() }
    # The engine reports from this thread (Run is synchronous): one dim progress line per interval, also in the log.
    $state = @{ Next = [DateTime]::UtcNow.AddSeconds($IntervalSeconds); Interval = $IntervalSeconds }
    $o.Progress = [Action[string]]{
        param($m)
        if ([DateTime]::UtcNow -ge $state.Next) { $state.Next = [DateTime]::UtcNow.AddSeconds($state.Interval); Write-TmtDetail ([string]$m) } else { Write-Verbose ([string]$m) }
    }.GetNewClosure()
    $result = [TeamsTransfer.PreviewExporter]::new($Store, $o).Run()
    foreach ($w in $result.Warnings) { Write-TmtWarn ([string]$w) }
    $result
}
