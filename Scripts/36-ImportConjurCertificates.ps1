<#
.SYNOPSIS
    Issue CA-signed certificates from DC01's Enterprise CA and import them
    into the Conjur Leader (Installation deck Step 8 / Exercise Guide's
    3-import-cert.sh).
.DESCRIPTION
    UNTESTED - first validation run pending.

    Conjur ships no CSR-generation utility (unlike PTA's
    certificateSigningRequestGenerationUtil.sh) - the deck's own reference
    scripts just call openssl directly with a SAN config file. This script
    does the same, then reuses the DC01 CA workflow already proven by
    14-ConfigurePTACertificates.ps1:
      - EDITF_ATTRIBUTESUBJECTALTNAME2 (SAN support) + clientAuth EKU on the
        WebServer template - idempotent, a no-op if PTA cert setup already
        did this (it does the same DC01 prep, so running both features is
        harmless either order)
      - certreq -q -submit against that template, same CRL-stale retry guard

    Two certificates per the deck's certificate spec (page 9):
      "leader"   CN=conjur-cluster - SAN = cluster + leader + both standbys.
                 Imported with `evoke ca import --set` (becomes the ACTIVE
                 serving cert).
      "follower" CN=conjur-follower - SAN = follower VIP + both followers.
                 Imported without --set (available for follower chain use,
                 not the leader's own serving cert).

    Steps:
      1. Prep DC01 CA (idempotent)
      2. For each pool: generate CSR+key on the Leader via openssl (guest-ops),
         submit to DC01, download the signed cert
      3. Copy root CA cert + both certs/keys into the Leader container
      4. `evoke ca import` (root, then leader --set, then follower)
      5. Restart Conjur services, verify /health
.EXAMPLE
    .\36-ImportConjurCertificates.ps1
.NOTES
    Prerequisite: Leader container running and evoke-configured (Scripts 35
    + evoke configure master). DC01 must have AD CS installed (same
    requirement as 14-ConfigurePTACertificates.ps1).
#>

[CmdletBinding()]
param(
    [string]$ConfigPath    = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$VMName        = "CONJUR-L01",
    [string]$ContainerName = "conjur",
    [string]$GuestUser     = "root",
    [string]$GuestPass     = "Cyberark1"
)

$ErrorActionPreference = 'Stop'
$Config   = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force
Initialize-VMwareHelper -Config $Config.VMware

$vmFolder = $Config.VMware.DefaultVMFolder
$candidates = @((Join-Path $vmFolder "$VMName\$VMName.vmx"), (Join-Path $vmFolder "$VMName.vmx"))
$vmx = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmx) { throw "VM not found: $VMName. Tried:`n  $($candidates -join "`n  ")" }

$domain  = $Config.Domain.Name
$dcIP    = $Config.Network.DNS
$dcCred  = New-Object PSCredential("$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)",
           (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force))
$certCfg = $CAConfig.PTA.Certificate   # shared org info, not PTA-specific in meaning

$certDir = "/opt/cyberark/conjur/certificates"

# Two pools per the Installation deck's certificate spec (page 9)
$pools = @(
    @{ Name = "leader";   Cn = "conjur-cluster.$domain";  Set = $true
       Sans = @("conjur-cluster.$domain","conjur-l01.$domain","conjur-s01.$domain","conjur-s02.$domain") }
    @{ Name = "follower"; Cn = "conjur-follower.$domain"; Set = $false
       Sans = @("conjur-follower.$domain","conjur-f01.$domain","conjur-f02.$domain") }
)

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
    param([string]$ScriptText, [string]$Marker, [string]$Label, [int]$TimeoutSec = 120)
    $r = Invoke-LinuxGuestScript -VMXPath $vmx -ScriptText $ScriptText `
         -GuestUser $GuestUser -GuestPassword $GuestPass -NoThrow -TimeoutSeconds $TimeoutSec
    $chk = Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","test -f $Marker") -NoThrow
    if ($r.ExitCode -ne 0 -or $chk.ExitCode -ne 0) {
        throw "$Label failed: $($r.StdErr) $($r.StdOut)"
    }
}

Write-Host "Target: $vmx" -ForegroundColor Cyan
Wait-GuestOps -Vmx $vmx
Write-Host "  guest-ops ready" -ForegroundColor Green

