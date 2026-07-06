<#
.SYNOPSIS
    Configure end-to-end Vault -> PTA syslog forwarding (PSM session monitoring).
.DESCRIPTION
    Sets up the full, working chain so the Vault forwards audit records (including
    PSM session activity) to PTA for real-time analysis:

    PTA side (via SSH, /etc/opt/pta/diamond-resources/local/systemparm.properties):
      - syslog_inbound: plain TCP listener on the syslog port (keeps 514/TLS),
        dropping the same-port TLS entry so the plain-TCP syslog is accepted
      - enable_client_verification=false (no client-cert on the unsecured listener)
      - restart appmgr so the Unsecured_TCP_Listener binds

    Vault side (via vmrun guest ops, dbparm.ini):
      - [MAIN] AllowNonStandardFWAddresses: allow the Vault's own hardened firewall
        to make the OUTBOUND syslog connection to PTA:<port> (without this the Vault
        blocks itself and nothing is sent)
      - [SYSLOG]: Syslog\PTA.xsl translator, PTA IP/port/protocol, message-code
        filter, UseLegacySyslogFormat=No
      - restart the Vault service

    Defaults to 11514/TCP (unsecured) for a lab. For a secured channel use TLS and
    configure a trusted connection (add the CA root to the Vault, point the [SYSLOG]
    protocol at a TLS port); not covered here.

    Verified working: the Vault forwards Logon/session audits and PTA parses them
    (auditType_VAULT_LOGON increments; PVWA System Health shows the events).

    Usage:
      .\11c-ConfigureVaultSyslogToPTA.ps1
      .\11c-ConfigureVaultSyslogToPTA.ps1 -PrimaryPTAName PTA01 -SyslogPort 11514 -SyslogProtocol TCP
.NOTES
    Restarts PTA 'appmgr' and the 'PrivateArk Server' (Vault) service - brief downtime.
    Timestamped backups of both systemparm.properties and dbparm.ini are made first.
#>

param(
    [string]$ConfigPath     = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$PrimaryPTAName = "PTA01",
    [int]   $SyslogPort     = 11514,
    [ValidateSet("TCP", "UDP")]
    [string]$SyslogProtocol = "TCP"
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { throw "ssh.exe not found (Windows OpenSSH Client)." }
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) { throw "scp.exe not found (Windows OpenSSH Client)." }

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1"  -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$ptaVM = $Config.VMs | Where-Object { ($_.Role -eq 'PTA' -or $_.Role -contains 'PTA') -and $_.Name -eq $PrimaryPTAName } | Select-Object -First 1
if (-not $ptaVM) { throw "Primary PTA '$PrimaryPTAName' not found in $ConfigPath" }
$ptaIP = $ptaVM.IPAddress

$vaultVMX = Join-Path $Config.VMware.DefaultVMFolder "VAULT01\VAULT01.vmx"
if (-not (Test-Path $vaultVMX)) { throw "VAULT01 VMX not found at '$vaultVMX' - deploy the Vault first" }
$guestUser = $Config.LocalAdmin.Username
$guestPass = $Config.LocalAdmin.Password

