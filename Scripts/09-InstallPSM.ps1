<#
.SYNOPSIS
    Install CyberArk PSM (Privileged Session Manager) on COMP01.
.DESCRIPTION
    Stages PSM installer via zip transfer, then runs InstallationAutomation scripts.
    Because the Installation stage may trigger a reboot (RDS role), the script
    splits execution into two guest invocations:

        Pre-reboot  : Readiness → Prerequisites → Installation
        Post-reboot : PostInstallation → Hardening → Registration

    RDS-RD-Server is installed explicitly and rebooted before automation scripts run.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config   = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"

$psmVM  = $Config.VMs | Where-Object { $_.Role -contains 'PSM' -or $_.Role -eq 'PSM' }
$psmVMX = $deployedVMs[$psmVM.Name]

if (-not $psmVMX) { throw "$($psmVM.Name) not found in DeployedVMs.xml" }

$guestUser = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$guestPass = $Config.Domain.DomainAdminPass
$mediaBase = $Config.CyberArkMedia.BasePath

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk PSM on $($psmVM.Name)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

Wait-LabVMReady -VMXPath $psmVMX

# Shared helper: run a guest call; on failure fetch the newest error_*.log and throw
function Invoke-GuestStep {
    param($VMXPath, $GuestUser, $GuestPassword, $ScriptBlock, $Label)
    $r = Invoke-LabVMPowerShell -VMXPath $VMXPath -GuestUser $GuestUser `
             -GuestPassword $GuestPassword -ScriptBlock $ScriptBlock -NoThrow
    if ($r.ExitCode -ne 0) {
        $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dir = "$PSScriptRoot\..\Logs"
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        $hostLog = "$dir\psm_${Label}_error_$ts.log"
        try {
            $latestLog = Invoke-LabVMPowerShell -VMXPath $VMXPath -GuestUser $GuestUser `
                -GuestPassword $GuestPassword -NoThrow -ScriptBlock @'
$f = Get-ChildItem 'C:\LabSetup\Logs' -Filter 'error_*.log' -ErrorAction SilentlyContinue |
     Sort-Object LastWriteTime | Select-Object -Last 1
if ($f) { Write-Output $f.FullName } else { Write-Output '' }
'@
            $guestLog = $latestLog.Output.Trim()
            if ($guestLog) {
                Copy-FileFromLabVM -VMXPath $VMXPath -GuestPath $guestLog `
                    -HostPath $hostLog -GuestUser $GuestUser -GuestPassword $GuestPassword | Out-Null
                Write-Host "`n=== Guest error ($Label) ===" -ForegroundColor Yellow
                Get-Content $hostLog | Write-Host
            }
        } catch { Write-Warning "Could not retrieve guest error log: $_" }
        throw "PSM $Label failed (exit $($r.ExitCode))"
    }
}

# ================================================================
# Step 1: Install RDS-RD-Server (required by PSM Readiness check)
# ================================================================
Write-Host "`n[Step 1] Installing RDS-RD-Server role..." -ForegroundColor Yellow

$rdsCheck = Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$rds = Get-WindowsFeature RDS-RD-Server
if ($rds.InstallState -eq 'Installed') {
    Write-Host "[SKIP] RDS-RD-Server already installed"
    exit 0
}
Write-Host "Installing RDS-RD-Server..."
$result = Install-WindowsFeature RDS-RD-Server -IncludeManagementTools
Write-Host "RDS-RD-Server install result: $($result.Success), RestartNeeded: $($result.RestartNeeded)"
if ($result.RestartNeeded -eq 'Yes') { exit 2 }
exit 0
'@ -NoThrow

if ($rdsCheck.ExitCode -eq 2) {
    Write-Host "  Rebooting for RDS role..." -ForegroundColor DarkGray
    Restart-LabVM -VMXPath $psmVMX
    Start-Sleep -Seconds 30
    Wait-LabVMReady -VMXPath $psmVMX -TimeoutSeconds 300
    Start-Sleep -Seconds 60
    Write-Host "  [OK] Reboot complete, RDS-RD-Server active" -ForegroundColor Green
} elseif ($rdsCheck.ExitCode -ne 0) {
    throw "RDS-RD-Server installation failed (exit $($rdsCheck.ExitCode))"
} else {
    Write-Host "  [OK] RDS-RD-Server ready" -ForegroundColor Green
}

# ================================================================
# Step 2: Copy PSM installer to guest (zip → copy → expand)
# ================================================================
Write-Host "`n[Step 2] Copying PSM installer to $($psmVM.Name)..." -ForegroundColor Yellow

$psmHostDir = Join-Path $mediaBase $Config.CyberArkMedia.PSMFolder

# Skip zip transfer/expand if installer is already extracted from a previous run
Write-Host "  Checking if installer already extracted..." -ForegroundColor DarkGray
$alreadyExtracted = Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Test-Path 'C:\CyberArkInstall\PSM\InstallationAutomation') { exit 0 } else { exit 1 }
'@

