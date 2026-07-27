<#
.SYNOPSIS
    Create the DC01 DNS A-records the Conjur HA cluster needs (Installation
    deck's DNS prerequisite - "DNS name must resolve... DNS Server is
    required for auto-failover cluster").
.DESCRIPTION
    UNTESTED - first validation run pending.

    04-DeployDC.ps1 only creates A-records for vault01/comp01/pvwa - nothing
    for the Conjur nodes, so `evoke configure master --master-altnames` and
    every subsequent conjur/summon/CLI call would fail DNS resolution without
    this. Uses the same WinRM (Invoke-Command) pattern already used against
    DC01 elsewhere in this repo (Deploy-Optional.ps1's Invoke-DC helper).

    Records created (idempotent - existing records with the wrong IP are
    replaced, matching ones are left alone):
      conjur-l01      192.168.100.60  Leader
      conjur-s01      192.168.100.61  Standby 1
      conjur-s02      192.168.100.62  Standby 2
      conjur-f01      192.168.100.65  Follower (GitLab)
      conjur-f02      192.168.100.66  Follower (Kubernetes)
      conjur-app01    192.168.100.70  GitLab runner + k3s + HAProxy
      conjur-cluster   192.168.100.70  Leader-pool VIP   (HAProxy on APP01, :443/444/1999/5432)
      conjur-follower  192.168.100.71  Follower-pool VIP (HAProxy on APP01, second IP alias, :443/444)

    conjur-cluster and conjur-follower both live on APP01's single HAProxy
    instance, but as of the port/VIP fix below each gets its OWN IP
    (.70 vs .71, a second address alias on the same NIC) rather than
    sharing one IP differentiated by port. CyberArk's official port table
    only ever lists 443/444/1999/5432 - an earlier version of this lab used
    8443/8444 for the follower pool to share .70 with the leader pool,
    which isn't part of the real spec. Two IPs on one host still isn't
    identical to a real client's separate load-balancer VM/IP, but it lets
    every port number here match the documented spec exactly - see
    Scripts\31-ConfigureLoadBalancer.ps1's defaults.
.EXAMPLE
    .\34-ConfigureConjurDNS.ps1
.NOTES
    Requires WinRM reachability to DC01 and Domain Admin credentials (same
    as Deploy-Optional.ps1's other DC-touching features).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath

$dcIP    = $Config.Network.DNS
$domain  = $Config.Domain.Name
$netbios = $Config.Domain.NetBIOSName
$dcCred  = New-Object PSCredential("$netbios\$($Config.Domain.DomainAdminUser)",
           (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force))

function Invoke-DC {
    param([scriptblock]$Script, [object[]]$ArgumentList)
    for ($i = 1; $i -le 3; $i++) {
        try { return Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock $Script -ArgumentList $ArgumentList }
        catch { if ($i -eq 3) { throw } ; Start-Sleep 5 }
    }
}

$records = @(
    @{ Name = "conjur-l01";      IP = "192.168.100.60" }
    @{ Name = "conjur-s01";      IP = "192.168.100.61" }
    @{ Name = "conjur-s02";      IP = "192.168.100.62" }
    @{ Name = "conjur-f01";      IP = "192.168.100.65" }
    @{ Name = "conjur-f02";      IP = "192.168.100.66" }
    @{ Name = "conjur-app01";    IP = "192.168.100.70" }
    @{ Name = "conjur-cluster";  IP = "192.168.100.70" }
    @{ Name = "conjur-follower"; IP = "192.168.100.71" }
)

Write-Host "Configuring Conjur DNS A-records on DC01 ($dcIP, zone $domain)..." -ForegroundColor Cyan

$out = Invoke-DC -ArgumentList $domain, $records -Script {
    param($domain, $records)
    Import-Module DnsServer -ErrorAction Stop
    $log = New-Object System.Collections.Generic.List[string]
    foreach ($r in $records) {
        $name = $r.Name; $ip = $r.IP
        $existing = Get-DnsServerResourceRecord -ZoneName $domain -Name $name -RRType A -ErrorAction SilentlyContinue
        $current = $existing | Where-Object { $_.RecordData.IPv4Address.ToString() -eq $ip }
        if ($current) {
            $log.Add("UNCHANGED:$name.$domain -> $ip")
            continue
        }
        if ($existing) {
            $existing | Remove-DnsServerResourceRecord -ZoneName $domain -Force
            $log.Add("REPLACED:$name.$domain -> $ip")
        } else {
            $log.Add("CREATED:$name.$domain -> $ip")
        }
        Add-DnsServerResourceRecordA -Name $name -ZoneName $domain -IPv4Address $ip
    }
    $log
}
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host "`nDone. Verify from any domain-joined host: nslookup conjur-cluster.$domain" -ForegroundColor Cyan
