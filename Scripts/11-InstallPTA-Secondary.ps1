<#
.SYNOPSIS
    Install CyberArk PTA Secondary Server for Disaster Recovery.
.DESCRIPTION
    Installs minimal PTA Secondary for DR replication. Secondary runs only ptadb.service,
    with data replicated from Primary.

    Usage - after Primary is installed:
      .\11-InstallPTA-Secondary.ps1 -PTANames @("PTA02")

    Steps per Secondary:
      1   Copy PTA installer files via SCP
      2   Import CyberArk GPG key into RPM keyring
      3   Install sshpass (PTA prerequisite)
      4   Configure firewalld (PTA port rules)
      5   Run PTA installer (handles its own reboot)
      6   Configure vault connectivity (minimal setup for db replication)
              6a  Patch Vault.ini (vault IP/port)
              6b  Add real-IP FQDN entry to /etc/hosts
              6c  Run vaultPermissionsValidation.sh
              6d  Run minimalPrepwiz.sh (minimal wizard, no PVWA registration)
              6e  Verify ptadb.service running (Secondary only runs DB, not web UI)

    After Secondary is up, on Primary run:
      ssh root@pta01.cyberark.lab
      bash /opt/pta/utility/dr/setupPrimary.sh
      (Provide Secondary SAN name and root password when prompted)

    Prerequisites:
    - PTA Primary must already be installed and running
    - PTA Secondary VM must be created (10-CreatePTAVM.ps1)
    - Windows OpenSSH client (ssh.exe / scp.exe) - included in Windows 10/11
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string[]]$PTANames = @("PTA02")
)

$ErrorActionPreference = 'Stop'

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

$allPTAVMs = @($Config.VMs | Where-Object { $_.Role -eq 'PTA' -or $_.Role -contains 'PTA' })
if (-not $allPTAVMs) { throw "No VM with Role 'PTA' found in LabConfig.psd1" }

$ptaVMs = @($allPTAVMs | Where-Object { $_.Name -in $PTANames })
if (-not $ptaVMs) { throw "No PTA VMs found matching names: $($PTANames -join ', ')" }
if ($ptaVMs.Count -ne 1 -or $ptaVMs[0].Name -ne 'PTA02') {
    throw "11-InstallPTA-Secondary.ps1 is intended for PTA02 only. Use 11-InstallPTA-Primary.ps1 for PTA01."
}

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing PTA Secondary on: $($ptaVMs.Name -join ', ')" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

foreach ($vm in $ptaVMs) {
    $vmx = Join-Path $Config.VMware.DefaultVMFolder "$($vm.Name)\$($vm.Name).vmx"
    if (-not (Test-Path $vmx)) {
        throw "$($vm.Name) VMX not found at '$vmx' - run 10-CreatePTAVM.ps1 first"
    }
}

$mediaBase = $Config.CyberArkMedia.BasePath
$ptaSource = Join-Path $mediaBase $Config.CyberArkMedia.PTAFolder
$guestDir  = $CAConfig.PTA.GuestInstallDir

$labKeyPath = Join-Path $PSScriptRoot "..\Config\pta_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath) ).Path + "\pta_lab_key"

if (-not (Test-Path $labKeyPath)) {
    Write-Host "Generating lab SSH key at $labKeyPath ..." -ForegroundColor Cyan
    & ssh-keygen.exe -t ed25519 -f $labKeyPath -N '""' -C "pta-lab-automation" | Out-Null
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
}
$labPubKey = Get-Content "$labKeyPath.pub" -Raw

