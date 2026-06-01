# AVD Portal Guide – Step by Step
## Do everything (or as much as possible) through the Azure Portal

> **Note:** Steps marked 🖥️ must be done on a domain-joined machine (cannot be done in the portal).
> Steps marked ☁️ are done entirely in the Azure Portal.
> Steps marked 📋 are manual AD tasks done in Active Directory Users and Computers.

---

## Before You Start – Required Roles

Make sure the right accounts are available **before** starting. Some steps need different roles — using an account with too many permissions is a security risk, and using one with too few will fail silently.

| Step | Task | Required Role / Permission |
|---|---|---|
| Steps 1–8 | Create OUs, groups, GPOs in Active Directory | **Domain Admin** (on-prem) |
| Step 4 | Delegate computer join rights | **Domain Admin** (on-prem) |
| Step 5–6 | Entra Connect sync configuration | **Hybrid Identity Administrator** (Entra) |
| Step 8a-i | Enable RDP auth on Windows Cloud Login SP | **Application Administrator** or **Cloud Application Administrator** (Entra) |
| Step 8a-ii | Create Kerberos server object | **Hybrid Identity Administrator** (Entra) + **Domain Admin** (on-prem) |
| Steps 9–12 | Check quotas, register providers | **Contributor** or **Owner** on Azure subscription |
| Steps 13–21 | Create resource groups, VNet, NSG | **Contributor** or **Owner** on Azure subscription |
| Steps 22–28 | Create storage account, AD-join it, set RBAC | **Contributor** (Azure) + **Domain Admin** (on-prem, for AD join) |
| Steps 30–42 | Create gallery, deploy and capture build VM | **Contributor** or **Owner** on Azure subscription |
| Steps 43–47 | Create host pool and session hosts | **Desktop Virtualization Contributor** or **Owner** |
| Step 47a | Enable SSO RDP property on host pool | **Desktop Virtualization Host Pool Contributor** or higher |
| Steps 52–56 | Configure FSLogix GPO | **Group Policy Creator Owners** or **Domain Admin** (on-prem) |
| Steps 57–63 | Create app groups, workspace, assign users | **Desktop Virtualization Contributor** or **Owner** |
| Steps 74–76 | Create Log Analytics workspace, alerts | **Contributor** on resource group or **Monitoring Contributor** |

> **Tip:** For a real deployment, create a dedicated service account per role rather than using one admin account for everything. The domain join account (`svc-avd-domainjoin`) is already planned for that purpose.

---

## Before You Start – What You Need Open

- Azure Portal: https://portal.azure.com
- Microsoft Entra Admin Center: https://entra.microsoft.com
- A domain-joined Windows machine (for AD steps and FSLogix AD join)
- RDP access to the build VM (for image creation)

---

## Phase 1 – On-Premises AD Preparation 🖥️

> Run these on a domain-joined machine with RSAT installed (Active Directory Users and Computers).

### Step 1 – Create OU for session hosts
1. Open **Active Directory Users and Computers** (`dsa.msc`)
2. Right-click your domain root → **New** → **Organizational Unit**
3. Name it `AVD` (or `AVD-Servers`) → check **Protect from accidental deletion** → OK
4. This is where your session host VMs will be placed when they join the domain

### Step 2 – Create security group for AVD users
1. In ADUC, navigate to an appropriate OU (e.g. `Users`)
2. Right-click → **New** → **Group**
3. Group name: `GRP-AVD-Users`
4. Group scope: **Global** | Group type: **Security** → OK
5. Right-click the new group → **Properties** → **Members** tab → **Add** → add all 25 users

### Step 3 – Create domain join service account
1. In ADUC, navigate to a `Service Accounts` OU (or create one)
2. Right-click → **New** → **User**
3. Full name: `svc-avd-domainjoin` | User logon name: `svc-avd-domainjoin` → Next
4. Set a strong password → uncheck **User must change password** → check **Password never expires** → Next → Finish

### Step 4 – Delegate computer join rights to the service account
1. In ADUC, right-click the `AVD` OU you created in Step 1
2. Click **Delegate Control…** → Next
3. Click **Add** → type `svc-avd-domainjoin` → OK → Next
4. Select **Create a custom task to delegate** → Next
5. Select **Only the following objects** → check **Computer objects** → check **Create selected objects in this folder** → Next
6. Check **General** → check **Read** and **Write** → Next → Finish

### Step 5 – Verify Entra Connect sync scope 🖥️
1. On the **Entra Connect server**, open **Microsoft Entra Connect**
2. Click **Configure** → **Customize synchronization options** → Next → sign in → Next
3. On the **Domain/OU Filtering** page, verify that:
   - The OU containing your AVD session hosts (`AVD`) is **checked**
   - The OU containing your 25 users is **checked**
4. Finish / exit without changing anything if it's already correct

### Step 6 – Enable Device Writeback in Entra Connect 🖥️
1. On the Entra Connect server, open **Microsoft Entra Connect**
2. Click **Configure** → **Configure device options** → Next
3. Select **Configure Hybrid Azure AD join** → Next
4. Ensure **Device writeback** is enabled → configure if not → Finish
5. Force a sync: open PowerShell and run:
   ```powershell
   Start-ADSyncSyncCycle -PolicyType Delta
   ```

