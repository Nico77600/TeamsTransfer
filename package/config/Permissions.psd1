@{
    # Teams Transfer - the application permissions (Microsoft Graph, application role, admin consent) that each mode needs.
    # Data only: parsed with Import-PowerShellDataFile, never executed. ONE table for the console (permission lights), for the guide and for
    # tools\Grant-LabConsent.ps1. A permission is satisfied by a broader one: X.ReadWrite.All covers X.Read.All, X.Read.All covers X.ReadBasic.All.
    # Side: Source = the tenant that is read; Target = the tenant that is read and written. Required = the mode fails without it;
    # Optional = only for an option of the mode (named in Reason).
    Version = 1
    Modes   = @{
        Assess = @{
            Side = 'Source'
            Required = @(
                @{ Name = 'User.Read.All'; Reason = 'Counts and samples the users.' }
                @{ Name = 'Chat.Read.All'; Reason = 'Samples the chats and their messages (protected API).' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Samples the teams (with -SampleTeams).' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Samples the channels (with -SampleTeams).' }
            )
            Optional = @(
                @{ Name = 'ChannelMessage.Read.All'; Reason = 'Counts channel messages (with -SampleTeams).' }
            )
        }
        Inventory = @{
            Side = 'Source'
            Required = @(
                @{ Name = 'User.Read.All'; Reason = 'Lists the users, including deleted ones and guests.' }
                @{ Name = 'Chat.ReadBasic.All'; Reason = 'Lists the chats of every user (Chat.Read.All also satisfies it).' }
                @{ Name = 'ChatMember.Read.All'; Reason = 'Reads the members of the chats.' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Lists the teams.' }
                @{ Name = 'TeamMember.Read.All'; Reason = 'Reads the members of the teams.' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Lists the channels of the teams.' }
                @{ Name = 'ChannelMember.Read.All'; Reason = 'Reads the members of the private and shared channels.' }
            )
            Optional = @()
        }
        Export = @{
            Side = 'Source'
            Required = @(
                @{ Name = 'User.Read.All'; Reason = 'Resolves the authors.' }
                @{ Name = 'Chat.Read.All'; Reason = 'Reads the chat messages (getAllMessages, protected API).' }
                @{ Name = 'ChatMember.Read.All'; Reason = 'Reads the members of the chats.' }
                @{ Name = 'ChannelMessage.Read.All'; Reason = 'Reads the channel messages and replies (protected API).' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Lists the teams of the scope.' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Lists the channels of the scope.' }
                @{ Name = 'ChannelMember.Read.All'; Reason = 'Reads the members of the channels.' }
            )
            Optional = @(
                @{ Name = 'Files.Read.All'; Reason = 'Downloads the files (with -IncludeFiles).' }
                @{ Name = 'Sites.Read.All'; Reason = 'Reads the channel file libraries (with -IncludeFiles).' }
            )
        }
        Files = @{
            Side = 'Source'
            Required = @(
                @{ Name = 'Files.Read.All'; Reason = 'Downloads the files that the messages refer to.' }
                @{ Name = 'Sites.Read.All'; Reason = 'Reads the SharePoint libraries of the channels.' }
            )
            Optional = @()
        }
        Plan = @{
            Side = 'Target'
            Required = @(
                @{ Name = 'User.Read.All'; Reason = 'Looks the authors up in the target tenant (mapping).' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Looks the teams up.' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Looks the channels up.' }
                @{ Name = 'Chat.Read.All'; Reason = 'Looks the existing chats up (scenario B).' }
            )
            Optional = @()
        }
        Ghosts = @{
            Side = 'Target'
            Required = @(
                @{ Name = 'User.ReadWrite.All'; Reason = 'Creates and reads the ghost accounts.' }
                @{ Name = 'Group.Read.All'; Reason = 'Finds the ghost tracking group.' }
                @{ Name = 'GroupMember.ReadWrite.All'; Reason = 'Adds the ghost accounts to the tracking group.' }
            )
            Optional = @(
                @{ Name = 'Group.ReadWrite.All'; Reason = 'Creates the tracking group (with -CreateTrackingGroup).' }
                @{ Name = 'User.DeleteRestore.All'; Reason = 'Purges removed ghosts (with -Remove -Purge).' }
            )
        }
        CopyFiles = @{
            Side = 'Target'
            Required = @(
                @{ Name = 'Files.ReadWrite.All'; Reason = 'Uploads the files into OneDrive and the channel libraries, and shares them.' }
                @{ Name = 'Sites.ReadWrite.All'; Reason = 'Writes into the SharePoint libraries of the channels.' }
            )
            Optional = @()
        }
        Import = @{
            Side = 'Target'
            Required = @(
                @{ Name = 'Teamwork.Migrate.All'; Reason = 'Starts, fills and completes the migration of chats and channels.' }
                @{ Name = 'Team.Create'; Reason = 'Creates the teams.' }
                @{ Name = 'Channel.Create'; Reason = 'Creates the channels.' }
                @{ Name = 'Chat.Create'; Reason = 'Creates the chats.' }
                @{ Name = 'Chat.ReadWrite.All'; Reason = 'Reads back the chats and their migration state.' }
                @{ Name = 'ChatMember.ReadWrite.All'; Reason = 'Adds the members of the chats.' }
                @{ Name = 'ChannelMember.ReadWrite.All'; Reason = 'Adds the members of the channels.' }
                @{ Name = 'TeamMember.ReadWrite.All'; Reason = 'Adds the members of the teams.' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Reads back the teams.' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Reads back the migration state of the channels.' }
            )
            Optional = @()
        }
        Verify = @{
            Side = 'Target'
            Required = @(
                @{ Name = 'User.Read.All'; Reason = 'Resolves the authors.' }
                @{ Name = 'Chat.Read.All'; Reason = 'Reads the imported chat messages and their migration state.' }
                @{ Name = 'ChannelMessage.Read.All'; Reason = 'Reads the imported channel messages.' }
                @{ Name = 'Team.ReadBasic.All'; Reason = 'Reads back the teams.' }
                @{ Name = 'Channel.ReadBasic.All'; Reason = 'Reads back the channels.' }
            )
            Optional = @()
        }
    }
}
