@{
    # TeamsTransfer configuration. Data only: parsed with Import-PowerShellDataFile, never executed.
    # Never put a secret, a password or a private key here. Override locally in TeamsTransfer.config.local.psd1 (not committed).

    Source = @{
        Cloud      = 'Global'          # Global | USGov | USGovDoD | China
        TenantId   = ''                # GUID or contoso.onmicrosoft.com
        ClientId   = ''                # App registration (application id) used to READ the source
        CertificateThumbprint = ''     # Certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My (private key required)
    }

    Target = @{
        Cloud      = 'Global'
        TenantId   = ''                # Same as Source for scenarios B (restore) and C (archive)
        ClientId   = ''                # App registration with Teamwork.Migrate.All used to WRITE the target
        CertificateThumbprint = ''
        ServiceAccountUserId  = ''     # UPN or object id of the service account in the TARGET tenant: owner of the teams the import creates and fallback author
                                       # (deleted, federated, unmapped authors). Order used by Plan, Ghosts, CopyFiles, Import and Verify: -ServiceAccount,
                                       # then this value, then the account recorded by the plan, then the identity map. Empty = not set.
    }

    Graph = @{
        MaxAttempts           = 8      # per request, 429/5xx/network included
        BaseBackoffSeconds    = 2
        MaxBackoffSeconds     = 120
        RequestTimeoutSeconds = 300
        ExportModel           = 'B'    # model parameter of the Teams export APIs (getAllMessages); required, otherwise evaluation mode
        InitialRatePerSecond  = 20     # starting rate of the adaptive limiter, per endpoint class
        MaxConcurrency        = 32     # simultaneous requests for the whole process
    }

    # Ghost accounts of the deleted authors (-Mode Ghosts). The command line overrides these values.
    Ghosts = @{
        DomainName          = ''                                   # domain of the ghost UPNs (tt-ghost-<hash>@<domain>): a verified domain or contoso.onmicrosoft.com of the TARGET tenant
        DisplayNameFormat   = ''                                   # {0} = source display name; empty = '{0} (former)'
        TrackingGroupName   = 'TeamsTransfer - Ghost accounts'     # every ghost is a member of this group
        CreateTrackingGroup = $false                               # allow the tool to create the group when it does not exist
        UsageLocation       = ''                                   # two-letter country code set on the ghost (for example FR); empty = not set
        ConfirmThreshold    = 5000                                 # above this many ghosts to create the stage is blocked unless -ConfirmGhostCount
    }

    Store = @{
        Path       = ''                # Root of the local store; empty = <Output.Root>\store, that is <parent of the package>\out\store (refused inside the package folder and on a network share)
        Partitions = 256               # fixed when the store is created
    }

    Output = @{
        Root = '.\out'                 # logs\ (log of the day), reports\ (one folder per run), store\ (default store). A relative path is resolved against the
                                       # PARENT folder of the package (...\TeamsTransfer\out next to package\), never the current folder and never inside the package
    }

    Logging = @{
        RetentionDays = 14             # TeamsTransfer_*.log files older than this are deleted when a run starts
    }
}
