<#
.SYNOPSIS
    Join all non-DC VMs to the domain
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Import-Module "$PSScriptRoot\..\Helpers\GuestHelper.psm1" -Force

$Config = Import-PowerShellDataFile $ConfigPath
Initialize-VMwareHelper -Config $Config.VMware

$deployedVMs = Import-Clixml "$PSScriptRoot\..\Config\DeployedVMs.xml"
$user = $Config.LocalAdmin.Username
$pass = $Config.LocalAdmin.Password

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "Joining VMs to Domain: $($Config.Domain.Name)" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan

# Only join non-DC, non-Vault VMs to the domain.
# Vault should remain standalone and not be domain joined.
$nonDCVMs = $Config.VMs | Where-Object {
    $roles = if ($_.Role -is [System.Array]) { $_.Role } else { @($_.Role) }
    -not ($roles -contains "DomainController") -and -not ($roles -contains "Vault")
}

foreach ($vm in $nonDCVMs) {
    $vmxPath = $deployedVMs[$vm.Name]
    Write-Host "`n--- Joining: $($vm.Name) ---" -ForegroundColor Yellow

    # Ensure DNS points to DC before attempting join
    $setDNS = @"
`$adapter = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex `$adapter.ifIndex ``
    -ServerAddresses @('$($Config.Network.DNS)')
Write-Host "DNS set to $($Config.Network.DNS)"

`$result = Resolve-DnsName '$($Config.Domain.Name)' -ErrorAction SilentlyContinue
if (`$result) {
    Write-Host "DNS resolution OK: $($Config.Domain.Name)"
} else {
    Write-Warning "Cannot resolve domain - check DC and network"
    ipconfig /flushdns
    Resolve-DnsName '$($Config.Domain.Name)' -ErrorAction Stop
}
"@

    Invoke-LabVMPowerShell -VMXPath $vmxPath -ScriptBlock $setDNS `
        -GuestUser $user -GuestPassword $pass

    Start-Sleep -Seconds 5

    # Join domain without -OUPath (uses default CN=Computers) and without restarting
    # inside the guest - restart is handled from the host to avoid killing the transcript.
    $joinDomain = @"
`$existing = (Get-WmiObject Win32_ComputerSystem).Domain
if (`$existing -eq '$($Config.Domain.Name)') {
    Write-Host "Already domain-joined: `$existing"
} else {
    `$secPass = ConvertTo-SecureString '$($Config.LocalAdmin.Password)' -AsPlainText -Force
    `$cred = New-Object System.Management.Automation.PSCredential('$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)', `$secPass)
    Add-Computer -DomainName '$($Config.Domain.Name)' -Credential `$cred -Force -ErrorAction Stop
    Write-Host "$($vm.Name) successfully joined to $($Config.Domain.Name)"
}
"@

    try {
        Invoke-LabVMPowerShell -VMXPath $vmxPath -ScriptBlock $joinDomain `
            -GuestUser $user -GuestPassword $pass
    } catch {
        # Read the guest error log so we can see the actual Add-Computer failure
        # Read the most recent transcript (script_TIMESTAMP.log) - unique per run,
        # never stale. The error.log uses -Append so it accumulates across runs.
        $tmpLog = Join-Path $env:TEMP "guest_log_$(Get-Random).txt"
        try {
            Invoke-VMRun -Arguments @(
                "-gu", $user, "-gp", $pass,
                "runProgramInGuest", "`"$vmxPath`"",
                "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-Command",
                "Get-ChildItem 'C:\LabSetup\Logs' -Filter 'script_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName | Set-Content 'C:\Windows\Temp\latestlog.txt' -Encoding UTF8"
            ) -NoThrow -TimeoutSeconds 20

            Copy-FileFromLabVM -VMXPath $vmxPath `
                -GuestPath 'C:\Windows\Temp\latestlog.txt' `
                -HostPath $tmpLog `
                -GuestUser $user -GuestPassword $pass
            $latestLogPath = (Get-Content $tmpLog -Raw -ErrorAction SilentlyContinue).Trim()

            if ($latestLogPath) {
                $tmpContent = Join-Path $env:TEMP "guest_content_$(Get-Random).txt"
                try {
                    Copy-FileFromLabVM -VMXPath $vmxPath `
                        -GuestPath $latestLogPath `
                        -HostPath $tmpContent `
                        -GuestUser $user -GuestPassword $pass
                    $logContent = Get-Content $tmpContent -Raw -ErrorAction SilentlyContinue
                    if ($logContent) {
                        Write-Host "`nGuest script transcript ($latestLogPath):" -ForegroundColor Red
                        Write-Host $logContent -ForegroundColor Red
                    }
                } finally { Remove-Item $tmpContent -Force -ErrorAction SilentlyContinue }
            }
        } catch { <# ignore log-copy failures #> }
        finally { Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue }
        throw
    }

    Write-Host "  Restarting $($vm.Name) to complete domain join..." -ForegroundColor DarkGray
    Restart-LabVM -VMXPath $vmxPath
    Start-Sleep -Seconds 15

    Write-Host "  Waiting for $($vm.Name) to come back online..." -ForegroundColor DarkGray
    Wait-LabVMReady -VMXPath $vmxPath -TimeoutSeconds 300

    # Verify with LOCAL credentials - VGAuth authenticates against local SAM reliably;
    # domain auth via vmrun is not dependable.
    $verifyScript = @"
`$domain = (Get-WmiObject Win32_ComputerSystem).Domain
Write-Host "Domain: `$domain"
if (`$domain -eq '$($Config.Domain.Name)') {
    Write-Host "VERIFIED: $($vm.Name) is domain-joined"
} else {
    throw "$($vm.Name) domain join FAILED - current domain: `$domain"
}
"@

    Invoke-LabVMPowerShell -VMXPath $vmxPath -ScriptBlock $verifyScript `
        -GuestUser $user -GuestPassword $pass

    Write-Host "  $($vm.Name) domain join confirmed." -ForegroundColor Green
}

# Snapshot — delete first so re-runs don't fail with "name already exists"
foreach ($vm in $nonDCVMs) {
    $vmx = $deployedVMs[$vm.Name]
    Stop-LabVM -VMXPath $vmx
    Start-Sleep -Seconds 10
    Invoke-VMRun -Arguments @("deleteSnapshot", "`"$vmx`"", "DomainJoined") -NoThrow | Out-Null
    New-LabVMSnapshot -VMXPath $vmx -SnapshotName "DomainJoined"
    Start-LabVM -VMXPath $vmx -NoGUI
}

Write-Host "`n$("=" * 60)" -ForegroundColor Green
Write-Host "All eligible VMs joined to domain (Vault excluded)." -ForegroundColor Green
Write-Host $("=" * 60) -ForegroundColor Green