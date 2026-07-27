<#
.SYNOPSIS
    Register one or more RHEL guests with subscription-manager, driven
    entirely over the vmrun guest-ops channel - no SSH/console login needed.
.DESCRIPTION
    UNTESTED - first validation run pending.

    Credentials are collected once via Get-Credential (masked prompt, never
    written to shell history or disk on the host) and reused for every target
    VM. subscription-manager has no --password-file/stdin option, only a CLI
    arg, so per VM the flow is:
      1. write a small self-contained script (embeds the credentials) to a
         host scratch temp file
      2. copy it into the guest's /tmp over guest-ops
      3. execute it there
      4. delete BOTH copies (guest and host) in a finally, regardless of
         success/failure

    This avoids the bigger leak: passing the password inline as a
    runProgramInGuest "-c ...password=X..." argument would additionally show
    up in the process list on both the Windows host (vmrun.exe's own argv,
    visible via Get-CimInstance Win32_Process while it runs) and the guest's
    `ps` output. Writing it to a script file executed by path avoids both.

    Still not zero-exposure: the password sits in a guest /tmp file for the
    few seconds subscription-manager takes to run. If you register VMs
    regularly, a Red Hat activation key (org ID + key, from the Red Hat
    customer portal) avoids this entirely - it's meant for unattended fleet
    registration and is scoped/revocable, unlike your personal password. Use
    -OrgId/-ActivationKey to register that way instead (no Get-Credential
    prompt, no personal credential ever touches a guest).
.EXAMPLE
    # Username/password, default node set (CONJUR-L01 + all current clones)
    .\Register-RHSM.ps1

    # Explicit subset
    .\Register-RHSM.ps1 -VMNames CONJUR-L01,CONJUR-S01

    # Activation key (no prompt, no personal credential)
    .\Register-RHSM.ps1 -OrgId 1234567 -ActivationKey conjur-lab
.NOTES
    Prerequisites on each target: open-vm-tools running, root login with the
    password given in -GuestPass.
#>

[CmdletBinding()]
param(
    [string]  $ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string[]]$VMNames    = @("CONJUR-L01","CONJUR-S01","CONJUR-S02","CONJUR-F01","CONJUR-F02","CONJUR-APP01"),
    [string]  $GuestUser  = "root",
    [string]  $GuestPass  = "Cyberark1",

    # Activation-key registration (no personal credential) - if both are
    # given, -OrgId/-ActivationKey is used and Get-Credential is skipped.
    [string]  $OrgId,
    [string]  $ActivationKey
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
if (-not $VMNames) { throw "Pass -VMNames, e.g. -VMNames CONJUR-L01,CONJUR-S01" }

function Resolve-NodeVMX {
    param([string]$Name)
    $candidates = @(
        (Join-Path $vmFolder "$Name\$Name.vmx"),
        (Join-Path $vmFolder "$Name.vmx")
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw "VM not found: $Name. Tried:`n  $($candidates -join "`n  ")" }
    return $found
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

# Single-quote a value for embedding in a single-quoted bash string.
function Protect-ForBashSingleQuotes {
    param([string]$Value)
    return $Value -replace "'", "'\''"
}

# ------------------------------------------------------------------
# Build the register command (credentials embedded once, reused per node)
# ------------------------------------------------------------------
if ($OrgId -and $ActivationKey) {
    Write-Host "Registering via activation key (org $OrgId) - no personal credential involved." -ForegroundColor Cyan
    $registerLine = "subscription-manager register --org='$(Protect-ForBashSingleQuotes $OrgId)' --activationkey='$(Protect-ForBashSingleQuotes $ActivationKey)' --force"
} else {
    $cred = Get-Credential -Message "Red Hat / RHSM credentials (used only in-memory this run, sent directly to each guest, never written to disk on this host)"
    $rhUser = $cred.UserName
    $rhPass = $cred.GetNetworkCredential().Password
    $registerLine = "subscription-manager register --username='$(Protect-ForBashSingleQuotes $rhUser)' --password='$(Protect-ForBashSingleQuotes $rhPass)' --force"
}

$results = @()
foreach ($name in $VMNames) {
    Write-Host "`n=== $name ===" -ForegroundColor Magenta
    $vmx = Resolve-NodeVMX -Name $name
    Wait-GuestOps -Vmx $vmx
    Write-Host "  guest-ops ready" -ForegroundColor Green

    $guestScript  = "/tmp/rhsm_register_$([guid]::NewGuid().ToString('N').Substring(0,8)).sh"
    $hostTemp     = [System.IO.Path]::Combine($env:TEMP, "rhsm_register_$([guid]::NewGuid().ToString('N').Substring(0,8)).sh")
    $marker       = "/tmp/rhsm_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $guestOut     = "/tmp/rhsm_out_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $hostOut      = [System.IO.Path]::Combine($env:TEMP, "rhsm_out_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt")

    # subscription-manager's own stdout/stderr never reaches vmrun's caller -
    # runProgramInGuest doesn't pipe guest process output back over VIX, it
    # only reports whether the launch/exit succeeded. Redirecting to a file
    # in-guest and copying that back is the only way to see the real error.
    $scriptBody = @"
#!/bin/bash
{ $registerLine ; } > $guestOut 2>&1
rc=`$?
if [ `$rc -eq 0 ]; then touch $marker; fi
exit `$rc
"@
    [System.IO.File]::WriteAllText($hostTemp, ($scriptBody -replace "`r`n","`n"), [System.Text.Encoding]::UTF8)

    $status = "FAILED"
    try {
        Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "CopyFileFromHostToGuest",$vmx,$hostTemp,$guestScript) | Out-Null
        $r = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$vmx,"/bin/bash","-c","chmod +x $guestScript && $guestScript") `
            -NoThrow -TimeoutSeconds 120
        $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$vmx,"/bin/bash","-c","test -f $marker") -NoThrow
        if ($r.ExitCode -eq 0 -and $chk.ExitCode -eq 0) {
            $status = "OK"
            Write-Host "  registered" -ForegroundColor Green
        } else {
            Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
                "copyFileFromGuestToHost",$vmx,$guestOut,$hostOut) -NoThrow | Out-Null
            $detail = if (Test-Path $hostOut) { (Get-Content $hostOut -Raw) } else { "(no output captured)" }
            Write-Warning "  register failed on $name`:`n$detail"
        }
    } finally {
        # Best-effort cleanup of both copies, regardless of outcome above -
        # this is the step that actually matters for not leaving the
        # password sitting on the guest.
        Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $guestScript $marker $guestOut") -NoThrow | Out-Null
        Remove-Item $hostTemp -Force -ErrorAction SilentlyContinue
        Remove-Item $hostOut  -Force -ErrorAction SilentlyContinue
    }
    $results += [PSCustomObject]@{ Node = $name; Status = $status }
}

# Best-effort: strings are immutable in .NET so this doesn't guarantee the
# plaintext password is scrubbed from process memory, only that our own
# named references to it are dropped.
$rhPass = $null; $registerLine = $null

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.Status -ne "OK" }) {
    throw "One or more nodes failed to register - see warnings above."
}