foreach ($ptaVM in $ptaVMs) {
    $ptaIP     = $ptaVM.IPAddress

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
Write-Host "Installing PTA Secondary on $($ptaVM.Name) ($ptaIP)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

Write-Host "`n[Pre-flight] Waiting for $($ptaVM.Name) SSH..." -ForegroundColor Yellow
Wait-PTASSH -TimeoutSeconds 300

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
Write-Host "  [OK] $($ptaVM.Name) SSH is ready (key auth)" -ForegroundColor Green

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
    if (-not $sshpassFile)             { throw "sshpass-*.rpm not found in $ptaSource" }

    Write-Host "  Found: $($tgzFile.Name) ($([math]::Round($tgzFile.Length/1MB,1)) MB)" -ForegroundColor DarkGray
    Write-Host "  Found: $($rpmFile.Name)" -ForegroundColor DarkGray
    Write-Host "  Found: $($sshpassFile.Name)" -ForegroundColor DarkGray

    Invoke-PTASSH -Command "mkdir -p $guestDir" | Out-Null

    foreach ($file in @($installerSh, $tgzFile.FullName, $rpmFile.FullName, $sshpassFile.FullName)) {
        Copy-ToGuest -LocalPath $file -RemoteDir $guestDir
    }

    Write-Host "  [OK] All installer files transferred" -ForegroundColor Green
}

Write-Host "`n[Step 2] Importing CyberArk GPG key into RPM keyring..." -ForegroundColor Yellow

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
    Write-Host "  RPM-GPG-KEY-CyberArk not found in $ptaSource" -ForegroundColor Yellow
    Write-Host "  Falling back: patching installer to use 'rpm -K --nosignature'..." -ForegroundColor DarkGray
    $patchResult = Invoke-PTASSH -Command "sed -i 's/rpm -K/rpm -K --nosignature/g' '$guestDir/pta_installer.sh' && echo 'patched'" -NoThrow
    if ($patchResult.Output -match 'patched') {
        Write-Host "  [OK] Installer patched (rpm -K --nosignature)" -ForegroundColor Green
    } else {
        Write-Warning "Installer patch may have failed: $($patchResult.Error -join '; ')"
    }
}

Write-Host "`n[Step 3] Ensuring sshpass is installed (PTA prerequisite)..." -ForegroundColor Yellow

