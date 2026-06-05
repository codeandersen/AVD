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
| Steps 22–23a | Create storage account, file share, private endpoint | **Contributor** or **Owner** on Azure subscription |
| Step 23b | Configure on-prem DNS conditional forwarder | **DNS Admins** or **Domain Admin** (on-prem) |
| Steps 24–28 | AD-join storage account, set RBAC, NTFS permissions | **Contributor** (Azure) + **Domain Admin** (on-prem) |
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
3. Group name: `GRP-ContosoGRP-AVD-Users`
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

Hide the consent prompt dialog
Use dynamic group created before
In the same PowerShell session, create a targetDeviceGroup object by running the following commands, replacing the <placeholders> with your own values:
$tdg = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphTargetDeviceGroup
$tdg.Id = "<Group object ID>"
$tdg.DisplayName = "<Group display name>"

Add the group to the targetDeviceGroup object by running the following commands:
New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $WCLspId -BodyParameter $tdg
Output example
Id                                   DisplayName
--                                   -----------
12345678-abcd-1234-abcd-1234567890ab Contoso-session-hosts

#### Step 8a-iii – Conditional Access with MFA ☁️
https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-mfa?tabs=avd

**What it does:** Enforces Microsoft Entra multifactor authentication (MFA) when users connect to Azure Virtual Desktop, adding an extra layer of security beyond username and password.

**Required role:** **Conditional Access Administrator** (Entra ID)

**Prerequisites:**
- Users must have a license that includes **Microsoft Entra ID P1 or P2**
- Microsoft Entra multifactor authentication must be enabled for your tenant
- A Microsoft Entra group containing your AVD users (e.g., `GRP-ContosoGRP-AVD-Users`)

**Create Conditional Access Policy:**

