# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-07-30

### Added
- **Conjur Enterprise HA cluster** — a full optional add-on: Leader + 2 Standbys + 2 Followers, HAProxy load balancing, DNS, CA-signed certificates, native key encryption, and initial root policy. `CONJUR-L01` can be built via `29-CreateConjurL01VM.ps1` (untested, needs a Red Hat activation key) or by hand — either way it needs a real Red Hat subscription plus CyberArk Marketplace media, neither of which can be scripted around — see the README's Conjur prerequisites section.
  - `Scripts\29-CreateConjurL01VM.ps1` — **UNTESTED**, feedback welcome. Unattended RHEL 9 kickstart install of `CONJUR-L01` (same isolinux-Tab-injection mechanism as `10-CreatePTAVM.ps1`/`12-CreatePSMPVM.ps1`), including kickstart-time RHSM registration via activation key so `open-vm-tools`/`podman` install from subscribed repos during the same pass — retroactively removes what used to be this feature's one fully-manual step. Still needs a real Red Hat account/activation key and a RHEL 9.2+ ISO, neither of which can be scripted around; falls back to hand-building L01 if you'd rather not use it.
  - `Scripts\30-CloneConjurNodes.ps1` — generalizes `CONJUR-L01` (built by Script 29 or by hand) and clones S01/S02/F01/F02/APP01.
  - `Scripts\Register-RHSM.ps1` — drives `subscription-manager register` over guest-ops (credentials collected once via `Get-Credential`, or `-OrgId`/`-ActivationKey` for no personal-credential exposure at all).
  - `Scripts\31-ConfigureLoadBalancer.ps1` (feature **LoadBalancer**) — generic, reusable HAProxy pool configurator (not Conjur-specific); used for the leader (equal-priority + `/health` httpcheck, matching official CyberArk LB guidance) and follower pools on `CONJUR-APP01`.
  - `Scripts\32`–`37` (features **ConjurSystemFolders**, **ConjurAppliance**, **ConjurDNS**, **ConjurInstallLeader**, **ConjurImportCertificates**, **ConjurEncryptKeys**) — system folders, appliance/CLI staging via real SCP, DNS records, Leader container + `evoke configure master`, CA-signed cert import, native master-key encryption.
  - `Scripts\38-InstallConjurStandby.ps1` / `Scripts\39-InstallConjurFollower.ps1` (features **ConjurInstallStandby** / **ConjurInstallFollower**) — seed + configure Standby/Follower nodes, including a scripted workaround for a real `evoke unpack seed` tar/symlink bug and the correct shared seed identity for Followers.
  - `Scripts\40-InstallVaultConjurSynchronizer.ps1` (feature **VaultConjurSynchronizer**) — installs the Vault-Conjur Synchronizer on COMP01 (idempotency/partial-install checks, IE-first-launch registry fix, platform-import via PVWA REST). Needs marketplace-only installer media and the "CyberArk Digital Vault" platform, neither of which can be redistributed. Its non-interactive installer automation (stdin-redirected) is not yet exercised end-to-end — flagged in the script header, feedback welcome.
  - `Scripts\41-LoadConjurRootPolicy.ps1` (feature **ConjurLoadRootPolicy**) + `Policies\{root-bootstrap,admins,root}.yml` — bootstraps `admins`/`apps`/`ops` branches and a self-owning `conjur-admins` group delegated `[read,create,update]` on root, without ever reassigning root's own owner. Verified end-to-end against a live cluster, including independent confirmation via `conjur policy fetch` that owner re-parenting via `update` actually takes effect.

## [1.4.0] - 2026-07-04

### Added
- `Deploy-Optional.ps1` — single menu/parameter-driven entry point for opt-in optional features, using supported tooling only (ActiveDirectory module + PVWA REST), idempotent, with WinRM retry and version-safe (PS 5.1/7) PVWA calls:
  - **VaultADObjects** — AD OU + Vault role groups + users.
  - **LDAPBindUser** — least-privilege AD bind user (List-Contents) stored as a PVWA account.
  - **ReconcileAccount** — AD reconcile account (Reset-Password + pwdLastSet rights) stored in PVWA.
  - **DiscoveryAccount** — AD accounts-discovery scan account (`svc-discovery`) stored in PVWA.
  - **PTACertificates** / **VaultPTASyslog** — expose the PTA-certificate and Vault→PTA-syslog scripts as Deploy-Optional features (dispatch to the backend scripts).