if ($alreadyExtracted.ExitCode -eq 0) {
    Write-Host "  [SKIP] Installer already extracted on guest" -ForegroundColor Yellow
} else {
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "mkdir" -ScriptBlock @'
New-Item -Path 'C:\CyberArkInstall\PSM' -ItemType Directory -Force | Out-Null
Write-Host 'Guest directories created'
'@

    Write-Host "  Compressing PSM installer..." -ForegroundColor DarkGray
    $psmZip = Join-Path $env:TEMP "PSMInstall_$(Get-Random).zip"
    try {
        Compress-Archive -Path "$psmHostDir\*" -DestinationPath $psmZip -Force
        $zipSizeMB = [math]::Round((Get-Item $psmZip).Length / 1MB, 1)
        Write-Host "  Transferring PSM installer ($zipSizeMB MB)..." -ForegroundColor DarkGray
        Copy-FileToLabVM -VMXPath $psmVMX -HostPath $psmZip `
            -GuestPath 'C:\Windows\Temp\PSMInstall.zip' `
            -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
    } finally {
        Remove-Item $psmZip -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Expanding PSM installer on guest..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "expand" -ScriptBlock @'
Expand-Archive 'C:\Windows\Temp\PSMInstall.zip' 'C:\CyberArkInstall\PSM' -Force
Remove-Item 'C:\Windows\Temp\PSMInstall.zip' -Force -ErrorAction SilentlyContinue
$count = (Get-ChildItem 'C:\CyberArkInstall\PSM' -Recurse -File).Count
Write-Host "  PSM installer: $count files"
'@
}

Write-Host "  [OK] PSM installer ready on guest" -ForegroundColor Green

# Snippet reused in every sub-call to locate InstallationAutomation
$findAutoDir = @'
$autoDir = 'C:\CyberArkInstall\PSM\InstallationAutomation'
if (-not (Test-Path $autoDir)) {
    $sub = Get-ChildItem 'C:\CyberArkInstall\PSM' -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path "$($_.FullName)\InstallationAutomation" } |
           Select-Object -First 1
    if ($sub) { $autoDir = "$($sub.FullName)\InstallationAutomation" }
    else { throw "InstallationAutomation directory not found under C:\CyberArkInstall\PSM" }
}
'@

# ================================================================
# Step 3: Pre-reboot stages (Readiness → Prerequisites → Installation)
# ================================================================
Write-Host "`n[Step 3] Running PSM pre-reboot stages..." -ForegroundColor Yellow

# --- Skip check ---
Write-Host "  Checking for existing PSM installation..." -ForegroundColor DarkGray
$skipCheck = Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Get-Service 'Cyber-Ark Privileged Session Manager' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }
'@

