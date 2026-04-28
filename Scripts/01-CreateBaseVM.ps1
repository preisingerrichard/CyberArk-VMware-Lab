<#
.SYNOPSIS
    Create and install a Windows Server base template VM with fully unattended install.
    Uses IMAPI2 (built-in Windows COM) to create the autounattend ISO - no oscdimg needed.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\RemotingHelper.psm1" -Force
$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$templateName = $Config.VMware.TemplateName

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Creating Base Template VM: $templateName" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helper: create a small ISO from a folder using IMAPI2 (no oscdimg needed)
# ---------------------------------------------------------------------------
function New-IsoFromFolder {
    param(
        [string]$SourceFolder,
        [string]$OutputIso,
        [string]$VolumeName = "AUTOUNATTEND"
    )

    # PowerShell cannot cast COM objects to IStream via [type]cast — use C# via Add-Type instead.
    # C# can perform COM QueryInterface (QI) at the IL level; PowerShell's cast operator cannot.
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
            var pRead = Marshal.AllocHGlobal(sizeof(int));
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
"@ -Language CSharp
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet (Joliet preserves long filenames like autounattend.xml)
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTreeWithNamedStreams($SourceFolder, $false)

    $image = $fsi.CreateResultImage()
    [Imapi2Helper]::WriteIsoStream($image.ImageStream, $OutputIso)

    $sizeMB = [math]::Round((Get-Item $OutputIso).Length / 1MB, 2)
    Write-Host "  Created ISO: $OutputIso ($sizeMB MB)" -ForegroundColor Green
}

function Wait-ForLabWinRM {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $session = New-LabSession -ComputerName $ComputerName -Username $Username -Password $Password
            if ($session) {
                return $session
            }
        } catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 15
    }

    throw "WinRM did not become ready on $ComputerName within $TimeoutSeconds seconds. Last error: $lastError"
}

function Install-VMwareToolsRemote {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session
    )

    Invoke-LabRemoteScript -Session $Session -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $log = 'C:\Windows\Temp\VMwareToolsInstall.log'
        Set-Content -Path $log -Value "VMware Tools remote install started: $(Get-Date)" -Encoding UTF8

        function Write-ToolsLog {
            param([string]$Message)
            Add-Content -Path $log -Value $Message
        }

        function Test-VMwareToolsInstalled {
            $toolsService = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
            $toolsUninstall = Get-ItemProperty `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', `
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'VMware Tools*' } |
                Select-Object -First 1

            return [bool]($toolsService -or $toolsUninstall)
        }

        function Get-ToolsInstallerPath {
            $cdDisks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 5" -ErrorAction SilentlyContinue)
            $driveMap = @{}
            foreach ($disk in $cdDisks) {
                if ($disk.DeviceID) {
                    $driveMap[$disk.DeviceID] = $disk
                }
            }

            $letters = @($cdDisks | Select-Object -ExpandProperty DeviceID) + @('D:','E:','F:','G:','H:','I:','J:')

            foreach ($drive in ($letters | Where-Object { $_ } | Select-Object -Unique)) {
                $disk = $driveMap[$drive]
                $volumeName = if ($disk) { $disk.VolumeName } else { $null }

                if ((Test-Path "$drive\sources\install.wim") -or (Test-Path "$drive\sources\install.esd")) {
                    Write-ToolsLog "Skipping $drive because it looks like Windows install media."
                    continue
                }

                foreach ($candidate in @(
                    "$drive\VMware Tools\setup.exe",
                    "$drive\VMware Tools\setup64.exe",
                    "$drive\VMware Tools.msi"
                )) {
                    if (Test-Path $candidate) {
                        return $candidate
                    }
                }

                if (
                    ($volumeName -match 'VMware Tools') -or
                    (Test-Path "$drive\VMware Tools.msi") -or
                    (Test-Path "$drive\VMware Tools") -or
                    (Test-Path "$drive\manifest.txt")
                ) {
                    foreach ($candidate in @(
                        "$drive\setup.exe",
                        "$drive\setup64.exe"
                    )) {
                        if (Test-Path $candidate) {
                            return $candidate
                        }
                    }
                }
            }

            return $null
        }

        if (Test-VMwareToolsInstalled) {
            Write-ToolsLog 'VMware Tools already installed.'
            return
        }

        $installerPath = $null
        for ($attempt = 1; $attempt -le 24 -and -not $installerPath; $attempt++) {
            $installerPath = Get-ToolsInstallerPath
            if (-not $installerPath) {
                Write-ToolsLog "Attempt $attempt/24: VMware Tools installer not visible yet. Waiting 15 seconds."
                Start-Sleep -Seconds 15
            }
        }

        if (-not $installerPath) {
            throw 'No VMware Tools installer found after waiting for CD-ROM enumeration.'
        }

        Write-ToolsLog "Installing from: $installerPath"

        if ($installerPath -like '*.msi') {
            $proc = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList '/i', "`"$installerPath`"", '/qn', 'REBOOT=ReallySuppress' `
                -Wait -NoNewWindow -PassThru
        } else {
            $proc = Start-Process -FilePath $installerPath `
                -ArgumentList '/s', '/v"/qn REBOOT=ReallySuppress"' `
                -Wait -NoNewWindow -PassThru
        }

        Write-ToolsLog "ExitCode: $($proc.ExitCode)"

        if ($proc.ExitCode -notin 0, 3010, 1641) {
            throw "Unexpected exit code from VMware Tools installer: $($proc.ExitCode)"
        }

        Start-Sleep -Seconds 20

        if (-not (Test-VMwareToolsInstalled)) {
            throw 'Installer exited successfully, but VMware Tools was not detected after install.'
        }

        Write-ToolsLog 'VMware Tools install verified in service list or uninstall registry.'
    }
}

