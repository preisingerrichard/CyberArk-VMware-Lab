<#
.SYNOPSIS
    Configure SSL certificates on PTA Primary and/or Secondary servers.
.DESCRIPTION
    Full certificate automation:
      0  Store Vault admin credential in PVWA safe (PTA-Automation)
      1  Configure DC01 CA for SAN support (EDITF_ATTRIBUTESUBJECTALTNAME2)
      2  Per PTA server:
           2a  Fix system hostname (PTA02 workaround for kickstart bug)
           2b  Generate CSR via stdin pipe to certificateSigningRequestGenerationUtil.sh
           2c  SCP CSR from PTA to host, copy to DC01
           2d  Submit CSR to DC01 CA via certreq, download signed cert
           2e  Export root CA cert from DC01
           2f  SCP cert + root CA back to PTA
           2g  Retrieve Vault admin password from PVWA safe
           2h  Install cert via stdin pipe to sslCertificateInstallationUtil.sh

    Usage:
      # Primary only:
      .\Configure-PTACertificates.ps1 -PrimaryName PTA01

      # Primary + Secondary (DR):
      .\Configure-PTACertificates.ps1 -PrimaryName PTA01 -SecondaryName PTA02

    Prerequisites:
    - PTA servers must be installed (11-InstallPTA-Primary.ps1 / 11-InstallPTA-Secondary.ps1)
    - PVWA must be running and accessible
    - DC01 must have Active Directory Certificate Services role installed
#>

param(
    [string]$ConfigPath    = "$PSScriptRoot\..\Config\LabConfig.psd1",
    [string]$PrimaryName   = "PTA01",
    [string]$SecondaryName = ""     # Leave empty for single PTA deployment
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh.exe  -ErrorAction SilentlyContinue)) { throw "ssh.exe not found." }
if (-not (Get-Command scp.exe  -ErrorAction SilentlyContinue)) { throw "scp.exe not found." }

Import-Module "$PSScriptRoot\..\Helpers\VMwareHelper.psm1" -Force

$Config   = Import-PowerShellDataFile $ConfigPath
$CAConfig = Import-PowerShellDataFile "$PSScriptRoot\..\Config\CyberArkConfig.psd1"
Initialize-VMwareHelper -Config $Config.VMware

# Build ordered list of PTA servers to process
$allPTAVMs   = @($Config.VMs | Where-Object { $_.Role -eq 'PTA' -or $_.Role -contains 'PTA' })
$ptaServers  = @()
$primaryVM   = $allPTAVMs | Where-Object { $_.Name -eq $PrimaryName } | Select-Object -First 1
if (-not $primaryVM) { throw "Primary VM '$PrimaryName' not found in LabConfig.psd1" }
$ptaServers += $primaryVM

if ($SecondaryName) {
    $secondaryVM = $allPTAVMs | Where-Object { $_.Name -eq $SecondaryName } | Select-Object -First 1
    if (-not $secondaryVM) { throw "Secondary VM '$SecondaryName' not found in LabConfig.psd1" }
    $ptaServers += $secondaryVM
}

# Shared config
$domain        = $Config.Domain.Name
$sharedPrefix  = $CAConfig.PTA.SharedDnsPrefix      # "pta"
$sharedFQDN    = "$sharedPrefix.$domain"            # pta.cyberark.lab
$certCfg       = $CAConfig.PTA.Certificate
$safeName      = $certCfg.SafeName
$accountName   = $certCfg.AccountName
$vaultAdminUser = $CAConfig.Vault.AdminUser
$vaultAdminPass = $CAConfig.Vault.AdminPassword
$pvwaVM        = $Config.VMs | Where-Object { $_.Role -contains 'PVWA' -or $_.Role -eq 'PVWA' } | Select-Object -First 1
$pvwaBase      = "https://$($pvwaVM.IPAddress)/PasswordVault"
$dcIP          = $Config.Network.DNS
$dcCred        = New-Object PSCredential(
    "$($Config.Domain.NetBIOSName)\$($Config.Domain.DomainAdminUser)",
    (ConvertTo-SecureString $Config.Domain.DomainAdminPass -AsPlainText -Force)
)
$labKeyPath    = Join-Path $PSScriptRoot "..\Config\pta_lab_key"
$labKeyPath    = (Resolve-Path -LiteralPath (Split-Path $labKeyPath)).Path + "\pta_lab_key"

