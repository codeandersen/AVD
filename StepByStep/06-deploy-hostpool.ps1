#Requires -Modules Az.Accounts, Az.Resources, Az.DesktopVirtualization, Az.Compute, Az.Network
<#
.SYNOPSIS
    Phase 6 – Deploy the AVD host pool and session hosts.
.DESCRIPTION
    Creates the pooled host pool, deploys 2 session host VMs from the custom
    gallery image, joins them to the on-prem domain (hybrid Entra join),
    and verifies the hosts show Available in the host pool.
.NOTES
    Steps covered: 43–51 from the deployment plan.
    Requires: Az.DesktopVirtualization module — install with:
              Install-Module Az.DesktopVirtualization -Scope CurrentUser
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 6: Host Pool + Session Hosts ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

# Verify Az.DesktopVirtualization is available
if (-not (Get-Module -ListAvailable -Name Az.DesktopVirtualization)) {
    Write-Host "Installing Az.DesktopVirtualization module..." -ForegroundColor Yellow
    Install-Module Az.DesktopVirtualization -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.DesktopVirtualization

# Collect domain join password securely
$domainJoinPassword = Read-Host -Prompt "Enter password for domain join account ($DomainJoinUPN)" -AsSecureString
$domainJoinCred     = New-Object System.Management.Automation.PSCredential($DomainJoinUPN, $domainJoinPassword)

# Collect local admin password for session host VMs
$localAdminCred = Get-Credential -Message "Enter local administrator username and password for session host VMs"

# -----------------------------------------------------------------------------
# Steps 43-47 – Create Host Pool
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 43-47] Creating host pool '$HostPoolName'..." -ForegroundColor Yellow