function Get-LabVmIpFromDhcpLease {
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [string]$LeaseFilePath = 'C:\ProgramData\VMware\vmnetdhcp.leases'
    )

    if (-not (Test-Path $VMXPath) -or -not (Test-Path $LeaseFilePath)) {
        return $null
    }

    $vmxContent = Get-Content -Path $VMXPath -Raw
    $macMatch = [regex]::Match($vmxContent, 'ethernet0\.generatedAddress\s*=\s*"([^"]+)"')
    if (-not $macMatch.Success) {
        return $null
    }

    $macAddress = $macMatch.Groups[1].Value.ToLowerInvariant()
    $leaseContent = Get-Content -Path $LeaseFilePath -Raw
    $leasePattern = '(?s)lease\s+(?<ip>\d+\.\d+\.\d+\.\d+)\s+\{.*?hardware ethernet\s+(?<mac>[0-9a-f:]+);.*?\}'
    $matches = [regex]::Matches($leaseContent, $leasePattern)

    $latestIp = $null
    foreach ($match in $matches) {
        if ($match.Groups['mac'].Value.ToLowerInvariant() -eq $macAddress) {
            $latestIp = $match.Groups['ip'].Value
        }
    }

    return $latestIp
}

# ---------------------------------------------------------------------------
# Resolve paths up front so early-exit and ISO-skip checks can use them
# ---------------------------------------------------------------------------
$templateFolder    = $Config.VMware.TemplateFolder
$templateVMXFolder = Join-Path $Config.VMware.DefaultVMFolder $templateName
$templateVMX       = Join-Path $templateVMXFolder "$templateName.vmx"
$unattendIso       = Join-Path $templateFolder "unattend.iso"

# Early exit: CleanInstall snapshot already exists - nothing left to do
if (Test-Path $templateVMX) {
    $snapshotCheck = Invoke-VMRun -Arguments @("listSnapshots", "`"$templateVMX`"") -NoThrow -TimeoutSeconds 30
    if ($snapshotCheck.ExitCode -eq 0 -and $snapshotCheck.StdOut -match 'CleanInstall') {
        Write-Host "`nCleanInstall snapshot already exists - template is ready!" -ForegroundColor Green
        Write-Host "  VMX: $templateVMX" -ForegroundColor Green
        return
    }
}

# ---------------------------------------------------------------------------
# Step 1: Build autounattend ISO
# Skip if the VM folder already exists - the ISO is already built and likely
# mounted in the running VM (rebuilding it would hit a file-lock error).
# ---------------------------------------------------------------------------
Write-Host "`n[Step 1] Building autounattend ISO..." -ForegroundColor Yellow

$isoSourceDir = Join-Path $templateFolder "unattend_iso"
$autounattendPath = Join-Path $isoSourceDir "autounattend.xml"
$toolsInstallScriptPath = Join-Path $isoSourceDir "Install-VmwareTools.ps1"