if (-not (Test-Path $labKeyPath)) { throw "Lab SSH key not found at $labKeyPath - run 10-CreatePTAVM.ps1 first" }

# TLS bypass for PVWA self-signed cert - -SkipCertificateCheck added to every Invoke-WebRequest call

$sshOpts = @(
    "-i", $labKeyPath,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10"
)

function Invoke-PTASSH {
    param([string]$IP, [string]$Command, [int]$TimeoutSec = 120, [switch]$NoThrow)

    # Run ssh as a child process so the timeout can actually be enforced
    # (a plain "& ssh.exe" blocks forever if the remote command hangs on a prompt).
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $sshArgs = @($sshOpts) + @("root@$IP", $Command)
    $proc = Start-Process -FilePath "ssh.exe" -ArgumentList $sshArgs `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
    }

    $stdout = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
    $stderr = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $exit = if ($timedOut) { 124 } else { $proc.ExitCode }

    if ($timedOut) {
        $msg = "SSH command timed out after ${TimeoutSec}s on $IP"
        if ($NoThrow) { $stderr += $msg } else { throw $msg }
    } elseif (-not $NoThrow -and $exit -ne 0) {
        throw "SSH command failed (exit $exit): $(($stderr + $stdout) -join '; ')"
    }
    return [PSCustomObject]@{ Output = $stdout; ExitStatus = $exit; Error = $stderr }
}

function Copy-ToPTA {
    param([string]$IP, [string]$LocalPath, [string]$RemoteDir)
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & scp.exe -i $labKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        $LocalPath "root@${IP}:${RemoteDir}/"
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($exit -ne 0) { throw "scp failed for $(Split-Path $LocalPath -Leaf) (exit $exit)" }
}

function Copy-FromPTA {
    param([string]$IP, [string]$RemotePath, [string]$LocalDir)
    $savedEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & scp.exe -i $labKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        "root@${IP}:${RemotePath}" $LocalDir
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($exit -ne 0) { throw "scp download failed for $RemotePath (exit $exit)" }
}

# ================================================================
# Step 0: Store Vault admin credential in PVWA safe
# ================================================================
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "PTA Certificate Configuration" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

Write-Host "`n[Step 0] Storing Vault admin credential in PVWA safe '$safeName'..." -ForegroundColor Yellow

$pvwaToken = $null
try {
    $logonBody = @{ username = $vaultAdminUser; password = $vaultAdminPass; concurrentSession = $true } | ConvertTo-Json
    $logonResp = Invoke-WebRequest -Uri "$pvwaBase/api/auth/Cyberark/Logon" `
        -Method POST -Body $logonBody -ContentType "application/json" -UseBasicParsing -SkipCertificateCheck
    $pvwaToken = $logonResp.Content.Trim('"')
    $pvwaHdrs  = @{ Authorization = $pvwaToken }
    Write-Host "  Authenticated to PVWA" -ForegroundColor DarkGray

    # Create safe if missing
    $safeExists = $false
    try {
        $null = Invoke-WebRequest -Uri "$pvwaBase/api/Safes/$safeName" `
            -Method GET -Headers $pvwaHdrs -UseBasicParsing -SkipCertificateCheck
        $safeExists = $true
        Write-Host "  Safe '$safeName' already exists" -ForegroundColor DarkGray
    } catch {}

    if (-not $safeExists) {
        $safeBody = @{
            safeName              = $safeName
            description           = "PTA automation credentials - Vault admin for certificate operations"
            numberOfDaysRetention = 0
        } | ConvertTo-Json
        $null = Invoke-WebRequest -Uri "$pvwaBase/api/Safes" -Method POST `
            -Body $safeBody -ContentType "application/json" -Headers $pvwaHdrs -UseBasicParsing -SkipCertificateCheck
        Write-Host "  Created safe '$safeName'" -ForegroundColor DarkGray
    }

    # Create account if missing - PASWS027E means already exists, treat as success
    $acctBody = @{
        name                      = $accountName
        address                   = $CAConfig.Vault.VaultAddress
        userName                  = $vaultAdminUser
        platformId                = "WinDomain"
        safeName                  = $safeName
        secretType                = "password"
        secret                    = $vaultAdminPass
        platformAccountProperties = @{}
    } | ConvertTo-Json
    try {
        $acctResp = Invoke-WebRequest -Uri "$pvwaBase/api/Accounts" -Method POST `
            -Body $acctBody -ContentType "application/json" -Headers $pvwaHdrs -UseBasicParsing -SkipCertificateCheck
        $acctId = ($acctResp.Content | ConvertFrom-Json).id
        Write-Host "  [OK] Account '$accountName' created (id: $acctId)" -ForegroundColor Green
    } catch {
        $body = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "" }
        if ($body -match 'PASWS027E') {
            Write-Host "  [OK] Account '$accountName' already exists in safe" -ForegroundColor Green
        } else {
            throw
        }
    }
} catch {
    $pvwaErr = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Warning "Step 0 error: $pvwaErr"
    Write-Warning "Continuing - will fall back to config password for cert installation"
} finally {
    if ($pvwaToken) {
        $null = Invoke-WebRequest -Uri "$pvwaBase/api/auth/Logoff" -Method POST `
            -Headers @{ Authorization = $pvwaToken } -UseBasicParsing -SkipCertificateCheck -ErrorAction SilentlyContinue
        $pvwaToken = $null
    }
}

# ================================================================
# Step 1: Configure DC01 CA
# ================================================================
Write-Host "`n[Step 1] Configuring DC01 CA for SAN support..." -ForegroundColor Yellow

$caName = $null
try {
    $caName = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        $caChanged = $false

        # Enable SAN from request attributes (allows certreq to pass SAN regardless of template)
        $currentFlags = (certutil -getreg policy\EditFlags 2>$null) -join ''
        if ($currentFlags -notmatch 'EDITF_ATTRIBUTESUBJECTALTNAME2') {
            certutil -setreg policy\EditFlags +EDITF_ATTRIBUTESUBJECTALTNAME2 | Out-Null
            $caChanged = $true
            Write-Output "CA: SAN support enabled"
        } else {
            Write-Output "CA: SAN support already enabled"
        }

        # Add Client Authentication EKU to the WebServer template. PTA's MongoDB DR
        # replication uses this cert as a CLIENT cert for X.509 cluster member auth;
        # an Enterprise CA stamps the TEMPLATE's EKU onto the cert (ignoring the CSR),
        # so a server-auth-only template breaks replication ("stream truncated" /
        # "no host maps to this node"). clientAuth = 1.3.6.1.5.5.7.3.2.
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
            Write-Warning "DR replication needs it - add Client Authentication to the template manually."
        }

        if ($caChanged) {
            Restart-Service certsvc -Force
            for ($i=0; $i -lt 20; $i++) { Start-Sleep 3; if ((certutil -ping 2>&1 | Out-String) -match 'interface is alive') { break } }
            Write-Output "CA: certsvc restarted"
        }

        # Republish the CRL so it is not expired. The lab CA denies issuance with
        # CRYPT_E_REVOCATION_OFFLINE when its CRL has lapsed (test dates jump around).
        certutil -CRL 2>&1 | Out-Null
        Write-Output "CA: CRL republished"

        # Get CA name for certreq -config
        $ca = (certutil -ping 2>$null | Select-String 'ICertRequest2') -replace '.*"(.*)".*','$1'
        if (-not $ca) {
            $ca = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').Active
        }
        Write-Output "CANAME:$ca"
    }

    $caName | Where-Object { $_ -notmatch '^CANAME:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    $caNameStr = ($caName | Where-Object { $_ -match '^CANAME:' }) -replace '^CANAME:',''
    if (-not $caNameStr) {
        $caNameStr = "$($Config.Domain.NetBIOSName)-DC01-CA"
        Write-Warning "Could not detect CA name, using default: $caNameStr"
    }
    Write-Host "  CA name: $caNameStr" -ForegroundColor DarkGray

    # Export root CA cert from DC01 and read bytes in the SAME remote session
    # (certutil -ca.cert output + ReadAllBytes must share one session/working dir)
    $rootCertLocal = Join-Path $env:TEMP "dc01_root_ca.crt"
    $certBytes = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        $der = "C:\Windows\Temp\root_ca.der"
        $dst = "C:\Windows\Temp\root_ca.crt"
        Remove-Item $der, $dst -Force -ErrorAction SilentlyContinue
        # certutil -ca.cert emits DER; PTA validates with openssl which needs PEM.
        # Export DER then -encode to base64 PEM. Run via cmd so certutil gets the
        # literal "-ca.cert <file>" line (PS native-arg passing splits "-ca.cert").
        $out = & cmd.exe /c "certutil -ca.cert `"$der`" && certutil -encode `"$der`" `"$dst`"" 2>&1 | Out-String
        if (-not (Test-Path $dst)) {
            throw "certutil root CA export/encode did not produce ${dst}: $out"
        }
        [System.IO.File]::ReadAllBytes($dst)
    }
    [System.IO.File]::WriteAllBytes($rootCertLocal, $certBytes)

    if ((Test-Path $rootCertLocal) -and ((Get-Item $rootCertLocal).Length -gt 0)) {
        Write-Host "  [OK] Root CA cert saved to $rootCertLocal ($($certBytes.Length) bytes)" -ForegroundColor Green
    } else {
        throw "Failed to download root CA cert from DC01"
    }
} catch {
    throw "Step 1 failed: $($_.Exception.Message)"
}

