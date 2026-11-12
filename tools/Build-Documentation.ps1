#Requires -Version 7.4

<#
.SYNOPSIS
    Builds the self-contained HTML guides of Teams Transfer from their Markdown sources (or one guide, from explicit local paths).

.DESCRIPTION
    The Markdown guide stays readable as plain text. This script turns it into a structured, self-contained page:

      - hero header (title, version, author, date) built from the front matter,
      - sticky sidebar with the parts and chapters, highlighting the chapter being read,
      - each chapter ("## ...") in its own card, with an icon and a number badge,
      - callouts from GitHub alerts (> [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]),
      - three custom blocks written as fenced code in the Markdown:
          ```cards   icon | title | text          (grid of small cards)
          ```steps   title | text                 (numbered timeline)
          ```flow    icon | title | subtitle      (diagram; "arrow | label | text" = connector)
      - code blocks with a language label and a Copy button,
      - local PNG/JPEG/GIF/WEBP images embedded as data URIs (the HTML file can be sent alone) with a zoom on click,
      - light / dark / system theme, keyboard focus, forced-colors and print layout,
      - the project disclaimer, exactly as in the documentation standard.

    The Markdown is untrusted input. The converter output is passed through an allow-list sanitizer: raw HTML elements that are not allowed
    (script, style, iframe, object, form, event handlers, ...) are shown as text, unsafe link schemes are dropped, and remote or unsafe images are
    replaced by a text note. No external font, script, style or image is ever referenced, and no network access is made. The output is deterministic:
    the same Markdown, image bytes and script produce byte-identical HTML (no clock, no machine or user name).

    Section icons: put <!-- icon: name --> on the line before a "## " heading. The names are the keys of $Icons.
    A link to another guide is written with its GitHub anchor (TeamsTransfer-Guide.md#chapter): in the HTML page it points to the HTML
    file of that guide.

.PARAMETER Source
    Markdown guide to build (an existing .md file of at most 4 MiB). Without -Source and -Destination, both guides of package\docs are built (replacing the HTML files).

.PARAMETER Destination
    HTML file to write (.html). The directory must exist. An existing file is only replaced with -Force. It must not be the source.

.PARAMETER ImageRoot
    Directory that local images of the guide are resolved against and must stay inside. Default: the directory of the source.

.PARAMETER Force
    Replace an existing destination file.

.EXAMPLE
    .\tools\Build-Documentation.ps1
    Builds package\docs\TeamsTransfer-UserGuide.html and package\docs\TeamsTransfer-Guide.html from their Markdown files.

.EXAMPLE
    .\tools\Build-Documentation.ps1 -Source .\package\docs\TeamsTransfer-Guide.md -Destination .\out\Guide.html -Force

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    PowerShell pitfall: never name a variable $matches (every -match overwrites the automatic $Matches).
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [string]$ImageRoot,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No explicit paths: build the two guides of the package, each in its own child pwsh (the script keeps one page of state).
if (-not $Source -and -not $Destination) {
    $docs = Join-Path (Split-Path -Parent $PSScriptRoot) 'package\docs'
    foreach ($name in 'TeamsTransfer-UserGuide', 'TeamsTransfer-Guide') {
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Source (Join-Path $docs ($name + '.md')) -Destination (Join-Path $docs ($name + '.html')) -Force
        if ($LASTEXITCODE -ne 0) { throw "Build of $name failed (exit code $LASTEXITCODE)."}
    }
    return
}
if (-not $Source -or -not $Destination) { throw 'Give both -Source and -Destination, or neither (builds both guides of package\docs).' }

$MaxSourceBytes = 4MB
$MaxImageBytes = 8MB

# ---- Paths ----------------------------------------------------------------------------------------------------------
if ($Source -match '[\*\?]' -or $Destination -match '[\*\?]') { throw 'Wildcards are not allowed in the source or the destination.' }
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'The source Markdown file does not exist.' }
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
if ([IO.Path]::GetExtension($Source) -ne '.md') { throw 'The source must be a .md file.' }
if ((Get-Item -LiteralPath $Source).Length -gt $MaxSourceBytes) { throw 'The source Markdown file is larger than 4 MiB.' }
$Destination = [IO.Path]::GetFullPath($Destination)
if ([IO.Path]::GetExtension($Destination) -ne '.html') { throw 'The destination must be a .html file.' }
if ($Destination -eq $Source) { throw 'The destination must not be the source.' }
$destinationDirectory = [IO.Path]::GetDirectoryName($Destination)
if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { throw 'The destination directory does not exist.' }
if ((Test-Path -LiteralPath $Destination) -and -not $Force) { throw 'The destination already exists; use -Force to replace it.' }
if (-not $ImageRoot) { $ImageRoot = [IO.Path]::GetDirectoryName($Source) }
if (-not (Test-Path -LiteralPath $ImageRoot -PathType Container)) { throw 'The image root does not exist.' }
$ImageRoot = (Resolve-Path -LiteralPath $ImageRoot).ProviderPath.TrimEnd('\', '/')

$enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }

# The disclaimer of the documentation standard; the text is part of that contract and must not be reworded.
$Disclaimer = "This Script is a Personal project.`nIt's provided ""AS-IS"". It's not an official Microsoft product so no support can be expected from Microsoft.`n`nAs any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.`n`nImport creates conversations in the target tenant and an imported conversation cannot be rolled back: run the preview, review the plan and test in a lab before using it on real data."

