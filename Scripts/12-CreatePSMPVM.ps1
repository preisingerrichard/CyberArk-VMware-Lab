<#
.SYNOPSIS
    Create and provision the PSMP01 Rocky Linux 9 virtual machine.
.DESCRIPTION
    1. Creates PSMP01 VM (VMX + VMDK) in VMware Workstation using BIOS firmware
    2. Creates a kickstart ISO (ks.cfg) attached as sata0:1
    3. Boots via BIOS/isolinux; injects inst.ks=cdrom by pressing Tab in the
       isolinux menu via WScript.Shell. Anaconda finds ks.cfg on the kickstart
       CDROM (sata0:1) and installs Rocky Linux fully unattended.
    4. Waits for SSH key auth, then registers PSMP01 in DeployedVMs.xml

    Uses guestOS = "other3xlinux-64" to ensure BIOS mode. rhel9-64Guest forces
    EFI in VMware virtualHW 19 regardless of the firmware = "bios" VMX setting.

    Generates a dedicated SSH key for PSMP01 at Config\psmp_lab_key.

    Run this before 13-InstallPSMP.ps1.
    Installation takes 20-35 minutes; the script waits automatically.
#>

param(
    [string]$ConfigPath        = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [int]   $InstallTimeoutMin = 60,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$psmpVM = $Config.VMs | Where-Object { $_.Role -eq 'PSMP' -or $_.Role -contains 'PSMP' } | Select-Object -First 1
if (-not $psmpVM) { throw "No VM with Role 'PSMP' found in LabConfig.psd1" }

$vmFolder  = Join-Path $Config.VMware.DefaultVMFolder $psmpVM.Name
$vmxPath   = Join-Path $vmFolder "$($psmpVM.Name).vmx"
$vmdkPath  = Join-Path $vmFolder "$($psmpVM.Name).vmdk"
$ksISOPath = Join-Path $vmFolder "ks.iso"
$rockyISO  = $Config.ISOs.RockyLinux

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Creating PSMP01 VM  ($($psmpVM.IPAddress), Rocky Linux 9)" -ForegroundColor Cyan
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

if (-not (Test-Path $rockyISO)) {
    throw "Rocky Linux ISO not found: '$rockyISO' - update ISOs.RockyLinux in LabConfig.psd1"
}

New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

if (Test-Path $vmxPath) {
    if (-not $Force) {
        throw "PSMP01 VM already exists at '$vmxPath'. Use -Force to power off and recreate it."
    }
    Write-Host "`n[Step 0] Tearing down existing PSMP01 VM (-Force)..." -ForegroundColor Yellow
    if (Test-VMRunning -Path $vmxPath) {
        Write-Host "  Stopping PSMP01..." -ForegroundColor DarkGray
        Invoke-VMRun -Arguments @("stop", "`"$vmxPath`"", "hard") -NoThrow | Out-Null
        Start-Sleep -Seconds 5
    }
    Write-Host "  Deleting VM folder: $vmFolder" -ForegroundColor DarkGray
    Remove-Item -Path $vmFolder -Recurse -Force
    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
    Write-Host "  [OK] PSMP01 removed" -ForegroundColor Green
}

# ================================================================
# Step 1: Create PSMP01 VM (VMX + VMDK)
# ================================================================
Write-Host "`n[Step 1] Creating PSMP01 VM..." -ForegroundColor Yellow

if (-not (Test-Path $vmdkPath)) {
    Write-Host "  Creating $($psmpVM.DiskGB) GB disk..." -ForegroundColor DarkGray
    $vdiskMgr = Join-Path (Split-Path $Config.VMware.VMRunPath) "vmware-vdiskmanager.exe"
    if (-not (Test-Path $vdiskMgr)) { throw "vmware-vdiskmanager.exe not found at '$vdiskMgr'" }
    & $vdiskMgr -c -s "$($psmpVM.DiskGB)GB" -a lsilogic -t 0 $vmdkPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vmware-vdiskmanager failed (exit $LASTEXITCODE)" }
} else {
    Write-Host "  [SKIP] Disk already exists: $vmdkPath" -ForegroundColor Yellow
}

Write-Host "  Writing VMX (BIOS mode, SATA CDROMs)..." -ForegroundColor DarkGray
$vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "$($psmpVM.Name)"
guestOS = "other3xlinux-64"
numvcpus = "$($psmpVM.CPUs)"
cpuid.coresPerSocket = "$($psmpVM.CPUs)"
memsize = "$($psmpVM.MemoryMB)"

scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$($psmpVM.Name).vmdk"
scsi0:0.deviceType = "scsi-hardDisk"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$rockyISO"
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

# Reuse the shared lab SSH key (same key used by 11-InstallPTA.ps1 and 13-InstallPSMP.ps1).
# Generated on first PTA/PSMP run; persists in Config\ for all Linux VM automation.
$labKeyPath = Join-Path $PSScriptRoot "..\Config\psmp_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\psmp_lab_key"
if (-not (Test-Path $labKeyPath)) {
    Write-Host "  Generating lab SSH key at $labKeyPath ..." -ForegroundColor DarkGray
    & ssh-keygen.exe -t ed25519 -f $labKeyPath -N '""' -C "lab-automation" | Out-Null
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
}
$labPubKey = (Get-Content "$labKeyPath.pub" -Raw).Trim()
Write-Host "  Lab SSH public key loaded" -ForegroundColor DarkGray

$ksDir  = Join-Path $env:TEMP "psmp_oemdrv_$(Get-Random)"
$ksFile = Join-Path $ksDir "ks.cfg"
New-Item -Path $ksDir -ItemType Directory -Force | Out-Null

try {
    $ksText = @"
#version=RHEL9
cmdline
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone UTC --utc
network --bootproto=static --device=link --ip=$($psmpVM.IPAddress) --netmask=$($Config.Network.SubnetMask) --gateway=$($Config.Network.Gateway) --nameserver=$($Config.Network.DNS),8.8.8.8 --hostname=psmp01.$($Config.Domain.Name) --activate
rootpw --plaintext $($Config.LocalAdmin.Password)
selinux --permissive
firewall --enabled --service=ssh --port=22:tcp
bootloader --location=mbr --boot-drive=sda
clearpart --all --initlabel --drives=sda
autopart --type=lvm
%packages
@^minimal-environment
tar
unzip
glibc-common
logrotate
iproute
policycoreutils-python-utils
sssd
sssd-ad
sssd-krb5
realmd
samba-common-tools
openssl
%end
%post
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-lab.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/10-lab.conf
systemctl enable sshd
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$labPubKey" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
dnf install -y adcli krb5-workstation oddjob oddjob-mkhomedir sssd-tools 2>/tmp/dnf-post.log || true
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

$nvramPath = Join-Path $vmFolder "$($psmpVM.Name).nvram"
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
    Where-Object { $_.MainWindowTitle -like "*$($psmpVM.Name)*" } |
    Select-Object -First 1

if (-not $vmwareProc) {
    Write-Warning "VMware window for '$($psmpVM.Name)' not found. Please manually press Tab in the isolinux menu, type ' inst.ks=cdrom', then Enter."
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
# Step 4: Wait for Rocky Linux installation to complete
# ================================================================
Write-Host "`n[Step 4] Waiting for Rocky Linux installation (up to $InstallTimeoutMin min)..." -ForegroundColor Yellow
Write-Host "  Polling every 30 seconds for SSH to respond..." -ForegroundColor DarkGray

$installDeadline = (Get-Date).AddMinutes($InstallTimeoutMin)
$ready           = $false
$port22FirstSeen = $null
$keyInstallTried = $false

$rootPass     = $Config.LocalAdmin.Password
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
        $tcpUp = $tcp.ConnectAsync($psmpVM.IPAddress, 22).Wait(3000)
        $tcp.Close()
    } catch {}

    if ($tcpUp) {
        if (-not $port22FirstSeen) { $port22FirstSeen = Get-Date }

        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & ssh.exe @sshOptsCheck "root@$($psmpVM.IPAddress)" "echo ready" 2>&1 } catch {}
        $keyExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP

        if ($keyExit -eq 0) {
            Write-Host "  [OK] Rocky Linux installed and SSH key auth confirmed at $elapsed min" -ForegroundColor Green
            $ready = $true
            break
        }

        $port22Age = if ($port22FirstSeen) { ((Get-Date) - $port22FirstSeen).TotalMinutes } else { 0 }
        if ($port22Age -ge 3 -and -not $keyInstallTried) {
            $keyInstallTried = $true
            Write-Host ""
            Write-Host "  Key auth not working after 3 min on port 22." -ForegroundColor Yellow
            Write-Host "  Installing lab SSH key via password SSH (one-time prompt)..." -ForegroundColor Yellow
            Write-Host "  >>> Enter root password when prompted: $rootPass <<<" -ForegroundColor Cyan
            $addKeyCmd = "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '$labPubKey' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo key_installed"
            $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $null = & ssh.exe @sshOptsPw "root@$($psmpVM.IPAddress)" $addKeyCmd 2>&1
            $ErrorActionPreference = $savedEAP
            continue
        }

        Write-Host "  [$elapsed min] Port 22 up - waiting for key auth..." -ForegroundColor DarkGray
    } else {
        Write-Host "  [$elapsed min] Still installing..." -ForegroundColor DarkGray
    }
}

if (-not $ready) {
    throw "Timeout: Rocky Linux SSH did not become reachable within $InstallTimeoutMin minutes. Check the VM console for errors."
}

# ================================================================
# Step 5: Register PSMP01 in DeployedVMs.xml
# ================================================================
Write-Host "`n[Step 5] Registering PSMP01..." -ForegroundColor Yellow

$deployedXml = "$PSScriptRoot\..\Config\DeployedVMs.xml"
$deployedVMs = if (Test-Path $deployedXml) { Import-Clixml $deployedXml } else { @{} }
$deployedVMs[$psmpVM.Name] = $vmxPath
$deployedVMs | Export-Clixml $deployedXml
Write-Host "  [OK] Registered in DeployedVMs.xml" -ForegroundColor Green

# ================================================================
# Step 6: Add PSMP01 DNS A record on DC01
# ================================================================
Write-Host "`n[Step 6] Adding PSMP01 DNS A record on DC01..." -ForegroundColor Yellow
$dcIP      = $Config.Network.DNS
$dcUser    = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$dcPass    = $Config.Domain.DomainAdminPass
$psmpShort = $psmpVM.Name.ToLower()
$zoneName  = $Config.Domain.Name

$dcCred = New-Object PSCredential($dcUser, (ConvertTo-SecureString $dcPass -AsPlainText -Force))
try {
    Invoke-Command -ComputerName $dcIP -Credential $dcCred -ErrorAction Stop -ScriptBlock {
        param($name, $zone, $ip)
        Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue |
            Remove-DnsServerResourceRecord -ZoneName $zone -Force -ErrorAction SilentlyContinue
        Add-DnsServerResourceRecordA -Name $name -ZoneName $zone -IPv4Address $ip `
            -TimeToLive ([TimeSpan]::FromHours(1))
        Write-Output "Created: $name.$zone -> $ip"
    } -ArgumentList $psmpShort, $zoneName, $psmpVM.IPAddress |
        ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "  [OK] DNS A record: $psmpShort.$zoneName -> $($psmpVM.IPAddress)" -ForegroundColor Green
} catch {
    Write-Warning "DNS record creation failed: $($_.Exception.Message)"
    Write-Warning "Add manually on DC01: Add-DnsServerResourceRecordA -Name $psmpShort -ZoneName $zoneName -IPv4Address $($psmpVM.IPAddress)"
}

$elapsed = (Get-Date) - $startTime
Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "PSMP01 ready - Rocky Linux 9 installed ($($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Green
Write-Host "  IP:   $($psmpVM.IPAddress)" -ForegroundColor Green
Write-Host "  Next: .\Deploy-Lab.ps1 -Steps PSMPInstall" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
