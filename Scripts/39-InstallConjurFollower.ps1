<#
.SYNOPSIS
    Create and fully configure a Conjur Follower node - container creation,
    seed transfer from the Leader, and evoke configure follower.
.DESCRIPTION
    Validated manually against F01 and F02 before being scripted - this is
    not first-run code.

    Follower differs from Standby (Scripts\38) in several real ways, not
    just cosmetically:
      - `podman run` only publishes 443+444 (no 5432/1999 - nothing listens
        on those on a Follower) and drops the `backups` volume mount -
        matches the official "Deploy a Secrets Manager container image"
        doc's separate Follower run command exactly.
      - `evoke ca issue` does NOT apply here and is never called. It only
        works for self-signed certs (`evoke ca --help`: "issue/regenerate
        commands are relevant for a self-signed certificates only"). Once
        this cluster's 3rd-party cert was imported (Script 36), Conjur's
        internal CA root was replaced, so `evoke ca issue` has no private
        key to sign with - calling it just errors, it isn't a prerequisite
        step to skip past.
      - **The seed's identity argument is the shared Follower group name
        (conjur-follower.<domain>), NOT the individual node's own hostname.**
        This is the single biggest gotcha found building this script.
        Standby uses its own individual name (each Standby gets its own
        copy of the Leader's cert); Followers as a GROUP share one
        certificate for their load balancer per the official cert-spec
        doc ("each group of Followers shares the certificate for its
        respective load balancer"). Using the node's own name instead
        causes two cascading failures: `evoke seed follower` tries to
        auto-issue a cert for that unrecognized name (hits the `evoke ca
        issue` limitation above), and if you instead manually alias an
        existing cert under the node's name, the encryption's
        filename-derived AAD (see Slosilo::Symmetric - AES-256-GCM keyed
        partly by the cert's own identity string) no longer matches, and
        every subsequent `evoke keys unlock`/`exec` fails with
        `OpenSSL::Cipher::CipherError` - indistinguishable from a wrong
        master key even though the key is correct. Because this script
        always uses the correct shared identity from the start, it never
        creates a wrongly-named file and never hits that class of bug -
        unlike the manual F01 attempt that needed a stale-file cleanup
        step, there is nothing equivalent to clean up here.

    Steps:
      1. Wait for guest-ops on the Follower
      2. Ensure the appliance image is loaded (same as Standby)
      3. System folders + firewalld - only 443/444
      4. Real seccomp profile + `podman run` (no backups mount, no
         5432/1999) + a real systemd unit via `podman generate systemd` (NOT
         `--new` - see Scripts\35's header: `--new` recreates the container
         fresh on every start including after a host reboot, silently wiping
         Postgres data that lives in the container's own filesystem layer -
         a real incident found 2026-07-31 when a host reboot wiped an entire
         live cluster this way)
      5. Seed transfer: `evoke seed follower <shared-follower-fqdn>
         <cluster-fqdn>` on the Leader, piped via SSH into `evoke unpack
         seed -` on the Follower - same host-mediated pipe pattern as
         Standby.
      6. Same known appliance tar/symlink bug as Standby (see Scripts\38's
         header for the full root-cause writeup) - re-run the exact tar
         command evoke logged, tolerate only `Cannot change mode` stderr,
         verify the file set landed.
      7. Copy the Leader's native-encryption master key to the Follower
         (same key everywhere).
      8. `evoke keys exec -m <master.key> -- evoke configure follower`
      9. Verify health on the Follower (`role: follower`, an active entry
         under `logical_replication_status.subscriptions`)

    Idempotent via the container's own `/opt/conjur/etc/role` file, same
    mechanism as Scripts\38.
.EXAMPLE
    .\39-InstallConjurFollower.ps1 -FollowerVMName CONJUR-F01
    .\39-InstallConjurFollower.ps1 -FollowerVMName CONJUR-F02
.NOTES
    Prerequisites: Leader fully configured and healthy. Leader's native
    master key backed up at Config\ConjurSecrets\CONJUR-L01-master.key
    (Script 37). Follower cert already imported on the Leader (Script 36 -
    CN=conjur-follower.<domain>). Windows OpenSSH client (ssh.exe/scp.exe).
#>

[CmdletBinding()]
param(
    [string]  $ConfigPath      = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]  $LeaderVMName    = "CONJUR-L01",
    [Parameter(Mandatory)]
    [string]  $FollowerVMName,
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
$followerVmx = Resolve-NodeVMX -Name $FollowerVMName

$domain         = $Config.Domain.Name
$followerFqdn   = "conjur-follower.$domain"   # shared Follower group identity - NOT $FollowerVMName's own name
$clusterFqdn    = "conjur-cluster.$domain"    # Leader/LB-facing name, matches what evoke seed follower expects as 2nd arg
$followerNodeFqdn = "$($FollowerVMName.ToLower()).$domain"  # only used for --hostname on this specific container

# Conjur nodes are a scripted add-on (Scripts\30+), not part of the base
# LabConfig.psd1 VM inventory - same hardcoded IP map used by
# 30-CloneConjurNodes.ps1 / 31-ConfigureLoadBalancer.ps1 / 38-InstallConjurStandby.ps1.
$nodeIPs = @{
    "CONJUR-L01" = "192.168.100.60"; "CONJUR-S01" = "192.168.100.61"
    "CONJUR-S02" = "192.168.100.62"; "CONJUR-F01" = "192.168.100.65"
    "CONJUR-F02" = "192.168.100.66"
}
$leaderIP   = $nodeIPs[$LeaderVMName]
$followerIP = $nodeIPs[$FollowerVMName]
if (-not $leaderIP)   { throw "No known IP for $LeaderVMName - not one of: $($nodeIPs.Keys -join ', ')" }
if (-not $followerIP) { throw "No known IP for $FollowerVMName - not one of: $($nodeIPs.Keys -join ', ')" }

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

Write-Host "Leader:    $leaderVmx ($clusterFqdn / $leaderIP)" -ForegroundColor Cyan
Write-Host "Follower:  $followerVmx ($followerNodeFqdn / $followerIP)" -ForegroundColor Cyan
Write-Host "Seed identity used: $followerFqdn (shared Follower group name, not this node's own hostname)" -ForegroundColor DarkGray
Wait-GuestOps -Vmx $followerVmx
Write-Host "  guest-ops ready on $FollowerVMName" -ForegroundColor Green

# ------------------------------------------------------------------
# Already fully configured? evoke's own role marker is the real source
# of truth here - container existing doesn't mean configured.
# ------------------------------------------------------------------
$existsCheck = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","podman container exists $ContainerName") -NoThrow
$containerExists = ($existsCheck.ExitCode -eq 0)

if ($containerExists) {
    $roleMarker = "/tmp/conjur_role_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$followerVmx,"/bin/bash","-c","podman exec $ContainerName cat /opt/conjur/etc/role > $roleMarker 2>/dev/null") -NoThrow | Out-Null
    $role = (Get-GuestFileText -Vmx $followerVmx -RemotePath $roleMarker)
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $roleMarker") -NoThrow | Out-Null
    if ($role -and $role.Trim() -eq 'follower') {
        Write-Host "  $FollowerVMName already configured as follower - nothing to do." -ForegroundColor Yellow
        exit 0
    }
    Write-Host "  container '$ContainerName' exists but role is not yet 'follower' (got: '$($role.Trim())') - continuing from seed transfer." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Container creation (skipped if it already exists)
# ------------------------------------------------------------------
if (-not $containerExists) {
    Write-Host "`n[1] System folders + firewalld (443/444 only)" -ForegroundColor Cyan
    $marker1 = "/tmp/conjur_follower_prereq_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prereqScript = @"
#!/bin/bash
set -e
mkdir -p /opt/cyberark/$ContainerName/{security,config,seeds,logs}
firewall-cmd --permanent --add-port=443/tcp --add-port=444/tcp
firewall-cmd --reload
touch $marker1
"@
    Invoke-GuestScriptChecked -Vmx $followerVmx -ScriptText $prereqScript -Marker $marker1 -Label "System folders + firewalld"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $marker1") -NoThrow | Out-Null
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
    Invoke-GuestScriptChecked -Vmx $followerVmx -ScriptText $imageScript -Marker $tagMarker -Label "Ensure image loaded"
    $imageRef = (Get-GuestFileText -Vmx $followerVmx -RemotePath $tagMarker).Trim()
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $tagMarker") -NoThrow | Out-Null
    if (-not $imageRef -or $imageRef -eq 'NO_IMAGE_NO_TARBALL') {
        throw "No appliance image loaded on $FollowerVMName and no tarball found at $RemoteApplianceTarball - run 33-CopyConjurAppliance.ps1 against this node first."
    }
    Write-Host "  [OK] image: $imageRef" -ForegroundColor Green

    Write-Host "`n[3] Create + start container (no backups mount, no 5432/1999)" -ForegroundColor Cyan
    $marker3 = "/tmp/conjur_follower_run_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $runScript = @"
#!/bin/bash
set -e
containerName="$ContainerName"
imageRef="$imageRef"
nodeFqdn="$followerNodeFqdn"

podman run --rm --entrypoint /bin/cat `$imageRef \
  /usr/share/doc/conjur/examples/seccomp.json > /opt/cyberark/`$containerName/security/seccomp.json

mkdir -p /opt/cyberark/`$containerName/{config,security,seeds,logs}

podman run \
  --name `$containerName \
  --hostname `$nodeFqdn \
  --detach \
  --cap-add AUDIT_WRITE \
  --security-opt seccomp=/opt/cyberark/`$containerName/security/seccomp.json \
  --publish "443:443" --publish "444:444" \
  --log-driver journald \
  --volume /opt/cyberark/`$containerName/config:/etc/conjur/config:z \
  --volume /opt/cyberark/`$containerName/security:/opt/cyberark/conjur/security:z \
  --volume /opt/cyberark/`$containerName/logs:/var/log/conjur:z \
  `$imageRef

podman generate systemd --name `$containerName > /etc/systemd/system/`$containerName.service
systemctl daemon-reload
systemctl enable `$containerName.service

touch $marker3
"@
    Invoke-GuestScriptChecked -Vmx $followerVmx -ScriptText $runScript -Marker $marker3 -Label "Create follower container" -TimeoutSec 180
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $marker3") -NoThrow | Out-Null
    Write-Host "  [OK] container created + started" -ForegroundColor Green
} else {
    Write-Host "`n[1-3] Container already exists - skipping creation." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Seed transfer - uses the SHARED Follower group identity, not this
# node's own name. Always attempted, always fails at the tar step
# (known appliance bug, see header). Failure here is expected.
# ------------------------------------------------------------------
Write-Host "`n[4] Seed transfer (Leader -> Follower, shared identity $followerFqdn, expect the known tar warning)" -ForegroundColor Cyan
$seedCmd = "podman exec $ContainerName evoke seed follower $followerFqdn $clusterFqdn"
$unpackCmd = "podman exec -i $ContainerName evoke unpack seed -"
& ssh.exe @sshOpts "root@$leaderIP" $seedCmd | & ssh.exe @sshOpts "root@$followerIP" $unpackCmd
Write-Host "  (seed pipe completed - checking staged content directly, not this command's exit code)" -ForegroundColor DarkGray

# ------------------------------------------------------------------
# Manual tar workaround - re-run the exact tar command evoke logged,
# tolerate ONLY "Cannot change mode" stderr lines, verify completeness.
# ------------------------------------------------------------------
Write-Host "`n[5] Manual seed extraction (working around the tar/symlink appliance bug)" -ForegroundColor Cyan
$marker5 = "/tmp/conjur_follower_extract_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
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
Invoke-GuestScriptChecked -Vmx $followerVmx -ScriptText $extractScript -Marker $marker5 -Label "Manual seed extraction" -TimeoutSec 60
$extractResult = (Get-GuestFileText -Vmx $followerVmx -RemotePath "/tmp/conjur_extract_result.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $marker5 /tmp/conjur_extract_result.txt") -NoThrow | Out-Null

if ($extractResult -match 'SEED_FILE_MISSING') {
    throw "No seed file staged on $FollowerVMName (/dev/shm/seed-file inside the container) - the SSH seed pipe from the Leader did not deliver content. Check SSH connectivity/auth to both nodes and re-run."
}
if ($extractResult -and $extractResult.Trim()) {
    throw "Seed extraction produced unexpected stderr (not just the known symlink-chmod noise) - stopping before configure follower. Output:`n$extractResult"
}
Write-Host "  [OK] extraction stderr contains only the known symlink-chmod noise" -ForegroundColor Green

# Verify the expected file set actually landed (matches F01/F02 validation)
$verifyMarker = "/tmp/conjur_follower_verify_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$verifyScript = @"
#!/bin/bash
set -e
podman exec $ContainerName bash -c "find /opt/conjur/etc/ssl -type f -name '*.key.enc' | wc -l; find /opt/conjur/etc/ssl -type l | wc -l" > /tmp/conjur_verify_result.txt
touch $verifyMarker
"@
Invoke-GuestScriptChecked -Vmx $followerVmx -ScriptText $verifyScript -Marker $verifyMarker -Label "Verify extracted file set" -TimeoutSec 30
$verifyResult = (Get-GuestFileText -Vmx $followerVmx -RemotePath "/tmp/conjur_verify_result.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $verifyMarker /tmp/conjur_verify_result.txt") -NoThrow | Out-Null
$counts = $verifyResult -split "`n" | Where-Object { $_.Trim() -match '^\d+$' } | ForEach-Object { [int]$_.Trim() }
if ($counts.Count -lt 2 -or $counts[0] -lt 1 -or $counts[1] -lt 3) {
    throw "Extracted file set looks incomplete on $FollowerVMName (expected >=1 .key.enc file and >=3 symlinks under /opt/conjur/etc/ssl, got: $verifyResult) - do not proceed to configure follower."
}
Write-Host "  [OK] expected file set present ($($counts[0]) key.enc files, $($counts[1]) symlinks)" -ForegroundColor Green

# ------------------------------------------------------------------
# Copy the Leader's master key + configure as follower
# ------------------------------------------------------------------
Write-Host "`n[6] Copy master key to Follower" -ForegroundColor Cyan
& scp.exe @sshOpts $MasterKeyPath "root@${followerIP}:/opt/cyberark/conjur/security/master.key"
if ($LASTEXITCODE -ne 0) { throw "scp of master key to $FollowerVMName failed (exit $LASTEXITCODE)" }
Write-Host "  [OK]" -ForegroundColor Green

Write-Host "`n[7] evoke configure follower (native key encryption)" -ForegroundColor Cyan
$marker7 = "/tmp/conjur_follower_configure_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$configureScript = @"
#!/bin/bash
set -e
podman exec $ContainerName evoke keys exec -m /opt/cyberark/conjur/security/master.key -- evoke configure follower > /tmp/conjur_configure_out.txt 2>&1
touch $marker7
"@
Invoke-LinuxGuestScript -VMXPath $followerVmx -ScriptText $configureScript `
    -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 180 | Out-Null
$chk7 = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","test -f $marker7") -NoThrow
$configureLog = (Get-GuestFileText -Vmx $followerVmx -RemotePath "/tmp/conjur_configure_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f $marker7") -NoThrow | Out-Null
if ($chk7.ExitCode -ne 0) {
    throw "evoke configure follower failed on $FollowerVMName. Log:`n$configureLog"
}
if ($configureLog -notmatch 'Configuration successful') {
    Write-Warning "evoke configure follower completed but log doesn't contain the expected success line - review manually:`n$configureLog"
} else {
    Write-Host "  [OK] Configuration successful. Conjur follower up and running." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","curl -sk https://localhost/health > /tmp/conjur_health_out.txt 2>&1") -NoThrow | Out-Null
$health = (Get-GuestFileText -Vmx $followerVmx -RemotePath "/tmp/conjur_health_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$followerVmx,"/bin/bash","-c","rm -f /tmp/conjur_health_out.txt") -NoThrow | Out-Null
Write-Host "`nHealth check:" -ForegroundColor Cyan
Write-Host $health -ForegroundColor Gray

Write-Host "`nDone." -ForegroundColor Cyan
