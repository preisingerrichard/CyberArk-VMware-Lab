<#
.SYNOPSIS
    Create the CyberArk Vault OU, role groups, and users in Active Directory.
.DESCRIPTION
    Optional lab feature (opt-in; NOT part of the default Deploy-Lab run). On a
    fresh domain none of these objects exist, so this script creates the full
    structure and is fully idempotent:

      OU=<OUName>
        Lab-Vault-Admins        <- vault_admin1..N
        Lab-Vault-Users         <- vault_user1..N
        Lab-Vault-Auditors      <- vault_auditor1..N
        Lab-Vault-SafeManagers  <- vault_safemgr1..N

    These groups map to Vault authorizations once the Vault external directory
    (LDAP) is configured. Uses only the supported ActiveDirectory PowerShell
    module on DC01 - nothing is touched on the appliances - so it is redeploy /
    upgrade safe. Idempotent: an existing OU/group/user (matched by name, in any
    container) is reused; only missing objects are created, membership ensured.

    Usage:
      .\20-CreateVaultADObjects.ps1
      .\20-CreateVaultADObjects.ps1 -OUName CyberArk -UsersPerGroup 10 -UserPassword 'Cyberark1!'
.NOTES
    Run after the domain controller is up (DomainController step).
#>

param(
    [string]$ConfigPath           = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$OUName               = "CyberArk",
    [ValidateRange(1, 100)]
    [int]   $UsersPerGroup        = 10,
    [string]$UserPassword         = "Cyberark1!",
    [bool]  $PasswordNeverExpires = $true,
    # Group display name -> user-name prefix
    [hashtable[]]$RoleMap = @(
        @{ Group = "Lab-Vault-Admins";       Prefix = "vault_admin"   },
        @{ Group = "Lab-Vault-Users";        Prefix = "vault_user"    },
        @{ Group = "Lab-Vault-Auditors";     Prefix = "vault_auditor" },
        @{ Group = "Lab-Vault-SafeManagers"; Prefix = "vault_safemgr" }
    )
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath

$dcIP    = $Config.Network.DNS
$domain  = $Config.Domain.Name                      # cyberark.lab
$netbios = $Config.Domain.NetBIOSName               # CYBERARKLAB
$dcCred  = New-Object PSCredential(
    "$netbios\$($Config.Domain.DomainAdminUser)",
    (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force)
)

Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host "Create Vault AD OU + role groups + users (optional feature)" -ForegroundColor Cyan
Write-Host "  Domain: $domain   OU: OU=$OUName   Users/group: $UsersPerGroup" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan

$result = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
    param($domain, $OUName, $roles, $count, $password, $pwdNeverExpires)
    Import-Module ActiveDirectory -ErrorAction Stop
    $log = New-Object System.Collections.Generic.List[string]

    $baseDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $ouDN   = "OU=$OUName,$baseDN"
    $secPw  = ConvertTo-SecureString $password -AsPlainText -Force

    # OU (create if missing)
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -SearchBase $baseDN -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $OUName -Path $baseDN -ProtectedFromAccidentalDeletion $false
        $log.Add("OU_CREATED:$ouDN")
    } else { $log.Add("OU_FOUND:$ouDN") }

    foreach ($r in $roles) {
        $grp = $r.Group; $prefix = $r.Prefix

        # Group: reuse if it exists anywhere (matched by name); else create in the OU
        $g = Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue
        if (-not $g) {
            New-ADGroup -Name $grp -SamAccountName ($grp -replace '[^A-Za-z0-9]','') `
                -GroupCategory Security -GroupScope Global -Path $ouDN
            $g = Get-ADGroup -Filter "Name -eq '$grp'"
            $log.Add("GROUP_CREATED:$grp")
        } else { $log.Add("GROUP_FOUND:$grp ($($g.DistinguishedName))") }

        $created = 0; $existed = 0; $added = 0
        for ($i = 1; $i -le $count; $i++) {
            $sam = "$prefix$i"
            $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
            if (-not $u) {
                New-ADUser -Name $sam -SamAccountName $sam `
                    -UserPrincipalName "$sam@$domain" -Path $ouDN `
                    -AccountPassword $secPw -Enabled $true `
                    -PasswordNeverExpires:$pwdNeverExpires -ChangePasswordAtLogon:$false
                $created++
            } else { $existed++ }

            $isMember = Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction SilentlyContinue |
                        Where-Object { $_.SamAccountName -eq $sam }
            if (-not $isMember) { Add-ADGroupMember -Identity $g.DistinguishedName -Members $sam; $added++ }
        }
        $log.Add("$grp : users created=$created existed=$existed, members_added=$added")
    }
    $log
} -ArgumentList $domain, $OUName, $RoleMap, $UsersPerGroup, $UserPassword, $PasswordNeverExpires

$result | ForEach-Object {
    $color = if ($_ -match 'CREATED|created=[1-9]|added=[1-9]') { 'Green' } else { 'DarkGray' }
    Write-Host "  $_" -ForegroundColor $color
}

Write-Host "`n[OK] Vault AD OU, role groups, and users ready." -ForegroundColor Green
Write-Host "Next (optional): configure the Vault external directory (LDAP) to map these groups to Vault authorizations." -ForegroundColor DarkGray