# ================================================================
# Step 1b: Ensure shared DR DNS A record (pta.cyberark.lab -> Primary IP)
# ----------------------------------------------------------------
# REQUIRED for DR: setupPrimary.sh builds the Mongo replica-set config using
# the shared name; if it does not resolve, rs.initiate fails with
# "No host described in new configuration ... maps to this node".
# Also lives in both certs' SAN. Idempotent - safe to run every time.
# ================================================================
Write-Host "`n[Step 1b] Ensuring shared DR DNS record ($sharedFQDN)..." -ForegroundColor Yellow
try {
    $primaryIP = ($ptaServers | Where-Object { $_.Name -eq $PrimaryName } | Select-Object -First 1).IPAddress
    $dnsMsg = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        param($zone, $recName, $ip)
        try { Import-Module DnsServer -ErrorAction Stop } catch { return "DNS_MODULE_MISSING" }
        $existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $recName -RRType A -ErrorAction SilentlyContinue
        if ($existing) {
            $cur = @($existing.RecordData.IPv4Address.IPAddressToString)
            if ($cur -contains $ip) { return "EXISTS_OK:$recName.$zone -> $ip" }
            # Wrong/extra IPs (e.g. left over from a prior deploy) - reset to primary only
            $existing | ForEach-Object { Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $_ -Force -ErrorAction SilentlyContinue }
            Add-DnsServerResourceRecordA -ZoneName $zone -Name $recName -IPv4Address $ip
            return "RESET:$recName.$zone -> $ip (was $($cur -join ','))"
        }
        Add-DnsServerResourceRecordA -ZoneName $zone -Name $recName -IPv4Address $ip
        return "ADDED:$recName.$zone -> $ip"
    } -ArgumentList $domain, $sharedPrefix, $primaryIP
    if ($dnsMsg -eq "DNS_MODULE_MISSING") {
        Write-Warning "DnsServer module not on $dcIP - create A record '$sharedFQDN -> $primaryIP' manually before running setupPrimary.sh"
    } else {
        Write-Host "  [OK] $dnsMsg" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not ensure shared DNS record: $($_.Exception.Message)"
    Write-Warning "Create A record '$sharedFQDN -> Primary IP' manually before running setupPrimary.sh"
}

