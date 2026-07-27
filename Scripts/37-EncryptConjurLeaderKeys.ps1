<#
.SYNOPSIS
    Encrypt the Conjur Leader's server keys with a native master key
    (Installation deck Step 3 - Optional: Encrypt the server keys).
.DESCRIPTION
    UNTESTED - first validation run pending.

    Without this, the data key / UI key / SSL keys sit in plaintext under
    /opt/cyberark/conjur/security on the Leader (and inside every seed file
    generated for a Standby/Follower). Native key encryption wraps them with
    a separate master key generated here.

    Method: native (openssl-generated master key), not HSM/KMS - lab has no
    HSM/KMS to test against, and native is what CyberArk itself documents as
    the baseline method when neither is available.

    Steps (guest-ops over vmrun, same pattern as Scripts\30-36):
      1. Wait for guest-ops
      2. Generate the master key on the guest with `openssl rand 32`,
         directly inside the already-mounted security folder
         (/opt/cyberark/$ContainerName/security/master.key on the host =
         /opt/cyberark/conjur/security/master.key inside the container) -
         deliberately NOT the doc's /etc/dap-secrets path, since that isn't
         bind-mounted in this lab's container layout and would need a
         separate `podman cp` step for no benefit. Reusing the existing
         mount means the key persists on the host automatically and appears
         in the container without copying anything.
         Skipped if a master key already exists on the guest (idempotent -
         `evoke keys encrypt` should only ever run once; re-running it
         against already-encrypted keys is not something to do by accident).
      3. `evoke keys lock` immediately before generating/encrypting (first
         run only) - matches CyberArk's official "Server key encryption
         methods" doc exactly for this scenario (Leader, post
         evoke configure master). The Leader is running with keys actively
         unlocked at this point; locking first is documented as required,
         not optional, before `evoke keys encrypt`.
      4. `evoke keys encrypt <path>` - only on first run (see above)
      5. `evoke keys unlock <path>` - always run, even on repeat
         invocations. This is intentionally NOT idempotent-skipped: the
         unlock only lives in the running container's memory, not on disk,
         so it has to happen again after every container restart (including
         the reboot-survival systemd unit from Script 35 restarting it) or
         Conjur services will not start. See the checklist gotcha this adds
         about needing to re-run this after any restart.
      6. Pull a copy of the master key back to the Windows host into
         Config\ConjurSecrets\ (gitignored - never commit this file. This is
         the single artifact that decrypts the whole cluster's secrets).

    CyberArk's own guidance: "preferably store it offline in a safe and
    retrievable place." The host-side copy this script makes is a working
    copy for the lab, not a substitute for actually moving it somewhere
    offline (password manager, encrypted USB, etc.) for a real engagement.
.EXAMPLE
    .\37-EncryptConjurLeaderKeys.ps1
.NOTES
    Prerequisite: Leader container running and evoke-configured (Script 35 +
    evoke configure master). Run once per Leader - Standbys/Followers pick up
    the encrypted keys automatically through their seed files, they don't
    need this run against them separately.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath    = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$VMName        = "CONJUR-L01",
    [string]$ContainerName = "conjur",
    [string]$GuestUser     = "root",
    [string]$GuestPass     = "Cyberark1",
    [string]$BackupDir     = "$PSScriptRoot\..\Config\ConjurSecrets"
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
$candidates = @((Join-Path $vmFolder "$VMName\$VMName.vmx"), (Join-Path $vmFolder "$VMName.vmx"))
$vmx = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmx) { throw "VM not found: $VMName. Tried:`n  $($candidates -join "`n  ")" }

$keyPathGuest = "/opt/cyberark/$ContainerName/security/master.key"
$keyPathContainer = "/opt/cyberark/conjur/security/master.key"

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
# Generate + encrypt (first run only)
# ------------------------------------------------------------------
$existsCheck = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","test -f $keyPathGuest") -NoThrow
$alreadyEncrypted = ($existsCheck.ExitCode -eq 0)

if ($alreadyEncrypted) {
    Write-Host "  master key already exists on $VMName - skipping generation/encrypt (not re-run to avoid rotating keys by accident)" -ForegroundColor Yellow
} else {
    $marker = "/tmp/conjur_keyenc_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $encryptScript = @"
#!/bin/bash
set -e
# evoke configure master left the server keys unlocked/in active use -
# official doc's own Leader-encryption example locks them first, before
# generating the master key or encrypting. Skipping this was the original
# gap in this script.
podman exec $ContainerName evoke keys lock
openssl rand 32 > $keyPathGuest
chmod 600 $keyPathGuest
podman exec $ContainerName evoke keys encrypt $keyPathContainer
touch $marker
"@
    Invoke-GuestScriptChecked -ScriptText $encryptScript -Marker $marker -Label "Generate + encrypt master key" -TimeoutSec 120
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
    Write-Host "  [OK] master key generated + server keys encrypted" -ForegroundColor Green
}

# ------------------------------------------------------------------
# Unlock (always - required after every container start/restart)
# ------------------------------------------------------------------
$unlockMarker = "/tmp/conjur_keyunlock_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$unlockScript = @"
#!/bin/bash
set -e
podman exec $ContainerName evoke keys unlock $keyPathContainer
touch $unlockMarker
"@
Invoke-GuestScriptChecked -ScriptText $unlockScript -Marker $unlockMarker -Label "Unlock server keys" -TimeoutSec 60
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $unlockMarker") -NoThrow | Out-Null
Write-Host "  [OK] server keys unlocked" -ForegroundColor Green

# ------------------------------------------------------------------
# Pull a host-side backup copy (gitignored - Config\ConjurSecrets\)
# ------------------------------------------------------------------
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
$hostCopy = Join-Path $BackupDir "$VMName-master.key"
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "copyFileFromGuestToHost",$vmx,$keyPathGuest,$hostCopy) | Out-Null
Write-Host "  [OK] master key copied to $hostCopy (gitignored)" -ForegroundColor Green

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","curl -sk https://localhost/health > /tmp/conjur_health_out.txt 2>&1") -NoThrow | Out-Null
$healthFile = [System.IO.Path]::Combine($env:TEMP, "conjur_health_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "copyFileFromGuestToHost",$vmx,"/tmp/conjur_health_out.txt",$healthFile) | Out-Null
Write-Host "`nHealth check:" -ForegroundColor Cyan
Get-Content $healthFile | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Remove-Item $healthFile -Force -ErrorAction SilentlyContinue
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f /tmp/conjur_health_out.txt") -NoThrow | Out-Null

Write-Host "`nDone." -ForegroundColor Cyan
Write-Host "IMPORTANT: server keys must be unlocked again after every container/host restart -" -ForegroundColor Yellow
Write-Host "  re-run this script (it will skip the encrypt step and just unlock)." -ForegroundColor Yellow
Write-Host "IMPORTANT: $hostCopy is the only copy outside the VM. Move it somewhere truly offline" -ForegroundColor Yellow
Write-Host "  (password manager, encrypted USB) for anything beyond this lab - it decrypts everything." -ForegroundColor Yellow