if (-not (Test-Path $templateFolder)) {
    New-Item -Path $templateFolder -ItemType Directory -Force | Out-Null
}

Write-Host "  Building/refreshing autounattend ISO files..." -ForegroundColor DarkGray
$unattendContent = Get-Content "$PSScriptRoot\..\Templates\unattend-base.xml" -Raw
$unattendContent = $unattendContent.Replace('YOURNAME',     $templateName)
$unattendContent = $unattendContent.Replace('YOURPASSWORD', $Config.LocalAdmin.Password)

$toolsInstallScript = @'
$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\VMwareToolsInstall.log'
Set-Content -Path $log -Value "VMware Tools install started: $(Get-Date)" -Encoding UTF8

function Write-ToolsLog {
    param([string]$Message)
    Add-Content -Path $log -Value $Message
}

function Test-VMwareToolsInstalled {
    $toolsService = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    $toolsUninstall = Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', `
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'VMware Tools*' } |
        Select-Object -First 1

    return [bool]($toolsService -or $toolsUninstall)
}

function Register-VMwareToolsRetryTask {
    $taskName = 'InstallVMwareToolsRetry'
    $localScript = 'C:\Windows\Temp\Install-VMwareTools-Retry.ps1'

    if ($PSCommandPath -and ($PSCommandPath -ne $localScript)) {
        Copy-Item -Path $PSCommandPath -Destination $localScript -Force
        Write-ToolsLog "Copied retry script to $localScript"
    }

    $existingTask = & schtasks.exe /Query /TN $taskName 2>$null
    if ($LASTEXITCODE -ne 0) {
        $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$localScript`""
        & schtasks.exe /Create /TN $taskName /SC MINUTE /MO 5 /TR $taskCommand /RU SYSTEM /RL HIGHEST /F | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to register scheduled task '$taskName'."
        }

        Write-ToolsLog "Registered scheduled task '$taskName' to retry every 5 minutes."
    } else {
        Write-ToolsLog "Scheduled task '$taskName' already exists."
    }

    & schtasks.exe /Run /TN $taskName | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ToolsLog "Started scheduled task '$taskName'."
    } else {
        Write-ToolsLog "Scheduled task '$taskName' could not be started immediately (exit $LASTEXITCODE)."
    }
}

function Unregister-VMwareToolsRetryTask {
    $taskName = 'InstallVMwareToolsRetry'
    & schtasks.exe /Query /TN $taskName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & schtasks.exe /Delete /TN $taskName /F | Out-Null
        Write-ToolsLog "Removed scheduled task '$taskName'."
    }
}

# Wait for VMware CD-ROM enumeration. On first logon the secondary ISO can be
# visible immediately while the VMware Tools ISO appears a bit later.
function Get-ToolsInstallerPath {
    $cdDisks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 5" -ErrorAction SilentlyContinue)
    $driveMap = @{}
    foreach ($disk in $cdDisks) {
        if ($disk.DeviceID) {
            $driveMap[$disk.DeviceID] = $disk
        }
    }

    $letters = @($cdDisks | Select-Object -ExpandProperty DeviceID) + @('D:','E:','F:','G:','H:','I:','J:')

    foreach ($drive in ($letters | Where-Object { $_ } | Select-Object -Unique)) {
        $disk = $driveMap[$drive]
        $volumeName = if ($disk) { $disk.VolumeName } else { $null }

        # Ignore the Windows installation DVD. It also has setup.exe at the root,
        # which causes a false-positive "successful" run during first logon.
        if ((Test-Path "$drive\sources\install.wim") -or (Test-Path "$drive\sources\install.esd")) {
            Write-ToolsLog "Skipping $drive because it looks like Windows install media."
            continue
        }

        $preferredCandidates = @(
            "$drive\VMware Tools\setup.exe",
            "$drive\VMware Tools\setup64.exe",
            "$drive\VMware Tools.msi"
        )

        foreach ($candidate in $preferredCandidates) {
            if (Test-Path $candidate) {
                return $candidate
            }
        }

        # Only accept a root-level setup.exe if the drive also has VMware-specific content.
        if (
            ($volumeName -match 'VMware Tools') -or
            (Test-Path "$drive\VMware Tools.msi") -or
            (Test-Path "$drive\VMware Tools") -or
            (Test-Path "$drive\manifest.txt")
        ) {
            foreach ($candidate in @(
                "$drive\setup.exe",
                "$drive\setup64.exe"
            )) {
                if (Test-Path $candidate) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

Register-VMwareToolsRetryTask

if (Test-VMwareToolsInstalled) {
    Write-ToolsLog 'VMware Tools already installed.'
    Unregister-VMwareToolsRetryTask
    exit 0
}

$installerPath = $null
for ($attempt = 1; $attempt -le 24 -and -not $installerPath; $attempt++) {
    $installerPath = Get-ToolsInstallerPath
    if (-not $installerPath) {
        Write-ToolsLog "Attempt $attempt/24: VMware Tools installer not visible yet. Waiting 15 seconds."
        Start-Sleep -Seconds 15
    }
}

if (-not $installerPath) {
    Write-ToolsLog 'No VMware Tools installer found after waiting for CD-ROM enumeration.'
    exit 1
}

Write-ToolsLog "Installing from: $installerPath"

try {
    if ($installerPath -like '*.msi') {
        $proc = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList '/i', "`"$installerPath`"", '/qn', 'REBOOT=ReallySuppress' `
            -Wait -NoNewWindow -PassThru
    } else {
        # Broadcom's documented silent install syntax for the Windows Tools bootstrapper.
        $proc = Start-Process -FilePath $installerPath `
            -ArgumentList '/s', '/v"/qn REBOOT=ReallySuppress"' `
            -Wait -NoNewWindow -PassThru
    }
    Write-ToolsLog "ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -in 0, 3010, 1641) {
        Start-Sleep -Seconds 20

        if (Test-VMwareToolsInstalled) {
            Write-ToolsLog 'VMware Tools install verified in service list or uninstall registry.'
            Unregister-VMwareToolsRetryTask
        } else {
            Write-ToolsLog 'Installer exited successfully, but VMware Tools was not detected after install. Scheduled task will retry.'
            exit 1
        }
    } else {
        Write-ToolsLog "Unexpected exit code from VMware Tools installer: $($proc.ExitCode)"
        exit $proc.ExitCode
    }
} catch {
    Write-ToolsLog "Installation failed: $($_.Exception.Message)"
    exit 1
}
'@
$expectedToolsHash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($toolsInstallScript)
    )
).Replace('-', '')
$currentToolsHash = if (Test-Path $toolsInstallScriptPath) {
    (Get-FileHash -Path $toolsInstallScriptPath -Algorithm SHA256).Hash
} else {
    $null
}
$needIsoBuild = -not (Test-Path $templateVMXFolder) -or `
    -not (Test-Path $autounattendPath) -or `
    -not (Test-Path $toolsInstallScriptPath) -or `
    ($currentToolsHash -ne $expectedToolsHash)

if (-not (Test-Path $isoSourceDir)) {
    New-Item -Path $isoSourceDir -ItemType Directory -Force | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($autounattendPath, $unattendContent, $utf8NoBom)
[System.IO.File]::WriteAllText($toolsInstallScriptPath, $toolsInstallScript, $utf8NoBom)

if ($needIsoBuild) {
    New-IsoFromFolder -SourceFolder $isoSourceDir -OutputIso $unattendIso
} else {
    Write-Host "  Autounattend ISO already matches the current template files." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 2: Create the VM (no-op if folder already exists)
# ---------------------------------------------------------------------------
Write-Host "`n[Step 2] Creating template VM..." -ForegroundColor Yellow

