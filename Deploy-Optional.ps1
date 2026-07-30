<#
.SYNOPSIS
    Optional, opt-in CyberArk lab configuration features - one entry point.
.DESCRIPTION
    A single menu/parameter-driven script for optional add-ons that are NOT part
    of the base lab. Uses only supported tooling (ActiveDirectory module on DC01,
    PVWA REST) - nothing is edited on the appliances, so it is redeploy/upgrade
    safe. Every feature is idempotent.

    Features:
      VaultADObjects    Create the AD OU + Vault role groups (Admins/Users/
                        Auditors/SafeManagers) and populate them with users.
      LDAPBindUser      Create the least-privilege AD bind user (List Contents)
                        and store it as an account in PVWA (for Vault/PTA LDAP).
      ReconcileAccount  (planned) Create a reconcile account in AD + PVWA.

    Usage:
      .\Deploy-Optional.ps1                                  # interactive menu
      .\Deploy-Optional.ps1 -Feature VaultADObjects
      .\Deploy-Optional.ps1 -Feature VaultADObjects,LDAPBindUser -GrantPTAAppUserRead
      .\Deploy-Optional.ps1 -ListFeatures
.NOTES
    Run after the domain controller (and, for PVWA steps, PVWA) are up.
#>

param(
    [ValidateSet("VaultADObjects", "LDAPBindUser", "ReconcileAccount", "DiscoveryAccount",
                 "PTACertificates", "VaultPTASyslog", "ConjurNodes", "LoadBalancer", "ConjurSystemFolders",
                 "ConjurAppliance", "ConjurDNS", "ConjurInstallLeader", "ConjurImportCertificates",
                 "ConjurEncryptKeys", "ConjurInstallStandby", "ConjurInstallFollower",
                 "VaultConjurSynchronizer", "ConjurLoadRootPolicy")]
    [string[]]$Feature,

    [string]$ConfigPath = "$PSScriptRoot\Config\LabConfig.psd1",

    # VaultADObjects
    [string]$OUName        = "CyberArk",
    [ValidateRange(1,100)][int]$UsersPerGroup = 10,
    [string]$UserPassword  = "Cyberark1!",

    # LDAPBindUser
    [string]$BindUser      = "svc-cybr-ldap",
    [string]$BindPassword  = "Cyberark1!",
    [string]$SafeName      = "VaultInternal",
    [string]$AccountName   = "cyberark.lab.pass",
    [switch]$GrantPTAAppUserRead,

    # ReconcileAccount
    [string]$ReconcileUser        = "svc-cybr-reconcile",
    [string]$ReconcilePassword    = "Cyberark1!",
    [string]$ReconcileSafe        = "VaultInternal",
    [string]$ReconcileAccountName = "cyberark.lab.reconcile",

    # DiscoveryAccount
    [string]$DiscoveryUser        = "svc-discovery",
    [string]$DiscoveryPassword    = "Cyberark1!",
    [string]$DiscoverySafe        = "VaultInternal",
    [string]$DiscoveryAccountName = "cyberark.lab.discovery",
    [string]$DiscoveryDisplayName = "CyberArk Discovery Scanner",

    # PTACertificates / VaultPTASyslog (dispatch to the backend scripts in Scripts\)
    [string]$PTAPrimaryName   = "PTA01",
    [string]$PTASecondaryName = "",
    [int]   $SyslogPort       = 11514,
    [ValidateSet("TCP","UDP")]
    [string]$SyslogProtocol   = "TCP",

    # ConjurNodes (dispatch to Scripts\30-CloneConjurNodes.ps1)
    [ValidateSet("full","linked")]
    [string]  $ConjurCloneType = "full",
    [string[]]$ConjurNodeNames,                 # subset, e.g. CONJUR-S01,CONJUR-S02; default all
    [string]  $ConjurGuestPass = "Cyberark1",   # CONJUR-L01 root password

    # LoadBalancer (dispatch to Scripts\31-ConfigureLoadBalancer.ps1)
    [string]  $LBTargetName = "CONJUR-APP01",
    [array]   $LBPools,                          # default = the two Conjur pools (see script)
    [string]  $LBGuestPass  = "Cyberark1",

    # ConjurSystemFolders (dispatch to Scripts\32-CreateConjurSystemFolders.ps1)
    [string[]]$ConjurFolderNodes,                 # default = L01+S01/S02/F01/F02 (see script)
    [string]  $ConjurFolderGuestPass = "Cyberark1",

    # ConjurAppliance (dispatch to Scripts\33-CopyConjurAppliance.ps1)
    [string[]]$ConjurApplianceNodes,               # default = L01+S01/S02/F01/F02 (see script)
    [string]  $ConjurApplianceGuestPass = "Cyberark1",
    [switch]  $ConjurApplianceLoad,                # also podman-load + verify + clean up on the guest
    [string[]]$ConjurCliNodes,                     # default = CONJUR-L01 only (see script)
    [switch]  $ConjurSkipCli,                      # skip the Conjur CLI RPM install entirely

    # ConjurInstallLeader (dispatch to Scripts\35-InstallConjurLeader.ps1)
    [string]  $ConjurLeaderVMName    = "CONJUR-L01",
    [string]  $ConjurContainerName   = "conjur",
    [string]  $ConjurLeaderGuestPass = "Cyberark1",

    # ConjurImportCertificates (dispatch to Scripts\36-ImportConjurCertificates.ps1)
    [string]  $ConjurCertVMName    = "CONJUR-L01",
    [string]  $ConjurCertGuestPass = "Cyberark1",

    # ConjurEncryptKeys (dispatch to Scripts\37-EncryptConjurLeaderKeys.ps1)
    [string]  $ConjurKeysVMName    = "CONJUR-L01",
    [string]  $ConjurKeysGuestPass = "Cyberark1",

    # ConjurInstallStandby (dispatch to Scripts\38-InstallConjurStandby.ps1)
    [string]  $ConjurStandbyVMName,                    # required - e.g. CONJUR-S01
    [string]  $ConjurStandbyGuestPass = "Cyberark1",

    # ConjurInstallFollower (dispatch to Scripts\39-InstallConjurFollower.ps1)
    [string]  $ConjurFollowerVMName,                   # required - e.g. CONJUR-F01
    [string]  $ConjurFollowerGuestPass = "Cyberark1",

    # VaultConjurSynchronizer (dispatch to Scripts\40-InstallVaultConjurSynchronizer.ps1)
    [string]  $SynchronizerPlatformZipPath,             # required only if the target platform is missing from the Vault
    [switch]  $SynchronizerForce,

    # ConjurLoadRootPolicy (dispatch to Scripts\41-LoadConjurRootPolicy.ps1)
    [string]  $ConjurPolicyVMName = "CONJUR-L01",
    [string]  $ConjurPolicyGuestPass = "Cyberark1",

    [switch]$ListFeatures
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
$CA     = Import-PowerShellDataFile "$PSScriptRoot\Config\CyberArkConfig.psd1"

$dcIP     = $Config.Network.DNS
$domain   = $Config.Domain.Name
$netbios  = $Config.Domain.NetBIOSName
$baseDN   = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
$dcCred   = New-Object PSCredential("$netbios\$($Config.Domain.DomainAdminUser)",
            (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force))
$pvwaVM   = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -eq 'PVWA' } | Select-Object -First 1
$pvwaBase = "https://$($pvwaVM.IPAddress)/PasswordVault"