# ================================================================
# Step 1: Prep DC01 CA (idempotent - shared with 14-ConfigurePTACertificates.ps1)
# ================================================================
Write-Host "`n[Step 1] Preparing DC01 CA..." -ForegroundColor Yellow
$caName = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
    $caChanged = $false
    $currentFlags = (certutil -getreg policy\EditFlags 2>$null) -join ''
    if ($currentFlags -notmatch 'EDITF_ATTRIBUTESUBJECTALTNAME2') {
        certutil -setreg policy\EditFlags +EDITF_ATTRIBUTESUBJECTALTNAME2 | Out-Null
        $caChanged = $true
        Write-Output "CA: SAN support enabled"
    } else {
        Write-Output "CA: SAN support already enabled"
    }
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $clientAuth = "1.3.6.1.5.5.7.3.2"; $serverAuth = "1.3.6.1.5.5.7.3.1"
        $configNC = (Get-ADRootDSE).configurationNamingContext
        $tdn = "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
        $tpl = Get-ADObject -Identity $tdn -Properties pKIExtendedKeyUsage,msPKI-Certificate-Application-Policy
        if ($tpl.pKIExtendedKeyUsage -notcontains $clientAuth) {
            Set-ADObject -Identity $tdn -Add @{ 'pKIExtendedKeyUsage' = $clientAuth }
            $ap = @($tpl.'msPKI-Certificate-Application-Policy')
            if ($ap -and $ap -notcontains $clientAuth) {
                Set-ADObject -Identity $tdn -Add @{ 'msPKI-Certificate-Application-Policy' = $clientAuth }
            } elseif (-not $ap) {
                Set-ADObject -Identity $tdn -Replace @{ 'msPKI-Certificate-Application-Policy' = @($serverAuth,$clientAuth) }
            }
            $caChanged = $true
            Write-Output "CA: WebServer template - Client Authentication EKU added"
        } else {
            Write-Output "CA: WebServer template already has Client Authentication EKU"
        }
    } catch {
        Write-Warning "Could not add clientAuth EKU to WebServer template: $($_.Exception.Message)"
    }
    if ($caChanged) {
        Restart-Service certsvc -Force
        for ($i=0; $i -lt 20; $i++) { Start-Sleep 3; if ((certutil -ping 2>&1 | Out-String) -match 'interface is alive') { break } }
        Write-Output "CA: certsvc restarted"
    }
    certutil -CRL 2>&1 | Out-Null
    Write-Output "CA: CRL republished"
    $ca = (certutil -ping 2>$null | Select-String 'ICertRequest2') -replace '.*"(.*)".*','$1'
    if (-not $ca) { $ca = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').Active }
    Write-Output "CANAME:$ca"
}
$caName | Where-Object { $_ -notmatch '^CANAME:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$caNameStr = ($caName | Where-Object { $_ -match '^CANAME:' }) -replace '^CANAME:',''
if (-not $caNameStr) { $caNameStr = "$($Config.Domain.NetBIOSName)-DC01-CA"; Write-Warning "Could not detect CA name, using default: $caNameStr" }
Write-Host "  CA name: $caNameStr" -ForegroundColor DarkGray

# Export the root CA cert as PEM: read the self-signed CA cert (CN = CA name)
# from DC01's machine certificate store and base64-encode it in PowerShell,
# so no temp files are needed.
$rootCertLocal = Join-Path $env:TEMP "conjur_root_ca.crt"
$certBytes = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ArgumentList $caNameStr -ScriptBlock {
    param($caName)
    $ca = Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root |
          Where-Object { $_.Subject -match "^CN=$([regex]::Escape($caName))(,|$)" -and $_.Subject -eq $_.Issuer } |
          Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $ca) { throw "Root CA certificate 'CN=$caName' not found in LocalMachine\My or \Root on DC01" }
    $b64 = [Convert]::ToBase64String($ca.RawData)
    $lines = for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) }
    $pem = "-----BEGIN CERTIFICATE-----`n" + ($lines -join "`n") + "`n-----END CERTIFICATE-----`n"
    [System.Text.Encoding]::ASCII.GetBytes($pem)
}
[System.IO.File]::WriteAllBytes($rootCertLocal, $certBytes)
Write-Host "  [OK] Root CA cert saved ($($certBytes.Length) bytes)" -ForegroundColor Green

