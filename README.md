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
| CONJUR-L01 | Conjur Enterprise Leader | 192.168.100.60 | 2 vCPU / 4 GB | 20 GB | RHEL 9 |
| CONJUR-S01 / S02 | Conjur Standby ×2 | 192.168.100.61 / .62 | 2 vCPU / 4 GB | 20 GB | RHEL 9 |
| CONJUR-F01 / F02 | Conjur Follower ×2 | 192.168.100.65 / .66 | 2 vCPU / 4 GB | 20 GB | RHEL 9 |
| CONJUR-APP01 | HAProxy LB + demo GitLab runner/k3s workload | 192.168.100.70 | 4 vCPU / 6 GB | 40 GB | RHEL 9 |

**Network:** VMnet8 (NAT), subnet `192.168.100.0/24`  
**Domain:** `cyberark.lab`  
**PVWA:** `https://comp01.cyberark.lab/PasswordVault/v10/logon/cyberark`

> PTA01, PTA02, PSMP01, and the entire Conjur cluster are optional. The base lab (DC01 + VAULT01 + COMP01) deploys without any of them. PTA02 is only needed to test PTA Disaster Recovery — see [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md). The Conjur cluster is a separate opt-in add-on — see [Conjur Enterprise cluster (optional add-on)](#conjur-cluster-deploy) below, and read its prerequisites carefully before starting: **Conjur needs a real RHEL subscription and marketplace-only media that no script can substitute for**, and `CONJUR-L01`'s own unattended-install script (`29-CreateConjurL01VM.ps1`) is untested.

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

<a id="conjur-prereqs"></a>
### Conjur Enterprise (optional add-on) — read before starting

The Conjur cluster has real prerequisites the rest of this lab doesn't, some of which cannot be fully automated or freely obtained. **Do not start the Conjur scripts expecting the same zero-manual-steps experience as the rest of this repo.**

- **A Red Hat subscription (or equivalent RHEL entitlement) — unavoidable, cannot be scripted around.** Conjur nodes run **RHEL 9**, not Rocky Linux — `dnf install podman` and friends need RHSM-registered channels. Rocky's freely-downloadable ISO does not work here. A free [Red Hat Developer](https://developers.redhat.com/) account is enough for lab/personal use and gets you both the RHEL 9.2+ ISO and an activation key (needed below); there is no way around creating one.
- **`CONJUR-L01`'s OS install is now scripted** — `Scripts\29-CreateConjurL01VM.ps1` (kickstart, same proven mechanism as `10-CreatePTAVM.ps1`/`12-CreatePSMPVM.ps1`, RHEL and Rocky share the same installer). **This script is genuinely untested** (no RHEL ISO + activation key were available to exercise it against yet — see its own header for exactly which parts are high-confidence vs. unverified). What it needs from you:
  ```powershell
  .\Scripts\29-CreateConjurL01VM.ps1 -OrgId <your-org-id> -ActivationKey <your-key>
  ```
  - The RHEL 9.2+ ISO, placed per `Config\LabConfig.psd1`'s `ISOs.RHEL9` path.
  - A Red Hat activation key (`-OrgId`/`-ActivationKey`) — create one at [console.redhat.com/insights/connector/activation-keys](https://console.redhat.com/insights/connector/activation-keys), free with a Developer account. Registration happens *during* the unattended install (kickstart's `rhsm` command, RHEL 9.2+) so `open-vm-tools`/`podman` can install from subscribed repos in the same pass — without it, Script 30 has nothing to talk to (guest-ops needs `open-vm-tools` running, and RHEL has no unauthenticated repos to install it from).

  If you'd rather not obtain an activation key, or the script doesn't work against your particular ISO point release, the fallback is what this repo did originally: hand-build a RHEL 9 VM (`CONJUR-L01`, static IP `192.168.100.60`, `open-vm-tools` running, root password matching `-GuestPass`) yourself, then start straight at Script 30.

  Script 30 then generalizes L01 (subscription-manager unregister, machine-id/SSH-host-key reset, hostname reset) and clones it into S01/S02/F01/F02/APP01 — that part is automated and has been run successfully.
- **`subscription-manager register` on every *clone* (S01/S02/F01/F02/APP01) is still manual, on purpose.** Script 29 only registers `CONJUR-L01` itself — generalizing/cloning doesn't re-run a kickstart, so each clone needs its own registration afterward. `Scripts\Register-RHSM.ps1` automates the *mechanics* (drives it over guest-ops, avoids leaking your password into process lists) but still needs **your own Red Hat credentials or activation key** — there's no way to script around needing a real account.
- **The Conjur Enterprise appliance tarball (`conjur-appliance-*.tar.gz`, ~680 MB) and Conjur CLI RPM are not included and cannot be redistributed.** Download them yourself from the [CyberArk Marketplace](https://marketplace.cyberark.com) (same account you use for the PAM installers) and place them at `Installers\Conjur\` — `Scripts\33-CopyConjurAppliance.ps1` picks them up from there.
- **The Vault-Conjur Synchronizer feature needs two more marketplace-only pieces**, only if you want that specific feature (everything else works without it):
  - The Synchronizer installer media itself (`V5SynchronizerInstallation.ps1` and friends) — staged manually, path passed via `-SynchronizerInstallerPath`.
  - The **"CyberArk Digital Vault"** PVWA platform (`PolicyID: CyberArkDigitalVault`) — this lab's Vault does not ship it by default. Download the platform zip from the Marketplace and either import it into PVWA yourself first, or pass `-SynchronizerPlatformZipPath` and `Scripts\40-InstallVaultConjurSynchronizer.ps1` imports it via REST. **This package's license does not permit redistribution — it can never be committed to this repo, gitignored or not.**

None of this is scriptable away — it's how CyberArk licenses this software. Everything else about the Conjur add-on (cloning, networking, HAProxy, DNS, certificates, cluster configuration, root policy) is fully automated once these pieces are in place.

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
> .\Deploy-Optional.ps1 -Feature PTACertificates -PTAPrimaryName PTA01 -PTASecondaryName PTA02
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

### `Scripts\Configure-PTACertificates.ps1` — PTA CA Certificates (optional / DR)
Exposed as the **`PTACertificates`** feature of `Deploy-Optional.ps1`; also runnable directly.
- Fully automates issuing CA-signed certificates to PTA from the lab's DC01 Enterprise CA — no manual CSR handling
- Configures the CA: enables SAN-from-request, republishes the CRL, and adds **Client Authentication** EKU to the WebServer template (required — MongoDB DR replication uses the cert as a client cert)
- Creates the shared DR DNS record (`pta.cyberark.lab` → Primary IP) on DC01
- Per PTA server: syncs the clock, generates a CSR, submits it to the CA (`certreq`), and installs the signed chain (root exported as PEM)
- Stores the Vault admin credential in a PVWA safe via REST API as a secure-retrieval demonstration
- Usage: `.\Deploy-Optional.ps1 -Feature PTACertificates -PTAPrimaryName PTA01 -PTASecondaryName PTA02` (omit secondary for a single PTA)

### `Scripts\Configure-VaultSyslogToPTA.ps1` — Vault → PTA Syslog (session monitoring)
Exposed as the **`VaultPTASyslog`** feature of `Deploy-Optional.ps1`; also runnable directly. Configures the complete Vault→PTA syslog chain so PSM session and Vault audit events reach PTA:
- **PTA side** (via SSH): sets `syslog_inbound` to a plain-TCP listener on 11514 (drops the same-port TLS entry) and `enable_client_verification=false`, then restarts `appmgr` so the unsecured listener binds
- **Vault side** (via vmrun): adds the `AllowNonStandardFWAddresses` rule to `dbparm.ini [MAIN]` (the Vault's hardened firewall blocks its own outbound syslog without it) and writes the `[SYSLOG]` section (`Syslog\PTA.xsl`, PTA IP/port/protocol, message-code filter), then restarts the Vault
- Verifies `Test-NetConnection` Vault→PTA succeeds; backs up both config files first
- Defaults to `11514/TCP` (unsecured, lab). For a secured channel use TLS + a trusted connection
- Usage: `.\Deploy-Optional.ps1 -Feature VaultPTASyslog` (or `-SyslogPort 11514 -SyslogProtocol TCP`)

### `Scripts\12-CreatePSMPVM.ps1` — Create PSMP01 VM
- Creates a Rocky Linux 9 VM (PSMP01) using a kickstart-based unattended install
- Configures static IP `192.168.100.50`, SSH key pair for automation

### `Scripts\13-InstallPSMP.ps1` — Install PSMP
- Copies PSMP installer to PSMP01 via SCP
- Installs PSMP and registers it with Vault

### Conjur Enterprise cluster (`Scripts\30`–`41`, optional add-on)

> `CONJUR-L01` itself needs either `29-CreateConjurL01VM.ps1` (untested, needs a Red Hat activation key) or a hand-built RHEL 9 VM — see the [prerequisites](#conjur-prereqs) above.

- **`29-CreateConjurL01VM.ps1`** — **UNTESTED.** Unattended RHEL 9 kickstart install of `CONJUR-L01` (same isolinux-Tab-injection mechanism as `10-CreatePTAVM.ps1`/`12-CreatePSMPVM.ps1`), including kickstart-time RHSM registration (`rhsm --organization=... --activation-key=...`) so `open-vm-tools`/`podman` install from subscribed repos during the same pass. Needs `-OrgId`/`-ActivationKey` and the RHEL 9.2+ ISO — see prerequisites. Verifies registration/package install actually landed before declaring success, since a bad org/key fails silently otherwise (installer finishes regardless, just without the packages).
- **`30-CloneConjurNodes.ps1`** — generalizes `CONJUR-L01` (subscription-manager unregister, machine-id/SSH-host-key reset, snapshot `generalized`), clones it into S01/S02/F01/F02/APP01, personalizes hostname/IP on each, grows APP01's root filesystem to its larger disk.
- **`Register-RHSM.ps1`** — registers L01 + every clone with Red Hat subscription-manager over guest-ops. Credentials collected once via `Get-Credential` (never touches shell history, disk, or process argv); `-OrgId`/`-ActivationKey` avoids using a personal password entirely.
- **`31-ConfigureLoadBalancer.ps1`** *(feature `LoadBalancer`)* — generic, reusable HAProxy pool configurator. Writes idempotent per-pool config blocks, opens firewalld ports, sets SELinux port labels, always restarts (never reloads — a silent-reload bug was found and fixed here). Not Conjur-specific; used here for the leader pool (equal-priority backends + `/health` HTTP check, matching official Conjur LB guidance) and follower pool (plain TCP check) on `CONJUR-APP01`.
- **`32-CreateConjurSystemFolders.ps1`** *(feature `ConjurSystemFolders`)* — creates `/opt/cyberark/conjur/{security,config,backup,seeds,logs}` on every appliance node (not APP01).
- **`33-CopyConjurAppliance.ps1`** *(feature `ConjurAppliance`)* — real SCP (not guest-ops — the ~680 MB tarball is too large for VIX file transfer), bootstraps SSH key trust first. `-Load` also runs `podman load` + verification. Also stages the Conjur CLI RPM on nodes needing interactive admin access (default: just the Leader).
- **`34-ConfigureConjurDNS.ps1`** *(feature `ConjurDNS`)* — creates per-node A-records plus `conjur-cluster` (leader/standby VIP) and `conjur-follower` (follower VIP) on DC01.
- **`35-InstallConjurLeader.ps1`** *(feature `ConjurInstallLeader`)* — creates the Leader's Podman container (real seccomp profile, `AUDIT_WRITE` capability, `:z` mounts, `podman generate systemd` for reboot survival — all fixes for real Docker-vs-Podman gaps found by testing) and runs `evoke configure master`.
- **`36-ImportConjurCertificates.ps1`** *(feature `ConjurImportCertificates`)* — issues leader/standby and follower certificates from the DC01 Enterprise CA and imports them via `evoke ca import`.
- **`37-EncryptConjurLeaderKeys.ps1`** *(feature `ConjurEncryptKeys`)* — generates a native master key and runs the `evoke keys lock`/`encrypt`/`unlock` cycle. **Unlock does not persist across restarts** — must be re-run after every container/host restart.
- **`38-InstallConjurStandby.ps1`** *(feature `ConjurInstallStandby`)* — seeds and configures a Standby, including a scripted workaround for a real `evoke unpack seed` bug (GNU tar's symlink-chmod call fails under Podman; content lands correctly regardless, only the exit code is wrong — worked around, not silently ignored).
- **`39-InstallConjurFollower.ps1`** *(feature `ConjurInstallFollower`)* — same pattern as Standby, with Follower's real deltas: no `backups` mount, no 5432/1999 published ports, no `evoke ca issue` call, and uses the **shared** `conjur-follower.<domain>` seed identity (not the node's own hostname — Followers share one certificate as a group, unlike Standbys).
- **`40-InstallVaultConjurSynchronizer.ps1`** *(feature `VaultConjurSynchronizer`)* — installs the Vault-Conjur Synchronizer on COMP01: idempotency + partial-install safety checks, an IE-first-launch registry fix (`Invoke-WebRequest` needs it on a fresh Windows Server 2022 build), platform-exists-or-import via PVWA REST, then a non-interactively-driven installer run via real stdin redirection. Needs marketplace-only media — see [prerequisites](#conjur-prereqs).
- **`41-LoadConjurRootPolicy.ps1`** *(feature `ConjurLoadRootPolicy`)* — loads `Policies\{root-bootstrap,admins,root}.yml`: creates `admins`/`apps`/`ops` branch stubs, a self-owning `conjur-admins` group, and delegates `[read,create,update]` on root to it — without ever reassigning root's own `owner:` (stays the built-in `admin` user). Uses only `conjur policy load`/`update` (additive) — never `replace` (the one destructive verb) — against root.

### `Deploy-Optional.ps1` — Optional lab features (AD / LDAP / reconcile)
Single menu/parameter-driven entry point for **opt-in** add-ons that are not part of the base lab. Supported tooling only (ActiveDirectory module on DC01 + PVWA REST) — nothing edited on the appliances, so it's redeploy/upgrade safe. Every feature is idempotent.
- **VaultADObjects** — AD OU + the four Vault role groups (Admins/Users/Auditors/SafeManagers) populated with users (`vault_admin1..N`, etc.)
- **LDAPBindUser** — least-privilege AD bind user (List-Contents) stored as a PVWA account (for Vault/PTA LDAP); optional `-GrantPTAAppUserRead`
- **ReconcileAccount** — AD reconcile account (Reset-Password + pwdLastSet rights) stored in PVWA
- **DiscoveryAccount** — AD accounts-discovery scan account (`svc-discovery`) stored in PVWA
- **PTACertificates** — issue + install CA-signed PTA certs from DC01 (DR-ready) — dispatches to `Scripts\Configure-PTACertificates.ps1`
- **VaultPTASyslog** — configure Vault→PTA syslog forwarding — dispatches to `Scripts\Configure-VaultSyslogToPTA.ps1`
- **ConjurNodes** — generalize `CONJUR-L01` and clone S01/S02/F01/F02/APP01 (see [Conjur Enterprise cluster](#conjur-cluster-deploy))
- **LoadBalancer** — generic, reusable HAProxy pool configurator (not Conjur-specific) — used for the Conjur leader/follower pools on APP01, reusable later for PVWA/PSM pools
- **ConjurSystemFolders** — create the `/opt/cyberark/conjur/{security,config,backup,seeds,logs}` folder set on every Conjur appliance node
- **ConjurAppliance** — copy the Conjur appliance tarball + CLI RPM to the nodes (dispatches to `Scripts\33-CopyConjurAppliance.ps1`, real SCP not guest-ops — the tarball is too large for VIX)
- **ConjurDNS** — create the Conjur A-records (per-node + cluster/follower VIPs) on DC01
- **ConjurInstallLeader** — bring up the Leader container and run `evoke configure master`
- **ConjurImportCertificates** — issue + import DC01 CA-signed leader/follower certs into the Leader
- **ConjurEncryptKeys** — encrypt the Leader's server keys with a native master key
- **ConjurInstallStandby** — create + configure a Standby — pass `-ConjurStandbyVMName`
- **ConjurInstallFollower** — create + configure a Follower — pass `-ConjurFollowerVMName`
- **VaultConjurSynchronizer** — install the Vault-Conjur Synchronizer on COMP01 (needs marketplace-only media — see [Conjur prerequisites](#conjur-prereqs))
- **ConjurLoadRootPolicy** — bootstrap Conjur's root policy (`admins`/`apps`/`ops` branches, self-owning `conjur-admins` group delegated `[read,create,update]` on root) — see the `Policies\` folder

```powershell
.\Deploy-Optional.ps1                                   # interactive menu
.\Deploy-Optional.ps1 -ListFeatures
.\Deploy-Optional.ps1 -Feature VaultADObjects,LDAPBindUser -GrantPTAAppUserRead
.\Deploy-Optional.ps1 -Feature ReconcileAccount
.\Deploy-Optional.ps1 -Feature DiscoveryAccount
.\Deploy-Optional.ps1 -Feature PTACertificates -PTAPrimaryName PTA01 -PTASecondaryName PTA02
.\Deploy-Optional.ps1 -Feature VaultPTASyslog
.\Deploy-Optional.ps1 -Feature ConjurLoadRootPolicy
```
> The final config — Vault external directory + AD-group→authorization mapping, linking the reconcile account to a platform, and referencing the discovery account in an Accounts Discovery scan (plus scan rights on the targets) — is done in PrivateArk Client / PVWA (supported UI; no REST endpoint), so it is not scripted.

---

## Post-Deployment Steps

### PTA — SSL Certificate Trust

Out of the box PTA uses a self-signed certificate, and PVWA validates it before displaying security events — which fails with self-signed certs (**CAWS00001E**). Two options:

**Quick (lab only):** disable validation in PVWA — **Administration → Options → General → SecurityModuleTrustedConnectionEnabled = `No`**, then Apply.

**Proper (automated):** run `.\Deploy-Optional.ps1 -Feature PTACertificates` to issue PTA a certificate from the lab's DC01 Enterprise CA. COMP01 (domain-joined) already trusts that CA root, so you can leave `SecurityModuleTrustedConnectionEnabled = Yes`. This is also **required for PTA DR** (the MongoDB replica set uses the cert for X.509 member auth).

### PTA Disaster Recovery (optional)

To pair a Primary + Secondary PTA with MongoDB replication, follow [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md). Summary:

1. `10-CreatePTAVM.ps1 -PTANames @("PTA01","PTA02")` — create both VMs
2. `11-InstallPTA-Primary.ps1` then `11-InstallPTA-Secondary.ps1`
3. `.\Deploy-Optional.ps1 -Feature PTACertificates -PTAPrimaryName PTA01 -PTASecondaryName PTA02` — certs (with clientAuth EKU) + shared DNS
4. `minimalPrepwiz.sh` on PTA02, then `setupPrimary.sh` on PTA01 (**run each once** — see below)
5. Verify `/opt/pta/mode/primary` (PTA01) and `/opt/pta/mode/secondary` (PTA02)

> **Run the DR wizards once.** `setupPrimary.sh` bootstraps from a clean *standalone* ptadb; a failed re-run leaves ptadb in an uninitialized replica-set state ("not primary"). Recovery without re-imaging: `sed -i '/^replication:/,/replSetName/d' /etc/opt/pta/ptadb/ptadb.conf && systemctl restart ptadb`.

> **Reconnecting a re-imaged PTA to an existing Vault/PVWA:** if PVWA shows the fresh PTA disconnected (JWT `token not valid` / `Error getting Vault Server version`), run `/opt/pta/utility/vaultPermissionsValidation.sh` and answer `y` to recreate the stale `PTAApp` Vault user, restart PTA services, then log in to PVWA to re-sync.

<a id="conjur-cluster-deploy"></a>
### Conjur Enterprise cluster (optional add-on)

**Read the [Conjur Enterprise prerequisites](#conjur-prereqs) above first** — a Red Hat subscription, a hand-built `CONJUR-L01` VM, and marketplace-only media are all required before script 30 will do anything useful.

Once `CONJUR-L01` exists (RHEL 9, static IP `192.168.100.60`, `open-vm-tools` running — either via Script 29, untested, or hand-built, see above) and `Installers\Conjur\` has the appliance tarball + CLI RPM, the rest is scripted, in this order:

```powershell
# 0. Create CONJUR-L01 itself (skip if you hand-built it instead - see prerequisites)
.\Scripts\29-CreateConjurL01VM.ps1 -OrgId <your-org-id> -ActivationKey <your-key>

# 1. Clone L01 into S01/S02/F01/F02/APP01 (generalizes L01 first)
.\Scripts\30-CloneConjurNodes.ps1

# 2. Register every node with Red Hat (prompts once for credentials, reuses them)
.\Scripts\Register-RHSM.ps1

# 3. Networking: HAProxy on APP01 (leader + follower pools), system folders, DNS
.\Deploy-Optional.ps1 -Feature LoadBalancer
.\Deploy-Optional.ps1 -Feature ConjurSystemFolders
.\Deploy-Optional.ps1 -Feature ConjurDNS

# 4. Stage the appliance image on every node + the CLI on the Leader
.\Scripts\33-CopyConjurAppliance.ps1 -VMNames CONJUR-L01,CONJUR-S01,CONJUR-S02,CONJUR-F01,CONJUR-F02 -Load

# 5. Bring up the Leader, import CA-signed certs, set up native key encryption
.\Deploy-Optional.ps1 -Feature ConjurInstallLeader
.\Deploy-Optional.ps1 -Feature ConjurImportCertificates
.\Deploy-Optional.ps1 -Feature ConjurEncryptKeys

# 6. Standbys + Followers
.\Deploy-Optional.ps1 -Feature ConjurInstallStandby -ConjurStandbyVMName CONJUR-S01
.\Deploy-Optional.ps1 -Feature ConjurInstallStandby -ConjurStandbyVMName CONJUR-S02
.\Deploy-Optional.ps1 -Feature ConjurInstallFollower -ConjurFollowerVMName CONJUR-F01
.\Deploy-Optional.ps1 -Feature ConjurInstallFollower -ConjurFollowerVMName CONJUR-F02

# 7. Root policy — admins/apps/ops branches, self-owning admin group delegated on root
.\Deploy-Optional.ps1 -Feature ConjurLoadRootPolicy

# 8. Optional: Vault-Conjur Synchronizer on COMP01 (needs its own marketplace media — see prerequisites)
.\Deploy-Optional.ps1 -Feature VaultConjurSynchronizer -SynchronizerPlatformZipPath <path-to-platform.zip>
```

Verify: `https://conjur-cluster.cyberark.lab/health` (leader/standby pool, via HAProxy on APP01) and `https://conjur-cluster.cyberark.lab/ui` should both work from a domain-joined machine (e.g. DC01) with no certificate warning.

> No dedicated load-balancer VM — HAProxy runs on `CONJUR-APP01` (`LoadBalancer` feature, a generic reusable HAProxy-pool configurator, not Conjur-specific). `ConjurLoadRootPolicy` only builds the `admins`/`apps`/`ops` branch structure and delegates administration to a `conjur-admins` group — it does not load any application-specific policy (that's expected to be client/project-specific and out of scope for a generic lab).

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
│   ├── Configure-PTACertificates.ps1
│   ├── Configure-VaultSyslogToPTA.ps1
│   ├── README-PTA-DR.md          # PTA Disaster Recovery guide
│   ├── 12-CreatePSMPVM.ps1
│   ├── 13-InstallPSMP.ps1
│   ├── 29-CreateConjurL01VM.ps1       ┐
│   ├── 30-CloneConjurNodes.ps1        │
│   ├── Register-RHSM.ps1              │
│   ├── 31-ConfigureLoadBalancer.ps1   │
│   ├── 32-CreateConjurSystemFolders.ps1
│   ├── 33-CopyConjurAppliance.ps1     │  Conjur Enterprise cluster
│   ├── 34-ConfigureConjurDNS.ps1      │  (optional add-on — see
│   ├── 35-InstallConjurLeader.ps1     │  Prerequisites + its own
│   ├── 36-ImportConjurCertificates.ps1│  README section)
│   ├── 37-EncryptConjurLeaderKeys.ps1 │
│   ├── 38-InstallConjurStandby.ps1    │
│   ├── 39-InstallConjurFollower.ps1   │
│   ├── 40-InstallVaultConjurSynchronizer.ps1
│   ├── 41-LoadConjurRootPolicy.ps1    ┘
│   └── Teardown.ps1
├── Policies\                    # Conjur root policy YAML (loaded by Script 41)
│   ├── root-bootstrap.yml
│   ├── admins.yml
│   └── root.yml
├── Templates\
│   └── unattend-base.xml       # Windows unattended install template
├── Installers\                 # CyberArk media — not included, see Prerequisites
├── Deploy-Lab.ps1              # Master orchestrator (base lab)
└── Deploy-Optional.ps1         # Optional opt-in features (AD/LDAP/reconcile/Conjur)
```

---

## Notes

- **Deployment time:** ~2–3 hours for base lab; ~3–4 hours for full lab including PTA and PSMP
- **Host RAM:** 16 GB minimum for base lab; 32 GB recommended for full lab. Add a second PTA (PTA02, 8 GB) only when testing DR.
- **Re-runnable:** Every script checks for existing state and skips completed steps, so individual scripts are safe to re-run after a partial failure. **Exception:** the PTA DR wizards (`minimalPrepwiz.sh` / `setupPrimary.sh`) must be run once — see the DR notes above.
- **CyberArk version:** Tested with CyberArk v14/v15 component packages
- **VMnet8 subnet:** Must be configured as `192.168.100.0/24` in VMware Virtual Network Editor before deployment. Without this, the host cannot reach guest VMs over TCP.
- **PTA DR:** Full Disaster Recovery walkthrough and troubleshooting in [Scripts/README-PTA-DR.md](Scripts/README-PTA-DR.md).
- **Conjur is genuinely more manual to start than the rest of this lab.** `CONJUR-L01`'s own creation (`29-CreateConjurL01VM.ps1`) is unattended but untested and needs a Red Hat activation key; the appliance/CLI/Synchronizer media are marketplace-only and cannot be redistributed regardless — read the [Conjur prerequisites](#conjur-prereqs) fully before starting. Once L01 exists and media is staged, everything from cloning through root-policy load is scripted, idempotent, and has been run and verified end-to-end.
- **Conjur automation testing status:** the container/`evoke configure`/certificate-import/key-encryption/HAProxy/DNS/replication path (Leader + 2 Standbys + 2 Followers) and the root-policy load (Script 41) have been run and verified end-to-end against a live cluster. `Scripts\40-InstallVaultConjurSynchronizer.ps1`'s non-interactive installer automation (Phase 5, stdin-redirected) has **not** been exercised end-to-end as automation — every real run so far already had the Synchronizer installed, so only its idempotency path is confirmed. If you hit an issue running it fresh, that's the most likely place — feedback/PRs welcome.
- **Podman version note:** CyberArk's own Conjur training material certifies Podman 3.3/3.4; this lab has been run successfully against Podman 5.8.2 (RHEL 9.8), but always check `docs.cyberark.com` for your installed appliance version's actual supported-platform matrix rather than relying on this note.