$sshpassCheck = Invoke-PTASSH -Command "rpm -q sshpass >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
if ($sshpassCheck.Output -match 'missing') {
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

    $pingTest = Invoke-PTASSH -Command "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo routable || echo no_route" -NoThrow
    Write-Host "  Internet routing: $($pingTest.Output -join '')" -ForegroundColor DarkGray

    $dnsTest = Invoke-PTASSH -Command "getent hosts mirrors.rockylinux.org >/dev/null 2>&1 && echo dns_ok || echo dns_fail" -NoThrow
    Write-Host "  DNS resolution: $($dnsTest.Output -join '')" -ForegroundColor DarkGray

    if ($pingTest.Output -match 'routable' -and $dnsTest.Output -match 'dns_ok') {
        Write-Host "  Internet reachable - installing sshpass via dnf (Rocky AppStream)..." -ForegroundColor DarkGray
        $dnfResult = Invoke-PTASSH -Command "dnf install -y sshpass 2>&1; echo dnf_exit:`$?" -TimeoutSec 120 -NoThrow
        $dnfResult.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        $rpmReason = if ($pingTest.Output -notmatch 'routable') { "No internet route" } else { "DNS resolution failed" }
        Write-Host "  $rpmReason - installing from staged RPM..." -ForegroundColor DarkGray
        $sshpassLocal = Get-ChildItem $ptaSource -Filter "sshpass-*.rpm" | Select-Object -First 1
        if (-not $sshpassLocal) {
            throw "sshpass-*.rpm not found in $ptaSource and $($ptaVM.Name) has no internet."
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

Write-Host "`n[Step 4] Configuring firewalld (PTA port rules)..." -ForegroundColor Yellow

$fwScript = @'
#!/bin/bash
systemctl enable --now firewalld
Z=public
firewall-cmd --permanent --zone=$Z --add-port=80/tcp
firewall-cmd --permanent --zone=$Z --add-port=8080/tcp
firewall-cmd --permanent --zone=$Z --add-port=11514/tcp
firewall-cmd --permanent --zone=$Z --add-port=11514/udp
# ptaDB / MongoDB replication port (required for DR pairing with the Primary)
firewall-cmd --permanent --zone=$Z --add-port=27017/tcp
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
        Write-Warning "Installer SSH exited with code $sshExit - check /tmp/pta_install.log on $($ptaVM.Name)"
    }

    Write-Host "  Waiting for VM to come back up after reboot..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    Wait-PTASSH -TimeoutSeconds 600

    $logDone = Invoke-PTASSH -Command "grep -c 'PTA deployed successfully' /tmp/pta_upgrade.log 2>/dev/null || echo 0" -NoThrow
    if ($sshExit -ne 255 -and $logDone.Output -match '^[1-9]') {
        Write-Host "  Installer exited cleanly (no SSH drop) - rebooting VM manually..." -ForegroundColor DarkGray
        Invoke-PTASSH -Command "reboot" -NoThrow | Out-Null
        Start-Sleep -Seconds 30
        Wait-PTASSH -TimeoutSeconds 600
    }

    Write-Host "  Waiting for ptadb service (up to 5 min) - Secondary only..." -ForegroundColor DarkGray
    $ptaDeadline = (Get-Date).AddMinutes(5)
    $ptaReady    = $false
    while ((Get-Date) -lt $ptaDeadline) {
        $svc = Invoke-PTASSH -Command "systemctl is-active ptadb 2>/dev/null" -NoThrow
        if ($svc.Output -match '^active') { $ptaReady = $true; break }
        Write-Host "  ptadb: $($svc.Output -join '' | ForEach-Object { $_.Trim() }) -- waiting..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }

    if (-not $ptaReady) {
        $installLog = Invoke-PTASSH -Command "tail -30 /tmp/pta_upgrade.log 2>/dev/null || echo '(no log)'" -NoThrow
        $installLog.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "ptadb not active 5 min after reboot. Check log above."
    }

    Write-Host "  [OK] PTA installed (Secondary ptadb ready)" -ForegroundColor Green
}

Write-Host "`n[Step 6] Configuring PTA vault connectivity (minimal for Secondary)..." -ForegroundColor Yellow

$vaultIP      = $CAConfig.Vault.VaultAddress
$vaultPort    = $CAConfig.Vault.VaultPort
$vaultIniPath = "/etc/opt/pta/diamond-resources/Vault.ini"

Write-Host "  [6a] Patching $vaultIniPath..." -ForegroundColor DarkGray
$patchResult = Invoke-PTASSH -Command "test -f $vaultIniPath && sed -i 's/^ADDRESS=.*/ADDRESS=$vaultIP/' $vaultIniPath && sed -i 's/^PORT=.*/PORT=$vaultPort/' $vaultIniPath && echo patched || echo missing" -NoThrow
if ($patchResult.Output -match 'patched') {
    $vaultCheck = Invoke-PTASSH -Command "grep -E '^(ADDRESS|PORT)=' $vaultIniPath" -NoThrow
    Write-Host "  $($vaultCheck.Output -join '  ')" -ForegroundColor DarkGray
    Write-Host "  [OK] Vault.ini patched" -ForegroundColor Green
} else {
    Write-Warning "Vault.ini not found at $vaultIniPath - skipping direct patch"
}

Write-Host "  [6b] Adding real-IP FQDN entry to /etc/hosts..." -ForegroundColor DarkGray
$ptaFQDN  = "$($ptaVM.Name.ToLower()).$($Config.Domain.Name)"
$ptaShort = $ptaVM.Name.ToLower()
$hostsPresent = Invoke-PTASSH -Command "grep -qF '$ptaFQDN' /etc/hosts && echo present || echo missing" -NoThrow
if ($hostsPresent.Output -notmatch 'present') {
    Invoke-PTASSH -Command "echo '$ptaIP  $ptaFQDN $ptaShort' >> /etc/hosts" -NoThrow | Out-Null
}
$fqdnCheck = Invoke-PTASSH -Command "grep -vE '^#|^\s*$' /etc/hosts" -NoThrow
$fqdnCheck.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  [OK] /etc/hosts updated" -ForegroundColor Green

Write-Host "  [6c] Running vaultPermissionsValidation.sh..." -ForegroundColor DarkGray
$vaultValFind = Invoke-PTASSH -Command "find /opt/pta -name 'vaultPermissionsValidation.sh' 2>/dev/null | head -1" -NoThrow
$vaultValPath = ($vaultValFind.Output -join '').Trim()

if ($vaultValPath) {
    Write-Host "  Found: $vaultValPath" -ForegroundColor DarkGray
    $vaultValCmd = "echo 'Y' | VAULT_ADMIN_USER='$($CAConfig.Vault.AdminUser)' VAULT_ADMIN_PASSWORD='$($CAConfig.Vault.AdminPassword)' timeout 60 bash '$vaultValPath' 2>&1; echo val_exit:`$?"
    $valResult = Invoke-PTASSH -Command $vaultValCmd -TimeoutSec 90 -NoThrow
    $valResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($valResult.Output -match 'val_exit:0') {
        Write-Host "  [OK] vaultPermissionsValidation.sh succeeded" -ForegroundColor Green
    } else {
        Write-Warning "vaultPermissionsValidation.sh non-zero exit -- vault connectivity may be broken"
    }
} else {
    Write-Host "  vaultPermissionsValidation.sh not found under /opt/pta" -ForegroundColor DarkGray
}

Write-Host "  [6d] Running minimalPrepwiz.sh (Secondary minimal configuration)..." -ForegroundColor DarkGray
$minimalWizPath = "/opt/pta/utility/dr/minimalPrepwiz.sh"
$minimalWizCheck = Invoke-PTASSH -Command "test -f $minimalWizPath && echo exists || echo missing" -NoThrow

if ($minimalWizCheck.Output -match 'exists') {
    Write-Host "  Found minimalPrepwiz.sh - running Secondary minimal wizard..." -ForegroundColor DarkGray
    $wizScript = @"
#!/bin/bash
echo 'Y' | timeout 180 bash $minimalWizPath 2>&1
echo wiz_exit:`$?
"@

    $tmpWizScript = Join-Path ([System.IO.Path]::GetTempPath()) "pta_secondary_wiz.sh"
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tmpWizScript, ($wizScript -replace "`r`n", "`n"), $utf8NoBom)
        Copy-ToGuest -LocalPath $tmpWizScript -RemoteDir "/tmp"

        Write-Host "  Waiting up to 3 minutes for minimal wizard..." -ForegroundColor DarkGray
        $wizResult = Invoke-PTASSH -Command "chmod +x /tmp/pta_secondary_wiz.sh && bash /tmp/pta_secondary_wiz.sh" -TimeoutSec 240 -NoThrow
        $wizResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        if ($wizResult.Output -match 'wiz_exit:0') {
            Write-Host "  [OK] Minimal wizard completed" -ForegroundColor Green
        } else {
            Write-Warning "Minimal wizard exited non-zero (may be expected for Secondary)"
        }
    } finally {
        Remove-Item $tmpWizScript -ErrorAction SilentlyContinue
    }
} else {
    Write-Warning "minimalPrepwiz.sh not found at $minimalWizPath - Secondary may not configure properly"
    Write-Warning "After Primary is fully installed, run on Primary: bash /opt/pta/utility/dr/setupPrimary.sh"
}

Write-Host "  [6e] Verifying ptadb.service running (Secondary only)..." -ForegroundColor DarkGray
$dbStatus = Invoke-PTASSH -Command "systemctl is-active ptadb 2>/dev/null" -NoThrow
Write-Host "  ptadb service: $($dbStatus.Output -join '')" -ForegroundColor DarkGray

if ($dbStatus.Output -match 'active') {
    Write-Host "  [OK] ptadb running on Secondary" -ForegroundColor Green
} else {
    Write-Warning "ptadb not active - replication may fail"
}

    Write-Host "`n$("=" * 60)" -ForegroundColor Green
    Write-Host "PTA Secondary installation complete on $($ptaVM.Name)" -ForegroundColor Green
    Write-Host "  IP:   $ptaIP" -ForegroundColor Green
    Write-Host "  Mode: Secondary (ptadb only, no web UI)" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor Green
}

