#Requires -Modules Az.Accounts, Az.Resources, Az.Network
<#
.SYNOPSIS
    Phase 3 – Deploy Azure networking for AVD (VNet, subnet, DNS, NSG).
.DESCRIPTION
    Creates the Resource Group, Virtual Network with custom DNS pointing to
    on-prem DCs, the session host subnet, and an NSG with AVD-required rules.
.NOTES
    Steps covered: 13–21 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 3: Azure Networking ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
}

# -----------------------------------------------------------------------------
# Step 13 – Resource Groups (infra + hosts)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 13] Creating Resource Groups..." -ForegroundColor Yellow

# Infra RG: VNet, NSG, Storage, Gallery, Host Pool, Workspace, Monitoring
$rg = Get-AzResourceGroup -Name $AzResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $AzResourceGroup -Location $AzLocation -Tag @{ Project = "AVD"; Environment = "Production"; Role = "Infrastructure" } | Out-Null
    Write-Host "  Created: $AzResourceGroup  (AVD services, networking, storage)" -ForegroundColor Green
} else {
    Write-Host "  $AzResourceGroup already exists, skipping." -ForegroundColor Gray
}

# Hosts RG: Session host VMs, NICs, OS disks
$rgHosts = Get-AzResourceGroup -Name $AzResourceGroupHosts -ErrorAction SilentlyContinue
if (-not $rgHosts) {
    New-AzResourceGroup -Name $AzResourceGroupHosts -Location $AzLocation -Tag @{ Project = "AVD"; Environment = "Production"; Role = "SessionHosts" } | Out-Null
    Write-Host "  Created: $AzResourceGroupHosts  (session host VMs, NICs, disks)" -ForegroundColor Green
} else {
    Write-Host "  $AzResourceGroupHosts already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 17 – NSG (create before VNet so we can associate on subnet creation)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 17] Creating NSG '$NsgName'..." -ForegroundColor Yellow
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $AzResourceGroup -Name $NsgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    # Step 18 – NSG rules
    # Rule 1: Allow AVD service tag inbound on 3389 (required for the AVD gateway to broker connections)
    $ruleAvd = New-AzNetworkSecurityRuleConfig `
        -Name                     "Allow-AVD-ServiceTag-RDP" `
        -Description              "Allow RDP from AVD control plane (gateway)" `
        -Protocol                 Tcp `
        -SourcePortRange          "*" `
        -DestinationPortRange     "3389" `
        -SourceAddressPrefix      "WindowsVirtualDesktop" `
        -DestinationAddressPrefix "VirtualNetwork" `
        -Access                   Allow `
        -Priority                 100 `
        -Direction                Inbound

    # Rule 2: Allow HTTPS outbound to Azure (required for AVD agent, monitoring, storage)
    $ruleHttpsOut = New-AzNetworkSecurityRuleConfig `
        -Name                     "Allow-HTTPS-Outbound" `
        -Description              "Allow HTTPS outbound to Azure services" `
        -Protocol                 Tcp `
        -SourcePortRange          "*" `
        -DestinationPortRange     "443" `
        -SourceAddressPrefix      "VirtualNetwork" `
        -DestinationAddressPrefix "AzureCloud" `
        -Access                   Allow `
        -Priority                 100 `
        -Direction                Outbound

    # Rule 3: Deny all other inbound RDP from internet
    $ruleDenyRdp = New-AzNetworkSecurityRuleConfig `
        -Name                     "Deny-RDP-Internet" `
        -Description              "Block direct RDP from internet" `
        -Protocol                 Tcp `
        -SourcePortRange          "*" `
        -DestinationPortRange     "3389" `
        -SourceAddressPrefix      "Internet" `
        -DestinationAddressPrefix "VirtualNetwork" `
        -Access                   Deny `
        -Priority                 200 `
        -Direction                Inbound

    $nsg = New-AzNetworkSecurityGroup `
        -ResourceGroupName $AzResourceGroup `
        -Location          $AzLocation `
        -Name              $NsgName `
        -SecurityRules     @($ruleAvd, $ruleDenyRdp, $ruleHttpsOut)
    Write-Host "  Created NSG: $NsgName with 3 rules" -ForegroundColor Green
} else {
    Write-Host "  NSG already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 14 – Virtual Network
# Steps 15-16 – Subnet with custom DNS
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 14-16] Creating VNet '$VNetName' with subnet '$SubnetName'..." -ForegroundColor Yellow
$existingVnet = Get-AzVirtualNetwork -ResourceGroupName $AzResourceGroup -Name $VNetName -ErrorAction SilentlyContinue

