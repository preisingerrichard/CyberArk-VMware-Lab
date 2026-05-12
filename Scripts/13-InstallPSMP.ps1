<#
.SYNOPSIS
    Install CyberArk PSM for SSH Proxy (PSMP) on PSMP01 (Rocky Linux 9).
.DESCRIPTION
    Uses Windows built-in ssh.exe/scp.exe with the shared lab Ed25519 key.

    Install order:
      1   Copy installer files (RPM, GPG key)
      2   Fix DNS for dnf
      3   Install OS dependencies (sssd, realmd, adcli, oddjob)
      4   Disable NSCD
      5   Stage psmpparms at /var/tmp/psmpparms (before RPM install)
      6   Install PSMP RPM (RPM %post reads psmpparms at install time)
      7   Register PSMP with vault via psmp_setup.sh
              7a  Configure vault.ini from RPM example
              7b  Create vault admin credential file
              7c  Run psmp_setup.sh --finalize
      8   Configure /etc/hosts
      9   Join AD domain via realm
      10  Verify psmpsrv service

    Prerequisites:
    - PSMP01 running Rocky Linux 9 with SSH key auth (12-CreatePSMPVM.ps1)
    - Windows OpenSSH client (ssh.exe / scp.exe)
    - Files in Installers\PSMP\:
        CARKpsmp-<version>.x86_64.rpm   (required)
        RPM-GPG-KEY-CyberArk            (required for signed install)
        psmpparms.sample                (reference — script generates psmpparms from it)
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
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

$psmpVM = $Config.VMs | Where-Object { $_.Role -eq 'PSMP' -or $_.Role -contains 'PSMP' } | Select-Object -First 1
if (-not $psmpVM) { throw "No VM with Role 'PSMP' found in LabConfig.psd1" }

$psmpVMX   = Join-Path $Config.VMware.DefaultVMFolder "$($psmpVM.Name)\$($psmpVM.Name).vmx"
$psmpIP    = $psmpVM.IPAddress
$mediaBase = $Config.CyberArkMedia.BasePath
$psmpSrc   = Join-Path $mediaBase $Config.CyberArkMedia.PSMPFolder
$guestDir  = $CAConfig.PSMP.GuestInstallDir

if (-not (Test-Path $psmpVMX)) {
    throw "PSMP01 VMX not found at '$psmpVMX' - run 12-CreatePSMPVM.ps1 first"
}

$labKeyPath = Join-Path $PSScriptRoot "..\Config\psmp_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\psmp_lab_key"
if (-not (Test-Path $labKeyPath)) {
    throw "SSH key not found at $labKeyPath - run 12-CreatePSMPVM.ps1 first"
}

$sshOpts = @(
    "-i", $labKeyPath,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10"
)

function Wait-PSMPSSH {
    param([int]$TimeoutSeconds = 300)
    Write-Host "  Waiting for SSH on ${psmpIP}:22..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            if ($tcp.ConnectAsync($psmpIP, 22).Wait(3000)) { $tcp.Close(); Start-Sleep -Seconds 5; return }
            $tcp.Close()
        } catch {}
        Start-Sleep -Seconds 10
    }
    throw "SSH on $psmpIP did not become reachable within $TimeoutSeconds seconds"
}

function Invoke-PSMPSSH {
    param([string]$Command, [int]$TimeoutSec = 120, [switch]$NoThrow)
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = $null
    try { $raw = & ssh.exe @sshOpts "root@$psmpIP" $Command 2>&1 } catch {}
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
        $LocalPath "root@${psmpIP}:${RemoteDir}/"
    $scpExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($scpExit -ne 0) { throw "scp failed for $fileName (exit $scpExit)" }
}

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk PSMP on $($psmpVM.Name) ($psmpIP)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# ================================================================
# Pre-flight
# ================================================================
Write-Host "`n[Pre-flight] Waiting for PSMP01 SSH..." -ForegroundColor Yellow
Wait-PSMPSSH -TimeoutSeconds 300

$keyAuthDeadline = (Get-Date).AddMinutes(10)
$keyAuthed = $false
while ((Get-Date) -lt $keyAuthDeadline) {
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & ssh.exe @sshOpts "root@$psmpIP" "echo ok" 2>&1 } catch {}
    $keyExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($keyExit -eq 0) { $keyAuthed = $true; break }
    Write-Host "  Key auth not yet ready - retrying in 15s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
    Wait-PSMPSSH -TimeoutSeconds 60
}
if (-not $keyAuthed) { throw "Key-based SSH auth failed. Run 12-CreatePSMPVM.ps1 to regenerate VM." }
Write-Host "  [OK] PSMP01 SSH is ready" -ForegroundColor Green