if (-not (Test-Path $templateVMXFolder)) {
    New-LabVM -VMName $templateName `
        -CPUs 2 -MemoryMB 4096 -DiskGB 60 `
        -ISOPath $Config.ISOs.WindowsServer `
        -GuestOS "windows2019srvnext-64" `
        -NetworkType "nat" | Out-Null
}

# Attach autounattend ISO as a second CD-ROM (ide1:1) - only if not already present
# Windows Setup scans all CD-ROM drives for autounattend.xml
$vmxLines = [System.IO.File]::ReadAllLines($templateVMX, [System.Text.Encoding]::UTF8)
$vmxChanged = $false

# AMD + Hyper-V host (WHP mode) compatibility - prevents STATUS_INTEGER_DIVIDE_BY_ZERO BSOD
# during Windows Server 2022 OOBE boot phase on AMD CPUs under Hyper-V.
if (-not ($vmxLines -match 'hypervisor\.cpuid\.v0')) {
    $vmxLines += @(
        '',
        '# AMD + Hyper-V (WHP) host compatibility flags - prevents BSOD 0x7E/0xC0000094',
        'hypervisor.cpuid.v0 = "FALSE"',
        'mce.enable = "TRUE"',
        'vhv.enable = "FALSE"'
    )
    $vmxChanged = $true
    Write-Host "  AMD/Hyper-V compatibility flags added to VMX." -ForegroundColor Green
}

