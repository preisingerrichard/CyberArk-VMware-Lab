# PTA Disaster Recovery (DR) Installation Guide

This guide covers deploying CyberArk PTA in a Disaster Recovery configuration with Primary and Secondary servers.

## Architecture

- **PTA Primary**: Full installation with web UI, API, and database
- **PTA Secondary**: Minimal installation with only ptadb service running; data replicates from Primary
- **Network**: Separate FQDNs per server (pta01.cyberark.lab, pta02.cyberark.lab) + optional shared name (pta.cyberark.lab)

## Prerequisites

- Both PTA VMs created: `10-CreatePTAVM.ps1 -PTANames @("PTA01","PTA02")`
- Vault and PVWA already deployed and healthy
- LabConfig.psd1 includes both PTA01 and PTA02 VM definitions

## Certificate Requirements (Before Installation)

For production, obtain proper certificates. For lab testing with self-signed certs, see [Certificate Management for DR](#certificate-management-for-dr) below.

### Important: Subject Alternative Names (SAN) Format

For DR deployments, certificates must include all three names in SAN (case-sensitive):

**Primary Certificate SAN:**
```
dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40
```

**Secondary Certificate SAN:**
```
dns:pta02.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.41
```

The shared name (`pta.cyberark.lab`) must appear in both certificates.

## Installation Steps

### 1. Install PTA Primary Server

```powershell
.\11-InstallPTA-Primary.ps1 -PTANames @("PTA01")
```

**Duration**: ~45-60 minutes including:
- Installer (20-30 min)
- Vault connectivity setup
- PVWA registration
- DiamondWebApp deployment

**Verification**: After Primary is up:
```
https://192.168.100.40:8443 should show PTA web UI
PVWA > Administration > PTA should show PTA01 connected
```

### 2. Install PTA Secondary Server

```powershell
.\11-InstallPTA-Secondary.ps1 -PTANames @("PTA02")
```

**Duration**: ~40-50 minutes (similar to Primary but skips web UI setup)

**Key Differences from Primary**:
- Runs minimal wizard only (no PVWA registration on Secondary)
- Skips DiamondWebApp deployment
- Only ptadb.service runs (no ptaweb)
- No personal safe or web UI configuration

**Verification**: After Secondary is up:
```powershell
ssh root@192.168.100.41
systemctl is-active ptadb
# Should return: active
```

### 3. Enable Replication on Primary

On the Primary server, run the DR setup script:

```bash
ssh root@pta01.cyberark.lab
bash /opt/pta/utility/dr/setupPrimary.sh
```

When prompted:
- **Primary SAN name**: `pta01` (exact match from certificate CN)
- **Secondary SAN name**: `pta02` (exact match from certificate CN)
- **Secondary root password**: `Cyberark!Local2024` (from LocalAdmin.Password in config)

This script:
- Configures MongoDB replication
- Enables replication from Primary to Secondary
- Validates connectivity between servers

**Expected output**:
```
[OK] Primary and Secondary replication configured
[OK] Initial sync from Primary to Secondary completed
```

### 4. Verify DR Replication

On Primary:
```bash
/opt/pta/mode
# Should contain: "primary"

# Check replication status
mongo --host localhost:27017 --eval 'rs.status()' | grep -E '(members|STATE)'
```

On Secondary:
```bash
/opt/pta/mode
# Should contain: "secondary"

# Verify ptadb is running only
systemctl status ptadb
systemctl status ptaweb 2>/dev/null || echo "ptaweb not running (expected)"
```

In PVWA:
- Administration > PTA should show PTA01 (Primary) as "Connected"
- PTA02 (Secondary) should NOT appear (Secondary doesn't register with PVWA)

## Configuration Reference

### VM IPs and Hostnames

| VM | IP | FQDN | Certificate CN |
|---|---|---|---|
| Primary | 192.168.100.40 | pta01.cyberark.lab | pta01 |
| Secondary | 192.168.100.41 | pta02.cyberark.lab | pta02 |
| Shared name (Primary) | 192.168.100.40 | pta.cyberark.lab | (included in both certs' SAN) |

> **Note:** `pta.cyberark.lab` always points to the Primary IP. This is NOT load balancing.
> Failover to Secondary is handled internally by Vault's `dbparm.ini` configuration — external
> components always communicate with the Primary. The shared name must exist in both Primary
> and Secondary certificates' SAN fields so the DR replication trusts the shared identity.

### Network Ports

All PTA servers (Primary and Secondary) require these firewall ports:

- **SSH**: 22/tcp (for management)
- **HTTP/HTTPS port forward**: 80/tcp → 8080, 443/tcp → 8443
- **Syslog**: 514/tcp, 514/udp, 11514/tcp, 11514/udp
- **Mongo Replication**: 27017/tcp (internal, between Primary and Secondary)

### Credentials

| Component | Username | Password |
|---|---|---|
| PTA Root | root | Cyberark!Local2024 |
| PTA Admin UI | admin | Cyberark1! |
| Vault Admin | Administrator | Cyberark1 |

## Troubleshooting

### Secondary won't start ptadb service

```bash
# On Secondary, check minimal wizard output
tail -50 /tmp/pta_upgrade.log | grep -i "error\|fail"

# Re-run minimal wizard manually
bash /opt/pta/utility/dr/minimalPrepwiz.sh
```

### Replication not syncing

On Primary, verify Secondary is reachable:
```bash
mongosh --host localhost:27017
rs.add("pta02.cyberark.lab:27017")
rs.status()
```

If Secondary not appearing in replica set, check:
- `/etc/hosts` entries on both servers
- MongoDB is running on Secondary: `systemctl status ptadb`
- Firewall allows 27017/tcp between servers

### PVWA shows PTA02 as "Disconnected" or missing

Secondary should NOT appear in PVWA. If it does:
- Stop ptaweb on Secondary: `systemctl stop ptaweb`
- Verify only ptadb is running: `systemctl list-units --state=running | grep pta`

## Reverting to Single PTA (Primary Only)

To remove Secondary and return to single-server mode:

```bash
# On Primary, remove Secondary from replica set
ssh root@pta01.cyberark.lab
mongosh --host localhost:27017
rs.remove("pta02.cyberark.lab:27017")
exit

# Tear down Secondary VM
vmrun stop "F:\VMs\CyberArk\PTA02\PTA02.vmx" hard
rm -r "F:\VMs\CyberArk\PTA02"
```

Verify Primary still connected in PVWA after removal.

## Certificate Management for DR

Certificates are case-sensitive and must match hostnames exactly.

### Generate Certificate Signing Request (CSR)

On each PTA server (Primary and Secondary):

```bash
ssh root@pta0X.cyberark.lab
```

**Option A: Using utility script (non-interactive)**
```bash
/opt/pta/utility/certificateSigningRequestGenerationUtil.sh
```

**Option B: Using run.sh menu**
```bash
bash /opt/pta/utility/run.sh
# Select: 14. Generating a Certificate Signing Request (CSR)
```

When prompted, specify:
- **PTA Host name**: `pta01` (for Primary) or `pta02` (for Secondary)
- **Organization**: Your org name
- **Department**: Your dept name
- **City/State/Country**: Your location
- **Subject Alternative Names (SAN)**:
  - **Primary**: `dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40`
  - **Secondary**: `dns:pta02.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.41`

CSR output location: `/opt/pta/ca/pta_server.csr`

Download CSR via SCP and submit to your Certificate Authority (CA).

### Install Signed Certificates

After CA returns signed certificates and certificate chain:

1. **Upload certificate files to PTA server** (via WinSCP or SCP):
   - PTA Server Certificate (e.g., `pta_server.crt`)
   - Root Certificate (e.g., `root.crt`)
   - Intermediate Certificates (if any, in order)

2. **On PTA server, run option 15**:
   ```bash
   ssh root@pta0X.cyberark.lab
   bash /opt/pta/utility/run.sh
   # Select: 15. Installing SSL Certificate Chain (Root, Intermediate(s), PTA Server certificates)
   ```

3. **Specify certificate paths when prompted**:
   - PTA Server Certificate: e.g., `/tmp/pta_server.crt`
   - Root Certificate: e.g., `/tmp/root.crt`
   - Intermediate Certificates: e.g., `/tmp/intermediate.crt` (if applicable)

4. **Vault credentials required**:
   - Username: `Administrator`
   - Password: `Cyberark1` (from CyberArkConfig.psd1)

5. **Vault Permissions Validation** will run automatically. If [FIX] appears:
   - Select Y to fix permissions
   - Provide Vault Admin credentials again
   - Validation should pass with all [OK]

6. **PTA services restart** automatically after certificate installation.

### Lab Testing: Self-Signed Certificates (Not Production-Safe)

For quick DR testing without a CA:

```bash
# On Primary
ssh root@pta01.cyberark.lab
cd /tmp

# Generate self-signed cert with SAN (valid 365 days)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout pta01.key -out pta01.crt \
  -subj "/CN=pta01.cyberark.lab/O=Lab/C=US" \
  -addext "subjectAltName=dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40"

# Then proceed with run.sh option 15 to install
bash /opt/pta/utility/run.sh
# Select 15, specify pta01.crt as PTA Server Certificate
```

Repeat for Secondary with appropriate SAN.

**WARNING**: Self-signed certs are NOT production-safe. Use only for lab/DR testing. Production requires proper CA-signed certificates.
