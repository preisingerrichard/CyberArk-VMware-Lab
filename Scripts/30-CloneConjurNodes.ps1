<#
.SYNOPSIS
    Generalize the CONJUR-L01 base image (RHEL 9 "sysprep") - built either by
    Scripts\29-CreateConjurL01VM.ps1 or by hand - then clone it into the
    remaining Conjur nodes and personalize each one.
.DESCRIPTION
    UNTESTED - first validation run pending (smoke test: -Nodes CONJUR-S01).

    Four phases, all guest work over the vmrun guest-ops channel (open-vm-tools,
    no network dependency):

    A. Generalize CONJUR-L01 (once; skipped when the 'generalized' snapshot
       already exists). Runs the standard Linux template prep ON L01:
         subscription-manager unregister + clean, empty /etc/machine-id,
         remove SSH host keys, hostname -> localhost.localdomain, clear
         root bash history, poweroff. Then takes the powered-off snapshot
       'generalized'. The static-IP profile (.60) is deliberately kept -
       clones are re-addressed over guest-ops while L01 is powered off,
       so the transient duplicate never conflicts.

    B. Clone each node from the 'generalized' snapshot (full or linked -
       full clones also use the snapshot, so re-runs always clone the clean
       state even after L01 has been re-personalized). Per-node vCPU/RAM
       written into the .vmx while powered off; CONJUR-APP01's disk expanded
       to 40 GB (full clones only - linked deltas cannot be expanded).

    C. Personalize each clone: hostname + static IP via nmcli, APP01 root-FS
       grow (growpart or sfdisk fallback + LVM extend), reboot. machine-id and
       SSH host keys regenerate automatically on first boot from the emptied
       template state.

    D. Re-personalize L01: power it back on and restore its hostname
       (conjur-l01.<domain>). Its IP profile was never touched.

    Manual follow-up (not scriptable - RHSM credentials are yours):
      subscription-manager register on L01 AND every clone before installing
      Podman/Conjur.

    Nodes:
      CONJUR-S01   192.168.100.61  2 vCPU / 4 GB          Standby 1
      CONJUR-S02   192.168.100.62  2 vCPU / 4 GB          Standby 2
      CONJUR-F01   192.168.100.65  2 vCPU / 4 GB          Follower (GitLab)
      CONJUR-F02   192.168.100.66  2 vCPU / 4 GB          Follower (Kubernetes)
      CONJUR-APP01 192.168.100.70  4 vCPU / 6 GB / 40 GB  GitLab runner + k3s + LB

    There is no dedicated LB node - the leader/standby and follower pools are
    load-balanced by HAProxy running ON CONJUR-APP01 (see
    Scripts\31-ConfigureLoadBalancer.ps1 / the Deploy-Optional 'LoadBalancer'
    feature), not by a separate VM.
.EXAMPLE
    .\30-CloneConjurNodes.ps1                          # all six nodes, full clones
    .\30-CloneConjurNodes.ps1 -CloneType linked
    .\30-CloneConjurNodes.ps1 -Nodes CONJUR-S01        # smoke test, one node
.NOTES
    Prerequisites on CONJUR-L01: open-vm-tools running; root login with the
    password given in -GuestPass. Nothing else - generalization is automated.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath   = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$TemplateVMX,                       # defaults to <VMFolder>\CONJUR-L01\CONJUR-L01.vmx
    [ValidateSet("full","linked")]
    [string]$CloneType    = "full",
    [string]$SnapshotName = "generalized",      # powered-off snapshot; auto-created by Phase A
    [string[]]$Nodes,                           # subset of node names; default = all
    [string]$GuestUser    = "root",
    [string]$GuestPass    = "Cyberark1",        # template root password
    [string]$Domain       = "cyberark.lab",
    [string]$Nic          = "ens160",
    [switch]$LeaveTemplateOff                   # skip Phase D (don't boot L01 at the end)
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
$gateway  = $Config.Network.Gateway
$dns      = $Config.Network.DNS
if (-not $TemplateVMX) {
    # Hand-built VM may live in a per-VM subfolder or flat in the VM folder
    $candidates = @(
        (Join-Path $vmFolder "CONJUR-L01\CONJUR-L01.vmx"),
        (Join-Path $vmFolder "CONJUR-L01.vmx")
    )
    $TemplateVMX = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $TemplateVMX) { throw "Template not found. Tried:`n  $($candidates -join "`n  ")`nBuild CONJUR-L01 by hand first, or pass -TemplateVMX." }
}
if (-not (Test-Path $TemplateVMX)) { throw "Template not found: $TemplateVMX" }

