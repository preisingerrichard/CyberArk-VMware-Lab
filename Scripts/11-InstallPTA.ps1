<#
.SYNOPSIS
    Install CyberArk Privileged Threat Analytics (PTA) on PTA01 (Rocky Linux 9).
.DESCRIPTION
    Uses Windows built-in ssh.exe/scp.exe with a dedicated lab Ed25519 key.
    No Posh-SSH or open-vm-tools required -- keeps PTA01 OS minimal as required
    by CyberArk PTA prerequisites.

    Steps:
      1   Copy PTA installer files via SCP
      2   Import CyberArk GPG key into RPM keyring
      3   Install sshpass (PTA prerequisite)
      4   Configure firewalld (PTA port rules)
      5   Run PTA installer (handles its own reboot)
      6   Configure PTA vault + PVWA connectivity:
              6a  Patch Vault.ini (vault IP/port)
              6b  Add real-IP FQDN entry to /etc/hosts
              6c  Run vaultPermissionsValidation.sh
              6d  Run installer.war wizard (vault + PVWA registration)
              6e  Set PTAAppUser personal safe via PVWA REST API
              6f  Import PVWA SSL cert into PTA JVM cacerts
              6g  Import PTA SSL cert into COMP01 Windows Trusted Root
              6h  Deploy DiamondWebApp
              6i  Restart PTA services
              6j  Wait for ptaweb on port 8443

    Prerequisites:
    - PTA01 must be running Rocky Linux 9 with sshd enabled (10-CreatePTAVM.ps1)
    - Windows OpenSSH client (ssh.exe / scp.exe) - included in Windows 10/11
    - Files in Installers\PTA\:
        pta_installer.sh
        pta-<version>.tgz
        pta-selinux-policy-<version>.el9.noarch.rpm
        sshpass-<version>.el9.x86_64.rpm   (from EPEL 9 - required PTA OS dependency)
          Download: https://kojipkgs.fedoraproject.org/packages/sshpass/
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

# Verify Windows OpenSSH client is available
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "ssh.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force

$Config   = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

$ptaVM = $Config.VMs | Where-Object { $_.Role -eq 'PTA' -or $_.Role -contains 'PTA' } | Select-Object -First 1
if (-not $ptaVM) { throw "No VM with Role 'PTA' found in LabConfig.psd1" }

$ptaVMX    = Join-Path $Config.VMware.DefaultVMFolder "$($ptaVM.Name)\$($ptaVM.Name).vmx"
$ptaIP     = $ptaVM.IPAddress
$ptaPort   = $CAConfig.PTA.APIPort
$mediaBase = $Config.CyberArkMedia.BasePath
$ptaSource = Join-Path $mediaBase $Config.CyberArkMedia.PTAFolder
$guestDir  = $CAConfig.PTA.GuestInstallDir

if (-not (Test-Path $ptaVMX)) {
    throw "PTA01 VMX not found at '$ptaVMX' - run 10-CreatePTAVM.ps1 first"
}

# ================================================================
# Lab SSH key setup
# ================================================================
$labKeyPath = Join-Path $PSScriptRoot "..\Config\pta_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath) ).Path + "\pta_lab_key"

if (-not (Test-Path $labKeyPath)) {
    Write-Host "Generating lab SSH key at $labKeyPath ..." -ForegroundColor Cyan
    & ssh-keygen.exe -t ed25519 -f $labKeyPath -N '""' -C "pta-lab-automation" | Out-Null
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
}
$labPubKey = Get-Content "$labKeyPath.pub" -Raw

# SSH options used by every call -- shared as an array splat.
# UserKnownHostsFile=NUL discards known_hosts for this lab key so a
# freshly-reimaged VM never triggers a NativeCommandError from the host-key
# mismatch warning (which can corrupt $LASTEXITCODE in PS 5.1 error handling).
$sshOpts = @(
    "-i", $labKeyPath,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10"
)

function Wait-PTASSH {
    param([int]$TimeoutSeconds = 300)
    Write-Host "  Waiting for SSH on ${ptaIP}:22..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            if ($tcp.ConnectAsync($ptaIP, 22).Wait(3000)) {
                $tcp.Close()
                Start-Sleep -Seconds 5
                return
            }
            $tcp.Close()
        } catch {}
        Start-Sleep -Seconds 10
    }
    throw "SSH on $ptaIP did not become reachable within $TimeoutSeconds seconds"
}

function Invoke-PTASSH {
    param([string]$Command, [int]$TimeoutSec = 120, [switch]$NoThrow)
    # Drop ErrorActionPreference to Continue for the native call.
    # With ErrorActionPreference=Stop, any stderr output from ssh.exe causes a
    # NativeCommandError which sets $LASTEXITCODE=-1 instead of the real exit code.
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = $null
    try { $raw = & ssh.exe @sshOpts "root@$ptaIP" $Command 2>&1 } catch {}
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP

    $stdout = @($raw | Where-Object { $_ -is [string] })
    $stderr = @($raw | Where-Object { $_ -isnot [string] } | ForEach-Object { $_.ToString() })
    if (-not $NoThrow -and $exit -ne 0) {
        throw "SSH command failed (exit $exit): $($stderr + $stdout -join '; ')"
    }
    return [PSCustomObject]@{ Output = $stdout; ExitStatus = $exit; Error = $stderr }
}

function Copy-ToGuest {
    param([string]$LocalPath, [string]$RemoteDir)
    $fileName = Split-Path $LocalPath -Leaf
    Write-Host "  Uploading $fileName..." -ForegroundColor DarkGray
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & scp.exe -i $labKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        $LocalPath "root@${ptaIP}:${RemoteDir}/"
    $scpExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($scpExit -ne 0) { throw "scp failed for $fileName (exit $scpExit)" }
}

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk PTA on $($ptaVM.Name) ($ptaIP)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# ================================================================
# Pre-flight
# ================================================================
Write-Host "`n[Pre-flight] Waiting for PTA01 SSH..." -ForegroundColor Yellow
Wait-PTASSH -TimeoutSeconds 300