Write-Host "`n[Pre-flight] Checking Vault reachability..." -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds(60)
$vaultReachable = $false
while ((Get-Date) -lt $deadline) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($CAConfig.Vault.VaultAddress, $CAConfig.Vault.VaultPort)
        $tcp.Close(); $vaultReachable = $true; break
    } catch { Start-Sleep -Seconds 5 }
}
if (-not $vaultReachable) {
    throw "Vault not reachable on $($CAConfig.Vault.VaultAddress):$($CAConfig.Vault.VaultPort) - Vault must be running before PSMP RPM install"
}
Write-Host "  [OK] Vault is reachable (RPM %post will connect to vault)" -ForegroundColor Green

# ================================================================
# Step 1: Copy installer files
# ================================================================
Write-Host "`n[Step 1] Copying PSMP installer files to $($psmpVM.Name)..." -ForegroundColor Yellow

$psmpRPM   = Get-ChildItem $psmpSrc -Filter "CARKpsmp-*.x86_64.rpm" -ErrorAction SilentlyContinue | Select-Object -First 1
$gpgKeyLocal = Join-Path $psmpSrc "RPM-GPG-KEY-CyberArk"

if (-not $psmpRPM) { throw "CARKpsmp-*.x86_64.rpm not found in $psmpSrc" }
Write-Host "  Found: $($psmpRPM.Name) ($([math]::Round($psmpRPM.Length/1MB,1)) MB)" -ForegroundColor DarkGray

Invoke-PSMPSSH -Command "mkdir -p $guestDir" | Out-Null

$alreadyUploaded = Invoke-PSMPSSH -Command "test -f $guestDir/$($psmpRPM.Name) && echo yes || echo no" -NoThrow
if ($alreadyUploaded.Output -match 'yes') {
    Write-Host "  [SKIP] RPM already on guest" -ForegroundColor Yellow
} else {
    Copy-ToGuest -LocalPath $psmpRPM.FullName -RemoteDir $guestDir
}

if (Test-Path $gpgKeyLocal) {
    Copy-ToGuest -LocalPath $gpgKeyLocal -RemoteDir $guestDir
    Write-Host "  GPG key staged for import" -ForegroundColor DarkGray
}

Write-Host "  [OK] Files ready on guest" -ForegroundColor Green

# ================================================================
# Step 2: Fix DNS for package installation
# ================================================================
Write-Host "`n[Step 2] Fixing DNS for package installation..." -ForegroundColor Yellow

$nmFix = Invoke-PSMPSSH -Command @'
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

$pingTest = Invoke-PSMPSSH -Command "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo routable || echo no_route" -NoThrow
$dnsTest  = Invoke-PSMPSSH -Command "getent hosts rocky.resf.org >/dev/null 2>&1 && echo dns_ok || echo dns_fail" -NoThrow
Write-Host "  Routing: $($pingTest.Output -join '') | DNS: $($dnsTest.Output -join '')" -ForegroundColor DarkGray

# ================================================================
# Step 3: Install OS dependencies
# ================================================================
Write-Host "`n[Step 3] Installing OS dependencies..." -ForegroundColor Yellow

$depsCheck = Invoke-PSMPSSH -Command "rpm -q realmd >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
if ($depsCheck.Output -match 'installed') {
    Write-Host "  [SKIP] Dependencies already installed" -ForegroundColor Yellow
} elseif ($pingTest.Output -match 'routable' -and $dnsTest.Output -match 'dns_ok') {
    $depsResult = Invoke-PSMPSSH -Command @'
dnf install -y sssd sssd-ad sssd-tools sssd-krb5 \
    realmd adcli \
    oddjob oddjob-mkhomedir \
    samba-common-tools \
    krb5-workstation \
    policycoreutils-python-utils \
    openssl 2>&1
echo deps_exit:$?
'@ -TimeoutSec 300 -NoThrow
    $depsResult.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if (-not ($depsResult.Output -match 'deps_exit:0')) {
        Write-Warning "Dependency install may have failed - realm join in Step 5 may not work"
    } else {
        Write-Host "  [OK] OS dependencies installed" -ForegroundColor Green
    }
} else {
    Write-Warning "No internet - OS dependencies must be pre-installed. Required: sssd sssd-ad realmd adcli oddjob samba-common-tools krb5-workstation"
}

