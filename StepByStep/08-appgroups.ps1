#Requires -Modules Az.Accounts, Az.DesktopVirtualization
<#
.SYNOPSIS
    Phase 8 – Create workspace, application groups, publish RemoteApps, assign users.
.DESCRIPTION
    Creates the AVD workspace, a RemoteApp application group with all required
    applications published, and assigns the AVD users group to the app groups.
.NOTES
    Steps covered: 57–63 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 8: Application Groups & Workspace ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.DesktopVirtualization

# Get the AVD users group object ID from Entra ID
$groupObjectId = (Get-AzADGroup -DisplayName $AdGroupAvdUsers -ErrorAction SilentlyContinue).Id
if (-not $groupObjectId) {
    Write-Warning "Group '$AdGroupAvdUsers' not found in Entra ID."
    Write-Warning "Make sure Entra Connect has synced the group, then re-run."
    Write-Warning "Force sync: Start-ADSyncSyncCycle -PolicyType Delta"
}

# Host pool resource ID
$hostPoolId = (Get-AzWvdHostPool -ResourceGroupName $AzResourceGroup -Name $HostPoolName).Id
if (-not $hostPoolId) {
    Write-Error "Host pool '$HostPoolName' not found. Run 06-deploy-hostpool.ps1 first."
}

# -----------------------------------------------------------------------------
# Step 57 – Rename auto-created Desktop application group
# -----------------------------------------------------------------------------
Write-Host "`n[Step 57] Checking for auto-created Desktop application group..." -ForegroundColor Yellow

$existingAppGroups = Get-AzWvdApplicationGroup -ResourceGroupName $AzResourceGroup -ErrorAction SilentlyContinue |
    Where-Object { $_.HostPoolArmPath -eq $hostPoolId }

$desktopGroup = $existingAppGroups | Where-Object { $_.ApplicationGroupType -eq "Desktop" }
if ($desktopGroup) {
    Write-Host "  Found auto-created Desktop app group: $($desktopGroup.Name)" -ForegroundColor Gray
    if ($desktopGroup.Name -ne $AppGroupDesktop) {
        Write-Host "  Note: Rename to '$AppGroupDesktop' is not supported via PowerShell — use the Portal." -ForegroundColor Yellow
        Write-Host "  AVD Portal > Application groups > $($desktopGroup.Name) > Properties > rename" -ForegroundColor Gray
    }
    $desktopGroupName = $desktopGroup.Name
} else {
    # Create the Desktop group if it doesn't exist
    Write-Host "  Creating Desktop application group '$AppGroupDesktop'..." -ForegroundColor Yellow
    New-AzWvdApplicationGroup `
        -ResourceGroupName    $AzResourceGroup `
        -Name                 $AppGroupDesktop `
        -Location             $AzLocation `
        -HostPoolArmPath      $hostPoolId `
        -ApplicationGroupType "Desktop" `
        -Description          "Full desktop access - restricted to admins or specific users" | Out-Null
    Write-Host "  Created: $AppGroupDesktop" -ForegroundColor Green
    $desktopGroupName = $AppGroupDesktop
}

# -----------------------------------------------------------------------------
# Steps 58-59 – Create RemoteApp application group and publish apps
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 58-59] Creating RemoteApp application group '$AppGroupRemoteApp'..." -ForegroundColor Yellow

$remoteAppGroup = Get-AzWvdApplicationGroup `
    -ResourceGroupName $AzResourceGroup `
    -Name              $AppGroupRemoteApp `
    -ErrorAction SilentlyContinue

if (-not $remoteAppGroup) {
    $remoteAppGroup = New-AzWvdApplicationGroup `
        -ResourceGroupName    $AzResourceGroup `
        -Name                 $AppGroupRemoteApp `
        -Location             $AzLocation `
        -HostPoolArmPath      $hostPoolId `
        -ApplicationGroupType "RemoteApp" `
        -Description          "Published RemoteApps for all AVD users"
    Write-Host "  Created RemoteApp group: $AppGroupRemoteApp" -ForegroundColor Green
} else {
    Write-Host "  '$AppGroupRemoteApp' already exists." -ForegroundColor Gray
}

# Define apps to publish
# Application source: "MsixPackage" or "File" — we use "File" for exe paths
# DisplayName, FilePath, CommandLineSetting
$appsToPublish = @(
    @{
        Name            = "BusinessCentral"
        DisplayName     = "Business Central"
        Description     = "Microsoft Dynamics 365 Business Central"
        FilePath        = "C:\Program Files\Microsoft Dynamics 365 Business Central\*\RoleTailored Client\Microsoft.Dynamics.Nav.Client.exe"
        CommandLineArgs = ""
        IconIndex       = 0
    },
    @{
        Name            = "Outlook"
        DisplayName     = "Outlook"
        Description     = "Microsoft Outlook"
        FilePath        = "C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE"
        CommandLineArgs = ""
        IconIndex       = 0
    },
    @{
        Name            = "Excel"
        DisplayName     = "Excel"
        Description     = "Microsoft Excel"
        FilePath        = "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE"
        CommandLineArgs = ""
        IconIndex       = 0
    },
    @{
        Name            = "Word"
        DisplayName     = "Word"
        Description     = "Microsoft Word"
        FilePath        = "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
        CommandLineArgs = ""
        IconIndex       = 0
    },
    @{
        Name            = "RemoteDesktop"
        DisplayName     = "Remote Desktop"
        Description     = "Remote Desktop Connection (mstsc)"
        FilePath        = "C:\Windows\System32\mstsc.exe"
        CommandLineArgs = ""
        IconIndex       = 0
    }
)

Write-Host "`n  Publishing RemoteApps..." -ForegroundColor Yellow
foreach ($app in $appsToPublish) {
    $existingApp = Get-AzWvdApplication `
        -ResourceGroupName       $AzResourceGroup `
        -ApplicationGroupName    $AppGroupRemoteApp `
        -Name                    $app.Name `
        -ErrorAction SilentlyContinue

    if ($existingApp) {
        Write-Host "    Already published: $($app.DisplayName)" -ForegroundColor Gray
        continue
    }

    # Resolve wildcard in file path if present (e.g. Business Central version folder)
    $resolvedPath = $app.FilePath
    if ($resolvedPath -match '\*') {
        $resolved = Resolve-Path -Path $resolvedPath -ErrorAction SilentlyContinue
        if ($resolved) {
            $resolvedPath = $resolved.Path | Select-Object -Last 1
        } else {
            Write-Warning "    Could not resolve path for '$($app.DisplayName)': $($app.FilePath)"
            Write-Warning "    Skipping — add manually via Portal after verifying install path on session host."
            continue
        }
    }

    try {
        New-AzWvdApplication `
            -ResourceGroupName       $AzResourceGroup `
            -ApplicationGroupName    $AppGroupRemoteApp `
            -Name                    $app.Name `
            -DisplayName             $app.DisplayName `
            -Description             $app.Description `
            -FilePath                $resolvedPath `
            -CommandLineSetting      "DoNotAllow" `
            -IconPath                $resolvedPath `
            -IconIndex               $app.IconIndex `
            -ShowInPortal            $true | Out-Null
        Write-Host "    Published: $($app.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Warning "    Failed to publish '$($app.DisplayName)': $_"
        Write-Warning "    Add manually via Portal: AVD > Application groups > $AppGroupRemoteApp > Applications > + Add"
    }
}