# Verify key-based auth works. If it fails, the kickstart %post may not have
# written authorized_keys. After 3 retries (~90s) we attempt a one-time
# password-based SSH call to install the key, then continue with key auth.
$keyAuthDeadline  = (Get-Date).AddMinutes(30)
$keyAuthed        = $false
$keyInstallTried  = $false
$keyRetries       = 0
$rootPass         = $Config.LocalAdmin.Password
$sshOptsPw        = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
                      "-o", "BatchMode=no", "-o", "ConnectTimeout=10",
                      "-o", "PreferredAuthentications=keyboard-interactive,password")

while ((Get-Date) -lt $keyAuthDeadline) {
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & ssh.exe @sshOpts "root@$ptaIP" "echo ok" 2>&1 } catch {}
    $keyExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($keyExit -eq 0) { $keyAuthed = $true; break }

    $keyRetries++
    if ($keyRetries -ge 3 -and -not $keyInstallTried) {
        $keyInstallTried = $true
        Write-Host ""
        Write-Host "  Key auth failed 3 times -- installing lab key via password SSH (one-time prompt)..." -ForegroundColor Yellow
        Write-Host "  >>> Enter root password when prompted: $rootPass <<<" -ForegroundColor Cyan
        $addKeyCmd = "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '$($labPubKey.Trim())' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo key_installed"
        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $null = & ssh.exe @sshOptsPw "root@$ptaIP" $addKeyCmd 2>&1
        $ErrorActionPreference = $savedEAP
        Write-Host "  Retrying key auth..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
        continue
    }

    Write-Host "  Key auth not yet ready (ssh exit $keyExit) - retrying in 30s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    Wait-PTASSH -TimeoutSeconds 120
}
if (-not $keyAuthed) {
    throw "Key-based SSH auth failed after 30 min. Run from host: ssh -o BatchMode=no root@$ptaIP then add key manually."
}
Write-Host "  [OK] PTA01 SSH is ready (key auth)" -ForegroundColor Green

