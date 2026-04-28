<#
.SYNOPSIS
    Install CyberArk Vault Server v15.0 on VAULT01
.NOTES
    Flow: Vault install → Client install → Firewall fix → Reboot → Done
    
    Uses YOUR recorded ISS files EXACTLY as-is (byte-for-byte, no modifications).
      Helpers\setup.iss         (vault server — BootOption=0, no reboot)
      Helpers\setup-client.iss  (PrivateArk client — Result=1, BootOption=0, no reboot)
    
    Port 1858 verification is handled by 07-InstallCPM.ps1 pre-flight check.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"
$vaultVMX = $deployedVMs["VAULT01"]

if (-not $vaultVMX) { throw "VAULT01 not found in DeployedVMs.xml" }

$guestUser = $Config.LocalAdmin.Username
$guestPass = $Config.LocalAdmin.Password

$mediaBase = $Config.CyberArkMedia.BasePath

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Installing CyberArk Vault v15.0 on VAULT01" -ForegroundColor Cyan
Write-Host "  Flow: Vault → Client → Firewall fix → Reboot" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

Wait-LabVMReady -VMXPath $vaultVMX

# ================================================================
# Step 1: Copy ALL installation media to guest VM
# ================================================================
Write-Host "`n[Step 1] Copying installation media to VAULT01..." -ForegroundColor Yellow

$vaultInstallerHost  = Join-Path $mediaBase $Config.CyberArkMedia.VaultFolder
$clientInstallerHost = Join-Path $mediaBase $Config.CyberArkMedia.ClientFolder
$masterKeyHost       = Join-Path $mediaBase $Config.CyberArkMedia.MasterKeyFolder
$operatorKeyHost     = Join-Path $mediaBase $Config.CyberArkMedia.OperatorKeyFolder
$licenseHost         = Join-Path $mediaBase $Config.CyberArkMedia.LicenseFile

$masterKeyGuest     = $CAConfig.Vault.Guest.MasterKeyFolder
$operatorKeyGuest   = $CAConfig.Vault.Guest.OperatorKeyFolder
$licenseFolderGuest = Split-Path $CAConfig.Vault.Guest.LicenseFile -Parent

Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock @"
New-Item -Path 'C:\CyberArkInstall\Vault'  -ItemType Directory -Force | Out-Null
New-Item -Path 'C:\CyberArkInstall\Client' -ItemType Directory -Force | Out-Null
New-Item -Path '$masterKeyGuest'            -ItemType Directory -Force | Out-Null
New-Item -Path '$operatorKeyGuest'          -ItemType Directory -Force | Out-Null
New-Item -Path '$licenseFolderGuest'        -ItemType Directory -Force | Out-Null
New-Item -Path 'C:\LabSetup\Logs'           -ItemType Directory -Force | Out-Null
Write-Host 'Guest directories created'
"@ -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

# --- Vault installer ---
Write-Host "  Transferring Vault installer..." -ForegroundColor DarkGray
$vaultZip = Join-Path $env:TEMP "VaultInstall_$(Get-Random).zip"
try {
    Compress-Archive -Path "$vaultInstallerHost\*" -DestinationPath $vaultZip -Force
    $zipSizeMB = [math]::Round((Get-Item $vaultZip).Length / 1MB, 1)
    Write-Host "    ($zipSizeMB MB)" -ForegroundColor DarkGray
    Copy-FileToLabVM -VMXPath $vaultVMX -HostPath $vaultZip `
        -GuestPath 'C:\Windows\Temp\VaultInstall.zip' `
        -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
} finally {
    Remove-Item $vaultZip -Force -ErrorAction SilentlyContinue
}
Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock @"
Expand-Archive 'C:\Windows\Temp\VaultInstall.zip' 'C:\CyberArkInstall\Vault' -Force
Remove-Item 'C:\Windows\Temp\VaultInstall.zip' -Force -ErrorAction SilentlyContinue
Write-Host "  Vault: `$((Get-ChildItem 'C:\CyberArkInstall\Vault' -Recurse -File).Count) files"
"@ -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