### Step 7 – Review Citrix GPOs 📋
1. Open **Group Policy Management** (`gpmc.msc`)
2. Browse to the OUs currently linked to Citrix servers
3. For each GPO, note: is it Citrix-specific (ICA, Receiver, Workspace policies) or generic (drive maps, printers, time zone)?
4. Generic GPOs can be relinked to the AVD OU later. Do NOT link Citrix-specific GPOs to AVD.

### Step 8 – Create AVD baseline GPO 📋
1. In **Group Policy Management**, right-click your domain → **Create a GPO in this domain** 
2. Name it `AVD - Session Host Policy` → OK
3. Right-click the `AVD` OU → **Link an Existing GPO** → select `AVD - Session Host Policy` → OK
4. Leave it empty for now — FSLogix settings will be added in Phase 7

### Step 8a – Enable Entra ID SSO for AVD (two sub-steps) 🖥️

> This eliminates the **second password prompt** when connecting via the Windows App. Two things must be done: enable RDP auth on the Entra tenant (once per tenant), then create a Kerberos server object (once per domain).

#### Step 8a-i – Enable Microsoft Entra authentication for RDP ☁️

**What it does:** Enables the `Windows Cloud Login` Entra ID service principal to issue RDP access tokens. Without this, the host pool SSO setting has no effect.

**Required role:** **Application Administrator** or **Cloud Application Administrator** (not Global Admin)

**Run from:** Any machine with PowerShell, or Azure Cloud Shell

1. Install the Microsoft Graph PowerShell SDK if not already present:
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser -Force
   ```
2. Import modules and connect (you will be prompted to sign in with an Application Administrator account):
   ```powershell
   Import-Module Microsoft.Graph.Authentication
   Import-Module Microsoft.Graph.Applications
   Connect-MgGraph -Scopes "Application.Read.All","Application-RemoteDesktopConfig.ReadWrite.All"
   ```
3. Get the `Windows Cloud Login` service principal and enable RDP on it:
   ```powershell
   $WCLspId = (Get-MgServicePrincipal -Filter "AppId eq '270efc09-cd0d-444b-a71f-39af4910ec45'").Id

   If ((Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId).IsRemoteDesktopProtocolEnabled -ne $true) {
       Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId -IsRemoteDesktopProtocolEnabled
   }
   ```
4. Verify:
   ```powershell
   Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $WCLspId
   ```
   Output must show `IsRemoteDesktopProtocolEnabled : True`

> **Note:** This is a **one-time per Entra tenant** setting — not per host pool or per customer deployment.

#### Step 8a-ii – Create Kerberos Server Object 🖥️

**What it does:** Required for hybrid joined session hosts to complete Kerberos authentication to the on-prem domain controller via SSO.

**Required roles:**
- Entra ID: **Hybrid Identity Administrator** (not Global Admin)
- On-premises: **Domain Admin**

**Run from:** Domain-joined machine

1. Install the module:
   ```powershell
   Install-Module -Name AzureADHybridAuthenticationManagement -Force
   ```
2. Create the Kerberos server object (prompts for credentials):
   ```powershell
   Set-AzureADKerberosServer `
     -Domain "contoso.local" `
     -UserPrincipalName "hybridadmin@contoso.com" `
     -DomainCredential (Get-Credential -Message "Domain Admin credentials for contoso.local")
   ```
3. Verify:
   ```powershell
   Get-AzureADKerberosServer -Domain "contoso.local" -UserPrincipalName "hybridadmin@contoso.com"
   ```
   You should see a `CloudId` value returned.
4. In ADUC, confirm a computer object named `AzureADKerberos` exists in `CN=Computers`

> **Note:** One per domain — not per host pool.

---

## Phase 2 – Azure Prerequisites ☁️

### Step 9 – Check VM quota in Denmark East
1. In the Azure Portal, search for **Quotas** in the top search bar → open **Quotas**
2. Select **Compute** → filter by location: **Denmark East**
3. Search for `Standard DSv5 Family vCPUs` → check **Current usage** vs **Limit**
4. You need at least **8 vCPUs** available (2× D4s_v5 = 8 cores) or **16** for D8s_v5
5. If below limit: click the quota → **Request increase** → set new limit → Submit

### Step 10 – Register AVD resource provider
1. In the Portal, go to **Subscriptions** → click your subscription
2. In the left menu: **Resource providers**
3. Search for `Microsoft.DesktopVirtualization`
4. If status is not **Registered**: click it → click **Register** at the top
5. Refresh every 30 seconds until it shows **Registered**

### Step 11 – Verify user licensing ☁️
1. Go to https://admin.microsoft.com → **Users** → **Active users**
2. Click on a sample user → **Licenses and apps** tab
3. Confirm **Microsoft 365 E3** (or E5 / Business Premium) is listed and assigned
4. Repeat spot-check for a few users, or use **Licenses** page to see total assigned counts

### Step 12 – Verify VPN is active ☁️
1. In the Portal, go to **Virtual network gateways** (or **VPN Gateways**)
2. Find the existing VPN gateway → **Connections** → check status shows **Connected**
3. If no VPN gateway exists in Denmark East yet: the existing one in another region must have routing to Denmark East added — discuss with network team

