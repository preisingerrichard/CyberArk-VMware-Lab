<#
.SYNOPSIS
    Install CyberArk Central Policy Manager (CPM) on COMP01.
.DESCRIPTION
    Stages CPM installer via zip transfer, then runs InstallationAutomation scripts:
        1. CPM_PreInstallation.ps1
        2. CPMInstallation.ps1
        3. CPMRegisterCommponent.ps1
        4. CPM_Hardening.ps1
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

$compVM  = $Config.VMs | Where-Object { $_.Role -contains 'CPM' -or $_.Role -eq 'CPM' }
$compVMX = $deployedVMs[$compVM.Name]

if (-not $compVMX) { throw "$($compVM.Name) not found in DeployedVMs.xml" }

$guestUser = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$guestPass = $Config.Domain.DomainAdminPass
$mediaBase = $Config.CyberArkMedia.BasePath

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk CPM on $($compVM.Name)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

Wait-LabVMReady -VMXPath $compVMX

# ================================================================
# Pre-flight: Ensure VAULT01 is on and port 1858 reachable
# ================================================================
Write-Host "`n[Pre-flight] Ensuring Vault is reachable on $($CAConfig.Vault.VaultAddress):$($CAConfig.Vault.VaultPort)..." -ForegroundColor Yellow

$vaultVM  = $Config.VMs | Where-Object { $_.Role -eq 'Vault' -or $_.Role -contains 'Vault' }
$vaultVMX = $deployedVMs[$vaultVM.Name]

Wait-LabVMReady -VMXPath $vaultVMX

# Poll port 1858 from within COMP01
$deadline = (Get-Date).AddSeconds(300)
$reached  = $false
while ((Get-Date) -lt $deadline) {
    $tcpCheck = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -ScriptBlock @"
`$tcp = Test-NetConnection -ComputerName '$($CAConfig.Vault.VaultAddress)' ``
    -Port $($CAConfig.Vault.VaultPort) -WarningAction SilentlyContinue -InformationLevel Quiet
if (`$tcp) { exit 0 } else { exit 1 }
"@
    if ($tcpCheck.ExitCode -eq 0) { $reached = $true; break }
    Write-Host "  Vault port $($CAConfig.Vault.VaultPort) not yet open - waiting..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}
if (-not $reached) {
    throw "Vault not reachable on port $($CAConfig.Vault.VaultPort). Start 'PrivateArk Server' on VAULT01 and re-run."
}
Write-Host "  [OK] Vault is reachable on port $($CAConfig.Vault.VaultPort)" -ForegroundColor Green

# ================================================================
# Step 1: Copy CPM installer to guest (zip → copy → expand)
# ================================================================
Write-Host "`n[Step 1] Copying CPM installer to $($compVM.Name)..." -ForegroundColor Yellow

$cpmHostDir = Join-Path $mediaBase $Config.CyberArkMedia.CPMFolder

# Shared helper: run a guest call; on failure fetch the newest error_*.log and throw
function Invoke-GuestStep {
    param($VMXPath, $GuestUser, $GuestPassword, $ScriptBlock, $Label)
    $r = Invoke-LabVMPowerShell -VMXPath $VMXPath -GuestUser $GuestUser `
             -GuestPassword $GuestPassword -ScriptBlock $ScriptBlock -NoThrow
    if ($r.ExitCode -ne 0) {
        $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dir = "$PSScriptRoot\..\Logs"
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        $hostLog = "$dir\cpm_${Label}_error_$ts.log"
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
        throw "CPM $Label failed (exit $($r.ExitCode))"
    }
}

# Skip zip transfer/expand if installer is already extracted from a previous run
Write-Host "  Checking if installer already extracted..." -ForegroundColor DarkGray
$alreadyExtracted = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Test-Path 'C:\CyberArkInstall\CPM\InstallationAutomation') { exit 0 } else { exit 1 }
'@

if ($alreadyExtracted.ExitCode -eq 0) {
    Write-Host "  [SKIP] Installer already extracted on guest" -ForegroundColor Yellow
} else {
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "mkdir" -ScriptBlock @'
New-Item -Path 'C:\CyberArkInstall\CPM' -ItemType Directory -Force | Out-Null
Write-Host 'Guest directories created'
'@

    Write-Host "  Compressing CPM installer..." -ForegroundColor DarkGray
    $cpmZip = Join-Path $env:TEMP "CPMInstall_$(Get-Random).zip"
    try {
        Compress-Archive -Path "$cpmHostDir\*" -DestinationPath $cpmZip -Force
        $zipSizeMB = [math]::Round((Get-Item $cpmZip).Length / 1MB, 1)
        Write-Host "  Transferring CPM installer ($zipSizeMB MB)..." -ForegroundColor DarkGray
        Copy-FileToLabVM -VMXPath $compVMX -HostPath $cpmZip `
            -GuestPath 'C:\Windows\Temp\CPMInstall.zip' `
            -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
    } finally {
        Remove-Item $cpmZip -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Expanding CPM installer on guest..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "expand" -ScriptBlock @'
Expand-Archive 'C:\Windows\Temp\CPMInstall.zip' 'C:\CyberArkInstall\CPM' -Force
Remove-Item 'C:\Windows\Temp\CPMInstall.zip' -Force -ErrorAction SilentlyContinue
$count = (Get-ChildItem 'C:\CyberArkInstall\CPM' -Recurse -File).Count
Write-Host "  CPM installer: $count files"
'@
}

Write-Host "  [OK] CPM installer ready on guest" -ForegroundColor Green

# ================================================================
# Step 2: Install CPM via InstallationAutomation scripts
# ================================================================
Write-Host "`n[Step 2] Installing CPM..." -ForegroundColor Yellow

# Snippet reused in every sub-call to locate InstallationAutomation
$findAutoDir = @'
$autoDir = 'C:\CyberArkInstall\CPM\InstallationAutomation'
if (-not (Test-Path $autoDir)) {
    $sub = Get-ChildItem 'C:\CyberArkInstall\CPM' -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path "$($_.FullName)\InstallationAutomation" } |
           Select-Object -First 1
    if ($sub) { $autoDir = "$($sub.FullName)\InstallationAutomation" }
    else { throw "InstallationAutomation directory not found under C:\CyberArkInstall\CPM" }
}
'@