# --- Client installer ---
Write-Host "  Transferring Client installer..." -ForegroundColor DarkGray
$clientZip = Join-Path $env:TEMP "ClientInstall_$(Get-Random).zip"
try {
    Compress-Archive -Path "$clientInstallerHost\*" -DestinationPath $clientZip -Force
    $zipSizeMB = [math]::Round((Get-Item $clientZip).Length / 1MB, 1)
    Write-Host "    ($zipSizeMB MB)" -ForegroundColor DarkGray
    Copy-FileToLabVM -VMXPath $vaultVMX -HostPath $clientZip `
        -GuestPath 'C:\Windows\Temp\ClientInstall.zip' `
        -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
} finally {
    Remove-Item $clientZip -Force -ErrorAction SilentlyContinue
}
Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock @"
Expand-Archive 'C:\Windows\Temp\ClientInstall.zip' 'C:\CyberArkInstall\Client' -Force
Remove-Item 'C:\Windows\Temp\ClientInstall.zip' -Force -ErrorAction SilentlyContinue
Write-Host "  Client: `$((Get-ChildItem 'C:\CyberArkInstall\Client' -Recurse -File).Count) files"
"@ -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

# --- Keys ---
Write-Host "  Copying keys..." -ForegroundColor DarkGray
Get-ChildItem $masterKeyHost -File | ForEach-Object {
    Copy-FileToLabVM -VMXPath $vaultVMX -HostPath $_.FullName `
        -GuestPath "$masterKeyGuest\$($_.Name)" `
        -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
}
Get-ChildItem $operatorKeyHost -File | ForEach-Object {
    Copy-FileToLabVM -VMXPath $vaultVMX -HostPath $_.FullName `
        -GuestPath "$operatorKeyGuest\$($_.Name)" `
        -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
}

# --- License ---
if (Test-Path $licenseHost) {
    Copy-FileToLabVM -VMXPath $vaultVMX -HostPath $licenseHost `
        -GuestPath $CAConfig.Vault.Guest.LicenseFile `
        -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
} else {
    Write-Warning "License file not found at $licenseHost"
}

# --- ISS files (byte-for-byte) ---
Write-Host "  Copying ISS files (byte-for-byte)..." -ForegroundColor DarkGray

$vaultIssSource  = "$PSScriptRoot\..\Helpers\setup.iss"
$clientIssSource = "$PSScriptRoot\..\Helpers\setup-client.iss"

if (-not (Test-Path $vaultIssSource))  { throw "Vault ISS not found: $vaultIssSource" }
if (-not (Test-Path $clientIssSource)) { throw "Client ISS not found: $clientIssSource" }

Copy-FileToLabVM -VMXPath $vaultVMX -HostPath (Resolve-Path $vaultIssSource).Path `
    -GuestPath 'C:\CyberArkInstall\Vault\setup.iss' `
    -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

Copy-FileToLabVM -VMXPath $vaultVMX -HostPath (Resolve-Path $clientIssSource).Path `
    -GuestPath 'C:\CyberArkInstall\Client\setup.iss' `
    -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

Write-Host "  [OK] All media copied" -ForegroundColor Green

# ================================================================
# Step 2: Validate files
# ================================================================
Write-Host "`n[Step 2] Validating files..." -ForegroundColor Yellow