---

## Phase 3 – Networking ☁️

### Step 13 – Create Both Resource Groups

> Two RGs keep session host VMs isolated from AVD service objects. When you need to rebuild hosts, you can delete `rg-contoso-avd-hosts` without touching your host pool config, workspaces, or storage.

**First — Infra RG** (VNet, NSG, Storage, Gallery, Host Pool, Workspace, Monitoring):
1. Portal → search **Resource groups** → **+ Create**
2. Subscription: your subscription
3. Resource group name: `rg-contoso-avd-avdresources`
4. Region: **Denmark East**
5. Tags: `Project = AVD`, `Environment = Production`, `Role = Infrastructure`
6. **Review + Create** → **Create**

**Second — Hosts RG** (Session host VMs, NICs, OS disks):
7. **+ Create** again
8. Resource group name: `rg-contoso-avd-hosts`
9. Region: **Denmark East**
10. Tags: `Project = AVD`, `Environment = Production`, `Role = SessionHosts`
11. **Review + Create** → **Create**

### Step 14-16 – Create Virtual Network with custom DNS
1. Portal → search **Virtual networks** → **+ Create**
2. **Basics tab:**
   - Resource group: `rg-contoso-avd-avdresources`
   - Name: `vnet-contoso-dke`
   - Region: **Denmark East**
3. **IP Addresses tab:**
   - IPv4 address space: `10.10.0.0/16` *(adjust if it overlaps your on-prem network)*
   - Delete the default subnet
   - Click **+ Add a subnet**:
     - Subnet name: `snet-contoso-avd`
     - Starting address: `10.10.1.0`
     - Subnet size: `/24`
     - Click **Add**
4. **Security tab:** leave defaults for now (NSG added next)
5. **Review + Create** → **Create**

> **After creation — set custom DNS (critical for hybrid join):**
6. Go to the new VNet → left menu: **DNS servers**
7. Select **Custom**
8. Add your on-prem DC IP addresses (e.g. `10.0.0.10`, `10.0.0.11`)
9. Click **Save**

### Step 17-18 – Create NSG and attach to subnet
1. Portal → search **Network security groups** → **+ Create**
2. Resource group: `rg-contoso-avd-avdresources`
3. Name: `nsg-contoso-avd`
4. Region: **Denmark East**
5. **Review + Create** → **Create**

**Add inbound security rule (allow AVD service tag):**
6. Open the new NSG → **Inbound security rules** → **+ Add**
   - Source: `Service Tag`
   - Source service tag: `WindowsVirtualDesktop`
   - Destination port ranges: `3389`
   - Protocol: `TCP`
   - Action: **Allow**
   - Priority: `100`
   - Name: `Allow-AVD-ServiceTag-RDP`
   - → **Add**

**Add deny rule (block internet RDP):**
7. **+ Add** again:
   - Source: `Service Tag` → Source service tag: `Internet`
   - Destination port ranges: `3389`
   - Protocol: `TCP`
   - Action: **Deny**
   - Priority: `200`
   - Name: `Deny-RDP-Internet`
   - → **Add**

**Attach NSG to the subnet:**
8. Go to NSG → **Subnets** → **+ Associate**
9. Virtual network: `vnet-contoso-dke` → Subnet: `snet-contoso-avd` → **OK**

### Steps 19-21 – Test VPN routing (test VM)
1. Portal → **Virtual machines** → **+ Create** → **Azure virtual machine**
2. Resource group: `rg-contoso-avd-hosts` | Name: `avd-test-vm` | Region: **Denmark East**
3. Image: `Windows Server 2022` | Size: `Standard_B2s`
4. Set admin username/password → **Inbound ports**: RDP
5. **Networking tab**: VNet `vnet-contoso-dke`, Subnet `snet-contoso-avd`
6. **Review + Create** → **Create**
7. RDP into the test VM once it's running
8. Inside the VM, open PowerShell and run:
   ```powershell
   ping 10.0.0.10          # Replace with your on-prem DC IP — must reply
   nslookup contoso.local  # Replace with your domain — must return DC IP
   ```
9. If both succeed: **delete this VM** (Portal → VM → Delete, check "delete disk" and "delete NIC")
10. If they fail: VPN routing is not working — stop here and fix before continuing

---

## Phase 4 – Azure Files + FSLogix Storage

### Step 22-23 – Create Storage Account and File Share ☁️
1. Portal → search **Storage accounts** → **+ Create**
2. **Basics tab:**
   - Resource group: `rg-contoso-avd-avdresources`
   - Storage account name: `stacontosoprofiles` *(must be globally unique, all lowercase)*
   - Region: **Denmark East**
   - Performance: **Standard**
   - Redundancy: **Locally-redundant storage (LRS)**
3. Leave other tabs as default
4. **Review + Create** → **Create**

**Create the file share:**
5. Open the storage account → left menu: **File shares** → **+ File share**
6. Name: `fslogix-profiles`
7. Tier: **Transaction optimized**
8. Quota: `1024` GB (1 TB — can increase later)
9. → **Create**