# ================================================================
# Step 4: Disable NSCD
# SSSD handles name resolution; NSCD caching conflicts with it and causes
# stale-credential issues with AD-joined users.
# ================================================================
Write-Host "`n[Step 4] Disabling NSCD..." -ForegroundColor Yellow

$nscdResult = Invoke-PSMPSSH -Command @'
systemctl stop nscd.service nscd.socket 2>/dev/null || true
systemctl disable nscd.service nscd.socket 2>/dev/null || true
echo nscd_done
'@ -TimeoutSec 15 -NoThrow
if ($nscdResult.Output -match 'nscd_done') {
    Write-Host "  [OK] NSCD stopped and disabled" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] NSCD not present" -ForegroundColor DarkGray
}

# ================================================================
# Step 5: Stage psmpparms at /var/tmp/psmpparms (before RPM install)
# RPM %post reads this for EULA acceptance and hardening settings.
# vault.ini is configured after RPM install via psmp_setup.sh.
# ================================================================
Write-Host "`n[Step 5] Staging psmpparms at /var/tmp/psmpparms..." -ForegroundColor Yellow

# Hardening=No avoids fapolicy issues in a lab environment.
# PSMPMachineDomainName ensures vault users are named correctly for this host.
$psmpParmsContent = @"
[Main]
AcceptCyberArkEULA=Yes
Hardening=No
HardeningDoDIN=No
PSMPMachineDomainName=$($Config.Domain.Name)
"@

$tmpPsmpparms = Join-Path ([System.IO.Path]::GetTempPath()) "psmpparms"
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpPsmpparms, ($psmpParmsContent -replace "`r`n", "`n"), $utf8NoBom)
    Copy-ToGuest -LocalPath $tmpPsmpparms -RemoteDir "/var/tmp"
} finally {
    Remove-Item $tmpPsmpparms -ErrorAction SilentlyContinue
}

$parmsCheck = Invoke-PSMPSSH -Command "cat /var/tmp/psmpparms" -NoThrow
$parmsCheck.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  [OK] psmpparms staged" -ForegroundColor Green

# ================================================================
# Step 6: Import GPG key and install PSMP RPM
# ================================================================
Write-Host "`n[Step 6] Installing PSMP RPM..." -ForegroundColor Yellow

