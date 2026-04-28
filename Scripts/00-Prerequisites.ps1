<#
.SYNOPSIS
    Check all prerequisites for the CyberArk lab deployment.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\Config\LabConfig.psd1"
)

$ErrorActionPreference = 'Stop'

$Config = Import-PowerShellDataFile $ConfigPath
$checks = @()
$warnings = 0

Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "CyberArk Lab - Prerequisites Check" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. VMware Workstation
# ---------------------------------------------------------------------------
Write-Host "[1] VMware Workstation Pro..." -NoNewline

$vmrunPath = $Config.VMware.VMRunPath
if (Test-Path $vmrunPath) {
    $vmrunVersion = & $vmrunPath 2>&1 | Select-String "vmrun version" | Select-Object -First 1
    Write-Host " OK" -ForegroundColor Green
    if ($vmrunVersion) {
        Write-Host "    $vmrunVersion" -ForegroundColor DarkGray
    }
    $checks += @{ Check = "VMware"; Status = "OK" }
} else {
    Write-Host " FAILED" -ForegroundColor Red
    Write-Host "    vmrun.exe not found at: $vmrunPath" -ForegroundColor Red
    $checks += @{ Check = "VMware"; Status = "FAILED" }
}

# ---------------------------------------------------------------------------
# 2. Windows Server ISO
# ---------------------------------------------------------------------------
Write-Host "[2] Windows Server ISO..." -NoNewline

$isoPath = $Config.ISOs.WindowsServer
if (Test-Path $isoPath) {
    $isoSize = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)
    Write-Host " OK ($isoSize GB)" -ForegroundColor Green
    Write-Host "    $isoPath" -ForegroundColor DarkGray
    $checks += @{ Check = "WindowsISO"; Status = "OK" }
} else {
    Write-Host " FAILED" -ForegroundColor Red
    Write-Host "    ISO not found at: $isoPath" -ForegroundColor Red
    $checks += @{ Check = "WindowsISO"; Status = "FAILED" }
}

# ---------------------------------------------------------------------------
# 3. CyberArk Installation Media (folder-based, NOT ISO)
# ---------------------------------------------------------------------------
Write-Host "[3] CyberArk Installation Media (v15.0 folders)..." -NoNewline
$cyberArkPath = $Config.CyberArkMedia.BasePath

