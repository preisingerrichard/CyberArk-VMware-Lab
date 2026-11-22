<#
.SYNOPSIS
    Configure the Vault LDAP integration: directory + group mappings (PVWA REST).
.DESCRIPTION
    Makes the AD objects from 16-CreateVaultADObjects.ps1 usable for Vault logon.
    Plain LDAP (389) - LDAPS is deliberately out of scope for the lab.

    Vault side (via vmrun guest ops on VAULT01):
      - hosts file entry for DC01 (the hardened Vault has no working DNS path)
      - dbparm.ini [MAIN] AllowNonStandardFWAddresses=[<DC IP>],Yes,389:outbound/tcp
        so the Vault's own firewall allows the outbound LDAP connection. Backed up
        first; the Vault service is restarted ONLY if the rule was added.

    PVWA side (REST, as the Vault admin):
      - bind account stored in safe VaultInternal on Win-Dom-SvcAcc, the shared
        lab service-account platform (duplicated from WinDomain - see
        Helpers\PVWAHelper.psm1; moved there if it is on another platform).
        Automatic management OFF so the CPM never rotates a password the
        directory depends on. WinDomain is a Marketplace package and is not
        shipped: pass -WinDomainZipPath to import it, else the platform is
        duplicated from the built-in WindowsDomainLDAP (WARN).
        (-GrantPTAAppUserRead also gives PTAAppUser read on that safe)
      - LDAP directory <domain> -> DC01:389, bind user, MicrosoftADProfile.ini
      - LDAP authentication method enabled
      - directory mappings:
          Lab Vault Admins        Lab-Vault-Admins       -> Vault Admins + admin authorizations
          Lab Vault Auditors      Lab-Vault-Auditors     -> Auditors + Audit Users
          Lab Vault Safe Managers Lab-Vault-SafeManagers -> Add Safes
          Lab Vault Users         Lab-Vault-Users        -> (logon only)
      - verification: LDAP logon to PVWA as one user per role (creates the Vault
        user on first logon, which is normal LDAP behaviour). -SkipLogonTest skips it.

    Everything is skip-if-exists; a second run changes nothing.

    Usage:
      .\17-ConfigureVaultLDAP.ps1
      .\17-ConfigureVaultLDAP.ps1 -GrantPTAAppUserRead
.NOTES
    Run after 16-CreateVaultADObjects.ps1 and PVWA install. If the firewall rule is
    new, the 'PrivateArk Server' (Vault) service restarts - brief downtime.
#>

param(
    [string]$ConfigPath    = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$BindUser      = "svc-cybr-ldap",
    [string]$BindPassword  = "Cyberark1!",
    [string]$SafeName      = "VaultInternal",
    [string]$AccountName   = "cyberark.lab.pass",
    [string]$PlatformId    = "Win-Dom-SvcAcc",  # shared lab service-account platform (duplicated from WinDomain)
    [string]$WinDomainZipPath,                  # Marketplace WinDomain package - only if WinDomain isn't in the Vault
    [switch]$GrantPTAAppUserRead,
    [string]$TestPassword  = "Cyberark1!",     # password of the vault_* test users (16's -UserPassword)
    [switch]$SkipLogonTest
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\PVWAHelper.psm1"   -Force

$Config = Import-PowerShellDataFile $ConfigPath
$CA     = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

$domain  = $Config.Domain.Name
$baseDN  = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
$upn     = "$BindUser@$domain"
$dcVM    = $Config.VMs | Where-Object { $_.Role -eq 'DomainController' -or $_.Role -contains 'DomainController' } | Select-Object -First 1
$dcIP    = $dcVM.IPAddress
$dcFQDN  = "$($dcVM.Name.ToLower()).$domain"
$pvwaVM  = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -eq 'PVWA' } | Select-Object -First 1
$pvwaBase = "https://$($pvwaVM.IPAddress)/PasswordVault"

$vaultVMX = Join-Path $Config.VMware.DefaultVMFolder "VAULT01\VAULT01.vmx"
if (-not (Test-Path $vaultVMX)) { throw "VAULT01 VMX not found at '$vaultVMX' - deploy the Vault first" }
$guestUser = $Config.LocalAdmin.Username
$guestPass = $Config.LocalAdmin.Password