# ---- feature catalogue (add new options here) --------------------
$catalogue = [ordered]@{
    VaultADObjects   = "Create AD OU + Vault role groups + users"
    LDAPBindUser     = "Create AD bind user (List Contents) + store in PVWA"
    ReconcileAccount = "Create a reconcile account (Reset Password) in AD + PVWA"
    DiscoveryAccount = "Create the accounts-discovery scan account in AD + PVWA"
    PTACertificates  = "Issue + install PTA CA certificates from DC01 (DR-ready)"
    VaultPTASyslog   = "Configure Vault -> PTA syslog forwarding (session monitoring)"
    ConjurNodes      = "Clone CONJUR-L01 into the Conjur cluster nodes (S/F/APP)"
    LoadBalancer     = "Configure HAProxy pools on a target node (default: Conjur leader+follower on APP01)"
    ConjurSystemFolders = "Create /opt/cyberark/conjur system folders on Conjur nodes (deck Step 2)"
    ConjurAppliance  = "Copy (+ optionally load) the Conjur appliance tarball onto Conjur nodes (deck Step 4)"
    ConjurDNS        = "Create DC01 DNS A-records for the Conjur nodes + cluster/follower VIPs"
    ConjurInstallLeader = "Create+start the Conjur Leader container on L01 (deck Step 6, real seccomp profile)"
    ConjurImportCertificates = "Issue + import DC01 CA-signed leader/follower certs into the Conjur Leader (deck Step 8)"
    ConjurEncryptKeys = "Encrypt the Conjur Leader's server keys with a native master key (deck Step 3, optional)"
    ConjurInstallStandby = "Create + configure a Conjur Standby (container, seed transfer, evoke configure standby) - pass -ConjurStandbyVMName"
    ConjurInstallFollower = "Create + configure a Conjur Follower (container, shared-identity seed transfer, evoke configure follower) - pass -ConjurFollowerVMName"
    VaultConjurSynchronizer = "Install the Vault-Conjur Synchronizer on COMP01 (LOB sync of a Vault safe into Conjur) - pass -SynchronizerPlatformZipPath if the target Vault platform doesn't exist yet"
    ConjurLoadRootPolicy = "Bootstrap Conjur's root policy (admins/apps/ops branches, conjur-admins group delegated on root) - see Policies\ folder"
}

