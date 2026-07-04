# CyberArk Self-Hosted Lab — VMware Workstation

Automated deployment of a full CyberArk self-hosted environment on VMware Workstation Pro using PowerShell. Builds Windows Server 2022 and Rocky Linux 9 VMs from scratch, promotes a domain controller, and installs Vault, PVWA, CPM, PSM, PTA, and PSMP — all unattended.

---

## Architecture

| VM | Role | IP | RAM | Disk | OS |
|---|---|---|---|---|---|
| DC01 | Active Directory / DNS | 192.168.100.10 | 4 GB | 30 GB | Windows Server 2022 |
| VAULT01 | CyberArk Vault Server | 192.168.100.20 | 4 GB | 30 GB | Windows Server 2022 |
| COMP01 | PVWA + CPM + PSM | 192.168.100.30 | 8 GB | 60 GB | Windows Server 2022 |
| PTA01 | Privileged Threat Analytics (Primary) | 192.168.100.40 | 8 GB | 60 GB | Rocky Linux 9 |
| PTA02 | Privileged Threat Analytics (Secondary / DR) | 192.168.100.41 | 8 GB | 60 GB | Rocky Linux 9 |
| PSMP01 | PSM for SSH Proxy | 192.168.100.50 | 4 GB | 40 GB | Rocky Linux 9 |

**Network:** VMnet8 (NAT), subnet `192.168.100.0/24`  
**Domain:** `cyberark.lab`  
**PVWA:** `https://comp01.cyberark.lab/PasswordVault/v10/logon/cyberark`

> PTA01, PTA02, and PSMP01 are optional. The base lab (DC01 + VAULT01 + COMP01) deploys without them. PTA02 is only needed to test PTA Disaster Recovery — see [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md).

> **PTA VMs require 8 GB RAM each.** At 4 GB the post-install JVM utilities (CSR generation, DR wizards) run out of heap and hang once all PTA services are running.

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
- **Rocky Linux 9 minimal ISO** — required for PTA01 and PSMP01 only:  
  `X:\VMWare\CyberArk-VMware-Lab\ISO\Rocky-9.7-x86_64-minimal.iso`

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
├── PTA\                           # Privileged Threat Analytics (optional)
│   ├── pta_installer.sh
│   ├── pta-<version>.tgz
│   ├── pta-selinux-policy-<version>.el9.noarch.rpm
│   └── sshpass-<version>.el9.x86_64.rpm
├── PSMP\                          # PSM for SSH Proxy (optional)
│   └── ...
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

### Base lab (Vault + PVWA + CPM + PSM)

```powershell
.\Deploy-Lab.ps1
```

### Full lab including PTA and PSMP

```powershell
.\Deploy-Lab.ps1 -Steps Full
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
.\Deploy-Lab.ps1 -Steps CreatePTAVM, PTAInstall
.\Deploy-Lab.ps1 -Steps CreatePSMPVM, PSMPInstall
```

Multiple steps can be combined:
```powershell
.\Deploy-Lab.ps1 -Steps VaultInstall, PVWAInstall, CPMInstall
```

> **PTA scope of `Deploy-Lab.ps1`:** `CreatePTAVM` builds **PTA01** only and `PTAInstall` runs the **Primary** install (`11-InstallPTA-Primary.ps1`). The PTA **Secondary** and **certificate/DR** steps are intentionally *not* orchestrator steps — run them as standalone scripts when testing Disaster Recovery:
> ```powershell
> .\Scripts\10-CreatePTAVM.ps1 -PTANames @("PTA02")          # add the Secondary VM
> .\Scripts\11-InstallPTA-Secondary.ps1                       # install the Secondary
> .\Scripts\11b-ConfigurePTACertificates.ps1 -PrimaryName PTA01 -SecondaryName PTA02
> ```
> See [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md) for the full DR flow.

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
- Joins COMP01 to `cyberark.lab` (VAULT01 stays standalone — Vault must not be domain-joined)
- Reboots after joining

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

### `Scripts\10-CreatePTAVM.ps1` — Create PTA01 VM
- Creates a Rocky Linux 9 VM (PTA01) using a kickstart-based unattended install
- Configures static IP `192.168.100.40`, SSH key pair for automation