Write-Host "`n[Pre-flight] Checking Vault reachability..." -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds(120)
$vaultReachable = $false
while ((Get-Date) -lt $deadline) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($CAConfig.Vault.VaultAddress, $CAConfig.Vault.VaultPort)
        $tcp.Close()
        $vaultReachable = $true
        break
    } catch {
        Write-Host "  Vault not yet reachable, retrying..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}
if (-not $vaultReachable) {
    throw "Vault not reachable on $($CAConfig.Vault.VaultAddress):$($CAConfig.Vault.VaultPort)"
}
Write-Host "  [OK] Vault is reachable" -ForegroundColor Green

# ================================================================
# Step 1: Copy PTA installer files via SCP
# ================================================================
Write-Host "`n[Step 1] Copying PTA installer files to $($ptaVM.Name)..." -ForegroundColor Yellow

$checkResult = Invoke-PTASSH -Command "test -f $guestDir/pta_installer.sh && echo exists || echo missing" -NoThrow
if ($checkResult.Output -match 'exists') {
    Write-Host "  [SKIP] Installer files already on guest" -ForegroundColor Yellow
} else {
    $installerSh  = Join-Path $ptaSource "pta_installer.sh"
    $tgzFile      = Get-ChildItem $ptaSource -Filter "pta-*.tgz" | Select-Object -First 1
    $rpmFile      = Get-ChildItem $ptaSource -Filter "pta-selinux-policy-*.el9.noarch.rpm" | Select-Object -First 1
    $sshpassFile  = Get-ChildItem $ptaSource -Filter "sshpass-*.rpm" | Select-Object -First 1

    if (-not (Test-Path $installerSh)) { throw "pta_installer.sh not found in $ptaSource" }
    if (-not $tgzFile)                 { throw "pta-*.tgz not found in $ptaSource" }
    if (-not $rpmFile)                 { throw "pta-selinux-policy-*.el9.noarch.rpm not found in $ptaSource" }
    if (-not $sshpassFile)             {
        throw @"
sshpass-*.rpm not found in $ptaSource
Download and place it there:
  https://rockylinux.pkgs.org/9/rockylinux-appstream-x86_64/sshpass-1.09-4.el9.x86_64.rpm.html
  (click the direct download link on that page)
"@
    }

    Write-Host "  Found: $($tgzFile.Name) ($([math]::Round($tgzFile.Length/1MB,1)) MB)" -ForegroundColor DarkGray
    Write-Host "  Found: $($rpmFile.Name)" -ForegroundColor DarkGray
    Write-Host "  Found: $($sshpassFile.Name)" -ForegroundColor DarkGray

    Invoke-PTASSH -Command "mkdir -p $guestDir" | Out-Null

    foreach ($file in @($installerSh, $tgzFile.FullName, $rpmFile.FullName, $sshpassFile.FullName)) {
        Copy-ToGuest -LocalPath $file -RemoteDir $guestDir
    }

    Write-Host "  [OK] All installer files transferred" -ForegroundColor Green
}

# ================================================================
# Step 2: Import CyberArk GPG key into RPM keyring
# ================================================================
Write-Host "`n[Step 2] Importing CyberArk GPG key into RPM keyring..." -ForegroundColor Yellow

# Primary: look for RPM-GPG-KEY-CyberArk in the PTA source folder.
# Download it from the CyberArk Technical Community and place it alongside
# pta_installer.sh before running this script.
$gpgKeyLocal = Join-Path $ptaSource "RPM-GPG-KEY-CyberArk"

if (Test-Path $gpgKeyLocal) {
    Write-Host "  Found RPM-GPG-KEY-CyberArk in installer folder - uploading..." -ForegroundColor DarkGray
    Copy-ToGuest -LocalPath $gpgKeyLocal -RemoteDir $guestDir
    $importResult = Invoke-PTASSH -Command "rpm --import '$guestDir/RPM-GPG-KEY-CyberArk' && echo 'GPG key imported OK'" -NoThrow
    if ($importResult.Output -match 'imported OK') {
        Write-Host "  [OK] CyberArk GPG key imported" -ForegroundColor Green
    } else {
        Write-Warning "rpm --import returned exit $($importResult.ExitStatus) - $($importResult.Error -join '; ')"
    }
} else {
    # Fallback: RPM-GPG-KEY-CyberArk not present. Patch the installer so
    # 'rpm -K' uses --nosignature and outputs 'digests OK' without a key.
    Write-Host "  RPM-GPG-KEY-CyberArk not found in $ptaSource" -ForegroundColor Yellow
    Write-Host "  Falling back: patching installer to use 'rpm -K --nosignature'..." -ForegroundColor DarkGray
    Write-Host "  (Download RPM-GPG-KEY-CyberArk from the CyberArk Technical Community" -ForegroundColor DarkGray
    Write-Host "   and place it in $ptaSource for a proper signed install)" -ForegroundColor DarkGray
    $patchResult = Invoke-PTASSH -Command "sed -i 's/rpm -K/rpm -K --nosignature/g' '$guestDir/pta_installer.sh' && echo 'patched'" -NoThrow
    if ($patchResult.Output -match 'patched') {
        Write-Host "  [OK] Installer patched (rpm -K --nosignature)" -ForegroundColor Green
    } else {
        Write-Warning "Installer patch may have failed: $($patchResult.Error -join '; ')"
    }
}

# ================================================================
# Step 3: Install sshpass
# PTA installer dependency check requires sshpass. Rocky 9 minimal ISO
# does not include it, so it must be fetched from AppStream or staged as RPM.
# ================================================================
Write-Host "`n[Step 3] Ensuring sshpass is installed (PTA prerequisite)..." -ForegroundColor Yellow

$sshpassCheck = Invoke-PTASSH -Command "rpm -q sshpass >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
if ($sshpassCheck.Output -match 'missing') {
    # Fix DNS: nmcli persists the setting, but NM writes resolv.conf asynchronously.
    # Force-write resolv.conf immediately so dnf sees 8.8.8.8 right away.
    # Rocky 9 may have a systemd-resolved stub symlink at /etc/resolv.conf -- remove it first.
    Write-Host "  Fixing DNS: nmcli + force resolv.conf..." -ForegroundColor DarkGray
    $nmFix = Invoke-PTASSH -Command @'
CONN=$(nmcli -t -f NAME connection show --active | head -1)
nmcli connection modify "$CONN" ipv4.dns "8.8.8.8 192.168.100.10" ipv4.ignore-auto-dns yes
nmcli connection up "$CONN" 2>&1 | tail -1
sleep 2
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 192.168.100.10\n' > /etc/resolv.conf
systemctl try-restart systemd-resolved 2>/dev/null || true
sleep 1
echo dns_fixed
'@ -TimeoutSec 30 -NoThrow
    $nmFix.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    # Test routing (raw ICMP to 8.8.8.8 -- no DNS)
    $pingTest = Invoke-PTASSH -Command "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo routable || echo no_route" -NoThrow
    Write-Host "  Internet routing: $($pingTest.Output -join '')" -ForegroundColor DarkGray

    # Test DNS resolution separately
    $dnsTest = Invoke-PTASSH -Command "getent hosts mirrors.rockylinux.org >/dev/null 2>&1 && echo dns_ok || echo dns_fail" -NoThrow
    Write-Host "  DNS resolution: $($dnsTest.Output -join '')" -ForegroundColor DarkGray

    if ($pingTest.Output -match 'routable' -and $dnsTest.Output -match 'dns_ok') {
        Write-Host "  Internet reachable - installing sshpass via dnf (Rocky AppStream)..." -ForegroundColor DarkGray
        $dnfResult = Invoke-PTASSH -Command "dnf install -y sshpass 2>&1; echo dnf_exit:`$?" -TimeoutSec 120 -NoThrow
        $dnfResult.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        # Covers: no internet route, OR routing OK but DNS resolution still failing.
        $rpmReason = if ($pingTest.Output -notmatch 'routable') { "No internet route" } else { "DNS resolution failed" }
        Write-Host "  $rpmReason - installing from staged RPM..." -ForegroundColor DarkGray
        $sshpassLocal = Get-ChildItem $ptaSource -Filter "sshpass-*.rpm" | Select-Object -First 1
        if (-not $sshpassLocal) {
            throw "sshpass-*.rpm not found in $ptaSource and PTA01 has no internet. Download from https://rockylinux.pkgs.org/9/rockylinux-appstream-x86_64/sshpass-1.09-4.el9.x86_64.rpm.html and place it in $ptaSource."
        }
        $onGuest = Invoke-PTASSH -Command "ls $guestDir/sshpass-*.rpm 2>/dev/null && echo present || echo absent" -NoThrow
        if ($onGuest.Output -notmatch 'present') {
            Copy-ToGuest -LocalPath $sshpassLocal.FullName -RemoteDir $guestDir
        }
        $rpmResult = Invoke-PTASSH -Command "rpm -ivh --nosignature $guestDir/$($sshpassLocal.Name) 2>&1; echo rpm_exit:`$?" -NoThrow
        $rpmResult.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }

    $sshpassVerify = Invoke-PTASSH -Command "rpm -q sshpass >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
    if ($sshpassVerify.Output -notmatch 'installed') {
        throw "sshpass install failed. See output above."
    }
    Write-Host "  [OK] sshpass installed" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] sshpass already installed" -ForegroundColor Yellow
}

# ================================================================
# Step 4: Configure OS firewall (PTA 15.0+ no longer manages firewalld)
# Required per PTA Port Usage docs:
#   Incoming: 22/tcp, 80/tcp, 443/tcp, 8080/tcp, 8443/tcp,
#             514/tcp, 514/udp, 11514/tcp, 11514/udp, ICMP echo
#   Port forwarding: TCP 80->8080, TCP 443->8443
# ================================================================
Write-Host "`n[Step 4] Configuring firewalld (PTA port rules)..." -ForegroundColor Yellow