if (Test-Path $cyberArkPath) {
    $mediaChecks = @()

    # Check each component installer
    $components = @(
        @{ Name = "Vault";    Path = $Config.CyberArkMedia.VaultInstaller },
        @{ Name = "CPM";      Path = $Config.CyberArkMedia.CPMInstaller },
        @{ Name = "PVWA";     Path = $Config.CyberArkMedia.PVWAInstaller },
        @{ Name = "PSM";      Path = $Config.CyberArkMedia.PSMInstaller }
    )

    foreach ($comp in $components) {
        $fullPath = Join-Path $cyberArkPath $comp.Path
        if (Test-Path $fullPath) {
            $mediaChecks += @{ Name = $comp.Name; Status = "OK" }
        } else {
            $mediaChecks += @{ Name = $comp.Name; Status = "MISSING"; Path = $fullPath }
        }
    }

    # Check key folders (CRITICAL - these are folders, not ISOs)
    $masterKeyPath   = Join-Path $cyberArkPath $Config.CyberArkMedia.MasterKeyFolder
    $operatorKeyPath = Join-Path $cyberArkPath $Config.CyberArkMedia.OperatorKeyFolder

    # Validate Master key folder contents
    if (Test-Path $masterKeyPath) {
        $masterFiles = Get-ChildItem $masterKeyPath
        $requiredMasterFiles = @("recprv.key", "recpub.key", "rndbase.dat", "server.key")
        $missingMaster = $requiredMasterFiles | Where-Object {
            -not (Test-Path (Join-Path $masterKeyPath $_))
        }

        if ($missingMaster.Count -eq 0) {
            $mediaChecks += @{ Name = "Master Keys"; Status = "OK" }
            Write-Host ""
            Write-Host "    Master key folder: $masterKeyPath" -ForegroundColor DarkGray
            $masterFiles | ForEach-Object {
                Write-Host "      +-- $($_.Name) ($([math]::Round($_.Length/1KB, 1)) KB)" -ForegroundColor DarkGray
            }
        } else {
            $mediaChecks += @{
                Name   = "Master Keys"
                Status = "INCOMPLETE"
                Detail = "Missing: $($missingMaster -join ', ')"
            }
        }
    } else {
        $mediaChecks += @{
            Name   = "Master Keys"
            Status = "MISSING"
            Path   = $masterKeyPath
        }
    }

    # Validate Operator key folder contents
    if (Test-Path $operatorKeyPath) {
        $operatorFiles = Get-ChildItem $operatorKeyPath
        $requiredOperatorFiles = @("recpub.key", "rndbase.dat", "server.key")
        $missingOperator = $requiredOperatorFiles | Where-Object {
            -not (Test-Path (Join-Path $operatorKeyPath $_))
        }

        if ($missingOperator.Count -eq 0) {
            $mediaChecks += @{ Name = "Operator Keys"; Status = "OK" }
            Write-Host "    Operator key folder: $operatorKeyPath" -ForegroundColor DarkGray
            $operatorFiles | ForEach-Object {
                Write-Host "      +-- $($_.Name) ($([math]::Round($_.Length/1KB, 1)) KB)" -ForegroundColor DarkGray
            }
        } else {
            $mediaChecks += @{
                Name   = "Operator Keys"
                Status = "INCOMPLETE"
                Detail = "Missing: $($missingOperator -join ', ')"
            }
        }
    } else {
        $mediaChecks += @{
            Name   = "Operator Keys"
            Status = "MISSING"
            Path   = $operatorKeyPath
        }
    }

    # Check license
    $licensePath = Join-Path $cyberArkPath $Config.CyberArkMedia.LicenseFile
    if (Test-Path $licensePath) {
        $mediaChecks += @{ Name = "License"; Status = "OK" }
    } else {
        $mediaChecks += @{ Name = "License"; Status = "MISSING"; Path = $licensePath }
    }

    # Report
    $missing = $mediaChecks | Where-Object { $_.Status -ne "OK" }
    if ($missing.Count -eq 0) {
        Write-Host " ALL OK" -ForegroundColor Green
        $checks += @{ Check = "CyberArkMedia"; Status = "OK" }
    } else {
        Write-Host " ISSUES FOUND" -ForegroundColor Yellow
        foreach ($m in $missing) {
            Write-Host "    [X] $($m.Name): $($m.Status)" -ForegroundColor Yellow
            if ($m.Path)   { Write-Host "      Expected: $($m.Path)"   -ForegroundColor DarkYellow }
            if ($m.Detail) { Write-Host "      $($m.Detail)"           -ForegroundColor DarkYellow }
        }
        $checks += @{ Check = "CyberArkMedia"; Status = "PARTIAL" }
        $warnings++
    }

    # Print summary table
    Write-Host ""
    Write-Host "    CyberArk Media Summary:" -ForegroundColor Cyan
    Write-Host "    +------------------+----------+" -ForegroundColor DarkGray
    Write-Host "    | Component        | Status   |" -ForegroundColor DarkGray
    Write-Host "    +------------------+----------+" -ForegroundColor DarkGray
    foreach ($mc in $mediaChecks) {
        $statusColor = if ($mc.Status -eq "OK") { "Green" } else { "Yellow" }
        $name   = $mc.Name.PadRight(16)
        $status = $mc.Status.PadRight(8)
        Write-Host "    | " -NoNewline -ForegroundColor DarkGray
        Write-Host $name -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor DarkGray
        Write-Host $status -NoNewline -ForegroundColor $statusColor
        Write-Host " |" -ForegroundColor DarkGray
    }
    Write-Host "    +------------------+----------+" -ForegroundColor DarkGray

} else {
    Write-Host " FAILED" -ForegroundColor Red
    Write-Host "    Base path not found: $cyberArkPath" -ForegroundColor Red
    $checks += @{ Check = "CyberArkMedia"; Status = "FAILED" }
}

# ---------------------------------------------------------------------------
# 4. VM Folder
# ---------------------------------------------------------------------------
Write-Host "`n[4] VM Storage folder..." -NoNewline

$vmFolder = $Config.VMware.DefaultVMFolder
if (-not (Test-Path $vmFolder)) {
    New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
}

$drive = Split-Path $vmFolder -Qualifier
$disk = Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue
if ($disk) {
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    $minGB  = 250
    if ($freeGB -ge $minGB) {
        Write-Host " OK ($freeGB GB free)" -ForegroundColor Green
        $checks += @{ Check = "DiskSpace"; Status = "OK" }
    } else {
        Write-Host " WARNING ($freeGB GB free, need $minGB+ GB)" -ForegroundColor Yellow
        $checks += @{ Check = "DiskSpace"; Status = "WARNING" }
        $warnings++
    }
} else {
    Write-Host " OK" -ForegroundColor Green
    $checks += @{ Check = "DiskSpace"; Status = "OK" }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Prerequisites Summary" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$failed = $checks | Where-Object { $_.Status -eq "FAILED" }

foreach ($c in $checks) {
    $color  = switch ($c.Status) {
        "OK"      { "Green"  }
        "PARTIAL" { "Yellow" }
        "WARNING" { "Yellow" }
        default   { "Red"    }
    }
    $symbol = if ($c.Status -eq "OK") { "[OK]" } else { "[!!]" }
    Write-Host "  $symbol $($c.Check.PadRight(20)) $($c.Status)" -ForegroundColor $color
}

Write-Host ""

if ($failed.Count -gt 0) {
    Write-Host "CRITICAL prerequisites are missing. Fix them before deploying." -ForegroundColor Red
    throw "Prerequisites check failed: $($failed.Check -join ', ')"
} elseif ($warnings -gt 0) {
    Write-Host "Prerequisites OK with warnings. Deployment can proceed." -ForegroundColor Yellow
} else {
    Write-Host "All prerequisites satisfied. Ready to deploy!" -ForegroundColor Green
}
