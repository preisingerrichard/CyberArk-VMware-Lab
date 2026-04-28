<#
.SYNOPSIS
    Install CyberArk PVWA (Password Vault Web Access) on COMP01.
.DESCRIPTION
    Stages PVWA installer via zip transfer, then runs InstallationAutomation scripts:
        1. PVWA_Prerequisites.ps1
        2. PVWAInstallation.ps1
        3. PVWARegisterComponent.ps1
        4. PVWA_Hardening.ps1
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

$pvwaVM  = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -eq 'PVWA' }
$pvwaVMX = $deployedVMs[$pvwaVM.Name]

if (-not $pvwaVMX) { throw "$($pvwaVM.Name) not found in DeployedVMs.xml" }

$guestUser = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$guestPass = $Config.Domain.DomainAdminPass
$mediaBase = $Config.CyberArkMedia.BasePath

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk PVWA on $($pvwaVM.Name)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

Wait-LabVMReady -VMXPath $pvwaVMX

# ================================================================
# Pre-flight: Ensure VAULT01 is on and port 1858 reachable
# ================================================================
Write-Host "`n[Pre-flight] Ensuring Vault is reachable on $($CAConfig.Vault.VaultAddress):$($CAConfig.Vault.VaultPort)..." -ForegroundColor Yellow

$vaultVM  = $Config.VMs | Where-Object { $_.Role -eq 'Vault' -or $_.Role -contains 'Vault' }
$vaultVMX = $deployedVMs[$vaultVM.Name]

Wait-LabVMReady -VMXPath $vaultVMX

