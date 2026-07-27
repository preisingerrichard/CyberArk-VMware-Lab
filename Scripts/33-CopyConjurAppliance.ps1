<#
.SYNOPSIS
    Copy the Conjur appliance tarball to the Conjur nodes (Installation
    deck, Step 4) and, optionally, load it into Podman. Also installs the
    Conjur CLI RPM on the node(s) that need interactive/admin access.
.DESCRIPTION
    UNTESTED - first validation run pending.

    The appliance archive is ~680MB - too large to push efficiently over the
    vmrun guest-ops channel used by the rest of the Conjur scripts (VIX file
    transfer through the VMX RPC channel is far slower than a network copy at
    that size). This script uses real SCP instead, matching the precedent
    already set by 13-InstallPSMP.ps1 for large Linux transfers:

      1. Bootstrap SSH trust (guest-ops, password auth - no network needed
         for this part): generate Config\conjur_lab_key if missing, push its
         public half into each node's /root/.ssh/authorized_keys (idempotent
         - skipped if already present), make sure sshd is enabled/running and
         firewalld allows port 22.
      2. Wait for SSH to answer, then scp.exe the tarball from the local
         Installers\Conjur\ media folder to /tmp on each node.
      3. Optionally (-Load) run `podman load -i` on the guest and verify with
         `podman images`, then remove the on-guest copy of the tarball to
         reclaim disk (these are 20GB dev-tier nodes; the ~680MB tarball plus
         the unpacked image adds up).
      4. For nodes in -CliVMNames (default: just the Leader - matching the
         Exercise Guide, where all CLI-driven policy/admin work happens from
         conjur1), also scp the Conjur CLI RPM and `rpm -Uvh` it, then verify
         with `conjur --version`. Skip entirely with -SkipCli.

    Default target set for the appliance itself is the five Conjur appliance
    nodes (Leader/Standbys/Followers) - CONJUR-APP01 is excluded, it never
    runs a Conjur container.
.EXAMPLE
    .\33-CopyConjurAppliance.ps1
    .\33-CopyConjurAppliance.ps1 -VMNames CONJUR-L01 -Load
    .\33-CopyConjurAppliance.ps1 -VMNames CONJUR-L01 -Load -CliVMNames CONJUR-L01,CONJUR-S01
.NOTES
    Prerequisite: Windows OpenSSH client (ssh.exe/scp.exe). The appliance
    tarball and CLI RPM must already be staged at Installers\Conjur\ (see
    Config\LabConfig.psd1 CyberArkMedia.ConjurFolder).
#>

[CmdletBinding()]
param(
    [string]  $ConfigPath   = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string[]]$VMNames      = @("CONJUR-L01","CONJUR-S01","CONJUR-S02","CONJUR-F01","CONJUR-F02"),
    [string]  $GuestUser    = "root",
    [string]  $GuestPass    = "Cyberark1",
    [string]  $ApplianceFile,                    # defaults to the single .tar/.tar.gz found in the media folder
    [string]  $RemoteDir    = "/tmp",
    [switch]  $Load,                              # also `podman load` + verify + clean up the tarball on the guest
    [string]  $CliFile,                           # defaults to the single conjur-cli*.rpm found in the media folder
    [string[]]$CliVMNames   = @("CONJUR-L01"),     # nodes that also get the Conjur CLI installed
    [switch]  $SkipCli
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "ssh.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe not found. Enable Windows Optional Feature 'OpenSSH Client' in Settings."
}

$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder  = $Config.VMware.DefaultVMFolder
$mediaBase = Join-Path $Config.CyberArkMedia.BasePath $Config.CyberArkMedia.ConjurFolder

if (-not $ApplianceFile) {
    $found = Get-ChildItem $mediaBase -Filter "conjur-appliance*.tar*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "No conjur-appliance*.tar* found under $mediaBase - stage the appliance media there first." }
    $ApplianceFile = $found.FullName
}
if (-not (Test-Path $ApplianceFile)) { throw "Appliance file not found: $ApplianceFile" }
$applianceName = Split-Path $ApplianceFile -Leaf
$applianceSizeMB = [math]::Round((Get-Item $ApplianceFile).Length / 1MB, 0)
Write-Host "Appliance media: $ApplianceFile ($applianceSizeMB MB)" -ForegroundColor Cyan

if (-not $SkipCli -and -not $CliFile) {
    $foundCli = Get-ChildItem $mediaBase -Filter "conjur-cli*.rpm" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundCli) { $CliFile = $foundCli.FullName }
    else { Write-Warning "No conjur-cli*.rpm found under $mediaBase - CLI install will be skipped."; $SkipCli = $true }
}
if (-not $SkipCli) {
    if (-not (Test-Path $CliFile)) { throw "CLI file not found: $CliFile" }
    $cliName = Split-Path $CliFile -Leaf
    Write-Host "CLI media: $CliFile" -ForegroundColor Cyan
}

# ---- lab SSH key (generate once, matches psmp_lab_key/pta_lab_key) ----
$labKeyPath = Join-Path $PSScriptRoot "..\Config\conjur_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\conjur_lab_key"
$labPubPath = "$labKeyPath.pub"
if (-not (Test-Path $labKeyPath)) {
    Write-Host "Generating $labKeyPath ..." -ForegroundColor Cyan
    & ssh-keygen -t ed25519 -f $labKeyPath -N "" -C "conjur-lab" -q
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
    # Windows OpenSSH refuses a private key readable by more than the owner
    # (ssh-keygen's own NTFS ACL isn't restrictive enough by default) - strip
    # inheritance and leave only the current user with read access.
    icacls $labKeyPath /inheritance:r | Out-Null
    icacls $labKeyPath /grant:r "${env:USERNAME}:(R)" | Out-Null
}
$pubKey = (Get-Content $labPubPath -Raw).Trim()