1. Sign in to **Microsoft Entra admin center** (https://entra.microsoft.com) as a Conditional Access Administrator
2. Browse to **Protection** → **Conditional Access** → **Policies**
3. Select **+ New policy**
4. Give your policy a name: `AVD - Require MFA`

**Configure Users:**

5. Under **Assignments** → **Users**, select **0 users and groups selected**
6. Under the **Include** tab, select **Select users and groups** and check **Users and groups**
7. Under **Select**, select **0 users and groups selected**
8. Search for and select `GRP-ContosoGRP-AVD-Users` (or your AVD users group) → **Select**

**Configure Target Resources:**

9. Under **Assignments** → **Target resources**, select **No target resources selected**
10. For **Select what this policy applies to**, leave the default of **Resources (formerly cloud apps)**
11. Under the **Include** tab, select **Select resources**, then under **Select**, select **None**
12. On the new pane, search for and select the following apps:
    - **Azure Virtual Desktop** (app ID `9cdead84-a844-4324-93f2-b2e6bb768d07`) — applies when users subscribe to AVD, authenticate to the AVD Gateway, and send diagnostics
    - **Windows Cloud Login** (app ID `270efc09-cd0d-444b-a71f-39af4910ec45`) — applies when users authenticate to the session host with SSO enabled
    
    > **Important:** Match Conditional Access policies between these two apps, except for sign-in frequency. Do NOT select **Azure Virtual Desktop Azure Resource Manager Provider** (app ID `50e95039-b200-4007-bc97-8d5790743a63`) — this is only for retrieving the user feed.

13. Select **Select**

**Configure Client Apps:**

14. Under **Assignments** → **Conditions**, select **0 conditions selected**
15. Under **Client apps**, select **Not configured**
16. On the new pane, for **Configure**, select **Yes**
17. Select the client apps this policy applies to:
    - Check **Browser** if you want the policy to apply to the web client
    - Check **Mobile apps and desktop clients** if you want to apply the policy to other clients
    - Check **both** if you want to apply the policy to all clients (recommended)
    - Deselect values for legacy authentication clients
18. Select **Done**

**Configure Grant Controls:**

19. Under **Access controls** → **Grant**, select **0 controls selected**
20. On the new pane, select **Grant access**
21. Check **Require multifactor authentication**
22. Select **Select**

**Enable Policy:**

23. At the bottom of the page, set **Enable policy** to **On**
24. Select **Create**

**Optional – Configure Sign-in Frequency:**

To configure how often users must reauthenticate:

25. Open the policy you just created
26. Under **Access controls** → **Session**, select **0 controls selected**
27. In the Session pane, select **Sign-in frequency**
28. Select **Periodic reauthentication** or **Every time**:
    - **Periodic reauthentication**: Set a time period (e.g., `1` hour) after which users must sign in again when a new access token is needed
    - **Every time**: Only supported for the **Windows Cloud Login** app with SSO enabled. Users are prompted to reauthenticate when launching a new connection after 5-10 minutes since their last authentication
29. Select **Select**
30. At the bottom of the page, select **Save**

> **Note:** Reauthentication only happens when a user must authenticate to a resource and a new access token is needed. After a connection is established, users aren't prompted even if the connection lasts longer than the configured sign-in frequency.

> **Reference:** [Microsoft Learn - Enforce MFA for Azure Virtual Desktop using Conditional Access](https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-mfa?tabs=avd)

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

> **After creation — set custom DNS (critical for hybrid join and private endpoints):**
6. Go to the new VNet → left menu: **DNS servers**
7. Select **Custom**
8. Add your on-prem DC IP addresses (e.g. `10.0.0.10`, `10.0.0.11`)
9. Click **Save**

> **Note:** Custom DNS is required for both domain join and private endpoint DNS resolution. The private DNS zone created in Step 23a will automatically integrate with this VNet to resolve `stacontosoprofiles.file.core.windows.net` to the private IP.

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

### Step 23a – Configure Private Endpoint for Storage Account ☁️

> Private endpoint ensures FSLogix profile access is only possible from within your VNet, not from the public internet. This is critical for security.

1. Portal → Storage account `stacontosoprofiles` → left menu: **Networking**
2. Click the **Private endpoint connections** tab → **+ Private endpoint**
3. **Basics tab:**
   - Resource group: `rg-contoso-avd-avdresources`
   - Name: `pe-stacontosoprofiles-file`
   - Network Interface Name: `nic-pe-stacontosoprofiles-file` *(auto-generated, can leave as is)*
   - Region: **Denmark East**
   - → **Next: Resource**
4. **Resource tab:**
   - Connection method: **Connect to an Azure resource in my directory**
   - Subscription: *(your subscription)*
   - Resource type: `Microsoft.Storage/storageAccounts`
   - Resource: `stacontosoprofiles`
   - Target sub-resource: **file**
   - → **Next: Virtual Network**
5. **Virtual Network tab:**
   - Virtual network: `vnet-contoso-dke`
   - Subnet: `snet-contoso-avd`
   - Network policy for private endpoints: **Disabled** *(default)*
   - Private IP configuration: **Dynamically allocate IP address**
   - Application security group: *(leave empty)*
   - → **Next: DNS**
6. **DNS tab:**
   - Integrate with private DNS zone: **Yes**
   - Subscription: *(your subscription)*
   
   **If the private DNS zone already exists:**
   - Resource group: *(select the RG where the existing zone is located)*
   - Private DNS zone: Select **existing** `privatelink.file.core.windows.net` from dropdown
   
   **If creating new:**
   - Resource group: `rg-contoso-avd-avdresources`
   - Private DNS zone: `privatelink.file.core.windows.net` *(will be auto-created)*
   
   - → **Next: Tags**
   
   > **Troubleshooting:** If deployment fails with "BadRequest" or "conflict" error about overlapping namespaces:
   > 1. Cancel this wizard
   > 2. Go to **Private DNS zones** in the Portal
   > 3. Find the existing `privatelink.file.core.windows.net` zone
   > 4. Check **Virtual network links** → verify `vnet-contoso-dke` is linked (if not, add it)
   > 5. Restart the private endpoint wizard and select the **existing** zone in step 6
7. **Tags tab:** *(optional)*
   - Add tags if needed: `Project = AVD`, `Environment = Production`
   - → **Next: Review + create**
8. **Review + create** → **Create**
9. Wait for deployment to complete (1–2 minutes)

**Disable public network access:**
10. Go back to Storage account → **Networking** → **Firewalls and virtual networks** tab
11. Public network access: Select **Disabled**
    - *Alternative:* Select **Enabled from selected virtual networks and IP addresses** if you need temporary access for management from specific IPs
12. Click **Save**

**Verify private endpoint:**
13. Storage account → **Networking** → **Private endpoint connections** tab
14. Confirm the endpoint `pe-stacontosoprofiles-file` shows **Connection state: Approved**
15. On a domain-joined machine (or session host later), test DNS resolution:
    ```powershell
    nslookup stacontosoprofiles.file.core.windows.net
    ```
    Should return a **private IP** (10.10.1.x range), not a public IP

> **Important:** After enabling private endpoint and disabling public access, you can only access the file share from within the VNet or via VPN. If you need to run the AD join script (Step 24-26) from your local machine, either run it from a domain-joined VM in Azure, or temporarily allow your public IP in the storage account firewall.

### Step 23b – Configure On-Premises DNS for Private Endpoint Resolution 🖥️

> This step is required for on-premises machines to resolve the storage account's private endpoint via VPN. Without this, on-prem machines will resolve to the public IP (which is now blocked).

**How Private Endpoint DNS Works:**
- Azure VMs in the VNet automatically use the private DNS zone (`privatelink.file.core.windows.net`) linked to the VNet
- On-premises DNS servers need a **conditional forwarder** to query Azure's internal DNS resolver

**Configure Conditional Forwarder on On-Premises DNS:**

1. On your **on-premises DNS server**, open **DNS Manager** (`dnsmgmt.msc`)
2. Expand your DNS server → right-click **Conditional Forwarders** → **New Conditional Forwarder**
3. DNS Domain: `privatelink.file.core.windows.net`
4. IP addresses of the master servers: `168.63.129.16`
   - This is Azure's internal DNS resolver (also called Azure DNS or WireServer)
   - Click **OK** after entering the IP
5. Check **Store this conditional forwarder in Active Directory, and replicate it as follows:**
   - Select: **All DNS servers in this domain** (or **All DNS servers in this forest** if multi-domain)
6. Click **OK**

**Verify from On-Premises:**
7. On an on-premises machine connected via VPN, open PowerShell:
   ```powershell
   nslookup stacontosoprofiles.file.core.windows.net
   ```
   Should return:
   ```
   Name:    stacontosoprofiles.privatelink.file.core.windows.net
   Address: 10.10.1.x  (private IP from your Azure VNet)
   ```

8. If it still returns a public IP, check:
   - VPN connection is active and routing to `10.10.0.0/16`
   - DNS server replication completed (wait 5-10 minutes)
   - Clear DNS cache: `ipconfig /flushdns`

> **Alternative:** If you cannot modify on-prem DNS servers, run Steps 24-26 and Step 28 from a domain-joined VM in Azure instead of from on-premises.

### Step 24-26 – Enable AD Authentication on Storage Account 🖥️

> This **must** be done from a domain-joined machine. Cannot be done through the Portal alone.

> **Network access note:** If you disabled public access in Step 23a, run this from:
> - A domain-joined VM in Azure (same VNet), OR
> - Your on-prem domain-joined machine via VPN, OR
> - Temporarily re-enable public access or add your IP to the firewall allowlist

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
5. Select: `GRP-ContosoGRP-AVD-Users` (the AD group you created in Phase 1)
6. → **Review + Assign**

### Step 28 – Create Entity Subfolders + Set NTFS Permissions 🖥️

> The share uses a subfolder per company entity. Each subfolder has its own NTFS permissions scoped to that entity's AD group. The FSLogix GPO points to the subfolder, not the share root.

**Folder layout:**
```
fslogix-profiles\
  contosogrp\  ← Contoso Group  (GRP-ContosoGRP-AVD-Users)
  contosode\     ← Contoso Germany          (GRP-ContosoDE-AVD-Users)
```

> **Prerequisites:** This step must be run from a domain-joined machine that has network access to the storage account. Options:
> - A domain-joined VM in Azure (in the same VNet as the private endpoint)
> - Your on-premises domain-joined machine connected via VPN
> - Temporarily allow your public IP in the storage account firewall (Step 23a, step 11)

1. On a domain-joined machine with network access, open **PowerShell as Administrator**

2. Map the share root using AD authentication:
   ```powershell
   net use Z: \\stacontosoprofiles.file.core.windows.net\fslogix-profiles /persistent:no
   ```
   - When prompted for credentials, use your **domain admin account** (e.g., `CONTOSO\administrator`)
   - The storage account will authenticate you via AD (configured in Step 24-26)
   - **Do NOT use** `AZURE\stacontosoprofiles` with storage account key — AD authentication is required for NTFS permissions

**Create entity subfolders:**
3. Create the subfolders for each entity:
   ```powershell
   New-Item -Path "Z:\contosogrp" -ItemType Directory
   New-Item -Path "Z:\contosode" -ItemType Directory
   New-Item -Path "Z:\_redirection" -ItemType Directory
   ```

**Configure NTFS permissions for `_redirection` folder (for redirections.xml):**

4. Set READ permissions for AVD users to access the redirections.xml file:
   ```powershell
   # Grant READ permissions to AVD users with inheritance to files
   # (OI) = Object Inherit, (CI) = Container Inherit - propagates to files and subfolders
   icacls Z:\_redirection /grant "CONTOSO\GRP-ContosoGRP-AVD-Users:(OI)(CI)(R)"
   icacls Z:\_redirection /grant "CONTOSO\GRP-ContosoDE-AVD-Users:(OI)(CI)(R)"
   
   # Grant full control to admins with inheritance
   icacls Z:\_redirection /grant "CONTOSO\Domain Admins:(OI)(CI)(F)"
   
   # Remove default permissions
   icacls Z:\_redirection /remove "Authenticated Users"
   icacls Z:\_redirection /remove "Builtin\Users"
   ```

   > **Note:** Users only need READ access to copy redirections.xml during login. If using SYSVOL instead (recommended for hybrid environments), skip this step and use `\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix` in the GPO setting.

**Configure NTFS permissions for `contosogrp` subfolder:**

5. Set permissions using Microsoft's recommended `icacls` commands:
   ```powershell
   # Grant Modify permissions to the AVD users group
   icacls Z:\contosogrp /grant "CONTOSO\GRP-ContosoGRP-AVD-Users:(M)"
   
   # Grant Creator Owner full control over their own profile folders
   icacls Z:\contosogrp /grant "Creator Owner:(OI)(CI)(IO)(M)"
   
   # Remove default permissions
   icacls Z:\contosogrp /remove "Authenticated Users"
   icacls Z:\contosogrp /remove "Builtin\Users"
   ```

**Configure NTFS permissions for `contosode` subfolder:**

6. Repeat for the Germany entity:
   ```powershell
   # Grant Modify permissions to the Germany AVD users group
   icacls Z:\contosode /grant "CONTOSO\GRP-ContosoDE-AVD-Users:(M)"
   
   # Grant Creator Owner full control
   icacls Z:\contosode /grant "Creator Owner:(OI)(CI)(IO)(M)"
   
   # Remove default permissions
   icacls Z:\contosode /remove "Authenticated Users"
   icacls Z:\contosode /remove "Builtin\Users"
   ```

**Verify permissions:**
7. Check the permissions were applied correctly:
   ```powershell
   icacls Z:\contosogrp
   icacls Z:\contosode
   icacls Z:\_redirection
   ```
   - Profile folders should show: `CONTOSO\GRP-Contoso[entity]-AVD-Users:(M)` and `Creator Owner:(OI)(CI)(IO)(M)`
   - `_redirection` folder should show: Both AVD groups with `(R)` and `Domain Admins:(F)`
   - No `Authenticated Users` or `Builtin\Users` on any folder

8. Disconnect the mapped drive:
   ```powershell
   net use Z: /delete
   ```

> **Reference:** [Microsoft Learn - Configure FSLogix Profile Container with Azure Files and Active Directory](https://learn.microsoft.com/en-us/fslogix/how-to-configure-profile-container-azure-files-active-directory?tabs=adds)

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
12. Name prefix: `AVD-contoso-sh`
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

> **Note on FSLogix Redirections:** Starting with FSLogix 2210 (2.9.8361.52326) and later, Microsoft Entra ID authentication folders are **automatically excluded** by default and no longer roamed. This includes `Microsoft.AAD.BrokerPlugin`, `Microsoft.Windows.CloudExperienceHost`, and `Microsoft\TokenBroker`. You only need a custom `redirections.xml` file if you have specific application folders to exclude beyond the defaults. For most AVD deployments, the default FSLogix behavior is sufficient.
>
> **Reference:** [FSLogix Known Issues - Microsoft Entra ID broker directories](https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues#microsoft-entra-id-broker-directories-and-apps)

### Step 55a – (Optional) Configure FSLogix Redirections for Performance 🖥️

> **When to use this:** If you want to optimize profile container performance by excluding browser caches, Teams cache, temp files, and other non-essential data that doesn't need to roam. This reduces VHDX size and improves login/logout times.

> **⚠️ CRITICAL - Read This First:**
> - Microsoft's official recommendation: **Start WITHOUT redirections.xml** (their "Standard" configuration)
> - Community consensus: **"Less is best"** - over-excluding causes mysterious application breakages
> - Real-world experience: Teams starting with 25+ exclusions had constant issues; cutting to ~10 fixed 80% of problems
> - Each exclusion adds complexity and can cause undocumented application behaviors
> - **Start with Tier 1 (Minimal), only move to Tier 2/3 if you have proven profile bloat issues**

**Choose Your Tier:**

---

#### **Tier 1: Minimal (Recommended Starting Point)**

**Who this is for:** Most AVD deployments. Proven stable in production for 2+ years.

**What it excludes:** Only Microsoft Teams cache (new MSIX version) and Edge cache - the safest, most impactful exclusions.

**Expected profile size reduction:** 15-25%

1. On a domain-joined machine, create the folder structure:
   ```powershell
   New-Item -Path "\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix" -ItemType Directory -Force
   ```

2. Create `redirections.xml` at `\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix\redirections.xml`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <FrxProfileFolderRedirection ExcludeCommonFolders="0">
     <Excludes>
       <!-- Microsoft Teams (MSIX) cache -->
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\Service Worker</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\WebStorage</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\TempState</Exclude>
       
       <!-- Legacy Teams (if still present) -->
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\media-stack</Exclude>
       
       <!-- Microsoft Edge cache -->
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\GPUCache</Exclude>
     </Excludes>
     <Includes>
       <!-- Ensure Edge user data is included -->
       <Include>AppData\Local\Microsoft\Edge\User Data</Include>
     </Includes>
   </FrxProfileFolderRedirection>
   ```

---

#### **Tier 2: Balanced (If Tier 1 Isn't Enough)**

**Who this is for:** Environments with proven profile bloat (>20GB average) after running Tier 1 for 2+ weeks.

**What it adds:** Browser caches (Chrome), system temp files, Office/Zoom logs. Excludes items with **documented Microsoft recommendations** or proven community safety.

**Expected profile size reduction:** 30-40%

**⚠️ Warning:** Test in a pilot group first. Some exclusions (like Code Cache) can hurt warm-load performance.

<details>
<summary>Click to expand Tier 2 redirections.xml</summary>

2. Create `redirections.xml` at `\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix\redirections.xml`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <FrxProfileFolderRedirection ExcludeCommonFolders="0">
     <Excludes>
       <!-- Microsoft Teams (MSIX) cache -->
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\Service Worker</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\TempState</Exclude>
       
       <!-- Legacy Teams -->
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\media-stack</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\logs</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\Cache</Exclude>
       
       <!-- Google Chrome cache -->
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\Media Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\ShaderCache</Exclude>
       
       <!-- Microsoft Edge cache -->
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Crashpad</Exclude>
       
       <!-- Windows system temp -->
       <Exclude Copy="0">AppData\Local\Temp</Exclude>
       <Exclude Copy="0">AppData\Local\CrashDumps</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Windows\WER</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Windows\INetCache</Exclude>
       
       <!-- Office/Zoom logs -->
       <Exclude Copy="0">AppData\Local\Microsoft\Office\16.0\Lync\Tracing</Exclude>
       <Exclude Copy="0">AppData\Roaming\Zoom\logs</Exclude>
     </Excludes>
     <Includes>
       <Include>AppData\Local\Google\Chrome\User Data</Include>
       <Include>AppData\Local\Microsoft\Edge\User Data</Include>
     </Includes>
   </FrxProfileFolderRedirection>
   ```

</details>

---

#### **Tier 3: Comprehensive (Advanced - Use with Extreme Caution)**

**Who this is for:** Large-scale deployments with severe storage cost issues AND dedicated testing resources.

**What it adds:** Extensive exclusions across all applications, user folders, and system caches.

**Expected profile size reduction:** 40-50%

**⚠️ DANGER:** This list has caused production issues in multiple Reddit-documented cases:
- Broken Excel add-ins
- M365 sign-in failures
- Application state loss
- Mysterious crashes

**Requirements before using:**
- ✅ Tier 1 tested for 2+ weeks
- ✅ Tier 2 tested for 2+ weeks
- ✅ Dedicated pilot group
- ✅ Rollback plan ready
- ✅ User communication prepared

<details>
<summary>Click to expand Tier 3 redirections.xml (COMPREHENSIVE - TEST THOROUGHLY)</summary>

2. Create `redirections.xml` at `\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix\redirections.xml`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <FrxProfileFolderRedirection ExcludeCommonFolders="0">
     <Excludes>
       <!-- Google Chrome excludes -->
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\Cached Theme Image</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Default\Media Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\ShaderCache</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\Crashpad</Exclude>
       <Exclude Copy="0">AppData\Local\Google\Chrome\User Data\SwReporter</Exclude>
       
       <!-- Microsoft Edge excludes -->
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\Cache</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\Code Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Crashpad</Exclude>
       
       <!-- Microsoft general excludes -->
       <Exclude Copy="0">AppData\Local\Microsoft\Windows\WER</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Terminal Server Client\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Office\16.0\Lync\Tracing</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\MSOIdentityCRL\Tracing</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\OneNote\16.0\Backup</Exclude>
       <Exclude Copy="0">AppData\Local\CrashDumps</Exclude>
       <Exclude Copy="0">AppData\Local\SquirrelTemp</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\TokenBroker\Cache</Exclude>
       <Exclude Copy="0">AppData\Local\Microsoft\Windows\INetCache</Exclude>
       
       <!-- Microsoft Teams excludes -->
       <Exclude Copy="0">AppData\Local\Microsoft\Teams\Current\Locales</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\GPUCache</Exclude>
       <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\TempState</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\Cache</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft Teams\Logs</Exclude>
       <Exclude Copy="0">AppData\Roaming\Microsoft\Teams\media-stack</Exclude>
       
       <!-- Adobe excludes -->
       <Exclude Copy="0">AppData\Roaming\Adobe\SLData</Exclude>
       
       <!-- Java excludes -->
       <Exclude Copy="0">AppData\Roaming\Sun\Java\Deployment\cache</Exclude>
       <Exclude Copy="0">AppData\Roaming\Sun\Java\Deployment\log</Exclude>
       <Exclude Copy="0">AppData\Roaming\Sun\Java\Deployment\tmp</Exclude>
       
       <!-- Mozilla Firefox excludes -->
       <Exclude Copy="0">AppData\Local\Mozilla Firefox</Exclude>
       <Exclude Copy="0">AppData\Local\Mozilla</Exclude>
       
       <!-- Zoom excludes -->
       <Exclude Copy="0">AppData\Local\Zoom</Exclude>
       <Exclude Copy="0">AppData\Roaming\Zoom\logs</Exclude>
       
       <!-- Others -->
       <Exclude Copy="0">AppData\Local\GoToMeeting</Exclude>
       <Exclude Copy="0">Videos</Exclude>
       <Exclude Copy="0">Saved Games</Exclude>
       <Exclude Copy="0">Contacts</Exclude>
       <Exclude Copy="0">Music</Exclude>
       <Exclude Copy="0">Downloads</Exclude>
       <Exclude Copy="0">AppData\Local\Temp</Exclude>
       <Exclude Copy="0">AppData\Local\VirtualStore</Exclude>
     </Excludes>
     <Includes>
       <Include Copy="3">AppData\LocalLow\Sun\Java\Deployment\security</Include>
       <Include>AppData\Local\Google\Chrome\User Data</Include>
       <Include>AppData\Local\Microsoft\Edge\User Data</Include>
     </Includes>
   </FrxProfileFolderRedirection>
   ```

</details>

---

**Additional Notes for All Tiers:**

- **Outlook OST**: Do NOT exclude it. Instead, reduce Outlook's cached exchange mode to 1-2 months (default is 1 year)
- **New Outlook**: The new Outlook app doesn't use OST files, saving significant space automatically

**Configure GPO to use redirections.xml (applies to all tiers):**

3. Open **Group Policy Management** (`gpmc.msc`)
4. Edit the `AVD - Session Host Policy` GPO
5. Navigate to: `Computer Configuration > Policies > Administrative Templates > FSLogix > Profile Containers`
6. Configure the following setting:
   - **Redirections XML Source Folder**: **Enabled**
   - Value: `\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix`
7. Click **OK** → Close the GPO editor

**Verify:**

8. On a session host, run:
   ```powershell
   gpupdate /force
   Test-Path "\\contoso.local\SYSVOL\contoso.local\Policies\FSLogix\redirections.xml"
   ```
   Should return `True`

9. After a user logs in, check if redirections are applied:
   ```powershell
   # Check FSLogix logs
   Get-Content "C:\ProgramData\FSLogix\Logs\Profile\*.log" | Select-String "redirections.xml"
   ```

**Monitoring Profile Sizes:**

After implementing any tier, monitor profile sizes over 2-4 weeks:

```powershell
# On the file share server or via Azure Files metrics
Get-ChildItem "\\stacontosoprofiles.file.core.windows.net\fslogix-profiles\contosogrp\*.vhdx" | 
  Select-Object Name, @{Name="SizeGB";Expression={[math]::Round($_.Length/1GB,2)}} | 
  Sort-Object SizeGB -Descending
```

> **References:**
> - [Microsoft Learn - FSLogix Redirections Tutorial](https://learn.microsoft.com/en-us/fslogix/tutorial-redirections-xml)
> - [Microsoft Learn - Configuration Examples](https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples)
> - [Reddit FSLogix Community Discussion](https://www.reddit.com/r/fslogix/comments/1r0ccx1/is_there_a_killer_redirectionsxml_for_avd/)
> - [Aaron Parker's FSLogix Reference](https://github.com/aaronparker/fslogix/blob/main/Redirections/Redirections.csv) (research only, not a recommended implementation)

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
5. Click **+ Add** → search for `GRP-ContosoGRP-AVD-Users` → select → **Select**
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
3. Search and select `GRP-ContosoGRP-AVD-Users` → **Select**
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
- [ ] Document how to add users: add to `GRP-ContosoGRP-AVD-Users` in Active Directory
- [ ] Document how to remove users: remove from `GRP-ContosoGRP-AVD-Users` — their FSLogix `.vhdx` remains on the share
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
| App not visible in workspace | User not assigned to app group | AVD → App group → Assignments → add `GRP-ContosoGRP-AVD-Users` |
| BC not connecting to on-prem server | VPN routing / firewall | Check NSG, check that BC port (typically 7046/443) is open over VPN |