# ---- Icons (24x24, stroke) ------------------------------------------------------------------------------------------
$Icons = @{
    book      = '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/><path d="M4 19V5"/><path d="M8 7h7M8 11h5"/>'
    flow      = '<rect x="3" y="4" width="7" height="5" rx="1.5"/><rect x="14" y="15" width="7" height="5" rx="1.5"/><path d="M6.5 9v4a2 2 0 0 0 2 2H14"/>'
    lightbulb = '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/>'
    checklist = '<path d="M10 6h10M10 12h10M10 18h10"/><path d="m3.5 6 1.5 1.5L8 4.5M3.5 12l1.5 1.5L8 10.5M3.5 18l1.5 1.5L8 16.5"/>'
    download  = '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 20h16"/>'
    settings  = '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>'
    clock     = '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'
    terminal  = '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>'
    chart     = '<path d="M3 20h18"/><path d="M6 16v-5M11 16V6M16 16v-8"/>'
    layers    = '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>'
    gear      = '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.9 4.9 7 7M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1 7 17M17 7l2.1-2.1"/>'
    wrench    = '<path d="M15 4a5 5 0 0 0-4.6 6.9L3 18.3 5.7 21l7.4-7.4A5 5 0 0 0 20 9l-3 1-3-3 1-3z"/>'
    beaker    = '<path d="M9 3h6M10 3v6L4.5 18.5A1.7 1.7 0 0 0 6 21h12a1.7 1.7 0 0 0 1.5-2.5L14 9V3"/><path d="M7 15h10"/>'
    lifebuoy  = '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="m5.6 5.6 3.6 3.6M14.8 14.8l3.6 3.6M18.4 5.6l-3.6 3.6M9.2 14.8l-3.6 3.6"/>'
    compare   = '<rect x="3" y="4" width="7" height="16" rx="1.5"/><rect x="14" y="4" width="7" height="16" rx="1.5"/><path d="M6.5 9h0M17.5 9h0"/>'
    database  = '<ellipse cx="12" cy="5.5" rx="8" ry="3"/><path d="M4 5.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>'
    tag       = '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8" r="1.5"/>'
    target    = '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>'
    file      = '<path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4M9 13h6M9 17h6"/>'
    calendar  = '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>'
    refresh   = '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.3 4.9L20 16"/><path d="M20 20v-4h-4"/>'
    people    = '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14.5a5 5 0 0 1 5.5 5"/>'
    key       = '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l3 3"/>'
    shield    = '<path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z"/><path d="m9 12 2 2 4-4"/>'
    info      = '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.5"/>'
    search    = '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>'
    check     = '<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>'
    play      = '<circle cx="12" cy="12" r="9"/><path d="m10 8 6 4-6 4z"/>'
    mail      = '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>'
    copy      = '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>'
    moon      = '<path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"/>'
    up        = '<path d="m6 14 6-6 6 6"/>'
    user      = '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'
    folder    = '<path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'
    upload    = '<path d="M12 21V9"/><path d="m7 14 5-5 5 5"/><path d="M4 4h16"/>'
    chat      = '<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>'
    audit     = '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>'
}
function Get-Icon([string]$Name, [string]$Class = 'icon') {
    $path = $Icons[$Name]; if (-not $path) { $path = $Icons['info'] }
    "<svg class=""$Class"" viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.7"" stroke-linecap=""round"" stroke-linejoin=""round"" aria-hidden=""true"">$path</svg>"
}

# ---- Sanitizer ------------------------------------------------------------------------------------------------------
$AllowedTags = @{}
foreach ($n in 'p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code', 'em', 'strong', 'del', 'ins', 'b', 'i', 'u', 's',
    'sub', 'sup', 'kbd', 'mark', 'small', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'a', 'img', 'div', 'span', 'dl', 'dt', 'dd', 'input', 'svg', 'path') { $AllowedTags[$n] = $true }
$VoidTags = @{ br = $true; hr = $true; img = $true; input = $true; path = $true }
$AllowedAttributes = @{
    a = @('href', 'title'); img = @('src', 'alt', 'title'); h1 = @('id'); h2 = @('id'); h3 = @('id'); h4 = @('id'); h5 = @('id'); h6 = @('id')
    th = @('align'); td = @('align'); ol = @('start'); li = @('class'); p = @('class'); blockquote = @('class'); div = @('class'); span = @('class'); code = @('class'); pre = @('class'); table = @('class')
    input = @('type', 'disabled', 'checked', 'class'); svg = @('class', 'viewbox', 'version', 'width', 'height', 'aria-hidden'); path = @('d', 'fill-rule')
}

