#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Phase 1 – On-premises Active Directory preparation for AVD.
.DESCRIPTION
    Creates the AVD OU structure, security group, domain join service account,
    and baseline GPO. Run from a domain-joined machine with RSAT installed and
    Domain Admin (or delegated) rights.
.NOTES
    Steps covered: 1–8 from the deployment plan.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 1: On-Premises AD Preparation ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Step 1 – Create OU for AVD session host computers
# -----------------------------------------------------------------------------
Write-Host "`n[Step 1] Creating OU for AVD session hosts: $OuSessionHosts" -ForegroundColor Yellow
$parentOu = ($OuSessionHosts -replace '^OU=[^,]+,', '')
$ouName   = ($OuSessionHosts -replace '^OU=([^,]+),.+$', '$1')

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OuSessionHosts'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $ouName -Path $parentOu -ProtectedFromAccidentalDeletion $true
    Write-Host "  Created: $OuSessionHosts" -ForegroundColor Green
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 2 – Create OU for AVD users (optional — users can stay in their current OU)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 2] Creating OU for AVD users: $OuAvdUsers" -ForegroundColor Yellow
$parentOuUsers = ($OuAvdUsers -replace '^OU=[^,]+,', '')
$ouNameUsers   = ($OuAvdUsers -replace '^OU=([^,]+),.+$', '$1')

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OuAvdUsers'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $ouNameUsers -Path $parentOuUsers -ProtectedFromAccidentalDeletion $true
    Write-Host "  Created: $OuAvdUsers" -ForegroundColor Green
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 3 – Create security group for AVD users
# -----------------------------------------------------------------------------
Write-Host "`n[Step 3] Creating security group: $AdGroupAvdUsers" -ForegroundColor Yellow
if (-not (Get-ADGroup -Filter "Name -eq '$AdGroupAvdUsers'" -ErrorAction SilentlyContinue)) {
    New-ADGroup `
        -Name           $AdGroupAvdUsers `
        -GroupScope     Global `
        -GroupCategory  Security `
        -Path           $OuAvdUsers `
        -Description    "Members have access to AVD RemoteApps and Desktop"
    Write-Host "  Created group: $AdGroupAvdUsers" -ForegroundColor Green
    Write-Host "  ACTION REQUIRED: Add all 25 users to this group in AD Users and Computers." -ForegroundColor Magenta
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 4 – Create domain join service account
# -----------------------------------------------------------------------------
Write-Host "`n[Step 4] Creating domain join service account: $DomainJoinAccount" -ForegroundColor Yellow
if (-not (Get-ADUser -Filter "SamAccountName -eq '$DomainJoinAccount'" -ErrorAction SilentlyContinue)) {
    $svcPassword = Read-Host -Prompt "  Enter password for $DomainJoinAccount" -AsSecureString
    New-ADUser `
        -Name              $DomainJoinAccount `
        -SamAccountName    $DomainJoinAccount `
        -UserPrincipalName $DomainJoinUPN `
        -Path              "OU=Service Accounts,$AdDomainDN" `
        -AccountPassword   $svcPassword `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true `
        -Enabled           $true `
        -Description       "AVD session host domain join account — do not delete"
    Write-Host "  Created: $DomainJoinUPN" -ForegroundColor Green
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

# Grant the service account the right to join computers to the AVD OU
# This delegates "Create Computer objects" and "Delete Computer objects" on the AVD OU
Write-Host "  Delegating computer join rights on the AVD OU..." -ForegroundColor Yellow
$svcAccountSid = (Get-ADUser $DomainJoinAccount).SID

$ouPath = "AD:\$OuSessionHosts"
$acl    = Get-Acl -Path $ouPath

# GUID for "Create Computer objects"
$createComputerGuid = [Guid]"bf967a86-0de6-11d0-a285-00aa003049e2"
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $svcAccountSid,
    [System.DirectoryServices.ActiveDirectoryRights]::CreateChild,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $createComputerGuid,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
)
$acl.AddAccessRule($ace)
Set-Acl -Path $ouPath -AclObject $acl
Write-Host "  Delegation set on: $OuSessionHosts" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Steps 5-6 – Entra Connect verification (manual — cannot be automated here)
# -----------------------------------------------------------------------------
Write-Host "`n[Steps 5-6] Entra Connect – MANUAL VERIFICATION REQUIRED" -ForegroundColor Magenta
Write-Host "  Open Azure AD Connect on the Entra Connect server and confirm:"
Write-Host "  1. Sync scope includes: $OuSessionHosts"
Write-Host "  2. Sync scope includes the OU where AVD users live"
Write-Host "  3. Device writeback is ENABLED"
Write-Host "     (Azure AD Connect > Configure > Configure device options > Enable device writeback)"

# -----------------------------------------------------------------------------
# Step 7 – Citrix GPO audit reminder
# -----------------------------------------------------------------------------
Write-Host "`n[Step 7] Citrix GPO audit – MANUAL ACTION REQUIRED" -ForegroundColor Magenta
Write-Host "  Review existing Citrix GPOs. DO NOT link Citrix GPOs to the AVD OU."
Write-Host "  Safe to reuse: RDP settings, drive mappings, printer redirection, time zone, wallpaper."
Write-Host "  Must NOT use: Citrix Receiver/Workspace policies, ICA settings, Citrix profile policies."

# -----------------------------------------------------------------------------
# Step 8 – Create GPO for the AVD OU
# -----------------------------------------------------------------------------
Write-Host "`n[Step 8] Creating AVD baseline GPO..." -ForegroundColor Yellow
$gpoName = "AVD - Session Host Policy"
if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $gpoName -Comment "AVD session host settings - FSLogix configured via 07-fslogix-gpo.ps1"
    New-GPLink -Name $gpoName -Target $OuSessionHosts -LinkEnabled Yes | Out-Null
    Write-Host "  GPO created and linked to: $OuSessionHosts" -ForegroundColor Green
    Write-Host "  GPO ID: $($gpo.Id)" -ForegroundColor Gray
} else {
    Write-Host "  GPO '$gpoName' already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Step 8a-i – Enable Microsoft Entra authentication for RDP (one-time per tenant)
# -----------------------------------------------------------------------------
# Enables the Windows Cloud Login service principal to issue RDP access tokens.
# Required role: Application Administrator or Cloud Application Administrator.
# Run from any machine with PowerShell or Azure Cloud Shell.
# -----------------------------------------------------------------------------
Write-Host "`n[Step 8a-i] Enabling Microsoft Entra RDP authentication (Windows Cloud Login SP)..." -ForegroundColor Yellow
Write-Host "  Required Entra role: Application Administrator or Cloud Application Administrator" -ForegroundColor Gray

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "  Installing Microsoft.Graph module..." -ForegroundColor Gray
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Write-Host "  Connecting to Microsoft Graph — sign in with an Application Administrator account..." -ForegroundColor Yellow
Connect-MgGraph -Scopes "Application.Read.All","Application-RemoteDesktopConfig.ReadWrite.All"

$WCLspId = (Get-MgServicePrincipal -Filter "AppId eq '270efc09-cd0d-444b-a71f-39af4910ec45'").Id
if (-not $WCLspId) {
    Write-Warning "  Windows Cloud Login service principal not found. Verify the tenant is correct."
} else {
    $rdpConfig = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId -ErrorAction SilentlyContinue
    if ($rdpConfig.IsRemoteDesktopProtocolEnabled -eq $true) {
        Write-Host "  RDP already enabled on Windows Cloud Login SP. Skipping." -ForegroundColor Gray
    } else {
        Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId -IsRemoteDesktopProtocolEnabled
        Write-Host "  RDP authentication enabled on Windows Cloud Login service principal." -ForegroundColor Green
    }
    $verify = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId
    Write-Host "  Verified IsRemoteDesktopProtocolEnabled: $($verify.IsRemoteDesktopProtocolEnabled)" -ForegroundColor $(if ($verify.IsRemoteDesktopProtocolEnabled) { "Green" } else { "Red" })
}

# -----------------------------------------------------------------------------
# Step 8a-ii – Create Kerberos Server Object (one-time per domain)
# -----------------------------------------------------------------------------
# Required for hybrid joined session hosts to authenticate via Kerberos SSO.
# Required Entra role: Hybrid Identity Administrator (NOT Global Admin).
# Required on-prem: Domain Admin.
# Run from a domain-joined machine.
# -----------------------------------------------------------------------------
Write-Host "`n[Step 8a-ii] Creating Microsoft Entra Kerberos server object..." -ForegroundColor Yellow
Write-Host "  Required Entra role: Hybrid Identity Administrator" -ForegroundColor Gray
Write-Host "  Required on-prem:    Domain Admin" -ForegroundColor Gray

if (-not (Get-Module -ListAvailable -Name AzureADHybridAuthenticationManagement)) {
    Write-Host "  Installing AzureADHybridAuthenticationManagement module..." -ForegroundColor Gray
    Install-Module -Name AzureADHybridAuthenticationManagement -Force -AllowClobber
}
Import-Module AzureADHybridAuthenticationManagement

$hybridAdminUpn = Read-Host "  Entra ID Hybrid Identity Administrator UPN (e.g. hybridadmin@contoso.com)"
$existingKerberos = Get-AzureADKerberosServer -Domain $AdDomain `
    -UserPrincipalName $hybridAdminUpn -ErrorAction SilentlyContinue

if ($existingKerberos -and $existingKerberos.CloudId) {
    Write-Host "  Kerberos server object already exists (CloudId: $($existingKerberos.CloudId)). Skipping." -ForegroundColor Gray
} else {
    $domainCred = Get-Credential -Message "Domain Admin credentials for $AdDomain"
    Set-AzureADKerberosServer `
        -Domain            $AdDomain `
        -UserPrincipalName $hybridAdminUpn `
        -DomainCredential  $domainCred
    Write-Host "  Kerberos server object created. Verify AzureADKerberos exists in CN=Computers in ADUC." -ForegroundColor Green
    Write-Host "  Next: Enable SSO on the host pool — portal-guide.md Step 47a." -ForegroundColor Gray
}

Write-Host "`n=== Phase 1 Complete ===" -ForegroundColor Cyan
Write-Host "Next step: Run 02-check-prereqs.ps1 from any machine with Az module installed." -ForegroundColor White