# PTA lab SSH key
$labKeyPath = (Resolve-Path -LiteralPath (Split-Path (Join-Path $PSScriptRoot "..\Config\pta_lab_key"))).Path + "\pta_lab_key"
if (-not (Test-Path $labKeyPath)) { throw "Lab SSH key not found at $labKeyPath - run 10-CreatePTAVM.ps1 first" }
$sshOpts = @("-i", $labKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15")

# Vault message codes for PTA (per CyberArk PTA integration docs)
$msgCodeFilter = "295,308,7,24,31,428,361,372,373,359,436,412,411,300,302,294,427,471,4"

Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Configure Vault -> PTA syslog (session monitoring)" -ForegroundColor Cyan
Write-Host "  PTA (Primary): $PrimaryPTAName ($ptaIP)" -ForegroundColor Cyan
Write-Host "  Destination:   ${ptaIP}:${SyslogPort}/$SyslogProtocol (unsecured)" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan

# ================================================================
# Part 1: PTA - make the plain-TCP syslog listener accept the Vault
# ================================================================
Write-Host "`n[1/3] PTA: set plain-TCP syslog listener + client verification off..." -ForegroundColor Yellow

# syslog_inbound value (escaped quotes as stored in the properties file)
$q = '\"'
$sysInbound = "syslog_inbound=[{${q}port${q}:514,${q}protocol${q}:${q}TLS${q},${q}clientVerification${q}:false},{${q}port${q}:$SyslogPort,${q}protocol${q}:${q}$SyslogProtocol${q},${q}clientVerification${q}:false}]"

$ptaScript = @"
#!/bin/bash
set -e
f=/etc/opt/pta/diamond-resources/local/systemparm.properties
cp "`$f" "`$f.ptasyslogbak_`$(date +%s)"
grep -v '^syslog_inbound=' "`$f" > "`$f.tmp"
printf '%s\n' '$sysInbound' >> "`$f.tmp"
mv "`$f.tmp" "`$f"
if grep -q '^enable_client_verification=' "`$f"; then
  sed -i 's/^enable_client_verification=.*/enable_client_verification=false/' "`$f"
else
  printf 'enable_client_verification=false\n' >> "`$f"
fi
echo "SYSLOG_INBOUND: `$(grep '^syslog_inbound=' "`$f")"
echo "CLIENT_VERIF: `$(grep '^enable_client_verification=' "`$f")"
systemctl restart appmgr
for i in `$(seq 1 30); do
  sleep 5
  if ss -tlnp 2>/dev/null | grep -q ':$SyslogPort '; then echo "LISTENER_UP:$SyslogPort"; break; fi
done
ss -tlnp 2>/dev/null | grep ':$SyslogPort ' | head -1
"@

$tmpPta = Join-Path $env:TEMP "pta_syslog_cfg.sh"
[System.IO.File]::WriteAllText($tmpPta, ($ptaScript -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
& scp.exe @sshOpts $tmpPta "root@${ptaIP}:/tmp/pta_syslog_cfg.sh" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "scp of PTA config script failed (exit $LASTEXITCODE)" }
$savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$ptaOut = & ssh.exe @sshOpts "root@$ptaIP" "chmod +x /tmp/pta_syslog_cfg.sh && bash /tmp/pta_syslog_cfg.sh; rm -f /tmp/pta_syslog_cfg.sh" 2>&1
$ErrorActionPreference = $savedEAP
Remove-Item $tmpPta -ErrorAction SilentlyContinue
$ptaOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if (-not ($ptaOut -match "LISTENER_UP")) { throw "PTA syslog listener did not come up on $SyslogPort - check output above" }
Write-Host "  [OK] PTA listening (plain $SyslogProtocol) on $SyslogPort" -ForegroundColor Green

# ================================================================
# Part 2: Vault - firewall rule + [SYSLOG], then restart the Vault
# ================================================================
Write-Host "`n[2/3] Vault: dbparm.ini firewall rule + [SYSLOG], restart Vault..." -ForegroundColor Yellow
Wait-LabVMReady -VMXPath $vaultVMX -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

$fwRule = "AllowNonStandardFWAddresses=[$ptaIP],Yes,${SyslogPort}:outbound/tcp"

$guest = @"
`$ErrorActionPreference = 'Stop'
`$result = @()
try {
    `$conf = 'C:\Program Files (x86)\PrivateArk\Server\Conf\dbparm.ini'
    if (-not (Test-Path `$conf)) { throw "dbparm.ini not found at `$conf" }
    `$xsl = 'C:\Program Files (x86)\PrivateArk\Server\Syslog\PTA.xsl'
    if (-not (Test-Path `$xsl)) { throw "Syslog\PTA.xsl not found - required translator missing" }

    Copy-Item `$conf ("`$conf.ptabak_" + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
    `$result += "BACKUP_MADE"

    `$lines = Get-Content `$conf

    # (a) Ensure the Vault firewall allows the outbound syslog connection to PTA.
    if (-not (`$lines | Select-String -SimpleMatch '$fwRule')) {
        # drop any prior rule for this PTA:port then insert a fresh one after [MAIN]
        `$lines = `$lines | Where-Object { `$_ -notmatch [regex]::Escape('AllowNonStandardFWAddresses=[$ptaIP],Yes,${SyslogPort}:') }
        `$tmp = New-Object System.Collections.Generic.List[string]
        `$done = `$false
        foreach (`$l in `$lines) {
            `$tmp.Add(`$l)
            if (-not `$done -and `$l -match '^\s*\[MAIN\]\s*`$') { `$tmp.Add('$fwRule'); `$done = `$true }
        }
        if (-not `$done) { `$tmp.Insert(0,'[MAIN]'); `$tmp.Insert(1,'$fwRule') }
        `$lines = `$tmp.ToArray()
        `$result += "FW_RULE_ADDED"
    } else { `$result += "FW_RULE_PRESENT" }

    # (b) Replace the [SYSLOG] section with the PTA config.
    `$kept = New-Object System.Collections.Generic.List[string]
    `$inSys = `$false
    foreach (`$l in `$lines) {
        if (`$l -match '^\s*\[SYSLOG\]\s*`$') { `$inSys = `$true; continue }
        if (`$inSys -and `$l -match '^\s*\[') { `$inSys = `$false }
        if (-not `$inSys) { `$kept.Add(`$l) }
    }
    while (`$kept.Count -gt 0 -and `$kept[`$kept.Count-1] -match '^\s*`$') { `$kept.RemoveAt(`$kept.Count-1) }
    `$kept.Add('[SYSLOG]')
    `$kept.Add('SyslogTranslatorFile=Syslog\PTA.xsl')
    `$kept.Add('SyslogServerIP=$ptaIP')
    `$kept.Add('SyslogServerPort=$SyslogPort')
    `$kept.Add('SyslogServerProtocol=$SyslogProtocol')
    `$kept.Add('SyslogMessageCodeFilter=$msgCodeFilter')
    `$kept.Add('UseLegacySyslogFormat=No')

    Set-Content -Path `$conf -Value `$kept -Encoding Ascii
    `$result += "WROTE_DBPARM"

    Restart-Service 'PrivateArk Server' -Force
    Start-Sleep -Seconds 10
    `$result += "SERVICE:" + (Get-Service 'PrivateArk Server').Status
    Start-Sleep -Seconds 5
    `$t = Test-NetConnection -ComputerName '$ptaIP' -Port $SyslogPort -WarningAction SilentlyContinue
    `$result += "REACH_PTA:" + `$t.TcpTestSucceeded
    `$result += "OK"
} catch { `$result += "ERROR:`$(`$_.Exception.Message)" }
Set-Content -Path 'C:\Windows\Temp\vault_syslog_result.txt' -Value `$result -Encoding UTF8
"@

Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock $guest -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
$localResult = Join-Path $env:TEMP "vault_syslog_result.txt"
Remove-Item $localResult -Force -ErrorAction SilentlyContinue
Copy-FileFromLabVM -VMXPath $vaultVMX -GuestPath "C:\Windows\Temp\vault_syslog_result.txt" `
    -HostPath $localResult -GuestUser $guestUser -GuestPassword $guestPass
$out = Get-Content $localResult
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host "`n[3/3] Result" -ForegroundColor Yellow
if (($out -contains 'OK') -and ($out | Where-Object { $_ -match '^SERVICE:Running' }) -and ($out | Where-Object { $_ -match '^REACH_PTA:True' })) {
    Write-Host "  [OK] Vault -> PTA syslog is live (firewall + [SYSLOG] set, Vault can reach PTA:$SyslogPort)." -ForegroundColor Green
    Write-Host "  PSM session and Vault audit events will now appear in PTA / PVWA System Health." -ForegroundColor DarkGray
} else {
    throw "Vault syslog configuration failed - see output above. Backups: dbparm.ini.ptabak_* on the Vault, systemparm.properties.ptasyslogbak_* on PTA."
}