function Test-SafeUrl([string]$Value) {
    $v = [System.Net.WebUtility]::HtmlDecode($Value)
    $v = [regex]::Replace($v, '[\x00-\x20\x7F-\x9F]', '')
    if ($v.Length -eq 0 -or $v.Length -gt 2048) { return $false }
    if ($v.StartsWith('#', [StringComparison]::Ordinal)) { return $v -match '^#[\p{L}\p{N}_\-.:%]*$' }
    if ($v -match '^(?i:https?):') { return $v -match '^(?i:https?)://[^\s"''<>\\]+$' }
    if ($v -match '^(?i:mailto):') { return $v -match '^(?i:mailto):[^\s"''<>\\]+$' }
    if ($v.StartsWith('//', [StringComparison]::Ordinal) -or $v.Contains('\')) { return $false }
    $colon = $v.IndexOf(':'); $stop = $v.IndexOfAny([char[]]'/?#')
    if ($colon -ge 0 -and ($stop -lt 0 -or $colon -lt $stop)) { return $false }
    return $true
}

$script:ImageCount = 0
function Get-LocalImageSource([string]$Source) {
    # Returns the data URI of a local image that stays inside the image root and has a matching signature, otherwise $null.
    $rel = [System.Net.WebUtility]::HtmlDecode($Source)
    if ($rel -match '^[A-Za-z][A-Za-z0-9+.\-]*:' -or $rel.StartsWith('/') -or $rel.StartsWith('\') -or $rel.Contains('?') -or $rel.Contains('#')) { return $null }
    try { $rel = [Uri]::UnescapeDataString($rel) } catch { return $null }
    if ($rel.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { return $null }
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($ImageRoot, $rel))
    if (-not $full.StartsWith($ImageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $mime = switch ([IO.Path]::GetExtension($full).ToLowerInvariant()) { '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.gif' { 'image/gif' } '.webp' { 'image/webp' } default { $null } }
    if (-not $mime -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -gt $MaxImageBytes -or $item.Length -lt 12) { return $null }
    $bytes = [IO.File]::ReadAllBytes($full)
    $ok = switch ($mime) {
        'image/png' { $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47 }
        'image/jpeg' { $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 }
        'image/gif' { $bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 }
        'image/webp' { $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x45 }
    }
    if (-not $ok) { return $null }
    $script:ImageCount++
    return 'data:' + $mime + ';base64,' + [Convert]::ToBase64String($bytes)
}

function ConvertTo-SafeHtml([string]$Html) {
    $out = [Text.StringBuilder]::new()
    $stack = [Collections.Generic.List[string]]::new()
    $pos = 0
    $tokens = [regex]::Matches($Html, '(?s)<!--.*?-->|<(/?)([A-Za-z][A-Za-z0-9]*)((?:"[^"]*"|''[^'']*''|[^''">])*?)(/?)>')
    foreach ($t in $tokens) {
        if ($t.Index -gt $pos) { [void]$out.Append($Html.Substring($pos, $t.Index - $pos).Replace('<', '&lt;')) }
        $pos = $t.Index + $t.Length
        if ($t.Value.StartsWith('<!--', [StringComparison]::Ordinal)) {
            if ($t.Value -match '^<!-- icon: [\w-]{1,32} -->$') { [void]$out.Append($t.Value) }
            continue
        }
        $closing = $t.Groups[1].Value -eq '/'
        $name = $t.Groups[2].Value.ToLowerInvariant()
        if (-not $AllowedTags.ContainsKey($name)) { [void]$out.Append([System.Net.WebUtility]::HtmlEncode($t.Value)); continue }
        if ($closing) {
            $at = $stack.LastIndexOf($name)
            if ($at -lt 0) { continue }
            for ($k = $stack.Count - 1; $k -ge $at; $k--) { [void]$out.Append('</' + $stack[$k] + '>') }
            $stack.RemoveRange($at, $stack.Count - $at)
            continue
        }
        $allowed = if ($AllowedAttributes.ContainsKey($name)) { $AllowedAttributes[$name] } else { @() }
        $attrs = [Text.StringBuilder]::new()
        $isExternal = $false; $src = $null; $alt = ''; $title = ''
        foreach ($a in [regex]::Matches($t.Groups[3].Value, '([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s"''>]+)))?')) {
            $an = $a.Groups[1].Value.ToLowerInvariant()
            $av = if ($a.Groups[2].Success) { $a.Groups[2].Value } elseif ($a.Groups[3].Success) { $a.Groups[3].Value } elseif ($a.Groups[4].Success) { $a.Groups[4].Value } else { '' }
            if ($an -notin $allowed) { continue }
            $plain = [System.Net.WebUtility]::HtmlDecode($av)
            $keep = switch ($an) {
                'href' { Test-SafeUrl $av }
                'src' { $src = $av; $false }
                'alt' { $alt = $plain; $false }
                'title' { if ($name -eq 'img') { $title = $plain; $false } else { $true } }
                'id' { $plain -match '^[\p{L}\p{N}_\-.:]{1,120}$' }
                'class' { $plain -match '^[A-Za-z0-9_\- ]{1,100}$' }
                'align' { $plain -in 'left', 'right', 'center' }
                'start' { $plain -match '^\d{1,6}$' }
                'type' { $plain -eq 'checkbox' }
                'disabled' { $true }
                'checked' { $true }
                'viewbox' { $plain -match '^[0-9 .\-]{1,40}$' }
                'version' { $plain -match '^[0-9.]{1,8}$' }
                'width' { $plain -match '^\d{1,4}$' }
                'height' { $plain -match '^\d{1,4}$' }
                'aria-hidden' { $plain -eq 'true' }
                'd' { $plain -match '^[MmLlHhVvCcSsQqTtAaZz0-9 .,\-eE]{1,2000}$' }
                'fill-rule' { $plain -in 'evenodd', 'nonzero' }
                default { $false }
            }
            if (-not $keep) { continue }
            $outName = if ($an -eq 'viewbox') { 'viewBox' } else { $an }
            if ($an -in 'disabled', 'checked') { [void]$attrs.Append(' ' + $an + '="' + $an + '"') }
            else { [void]$attrs.Append(' ' + $outName + '="' + [System.Net.WebUtility]::HtmlEncode($plain) + '"') }
            if ($an -eq 'href' -and ([System.Net.WebUtility]::HtmlDecode($av) -match '^\s*(?i:https?:)')) { $isExternal = $true }
        }
        if ($name -eq 'input' -and $attrs.ToString() -notmatch 'type="checkbox"') { continue }
        if ($name -eq 'img') {
            $data = if ($src) { Get-LocalImageSource $src } else { $null }
            if ($data) { [void]$out.Append('<img loading="lazy" src="' + $data + '" alt="' + [System.Net.WebUtility]::HtmlEncode($alt) + '"' + $(if ($title) { ' title="' + [System.Net.WebUtility]::HtmlEncode($title) + '"' } else { '' }) + ' />') }
            else { [void]$out.Append('<span class="img-missing">[Image not available: ' + [System.Net.WebUtility]::HtmlEncode($alt) + ']</span>') }
            continue
        }
        if ($name -eq 'a' -and $isExternal) { [void]$attrs.Append(' target="_blank" rel="noopener noreferrer"') }
        if ($VoidTags.ContainsKey($name)) { [void]$out.Append('<' + $name + $attrs.ToString() + ' />') }
        else { [void]$out.Append('<' + $name + $attrs.ToString() + '>'); $stack.Add($name) }
    }
    if ($pos -lt $Html.Length) { [void]$out.Append($Html.Substring($pos).Replace('<', '&lt;')) }
    for ($k = $stack.Count - 1; $k -ge 0; $k--) { [void]$out.Append('</' + $stack[$k] + '>') }
    return $out.ToString()
}

function ConvertTo-DocumentationHtml([string]$Text) {
    $safe = (ConvertTo-SafeHtml (ConvertFrom-Markdown -InputObject $Text).Html).Replace("`r`n", "`n")
    # PowerShell 7.4 emits plain blockquotes; 7.6 adds native alert markup and decorative icons.
    $safe = [regex]::Replace($safe, '(?s)<p class="markdown-alert-title">(?:<svg\b[^>]*>.*?</svg>)?\s*(Note|Tip|Important|Warning|Caution)</p>',
        '<p class="markdown-alert-title">$1</p>')
    $out = [Text.StringBuilder]::new()
    $quotes = [Collections.Generic.Stack[bool]]::new()
    $position = 0
    foreach ($tag in [regex]::Matches($safe, '<blockquote(?:\s[^>]*)?>|</blockquote>')) {
        [void]$out.Append($safe.Substring($position, $tag.Index - $position))
        $position = $tag.Index + $tag.Length
        if ($tag.Value.StartsWith('<blockquote', [StringComparison]::Ordinal)) {
            $prefix = if ($tag.Value -ceq '<blockquote>') {
                [regex]::Match($safe.Substring($position), '(?i)^\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:[ \t]*\n|(?=</p>))')
            } else { [Text.RegularExpressions.Match]::Empty }
            $quotes.Push($prefix.Success)
            if ($prefix.Success) {
                $kind = $prefix.Groups[1].Value.ToLowerInvariant()
                $title = $kind.Substring(0, 1).ToUpperInvariant() + $kind.Substring(1)
                [void]$out.Append('<div class="markdown-alert markdown-alert-' + $kind + '">'+ "`n" + '<p class="markdown-alert-title">' + $title + '</p>' + "`n")
                $position += $prefix.Length
                if ($safe.Substring($position).StartsWith('</p>', [StringComparison]::Ordinal)) {
                    $position += 4
                    if ($position -lt $safe.Length -and $safe[$position] -eq "`n") { $position++ }
                } else {
                    [void]$out.Append('<p>')
                }
            } else {
                [void]$out.Append($tag.Value)
            }
        } else {
            if ($quotes.Count -eq 0) { throw 'The sanitized Markdown has an unmatched blockquote.' }
            [void]$out.Append($(if ($quotes.Pop()) { '</div>' } else { '</blockquote>' }))
        }
    }
    if ($quotes.Count -ne 0) { throw 'The sanitized Markdown has an unclosed blockquote.' }
    [void]$out.Append($safe.Substring($position))
    return $out.ToString()
}

function ConvertTo-Inline([string]$Text) {
    # Inline Markdown (code, bold, links) inside a custom block field, sanitized like the rest of the page.
    $h = (ConvertTo-DocumentationHtml $Text.Trim()).Trim()
    return ($h -replace '^<p>', '' -replace '</p>$', '')
}

# ---- Front matter ---------------------------------------------------------------------------------------------------
$markdown = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Source)).Replace("`r`n", "`n").Replace("`r", "`n")
$meta = @{ title = 'Guide'; subtitle = ''; version = ''; author = ''; updated = ''; badges = '' }
$front = [regex]::Match($markdown, '(?s)\A---\n(.*?)\n---\n')
if ($front.Success) {
    foreach ($line in $front.Groups[1].Value -split "`n") {
        if ($line -match '^\s*(\w+)\s*:\s*(.*)$') {
            $key = $Matches[1].ToLowerInvariant()
            if ($meta.ContainsKey($key)) { $meta[$key] = $Matches[2].Trim().Substring(0, [Math]::Min(200, $Matches[2].Trim().Length)) }
        }
    }
    $markdown = $markdown.Substring($front.Length)
}
$html = ConvertTo-DocumentationHtml $markdown

# ---- Custom blocks ------------------------------------------------------------------------------------------------------
$html = [regex]::Replace($html, '(?s)<pre><code class="language-(cards|steps|flow)">(.*?)</code></pre>', {
        param($m)
        $kind = $m.Groups[1].Value
        $lines = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value) -split "`n" | Where-Object { $_.Trim() }
        switch ($kind) {
            'cards' {
                $items = foreach ($l in $lines) {
                    $icon, $title, $text = $l.Split('|', 3).ForEach({ $_.Trim() })
                    "<div class=""card-item""><div class=""card-icon"">$(Get-Icon $icon)</div><div><div class=""card-title"">$(ConvertTo-Inline $title)</div><div class=""card-text"">$(ConvertTo-Inline $text)</div></div></div>"
                }
                "<div class=""cards"">$($items -join '')</div>"
            }
            'steps' {
                $n = 0
                $items = foreach ($l in $lines) {
                    $n++
                    $title, $text = $l.Split('|', 2).ForEach({ $_.Trim() })
                    "<li><span class=""step-num"">$n</span><div class=""step-body""><div class=""step-title"">$(ConvertTo-Inline $title)</div><div class=""step-text"">$(ConvertTo-Inline $text)</div></div></li>"
                }
                "<ol class=""steps"">$($items -join '')</ol>"
            }
            'flow' {
                $items = foreach ($l in $lines) {
                    $icon, $title, $sub = $l.Split('|', 3).ForEach({ $_.Trim() })
                    if ($icon -eq 'arrow') {
                        "<div class=""flow-arrow""><span class=""flow-label"">$(& $enc $title)</span><svg viewBox=""0 0 40 12"" aria-hidden=""true""><path d=""M0 6h36M31 1l6 5-6 5"" fill=""none"" stroke=""currentColor"" stroke-width=""1.6""/></svg><span class=""flow-sub"">$(& $enc $sub)</span></div>"
                    }
                    else {
                        "<div class=""flow-node""><div class=""flow-icon"">$(Get-Icon $icon)</div><div class=""flow-title"">$(& $enc $title)</div><div class=""flow-text"">$(& $enc $sub)</div></div>"
                    }
                }
                "<div class=""flow"">$($items -join '')</div>"
            }
        }
    })

# ---- Code blocks: label + copy button -------------------------------------------------------------------------------------
$languages = @{ powershell = 'PowerShell'; sql = 'SQL'; text = 'Text'; json = 'JSON'; csharp = 'C#'; xml = 'XML'; html = 'HTML'; '' = 'Code' }
$html = [regex]::Replace($html, '(?s)<pre><code(?: class="language-([\w-]+)")?>(.*?)</code></pre>', {
        param($m)
        $lang = $m.Groups[1].Value
        $label = if ($languages.ContainsKey($lang)) { $languages[$lang] } else { & $enc $lang }
        "<div class=""code""><div class=""code-head""><span>$label</span><button type=""button"" class=""copy"">$(Get-Icon 'copy' 'icon-sm')<span>Copy</span></button></div><pre><code>$($m.Groups[2].Value)</code></pre></div>"
    })

# ---- Tables, images, links, alerts ----------------------------------------------------------------------------------------
$html = $html.Replace('<table>', '<div class="table-wrap"><table>').Replace('</table>', '</table></div>')
$html = [regex]::Replace($html, '<p><img loading="lazy" src="([^"]+)" alt="([^"]*)"(?: title="[^"]*")? /></p>', {
        param($m)
        "<figure><img loading=""lazy"" src=""$($m.Groups[1].Value)"" alt=""$($m.Groups[2].Value)"" title=""Click to enlarge""><figcaption>$($m.Groups[2].Value)</figcaption></figure>"
    })
# A link to another guide points to its HTML file; GitHub anchors keep the chapter number, the ids of this page do not.
$html = [regex]::Replace($html, '<a href="([\w.-]+)\.md(?:#([^"]*))?"', {
        param($m)
        $anchor = ($m.Groups[2].Value -replace '^\d+-', '' -replace '-{2,}', '-')
        '<a href="' + $m.Groups[1].Value + '.html' + $(if ($anchor) { '#' + $anchor } else { '' }) + '"'
    })

# In-page links use the GitHub anchor (#2-before-you-start, #annex-a--glossary); the ids of this page drop the chapter number and collapse dashes.
$html = [regex]::Replace($html, '<a href="#(\d+-)?([^"]*)"', {
        param($m)
        '<a href="#' + ($m.Groups[2].Value -replace '-{2,}', '-') + '"'
    })

# ---- Parts and chapters -----------------------------------------------------------------------------------------------------
$pattern = '(?s)(?:<!-- icon: (?<icon>[\w-]+) -->\s*)?<h(?<lvl>[12]) id="(?<id>[^"]*)">(?<text>.*?)</h\k<lvl>>'
$headings = [regex]::Matches($html, $pattern)
$hero = ''; $body = [Text.StringBuilder]::new(); $nav = [Text.StringBuilder]::new()
$sectionOpen = $false
$sectionCount = 0
$separator = [string][char]0x00B7
$emDash = [string][char]0x2014
function New-Hero([string]$Lead, [string]$Content) {
    $badgeList = [Collections.Generic.List[string]]::new()
    if ($meta.version) { $badgeList.Add("<span class=""badge badge-accent"">Version $(& $enc $meta.version)</span>") }
    if ($meta.updated) { $badgeList.Add("<span class=""badge"">$(Get-Icon 'calendar' 'icon-sm')Updated $(& $enc $meta.updated)</span>") }
    if ($meta.author) { $badgeList.Add("<span class=""badge"">$(Get-Icon 'user' 'icon-sm')$(& $enc $meta.author)</span>") }
    $badgeList.Add("<span class=""badge"">$(Get-Icon 'terminal' 'icon-sm')PowerShell 7.4+</span>")
    foreach ($b in ($meta.badges -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { $badgeList.Add("<span class=""badge"">$(& $enc $b)</span>") }
    "<header class=""hero"" id=""top""><div class=""hero-top""><div class=""hero-logo"">$(Get-Icon 'shield')</div><div><div class=""eyebrow"">$(& $enc $meta.subtitle)</div><h1>$(& $enc $meta.title)</h1></div>" +
    "<button type=""button"" id=""theme"" class=""ghost"" title=""Light / dark"" aria-label=""Switch between light and dark theme"">$(Get-Icon 'moon' 'icon-sm')</button></div>" +
    "<div class=""badges"">$($badgeList -join '')</div><p class=""lead"">$Lead</p>$Content</header>"
}
if ($headings.Count -eq 0 -or $headings[0].Groups['lvl'].Value -ne '1') { $hero = New-Hero '' '' }
for ($i = 0; $i -lt $headings.Count; $i++) {
    $m = $headings[$i]
    $end = if ($i + 1 -lt $headings.Count) { $headings[$i + 1].Index } else { $html.Length }
    $content = $html.Substring($m.Index + $m.Length, $end - $m.Index - $m.Length)
    $text = $m.Groups['text'].Value; $id = $m.Groups['id'].Value
    if ($i -eq 0 -and $m.Groups['lvl'].Value -eq '1') {
        $lead = ''
        $quote = [regex]::Match($content, '(?s)^\s*<blockquote>\s*<p>(.*?)</p>\s*</blockquote>')
        if ($quote.Success) { $lead = $quote.Groups[1].Value; $content = $content.Substring($quote.Length) }
        $hero = New-Hero $lead $content
        continue
    }
    if ($sectionOpen) { [void]$body.Append('</div></section>'); $sectionOpen = $false }
    if ($m.Groups['lvl'].Value -eq '1') {
        $label, $name = ($text -split (' ' + $separator + ' '), 2)
        $partName = if ($name) { '<span class="part-name">' + $name + '</span>' } else { '' }
        $navName = if ($name) { ' <span>' + $name + '</span>' } else { '' }
        [void]$body.Append("<div class=""part"" id=""$id""><span class=""part-label"">$label</span>$partName</div>")
        [void]$nav.Append("<div class=""nav-part"">$label$navName</div>")
        [void]$body.Append($content)
        continue
    }
    $icon = if ($m.Groups['icon'].Success) { $m.Groups['icon'].Value } else { 'play' }
    $badge = ''; $eyebrow = ''; $title = $text
    $numbered = [regex]::Match($text, '^(\d+)\.\s+(.*)$')
    $annex = [regex]::Match($text, '^Annex ([A-Z]) ' + $emDash + ' (.*)$')
    if ($numbered.Success) { $badge = $numbered.Groups[1].Value; $title = $numbered.Groups[2].Value }
    elseif ($annex.Success) { $badge = $annex.Groups[1].Value; $title = $annex.Groups[2].Value; $eyebrow = "Annex $badge" }
    $eyebrowHtml = if ($eyebrow) { "<div class=""section-eyebrow"">$eyebrow</div>" } elseif ($badge) { "<div class=""section-eyebrow"">Chapter $badge</div>" } else { "<div class=""section-eyebrow"">Start here</div>" }
    [void]$body.Append("<section class=""section"" id=""$id""><div class=""section-head""><div class=""section-icon"">$(Get-Icon $icon)</div><div>$eyebrowHtml<h2>$title</h2></div></div><div class=""section-body"">")
    [void]$body.Append($content)
    $sectionOpen = $true; $sectionCount++
    $navBadge = if ($badge) { $badge } else { Get-Icon 'play' 'icon-xs' }
    [void]$nav.Append("<a href=""#$id"" data-target=""$id""><span class=""nav-badge"">$navBadge</span><span class=""nav-text"">$title</span></a>")
}
if ($sectionOpen) { [void]$body.Append('</div></section>') }
if ($headings.Count -gt 0 -and $headings[0].Groups['lvl'].Value -ne '1') { [void]$body.Insert(0, $html.Substring(0, $headings[0].Index)) }
if ($headings.Count -eq 0) { [void]$body.Append($html) }

# ---- Page -----------------------------------------------------------------------------------------------------------------
$disclaimerHtml = '<section class="disclaimer" id="disclaimer" aria-labelledby="disclaimer-title"><h2 id="disclaimer-title">Disclaimer</h2><p>' + ((& $enc $Disclaimer) -replace "`n`n", '</p><p>' -replace "`n", '<br />') + '</p></section>'
$footerLine = "$(& $enc $meta.title) $(& $enc $meta.version) $separator $(& $enc $meta.author) $separator $(& $enc $meta.updated) $separator generated from $(& $enc (Split-Path $Source -Leaf))"
$page = @"
<!doctype html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>$(& $enc $meta.title) - $(& $enc $meta.subtitle)</title>
<script>
  (() => {
    const param = new URLSearchParams(window.location.search).get("theme");
    const theme = param === "dark" || param === "light" ? param : (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>
<style>
:root {
  color-scheme: light;
  --cp-bg: #f7f4ef; --cp-bg-elevated: #fcfbf8; --cp-surface: #ffffff; --cp-surface-soft: #f5f5f5;
  --cp-border: #dedede; --cp-border-strong: #919191; --cp-text: #242424; --cp-text-muted: #5c5c5c; --cp-text-soft: #6f6f6f;
  --cp-accent: #b11f4b; --cp-accent-hover: #9a1a41; --cp-accent-soft: rgba(177, 31, 75, 0.08); --cp-accent-fg: #ffffff;
  --cp-success: #16a34a; --cp-danger: #dc2626; --cp-warning: #b45309; --cp-link: #0067b8;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12); --cp-highlight: rgba(177, 31, 75, 0.12);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --cp-bg: #3d3b3a; --cp-bg-elevated: #343231; --cp-surface: #292929; --cp-surface-soft: #2e2e2e;
  --cp-border: #474747; --cp-border-strong: #5f5f5f; --cp-text: #dedede; --cp-text-muted: #b0b0b0; --cp-text-soft: #b0b0b0;
  --cp-accent: #fd8ea1; --cp-accent-hover: #fb7b91; --cp-accent-soft: rgba(253, 142, 161, 0.14); --cp-accent-fg: #1a1a1a;
  --cp-success: #4ade80; --cp-danger: #f87171; --cp-warning: #fbbf24; --cp-link: #4da6ff;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32); --cp-highlight: rgba(253, 142, 161, 0.12);
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 24px; }
body { margin: 0; background: var(--cp-bg); color: var(--cp-text); font: 15.5px/1.7 "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif; display: grid; grid-template-columns: 300px minmax(0, 1fr); }
a { color: var(--cp-link); text-decoration: none; } a:hover { text-decoration: underline; }
.icon { width: 22px; height: 22px; } .icon-sm { width: 16px; height: 16px; flex-shrink: 0; } .icon-xs { width: 12px; height: 12px; }
button { font: inherit; color: var(--cp-text); background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 0.625rem; cursor: pointer; }
button:hover { border-color: var(--cp-accent); color: var(--cp-accent); }
:focus-visible { outline: 2px solid var(--cp-accent); outline-offset: 2px; }
.skip { position: absolute; left: -999px; top: 8px; background: var(--cp-surface); padding: 8px 12px; border-radius: 8px; z-index: 5; } .skip:focus { left: 8px; }
aside { position: sticky; top: 0; height: 100vh; overflow-y: auto; background: var(--cp-bg-elevated); border-right: 1px solid var(--cp-border); padding: 24px 16px 32px; }
.brand { display: flex; gap: 12px; align-items: center; padding: 4px 8px 20px; border-bottom: 1px solid var(--cp-border); margin-bottom: 12px; }
.brand-logo { width: 40px; height: 40px; border-radius: 12px; display: grid; place-items: center; background: var(--cp-accent); color: var(--cp-accent-fg); }
.brand-name { font-weight: 700; font-size: 15px; line-height: 1.2; } .brand-sub { font-size: 12px; color: var(--cp-text-muted); }
.nav-part { margin: 20px 8px 6px; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--cp-accent); }
.nav-part span { color: var(--cp-text-muted); font-weight: 600; letter-spacing: 0.04em; }
aside a { display: flex; align-items: center; gap: 10px; padding: 6px 8px; margin: 1px 0; border-radius: 0.625rem; color: var(--cp-text); font-size: 13.5px; line-height: 1.35; border-left: 3px solid transparent; }
aside a:hover { background: var(--cp-accent-soft); text-decoration: none; }
aside a.active { background: var(--cp-accent-soft); border-left-color: var(--cp-accent); font-weight: 600; }
.nav-badge { flex-shrink: 0; width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-size: 11.5px; font-weight: 700; background: var(--cp-surface-soft); color: var(--cp-text-muted); border: 1px solid var(--cp-border); }
aside a.active .nav-badge { background: var(--cp-accent); color: var(--cp-accent-fg); border-color: var(--cp-accent); }
main { padding: 40px 56px 80px; max-width: 1080px; width: 100%; }
.hero { position: relative; overflow: hidden; border: 1px solid var(--cp-border); border-top: 4px solid var(--cp-accent); border-radius: 16px; padding: 36px 40px 32px; margin-bottom: 40px; background: linear-gradient(125deg, var(--cp-surface) 40%, var(--cp-accent-soft)); }
.hero::before { content: ""; position: absolute; width: 320px; height: 320px; right: -110px; top: -170px; border: 44px solid var(--cp-highlight); border-radius: 50%; pointer-events: none; }
.hero-top { position: relative; display: flex; align-items: center; gap: 18px; }
.hero-logo { width: 60px; height: 60px; border-radius: 16px; display: grid; place-items: center; background: var(--cp-accent); color: var(--cp-accent-fg); flex-shrink: 0; }
.hero-logo .icon { width: 32px; height: 32px; }
.eyebrow, .section-eyebrow { font-size: 11.5px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--cp-accent); }
.hero h1 { font-size: 38px; font-weight: 700; letter-spacing: -0.025em; line-height: 1.1; margin: 4px 0 0; }
#theme { margin-left: auto; padding: 8px 10px; display: grid; place-items: center; }
.badges { position: relative; display: flex; flex-wrap: wrap; gap: 8px; margin: 22px 0 18px; }
.badge { display: inline-flex; align-items: center; gap: 6px; padding: 4px 12px; border-radius: 999px; font-size: 12.5px; background: var(--cp-surface); border: 1px solid var(--cp-border); color: var(--cp-text-muted); }
.badge-accent { background: var(--cp-accent); color: var(--cp-accent-fg); border-color: var(--cp-accent); font-weight: 600; }
.lead { position: relative; font-size: 17.5px; line-height: 1.6; max-width: 760px; margin: 0 0 24px; }
.part { display: flex; align-items: baseline; gap: 14px; margin: 56px 0 20px; padding-bottom: 10px; border-bottom: 2px solid var(--cp-accent); }
.part-label { font-size: 13px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--cp-accent); }
.part-name { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; }
.section, .disclaimer { background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; padding: 32px 40px 28px; margin: 0 0 28px; box-shadow: 0 0 2px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.14); }
.disclaimer h2 { font-size: 20px; margin: 0 0 8px; }
.section-head { display: flex; align-items: center; gap: 16px; padding-bottom: 18px; margin-bottom: 8px; border-bottom: 1px solid var(--cp-border); }
.section-icon { width: 48px; height: 48px; border-radius: 14px; display: grid; place-items: center; background: var(--cp-accent-soft); color: var(--cp-accent); flex-shrink: 0; }
.section-icon .icon { width: 26px; height: 26px; }
.section h2 { font-size: 25px; font-weight: 700; letter-spacing: -0.02em; margin: 2px 0 0; line-height: 1.2; }
.section-body > :first-child { margin-top: 16px; }
h3 { font-size: 17.5px; font-weight: 650; margin: 36px 0 12px; padding-left: 12px; border-left: 3px solid var(--cp-accent); line-height: 1.3; }
p { margin: 12px 0; } ul, ol { padding-left: 22px; } li { margin: 6px 0; } li::marker { color: var(--cp-accent); }
strong { font-weight: 650; }
code { font-family: Consolas, "Courier New", Courier, monospace; font-size: 0.88em; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); padding: 1px 6px; border-radius: 6px; }
kbd { font-family: Consolas, monospace; font-size: 0.85em; padding: 1px 7px; border: 1px solid var(--cp-border-strong); border-bottom-width: 2px; border-radius: 6px; background: var(--cp-surface-soft); }
hr { border: 0; border-top: 1px solid var(--cp-border); margin: 28px 0; }
.img-missing { color: var(--cp-text-muted); font-style: italic; }
.table-wrap { overflow-x: auto; margin: 16px 0 20px; border: 1px solid var(--cp-border); border-radius: 12px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; line-height: 1.55; }
th { text-align: left; font-weight: 650; font-size: 12.5px; letter-spacing: 0.02em; color: var(--cp-text-muted); background: var(--cp-surface-soft); padding: 11px 16px; border-bottom: 1px solid var(--cp-border); }
td { padding: 11px 16px; border-bottom: 1px solid var(--cp-border); vertical-align: top; }
td:first-child { font-weight: 600; } tr:last-child td { border-bottom: 0; } tbody tr:hover td { background: var(--cp-accent-soft); } td code { white-space: nowrap; }
.code { margin: 16px 0 20px; border: 1px solid var(--cp-border); border-radius: 12px; overflow: hidden; background: var(--cp-surface-soft); }
.code-head { display: flex; justify-content: space-between; align-items: center; padding: 6px 8px 6px 16px; border-bottom: 1px solid var(--cp-border); font-size: 12px; font-weight: 600; color: var(--cp-text-muted); letter-spacing: 0.04em; text-transform: uppercase; }
.copy { display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; font-size: 12px; text-transform: none; letter-spacing: 0; }
.copy.done { color: var(--cp-success); border-color: var(--cp-success); }
.code pre { margin: 0; padding: 16px 18px; overflow-x: auto; font-size: 13.5px; line-height: 1.6; }
.code pre code { background: none; border: 0; padding: 0; font-size: inherit; }
.markdown-alert { --tone: var(--cp-link); margin: 18px 0; padding: 14px 18px; border: 1px solid color-mix(in srgb, var(--tone) 35%, var(--cp-border)); border-left: 4px solid var(--tone); border-radius: 12px; background: color-mix(in srgb, var(--tone) 7%, var(--cp-surface)); }
.markdown-alert p { margin: 6px 0; }
.markdown-alert-title { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 13px; letter-spacing: 0.04em; text-transform: uppercase; color: var(--tone); margin: 0 0 4px !important; }
.markdown-alert-title svg { width: 16px; height: 16px; fill: currentColor; }
.markdown-alert-tip { --tone: var(--cp-success); } .markdown-alert-important { --tone: var(--cp-accent); }
.markdown-alert-warning { --tone: var(--cp-warning); } .markdown-alert-caution { --tone: var(--cp-danger); }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; margin: 18px 0 22px; position: relative; }
.card-item { display: flex; gap: 14px; padding: 16px 18px; border: 1px solid var(--cp-border); border-radius: 14px; background: var(--cp-surface); }
.card-item:hover { border-color: var(--cp-accent); }
.card-icon { width: 38px; height: 38px; border-radius: 11px; display: grid; place-items: center; background: var(--cp-accent-soft); color: var(--cp-accent); flex-shrink: 0; }
.card-title { font-weight: 700; font-size: 14.5px; line-height: 1.3; margin: 2px 0 4px; }
.card-text { font-size: 13.5px; line-height: 1.5; color: var(--cp-text-muted); }
.steps { list-style: none; padding: 0; margin: 18px 0 22px; position: relative; }
.steps li { position: relative; display: flex; gap: 16px; margin: 0; padding: 0 0 18px; }
.steps li:not(:last-child)::before { content: ""; position: absolute; left: 16px; top: 36px; bottom: 2px; width: 2px; background: var(--cp-border); }
.step-num { flex-shrink: 0; width: 34px; height: 34px; border-radius: 50%; display: grid; place-items: center; font-weight: 700; font-size: 14px; background: var(--cp-accent); color: var(--cp-accent-fg); box-shadow: 0 0 0 4px var(--cp-accent-soft); }
.step-body { padding-top: 5px; } .step-title { font-weight: 700; font-size: 15px; line-height: 1.35; }
.step-text { color: var(--cp-text-muted); font-size: 14.5px; margin-top: 2px; }
.flow { display: flex; align-items: stretch; flex-wrap: wrap; gap: 6px; margin: 20px 0 24px; padding: 20px; border-radius: 14px; background: var(--cp-surface-soft); border: 1px dashed var(--cp-border-strong); }
.flow-node { flex: 1 1 130px; min-width: 120px; text-align: center; padding: 16px 12px; border-radius: 12px; background: var(--cp-surface); border: 1px solid var(--cp-border); }
.flow-icon { width: 42px; height: 42px; margin: 0 auto 8px; border-radius: 12px; display: grid; place-items: center; background: var(--cp-accent-soft); color: var(--cp-accent); }
.flow-title { font-weight: 700; font-size: 14px; line-height: 1.3; } .flow-text { font-size: 12.5px; color: var(--cp-text-muted); line-height: 1.4; margin-top: 4px; }
.flow-arrow { flex: 0 0 auto; min-width: 70px; display: flex; flex-direction: column; align-items: center; justify-content: center; color: var(--cp-border-strong); padding: 0 2px; }
.flow-arrow svg { width: 44px; height: 14px; color: var(--cp-accent); }
.flow-label { font-size: 12px; font-weight: 700; color: var(--cp-accent); } .flow-sub { font-size: 11px; color: var(--cp-text-muted); text-align: center; max-width: 110px; line-height: 1.3; }
figure { margin: 18px 0 24px; }
figure img { display: block; max-width: 100%; border: 1px solid var(--cp-border); border-radius: 12px; cursor: zoom-in; }
figcaption { font-size: 13px; color: var(--cp-text-muted); margin-top: 8px; text-align: center; }
dialog#zoom { border: 0; padding: 0; background: transparent; max-width: 96vw; max-height: 96vh; }
dialog#zoom::backdrop { background: rgba(0, 0, 0, 0.7); }
dialog#zoom img { max-width: 96vw; max-height: 94vh; border-radius: 12px; cursor: zoom-out; display: block; }
#to-top { position: fixed; right: 24px; bottom: 24px; width: 44px; height: 44px; border-radius: 50%; display: grid; place-items: center; background: var(--cp-accent); color: var(--cp-accent-fg); border: 0; box-shadow: var(--cp-shadow); opacity: 0; pointer-events: none; transition: opacity 200ms; }
#to-top.visible { opacity: 1; pointer-events: auto; } #to-top:hover { background: var(--cp-accent-hover); color: var(--cp-accent-fg); }
footer { margin-top: 48px; padding-top: 20px; border-top: 1px solid var(--cp-border); font-size: 12.5px; color: var(--cp-text-muted); text-align: center; }
@media (max-width: 1000px) {
  body { display: block; }
  aside { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--cp-border); }
  main { padding: 24px 16px 60px; } .section, .disclaimer { padding: 24px 20px; } .hero { padding: 28px 22px; }
}
@media (forced-colors: active) {
  .hero, .section, .disclaimer, .code, .markdown-alert, .card-item, .flow-node { border: 1px solid CanvasText; }
  .badge-accent, .nav-badge, .step-num { border: 1px solid ButtonText; forced-color-adjust: none; background: ButtonFace; color: ButtonText; }
  aside a.active { outline: 2px solid Highlight; }
}
@media print {
  body { display: block; background: #fff; } aside, #to-top, #theme, .copy { display: none !important; }
  main { padding: 0; max-width: none; } .section { break-inside: avoid-page; box-shadow: none; } .part { break-before: page; }
}
</style></head><body>
<a class="skip" href="#content">Skip to the content</a>
<aside><div class="brand"><div class="brand-logo">$(Get-Icon 'shield')</div><div><div class="brand-name">$(& $enc $meta.title)</div><div class="brand-sub">$(& $enc $meta.subtitle) $separator v$(& $enc $meta.version)</div></div></div>
<nav aria-label="Contents">$($nav.ToString())</nav></aside>
<main id="content">$hero$($body.ToString())
$disclaimerHtml
<footer>$footerLine</footer></main>
<button type="button" id="to-top" title="Back to top" aria-label="Back to top">$(Get-Icon 'up' 'icon-sm')</button>
<dialog id="zoom"><img alt=""></dialog>
<script>
(() => {
  "use strict";
  document.getElementById("theme").addEventListener("click", () => {
    const root = document.documentElement;
    root.setAttribute("data-theme", root.getAttribute("data-theme") === "dark" ? "light" : "dark");
  });
  const links = new Map(Array.from(document.querySelectorAll("aside a[data-target]")).map(a => [a.dataset.target, a]));
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(entries => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        links.forEach(a => a.classList.remove("active"));
        const link = links.get(e.target.id);
        if (link) { link.classList.add("active"); link.scrollIntoView({ block: "nearest" }); }
      }
    }, { rootMargin: "-20% 0px -70% 0px" });
    document.querySelectorAll("section.section").forEach(s => observer.observe(s));
  }
  document.querySelectorAll(".code .copy").forEach(button => button.addEventListener("click", async () => {
    const text = button.closest(".code").querySelector("pre").innerText;
    try { await navigator.clipboard.writeText(text); }
    catch { const r = document.createRange(); r.selectNodeContents(button.closest(".code").querySelector("pre")); const s = getSelection(); s.removeAllRanges(); s.addRange(r); document.execCommand("copy"); s.removeAllRanges(); }
    const label = button.querySelector("span"); label.textContent = "Copied"; button.classList.add("done");
    setTimeout(() => { label.textContent = "Copy"; button.classList.remove("done"); }, 1600);
  }));
  const zoom = document.getElementById("zoom");
  document.querySelectorAll("figure img").forEach(img => img.addEventListener("click", () => { zoom.querySelector("img").src = img.src; zoom.showModal(); }));
  zoom.addEventListener("click", () => zoom.close());
  const top = document.getElementById("to-top");
  addEventListener("scroll", () => top.classList.toggle("visible", scrollY > 600), { passive: true });
  top.addEventListener("click", () => scrollTo({ top: 0 }));
})();
</script>
</body></html>
"@
$page = $page.Replace("`r`n", "`n")
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($page)
$temporary = $Destination + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
try {
    [IO.File]::WriteAllBytes($temporary, $bytes)
    [IO.File]::Move($temporary, $Destination, [bool]$Force)
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
[pscustomobject]@{
    Source      = $Source
    Destination = $Destination
    Bytes       = $bytes.Length
    Sha256      = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    Sections    = $sectionCount
    Images      = $script:ImageCount
}
