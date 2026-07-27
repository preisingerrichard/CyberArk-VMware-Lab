<#
.SYNOPSIS
    Generic HAProxy pool configurator - installs/configures HAProxy on a
    target RHEL guest and wires up one or more TCP-passthrough backend pools.
.DESCRIPTION
    UNTESTED - first validation run pending.

    Not Conjur-specific: takes an arbitrary list of pools (name, listen port,
    backend IP:port list) and writes each as its own idempotent config block,
    so the same script/feature configures a Conjur leader+follower LB today
    and a PVWA or PSM/PSMP pool later with no code changes - just parameters.

    TCP mode only (mode tcp, "option tcp-check") - deliberate. Conjur, PVWA
    and PSM/PSMP all do end-to-end TLS/RDP/SSH with the client; HAProxy must
    not terminate/inspect that traffic, only pass it through and health-check
    the raw TCP port. This matches the firewalld/service pattern already used
    elsewhere in this repo (Scripts\11-InstallPTA-Primary.ps1 etc.) rather
    than introducing a new one.

    Per pool, backends can be flagged 'backup' (suffix a backend entry with
    ":backup") for active/passive topologies - e.g. a Conjur leader pool
    where the standbys should only take traffic after the leader is promoted
    away and the old leader's healthcheck starts failing.

    Steps (guest-ops over vmrun, open-vm-tools, no network dependency):
      1. Wait for guest-ops to answer (same readiness probe as
         30-CloneConjurNodes.ps1 - checkToolsState is unreliable on this
         open-vm-tools build, so we probe runProgramInGuest directly instead)
      2. Install haproxy if missing (dnf) - if RHSM isn't registered on the
         target this fails with a clear, actionable message rather than a
         silent/opaque error
      3. Append each pool as a marker-delimited block directly in
         /etc/haproxy/haproxy.cfg ("# BEGIN POOL <name>" / "# END POOL <name>")
         - re-running replaces only that pool's block (sed delete +
         re-append), leaving the RPM's default global/defaults sections and
         any other pool's block untouched. (HAProxy has no nginx-style
         "includedir" - the stock RHEL systemd unit only loads haproxy.cfg
         itself, so pool config has to live in that one file, not conf.d.)
      4. Open each pool's listen port in firewalld (permanent + reload)
      5. Validate the resulting config (haproxy -c), enable+start (or
         reload) the service, and verify systemctl is-active as the success
         marker
.EXAMPLE
    # Default: the two Conjur pools, run against CONJUR-APP01
    .\31-ConfigureLoadBalancer.ps1

    # A future PVWA pool, explicit
    .\31-ConfigureLoadBalancer.ps1 -Pools @(
        @{ Name = "pvwa"; ListenPort = 443; Backends = @("192.168.100.30:443") }
    )
.NOTES
    Prerequisites on the target: open-vm-tools running, root login with the
    password given in -GuestPass, RHSM registered (haproxy comes from the
    RHEL AppStream repo).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$TargetVMX,                          # defaults to resolving CONJUR-APP01
    [string]$TargetName = "CONJUR-APP01",
    [array] $Pools,                               # default = the two Conjur pools below
    [string]$GuestUser  = "root",
    [string]$GuestPass  = "Cyberark1",
    [string]$Nic        = "ens160",
    [string]$FollowerVIP = "192.168.100.71"       # secondary IP alias on APP01 for the
                                                    # follower pool, so it can use plain
                                                    # 443/444 (CyberArk's real ports)
                                                    # instead of the old 8443/8444 workaround
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
if (-not $TargetVMX) {
    $candidates = @(
        (Join-Path $vmFolder "$TargetName\$TargetName.vmx"),
        (Join-Path $vmFolder "$TargetName.vmx")
    )
    $TargetVMX = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $TargetVMX) { throw "Target not found. Tried:`n  $($candidates -join "`n  ")`nRun 30-CloneConjurNodes.ps1 first, or pass -TargetVMX." }
}
if (-not (Test-Path $TargetVMX)) { throw "Target not found: $TargetVMX" }

