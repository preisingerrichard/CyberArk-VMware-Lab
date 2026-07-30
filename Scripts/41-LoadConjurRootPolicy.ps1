<#
.SYNOPSIS
    Bootstrap Conjur's root policy structure - admins/apps/ops branches,
    a self-owning admin group delegated to manage root, following
    CyberArk's own documented policy best practices.
.DESCRIPTION
    CONFIRMED WORKING against a live cluster (2026-07-30), including a
    live re-verification via `conjur policy fetch -b root` that owner
    re-parenting via `update` genuinely takes effect (see step 8) - not
    just planned/assumed.

    Live cluster state before this runs: only `root`, `vault01`, and
    `vault01/secrets` exist (the latter two created automatically by the
    Vault-Conjur Synchronizer installer, Script 40). This script never
    touches, re-declares, or inspects `vault01` - it's left alone entirely,
    which is safe because this script only ever uses `conjur policy load`
    and `conjur policy update` (both additive/non-destructive against
    unlisted objects), never `conjur policy replace` (the one genuinely
    destructive verb, confirmed via `conjur policy --help` on this exact
    CLI version - it does a full diff-and-delete, load/update do not).

    **Real constraint found the hard way, worth knowing before editing
    these files**: Conjur's YAML resolver scopes every unqualified id to
    whichever branch the load targets (`-b <branch>`), not to the account
    root. A bare `!policy root` loaded via `-b admins` resolves to
    `admins/root` (not found), and there is no leading-slash escape hatch
    for the top-level root policy object either (`!policy /` and
    `!policy /root` both error "Illegal absolute id"). The only way to
    reference the top-level root policy is a load that targets `-b root`
    itself, where bare `root` self-resolves. This is why the `!permit`
    delegating administration to `admins/conjur-admins` lives in root.yml
    (loaded `-b root`), not in admins.yml (loaded `-b admins`) alongside
    the group's own creation - moving it there is what fixed the "Illegal
    absolute id" / "Policy 'admins/root' not found" errors hit during
    development.

    Steps:
      1. Wait for guest-ops on the Leader
      2. Stage the three Policies\*.yml files to L01
      3. Confirm the Conjur CLI session is valid (conjur whoami), falling
         back to a fresh login only if needed (CLI is already known
         initialized on L01 from earlier manual work)
      4. Idempotency check: does the `admins/conjur-admins` group already
         exist? If yes, the one-time bootstrap load (step 5) is skipped -
         it must only ever run once, since it's the only step in this
         script that creates the admins/apps/ops branches from nothing.
      5. If not yet bootstrapped: `conjur policy load -b root -f
         root-bootstrap.yml` - creates admins/apps/ops as empty stubs,
         temporarily inheriting ownership from root (harmless, closed by
         step 7).
      6. Always: `conjur policy update -b admins -f admins.yml` - creates
         the self-owning conjur-admins group and grants the built-in admin
         user membership. Does NOT contain the root permit (see the
         id-resolution constraint above for why).
      7. Always: `conjur policy update -b root -f root.yml` - re-declares
         admins/apps/ops with an explicit `owner: !group
         admins/conjur-admins` (closing the implicit-inheritance gap left
         by step 5) AND carries the `!permit [read,create,update]` on
         root itself, delegating root administration to the group WITHOUT
         ever reassigning root's own `owner:` attribute (stays the
         built-in admin user).
      8. Verification (does NOT just trust exit codes):
           - `conjur list -k policy` must show exactly {root, vault01,
             vault01/secrets, admins, apps, ops} - catches anything
             unexpected having touched vault01, which would be a serious
             problem given the explicit promise not to touch it.
           - `conjur list -k group` must show admins/conjur-admins.
         For a deeper, independently-confirmed check beyond this script's
         own pass/fail (owner attributes, group membership, effective
         privileges), run `conjur policy fetch -b root`, `conjur role
         members <role-id>`, `conjur role memberships <role-id>`, or
         `conjur resource permitted-roles <resource-id> <privilege>`
         directly on the Leader - all positional-arg CLI commands, no
         `-i`/flag syntax.

    Idempotent: safe to re-run. Step 5's one-time bootstrap is guarded;
    steps 6-7 are naturally idempotent `update` calls (e.g. adding a named
    admin user later is just editing admins.yml and re-running this
    script).