if (-not ($vmxLines -match 'ide1:1\.present')) {
    $vmxLines += @(
        '',
        '# Autounattend ISO (secondary CD-ROM)',
        'ide1:1.present = "TRUE"',
        'ide1:1.deviceType = "cdrom-image"',
        "ide1:1.fileName = `"$($unattendIso -replace '\\','/')`"",
        'ide1:1.startConnected = "TRUE"'
    )
    $vmxChanged = $true
    Write-Host "  Autounattend ISO attached as secondary CD-ROM." -ForegroundColor Green
} else {
    Write-Host "  Autounattend ISO already configured in VMX." -ForegroundColor DarkGray
}

# Pre-mount VMware Tools ISO (sata0:1) so it's available the moment Windows first logs on.
# vmrun installTools requires a running guest OS, so calling it during Setup (which takes 20+ min)
# fails. By mounting the ISO upfront, FirstLogonCommands can install Tools immediately on first boot.
$toolsIso = Join-Path (Split-Path $Config.VMware.VMRunPath) "windows.iso"
if (Test-Path $toolsIso) {
    $toolsIsoFwd = $toolsIso -replace '\\', '/'
    if (-not ($vmxLines -match 'sata0:1\.present')) {
        $vmxLines += @(
            '',
            '# VMware Tools ISO - pre-mounted so FirstLogonCommands can install silently',
            'sata0:1.present = "TRUE"',
            'sata0:1.deviceType = "cdrom-image"',
            "sata0:1.fileName = `"$toolsIsoFwd`"",
            'sata0:1.startConnected = "TRUE"'
        )
        $vmxChanged = $true
        Write-Host "  VMware Tools ISO pre-mounted (sata0:1): $toolsIso" -ForegroundColor Green
    } else {
        # Ensure existing SATA1 CD-ROM stays connected to the VMware Tools ISO.
        $updatedTools = $false
        $vmxLines = $vmxLines | ForEach-Object {
            if ($_ -match '^sata0:1\.fileName') {
                $updatedTools = $true
                return "sata0:1.fileName = `"$toolsIsoFwd`""
            } elseif ($_ -match '^sata0:1\.startConnected') {
                $updatedTools = $true
                return 'sata0:1.startConnected = "TRUE"'
            } else {
                return $_
            }
        }
        if (-not $updatedTools) {
            $vmxLines += @(
                '',
                '# VMware Tools ISO - pre-mounted so FirstLogonCommands can install silently',
                "sata0:1.fileName = `"$toolsIsoFwd`"",
                'sata0:1.startConnected = "TRUE"'
            )
        }
        $vmxChanged = $true
        Write-Host "  VMware Tools ISO configuration verified for sata0:1." -ForegroundColor Green
    }
} else {
    Write-Warning "VMware Tools ISO not found at $toolsIso - Tools must be installed manually."
}