if (-not $Pools) {
    # Default: the Conjur leader+standby pools and follower (leastconn) pool.
    # Per CyberArk's official port table, the leader LB VIP must forward more
    # than just 443: 444 (health), 1999 (syslog-ng audit stream - followers
    # stream audit data to the leader through this same VIP) and 5432
    # (Postgres replication - followers/standbys keep reconnecting through
    # the VIP across a failover, not directly to whichever node happens to
    # be leader right now). The follower pool needs its own 444 health
    # listener too. One HAProxy instance handles both pools, but each pool
    # gets its OWN IP (leader pool on APP01's primary .70, follower pool on
    # a second IP alias, $FollowerVIP) so both can use CyberArk's real
    # 443/444/1999/5432 ports - no port-differentiation workaround (an
    # earlier version of this script used 8443/8444 for the follower pool
    # since it shared .70 with the leader pool; that's not in CyberArk's
    # spec at all, the official port table only ever lists 443/444/1999/5432,
    # so it's been dropped in favor of a real second VIP, closer to how an
    # actual client site would be built).
    #
    # Leader-pool routing (443/444/1999/5432): all backends equal priority,
    # NOT a primary+backup static list - matches the official architecture
    # doc exactly: "The active Leader is the only node that returns a
    # successful response (200 OK) to the load balancer's health check
    # requests" / "Forward traffic to the active Leader only, not Standbys."
    # That's HTTP-level health-check-driven routing, not a static failover
    # order. A plain TCP-connect check can't tell "Leader" apart from "a
    # Standby that's still up and TCP-reachable but demoted" - which matters
    # specifically after a manual promotion where the old Leader keeps
    # running. HttpCheck=true pools below check GET /health on CheckPort
    # (443, where the real cert lives) regardless of the pool's own traffic
    # port, and only route to whichever backend currently returns 200.
    $Pools = @(
        @{ Name = "conjur-leader";             ListenPort = 443;  BindIP = "192.168.100.70"; HttpCheck = $true; CheckPort = 443; Backends = @("192.168.100.60:443","192.168.100.61:443","192.168.100.62:443") },
        @{ Name = "conjur-leader-health";       ListenPort = 444;  BindIP = "192.168.100.70"; HttpCheck = $true; CheckPort = 443; Backends = @("192.168.100.60:444","192.168.100.61:444","192.168.100.62:444") },
        @{ Name = "conjur-leader-replication";  ListenPort = 5432; BindIP = "192.168.100.70"; HttpCheck = $true; CheckPort = 443; Backends = @("192.168.100.60:5432","192.168.100.61:5432","192.168.100.62:5432") },
        @{ Name = "conjur-leader-audit";        ListenPort = 1999; BindIP = "192.168.100.70"; HttpCheck = $true; CheckPort = 443; Backends = @("192.168.100.60:1999","192.168.100.61:1999","192.168.100.62:1999") },
        @{ Name = "conjur-follower";            ListenPort = 443;  BindIP = $FollowerVIP; Backends = @("192.168.100.65:443","192.168.100.66:443") },
        @{ Name = "conjur-follower-health";     ListenPort = 444;  BindIP = $FollowerVIP; Backends = @("192.168.100.65:444","192.168.100.66:444") }
    )
}

# ---- vmrun helpers (mirrors 30-CloneConjurNodes.ps1) --------------
function Wait-GuestOps {
    param([string]$Vmx, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep 5
        $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$Vmx,"/bin/true") -NoThrow -TimeoutSeconds 20
        if ($r.ExitCode -eq 0) { return }
    } while ((Get-Date) -lt $deadline)
    throw "Guest-ops did not become available on $Vmx within $TimeoutSec s"
}