# ================================================================
# Step 2: Per PTA server - CSR -> CA -> cert install
# ================================================================
foreach ($ptaVM in $ptaServers) {
    $ptaIP    = $ptaVM.IPAddress
    $ptaShort = $ptaVM.Name.ToLower()       # pta01 or pta02
    $ptaFQDN  = "$ptaShort.$domain"         # pta01.cyberark.lab

    Write-Host "`n$("=" * 70)" -ForegroundColor Cyan
    Write-Host "Processing $($ptaVM.Name) ($ptaIP)" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan

    # ---------------------------------------------------------------
    # Step 2.0: Clock guard - CA-issued certs fail chain validation
    # ("certificate is not yet valid") if the PTA clock is skewed from
    # the CA. Set the PTA clock to this host's UTC and persist it.
    # ---------------------------------------------------------------
    Write-Host "`n  [2.0] Checking clock skew..." -ForegroundColor Yellow
    $ptaEpoch = (Invoke-PTASSH -IP $ptaIP -Command "date -u +%s" -NoThrow).Output -join ''
    $skew = [Math]::Abs([long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) - [long]$ptaEpoch)
    if ($skew -gt 120) {
        $utcNow = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "       Skew ${skew}s - setting clock to $utcNow UTC" -ForegroundColor Yellow
        Invoke-PTASSH -IP $ptaIP -NoThrow `
            -Command "timedatectl set-ntp false; date -u -s '$utcNow'; hwclock --systohc --utc 2>/dev/null; systemctl restart chronyd 2>/dev/null; timedatectl set-ntp true 2>/dev/null" | Out-Null
        Write-Host "       [OK] Clock corrected" -ForegroundColor Green
    } else {
        Write-Host "       [OK] Clock in sync (skew ${skew}s)" -ForegroundColor Green
    }

    # SAN format: dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40
    $sanString    = "dns:$ptaFQDN,dns:$sharedFQDN,ip:$ptaIP"
    # certreq attribute format: dns=pta01.cyberark.lab&dns=pta.cyberark.lab&ipaddress=192.168.100.40
    $sanAttribute = "dns=$ptaFQDN&dns=$sharedFQDN&ipaddress=$ptaIP"

    # ---------------------------------------------------------------
    # Step 2a: Fix hostname (PTA02 may have been kickstarted as pta01)
    # ---------------------------------------------------------------
    Write-Host "`n  [2a] Verifying system hostname..." -ForegroundColor Yellow
    $currentHostname = (Invoke-PTASSH -IP $ptaIP -Command "hostname -f" -NoThrow).Output -join ''
    Write-Host "       Current: $currentHostname" -ForegroundColor DarkGray

    if ($currentHostname.Trim() -ne $ptaFQDN) {
        Write-Host "       Fixing hostname: $($currentHostname.Trim()) -> $ptaFQDN" -ForegroundColor Yellow
        Invoke-PTASSH -IP $ptaIP -Command "hostnamectl set-hostname $ptaFQDN" | Out-Null
        # Update /etc/hosts to match
        Invoke-PTASSH -IP $ptaIP -Command "grep -qF '$ptaFQDN' /etc/hosts || echo '$ptaIP  $ptaFQDN $ptaShort' >> /etc/hosts" -NoThrow | Out-Null
        $newHostname = (Invoke-PTASSH -IP $ptaIP -Command "hostname -f" -NoThrow).Output -join ''
        Write-Host "       New hostname: $($newHostname.Trim())" -ForegroundColor DarkGray
        Write-Host "       [OK] Hostname corrected" -ForegroundColor Green
    } else {
        Write-Host "       [OK] Hostname correct" -ForegroundColor Green
    }

    # ---------------------------------------------------------------
    # Step 2b: Generate CSR via stdin pipe
    # ---------------------------------------------------------------
    Write-Host "`n  [2b] Generating CSR on $($ptaVM.Name)..." -ForegroundColor Yellow

    $csrUtilPath = "/opt/pta/utility/certificateSigningRequestGenerationUtil.sh"
    $csrCheckResult = Invoke-PTASSH -IP $ptaIP -Command "test -f $csrUtilPath && echo found || echo missing" -NoThrow
    if ($csrCheckResult.Output -match 'missing') {
        throw "$csrUtilPath not found on $($ptaVM.Name) - ensure PTA is installed"
    }

    # Stdin answers (sequential prompts):
    # 1. PTA Host name       -> pta01 (short, not FQDN)
    # 2. Organization        -> from config
    # 3. Department          -> from config
    # 4. City                -> from config
    # 5. State               -> from config
    # 6. Country Code        -> from config
    # 7. Shared FQDN (opt)   -> pta.cyberark.lab
    # 8. SAN                 -> dns:pta01.cyberark.lab,dns:pta.cyberark.lab,ip:192.168.100.40
    $csrAnswers = "$ptaShort`n$($certCfg.Organization)`n$($certCfg.Department)`n$($certCfg.City)`n$($certCfg.State)`n$($certCfg.Country)`n$sharedFQDN`n$sanString`n"

    $csrScript = @"
#!/bin/bash
printf '$($csrAnswers -replace "'","'\''")' | bash $csrUtilPath 2>&1
echo csr_exit:\$?
"@
    $tmpCsrScript = Join-Path $env:TEMP "pta_csr_gen.sh"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpCsrScript, ($csrScript -replace "`r`n", "`n"), $utf8NoBom)

    try {
        Copy-ToPTA -IP $ptaIP -LocalPath $tmpCsrScript -RemoteDir "/tmp"
        Write-Host "       Running CSR generator (up to 2 min)..." -ForegroundColor DarkGray
        $csrResult = Invoke-PTASSH -IP $ptaIP -Command "chmod +x /tmp/pta_csr_gen.sh && bash /tmp/pta_csr_gen.sh" -TimeoutSec 120 -NoThrow
        $csrResult.Output | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }

        if ($csrResult.Output -match 'csr_exit:0') {
            Write-Host "       [OK] CSR generated" -ForegroundColor Green
        } else {
            Write-Warning "CSR generator returned non-zero exit - check output above"
        }
    } finally {
        Remove-Item $tmpCsrScript -ErrorAction SilentlyContinue
    }

    # Verify CSR was created
    $csrCheck = Invoke-PTASSH -IP $ptaIP -Command "test -f /opt/pta/ca/pta_server.csr && echo found || echo missing" -NoThrow
    if ($csrCheck.Output -match 'missing') {
        throw "CSR not found at /opt/pta/ca/pta_server.csr after generation"
    }

    # ---------------------------------------------------------------
    # Step 2c: SCP CSR from PTA to host, then copy to DC01
    # ---------------------------------------------------------------
    Write-Host "`n  [2c] Downloading CSR from $($ptaVM.Name)..." -ForegroundColor Yellow

    $localCsrPath = Join-Path $env:TEMP "$ptaShort.csr"
    Copy-FromPTA -IP $ptaIP -RemotePath "/opt/pta/ca/pta_server.csr" -LocalDir $localCsrPath
    Write-Host "       CSR saved to $localCsrPath" -ForegroundColor DarkGray

    # Upload CSR to DC01
    $remoteCsrPath  = "C:\Windows\Temp\$ptaShort.csr"
    $remoteCertPath = "C:\Windows\Temp\$ptaShort.crt"
    $csrBytes = [System.IO.File]::ReadAllBytes($localCsrPath)
    Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        param($bytes, $path) [System.IO.File]::WriteAllBytes($path, $bytes)
    } -ArgumentList $csrBytes, $remoteCsrPath
    Write-Host "       [OK] CSR uploaded to DC01:$remoteCsrPath" -ForegroundColor Green

    # ---------------------------------------------------------------
    # Step 2d: Submit CSR to DC01 CA
    # ---------------------------------------------------------------
    Write-Host "`n  [2d] Submitting CSR to DC01 CA ($caNameStr)..." -ForegroundColor Yellow

    # Run as a job with a timeout: certreq blocks forever on any interactive
    # prompt under WinRM. Two guards: -q suppresses ALL dialogs (a "revocation
    # offline" popup was the real cause of the earlier hang), and we republish
    # the CRL + retry once if the CA denies with CRYPT_E_REVOCATION_OFFLINE
    # (the lab CA's CRL expires as test dates jump around).
    $submitJob = Invoke-Command -ComputerName $dcIP -Credential $dcCred -AsJob -ScriptBlock {
        param($csrPath, $certPath, $san, $caName)

        # Use the CA's canonical config string (avoids the GUI CA-selection dialog).
        $cfgLine  = (certutil -getconfig 2>&1 | Select-String 'Config String:') | Select-Object -First 1
        $caConfig = if ($cfgLine) { ($cfgLine.ToString() -replace '.*"(.*)".*','$1') } else { ".\$caName" }
        if (-not $caConfig) { $caConfig = ".\$caName" }
        Write-Output "USING_CONFIG:$caConfig"

        $rspPath = [System.IO.Path]::ChangeExtension($certPath, '.rsp')

        function Submit-Csr {
            Remove-Item $certPath, $rspPath -Force -ErrorAction SilentlyContinue
            # -q = quiet: never show a dialog (prevents the WinRM hang)
            certreq -q -submit -config $caConfig `
                -attrib "CertificateTemplate:WebServer`nSAN:$san" `
                $csrPath $certPath 2>&1
        }

        $certreqOutput = Submit-Csr
        $out = ($certreqOutput | Out-String)
        # If the CA denied because its CRL is stale/offline, republish and retry once.
        if (($LASTEXITCODE -ne 0 -or -not (Test-Path $certPath)) -and $out -match 'REVOCATION_OFFLINE|revocation server was offline|0x80092013') {
            Write-Output "CRL_STALE_REPUBLISH"
            certutil -CRL 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $certreqOutput = Submit-Csr
        }

        if ($LASTEXITCODE -eq 0 -and (Test-Path $certPath)) {
            Write-Output "SUBMIT_OK"
            Write-Output $certreqOutput
        } else {
            Write-Output "SUBMIT_FAIL"
            Write-Output $certreqOutput
        }
    } -ArgumentList $remoteCsrPath, $remoteCertPath, $sanAttribute, $caNameStr

    if (Wait-Job $submitJob -Timeout 120) {
        $submitResult = Receive-Job $submitJob
    } else {
        Stop-Job $submitJob -ErrorAction SilentlyContinue
        Remove-Job $submitJob -Force -ErrorAction SilentlyContinue
        throw "certreq submit timed out (120s) on DC01 - likely an interactive prompt (stale C:\Windows\Temp\$ptaShort.crt or GUI CA picker). Clear C:\Windows\Temp\$ptaShort.* on DC01 and retry."
    }
    Remove-Job $submitJob -Force -ErrorAction SilentlyContinue

    $submitResult | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }

    if ($submitResult -notcontains 'SUBMIT_OK') {
        throw "certreq submission failed on DC01. Check CA is running and WebServer template is published."
    }
    Write-Host "       [OK] Certificate issued by DC01 CA" -ForegroundColor Green

    # ---------------------------------------------------------------
    # Step 2e+2f: Download cert + root CA from DC01, SCP to PTA
    # ---------------------------------------------------------------
    Write-Host "`n  [2e-2f] Transferring certificates to $($ptaVM.Name)..." -ForegroundColor Yellow

    $localCertPath = Join-Path $env:TEMP "$ptaShort.crt"
    $certBytes = Invoke-Command -ComputerName $dcIP -Credential $dcCred -ScriptBlock {
        param($path) [System.IO.File]::ReadAllBytes($path)
    } -ArgumentList $remoteCertPath
    [System.IO.File]::WriteAllBytes($localCertPath, $certBytes)
    Write-Host "       Cert downloaded to $localCertPath" -ForegroundColor DarkGray

    Copy-ToPTA -IP $ptaIP -LocalPath $localCertPath  -RemoteDir "/tmp"
    Copy-ToPTA -IP $ptaIP -LocalPath $rootCertLocal  -RemoteDir "/tmp"
    Invoke-PTASSH -IP $ptaIP -Command "mv /tmp/$ptaShort.crt /tmp/pta_server.crt && mv /tmp/dc01_root_ca.crt /tmp/root_ca.crt" -NoThrow | Out-Null
    Write-Host "       [OK] pta_server.crt + root_ca.crt on $($ptaVM.Name)" -ForegroundColor Green

    # ---------------------------------------------------------------
    # Step 2g: Get Vault admin password from config
    # ---------------------------------------------------------------
    Write-Host "`n  [2g] Using Vault admin password from config (stored in PVWA safe '$safeName')" -ForegroundColor Yellow
    $installPass = $vaultAdminPass

    # ---------------------------------------------------------------
    # Step 2h: Install cert via stdin pipe to sslCertificateInstallationUtil.sh
    # ---------------------------------------------------------------
    Write-Host "`n  [2h] Installing certificate on $($ptaVM.Name)..." -ForegroundColor Yellow

    $installUtil = "/opt/pta/utility/sslCertificateInstallationUtil.sh"
    $installCheck = Invoke-PTASSH -IP $ptaIP -Command "test -f $installUtil && echo found || echo missing" -NoThrow
    if ($installCheck.Output -match 'missing') {
        throw "$installUtil not found on $($ptaVM.Name)"
    }

    # Stdin answers for sslCertificateInstallationUtil.sh (sequential prompts).
    # NOTE: this util version has NO "fix permissions (Y/N)" prompt - it goes
    # straight from the intermediate question to the Vault credential prompts.
    # 1. PTA Server Certificate full path
    # 2. Root Certificate (y/n)               -> y
    # 3. Root Certificate full path
    # 4. Intermediate certificate(s) (y/n)    -> n (no intermediate in lab CA)
    # 5. Vault Admin username [Administrator]
    # 6. Vault Admin password
    # 7. Retype Vault Admin password
    $installAnswers = "/tmp/pta_server.crt`ny`n/tmp/root_ca.crt`nn`n$vaultAdminUser`n$installPass`n$installPass`n"

    $installScript = @"
