#Requires -Modules Az.Accounts, Az.Compute, Az.Resources
<#
.SYNOPSIS
    Phase 2 – Verify Azure prerequisites before deployment.
.DESCRIPTION
    Checks subscription quota, registers required resource providers,
    and validates user licensing. Outputs a pass/fail summary.
.NOTES
    Steps covered: 9–12 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 2: Azure Prerequisites Check ===" -ForegroundColor Cyan

# Connect to Azure
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using existing Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

$allPassed = $true

# -----------------------------------------------------------------------------
# Step 9 – Check VM quota for session host size in Denmark East
# -----------------------------------------------------------------------------
Write-Host "`n[Step 9] Checking VM quota for '$SessionHostSize' in '$AzLocation'..." -ForegroundColor Yellow

$usage = Get-AzVMUsage -Location $AzLocation | Where-Object {
    $_.Name.Value -match "standardDSv5Family" -or $_.Name.Value -match "cores"
}

foreach ($u in $usage) {
    $available = $u.Limit - $u.CurrentValue
    $status    = if ($available -ge ($SessionHostCount * 4)) { "OK" } else { "WARNING" }
    $color     = if ($status -eq "OK") { "Green" } else { "Red" }
    Write-Host ("  {0,-45} Used: {1,4}  Limit: {2,4}  Available: {3,4}  [{4}]" -f `
        $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $available, $status) -ForegroundColor $color
    if ($status -eq "WARNING") { $allPassed = $false }
}

# Also check if the specific VM size is available in the region
Write-Host "`n  Checking if '$SessionHostSize' SKU is available in $AzLocation..."
$sku = Get-AzComputeResourceSku -Location $AzLocation | Where-Object {
    $_.ResourceType -eq "virtualMachines" -and $_.Name -eq $SessionHostSize
}
if ($sku) {
    $restrictions = $sku | Select-Object -ExpandProperty Restrictions
    if ($restrictions.Count -eq 0) {
        Write-Host "  VM size '$SessionHostSize' is available in $AzLocation [OK]" -ForegroundColor Green
    } else {
        Write-Host "  VM size '$SessionHostSize' has restrictions in $AzLocation: $($restrictions.ReasonCode)" -ForegroundColor Red
        $allPassed = $false
    }
} else {
    Write-Host "  VM size '$SessionHostSize' NOT found in $AzLocation — choose a different size." -ForegroundColor Red
    $allPassed = $false
}

# -----------------------------------------------------------------------------
# Step 10 – Register required Azure resource providers
# -----------------------------------------------------------------------------
Write-Host "`n[Step 10] Registering required resource providers..." -ForegroundColor Yellow

$providers = @(
    "Microsoft.DesktopVirtualization",
    "Microsoft.Compute",
    "Microsoft.Network",
    "Microsoft.Storage",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights"
)

foreach ($provider in $providers) {
    $rp = Get-AzResourceProvider -ProviderNamespace $provider
    if ($rp.RegistrationState -ne "Registered") {
        Write-Host "  Registering $provider..." -ForegroundColor Yellow
        Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
        Write-Host "  $provider registration initiated (may take 1-2 min)" -ForegroundColor Yellow
    } else {
        Write-Host "  $provider [Already Registered]" -ForegroundColor Green
    }
}

# Wait for DesktopVirtualization specifically (required for host pool creation)
Write-Host "`n  Waiting for Microsoft.DesktopVirtualization to finish registering..."
$maxWait = 120
$waited  = 0
do {
    Start-Sleep -Seconds 10
    $waited += 10
    $state = (Get-AzResourceProvider -ProviderNamespace "Microsoft.DesktopVirtualization").RegistrationState
    Write-Host "  State: $state ($waited s)" -ForegroundColor Gray
} while ($state -ne "Registered" -and $waited -lt $maxWait)

if ($state -eq "Registered") {
    Write-Host "  Microsoft.DesktopVirtualization registered [OK]" -ForegroundColor Green
} else {
    Write-Host "  Timed out waiting — check status manually and re-run if needed." -ForegroundColor Red
    $allPassed = $false
}

# -----------------------------------------------------------------------------
# Step 11 – Licensing check (informational — requires Graph or manual check)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 11] Licensing — MANUAL VERIFICATION REQUIRED" -ForegroundColor Magenta
Write-Host "  Verify in Microsoft 365 Admin Center (admin.microsoft.com):"
Write-Host "  - All 25 AVD users have M365 E3, E5, F3, or Business Premium assigned"
Write-Host "  - Licenses required for AVD: any of the above plans include AVD entitlement"
Write-Host "  - Tip: Entra ID > Users > [user] > Licenses to check individual assignment"

# -----------------------------------------------------------------------------
# Step 12 – VPN connectivity check
# -----------------------------------------------------------------------------
Write-Host "`n[Step 12] VPN Connectivity — MANUAL VERIFICATION REQUIRED" -ForegroundColor Magenta
Write-Host "  Before session hosts are deployed, verify VPN is routing to Denmark East:"
Write-Host "  1. Deploy a temporary test VM in the same region/subnet"
Write-Host "  2. RDP in and run: ping $($OnPremDnsServers[0])"
Write-Host "  3. Run: nslookup $AdDomain"
Write-Host "  4. Both must succeed before proceeding to Phase 6 (host pool)"
Write-Host ""
Write-Host "  On-prem DC IPs configured: $($OnPremDnsServers -join ', ')"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host "`n=== Phase 2 Summary ===" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "All automated checks PASSED. Complete manual steps above, then run 03-networking.ps1." -ForegroundColor Green
} else {
    Write-Host "One or more checks FAILED. Resolve issues above before proceeding." -ForegroundColor Red
}
