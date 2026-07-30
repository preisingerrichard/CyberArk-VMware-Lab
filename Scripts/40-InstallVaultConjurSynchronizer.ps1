<#
.SYNOPSIS
    Install the CyberArk Vault-Conjur Synchronizer on COMP01, syncing a
    Vault safe's accounts into Conjur read-only (LOB - Line of Business).
.DESCRIPTION
    UNTESTED end-to-end as a script - validated manually on COMP01 first
    (per this repo's standing practice), then written up here. Two real
    environmental gaps were hit during the manual run and are handled
    below; the automated installer-execution step (Phase 5) is the one
    genuinely unverified part - see the warning there.

    Phase 1: idempotency check (Windows service; also checks for the
             ConjurSync Safe via PVWA REST to catch a PARTIAL prior attempt,
             since that changes the installer's prompt sequence - see
             Phase 5)
    Phase 2: fix Windows Server 2022's IE first-launch-config gap. The
             installer's own PowerShell modules call `Invoke-WebRequest`
             without `-UseBasicParsing` (Windows PowerShell 5.1's version
             of that cmdlet defaults to parsing responses via the IE COM
             engine); on a fresh server build IE's first-run wizard was
             never completed, and every REST call in the installer fails
             with "the Internet Explorer engine is not available... Specify
             the UseBasicParsing parameter." Not something to patch inside
             CyberArk's own installer modules - fix the underlying Windows
             state instead via the DisableFirstRunCustomize registry key.
             Idempotent, harmless to always apply.
    Phase 3: ensure the target Vault platform exists (via PVWA REST). This
             lab's Vault had NO platform matching the deck's expected
             "CyberArk Vault" name at all - not inactive, genuinely absent.
             Confirmed via Platform Management: 15 platforms total
             (Windows/PSM/*NIX/Database/Conjur Host groups), none named
             for Vault-internal service accounts. Fixed by importing a
             platform package via PVWA's platform-import REST endpoint -
             pass -PlatformZipPath pointing at a real platform .zip (a
             downloaded CyberArk platform package, NOT something this
             script fabricates) if the target platform is missing.
             **The "CyberArk Digital Vault" platform (PolicyID
             CyberArkDigitalVault) must be downloaded manually from the
             CyberArk Marketplace - its license does not permit
             redistribution, so it can never be committed to this repo or
             staged in the Installers\ folder, even gitignored.** Point
             -PlatformZipPath at wherever you've downloaded it yourself.
    Phase 4: verify the Synchronizer installer media is already staged on
             COMP01 - this script does NOT attempt to copy/stage it (unlike
             Scripts\07's PVWA zip-transfer pattern), since the host-side
             source location for this specific media wasn't an established
             convention in this repo when this was written. Throws with
             clear guidance if missing rather than guessing a source path.
    Phase 5: run V5SynchronizerInstallation.ps1 NON-INTERACTIVELY via real
             OS-level stdin redirection (Start-Process
             -RedirectStandardInput pointed at a file of newline-separated
             answers, matching the exact validated prompt sequence from two
             live manual runs on this lab). This is genuinely UNTESTED as
             automation: `Read-Host` is well known NOT to reliably consume
             PowerShell's `|` object pipeline (it talks to the console host
             directly), which is why this uses true process-level stdin
             redirection instead - the same mechanism `cmd /c "foo < file"`
             uses, which interactive console apps are far more likely to
             honor. Still worth watching closely on the first real run:
             a misaligned answer (e.g. if this hits the "Safe already
             exists, continue?" prompt unexpectedly, which only appears on
             a retry against a partially-completed prior attempt) could
             feed the WRONG value into the WRONG prompt - concretely, a
             mistyped/misaligned Vault admin password is exactly what
             caused a real lockout scare during this lab's own manual run.
             Phase 1's Safe-existence check exists specifically to catch
             that retry scenario before Phase 5 ever runs.
    Phase 6: check the captured installer output for the literal string
             "Vault Synchronizer installed successfully" before declaring
             success - never trust exit code alone for a Read-Host-driven
             script wrapped in stdin redirection.
.EXAMPLE
    .\40-InstallVaultConjurSynchronizer.ps1 -PlatformZipPath 'C:\Downloads\CyberArkDigitalVault.zip'
.NOTES
    Prerequisites: Conjur Leader configured and healthy, admin credentials
    known. Vault/PVWA up (COMP01). Vault-Conjur Synchronizer installer
    already extracted on COMP01 (this script checks, does not stage it).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath   = "$PSScriptRoot\..\Config\LabConfig.psd1",

    # Synchronizer instance / install
    [string]$InstanceName          = "COMP01",
    [string]$SynchronizerInstallerPath = "C:\CyberArkInstall\VaultConjurSynchronizer-Rls-v13.9.0\Installation\V5SynchronizerInstallation.ps1",

    # Vault / PVWA
    [string]$VaultAlias    = "vault01",
    [string]$PvwaUrl       = "https://comp01.cyberark.lab",
    [string]$VaultAddress  = "192.168.100.20",
    [string]$VaultAdminUser = "Administrator",
    [string]$VaultAdminPassword = "Cyberark1",
    [string]$SafeName      = "ConjurSync",

    # Conjur
    [string]$ConjurUrl     = "https://conjur-cluster.cyberark.lab",
    [string]$ConjurAccount = "cyberark",
    [string]$ConjurAdminUser = "admin",
    [string]$ConjurAdminPassword = "Cyberark!Local2024",

    # LOB
    [string]$LobName       = "secrets",
    [string]$PlatformName  = "CyberArk Digital Vault",
    [string]$PlatformZipPath,   # required only if $PlatformName doesn't already exist in the Vault

    [switch]$Force   # bypass the Phase 1 partial-install-safety-stop
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"
$compVM      = $Config.VMs | Where-Object { $_.Name -eq 'COMP01' }
$compVMX     = $deployedVMs[$compVM.Name]
if (-not $compVMX) { throw "COMP01 not found in DeployedVMs.xml" }

$guestUser = "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)"
$guestPass = $Config.Domain.DomainAdminPass

Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Vault-Conjur Synchronizer install on COMP01" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan

Wait-LabVMReady -VMXPath $compVMX

# ================================================================
# PVWA REST helpers (self-contained - this script can run standalone,
# same pattern as Deploy-Optional.ps1's Connect-PVWA but scoped here)
# ================================================================
$pvwaBase = "$PvwaUrl/PasswordVault"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $iwr = @{ UseBasicParsing = $true; SkipCertificateCheck = $true }
} else {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $iwr = @{ UseBasicParsing = $true }
}
function Connect-PVWALocal {
    $tok = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Cyberark/Logon" -Method POST `
        -Body (@{ username=$VaultAdminUser; password=$VaultAdminPassword; concurrentSession=$true } | ConvertTo-Json) `
        -ContentType "application/json").Content.Trim('"')
    return @{ Authorization = $tok }
}
function Disconnect-PVWALocal {
    param($Headers)
    if ($Headers) { Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Logoff" -Method POST -Headers $Headers -ErrorAction SilentlyContinue | Out-Null }
}

# ================================================================
# Phase 1: idempotency + partial-install safety check
# ================================================================
Write-Host "`n[Phase 1] Checking current state..." -ForegroundColor Yellow
$svcCheck = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -ScriptBlock @'
$svc = Get-Service -Name "CyberArkVaultConjurSynchronizer*" -ErrorAction SilentlyContinue
if ($svc) { if ($svc.Status -eq 'Running') { exit 0 } else { exit 2 } } else { exit 1 }
'@
# Exit 0 = installed and running, 2 = installed but stopped (still "done" -
# a service existing regardless of current run state means the install
# itself succeeded; NOT evidence of a partial/failed attempt. Confirmed
# live: the service can be created and left Stopped by a fully successful
# run - conflating "not running" with "not installed" was a real bug here
# on the first version of this script, caught because the actual state on
# COMP01 didn't match what this check assumed.
if ($svcCheck.ExitCode -eq 0) {
    Write-Host "  Synchronizer service already installed and running - nothing to do." -ForegroundColor Yellow
    exit 0
}
if ($svcCheck.ExitCode -eq 2) {
    Write-Host "  Synchronizer service already installed (currently Stopped) - nothing to do. Start it manually if it needs to be actively syncing:" -ForegroundColor Yellow
    Write-Host "    Start-Service -Name CyberArkVaultConjurSynchronizer   (run on COMP01)" -ForegroundColor Yellow
    exit 0
}

$pvwaHdr = Connect-PVWALocal
try {
    $safeExists = $false
    try {
        Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Safes/$SafeName" -Headers $pvwaHdr | Out-Null
        $safeExists = $true
    } catch { $safeExists = $false }

    if ($safeExists -and -not $Force) {
        throw "Safe '$SafeName' already exists but the Synchronizer service isn't running - " +
              "this looks like a partial prior install attempt. The installer will prompt " +
              "'$SafeName already exists. Continue?' which this script's fixed answer sequence " +
              "does NOT account for (it would misalign every prompt after it, same class of " +
              "risk that caused a real password mix-up during this lab's own manual run). " +
              "Either clean up the partial Safe/accounts manually and re-run, or pass -Force " +
              "to attempt anyway (only safe if you've verified the answer sequence still lines up)."
    }
    Write-Host "  [OK] Clean state - Safe '$SafeName' does not exist yet, safe to proceed" -ForegroundColor Green

    # ================================================================
    # Phase 2: IE first-launch registry fix (idempotent)
    # ================================================================
    Write-Host "`n[Phase 2] Ensuring IE first-launch config won't block Invoke-WebRequest..." -ForegroundColor Yellow
    Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock @'
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main' -Name 'DisableFirstRunCustomize' -Value 1 -Type DWord
'@ | Out-Null
    Write-Host "  [OK]" -ForegroundColor Green

    # ================================================================
    # Phase 3: ensure the target platform exists
    # ================================================================
    Write-Host "`n[Phase 3] Checking Vault platform '$PlatformName'..." -ForegroundColor Yellow
    $platforms = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Platforms" -Headers $pvwaHdr).Content | ConvertFrom-Json
    $platformExists = $platforms.Platforms | Where-Object { $_.Name -eq $PlatformName -or $_.PlatformID -eq $PlatformName }
    if ($platformExists) {
        Write-Host "  [OK] Platform '$PlatformName' already present" -ForegroundColor Green
    } else {
        if (-not $PlatformZipPath) {
            throw "Platform '$PlatformName' does not exist in this Vault, and no -PlatformZipPath " +
                  "was given to import it. This lab's Vault had zero Vault-internal-service-account " +
                  "platforms until one was manually imported via PVWA's Platform Management > Import " +
                  "screen - pass -PlatformZipPath pointing at a real downloaded platform .zip, or " +
                  "import it manually in PVWA first and re-run."
        }
        if (-not (Test-Path $PlatformZipPath)) { throw "PlatformZipPath not found: $PlatformZipPath" }
        Write-Host "  Importing platform from $PlatformZipPath..." -ForegroundColor DarkGray
        $zipB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PlatformZipPath))
        Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Platforms/Import" -Method POST `
            -Body (@{ ImportFile = $zipB64 } | ConvertTo-Json) -ContentType "application/json" -Headers $pvwaHdr | Out-Null
        Write-Host "  [OK] Platform imported" -ForegroundColor Green
    }
} finally {
    Disconnect-PVWALocal -Headers $pvwaHdr
}

# ================================================================
# Phase 4: verify installer media is staged (does not stage it itself)
# ================================================================
Write-Host "`n[Phase 4] Verifying Synchronizer installer is staged on COMP01..." -ForegroundColor Yellow
$mediaCheck = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -ScriptBlock @"
if (Test-Path '$SynchronizerInstallerPath') { exit 0 } else { exit 1 }
"@
if ($mediaCheck.ExitCode -ne 0) {
    throw "Synchronizer installer not found at $SynchronizerInstallerPath on COMP01. " +
          "Stage the Vault-Conjur Synchronizer installation media there first (this script " +
          "does not copy it - no established host-side media convention for it in this repo yet)."
}
Write-Host "  [OK]" -ForegroundColor Green

# ================================================================
# Phase 5: run the installer non-interactively via real stdin redirection
# ================================================================
Write-Host "`n[Phase 5] Running Synchronizer installer (non-interactive, UNTESTED automation path - watch closely)..." -ForegroundColor Yellow

# Exact validated prompt order from two live manual runs on this lab.
# Blank entries accept the installer's own displayed default.
$answers = @(
    "ent",                  # Conjur Cloud or Enterprise
    "no",                   # HA Synchronizer cluster
    $InstanceName,          # instance name
    "",                     # install target path (default)
    $VaultAlias,            # Vault alias
    $PvwaUrl,                # PVWA/Privilege Cloud Portal URL
    $VaultAddress,           # Vault IP/FQDN
    "",                     # Vault port (default 1858)
    $VaultAdminUser,         # Vault admin username
    $VaultAdminPassword,     # Vault admin password
    $SafeName,               # Safe name
    $ConjurUrl,               # Conjur server hostname/port
    $ConjurAccount,           # Conjur account name
    $ConjurAdminUser,         # Conjur username
    $ConjurAdminPassword,     # Conjur API key/password
    "yes",                   # create LOBs now
    $LobName,                 # LOB name
    $PlatformName              # CyberArk Vault platform name for the LOB account
)

$remoteAnswersFile = "C:\LabSetup\synchronizer_answers.txt"
$remoteOutFile     = "C:\LabSetup\synchronizer_install_out.log"
$remoteErrFile     = "C:\LabSetup\synchronizer_install_err.log"

# Write the answers file on the guest (avoids re-encoding secrets through
# guest-ops script text more than once)
$answersScript = "New-Item -Path 'C:\LabSetup' -ItemType Directory -Force | Out-Null`n"
$answersScript += "@(`n"
foreach ($a in $answers) { $answersScript += "  '$($a -replace "'", "''")',`n" }
$answersScript += ") | Set-Content -Path '$remoteAnswersFile' -Encoding ASCII"
Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -ScriptBlock $answersScript | Out-Null

$runScript = @"
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = "powershell.exe"
`$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "$SynchronizerInstallerPath"'
`$psi.RedirectStandardInput = `$true
`$psi.RedirectStandardOutput = `$true
`$psi.RedirectStandardError = `$true
`$psi.UseShellExecute = `$false
`$proc = [System.Diagnostics.Process]::Start(`$psi)
`$answerLines = Get-Content '$remoteAnswersFile'
foreach (`$line in `$answerLines) { `$proc.StandardInput.WriteLine(`$line) }
`$proc.StandardInput.Close()
`$stdout = `$proc.StandardOutput.ReadToEnd()
`$stderr = `$proc.StandardError.ReadToEnd()
`$proc.WaitForExit(600000) | Out-Null
`$stdout | Set-Content -Path '$remoteOutFile'
`$stderr | Set-Content -Path '$remoteErrFile'
exit `$proc.ExitCode
"@
$installResult = Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -TimeoutSeconds 660 -ScriptBlock $runScript

# ================================================================
# Phase 6: verify success from captured output, not exit code alone
# ================================================================
Write-Host "`n[Phase 6] Verifying result..." -ForegroundColor Yellow
$outLog = "$PSScriptRoot\..\Logs\synchronizer_install_out_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -Path (Split-Path $outLog) -ItemType Directory -Force | Out-Null
try {
    Copy-FileFromLabVM -VMXPath $compVMX -GuestPath $remoteOutFile -HostPath $outLog -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
} catch { Write-Warning "Could not retrieve install output log: $_" }

$outContent = if (Test-Path $outLog) { Get-Content $outLog -Raw } else { "" }
# Clear the answers file - contains the Vault admin password and Conjur API key in plaintext
Invoke-LabVMPowerShell -VMXPath $compVMX -GuestUser $guestUser -GuestPassword $guestPass -NoThrow -ScriptBlock "Remove-Item '$remoteAnswersFile' -Force -ErrorAction SilentlyContinue" | Out-Null

if ($outContent -match 'Vault Synchronizer installed successfully') {
    Write-Host "  [OK] Vault Synchronizer installed successfully." -ForegroundColor Green
} else {
    Write-Host "`n=== Captured installer output ===" -ForegroundColor Yellow
    Write-Host $outContent -ForegroundColor Gray
    throw "Installer did not report success - review the output above (also saved to $outLog) before assuming this worked. " +
          "If a prompt was answered incorrectly (e.g. this hit an unexpected extra prompt), check the Vault for a locked " +
          "$VaultAdminUser account before retrying."
}

Write-Host "`nDone. Verify in PVWA ($SafeName Safe -> LOBUser_$LobName + ConjurHost accounts) and in the Conjur UI (new Group/Host/Layer)." -ForegroundColor Cyan
