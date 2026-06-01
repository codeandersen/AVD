#Requires -Modules GroupPolicy, ActiveDirectory
<#
.SYNOPSIS
    Phase 7 – Configure FSLogix profile container settings via Group Policy.
.DESCRIPTION
    Copies FSLogix ADMX templates to the central policy store and configures
    the 'AVD - Session Host Policy' GPO with all required FSLogix settings.

    MUST be run from a domain-joined machine with:
      - RSAT Group Policy Management (gpmc) installed
      - FSLogix installed locally (or ADMX files manually copied beforehand)
      - Domain Admin rights (or delegated GPO edit rights)
.NOTES
    Steps covered: 52–56 from the deployment plan.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FslogixAdmxSourcePath = "C:\Program Files\FSLogix\Apps\PolicyDefinitions"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

$GpoName      = "AVD - Session Host Policy"
$SysvolRoot   = "\\$AdDomain\SYSVOL\$AdDomain\Policies\PolicyDefinitions"
# FSLogix VHD path points to the active entity subfolder, not the share root
$UncPath      = "\\$StorageAccountName.file.core.windows.net\$FileShareName\$FslogixActiveEntity"

Write-Host "`n=== Phase 7: FSLogix GPO Configuration ===" -ForegroundColor Cyan

# Verify domain access
try {
    Get-ADDomain | Out-Null
    Write-Host "Connected to domain: $AdDomain" -ForegroundColor Gray
} catch {
    Write-Error "Cannot connect to Active Directory. Run this script from a domain-joined machine."
}

# Verify the GPO exists
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    Write-Error "GPO '$GpoName' not found. Run 01-ad-prep.ps1 first to create and link the GPO."
}
Write-Host "Found GPO: '$GpoName' (ID: $($gpo.Id))" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# Step 52 – Copy FSLogix ADMX templates to central policy store
# -----------------------------------------------------------------------------
Write-Host "`n[Step 52] Copying FSLogix ADMX templates to central policy store..." -ForegroundColor Yellow
Write-Host "  Source: $FslogixAdmxSourcePath"
Write-Host "  Destination: $SysvolRoot"

# Check source exists (FSLogix must be installed locally, or provide path to extracted files)
if (-not (Test-Path $FslogixAdmxSourcePath)) {
    Write-Warning "  FSLogix PolicyDefinitions folder not found at: $FslogixAdmxSourcePath"
    Write-Warning "  Options:"
    Write-Warning "  1. Install FSLogix on this machine first (https://aka.ms/fslogix-latest)"
    Write-Warning "  2. Copy the PolicyDefinitions folder from the build VM"
    Write-Warning "  3. Re-run this script with -FslogixAdmxSourcePath pointing to the extracted files"

    $altPath = Read-Host "  Enter alternate path to FSLogix PolicyDefinitions folder (or press Enter to skip)"
    if ($altPath -and (Test-Path $altPath)) {
        $FslogixAdmxSourcePath = $altPath
    } else {
        Write-Host "  Skipping ADMX copy — configure manually if templates are not yet in SYSVOL." -ForegroundColor Yellow
    }
}

if (Test-Path $FslogixAdmxSourcePath) {
    # Create destination if it doesn't exist
    if (-not (Test-Path $SysvolRoot)) {
        New-Item -ItemType Directory -Path $SysvolRoot -Force | Out-Null
    }

    # Copy .admx file
    $admxFile = Get-ChildItem -Path $FslogixAdmxSourcePath -Filter "fslogix.admx" -ErrorAction SilentlyContinue
    if ($admxFile) {
        Copy-Item -Path $admxFile.FullName -Destination $SysvolRoot -Force
        Write-Host "  Copied: fslogix.admx" -ForegroundColor Green
    }

    # Copy .adml file (language-specific)
    $admlFile = Get-ChildItem -Path "$FslogixAdmxSourcePath\en-US" -Filter "fslogix.adml" -ErrorAction SilentlyContinue
    if ($admlFile) {
        $admlDest = "$SysvolRoot\en-US"
        if (-not (Test-Path $admlDest)) { New-Item -ItemType Directory -Path $admlDest -Force | Out-Null }
        Copy-Item -Path $admlFile.FullName -Destination $admlDest -Force
        Write-Host "  Copied: en-US\fslogix.adml" -ForegroundColor Green
    }

    if (-not $admxFile -and -not $admlFile) {
        Write-Warning "  FSLogix ADMX/ADML files not found in '$FslogixAdmxSourcePath'"
    }
}

# -----------------------------------------------------------------------------
# Steps 53-55 – Configure FSLogix GPO settings via registry-based policy
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 53-55] Configuring FSLogix GPO settings..." -ForegroundColor Yellow
Write-Host "  Target GPO : $GpoName"
Write-Host "  VHD Path   : $UncPath"
Write-Host "  Profile Size: $FslogixProfileSizeMB MB"

# FSLogix registry settings are applied under Computer Configuration
# HKLM\SOFTWARE\FSLogix\Profiles
$fslogixRegistryPath = "HKLM\SOFTWARE\FSLogix\Profiles"