if ($ListFeatures) {
    Write-Host "`nOptional features:" -ForegroundColor Cyan
    $catalogue.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-18} {1}" -f $_.Key, $_.Value) }
    return
}

# ---- shared helpers ----------------------------------------------
function Invoke-DC {
    # Invoke-Command to DC01 with a small retry (WinRM can transiently fail).
    param([scriptblock]$Script, [object[]]$ArgumentList)
    for ($i = 1; $i -le 3; $i++) {
        try { return Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock $Script -ArgumentList $ArgumentList }
        catch { if ($i -eq 3) { throw } ; Start-Sleep 5 }
    }
}

function Connect-PVWA {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $script:iwr = @{ UseBasicParsing = $true; SkipCertificateCheck = $true }
    } else {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $script:iwr = @{ UseBasicParsing = $true }
    }
    $script:pvwaTok = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Cyberark/Logon" -Method POST `
        -Body (@{ username=$CA.Vault.AdminUser; password=$CA.Vault.AdminPassword; concurrentSession=$true } | ConvertTo-Json) `
        -ContentType "application/json").Content.Trim('"')
    $script:pvwaHdr = @{ Authorization = $script:pvwaTok }
}
function Disconnect-PVWA {
    if ($script:pvwaTok) { Invoke-WebRequest @iwr -Uri "$pvwaBase/api/auth/Logoff" -Method POST -Headers $script:pvwaHdr -ErrorAction SilentlyContinue | Out-Null; $script:pvwaTok = $null }
}

# ================================================================
# Feature: VaultADObjects
# ================================================================
function Invoke-VaultADObjects {
    Write-Host "`n### VaultADObjects: OU + role groups + users ###" -ForegroundColor Cyan
    $roles = @(
        @{ Group="Lab-Vault-Admins";       Prefix="vault_admin"   },
        @{ Group="Lab-Vault-Users";        Prefix="vault_user"    },
        @{ Group="Lab-Vault-Auditors";     Prefix="vault_auditor" },
        @{ Group="Lab-Vault-SafeManagers"; Prefix="vault_safemgr" }
    )
    $out = Invoke-DC -ArgumentList $domain, $OUName, $roles, $UsersPerGroup, $UserPassword -Script {
        param($domain, $OUName, $roles, $count, $password)
        Import-Module ActiveDirectory -ErrorAction Stop
        $log = New-Object System.Collections.Generic.List[string]
        $baseDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
        $ouDN   = "OU=$OUName,$baseDN"
        $secPw  = ConvertTo-SecureString $password -AsPlainText -Force
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -SearchBase $baseDN -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $OUName -Path $baseDN -ProtectedFromAccidentalDeletion $false; $log.Add("OU_CREATED:$ouDN")
        } else { $log.Add("OU_FOUND:$ouDN") }
        foreach ($r in $roles) {
            $grp=$r.Group; $prefix=$r.Prefix
            $g = Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue
            if (-not $g) { New-ADGroup -Name $grp -SamAccountName ($grp -replace '[^A-Za-z0-9]','') -GroupCategory Security -GroupScope Global -Path $ouDN; $g = Get-ADGroup -Filter "Name -eq '$grp'"; $log.Add("GROUP_CREATED:$grp") }
            else { $log.Add("GROUP_FOUND:$grp") }
            $c=0;$e=0;$a=0
            for ($i=1;$i -le $count;$i++) {
                $sam="$prefix$i"
                if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
                    New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName "$sam@$domain" -Path $ouDN -AccountPassword $secPw -Enabled $true -PasswordNeverExpires:$true -ChangePasswordAtLogon:$false; $c++
                } else { $e++ }
                if (-not (Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $sam })) { Add-ADGroupMember -Identity $g.DistinguishedName -Members $sam; $a++ }
            }
            $log.Add("$grp : created=$c existed=$e added=$a")
        }
        $log
    }
    $out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "  [OK] VaultADObjects done" -ForegroundColor Green
}

