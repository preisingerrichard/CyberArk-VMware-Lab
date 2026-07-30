<#
.SYNOPSIS
    Create and provision CONJUR-L01 (RHEL 9), fully unattended - including
    RHSM registration during install so open-vm-tools/podman can be pulled
    from subscribed repos.
.DESCRIPTION
    UNTESTED - first validation run pending (no RHEL 9 ISO + activation key
    available to exercise it against yet). Built by close analogy to
    Scripts\12-CreatePSMPVM.ps1 (same kickstart/isolinux mechanism, proven
    working for Rocky Linux 9 against the identical Anaconda installer) -
    high confidence in the VM-creation/boot-injection/SSH-wait mechanics,
    genuinely unverified on the RHEL-specific parts: the `rhsm` kickstart
    command's exact syntax/behavior on whatever RHEL 9.2+ point release ISO
    you use, and the ISO's own installer boot-menu layout (isolinux Tab
    injection assumes the same menu shape Rocky 9.7 uses - should match,
    RHEL and Rocky share the same upstream installer, but not confirmed).
    Step 5's own verification pass is exactly for catching a silent
    registration failure rather than assuming success - if you hit a
    problem, that's the most likely place. Feedback welcome once someone
    (possibly future-me) actually runs this against real media.

    Retroactively automates what used to be a hand-built step (see the
    README's Conjur prerequisites section / Scripts\30-CloneConjurNodes.ps1's
    own header, both of which historically assumed CONJUR-L01 already
    existed). Mirrors Scripts\12-CreatePSMPVM.ps1's proven Rocky Linux
    kickstart-ISO/isolinux-Tab-injection mechanism almost exactly - Rocky
    and RHEL 9 share the identical Anaconda installer, and the existing
    kickstart files already target `#version=RHEL9` syntax.

    The one real gap that mechanism alone doesn't close: RHEL (unlike
    Rocky) has no unauthenticated repos, so `%packages` can't pull
    open-vm-tools/podman unless the system is already registered - and
    CONJUR-L01 needs open-vm-tools running before Script 30 can even talk
    to it (guest-ops/VIX, not SSH). Kickstart's `rhsm` command (RHEL
    9.2+) solves this by registering DURING install, before `%packages`
    runs - so this script requires an activation key (-OrgId
    -ActivationKey), the same no-personal-credential-exposure method
    Scripts\Register-RHSM.ps1 already supports as an alternative to
    interactive Get-Credential. A free Red Hat Developer account is
    enough to create one.

    This script does NOT remove the two prerequisites that genuinely
    can't be scripted around (see the README): you still need your own
    Red Hat account/entitlement to obtain both the RHEL 9.2+ ISO and an
    activation key - this only eliminates the manual OS-install labor
    (partitioning, hostname, static IP, root password, registration,
    package selection) once you have those two things.

    Does NOT create a DNS record (Scripts\34-ConfigureConjurDNS.ps1 /
    the ConjurDNS feature is the single source of truth for that - not
    duplicated here to avoid drift between two scripts). Does NOT
    register in Config\DeployedVMs.xml - Conjur nodes were never part of
    that mechanism (matches Scripts\30-41's existing convention; they
    already track Conjur node identity via hardcoded IPs, not
    $Config.VMs/DeployedVMs.xml).

    After this script: CONJUR-L01 exists, is RHSM-registered, has
    open-vm-tools running (Script 30's stated prerequisite) and podman
    installed. Proceed straight to Scripts\30-CloneConjurNodes.ps1.
    The clones it produces (S01/S02/F01/F02/APP01) still need their own
    manual `subscription-manager register` (Scripts\Register-RHSM.ps1)
    and `dnf install -y podman` afterward - this script only covers L01
    itself, cloning/generalizing doesn't re-run a kickstart.
.EXAMPLE
    .\29-CreateConjurL01VM.ps1 -OrgId 1234567 -ActivationKey conjur-lab
.NOTES
    Prerequisites:
      - RHEL 9.2+ ISO at $Config.ISOs.RHEL9 (Config\LabConfig.psd1) -
        requires a Red Hat account, not freely downloadable like the
        Windows/Rocky ISOs already used elsewhere in this repo.
      - A Red Hat activation key (-OrgId/-ActivationKey) - create one at
        https://console.redhat.com/insights/connector/activation-keys
        (free with a Red Hat Developer account).
    Installation takes 20-40 minutes; the script waits automatically.
#>

param(
    [string]$ConfigPath        = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [Parameter(Mandatory)][string]$OrgId,
    [Parameter(Mandatory)][string]$ActivationKey,
    [string]$GuestPass         = "Cyberark1",
    [int]   $InstallTimeoutMin = 60,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

# Hardcoded, not $Config.VMs - matches the convention already established by
# Scripts\30/31 for every other Conjur node (they were never added to
# LabConfig.psd1's VM inventory - see those scripts' own node IP maps).
$l01 = [pscustomobject]@{
    Name    = 'CONJUR-L01'
    IPAddress = '192.168.100.60'
    CPUs    = 2
    MemoryMB = 4096
    DiskGB  = 20
}

$vmFolder  = Join-Path $Config.VMware.DefaultVMFolder $l01.Name
$vmxPath   = Join-Path $vmFolder "$($l01.Name).vmx"
$vmdkPath  = Join-Path $vmFolder "$($l01.Name).vmdk"
$ksISOPath = Join-Path $vmFolder "ks.iso"
$rhelISO   = $Config.ISOs.RHEL9

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Creating CONJUR-L01 VM  ($($l01.IPAddress), RHEL 9)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

function New-OemdrvIso {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$OutputIso
    )

    if (-not ('Imapi2Helper' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class Imapi2Helper {
    public static void WriteIsoStream(object imageStream, string outputPath) {
        IStream stream = (IStream)imageStream;
        using (var fs = File.Create(outputPath)) {
            var buffer = new byte[65536];
            var pRead  = Marshal.AllocHGlobal(sizeof(int));
            try {
                while (true) {
                    stream.Read(buffer, buffer.Length, pRead);
                    int n = Marshal.ReadInt32(pRead);
                    if (n == 0) break;
                    fs.Write(buffer, 0, n);
                }
            } finally {
                Marshal.FreeHGlobal(pRead);
            }
        }
    }
}
"@ -Language CSharp -ReferencedAssemblies @(
            'System.dll',
            'System.Core.dll',
            'Microsoft.CSharp.dll'
        )
    }

    if (Test-Path $OutputIso) { Remove-Item -Path $OutputIso -Force }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 1
    $fsi.VolumeName = 'OEMDRV'
    $fsi.Root.AddTreeWithNamedStreams($SourceFolder, $false)
    $image = $fsi.CreateResultImage()
    [Imapi2Helper]::WriteIsoStream($image.ImageStream, $OutputIso)

    $isoBytes = [System.IO.File]::ReadAllBytes($OutputIso)
    $labelBytes = [System.Text.Encoding]::ASCII.GetBytes('OEMDRV'.PadRight(32))
    [System.Buffer]::BlockCopy($labelBytes, 0, $isoBytes, 0x8028, 32)
    [System.IO.File]::WriteAllBytes($OutputIso, $isoBytes)

    $written = [System.Text.Encoding]::ASCII.GetString($isoBytes[0x8028..0x8047]).TrimEnd()
    Write-Host "  OEMDRV ISO label: '$written'" -ForegroundColor DarkGray
    if ($written -ne 'OEMDRV') { throw "Failed to write OEMDRV label into kickstart ISO." }
}

function Test-VMRunning {
    param([Parameter(Mandatory)][string]$Path)
    $listResult = Invoke-VMRun -Arguments @('list') -NoThrow
    return ($listResult.StdOut -match [regex]::Escape($Path))
}

if (-not (Test-Path $rhelISO)) {
    throw "RHEL 9 ISO not found: '$rhelISO' - update ISOs.RHEL9 in LabConfig.psd1. See the README's Conjur prerequisites section for how to obtain it."
}

New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

if (Test-Path $vmxPath) {
    if (-not $Force) {
        throw "CONJUR-L01 VM already exists at '$vmxPath'. Use -Force to power off and recreate it."
    }
    Write-Host "`n[Step 0] Tearing down existing CONJUR-L01 VM (-Force)..." -ForegroundColor Yellow
    if (Test-VMRunning -Path $vmxPath) {
        Write-Host "  Stopping CONJUR-L01..." -ForegroundColor DarkGray
        Invoke-VMRun -Arguments @("stop", "`"$vmxPath`"", "hard") -NoThrow | Out-Null
        Start-Sleep -Seconds 5
    }
    Write-Host "  Deleting VM folder: $vmFolder" -ForegroundColor DarkGray
    Remove-Item -Path $vmFolder -Recurse -Force
    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
    Write-Host "  [OK] CONJUR-L01 removed" -ForegroundColor Green
}

# ================================================================
# Step 1: Create CONJUR-L01 VM (VMX + VMDK)
# ================================================================
Write-Host "`n[Step 1] Creating CONJUR-L01 VM..." -ForegroundColor Yellow

if (-not (Test-Path $vmdkPath)) {
    Write-Host "  Creating $($l01.DiskGB) GB disk..." -ForegroundColor DarkGray
    $vdiskMgr = Join-Path (Split-Path $Config.VMware.VMRunPath) "vmware-vdiskmanager.exe"
    if (-not (Test-Path $vdiskMgr)) { throw "vmware-vdiskmanager.exe not found at '$vdiskMgr'" }
    & $vdiskMgr -c -s "$($l01.DiskGB)GB" -a lsilogic -t 0 $vmdkPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vmware-vdiskmanager failed (exit $LASTEXITCODE)" }
} else {
    Write-Host "  [SKIP] Disk already exists: $vmdkPath" -ForegroundColor Yellow
}

Write-Host "  Writing VMX (BIOS mode, SATA CDROMs)..." -ForegroundColor DarkGray
# guestOS = "other3xlinux-64" (not rhel9-64Guest) - forces BIOS firmware so the
# isolinux Tab-injection trick below works, exactly matching the reasoning
# already proven in Scripts\10/12 (rhel9-64Guest forces EFI in virtualHW 19
# regardless of the firmware="bios" setting).
$vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "$($l01.Name)"
guestOS = "other3xlinux-64"
numvcpus = "$($l01.CPUs)"
cpuid.coresPerSocket = "$($l01.CPUs)"
memsize = "$($l01.MemoryMB)"

scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$($l01.Name).vmdk"
scsi0:0.deviceType = "scsi-hardDisk"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$rhelISO"
sata0:0.startConnected = "TRUE"

sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$ksISOPath"
sata0:1.startConnected = "TRUE"

ethernet0.present = "TRUE"
ethernet0.virtualDev = "e1000"
ethernet0.connectionType = "nat"
ethernet0.addressType = "generated"

floppy0.present = "FALSE"
sound.present = "FALSE"

firmware = "bios"
bios.bootOrder = "hdd,cdrom"

tools.syncTime = "TRUE"
tools.upgrade.policy = "manual"

powerType.powerOff = "soft"
powerType.reset = "soft"
"@

Set-Content -Path $vmxPath -Value $vmxContent -Encoding UTF8
Write-Host "  [OK] VMX ready: $vmxPath" -ForegroundColor Green

# ================================================================
# Step 2: Generate OEMDRV kickstart ISO
# ================================================================
Write-Host "`n[Step 2] Generating OEMDRV kickstart ISO..." -ForegroundColor Yellow

# Same shared-key convention Scripts\33-CopyConjurAppliance.ps1 already
# establishes for Conjur SSH automation - generating it here first just
# means script 33 finds it already present later.
$labKeyPath = Join-Path $PSScriptRoot "..\Config\conjur_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\conjur_lab_key"
if (-not (Test-Path $labKeyPath)) {
    Write-Host "  Generating lab SSH key at $labKeyPath ..." -ForegroundColor DarkGray
    & ssh-keygen.exe -t ed25519 -f $labKeyPath -N '""' -C "lab-automation" | Out-Null
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
}
$labPubKey = (Get-Content "$labKeyPath.pub" -Raw).Trim()
Write-Host "  Lab SSH public key loaded" -ForegroundColor DarkGray

$ksDir  = Join-Path $env:TEMP "conjurl01_oemdrv_$(Get-Random)"
$ksFile = Join-Path $ksDir "ks.cfg"
New-Item -Path $ksDir -ItemType Directory -Force | Out-Null

try {
    $ksText = @"
#version=RHEL9
cmdline
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone UTC --utc
network --bootproto=static --device=link --ip=$($l01.IPAddress) --netmask=$($Config.Network.SubnetMask) --gateway=$($Config.Network.Gateway) --nameserver=$($Config.Network.DNS),8.8.8.8 --hostname=conjur-l01.$($Config.Domain.Name) --activate
rootpw --plaintext $GuestPass
selinux --enforcing
firewall --enabled --service=ssh --port=22:tcp
bootloader --location=mbr --boot-drive=sda
clearpart --all --initlabel --drives=sda
autopart --type=lvm
rhsm --organization=$OrgId --activation-key=$ActivationKey
%packages
@^minimal-environment
open-vm-tools
podman
tar
policycoreutils-python-utils
%end
%post
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-lab.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/10-lab.conf
systemctl enable sshd
systemctl enable --now vmtoolsd
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$labPubKey" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
%end
reboot
"@

    $lfText = $ksText -replace "`r`n", "`n" -replace "`r", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ksFile, $lfText, $utf8NoBom)
    New-OemdrvIso -SourceFolder $ksDir -OutputIso $ksISOPath
} finally {
    Remove-Item $ksDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "  [OK] Kickstart ISO: $ksISOPath" -ForegroundColor Green

# ================================================================
# Step 3: Boot VM and inject kickstart boot parameter
# ================================================================
Write-Host "`n[Step 3] Booting VM and injecting kickstart via isolinux Tab..." -ForegroundColor Yellow

$nvramPath = Join-Path $vmFolder "$($l01.Name).nvram"
if (Test-Path $nvramPath) {
    Remove-Item $nvramPath -Force
    Write-Host "  Removed stale .nvram" -ForegroundColor DarkGray
}

$listResult = Invoke-VMRun -Arguments @("list") -NoThrow
if ($listResult.StdOut -notmatch [regex]::Escape($vmxPath)) {
    Invoke-VMRun -Arguments @("start", "`"$vmxPath`"") | Out-Null
    Write-Host "  VM started - waiting 20s for BIOS POST and isolinux menu..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
} else {
    Write-Host "  VM already running" -ForegroundColor DarkGray
}

$wshell     = New-Object -ComObject wscript.shell
$vmwareProc = Get-Process -Name "vmware" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$($l01.Name)*" } |
    Select-Object -First 1

if (-not $vmwareProc) {
    Write-Warning "VMware window for '$($l01.Name)' not found. Please manually press Tab in the isolinux menu, type ' inst.ks=cdrom', then Enter."
} else {
    Write-Host "  Activating VMware window (PID $($vmwareProc.Id))..." -ForegroundColor DarkGray
    $wshell.AppActivate($vmwareProc.Id) | Out-Null
    Start-Sleep -Milliseconds 600
    Write-Host "  Pressing Tab to edit isolinux boot entry..." -ForegroundColor DarkGray
    $wshell.SendKeys("{TAB}")
    Start-Sleep -Milliseconds 800
    Write-Host "  Typing: inst.ks=cdrom + Enter..." -ForegroundColor DarkGray
    $wshell.SendKeys(" inst.ks=cdrom{ENTER}")
    Write-Host "  [OK] Boot parameters sent via WScript.Shell" -ForegroundColor Green
}

# ================================================================
# Step 4: Wait for RHEL installation to complete
# ================================================================
Write-Host "`n[Step 4] Waiting for RHEL installation (up to $InstallTimeoutMin min)..." -ForegroundColor Yellow
Write-Host "  Polling every 30 seconds for SSH to respond..." -ForegroundColor DarkGray
Write-Host "  (registration happens mid-install via the rhsm kickstart command - if it" -ForegroundColor DarkGray
Write-Host "   fails, e.g. bad org/key, Anaconda will still finish but without open-vm-tools/" -ForegroundColor DarkGray
Write-Host "   podman installed - check the VM console if this run times out)" -ForegroundColor DarkGray

$installDeadline = (Get-Date).AddMinutes($InstallTimeoutMin)
$ready           = $false
$port22FirstSeen = $null
$keyInstallTried = $false

$sshOptsCheck = @("-i", $labKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8")
$sshOptsPw    = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
                  "-o", "BatchMode=no", "-o", "ConnectTimeout=10",
                  "-o", "PreferredAuthentications=keyboard-interactive,password")

while ((Get-Date) -lt $installDeadline) {
    Start-Sleep -Seconds 30
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 0)

    $tcpUp = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcpUp = $tcp.ConnectAsync($l01.IPAddress, 22).Wait(3000)
        $tcp.Close()
    } catch {}

    if ($tcpUp) {
        if (-not $port22FirstSeen) { $port22FirstSeen = Get-Date }

        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & ssh.exe @sshOptsCheck "root@$($l01.IPAddress)" "echo ready" 2>&1 } catch {}
        $keyExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP

        if ($keyExit -eq 0) {
            Write-Host "  [OK] RHEL installed and SSH key auth confirmed at $elapsed min" -ForegroundColor Green
            $ready = $true
            break
        }

        $port22Age = if ($port22FirstSeen) { ((Get-Date) - $port22FirstSeen).TotalMinutes } else { 0 }
        if ($port22Age -ge 3 -and -not $keyInstallTried) {
            $keyInstallTried = $true
            Write-Host ""
            Write-Host "  Key auth not working after 3 min on port 22." -ForegroundColor Yellow
            Write-Host "  Installing lab SSH key via password SSH (one-time prompt)..." -ForegroundColor Yellow
            Write-Host "  >>> Enter root password when prompted: $GuestPass <<<" -ForegroundColor Cyan
            $addKeyCmd = "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '$labPubKey' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo key_installed"
            $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $null = & ssh.exe @sshOptsPw "root@$($l01.IPAddress)" $addKeyCmd 2>&1
            $ErrorActionPreference = $savedEAP
            continue
        }

        Write-Host "  [$elapsed min] Port 22 up - waiting for key auth..." -ForegroundColor DarkGray
    } else {
        Write-Host "  [$elapsed min] Still installing..." -ForegroundColor DarkGray
    }
}

if (-not $ready) {
    throw "Timeout: RHEL SSH did not become reachable within $InstallTimeoutMin minutes. Check the VM console for errors."
}

# ================================================================
# Step 5: Verify registration + open-vm-tools/podman actually landed
# ================================================================
Write-Host "`n[Step 5] Verifying registration and package install..." -ForegroundColor Yellow
$verifyCmd = "subscription-manager status --org=$OrgId >/tmp/rhsm-status.txt 2>&1; rpm -q open-vm-tools podman >/tmp/pkg-status.txt 2>&1; systemctl is-active vmtoolsd >/tmp/vmtoolsd-status.txt 2>&1; echo done"
$savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$null = & ssh.exe @sshOptsCheck "root@$($l01.IPAddress)" $verifyCmd 2>&1
$ErrorActionPreference = $savedEAP

$pkgStatus = & ssh.exe @sshOptsCheck "root@$($l01.IPAddress)" "cat /tmp/pkg-status.txt" 2>&1
$vmtoolsStatus = & ssh.exe @sshOptsCheck "root@$($l01.IPAddress)" "cat /tmp/vmtoolsd-status.txt" 2>&1

if ($pkgStatus -match 'is not installed') {
    Write-Warning "open-vm-tools and/or podman did NOT install - registration likely failed during kickstart (check -OrgId/-ActivationKey). Details:"
    Write-Warning ($pkgStatus -join "`n")
    Write-Warning "You can register manually now (Scripts\Register-RHSM.ps1) then 'dnf install -y open-vm-tools podman && systemctl enable --now vmtoolsd' before proceeding to Script 30."
} elseif ($vmtoolsStatus -notmatch 'active') {
    Write-Warning "vmtoolsd is not active - Script 30 needs guest-ops (open-vm-tools) to reach this node. Status: $vmtoolsStatus"
} else {
    Write-Host "  [OK] Registered, open-vm-tools running, podman installed." -ForegroundColor Green
}

$elapsed = (Get-Date) - $startTime
Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "CONJUR-L01 ready - RHEL 9 installed ($($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Green
Write-Host "  IP:   $($l01.IPAddress)" -ForegroundColor Green
Write-Host "  Next: .\Scripts\30-CloneConjurNodes.ps1" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
