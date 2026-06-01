<#
.SYNOPSIS
    Phase 5b – Prepare the golden image inside the build VM.
.DESCRIPTION
    Run this script INSIDE the build VM (avd-build-vm) as a local Administrator.
    It installs FSLogix, runs the AVD optimisation tool, installs Windows updates,
    cleans up, and triggers Sysprep to generalise the image.

    After the script completes the VM will shut down automatically.
    Return to the Azure Portal to capture the image (Steps 40-41 in portal-guide.md).

    *** DO NOT run this on a production machine — it will SYSPREP the OS ***
.NOTES
    Steps covered: 33–39 from the deployment plan.
#>

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "`n=== Phase 5b: Golden Image Preparation ===" -ForegroundColor Cyan
Write-Host "Running inside build VM. This will end with Sysprep and shutdown." -ForegroundColor Yellow
Write-Host ""

# Safety check — ensure this is not accidentally run on a production/joined machine
$isAzureVM = (Invoke-RestMethod -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" `
    -Headers @{ Metadata = "true" } -ErrorAction SilentlyContinue) -ne $null
if (-not $isAzureVM) {
    Write-Warning "Could not confirm this is an Azure VM. Proceed with caution."
    $confirm = Read-Host "Type 'YES' to continue anyway"
    if ($confirm -ne "YES") { exit 0 }
}

$tempDir = "C:\AVD-ImagePrep"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# -----------------------------------------------------------------------------
# Step 33 – Verify Office 365 Apps are installed
# -----------------------------------------------------------------------------
Write-Host "`n[Step 33] Verifying Office 365 Apps..." -ForegroundColor Yellow
$outlookPath = "C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE"
if (Test-Path $outlookPath) {
    Write-Host "  Office 365 Apps found at C:\Program Files\Microsoft Office" -ForegroundColor Green
} else {
    Write-Warning "  Office 365 Apps not found at expected path. Verify the correct gallery image was used."
    Write-Warning "  Expected: Windows 11 Enterprise multi-session + Microsoft 365 Apps"
}