$hostPool = Get-AzWvdHostPool -ResourceGroupName $AzResourceGroup -Name $HostPoolName -ErrorAction SilentlyContinue
if (-not $hostPool) {
    $hostPool = New-AzWvdHostPool `
        -ResourceGroupName        $AzResourceGroup `
        -Name                     $HostPoolName `
        -Location                 $AzLocation `
        -HostPoolType             "Pooled" `
        -LoadBalancerType         "BreadthFirst" `
        -MaxSessionLimit          $MaxSessionsPerHost `
        -ValidationEnvironment    $false `
        -PreferredAppGroupType    "Desktop" `
        -StartVMOnConnect         $false
    Write-Host "  Host pool '$HostPoolName' created." -ForegroundColor Green
} else {
    Write-Host "  Host pool '$HostPoolName' already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 47a – Enable SSO on the host pool (Entra ID auth RDP property)
# -----------------------------------------------------------------------------
Write-Host "  Enabling SSO on host pool (enablerdsaadauth)..." -ForegroundColor Gray
Update-AzWvdHostPool `
    -ResourceGroupName $AzResourceGroup `
    -Name              $HostPoolName `
    -CustomRdpProperty "enablerdsaadauth:i:1"
Write-Host "  SSO enabled. Users will authenticate once via Entra ID — no second prompt." -ForegroundColor Green
Write-Host "  Prerequisite: Entra Kerberos server object must exist (Step 8a in 01-ad-prep.ps1)." -ForegroundColor Gray

# Generate a registration token (valid for 24 hours)
Write-Host "  Generating registration token..." -ForegroundColor Gray
$tokenExpiry = (Get-Date).ToUniversalTime().AddHours(24)
$regToken = New-AzWvdRegistrationInfo `
    -ResourceGroupName $AzResourceGroup `
    -HostPoolName      $HostPoolName `
    -ExpirationTime    $tokenExpiry
$registrationToken = $regToken.Token
Write-Host "  Registration token generated (valid 24 hours)." -ForegroundColor Green

# -----------------------------------------------------------------------------
# Deploy Session Host VMs
# -----------------------------------------------------------------------------
Write-Host "`n  Deploying $SessionHostCount session host VMs..." -ForegroundColor Yellow

# Get networking resources (VNet lives in infra RG)
$vnet   = Get-AzVirtualNetwork -ResourceGroupName $AzResourceGroup -Name $VNetName
$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
if (-not $subnet) {
    Write-Error "Subnet '$SubnetName' not found. Run 03-networking.ps1 first."
}

# Get image version from gallery
$imageVersion = Get-AzGalleryImageVersion `
    -ResourceGroupName    $AzResourceGroup `
    -GalleryName          $GalleryName `
    -GalleryImageDefinitionName $ImageDefinitionName `
    -Name                 $ImageVersion `
    -ErrorAction SilentlyContinue

if (-not $imageVersion) {
    Write-Error "Image version '$ImageVersion' not found in gallery '$GalleryName'. Complete Phase 5 first."
}

# Custom script extension content — installs AVD agent and registers with host pool
$avdAgentScript = @"
`$ErrorActionPreference = 'Stop'
`$tempDir = 'C:\AVD-Agent'
New-Item -ItemType Directory -Path `$tempDir -Force | Out-Null

# Download AVD Agent
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -OutFile "`$tempDir\AVDAgent.msi" -UseBasicParsing
# Download AVD Bootloader
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -OutFile "`$tempDir\AVDBootloader.msi" -UseBasicParsing

# Install AVD Agent
Start-Process msiexec.exe -ArgumentList "/i `$tempDir\AVDAgent.msi REGISTRATIONTOKEN=$registrationToken /quiet /norestart" -Wait

# Install Bootloader
Start-Process msiexec.exe -ArgumentList "/i `$tempDir\AVDBootloader.msi /quiet /norestart" -Wait

Remove-Item -Path `$tempDir -Recurse -Force -ErrorAction SilentlyContinue
"@

$encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($avdAgentScript))

for ($i = 0; $i -lt $SessionHostCount; $i++) {
    $vmName = "$SessionHostPrefix-$i"
    Write-Host "`n  Deploying VM: $vmName" -ForegroundColor Yellow

    # VMs and their NICs/disks go into the hosts RG
    $existingVm = Get-AzVM -ResourceGroupName $AzResourceGroupHosts -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Host "    VM '$vmName' already exists — skipping." -ForegroundColor Gray
        continue
    }

    # NIC
    $nicName = "$vmName-nic"
    $nic = New-AzNetworkInterface `
        -ResourceGroupName $AzResourceGroupHosts `
        -Name              $nicName `
        -Location          $AzLocation `
        -SubnetId          $subnet.Id

    # VM config
    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $SessionHostSize |
        Set-AzVMOperatingSystem `
            -Windows `
            -ComputerName  $vmName `
            -Credential    $localAdminCred `
            -JoinDomain    $AdDomain `
            -DomainCredential $domainJoinCred `
            -OUPath        $OuSessionHosts |
        Set-AzVMSourceImage -Id $imageVersion.Id |
        Add-AzVMNetworkInterface -Id $nic.Id |
        Set-AzVMOSDisk `
            -CreateOption  FromImage `
            -StorageAccountType Premium_LRS `
            -DiskSizeGB    128

    # Disable boot diagnostics
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    # Create VM in the hosts RG
    New-AzVM -ResourceGroupName $AzResourceGroupHosts -Location $AzLocation -VM $vmConfig | Out-Null
    Write-Host "    VM '$vmName' created and domain-joined in '$AzResourceGroupHosts'." -ForegroundColor Green

    # Install AVD Agent via Custom Script Extension
    Write-Host "    Installing AVD agent on $vmName..." -ForegroundColor Gray
    Set-AzVMExtension `
        -ResourceGroupName  $AzResourceGroupHosts `
        -VMName             $vmName `
        -Name               "AVDAgentInstall" `
        -Publisher          "Microsoft.Compute" `
        -ExtensionType      "CustomScriptExtension" `
        -TypeHandlerVersion "1.10" `
        -Settings           @{ commandToExecute = "powershell.exe -ExecutionPolicy Bypass -EncodedCommand $encodedScript" } | Out-Null
    Write-Host "    AVD agent installed on $vmName." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Steps 48-51 – Verification guidance
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 48-51] Post-Deployment Verification" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. AD: Verify computer objects exist in the AVD OU:" -ForegroundColor White
for ($i = 0; $i -lt $SessionHostCount; $i++) {
    Write-Host "       Get-ADComputer -Identity '$SessionHostPrefix-$i'" -ForegroundColor DarkGray
}
Write-Host "  Note: VMs are in '$AzResourceGroupHosts', host pool is in '$AzResourceGroup'" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Entra Connect: Force sync on the Entra Connect server:" -ForegroundColor White
Write-Host "       Start-ADSyncSyncCycle -PolicyType Delta" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  3. Entra ID: Check Devices — both VMs should show 'Hybrid Azure AD Joined'" -ForegroundColor White
Write-Host "       Portal: Entra Admin Center > Devices > All devices > search 'avd-sh'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  4. AVD Portal: Host pool > Session hosts — both should show 'Available'" -ForegroundColor White
Write-Host "       (may take 5-10 min for the agent to register)" -ForegroundColor DarkGray

# Check current session host status
Write-Host "`n  Checking session host status (may be 'Unavailable' until agent registers)..." -ForegroundColor Gray
Start-Sleep -Seconds 30
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $AzResourceGroup -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
if ($sessionHosts) {
    foreach ($sh in $sessionHosts) {
        $status = $sh.Status
        $color  = if ($status -eq "Available") { "Green" } else { "Yellow" }
        Write-Host "    $($sh.Name.Split('/')[1]) — Status: $status" -ForegroundColor $color
    }
} else {
    Write-Host "    No session hosts registered yet — check back in a few minutes." -ForegroundColor Yellow
}

Write-Host "`n=== Phase 6 Complete ===" -ForegroundColor Cyan
Write-Host "Next step: Run 07-fslogix-gpo.ps1 from a domain-joined machine." -ForegroundColor White
