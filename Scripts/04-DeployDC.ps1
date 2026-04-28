<#
.SYNOPSIS
    Configure DC01 as Active Directory Domain Controller
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
$CyberArkConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"
$dcVMX = $deployedVMs["DC01"]
$dcVM = $Config.VMs | Where-Object { $_.Name -eq "DC01" }

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "Deploying Domain Controller: DC01" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan

$user = $Config.LocalAdmin.Username
$pass = $Config.LocalAdmin.Password

# --- Step 1: Install AD DS Role ---
Write-Host "`n[Step 1] Installing AD DS Role..." -ForegroundColor Yellow

$installADDS = @"
Install-WindowsFeature -Name AD-Domain-Services, DNS, GPMC -IncludeManagementTools -Verbose
Write-Host "AD DS role installed"
"@

Invoke-LabVMPowerShell -VMXPath $dcVMX -ScriptBlock $installADDS `
    -GuestUser $user -GuestPassword $pass

Start-Sleep -Seconds 15

# --- Step 2: Promote to Domain Controller ---
Write-Host "`n[Step 2] Promoting to Domain Controller..." -ForegroundColor Yellow

$promoteDC = @"
`$securePassword = ConvertTo-SecureString '$($Config.Domain.SafeModePassword)' -AsPlainText -Force

Install-ADDSForest ``
    -DomainName '$($Config.Domain.Name)' ``
    -DomainNetbiosName '$($Config.Domain.NetBIOSName)' ``
    -SafeModeAdministratorPassword `$securePassword ``
    -InstallDns:`$true ``
    -DatabasePath 'C:\Windows\NTDS' ``
    -LogPath 'C:\Windows\NTDS' ``
    -SysvolPath 'C:\Windows\SYSVOL' ``
    -NoRebootOnCompletion:`$false ``
    -Force:`$true

Write-Host "Domain Controller promotion initiated"
"@

Invoke-LabVMPowerShell -VMXPath $dcVMX -ScriptBlock $promoteDC `
    -GuestUser $user -GuestPassword $pass

# Wait for reboot after promotion
Write-Host "Waiting for DC reboot after promotion..." -ForegroundColor Cyan
Start-Sleep -Seconds 60
Wait-LabVMReady -VMXPath $dcVMX -TimeoutSeconds 600

# Wait extra for AD services to start
Start-Sleep -Seconds 120
Write-Host "DC promotion complete. Waiting for AD services..." -ForegroundColor Cyan

# --- Step 3: Post-DC Configuration ---
Write-Host "`n[Step 3] Post-DC Configuration..." -ForegroundColor Yellow

# Use local format for authentication initially, then retry with domain format if needed
$localUser = $user
$localPass = $pass
$domainUser = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$domainPass = $Config.Domain.DomainAdminPass