$psmpInstalled = Invoke-PSMPSSH -Command "rpm -q CARKpsmp >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
if ($psmpInstalled.Output -match 'installed') {
    Write-Host "  [SKIP] CARKpsmp already installed" -ForegroundColor Yellow
} else {
    # Import CyberArk GPG key if available
    $gpgOnGuest = Invoke-PSMPSSH -Command "test -f $guestDir/RPM-GPG-KEY-CyberArk && echo yes || echo no" -NoThrow
    if ($gpgOnGuest.Output -match 'yes') {
        Write-Host "  Importing CyberArk GPG key..." -ForegroundColor DarkGray
        $gpgResult = Invoke-PSMPSSH -Command "rpm --import '$guestDir/RPM-GPG-KEY-CyberArk' && echo gpg_ok" -NoThrow
        if ($gpgResult.Output -match 'gpg_ok') {
            Write-Host "  [OK] GPG key imported" -ForegroundColor Green
        } else {
            Write-Warning "GPG key import may have failed - will fall back to --nosignature"
        }
    }

    Write-Host "  Installing CARKpsmp (RPM %post will connect to vault -- may take 2-3 min)..." -ForegroundColor DarkGray

    # Try signed install first; fall back to --nosignature if GPG not imported
    $rpmCmd = "rpm -ivh $guestDir/$($psmpRPM.Name) 2>&1; echo rpm_exit:`$?"
    $rpmResult = Invoke-PSMPSSH -Command $rpmCmd -TimeoutSec 300 -NoThrow
    $rpmResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    # If signed install failed with GPG error, retry with --nosignature
    if (-not ($rpmResult.Output -match 'rpm_exit:0')) {
        if ($rpmResult.Output -match 'NOKEY|GPG|signature') {
            Write-Host "  GPG check failed - retrying with --nosignature..." -ForegroundColor Yellow
            $rpmResult = Invoke-PSMPSSH -Command "rpm -ivh --nosignature $guestDir/$($psmpRPM.Name) 2>&1; echo rpm_exit:`$?" -TimeoutSec 300 -NoThrow
            $rpmResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }

    $psmpVerify = Invoke-PSMPSSH -Command "rpm -q CARKpsmp >/dev/null 2>&1 && echo installed || echo missing" -NoThrow
    if ($psmpVerify.Output -notmatch 'installed') {
        throw "CARKpsmp RPM install failed. See output above."
    }
    Write-Host "  [OK] CARKpsmp installed" -ForegroundColor Green
}

# ================================================================
# Step 7: Register PSMP with vault via psmp_setup.sh
#   7a. Copy vault.ini example (installed by RPM), set ADDRESS
#   7b. createcredfile -notsecure (non-interactive, lab only)
#   7c. psmp_setup.sh --finalize  (creates vault users + cred files)
# ================================================================
Write-Host "`n[Step 7] Registering PSMP with vault (psmp_setup.sh)..." -ForegroundColor Yellow

$credsAlready = Invoke-PSMPSSH -Command "test -f /etc/opt/CARKpsmp/vault/psmpappuser.cred && echo yes || echo no" -NoThrow
if ($credsAlready.Output -match 'yes') {
    Write-Host "  [SKIP] Vault cred files already present" -ForegroundColor Yellow
} else {
    # Step 7a: Configure vault.ini from the example shipped with the RPM
    Write-Host "  Configuring vault.ini..." -ForegroundColor DarkGray
    $vaultIniCmd = @"
cp /opt/CARKpsmp/doc/examples/vault.ini /tmp/psmp_vault.ini
sed -i 's/^ADDRESS=.*/ADDRESS=$($CAConfig.Vault.VaultAddress)/' /tmp/psmp_vault.ini
sed -i 's/^PORT=.*/PORT=$($CAConfig.Vault.VaultPort)/' /tmp/psmp_vault.ini
echo vault_ini_ok
"@
    $vaultIniResult = Invoke-PSMPSSH -Command $vaultIniCmd -TimeoutSec 15 -NoThrow
    $vaultIniResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if (-not ($vaultIniResult.Output -match 'vault_ini_ok')) {
        throw "Failed to configure vault.ini from RPM example. Check /opt/CARKpsmp/doc/examples/."
    }

    # Step 7b: Create vault admin credential file (non-interactive, -notsecure for lab)
    Write-Host "  Creating vault admin credential file..." -ForegroundColor DarkGray
    $credFile     = "/tmp/user.cred"
    $credBin      = "/opt/CARKpsmp/bin/createcredfile"
    $credCmd      = "'$credBin' '$credFile' Password -username '$($CAConfig.Vault.AdminUser)' -password '$($CAConfig.Vault.AdminPassword)' -osusername root -notsecure 2>&1; echo cred_exit:`$?"
    $credResult   = Invoke-PSMPSSH -Command $credCmd -TimeoutSec 30 -NoThrow
    $credResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if (-not ($credResult.Output -match 'cred_exit:0')) {
        throw "createcredfile failed. See output above."
    }

    # Step 7c: Run psmp_setup.sh --finalize
    Write-Host "  Running psmp_setup.sh --finalize (may take 2-3 min)..." -ForegroundColor DarkGray
    $setupCmd    = "/opt/CARKpsmp/bin/psmp_setup.sh --finalize --vault-ini /tmp/psmp_vault.ini --credfile '$credFile' 2>&1; echo setup_exit:`$?"
    $setupResult = Invoke-PSMPSSH -Command $setupCmd -TimeoutSec 300 -NoThrow
    $setupResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    Invoke-PSMPSSH -Command "rm -f '$credFile' /tmp/psmp_vault.ini" -NoThrow | Out-Null

    if (-not ($setupResult.Output -match 'setup_exit:0')) {
        Write-Warning "psmp_setup.sh non-zero exit. Check /var/opt/CARKpsmp/temp/psmp_setup.log"
        $setupLog = Invoke-PSMPSSH -Command "tail -20 /var/opt/CARKpsmp/temp/psmp_setup.log 2>/dev/null || echo '(no log)'" -NoThrow
        $setupLog.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    } else {
        Write-Host "  [OK] PSMP registered in vault" -ForegroundColor Green
    }
}

# ================================================================
# Step 8: Update /etc/hosts
# ================================================================
Write-Host "`n[Step 8] Updating /etc/hosts..." -ForegroundColor DarkGray

$psmpFQDN  = "$($psmpVM.Name.ToLower()).$($Config.Domain.Name)"
$psmpShort = $psmpVM.Name.ToLower()

foreach ($pair in @(
    @{ IP = $psmpIP;                        FQDN = $psmpFQDN;                            Short = $psmpShort },
    @{ IP = $CAConfig.Vault.VaultAddress;   FQDN = "vault01.$($Config.Domain.Name)";     Short = "vault01" }
)) {
    $present = Invoke-PSMPSSH -Command "grep -qF '$($pair.FQDN)' /etc/hosts && echo present || echo missing" -NoThrow
    if ($present.Output -match 'missing') {
        Invoke-PSMPSSH -Command "echo '$($pair.IP)  $($pair.FQDN) $($pair.Short)' >> /etc/hosts" -NoThrow | Out-Null
    }
}
$hostsContent = Invoke-PSMPSSH -Command "grep -vE '^#|^\s*$' /etc/hosts" -NoThrow
$hostsContent.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  [OK] /etc/hosts updated" -ForegroundColor Green

# ================================================================
# Step 9: Join AD domain
# ================================================================
Write-Host "`n[Step 9] Joining AD domain ($($Config.Domain.Name))..." -ForegroundColor Yellow

$domainJoined = Invoke-PSMPSSH -Command "realm list 2>/dev/null | grep -q '$($Config.Domain.Name)' && echo joined || echo not_joined" -NoThrow
if ($domainJoined.Output -match 'joined') {
    Write-Host "  [SKIP] Already joined to $($Config.Domain.Name)" -ForegroundColor Yellow
} else {
    $dcReach = Invoke-PSMPSSH -Command "ping -c 1 -W 3 $($Config.Network.DNS) >/dev/null 2>&1 && echo ok || echo fail" -NoThrow
    if ($dcReach.Output -notmatch 'ok') {
        Write-Warning "DC01 ($($Config.Network.DNS)) not reachable - domain join may fail"
    }

    Write-Host "  Running realm join (DC01: $($Config.Network.DNS))..." -ForegroundColor DarkGray
    $joinCmd = "echo '$($Config.Domain.DomainAdminPass)' | realm join --user=$($Config.Domain.DomainAdminUser) $($Config.Domain.Name) 2>&1; echo join_exit:`$?"
    $joinResult = Invoke-PSMPSSH -Command $joinCmd -TimeoutSec 120 -NoThrow
    $joinResult.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if ($joinResult.Output -match 'join_exit:0') {
        Write-Host "  [OK] Joined $($Config.Domain.Name)" -ForegroundColor Green
        Invoke-PSMPSSH -Command "realm permit --all 2>/dev/null; true" -NoThrow | Out-Null
        Invoke-PSMPSSH -Command "authselect select sssd with-mkhomedir --force 2>/dev/null; true" -NoThrow | Out-Null
        Invoke-PSMPSSH -Command "systemctl enable --now oddjobd 2>/dev/null; true" -NoThrow | Out-Null
    } else {
        Write-Warning "realm join non-zero exit -- PSMP AD authentication will not work until domain join succeeds"
        Write-Warning "Manual fix: ssh root@$psmpIP  then:  echo '<pass>' | realm join --user=Administrator $($Config.Domain.Name)"
    }
}

# ================================================================
# Step 10: Verify psmpsrv service
# ================================================================
Write-Host "`n[Step 10] Checking psmpsrv service..." -ForegroundColor Yellow

# RPM %post should have started the service; give it a moment
Start-Sleep -Seconds 5
Invoke-PSMPSSH -Command "systemctl restart psmpsrv-psmpserver psmpsrv-psmpadbserver 2>/dev/null; true" -TimeoutSec 30 -NoThrow | Out-Null
Start-Sleep -Seconds 3

$svcStatus = Invoke-PSMPSSH -Command "systemctl is-active psmpsrv-psmpserver 2>/dev/null || echo unknown" -NoThrow
Write-Host "  psmpsrv-psmpserver: $($svcStatus.Output -join '')" -ForegroundColor DarkGray
$adbStatus = Invoke-PSMPSSH -Command "systemctl is-active psmpsrv-psmpadbserver 2>/dev/null || echo unknown" -NoThrow
Write-Host "  psmpsrv-psmpadbserver: $($adbStatus.Output -join '')" -ForegroundColor DarkGray

if ($svcStatus.Output -match '^active') {
    Write-Host "  [OK] PSMP services running" -ForegroundColor Green
} else {
    $journalLog = Invoke-PSMPSSH -Command "journalctl -u psmpsrv-psmpserver --no-pager -n 30 2>/dev/null || echo '(no journal)'" -NoThrow
    $journalLog.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Warning "psmpsrv-psmpserver not active."
    Write-Warning "Check logs: /var/opt/CARKpsmp/logs/PSMPConsole.log"
}

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "PSMP installation complete on $($psmpVM.Name)" -ForegroundColor Green
Write-Host "  SSH proxy: $psmpIP`:22" -ForegroundColor Green
Write-Host "  Connect:   ssh <user>@<target>@$psmpIP" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