### Changed
- Renamed `Scripts/11b-ConfigurePTACertificates.ps1` → `Scripts/Configure-PTACertificates.ps1` and `Scripts/11c-ConfigureVaultSyslogToPTA.ps1` → `Scripts/Configure-VaultSyslogToPTA.ps1` (drop the b/c suffix; now dispatched from `Deploy-Optional.ps1`).

### Removed
- `Scripts/20-CreateVaultADObjects.ps1` (folded into `Deploy-Optional.ps1`) and the `Deploy-Lab.ps1` `CreateVaultADObjects` + `VaultPTASyslog` steps — optional features now live in `Deploy-Optional.ps1`.

## [1.3.0] - 2026-07-04

### Added
- `Scripts/20-CreateVaultADObjects.ps1` — optional, opt-in feature that creates an AD OU + the four Vault role groups (Admins/Users/Auditors/SafeManagers) and populates them with users (`vault_admin1..N`, etc.) for the Vault LDAP integration. Supported ActiveDirectory module only (redeploy/upgrade safe); idempotent.
- `Deploy-Lab.ps1` `CreateVaultADObjects` step (opt-in only — never auto-runs in `All`/`Full`).

## [1.2.0] - 2026-07-04

### Added
- `Scripts/11c-ConfigureVaultSyslogToPTA.ps1` — configures the complete Vault→PTA syslog chain for PSM session / Vault audit monitoring:
  - PTA side: `syslog_inbound` plain-TCP listener on 11514 + `enable_client_verification=false`, restart `appmgr`.
  - Vault side: `AllowNonStandardFWAddresses` firewall rule in `dbparm.ini [MAIN]` (required — the Vault firewall otherwise blocks its own outbound syslog) + `[SYSLOG]` section (`Syslog\PTA.xsl`), restart the Vault.
  - Verifies Vault→PTA reachability; backs up both config files. Defaults to `11514/TCP` (unsecured).
- `Deploy-Lab.ps1` `VaultPTASyslog` step (runs after `PTAInstall` in a Full deploy).

## [1.1.0] - 2026-07-04

### Added
- **PTA Disaster Recovery** support (Primary + Secondary with MongoDB replication).
  - `Scripts/11-InstallPTA-Primary.ps1` and `Scripts/11-InstallPTA-Secondary.ps1` (split from the former `11-InstallPTA.ps1`).
  - `Scripts/11b-ConfigurePTACertificates.ps1` — end-to-end CA certificate automation against the DC01 Enterprise CA (CSR generation, `certreq` submission, signed-chain install), shared DR DNS record creation, and Vault-admin credential storage via PVWA REST API.
  - `Scripts/README-PTA-DR.md` — full DR deployment and troubleshooting guide.
  - `PTA02` VM definition (192.168.100.41) in `Config/LabConfig.psd1`.
- `10-CreatePTAVM.ps1` supports multiple PTAs via `-PTANames`, with chrony time sync from DC01 and TCP 27017 opened in the kickstart firewall.

### Changed
- **PTA VMs bumped from 4 GB to 8 GB RAM.** At 4 GB the post-install JVM utilities (CSR generation, DR wizards) exhaust heap and hang once all PTA services are running.
- WebServer certificate template now carries **Client Authentication** EKU (required — MongoDB DR replication uses the PTA cert as a client cert for X.509 member auth).
- README documents PTA DR, the certificate automation, and the reconnect procedure for a re-imaged PTA.

### Fixed
- `Helpers/VMwareHelper.psm1` — removed manual quote-wrapping of vmrun path arguments that broke under .NET `ArgumentList` ("unknown file suffix").
- Scripts are ASCII-only so they parse under Windows PowerShell 5.1 (non-ASCII glyphs desynced string parsing).
- `certreq` submission uses `-q` (no GUI hang under WinRM) and republishes the CA CRL to avoid `CRYPT_E_REVOCATION_OFFLINE` denials.
- Root CA exported as PEM (PTA's openssl-based chain validation rejects DER).

### Removed
- `Scripts/11-InstallPTA.ps1` (superseded by the Primary/Secondary split).

## [1.0.0]

### Added
- Initial unattended deployment of the full CyberArk self-hosted lab on VMware Workstation: DC01, VAULT01, COMP01 (PVWA + CPM + PSM), PTA01, PSMP01.
- Master orchestrator `Deploy-Lab.ps1` with per-step execution.
- Teardown script and helper modules.

[1.5.0]: #150---2026-07-30
[1.4.0]: #140---2026-07-04
[1.3.0]: #130---2026-07-04
[1.2.0]: #120---2026-07-04
[1.1.0]: #110---2026-07-04
[1.0.0]: #100