$fwScript = @'
#!/bin/bash
# Kickstart already opened ssh/443/8443/514 in the public zone.
# Add remaining required ports and port-forwarding rules.
systemctl enable --now firewalld
Z=public
firewall-cmd --permanent --zone=$Z --add-port=80/tcp
firewall-cmd --permanent --zone=$Z --add-port=8080/tcp
firewall-cmd --permanent --zone=$Z --add-port=11514/tcp
firewall-cmd --permanent --zone=$Z --add-port=11514/udp
# PTA port-forwarding rules (TCP 80->8080, TCP 443->8443)
firewall-cmd --permanent --zone=$Z --add-forward-port=port=80:proto=tcp:toport=8080
firewall-cmd --permanent --zone=$Z --add-forward-port=port=443:proto=tcp:toport=8443
firewall-cmd --reload
firewall-cmd --zone=$Z --list-all
echo "firewall_configured_ok"
'@

$tmpFwScript = Join-Path ([System.IO.Path]::GetTempPath()) "pta_firewall.sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmpFwScript, ($fwScript -replace "`r`n", "`n"), $utf8NoBom)
Copy-ToGuest -LocalPath $tmpFwScript -RemoteDir "/tmp"
Remove-Item $tmpFwScript -ErrorAction SilentlyContinue

$fwResult = Invoke-PTASSH -Command "chmod +x /tmp/pta_firewall.sh && bash /tmp/pta_firewall.sh 2>&1" -TimeoutSec 60 -NoThrow
$fwResult.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($fwResult.Output -match 'firewall_configured_ok') {
    Write-Host "  [OK] firewalld configured" -ForegroundColor Green
} else {
    Write-Warning "firewalld configuration may have failed - check output above"
}

# ================================================================
# Step 5: Run PTA installer (handles its own reboot)
# ================================================================
Write-Host "`n[Step 5] Running PTA installer (20-30 min)..." -ForegroundColor Yellow

$installedCheck = Invoke-PTASSH -Command "systemctl is-active appmgr.service 2>/dev/null || echo inactive" -NoThrow
if ($installedCheck.Output -match '^active') {
    Write-Host "  [SKIP] PTA service already running" -ForegroundColor Yellow
} else {
    Write-Host "  Starting installer (SSH will drop when VM reboots - expected)..." -ForegroundColor DarkGray

    $remoteCmd = "cd '$guestDir' && chmod +x pta_installer.sh && printf 'Y\n\n' | bash ./pta_installer.sh >> /tmp/pta_install.log 2>&1"
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & ssh.exe -i $labKeyPath `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        -o BatchMode=yes `
        -o ServerAliveInterval=30 `
        -o ServerAliveCountMax=5 `
        "root@$ptaIP" $remoteCmd
    $sshExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($sshExit -eq 255) {
        Write-Host "  SSH connection dropped (VM rebooting) - expected" -ForegroundColor DarkGray
    } elseif ($sshExit -ne 0) {
        Write-Warning "Installer SSH exited with code $sshExit - check /tmp/pta_install.log on PTA01"
    }

    Write-Host "  Waiting for VM to come back up after reboot..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    Wait-PTASSH -TimeoutSeconds 600

    # Installer may exit 0 without rebooting (PTA 15.0). If so, reboot manually.
    $logDone = Invoke-PTASSH -Command "grep -c 'PTA deployed successfully' /tmp/pta_upgrade.log 2>/dev/null || echo 0" -NoThrow
    if ($sshExit -ne 255 -and $logDone.Output -match '^[1-9]') {
        Write-Host "  Installer exited cleanly (no SSH drop) - rebooting VM manually..." -ForegroundColor DarkGray
        Invoke-PTASSH -Command "reboot" -NoThrow | Out-Null
        Start-Sleep -Seconds 30
        Wait-PTASSH -TimeoutSeconds 600
    }

    # Poll for ptaweb up to 5 minutes -- PTA services are slow to start after boot.
    Write-Host "  Waiting for ptaweb service (up to 5 min)..." -ForegroundColor DarkGray
    $ptaDeadline = (Get-Date).AddMinutes(5)
    $ptaReady    = $false
    while ((Get-Date) -lt $ptaDeadline) {
        $svc = Invoke-PTASSH -Command "systemctl is-active ptaweb 2>/dev/null" -NoThrow
        if ($svc.Output -match '^active') { $ptaReady = $true; break }
        Write-Host "  ptaweb: $($svc.Output -join '' | ForEach-Object { $_.Trim() }) -- waiting..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }

    if (-not $ptaReady) {
        $installLog = Invoke-PTASSH -Command "tail -30 /tmp/pta_upgrade.log 2>/dev/null || echo '(no log)'" -NoThrow
        $installLog.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "ptaweb not active 5 min after reboot. Check log above."
    }

    Write-Host "  [OK] PTA installed and services active" -ForegroundColor Green
}

# ================================================================
# Step 6: Configure PTA vault + PVWA connectivity
# Sub-steps run in dependency order so TLS trust is established before
# DiamondWebApp registration, which requires PVWA to call back to PTA.
# ================================================================
Write-Host "`n[Step 6] Configuring PTA vault and PVWA connectivity..." -ForegroundColor Yellow

$pvwaVM   = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -eq 'PVWA' } | Select-Object -First 1

$vaultIP      = $CAConfig.Vault.VaultAddress
$vaultPort    = $CAConfig.Vault.VaultPort
$vaultPass    = $CAConfig.Vault.AdminPassword
$vaultIniPath = "/etc/opt/pta/diamond-resources/Vault.ini"

# Step 6a: Patch Vault.ini (installer sets ADDRESS to dummy 11.22.33.444)
Write-Host "  [6a] Patching $vaultIniPath..." -ForegroundColor DarkGray
$patchResult = Invoke-PTASSH -Command "test -f $vaultIniPath && sed -i 's/^ADDRESS=.*/ADDRESS=$vaultIP/' $vaultIniPath && sed -i 's/^PORT=.*/PORT=$vaultPort/' $vaultIniPath && echo patched || echo missing" -NoThrow
if ($patchResult.Output -match 'patched') {
    $vaultCheck = Invoke-PTASSH -Command "grep -E '^(ADDRESS|PORT)=' $vaultIniPath" -NoThrow
    Write-Host "  $($vaultCheck.Output -join '  ')" -ForegroundColor DarkGray
    Write-Host "  [OK] Vault.ini patched" -ForegroundColor Green
} else {
    Write-Warning "Vault.ini not found at $vaultIniPath - skipping direct patch"
}

