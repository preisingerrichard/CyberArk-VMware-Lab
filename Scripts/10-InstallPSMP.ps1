<#
.SYNOPSIS
    Install CyberArk PSM for SSH Proxy (PSMP) on a Linux VM
.DESCRIPTION
    PSMP runs on RHEL/CentOS and provides SSH-based privileged access.
    This script is a placeholder — the lab topology defined in LabConfig.psd1
    does not include a PSMP VM by default (the PSMP role is commented out).

    To enable PSMP:
      1. Uncomment the PSMP01 VM definition in Config\LabConfig.psd1
      2. Provision the Linux VM (RHEL 8/9 or CentOS Stream)
      3. Configure SSH key-based access from the host
      4. Run this script

    PSMP installation is performed via SSH using plink.exe (PuTTY) or
    the native OpenSSH client, not vmrun, because vmrun guest operations
    are not supported on Linux VMs without VMware Tools + VIX API.
.NOTES
    Requires: PuTTY plink.exe or OpenSSH installed on the host
    Requires: PSMP Linux installer RPM in Installers\PSMP\
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\NetworkHelper.psm1" -Force

$Config   = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"

# Check if PSMP VM is defined
$psmpVM = $Config.VMs | Where-Object { $_.Role -contains "PSMP" -or $_.Role -eq "PSMP" }

if (-not $psmpVM) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "  PSMP INSTALLATION SKIPPED" -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No PSMP VM defined in LabConfig.psd1." -ForegroundColor DarkGray
    Write-Host "This is expected — PSMP01 is commented out in the default config." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "To add PSMP to your lab:" -ForegroundColor White
    Write-Host "  1. Uncomment the PSMP01 block in Config\LabConfig.psd1" -ForegroundColor White
    Write-Host "  2. Place the PSMP RPM in Installers\PSMP\" -ForegroundColor White
    Write-Host "  3. Re-run 01-CreateBaseVM (Linux template) and 02-DeployVMs" -ForegroundColor White
    Write-Host "  4. Re-run this script" -ForegroundColor White
    Write-Host ""
    return
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Installing CyberArk PSMP on $($psmpVM.Name)" -ForegroundColor Cyan
Write-Host "  IP: $($psmpVM.IPAddress)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# ================================================================
# Locate SSH client on host
# ================================================================
$sshClients = @(
    "C:\Windows\System32\OpenSSH\ssh.exe",
    "$env:ProgramFiles\Git\usr\bin\ssh.exe",
    "$env:ProgramFiles\PuTTY\plink.exe"
)

$sshExe = $sshClients | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sshExe) {
    throw "No SSH client found. Install OpenSSH (Windows optional feature) or PuTTY."
}

Write-Host "Using SSH client: $sshExe" -ForegroundColor DarkGray

$psmpIP   = $psmpVM.IPAddress
$psmpUser = "root"
$psmpPass = $Config.LocalAdmin.Password    # set during Linux provisioning

# Wait for SSH port
$sshOpen = Wait-PortOpen -ComputerName $psmpIP -Port 22 -TimeoutSeconds 300
if (-not $sshOpen) {
    throw "Cannot reach $psmpIP on port 22"
}

# ================================================================
# Step 1: Copy PSMP installer RPM to Linux VM via SCP
# ================================================================
Write-Host "`n[Step 1] Copying PSMP installer to $($psmpVM.Name)..." -ForegroundColor Yellow

$psmpInstallerDir = Join-Path $Config.CyberArkMedia.BasePath "PSMP"
$psmpRPM = Get-ChildItem $psmpInstallerDir -Filter "*.rpm" | Select-Object -First 1

if (-not $psmpRPM) {
    throw "No PSMP RPM found in $psmpInstallerDir"
}

Write-Host "  RPM: $($psmpRPM.Name)" -ForegroundColor DarkGray

# Use scp to copy (OpenSSH) or pscp (PuTTY)
if ($sshExe -like "*plink*") {
    $scpExe = Join-Path (Split-Path $sshExe) "pscp.exe"
} else {
    $scpExe = $sshExe -replace 'ssh\.exe$', 'scp.exe'
}

if (Test-Path $scpExe) {
    & $scpExe -pw $psmpPass `
        $psmpRPM.FullName `
        "${psmpUser}@${psmpIP}:/tmp/$($psmpRPM.Name)"
} else {
    Write-Warning "scp not found at $scpExe. Manual copy required."
    Write-Host "  Run: scp '$($psmpRPM.FullName)' ${psmpUser}@${psmpIP}:/tmp/" -ForegroundColor Yellow
    Read-Host "Press Enter when RPM is copied to /tmp/ on the VM"
}

# ================================================================
# Step 2: Install PSMP via SSH
# ================================================================
Write-Host "`n[Step 2] Installing PSMP on $($psmpVM.Name)..." -ForegroundColor Yellow

$installCommands = @"
set -e

echo "=== CyberArk PSMP Installation ==="

# Install dependencies
yum install -y openssl libssl cyrus-sasl pam 2>/dev/null || \
dnf install -y openssl libssl cyrus-sasl pam 2>/dev/null || true

# Install PSMP RPM
echo "Installing PSMP RPM..."
rpm -ivh /tmp/$($psmpRPM.Name) || true

# Configure Vault.ini for PSMP
PSMP_CONF="/etc/opt/CARKpsmp/vault/Vault.ini"
if [ -f "`$PSMP_CONF" ]; then
    sed -i "s/^ADDRESS=.*/ADDRESS=$($CAConfig.Vault.VaultAddress)/" "`$PSMP_CONF"
    sed -i "s/^PORT=.*/PORT=$($CAConfig.Vault.VaultPort)/" "`$PSMP_CONF"
    echo "Vault.ini configured"
else
    echo "Creating Vault.ini..."
    mkdir -p /etc/opt/CARKpsmp/vault
    cat > "`$PSMP_CONF" << 'VAULTINI'
[MAIN]
ADDRESS=$($CAConfig.Vault.VaultAddress)
PORT=$($CAConfig.Vault.VaultPort)
VAULTINI
fi

# Enable and start PSMP service
systemctl enable psmpserver 2>/dev/null || true
systemctl start psmpserver 2>/dev/null || true

# Verify
echo ""
echo "=== PSMP Service Status ==="
systemctl status psmpserver --no-pager 2>/dev/null || service psmpserver status 2>/dev/null || echo "Service not found"

echo ""
echo "=== PSMP Installation Complete ==="
"@

$tempScript = Join-Path $env:TEMP "psmp_install_$(Get-Random).sh"
Set-Content -Path $tempScript -Value $installCommands -Encoding ASCII

# Execute via SSH — pipe script content (PowerShell has no < redirect)
if ($sshExe -like "*plink*") {
    Get-Content $tempScript | & $sshExe -pw $psmpPass -batch "${psmpUser}@${psmpIP}" "bash -s"
} else {
    # OpenSSH - use StrictHostKeyChecking=no for lab
    Get-Content $tempScript | & $sshExe `
        -o StrictHostKeyChecking=no `
        -o "PasswordAuthentication=yes" `
        "${psmpUser}@${psmpIP}" `
        "bash -s"
}

Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

Write-Host "`nPSMP installation complete on $($psmpVM.Name)" -ForegroundColor Green
Write-Host "  SSH proxy port: 22 ($psmpIP)" -ForegroundColor Green
Write-Host "  Connect via: ssh <domain_user>@<target>@$psmpIP" -ForegroundColor Green
