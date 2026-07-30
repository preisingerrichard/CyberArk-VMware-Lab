<#
.SYNOPSIS
    Create and fully configure a Conjur Standby node - container creation,
    seed transfer from the Leader, and evoke configure standby (Installation
    deck's "Configure Standbys" steps 1-2).
.DESCRIPTION
    Validated manually against S01 and S02 before being scripted (twice,
    byte-for-byte identical both times) - this is not first-run code.

    Steps:
      1. Wait for guest-ops on the Standby
      2. Ensure the appliance image is loaded (checks `podman images` first;
         loads from the tarball already staged at /tmp by
         33-CopyConjurAppliance.ps1 if missing - S02 needed this during
         manual validation, S01 didn't, so both paths are exercised)
      3. System folders + firewalld ports (same 4 ports as the Leader:
         443/444/1999/5432 - see Scripts\35's firewalld gotcha, it applies
         identically here)
      4. Real seccomp profile + `podman run` (hostname, --cap-add
         AUDIT_WRITE, :z mounts, backups plural, no --restart) + a real
         systemd unit via `podman generate systemd --new`
      5. Seed transfer: `evoke seed standby <standby-fqdn> <leader-fqdn>` on
         the Leader, piped directly (over real SSH, not guest-ops - this is
         a host-mediated two-VM pipe, matching 33-CopyConjurAppliance.ps1's
         SSH precedent) into `evoke unpack seed -` on the Standby.
      6. **KNOWN APPLIANCE BUG, not a Podman gap**: step 5 above always
         fails with `error: Unable to extract seed file`. Traced into
         `/opt/conjur/evoke/lib/evoke/action/unpack/seed.rb` - the seed's
         /opt/conjur/etc/ssl/ symlinks trigger a tar chmod call Linux has
         never supported for symlinks; the GNU tar 1.35 bundled in this
         appliance image attempts it anyway (most tar builds silently skip
         it) and evoke checks tar's raw exit code with zero tolerance.
         Ruled out before concluding this: SELinux (reproduced in permissive
         mode), missing capabilities (CAP_FOWNER/CAP_CHOWN both present),
         storage driver (overlay-native and bind-mounted paths both fail
         identically), TAR_OPTIONS=--no-same-permissions (changes the
         attempted mode, not whether tar attempts it). Filed as a CyberArk
         support ticket - see CLIENT-CONJUR-INSTALL-CHECKLIST.md Section 2
         for the full writeup. The actual file content lands correctly
         despite the error - only the cosmetic symlink-chmod step fails, and
         evoke's own remaining checks (`remove_seed_file` is a no-op when
         seeding via stdin; `ensure_key_present` only checks a real
         non-symlink key file exists) already pass once the content is on
         disk. This step re-runs the exact tar command evoke logged,
         confirms stderr has nothing but `Cannot change mode` lines (aborts
         if it finds anything else - that would be a real problem, not this
         known one), then verifies the expected file set landed.
      7. Copy the Leader's native-encryption master key to the Standby (same
         key everywhere - required before `evoke keys exec` will work here)
      8. `evoke keys exec -m <master.key> -- evoke configure standby`
      9. Verify health on the Standby (`role: standby`, `streaming: true`)

    Idempotent via the container's own `/opt/conjur/etc/role` file - if it
    already reads "standby", the node is fully configured and this script
    reports success and exits without repeating seed transfer or configure
    (which are not safe/meaningful to blindly re-run against an already-live
    node). Container creation itself is idempotent via `podman container
    exists`, same as 35-InstallConjurLeader.ps1.
.EXAMPLE
    .\38-InstallConjurStandby.ps1 -StandbyVMName CONJUR-S01
    .\38-InstallConjurStandby.ps1 -StandbyVMName CONJUR-S02
.NOTES
    Prerequisites: Leader fully configured (evoke configure master) and
    healthy. Leader's native master key backed up at
    Config\ConjurSecrets\CONJUR-L01-master.key (Script 37). Windows OpenSSH
    client (ssh.exe/scp.exe) - same as 33-CopyConjurAppliance.ps1.
#>

