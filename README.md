# CyberArk Self-Hosted Lab — VMware Workstation

Automated deployment of a full CyberArk self-hosted environment on VMware Workstation Pro using PowerShell. Builds three Windows Server 2022 VMs from scratch, promotes a domain controller, and installs Vault, PVWA, CPM, and PSM — all unattended.

---

## Architecture

| VM | Role | IP | RAM | Disk |
|---|---|---|---|---|
| DC01 | Active Directory / DNS | 192.168.100.10 | 4 GB | 30 GB |
| VAULT01 | CyberArk Vault Server | 192.168.100.20 | 4 GB | 30 GB |
| COMP01 | PVWA + CPM + PSM | 192.168.100.30 | 8 GB | 60 GB |

**Network:** VMnet8 (NAT), subnet `192.168.100.0/24`  
**Domain:** `cyberark.lab`  
**PVWA:** `https://comp01.cyberark.lab/PasswordVault/v10/logon/cyberark`

---

## Prerequisites

### Software (on the host machine)

- **VMware Workstation Pro** 17 or later — vmrun.exe must be at the default path:  
  `C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe`
- **PowerShell 5.1** (built into Windows) — run as **Administrator**
- **Windows Server 2022 Evaluation ISO** — free download from Microsoft:  
  [https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022)  
  Download the **64-bit ISO** edition. Place it at:  
  `X:\VMWare\CyberArk-VMware-Lab\ISO\SERVER_EVAL_x64FRE_en-us.iso`  
  *(path is configurable in `Config\LabConfig.psd1`)*

### CyberArk Installation Files

