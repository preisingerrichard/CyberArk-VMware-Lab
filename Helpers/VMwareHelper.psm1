#Requires -Version 5.1

<#
.SYNOPSIS
    VMware Workstation automation helper using vmrun and vmware-vdiskmanager
.DESCRIPTION
    Wraps vmrun.exe commands for VM lifecycle management.
    Works with VMware Workstation Pro (not Player - Player lacks vmrun support).
.NOTES
    VMware Workstation Pro is REQUIRED. Player does not support vmrun or VIX API.
#>

$Script:VMwareConfig = $null

function Initialize-VMwareHelper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $Script:VMwareConfig = $Config

    # Validate vmrun exists
    if (-not (Test-Path $Config.VMRunPath)) {
        throw "vmrun.exe not found at '$($Config.VMRunPath)'. Is VMware Workstation Pro installed?"
    }

    # Validate vmware-vdiskmanager
    $vdiskMgr = Join-Path (Split-Path $Config.VMRunPath) "vmware-vdiskmanager.exe"
    if (-not (Test-Path $vdiskMgr)) {
        Write-Warning "vmware-vdiskmanager.exe not found. Disk operations may fail."
    }

    Write-Verbose "VMware Helper initialized. vmrun: $($Config.VMRunPath)"
}

function Invoke-VMRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 600,
        [switch]$NoThrow
    )

    $vmrun = $Script:VMwareConfig.VMRunPath

    Write-Verbose "vmrun $($Arguments -join ' ')"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $vmrun
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    # ArgumentList (PS7+/.NET5+) passes each element as a discrete argument,
    # preserving spaces without manual quoting.  Fall back to a quoted join on PS5.
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    } else {
        # PS 5.x: quote any argument that contains a space and isn't already quoted
        $quoted = $Arguments | ForEach-Object {
            if ($_ -match '\s' -and $_ -notmatch '^".*"$') { "`"$_`"" } else { $_ }
        }
        $psi.Arguments = $quoted -join ' '
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "vmrun timed out after $TimeoutSeconds seconds"
    }

    $result = @{
        ExitCode = $process.ExitCode
        StdOut   = $stdout.Trim()
        StdErr   = $stderr.Trim()
    }

    if ($result.ExitCode -ne 0 -and -not $NoThrow) {
        throw "vmrun failed (exit $($result.ExitCode)): $($result.StdErr) $($result.StdOut)"
    }

    return $result
}

function New-LabVM {
    <#
    .SYNOPSIS
        Creates a new VM by generating VMX file directly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$CPUs = 2,
        [int]$MemoryMB = 4096,
        [int]$DiskGB = 60,
        [string]$NetworkType = "nat",
        [string]$ISOPath,
        [string]$GuestOS = "windows2019srvnext-64"  # VMware guest OS identifier (WS 2022 in VMware 17)
    )

    $vmFolder = Join-Path $Script:VMwareConfig.DefaultVMFolder $VMName
    $vmxPath = Join-Path $vmFolder "$VMName.vmx"
    $vmdkPath = Join-Path $vmFolder "$VMName.vmdk"

    if (Test-Path $vmFolder) {
        Write-Warning "VM folder already exists: $vmFolder"
        return $vmxPath
    }

    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

    # Create virtual disk
    $vdiskMgr = Join-Path (Split-Path $Script:VMwareConfig.VMRunPath) "vmware-vdiskmanager.exe"

    Write-Host "Creating virtual disk: $vmdkPath ($DiskGB GB)" -ForegroundColor Cyan
    & $vdiskMgr -c -s "${DiskGB}GB" -a lsilogic -t 0 $vmdkPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create virtual disk" }

    # Generate VMX content
    $vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "$VMName"
guestOS = "$GuestOS"

# CPU
numvcpus = "$CPUs"
cpuid.coresPerSocket = "$CPUs"

# Memory
memsize = "$MemoryMB"

# PCIe bridges (required for e1000e and vmxnet3 on hardware version 19)
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"

# Disk (SATA - natively detected by all Windows installers without extra drivers)
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "$VMName.vmdk"

# CD/DVD
ide1:0.present = "TRUE"
ide1:0.deviceType = "cdrom-image"
ide1:0.fileName = "$ISOPath"
ide1:0.startConnected = "TRUE"

# Network
ethernet0.present = "TRUE"
ethernet0.connectionType = "$NetworkType"
ethernet0.virtualDev = "e1000e"
ethernet0.addressType = "generated"
ethernet0.startConnected = "TRUE"

# Floppy (disabled)
floppy0.present = "FALSE"

# Boot
bios.bootOrder = "cdrom,hdd"
bios.hddOrder = "sata0:0"
bios.bootDelay = "3000"

# VMware Tools
tools.syncTime = "TRUE"
tools.upgrade.policy = "manual"

# Other
powerType.powerOff = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"

# Firmware (BIOS for compatibility; use "efi" for UEFI)
firmware = "bios"

# Shared folders for file transfer
sharedFolder.option = "alwaysEnabled"
sharedFolder.maxNum = "1"
sharedFolder0.present = "TRUE"
sharedFolder0.enabled = "TRUE"
sharedFolder0.readAccess = "TRUE"
sharedFolder0.writeAccess = "FALSE"
sharedFolder0.hostPath = "$($Script:VMwareConfig.DefaultVMFolder -replace '\\','\\')\\_SharedFiles"
sharedFolder0.guestName = "LabShare"
sharedFolder0.expiration = "never"
isolation.tools.hgfs.disable = "FALSE"

# Enable VNC for remote console (optional)
# RemoteDisplay.vnc.enabled = "TRUE"
# RemoteDisplay.vnc.port = "5900"
"@

    Set-Content -Path $vmxPath -Value $vmxContent -Encoding UTF8
    Write-Host "Created VM: $vmxPath" -ForegroundColor Green

    return $vmxPath
}

function New-LabVMFromTemplate {
    <#
    .SYNOPSIS
        Clones a VM from a template (linked or full clone)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplateVMXPath,
        [Parameter(Mandatory)][string]$NewVMName,
        [ValidateSet("full", "linked")][string]$CloneType = "full",
        [string]$SnapshotName = "CleanInstall"
    )

    $vmFolder = Join-Path $Script:VMwareConfig.DefaultVMFolder $NewVMName
    $newVMXPath = Join-Path $vmFolder "$NewVMName.vmx"

    if (Test-Path $newVMXPath) {
        Write-Warning "VM '$NewVMName' already exists at $newVMXPath - skipping clone"
        return $newVMXPath
    }

    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

    Write-Host "Cloning VM '$NewVMName' from template (${CloneType})..." -ForegroundColor Cyan

    $vmrunArgs = @(
        "clone"
        "`"$TemplateVMXPath`""
        "`"$newVMXPath`""
        $CloneType
    )

    if ($SnapshotName) {
        $vmrunArgs += "-snapshot=`"$SnapshotName`""
    }

    $vmrunArgs += "-cloneName=`"$NewVMName`""

    Invoke-VMRun -Arguments $vmrunArgs -TimeoutSeconds 1200 | Out-Null

    # Update VM display name
    $vmxContent = Get-Content $newVMXPath -Raw
    $vmxContent = $vmxContent -replace 'displayName = ".*"', "displayName = `"$NewVMName`""
    Set-Content -Path $newVMXPath -Value $vmxContent

    Write-Host "Clone complete: $newVMXPath" -ForegroundColor Green
    return $newVMXPath
}

function Start-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [switch]$NoGUI
    )

    $guiMode = if ($NoGUI) { "nogui" } else { "gui" }
    Write-Host "Starting VM: $(Split-Path $VMXPath -Leaf) [$guiMode]" -ForegroundColor Cyan
    Invoke-VMRun -Arguments @("start", "`"$VMXPath`"", $guiMode)
}

function Stop-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [switch]$Hard
    )

    $mode = if ($Hard) { "hard" } else { "soft" }
    Write-Host "Stopping VM: $(Split-Path $VMXPath -Leaf) [$mode]" -ForegroundColor Yellow
    Invoke-VMRun -Arguments @("stop", "`"$VMXPath`"", $mode) -NoThrow
}