Write-Host ""
Write-Host "  ACTION: Manually install any customer-specific applications now if not already done:" -ForegroundColor Magenta
Write-Host "    - Business Central client (download from your BC server or partner)"
Write-Host "    - Any additional apps confirmed with the customer"
Write-Host ""
$appsReady = Read-Host "  Have you installed all required applications? (yes/no)"
if ($appsReady -ne "yes") {
    Write-Host "  Install your applications, then re-run this script." -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# Step 34 – Install FSLogix Agent
# -----------------------------------------------------------------------------
Write-Host "`n[Step 34] Downloading and installing FSLogix..." -ForegroundColor Yellow

$fslogixUrl      = "https://aka.ms/fslogix-latest"
$fslogixZip      = "$tempDir\FSLogix.zip"
$fslogixExtract  = "$tempDir\FSLogix"

Write-Host "  Downloading FSLogix..." -ForegroundColor Gray
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $fslogixUrl -OutFile $fslogixZip -UseBasicParsing
Expand-Archive -Path $fslogixZip -DestinationPath $fslogixExtract -Force

$fslogixSetup = Get-ChildItem -Path $fslogixExtract -Recurse -Filter "FSLogixAppsSetup.exe" | Select-Object -First 1
if (-not $fslogixSetup) {
    Write-Error "FSLogixAppsSetup.exe not found in extracted files. Check the download."
}

Write-Host "  Installing FSLogix from: $($fslogixSetup.FullName)" -ForegroundColor Gray
Start-Process -FilePath $fslogixSetup.FullName -ArgumentList "/install /quiet /norestart" -Wait
Write-Host "  FSLogix installed." -ForegroundColor Green

# Copy ADMX templates to a temp location so they can be retrieved for the domain policy store
$policySource = "C:\Program Files\FSLogix\Apps\PolicyDefinitions"
if (Test-Path $policySource) {
    $admxDest = "$tempDir\FSLogix-ADMX"
    Copy-Item -Path $policySource -Destination $admxDest -Recurse -Force
    Write-Host "  ADMX templates copied to: $admxDest" -ForegroundColor Green
    Write-Host "  Copy these to your domain SYSVOL before running 07-fslogix-gpo.ps1" -ForegroundColor Magenta
}

# -----------------------------------------------------------------------------
# Step 35 – Run AVD Optimisation Tool (VDOT)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 35] Running AVD Optimisation Tool (VDOT)..." -ForegroundColor Yellow

$vdotUrl     = "https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/refs/heads/main.zip"
$vdotZip     = "$tempDir\vdot.zip"
$vdotExtract = "$tempDir\vdot"

Write-Host "  Downloading VDOT..." -ForegroundColor Gray
Invoke-WebRequest -Uri $vdotUrl -OutFile $vdotZip -UseBasicParsing
Expand-Archive -Path $vdotZip -DestinationPath $vdotExtract -Force

$vdotScript = Get-ChildItem -Path $vdotExtract -Recurse -Filter "Windows_VDOT.ps1" | Select-Object -First 1
if (-not $vdotScript) {
    Write-Warning "  VDOT script not found — skipping optimisation. Manually download and run if needed."
} else {
    Write-Host "  Running VDOT (this may take several minutes)..." -ForegroundColor Gray
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
    & $vdotScript.FullName -Optimizations All -AcceptEULA -Restart $false -Verbose
    Write-Host "  VDOT optimisation complete." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Step 36 – Windows Update
# -----------------------------------------------------------------------------
Write-Host "`n[Step 36] Installing Windows Updates..." -ForegroundColor Yellow

# Install PSWindowsUpdate module if not present
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "  Installing PSWindowsUpdate module..." -ForegroundColor Gray
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false | Out-Null
}

Import-Module PSWindowsUpdate
$updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot
if ($updates.Count -gt 0) {
    Write-Host "  Installing $($updates.Count) update(s)..." -ForegroundColor Gray
    Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false | Out-Null
    Write-Host "  Updates installed. A reboot may be needed — reboot now, then re-run this script to continue." -ForegroundColor Yellow

    $rebootNeeded = (New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
    if ($rebootNeeded) {
        Write-Host "  Reboot required. Rebooting in 30 seconds..." -ForegroundColor Yellow
        Write-Host "  After reboot, re-run this script to continue from the cleanup step." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        Restart-Computer -Force
        exit 0
    }
} else {
    Write-Host "  No updates pending." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Step 37 – Clean Up
# -----------------------------------------------------------------------------
Write-Host "`n[Step 37] Cleaning up temporary files..." -ForegroundColor Yellow

# Clear temp folders
$foldersToClean = @(
    $env:TEMP,
    "C:\Windows\Temp",
    "C:\Windows\SoftwareDistribution\Download"
)
foreach ($folder in $foldersToClean) {
    if (Test-Path $folder) {
        Get-ChildItem -Path $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleaned: $folder" -ForegroundColor Gray
    }
}

# Remove our prep folder (keep ADMX copy if it exists on desktop/share)
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Temp prep folder removed." -ForegroundColor Gray

# Clear event logs
Write-Host "  Clearing event logs..." -ForegroundColor Gray
Get-EventLog -List | ForEach-Object {
    [System.Diagnostics.EventLog]::DeleteEventSource($_.Log) 2>$null
    Clear-EventLog -LogName $_.Log -ErrorAction SilentlyContinue
}

Write-Host "  Cleanup complete." -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 38 – Confirm AVD Agent is NOT installed
# -----------------------------------------------------------------------------
Write-Host "`n[Step 38] Checking AVD agent status..." -ForegroundColor Yellow
$avdAgent = Get-WmiObject Win32_Product | Where-Object { $_.Name -like "*Remote Desktop Services Infrastructure Agent*" }
if ($avdAgent) {
    Write-Warning "AVD agent is installed on this build VM. It should NOT be pre-installed."
    Write-Warning "The agent will be installed automatically during host pool deployment."
    Write-Warning "Uninstall it now: $($avdAgent.Name)"
    $uninstall = Read-Host "  Uninstall automatically? (yes/no)"
    if ($uninstall -eq "yes") {
        $avdAgent.Uninstall() | Out-Null
        Write-Host "  AVD agent uninstalled." -ForegroundColor Green
    }
} else {
    Write-Host "  AVD agent not installed — correct." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Step 39 – Sysprep
# -----------------------------------------------------------------------------
Write-Host "`n[Step 39] Running Sysprep — VM will shut down after this step." -ForegroundColor Yellow
Write-Host ""
Write-Host "  *** THIS IS THE POINT OF NO RETURN ***" -ForegroundColor Red
Write-Host "  The VM will be generalised and shut down."
Write-Host "  After shutdown, go to the Azure Portal and CAPTURE the image (portal-guide.md Step 40)."
Write-Host ""
$sysprepConfirm = Read-Host "  Type 'SYSPREP' to proceed"

if ($sysprepConfirm -eq "SYSPREP") {
    Write-Host "  Starting Sysprep..." -ForegroundColor Yellow
    Start-Process -FilePath "C:\Windows\System32\Sysprep\sysprep.exe" `
        -ArgumentList "/oobe /generalize /shutdown /quiet" `
        -Wait
} else {
    Write-Host "  Sysprep cancelled. Run the script again when ready." -ForegroundColor Gray
}