# Helper function to set a GPO registry value
function Set-GpoRegistryValue {
    param(
        [string]$GpoName,
        [string]$Key,
        [string]$ValueName,
        [string]$Type,
        $Value
    )
    Set-GPRegistryValue `
        -Name      $GpoName `
        -Key       $Key `
        -ValueName $ValueName `
        -Type      $Type `
        -Value     $Value `
        -ErrorAction Stop | Out-Null
    Write-Host "  Set: $ValueName = $Value" -ForegroundColor Green
}

# FSLogix Profile Container settings
$settings = @(
    @{ Name = "Enabled";                            Type = "DWord";  Value = 1 },
    @{ Name = "VHDLocations";                       Type = "MultiString"; Value = $UncPath },
    @{ Name = "DeleteLocalProfileWhenVHDShouldApply"; Type = "DWord"; Value = 1 },
    @{ Name = "VolumeType";                         Type = "String"; Value = "VHDX" },
    @{ Name = "SizeInMBs";                          Type = "DWord";  Value = $FslogixProfileSizeMB },
    @{ Name = "IsFltEnabled";                       Type = "DWord";  Value = 1 },
    @{ Name = "PreventLoginWithFailure";             Type = "DWord";  Value = 1 },
    @{ Name = "PreventLoginWithTempProfile";         Type = "DWord";  Value = 1 },
    @{ Name = "ProfileType";                        Type = "DWord";  Value = 0 },  # 0 = Read-write profile
    @{ Name = "ReAttachIntervalSeconds";             Type = "DWord";  Value = 15 },
    @{ Name = "ReAttachRetryCount";                 Type = "DWord";  Value = 3 }
)

foreach ($setting in $settings) {
    try {
        Set-GpoRegistryValue `
            -GpoName    $GpoName `
            -Key        $fslogixRegistryPath `
            -ValueName  $setting.Name `
            -Type       $setting.Type `
            -Value      $setting.Value
    } catch {
        Write-Warning "  Failed to set '$($setting.Name)': $_"
    }
}

# Office 365 Container (keeps Outlook cache in the FSLogix container too)
Write-Host "`n  Configuring Office 365 Container (Outlook cache)..." -ForegroundColor Gray
$o365Path = "HKLM\SOFTWARE\Policies\FSLogix\ODFC"
$o365Settings = @(
    @{ Name = "Enabled";          Type = "DWord"; Value = 1 },
    @{ Name = "VHDLocations";     Type = "MultiString"; Value = $UncPath },
    @{ Name = "VolumeType";       Type = "String"; Value = "VHDX" },
    @{ Name = "SizeInMBs";        Type = "DWord";  Value = 30720 },
    @{ Name = "IncludeOneDrive";  Type = "DWord";  Value = 0 },   # Exclude OneDrive (it syncs itself)
    @{ Name = "IncludeOutlook";   Type = "DWord";  Value = 1 },
    @{ Name = "IncludeTeams";     Type = "DWord";  Value = 1 }
)

foreach ($setting in $o365Settings) {
    try {
        Set-GpoRegistryValue `
            -GpoName    $GpoName `
            -Key        $o365Path `
            -ValueName  $setting.Name `
            -Type       $setting.Type `
            -Value      $setting.Value
    } catch {
        Write-Warning "  Failed to set O365 '$($setting.Name)': $_"
    }
}

# -----------------------------------------------------------------------------
# Step 56 – Force GPO update and verify
# -----------------------------------------------------------------------------
Write-Host "`n[Step 56] Verifying GPO on session hosts..." -ForegroundColor Yellow
Write-Host "  Run the following on each session host to verify GPO is applied:" -ForegroundColor White
Write-Host ""
Write-Host @"
  # Run on avd-sh-0 or avd-sh-1:
  Invoke-Command -ComputerName "$SessionHostPrefix-0","$SessionHostPrefix-1" -ScriptBlock {
      gpupdate /force
      gpresult /scope computer /r | Select-String -Pattern 'AVD','FSLogix','Applied'
  }
"@ -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Expected output: '$GpoName' listed under 'Applied Group Policy Objects'" -ForegroundColor Gray

# Attempt remote GPO update if WinRM is available
Write-Host "`n  Attempting remote gpupdate on session hosts (requires WinRM)..." -ForegroundColor Gray
for ($i = 0; $i -lt $SessionHostCount; $i++) {
    $hostName = "$SessionHostPrefix-$i"
    try {
        Invoke-Command -ComputerName $hostName -ScriptBlock { gpupdate /force } -ErrorAction Stop | Out-Null
        Write-Host "  gpupdate complete on $hostName" -ForegroundColor Green
    } catch {
        Write-Host "  Could not reach $hostName via WinRM — run gpupdate manually." -ForegroundColor Yellow
    }
}

Write-Host "`n=== Phase 7 Complete ===" -ForegroundColor Cyan
Write-Host "Next step: Run 08-appgroups.ps1 from any machine." -ForegroundColor White