$validateScript = @"
`$fail = `$false
foreach (`$f in @(
    'C:\CyberArkInstall\Vault\setup.exe', 'C:\CyberArkInstall\Vault\setup.iss',
    'C:\CyberArkInstall\Client\setup.exe', 'C:\CyberArkInstall\Client\setup.iss'
)) {
    if (Test-Path `$f) { Write-Host "  [OK] `$f" -ForegroundColor Green }
    else { Write-Host "  [FAIL] `$f" -ForegroundColor Red; `$fail = `$true }
}
foreach (`$f in @('recprv.key','recpub.key','rndbase.dat','server.key')) {
    if (Test-Path (Join-Path '$masterKeyGuest' `$f)) { Write-Host "  [OK] Master\`$f" -ForegroundColor Green }
    else { Write-Host "  [FAIL] Master\`$f" -ForegroundColor Red; `$fail = `$true }
}
foreach (`$f in @('recpub.key','rndbase.dat','server.key')) {
    if (Test-Path (Join-Path '$operatorKeyGuest' `$f)) { Write-Host "  [OK] Operator\`$f" -ForegroundColor Green }
    else { Write-Host "  [FAIL] Operator\`$f" -ForegroundColor Red; `$fail = `$true }
}
if (`$fail) { throw "Required files missing." }
Write-Host "  [OK] All validated" -ForegroundColor Green
"@
Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock $validateScript `
    -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

# ================================================================
# Step 3: Prerequisites
# ================================================================
Write-Host "`n[Step 3] Configuring prerequisites..." -ForegroundColor Yellow

Invoke-LabVMPowerShell -VMXPath $vaultVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$ErrorActionPreference = 'SilentlyContinue'
foreach ($svc in @('Spooler', 'WSearch', 'TabletInputService')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  Disabled: $svc"
    }
}
Write-Host "  [OK] Prerequisites done"
'@ | Out-Null

# ================================================================
# Step 4: Install Vault Server + PrivateArk Client
#
# Both run in a single guest session. Neither triggers a reboot:
#   Vault ISS:  BootOption=0
#   Client ISS: Result=1, BootOption=0
# Script reboots explicitly in Step 5.
# ================================================================
Write-Host "`n[Step 4] Installing Vault Server + PrivateArk Client..." -ForegroundColor Yellow

$installBoth = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\LabSetup\Logs\vault_install_transcript.log' -Force | Out-Null

# --- Vault Server ---
Write-Host 'Installing Vault Server...' -ForegroundColor Cyan
Set-Location 'C:\CyberArkInstall\Vault'

`$vaultService = Get-Service -Name 'PrivateArk Server' -ErrorAction SilentlyContinue
if (`$vaultService) {
    Write-Host "  [SKIP] Already installed" -ForegroundColor Yellow
} else {
    `$guid = '{BF1F0850-D1C7-11D3-8E83-0000E8EFAFE3}'
    foreach (`$rp in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$guid",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\`$guid",
        "HKLM:\SOFTWARE\InstallShield\Installed Products\`$guid",
        "HKLM:\SOFTWARE\WOW6432Node\InstallShield\Installed Products\`$guid",
        "HKLM:\SYSTEM\CurrentControlSet\Services\PrivateArk Server",
        "HKLM:\SYSTEM\CurrentControlSet\Services\CyberArk Logic Container",
        "HKLM:\SYSTEM\CurrentControlSet\Services\CyberArk Event Notification Engine"
    )) {
        if (Test-Path `$rp) { Remove-Item `$rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    `$vaultProc = Start-Process -FilePath '.\setup.exe' -ArgumentList '/s' -Wait -PassThru -NoNewWindow
    `$sw.Stop()
    Write-Host "  Exit: `$(`$vaultProc.ExitCode) (`$([math]::Round(`$sw.Elapsed.TotalSeconds))s)"

    if (Test-Path '.\setup.log') {
        Get-Content '.\setup.log' | Write-Host
    }

    `$files = (Get-ChildItem 'C:\Program Files (x86)\PrivateArk\Server' -File -Recurse -ErrorAction SilentlyContinue).Count
    if (`$vaultProc.ExitCode -eq 0 -and `$files -gt 10) {
        Write-Host "  [OK] Vault installed (`$files files)" -ForegroundColor Green
    } else {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        throw "Vault failed. Exit: `$(`$vaultProc.ExitCode), Files: `$files"
    }
}

# --- PrivateArk Client ---
Write-Host 'Installing PrivateArk Client...' -ForegroundColor Cyan
Set-Location 'C:\CyberArkInstall\Client'