# --- Skip check ---
Write-Host "  Checking for existing CPM installation..." -ForegroundColor DarkGray
$skipCheck = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Get-Service 'CyberArk Password Manager' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }
'@

if ($skipCheck.ExitCode -eq 0) {
    Write-Host "  [SKIP] CPM service already present - skipping installation" -ForegroundColor Yellow
} else {
    # --- 2a: Patch registration config ---
    Write-Host "  [Setup] Patching registration config..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
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

`$regConfig = "`$autoDir\Registration\CPMRegisterComponentConfig.xml"
if (Test-Path `$regConfig) {
    Set-XmlParam `$regConfig 'vaultip'   '$($CAConfig.Vault.VaultAddress)'
    Set-XmlParam `$regConfig 'vaultUser' '$($CAConfig.Vault.AdminUser)'
} else { Write-Warning "Registration config not found: `$regConfig" }
"@

    # --- 2b: Prerequisites ---
    Write-Host "  [1/4] Installing CPM prerequisites (may take 5-10 min)..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "prerequisites" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running CPM_PreInstallation.ps1...'
& .\CPM_PreInstallation.ps1
Write-Host '[OK] Prerequisites complete'
"@
    Write-Host "  [1/4] Prerequisites complete" -ForegroundColor Green

    # --- 2c: CPM Installer ---
    Write-Host "  [2/4] Running CPM installer (10-20 min, please wait)..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "installation" -ScriptBlock @"
$findAutoDir
Set-Location "`$autoDir\Installation"
Write-Host 'Running CPMInstallation.ps1...'
& .\CPMInstallation.ps1
Write-Host '[OK] Installation complete'
"@
    Write-Host "  [2/4] Installation complete" -ForegroundColor Green

    # --- 2d: Registration ---
    Write-Host "  [3/4] Registering CPM with Vault..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "registration" -ScriptBlock @"
$findAutoDir
Set-Location "`$autoDir\Registration"
Write-Host 'Running CPMRegisterCommponent.ps1...'
& .\CPMRegisterCommponent.ps1 -pwd '$($CAConfig.Vault.AdminPassword)'
Write-Host '[OK] Registration complete'
"@
    Write-Host "  [3/4] Registration complete" -ForegroundColor Green

    # --- 2e: Hardening ---
    Write-Host "  [4/4] Applying security hardening..." -ForegroundColor DarkGray
    Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -NoThrow -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running CPM_Hardening.ps1...'
try { & .\CPM_Hardening.ps1 } catch { Write-Warning "Hardening non-fatal error: `$_" }
Write-Host '[OK] Hardening complete'
"@ | Out-Null
    Write-Host "  [4/4] Hardening complete" -ForegroundColor Green
}

Write-Host "  [OK] CPM installed" -ForegroundColor Green

# ================================================================
# Step 3: Verify
# ================================================================
Write-Host "`n[Step 3] Verifying CPM installation..." -ForegroundColor Yellow

Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$svc = Get-Service 'CyberArk Password Manager' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "[OK] $($svc.DisplayName): $($svc.Status)" -ForegroundColor Green
} else {
    Write-Warning "CyberArk Password Manager service not found"
    Get-Service | Where-Object { $_.DisplayName -match 'CyberArk|CPM|Password Manager' } |
        ForEach-Object { Write-Host "  Found: $($_.DisplayName) - $($_.Status)" }
}
'@ | Out-Null

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "CPM installation complete on $($compVM.Name)" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