# ================================================================
# Step 2: Per pool - CSR (on Leader, openssl) -> DC01 CA -> signed cert
# ================================================================
$issuedCerts = @{}   # pool name -> local host path of signed .cer
$issuedKeys  = @{}   # pool name -> local host path of .key

foreach ($pool in $pools) {
    $poolName = $pool.Name
    $cn       = $pool.Cn
    $sans     = $pool.Sans
    Write-Host "`n[Pool: $poolName] CN=$cn" -ForegroundColor Cyan

    # ---- 2a: generate CSR + key on the Leader via openssl ----
    $sanConfLines = ($sans | ForEach-Object { $i = $sans.IndexOf($_) + 1; "DNS.$i = $_" }) -join "`n"
    $marker = "/tmp/conjur_csr_${poolName}_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $csrScript = @"
#!/bin/bash
set -e
mkdir -p $certDir
cat > /tmp/${poolName}-openssl.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $cn
O = $($certCfg.Organization)
OU = $($certCfg.Department)
L = $($certCfg.City)
ST = $($certCfg.State)
C = $($certCfg.Country)

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
$sanConfLines
EOF
openssl req -new -newkey rsa:2048 -nodes \
  -keyout $certDir/conjur-${poolName}.key \
  -out $certDir/conjur-${poolName}.csr \
  -config /tmp/${poolName}-openssl.cnf
touch $marker
"@
    Invoke-GuestScriptChecked -ScriptText $csrScript -Marker $marker -Label "Generate $poolName CSR" -TimeoutSec 60
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
    Write-Host "  CSR generated" -ForegroundColor Green

    # ---- 2b: pull CSR to host ----
    $localCsr = Join-Path $env:TEMP "conjur-$poolName.csr"
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "copyFileFromGuestToHost",$vmx,"$certDir/conjur-${poolName}.csr",$localCsr) | Out-Null

    # ---- 2c: submit to DC01 CA ----
    $sanAttribute  = ($sans | ForEach-Object { "dns=$_" }) -join '&'
    $remoteCsrPath  = "C:\Windows\Temp\conjur-$poolName.csr"
    $remoteCertPath = "C:\Windows\Temp\conjur-$poolName.crt"
    $csrBytes = [System.IO.File]::ReadAllBytes($localCsr)
    Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        param($bytes, $path) [System.IO.File]::WriteAllBytes($path, $bytes)
    } -ArgumentList $csrBytes, $remoteCsrPath

    Write-Host "  Submitting to DC01 CA ($caNameStr)..." -ForegroundColor DarkGray
    $submitJob = Invoke-Command -ComputerName $dcIP -Credential $dcCred -AsJob -ScriptBlock {
        param($csrPath, $certPath, $san, $caName)
        $cfgLine  = (certutil -getconfig 2>&1 | Select-String 'Config String:') | Select-Object -First 1
        $caConfig = if ($cfgLine) { ($cfgLine.ToString() -replace '.*"(.*)".*','$1') } else { ".\$caName" }
        if (-not $caConfig) { $caConfig = ".\$caName" }
        $rspPath = [System.IO.Path]::ChangeExtension($certPath, '.rsp')
        function Submit-Csr {
            Remove-Item $certPath, $rspPath -Force -ErrorAction SilentlyContinue
            certreq -q -submit -config $caConfig `
                -attrib "CertificateTemplate:WebServer`nSAN:$san" `
                $csrPath $certPath 2>&1
        }
        $certreqOutput = Submit-Csr
        $out = ($certreqOutput | Out-String)
        if (($LASTEXITCODE -ne 0 -or -not (Test-Path $certPath)) -and $out -match 'REVOCATION_OFFLINE|revocation server was offline|0x80092013') {
            Write-Output "CRL_STALE_REPUBLISH"
            certutil -CRL 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $certreqOutput = Submit-Csr
        }
        if ($LASTEXITCODE -eq 0 -and (Test-Path $certPath)) { Write-Output "SUBMIT_OK"; Write-Output $certreqOutput }
        else { Write-Output "SUBMIT_FAIL"; Write-Output $certreqOutput }
    } -ArgumentList $remoteCsrPath, $remoteCertPath, $sanAttribute, $caNameStr

    if (Wait-Job $submitJob -Timeout 120) { $submitResult = Receive-Job $submitJob }
    else {
        Stop-Job $submitJob -ErrorAction SilentlyContinue; Remove-Job $submitJob -Force -ErrorAction SilentlyContinue
        throw "certreq submit timed out (120s) on DC01 for $poolName - clear C:\Windows\Temp\conjur-$poolName.* on DC01 and retry."
    }
    Remove-Job $submitJob -Force -ErrorAction SilentlyContinue
    $submitResult | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($submitResult -notcontains 'SUBMIT_OK') { throw "certreq submission failed on DC01 for $poolName." }
    Write-Host "  [OK] Certificate issued" -ForegroundColor Green

    # ---- 2d: download signed cert, stash paths ----
    $localCert = Join-Path $env:TEMP "conjur-$poolName.cer"
    $certBytes2 = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        param($path) [System.IO.File]::ReadAllBytes($path)
    } -ArgumentList $remoteCertPath
    [System.IO.File]::WriteAllBytes($localCert, $certBytes2)
    $issuedCerts[$poolName] = $localCert
    $issuedKeys[$poolName]  = $null   # key never leaves the Leader - stays at $certDir/conjur-$poolName.key
}