Write-Host ""
Write-Host "  ACTION: Add the 1-2 additional customer apps manually via the Portal or by" -ForegroundColor Magenta
Write-Host "  adding entries to the `$appsToPublish array above and re-running this script." -ForegroundColor Magenta

# -----------------------------------------------------------------------------
# Steps 60-61 – Create Workspace and associate app groups
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 60-61] Creating workspace '$WorkspaceName'..." -ForegroundColor Yellow

$appGroupIds = @(
    (Get-AzWvdApplicationGroup -ResourceGroupName $AzResourceGroup -Name $AppGroupRemoteApp).Id
    (Get-AzWvdApplicationGroup -ResourceGroupName $AzResourceGroup -Name $desktopGroupName).Id
) | Where-Object { $_ -ne $null }

$workspace = Get-AzWvdWorkspace -ResourceGroupName $AzResourceGroup -Name $WorkspaceName -ErrorAction SilentlyContinue
if (-not $workspace) {
    New-AzWvdWorkspace `
        -ResourceGroupName        $AzResourceGroup `
        -Name                     $WorkspaceName `
        -Location                 $AzLocation `
        -ApplicationGroupReference $appGroupIds `
        -Description              "AVD workspace for all users" | Out-Null
    Write-Host "  Created workspace: $WorkspaceName" -ForegroundColor Green
} else {
    Write-Host "  Workspace already exists — updating app group associations..." -ForegroundColor Gray
    Update-AzWvdWorkspace `
        -ResourceGroupName         $AzResourceGroup `
        -Name                      $WorkspaceName `
        -ApplicationGroupReference $appGroupIds | Out-Null
    Write-Host "  Workspace updated." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Steps 62-63 – Assign users to application groups
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 62-63] Assigning '$AdGroupAvdUsers' to application groups..." -ForegroundColor Yellow

if ($groupObjectId) {
    foreach ($agName in @($AppGroupRemoteApp, $desktopGroupName)) {
        $agId = (Get-AzWvdApplicationGroup -ResourceGroupName $AzResourceGroup -Name $agName).Id

        $existingAssignment = Get-AzRoleAssignment `
            -ObjectId           $groupObjectId `
            -RoleDefinitionName "Desktop Virtualization User" `
            -Scope              $agId `
            -ErrorAction SilentlyContinue

        if (-not $existingAssignment) {
            New-AzRoleAssignment `
                -ObjectId           $groupObjectId `
                -RoleDefinitionName "Desktop Virtualization User" `
                -Scope              $agId | Out-Null
            Write-Host "  Assigned '$AdGroupAvdUsers' to '$agName'" -ForegroundColor Green
        } else {
            Write-Host "  '$AdGroupAvdUsers' already assigned to '$agName'" -ForegroundColor Gray
        }
    }
} else {
    Write-Warning "Skipped user assignment — group '$AdGroupAvdUsers' not found in Entra ID."
}

Write-Host "`n=== Phase 8 Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Users can now connect via Windows App:" -ForegroundColor White
Write-Host "  Windows : https://aka.ms/windows-app" -ForegroundColor Gray
Write-Host "  Mac     : Search 'Windows App' in the Mac App Store" -ForegroundColor Gray
Write-Host ""
Write-Host "Next step: Run 09-monitoring.ps1, then proceed to testing." -ForegroundColor White