CyberArk installers require a valid partner or customer account. Download from the **CyberArk Marketplace**:  
[https://marketplace.cyberark.com](https://marketplace.cyberark.com)

Download the **Self-Hosted PAM** package for your version (v14 or v15). The zip contains separate installer folders for Vault, PVWA, CPM, and PSM — extract them into `Installers\` following the folder structure shown below.

### CyberArk Vault Keys and License

The Vault requires cryptographic key files and a license file before it can start. These are provided separately from the installer.

**License:** Obtained from CyberArk when you register your deployment. Place it at:
```
Installers\License\License.xml
```

**Vault keys:** Generated using the **PAKeyGenerator** utility, included in the Vault installer package. Run it once on any Windows machine to produce the master and operator key sets:

1. Extract the Vault installer package
2. Locate `PAKeyGenerator.exe` (typically in the `Server\` folder)
3. Run it and follow the prompts — it will generate two sets of key files
4. Place the output into:
   ```
   Installers\keys\master\     ← master key set (recprv.key, recpub.key, rndbase.dat, server.key)
   Installers\keys\operator\   ← operator key set (recpub.key, rndbase.dat, server.key)
   ```

Full documentation for PAKeyGenerator:  
[https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/pakeygenerator-utility.htm](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/pakeygenerator-utility.htm)

> Keep the master key set secure — it is required to recover the Vault if the operator key is lost. In a lab environment, store both sets locally.

### Host WinRM Configuration (required — one-time manual setup)

`01-CreateBaseVM.ps1` connects to the template VM over WinRM to install VMware Tools. Before running the deployment, run the following commands **on the host machine as Administrator**:

```powershell
# 1. Enable WinRM on the host
winrm quickconfig -q

# 2. Trust hosts for WinRM connections — choose one option:

# Option A (simplest): trust all hosts — safe for a private lab network
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force

# Option B (specific IP): trust only the template VM's IP
#   Boot the template VM from the ISO once, check the IP it receives via DHCP
#   (visible in VMware or via ipconfig inside the VM), then use that IP here
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<template-vm-ip>' -Force
```

WinRM on the **guest VMs** is configured automatically by the unattended install (`unattend-base.xml` runs `Enable-PSRemoting` and `winrm quickconfig` on first boot) — no manual steps required inside any VM.

### CyberArk Installer Files

You need a valid CyberArk license and installer package (v14+). Place files under `Installers\` with this exact structure:

```
Installers\
├── Server\                        # Vault server
│   ├── setup.exe
│   └── ...
├── Client\Client\                 # PrivateArk Client
│   ├── setup.exe
│   └── ...
├── PVWA\                          # PVWA component
│   └── InstallationAutomation\
│       ├── PVWA_Prerequisites.ps1
│       ├── PVWAInstallation.ps1
│       ├── PVWARegisterComponent.ps1
│       ├── PVWA_Hardening.ps1
│       └── Registration\
│           └── PVWARegisterComponentConfig.xml
├── CPM\                           # Central Policy Manager
│   └── InstallationAutomation\
│       ├── CPM_PreInstallation.ps1
│       ├── CPMInstallation.ps1
│       ├── CPMRegisterCommponent.ps1
│       ├── CPM_Hardening.ps1
│       └── Registration\
│           └── CPMRegisterComponentConfig.xml
├── PSM\                           # Privileged Session Manager
│   └── InstallationAutomation\
│       ├── Execute-Stage.ps1
│       ├── Readiness\
│       ├── Prerequisites\
│       ├── Installation\
│       ├── PostInstallation\
│       ├── Hardening\
│       └── Registration\
│           └── RegistrationConfig.xml
├── keys\
│   ├── master\                    # recprv.key, recpub.key, rndbase.dat, server.key
│   └── operator\                  # recpub.key, rndbase.dat, server.key
└── License\
    └── License.xml
```

### Silent Install Response Files

The Vault installer uses two recorded response files (`Helpers\setup.iss` and `Helpers\Setup-client.iss`) to drive the silent install. **Both files are already included in this repo** — no action needed.

If you ever switch to a different CyberArk version and the installer wizard changes, regenerate them by running the installer in record mode:

```powershell
# Record Vault server install
.\Installers\Server\setup.exe /r /f1".\Helpers\setup.iss"

# Record PrivateArk Client install
.\Installers\Client\Client\setup.exe /r /f1".\Helpers\Setup-client.iss"
```

---

## Configuration

### `Config\LabConfig.psd1`
Main configuration — VM specs, network, domain, and media paths.

| Setting | Default | Description |
|---|---|---|
| `VMware.DefaultVMFolder` | `F:\VMs\CyberArk` | Where VM files are created |
| `VMware.TemplateName` | `WS2022-Tmpl` | Name of the base template VM |
| `Domain.Name` | `cyberark.lab` | AD domain FQDN |
| `Domain.DomainAdminPass` | `Cyberark!Local2024` | Domain admin password |
| `LocalAdmin.Password` | `Cyberark!Local2024` | Local admin password on all VMs |
| `CyberArkMedia.BasePath` | `F:\VMWare\CyberArk-VMware-Lab\Installers` | Root of installer files |

### `Config\CyberArkConfig.psd1`
CyberArk-specific settings — Vault address, admin credentials, component install paths.

| Setting | Default | Description |
|---|---|---|
| `Vault.AdminPassword` | `Cyberark1` | Vault Administrator password |
| `Vault.MasterPassword` | `Cyberark1` | Vault Master password |
| `Vault.VaultAddress` | `192.168.100.20` | VAULT01 IP |
| `Vault.VaultPort` | `1858` | Vault communication port |

---

## Deployment

### Full deployment (all steps)

```powershell
.\Deploy-Lab.ps1
```

### Individual steps

```powershell
.\Deploy-Lab.ps1 -Steps BaseVM
.\Deploy-Lab.ps1 -Steps DeployVMs
.\Deploy-Lab.ps1 -Steps DomainController
.\Deploy-Lab.ps1 -Steps DomainJoin
.\Deploy-Lab.ps1 -Steps VaultInstall
.\Deploy-Lab.ps1 -Steps PVWAInstall
.\Deploy-Lab.ps1 -Steps CPMInstall
.\Deploy-Lab.ps1 -Steps PSMInstall
```

Multiple steps can be combined:
```powershell
.\Deploy-Lab.ps1 -Steps VaultInstall, PVWAInstall, CPMInstall
```

---

## What Each Script Does

### `Scripts\01-CreateBaseVM.ps1` — Base Template VM
- Creates a new VM (`WS2022-Tmpl`) in VMware Workstation
- Generates an unattended install ISO using Windows IMAPI2 (no external tools needed)
- Boots from the Windows Server 2022 ISO and performs a fully unattended OS install
- Installs VMware Tools via WinRM
- Sysprepped and powered off — ready to clone

### `Scripts\02-DeployVMs.ps1` — Deploy Lab VMs
- Clones `WS2022-Tmpl` into DC01, VAULT01, and COMP01 as linked clones
- Configures each VM with static IP, hostname, and DNS via guest PowerShell
- Saves VM paths to `Config\DeployedVMs.xml` for use by subsequent scripts

### `Scripts\04-DeployDC.ps1` — Domain Controller
- Installs the AD DS role on DC01
- Promotes DC01 to a domain controller for `cyberark.lab`
- Configures DNS and waits for AD services to stabilise
- Reboots automatically

### `Scripts\05-DomainJoin.ps1` — Domain Join
- Joins VAULT01 and COMP01 to `cyberark.lab`
- Reboots each VM after joining

### `Scripts\06-InstallVault.ps1` — CyberArk Vault
- Copies Vault installer, keys, and license file to VAULT01
- Runs `setup.exe` silently using the recorded `Helpers\setup.iss`
- Installs PrivateArk Client using `Helpers\Setup-client.iss`
- Opens port 1858 in Windows Firewall
- Reboots VAULT01

### `Scripts\07-InstallPVWA.ps1` — PVWA
- Transfers and extracts the PVWA installer to COMP01
- Runs `PVWA_Prerequisites.ps1` (IIS, .NET, Windows features)
- Runs `PVWAInstallation.ps1`
- Patches registration config with Vault IP and admin user
- Runs `PVWARegisterComponent.ps1` to register with Vault
- Runs `PVWA_Hardening.ps1` (TLS, IIS header suppression)
- Adds an Edge bookmark on the host: `https://comp01.cyberark.lab/PasswordVault/v10/logon/cyberark`

### `Scripts\08-InstallCPM.ps1` — CPM
- Transfers and extracts the CPM installer to COMP01
- Runs `CPM_PreInstallation.ps1`
- Runs `CPMInstallation.ps1`
- Patches registration config and runs `CPMRegisterCommponent.ps1`
- Runs `CPM_Hardening.ps1`

### `Scripts\09-InstallPSM.ps1` — PSM
- Installs the RDS-RD-Server Windows role (required by PSM) and reboots if needed
- Transfers and extracts the PSM installer to COMP01
- Pre-reboot stages: Readiness check → Prerequisites → Installation (may trigger another reboot)
- Post-reboot stages: PostInstallation → Hardening → Registration with Vault

---

## Teardown

Destroys all lab VMs and frees disk space. The base template is preserved by default.

```powershell
# Destroy lab VMs (prompts for confirmation)
.\Scripts\Teardown.ps1

# Destroy lab VMs without prompt
.\Scripts\Teardown.ps1 -Force

# Also destroy the base template
.\Scripts\Teardown.ps1 -Force -IncludeTemplate
```

If VMs fail to start after a host reboot or crash, stale VMware lock files may need clearing:

```powershell
# Find and remove stale lock files across all VMs
Get-ChildItem "F:\VMs\CyberArk" -Recurse -Filter "*.lck" | Remove-Item -Recurse -Force
```

---

## Accessing the Lab

| Resource | URL / Address |
|---|---|
| PVWA | `https://comp01.cyberark.lab/PasswordVault/v10/logon/cyberark` |
| Vault | `192.168.100.20:1858` |
| Domain | `cyberark.lab` |
| Admin user | `CYBERARKLAB\Administrator` |

> The PVWA certificate (`comp01.cyberark.lab`) is trusted automatically by Windows during installation. Access via the hostname above to avoid browser warnings.

---

## Repository Structure

```
CyberArk-VMware-Lab\
├── Config\
│   ├── LabConfig.psd1          # VM, network, domain settings
│   └── CyberArkConfig.psd1     # CyberArk component settings
├── Helpers\
│   ├── VMwareHelper.psm1       # vmrun wrapper, VM lifecycle functions
│   ├── GuestHelper.psm1        # Guest file copy, WinRM helpers
│   ├── RemotingHelper.psm1     # PowerShell remoting helpers
│   ├── CyberArkHelper.psm1     # CyberArk service/credential helpers
│   ├── NetworkHelper.psm1      # Network connectivity helpers
│   ├── setup.iss               # Recorded silent install — Vault server
│   └── Setup-client.iss        # Recorded silent install — PrivateArk Client
├── Scripts\
│   ├── 01-CreateBaseVM.ps1
│   ├── 02-DeployVMs.ps1
│   ├── 04-DeployDC.ps1
│   ├── 05-DomainJoin.ps1
│   ├── 06-InstallVault.ps1
│   ├── 07-InstallPVWA.ps1
│   ├── 08-InstallCPM.ps1
│   ├── 09-InstallPSM.ps1
│   └── Teardown.ps1
├── Templates\
│   └── unattend-base.xml       # Windows unattended install template
├── Installers\                 # CyberArk media — not included, see Prerequisites
└── Deploy-Lab.ps1              # Master orchestrator
```

---

## Notes

- **Deployment time:** ~1 hour end-to-end on an SSD
- **Host RAM:** 16 GB minimum recommended (VMs use ~16 GB combined when all running)
- **Re-runnable:** Every script checks for existing state and skips completed steps, so individual scripts are safe to re-run after a partial failure
- **CyberArk version:** Tested with CyberArk v14/v15 component packages