function Invoke-GuestScriptChecked {
    param([string]$Vmx, [string]$ScriptText, [string]$Marker, [string]$Label)
    $r = Invoke-LinuxGuestScript -VMXPath $Vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 300
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$Vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

Write-Host "Target: $TargetVMX" -ForegroundColor Cyan
Wait-GuestOps -Vmx $TargetVMX
Write-Host "  guest-ops ready" -ForegroundColor Green

# ------------------------------------------------------------------
# Install haproxy if missing
# ------------------------------------------------------------------
$installScript = @'
#!/bin/bash
set -e
if ! command -v haproxy >/dev/null 2>&1; then
  dnf install -y haproxy
fi
rm -f /tmp/lb_install_ok && touch /tmp/lb_install_ok
'@
$r = Invoke-LinuxGuestScript -VMXPath $TargetVMX -ScriptText $installScript `
     -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 300
$chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$TargetVMX,"/bin/bash","-c","test -f /tmp/lb_install_ok") -NoThrow
if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
    throw "haproxy install failed on $TargetVMX (likely RHSM not registered - run 'subscription-manager register' on the target first): $($r.StdErr) $($r.StdOut)"
}
Write-Host "  haproxy installed" -ForegroundColor Green

# ------------------------------------------------------------------
# Ensure the follower-pool secondary IP alias exists (idempotent - only
# added if a pool actually references it via BindIP, and only if not
# already present on the NIC). Lets the follower pool use CyberArk's real
# 443/444 instead of a port-differentiation workaround on the primary IP.
# ------------------------------------------------------------------
$bindIPs = $Pools | Where-Object { $_.BindIP } | ForEach-Object { $_.BindIP } | Select-Object -Unique
foreach ($vip in $bindIPs) {
    $vipMarker = "/tmp/lb_vip_$($vip -replace '\.','_')_ok"
    $vipScript = @"
#!/bin/bash
set -e
if ! ip -4 addr show $Nic | grep -q "$vip/"; then
  CON=`$(nmcli -g GENERAL.CONNECTION device show $Nic 2>/dev/null | head -1)
  nmcli con mod "`$CON" +ipv4.addresses $vip/24
  nmcli con up "`$CON" || true
fi
touch $vipMarker
"@
    Invoke-GuestScriptChecked -Vmx $TargetVMX -ScriptText $vipScript -Marker $vipMarker -Label "Ensure IP alias $vip on $Nic"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$TargetVMX,"/bin/bash","-c","rm -f $vipMarker") -NoThrow | Out-Null
    Write-Host "  IP alias $vip on $Nic confirmed" -ForegroundColor Green
}

# ------------------------------------------------------------------
# SELinux port labeling - RHEL's default policy only lets haproxy_t bind
# ports already typed http_port_t (443, 80, 8443, etc). Any other port
# haproxy needs to listen on (444, 1999, 5432 here) fails with a "cannot
# bind socket (Permission denied)" that looks like a plain Unix permission
# problem but is actually an SELinux denial - confirmed live: 443 bound
# fine, 444/1999/5432 all failed identically with nothing else holding
# those ports. 5432 in particular already ships pre-labeled
# postgresql_port_t by default (even with no local Postgres running) -
# `semanage port -a` errors if a port already has a different type, so this
# checks the current label first and uses -m (modify) instead of -a (add)
# when needed. Safe to relabel host-wide here since APP01 never runs a
# real Postgres server - this only affects APP01's own SELinux policy
# database, not L01/S01/S02.
# ------------------------------------------------------------------
$lbPorts = $Pools | ForEach-Object { $_.ListenPort } | Select-Object -Unique
$portList = $lbPorts -join ' '
$portMarker = "/tmp/lb_selinux_ports_ok"
$portScript = @"
#!/bin/bash
set -e
for p in $portList; do
  if semanage port -l | grep -qE "^http_port_t\s.*[ ,]`$p(,|$)"; then
    continue
  elif semanage port -l | grep -qE "[ ,]`$p(,|$)"; then
    semanage port -m -t http_port_t -p tcp `$p
  else
    semanage port -a -t http_port_t -p tcp `$p
  fi
done
touch $portMarker
"@
Invoke-GuestScriptChecked -Vmx $TargetVMX -ScriptText $portScript -Marker $portMarker -Label "SELinux port labeling"
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$TargetVMX,"/bin/bash","-c","rm -f $portMarker") -NoThrow | Out-Null
Write-Host "  SELinux port labels confirmed for: $portList" -ForegroundColor Green