if (Test-Path 'C:\Program Files (x86)\PrivateArk\Client\PrivateArk.exe') {
    Write-Host "  [SKIP] Already installed" -ForegroundColor Yellow
} else {
    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    `$clientProc = Start-Process -FilePath '.\setup.exe' -ArgumentList '/s' -Wait -PassThru -NoNewWindow
    `$sw.Stop()
    Write-Host "  Exit: `$(`$clientProc.ExitCode) (`$([math]::Round(`$sw.Elapsed.TotalSeconds))s)"

    if (Test-Path '.\setup.log') {
        Get-Content '.\setup.log' | Write-Host
    }

    if (`$clientProc.ExitCode -eq 0) {
        Write-Host "  [OK] Client installed" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Client failed (exit `$(`$clientProc.ExitCode)) - continuing" -ForegroundColor Yellow
    }
}

Write-Host "Both installers complete." -ForegroundColor Green
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
"@

$installResult = Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock $installBoth `
    -GuestUser $guestUser -GuestPassword $guestPass -NoThrow

if ($installResult.ExitCode -ne 0) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logDir = "$PSScriptRoot\..\Logs"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    foreach ($logInfo in @(
        @{ Guest = 'C:\CyberArkInstall\Vault\setup.log';  Host = "$logDir\vault_setup_$timestamp.log";  Label = 'vault setup.log' },
        @{ Guest = 'C:\CyberArkInstall\Client\setup.log'; Host = "$logDir\client_setup_$timestamp.log"; Label = 'client setup.log' },
        @{ Guest = 'C:\LabSetup\Logs\vault_install_transcript.log'; Host = "$logDir\transcript_$timestamp.log"; Label = 'transcript' }
    )) {
        try {
            Copy-FileFromLabVM -VMXPath $vaultVMX `
                -GuestPath $logInfo.Guest -HostPath $logInfo.Host `
                -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
            Write-Host "`n=== $($logInfo.Label) ===" -ForegroundColor Yellow
            Get-Content $logInfo.Host | Write-Host
        } catch { Write-Warning "Could not retrieve $($logInfo.Label): $_" }
    }
    throw "Installation failed. Logs: $logDir"
}

Write-Host "  [OK] Vault Server + PrivateArk Client installed" -ForegroundColor Green

# ================================================================
# Step 5: Firewall fix + reboot
#
# Vault hardening sets AllowLocalPolicyMerge=0 on all firewall
# profiles, blocking inbound allow-rules including port 1858.
# Fix the registry, add 1858 rule, then reboot.
# ================================================================
Write-Host "`n[Step 5] Applying firewall fix and rebooting..." -ForegroundColor Yellow

Invoke-LabVMPowerShell -VMXPath $vaultVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
$profiles = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile',
    'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\StandardProfile',
    'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile'
)
foreach ($p in $profiles) {
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    Set-ItemProperty -Path $p -Name 'AllowLocalIPsecPolicyMerge' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $p -Name 'AllowLocalPolicyMerge'      -Value 1 -Type DWord -Force
}
Write-Host "  [OK] AllowLocalPolicyMerge=1 on all profiles"

$ruleName = 'CyberArk Vault 1858'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
        -LocalPort 1858 -Protocol TCP -Action Allow -Profile Any | Out-Null
    Write-Host "  [OK] Firewall rule created: $ruleName"
} else {
    Write-Host "  [OK] Firewall rule exists: $ruleName"
}
'@ | Out-Null

Write-Host "  Rebooting VAULT01..." -ForegroundColor DarkGray
Restart-LabVM -VMXPath $vaultVMX
Start-Sleep -Seconds 45
Wait-LabVMReady -VMXPath $vaultVMX -TimeoutSeconds 300
Write-Host "  [OK] VAULT01 is back after reboot" -ForegroundColor Green

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "CyberArk Vault v15.0 installation complete!" -ForegroundColor Green
Write-Host "  Server:    VAULT01 ($($CAConfig.Vault.VaultAddress))" -ForegroundColor Green
Write-Host "  Port:      $($CAConfig.Vault.VaultPort) (verified by CPM pre-flight)" -ForegroundColor Green
Write-Host "  Firewall:  AllowLocalPolicyMerge=1 + port 1858 rule" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green