#!/bin/bash
printf '$($installAnswers -replace "'","'\''")' | bash $installUtil 2>&1
echo install_exit:\$?
"@
    $tmpInstallScript = Join-Path $env:TEMP "pta_cert_install.sh"
    [System.IO.File]::WriteAllText($tmpInstallScript, ($installScript -replace "`r`n", "`n"), $utf8NoBom)

    try {
        Copy-ToPTA -IP $ptaIP -LocalPath $tmpInstallScript -RemoteDir "/tmp"
        Write-Host "       Running cert installation (up to 5 min)..." -ForegroundColor DarkGray
        $installResult = Invoke-PTASSH -IP $ptaIP -Command "chmod +x /tmp/pta_cert_install.sh && bash /tmp/pta_cert_install.sh" -TimeoutSec 300 -NoThrow
        $installResult.Output | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }

        if ($installResult.Output -match 'install_exit:0') {
            Write-Host "       [OK] Certificate installed" -ForegroundColor Green
        } elseif ($installResult.Output -match 'SSL Certificate Chain installed successfully') {
            Write-Host "       [OK] Certificate chain installed successfully" -ForegroundColor Green
        } else {
            Write-Warning "Certificate installation returned non-zero exit - check output above"
            Write-Warning "Manual fix: ssh root@$ptaIP then: bash $installUtil"
        }
    } finally {
        Remove-Item $tmpInstallScript -ErrorAction SilentlyContinue
    }

    # Cleanup temp files on PTA
    Invoke-PTASSH -IP $ptaIP -Command "rm -f /tmp/pta_server.crt /tmp/root_ca.crt /tmp/pta_csr_gen.sh /tmp/pta_cert_install.sh" -NoThrow | Out-Null

    Write-Host "`n$("=" * 70)" -ForegroundColor Green
    Write-Host "$($ptaVM.Name) certificate configured" -ForegroundColor Green
    Write-Host "  FQDN:  $ptaFQDN" -ForegroundColor Green
    Write-Host "  SAN:   $sanString" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green
}