### `Scripts\11-InstallPTA-Primary.ps1` — Install PTA Primary
- Copies PTA installer files to PTA01 via SCP
- Runs the PTA installer and post-install configuration wizard
- Registers PTA with Vault and PVWA
- Imports PVWA SSL cert into PTA's JVM cacerts (required for PTA → PVWA HTTPS)
- Imports PTA SSL cert into COMP01's Trusted Root store (required for PVWA → PTA HTTPS)
- Deploys DiamondWebApp (PTA web UI)

### `Scripts\11-InstallPTA-Secondary.ps1` — Install PTA Secondary
- Performs the DR-oriented secondary install flow for PTA02
- Prepares the secondary host for replication and minimal PTA DB operation
- Opens TCP 27017 (MongoDB replication) required for DR pairing

### `Scripts\11b-ConfigurePTACertificates.ps1` — PTA CA Certificates (optional / DR)
- Fully automates issuing CA-signed certificates to PTA from the lab's DC01 Enterprise CA — no manual CSR handling
- Configures the CA: enables SAN-from-request, republishes the CRL, and adds **Client Authentication** EKU to the WebServer template (required — MongoDB DR replication uses the cert as a client cert)
- Creates the shared DR DNS record (`pta.cyberark.lab` → Primary IP) on DC01
- Per PTA server: syncs the clock, generates a CSR, submits it to the CA (`certreq`), and installs the signed chain (root exported as PEM)
- Stores the Vault admin credential in a PVWA safe via REST API as a secure-retrieval demonstration
- Usage: `.\Scripts\11b-ConfigurePTACertificates.ps1 -PrimaryName PTA01 -SecondaryName PTA02` (omit `-SecondaryName` for a single PTA)