### Step 24-26 – Enable AD Authentication on Storage Account 🖥️

> This **must** be done from a domain-joined machine. Cannot be done through the Portal alone.

1. On a domain-joined machine, open PowerShell as Administrator
2. Install the AzFilesHybrid module:
   ```powershell
   # Download from: https://github.com/Azure-Samples/azure-files-samples/releases
   # Extract the zip, then run:
   cd C:\AzFilesHybrid
   .\CopyToPSPath.ps1
   Import-Module AzFilesHybrid
   ```
3. Connect to Azure:
   ```powershell
   Connect-AzAccount
   Set-AzContext -SubscriptionId "YOUR-SUBSCRIPTION-ID"
   ```
4. Join the storage account to your domain:
   ```powershell
   Join-AzStorageAccountForAuth `
     -ResourceGroupName "rg-contoso-avd-avdresources" `
     -StorageAccountName "stacontosoprofiles" `
     -DomainAccountType "ComputerAccount" `
     -OrganizationalUnitDistinguishedName "OU=AVD,OU=Servers,DC=contoso,DC=local"
   ```
5. Verify it worked:
   - In Azure Portal → Storage Account → **Configuration** → scroll to **Active Directory** — should show your domain
   - In ADUC, you should see `stacontosoprofiles` as a computer object in the AVD OU

### Step 27 – Set share-level RBAC ☁️
1. Portal → Storage account `stacontosoprofiles` → **File shares** → click `fslogix-profiles`
2. Left menu: **Access Control (IAM)** → **+ Add** → **Add role assignment**
3. Role: `Storage File Data SMB Share Contributor`
4. Assign access to: **User, group, or service principal**
5. Select: `GRP-AVD-Users` (the AD group you created in Phase 1)
6. → **Review + Assign**

### Step 28 – Create Entity Subfolders + Set NTFS Permissions 🖥️

> The share uses a subfolder per company entity. Each subfolder has its own NTFS permissions scoped to that entity's AD group. The FSLogix GPO points to the subfolder, not the share root.

**Folder layout:**
```
fslogix-profiles\
  contosogrp\  ← Contoso Group  (GRP-AVD-Users)
  contosode\     ← Contoso Germany          (GRP-ContosoDE-AVD-Users)
```

1. On a domain-joined machine, map the share root:
   ```powershell
   net use Z: \\stacontosoprofiles.file.core.windows.net\fslogix-profiles /persistent:no
   ```
   *(Credentials: username `AZURE\stacontosoprofiles`, password = storage account key from Portal → Access keys)*

**On the share root (Z:\):**
2. Right-click `Z:` → **Properties** → **Security** → **Advanced**
3. **Disable inheritance** → Convert to explicit
4. Keep only `SYSTEM` and `Administrators` (Full Control)
5. Add each entity AD group with **Traverse folder / execute file** only, **This folder only** (no inheritance)
   - `GRP-AVD-Users` → Traverse — This folder only
   - `GRP-ContosoDE-AVD-Users` → Traverse — This folder only
6. Click **Apply**

**Create and secure the `contosogrp` subfolder:**
7. Create folder: `Z:\contosogrp`
8. Right-click `Z:\contosogrp` → **Properties** → **Security** → **Advanced**
9. **Disable inheritance** → Remove inherited entries
10. Add `CREATOR OWNER` → **Full Control** → **Subfolders and files only**
11. Add `GRP-AVD-Users`:
    - **Traverse folder / execute file** + **List folder** + **Create folders** → **This folder only**
12. Click **Apply**

**Create and secure the `contosode` subfolder:**
13. Create folder: `Z:\contosode`
14. Repeat steps 8–12 but use `GRP-ContosoDE-AVD-Users` instead of `GRP-AVD-Users`

15. Disconnect the mapped drive:
    ```powershell
    net use Z: /delete
    ```

> **FSLogix VHD Location** for `hp-contosogrp`: `\\stacontosoprofiles.file.core.windows.net\fslogix-profiles\contosogrp`
> When deploying a new entity (e.g. Contoso Germany), create a new host pool and point its GPO to `...\contosode`

---

## Phase 5 – Golden Image

### Step 30-31 – Create Azure Compute Gallery ☁️
1. Portal → search **Azure Compute Gallery** → **+ Create**
2. Resource group: `rg-contoso-avd-avdresources`
3. Gallery name: `acg_contoso_avd` *(underscores only, no hyphens)*
4. Region: **Denmark East**
5. **Review + Create** → **Create**

**Create Image Definition:**
6. Open the gallery → **+ Add** → **VM image definition**
7. Image definition name: `Win11-MultiSession-M365`
8. OS type: **Windows**
9. VM generation: **Gen 2**
10. Operating system state: **Generalized**
11. Publisher: `Contoso` (or your company name)
12. Offer: `AVD`
13. SKU: `Win11-MS`
14. → **Review + Create** → **Create**

