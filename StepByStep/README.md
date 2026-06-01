# AVD Deployment Scripts
## 25 Users · Hybrid Entra Join · Denmark East · FSLogix on Azure Files

Automated deployment scripts for the AVD environment. Run them in order, phase by phase.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.x or Windows PowerShell 5.1 |
| Az PowerShell module | `Install-Module Az -Scope CurrentUser` |
| RSAT (AD tools) | Required for Phase 1 — run from a domain-joined machine |
| AzFilesHybrid module | Downloaded in Phase 4 — run from a domain-joined machine |
| Azure access | Contributor on the subscription |

---

## Quick Start

1. **Edit `config.ps1`** — fill in your customer's values (domain, VPN, IP ranges, etc.)
2. Run each script in order from an elevated PowerShell prompt
3. Scripts that must run **on-prem (domain-joined)**: `01`, `04`, `07`
4. Scripts that run **inside the image build VM**: `05-image-prep.ps1`
5. All other scripts run from **any machine with Az module + internet access**

---

## Script Order

| Script | Phase | Where to run |
|---|---|---|
| `01-ad-prep.ps1` | AD Preparation | Domain-joined machine (on-prem) |
| `02-check-prereqs.ps1` | Azure Prerequisites | Any machine |
| `03-networking.ps1` | Azure Networking | Any machine |
| `04-azure-files.ps1` | FSLogix Storage | Domain-joined machine (on-prem) |
| `05-create-gallery.ps1` | Create Image Gallery | Any machine |
| `05-image-prep.ps1` | Golden Image Build | **Inside the build VM** (RDP in) |
| `06-deploy-hostpool.ps1` | Host Pool + Session Hosts | Any machine |
| `07-fslogix-gpo.ps1` | FSLogix GPO | Domain Controller or RSAT machine |
| `08-appgroups.ps1` | App Groups + Workspace | Any machine |
| `09-monitoring.ps1` | Monitoring + Alerts | Any machine |

---

## After Deployment

- Add/remove users: modify group membership of `GRP-AVD-Users` in Active Directory
- Update image: re-run from `05-create-gallery.ps1`, then re-image session hosts via AVD Portal
- Decommission Citrix: after 2–4 weeks parallel run, confirm with customer before shutting down

---

## Key Resource Names

| Resource | Name | Resource Group |
|---|---|---|
| Resource Group (services) | `rg-contoso-avd-avdresources` | – |
| Resource Group (VMs) | `rg-contoso-avd-hosts` | – |
| Virtual Network | `vnet-contoso-dke` | `rg-contoso-avd-avdresources` |
| Storage Account | `stacontosoprofiles` | `rg-contoso-avd-avdresources` |
| Azure Compute Gallery | `acg_contoso_avd` | `rg-contoso-avd-avdresources` |
| Host Pool | `hp-contosogrp` | `rg-contoso-avd-avdresources` |
| Workspace | `ws-contosogrp` | `rg-contoso-avd-avdresources` |
| App Group (apps) | `ag-contosogrp-apps` | `rg-contoso-avd-avdresources` |
| App Group (desktop) | `ag-contosogrp-desktop` | `rg-contoso-avd-avdresources` |
| Log Analytics | `law-contoso-avd` | `rg-contoso-avd-avdresources` |
| Session Hosts (VMs) | `contosogrp-sh-0`, `contosogrp-sh-1` | `rg-contoso-avd-hosts` |

> **Why two RGs?** Session hosts get rebuilt periodically. Keeping VMs in `rg-contoso-avd-hosts` lets you delete and redeploy all compute without affecting the host pool, app groups, profiles, or workspace in `rg-contoso-avd-avdresources`.