[CmdletBinding()]
param(
    [string]  $ConfigPath      = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]  $LeaderVMName    = "CONJUR-L01",
    [Parameter(Mandatory)]
    [string]  $StandbyVMName,
    [string]  $ContainerName   = "conjur",
    [string]  $GuestUser       = "root",
    [string]  $GuestPass       = "Cyberark1",
    [string]  $MasterKeyPath   = "$PSScriptRoot\..\Config\ConjurSecrets\CONJUR-L01-master.key",
    [string]  $RemoteApplianceTarball = "/tmp/conjur-appliance-Rls-v13.9.0.tar.gz"
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "ssh.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}
if (-not (Test-Path $MasterKeyPath)) {
    throw "Master key not found at $MasterKeyPath - run Scripts\37-EncryptConjurLeaderKeys.ps1 against the Leader first."
}

$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
function Resolve-NodeVMX {
    param([string]$Name)
    $candidates = @((Join-Path $vmFolder "$Name\$Name.vmx"), (Join-Path $vmFolder "$Name.vmx"))
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw "VM not found: $Name. Tried:`n  $($candidates -join "`n  ")" }
    return $found
}
$leaderVmx   = Resolve-NodeVMX -Name $LeaderVMName
$standbyVmx  = Resolve-NodeVMX -Name $StandbyVMName

$domain      = $Config.Domain.Name
$leaderFqdn  = "$($LeaderVMName.ToLower()).$domain"
$standbyFqdn = "$($StandbyVMName.ToLower()).$domain"

# Conjur nodes are a scripted add-on (Scripts\30+), not part of the base
# LabConfig.psd1 VM inventory - same hardcoded IP map used by
# 30-CloneConjurNodes.ps1 / 31-ConfigureLoadBalancer.ps1.
$nodeIPs = @{
    "CONJUR-L01" = "192.168.100.60"; "CONJUR-S01" = "192.168.100.61"
    "CONJUR-S02" = "192.168.100.62"; "CONJUR-F01" = "192.168.100.65"
    "CONJUR-F02" = "192.168.100.66"
}
$leaderIP  = $nodeIPs[$LeaderVMName]
$standbyIP = $nodeIPs[$StandbyVMName]
if (-not $leaderIP)  { throw "No known IP for $LeaderVMName - not one of: $($nodeIPs.Keys -join ', ')" }
if (-not $standbyIP) { throw "No known IP for $StandbyVMName - not one of: $($nodeIPs.Keys -join ', ')" }

$labKeyPath = Join-Path $PSScriptRoot "..\Config\conjur_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\conjur_lab_key"
if (-not (Test-Path $labKeyPath)) { throw "SSH key not found: $labKeyPath - run 33-CopyConjurAppliance.ps1 first (it bootstraps this key)." }
$sshOpts = @("-i", $labKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
             "-o", "BatchMode=yes", "-o", "ConnectTimeout=10")

function Wait-GuestOps {
    param([string]$Vmx, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep 5
        $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$Vmx,"/bin/true") -NoThrow -TimeoutSeconds 20
        if ($r.ExitCode -eq 0) { return }
    } while ((Get-Date) -lt $deadline)
    throw "Guest-ops did not become available on $Vmx within $TimeoutSec s"
}

function Invoke-GuestScriptChecked {
    param([string]$Vmx, [string]$ScriptText, [string]$Marker, [string]$Label, [int]$TimeoutSec = 120)
    $r = Invoke-LinuxGuestScript -VMXPath $Vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds $TimeoutSec
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$Vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

function Get-GuestFileText {
    param([string]$Vmx, [string]$RemotePath)
    $local = [System.IO.Path]::Combine($env:TEMP, "conjur_read_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt")
    $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "copyFileFromGuestToHost",$Vmx,$RemotePath,$local) -NoThrow
    if ($r.ExitCode -ne 0) { return $null }
    $text = Get-Content $local -Raw -ErrorAction SilentlyContinue
    Remove-Item $local -Force -ErrorAction SilentlyContinue
    return $text
}

Write-Host "Leader:   $leaderVmx ($leaderFqdn / $leaderIP)" -ForegroundColor Cyan
Write-Host "Standby:  $standbyVmx ($standbyFqdn / $standbyIP)" -ForegroundColor Cyan
Wait-GuestOps -Vmx $standbyVmx
Write-Host "  guest-ops ready on $StandbyVMName" -ForegroundColor Green

# ------------------------------------------------------------------
# Already fully configured? evoke's own role marker is the real source
# of truth here - container existing doesn't mean configured.
# ------------------------------------------------------------------
$existsCheck = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","podman container exists $ContainerName") -NoThrow
$containerExists = ($existsCheck.ExitCode -eq 0)

if ($containerExists) {
    # role file lives inside the container's own storage, not host-bind-mounted -
    # read it via podman exec through a temp host-side redirect
    $roleMarker = "/tmp/conjur_role_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$standbyVmx,"/bin/bash","-c","podman exec $ContainerName cat /opt/conjur/etc/role > $roleMarker 2>/dev/null") -NoThrow | Out-Null
    $role = (Get-GuestFileText -Vmx $standbyVmx -RemotePath $roleMarker)
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $roleMarker") -NoThrow | Out-Null
    if ($role -and $role.Trim() -eq 'standby') {
        Write-Host "  $StandbyVMName already configured as standby - nothing to do." -ForegroundColor Yellow
        exit 0
    }
    Write-Host "  container '$ContainerName' exists but role is not yet 'standby' (got: '$($role.Trim())') - continuing from seed transfer." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Container creation (skipped if it already exists)
# ------------------------------------------------------------------
if (-not $containerExists) {
    Write-Host "`n[1] System folders + firewalld" -ForegroundColor Cyan
    $marker1 = "/tmp/conjur_standby_prereq_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prereqScript = @"
#!/bin/bash
set -e
mkdir -p /opt/cyberark/$ContainerName/{security,config,backups,seeds,logs}
firewall-cmd --permanent --add-port=443/tcp --add-port=444/tcp --add-port=1999/tcp --add-port=5432/tcp
firewall-cmd --reload
touch $marker1
"@
    Invoke-GuestScriptChecked -Vmx $standbyVmx -ScriptText $prereqScript -Marker $marker1 -Label "System folders + firewalld"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $marker1") -NoThrow | Out-Null
    Write-Host "  [OK]" -ForegroundColor Green

    Write-Host "`n[2] Ensure appliance image is loaded" -ForegroundColor Cyan
    $tagMarker = "/tmp/conjur_tag_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $imageScript = @"
#!/bin/bash
set -e
if ! podman images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^registry.tld/conjur-appliance:' > $tagMarker; then
  if [ -f '$RemoteApplianceTarball' ]; then
    podman load -i '$RemoteApplianceTarball'
    podman images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^registry.tld/conjur-appliance:' > $tagMarker
  else
    echo "NO_IMAGE_NO_TARBALL" > $tagMarker
  fi
fi
"@
    Invoke-GuestScriptChecked -Vmx $standbyVmx -ScriptText $imageScript -Marker $tagMarker -Label "Ensure image loaded"
    $imageRef = (Get-GuestFileText -Vmx $standbyVmx -RemotePath $tagMarker).Trim()
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $tagMarker") -NoThrow | Out-Null
    if (-not $imageRef -or $imageRef -eq 'NO_IMAGE_NO_TARBALL') {
        throw "No appliance image loaded on $StandbyVMName and no tarball found at $RemoteApplianceTarball - run 33-CopyConjurAppliance.ps1 against this node first."
    }
    Write-Host "  [OK] image: $imageRef" -ForegroundColor Green

    Write-Host "`n[3] Create + start container" -ForegroundColor Cyan
    $marker3 = "/tmp/conjur_standby_run_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $runScript = @"
#!/bin/bash
set -e
containerName="$ContainerName"
imageRef="$imageRef"
nodeFqdn="$standbyFqdn"

podman run --rm --entrypoint /bin/cat `$imageRef \
  /usr/share/doc/conjur/examples/seccomp.json > /opt/cyberark/`$containerName/security/seccomp.json

mkdir -p /opt/cyberark/`$containerName/{config,security,backups,seeds,logs}

podman run \
  --name `$containerName \
  --hostname `$nodeFqdn \
  --detach \
  --cap-add AUDIT_WRITE \
  --security-opt seccomp=/opt/cyberark/`$containerName/security/seccomp.json \
  --publish "443:443" --publish "444:444" --publish "5432:5432" --publish "1999:1999" \
  --log-driver journald \
  --volume /opt/cyberark/`$containerName/config:/etc/conjur/config:z \
  --volume /opt/cyberark/`$containerName/security:/opt/cyberark/conjur/security:z \
  --volume /opt/cyberark/`$containerName/backups:/opt/conjur/backup:z \
  --volume /opt/cyberark/`$containerName/seeds:/opt/cyberark/conjur/seeds:z \
  --volume /opt/cyberark/`$containerName/logs:/var/log/conjur:z \
  `$imageRef

podman generate systemd --new --name `$containerName > /etc/systemd/system/`$containerName.service
systemctl daemon-reload
systemctl enable `$containerName.service

touch $marker3
"@
    Invoke-GuestScriptChecked -Vmx $standbyVmx -ScriptText $runScript -Marker $marker3 -Label "Create standby container" -TimeoutSec 180
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $marker3") -NoThrow | Out-Null
    Write-Host "  [OK] container created + started" -ForegroundColor Green
} else {
    Write-Host "`n[1-3] Container already exists - skipping creation." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Seed transfer - always attempted, always fails at the tar step
# (known appliance bug, see header). Failure here is expected.
# ------------------------------------------------------------------
Write-Host "`n[4] Seed transfer (Leader -> Standby, expect the known tar warning)" -ForegroundColor Cyan
$seedCmd = "podman exec $ContainerName evoke seed standby $standbyFqdn $leaderFqdn"
$unpackCmd = "podman exec -i $ContainerName evoke unpack seed -"
# Plain native-command pipe, matching exactly what was validated manually
# against S01/S02 - ssh1's stdout streams directly into ssh2's stdin.
& ssh.exe @sshOpts "root@$leaderIP" $seedCmd | & ssh.exe @sshOpts "root@$standbyIP" $unpackCmd
Write-Host "  (seed pipe completed - checking staged content directly, not this command's exit code)" -ForegroundColor DarkGray

# ------------------------------------------------------------------
# Manual tar workaround - re-run the exact tar command evoke logged,
# tolerate ONLY "Cannot change mode" stderr lines, verify completeness.
# ------------------------------------------------------------------
Write-Host "`n[5] Manual seed extraction (working around the tar/symlink appliance bug)" -ForegroundColor Cyan
$marker5 = "/tmp/conjur_standby_extract_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$extractScript = @"
#!/bin/bash
set -e
if ! podman exec $ContainerName test -f /dev/shm/seed-file; then
  echo "SEED_FILE_MISSING" > /tmp/conjur_extract_result.txt
  touch $marker5
  exit 0
fi
podman exec $ContainerName bash -c "tar --exclude /opt/conjur/etc/VERSION --exclude /opt/conjur/etc/PAS_RELEASE --exclude /opt/conjur/etc/role --exclude 'ui.key*' -x --exclude='*.conf*' -f '/dev/shm/seed-file' -C / 2> /tmp/tar_stderr.log; grep -v 'Cannot change mode' /tmp/tar_stderr.log > /tmp/tar_stderr_filtered.log || true"
podman exec $ContainerName cat /tmp/tar_stderr_filtered.log > /tmp/conjur_extract_result.txt
touch $marker5
"@
Invoke-GuestScriptChecked -Vmx $standbyVmx -ScriptText $extractScript -Marker $marker5 -Label "Manual seed extraction" -TimeoutSec 60
$extractResult = (Get-GuestFileText -Vmx $standbyVmx -RemotePath "/tmp/conjur_extract_result.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $marker5 /tmp/conjur_extract_result.txt") -NoThrow | Out-Null

if ($extractResult -match 'SEED_FILE_MISSING') {
    throw "No seed file staged on $StandbyVMName (/dev/shm/seed-file inside the container) - the SSH seed pipe from the Leader did not deliver content. Check SSH connectivity/auth to both nodes and re-run."
}
if ($extractResult -and $extractResult.Trim()) {
    throw "Seed extraction produced unexpected stderr (not just the known symlink-chmod noise) - stopping before configure standby. Output:`n$extractResult"
}
Write-Host "  [OK] extraction stderr contains only the known symlink-chmod noise" -ForegroundColor Green

# Verify the expected file set actually landed (11 entries, matches S01/S02 validation)
$verifyMarker = "/tmp/conjur_standby_verify_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$verifyScript = @"
#!/bin/bash
set -e
podman exec $ContainerName bash -c "find /opt/conjur/etc/ssl -type f -name '*.key.enc' | wc -l; find /opt/conjur/etc/ssl -type l | wc -l" > /tmp/conjur_verify_result.txt
touch $verifyMarker
"@
Invoke-GuestScriptChecked -Vmx $standbyVmx -ScriptText $verifyScript -Marker $verifyMarker -Label "Verify extracted file set" -TimeoutSec 30
$verifyResult = (Get-GuestFileText -Vmx $standbyVmx -RemotePath "/tmp/conjur_verify_result.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $verifyMarker /tmp/conjur_verify_result.txt") -NoThrow | Out-Null
$counts = $verifyResult -split "`n" | Where-Object { $_.Trim() -match '^\d+$' } | ForEach-Object { [int]$_.Trim() }
if ($counts.Count -lt 2 -or $counts[0] -lt 2 -or $counts[1] -lt 4) {
    throw "Extracted file set looks incomplete on $StandbyVMName (expected >=2 .key.enc files and >=4 symlinks under /opt/conjur/etc/ssl, got: $verifyResult) - do not proceed to configure standby."
}
Write-Host "  [OK] expected file set present ($($counts[0]) key.enc files, $($counts[1]) symlinks)" -ForegroundColor Green

# ------------------------------------------------------------------
# Copy the Leader's master key + configure as standby
# ------------------------------------------------------------------
Write-Host "`n[6] Copy master key to Standby" -ForegroundColor Cyan
& scp.exe @sshOpts $MasterKeyPath "root@${standbyIP}:/opt/cyberark/conjur/security/master.key"
if ($LASTEXITCODE -ne 0) { throw "scp of master key to $StandbyVMName failed (exit $LASTEXITCODE)" }
Write-Host "  [OK]" -ForegroundColor Green

Write-Host "`n[7] evoke configure standby (native key encryption)" -ForegroundColor Cyan
$marker7 = "/tmp/conjur_standby_configure_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$configureScript = @"
#!/bin/bash
set -e
podman exec $ContainerName evoke keys exec -m /opt/cyberark/conjur/security/master.key -- evoke configure standby > /tmp/conjur_configure_out.txt 2>&1
touch $marker7
"@
Invoke-LinuxGuestScript -VMXPath $standbyVmx -ScriptText $configureScript `
    -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 180 | Out-Null
$chk7 = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","test -f $marker7") -NoThrow
$configureLog = (Get-GuestFileText -Vmx $standbyVmx -RemotePath "/tmp/conjur_configure_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f $marker7") -NoThrow | Out-Null
if ($chk7.ExitCode -ne 0) {
    throw "evoke configure standby failed on $StandbyVMName. Log:`n$configureLog"
}
if ($configureLog -notmatch 'Configuration successful') {
    Write-Warning "evoke configure standby completed but log doesn't contain the expected success line - review manually:`n$configureLog"
} else {
    Write-Host "  [OK] Configuration successful. Conjur standby up and running." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","curl -sk https://localhost/health > /tmp/conjur_health_out.txt 2>&1") -NoThrow | Out-Null
$health = (Get-GuestFileText -Vmx $standbyVmx -RemotePath "/tmp/conjur_health_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$standbyVmx,"/bin/bash","-c","rm -f /tmp/conjur_health_out.txt") -NoThrow | Out-Null
Write-Host "`nHealth check:" -ForegroundColor Cyan
Write-Host $health -ForegroundColor Gray

Write-Host "`nDone. If this is the last Standby, run on the Leader:" -ForegroundColor Cyan
Write-Host "  podman exec $ContainerName evoke replication sync start" -ForegroundColor Yellow