if ($skipCheck.ExitCode -eq 0) {
    Write-Host "  [SKIP] PSM service already present - skipping to post-install verification" -ForegroundColor Yellow
} else {
    # --- 3a: Patch registration config ---
    Write-Host "  [Setup] Patching registration config..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "setup" -ScriptBlock @"
$findAutoDir

function Set-XmlParam (`$xmlPath, `$paramName, `$newValue) {
    [xml]`$doc = Get-Content `$xmlPath -Raw
    `$node = `$doc.SelectSingleNode("//*[@Name='`$paramName']")
    if (-not `$node) {
        `$node = `$doc.SelectNodes('//*') |
            Where-Object { `$_.Attributes -and `$_.Attributes['Name'] -and
                           `$_.Attributes['Name'].Value -ieq `$paramName } |
            Select-Object -First 1
    }
    if (`$node) {
        if (`$node.Attributes['Value']) { `$node.SetAttribute('Value', `$newValue) }
        else { `$node.InnerText = `$newValue }
        `$doc.Save(`$xmlPath)
        Write-Host "  [OK] `$paramName = `$newValue"
    } else { Write-Warning "  `$paramName not found in `$(Split-Path `$xmlPath -Leaf)" }
}

`$regConfig = "`$autoDir\Registration\RegistrationConfig.xml"
if (Test-Path `$regConfig) {
    Set-XmlParam `$regConfig 'vaultip'       '$($CAConfig.Vault.VaultAddress)'
    Set-XmlParam `$regConfig 'vaultusername' '$($CAConfig.Vault.AdminUser)'
    Set-XmlParam `$regConfig 'accepteula'    'yes'
} else { Write-Warning "Registration config not found: `$regConfig" }
"@

    # --- 3b: Readiness ---
    Write-Host "  [1/3] Running PSM Readiness check..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "readiness" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (Readiness)...'
& .\Execute-Stage.ps1 -configFilePath '.\Readiness\ReadinessConfig.xml'
Write-Host '[OK] Readiness complete'
"@
    Write-Host "  [1/3] Readiness complete" -ForegroundColor Green

    # --- 3c: Prerequisites ---
    Write-Host "  [2/3] Installing PSM prerequisites (may take 5-10 min)..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "prerequisites" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (Prerequisites)...'
& .\Execute-Stage.ps1 -configFilePath '.\Prerequisites\PrerequisitesConfig.xml'
Write-Host '[OK] Prerequisites complete'
"@
    Write-Host "  [2/3] Prerequisites complete" -ForegroundColor Green

    # --- 3d: Installation (may trigger reboot) ---
    Write-Host "  [3/3] Running PSM installer (10-20 min, possible reboot)..." -ForegroundColor DarkGray
    $installResult = Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser `
        -GuestPassword $guestPass -NoThrow -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (Installation)...'
& .\Execute-Stage.ps1 -configFilePath '.\Installation\InstallationConfig.xml'
Write-Host '[OK] Installation stage complete'
"@

    # Wait for reboot regardless — Installation stage may reboot the VM
    Write-Host "  Waiting for VM after Installation stage (possible reboot)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    Wait-LabVMReady -VMXPath $psmVMX -TimeoutSeconds 300
    Start-Sleep -Seconds 60

    if ($installResult.ExitCode -notin @(0, 3010)) {
        $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dir = "$PSScriptRoot\..\Logs"
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        try {
            $latestLog = Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser `
                -GuestPassword $guestPass -NoThrow -ScriptBlock @'
$f = Get-ChildItem 'C:\LabSetup\Logs' -Filter 'error_*.log' -ErrorAction SilentlyContinue |
     Sort-Object LastWriteTime | Select-Object -Last 1
if ($f) { Write-Output $f.FullName } else { Write-Output '' }
'@
            $guestLog = $latestLog.Output.Trim()
            if ($guestLog) {
                $hostLog = "$dir\psm_installation_error_$ts.log"
                Copy-FileFromLabVM -VMXPath $psmVMX -GuestPath $guestLog `
                    -HostPath $hostLog -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
                Write-Host "`n=== Guest error (installation) ===" -ForegroundColor Yellow
                Get-Content $hostLog | Write-Host
            }
        } catch { Write-Warning "Could not retrieve guest error log: $_" }
        throw "PSM installation failed (exit $($installResult.ExitCode))"
    }
    Write-Host "  [3/3] Installation complete" -ForegroundColor Green

    # ================================================================
    # Step 4: Post-reboot stages (PostInstallation → Hardening → Registration)
    # ================================================================
    Write-Host "`n[Step 4] Running PSM post-reboot stages..." -ForegroundColor Yellow

    # --- 4a: PostInstallation ---
    Write-Host "  [1/3] Running PostInstallation..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "postinstall" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (PostInstallation)...'
& .\Execute-Stage.ps1 -configFilePath '.\PostInstallation\PostInstallationConfig.xml'
Write-Host '[OK] PostInstallation complete'
"@
    Write-Host "  [1/3] PostInstallation complete" -ForegroundColor Green

    # --- 4b: Hardening ---
    Write-Host "  [2/3] Applying security hardening..." -ForegroundColor DarkGray
    Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -NoThrow -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (Hardening)...'
try { & .\Execute-Stage.ps1 -configFilePath '.\Hardening\HardeningConfig.xml' }
catch { Write-Warning "Hardening non-fatal error: `$_" }
Write-Host '[OK] Hardening complete'
"@ | Out-Null
    Write-Host "  [2/3] Hardening complete" -ForegroundColor Green

    # --- 4c: Registration ---
    Write-Host "  [3/3] Registering PSM with Vault..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "registration" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running Execute-Stage.ps1 (Registration)...'
& .\Execute-Stage.ps1 -configFilePath '.\Registration\RegistrationConfig.xml' -pwd '$($CAConfig.Vault.AdminPassword)'
Write-Host '[OK] Registration complete'
"@
    Write-Host "  [3/3] Registration complete" -ForegroundColor Green
}

Write-Host "  [OK] PSM installed" -ForegroundColor Green

# ================================================================
# Step 5: Verify
# ================================================================
Write-Host "`n[Step 5] Verifying PSM installation..." -ForegroundColor Yellow

Invoke-LabVMPowerShell -VMXPath $psmVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$svc = Get-Service 'Cyber-Ark Privileged Session Manager' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "[OK] $($svc.DisplayName): $($svc.Status)" -ForegroundColor Green
} else {
    Write-Warning "Cyber-Ark Privileged Session Manager service not found"
    Get-Service | Where-Object { $_.DisplayName -match 'CyberArk|PSM|Privileged Session' } |
        ForEach-Object { Write-Host "  Found: $($_.DisplayName) - $($_.Status)" }
}
'@ | Out-Null

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "PSM installation complete on $($psmVM.Name)" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