$mappings = @(
    @{ Name = "Lab Vault Admins";        Group = "Lab-Vault-Admins";       VaultGroups = @("Vault Admins")
       Auth = @("AddUpdateUsers","AddSafes","AddNetworkAreas","ManageServerFileCategories","AuditUsers","ResetUsersPasswords","ActivateUsers")
       TestUser = "vault_admin1" },
    @{ Name = "Lab Vault Auditors";      Group = "Lab-Vault-Auditors";     VaultGroups = @("Auditors"); Auth = @("AuditUsers"); TestUser = "vault_auditor1" },
    @{ Name = "Lab Vault Safe Managers"; Group = "Lab-Vault-SafeManagers"; VaultGroups = @();           Auth = @("AddSafes");   TestUser = "vault_safemgr1" },
    @{ Name = "Lab Vault Users";         Group = "Lab-Vault-Users";        VaultGroups = @();           Auth = @();             TestUser = "vault_user1" }
)

# ---- PVWA helpers (PS 5.1 + 7) -----------------------------------
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $iwr = @{ UseBasicParsing = $true; SkipCertificateCheck = $true }
} else {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $iwr = @{ UseBasicParsing = $true }
}
function Connect-PVWA {
    # Retries: right after a Vault restart PVWA needs a moment to reconnect.
    for ($i = 1; $i -le 12; $i++) {
        try {
            $script:pvwaTok = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Cyberark/Logon" -Method POST `
                -Body (@{ username=$CA.Vault.AdminUser; password=$CA.Vault.AdminPassword; concurrentSession=$true } | ConvertTo-Json) `
                -ContentType "application/json").Content.Trim('"')
            $script:pvwaHdr = @{ Authorization = $script:pvwaTok }
            return
        } catch {
            if ($i -eq 12) { throw "PVWA logon failed ($pvwaBase): $($_.ErrorDetails.Message) $($_.Exception.Message)" }
            Start-Sleep 10
        }
    }
}
function Disconnect-PVWA {
    if ($script:pvwaTok) { Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Logoff" -Method POST -Headers $script:pvwaHdr -ErrorAction SilentlyContinue | Out-Null; $script:pvwaTok = $null }
}
function Invoke-PVWA {
    param([string]$Path, [string]$Method = "GET", [object]$Body)
    $p = @{ Uri = "$pvwaBase$Path"; Method = $Method; Headers = $script:pvwaHdr; ContentType = "application/json" }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 6) }
    try { $r = Invoke-WebRequest @iwr @p } catch { throw "PVWA $Method $Path failed: $($_.ErrorDetails.Message) $($_.Exception.Message)" }
    if ($r.Content) { return $r.Content | ConvertFrom-Json }
}

Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Configure Vault LDAP integration (UNTESTED from scratch - feedback welcome)" -ForegroundColor Cyan
Write-Host "  Directory: $domain -> ${dcFQDN}:389 ($dcIP), bind $upn" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan

# ---- pre-flight --------------------------------------------------
$t = Test-NetConnection -ComputerName $dcIP -Port 389 -WarningAction SilentlyContinue
if (-not $t.TcpTestSucceeded) { throw "DC01 ($dcIP) is not answering on 389/tcp from this host - is the DC up?" }
# Same simple bind the Vault will do - fail here with a clear message instead of a PVWA "Code(21, 49)".
Add-Type -AssemblyName System.DirectoryServices.Protocols
$ldap = New-Object System.DirectoryServices.Protocols.LdapConnection("${dcIP}:389")
$ldap.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
$ldap.SessionOptions.ProtocolVersion = 3
try { $ldap.Bind((New-Object System.Net.NetworkCredential($upn, $BindPassword))) }
catch { throw "LDAP bind as $upn failed ($($_.Exception.Message)) - wrong -BindPassword? Run 16-CreateVaultADObjects.ps1 -ResetBindPassword to set it." }
finally { $ldap.Dispose() }
Write-Host "  [OK] Pre-flight: DC01 389 reachable, bind as $upn works" -ForegroundColor Green

# ================================================================
# Part 1: Vault - hosts entry + firewall rule for outbound LDAP
# ================================================================
Write-Host "`n[1/4] Vault: hosts entry + dbparm.ini firewall rule (389 outbound)..." -ForegroundColor Yellow
Wait-LabVMReady -VMXPath $vaultVMX -GuestUser $guestUser -GuestPassword $guestPass | Out-Null

$fwRule = "AllowNonStandardFWAddresses=[$dcIP],Yes,389:outbound/tcp"
$guest = @"
`$ErrorActionPreference = 'Stop'
`$result = @()
try {
    `$hosts = "`$env:SystemRoot\System32\drivers\etc\hosts"
    if (Select-String -Path `$hosts -Pattern '^\s*[0-9.]+\s+.*\b$([regex]::Escape($dcFQDN))\b' -Quiet) { `$result += "HOSTS_PRESENT" }
    else { Add-Content -Path `$hosts -Value "$dcIP`t$dcFQDN $($dcVM.Name.ToLower())" -Encoding Ascii; `$result += "HOSTS_ADDED" }

    `$conf = 'C:\Program Files (x86)\PrivateArk\Server\Conf\dbparm.ini'
    if (-not (Test-Path `$conf)) { throw "dbparm.ini not found at `$conf" }
    `$lines = Get-Content `$conf
    if (`$lines | Where-Object { `$_.Trim() -eq '$fwRule' }) { `$result += "FW_RULE_PRESENT" }
    else {
        Copy-Item `$conf ("`$conf.ldapbak_" + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
        `$tmp = New-Object System.Collections.Generic.List[string]
        `$done = `$false
        foreach (`$l in `$lines) {
            `$tmp.Add(`$l)
            if (-not `$done -and `$l -match '^\s*\[MAIN\]\s*`$') { `$tmp.Add('$fwRule'); `$done = `$true }
        }
        if (-not `$done) { throw "[MAIN] section not found in dbparm.ini" }
        Set-Content -Path `$conf -Value `$tmp -Encoding Ascii
        `$result += "FW_RULE_ADDED"
        Restart-Service 'PrivateArk Server' -Force
        Start-Sleep -Seconds 15
        `$result += "VAULT_RESTARTED:" + (Get-Service 'PrivateArk Server').Status
    }
    Start-Sleep -Seconds 2
    `$result += "REACH_DC_389:" + (Test-NetConnection -ComputerName '$dcFQDN' -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded
    `$result += "OK"
} catch { `$result += "ERROR:`$(`$_.Exception.Message)" }
Set-Content -Path 'C:\Windows\Temp\vault_ldap_result.txt' -Value `$result -Encoding UTF8
"@
Invoke-LabVMPowerShell -VMXPath $vaultVMX -ScriptBlock $guest -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
$localResult = Join-Path $env:TEMP "vault_ldap_result.txt"
Remove-Item $localResult -Force -ErrorAction SilentlyContinue
Copy-FileFromLabVM -VMXPath $vaultVMX -GuestPath "C:\Windows\Temp\vault_ldap_result.txt" `
    -HostPath $localResult -GuestUser $guestUser -GuestPassword $guestPass | Out-Null
$out = Get-Content $localResult
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if (-not ($out -contains 'OK')) { throw "Vault LDAP prep failed - see output above (backup: dbparm.ini.ldapbak_* on VAULT01)." }
if (-not ($out -contains 'REACH_DC_389:True')) {
    throw "VAULT01 still cannot reach ${dcFQDN}:389 - check the '$fwRule' line under [MAIN] in dbparm.ini and that the Vault service restarted."
}
Write-Host "  [OK] Vault can reach ${dcFQDN}:389" -ForegroundColor Green

Connect-PVWA
try {
    # ================================================================
    # Part 2: bind account in the VaultInternal safe
    # ================================================================
    Write-Host "`n[2/4] PVWA: bind account in safe $SafeName..." -ForegroundColor Yellow
    $srch  = Invoke-PVWA "/api/Accounts?search=$BindUser&filter=safeName%20eq%20$SafeName"
    $found = $srch.value | Where-Object { $_.userName -eq $upn -or $_.userName -eq $BindUser } | Select-Object -First 1
    $null = Initialize-LabServiceAccountPlatform -PvwaBase $pvwaBase -Headers $script:pvwaHdr -Iwr $iwr `
                -PlatformId $PlatformId -SourceZipPath $WinDomainZipPath
    if ($found) {
        Write-Host "  [OK] Account exists: id=$($found.id) ($($found.name))" -ForegroundColor Green
        Set-LabAccountPlatform -PvwaBase $pvwaBase -Headers $script:pvwaHdr -Iwr $iwr -Account $found -PlatformId $PlatformId
    } else {
        # No automatic management: a CPM rotation would break the directory's stored bind password.
        $acct = Invoke-PVWA "/api/Accounts" POST @{ name=$AccountName; address=$domain; userName=$upn; platformId=$PlatformId
                                                    safeName=$SafeName; secretType="password"; secret=$BindPassword; platformAccountProperties=@{}
                                                    secretManagement=@{ automaticManagementEnabled=$false
                                                                        manualManagementReason="LDAP bind account - rotation would break the Vault directory bind" } }
        Write-Host "  [OK] Account created: id=$($acct.id) ($AccountName, $PlatformId, manual management)" -ForegroundColor Green
    }
    if ($GrantPTAAppUserRead) {
        try {
            Invoke-PVWA "/api/Safes/$SafeName/Members" POST @{ memberName="PTAAppUser"; searchIn="Vault"
                permissions=@{ useAccounts=$true; retrieveAccounts=$true; listAccounts=$true } } | Out-Null
            Write-Host "  [OK] PTAAppUser granted read on $SafeName" -ForegroundColor Green
        } catch { if ("$_" -match 'already') { Write-Host "  [OK] PTAAppUser already a member" -ForegroundColor Green } else { throw } }
    }

    # ================================================================
    # Part 3: LDAP directory + LDAP authentication method
    # ================================================================
    Write-Host "`n[3/4] PVWA: LDAP directory $domain + LDAP auth method..." -ForegroundColor Yellow
    $dirs = @(Invoke-PVWA "/api/Configuration/LDAP/Directories")
    $dir  = $dirs | Where-Object { $_.DomainName -eq $domain } | Select-Object -First 1
    if ($dir) {
        Write-Host "  [OK] Directory exists: $domain" -ForegroundColor Green
        $cur = Invoke-PVWA "/api/Configuration/LDAP/Directories/$domain/"   # trailing / : IIS 404s on a trailing ".lab" "extension"
        $hosts = @($cur.DCList | ForEach-Object { "$($_.Name):$($_.Port)" })
        if ($hosts -notcontains "${dcFQDN}:389" -or $cur.BindUsername -ne $upn) {
            Write-Warning "Existing directory differs (hosts=$($hosts -join ','), bind=$($cur.BindUsername)) - left unchanged."
        }
    } else {
        Invoke-PVWA "/api/Configuration/LDAP/Directories" POST @{
            DomainName        = $domain
            DomainBaseContext = $baseDN
            BindUsername      = $upn
            BindPassword      = $BindPassword
            DirectoryType     = "MicrosoftADProfile.ini"
            # Directory-level Port/SSLConnect must match the DC entry, else PASWS233E.
            SSLConnect        = $false
            Port              = 389
            DCList            = @(@{ Name = $dcFQDN; Port = 389; SSLConnect = $false })
        } | Out-Null
        Write-Host "  [OK] Directory created: $domain -> ${dcFQDN}:389" -ForegroundColor Green
    }

    $ldapAuth = (Invoke-PVWA "/api/Configuration/AuthenticationMethods").Methods | Where-Object { $_.id -eq 'ldap' }
    if ($ldapAuth.enabled) { Write-Host "  [OK] LDAP auth method already enabled" -ForegroundColor Green }
    else {
        $ldapAuth.enabled = $true
        Invoke-PVWA "/api/Configuration/AuthenticationMethods/ldap" PUT $ldapAuth | Out-Null
        Write-Host "  [OK] LDAP auth method enabled" -ForegroundColor Green
    }

    # ================================================================
    # Part 4: directory mappings
    # ================================================================
    Write-Host "`n[4/4] PVWA: directory mappings..." -ForegroundColor Yellow
    $existing = @(Invoke-PVWA "/api/Configuration/LDAP/Directories/$domain/Mappings")
    foreach ($m in $mappings) {
        if ($existing | Where-Object { $_.MappingName -eq $m.Name }) { Write-Host "  [OK] $($m.Name) exists" -ForegroundColor Green; continue }
        $body = @{ MappingName = $m.Name; LDAPBranch = $baseDN; DomainGroups = @($m.Group); Location = "\"
                   MappingAuthorizations = @($m.Auth) }
        if ($m.VaultGroups.Count) { $body.VaultGroups = @($m.VaultGroups) }
        Invoke-PVWA "/api/Configuration/LDAP/Directories/$domain/Mappings" POST $body | Out-Null
        Write-Host "  [OK] $($m.Name) created ($($m.Group) -> $(if ($m.VaultGroups.Count) { $m.VaultGroups -join ',' } else { '-' }); $(if ($m.Auth.Count) { $m.Auth -join ',' } else { 'logon only' }))" -ForegroundColor Green
    }
} finally { Disconnect-PVWA }

# ---- verification: LDAP logon per role ---------------------------
if (-not $SkipLogonTest) {
    Write-Host "`n[verify] LDAP logon to PVWA per role..." -ForegroundColor Yellow
    $fail = 0
    foreach ($m in $mappings) {
        try {
            $tok = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/LDAP/Logon" -Method POST -ContentType "application/json" `
                -Body (@{ username=$m.TestUser; password=$TestPassword; concurrentSession=$true } | ConvertTo-Json)).Content.Trim('"')
            Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Logoff" -Method POST -Headers @{ Authorization=$tok } -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [OK] $($m.TestUser) logged on via LDAP" -ForegroundColor Green
        } catch { $fail++; Write-Warning "$($m.TestUser) LDAP logon failed: $($_.ErrorDetails.Message)" }
    }
    if ($fail) { throw "$fail LDAP test logon(s) failed - check the directory/mappings in PVWA (Administration > LDAP Integration)." }
}
Write-Host "`n[OK] Vault LDAP integration configured. Log on to PVWA with method 'LDAP' as e.g. vault_admin1." -ForegroundColor Green
