#Requires -Modules Az.Accounts, Az.Resources, Az.Compute
<#
.SYNOPSIS
    Phase 5a – Create Azure Compute Gallery, image definition, and build VM.
.DESCRIPTION
    Creates the gallery, image definition, and deploys the temporary build VM
    from the Windows 11 Multi-Session + M365 Apps marketplace image.
    After this script completes, RDP into the build VM and run 05-image-prep.ps1.
.NOTES
    Steps covered: 30–32 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 5a: Create Image Gallery + Build VM ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 30 – Create Azure Compute Gallery
# -----------------------------------------------------------------------------
Write-Host "`n[Step 30] Creating Azure Compute Gallery '$GalleryName'..." -ForegroundColor Yellow

$gallery = Get-AzGallery -ResourceGroupName $AzResourceGroup -Name $GalleryName -ErrorAction SilentlyContinue
if (-not $gallery) {
    $gallery = New-AzGallery `
        -ResourceGroupName $AzResourceGroup `
        -Name              $GalleryName `
        -Location          $AzLocation `
        -Description       "AVD golden images for session host deployment"
    Write-Host "  Created gallery: $GalleryName" -ForegroundColor Green
} else {
    Write-Host "  Gallery already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 31 – Create Image Definition
# -----------------------------------------------------------------------------
Write-Host "`n[Step 31] Creating image definition '$ImageDefinitionName'..." -ForegroundColor Yellow

$imageDef = Get-AzGalleryImageDefinition `
    -ResourceGroupName $AzResourceGroup `
    -GalleryName       $GalleryName `
    -Name              $ImageDefinitionName `
    -ErrorAction SilentlyContinue

if (-not $imageDef) {
    $imageDef = New-AzGalleryImageDefinition `
        -ResourceGroupName $AzResourceGroup `
        -GalleryName       $GalleryName `
        -Name              $ImageDefinitionName `
        -Location          $AzLocation `
        -Publisher         "Contoso" `
        -Offer             "AVD" `
        -Sku               "Win11-MS" `
        -OsState           "Generalized" `
        -OsType            "Windows" `
        -HyperVGeneration  "V2" `
        -Description       "Windows 11 Multi-Session + M365 Apps - AVD optimized"
    Write-Host "  Created image definition: $ImageDefinitionName" -ForegroundColor Green
} else {
    Write-Host "  Image definition already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 32 – Deploy Build VM
# -----------------------------------------------------------------------------
Write-Host "`n[Step 32] Deploying build VM '$BuildVmName'..." -ForegroundColor Yellow

$existingBuildVm = Get-AzVM -ResourceGroupName $AzResourceGroupHosts -Name $BuildVmName -ErrorAction SilentlyContinue
if ($existingBuildVm) {
    Write-Host "  Build VM '$BuildVmName' already exists — skipping creation." -ForegroundColor Gray
    Write-Host "  If you need a fresh VM, delete it first: Remove-AzVM -ResourceGroupName '$AzResourceGroupHosts' -Name '$BuildVmName' -Force" -ForegroundColor Gray
} else {
    # Ensure the hosts RG exists (created by 03-networking.ps1, but create here too if needed)
    if (-not (Get-AzResourceGroup -Name $AzResourceGroupHosts -ErrorAction SilentlyContinue)) {
        New-AzResourceGroup -Name $AzResourceGroupHosts -Location $AzLocation -Tag @{ Project = "AVD"; Environment = "Production"; Role = "SessionHosts" } | Out-Null
        Write-Host "  Created resource group: $AzResourceGroupHosts" -ForegroundColor Green
    }

    # Get the subnet reference
    $vnet   = Get-AzVirtualNetwork -ResourceGroupName $AzResourceGroup -Name $VNetName
    $subnet = ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName })
    if (-not $subnet) {
        Write-Error "Subnet '$SubnetName' not found in VNet '$VNetName'. Run 03-networking.ps1 first."
    }

    # Get the latest marketplace image version
    Write-Host "  Resolving latest marketplace image version..." -ForegroundColor Gray
    $latestImage = Get-AzVMImage `
        -Location  $AzLocation `
        -Publisher $SourceImagePublisher `
        -Offer     $SourceImageOffer `
        -Sku       $SourceImageSku |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $latestImage) {
        Write-Error "Could not find marketplace image: $SourceImagePublisher/$SourceImageOffer/$SourceImageSku in $AzLocation"
    }
    Write-Host "  Using image version: $($latestImage.Version)" -ForegroundColor Gray

    # Prompt for local admin credentials for the build VM
    Write-Host "  Enter local admin credentials for the build VM:" -ForegroundColor Yellow
    $buildVmCred = Get-Credential -Message "Build VM local administrator"

    # NIC — goes into the hosts RG along with the VM
    $nicName = "$BuildVmName-nic"
    $nic = New-AzNetworkInterface `
        -ResourceGroupName $AzResourceGroupHosts `
        -Name              $nicName `
        -Location          $AzLocation `
        -SubnetId          $subnet.Id

    # VM config
    $vmConfig = New-AzVMConfig -VMName $BuildVmName -VMSize $BuildVmSize |
        Set-AzVMOperatingSystem -Windows -ComputerName $BuildVmName -Credential $buildVmCred |
        Set-AzVMSourceImage `
            -PublisherName $SourceImagePublisher `
            -Offer         $SourceImageOffer `
            -Skus          $SourceImageSku `
            -Version       $latestImage.Version |
        Add-AzVMNetworkInterface -Id $nic.Id |
        Set-AzVMOSDisk -CreateOption FromImage -StorageAccountType Premium_LRS

    # Disable boot diagnostics (keeps it simple for a temporary VM)
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    New-AzVM -ResourceGroupName $AzResourceGroupHosts -Location $AzLocation -VM $vmConfig | Out-Null
    Write-Host "  Build VM '$BuildVmName' created in '$AzResourceGroupHosts'." -ForegroundColor Green
}

# Display connection info
$buildVm  = Get-AzVM -ResourceGroupName $AzResourceGroupHosts -Name $BuildVmName
$nicId    = $buildVm.NetworkProfile.NetworkInterfaces[0].Id
$nicObj   = Get-AzNetworkInterface -ResourceId $nicId
$privateIp = $nicObj.IpConfigurations[0].PrivateIpAddress

Write-Host "`n=== Phase 5a Complete ===" -ForegroundColor Cyan
Write-Host "Build VM private IP : $privateIp" -ForegroundColor White
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. RDP into $BuildVmName at $privateIp (via VPN/Bastion)"
Write-Host "2. Copy 05-image-prep.ps1 to the build VM"
Write-Host "3. Run 05-image-prep.ps1 inside the VM as Administrator"
Write-Host "4. The script will install apps, FSLogix, optimise, and trigger Sysprep"
Write-Host "5. After the VM shuts down, return and the Portal guide (Phase 5 Step 40) will capture it"