# ================================================================
# Feature: LDAPBindUser
# ================================================================
function Invoke-LDAPBindUser {
    Write-Host "`n### LDAPBindUser: AD bind user + PVWA account ###" -ForegroundColor Cyan
    $upn = "$BindUser@$domain"
    $ad = Invoke-DC -ArgumentList $BindUser, $upn, $BindPassword, $baseDN, $netbios -Script {
        param($sam, $upn, $password, $baseDN, $netbios)
        Import-Module ActiveDirectory -ErrorAction Stop
        $log = New-Object System.Collections.Generic.List[string]
        $secPw = ConvertTo-SecureString $password -AsPlainText -Force
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $u) {
            New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName $upn -Path "CN=Users,$baseDN" -AccountPassword $secPw -Enabled $true -PasswordNeverExpires:$true -ChangePasswordAtLogon:$false -Description "CyberArk Vault/PTA LDAP bind account (least privilege)"
            $log.Add("USER_CREATED:$upn")
        } else { Set-ADUser -Identity $u -PasswordNeverExpires $true; $log.Add("USER_EXISTS:$upn") }
        $r = & dsacls $baseDN /I:T /G "$netbios\${sam}:LC" 2>&1
        $log.Add($(if ($LASTEXITCODE -eq 0) { "LIST_CONTENTS_GRANTED" } else { "LIST_CONTENTS_WARN:$($r | Select-Object -Last 1)" }))
        $log
    }
    $ad | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    Connect-PVWA
    try {
        $srch = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts?search=$BindUser&searchIn=$SafeName" -Headers $pvwaHdr).Content | ConvertFrom-Json
        $found = $srch.value | Where-Object { $_.userName -eq $upn -or $_.userName -eq $BindUser } | Select-Object -First 1
        if ($found) { Write-Host "  [OK] PVWA account exists: id=$($found.id) addr=$($found.address)" -ForegroundColor Green }
        else {
            $body = @{ name=$AccountName; address=$domain; userName=$upn; platformId="WinDomain"; safeName=$SafeName; secretType="password"; secret=$BindPassword; platformAccountProperties=@{} } | ConvertTo-Json
            $id = ((Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts" -Method POST -Body $body -ContentType "application/json" -Headers $pvwaHdr).Content | ConvertFrom-Json).id
            Write-Host "  [OK] PVWA account created: id=$id (address=$domain)" -ForegroundColor Green
        }
        if ($GrantPTAAppUserRead) {
            $mem = @{ memberName="PTAAppUser"; searchIn="Vault"; permissions=@{ useAccounts=$true; retrieveAccounts=$true; listAccounts=$true } } | ConvertTo-Json
            try { Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Safes/$SafeName/Members" -Method POST -Body $mem -ContentType "application/json" -Headers $pvwaHdr | Out-Null; Write-Host "  [OK] PTAAppUser granted read on $SafeName" -ForegroundColor Green }
            catch { if (($_.ErrorDetails.Message) -match 'already') { Write-Host "  [OK] PTAAppUser already member" -ForegroundColor Green } else { Write-Warning $_.ErrorDetails.Message } }
        }
    } finally { Disconnect-PVWA }
    Write-Host "  [OK] LDAPBindUser done. Configure the external directory / group mapping in PrivateArk / PVWA." -ForegroundColor Green
}

# ================================================================
# Feature: ReconcileAccount
#   AD account the CPM uses to reset/reconcile domain-account passwords.
#   Creates the AD account + delegates "Reset Password" (and pwdLastSet write)
#   on the directory, then stores it in PVWA. Linking it as the reconcile
#   account for a platform/accounts is done in PVWA (platform config).
# ================================================================
function Invoke-ReconcileAccount {
    Write-Host "`n### ReconcileAccount: AD reset-password account + PVWA account ###" -ForegroundColor Cyan
    $upn = "$ReconcileUser@$domain"
    $ad = Invoke-DC -ArgumentList $ReconcileUser, $upn, $ReconcilePassword, $baseDN, $netbios -Script {
        param($sam, $upn, $password, $baseDN, $netbios)
        Import-Module ActiveDirectory -ErrorAction Stop
        $log = New-Object System.Collections.Generic.List[string]
        $secPw = ConvertTo-SecureString $password -AsPlainText -Force
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $u) {
            New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName $upn -Path "CN=Users,$baseDN" `
                -AccountPassword $secPw -Enabled $true -PasswordNeverExpires:$true -ChangePasswordAtLogon:$false `
                -Description "CyberArk CPM reconcile account (reset-password rights)"
            $log.Add("USER_CREATED:$upn")
        } else { Set-ADUser -Identity $u -PasswordNeverExpires $true; $log.Add("USER_EXISTS:$upn") }
        # Delegate the "Reset Password" extended right + pwdLastSet write, inheritable to user objects
        $r1 = & dsacls $baseDN /I:T /G "$netbios\${sam}:CA;Reset Password" 2>&1
        $log.Add($(if ($LASTEXITCODE -eq 0) { "RESET_PASSWORD_GRANTED" } else { "RESET_PASSWORD_WARN:$($r1 | Select-Object -Last 1)" }))
        $r2 = & dsacls $baseDN /I:T /G "$netbios\${sam}:WP;pwdLastSet" 2>&1
        $log.Add($(if ($LASTEXITCODE -eq 0) { "PWDLASTSET_WRITE_GRANTED" } else { "PWDLASTSET_WARN:$($r2 | Select-Object -Last 1)" }))
        $log
    }
    $ad | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    Connect-PVWA
    try {
        $srch = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts?search=$ReconcileUser&searchIn=$ReconcileSafe" -Headers $pvwaHdr).Content | ConvertFrom-Json
        $found = $srch.value | Where-Object { $_.userName -eq $upn -or $_.userName -eq $ReconcileUser } | Select-Object -First 1
        if ($found) { Write-Host "  [OK] PVWA account exists: id=$($found.id) addr=$($found.address)" -ForegroundColor Green }
        else {
            $body = @{ name=$ReconcileAccountName; address=$domain; userName=$upn; platformId="WinDomain"; safeName=$ReconcileSafe; secretType="password"; secret=$ReconcilePassword; platformAccountProperties=@{} } | ConvertTo-Json
            $id = ((Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts" -Method POST -Body $body -ContentType "application/json" -Headers $pvwaHdr).Content | ConvertFrom-Json).id
            Write-Host "  [OK] PVWA account created: id=$id (address=$domain)" -ForegroundColor Green
        }
    } finally { Disconnect-PVWA }
    Write-Host "  [OK] ReconcileAccount ready. Set it as the reconcile account for the target platform/accounts in PVWA." -ForegroundColor Green
}

# ================================================================
# Feature: DiscoveryAccount
#   Domain account used by CyberArk Accounts Discovery to scan machines for
#   accounts. Creates the AD account + stores it in PVWA. Discovery scan rights
#   (local admin on targets) and the scan definition are configured in PVWA/on
#   the targets - not an AD delegation.
# ================================================================
function Invoke-DiscoveryAccount {
    Write-Host "`n### DiscoveryAccount: accounts-discovery scan account + PVWA account ###" -ForegroundColor Cyan
    $upn = "$DiscoveryUser@$domain"
    $ad = Invoke-DC -ArgumentList $DiscoveryUser, $upn, $DiscoveryPassword, $baseDN, $DiscoveryDisplayName -Script {
        param($sam, $upn, $password, $baseDN, $displayName)
        Import-Module ActiveDirectory -ErrorAction Stop
        $log = New-Object System.Collections.Generic.List[string]
        $secPw = ConvertTo-SecureString $password -AsPlainText -Force
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $u) {
            New-ADUser -Name $displayName -SamAccountName $sam -UserPrincipalName $upn -Path "CN=Users,$baseDN" `
                -AccountPassword $secPw -Enabled $true -PasswordNeverExpires:$true -ChangePasswordAtLogon:$false `
                -Description "CyberArk Windows/Unix discovery scan account"
            $log.Add("USER_CREATED:$upn")
        } else { Set-ADUser -Identity $u -PasswordNeverExpires $true; $log.Add("USER_EXISTS:$upn ($($u.DistinguishedName))") }
        $log
    }
    $ad | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    Connect-PVWA
    try {
        $srch = (Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts?search=$DiscoveryUser&searchIn=$DiscoverySafe" -Headers $pvwaHdr).Content | ConvertFrom-Json
        $found = $srch.value | Where-Object { $_.userName -eq $upn -or $_.userName -eq $DiscoveryUser } | Select-Object -First 1
        if ($found) { Write-Host "  [OK] PVWA account exists: id=$($found.id) addr=$($found.address)" -ForegroundColor Green }
        else {
            $body = @{ name=$DiscoveryAccountName; address=$domain; userName=$upn; platformId="WinDomain"; safeName=$DiscoverySafe; secretType="password"; secret=$DiscoveryPassword; platformAccountProperties=@{} } | ConvertTo-Json
            $id = ((Invoke-WebRequest @iwr -Uri "$pvwaBase/api/Accounts" -Method POST -Body $body -ContentType "application/json" -Headers $pvwaHdr).Content | ConvertFrom-Json).id
            Write-Host "  [OK] PVWA account created: id=$id (address=$domain)" -ForegroundColor Green
        }
    } finally { Disconnect-PVWA }
    Write-Host "  [OK] DiscoveryAccount ready. Reference it in the Accounts Discovery scan definition in PVWA; ensure it has scan rights on the targets." -ForegroundColor Green
}

# ================================================================
# Feature: PTACertificates  (dispatch to Scripts\Configure-PTACertificates.ps1)
#   Issues + installs CA-signed PTA certificates from the DC01 Enterprise CA.
# ================================================================
function Invoke-PTACertificates {
    Write-Host "`n### PTACertificates ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\Configure-PTACertificates.ps1" -PrimaryName $PTAPrimaryName -SecondaryName $PTASecondaryName
}

# ================================================================
# Feature: VaultPTASyslog  (dispatch to Scripts\Configure-VaultSyslogToPTA.ps1)
#   Configures Vault -> PTA syslog forwarding for session monitoring.
# ================================================================
function Invoke-VaultPTASyslog {
    Write-Host "`n### VaultPTASyslog ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\Configure-VaultSyslogToPTA.ps1" -PrimaryPTAName $PTAPrimaryName -SyslogPort $SyslogPort -SyslogProtocol $SyslogProtocol
}

# ================================================================
# Feature: ConjurNodes  (dispatch to Scripts\30-CloneConjurNodes.ps1)
#   Clones the hand-built CONJUR-L01 leader into S01/S02/F01/F02/LB01/APP01.
#   Template prereqs (power-off, snapshot) are automated; each clone is
#   generalized post-clone so L01 itself is never modified.
# ================================================================
function Invoke-ConjurNodes {
    Write-Host "`n### ConjurNodes ###" -ForegroundColor Cyan
    $splat = @{ CloneType = $ConjurCloneType; GuestPass = $ConjurGuestPass }
    if ($ConjurNodeNames) { $splat.Nodes = $ConjurNodeNames }
    & "$PSScriptRoot\Scripts\30-CloneConjurNodes.ps1" @splat
}

# ================================================================
# Feature: LoadBalancer  (dispatch to Scripts\31-ConfigureLoadBalancer.ps1)
#   Generic HAProxy pool configurator. Default wires the Conjur
#   leader+follower pools on CONJUR-APP01; pass -LBPools for any other
#   target (PVWA, PSM/PSMP, etc.) with no code changes.
# ================================================================
function Invoke-LoadBalancer {
    Write-Host "`n### LoadBalancer ###" -ForegroundColor Cyan
    $splat = @{ TargetName = $LBTargetName; GuestPass = $LBGuestPass }
    if ($LBPools) { $splat.Pools = $LBPools }
    & "$PSScriptRoot\Scripts\31-ConfigureLoadBalancer.ps1" @splat
}

# ================================================================
# Feature: ConjurSystemFolders  (dispatch to Scripts\32-CreateConjurSystemFolders.ps1)
#   Creates /opt/cyberark/conjur/{security,config,backup,seeds,logs} on the
#   Conjur appliance nodes (Leader/Standbys/Followers - not APP01).
# ================================================================
function Invoke-ConjurSystemFolders {
    Write-Host "`n### ConjurSystemFolders ###" -ForegroundColor Cyan
    $splat = @{ GuestPass = $ConjurFolderGuestPass }
    if ($ConjurFolderNodes) { $splat.VMNames = $ConjurFolderNodes }
    & "$PSScriptRoot\Scripts\32-CreateConjurSystemFolders.ps1" @splat
}

# ================================================================
# Feature: ConjurAppliance  (dispatch to Scripts\33-CopyConjurAppliance.ps1)
#   Copies the Conjur appliance tarball (SCP, not guest-ops - too large for
#   the VIX channel) onto the Conjur nodes; -ConjurApplianceLoad also runs
#   podman load + verify + cleanup on the guest.
# ================================================================
function Invoke-ConjurAppliance {
    Write-Host "`n### ConjurAppliance ###" -ForegroundColor Cyan
    $splat = @{ GuestPass = $ConjurApplianceGuestPass }
    if ($ConjurApplianceNodes) { $splat.VMNames = $ConjurApplianceNodes }
    if ($ConjurApplianceLoad) { $splat.Load = $true }
    if ($ConjurCliNodes) { $splat.CliVMNames = $ConjurCliNodes }
    if ($ConjurSkipCli) { $splat.SkipCli = $true }
    & "$PSScriptRoot\Scripts\33-CopyConjurAppliance.ps1" @splat
}

# ================================================================
# Feature: ConjurDNS  (dispatch to Scripts\34-ConfigureConjurDNS.ps1)
#   Creates the DC01 A-records the Conjur cluster needs (node hostnames +
#   cluster/follower VIPs) - deck's DNS prerequisite for evoke configure.
# ================================================================
function Invoke-ConjurDNS {
    Write-Host "`n### ConjurDNS ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\34-ConfigureConjurDNS.ps1"
}

# ================================================================
# Feature: ConjurInstallLeader  (dispatch to Scripts\35-InstallConjurLeader.ps1)
#   Creates + starts the Conjur Leader container with a real (not
#   unconfined) seccomp profile extracted from the loaded image. Does NOT
#   run evoke configure - that needs cluster/admin decisions confirmed
#   first (see CLIENT-CONJUR-INSTALL-CHECKLIST.md).
# ================================================================
function Invoke-ConjurInstallLeader {
    Write-Host "`n### ConjurInstallLeader ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\35-InstallConjurLeader.ps1" -VMName $ConjurLeaderVMName `
        -ContainerName $ConjurContainerName -GuestPass $ConjurLeaderGuestPass
}

# ================================================================
# Feature: ConjurImportCertificates  (dispatch to Scripts\36-ImportConjurCertificates.ps1)
#   Issues leader+follower certs from the DC01 Enterprise CA (WebServer
#   template - already SAN+clientAuth capable via PTACertificates prep) and
#   runs evoke ca import on the Leader (deck Step 8).
# ================================================================
function Invoke-ConjurImportCertificates {
    Write-Host "`n### ConjurImportCertificates ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\36-ImportConjurCertificates.ps1" -VMName $ConjurCertVMName `
        -ContainerName $ConjurContainerName -GuestPass $ConjurCertGuestPass
}

# ================================================================
# Feature: ConjurEncryptKeys  (dispatch to Scripts\37-EncryptConjurLeaderKeys.ps1)
#   Encrypts the Leader's server keys with a native master key (deck Step 3,
#   optional but strongly recommended). Idempotent - re-running skips
#   generation if a key already exists but always re-runs the unlock, which
#   is required after every container/host restart.
# ================================================================
function Invoke-ConjurEncryptKeys {
    Write-Host "`n### ConjurEncryptKeys ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\37-EncryptConjurLeaderKeys.ps1" -VMName $ConjurKeysVMName `
        -ContainerName $ConjurContainerName -GuestPass $ConjurKeysGuestPass
}

# ================================================================
# Feature: ConjurInstallStandby  (dispatch to Scripts\38-InstallConjurStandby.ps1)
#   Creates + fully configures a Standby (container, seed transfer from the
#   Leader, evoke configure standby). Requires -ConjurStandbyVMName. Not
#   idempotent-skippable for seed transfer/configure - only container
#   creation and the overall run are idempotent (checks evoke's own role
#   marker first).
# ================================================================
function Invoke-ConjurInstallStandby {
    if (-not $ConjurStandbyVMName) { throw "ConjurInstallStandby requires -ConjurStandbyVMName (e.g. CONJUR-S01)" }
    Write-Host "`n### ConjurInstallStandby: $ConjurStandbyVMName ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\38-InstallConjurStandby.ps1" -StandbyVMName $ConjurStandbyVMName `
        -ContainerName $ConjurContainerName -GuestPass $ConjurStandbyGuestPass
}

# ================================================================
# Feature: ConjurInstallFollower  (dispatch to Scripts\39-InstallConjurFollower.ps1)
#   Creates + fully configures a Follower. Requires -ConjurFollowerVMName.
#   Uses the shared Follower group identity for seeding, not the node's own
#   name - see script header for why that distinction matters.
# ================================================================
function Invoke-ConjurInstallFollower {
    if (-not $ConjurFollowerVMName) { throw "ConjurInstallFollower requires -ConjurFollowerVMName (e.g. CONJUR-F01)" }
    Write-Host "`n### ConjurInstallFollower: $ConjurFollowerVMName ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\39-InstallConjurFollower.ps1" -FollowerVMName $ConjurFollowerVMName `
        -ContainerName $ConjurContainerName -GuestPass $ConjurFollowerGuestPass
}

# ================================================================
# Feature: VaultConjurSynchronizer  (dispatch to Scripts\40-InstallVaultConjurSynchronizer.ps1)
#   Installs the Vault-Conjur Synchronizer on COMP01. See the script's own
#   header for the IE-first-launch and missing-platform gaps this handles,
#   and the caveats around its non-interactive install automation.
# ================================================================
function Invoke-VaultConjurSynchronizer {
    Write-Host "`n### VaultConjurSynchronizer ###" -ForegroundColor Cyan
    $splat = @{}
    if ($SynchronizerPlatformZipPath) { $splat.PlatformZipPath = $SynchronizerPlatformZipPath }
    if ($SynchronizerForce) { $splat.Force = $true }
    & "$PSScriptRoot\Scripts\40-InstallVaultConjurSynchronizer.ps1" @splat
}

# ================================================================
# Feature: ConjurLoadRootPolicy  (dispatch to Scripts\41-LoadConjurRootPolicy.ps1)
#   Bootstraps admins/apps/ops branch stubs under root, creates the
#   self-owning conjur-admins group, and permits it [read,create,update]
#   on root itself (root's own owner: stays the admin user, untouched).
#   See Policies\*.yml and the script header for the two-pass load order
#   and the branch-scoped id-resolution rules that constrain it.
# ================================================================
function Invoke-ConjurLoadRootPolicy {
    Write-Host "`n### ConjurLoadRootPolicy ###" -ForegroundColor Cyan
    & "$PSScriptRoot\Scripts\41-LoadConjurRootPolicy.ps1" -LeaderVMName $ConjurPolicyVMName -GuestPass $ConjurPolicyGuestPass
}

# ---- menu (when no -Feature given) -------------------------------
if (-not $Feature) {
    Write-Host "`nOptional CyberArk lab features:" -ForegroundColor Cyan
    $keys = @($catalogue.Keys)
    for ($i=0; $i -lt $keys.Count; $i++) { Write-Host ("  {0}. {1,-18} {2}" -f ($i+1), $keys[$i], $catalogue[$keys[$i]]) }
    $sel = Read-Host "`nSelect feature number(s), comma-separated (or Enter to cancel)"
    if (-not $sel) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $Feature = $sel -split ',' | ForEach-Object { $n=[int]($_.Trim()); if ($n -ge 1 -and $n -le $keys.Count) { $keys[$n-1] } }
}

# ---- dispatch ----------------------------------------------------
Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Deploy-Optional: $($Feature -join ', ')" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan
foreach ($f in $Feature) {
    switch ($f) {
        "VaultADObjects"   { Invoke-VaultADObjects }
        "LDAPBindUser"     { Invoke-LDAPBindUser }
        "ReconcileAccount" { Invoke-ReconcileAccount }
        "DiscoveryAccount" { Invoke-DiscoveryAccount }
        "PTACertificates"  { Invoke-PTACertificates }
        "VaultPTASyslog"   { Invoke-VaultPTASyslog }
        "ConjurNodes"      { Invoke-ConjurNodes }
        "LoadBalancer"     { Invoke-LoadBalancer }
        "ConjurSystemFolders" { Invoke-ConjurSystemFolders }
        "ConjurAppliance"  { Invoke-ConjurAppliance }
        "ConjurDNS"        { Invoke-ConjurDNS }
        "ConjurInstallLeader" { Invoke-ConjurInstallLeader }
        "ConjurImportCertificates" { Invoke-ConjurImportCertificates }
        "ConjurEncryptKeys" { Invoke-ConjurEncryptKeys }
        "ConjurInstallStandby" { Invoke-ConjurInstallStandby }
        "ConjurInstallFollower" { Invoke-ConjurInstallFollower }
        "VaultConjurSynchronizer" { Invoke-VaultConjurSynchronizer }
        "ConjurLoadRootPolicy" { Invoke-ConjurLoadRootPolicy }
    }
}
Write-Host "`nDone." -ForegroundColor Green