Write-Host "`nAll PTA Secondary installations complete." -ForegroundColor Green
Write-Host "`n$("=" * 80)" -ForegroundColor Cyan
Write-Host "NEXT STEPS FOR FULL DR DEPLOYMENT" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan

Write-Host "`n[Step 1] Shared DNS A record (pta.cyberark.lab -> Primary IP)" -ForegroundColor Yellow
Write-Host "  Created automatically by 11b-ConfigurePTACertificates.ps1 (Step 1b)." -ForegroundColor DarkGray
Write-Host "  Always points to the Primary IP only - NOT load balanced. Failover is" -ForegroundColor DarkGray
Write-Host "  handled internally by the Vault dbparm.ini; external components always" -ForegroundColor DarkGray
Write-Host "  talk to the Primary. The shared name must exist before setupPrimary.sh." -ForegroundColor DarkGray

Write-Host "`n[Step 2] Generate Certificate Signing Requests (CSR)" -ForegroundColor Yellow
Write-Host "  On each PTA server (Primary and Secondary):" -ForegroundColor DarkGray
Write-Host "    ssh root@pta0X.cyberark.lab" -ForegroundColor DarkGray
Write-Host "    /opt/pta/utility/certificateSigningRequestGenerationUtil.sh" -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "  OR use run.sh menu option 14:" -ForegroundColor DarkGray
Write-Host "    bash /opt/pta/utility/run.sh" -ForegroundColor DarkGray
Write-Host "    Select: 14. Generating a Certificate Signing Request (CSR)" -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "  Enter certificate details. For Subject Alternative Names (SAN), use:" -ForegroundColor DarkGray
Write-Host "    PRIMARY:   dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40" -ForegroundColor DarkGray
Write-Host "    SECONDARY: dns:pta02.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.41" -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "  CSR output: /opt/pta/ca/pta_server.csr" -ForegroundColor DarkGray
Write-Host "  Download CSR via SCP and submit to your Certificate Authority (CA)" -ForegroundColor DarkGray