### `Scripts\11c-ConfigureVaultSyslogToPTA.ps1` — Vault → PTA Syslog (session monitoring)
Configures the complete Vault→PTA syslog chain so PSM session and Vault audit events reach PTA:
- **PTA side** (via SSH): sets `syslog_inbound` to a plain-TCP listener on 11514 (drops the same-port TLS entry) and `enable_client_verification=false`, then restarts `appmgr` so the unsecured listener binds
- **Vault side** (via vmrun): adds the `AllowNonStandardFWAddresses` rule to `dbparm.ini [MAIN]` (the Vault's hardened firewall blocks its own outbound syslog without it) and writes the `[SYSLOG]` section (`Syslog\PTA.xsl`, PTA IP/port/protocol, message-code filter), then restarts the Vault
- Verifies `Test-NetConnection` Vault→PTA succeeds; backs up both config files first
- Defaults to `11514/TCP` (unsecured, lab). For a secured channel use TLS + a trusted connection
- Wired into `Deploy-Lab.ps1` as the `VaultPTASyslog` step (runs after `PTAInstall` in a Full deploy)
- Usage: `.\Scripts\11c-ConfigureVaultSyslogToPTA.ps1` (or `-PrimaryPTAName PTA01 -SyslogPort 11514 -SyslogProtocol TCP`)

### `Scripts\12-CreatePSMPVM.ps1` — Create PSMP01 VM
- Creates a Rocky Linux 9 VM (PSMP01) using a kickstart-based unattended install
- Configures static IP `192.168.100.50`, SSH key pair for automation

### `Scripts\13-InstallPSMP.ps1` — Install PSMP
- Copies PSMP installer to PSMP01 via SCP
- Installs PSMP and registers it with Vault

### `Scripts\20-CreateVaultADObjects.ps1` — Vault AD groups + users (optional)
- **Opt-in** feature (never auto-run in `All`/`Full`) for the Vault LDAP / AD integration
- Creates an OU and four Vault role groups (Admins, Users, Auditors, Safe Managers), then populates each with users (`vault_admin1..N`, `vault_user1..N`, `vault_auditor1..N`, `vault_safemgr1..N`)
- Uses only the supported ActiveDirectory PowerShell module on DC01 — nothing touched on the appliances, so it's redeploy/upgrade safe. Idempotent (existing objects reused)
- Run via `Deploy-Lab.ps1 -Steps CreateVaultADObjects` or directly: `.\Scripts\20-CreateVaultADObjects.ps1 -UsersPerGroup 10`

---

## Post-Deployment Steps

### PTA — SSL Certificate Trust

Out of the box PTA uses a self-signed certificate, and PVWA validates it before displaying security events — which fails with self-signed certs (**CAWS00001E**). Two options:

**Quick (lab only):** disable validation in PVWA — **Administration → Options → General → SecurityModuleTrustedConnectionEnabled = `No`**, then Apply.

**Proper (automated):** run `11b-ConfigurePTACertificates.ps1` to issue PTA a certificate from the lab's DC01 Enterprise CA. COMP01 (domain-joined) already trusts that CA root, so you can leave `SecurityModuleTrustedConnectionEnabled = Yes`. This is also **required for PTA DR** (the MongoDB replica set uses the cert for X.509 member auth).

### PTA Disaster Recovery (optional)

To pair a Primary + Secondary PTA with MongoDB replication, follow [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md). Summary:

1. `10-CreatePTAVM.ps1 -PTANames @("PTA01","PTA02")` — create both VMs
2. `11-InstallPTA-Primary.ps1` then `11-InstallPTA-Secondary.ps1`
3. `11b-ConfigurePTACertificates.ps1 -PrimaryName PTA01 -SecondaryName PTA02` — certs (with clientAuth EKU) + shared DNS
4. `minimalPrepwiz.sh` on PTA02, then `setupPrimary.sh` on PTA01 (**run each once** — see below)
5. Verify `/opt/pta/mode/primary` (PTA01) and `/opt/pta/mode/secondary` (PTA02)

> **Run the DR wizards once.** `setupPrimary.sh` bootstraps from a clean *standalone* ptadb; a failed re-run leaves ptadb in an uninitialized replica-set state ("not primary"). Recovery without re-imaging: `sed -i '/^replication:/,/replSetName/d' /etc/opt/pta/ptadb/ptadb.conf && systemctl restart ptadb`.

> **Reconnecting a re-imaged PTA to an existing Vault/PVWA:** if PVWA shows the fresh PTA disconnected (JWT `token not valid` / `Error getting Vault Server version`), run `/opt/pta/utility/vaultPermissionsValidation.sh` and answer `y` to recreate the stale `PTAApp` Vault user, restart PTA services, then log in to PVWA to re-sync.

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
| PTA (Primary) | `https://192.168.100.40:8443` |
| PTA (Secondary / DR) | `192.168.100.41` (ptadb only — no web UI by design) |
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
│   ├── 10-CreatePTAVM.ps1
│   ├── 11-InstallPTA-Primary.ps1
│   ├── 11-InstallPTA-Secondary.ps1
│   ├── 11b-ConfigurePTACertificates.ps1
│   ├── 11c-ConfigureVaultSyslogToPTA.ps1
│   ├── README-PTA-DR.md          # PTA Disaster Recovery guide
│   ├── 12-CreatePSMPVM.ps1
│   ├── 13-InstallPSMP.ps1
│   ├── 20-CreateVaultADObjects.ps1   # optional: AD groups/users for Vault LDAP
│   └── Teardown.ps1
├── Templates\
│   └── unattend-base.xml       # Windows unattended install template
├── Installers\                 # CyberArk media — not included, see Prerequisites
└── Deploy-Lab.ps1              # Master orchestrator
```

---

## Notes

- **Deployment time:** ~2–3 hours for base lab; ~3–4 hours for full lab including PTA and PSMP
- **Host RAM:** 16 GB minimum for base lab; 32 GB recommended for full lab. Add a second PTA (PTA02, 8 GB) only when testing DR.
- **Re-runnable:** Every script checks for existing state and skips completed steps, so individual scripts are safe to re-run after a partial failure. **Exception:** the PTA DR wizards (`minimalPrepwiz.sh` / `setupPrimary.sh`) must be run once — see the DR notes above.
- **CyberArk version:** Tested with CyberArk v14/v15 component packages
- **VMnet8 subnet:** Must be configured as `192.168.100.0/24` in VMware Virtual Network Editor before deployment. Without this, the host cannot reach guest VMs over TCP.
- **PTA DR:** Full Disaster Recovery walkthrough and troubleshooting in [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md).
