# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [Semantic Versioning](https://semver.org/).

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

[1.3.0]: #130---2026-07-04
[1.2.0]: #120---2026-07-04
[1.1.0]: #110---2026-07-04
[1.0.0]: #100