if (-not $existingVnet) {
    # Build subnet config with NSG attached
    $subnetConfig = New-AzVirtualNetworkSubnetConfig `
        -Name                 $SubnetName `
        -AddressPrefix        $SubnetPrefix `
        -NetworkSecurityGroup $nsg

    # Create VNet with on-prem DC as DNS server
    # Step 16 – Custom DNS is critical for hybrid join
    New-AzVirtualNetwork `
        -ResourceGroupName $AzResourceGroup `
        -Location          $AzLocation `
        -Name              $VNetName `
        -AddressPrefix     $VNetAddressPrefix `
        -Subnet            $subnetConfig `
        -DnsServer         $OnPremDnsServers `
        -Tag               @{ Project = "AVD"; Environment = "Production" } | Out-Null

    Write-Host "  Created VNet: $VNetName ($VNetAddressPrefix)" -ForegroundColor Green
    Write-Host "  Subnet:       $SubnetName ($SubnetPrefix)" -ForegroundColor Green
    Write-Host "  Custom DNS:   $($OnPremDnsServers -join ', ')" -ForegroundColor Green
} else {
    Write-Host "  VNet '$VNetName' already exists." -ForegroundColor Gray

    # Check if our subnet already exists
    $existingSubnet = $existingVnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
    if (-not $existingSubnet) {
        Write-Host "  Adding subnet '$SubnetName' to existing VNet..." -ForegroundColor Yellow
        Add-AzVirtualNetworkSubnetConfig `
            -VirtualNetwork       $existingVnet `
            -Name                 $SubnetName `
            -AddressPrefix        $SubnetPrefix `
            -NetworkSecurityGroup $nsg | Out-Null
        Set-AzVirtualNetwork -VirtualNetwork $existingVnet | Out-Null
        Write-Host "  Subnet added." -ForegroundColor Green
    } else {
        Write-Host "  Subnet '$SubnetName' already exists, skipping." -ForegroundColor Gray
    }

    # Ensure DNS is set correctly
    $existingVnet = Get-AzVirtualNetwork -ResourceGroupName $AzResourceGroup -Name $VNetName
    if ($existingVnet.DhcpOptions.DnsServers -notcontains $OnPremDnsServers[0]) {
        Write-Host "  Updating DNS servers on VNet to on-prem DCs..." -ForegroundColor Yellow
        $existingVnet.DhcpOptions.DnsServers = $OnPremDnsServers
        Set-AzVirtualNetwork -VirtualNetwork $existingVnet | Out-Null
        Write-Host "  DNS updated: $($OnPremDnsServers -join ', ')" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# Steps 19-21 – Verify VPN routing (guidance + optional test VM)
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 19-21] VPN Routing Verification" -ForegroundColor Yellow
Write-Host "  The script cannot automate this step. Manually verify:"
Write-Host "  1. Deploy a test VM in subnet '$SubnetName' of VNet '$VNetName'"
Write-Host "  2. RDP into the test VM"
Write-Host "  3. Run: ping $($OnPremDnsServers[0])   (should reply)"
Write-Host "  4. Run: nslookup $AdDomain             (should return DC IP)"
Write-Host "  5. If both pass, delete the test VM and proceed to Phase 4"
Write-Host ""
Write-Host "  To quickly create a test VM (run manually if needed):"
Write-Host @"
  `$subnet = (Get-AzVirtualNetwork -ResourceGroupName '$AzResourceGroup' -Name '$VNetName').Subnets | Where-Object { `$_.Name -eq '$SubnetName' }
  New-AzVm -ResourceGroupName '$AzResourceGroup' -Name 'avd-test-vm' -Location '$AzLocation' ``
           -VirtualNetworkName '$VNetName' -SubnetName '$SubnetName' -Size 'Standard_B2s' -OpenPorts 3389
"@ -ForegroundColor DarkGray

Write-Host "`n=== Phase 3 Complete ===" -ForegroundColor Cyan
Write-Host "Verify VPN routing (steps 19-21), then run 04-azure-files.ps1 from a domain-joined machine." -ForegroundColor White
