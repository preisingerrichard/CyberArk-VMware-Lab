<#
.SYNOPSIS
    Deploy all lab VMs by cloning from the template
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$templateVMX = Join-Path $Config.VMware.DefaultVMFolder "$($Config.VMware.TemplateName)\$($Config.VMware.TemplateName).vmx"

if (-not (Test-Path $templateVMX)) {
    throw "Template VM not found. Run 01-CreateBaseVM.ps1 first."
}

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Deploying Lab VMs from Template" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# Track deployed VMs
$deployedVMs = @{}

foreach ($vm in $Config.VMs) {
    Write-Host "`n--- Deploying: $($vm.Name) ($($vm.Description)) ---" -ForegroundColor Yellow

    # Clone from template
    $vmxPath = New-LabVMFromTemplate `
        -TemplateVMXPath $templateVMX `
        -NewVMName $vm.Name `
        -CloneType "full" `
        -SnapshotName "CleanInstall"

    # Adjust resources
    $vmxContent = Get-Content $vmxPath
    $vmxContent = $vmxContent | ForEach-Object {
        if ($_ -match '^numvcpus') { "numvcpus = `"$($vm.CPUs)`"" }
        elseif ($_ -match '^cpuid\.coresPerSocket') { "cpuid.coresPerSocket = `"$($vm.CPUs)`"" }
        elseif ($_ -match '^memsize') { "memsize = `"$($vm.MemoryMB)`"" }
        else { $_ }
    }
    Set-Content -Path $vmxPath -Value $vmxContent

    # Start VM
    Start-LabVM -VMXPath $vmxPath -NoGUI
    $deployedVMs[$vm.Name] = $vmxPath

    Write-Host "Started: $($vm.Name)" -ForegroundColor Green
}

# Wait for all VMs to be ready
Write-Host "`nWaiting for all VMs to boot..." -ForegroundColor Cyan
foreach ($vm in $Config.VMs) {
    $vmxPath = $deployedVMs[$vm.Name]
    Wait-LabVMReady -VMXPath $vmxPath -TimeoutSeconds 600 `
        -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password
}

# Configure each VM
foreach ($vm in $Config.VMs) {
    $vmxPath = $deployedVMs[$vm.Name]
    Write-Host "`nConfiguring: $($vm.Name)" -ForegroundColor Yellow

    # Set computer name
    Set-GuestComputerName -VMXPath $vmxPath -ComputerName $vm.Name `
        -GuestUser $Config.LocalAdmin.Username `
        -GuestPassword $Config.LocalAdmin.Password

    # Set static IP
    Set-GuestStaticIP -VMXPath $vmxPath `
        -IPAddress $vm.IPAddress `
        -SubnetMask $Config.Network.SubnetMask `
        -Gateway $Config.Network.Gateway `
        -DNS $Config.Network.DNS `
        -GuestUser $Config.LocalAdmin.Username `
        -GuestPassword $Config.LocalAdmin.Password

    # Enable WinRM
    Enable-GuestWinRM -VMXPath $vmxPath `
        -GuestUser $Config.LocalAdmin.Username `
        -GuestPassword $Config.LocalAdmin.Password

    # Disable firewall (lab only!)
    Disable-GuestFirewall -VMXPath $vmxPath `
        -GuestUser $Config.LocalAdmin.Username `
        -GuestPassword $Config.LocalAdmin.Password

    Write-Host "  Rebooting $($vm.Name) for hostname change..." -ForegroundColor DarkGray
    Restart-LabVM -VMXPath $vmxPath
}

# Wait for all reboots
Start-Sleep -Seconds 30
foreach ($vm in $Config.VMs) {
    Wait-LabVMReady -VMXPath $deployedVMs[$vm.Name] -TimeoutSeconds 300 `
        -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password
}

# Sysprep non-DC VMs to generate unique machine SIDs.
# Cloning from a template causes every clone to share the template's machine SID.
# When DC01 is promoted, the domain SID is derived from its (template) machine SID.
# COMP01/VAULT01 (also cloned from that template) then have the same SID as the domain,
# which causes Add-Computer to fail with "SID of the domain identical to the SID of this machine".
$sysprepVMs = $Config.VMs | Where-Object {
    $roles = if ($_.Role -is [System.Array]) { $_.Role } else { @($_.Role) }
    -not ($roles -contains "DomainController")
}

if ($sysprepVMs) {
    Write-Host "`nSysprepping non-DC VMs to generate unique machine SIDs..." -ForegroundColor Cyan

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    foreach ($vm in $sysprepVMs) {
        $vmxPath = $deployedVMs[$vm.Name]
        Write-Host "  Launching sysprep on $($vm.Name)..." -ForegroundColor Yellow

        # Minimal sysprep unattend: sets hostname and admin password for OOBE.
        # Network, WinRM, and firewall are re-applied from the host after OOBE completes.
        $sysprepUnattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <ComputerName>$($vm.Name)</ComputerName>
            <TimeZone>UTC</TimeZone>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$($Config.LocalAdmin.Password)</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>5</LogonCount>
                <Username>Administrator</Username>
                <Password>
                    <Value>$($Config.LocalAdmin.Password)</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -Command "Set-ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue"</CommandLine>
                    <Description>Set Execution Policy</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>powershell.exe -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"</CommandLine>
                    <Description>Enable WinRM</Description>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
"@

        $localUnattendPath = Join-Path $env:TEMP "sysprep_$($vm.Name)_$(Get-Random).xml"
        [System.IO.File]::WriteAllText($localUnattendPath, $sysprepUnattend, $utf8NoBom)

        try {
            Copy-FileToLabVM -VMXPath $vmxPath `
                -HostPath $localUnattendPath `
                -GuestPath 'C:\Windows\System32\Sysprep\sysprep_unattend.xml' `
                -GuestUser $Config.LocalAdmin.Username `
                -GuestPassword $Config.LocalAdmin.Password

            # Use /shutdown (not /reboot) so the VM powers off cleanly.
            # The host then calls Start-LabVM so vmrun owns the next boot event,
            # which is required for getGuestIPAddress / VGAuth to work reliably.
            # -noWait returns immediately; sysprep runs and shuts the VM down on its own.
            Invoke-VMRun -Arguments @(
                "-gu", $Config.LocalAdmin.Username,
                "-gp", $Config.LocalAdmin.Password,
                "runProgramInGuest", "`"$vmxPath`"",
                "-noWait",
                "C:\Windows\System32\Sysprep\sysprep.exe",
                "/generalize", "/oobe", "/shutdown",
                "/unattend:C:\Windows\System32\Sysprep\sysprep_unattend.xml"
            ) -NoThrow -TimeoutSeconds 30
        } finally {
            Remove-Item $localUnattendPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Sysprep /generalize on Windows Server 2022 typically takes 3-5 minutes.
    # All VMs are generalizing in parallel, so one wait covers all of them.
    Write-Host "`nWaiting for sysprep to complete generalize (5 minutes)..." -ForegroundColor Cyan
    Start-Sleep -Seconds 300

    foreach ($vm in $sysprepVMs) {
        $vmxPath = $deployedVMs[$vm.Name]

        # Boot the VM now that sysprep has shut it down.
        # vmrun owns this start event, so getGuestIPAddress and VGAuth work correctly.
        Write-Host "  Starting $($vm.Name) for OOBE..." -ForegroundColor Yellow
        Start-LabVM -VMXPath $vmxPath -NoGUI

        Write-Host "  Waiting for $($vm.Name) to complete OOBE..." -ForegroundColor DarkGray
        Wait-LabVMReady -VMXPath $vmxPath -TimeoutSeconds 900 `
            -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password
        Wait-LabVMSetupComplete -VMXPath $vmxPath -TimeoutSeconds 900 `
            -GuestUser $Config.LocalAdmin.Username -GuestPassword $Config.LocalAdmin.Password
        Write-Host "  $($vm.Name) back online - re-applying network config..." -ForegroundColor DarkGray

        # Re-apply static IP, WinRM, and firewall: sysprep OOBE can reset DHCP on
        # the adapter even though registry-based static config usually survives.
        Set-GuestStaticIP -VMXPath $vmxPath `
            -IPAddress $vm.IPAddress `
            -SubnetMask $Config.Network.SubnetMask `
            -Gateway $Config.Network.Gateway `
            -DNS $Config.Network.DNS `
            -GuestUser $Config.LocalAdmin.Username `
            -GuestPassword $Config.LocalAdmin.Password

        Enable-GuestWinRM -VMXPath $vmxPath `
            -GuestUser $Config.LocalAdmin.Username `
            -GuestPassword $Config.LocalAdmin.Password

        Disable-GuestFirewall -VMXPath $vmxPath `
            -GuestUser $Config.LocalAdmin.Username `
            -GuestPassword $Config.LocalAdmin.Password

        Write-Host "  $($vm.Name) sysprep complete." -ForegroundColor Green
    }
}

# Snapshot all VMs
foreach ($vm in $Config.VMs) {
    Stop-LabVM -VMXPath $deployedVMs[$vm.Name]
    Start-Sleep -Seconds 10
    New-LabVMSnapshot -VMXPath $deployedVMs[$vm.Name] -SnapshotName "Configured-PreDomain"
    Start-LabVM -VMXPath $deployedVMs[$vm.Name] -NoGUI
}

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "All VMs deployed and configured!" -ForegroundColor Green
$deployedVMs.GetEnumerator() | ForEach-Object {
    $vmName = $_.Key
    $vmConfig = $Config.VMs | Where-Object { $_.Name -eq $vmName }
    Write-Host "  $vmName -> $($vmConfig.IPAddress)" -ForegroundColor Green
}
Write-Host $("=" * 60) -ForegroundColor Green

# Save VM paths for subsequent scripts
$deployedVMs | Export-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"
