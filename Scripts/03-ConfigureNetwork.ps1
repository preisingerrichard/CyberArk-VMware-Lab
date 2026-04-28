<#
.SYNOPSIS
    Configure static IP addresses on all lab VMs
.DESCRIPTION
    Sets static IP, subnet mask, gateway, and DNS on each VM after
    initial Windows install. Runs after 02-DeployVMs.ps1.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1"  -Force
Import-Module "$PSScriptRoot\..\Helpers\NetworkHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"

$subnetInfo = Get-LabNetworkSubnet -CIDRSubnet $Config.Network.Subnet
$subnetMask = $Config.Network.SubnetMask
$gateway    = $Config.Network.Gateway
$dns        = $Config.Network.DNS

$localUser = $Config.LocalAdmin.Username
$localPass = $Config.LocalAdmin.Password

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Configuring static IP addresses" -ForegroundColor Cyan
Write-Host "  Subnet : $($Config.Network.Subnet)" -ForegroundColor Cyan
Write-Host "  Gateway: $gateway" -ForegroundColor Cyan
Write-Host "  DNS    : $dns" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

foreach ($vm in $Config.VMs) {
    $vmxPath = $deployedVMs[$vm.Name]
    if (-not $vmxPath) {
        Write-Warning "No VMX path found for $($vm.Name) — skipping"
        continue
    }

    Write-Host "`n[$($vm.Name)] Configuring IP $($vm.IPAddress)..." -ForegroundColor Yellow

    Wait-LabVMReady -VMXPath $vmxPath -TimeoutSeconds 300

    $ipScript = @"
`$ErrorActionPreference = 'Stop'

# Find active adapter
`$adapter = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1
if (-not `$adapter) { throw "No active network adapter found" }

Write-Host "Configuring adapter: `$(`$adapter.Name) (index `$(`$adapter.ifIndex))"

# Clear existing configuration
`$existing = Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (`$existing) {
    Remove-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -Confirm:`$false -ErrorAction SilentlyContinue
}
Remove-NetRoute -InterfaceIndex `$adapter.ifIndex -Confirm:`$false -ErrorAction SilentlyContinue

# Apply static IP
New-NetIPAddress ``
    -InterfaceIndex `$adapter.ifIndex ``
    -IPAddress '$($vm.IPAddress)' ``
    -PrefixLength $($subnetInfo.PrefixLength) ``
    -DefaultGateway '$gateway'

# Apply DNS
Set-DnsClientServerAddress ``
    -InterfaceIndex `$adapter.ifIndex ``
    -ServerAddresses @('$dns')

# Set adapter description for clarity
# Rename-NetAdapter -Name `$adapter.Name -NewName 'Lab' -ErrorAction SilentlyContinue

Write-Host "IP configured: $($vm.IPAddress) / $subnetMask" -ForegroundColor Green
Write-Host "Gateway: $gateway"
Write-Host "DNS: $dns"

# Verify
`$cfg = Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4
Write-Host "Verified: `$(`$cfg.IPAddress)/`$(`$cfg.PrefixLength)"
"@

    Invoke-LabVMPowerShell -VMXPath $vmxPath -ScriptBlock $ipScript `
        -GuestUser $localUser -GuestPassword $localPass

    Write-Host "  [$($vm.Name)] Static IP set to $($vm.IPAddress)" -ForegroundColor Green

    # Brief wait for network to settle
    Start-Sleep -Seconds 5
}

# ================================================================
# Verify connectivity after IP configuration
# ================================================================
Write-Host "`nVerifying connectivity from host to lab VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

foreach ($vm in $Config.VMs) {
    $reachable = Test-Connection -ComputerName $vm.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
    $status = if ($reachable) { "[OK]" } else { "[WARN]" }
    $color  = if ($reachable) { "Green" } else { "Yellow" }
    Write-Host "  $status $($vm.Name) ($($vm.IPAddress))" -ForegroundColor $color
}

Write-Host "`nNetwork configuration complete." -ForegroundColor Green
Write-Host "DNS server will be the DC ($dns) once the DC is promoted." -ForegroundColor DarkGray
