<#
.SYNOPSIS
    Master CyberArk Lab Deployment Orchestrator
.DESCRIPTION
    Deploys a complete CyberArk self-hosted environment on VMware Workstation Pro.
.PARAMETER Steps
    Specify which steps to run. Default: All
.EXAMPLE
    .\Deploy-Lab.ps1 -Steps Full          # Everything: base lab + PTA + PSMP
    .\Deploy-Lab.ps1                      # Base lab only (no PTA/PSMP)
    .\Deploy-Lab.ps1 -Steps Prerequisites,BaseVM,DeployVMs
    .\Deploy-Lab.ps1 -Help                # List all steps and examples
#>

[CmdletBinding()]
param(
    [ValidateSet(
        "All", "Full", "Prerequisites", "BaseVM", "DeployVMs", "DomainController",
        "DomainJoin", "VaultInstall", "PVWAInstall", "CPMInstall",
        "PSMInstall", "CreatePTAVM", "PTAInstall", "CreatePSMPVM", "PSMPInstall"
    )]
    [string[]]$Steps = @("All"),

    [switch]$NoGUI,
    [switch]$Help,
    [string]$ConfigPath = "$PSScriptRoot\Config\LabConfig.psd1"
)

if ($Help) {
    Write-Host ""
    Write-Host "Deploy-Lab.ps1 - CyberArk Lab Deployment" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "AVAILABLE STEPS" -ForegroundColor Yellow
    Write-Host ""
    $stepInfo = [ordered]@{
        "All"              = "Base lab: Prerequisites through PSMInstall (no PTA/PSMP)"
        "Full"             = "Everything: base lab + PTA + PSMP in one command"
        "Prerequisites"    = "Verify host requirements (vmrun.exe, ISOs, installer media)"
        "BaseVM"           = "Create Windows Server 2022 template VM (sysprepped, snapshotted)"
        "DeployVMs"        = "Clone DC01, VAULT01, COMP01 from template; set IPs, hostnames, WinRM"
        "DomainController" = "Promote DC01: AD DS, DNS zone cyberark.lab"
        "DomainJoin"       = "Join COMP01 to domain (VAULT01 stays standalone)"
        "VaultInstall"     = "Install CyberArk Vault on VAULT01"
        "PVWAInstall"      = "Install PVWA on COMP01 (IIS, installer, register with Vault)"
        "CPMInstall"       = "Install CPM on COMP01 (register with Vault)"
        "PSMInstall"       = "Install PSM on COMP01 (register with Vault)"
        "CreatePTAVM"      = "Create PTA01 Rocky Linux 9 VM via kickstart"
        "PTAInstall"       = "Install and configure PTA on PTA01"
        "CreatePSMPVM"     = "Create PSMP01 Rocky Linux 9 VM via kickstart"
        "PSMPInstall"      = "Install and configure PSMP on PSMP01"
    }
    $w = ($stepInfo.Keys | Measure-Object Length -Maximum).Maximum + 2
    foreach ($s in $stepInfo.Keys) {
        $highlight = if ($s -in 'All','Full') { 'Cyan' } else { 'White' }
        Write-Host ("  {0,-$w} {1}" -f $s, $stepInfo[$s]) -ForegroundColor $highlight
    }
    Write-Host ""
    Write-Host "USAGE EXAMPLES" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  .\Deploy-Lab.ps1 -Steps Full                        # Everything in one command"
    Write-Host "  .\Deploy-Lab.ps1                                    # Base lab only (no PTA/PSMP)"
    Write-Host "  .\Deploy-Lab.ps1 -Steps Prerequisites               # Pre-flight check only"
    Write-Host "  .\Deploy-Lab.ps1 -Steps VaultInstall,PVWAInstall    # Specific steps only"
    Write-Host "  .\Deploy-Lab.ps1 -Steps CreatePTAVM,PTAInstall      # Add PTA to existing lab"
    Write-Host "  .\Deploy-Lab.ps1 -Steps PTAInstall                  # Re-run PTA install only"
    Write-Host "  .\Deploy-Lab.ps1 -Steps CreatePSMPVM,PSMPInstall    # Add PSMP to existing lab"
    Write-Host "  .\Deploy-Lab.ps1 -Steps PSMPInstall                 # Re-run PSMP install only"
    Write-Host ""
    return
}

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

$fullDeploy = $Steps -contains "Full"
$allSteps   = $Steps -contains "All" -or $fullDeploy
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

# PTA and PSMP steps run when explicitly requested or when -Steps Full is used
if ($Steps -contains "CreatePTAVM" -or $fullDeploy) {
    Invoke-LabStep -StepName "CreatePTAVM" `
        -ScriptPath "$scriptsDir\10-CreatePTAVM.ps1" `
        -Description "Creating PTA01 Rocky Linux 9 VM"
}

if ($Steps -contains "PTAInstall" -or $fullDeploy) {
    Invoke-LabStep -StepName "PTAInstall" `
        -ScriptPath "$scriptsDir\11-InstallPTA.ps1" `
        -Description "Installing CyberArk PTA (Rocky Linux)"
}

if ($Steps -contains "CreatePSMPVM" -or $fullDeploy) {
    Invoke-LabStep -StepName "CreatePSMPVM" `
        -ScriptPath "$scriptsDir\12-CreatePSMPVM.ps1" `
        -Description "Creating PSMP01 Rocky Linux 9 VM"
}

if ($Steps -contains "PSMPInstall" -or $fullDeploy) {
    Invoke-LabStep -StepName "PSMPInstall" `
        -ScriptPath "$scriptsDir\13-InstallPSMP.ps1" `
        -Description "Installing CyberArk PSMP (Rocky Linux)"
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