### Step 32 – Deploy Image Build VM ☁️
1. Portal → **Virtual machines** → **+ Create** → **Azure virtual machine**
2. **Basics:**
   - Resource group: `rg-contoso-avd-hosts` *(build VM is temporary compute — goes in hosts RG)*
   - VM name: `contoso-build-vm`
   - Region: **Denmark East**
   - Image: click **See all images** → search `Windows 11` → find **Windows 11 Enterprise multi-session + Microsoft 365 Apps** (latest version) → Select
   - Size: `Standard_D4s_v5`
   - Admin account: set username and password
3. **Networking:**
   - VNet: `vnet-contoso-dke`
   - Subnet: `snet-contoso-avd`
   - Public IP: **None** *(use Bastion or RDP via VPN)*
   - NIC NSG: **None** *(subnet NSG already applied)*
4. Leave other tabs as default → **Review + Create** → **Create**

### Steps 33-38 – Configure the Build VM 🖥️

> RDP into `contoso-build-vm` and do the following:

**Install applications:**
1. Install **Business Central client** (download from your BC server / Microsoft download center)
2. Install any other required applications (confirm the 1-2 unknown apps with the customer)
3. Verify **Office 365 Apps** are already installed — open Word to activate with a test account

**Install FSLogix:**
4. Download FSLogix from: https://aka.ms/fslogix-latest
5. Extract the zip → run `FSLogixAppsSetup.exe` → follow the installer (accept defaults)
6. Do **NOT** configure FSLogix settings yet — that will be done via GPO in Phase 7

**Run AVD Optimization:**
7. Open PowerShell as Administrator:
   ```powershell
   # Download the optimization tool
   $url = "https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/refs/heads/main.zip"
   Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\vdot.zip"
   Expand-Archive "$env:TEMP\vdot.zip" -DestinationPath "$env:TEMP\vdot"
   cd "$env:TEMP\vdot\Virtual-Desktop-Optimization-Tool-main"
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
   .\Windows_VDOT.ps1 -Optimizations All -AcceptEULA
   ```
8. Reboot when prompted

**Run Windows Update:**
9. Settings → Windows Update → **Check for updates** → install all → reboot
10. Repeat until no more updates pending

**Clean up:**
11. Empty the Recycle Bin
12. In PowerShell: `Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue`
13. Run Disk Cleanup: search `cleanmgr` → select C: → check all boxes → Clean up system files → check all → OK

**⚠️ Do NOT install the AVD agent manually** — the host pool wizard installs it automatically.

### Step 39-40 – Sysprep and Capture ☁️🖥️

**Run Sysprep (inside the VM):**
1. Open Command Prompt as Administrator:
   ```cmd
   C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown
   ```
2. Wait for the VM to **fully shut down** (status in Portal: **Stopped (deallocated)**)

**Capture the image:**
3. Portal → **Virtual machines** → `contoso-build-vm`
4. Click **Capture** at the top
5. Share image to Azure compute gallery: **Yes, share it to a gallery as an image version**
6. Gallery: `acg_contoso_avd`
7. Target VM image definition: `Win11-MultiSession-M365`
8. Version number: `1.0.0`
9. Target regions: **Denmark East** — Replicas: `1`
10. Exclude from latest: **No**
11. Click **Review + Create** → **Create**
12. Wait until the image version shows status **Succeeded** (takes 10–20 min)

### Step 42 – Delete the build VM ☁️
1. Portal → `contoso-build-vm` → **Delete**
2. Check all boxes: **Delete OS disk**, **Delete network interfaces**, **Delete public IP**
3. Confirm deletion

---

## Phase 6 – Host Pool & Session Hosts ☁️

### Steps 43-47 – Create Host Pool with Session Hosts
1. Portal → search **Azure Virtual Desktop** → **Host pools** → **+ Create**

**Basics tab:**
2. Subscription / Resource group: `rg-contoso-avd-avdresources` *(host pool is a service object, not a VM)*
3. Host pool name: `hp-contosogrp`
4. Location: **Denmark East**
5. Validation environment: **No**
6. Host pool type: **Pooled**
7. Load balancing algorithm: **Breadth-first**
8. Max session limit: **13**
9. → **Next: Virtual Machines**

**Virtual Machines tab:**
10. Add Azure virtual machines: **Yes**
11. Resource group: `rg-contoso-avd-hosts` *(VMs go into the hosts RG)*
12. Name prefix: `contosogrp-sh`
13. Virtual machine location: **Denmark East**
14. Availability options: **Availability zone** → select zone `1` for sh-0 *(if available — check first)*
15. Security type: **Standard**
16. Image: click **See all images** → **My items** → **Compute gallery** → select `Win11-MultiSession-M365` version `1.0.0`
17. Virtual machine size: `Standard_D4s_v5` → click **Change size** if needed
18. Number of VMs: **2**
19. OS disk type: **Premium SSD**
20. Virtual network: `vnet-contoso-dke`
21. Subnet: `snet-contoso-avd`
22. Network security group: **None** *(already on subnet)*
23. Public inbound ports: **No**

**Domain join settings:**
24. Select which directory to join: **Active Directory**
25. AD domain join UPN: `svc-avd-domainjoin@contoso.local`
26. Password: *(the service account password)*
27. Specify domain or unit: **Yes**
28. Domain to join: `contoso.local`
29. Organizational unit path: `OU=AVD,OU=Servers,DC=contoso,DC=local`
30. → **Next: Workspace**

