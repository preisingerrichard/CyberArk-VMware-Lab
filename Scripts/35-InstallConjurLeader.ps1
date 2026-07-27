<#
.SYNOPSIS
    Create and start the Conjur Leader container on CONJUR-L01 (Installation
    deck Step 6 / Exercise Guide's 1-Install-leader.sh), using a real
    extracted seccomp profile instead of seccomp=unconfined.
.DESCRIPTION
    UNTESTED - first validation run pending.

    This is deliberately scoped to container creation only - it does NOT run
    `evoke configure master` (that needs cluster name, admin password, and
    account name decided first; see CLIENT-CONJUR-INSTALL-CHECKLIST.md). Run
    that separately once you've confirmed the final node/altname list.

    Steps (guest-ops over vmrun, same pattern as Scripts\30-34):
      1. Wait for guest-ops
      2. Detect the loaded conjur-appliance image tag (podman images) -
         auto-adapts if a different version is ever loaded, no hardcoded
         version to keep in sync
      3. Extract that image's own seccomp profile to
         /opt/cyberark/conjur/security/seccomp.json (CyberArk-shipped
         profile plus the add_key/keyctl/request_key syscalls Conjur needs -
         NOT --security-opt seccomp=unconfined, which is TEST/DEV only per
         the Installation deck)
      4. If a container named $ContainerName doesn't already exist, create
         + start it with that profile and the standard leader port set
         (443/444/5432/1999) and volume mounts

    Reconciled against CyberArk's official "Deploy a Secrets Manager
    container image" doc (not just the training deck, which has since turned
    out to disagree with current docs in a few places):
      - `--cap-add AUDIT_WRITE` added explicitly. Docker's classic default
        capability set included AUDIT_WRITE; Podman's does not - confirmed
        by the official doc too ("When you run Secrets Manager in Podman,
        add --cap-add AUDIT_WRITE"). Without it the appliance logs
        "AUDIT_WRITE capability is not present... required for scheduled
        CRON jobs" and exits immediately.
      - Volume mount uses .../backups (plural) - matches the official doc's
        folder layout exactly, and 32-CreateConjurSystemFolders.ps1 was
        corrected to match. (Earlier version of this script used singular
        "backup", based on a mismatch in the older training deck where its
        own mkdir step used "backup" but its docker-run step mounted
        "backups" - we picked the wrong side of that mismatch. The current
        official docs are consistently plural.)
      - `:z` (lowercase) SELinux mount label, not `:Z` (uppercase) - matches
        the official doc exactly. The doc explicitly warns "incorrect use of
        :z and :Z options may render the host OS inoperable", so this
        deliberately follows the documented flag rather than guessing.
      - `--hostname <node-FQDN>` added - the official doc sets this
        explicitly on every node; earlier version omitted it, leaving the
        container with Podman's default (non-FQDN) hostname.
      - NOT using `--restart=unless-stopped` on `podman run` - the official
        doc is explicit: "If you are using Podman, you must not specify the
        --restart option in the run command... specify a restart policy when
        you create the systemd [unit] instead." Reboot survival is handled
        by generating a real systemd unit via `podman generate systemd`
        (below), not by a container-level restart flag. Earlier version of
        this script used --restart=unless-stopped + podman-restart.service,
        which contradicts this guidance - removed.
      - Defensive `mkdir -p` for all mount paths runs right before `podman
        run` regardless of what 32-CreateConjurSystemFolders.ps1 already
        did - Podman does not auto-create missing bind-mount host
        directories like Docker does, so a missing folder hard-fails the
        whole run with a statfs error instead of a silent auto-create.
      - firewalld ports opened for 443/444/1999/5432 - not a Podman-vs-Docker
        gap, just a step nothing else in the pipeline did. firewalld ships
        enabled on RHEL 9.8 (default zone: ssh only); `podman --publish`
        still routes through the host's normal netfilter chains, so without
        this the leader answered on localhost but was unreachable from the
        HAProxy pool on APP01 - confirmed live before this was added.

    NOTE: the systemd-unit step below follows Podman's standard *rootful*
    generate-systemd pattern (`podman generate systemd --new --name ... >
    /etc/systemd/system/<name>.service`). CyberArk's official doc's Step 11
    is written for both root/rootless, but the rootful-tab body wasn't
    available when this was written (only the rootless
    $HOME/.config/systemd/user variant was seen) - since this lab runs
    containers as true root (not a rootless Podman user), the standard
    Podman rootful equivalent is used instead. Verify against the actual
    CyberArk doc's Rootful tab before relying on this for a real engagement.

    Idempotent: re-running with the container already present just reports
    it and exits - does not recreate or restart it. NOTE: this only checks
    existence, not health - if a previous attempt left a crash-looping or
    stopped container behind, remove it first (`podman rm -f conjur`) before
    re-running, otherwise this script will see it "exists" and skip.
.EXAMPLE
    .\35-InstallConjurLeader.ps1
.NOTES
    Prerequisites: CONJUR-L01 cloned+registered+appliance-loaded (Scripts
    30/33), system folders created (Scripts 32).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath    = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$VMName        = "CONJUR-L01",
    [string]$ContainerName = "conjur",
    [string]$GuestUser     = "root",
    [string]$GuestPass     = "Cyberark1"
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
$candidates = @((Join-Path $vmFolder "$VMName\$VMName.vmx"), (Join-Path $vmFolder "$VMName.vmx"))
$vmx = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmx) { throw "VM not found: $VMName. Tried:`n  $($candidates -join "`n  ")" }

$nodeFqdn = "$($VMName.ToLower()).$($Config.Domain.Name)"

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
    param([string]$ScriptText, [string]$Marker, [string]$Label, [int]$TimeoutSec = 120)
    $r = Invoke-LinuxGuestScript -VMXPath $vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds $TimeoutSec
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

Write-Host "Target: $vmx" -ForegroundColor Cyan
Wait-GuestOps -Vmx $vmx
Write-Host "  guest-ops ready" -ForegroundColor Green

# ------------------------------------------------------------------
# Already running? Report and stop - this script never recreates.
# ------------------------------------------------------------------
$existsCheck = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","podman container exists $ContainerName") -NoThrow
if ($existsCheck.ExitCode -eq 0) {
    Write-Host "  container '$ContainerName' already exists - not recreating. Remove it manually first if you want a fresh container." -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------
# Detect the loaded image tag
# ------------------------------------------------------------------
$tagMarker = "/tmp/conjur_tag_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
$tagScript = @"
#!/bin/bash
set -e
podman images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^registry.tld/conjur-appliance:' > $tagMarker
"@
Invoke-GuestScriptChecked -ScriptText $tagScript -Marker $tagMarker -Label "Detect loaded image tag"
$tagOut = [System.IO.Path]::Combine($env:TEMP, "conjur_tag_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "copyFileFromGuestToHost",$vmx,$tagMarker,$tagOut) | Out-Null
$imageRef = (Get-Content $tagOut -Raw).Trim()
Remove-Item $tagOut -Force -ErrorAction SilentlyContinue
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $tagMarker") -NoThrow | Out-Null
if (-not $imageRef) { throw "No registry.tld/conjur-appliance:* image found loaded on $VMName - run the ConjurAppliance feature first." }
Write-Host "  detected image: $imageRef" -ForegroundColor Green

# ------------------------------------------------------------------
# Extract the real seccomp profile + create/start the container
# ------------------------------------------------------------------
$marker = "/tmp/conjur_leader_install_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$installScript = @"
#!/bin/bash
set -e
containerName="$ContainerName"
imageRef="$imageRef"
nodeFqdn="$nodeFqdn"

# Real seccomp profile from THIS image build - not seccomp=unconfined
# (that's TEST/DEV only per CyberArk's Installation deck)
podman run --rm --entrypoint /bin/cat `$imageRef \
  /usr/share/doc/conjur/examples/seccomp.json > /opt/cyberark/`$containerName/security/seccomp.json

# Podman (unlike Docker) does NOT auto-create missing host bind-mount
# directories - it fails the whole `podman run` with a statfs error instead.
# Belt-and-suspenders: make sure every mount target exists even if
# 32-CreateConjurSystemFolders.ps1 was skipped or a folder went missing.
mkdir -p /opt/cyberark/`$containerName/{config,security,backups,seeds,logs}

echo "Creating Conjur Leader (Master) Server Container"
echo "------------------------------------"
set -x
podman run \
  --name `$containerName \
  --hostname `$nodeFqdn \
  --detach \
  --cap-add AUDIT_WRITE \
  --security-opt seccomp=/opt/cyberark/`$containerName/security/seccomp.json \
  --publish "443:443" \
  --publish "444:444" \
  --publish "5432:5432" \
  --publish "1999:1999" \
  --log-driver journald \
  --volume /opt/cyberark/`$containerName/config:/etc/conjur/config:z \
  --volume /opt/cyberark/`$containerName/security:/opt/cyberark/conjur/security:z \
  --volume /opt/cyberark/`$containerName/backups:/opt/conjur/backup:z \
  --volume /opt/cyberark/`$containerName/seeds:/opt/cyberark/conjur/seeds:z \
  --volume /opt/cyberark/`$containerName/logs:/var/log/conjur:z \
  `$imageRef
set +x

# Podman has no long-running daemon watching containers the way dockerd does
# (which re-applies restart policy at its own boot-time startup) - a bare
# --restart flag on the container does NOT survive a host reboot. Official
# guidance: do not use --restart with Podman at all, generate a real systemd
# unit instead. Rootful equivalent of the doc's Step 11 (doc's shown example
# was the rootless $HOME/.config/systemd/user variant).
podman generate systemd --new --name `$containerName > /etc/systemd/system/`$containerName.service
systemctl daemon-reload
systemctl enable `$containerName.service

# firewalld ships enabled on RHEL 9.8, default zone only allows the ssh
# service - podman --publish still routes inbound traffic through the host's
# normal netfilter chains, so without this every port above is reachable
# only from localhost (confirmed live: curl https://localhost/health worked,
# but the same request via the HAProxy pool from APP01 was silently dropped
# until this was added).
firewall-cmd --permanent --add-port=443/tcp --add-port=444/tcp --add-port=1999/tcp --add-port=5432/tcp
firewall-cmd --reload

touch $marker
"@
Invoke-GuestScriptChecked -ScriptText $installScript -Marker $marker -Label "Create leader container" -TimeoutSec 180
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
Write-Host "  container created + started" -ForegroundColor Green

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","podman ps --filter name=$ContainerName --format '{{.Names}} {{.Status}} {{.Image}}' > /tmp/conjur_ps_out.txt") -NoThrow | Out-Null
$psFile = [System.IO.Path]::Combine($env:TEMP, "conjur_ps_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "copyFileFromGuestToHost",$vmx,"/tmp/conjur_ps_out.txt",$psFile) | Out-Null
Write-Host "`nDone. Container status:" -ForegroundColor Cyan
Get-Content $psFile | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Remove-Item $psFile -Force -ErrorAction SilentlyContinue
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f /tmp/conjur_ps_out.txt") -NoThrow | Out-Null

Write-Host "`nNext step (not run by this script - needs cluster/admin decisions confirmed first):" -ForegroundColor Yellow
Write-Host "  evoke configure master --accept-eula --hostname <cluster-dns> --master-altnames `"<leader-dns>,<standby1-dns>,<standby2-dns>`" --admin-password <password> <account>" -ForegroundColor Yellow