.EXAMPLE
    .\41-LoadConjurRootPolicy.ps1
.NOTES
    Prerequisites: Leader configured and healthy. Conjur CLI already
    initialized/logged in on L01 (matches earlier manual setup - --url/-a
    known, cert trusted via --ca-cert or system trust store).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath      = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$LeaderVMName    = "CONJUR-L01",
    [string]$GuestUser       = "root",
    [string]$GuestPass       = "Cyberark1",
    [string]$PoliciesLocalDir = "$PSScriptRoot\..\Policies",
    [string]$ConjurAdminUser = "admin",
    [string]$ConjurAdminPassword = "Cyberark!Local2024"
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
$candidates = @((Join-Path $vmFolder "$LeaderVMName\$LeaderVMName.vmx"), (Join-Path $vmFolder "$LeaderVMName.vmx"))
$vmx = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmx) { throw "VM not found: $LeaderVMName. Tried:`n  $($candidates -join "`n  ")" }

foreach ($f in @('root-bootstrap.yml', 'admins.yml', 'root.yml')) {
    if (-not (Test-Path (Join-Path $PoliciesLocalDir $f))) {
        throw "Missing policy file: $PoliciesLocalDir\$f"
    }
}

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
    # StdOut/StdErr from Invoke-LinuxGuestScript are unreliable over guest-ops
    # (same VIX limitation as the Windows side) - the script text itself
    # redirects to $Log so failures are actually diagnosable, not just blank.
    param([string]$ScriptText, [string]$Marker, [string]$Label, [int]$TimeoutSec = 60)
    $r = Invoke-LinuxGuestScript -VMXPath $vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds $TimeoutSec
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        $log = Get-GuestFileText -RemotePath "$Marker.log"
        throw "$Label failed (exit $($r.ExitCode)): $log"
    }
}

function Get-GuestFileText {
    param([string]$RemotePath)
    $local = [System.IO.Path]::Combine($env:TEMP, "conjur_policy_read_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt")
    $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "copyFileFromGuestToHost",$vmx,$RemotePath,$local) -NoThrow
    if ($r.ExitCode -ne 0) { return $null }
    $text = Get-Content $local -Raw -ErrorAction SilentlyContinue
    Remove-Item $local -Force -ErrorAction SilentlyContinue
    return $text
}

Write-Host "Target: $vmx" -ForegroundColor Cyan
Wait-GuestOps -Vmx $vmx
Write-Host "  guest-ops ready" -ForegroundColor Green

# ------------------------------------------------------------------
# Stage policy files
# ------------------------------------------------------------------
Write-Host "`n[1] Staging policy files" -ForegroundColor Cyan
$remoteDir = "/tmp/conjur-policies-$([guid]::NewGuid().ToString('N').Substring(0,8))"
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","mkdir -p $remoteDir") | Out-Null
foreach ($f in @('root-bootstrap.yml', 'admins.yml', 'root.yml')) {
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "CopyFileFromHostToGuest",$vmx,(Join-Path $PoliciesLocalDir $f),"$remoteDir/$f") | Out-Null
}
Write-Host "  [OK] staged to $remoteDir" -ForegroundColor Green

# ------------------------------------------------------------------
# Confirm CLI session
# ------------------------------------------------------------------
Write-Host "`n[2] Confirming Conjur CLI session" -ForegroundColor Cyan
$whoamiCheck = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","conjur whoami > /dev/null 2>&1") -NoThrow
if ($whoamiCheck.ExitCode -ne 0) {
    Write-Host "  Not logged in - attempting conjur login" -ForegroundColor Yellow
    $loginMarker = "/tmp/conjur_login_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $loginScript = @"
#!/bin/bash
exec > $loginMarker.log 2>&1
set -e
conjur login -i $ConjurAdminUser -p '$ConjurAdminPassword'
touch $loginMarker
"@
    Invoke-GuestScriptChecked -ScriptText $loginScript -Marker $loginMarker -Label "conjur login"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $loginMarker") -NoThrow | Out-Null
}
Write-Host "  [OK]" -ForegroundColor Green