**Workspace tab:**
31. Register desktop app group: **No** *(we'll create app groups manually)*
32. → **Review + Create** → **Create**
33. Deployment takes **10–15 minutes** — grab a coffee ☕

### Step 47a – Enable SSO on the Host Pool ☁️

> Requires Step 8a (Entra Kerberos) to have been completed first.

1. Portal → **Azure Virtual Desktop** → **Host pools** → `hp-contosogrp`
2. Left menu: **RDP Properties** → click the **Advanced** tab
3. In the RDP properties text box, add (append with a semicolon if other properties exist):
   ```
   enablerdsaadauth:i:1
   ```
4. Click **Save**

> **What this does:** Tells the Windows App to use Entra ID-based authentication and pass a Kerberos ticket silently — users see only one login prompt, not two.
>
> **Client requirement:** Windows App (Store version) or Remote Desktop client version **1.2.3316** or later. The old MSRDC client does not support this.

### Steps 48-51 – Verify Session Hosts
**Verify in Active Directory:**
34. On a domain-joined machine, open ADUC → navigate to `OU=AVD,OU=Servers`
35. Confirm `contosogrp-sh-0` and `contosogrp-sh-1` appear as computer objects

**Force Entra Connect sync:**
36. On the Entra Connect server, run:
    ```powershell
    Start-ADSyncSyncCycle -PolicyType Delta
    ```

**Verify in Entra ID:**
37. Entra Admin Center → **Devices** → **All devices**
38. Search for `contosogrp-sh` — both VMs should appear with **Join type: Hybrid Azure AD Joined**
39. If they show as just "Azure AD registered" wait another sync cycle (up to 30 min)

**Verify in AVD Portal:**
40. Azure Virtual Desktop → Host pools → `hp-contosogrp` → **Session hosts**
41. Both `contosogrp-sh-0` and `contosogrp-sh-1` must show **Status: Available**
42. If status is **Unavailable**, click on the host → **Health checks** to see what's wrong

---

## Phase 7 – FSLogix GPO Configuration 🖥️

> Run on a domain-joined machine with Group Policy Management (RSAT) installed.

### Step 52 – Copy FSLogix ADMX templates
1. On the `contoso-build-vm` (before you deleted it) — or re-extract the FSLogix installer
2. Copy the ADMX files to the central store:
   - Source: `C:\Program Files\FSLogix\Apps\PolicyDefinitions\`
   - Files to copy: `fslogix.admx` and `fslogix.adml` (in the `en-US` subfolder)
3. Destination:
   - `fslogix.admx` → `\\contoso.local\SYSVOL\contoso.local\Policies\PolicyDefinitions\`
   - `fslogix.adml` → `\\contoso.local\SYSVOL\contoso.local\Policies\PolicyDefinitions\en-US\`

> **Alternative:** Download FSLogix directly on the DC: https://aka.ms/fslogix-latest

### Steps 53-55 – Configure FSLogix via GPO
1. Open **Group Policy Management** (`gpmc.msc`)
2. Find the GPO `AVD - Session Host Policy` (linked to the AVD OU)
3. Right-click → **Edit**
4. Navigate to:
   `Computer Configuration > Policies > Administrative Templates > FSLogix > Profile Containers`
5. Configure each setting by double-clicking it:

   | Setting | Value |
   |---|---|
   | **Enabled** | **Enabled** |
   | **VHD Location** | `\\stacontosoprofiles.file.core.windows.net\fslogix-profiles\contosogrp` |
   | **Delete Local Profile When VHD Should Apply** | **Enabled** |
   | **Volume Type (VHD or VHDX)** | `VHDX` |
   | **Size in MBs** | `30720` (= 30 GB) |

6. Close the GPO editor

### Step 56 – Verify GPO applies
1. RDP into one of the session hosts (`contosogrp-sh-0`)
2. Open PowerShell:
   ```powershell
   gpupdate /force
   gpresult /scope computer /r
   ```
3. Look for `AVD - Session Host Policy` in the **Applied Group Policy Objects** list

---

## Phase 8 – Application Groups & Workspace ☁️

### Step 57 – Rename the auto-created Desktop app group
1. Azure Virtual Desktop → **Application groups**
2. Find the auto-created group (named something like `hp-contosogrp-DAG`)
3. Click it → **Properties** → rename to `ag-contosogrp-desktop` (or leave as is)

### Step 58-59 – Create RemoteApp application group
1. Azure Virtual Desktop → **Application groups** → **+ Create**
2. Basics:
   - Resource group: `rg-contoso-avd-avdresources`
   - Host pool: `hp-contosogrp`
   - Application group type: **RemoteApp**
   - Application group name: `ag-contosogrp-apps`
   - → **Next: Applications**

3. Click **+ Add applications** for each app:

   **Business Central:**
   - Application source: **Start menu** (if BC client is installed) or **File path**
   - If file path: `C:\Program Files\Microsoft Dynamics 365 Business Central\[version]\RoleTailored Client\Microsoft.Dynamics.Nav.Client.exe`
   - Display name: `Business Central`
   - → **Save**

   **Microsoft Outlook:**
   - Application source: **Start menu** → search `Outlook`
   - Display name: `Outlook`
   - → **Save**

   **Microsoft Excel:**
   - Application source: **Start menu** → search `Excel`
   - Display name: `Excel`
   - → **Save**

   **Microsoft Word:**
   - Application source: **Start menu** → search `Word`
   - Display name: `Word`
   - → **Save**

   **Remote Desktop Connection:**
   - Application source: **File path**
   - Application path: `C:\Windows\System32\mstsc.exe`
   - Display name: `Remote Desktop`
   - → **Save**

   *(Add the 1-2 remaining apps in the same way — confirm paths with customer)*

4. → **Next: Assignments**
5. Click **+ Add** → search for `GRP-AVD-Users` → select → **Select**
6. → **Review + Create** → **Create**

### Step 60-61 – Create Workspace and associate app groups
1. Azure Virtual Desktop → **Workspaces** → **+ Create**
2. Resource group: `rg-contoso-avd-avdresources`
3. Workspace name: `ws-contosogrp`
4. Location: **Denmark East**
5. **Application groups tab:** click **+ Add** → select both `ag-contosogrp-apps` and `ag-contosogrp-desktop`
6. → **Review + Create** → **Create**

### Step 62-63 – Assign users to app groups
1. Azure Virtual Desktop → **Application groups** → `ag-contosogrp-apps`
2. Left menu: **Assignments** → **+ Add**
3. Search and select `GRP-AVD-Users` → **Select**
4. Repeat for `ag-contosogrp-desktop` if full desktop access is needed

---

## Phase 9 – Client Setup & Testing

### Step 64-65 – Install the client and connect
**Windows:**
1. Download **Windows App** from https://aka.ms/windows-app or the Microsoft Store
2. Sign in with an AVD user's Microsoft 365 account (e.g. `user@contoso.com`)
3. The workspace `ws-contosogrp` and all RemoteApps should appear

**Mac:**
1. Download **Windows App** from the Mac App Store (search "Windows App")
2. Sign in the same way → verify RemoteApps appear

### Steps 66-73 – Test checklist

| # | Test | Expected Result |
|---|---|---|
| 66 | Launch **Business Central** RemoteApp | Opens and connects to on-prem BC server |
| 67 | Launch **Outlook** RemoteApp | Loads email, profile correct |
| 68 | Log off → log back in | All settings/profile preserved (FSLogix) |
| 69 | Check file share | `\\stacontosoprofiles.file.core.windows.net\fslogix-profiles\contosogrp` shows one `.vhdx` per user |
| 70 | Run `gpresult /r` in session | `AVD - Session Host Policy` listed as applied |
| 71 | Two users connect simultaneously | One lands on `contosogrp-sh-0`, second on `contosogrp-sh-1` |
| 72 | Connect from Mac / Australia | Apps launch, latency ~270–300ms, acceptable |
| 73 | Launch **Remote Desktop** RemoteApp | Can RDP to other internal machines from within session |

---

## Phase 10 – Monitoring ☁️

### Step 74-75 – Enable AVD Insights
1. Portal → **Azure Virtual Desktop** → **Insights** (in the left menu)
2. If prompted to set up diagnostics: click **Open configuration workbook**
3. Select your host pool `hp-contosogrp`
4. Under **Log Analytics workspace**: click **+ Create new workspace**
   - Name: `law-contoso-avd`
   - Resource group: `rg-contoso-avd-avdresources`
   - Region: **Denmark East**
   - → **Review + Create** → **Create**
5. Back in the configuration workbook: select `law-contoso-avd` for all diagnostic settings
6. Click **Configure host pool** → **Configure workspace** → **Configure session hosts**

### Step 76 – Create a health alert
1. Portal → **Monitor** → **Alerts** → **+ Create** → **Alert rule**
2. Scope: select your session hosts (`contosogrp-sh-0`, `contosogrp-sh-1`)
3. Condition: click **Add condition** → search `Heartbeat` → select it
4. Threshold: **Less than** `1` → Aggregation: **Count** → Period: **5 minutes**
5. Actions: **+ Create action group**
   - Name: `ag-avd-admins`
   - Notification: Email → enter your email address
   - → **Review + Create** → **Create**
6. Alert rule name: `AVD - Session Host Down`
7. → **Review + Create** → **Create**

---

## Phase 10 – Handover Checklist

- [ ] Share the file share UNC path with the customer IT team: `\\stacontosoprofiles.file.core.windows.net\fslogix-profiles`
- [ ] Document how to add users: add to `GRP-AVD-Users` in Active Directory
- [ ] Document how to remove users: remove from `GRP-AVD-Users` — their FSLogix `.vhdx` remains on the share
- [ ] Share the App Store link for Windows App (Mac + Windows)
- [ ] Keep Citrix running in parallel for **2–4 weeks** before decommissioning
- [ ] After parallel period: schedule Citrix decommission with customer

---

## Appendix – AVD VM Sizing Reference

> Use this to size session hosts correctly for new customers. The right VM = good user experience at the right cost. The wrong VM = sluggish sessions or wasted budget.

### Workload Profiles

| Workload | Description | RAM per user | vCPU per user | Typical users/host |
|---|---|---|---|---|
| **Light** | Web browsing, email, simple data entry | 2–3 GB | 0.2 vCPU | 8–12 per D4s_v5 |
| **Medium** | Office 365, Teams calls, standard line-of-business apps | 4 GB | 0.4 vCPU | 4–8 per D4s_v5 |
| **Heavy** | ERP (Business Central, SAP), dev tools, multi-app | 6–8 GB | 0.5–0.8 vCPU | 2–4 per D4s_v5 |
| **Power / GPU** | CAD, 3D, rendering, video editing | 8+ GB + GPU | GPU-bound | 1–4 per NV-series |

> **This deployment** (Business Central + Office 365): classified as **Heavy**. Recommended baseline: **D8s_v5** with max 8–10 sessions per host, not D4s_v5 with 13. Adjust `$MaxSessionsPerHost` and `$SessionHostSize` in `config.ps1` accordingly.

---

### VM Series Comparison

| Series | Focus | vCPU : RAM ratio | Best for AVD |
|---|---|---|---|
| **Dsv5 / Ddsv5** | General purpose | 1 : 4 | ✅ Most AVD deployments — good balance |
| **Esv5 / Edsv5** | Memory optimized | 1 : 8 | ✅ ERP-heavy, SQL-heavy, power users needing lots of RAM |
| **Fsv2** | Compute optimized | 1 : 2 | ⚠️ Low RAM per core — only for compute-intensive, RAM-light workloads |
| **NVads A10 v5** | GPU (NVIDIA A10) | 1 : 6.7 | ✅ Light-medium GPU (AutoCAD, GIS, graphics-assisted apps) |
| **NCas_T4_v3** | GPU (NVIDIA T4) | 1 : 8 | ✅ ML inference, heavier GPU rendering |
| **Bsv2** | Burstable | 1 : 4 | ❌ Not recommended for AVD — CPU burst model causes inconsistent sessions |

---

### Recommended Sizes by Scenario

| Scenario | VM Size | vCPU | RAM | Max sessions | Notes |
|---|---|---|---|---|---|
| Light office (email + web) | `Standard_D4s_v5` | 4 | 16 GB | 10–12 | Good for ~120 light users on 10 VMs |
| Medium office (O365 + Teams) | `Standard_D4s_v5` | 4 | 16 GB | 6–8 | Teams video calls eat RAM |
| ERP / Business Central | `Standard_D8s_v5` | 8 | 32 GB | 8–10 | BC + O365 together = heavy load |
| ERP power users | `Standard_E8s_v5` | 8 | 64 GB | 6–8 | Extra RAM headroom for large BC companies |
| Developer workstations | `Standard_D16s_v5` | 16 | 64 GB | 4–6 | IDE + build tools + browser tabs |
| Light CAD / GIS | `Standard_NV6ads_A10_v5` | 6 | 55 GB | 1–2 | Fractional GPU; check app GPU requirements |

---

### Memory Sizing Rules of Thumb

- **4 GB** — minimum per concurrent user for any workload
- **6 GB** — recommended for Office 365 + Teams (Teams alone can use 500 MB–1.5 GB)
- **8 GB** — recommended for ERP users (Business Central, SAP B1, Dynamics)
- **12+ GB** — power users with multiple large ERP companies open simultaneously
- Always leave **10–15% headroom** on the host for the OS and AVD agent (roughly 2–3 GB)

**Formula:**

```
Total RAM needed = (concurrent users × RAM per user) + 3 GB OS overhead
→ Pick the next VM size up from that number
```

**Example** — 10 Business Central users on one host:
```
10 × 6 GB + 3 GB overhead = 63 GB  →  use Standard_E8s_v5 (64 GB) or D16s_v5 (64 GB)
```

---

### When to use more smaller VMs vs fewer larger VMs

| Approach | Pros | Cons |
|---|---|---|
| **Many small VMs** (D4s_v5) | Lower blast radius if one crashes; easier to patch one at a time | More management overhead; more FSLogix connections |
| **Fewer large VMs** (D8s_v5+) | Simpler management; better session density | Single VM failure impacts more users |

> **Recommendation:** 2–4 VMs minimum for AVD pooled deployments (availability + breadth-first load balancing). Beyond 4 VMs, use VM Scale Sets or Autoscale.

---

## Quick Troubleshooting Reference

| Problem | Most likely cause | Fix |
|---|---|---|
| Session hosts stuck on "Unavailable" | AVD agent not installed / VPN issue | Check health checks on the session host in AVD Portal |
| Hybrid join not showing in Entra ID | Device writeback off / OU not in sync scope | Check Entra Connect config, re-run `Start-ADSyncSyncCycle` |
| Users get temporary profile (not FSLogix) | NTFS permissions wrong or share unreachable | Check permissions on share, verify storage account AD auth |
| Can't resolve on-prem domain from session host | VNet DNS still set to Azure default | Check VNet DNS servers → must point to on-prem DC |
| App not visible in workspace | User not assigned to app group | AVD → App group → Assignments → add `GRP-AVD-Users` |
| BC not connecting to on-prem server | VPN routing / firewall | Check NSG, check that BC port (typically 7046/443) is open over VPN |
