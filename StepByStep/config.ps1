# =============================================================================
# AVD Deployment – Shared Configuration
# Edit ALL values in this file before running any deployment script.
# PSScriptAnalyzer "unused variable" warnings here are false positives —
# all variables are consumed by the other scripts via dot-sourcing.
# =============================================================================
# PSScriptAnalyzer disable PSUseDeclaredVarsMoreThanAssignments

# -----------------------------------------------------------------------------
# Azure
# -----------------------------------------------------------------------------
$AzSubscriptionId      = "00000000-0000-0000-0000-000000000000"  # Your Azure subscription ID
$AzLocation            = "denmarkeast"                            # Azure region

# Two resource groups — infra holds AVD services, hosts holds the VMs
# This lets you wipe and redeploy session hosts without touching AVD config
$AzResourceGroup       = "rg-contoso-avd-avdresources"               # VNet, NSG, Storage, Gallery, Host Pool, Workspace, Monitoring
$AzResourceGroupHosts  = "rg-contoso-avd-hosts"                      # Session host VMs, NICs, OS disks

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
$VNetName              = "vnet-contoso-dke"
$VNetAddressPrefix     = "10.10.0.0/16"                          # Must NOT overlap on-prem
$SubnetName            = "snet-contoso-avd"
$SubnetPrefix          = "10.10.1.0/24"
$NsgName               = "nsg-contoso-avd"

# On-premises Domain Controller IPs (used as custom DNS on the VNet)
$OnPremDnsServers      = @("10.0.0.10", "10.0.0.11")             # Replace with actual DC IPs

# -----------------------------------------------------------------------------
# On-Premises Active Directory
# -----------------------------------------------------------------------------
$AdDomain              = "contoso.local"                         # On-prem AD domain FQDN
$AdDomainNetbios       = "CONTOSO"                               # NetBIOS name
$AdDomainDN            = "DC=contoso,DC=local"                   # Distinguished name of domain root

# OUs (will be created by 01-ad-prep.ps1)
$OuSessionHosts        = "OU=AVD,OU=Servers,$AdDomainDN"         # OU for AVD session host computers
$OuAvdUsers            = "OU=AVD-Users,OU=Users,$AdDomainDN"     # OU for AVD users (existing users can stay in their current OU)

# AD Group for AVD users
$AdGroupAvdUsers       = "GRP-AVD-Users"

# Domain join service account (created by 01-ad-prep.ps1)
$DomainJoinAccount     = "svc-avd-domainjoin"
$DomainJoinUPN         = "$DomainJoinAccount@$AdDomain"
# NOTE: Set the password as a SecureString at runtime — never hardcode it here
# $DomainJoinPassword  = Read-Host -AsSecureString "Domain join account password"

# -----------------------------------------------------------------------------
# Azure Files / FSLogix
# -----------------------------------------------------------------------------
$StorageAccountName    = "stacontosoprofiles"                       # Must be globally unique, lowercase, 3-24 chars
$FileShareName         = "fslogix-profiles"
$FslogixProfileSizeMB  = 30720                                   # 30 GB per user — adjust based on Citrix profile sizes

# Entity subfolders — one per company entity/country using this storage account.
# Each folder gets its own NTFS permissions scoped to the matching AD group.
# The FSLogix GPO for each host pool points to its own subfolder, not the share root.
# Add an entry here before deploying a new entity.
$FslogixEntities = @(
    @{ Folder = "contosogrp"; AdGroup = "GRP-AVD-Users"          },  # Contoso Group (this deployment)
    @{ Folder = "contosode";  AdGroup = "GRP-ContosoDE-AVD-Users" }   # Contoso Germany (create AD group when needed)
)
$FslogixActiveEntity   = "contosogrp"                              # Subfolder this host pool's GPO will point to

# -----------------------------------------------------------------------------
# Golden Image / Azure Compute Gallery
# -----------------------------------------------------------------------------
$GalleryName           = "acg_contoso_avd"                          # Azure Compute Gallery name (underscores allowed, no hyphens)
$ImageDefinitionName   = "Win11-MultiSession-M365"                 # Describes OS content — no company prefix needed
$ImageVersion          = "1.0.0"
$BuildVmName           = "contoso-build-vm"                         # Temporary VM used to build the image
$BuildVmSize           = "Standard_D4s_v5"

# Source gallery image (Microsoft provided)
$SourceImagePublisher  = "MicrosoftWindowsDesktop"
$SourceImageOffer      = "office-365"
$SourceImageSku        = "win11-24h2-avd-m365"                   # Windows 11 24H2 Multi-Session + M365 Apps

# -----------------------------------------------------------------------------
# Host Pool
# -----------------------------------------------------------------------------
$HostPoolName          = "hp-contosogrp"                            # grp = pooled/shared session host solution
$SessionHostPrefix     = "contosogrp-sh"                            # VMs will be named contosogrp-sh-0, contosogrp-sh-1
$SessionHostCount      = 2
$SessionHostSize       = "Standard_D4s_v5"                       # Resize to D8s_v5 if needed
$MaxSessionsPerHost    = 13                                       # 25 users / 2 hosts, rounded up

# -----------------------------------------------------------------------------
# Application Groups & Workspace
# -----------------------------------------------------------------------------
$WorkspaceName         = "ws-contosogrp"
$AppGroupRemoteApp     = "ag-contosogrp-apps"
$AppGroupDesktop       = "ag-contosogrp-desktop"

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------
$LogAnalyticsName      = "law-contoso-avd"