# ------------------------------------------------------------------
# Write each pool's config block directly into haproxy.cfg
# (idempotent: sed-delete any prior block for this pool, then re-append)
# ------------------------------------------------------------------
foreach ($pool in $Pools) {
    $name = $pool.Name
    $port = $pool.ListenPort
    $mode = if ($pool.Mode) { $pool.Mode } else { "tcp" }
    Write-Host "`n=== Pool: $name (listen $port, mode $mode) ===" -ForegroundColor Magenta

    $httpCheck = [bool]$pool.HttpCheck

    $serverLines = ($pool.Backends | ForEach-Object {
        $parts = $_ -split ':'
        $ip = $parts[0]; $bport = $parts[1]; $isBackup = (-not $httpCheck -and $parts.Count -gt 2 -and $parts[2] -eq 'backup')
        $srvName = "srv-$($ip -replace '\.','-')"
        if ($httpCheck) {
            $cport = if ($pool.CheckPort) { $pool.CheckPort } else { $bport }
            "    server $srvName ${ip}:${bport} check port $cport check-ssl verify none"
        } else {
            $flag = if ($isBackup) { " backup" } else { "" }
            "    server $srvName ${ip}:${bport} check$flag"
        }
    }) -join "`n"

    $healthLines = if ($httpCheck) {
        "    option httpchk GET /health`n    http-check expect status 200"
    } else {
        "    option tcp-check"
    }
    $balance = if ($httpCheck) { "roundrobin" } else { "leastconn" }
    $bindAddr = if ($pool.BindIP) { $pool.BindIP } else { "*" }

    $poolCfg = @"
# BEGIN POOL $name (managed by 31-ConfigureLoadBalancer.ps1)
frontend fe_$name
    bind ${bindAddr}:$port
    mode $mode
    default_backend be_$name

backend be_$name
    mode $mode
    balance $balance
$healthLines
$serverLines
# END POOL $name
"@

    # Strip any previous block for this pool, then append the fresh one.
    # Pool names are simple slugs (no sed-special chars), so a literal
    # address-range delete is safe here.
    $writeScript = @"
#!/bin/bash
set -e
f=/etc/haproxy/haproxy.cfg
sed -i "/# BEGIN POOL $name /,/# END POOL $name\$/d" "`$f"
{
  echo ""
  cat <<'POOLCFG'
$poolCfg
POOLCFG
} >> "`$f"
rm -f /tmp/lb_pool_${name}_ok && touch /tmp/lb_pool_${name}_ok
"@
    Invoke-GuestScriptChecked -Vmx $TargetVMX -ScriptText $writeScript `
        -Marker "/tmp/lb_pool_${name}_ok" -Label "Write pool $name"
    Write-Host "  haproxy.cfg: pool block written ($($pool.Backends.Count) backend(s))" -ForegroundColor Green

    $fwScript = @"
#!/bin/bash
set -e
firewall-cmd --permanent --add-port=$port/tcp
rm -f /tmp/lb_fw_${name}_ok && touch /tmp/lb_fw_${name}_ok
"@
    Invoke-GuestScriptChecked -Vmx $TargetVMX -ScriptText $fwScript `
        -Marker "/tmp/lb_fw_${name}_ok" -Label "Open firewalld port for $name"
    Write-Host "  firewalld: $port/tcp opened (permanent)" -ForegroundColor Green
}

# ------------------------------------------------------------------
# Validate + (re)start haproxy
# ------------------------------------------------------------------
$activateScript = @'
#!/bin/bash
set -e
firewall-cmd --reload
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy >/dev/null 2>&1 || true
# Always restart, never `systemctl reload` - HAProxy's reload is a USR2-signaled
# re-exec that can fail silently: systemd's ExecReload subprocess (the config
# check + the kill -USR2) both report exit 0 even when the re-exec itself
# fails, so `set -e` never catches it and `systemctl is-active` still reports
# "active" because the OLD worker process just keeps running untouched.
# Confirmed live: a leader-pool routing fix sat correctly in haproxy.cfg for
# multiple re-runs while the actual listening process silently kept serving
# a 2-day-old config the whole time. Restart is a clean stop+start, no
# re-exec involved, no silent-failure mode.
systemctl restart haproxy
systemctl is-active --quiet haproxy
if systemctl show haproxy -p Result --value | grep -qv '^success$'; then
  systemctl status haproxy --no-pager
  exit 1
fi
rm -f /tmp/lb_activate_ok && touch /tmp/lb_activate_ok
'@
Invoke-GuestScriptChecked -Vmx $TargetVMX -ScriptText $activateScript `
    -Marker "/tmp/lb_activate_ok" -Label "Validate + start haproxy"

Write-Host "`nDone. haproxy active on $TargetName with $($Pools.Count) pool(s):" -ForegroundColor Cyan
foreach ($p in $Pools) { Write-Host "  - $($p.Name): listen $($p.ListenPort) -> $($p.Backends -join ', ')" -ForegroundColor Gray }