function Restart-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [switch]$Hard
    )

    $mode = if ($Hard) { "hard" } else { "soft" }
    Invoke-VMRun -Arguments @("reset", "`"$VMXPath`"", $mode)
}

function New-LabVMSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    Write-Host "Creating snapshot '$SnapshotName'..." -ForegroundColor Cyan
    Invoke-VMRun -Arguments @("snapshot", "`"$VMXPath`"", "`"$SnapshotName`"")
}

function Restore-LabVMSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    Write-Host "Reverting to snapshot '$SnapshotName'..." -ForegroundColor Yellow
    Invoke-VMRun -Arguments @("revertToSnapshot", "`"$VMXPath`"", "`"$SnapshotName`"")
}

function Remove-AllLabVMSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [string]$VMName = ""
    )

    $label = if ($VMName) { $VMName } else { Split-Path (Split-Path $VMXPath) -Leaf }

    $vmrun = $Script:VMwareConfig.VMRunPath
    $result = & $vmrun "listSnapshots" "`"$VMXPath`"" 2>&1
    $lines  = ($result -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^Total snapshots' }

    if ($lines.Count -eq 0) {
        Write-Host "  $label`: no snapshots" -ForegroundColor DarkGray
        return
    }

    foreach ($snap in $lines) {
        Write-Host "  $label`: removing snapshot '$snap'..." -ForegroundColor DarkGray
        & $vmrun "deleteSnapshot" "`"$VMXPath`"" "`"$snap`"" | Out-Null
    }
    Write-Host "  $label`: $($lines.Count) snapshot(s) removed" -ForegroundColor Green
}

