#Requires -Version 5.1

<#
.SYNOPSIS
    Network helper functions for VMware lab environment
.DESCRIPTION
    Manages VMware virtual network (VMnet) configuration,
    validates connectivity, and performs network-related tasks.
#>

function Get-VMNetConfig {
    <#
    .SYNOPSIS
        Read VMware virtual network configuration from registry
    #>
    [CmdletBinding()]
    param(
        [string]$VMNetName = "VMnet8"
    )

    $key = "HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig\$VMNetName"
    if (-not (Test-Path $key)) {
        $key = "HKLM:\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig\$VMNetName"
    }

    if (Test-Path $key) {
        return Get-ItemProperty $key
    }

    Write-Warning "VMnet config not found for $VMNetName"
    return $null
}

function Test-VMNetExists {
    [CmdletBinding()]
    param(
        [string]$VMNetName
    )

    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Description -like "*VMware*$VMNetName*" -or $_.Name -like "*$VMNetName*" }

    return ($null -ne $adapter)
}

function Get-LabNetworkSubnet {
    <#
    .SYNOPSIS
        Parse subnet address and prefix length from CIDR notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CIDRSubnet   # e.g. "192.168.100.0/24"
    )

    $parts = $CIDRSubnet.Split('/')
    return @{
        NetworkAddress = $parts[0]
        PrefixLength   = [int]$parts[1]
        SubnetMask     = ConvertFrom-PrefixLength -PrefixLength ([int]$parts[1])
    }
}

function ConvertFrom-PrefixLength {
    [CmdletBinding()]
    param([int]$PrefixLength)

    $binary = ('1' * $PrefixLength).PadRight(32, '0')
    $octets = for ($i = 0; $i -lt 32; $i += 8) {
        [Convert]::ToInt32($binary.Substring($i, 8), 2)
    }
    return $octets -join '.'
}

function Test-LabConnectivity {
    <#
    .SYNOPSIS
        Test network connectivity between lab components
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $results = @()
    $vms = $Config.VMs

    Write-Host "Testing lab network connectivity..." -ForegroundColor Cyan

    foreach ($vm in $vms) {
        $pingResult = Test-Connection -ComputerName $vm.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
        $results += @{
            Name      = $vm.Name
            IPAddress = $vm.IPAddress
            Ping      = $pingResult
        }

        $status = if ($pingResult) { "[OK]" } else { "[FAIL]" }
        $color  = if ($pingResult) { "Green" } else { "Red" }
        Write-Host "  $status $($vm.Name) ($($vm.IPAddress))" -ForegroundColor $color
    }

    return $results
}

function Test-PortOpen {
    <#
    .SYNOPSIS
        Test if a TCP port is open on a remote host
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($ComputerName, $Port, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)

        if ($wait) {
            $tcp.EndConnect($ar) | Out-Null
            $tcp.Close()
            return $true
        }
        else {
            $tcp.Close()
            return $false
        }
    }
    catch {
        return $false
    }
}

function Wait-PortOpen {
    <#
    .SYNOPSIS
        Wait until a port is reachable (poll until timeout)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 10
    )

    $elapsed = 0
    Write-Host "Waiting for $ComputerName`:$Port to become reachable..." -ForegroundColor Cyan

    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-PortOpen -ComputerName $ComputerName -Port $Port) {
            Write-Host "  Port $ComputerName`:$Port is open." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        Write-Host "  Still waiting... ($elapsed/$TimeoutSeconds sec)" -ForegroundColor DarkGray
    }

    Write-Warning "Port $ComputerName`:$Port did not open within $TimeoutSeconds seconds"
    return $false
}

function Get-LabDNSStatus {
    <#
    .SYNOPSIS
        Verify DNS resolution works for domain members
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $dns    = $Config.Network.DNS
    $domain = $Config.Domain.Name

    Write-Host "Checking DNS ($dns) for domain $domain..." -ForegroundColor Cyan

    if (-not (Test-PortOpen -ComputerName $dns -Port 53)) {
        Write-Warning "DNS server $dns port 53 not reachable"
        return $false
    }

    try {
        $result = Resolve-DnsName -Name $domain -Server $dns -ErrorAction Stop
        Write-Host "  Domain $domain resolved OK" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "DNS resolution failed for ${domain}: $_"
        return $false
    }
}

Export-ModuleMember -Function *
