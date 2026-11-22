<#
.SYNOPSIS
    Create the AD objects for the CyberArk Vault LDAP integration on DC01.
.DESCRIPTION
    Runs against DC01 over WinRM using only the supported ActiveDirectory module
    and dsacls. Idempotent - a second run changes nothing.

    LDAP bind account:
      - OU=ServiceAccounts at the domain root
      - svc-cybr-ldap ("CyberArk LDAP Bind") in that OU, password never expires
        (moved there if it exists elsewhere, e.g. CN=Users from older versions)
      - List Contents (LC) on the domain root, inherited - read-only, nothing more

    Vault role objects (OU=CyberArk):
      - Lab-Vault-Admins / -Users / -Auditors / -SafeManagers (Global Security)
        An existing group elsewhere (e.g. CN=Users) is MOVED, not recreated, so
        its SID and membership are preserved.
      - vault_admin1..N / vault_user1..N / vault_auditor1..N / vault_safemgr1..N,
        each a member of its role group. A user that already exists outside
        OU=CyberArk is left where it is (WARN) and only its membership is ensured.

    Nothing else in AD is touched. The Vault/PVWA side (LDAP directory + group
    mappings) is 17-ConfigureVaultLDAP.ps1.

    Usage:
      .\16-CreateVaultADObjects.ps1
      .\16-CreateVaultADObjects.ps1 -UsersPerGroup 3
      .\16-CreateVaultADObjects.ps1 -ResetBindPassword   # existing bind user, unknown password
.NOTES
    Run after 04-DeployDC.ps1.
#>

param(
    [string]$ConfigPath      = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$OUName          = "CyberArk",
    [ValidateRange(1,100)][int]$UsersPerGroup = 10,
    [string]$UserPassword    = "Cyberark1!",
    [string]$BindUser        = "svc-cybr-ldap",
    [string]$BindDisplayName = "CyberArk LDAP Bind",
    [string]$BindPassword    = "Cyberark1!",
    [string]$BindOU          = "ServiceAccounts",
    [switch]$ResetBindPassword          # set an EXISTING bind user's password to -BindPassword
)

$ErrorActionPreference = 'Stop'

$Config  = Import-PowerShellDataFile $ConfigPath
$dcIP    = $Config.Network.DNS
$domain  = $Config.Domain.Name
$netbios = $Config.Domain.NetBIOSName
$dcCred  = New-Object PSCredential("$netbios\$($Config.Domain.DomainAdminUser)",
           (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force))

$roles = @(
    @{ Group = "Lab-Vault-Admins";       Prefix = "vault_admin"   },
    @{ Group = "Lab-Vault-Users";        Prefix = "vault_user"    },
    @{ Group = "Lab-Vault-Auditors";     Prefix = "vault_auditor" },
    @{ Group = "Lab-Vault-SafeManagers"; Prefix = "vault_safemgr" }
)

function Invoke-DC {
    # Invoke-Command to DC01 with a small retry (WinRM can transiently fail).
    param([scriptblock]$Script, [object[]]$ArgumentList)
    for ($i = 1; $i -le 3; $i++) {
        try { return Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock $Script -ArgumentList $ArgumentList }
        catch { if ($i -eq 3) { throw "DC01 ($dcIP) remote step failed after 3 attempts: $($_.Exception.Message)" } ; Start-Sleep 5 }
    }
}

Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Create Vault AD objects on DC01 ($dcIP)" -ForegroundColor Cyan
Write-Host "  Bind user: $BindUser in OU=$BindOU  |  Roles: OU=$OUName, $UsersPerGroup users/group" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan

# ================================================================
# Part 1: LDAP bind account
# ================================================================
Write-Host "`n[1/2] LDAP bind account..." -ForegroundColor Yellow
$out = Invoke-DC -ArgumentList $domain, $netbios, $BindUser, $BindDisplayName, $BindPassword, $BindOU, $ResetBindPassword.IsPresent -Script {
    param($domain, $netbios, $sam, $displayName, $password, $bindOU, $resetPw)
    Import-Module ActiveDirectory -ErrorAction Stop
    $log    = New-Object System.Collections.Generic.List[string]
    $baseDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $ouDN   = "OU=$bindOU,$baseDN"
    $upn    = "$sam@$domain"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $bindOU -Path $baseDN -ProtectedFromAccidentalDeletion $false
        $log.Add("OU_CREATED:$ouDN")
    } else { $log.Add("OU_FOUND:$ouDN") }

    $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if (-not $u) {
        New-ADUser -Name $displayName -DisplayName $displayName -SamAccountName $sam -UserPrincipalName $upn -Path $ouDN `
            -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) -Enabled $true `
            -PasswordNeverExpires $true -ChangePasswordAtLogon $false `
            -Description "CyberArk PAM LDAP bind account - read-only directory queries"
        $log.Add("USER_CREATED:$upn")
    } else {
        if ($u.DistinguishedName -notlike "*,$ouDN") {
            Move-ADObject -Identity $u.DistinguishedName -TargetPath $ouDN
            $log.Add("USER_MOVED:$upn -> $ouDN")
        } else { $log.Add("USER_FOUND:$upn") }
        if (-not (Get-ADUser $sam -Properties PasswordNeverExpires).PasswordNeverExpires) {
            Set-ADUser -Identity $sam -PasswordNeverExpires $true; $log.Add("PWD_NEVER_EXPIRES_SET")
        }
        if ($resetPw) {
            Set-ADAccountPassword -Identity $sam -Reset -NewPassword (ConvertTo-SecureString $password -AsPlainText -Force)
            $log.Add("PASSWORD_RESET")
        }
    }

    # List Contents on the domain root (inherited). Only grant when missing.
    $id  = "$netbios\$sam"
    $ace = (Get-Acl "AD:\$baseDN").Access | Where-Object {
        $_.IdentityReference.Value -eq $id -and $_.AccessControlType -eq 'Allow' -and
        ($_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::ListChildren) }
    if ($ace) { $log.Add("LIST_CONTENTS_FOUND") }
    else {
        $r = & dsacls $baseDN /I:T /G "${id}:LC" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "dsacls failed: $($r | Select-Object -Last 1)" }
        $log.Add("LIST_CONTENTS_GRANTED")
    }

    # Confirm the bind credentials work with a simple bind on 389 - exactly what the Vault does.
    # (DirectoryEntry is not used: its PowerShell adapter swallows bind failures.)
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $ldap = New-Object System.DirectoryServices.Protocols.LdapConnection("localhost:389")
    $ldap.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
    $ldap.SessionOptions.ProtocolVersion = 3
    try { $ldap.Bind((New-Object System.Net.NetworkCredential($upn, $password))); $log.Add("BIND_CHECK:OK") }
    catch { $log.Add("BIND_CHECK:FAIL $($_.Exception.Message)") }
    finally { $ldap.Dispose() }
    $log
}
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($out -match '^BIND_CHECK:FAIL') {
    Write-Warning "Bind with -BindPassword failed - $BindUser already exists with a different password. Re-run with -ResetBindPassword, or pass the right -BindPassword (17-ConfigureVaultLDAP.ps1 needs it)."
} else { Write-Host "  [OK] Bind account ready" -ForegroundColor Green }

# ================================================================
# Part 2: Vault role groups + users in OU=CyberArk
# ================================================================
Write-Host "`n[2/2] Vault role groups + users..." -ForegroundColor Yellow
$out = Invoke-DC -ArgumentList $domain, $OUName, $roles, $UsersPerGroup, $UserPassword -Script {
    param($domain, $OUName, $roles, $count, $password)
    Import-Module ActiveDirectory -ErrorAction Stop
    $log    = New-Object System.Collections.Generic.List[string]
    $baseDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $ouDN   = "OU=$OUName,$baseDN"
    $secPw  = ConvertTo-SecureString $password -AsPlainText -Force

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $OUName -Path $baseDN -ProtectedFromAccidentalDeletion $false
        $log.Add("OU_CREATED:$ouDN")
    } else { $log.Add("OU_FOUND:$ouDN") }

    foreach ($r in $roles) {
        $grp = $r.Group; $prefix = $r.Prefix
        $found = @(Get-ADGroup -Filter "Name -eq '$grp'" -Properties ProtectedFromAccidentalDeletion -ErrorAction SilentlyContinue)
        if ($found.Count -gt 1) { throw "Group '$grp' exists $($found.Count) times ($($found.DistinguishedName -join '; ')) - resolve manually" }
        if ($found.Count -eq 0) {
            New-ADGroup -Name $grp -SamAccountName ($grp -replace '[^A-Za-z0-9]','') -GroupCategory Security -GroupScope Global -Path $ouDN
            $log.Add("GROUP_CREATED:$grp")
        } elseif ($found[0].DistinguishedName -ne "CN=$grp,$ouDN") {
            $sid = $found[0].SID.Value
            if ($found[0].ProtectedFromAccidentalDeletion) {
                Set-ADObject -Identity $found[0].DistinguishedName -ProtectedFromAccidentalDeletion $false
            }
            Move-ADObject -Identity $found[0].DistinguishedName -TargetPath $ouDN
            $after = Get-ADGroup -Identity $sid
            $log.Add("GROUP_MOVED:$grp $($found[0].DistinguishedName) -> $($after.DistinguishedName) (SID unchanged)")
        } else { $log.Add("GROUP_FOUND:$grp") }
        $g = Get-ADGroup -Filter "Name -eq '$grp'"

        $members = @(Get-ADGroupMember -Identity $g.DistinguishedName | ForEach-Object { $_.SamAccountName })
        $c = 0; $e = 0; $a = 0
        for ($i = 1; $i -le $count; $i++) {
            $sam = "$prefix$i"
            $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
            if (-not $u) {
                New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName "$sam@$domain" -Path $ouDN `
                    -AccountPassword $secPw -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
                $c++
            } else {
                $e++
                if ($u.DistinguishedName -notlike "*,$ouDN") { $log.Add("WARN_USER_OUTSIDE_OU:$($u.DistinguishedName) (left in place)") }
            }
            if ($members -notcontains $sam) { Add-ADGroupMember -Identity $g.DistinguishedName -Members $sam; $a++ }
        }
        $log.Add("$grp : users created=$c existed=$e added-to-group=$a")
    }
    $log
}
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  [OK] Vault AD objects ready. Next: 17-ConfigureVaultLDAP.ps1 (Vault LDAP directory + mappings)." -ForegroundColor Green