function Get-LabVMIPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [int]$TimeoutSeconds = 300
    )

    $elapsed = 0
    $interval = 10

    while ($elapsed -lt $TimeoutSeconds) {
        $result = Invoke-VMRun -Arguments @("getGuestIPAddress", "`"$VMXPath`"", "-wait") -NoThrow -TimeoutSeconds 30

        if ($result.ExitCode -eq 0 -and $result.StdOut -match '\d+\.\d+\.\d+\.\d+') {
            return $result.StdOut.Trim()
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
        Write-Verbose "Waiting for IP address... ($elapsed/$TimeoutSeconds)"
    }

    Write-Warning "Could not get IP address within $TimeoutSeconds seconds"
    return $null
}

function Wait-LabVMReady {
    <#
    .SYNOPSIS
        Waits for VM to be fully booted and VMware Tools running.
    .NOTES
        When GuestUser/GuestPassword are supplied the check uses runProgramInGuest
        (VGAuth over VMCI kernel socket) which works for VMs not yet registered in
        the Workstation GUI library.  Without credentials the fallback is
        getGuestIPAddress, which requires the VM to be in the Workstation inventory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [int]$TimeoutSeconds = 600,
        [string]$GuestUser = "",
        [string]$GuestPassword = ""
    )

    $useVGAuth = ($GuestUser -ne "") -and ($GuestPassword -ne "")

    Write-Host "Waiting for VM to be ready..." -ForegroundColor Cyan
    $elapsed = 0
    $interval = 15

    while ($elapsed -lt $TimeoutSeconds) {
        if ($useVGAuth) {
            # VGAuth communicates via the VMCI kernel socket inside VMware Tools.
            # It works regardless of whether the VM is in Workstation's inventory.
            $result = Invoke-VMRun -Arguments @(
                "-gu", $GuestUser,
                "-gp", $GuestPassword,
                "runProgramInGuest", "`"$VMXPath`"",
                "C:\Windows\System32\hostname.exe"
            ) -NoThrow -TimeoutSeconds 20

            if ($result.ExitCode -eq 0) {
                Write-Host "VM is ready (VGAuth OK)." -ForegroundColor Green
                return $true
            }
        } else {
            # Fallback: requires the VM to be registered in the Workstation library.
            $result = Invoke-VMRun -Arguments @(
                "getGuestIPAddress", "`"$VMXPath`""
            ) -NoThrow -TimeoutSeconds 20

            if ($result.ExitCode -eq 0 -and $result.StdOut -match '\d+\.\d+\.\d+\.\d+') {
                Write-Host "VM is ready. IP: $($result.StdOut.Trim())" -ForegroundColor Green
                return $true
            }
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
        Write-Host "  Still waiting... ($elapsed/$TimeoutSeconds sec)" -ForegroundColor DarkGray
    }

    throw "VM did not become ready within $TimeoutSeconds seconds"
}

function Copy-FileToLabVM {
    <#
    .SYNOPSIS
        Copy file from host to guest using vmrun
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    Write-Verbose "Copying '$HostPath' -> '$GuestPath'"
    Invoke-VMRun -Arguments @(
        "-gu", $GuestUser,
        "-gp", $GuestPassword,
        "copyFileFromHostToGuest",
        "`"$VMXPath`"",
        "`"$HostPath`"",
        "`"$GuestPath`""
    )
}

