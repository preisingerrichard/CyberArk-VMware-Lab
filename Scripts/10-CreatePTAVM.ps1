<#
.SYNOPSIS
    Create and provision PTA Rocky Linux 9 virtual machines.
.DESCRIPTION
    Creates PTA VMs (VMX + VMDK) in VMware Workstation using BIOS firmware.

    By default creates only PTA01. To create multiple PTAs for DR testing:
      .\10-CreatePTAVM.ps1 -PTANames @("PTA01","PTA02")

    Steps per VM:
    1. Creates VM (VMX + VMDK) in VMware Workstation using BIOS firmware
    2. Creates a kickstart ISO (ks.cfg) attached as sata0:1
    3. Boots via BIOS/isolinux; injects inst.ks=cdrom via WScript.Shell
    4. Waits for open-vm-tools, then registers VM in DeployedVMs.xml

    Uses guestOS = "other3xlinux-64" to ensure BIOS mode. rhel9-64Guest forces
    EFI in VMware virtualHW 19 regardless of the firmware = "bios" VMX setting.

    Run this before 11-InstallPTA-Primary.ps1 or 11-InstallPTA-Secondary.ps1.
    Installation takes 20-35 minutes per VM; the script waits automatically.
#>

param(
    [string]$ConfigPath        = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [int]   $InstallTimeoutMin = 60,
    [switch]$Force,
    [string[]]$PTANames        = @("PTA01")  # Override with @("PTA01","PTA02") to deploy multiple
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$allPTAVMs = @($Config.VMs | Where-Object { $_.Role -eq 'PTA' -or $_.Role -contains 'PTA' })
if (-not $allPTAVMs) { throw "No VM with Role 'PTA' found in LabConfig.psd1" }

$ptaVMs = @($allPTAVMs | Where-Object { $_.Name -in $PTANames })
if (-not $ptaVMs) { throw "No PTA VMs found matching names: $($PTANames -join ', ')" }

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Creating PTA VMs: $($ptaVMs.Name -join ', ')" -ForegroundColor Cyan
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

    if (Test-Path $OutputIso) {
        Remove-Item -Path $OutputIso -Force
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 1
    $fsi.VolumeName = 'OEMDRV'
    $fsi.Root.AddTreeWithNamedStreams($SourceFolder, $false)
    $image = $fsi.CreateResultImage()
    [Imapi2Helper]::WriteIsoStream($image.ImageStream, $OutputIso)

    # Anaconda checks the ISO9660 primary volume descriptor. Patch it directly
    # so the volume label is exactly OEMDRV even when IMAPI2 only sets Joliet.
    $isoBytes = [System.IO.File]::ReadAllBytes($OutputIso)
    $labelBytes = [System.Text.Encoding]::ASCII.GetBytes('OEMDRV'.PadRight(32))
    [System.Buffer]::BlockCopy($labelBytes, 0, $isoBytes, 0x8028, 32)
    [System.IO.File]::WriteAllBytes($OutputIso, $isoBytes)

    $written = [System.Text.Encoding]::ASCII.GetString($isoBytes[0x8028..0x8047]).TrimEnd()
    Write-Host "  OEMDRV ISO label: '$written'" -ForegroundColor DarkGray
    if ($written -ne 'OEMDRV') {
        throw "Failed to write OEMDRV label into kickstart ISO."
    }
}

function Test-VMRunning {
    param([Parameter(Mandatory)][string]$Path)

    $listResult = Invoke-VMRun -Arguments @('list') -NoThrow
    return ($listResult.StdOut -match [regex]::Escape($Path))
}

$rockyISO = $Config.ISOs.RockyLinux
if (-not (Test-Path $rockyISO)) {
    throw "Rocky Linux ISO not found: '$rockyISO' - update ISOs.RockyLinux in LabConfig.psd1"
}

foreach ($ptaVM in $ptaVMs) {
    $vmFolder = Join-Path $Config.VMware.DefaultVMFolder $ptaVM.Name
    $vmxPath  = Join-Path $vmFolder "$($ptaVM.Name).vmx"
    $vmdkPath = Join-Path $vmFolder "$($ptaVM.Name).vmdk"
    $ksISOPath = Join-Path $vmFolder "ks.iso"

    Write-Host "`n[PTA VM] Creating $($ptaVM.Name) ($($ptaVM.IPAddress), Rocky Linux 9)" -ForegroundColor Cyan

New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

if (Test-Path $vmxPath) {
    if (-not $Force) {
        throw "PTA01 VM already exists at '$vmxPath'. Use -Force to power off and recreate it."
    }
    Write-Host "`n[Step 0] Tearing down existing $($ptaVM.Name) VM (-Force)..." -ForegroundColor Yellow
    $vmxPathUnix = $vmxPath -replace '\\', '/'
    if (Test-VMRunning -Path $vmxPathUnix) {
        Write-Host "  Stopping $($ptaVM.Name)..." -ForegroundColor DarkGray
        Invoke-VMRun -Arguments @("stop", $vmxPathUnix, "hard") -NoThrow | Out-Null
        Start-Sleep -Seconds 5
    }
    Write-Host "  Deleting VM folder: $vmFolder" -ForegroundColor DarkGray
    Remove-Item -Path $vmFolder -Recurse -Force
    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
    Write-Host "  [OK] PTA01 removed" -ForegroundColor Green
}

# ================================================================
# Step 1: Create or update PTA01 VM (VMX + VMDK)
# ================================================================
Write-Host "`n[Step 1] Creating or updating PTA01 VM..." -ForegroundColor Yellow

if (-not (Test-Path $vmdkPath)) {
    Write-Host "  Creating $($ptaVM.DiskGB) GB disk..." -ForegroundColor DarkGray
    $vdiskMgr = Join-Path (Split-Path $Config.VMware.VMRunPath) "vmware-vdiskmanager.exe"
    if (-not (Test-Path $vdiskMgr)) { throw "vmware-vdiskmanager.exe not found at '$vdiskMgr'" }
    & $vdiskMgr -c -s "$($ptaVM.DiskGB)GB" -a lsilogic -t 0 $vmdkPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vmware-vdiskmanager failed (exit $LASTEXITCODE)" }
} else {
    Write-Host "  [SKIP] Disk already exists: $vmdkPath" -ForegroundColor Yellow
}

Write-Host "  Writing VMX (BIOS mode, SATA CDROMs)..." -ForegroundColor DarkGray
$vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "$($ptaVM.Name)"
guestOS = "other3xlinux-64"
numvcpus = "$($ptaVM.CPUs)"
cpuid.coresPerSocket = "$($ptaVM.CPUs)"
memsize = "$($ptaVM.MemoryMB)"

scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$($ptaVM.Name).vmdk"
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

# Generate lab SSH key if not present -- the PTA primary/secondary installers use
# the private key; the public key is embedded in the kickstart so the VM trusts it
# from first boot.
$labKeyPath = Join-Path $PSScriptRoot "..\Config\pta_lab_key"
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\pta_lab_key"
if (-not (Test-Path $labKeyPath)) {
    Write-Host "  Generating lab SSH key at $labKeyPath ..." -ForegroundColor DarkGray
    & ssh-keygen.exe -t ed25519 -f $labKeyPath -N '""' -C "pta-lab-automation" | Out-Null
    if (-not (Test-Path $labKeyPath)) { throw "ssh-keygen failed to create $labKeyPath" }
}
$labPubKey = (Get-Content "$labKeyPath.pub" -Raw).Trim()
Write-Host "  Lab SSH public key loaded" -ForegroundColor DarkGray

$ksDir = Join-Path $env:TEMP "pta_oemdrv_$(Get-Random)"
$ksFile = Join-Path $ksDir "ks.cfg"
New-Item -Path $ksDir -ItemType Directory -Force | Out-Null

try {
    $ksText = @"
#version=RHEL9
cmdline
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone UTC --utc --ntpservers=$($Config.Network.DNS)
network --bootproto=static --device=link --ip=$($ptaVM.IPAddress) --netmask=$($Config.Network.SubnetMask) --gateway=$($Config.Network.Gateway) --nameserver=$($Config.Network.DNS),8.8.8.8 --hostname=$($ptaVM.Name.ToLower()).$($Config.Domain.Name) --activate
rootpw --plaintext $($Config.LocalAdmin.Password)
selinux --permissive
firewall --enabled --service=ssh --port=80:tcp --port=443:tcp --port=8080:tcp --port=8443:tcp --port=514:tcp --port=514:udp --port=11514:tcp --port=11514:udp --port=27017:tcp
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
chrony
%end
%post
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-lab.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/10-lab.conf
systemctl enable sshd
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$labPubKey" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
# Time sync from DC01 (domain time source) - CA-issued certs fail with clock skew
cat > /etc/chrony.conf <<CHRONYCONF
server $($Config.Network.DNS) iburst
driftfile /var/lib/chrony/drift
makestep 1.0 -1
rtcsync
logdir /var/log/chrony
CHRONYCONF
systemctl enable chronyd
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

# Remove stale .nvram from any prior EFI-mode attempt so BIOS boots clean.
$nvramPath = Join-Path $vmFolder "$($ptaVM.Name).nvram"
if (Test-Path $nvramPath) {
    Remove-Item $nvramPath -Force
    Write-Host "  Removed stale .nvram" -ForegroundColor DarkGray
}

$listResult = Invoke-VMRun -Arguments @("list") -NoThrow
$vmxPathUnix = $vmxPath -replace '\\', '/'
if ($listResult.StdOut -notmatch [regex]::Escape($vmxPathUnix)) {
    Invoke-VMRun -Arguments @("start", $vmxPathUnix) | Out-Null
    Write-Host "  VM started - waiting 20s for BIOS POST and isolinux menu..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
} else {
    Write-Host "  VM already running" -ForegroundColor DarkGray
}

# Use WScript.Shell to activate the VMware Workstation window and send keystrokes
# through the Windows input stack. vmrun sendKey returns exit -1 on this system.
# Pressing Tab in isolinux appends to the selected kernel line; we add inst.ks=cdrom
# so Anaconda scans all attached CDROMs and finds ks.cfg on sata0:1.
$wshell     = New-Object -ComObject wscript.shell
$vmwareProc = Get-Process -Name "vmware" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$($ptaVM.Name)*" } |
    Select-Object -First 1

if (-not $vmwareProc) {
    Write-Warning "VMware window for '$($ptaVM.Name)' not found. Please manually press Tab in the isolinux menu, type ' inst.ks=cdrom', then Enter."
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
Write-Host "  Polling every 30 seconds for open-vm-tools to respond..." -ForegroundColor DarkGray

$installDeadline  = (Get-Date).AddMinutes($InstallTimeoutMin)
$ready            = $false
$port22FirstSeen  = $null
$keyInstallTried  = $false

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
        $tcpUp = $tcp.ConnectAsync($ptaVM.IPAddress, 22).Wait(3000)
        $tcp.Close()
    } catch {}

    if ($tcpUp) {
        if (-not $port22FirstSeen) { $port22FirstSeen = Get-Date }

        # Primary: lab SSH key (set by kickstart %post)
        $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & ssh.exe @sshOptsCheck "root@$($ptaVM.IPAddress)" "echo ready" 2>&1 } catch {}
        $keyExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP

        if ($keyExit -eq 0) {
            Write-Host "  [OK] Rocky Linux installed and SSH key auth confirmed at $elapsed min" -ForegroundColor Green
            $ready = $true
            break
        }

        # Fallback: if port 22 has been up for 3+ minutes and key auth still
        # fails, the kickstart %post likely didn't write authorized_keys.
        # Use one interactive password SSH call to install the lab key.
        # ssh.exe will prompt for the root password once; all subsequent
        # connections use key auth as normal.
        $port22Age = if ($port22FirstSeen) { ((Get-Date) - $port22FirstSeen).TotalMinutes } else { 0 }
        if ($port22Age -ge 3 -and -not $keyInstallTried) {
            $keyInstallTried = $true
            Write-Host ""
            Write-Host "  Key auth not working after 3 min on port 22." -ForegroundColor Yellow
            Write-Host "  Installing lab SSH key via password SSH (one-time prompt)..." -ForegroundColor Yellow
            Write-Host "  >>> Enter root password when prompted: $rootPass <<<" -ForegroundColor Cyan
            $addKeyCmd = "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '$labPubKey' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo key_installed"
            $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $null = & ssh.exe @sshOptsPw "root@$($ptaVM.IPAddress)" $addKeyCmd 2>&1
            $pwExit = $LASTEXITCODE
            $ErrorActionPreference = $savedEAP
            if ($pwExit -eq 0) {
                Write-Host "  [OK] Lab key installed -- retrying key auth..." -ForegroundColor Green
            } else {
                Write-Host "  Password SSH exited $pwExit - will keep retrying key auth" -ForegroundColor DarkGray
            }
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
# Step 5: Register PTA01 in DeployedVMs.xml
# ================================================================
Write-Host "`n[Step 5] Registering PTA01..." -ForegroundColor Yellow

$deployedXml = "$PSScriptRoot\..\Config\DeployedVMs.xml"
$deployedVMs = if (Test-Path $deployedXml) { Import-Clixml $deployedXml } else { @{} }
$deployedVMs[$ptaVM.Name] = $vmxPath
$deployedVMs | Export-Clixml $deployedXml

Write-Host "  [OK] Registered in DeployedVMs.xml" -ForegroundColor Green

# ================================================================
# Step 6: Add PTA01 DNS A record on DC01
# ================================================================
Write-Host "`n[Step 6] Adding PTA01 DNS A record on DC01..." -ForegroundColor Yellow
$dcIP     = $Config.Network.DNS
$dcUser   = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$dcPass   = $Config.Domain.DomainAdminPass
$ptaShort = $ptaVM.Name.ToLower()
$zoneName = $Config.Domain.Name

$dcCred = New-Object PSCredential($dcUser, (ConvertTo-SecureString $dcPass -AsPlainText -Force))
try {
    Invoke-Command -ComputerName $dcIP -Credential $dcCred -ErrorAction Stop -ScriptBlock {
        param($name, $zone, $ip)
        # Idempotent: remove stale record before adding
        Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue |
            Remove-DnsServerResourceRecord -ZoneName $zone -Force -ErrorAction SilentlyContinue
        Add-DnsServerResourceRecordA -Name $name -ZoneName $zone -IPv4Address $ip `
            -TimeToLive ([TimeSpan]::FromHours(1))
        Write-Output "Created: $name.$zone -> $ip"
    } -ArgumentList $ptaShort, $zoneName, $ptaVM.IPAddress |
        ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "  [OK] DNS A record: $ptaShort.$zoneName -> $($ptaVM.IPAddress)" -ForegroundColor Green
} catch {
    Write-Warning "DNS record creation failed: $($_.Exception.Message)"
    Write-Warning "Add manually on DC01: Add-DnsServerResourceRecordA -Name $ptaShort -ZoneName $zoneName -IPv4Address $($ptaVM.IPAddress)"
}

    $elapsed = (Get-Date) - $startTime
    Write-Host "`n$("=" * 60)" -ForegroundColor Green
    Write-Host "$($ptaVM.Name) ready - Rocky Linux 9 installed ($($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Green
    Write-Host "  IP:   $($ptaVM.IPAddress)" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor Green
}

Write-Host "`nAll PTA VMs created successfully." -ForegroundColor Green
if ($ptaVMs.Count -eq 1 -and $ptaVMs[0].Name -eq "PTA01") {
    Write-Host "Next: .\Scripts\11-InstallPTA-Primary.ps1 -PTANames @(""PTA01"")" -ForegroundColor Green
} elseif ($ptaVMs.Count -eq 1 -and $ptaVMs[0].Name -eq "PTA02") {
    Write-Host "Next: .\Scripts\11-InstallPTA-Secondary.ps1 -PTANames @(""PTA02"")" -ForegroundColor Green
} else {
    Write-Host "Next step 1: .\Scripts\11-InstallPTA-Primary.ps1 -PTANames @(""PTA01"")" -ForegroundColor Green
    Write-Host "Next step 2: .\Scripts\11-InstallPTA-Secondary.ps1 -PTANames @(""PTA02"")" -ForegroundColor Green
}
