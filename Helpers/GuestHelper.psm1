#Requires -Version 5.1

<#
.SYNOPSIS
    Helper functions for configuring Windows inside guest VMs
    Uses vmrun-based execution from VMwareHelper
#>

Import-Module "$PSScriptRoot\RemotingHelper.psm1" -Force

function Set-GuestStaticIP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$SubnetMask,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string]$DNS,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    $script = @"
# Find the active Ethernet adapter
`$adapter = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' -and `$_.Name -like '*Ethernet*' } | Select-Object -First 1
if (-not `$adapter) { `$adapter = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1 }

Write-Host "Configuring adapter: `$(`$adapter.Name)"

# Remove existing IP config
Remove-NetIPAddress -InterfaceIndex `$adapter.ifIndex -Confirm:`$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex `$adapter.ifIndex -Confirm:`$false -ErrorAction SilentlyContinue

# Set static IP
New-NetIPAddress -InterfaceIndex `$adapter.ifIndex ``
    -IPAddress '$IPAddress' ``
    -PrefixLength $(Convert-SubnetMaskToPrefix $SubnetMask) ``
    -DefaultGateway '$Gateway'

# Set DNS
Set-DnsClientServerAddress -InterfaceIndex `$adapter.ifIndex ``
    -ServerAddresses @('$DNS')

Write-Host "Network configured: $IPAddress"
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Convert-SubnetMaskToPrefix {
    param([string]$SubnetMask)

    $octets = $SubnetMask.Split('.')
    $binary = ($octets | ForEach-Object { [Convert]::ToString([int]$_, 2) }) -join ''
    return ($binary.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Set-GuestComputerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [switch]$Restart
    )

    $restartFlag = if ($Restart) { "-Restart" } else { "" }

    $script = @"
Rename-Computer -NewName '$ComputerName' $restartFlag -Force
Write-Host "Computer renamed to $ComputerName"
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Install-GuestWindowsFeature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string[]]$FeatureNames,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [switch]$IncludeManagementTools
    )

    $features = $FeatureNames -join "','"
    $mgmt = if ($IncludeManagementTools) { "-IncludeManagementTools" } else { "" }

    $script = @"
Install-WindowsFeature -Name @('$features') $mgmt -Verbose
Write-Host "Features installed: $features"
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Copy-FolderToGuest {
    <#
    .SYNOPSIS
        Recursively copy a folder to guest (vmrun only supports single files)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$HostFolder,
        [Parameter(Mandatory)][string]$GuestFolder,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    $guestIp = Get-LabVMIPAddress -VMXPath $VMXPath -TimeoutSeconds 120
    if (-not $guestIp) {
        throw "Could not determine guest IP for file copy."
    }

    $session = $null
    try {
        $session = New-LabSession -ComputerName $guestIp -Username $GuestUser -Password $GuestPassword
        Invoke-Command -Session $session -ScriptBlock {
            param($TargetPath)
            New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
        } -ArgumentList $GuestFolder

        Copy-Item -Path (Join-Path $HostFolder '*') -Destination $GuestFolder -ToSession $session -Force -Recurse
    }
    finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Wait-GuestReboot {
    <#
    .SYNOPSIS
        Wait for a VM to reboot and come back online
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [int]$TimeoutSeconds = 600
    )

    Write-Host "Waiting for VM reboot..." -ForegroundColor Cyan

    # Wait for VM to go down
    Start-Sleep -Seconds 15

    # Wait for VM to come back
    Wait-LabVMReady -VMXPath $VMXPath -TimeoutSeconds $TimeoutSeconds

    # Extra settle time for Windows services
    Start-Sleep -Seconds 30
}

function Enable-GuestWinRM {
    <#
    .SYNOPSIS
        Enable WinRM in guest for PowerShell remoting (alternative to vmrun)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    $script = @"
# Enable WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Configure WinRM for lab use
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
Set-Item WSMan:\localhost\Service\Auth\Basic -Value `$true
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value `$true

# Configure firewall
New-NetFirewallRule -DisplayName 'WinRM-HTTP' -Direction Inbound ``
    -LocalPort 5985 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinRM-HTTPS' -Direction Inbound ``
    -LocalPort 5986 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# Restart WinRM
Restart-Service WinRM

Write-Host "WinRM enabled and configured"
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Disable-GuestFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword
    )

    $script = @"
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Host "Firewall disabled on all profiles"
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

Export-ModuleMember -Function *
