# TeamsTransfer console - Demo mode (-Gui -Demo): a synthetic source tenant, a synthetic target tenant and a temporary store, all in memory
# and on the local disk, so every page works offline (screenshots, tests, client demonstrations).
# DEMO-ONLY. The C# demo sources (package\demo\*.cs: SyntheticTenant, FakeGraphTransport ...) are compiled together with the engine in Demo mode only;`n# the command line modes never load them.

function Get-TtgDemoSupportFiles {
    # The demo sources shipped in the package (package\demo\*.cs): a synthetic tenant and a fake Graph, compiled with the engine in Demo mode ONLY.
    param([Parameter(Mandatory)][string]$PackageRoot)
    $dir = Join-Path $PackageRoot 'demo'
    $files = @()
    if (Test-Path -LiteralPath $dir -PathType Container) { $files = @(Get-ChildItem -LiteralPath $dir -Filter *.cs -File | Sort-Object Name | ForEach-Object FullName) }
    if ($files.Count -eq 0) { throw "Demo mode needs the demo sources of the package (package\demo\*.cs): $dir is missing or empty." }
    return $files
}
function New-TtgDemoWorld {
    <#
    .SYNOPSIS
        The Demo world: the synthetic source tenant (Contoso) and a target tenant (Northwind) whose users carry the same local parts, plus a service account.
    .OUTPUTS
        Hashtable: Source, Target (FakeTenant), SourceDomain, TargetDomain, ServiceAccount, Roles (the permissions the demo apps "hold").
    #>
    $source = [TeamsTransfer.Testing.SyntheticTenant]::Demo()
    $target = [TeamsTransfer.Testing.FakeTenant]::new(99, 'northwind.com')
    foreach ($u in $source.Users) {
        if ($u.Deleted -or $u.External) { continue }
        $local = ($u.Upn -split '@')[0]
        [void]$target.AddUser("$local@northwind.com", $u.DisplayName)
    }
    [void]$target.AddUser('svc-migration@northwind.com', 'Migration service account')
    @{
        Source = $source; Target = $target; SourceDomain = 'contoso.com'; TargetDomain = 'northwind.com'; ServiceAccount = 'svc-migration@northwind.com'
        # What the demo apps hold: everything the demo needs (all lights green).
        Roles = @{
            Source = @('User.Read.All', 'Chat.Read.All', 'ChatMember.Read.All', 'ChannelMessage.Read.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'ChannelMember.Read.All', 'Files.Read.All', 'Sites.Read.All')
            Target = @('Teamwork.Migrate.All', 'Chat.Create', 'Chat.ReadWrite.All', 'ChatMember.ReadWrite.All', 'Channel.Create', 'ChannelMember.ReadWrite.All', 'Team.Create', 'TeamMember.ReadWrite.All', 'User.ReadWrite.All', 'Group.ReadWrite.All', 'ChannelMessage.Read.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'Files.ReadWrite.All', 'Sites.ReadWrite.All')
        }
    }
}

function Get-TtgDemoFormDefaults {
    # What the forms of the pages are pre-filled with in Demo mode (so a run needs no typing).
    @{
        Plan  = @{ DomainMap = 'contoso.com=northwind.com'; ServiceAccount = 'svc-migration@northwind.com'; GhostDomain = 'northwind.com' }
        Ghosts = @{ GhostDomain = 'northwind.com'; ServiceAccount = 'svc-migration@northwind.com'; CreateTrackingGroup = $true }
        CopyFiles = @{ ServiceAccount = 'svc-migration@northwind.com' }
        Import = @{ ServiceAccount = 'svc-migration@northwind.com' }
        Verify = @{ ServiceAccount = 'svc-migration@northwind.com' }
        Export = @{ IncludeChannels = $true; IncludeFiles = $true }
        Assess = @{ SampleUsers = 4 }
    }
}
