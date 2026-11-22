# PVWAHelper.psm1 - shared PVWA REST helpers for lab platform/account handling.
# Callers pass their own PVWA base URL, auth headers and Invoke-WebRequest
# splat (@{UseBasicParsing; SkipCertificateCheck} on PS7, set up for PS 5.1 by the caller).

function Initialize-LabServiceAccountPlatform {
    <#
    .SYNOPSIS
        Ensure the lab's shared Windows-domain service-account platform exists and is active.
    .DESCRIPTION
        One platform for all lab Windows domain service accounts (LDAP bind, reconcile,
        discovery), duplicated from WinDomain - the default platforms are never used directly.

        WinDomain is a CyberArk Marketplace package and is NOT shipped with this repo
        (community-account download). If it is missing from the Vault:
          - -SourceZipPath given -> imported from that zip first
          - otherwise            -> duplicated from the built-in WindowsDomainLDAP instead (WARN)
        Returns the PlatformID.
    #>
    param(
        [Parameter(Mandatory)][string]$PvwaBase,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Iwr,
        [string]$PlatformId       = "Win-Dom-SvcAcc",
        [string]$SourcePlatformId = "WinDomain",
        [string]$SourceZipPath,
        [string]$FallbackSourceId = "WindowsDomainLDAP"
    )
    function Get-Targets { ((Invoke-WebRequest @Iwr -Uri "$PvwaBase/api/Platforms/targets" -Headers $Headers).Content | ConvertFrom-Json).Platforms }
    function Enable-Target($p) {
        if (-not $p.Active) {
            Invoke-WebRequest @Iwr -Uri "$PvwaBase/api/Platforms/targets/$($p.ID)/activate" -Method POST -Headers $Headers | Out-Null
            Write-Host "  [OK] Platform $($p.PlatformID) activated" -ForegroundColor Green
        }
    }

    $targets = Get-Targets
    $existing = $targets | Where-Object { $_.PlatformID -eq $PlatformId } | Select-Object -First 1
    if ($existing) {
        Write-Host "  [OK] Platform $PlatformId exists" -ForegroundColor Green
        Enable-Target $existing
        return $PlatformId
    }

    $source = $targets | Where-Object { $_.PlatformID -eq $SourcePlatformId } | Select-Object -First 1
    if (-not $source -and $SourceZipPath) {
        if (-not (Test-Path $SourceZipPath)) { throw "Platform zip not found: $SourceZipPath" }
        $zipB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($SourceZipPath))
        Invoke-WebRequest @Iwr -Uri "$PvwaBase/api/Platforms/Import" -Method POST -Headers $Headers `
            -Body (@{ ImportFile = $zipB64 } | ConvertTo-Json) -ContentType "application/json" | Out-Null
        Write-Host "  [OK] Platform $SourcePlatformId imported from $SourceZipPath" -ForegroundColor Green
        $source = Get-Targets | Where-Object { $_.PlatformID -eq $SourcePlatformId } | Select-Object -First 1
        if (-not $source) { throw "Imported $SourceZipPath but platform '$SourcePlatformId' still not found - wrong package?" }
    }
    if (-not $source) {
        $source = $targets | Where-Object { $_.PlatformID -eq $FallbackSourceId } | Select-Object -First 1
        if (-not $source) { throw "Neither '$SourcePlatformId' nor '$FallbackSourceId' exists in the Vault - cannot create $PlatformId" }
        Write-Warning "Platform '$SourcePlatformId' (CyberArk Marketplace) is not in the Vault - duplicating $PlatformId from built-in '$FallbackSourceId' instead. Pass the WinDomain zip to use it as the base."
    }

    $dup = (Invoke-WebRequest @Iwr -Uri "$PvwaBase/api/Platforms/targets/$($source.ID)/duplicate" -Method POST -Headers $Headers `
        -Body (@{ Name = $PlatformId; Description = "Lab Windows domain service accounts (copy of $($source.PlatformID))" } | ConvertTo-Json) `
        -ContentType "application/json").Content | ConvertFrom-Json
    Write-Host "  [OK] Platform $PlatformId created (duplicate of $($source.PlatformID), id=$($dup.ID))" -ForegroundColor Green
    Enable-Target (Get-Targets | Where-Object { $_.ID -eq $dup.ID } | Select-Object -First 1)
    return $PlatformId
}

function Set-LabAccountPlatform {
    <#
    .SYNOPSIS
        Move an existing PVWA account onto -PlatformId if it is on another platform.
    #>
    param(
        [Parameter(Mandatory)][string]$PvwaBase,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Iwr,
        [Parameter(Mandatory)][object]$Account,      # an item from GET /api/Accounts
        [Parameter(Mandatory)][string]$PlatformId
    )
    if ($Account.platformId -eq $PlatformId) { return }
    $patch = ConvertTo-Json -InputObject @(@{ op = "replace"; path = "/platformId"; value = $PlatformId })
    Invoke-WebRequest @Iwr -Uri "$PvwaBase/api/Accounts/$($Account.id)" -Method PATCH -Headers $Headers `
        -Body $patch -ContentType "application/json" | Out-Null
    Write-Host "  [OK] $($Account.name) moved $($Account.platformId) -> $PlatformId" -ForegroundColor Green
}

Export-ModuleMember -Function Initialize-LabServiceAccountPlatform, Set-LabAccountPlatform