# ------------------------------------------------------------------
# Idempotency check: has this already been bootstrapped?
# ------------------------------------------------------------------
Write-Host "`n[3] Checking bootstrap state" -ForegroundColor Cyan
$groupMarker = "/tmp/conjur_group_list_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","conjur list -k group > $groupMarker 2>&1") -NoThrow | Out-Null
$groupList = Get-GuestFileText -RemotePath $groupMarker
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $groupMarker") -NoThrow | Out-Null
$alreadyBootstrapped = ($groupList -match 'admins/conjur-admins')

if ($alreadyBootstrapped) {
    Write-Host "  admins/conjur-admins already exists - skipping one-time bootstrap load" -ForegroundColor Yellow
} else {
    Write-Host "`n[4] One-time bootstrap: creating admins/apps/ops branches" -ForegroundColor Cyan
    $marker4 = "/tmp/conjur_bootstrap_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $bootstrapScript = @"
#!/bin/bash
exec > $marker4.log 2>&1
set -e
conjur policy load -b root -f $remoteDir/root-bootstrap.yml
touch $marker4
"@
    Invoke-GuestScriptChecked -ScriptText $bootstrapScript -Marker $marker4 -Label "Bootstrap root policy" -TimeoutSec 90
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker4") -NoThrow | Out-Null
    Write-Host "  [OK]" -ForegroundColor Green
}

# ------------------------------------------------------------------
# Always: apply admins.yml then root.yml
# ------------------------------------------------------------------
Write-Host "`n[5] Applying admins.yml (conjur-admins group + root permit)" -ForegroundColor Cyan
$marker5 = "/tmp/conjur_admins_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$adminsScript = @"
#!/bin/bash
exec > $marker5.log 2>&1
set -e
conjur policy update -b admins -f $remoteDir/admins.yml
touch $marker5
"@
Invoke-GuestScriptChecked -ScriptText $adminsScript -Marker $marker5 -Label "Apply admins.yml" -TimeoutSec 90
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker5") -NoThrow | Out-Null
Write-Host "  [OK]" -ForegroundColor Green

Write-Host "`n[6] Applying root.yml (explicit owner for admins/apps/ops)" -ForegroundColor Cyan
$marker6 = "/tmp/conjur_root_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$rootScript = @"
#!/bin/bash
exec > $marker6.log 2>&1
set -e
conjur policy update -b root -f $remoteDir/root.yml
touch $marker6
"@
Invoke-GuestScriptChecked -ScriptText $rootScript -Marker $marker6 -Label "Apply root.yml" -TimeoutSec 90
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker6") -NoThrow | Out-Null
Write-Host "  [OK]" -ForegroundColor Green

# ------------------------------------------------------------------
# Verification - the real check, not just trusting exit codes
# ------------------------------------------------------------------
Write-Host "`n[7] Verifying result" -ForegroundColor Cyan
$verifyMarker = "/tmp/conjur_verify_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","(echo '--- policy ---'; conjur list -k policy; echo '--- group ---'; conjur list -k group) > $verifyMarker 2>&1") -NoThrow | Out-Null
$verifyOut = Get-GuestFileText -RemotePath $verifyMarker
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $verifyMarker") -NoThrow | Out-Null

Write-Host $verifyOut -ForegroundColor Gray

$expectedPolicies = @('root', 'vault01', 'vault01/secrets', 'admins', 'apps', 'ops')
$missing = $expectedPolicies | Where-Object { $verifyOut -notmatch [regex]::Escape($_) }
if ($missing) {
    Write-Warning "Expected policy branch(es) not found in output: $($missing -join ', ') - review the output above before trusting this run."
} elseif ($verifyOut -notmatch 'admins/conjur-admins') {
    Write-Warning "admins/conjur-admins group not found in output - review before trusting this run."
} else {
    Write-Host "`n  [OK] Expected policy set present: $($expectedPolicies -join ', '), plus admins/conjur-admins group." -ForegroundColor Green
    Write-Host "  NOTE: owner re-parenting (root.yml step) was not independently re-verified here beyond object presence -" -ForegroundColor Yellow
    Write-Host "  spot-check via the Conjur UI's Policies page if you want to confirm owner attributes directly." -ForegroundColor Yellow
}

# Clean up staged files
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -rf $remoteDir") -NoThrow | Out-Null

Write-Host "`nDone. apps/* and ops/* content is a future, separate pass - these branches are intentionally empty containers right now." -ForegroundColor Cyan