$nodeSpecs = @(
    @{ Name = "CONJUR-S01";   IP = "192.168.100.61"; CPU = 2; RamMB = 4096 },
    @{ Name = "CONJUR-S02";   IP = "192.168.100.62"; CPU = 2; RamMB = 4096 },
    @{ Name = "CONJUR-F01";   IP = "192.168.100.65"; CPU = 2; RamMB = 4096 },
    @{ Name = "CONJUR-F02";   IP = "192.168.100.66"; CPU = 2; RamMB = 4096 },
    @{ Name = "CONJUR-APP01"; IP = "192.168.100.70"; CPU = 4; RamMB = 6144; DiskGB = 40 }
)
$targets = if ($Nodes) { $nodeSpecs | Where-Object { $Nodes -contains $_.Name } } else { $nodeSpecs }
if (-not $targets) { throw "No matching nodes. Valid names: $($nodeSpecs.Name -join ', ')" }

# ---- small vmrun helpers -----------------------------------------
function Wait-LinuxTools {
    # Probe guest-ops directly rather than checkToolsState: on some
    # open-vm-tools builds the reported tools state sticks at "installed"
    # even though the guest RPC channel (what runProgramInGuest/copyFile
    # actually use) is fully up - checkToolsState would then false-block
    # until TimeoutSec every single time.
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

function Test-VMRunning {
    param([string]$Vmx)
    $l = (Invoke-VMRun -Arguments @("list") -NoThrow).StdOut
    return [bool]($l -split "`n" | Where-Object { $_.Trim() -ieq $Vmx })
}

function Wait-VMOff {
    param([string]$Vmx, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        if (-not (Test-VMRunning -Vmx $Vmx)) { return }
    }
    throw "VM did not power off within $TimeoutSec s: $Vmx"
}

function Get-VMSnapshots {
    param([string]$Vmx)
    (Invoke-VMRun -Arguments @("listSnapshots", $Vmx) -NoThrow).StdOut -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^Total snapshots' }
}

function Invoke-GuestScriptChecked {
    # Invoke-LinuxGuestScript's wrapper always exits 0, so verify success via a
    # set -e marker file the script must create as its last statement.
    param([string]$Vmx, [string]$ScriptText, [string]$Marker, [string]$Label)
    $r = Invoke-LinuxGuestScript -VMXPath $Vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 600
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$Vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

# ==================================================================
# Phase A - generalize CONJUR-L01 (once; snapshot is the marker)
# ==================================================================
Write-Host "Template: $TemplateVMX  ($CloneType clone from snapshot '$SnapshotName')" -ForegroundColor Cyan

if ((Get-VMSnapshots -Vmx $TemplateVMX) -contains $SnapshotName) {
    Write-Host "Snapshot '$SnapshotName' exists - Phase A (generalize) skipped" -ForegroundColor DarkGray
    if (Test-VMRunning -Vmx $TemplateVMX) {
        Write-Host "CONJUR-L01 is running - soft shutdown (cloning needs it off)..." -ForegroundColor Yellow
        Stop-LabVM -VMXPath $TemplateVMX
        Wait-VMOff -Vmx $TemplateVMX
    }
} else {
    Write-Host "`n=== Phase A: generalize CONJUR-L01 (Linux sysprep) ===" -ForegroundColor Magenta
    if (-not (Test-VMRunning -Vmx $TemplateVMX)) {
        Start-LabVM -VMXPath $TemplateVMX -NoGUI | Out-Null
    }
    Wait-LinuxTools -Vmx $TemplateVMX

    $generalize = @'
#!/bin/bash
set -e
subscription-manager unregister || true
subscription-manager clean || true
rm -f /etc/machine-id && touch /etc/machine-id
rm -f /etc/ssh/ssh_host_*
hostnamectl set-hostname localhost.localdomain
truncate -s 0 /root/.bash_history
rm -f /tmp/generalize_ok && touch /tmp/generalize_ok
'@
    Invoke-GuestScriptChecked -Vmx $TemplateVMX -ScriptText $generalize `
        -Marker "/tmp/generalize_ok" -Label "Generalize CONJUR-L01"
    Write-Host "  generalized (subscription cleaned, machine-id emptied, SSH host keys removed)" -ForegroundColor Green

    # -noWait: the guest powers off underneath vmrun, so waiting for the
    # program's exit status would hang until the vmrun timeout
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$TemplateVMX,"-noWait","/bin/bash","-c","systemctl poweroff") -NoThrow | Out-Null
    Wait-VMOff -Vmx $TemplateVMX
    Write-Host "  powered off" -ForegroundColor Green

    New-LabVMSnapshot -VMXPath $TemplateVMX -SnapshotName $SnapshotName
    Write-Host "  snapshot '$SnapshotName' created" -ForegroundColor Green
}

# ==================================================================
# Phase B + C - clone from the generalized snapshot, personalize
# ==================================================================
foreach ($n in $targets) {
    $name = $n.Name; $ip = $n.IP; $fqdn = "$($name.ToLower()).$Domain"
    $destVmx = Join-Path $vmFolder "$name\$name.vmx"
    Write-Host "`n=== $name ($ip, $($n.CPU) vCPU / $($n.RamMB) MB) ===" -ForegroundColor Magenta

    # Clone + vmx tweaks + disk expand only when the clone doesn't exist yet.
    # Personalize always runs (idempotent) so an interrupted run can resume.
    $freshClone = -not (Test-Path $destVmx)
    if (-not $freshClone) {
        Write-Host "  exists - skipping clone (personalize will still run)" -ForegroundColor DarkGray
    } else {
    # Both full and linked clones come from the generalized snapshot
    New-LabVMFromTemplate -TemplateVMXPath $TemplateVMX -NewVMName $name `
        -CloneType $CloneType -SnapshotName $SnapshotName | Out-Null

    # Per-node hardware while powered off
    $vmx = Get-Content $destVmx -Raw
    $vmx = $vmx -replace '(?m)^memsize\s*=\s*".*"',  "memsize = `"$($n.RamMB)`""
    $vmx = $vmx -replace '(?m)^numvcpus\s*=\s*".*"', "numvcpus = `"$($n.CPU)`""
    if ($vmx -notmatch '(?m)^numvcpus') { $vmx += "`nnumvcpus = `"$($n.CPU)`"" }
    Set-Content -Path $destVmx -Value $vmx
    Write-Host "  vmx: memsize=$($n.RamMB) numvcpus=$($n.CPU)" -ForegroundColor Green
    }

    # Disk expansion (full clones only - linked deltas can't be expanded)
    $wantGrow = $false
    if ($freshClone -and $n.DiskGB) {
        if ($CloneType -eq "full") {
            $vdiskMgr = Join-Path (Split-Path $Config.VMware.VMRunPath) "vmware-vdiskmanager.exe"
            $vmdk = Get-ChildItem (Split-Path $destVmx) -Filter "*.vmdk" |
                    Where-Object { $_.Name -notmatch '-s\d{3}\.vmdk$' -and $_.Name -notmatch '-flat\.vmdk$' } |
                    Select-Object -First 1
            & $vdiskMgr -x "$($n.DiskGB)GB" $vmdk.FullName | Out-Null
            if ($LASTEXITCODE) { Write-Warning "  disk expand failed (exit $LASTEXITCODE) - continuing at template size" }
            else { Write-Host "  vmdk expanded to $($n.DiskGB) GB" -ForegroundColor Green; $wantGrow = $true }
        } else {
            Write-Warning "  $name wants $($n.DiskGB) GB but linked clones can't be expanded - staying at template size"
        }
    }

    if (-not (Test-VMRunning -Vmx $destVmx)) { Start-LabVM -VMXPath $destVmx -NoGUI | Out-Null }
    Wait-LinuxTools -Vmx $destVmx
    Write-Host "  booted, tools up (fresh machine-id + SSH host keys regenerated on boot)" -ForegroundColor Green

    # Root-FS grow for the expanded vmdk (default RHEL LVM layout).
    # growpart when available; sfdisk (util-linux, always present) as fallback -
    # RHSM is unregistered on clones, so dnf-installing cloud-utils-growpart is
    # not an option here. Every step || true so a re-run on an already-grown
    # disk is harmless.
    $growBlock = if ($wantGrow) { @'
src=$(findmnt -no SOURCE /)
case "$src" in
  /dev/mapper/*) part=$(pvs --noheadings -o pv_name | head -1 | tr -d ' ') ;;
  *)             part=$src ;;
esac
disk=/dev/$(lsblk -ndo PKNAME "$part")
pnum=$(cat /sys/class/block/$(basename "$part")/partition)
if command -v growpart >/dev/null 2>&1; then
  growpart "$disk" "$pnum" || true
else
  echo ", +" | sfdisk -N "$pnum" --force --no-reread "$disk" || true
  partprobe "$disk" || true
fi
case "$src" in
  /dev/mapper/*) pvresize "$part" || true; lvextend -r -l +100%FREE "$src" || true ;;
  *)             xfs_growfs / || resize2fs "$src" || true ;;
esac
'@ } else { "" }

    # Personalize over guest-ops (no network needed - safe while the clone
    # still transiently holds L01's .60 address; L01 is powered off).
    $personalize = @"
#!/bin/bash
set -e
hostnamectl set-hostname $fqdn
CON=`$(nmcli -g GENERAL.CONNECTION device show $Nic 2>/dev/null | head -1)
[ -n "`$CON" ] || CON=$Nic
nmcli con mod "`$CON" ipv4.method manual ipv4.addresses $ip/24 ipv4.gateway $gateway ipv4.dns $dns
nmcli con up "`$CON" || true
$growBlock
rm -f /tmp/conjur_reconfig_ok && touch /tmp/conjur_reconfig_ok
"@
    Invoke-GuestScriptChecked -Vmx $destVmx -ScriptText $personalize `
        -Marker "/tmp/conjur_reconfig_ok" -Label "Personalize $name"

    # Reboot so hostname/IP settle cleanly. -noWait: guest reboots underneath
    # vmrun, so waiting for the program's exit status would hang
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$destVmx,"-noWait","/bin/bash","-c","systemctl reboot") -NoThrow | Out-Null
    Write-Host "  personalized -> $fqdn @ $ip (rebooting)" -ForegroundColor Green
}

# ==================================================================
# Phase D - re-personalize CONJUR-L01 (idempotent)
# ==================================================================
if (-not $LeaveTemplateOff) {
    Write-Host "`n=== Phase D: restore CONJUR-L01 identity ===" -ForegroundColor Magenta
    if (-not (Test-VMRunning -Vmx $TemplateVMX)) {
        Start-LabVM -VMXPath $TemplateVMX -NoGUI | Out-Null
    }
    Wait-LinuxTools -Vmx $TemplateVMX
    $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$TemplateVMX,"/bin/bash","-c","hostnamectl set-hostname conjur-l01.$Domain") -NoThrow
    if ($r.ExitCode -ne 0) { throw "Restoring L01 hostname failed: $($r.StdErr) $($r.StdOut)" }
    Write-Host "  CONJUR-L01 back up as conjur-l01.$Domain @ 192.168.100.60 (IP profile was never changed)" -ForegroundColor Green
}

Write-Host "`nDone." -ForegroundColor Cyan
Write-Host "  - Clones are rebooting in the background; give them ~1 min." -ForegroundColor Gray
Write-Host "  - MANUAL STEP: subscription-manager register on CONJUR-L01 AND every clone" -ForegroundColor Yellow
Write-Host "    (generalization unregistered the template) before installing Podman/Conjur." -ForegroundColor Yellow
if ($LeaveTemplateOff) {
    Write-Host "  - CONJUR-L01 left powered OFF (-LeaveTemplateOff). Its hostname is still localhost.localdomain;" -ForegroundColor Yellow
    Write-Host "    re-run without -LeaveTemplateOff (clones are skipped) or set the hostname manually." -ForegroundColor Yellow
}
