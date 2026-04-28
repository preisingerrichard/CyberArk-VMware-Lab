<#
.SYNOPSIS
    Destroy the entire CyberArk lab environment
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [switch]$Force,
    [switch]$IncludeTemplate
)

$Config = Import-PowerShellDataFile $ConfigPath

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

if (-not $Force) {
    Write-Host "WARNING: This will destroy ALL lab VMs!" -ForegroundColor Red
    Write-Host "VMs to destroy: $(($Config.VMs.Name) -join ', ')" -ForegroundColor Yellow
    $confirm = Read-Host "Type 'DESTROY' to confirm"
    if ($confirm -ne 'DESTROY') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

# Stop and delete all VMs
foreach ($vm in $Config.VMs) {
    $vmxPath = Join-Path $Config.VMware.DefaultVMFolder "$($vm.Name)\$($vm.Name).vmx"

    if (Test-Path $vmxPath) {
        Write-Host "Destroying: $($vm.Name)" -ForegroundColor Red
        Stop-LabVM -VMXPath $vmxPath -Hard
        Start-Sleep -Seconds 5

        # Delete VM files
        Invoke-VMRun -Arguments @("deleteVM", "`"$vmxPath`"") -NoThrow
        Start-Sleep -Seconds 2

        # Clean up folder if still exists
        $vmFolder = Split-Path $vmxPath
        if (Test-Path $vmFolder) {
            Remove-Item -Path $vmFolder -Recurse -Force
        }

        Write-Host "  Deleted: $($vm.Name)" -ForegroundColor DarkRed
    }
}

if ($IncludeTemplate) {
    $templatePath = Join-Path $Config.VMware.DefaultVMFolder "$($Config.VMware.TemplateName)\$($Config.VMware.TemplateName).vmx"
    if (Test-Path $templatePath) {
        Write-Host "Destroying template VM..." -ForegroundColor Red
        Stop-LabVM -VMXPath $templatePath -Hard
        Invoke-VMRun -Arguments @("deleteVM", "`"$templatePath`"") -NoThrow
        Remove-Item (Split-Path $templatePath) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Clean up config files
Remove-Item "$PSScriptRoot\..\Config\DeployedVMs.xml" -Force -ErrorAction SilentlyContinue

Write-Host "`nLab environment destroyed." -ForegroundColor Red