function Copy-FileFromLabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    Invoke-VMRun -Arguments @(
        "-gu", $GuestUser,
        "-gp", $GuestPassword,
        "copyFileFromGuestToHost",
        "`"$VMXPath`"",
        "`"$GuestPath`"",
        "`"$HostPath`""
    )
}

function Invoke-LabVMScript {
    <#
    .SYNOPSIS
        Execute a script inside the guest VM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [ValidateSet("PowerShell", "Cmd", "Bat")]
        [string]$ScriptType = "PowerShell",
        [switch]$Interactive,
        [switch]$NoWait,
        [switch]$NoThrow
    )

    # Write script to temp file on host
    $extension = switch ($ScriptType) {
        "PowerShell" { ".ps1" }
        "Cmd"        { ".cmd" }
        "Bat"        { ".bat" }
    }

    $tempHostPath = Join-Path $env:TEMP "labscript_$(Get-Random)$extension"
    $tempGuestPath = "C:\Windows\Temp\labscript_$(Get-Random)$extension"

    Set-Content -Path $tempHostPath -Value $ScriptText -Encoding UTF8

    try {
        # Copy script to guest (suppress return value — caller only needs the run result)
        Copy-FileToLabVM -VMXPath $VMXPath -HostPath $tempHostPath `
            -GuestPath $tempGuestPath -GuestUser $GuestUser -GuestPassword $GuestPassword | Out-Null

        # Determine interpreter and its arguments as discrete array elements
        $interpreter = switch ($ScriptType) {
            "PowerShell" { "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" }
            "Cmd"        { "C:\Windows\System32\cmd.exe" }
            "Bat"        { "C:\Windows\System32\cmd.exe" }
        }

        $interpreterArgs = switch ($ScriptType) {
            "PowerShell" { @("-ExecutionPolicy", "Bypass", "-NonInteractive", "-File", $tempGuestPath) }
            "Cmd"        { @("/c", $tempGuestPath) }
            "Bat"        { @("/c", $tempGuestPath) }
        }

        $runCommand = if ($Interactive) { "runScriptInGuest" } else { "runProgramInGuest" }

        $vmrunArgs = @(
            "-gu", $GuestUser,
            "-gp", $GuestPassword,
            $runCommand,
            "`"$VMXPath`""
        )

        if ($NoWait)    { $vmrunArgs += "-noWait" }
        if ($Interactive) { $vmrunArgs += "-activeWindow" }

        $vmrunArgs += $interpreter
        $vmrunArgs += $interpreterArgs

        $result = Invoke-VMRun -Arguments $vmrunArgs -TimeoutSeconds 3600 -NoThrow:$NoThrow

        return $result
    }
    finally {
        Remove-Item $tempHostPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LabVMPowerShell {
    <#
    .SYNOPSIS
        Convenience wrapper for running PowerShell in guest
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$ScriptBlock,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [switch]$NoWait,
        [switch]$NoThrow
    )

    # Wrap script block with error handling and logging
    $wrappedScript = @"
`$ErrorActionPreference = 'Stop'
`$logFile = "C:\LabSetup\Logs\script_`$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
# Ensure both C:\LabSetup and C:\LabSetup\Logs exist before Start-Transcript
New-Item -Path 'C:\LabSetup'      -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path 'C:\LabSetup\Logs' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
# Non-fatal: if transcript can't start (e.g. session policy), continue anyway
Start-Transcript -Path `$logFile -Append -ErrorAction SilentlyContinue

try {
    $ScriptBlock
    Write-Host "Script completed successfully"
}
catch {
    Write-Error `$_.Exception.Message
    `$_ | Out-File "C:\LabSetup\Logs\error_`$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    throw
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
"@

    Invoke-LabVMScript -VMXPath $VMXPath -ScriptText $wrappedScript `
        -GuestUser $GuestUser -GuestPassword $GuestPassword `
        -ScriptType PowerShell -NoWait:$NoWait -NoThrow:$NoThrow
}

function Test-LabVMSetupComplete {
    <#
    .SYNOPSIS
        Returns $true when Windows setup/OOBE has completed inside the guest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    $checkScript = @'
$oobe = (Get-ItemProperty -Path "HKLM:\SYSTEM\Setup" -ErrorAction SilentlyContinue)
$state = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue)

$oobeInProgress = if ($null -ne $oobe) { [int]$oobe.OOBEInProgress } else { 0 }
$systemSetupInProgress = if ($null -ne $oobe) { [int]$oobe.SystemSetupInProgress } else { 0 }
$imageState = if ($null -ne $state) { [string]$state.ImageState } else { "" }

if ($oobeInProgress -eq 0 -and $systemSetupInProgress -eq 0 -and $imageState -eq 'IMAGE_STATE_COMPLETE') {
    exit 0
}

Write-Output "OOBEInProgress=$oobeInProgress SystemSetupInProgress=$systemSetupInProgress ImageState=$imageState"
exit 1
'@

    $result = Invoke-LabVMScript -VMXPath $VMXPath -ScriptText $checkScript `
        -GuestUser $GuestUser -GuestPassword $GuestPassword `
        -ScriptType PowerShell -NoThrow

    return ($result.ExitCode -eq 0)
}