# Step 6b: Add real-IP FQDN entry to /etc/hosts.
# NEVER add the FQDN to 127.0.0.1 -- Java InetAddress.getLocalHost() would resolve
# to "localhost" and the wizard registers PTA with PVWA as "localhost" (CAWS00001E).
Write-Host "  [6b] Adding real-IP FQDN entry to /etc/hosts..." -ForegroundColor DarkGray
$ptaFQDN  = "$($ptaVM.Name.ToLower()).$($Config.Domain.Name)"
$ptaShort = $ptaVM.Name.ToLower()
$hostsPresent = Invoke-PTASSH -Command "grep -qF '$ptaFQDN' /etc/hosts && echo present || echo missing" -NoThrow
if ($hostsPresent.Output -notmatch 'present') {
    Invoke-PTASSH -Command "echo '$ptaIP  $ptaFQDN $ptaShort' >> /etc/hosts" -NoThrow | Out-Null
}
$fqdnCheck = Invoke-PTASSH -Command "grep -vE '^#|^\s*$' /etc/hosts" -NoThrow
$fqdnCheck.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$fqdnResult = Invoke-PTASSH -Command "hostname -f" -NoThrow
Write-Host "  hostname -f: $($fqdnResult.Output -join '')" -ForegroundColor DarkGray
Write-Host "  [OK] /etc/hosts updated" -ForegroundColor Green

# Step 6c: Run vaultPermissionsValidation.sh explicitly.
# Running after Vault.ini and /etc/hosts are correct ensures PTAAppUser vault auth
# is established before the wizard and before DiamondWebApp registration.
Write-Host "  [6c] Running vaultPermissionsValidation.sh..." -ForegroundColor DarkGray

$vaultValFind = Invoke-PTASSH -Command "find /opt/pta -name 'vaultPermissionsValidation.sh' 2>/dev/null | head -1" -NoThrow
$vaultValPath = ($vaultValFind.Output -join '').Trim()

if ($vaultValPath) {
    Write-Host "  Found: $vaultValPath" -ForegroundColor DarkGray
    # Pass vault credentials via environment vars -- avoids quoting issues with
    # special chars in passwords. The script reads from Vault.ini for address/port.
    # echo Y: auto-answers the "fix permissions now? (Y/N)" interactive prompt
    $vaultValCmd = "echo 'Y' | VAULT_ADMIN_USER='$($CAConfig.Vault.AdminUser)' VAULT_ADMIN_PASSWORD='$($CAConfig.Vault.AdminPassword)' timeout 60 bash '$vaultValPath' 2>&1; echo val_exit:`$?"
    $valResult = Invoke-PTASSH -Command $vaultValCmd -TimeoutSec 90 -NoThrow
    $valResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($valResult.Output -match 'val_exit:0') {
        Write-Host "  [OK] vaultPermissionsValidation.sh succeeded" -ForegroundColor Green
    } else {
        Write-Warning "vaultPermissionsValidation.sh non-zero exit -- vault connectivity may be broken"
        Write-Warning "Check: ADDRESS/PORT in $vaultIniPath, vault is reachable, PTAAppUser exists in vault"
    }
} else {
    Write-Host "  vaultPermissionsValidation.sh not found under /opt/pta -- installer wizard will handle vault validation" -ForegroundColor DarkGray
}

# Step 6d: Run the installer.war wizard via the REST API.
# pta_configure_installer.py drives all 13 wizard steps in one pass:
# vault connectivity, PVWA registration, firewalld, syslog.
Write-Host "  [6d] Running installer.war wizard (vault + PVWA configuration)..." -ForegroundColor DarkGray

$timezone = $CAConfig.PTA.Timezone
$pvwaHost = if ($pvwaVM) { "$($pvwaVM.Name.ToLower()).$($Config.Domain.Name)" } else { $CAConfig.Vault.VaultAddress }
$rootPass = $Config.LocalAdmin.Password

$pyScriptSrc = Join-Path $PSScriptRoot "pta_configure_installer.py"
if (-not (Test-Path $pyScriptSrc)) {
    throw "pta_configure_installer.py not found at $pyScriptSrc - required for installer wizard"
}
Copy-ToGuest -LocalPath $pyScriptSrc -RemoteDir "/tmp"

# Wrap the call in a shell script to avoid PowerShell quoting / special-char issues
# with passwords containing !, $, spaces, etc. Values are expanded by PowerShell
# here (single backtick to suppress) but the resulting .sh is plain bash.
$wizScript = @"
#!/bin/bash
python3 /tmp/pta_configure_installer.py \
  '$vaultIP' \
  '$vaultPass' \
  '$pvwaHost' \
  '$rootPass' \
  '$($CAConfig.Vault.AdminUser)' \
  '$timezone' 2>&1
exit `$?
"@

$tmpWizScript = Join-Path ([System.IO.Path]::GetTempPath()) "pta_wizard_run.sh"
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpWizScript, ($wizScript -replace "`r`n", "`n"), $utf8NoBom)
    Copy-ToGuest -LocalPath $tmpWizScript -RemoteDir "/tmp"

    Write-Host "  Waiting up to 11 minutes for wizard to complete..." -ForegroundColor DarkGray
    $wizResult = Invoke-PTASSH -Command "chmod +x /tmp/pta_wizard_run.sh && bash /tmp/pta_wizard_run.sh" -TimeoutSec 680 -NoThrow
    $wizResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if ($wizResult.ExitStatus -eq 0) {
        Write-Host "  [OK] Installer wizard completed" -ForegroundColor Green
    } else {
        Write-Warning "Installer wizard exited $($wizResult.ExitStatus)"
        Write-Warning "To re-run manually, SSH to PTA01 and run:"
        Write-Warning "  python3 /tmp/pta_configure_installer.py $vaultIP '$vaultPass' $pvwaHost"
    }
} finally {
    Remove-Item $tmpWizScript -ErrorAction SilentlyContinue
}

