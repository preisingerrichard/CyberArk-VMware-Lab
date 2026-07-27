<#
.SYNOPSIS
    Create the Conjur system folders (Installation deck, Step 2) on every
    Conjur node - Leader, Standbys, Followers.
.DESCRIPTION
    UNTESTED - first validation run pending.

    mkdir -p /opt/cyberark/conjur/{security,config,backups,seeds,logs} on each
    target, over the vmrun guest-ops channel (no SSH/console login needed) -
    same mechanism as 30-CloneConjurNodes.ps1 / 31-ConfigureLoadBalancer.ps1 /
    Register-RHSM.ps1.

    Folder names/purpose match CyberArk's official "Deploy a Secrets Manager
    container image" doc exactly (not the older training deck, which used
    singular "backup" in its mkdir step while its own docker-run step mounted
    "backups" - an internal inconsistency in the deck that we initially
    "fixed" the wrong way; the current official docs are consistently plural):
      security  Docker/Podman seccomp.json
      config    Conjur configuration file
      backups   backups available on the host
      seeds     seed files transferred into the container
      logs      direct host access to Conjur logs

    Default target set is the five actual Conjur appliance nodes
    (L01/S01/S02/F01/F02) - CONJUR-APP01 is excluded, it only runs the
    GitLab runner / k3s / HAProxy, never a Conjur container itself.
.EXAMPLE
    .\32-CreateConjurSystemFolders.ps1
    .\32-CreateConjurSystemFolders.ps1 -VMNames CONJUR-L01
.NOTES
    Prerequisite on each target: open-vm-tools running, root login with the
    password given in -GuestPass. RHSM registration is NOT required for this
    step (mkdir needs no packages).
#>

[CmdletBinding()]
param(
    [string]  $ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string[]]$VMNames    = @("CONJUR-L01","CONJUR-S01","CONJUR-S02","CONJUR-F01","CONJUR-F02"),
    [string]  $GuestUser  = "root",
    [string]  $GuestPass  = "Cyberark1",
    [string]  $BasePath   = "/opt/cyberark/conjur",
    [string[]]$Folders    = @("security","config","backups","seeds","logs")
)

$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile $ConfigPath
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
if (-not $VMNames) { throw "Pass -VMNames, e.g. -VMNames CONJUR-L01" }

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

function Invoke-GuestScriptChecked {
    param([string]$Vmx, [string]$ScriptText, [string]$Marker, [string]$Label)
    $r = Invoke-LinuxGuestScript -VMXPath $Vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds 120
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$Vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

$folderList = ($Folders -join ",")
$results = @()

foreach ($name in $VMNames) {
    Write-Host "`n=== $name ===" -ForegroundColor Magenta
    $vmx = Resolve-NodeVMX -Name $name
    Wait-GuestOps -Vmx $vmx
    Write-Host "  guest-ops ready" -ForegroundColor Green

    $marker = "/tmp/conjur_folders_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $script = @"
#!/bin/bash
set -e
mkdir -p $BasePath/{$folderList}
touch $marker
"@
    try {
        Invoke-GuestScriptChecked -Vmx $vmx -ScriptText $script `
            -Marker $marker -Label "Create system folders on $name"
        Write-Host "  $BasePath/{$folderList} created" -ForegroundColor Green
        $results += [PSCustomObject]@{ Node = $name; Status = "OK" }
    } catch {
        Write-Warning "  $($_.Exception.Message)"
        $results += [PSCustomObject]@{ Node = $name; Status = "FAILED" }
    } finally {
        Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
            "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
    }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.Status -ne "OK" }) {
    throw "One or more nodes failed - see warnings above."
}