# ================================================================
# Post-install summary
# ================================================================
Write-Host "`n$("=" * 70)" -ForegroundColor Cyan
Write-Host "CERTIFICATE CONFIGURATION COMPLETE" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($SecondaryName) {
    Write-Host "`n[Next: Enable DR Replication]" -ForegroundColor Yellow
    Write-Host "  ssh root@$($primaryVM.IPAddress)" -ForegroundColor DarkGray
    Write-Host "  bash /opt/pta/utility/dr/setupPrimary.sh" -ForegroundColor DarkGray
    Write-Host "  Provide when prompted:" -ForegroundColor DarkGray
    Write-Host "    Primary SAN name:   $($primaryVM.Name.ToLower())" -ForegroundColor DarkGray
    Write-Host "    Secondary SAN name: $($ptaServers[-1].Name.ToLower())" -ForegroundColor DarkGray
    Write-Host "    Secondary root pwd: $($Config.LocalAdmin.Password)" -ForegroundColor DarkGray
    Write-Host "`n[Verify]" -ForegroundColor Yellow
    Write-Host "  Primary:   cat /opt/pta/mode  (should show: primary)" -ForegroundColor DarkGray
    Write-Host "  Secondary: cat /opt/pta/mode  (should show: secondary)" -ForegroundColor DarkGray
    Write-Host "  Secondary: systemctl status ptadb" -ForegroundColor DarkGray
    Write-Host "  PVWA: Administration > PTA > $PrimaryName should show Connected" -ForegroundColor DarkGray
} else {
    Write-Host "`n[Verify]" -ForegroundColor Yellow
    Write-Host "  PVWA: Administration > PTA > $PrimaryName should show Connected" -ForegroundColor DarkGray
    Write-Host "  Web UI: https://$($primaryVM.IPAddress):8443" -ForegroundColor DarkGray
}

Write-Host "`n  Credentials stored in: PVWA > Safe '$safeName' > Account '$accountName'" -ForegroundColor DarkGray
Write-Host ("=" * 70) -ForegroundColor Cyan