# Step 6e: Create PTAAppUser personal safe and set the vault PersonalSafe attribute.
# CasosServices only reads MDCSafesUserPersonal when PersonalSafe attribute points
# to an actual safe the user can access. Creating the safe and adding the user as
# member alone is not sufficient -- the attribute must be set explicitly via PUT /api/Users.
Write-Host "  [6e] Setting PTAAppUser personal safe..." -ForegroundColor DarkGray

if (-not $pvwaVM) {
    Write-Warning "No PVWA VM configured - skipping personal safe setup (CasosServices will fail)"
} else {
    # PS 5.1 TLS bypass for the PVWA's self-signed certificate
    if (-not ([System.Management.Automation.PSTypeName]'Pta11TrustAll').Type) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class Pta11TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@ -ErrorAction SilentlyContinue
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object Pta11TrustAll
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

    $pvwaBase  = "https://$($pvwaVM.IPAddress)/PasswordVault"
    $ptaUser   = "PTAAppUser"
    $ptaSafe   = "PTAAppUser"
    $adminUser = $CAConfig.Vault.AdminUser
    $pvwaToken = $null

    try {
        # Authenticate
        $logonBody = @{ username = $adminUser; password = $vaultPass; concurrentSession = $true } | ConvertTo-Json
        $logonResp = Invoke-WebRequest -Uri "$pvwaBase/api/auth/Cyberark/Logon" `
            -Method POST -Body $logonBody -ContentType "application/json" -UseBasicParsing
        $pvwaToken = $logonResp.Content.Trim('"')
        $pvwaHdrs  = @{ Authorization = $pvwaToken }
        Write-Host "    Authenticated to PVWA" -ForegroundColor DarkGray

        # (a) Create safe if it does not already exist
        try {
            $null = Invoke-WebRequest -Uri "$pvwaBase/api/Safes/$ptaSafe" `
                -Method GET -Headers $pvwaHdrs -UseBasicParsing
            Write-Host "    Safe '$ptaSafe' already exists" -ForegroundColor DarkGray
        } catch {
            $safeBody = @{
                safeName              = $ptaSafe
                description           = "PTAAppUser personal safe"
                numberOfDaysRetention = 0
            } | ConvertTo-Json
            try {
                $null = Invoke-WebRequest -Uri "$pvwaBase/api/Safes" -Method POST `
                    -Body $safeBody -ContentType "application/json" -Headers $pvwaHdrs -UseBasicParsing
                Write-Host "    Created safe '$ptaSafe'" -ForegroundColor DarkGray
            } catch {
                Write-Host "    Safe create: $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        }

        # (b) Add PTAAppUser as safe member with full permissions
        $memberBody = @{
            memberName  = $ptaUser
            memberType  = "User"
            searchIn    = "Vault"
            permissions = @{
                useAccounts                            = $true
                retrieveAccounts                       = $true
                listAccounts                           = $true
                addAccounts                            = $true
                updateAccountContent                   = $true
                updateAccountProperties                = $true
                initiateCPMAccountManagementOperations = $true
                specifyNextAccountContent              = $true
                renameAccounts                         = $true
                deleteAccounts                         = $true
                unlockAccounts                         = $true
                manageSafe                             = $true
                manageSafeMembers                      = $true
                backupSafe                             = $true
                viewAuditLog                           = $true
                viewSafeMembers                        = $true
                accessWithoutConfirmation              = $true
                createFolders                          = $true
                deleteFolders                          = $true
                moveAccountsAndFolders                 = $true
            }
        } | ConvertTo-Json -Depth 5
        try {
            $null = Invoke-WebRequest -Uri "$pvwaBase/api/Safes/$ptaSafe/Members" -Method POST `
                -Body $memberBody -ContentType "application/json" -Headers $pvwaHdrs -UseBasicParsing
            Write-Host "    Added $ptaUser as safe member" -ForegroundColor DarkGray
        } catch {
            $mCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($mCode -eq 409) {
                Write-Host "    $ptaUser is already a safe member" -ForegroundColor DarkGray
            } else {
                Write-Host "    Member add: $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        }

        # (c) Locate PTAAppUser's vault user ID
        $searchResp = Invoke-WebRequest -Uri "$pvwaBase/api/Users?search=$ptaUser" `
            -Method GET -Headers $pvwaHdrs -UseBasicParsing
        $userList   = $searchResp.Content | ConvertFrom-Json
        $users      = if ($userList.Users) { $userList.Users } else { @() }
        $ptaUserObj = $users | Where-Object { $_.username -ieq $ptaUser } | Select-Object -First 1

        if (-not $ptaUserObj) {
            Write-Warning "PTAAppUser not found in vault -- pasConfiguration.sh may not have run cleanly"
        } else {
            Write-Host "    Found $ptaUser (id: $($ptaUserObj.id), personalSafe now: '$($ptaUserObj.personalSafe)')" -ForegroundColor DarkGray

            # (d) Set the PersonalSafe vault attribute.
            # PUT /api/Users requires the full user object — partial bodies return 400.
            # GET the full representation first, patch personalSafe, then PUT it back.
            $fullUserResp = Invoke-WebRequest -Uri "$pvwaBase/api/Users/$($ptaUserObj.id)" `
                -Method GET -Headers $pvwaHdrs -UseBasicParsing
            $fullUser = $fullUserResp.Content | ConvertFrom-Json
            $fullUser | Add-Member -MemberType NoteProperty -Name personalSafe -Value $ptaSafe -Force
            $updateBody = $fullUser | ConvertTo-Json -Depth 10
            try {
                $null = Invoke-WebRequest -Uri "$pvwaBase/api/Users/$($ptaUserObj.id)" -Method PUT `
                    -Body $updateBody -ContentType "application/json" -Headers $pvwaHdrs -UseBasicParsing
            } catch {
                Write-Host "    PUT /Users: $($_.Exception.Message)" -ForegroundColor DarkGray
            }

            # (e) Verify the attribute was actually persisted
            $verifyResp = Invoke-WebRequest -Uri "$pvwaBase/api/Users/$($ptaUserObj.id)" `
                -Method GET -Headers $pvwaHdrs -UseBasicParsing
            $verified = $verifyResp.Content | ConvertFrom-Json
            if ($verified.personalSafe -ieq $ptaSafe) {
                Write-Host "  [OK] PTAAppUser.PersonalSafe = '$ptaSafe' confirmed via PVWA API" -ForegroundColor Green
            } else {
                Write-Warning "PVWA API did not persist PersonalSafe (got: '$($verified.personalSafe)')"
                Write-Warning "CasosServices will not connect until PersonalSafe is set on PTAAppUser"
            }
        }
    } catch {
        Write-Warning "Step 6e error: $($_.Exception.Message)"
    } finally {
        if ($pvwaToken) {
            $null = Invoke-WebRequest -Uri "$pvwaBase/api/auth/Logoff" -Method POST `
                -Headers @{ Authorization = $pvwaToken } -UseBasicParsing -ErrorAction SilentlyContinue
        }
    }
}

# Step 6f: Import PVWA SSL cert into PTA JVM cacerts truststore.
# PTA uses /opt/pta/jvm/jre8 with its own cacerts, independent of the OS trust store.
# Without this, PTA's Java HTTPS client rejects PVWA's self-signed cert.
# Must run before step 6h (DiamondWebApp) which calls PVWA to register PTA.
Write-Host "  [6f] Importing PVWA SSL cert into PTA JVM cacerts..." -ForegroundColor DarkGray

$keytool       = "/opt/pta/jvm/jre8/bin/keytool"
$cacerts       = "/opt/pta/jvm/jre8/lib/security/cacerts"
$pvwaCertAlias = "pvwa-comp01"
$pvwaHostFull  = if ($pvwaVM) { "$($pvwaVM.Name.ToLower()).$($Config.Domain.Name)" } else { $pvwaVM.IPAddress }
$pvwaIpAddr    = if ($pvwaVM) { $pvwaVM.IPAddress } else { $CAConfig.Vault.VaultAddress }

$certCheck = Invoke-PTASSH -Command "$keytool -list -alias $pvwaCertAlias -keystore $cacerts -storepass changeit -noprompt 2>/dev/null && echo exists || echo missing" -NoThrow
if ($certCheck.Output -match 'exists') {
    Write-Host "  [SKIP] PVWA cert already in PTA JVM cacerts (alias: $pvwaCertAlias)" -ForegroundColor Yellow
} else {
    # Fetch PVWA cert via openssl
    $fetchResult = Invoke-PTASSH -Command "openssl s_client -connect ${pvwaIpAddr}:443 -servername $pvwaHostFull </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/pvwa_cert.pem && echo cert_saved || echo cert_failed" -NoThrow
    if ($fetchResult.Output -notmatch 'cert_saved') {
        Write-Warning "PVWA cert fetch failed -- trying without SNI..."
        $fetchResult = Invoke-PTASSH -Command "openssl s_client -connect ${pvwaIpAddr}:443 </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/pvwa_cert.pem && echo cert_saved || echo cert_failed" -NoThrow
    }

    if ($fetchResult.Output -match 'cert_saved') {
        $importResult = Invoke-PTASSH -Command "$keytool -importcert -alias $pvwaCertAlias -file /tmp/pvwa_cert.pem -keystore $cacerts -storepass changeit -noprompt 2>&1 && echo imported || echo import_failed" -NoThrow
        if ($importResult.Output -match 'imported') {
            Write-Host "  [OK] PVWA cert imported into PTA JVM cacerts (alias: $pvwaCertAlias)" -ForegroundColor Green
        } else {
            Write-Warning "keytool import may have failed: $($importResult.Output -join '; ')"
        }
    } else {
        Write-Warning "Could not fetch PVWA SSL cert from ${pvwaIpAddr}:443 -- skipping JVM cacerts import"
        Write-Warning "PTA EPV API calls to PVWA will fail until cert is imported manually:"
        Write-Warning "  openssl s_client -connect ${pvwaIpAddr}:443 </dev/null 2>/dev/null | openssl x509 > /tmp/pvwa_cert.pem"
        Write-Warning "  $keytool -importcert -alias $pvwaCertAlias -file /tmp/pvwa_cert.pem -keystore $cacerts -storepass changeit -noprompt"
    }
}

# Step 6g: Import PTA SSL cert into COMP01 Windows Trusted Root CA store.
# Must run before step 6h: PVWA makes a callback to PTA over HTTPS during
# DiamondWebApp registration. Without PTA's cert in COMP01's Trusted Root,
# that callback fails with CAWS00001E and PTA shows as "Disconnected".
Write-Host "  [6g] Importing PTA SSL cert into COMP01 Windows Trusted Root..." -ForegroundColor DarkGray

$comp01VM  = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -contains 'CPM' } | Select-Object -First 1
$comp01Vmx = if ($comp01VM) { Join-Path $Config.VMware.DefaultVMFolder "$($comp01VM.Name)\$($comp01VM.Name).vmx" } else { $null }
$winAdmin  = $Config.LocalAdmin.Username
$winPass   = $Config.LocalAdmin.Password

if (-not $comp01VM -or -not (Test-Path $comp01Vmx)) {
    Write-Warning "COMP01 VMX not found -- skipping PTA cert import. CAWS00001E will occur until cert is imported manually."
} else {
    # 1. Fetch PTA's TLS cert from port 8443 via openssl on PTA01
    $ptaCertFetch = Invoke-PTASSH -Command "openssl s_client -connect localhost:$ptaPort </dev/null 2>/dev/null | openssl x509 -outform DER > /tmp/pta_cert.der && echo pta_cert_saved || echo pta_cert_failed" -NoThrow
    if ($ptaCertFetch.Output -notmatch 'pta_cert_saved') {
        Write-Warning "Could not export PTA TLS cert from port $ptaPort -- ptaweb may still be starting. Retrying in 30s..."
        Start-Sleep -Seconds 30
        $ptaCertFetch = Invoke-PTASSH -Command "openssl s_client -connect localhost:$ptaPort </dev/null 2>/dev/null | openssl x509 -outform DER > /tmp/pta_cert.der && echo pta_cert_saved || echo pta_cert_failed" -NoThrow
    }

    if ($ptaCertFetch.Output -match 'pta_cert_saved') {
        # 2. SCP cert from PTA01 to Windows host
        $ptaCertLocal = Join-Path $env:TEMP "pta01_cert.der"
        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & scp.exe -i $labKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
            "root@${ptaIP}:/tmp/pta_cert.der" $ptaCertLocal 2>&1 | Out-Null
        $scpExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP

        if ($scpExit -eq 0 -and (Test-Path $ptaCertLocal)) {
            # 3. Copy cert into COMP01 guest
            $guestCertPath = "C:\Windows\Temp\pta01_cert.der"
            Copy-FileToLabVM -VMXPath $comp01Vmx -HostPath $ptaCertLocal `
                -GuestPath $guestCertPath -GuestUser $winAdmin -GuestPassword $winPass

            # 4. Import into LocalMachine\Root via X509Store API (reliable, waits for completion)
            $importResult = Invoke-LabVMPowerShell -VMXPath $comp01Vmx `
                -GuestUser $winAdmin -GuestPassword $winPass -NoThrow -ScriptBlock @"
`$cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2('$guestCertPath')
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
`$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
`$store.Add(`$cert)
`$store.Close()
Write-Host "Imported thumbprint: `$(`$cert.Thumbprint)"
"@
            if ($importResult.ExitCode -eq 0) {
                Write-Host "  [OK] PTA cert imported into COMP01 Trusted Root" -ForegroundColor Green
            } else {
                Write-Warning "X509Store import on COMP01 failed (exit $($importResult.ExitCode)): $($importResult.Output -join '; ')"
                Write-Warning "CAWS00001E will occur. Manual fix on COMP01: certutil -addstore -f Root C:\Windows\Temp\pta01_cert.der"
            }
            Remove-Item $ptaCertLocal -ErrorAction SilentlyContinue
        } else {
            Write-Warning "scp of PTA cert from PTA01 failed (exit $scpExit) -- skipping COMP01 cert import"
        }
    } else {
        Write-Warning "PTA did not return a cert on port $ptaPort -- ptaweb may not be running. Skipping COMP01 cert import."
        Write-Warning "Manual fix: ssh root@$ptaIP; openssl s_client -connect localhost:$ptaPort </dev/null | openssl x509 -outform DER > /tmp/pta_cert.der"
        Write-Warning "Then SCP to host, copy to COMP01, run: certutil -addstore -f Root C:\Windows\Temp\pta01_cert.der"
    }
}

# Step 6h: Deploy DiamondWebApp (PTA web UI + API application).
# diamondWebAppDeploymentUtil.sh deploys ROOT.war and registers PTA with PVWA.
# Runs after step 6g so PVWA's HTTPS callback to PTA succeeds.
Write-Host "  [6h] Deploying DiamondWebApp..." -ForegroundColor DarkGray

$deployUtil  = "/opt/pta/utility/internal/diamondWebAppDeploymentUtil.sh"
$rootWarPath = "/opt/pta/webapps/ROOT.war"
$deployCheck = Invoke-PTASSH -Command "test -f $rootWarPath && echo deployed || echo missing" -NoThrow

if ($deployCheck.Output -match 'deployed') {
    Write-Host "  ROOT.war already present -- re-running deployment util to refresh PVWA registration..." -ForegroundColor DarkGray
}

# Log hostname -f before registering -- this is what PTA tells PVWA its address is.
$ptaHostname = Invoke-PTASSH -Command "hostname -f" -NoThrow
Write-Host "  PTA FQDN (hostname -f): $($ptaHostname.Output -join '')" -ForegroundColor DarkGray

$deployResult = Invoke-PTASSH -Command "bash $deployUtil 2>&1; echo deploy_exit:`$?" -TimeoutSec 180 -NoThrow
Write-Host "  DiamondWebApp deploy output:" -ForegroundColor DarkGray
$deployResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($deployResult.Output -match 'deploy_exit:0') {
    Write-Host "  [OK] DiamondWebApp deployed" -ForegroundColor Green
    # Restart ptaweb so Tomcat picks up ROOT.war
    Invoke-PTASSH -Command "systemctl restart ptaweb 2>&1; sleep 5" -TimeoutSec 60 -NoThrow | Out-Null
} else {
    $deployExitLine = $deployResult.Output | Where-Object { $_ -match 'deploy_exit:' } | Select-Object -Last 1
    Write-Warning "diamondWebAppDeploymentUtil.sh non-zero exit: $deployExitLine"
    Write-Warning "Manual fix: ssh root@$ptaIP then: bash $deployUtil"
}

# Step 6i: Restart PTA services to apply all configuration changes
Write-Host "  [6i] Restarting PTA services..." -ForegroundColor DarkGray
Invoke-PTASSH -Command "systemctl restart appmgr 2>/dev/null; true" -TimeoutSec 90 -NoThrow | Out-Null
Start-Sleep -Seconds 20
$svcStatus = Invoke-PTASSH -Command "systemctl is-active ptaweb.service 2>/dev/null || echo unknown" -NoThrow
Write-Host "  ptaweb status: $($svcStatus.Output -join '')" -ForegroundColor DarkGray

# Step 6j: Wait for ptaweb on port $ptaPort
Write-Host "  [6j] Waiting for PTA web on port $ptaPort..." -ForegroundColor DarkGray
$ptaDeadline = (Get-Date).AddSeconds(180)
$ptaUp = $false
while ((Get-Date) -lt $ptaDeadline) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        if ($tcp.ConnectAsync($ptaIP, $ptaPort).Wait(3000)) {
            $tcp.Close()
            $ptaUp = $true
            break
        }
        $tcp.Close()
    } catch {}
    Write-Host "  Waiting for port $ptaPort..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

if ($ptaUp) {
    Write-Host "  [OK] PTA web is responding on port $ptaPort" -ForegroundColor Green
} else {
    Write-Warning "PTA web did not respond on port $ptaPort within 3 minutes"
    Write-Warning "Check 'systemctl status ptaweb' on PTA01"
}

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "PTA installation complete on $($ptaVM.Name)" -ForegroundColor Green
Write-Host "  PTA API:  https://$ptaIP`:$ptaPort" -ForegroundColor Green
Write-Host "  PTA Web:  https://$ptaIP" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