# Poll port 1858 from within the PVWA VM
$deadline = (Get-Date).AddSeconds(300)
$reached  = $false
while ((Get-Date) -lt $deadline) {
    $tcpCheck = Invoke-LabVMPowerShell -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -ScriptBlock @"
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
# Step 1: Copy PVWA installer to guest (zip → copy → expand)
# ================================================================
Write-Host "`n[Step 1] Copying PVWA installer to $($pvwaVM.Name)..." -ForegroundColor Yellow

$pvwaHostDir = Join-Path $mediaBase $Config.CyberArkMedia.PVWAFolder

# Shared helper: run a guest call; on failure fetch the newest error_*.log and throw
function Invoke-GuestStep {
    param($VMXPath, $GuestUser, $GuestPassword, $ScriptBlock, $Label)
    $r = Invoke-LabVMPowerShell -VMXPath $VMXPath -GuestUser $GuestUser `
             -GuestPassword $GuestPassword -ScriptBlock $ScriptBlock -NoThrow
    if ($r.ExitCode -ne 0) {
        $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dir = "$PSScriptRoot\..\Logs"
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        # Fetch the newest timestamped error log written by the VMwareHelper wrapper
        $hostLog = "$dir\pvwa_${Label}_error_$ts.log"
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
        throw "PVWA $Label failed (exit $($r.ExitCode))"
    }
}

# Skip zip transfer/expand if installer is already extracted from a previous run
Write-Host "  Checking if installer already extracted..." -ForegroundColor DarkGray
$alreadyExtracted = Invoke-LabVMPowerShell -VMXPath $pvwaVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Test-Path 'C:\CyberArkInstall\PVWA\InstallationAutomation') { exit 0 } else { exit 1 }
'@

if ($alreadyExtracted.ExitCode -eq 0) {
    Write-Host "  [SKIP] Installer already extracted on guest" -ForegroundColor Yellow
} else {
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "mkdir" -ScriptBlock @'
New-Item -Path 'C:\CyberArkInstall\PVWA' -ItemType Directory -Force | Out-Null
Write-Host 'Guest directories created'
'@

    Write-Host "  Compressing PVWA installer..." -ForegroundColor DarkGray
    $pvwaZip = Join-Path $env:TEMP "PVWAInstall_$(Get-Random).zip"
    try {
        Compress-Archive -Path "$pvwaHostDir\*" -DestinationPath $pvwaZip -Force
        $zipSizeMB = [math]::Round((Get-Item $pvwaZip).Length / 1MB, 1)
        Write-Host "  Transferring PVWA installer ($zipSizeMB MB)..." -ForegroundColor DarkGray
        Copy-FileToLabVM -VMXPath $pvwaVMX -HostPath $pvwaZip `
            -GuestPath 'C:\Windows\Temp\PVWAInstall.zip' `
            -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
    } finally {
        Remove-Item $pvwaZip -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Expanding PVWA installer on guest..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "expand" -ScriptBlock @'
Expand-Archive 'C:\Windows\Temp\PVWAInstall.zip' 'C:\CyberArkInstall\PVWA' -Force
Remove-Item 'C:\Windows\Temp\PVWAInstall.zip' -Force -ErrorAction SilentlyContinue
$count = (Get-ChildItem 'C:\CyberArkInstall\PVWA' -Recurse -File).Count
Write-Host "  PVWA installer: $count files"
'@
}

Write-Host "  [OK] PVWA installer ready on guest" -ForegroundColor Green

# ================================================================
# Step 2: Install PVWA via InstallationAutomation scripts
# ================================================================
Write-Host "`n[Step 2] Installing PVWA..." -ForegroundColor Yellow

# Snippet reused in every sub-call to locate InstallationAutomation
$findAutoDir = @'
$autoDir = 'C:\CyberArkInstall\PVWA\InstallationAutomation'
if (-not (Test-Path $autoDir)) {
    $sub = Get-ChildItem 'C:\CyberArkInstall\PVWA' -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path "$($_.FullName)\InstallationAutomation" } |
           Select-Object -First 1
    if ($sub) { $autoDir = "$($sub.FullName)\InstallationAutomation" }
    else { throw "InstallationAutomation directory not found under C:\CyberArkInstall\PVWA" }
}
'@

# Invoke-GuestStep is defined in Step 1 above and reused here

# --- Skip check ---
Write-Host "  Checking for existing PVWA installation..." -ForegroundColor DarkGray
$skipCheck = Invoke-LabVMPowerShell -VMXPath $pvwaVMX -GuestUser $guestUser `
    -GuestPassword $guestPass -NoThrow -ScriptBlock @'
if (Get-Service 'CyberArk Scheduled Tasks' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }
'@

if ($skipCheck.ExitCode -eq 0) {
    Write-Host "  [SKIP] PVWA service already present - skipping installation" -ForegroundColor Yellow
} else {
    # --- 2a: Prepare log dir and patch registration config ---
    Write-Host "  [Setup] Patching registration config..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
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

`$regConfig = "`$autoDir\Registration\PVWARegisterComponentConfig.xml"
if (Test-Path `$regConfig) {
    Set-XmlParam `$regConfig 'vaultip'   '$($CAConfig.Vault.VaultAddress)'
    Set-XmlParam `$regConfig 'vaultuser' '$($CAConfig.Vault.AdminUser)'
} else { Write-Warning "Registration config not found: `$regConfig" }
"@

    # --- 2b: Prerequisites (IIS, .NET, Windows features) ---
    Write-Host "  [1/4] Installing IIS, .NET and Windows prerequisites (may take 5-10 min)..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "prerequisites" -ScriptBlock @"
$findAutoDir
Set-Location `$autoDir
Write-Host 'Running PVWA_Prerequisites.ps1...'
& .\PVWA_Prerequisites.ps1
Write-Host '[OK] Prerequisites complete'
"@
    Write-Host "  [1/4] Prerequisites complete" -ForegroundColor Green

    # --- 2c: PVWA Installer ---
    Write-Host "  [2/4] Running PVWA installer (10-20 min, please wait)..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "installation" -ScriptBlock @"
$findAutoDir
Set-Location "`$autoDir\Installation"
Write-Host 'Running PVWAInstallation.ps1...'
& .\PVWAInstallation.ps1
Write-Host '[OK] Installation complete'
"@
    Write-Host "  [2/4] Installation complete" -ForegroundColor Green

    # --- 2d: Registration ---
    Write-Host "  [3/4] Registering PVWA with Vault..." -ForegroundColor DarkGray
    Invoke-GuestStep -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -Label "registration" -ScriptBlock @"
$findAutoDir
Set-Location "`$autoDir\Registration"
Write-Host 'Running PVWARegisterComponent.ps1...'
& .\PVWARegisterComponent.ps1 -pwd '$($CAConfig.Vault.AdminPassword)'
Write-Host '[OK] Registration complete'
"@
    Write-Host "  [3/4] Registration complete" -ForegroundColor Green

    # --- 2e: Hardening ---
    # PVWA_Hardening.ps1 restarts the HTTP kernel driver, which can deadlock if IIS
    # dependents are still running. Pre-stop W3SVC/WAS, then run hardening in a
    # background job with a 120-second timeout so a stuck HTTP stop cannot hang deploy.
    Write-Host "  [4/4] Applying security hardening (IIS header suppression, TLS, etc.)..." -ForegroundColor DarkGray
    Invoke-LabVMPowerShell -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass `
        -NoThrow -ScriptBlock @"
$findAutoDir

Write-Host 'Stopping IIS services before hardening...'
Stop-Service W3SVC, WAS -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

Write-Host 'Running PVWA_Hardening.ps1 (timeout: 120 s)...'
`$job = Start-Job -ScriptBlock {
    param(`$dir)
    Set-Location `$dir
    & .\PVWA_Hardening.ps1
} -ArgumentList `$autoDir

`$done = `$job | Wait-Job -Timeout 120
if (-not `$done) {
    Stop-Job `$job -ErrorAction SilentlyContinue
    Write-Warning 'Hardening timed out waiting for HTTP service to stop - continuing. HTTP will settle on next reboot.'
} else {
    Receive-Job `$job
}
Remove-Job `$job -Force -ErrorAction SilentlyContinue

Write-Host 'Restarting IIS...'
Start-Service W3SVC -ErrorAction SilentlyContinue
Write-Host '[OK] Hardening complete'
"@ | Out-Null
    Write-Host "  [4/4] Hardening complete" -ForegroundColor Green
}

Write-Host "  [OK] PVWA installed" -ForegroundColor Green

# ================================================================
# Step 3: Verify
# ================================================================
Write-Host "`n[Step 3] Verifying PVWA installation..." -ForegroundColor Yellow

Invoke-LabVMPowerShell -VMXPath $pvwaVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$svc = Get-Service 'CyberArk Scheduled Tasks' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "[OK] $($svc.DisplayName): $($svc.Status)" -ForegroundColor Green
} else {
    Write-Warning "CyberArk Scheduled Tasks service not found"
    Get-Service | Where-Object { $_.DisplayName -match 'CyberArk|PVWA|PasswordVault' } |
        ForEach-Object { Write-Host "  Found: $($_.DisplayName) - $($_.Status)" }
}

Import-Module WebAdministration -ErrorAction SilentlyContinue
$pool = Get-ChildItem IIS:\AppPools -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'PasswordVault' }
if ($pool) {
    Write-Host "[OK] IIS App Pool: $($pool.Name) - $($pool.State)" -ForegroundColor Green
} else {
    Write-Warning "PasswordVault IIS app pool not found"
}
'@ | Out-Null

Write-Host "  PVWA URL: https://comp01.$($Config.Domain.Name)/PasswordVault/v10/logon/cyberark" -ForegroundColor DarkGray

# ================================================================
# Step 4: Create PVWA desktop shortcut on host
# ================================================================
Write-Host "`n[Step 4] Creating PVWA desktop shortcut..." -ForegroundColor Yellow

$pvwaUrl      = "https://comp01.$($Config.Domain.Name)/PasswordVault/v10/logon/cyberark"
$shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'PVWA - CyberArk Lab.url')

try {
    if (Test-Path $shortcutPath) {
        Write-Host "  [SKIP] Desktop shortcut already exists" -ForegroundColor Yellow
    } else {
        $ini = "[InternetShortcut]`r`nURL=$pvwaUrl`r`nIconIndex=0`r`nIconFile=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`r`n"
        [System.IO.File]::WriteAllText($shortcutPath, $ini, [System.Text.Encoding]::UTF8)
        Write-Host "  [OK] Shortcut created: $shortcutPath" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not create desktop shortcut: $_"
}


Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "PVWA installation complete on $($pvwaVM.Name)" -ForegroundColor Green
Write-Host "  URL: https://comp01.$($Config.Domain.Name)/PasswordVault/v10/logon/cyberark" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green