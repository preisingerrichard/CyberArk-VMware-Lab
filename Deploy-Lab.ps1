<#
.SYNOPSIS
    Master CyberArk Lab Deployment Orchestrator
.DESCRIPTION
    Deploys a complete CyberArk self-hosted environment on VMware Workstation Pro.
.PARAMETER Steps
    Specify which steps to run. Default: All
.EXAMPLE
    .\Deploy-Lab.ps1
    .\Deploy-Lab.ps1 -Steps Prerequisites,BaseVM,DeployVMs
    .\Deploy-Lab.ps1 -Steps VaultInstall -SkipSnapshots
#>

[CmdletBinding()]
param(
    [ValidateSet(
        "All", "Prerequisites", "BaseVM", "DeployVMs", "DomainController",
        "DomainJoin", "VaultInstall", "PVWAInstall", "CPMInstall",
        "PSMInstall"
    )]
    [string[]]$Steps = @("All"),

    [switch]$SkipSnapshots,
    [switch]$NoGUI,
    [string]$ConfigPath = "$PSScriptRoot\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Banner
Write-Host ""
Write-Host "CyberArk Self-Hosted Lab Deployment" -ForegroundColor Cyan
Write-Host "VMware Workstation Pro + PowerShell" -ForegroundColor Cyan
Write-Host ""

# Validate config exists
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$Config = Import-PowerShellDataFile $ConfigPath
Write-Host "Configuration loaded from: $ConfigPath" -ForegroundColor DarkGray
Write-Host "Target folder: $($Config.VMware.DefaultVMFolder)" -ForegroundColor DarkGray
Write-Host "Domain: $($Config.Domain.Name)" -ForegroundColor DarkGray
Write-Host "VMs to deploy: $(($Config.VMs | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor DarkGray
Write-Host ""

# Create shared files directory
$sharedFolder = Join-Path $Config.VMware.DefaultVMFolder "_SharedFiles"
New-Item -Path $sharedFolder -ItemType Directory -Force | Out-Null

$allSteps = $Steps -contains "All"
$scriptsDir = "$PSScriptRoot\Scripts"

# Step tracking
$stepResults = @()

function Invoke-LabStep {
    param(
        [string]$StepName,
        [string]$ScriptPath,
        [string]$Description
    )

    $stepStart = Get-Date
    Write-Host "`n$("=" * 70)" -ForegroundColor Magenta
    Write-Host "  STEP: $Description" -ForegroundColor Magenta
    Write-Host "  Script: $(Split-Path $ScriptPath -Leaf)" -ForegroundColor DarkMagenta
    Write-Host $("=" * 70) -ForegroundColor Magenta

    try {
        & $ScriptPath -ConfigPath $ConfigPath
        $duration = (Get-Date) - $stepStart

        $script:stepResults += @{
            Step = $StepName
            Status = "SUCCESS"
            Duration = $duration.ToString("hh\:mm\:ss")
        }

        Write-Host ""
        Write-Host "[SUCCESS] $StepName completed in $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
    }
    catch {
        $duration = (Get-Date) - $stepStart

        $script:stepResults += @{
            Step = $StepName
            Status = "FAILED"
            Duration = $duration.ToString("hh\:mm\:ss")
            Error = $_.Exception.Message
        }

        Write-Host ""
        Write-Host "[FAILED] $StepName FAILED after $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red

        $continue = Read-Host "Continue with next step? (Y/N)"
        if ($continue -ne 'Y') {
            throw "Deployment aborted at step: $StepName"
        }
    }
}

# Execute steps
if ($allSteps -or $Steps -contains "Prerequisites") {
    Invoke-LabStep -StepName "Prerequisites" `
        -ScriptPath "$scriptsDir\00-Prerequisites.ps1" `
        -Description "Checking prerequisites"
}

if ($allSteps -or $Steps -contains "BaseVM") {
    Invoke-LabStep -StepName "BaseVM" `
        -ScriptPath "$scriptsDir\01-CreateBaseVM.ps1" `
        -Description "Creating Windows Server base template VM"
}

if ($allSteps -or $Steps -contains "DeployVMs") {
    Invoke-LabStep -StepName "DeployVMs" `
        -ScriptPath "$scriptsDir\02-DeployVMs.ps1" `
        -Description "Deploying all lab VMs from template"
}

if ($allSteps -or $Steps -contains "DomainController") {
    Invoke-LabStep -StepName "DomainController" `
        -ScriptPath "$scriptsDir\04-DeployDC.ps1" `
        -Description "Configuring Domain Controller (DC01)"
}

if ($allSteps -or $Steps -contains "DomainJoin") {
    Invoke-LabStep -StepName "DomainJoin" `
        -ScriptPath "$scriptsDir\05-DomainJoin.ps1" `
        -Description "Joining VMs to domain"
}

if ($allSteps -or $Steps -contains "VaultInstall") {
    Invoke-LabStep -StepName "VaultInstall" `
        -ScriptPath "$scriptsDir\06-InstallVault.ps1" `
        -Description "Installing CyberArk Vault Server"
}

if ($allSteps -or $Steps -contains "PVWAInstall") {
    Invoke-LabStep -StepName "PVWAInstall" `
        -ScriptPath "$scriptsDir\07-InstallPVWA.ps1" `
        -Description "Installing CyberArk PVWA"
}

if ($allSteps -or $Steps -contains "CPMInstall") {
    Invoke-LabStep -StepName "CPMInstall" `
        -ScriptPath "$scriptsDir\08-InstallCPM.ps1" `
        -Description "Installing CyberArk CPM"
}

if ($allSteps -or $Steps -contains "PSMInstall") {
    Invoke-LabStep -StepName "PSMInstall" `
        -ScriptPath "$scriptsDir\09-InstallPSM.ps1" `
        -Description "Installing CyberArk PSM"
}


# Final Summary
$totalDuration = (Get-Date) - $startTime

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  DEPLOYMENT SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$stepResults | ForEach-Object {
    $color = if ($_.Status -eq "SUCCESS") { "Green" } else { "Red" }
    $symbol = if ($_.Status -eq "SUCCESS") { "[OK]" } else { "[FAIL]" }
    Write-Host "  $symbol $($_.Step.PadRight(25)) $($_.Status.PadRight(10)) ($($_.Duration))" -ForegroundColor $color
}

Write-Host ""
Write-Host "  Total time: $($totalDuration.ToString('hh\:mm\:ss'))" -ForegroundColor White

$failed = $stepResults | Where-Object { $_.Status -eq "FAILED" }
if ($failed.Count -eq 0) {
    Write-Host ""
    $completedStepNames = @(
        $stepResults |
        Where-Object { $_.Status -eq "SUCCESS" } |
        ForEach-Object { $_["Step"] }
    )
    $fullLabSteps = @("DeployVMs", "DomainController", "DomainJoin", "VaultInstall", "PVWAInstall", "CPMInstall", "PSMInstall")
    $isFullLabDeployment = $allSteps -or (($fullLabSteps | Where-Object { $completedStepNames -contains $_ }).Count -gt 0)

    if ($isFullLabDeployment) {
        $vaultVm = $Config.VMs | Where-Object {
            $roles = @($_.Role)
            $roles -contains 'Vault'
        } | Select-Object -First 1

        $vaultIP = if ($vaultVm) { $vaultVm.IPAddress } else { $null }
        $domainName = $Config.Domain.Name

        # Clean up deployment snapshots — no longer needed once installation is complete
        if (Test-Path "$PSScriptRoot\Config\DeployedVMs.xml") {
            Write-Host "Removing deployment snapshots..." -ForegroundColor Cyan
            $deployedVMs = Import-Clixml "$PSScriptRoot\Config\DeployedVMs.xml"
            foreach ($vm in $Config.VMs) {
                $vmx = $deployedVMs[$vm.Name]
                if ($vmx -and (Test-Path $vmx)) {
                    Remove-AllLabVMSnapshots -VMXPath $vmx -VMName $vm.Name
                }
            }
            Write-Host ""
        }

        Write-Host "LAB DEPLOYMENT SUCCESSFUL!" -ForegroundColor Green
        Write-Host ""
        Write-Host "  PVWA:   https://comp01.$domainName/PasswordVault/v10/logon/cyberark" -ForegroundColor Green
        if ($vaultIP) {
            Write-Host "  Vault:  $vaultIP`:1858" -ForegroundColor Green
        }
        Write-Host "  Domain: $domainName" -ForegroundColor Green
        Write-Host "  Admin:  $($Config.Domain.NetBIOSName)\Administrator" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "Requested deployment step(s) completed successfully." -ForegroundColor Green
        Write-Host ""
    }
} else {
    Write-Host "Some steps failed. Review errors above." -ForegroundColor Yellow
}
