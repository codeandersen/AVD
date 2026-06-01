#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
<#
.SYNOPSIS
    Phase 4 – Create Azure Files storage account and configure FSLogix profile share.
.DESCRIPTION
    Creates the storage account, file share, enables AD authentication via the
    AzFilesHybrid module, sets share-level RBAC, and sets NTFS permissions.

    MUST be run from a domain-joined machine with:
      - Az PowerShell module installed
      - AzFilesHybrid module installed (https://github.com/Azure-Samples/azure-files-samples/releases)
      - Rights to create computer objects in the AVD OU
.NOTES
    Steps covered: 22–29 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 4: Azure Files + FSLogix Profile Storage ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

# Verify AzFilesHybrid is available
if (-not (Get-Module -ListAvailable -Name AzFilesHybrid)) {
    Write-Error @"
AzFilesHybrid module not found.
1. Download from: https://github.com/Azure-Samples/azure-files-samples/releases
2. Extract the zip
3. Run: .\CopyToPSPath.ps1
4. Re-run this script
"@
    exit 1
}

# Verify this machine is domain-joined
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
if ($domain -eq "WORKGROUP" -or [string]::IsNullOrEmpty($domain)) {
    Write-Error "This machine is not domain-joined (domain=$domain). Run this script from a domain-joined machine."
    exit 1
}
Write-Host "Running on domain-joined machine: $domain" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# Step 22 – Create Storage Account
# -----------------------------------------------------------------------------
Write-Host "`n[Step 22] Creating storage account '$StorageAccountName'..." -ForegroundColor Yellow

$storageAccount = Get-AzStorageAccount -ResourceGroupName $AzResourceGroup -Name $StorageAccountName -ErrorAction SilentlyContinue
if (-not $storageAccount) {
    $storageAccount = New-AzStorageAccount `
        -ResourceGroupName $AzResourceGroup `
        -Name              $StorageAccountName `
        -Location          $AzLocation `
        -SkuName           "Standard_LRS" `
        -Kind              "StorageV2" `
        -EnableLargeFileShare `
        -MinimumTlsVersion "TLS1_2" `
        -Tag               @{ Project = "AVD"; Environment = "Production" }
    Write-Host "  Created: $StorageAccountName" -ForegroundColor Green
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 23 – Create File Share
# -----------------------------------------------------------------------------
Write-Host "`n[Step 23] Creating file share '$FileShareName'..." -ForegroundColor Yellow

$ctx   = $storageAccount.Context
$share = Get-AzStorageShare -Name $FileShareName -Context $ctx -ErrorAction SilentlyContinue
if (-not $share) {
    New-AzStorageShare -Name $FileShareName -Context $ctx | Out-Null

    # Set quota in GB (convert from MB)
    $quotaGb = [math]::Ceiling($FslogixProfileSizeMB * 25 / 1024)  # 25 users × profile size, in GB
    $quotaGb = [math]::Max($quotaGb, 100)                           # Minimum 100 GB
    Set-AzStorageShareQuota -ShareName $FileShareName -Quota $quotaGb -Context $ctx | Out-Null
    Write-Host "  Created share '$FileShareName' with quota: $quotaGb GB" -ForegroundColor Green
} else {
    Write-Host "  Share already exists, skipping." -ForegroundColor Gray
}

# Derive UNC path
$uncPath = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
Write-Host "  UNC path: $uncPath" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# Steps 24-26 – Enable AD Authentication (AzFilesHybrid)
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 24-26] Enabling AD authentication on storage account..." -ForegroundColor Yellow

Import-Module AzFilesHybrid -Force

# Check if already domain-joined
$adAuth = (Get-AzStorageAccount -ResourceGroupName $AzResourceGroup -Name $StorageAccountName).AzureFilesIdentityBasedAuth
if ($adAuth.DirectoryServiceOptions -eq "AD") {
    Write-Host "  Storage account already AD-joined, skipping." -ForegroundColor Gray
} else {
    Join-AzStorageAccountForAuth `
        -ResourceGroupName                   $AzResourceGroup `
        -StorageAccountName                  $StorageAccountName `
        -DomainAccountType                   "ComputerAccount" `
        -OrganizationalUnitDistinguishedName $OuSessionHosts

    Write-Host "  Storage account joined to AD domain." -ForegroundColor Green

    # Verify the computer object was created in AD
    $storageAccountComputerObject = Get-ADComputer -Filter "Name -eq '$StorageAccountName'" -ErrorAction SilentlyContinue
    if ($storageAccountComputerObject) {
        Write-Host "  Verified: computer object found in AD: $($storageAccountComputerObject.DistinguishedName)" -ForegroundColor Green
    } else {
        Write-Warning "  Computer object not found in AD — verify the OU path and re-run if needed."
    }
}

# -----------------------------------------------------------------------------
# Step 27 – Set share-level RBAC
# -----------------------------------------------------------------------------
Write-Host "`n[Step 27] Assigning share-level RBAC to '$AdGroupAvdUsers'..." -ForegroundColor Yellow

$shareResourceId = "/subscriptions/$AzSubscriptionId/resourceGroups/$AzResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/fileshares/$FileShareName"

# Get the group object ID from Azure AD
$groupObjectId = (Get-AzADGroup -DisplayName $AdGroupAvdUsers).Id
if (-not $groupObjectId) {
    Write-Warning "  Group '$AdGroupAvdUsers' not found in Entra ID. Make sure Entra Connect has synced it."
    Write-Warning "  Run 'Start-ADSyncSyncCycle -PolicyType Delta' on the Entra Connect server and retry."
} else {
    $existingAssignment = Get-AzRoleAssignment `
        -ObjectId            $groupObjectId `
        -RoleDefinitionName  "Storage File Data SMB Share Contributor" `
        -Scope               $shareResourceId `
        -ErrorAction SilentlyContinue

    if (-not $existingAssignment) {
        New-AzRoleAssignment `
            -ObjectId           $groupObjectId `
            -RoleDefinitionName "Storage File Data SMB Share Contributor" `
            -Scope              $shareResourceId | Out-Null
        Write-Host "  RBAC assigned: '$AdGroupAvdUsers' -> 'Storage File Data SMB Share Contributor'" -ForegroundColor Green
    } else {
        Write-Host "  RBAC already assigned, skipping." -ForegroundColor Gray
    }
}

# -----------------------------------------------------------------------------
# Step 28 – Create Entity Subfolders + Set NTFS Permissions
# -----------------------------------------------------------------------------
# Folder layout:
#   fslogix-profiles\
#     contosogrp\  <- Contoso Group  (GRP-AVD-Users)
#     contosode\   <- Contoso Germany (GRP-ContosoDE-AVD-Users)
#
# Share root: read-only traverse for all entities (no profile data here)
# Each subfolder: CREATOR OWNER full control + entity AD group create folders
# FSLogix GPO for each host pool points to its own subfolder, not the root.
# -----------------------------------------------------------------------------
Write-Host "`n[Step 28] Creating entity folders and setting NTFS permissions..." -ForegroundColor Yellow

# Mount the share with the storage account key
$storageKey  = (Get-AzStorageAccountKey -ResourceGroupName $AzResourceGroup -Name $StorageAccountName)[0].Value
$driveLetter = "Z"
if (Test-Path "${driveLetter}:") { net use "${driveLetter}:" /delete /y | Out-Null }

$mountResult = net use "${driveLetter}:" $uncPath /user:"AZURE\$StorageAccountName" $storageKey 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  Could not mount share: $mountResult"
    Write-Warning "  Create entity folders and set NTFS permissions manually — see portal-guide.md Step 28."
} else {
    Write-Host "  Share mounted at ${driveLetter}:" -ForegroundColor Green

    # ------------------------------------------------------------------
    # Root share — minimal permissions (traverse only, no profile data)
    # ------------------------------------------------------------------
    $rootAcl = Get-Acl "${driveLetter}:"
    $rootAcl.SetAccessRuleProtection($true, $true)  # Break inheritance

    # Strip all non-system rules
    $rootAcl.Access | Where-Object {
        $_.IdentityReference -notmatch "NT AUTHORITY\\SYSTEM" -and
        $_.IdentityReference -notmatch "BUILTIN\\Administrators"
    } | ForEach-Object { $rootAcl.RemoveAccessRule($_) | Out-Null }

    # All entity groups get traverse on the root so they can reach their subfolder
    foreach ($entity in $FslogixEntities) {
        $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$AdDomainNetbios\$($entity.AdGroup)",
            "ReadAndExecute",
            "None", "NoPropagateInherit", "Allow"
        )
        $rootAcl.AddAccessRule($traverseRule)
        Write-Host "  Root traverse: $($entity.AdGroup)" -ForegroundColor Gray
    }
    Set-Acl "${driveLetter}:" $rootAcl

    # ------------------------------------------------------------------
    # Entity subfolders — one per entry in $FslogixEntities
    # ------------------------------------------------------------------
    foreach ($entity in $FslogixEntities) {
        $folderPath = "${driveLetter}:\$($entity.Folder)"

        # Create the folder if it doesn't exist
        if (-not (Test-Path $folderPath)) {
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            Write-Host "  Created folder: $($entity.Folder)" -ForegroundColor Green
        } else {
            Write-Host "  Folder exists:  $($entity.Folder)" -ForegroundColor Gray
        }

        $acl = Get-Acl $folderPath
        $acl.SetAccessRuleProtection($true, $false)  # Break inheritance, keep existing

        # Strip non-system inherited rules
        $acl.Access | Where-Object {
            $_.IdentityReference -notmatch "NT AUTHORITY\\SYSTEM" -and
            $_.IdentityReference -notmatch "BUILTIN\\Administrators" -and
            $_.IsInherited -eq $true
        } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

        # CREATOR OWNER — Full Control — subfolders and files only
        $creatorOwnerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "CREATOR OWNER", "FullControl",
            "ContainerInherit,ObjectInherit", "InheritOnly", "Allow"
        )
        $acl.AddAccessRule($creatorOwnerRule)

        # Entity AD group — traverse + list — this folder only
        $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$AdDomainNetbios\$($entity.AdGroup)",
            "ReadAndExecute",
            "None", "NoPropagateInherit", "Allow"
        )
        $acl.AddAccessRule($traverseRule)

        # Entity AD group — create subfolders — this folder only
        # (FSLogix creates one subfolder per user inside the entity folder)
        $createFolderRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$AdDomainNetbios\$($entity.AdGroup)",
            "AppendData",
            "None", "NoPropagateInherit", "Allow"
        )
        $acl.AddAccessRule($createFolderRule)

        Set-Acl $folderPath $acl
        Write-Host "  NTFS set on '$($entity.Folder)' for '$($entity.AdGroup)'" -ForegroundColor Green
    }

    net use "${driveLetter}:" /delete /y | Out-Null
    Write-Host "  Share unmounted." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Step 29 – Summary
# -----------------------------------------------------------------------------
$activeUncPath = "\\$StorageAccountName.file.core.windows.net\$FileShareName\$FslogixActiveEntity"

Write-Host "`n=== Phase 4 Summary ===" -ForegroundColor Cyan
Write-Host "Storage Account   : $StorageAccountName" -ForegroundColor White
Write-Host "File Share        : $FileShareName" -ForegroundColor White
Write-Host "Share root UNC    : $uncPath" -ForegroundColor White
Write-Host "Active entity     : $FslogixActiveEntity" -ForegroundColor White
Write-Host "FSLogix VHD path  : $activeUncPath" -ForegroundColor Green
Write-Host ""
Write-Host "Entity folders created:" -ForegroundColor White
foreach ($entity in $FslogixEntities) {
    Write-Host "  \\...\$FileShareName\$($entity.Folder)  ->  $($entity.AdGroup)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "The FSLogix GPO (07-fslogix-gpo.ps1) will set VHDLocations to:" -ForegroundColor Yellow
Write-Host "  $activeUncPath" -ForegroundColor Yellow
Write-Host "`nNext step: Run 05-create-gallery.ps1 from any machine." -ForegroundColor White