# ================================================================
# Step 3: Push root CA cert + signed certs back to the Leader,
# import into the container, restart services
# ================================================================
Write-Host "`n[Step 3] Importing certificates into $ContainerName..." -ForegroundColor Yellow

foreach ($poolName in $issuedCerts.Keys) {
    Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
        "CopyFileFromHostToGuest",$vmx,$issuedCerts[$poolName],"$certDir/conjur-$poolName.cer") | Out-Null
}
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "CopyFileFromHostToGuest",$vmx,$rootCertLocal,"$certDir/cacert.cer") | Out-Null
Write-Host "  certs staged on $VMName at $certDir" -ForegroundColor Green

$marker = "/tmp/conjur_cert_import_ok_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$importScript = @"
#!/bin/bash
set -e
containerName="$ContainerName"
certDir="$certDir"

podman exec `$containerName mkdir -p `$certDir
podman cp `$certDir/cacert.cer `$containerName:`$certDir/cacert.cer
podman cp `$certDir/conjur-leader.cer `$containerName:`$certDir/conjur-leader.cer
podman cp `$certDir/conjur-leader.key `$containerName:`$certDir/conjur-leader.key
podman cp `$certDir/conjur-follower.cer `$containerName:`$certDir/conjur-follower.cer
podman cp `$certDir/conjur-follower.key `$containerName:`$certDir/conjur-follower.key

podman exec `$containerName evoke ca import --no-restart --force --root `$certDir/cacert.cer
podman exec `$containerName evoke ca import --no-restart --key `$certDir/conjur-leader.key --set `$certDir/conjur-leader.cer
podman exec `$containerName evoke ca import --no-restart --key `$certDir/conjur-follower.key `$certDir/conjur-follower.cer

podman exec `$containerName sv restart conjur nginx pg seed
touch $marker
"@
Invoke-GuestScriptChecked -ScriptText $importScript -Marker $marker -Label "Import certificates" -TimeoutSec 120
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f $marker") -NoThrow | Out-Null
Write-Host "  [OK] Certificates imported, services restarted" -ForegroundColor Green

# ================================================================
# Verify
# ================================================================
Start-Sleep 5
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","curl -sk https://localhost/health > /tmp/conjur_health_out.txt 2>&1") -NoThrow | Out-Null
$healthFile = [System.IO.Path]::Combine($env:TEMP, "conjur_health_out.txt")
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "copyFileFromGuestToHost",$vmx,"/tmp/conjur_health_out.txt",$healthFile) | Out-Null
Write-Host "`nHealth check:" -ForegroundColor Cyan
Get-Content $healthFile | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Remove-Item $healthFile -Force -ErrorAction SilentlyContinue
Invoke-VMRun -Arguments @("-gu",$GuestUser,"-gp",$GuestPass,
    "runProgramInGuest",$vmx,"/bin/bash","-c","rm -f /tmp/conjur_health_out.txt") -NoThrow | Out-Null

Write-Host "`nDone. conjur-leader cert (CN=conjur-cluster.$domain) is now the active serving cert." -ForegroundColor Cyan
Write-Host "conjur-follower cert imported and ready for follower nodes." -ForegroundColor Cyan