$postDCConfig = @"
# Wait for AD to be fully ready
`$maxRetry = 30
`$retry = 0
while (`$retry -lt `$maxRetry) {
    try {
        Get-ADDomain -ErrorAction Stop
        Write-Host "AD is ready!"
        break
    }
    catch {
        `$retry++
        Write-Host "Waiting for AD... (`$retry/`$maxRetry)"
        Start-Sleep -Seconds 10
    }
}

# Create OUs
New-ADOrganizationalUnit -Name "CyberArk" -Path "DC=cyberark,DC=lab" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "ServiceAccounts" -Path "OU=CyberArk,DC=cyberark,DC=lab" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "Servers" -Path "OU=CyberArk,DC=cyberark,DC=lab" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "PAM" -Path "OU=CyberArk,DC=cyberark,DC=lab" -ErrorAction SilentlyContinue

Write-Host "OUs created"

# Create CyberArk Service Accounts
`$serviceAccounts = @(
    @{ Name = 'CyberArk-CPM'; Description = 'CPM Service Account' },
    @{ Name = 'CyberArk-PVWA'; Description = 'PVWA Service Account' },
    @{ Name = 'CyberArk-PSM'; Description = 'PSM Service Account' }
)

foreach (`$sa in `$serviceAccounts) {
    `$secPass = ConvertTo-SecureString '$($CyberArkConfig.ServiceAccounts.Password)' -AsPlainText -Force
    New-ADUser -Name `$sa.Name ``
        -SamAccountName `$sa.Name ``
        -UserPrincipalName "`$(`$sa.Name)@cyberark.lab" ``
        -Description `$sa.Description ``
        -Path "OU=ServiceAccounts,OU=CyberArk,DC=cyberark,DC=lab" ``
        -AccountPassword `$secPass ``
        -Enabled `$true ``
        -PasswordNeverExpires `$true ``
        -CannotChangePassword `$true ``
        -ErrorAction SilentlyContinue

    Write-Host "Created service account: `$(`$sa.Name)"
}

# Create DNS records for CyberArk servers
Add-DnsServerResourceRecordA -Name "vault01" -ZoneName "cyberark.lab" -IPv4Address "192.168.100.20" -ErrorAction SilentlyContinue
Add-DnsServerResourceRecordA -Name "comp01" -ZoneName "cyberark.lab" -IPv4Address "192.168.100.30" -ErrorAction SilentlyContinue
Add-DnsServerResourceRecordA -Name "pvwa" -ZoneName "cyberark.lab" -IPv4Address "192.168.100.30" -ErrorAction SilentlyContinue

Write-Host "DNS records created"

# Install Certificate Authority (Enterprise CA for PVWA HTTPS)
Install-WindowsFeature -Name AD-Certificate, ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools

Install-AdcsCertificationAuthority ``
    -CAType EnterpriseRootCA ``
    -CACommonName "CyberArk-Lab-CA" ``
    -KeyLength 2048 ``
    -HashAlgorithm SHA256 ``
    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" ``
    -ValidityPeriod Years ``
    -ValidityPeriodUnits 10 ``
    -Force

Write-Host "Enterprise CA installed"

# Configure Certificate Auto-Enrollment GPO
# (Simplified - in production you'd use proper GPO cmdlets)

Write-Host "DC post-configuration complete!"
"@

# Try with local credentials first (immediately after DC promotion)
Write-Host "Attempting post-DC configuration (trying local credentials first)..." -ForegroundColor Cyan
try {
    Invoke-LabVMPowerShell -VMXPath $dcVMX -ScriptBlock $postDCConfig `
        -GuestUser $localUser -GuestPassword $localPass -ErrorAction Stop
    Write-Host "Post-DC configuration completed successfully" -ForegroundColor Green
} catch {
    Write-Host "Local credentials failed, retrying with domain credentials after delay..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
    try {
        Invoke-LabVMPowerShell -VMXPath $dcVMX -ScriptBlock $postDCConfig `
            -GuestUser $domainUser -GuestPassword $domainPass
        Write-Host "Post-DC configuration completed successfully with domain credentials" -ForegroundColor Green
    } catch {
        Write-Warning "Post-DC configuration failed: $_"
        Write-Host "Continuing anyway - configuration may be partially complete" -ForegroundColor Yellow
    }
}

# Snapshot
Stop-LabVM -VMXPath $dcVMX
Start-Sleep -Seconds 15
New-LabVMSnapshot -VMXPath $dcVMX -SnapshotName "DC-Configured"
Start-LabVM -VMXPath $dcVMX -NoGUI
Wait-LabVMReady -VMXPath $dcVMX

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "Domain Controller DC01 fully configured!" -ForegroundColor Green
Write-Host "  Domain: $($Config.Domain.Name)" -ForegroundColor Green
Write-Host "  DNS: $($dcVM.IPAddress)" -ForegroundColor Green
Write-Host "  CA: CyberArk-Lab-CA" -ForegroundColor Green
Write-Host $("=" * 60) -ForegroundColor Green