# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- `Deploy-Optional.ps1`: **ReconcileAccount** and **DiscoveryAccount** store their accounts in a separate safe `Lab-ServiceAccounts` instead of `VaultInternal`. The safe is created if missing and managed by the logged-on CPM. In `VaultInternal` (no managing CPM) the CPM could not use the reconcile account, so every reconcile failed. `VaultInternal` stays reserved for the LDAP bind account. Existing labs: rerun both features, then remove the old copies from `VaultInternal`.

## [1.7.0] - 2026-09-24

### Added
- **Vault LDAP integration, end to end.** Two numbered scripts that take a lab from zero to working AD logon to PVWA, both run by `Deploy-Lab.ps1 -Steps Full` and exposed as `Deploy-Optional.ps1` features:
  - `Scripts\16-CreateVaultADObjects.ps1` (step/feature **VaultADObjects**) — LDAP bind account `svc-cybr-ldap` in `OU=ServiceAccounts` with List Contents on the domain root, plus the four `Lab-Vault-*` role groups and their `vault_*` users in `OU=CyberArk`. Groups found elsewhere (e.g. `CN=Users`) are moved, keeping SID and membership. Checks the bind credentials with a real LDAP simple bind; `-ResetBindPassword` for an existing account with an unknown password.
  - `Scripts\17-ConfigureVaultLDAP.ps1` (step/feature **VaultLDAP**) — Vault hosts entry for DC01 + `dbparm.ini [MAIN] AllowNonStandardFWAddresses=[<DC IP>],Yes,389:outbound/tcp` (Vault restarted only when the rule is new); bind account stored in `VaultInternal`; PVWA LDAP directory (plain LDAP, 389); LDAP auth method enabled; four directory mappings (Vault Admins / Auditors / Add Safes / logon-only); verified by an LDAP logon per role. Verified on a live 15.0.2 lab; not yet run inside a from-scratch `-Steps Full` — feedback welcome.
- `Deploy-Lab.ps1` steps **VaultADObjects**, **VaultLDAP** (after PSMInstall) and **PTACertificates**, **VaultPTASyslog** (after PTAInstall), all part of `-Steps Full`.
- **Shared service-account platform `Win-Dom-SvcAcc`** (`Helpers\PVWAHelper.psm1`) — one platform for every lab Windows domain service account (LDAP bind, reconcile, discovery), duplicated from the Marketplace **WinDomain** platform via PVWA REST; existing accounts on another platform are moved onto it. WinDomain is not redistributable, so it is never shipped: pass `-WinDomainZipPath` to import it, otherwise `Win-Dom-SvcAcc` is duplicated from the built-in `WindowsDomainLDAP` with a warning.

- `04-DeployDC.ps1` Step 4: DC01 syncs time from `pool.ntp.org` / `time.windows.com` and is marked a reliable time source (inbound UDP 123 allowed). Without an external peer it free-ran off the VM clock, and lab clocks drifted (wrong event timestamps on PTA).

### Changed
- Moved `Scripts\pta_configure_installer.py` → `Helpers\PTAInstallerWizard.py` (support file run on PTA01 by `11-InstallPTA-Primary.ps1`, not a deployment step; it now sits with the other non-step helpers).
- Renamed `Scripts\Configure-PTACertificates.ps1` → `Scripts\14-ConfigurePTACertificates.ps1` and `Scripts\Configure-VaultSyslogToPTA.ps1` → `Scripts\15-ConfigureVaultSyslogToPTA.ps1` — they now continue the numbered sequence and run in `-Steps Full`.
- `Deploy-Optional.ps1`: **VaultADObjects** now dispatches to script 16 instead of carrying its own inline copy (the inline copy had drifted — it put the bind user in `CN=Users`).
- `Deploy-Optional.ps1`: feature **LDAPBindUser** renamed to **VaultLDAP** and dispatches to script 17, which does everything LDAPBindUser did plus the directory and mappings. The bind account is stored on `Win-Dom-SvcAcc` with automatic management off.
- `Deploy-Optional.ps1`: **ReconcileAccount** and **DiscoveryAccount** store their accounts on `Win-Dom-SvcAcc` instead of `WinDomain` (which a stock 15.x Vault does not have, so account creation failed there). When the PVWA account is first created, the AD password is reset to the stored value so the two start in sync (an AD account that pre-existed with another password no longer ends up stored wrongly); later runs never reset it. `-DiscoveryPassword` now defaults to `Cyberark!Local2024`.