function Wait-LabVMSetupComplete {
    <#
    .SYNOPSIS
        Waits until Windows setup/OOBE has completed inside the guest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [int]$TimeoutSeconds = 900
    )

    $elapsed = 0
    $interval = 15

    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-LabVMSetupComplete -VMXPath $VMXPath -GuestUser $GuestUser -GuestPassword $GuestPassword) {
            Write-Host "Windows setup/OOBE is complete." -ForegroundColor Green
            return $true
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
        Write-Host "  Waiting for Windows setup to finish... ($elapsed/$TimeoutSeconds sec)" -ForegroundColor DarkGray
    }

    throw "Windows setup/OOBE did not complete within $TimeoutSeconds seconds"
}

function Get-RunningLabVMs {
    $result = Invoke-VMRun -Arguments @("list") -NoThrow
    if ($result.ExitCode -eq 0) {
        $lines = $result.StdOut -split "`n" | Where-Object { $_ -match '\.vmx$' }
        return $lines
    }
    return @()
}

function Set-LabVMNetwork {
    <#
    .SYNOPSIS
        Modify VMX network settings (requires VM to be off)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [string]$ConnectionType = "nat",
        [string]$VNetName
    )

    $content = Get-Content $VMXPath

    # Update connection type
    $content = $content | ForEach-Object {
        if ($_ -match '^ethernet0\.connectionType') {
            "ethernet0.connectionType = `"$ConnectionType`""
        }
        elseif ($VNetName -and $_ -match '^ethernet0\.vnet') {
            "ethernet0.vnet = `"$VNetName`""
        }
        else { $_ }
    }

    if ($VNetName -and ($content -notmatch 'ethernet0\.vnet')) {
        $content += "ethernet0.vnet = `"$VNetName`""
    }

    Set-Content -Path $VMXPath -Value $content
}

function Add-LabVMDisk {
    <#
    .SYNOPSIS
        Add an additional virtual disk to a VM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][int]$DiskGB,
        [string]$BusType = "scsi0",
        [int]$UnitNumber = 1
    )

    $vmFolder = Split-Path $VMXPath
    $vmName = [System.IO.Path]::GetFileNameWithoutExtension($VMXPath)
    $vmdkPath = Join-Path $vmFolder "${vmName}_disk${UnitNumber}.vmdk"

    # Create disk
    $vdiskMgr = Join-Path (Split-Path $Script:VMwareConfig.VMRunPath) "vmware-vdiskmanager.exe"
    & $vdiskMgr -c -s "${DiskGB}GB" -a lsilogic -t 0 $vmdkPath

    # Add to VMX
    $vmxAddition = @"

${BusType}:${UnitNumber}.present = "TRUE"
${BusType}:${UnitNumber}.fileName = "$([System.IO.Path]::GetFileName($vmdkPath))"
"@

    Add-Content -Path $VMXPath -Value $vmxAddition
}

Export-ModuleMember -Function *
