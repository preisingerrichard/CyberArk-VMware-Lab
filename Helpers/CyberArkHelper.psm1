#Requires -Version 5.1

<#
.SYNOPSIS
    CyberArk-specific automation helpers
.DESCRIPTION
    Functions for managing CyberArk component configuration,
    credential file generation, and service account creation.
    Used by the installation scripts (06-11).
#>

function New-CyberArkCredFile {
    <#
    .SYNOPSIS
        Generate a CyberArk credential file via CreateCredFile.exe inside a guest VM
    .DESCRIPTION
        Several CyberArk components (CPM, PVWA, PSM) require a credential file
        that stores the Vault application user credentials in encrypted form.
        CreateCredFile.exe must run on the component machine itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,

        # Path to CreateCredFile.exe inside the guest
        [Parameter(Mandatory)][string]$UtilityPath,

        # Output .cred or .ini file path inside the guest
        [Parameter(Mandatory)][string]$OutputFilePath,

        # Vault application user credentials
        [Parameter(Mandatory)][string]$VaultUser,
        [Parameter(Mandatory)][string]$VaultUserPassword
    )

    $script = @"
`$ErrorActionPreference = 'Stop'

if (-not (Test-Path '$UtilityPath')) {
    throw "CreateCredFile.exe not found at: $UtilityPath"
}

# CreateCredFile syntax: CreateCredFile.exe <output> Password /Username <u> /Password <p> /AppType <type>
`$args = @(
    '$OutputFilePath',
    'Password',
    '/Username', '$VaultUser',
    '/Password', '$VaultUserPassword',
    '/AppType', 'AppPrv'
)

`$proc = Start-Process -FilePath '$UtilityPath' ``
    -ArgumentList `$args ``
    -Wait -PassThru -NoNewWindow

Write-Host "CreateCredFile exit code: `$(`$proc.ExitCode)"

if (`$proc.ExitCode -ne 0) {
    throw "CreateCredFile.exe failed with exit code `$(`$proc.ExitCode)"
}

if (Test-Path '$OutputFilePath') {
    Write-Host "Credential file created: $OutputFilePath" -ForegroundColor Green
} else {
    throw "Credential file was not created at: $OutputFilePath"
}
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function New-CyberArkDomainServiceAccounts {
    <#
    .SYNOPSIS
        Create CyberArk service accounts in Active Directory
    .DESCRIPTION
        Creates the standard CyberArk service accounts (CPM, PVWA, PSM)
        as domain users with password-never-expires.
        Must be run on the DC or via a domain-admin session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,    # DC01 vmx path
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [Parameter(Mandatory)][hashtable]$CAConfig,
        [Parameter(Mandatory)][string]$DomainDN    # e.g. DC=cyberark,DC=lab
    )

    $accounts = ($CAConfig.ServiceAccounts.Accounts | ForEach-Object {
        "`$accounts += @{ Name='$($_.Name)'; Desc='$($_.Description)' }"
    }) -join "`n"

    $script = @"
Import-Module ActiveDirectory -ErrorAction Stop

`$accounts = @()
$accounts

foreach (`$acct in `$accounts) {
    `$existing = Get-ADUser -Filter { SamAccountName -eq `$acct.Name } -ErrorAction SilentlyContinue
    if (`$existing) {
        Write-Host "  [EXISTS] `$(`$acct.Name)" -ForegroundColor DarkGray
        continue
    }

    `$secPass = ConvertTo-SecureString '$($CAConfig.ServiceAccounts.Password)' -AsPlainText -Force
    New-ADUser -Name `$acct.Name ``
        -SamAccountName `$acct.Name ``
        -UserPrincipalName "`$(`$acct.Name)@cyberark.lab" ``
        -Description `$acct.Desc ``
        -Path "CN=Users,$DomainDN" ``
        -AccountPassword `$secPass ``
        -Enabled `$true ``
        -PasswordNeverExpires `$true ``
        -CannotChangePassword `$true

    Write-Host "  [CREATED] `$(`$acct.Name)" -ForegroundColor Green
}
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Wait-CyberArkVaultReady {
    <#
    .SYNOPSIS
        Poll Vault port 1858 until accepting connections
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VaultAddress,
        [int]$VaultPort = 1858,
        [int]$TimeoutSeconds = 600,
        [int]$IntervalSeconds = 15
    )

    Write-Host "Waiting for CyberArk Vault at $VaultAddress`:$VaultPort..." -ForegroundColor Cyan

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $open = & {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($VaultAddress, $VaultPort, $null, $null)
                $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
                $tcp.Close()
                $ok
            }
            catch { $false }
        }

        if ($open) {
            Write-Host "  Vault is ready!" -ForegroundColor Green
            return $true
        }

        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        Write-Host "  Still waiting... ($elapsed/$TimeoutSeconds sec)" -ForegroundColor DarkGray
    }

    throw "Vault at $VaultAddress`:$VaultPort did not become ready within $TimeoutSeconds seconds"
}

function Get-CyberArkServiceStatus {
    <#
    .SYNOPSIS
        Retrieve CyberArk component service status from a guest VM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMXPath,
        [Parameter(Mandatory)][string]$GuestUser,
        [Parameter(Mandatory)][string]$GuestPassword,
        [ValidateSet("Vault","CPM","PVWA","PSM","All")]
        [string]$Component = "All"
    )

    $filterMap = @{
        Vault = "'PrivateArk*','CyberArk Password Vault*'"
        CPM   = "'CyberArk Password Manager*'"
        PVWA  = "'CyberArk Scheduled Tasks*','CyberArk IIS*'"
        PSM   = "'Cyber-Ark Privileged Session Manager*'"
        All   = "'PrivateArk*','CyberArk*','Cyber-Ark*'"
    }

    $filter = $filterMap[$Component]

    $script = @"
`$names = @($filter)
`$svcs = Get-Service | Where-Object {
    `$svcName = `$_.DisplayName
    `$names | Where-Object { `$svcName -like `$_ }
}

if (`$svcs) {
    `$svcs | Format-Table Name, DisplayName, Status -AutoSize
} else {
    Write-Warning "No CyberArk services found matching component: $Component"
}
"@

    Invoke-LabVMPowerShell -VMXPath $VMXPath -ScriptBlock $script `
        -GuestUser $GuestUser -GuestPassword $GuestPassword
}

function Test-CyberArkPVWA {
    <#
    .SYNOPSIS
        HTTP health check for PVWA web application
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PVWAAddress,
        [int]$Port = 443,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 15
    )

    $url = "https://$PVWAAddress/PasswordVault"
    Write-Host "Waiting for PVWA at $url..." -ForegroundColor Cyan

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing `
                -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -in @(200, 302)) {
                Write-Host "  PVWA is responding (HTTP $($response.StatusCode))!" -ForegroundColor Green
                return $true
            }
        }
        catch { }

        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        Write-Host "  Still waiting... ($elapsed/$TimeoutSeconds sec)" -ForegroundColor DarkGray
    }

    Write-Warning "PVWA at $url did not become reachable within $TimeoutSeconds seconds"
    return $false
}

Export-ModuleMember -Function *