### Removed
- `14-ConfigurePTACertificates.ps1` Step 0 (copy of the Vault `Administrator` password stored as `VaultAdmin-PTA` in safe `PTA-Automation`) and the `PTA.Certificate.SafeName`/`AccountName` config keys. The stored copy was never read back — Step 2g always used the config password — and on a stock 15.x Vault the account creation failed (`WinDomain` platform missing), leaving an empty `PTA-Automation` safe behind. Script 14 no longer needs PVWA.

### Fixed
- `14-ConfigurePTACertificates.ps1`: the CSR/cert-install wrappers wrote `echo csr_exit:\$?` inside a PowerShell here-string, so PowerShell expanded `$?` itself (`True`) and the real exit code was never captured — the CSR step always printed a false "non-zero exit" warning, and the install step only passed via its success-text fallback. Now `` `$? ``.
- `15-ConfigureVaultSyslogToPTA.ps1`: rewriting `systemparm.properties` via temp file + `mv` left it owned by `root:root`; it now restores `ptaapp:pta_server` (+ `restorecon`). Matters for DR — `drfilessync` copies the file as-is to the secondary.
- `11-InstallPTA-Primary.ps1` on PowerShell 7: the PVWA certificate bypass used `ICertificatePolicy`/`Add-Type`, which only works on Windows PowerShell 5.1. Every PVWA call now uses `-SkipCertificateCheck`, like the rest of the repo. Also removed the `personalSafe` step: that field does not exist on `/api/Users` (PVWA silently drops it). CasosServices only needs the PTA safe to exist with PTAAppUser as a member, which the earlier sub-steps already do.
- `Helpers\PTAInstallerWizard.py`: re-registering an already-installed PTA did nothing, because this installer version answers `DELETE /api/installation/` with HTTP 405. The wizard state is now reset where it is actually stored: `remote_installation_status=NOT_STARTED` in `systemparm.properties`, with a backup, `ptaapp:pta_server` ownership kept, and a `ptaweb` restart.
- `40-InstallVaultConjurSynchronizer.ps1`: the installer run could hang forever with no output. Stdout was read to the end while stderr was redirected but never drained, a classic .NET Process pipe deadlock. Both streams are now read asynchronously.
- `40-InstallVaultConjurSynchronizer.ps1`: an installed but Stopped Synchronizer service no longer counts as "done". After a Vault rebuild the service survives but its Safe and LOB user are gone, so the script now checks that they exist, as the fresh-install path does.

## [1.6.0] - 2026-07-30

### Added
- **`Deploy-Lab.ps1`: Retry option on step failure.** Previously only Continue-or-abort (Y/N) when a step failed. Now Retry/Continue/Abort (R/C/A) - Retry re-runs just the failed step in place, letting an admin fix the underlying issue (credentials, network, a missing file) and try again without restarting the whole deployment or manually re-invoking the script outside the orchestrator. Safe because every script in this repo already checks existing state and skips completed sub-steps - re-running after a partial failure was already how these scripts were designed to be used.

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

[1.6.0]: #160---2026-07-30
[1.5.0]: #150---2026-07-30
[1.4.0]: #140---2026-07-04
[1.3.0]: #130---2026-07-04
[1.2.0]: #120---2026-07-04
[1.1.0]: #110---2026-07-04
[1.0.0]: #100