Write-Host "`n[Step 3] Install certificates on PTA servers" -ForegroundColor Yellow
Write-Host "  After CA returns signed certificates and certificate chain:" -ForegroundColor DarkGray
Write-Host "    1. Upload cert + chain to PTA server via WinSCP or SCP" -ForegroundColor DarkGray
Write-Host "    2. On PTA server, run option 15 from run.sh:" -ForegroundColor DarkGray
Write-Host "       bash /opt/pta/utility/run.sh" -ForegroundColor DarkGray
Write-Host "       Select: 15. Installing SSL Certificate Chain" -ForegroundColor DarkGray
Write-Host "    3. Specify certificate paths when prompted" -ForegroundColor DarkGray
Write-Host "    4. Vault admin credentials will be required (Administrator / Cyberark1)" -ForegroundColor DarkGray

Write-Host "`n[Step 4] Setup replication on Primary" -ForegroundColor Yellow
Write-Host "  After both servers are fully installed (certificates in place):" -ForegroundColor DarkGray
Write-Host "    ssh root@pta01.cyberark.lab" -ForegroundColor DarkGray
Write-Host "    bash /opt/pta/utility/dr/setupPrimary.sh" -ForegroundColor DarkGray
Write-Host "  Provide:" -ForegroundColor DarkGray
Write-Host "    Primary SAN name: pta01" -ForegroundColor DarkGray
Write-Host "    Secondary SAN name: pta02" -ForegroundColor DarkGray
Write-Host "    Secondary root password: Cyberark!Local2024" -ForegroundColor DarkGray

Write-Host "`n[Step 5] Verify replication" -ForegroundColor Yellow
Write-Host "  On Primary:" -ForegroundColor DarkGray
Write-Host "    cat /opt/pta/mode" -ForegroundColor DarkGray
Write-Host "    mongosh --host localhost:27017 --eval 'rs.status()'" -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "  On Secondary:" -ForegroundColor DarkGray
Write-Host "    cat /opt/pta/mode" -ForegroundColor DarkGray
Write-Host "    systemctl status ptadb" -ForegroundColor DarkGray
Write-Host "" -ForegroundColor DarkGray
Write-Host "  In PVWA:" -ForegroundColor DarkGray
Write-Host "    Administration > Privileged Threat Analytics" -ForegroundColor DarkGray
Write-Host "    Primary (pta01) should show: Connected" -ForegroundColor DarkGray

Write-Host "`n$("=" * 80)" -ForegroundColor Cyan
Write-Host "Full documentation: Scripts\README-PTA-DR.md" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