if ($vmxChanged) {
    [System.IO.File]::WriteAllLines($templateVMX, $vmxLines, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# Step 3: Start VM - Windows installs fully unattended
# ---------------------------------------------------------------------------
Write-Host "`n[Step 3] Starting VM for unattended Windows installation..." -ForegroundColor Yellow
Write-Host "  Windows will install automatically (15-30 min)." -ForegroundColor DarkGray
Write-Host "  VMware Tools will be installed from the host after WinRM becomes available." -ForegroundColor DarkGray

Start-LabVM -VMXPath $templateVMX

# Wait for the guest to get an IP first, then switch to WinRM for the Tools install.
$maxWait = 3600  # 60 minutes total
$elapsed = 0
$vmIp = $null

Write-Host "`nWaiting for guest networking (Windows Setup takes ~20 min)..." -ForegroundColor Cyan

while ($elapsed -lt $maxWait -and -not $vmIp) {
    Start-Sleep -Seconds 30
    $elapsed += 30
    $minutes = [math]::Floor($elapsed / 60)

    $vmIp = Get-LabVmIpFromDhcpLease -VMXPath $templateVMX

    if ($vmIp) {
        Write-Host "  Guest IP detected: $vmIp" -ForegroundColor Green
    } else {
        Write-Host "  Waiting for guest IP... ($minutes min / $([math]::Floor($maxWait/60)) min max)" -ForegroundColor DarkGray
    }
}

if (-not $vmIp) {
    throw "Template VM did not obtain an IP within $([math]::Floor($maxWait/60)) minutes."
}

Write-Host "`nWaiting for WinRM to become available on $vmIp..." -ForegroundColor Cyan
$session = $null
try {
    $session = Wait-ForLabWinRM -ComputerName $vmIp `
        -Username $Config.LocalAdmin.Username `
        -Password $Config.LocalAdmin.Password `
        -TimeoutSeconds 1800

    Write-Host "  WinRM ready on $vmIp" -ForegroundColor Green

    Write-Host "`nInstalling VMware Tools via WinRM..." -ForegroundColor Cyan
    Install-VMwareToolsRemote -Session $session
} finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

Write-Host "Waiting for VMware Tools guest operations..." -ForegroundColor Cyan
Wait-LabVMReady -VMXPath $templateVMX `
    -TimeoutSeconds 900 `
    -GuestUser $Config.LocalAdmin.Username `
    -GuestPassword $Config.LocalAdmin.Password

Write-Host "`nWindows installation and VMware Tools setup complete!" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 4: Post-install hardening and lab prep
# ---------------------------------------------------------------------------
Write-Host "`n[Step 4] Configuring template..." -ForegroundColor Yellow

$postInstallScript = @'
$ErrorActionPreference = 'SilentlyContinue'

# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Enable WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck
winrm quickconfig -q

# Set network to private (required for WinRM)
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Disable Windows Update (lab only)
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service wuauserv -StartupType Disabled

# Disable Server Manager auto-launch
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask

# Disable IE Enhanced Security Configuration
$AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UserKey  -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue

# Set PowerShell execution policy
Set-ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue

# Create standard lab directories
New-Item -Path "C:\LabSetup"         -ItemType Directory -Force | Out-Null
New-Item -Path "C:\LabSetup\Logs"    -ItemType Directory -Force | Out-Null
New-Item -Path "C:\LabSetup\Scripts" -ItemType Directory -Force | Out-Null
New-Item -Path "C:\CyberArkInstall"  -ItemType Directory -Force | Out-Null

Write-Host "Template configuration complete"
'@

Invoke-LabVMPowerShell -VMXPath $templateVMX -ScriptBlock $postInstallScript `
    -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password

# ---------------------------------------------------------------------------
# Step 5: Shutdown, disconnect ISOs, snapshot
# ---------------------------------------------------------------------------
Write-Host "`n[Step 5] Creating CleanInstall snapshot..." -ForegroundColor Yellow

Stop-LabVM -VMXPath $templateVMX
Start-Sleep -Seconds 15

# Disconnect all CD-ROMs so clones don't boot from any ISO
$vmxLines = [System.IO.File]::ReadAllLines($templateVMX, [System.Text.Encoding]::UTF8)
$vmxLines = $vmxLines | ForEach-Object {
    if ($_ -match '^(ide[01]:\d|sata0:[1-9])\.startConnected') { $_ -replace '"TRUE"', '"FALSE"' }
    else { $_ }
}
[System.IO.File]::WriteAllLines($templateVMX, $vmxLines, [System.Text.Encoding]::UTF8)

# Brief boot to finalize (Tools registration, etc.), then snapshot
Start-LabVM -VMXPath $templateVMX -NoGUI
Wait-LabVMReady -VMXPath $templateVMX

# Light cleanup inside guest before snapshot
Invoke-LabVMPowerShell -VMXPath $templateVMX -ScriptBlock @'
ipconfig /release
Clear-EventLog -LogName Application, System, Security -ErrorAction SilentlyContinue
'@ -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password

Start-Sleep -Seconds 10
Stop-LabVM -VMXPath $templateVMX
Start-Sleep -Seconds 15

New-LabVMSnapshot -VMXPath $templateVMX -SnapshotName "CleanInstall"

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "Template VM ready!" -ForegroundColor Green
Write-Host "  VMX:      $templateVMX" -ForegroundColor Green
Write-Host "  Snapshot: CleanInstall" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