$sshOpts = @("-i", $labKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
             "-o", "BatchMode=yes", "-o", "ConnectTimeout=10")

function Resolve-NodeVMX {
    param([string]$Name)
    $candidates = @((Join-Path $vmFolder "$Name\$Name.vmx"), (Join-Path $vmFolder "$Name.vmx"))
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw "VM not found: $Name. Tried:`n  $($candidates -join "`n  ")" }
    return $found
}

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
    param([string]$Vmx, [string]$ScriptText, [string]$Marker, [string]$Label)
    $r = Invoke-LinuxGuestScript -VMXPath $Vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 120
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$Vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

function Wait-NodeSSH {
    param([string]$IP, [int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            if ($tcp.ConnectAsync($IP, 22).Wait(3000)) { $tcp.Close(); Start-Sleep 3; return }
            $tcp.Close()
        } catch {}
        Start-Sleep 5
    }
    throw "SSH on $IP did not become reachable within $TimeoutSeconds s"
}

$nodeSpecs = @{
    "CONJUR-L01" = "192.168.100.60"; "CONJUR-S01" = "192.168.100.61"; "CONJUR-S02" = "192.168.100.62"
    "CONJUR-F01" = "192.168.100.65"; "CONJUR-F02" = "192.168.100.66"
}

$results = @()
foreach ($name in $VMNames) {
    Write-Host "`n=== $name ===" -ForegroundColor Magenta
    $vmx = Resolve-NodeVMX -Name $name
    $ip  = $nodeSpecs[$name]
    if (-not $ip) { throw "No known IP for $name - add it to `$nodeSpecs or pass -VMNames with a known node." }

    Wait-GuestOps -Vmx $vmx
    Write-Host "  guest-ops ready" -ForegroundColor Green

    # ---- bootstrap SSH trust over guest-ops (password auth, one-time) ----
    $marker = "/tmp/conjur_sshboot_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $bootScript = @"
#!/bin/bash
set -e
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qxF '$pubKey' /root/.ssh/authorized_keys || echo '$pubKey' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
systemctl enable --now sshd >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
touch $marker
"@
    Invoke-GuestScriptChecked -Vmx $vmx -ScriptText $bootScript -Marker $marker -Label "SSH bootstrap on $name"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
    Write-Host "  SSH key trusted" -ForegroundColor Green

    Wait-NodeSSH -IP $ip
    Write-Host "  SSH reachable" -ForegroundColor Green

    # ---- scp the tarball ----
    $status = "FAILED"
    try {
        Write-Host "  copying $applianceName ($applianceSizeMB MB) -> ${RemoteDir}/ ..." -ForegroundColor DarkGray
        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & scp.exe @sshOpts $ApplianceFile "root@${ip}:${RemoteDir}/"
        $scpExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP
        if ($scpExit -ne 0) { throw "scp failed (exit $scpExit)" }
        Write-Host "  copied" -ForegroundColor Green
        $status = "COPIED"

        if ($Load) {
            $remotePath = "$RemoteDir/$applianceName"
            $loadOut = & ssh.exe @sshOpts "root@$ip" "podman load -i $remotePath && podman images --format '{{.Repository}}:{{.Tag}}' && rm -f $remotePath"
            $loadExit = $LASTEXITCODE
            if ($loadExit -ne 0) { throw "podman load failed (exit $loadExit): $loadOut" }
            Write-Host "  loaded into podman, tarball removed from guest:" -ForegroundColor Green
            $loadOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $status = "LOADED"
        }
    } catch {
        Write-Warning "  $($_.Exception.Message)"
    }

    # ---- Conjur CLI (only on nodes listed in -CliVMNames) ----
    $cliStatus = "SKIPPED"
    if (-not $SkipCli -and ($CliVMNames -contains $name)) {
        $cliStatus = "FAILED"
        try {
            Write-Host "  copying $cliName -> ${RemoteDir}/ ..." -ForegroundColor DarkGray
            $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & scp.exe @sshOpts $CliFile "root@${ip}:${RemoteDir}/"
            $scpExit = $LASTEXITCODE
            $ErrorActionPreference = $savedEAP
            if ($scpExit -ne 0) { throw "scp failed (exit $scpExit)" }

            # rpm -Uvh (upgrade-or-install) so a re-run on an already-installed
            # node is a no-op rather than an "already installed" failure
            $remoteCliPath = "$RemoteDir/$cliName"
            $installOut = & ssh.exe @sshOpts "root@$ip" "rpm -Uvh $remoteCliPath && conjur --version && rm -f $remoteCliPath"
            $installExit = $LASTEXITCODE
            if ($installExit -ne 0) { throw "CLI install failed (exit $installExit): $installOut" }
            Write-Host "  Conjur CLI installed: $installOut" -ForegroundColor Green
            $cliStatus = "OK"
        } catch {
            Write-Warning "  CLI: $($_.Exception.Message)"
        }
    }

    $results += [PSCustomObject]@{ Node = $name; IP = $ip; Status = $status; CLI = $cliStatus }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.Status -eq "FAILED" }) {
    throw "One or more nodes failed - see warnings above."
}
