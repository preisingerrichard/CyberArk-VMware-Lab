#requires -Version 5.1
<#
.SYNOPSIS
    Interactive path and network configuration wizard for CyberArk Lab.
.DESCRIPTION
    Prompts for machine-specific paths (VMware, ISOs, installers, VM storage),
    network settings, and VM IP addresses, then writes Config\LabConfig.psd1.
    Run once before Deploy-Lab.ps1 on any new machine.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ConfigPath = Join-Path $PSScriptRoot "Config\LabConfig.psd1"
if (-not (Test-Path $ConfigPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Config not found:`n$ConfigPath`n`nRun from the repo root.",
        "CyberArk Lab Setup", 'OK', 'Error') | Out-Null
    exit 1
}
$Config = Import-PowerShellDataFile $ConfigPath

# ── helpers ───────────────────────────────────────────────────────────────────
function Add-Label {
    param($parent, $text, $x, $y, $w = 160, $h = 20)
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $text
    $lbl.Location  = New-Object System.Drawing.Point($x, ($y + 3))
    $lbl.Size      = New-Object System.Drawing.Size($w, $h)
    $lbl.TextAlign = "MiddleLeft"
    $parent.Controls.Add($lbl)
    return $lbl
}

function Add-TextBox {
    param($parent, $value, $x, $y, $w = 200)
    $tb          = New-Object System.Windows.Forms.TextBox
    $tb.Text     = $value
    $tb.Location = New-Object System.Drawing.Point($x, $y)
    $tb.Size     = New-Object System.Drawing.Size($w, 23)
    $parent.Controls.Add($tb)
    return $tb
}

function Add-BrowseButton {
    param($parent, $tb, $x, $y, [switch]$File, $filter = "All Files (*.*)|*.*")
    $btn           = New-Object System.Windows.Forms.Button
    $btn.Text      = "Browse..."
    $btn.Location  = New-Object System.Drawing.Point($x, ($y - 1))
    $btn.Size      = New-Object System.Drawing.Size(76, 25)
    $btn.FlatStyle = "System"
    if ($File) {
        $btn.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = $filter
            if ($tb.Text -and (Test-Path (Split-Path $tb.Text -Parent -ErrorAction SilentlyContinue))) {
                $dlg.InitialDirectory = Split-Path $tb.Text -Parent
            }
            if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.FileName }
        }.GetNewClosure())
    } else {
        $btn.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($tb.Text -and (Test-Path $tb.Text)) { $dlg.SelectedPath = $tb.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.SelectedPath }
        }.GetNewClosure())
    }
    $parent.Controls.Add($btn)
    return $btn
}

function New-GroupBox {
    param($parent, $text, $x, $y, $w, $h)
    $gb          = New-Object System.Windows.Forms.GroupBox
    $gb.Text     = $text
    $gb.Location = New-Object System.Drawing.Point($x, $y)
    $gb.Size     = New-Object System.Drawing.Size($w, $h)
    $gb.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $parent.Controls.Add($gb)
    return $gb
}

function Get-VMIP {
    param($role)
    $vm = $Config.VMs | Where-Object {
        $r = @($_.Role); $r -contains $role -or $_.Role -eq $role
    } | Select-Object -First 1
    if ($vm) { return $vm.IPAddress } else { return "" }
}

# layout constants
$GX  = 20    # groupbox x
$GW  = 706   # groupbox width
$LX  = 10    # label x inside groupbox
$LW  = 170   # label width (path sections)
$TX  = 185   # textbox x (path sections)
$TW  = 360   # textbox width (path sections)
$BX  = 553   # browse button x
$ROW = 30    # row height

# ── form (no scroll -- sized to fit all sections) ─────────────────────────────
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "CyberArk Lab - Machine Setup"
$form.ClientSize      = New-Object System.Drawing.Size(748, 795)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

# ── VMware ────────────────────────────────────────────────────────────────────
$y0 = 8
$gbVM = New-GroupBox $form "VMware Workstation" $GX $y0 $GW 145
$r = 25
Add-Label $gbVM "Workstation install folder:" $LX $r $LW
$tbVMWPath = Add-TextBox $gbVM $Config.VMware.WorkstationPath $TX $r $TW
Add-BrowseButton $gbVM $tbVMWPath $BX $r

$r += $ROW
Add-Label $gbVM "VM storage folder:" $LX $r $LW
$tbVMFolder = Add-TextBox $gbVM $Config.VMware.DefaultVMFolder $TX $r $TW
Add-BrowseButton $gbVM $tbVMFolder $BX $r

$r += $ROW
Add-Label $gbVM "Template folder:" $LX $r $LW
$tbTmplFolder = Add-TextBox $gbVM $Config.VMware.TemplateFolder $TX $r $TW
Add-BrowseButton $gbVM $tbTmplFolder $BX $r

$r += $ROW
Add-Label $gbVM "Template VM name:" $LX $r $LW
$tbTmplName = Add-TextBox $gbVM $Config.VMware.TemplateName $TX $r 180

# ── ISOs ─────────────────────────────────────────────────────────────────────
$y1 = $y0 + 145 + 6
$gbISO = New-GroupBox $form "ISO Files" $GX $y1 $GW 100
$r = 25
Add-Label $gbISO "Windows Server ISO:" $LX $r $LW
$tbWinISO = Add-TextBox $gbISO $Config.ISOs.WindowsServer $TX $r $TW
Add-BrowseButton $gbISO $tbWinISO $BX $r -File -filter "ISO files (*.iso)|*.iso|All files (*.*)|*.*"

$r += $ROW
Add-Label $gbISO "Rocky Linux ISO:" $LX $r $LW
$tbRockyISO = Add-TextBox $gbISO $Config.ISOs.RockyLinux $TX $r $TW
Add-BrowseButton $gbISO $tbRockyISO $BX $r -File -filter "ISO files (*.iso)|*.iso|All files (*.*)|*.*"

# ── CyberArk installers ───────────────────────────────────────────────────────
$y2 = $y1 + 100 + 6
$gbCA = New-GroupBox $form "CyberArk Installer Media" $GX $y2 $GW 60
$r = 25
Add-Label $gbCA "Installers base folder:" $LX $r $LW
$tbCABase = Add-TextBox $gbCA $Config.CyberArkMedia.BasePath $TX $r $TW
Add-BrowseButton $gbCA $tbCABase $BX $r

# ── Network ───────────────────────────────────────────────────────────────────
$y3 = $y2 + 60 + 6
$gbNet = New-GroupBox $form "Network  (changes here update LabConfig.psd1 and scripts)" $GX $y3 $GW 130

# two columns: left half / right half
$NLW = 115   # network label width
$NTW = 165   # network textbox width
$C1L = 10;  $C1T = $C1L + $NLW + 5    # col-1 label x, textbox x
$C2L = 350; $C2T = $C2L + $NLW + 5    # col-2 label x, textbox x

$r = 25
Add-Label $gbNet "VMnet name:" $C1L $r $NLW
$tbVMNet = Add-TextBox $gbNet $Config.Network.VMNetName $C1T $r $NTW
Add-Label $gbNet "Subnet mask:" $C2L $r $NLW
$tbMask = Add-TextBox $gbNet $Config.Network.SubnetMask $C2T $r $NTW

$r += $ROW
Add-Label $gbNet "Subnet (CIDR):" $C1L $r $NLW
$tbSubnet = Add-TextBox $gbNet $Config.Network.Subnet $C1T $r $NTW
Add-Label $gbNet "Gateway:" $C2L $r $NLW
$tbGateway = Add-TextBox $gbNet $Config.Network.Gateway $C2T $r $NTW

$r += $ROW
Add-Label $gbNet "DNS / DC01 IP:" $C1L $r $NLW
$tbDNS = Add-TextBox $gbNet $Config.Network.DNS $C1T $r $NTW

# ── VM IP Addresses ───────────────────────────────────────────────────────────
$y4 = $y3 + 130 + 6
$gbIPs = New-GroupBox $form "VM IP Addresses" $GX $y4 $GW 190

$ILW = 195   # wider labels so "COMP01 (CPM/PVWA/PSM):" fits
$ITX = 210   # textbox x inside VM IPs group
$ITW = 110   # enough for any IPv4

$r = 25
Add-Label $gbIPs "DC01   (Domain Controller):" $LX $r $ILW
$tbDC01IP = Add-TextBox $gbIPs (Get-VMIP "DomainController") $ITX $r $ITW

$r += $ROW
Add-Label $gbIPs "VAULT01  (CyberArk Vault):" $LX $r $ILW
$tbVaultIP = Add-TextBox $gbIPs (Get-VMIP "Vault") $ITX $r $ITW

$r += $ROW
Add-Label $gbIPs "COMP01  (CPM / PVWA / PSM):" $LX $r $ILW
$tbCompIP = Add-TextBox $gbIPs (Get-VMIP "CPM") $ITX $r $ITW

$r += $ROW
Add-Label $gbIPs "PTA01    (optional):" $LX $r $ILW
$tbPtaIP = Add-TextBox $gbIPs (Get-VMIP "PTA") $ITX $r $ITW

$r += $ROW
Add-Label $gbIPs "PSMP01  (optional):" $LX $r $ILW
$tbPsmpIP = Add-TextBox $gbIPs (Get-VMIP "PSMP") $ITX $r $ITW

# ── status + buttons ─────────────────────────────────────────────────────────
$yB = $y4 + 190 + 8

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(20, $yB)
$lblStatus.Size      = New-Object System.Drawing.Size(520, 20)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblStatus.Text      = "All changes write to Config\LabConfig.psd1 -- scripts read from there."
$form.Controls.Add($lblStatus)

$btnOK             = New-Object System.Windows.Forms.Button
$btnOK.Text        = "Save && Close"
$btnOK.Size        = New-Object System.Drawing.Size(120, 30)
$btnOK.Location    = New-Object System.Drawing.Point(608, ($yB + 30))
$btnOK.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnOK.ForeColor   = [System.Drawing.Color]::White
$btnOK.FlatStyle   = "Flat"
$btnOK.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnOK)
$form.AcceptButton = $btnOK

$btnCancel           = New-Object System.Windows.Forms.Button
$btnCancel.Text      = "Cancel"
$btnCancel.Size      = New-Object System.Drawing.Size(80, 30)
$btnCancel.Location  = New-Object System.Drawing.Point(518, ($yB + 30))
$btnCancel.FlatStyle = "System"
$form.Controls.Add($btnCancel)
$form.CancelButton   = $btnCancel

# ── save ─────────────────────────────────────────────────────────────────────
$btnOK.Add_Click({
    $vmrunDerived = Join-Path $tbVMWPath.Text "vmrun.exe"

    $missing = @()
    if (-not (Test-Path $tbVMWPath.Text))  { $missing += "VMware folder: $($tbVMWPath.Text)" }
    if (-not (Test-Path $tbVMFolder.Text)) { $missing += "VM storage: $($tbVMFolder.Text)" }
    if (-not (Test-Path $tbWinISO.Text))   { $missing += "Windows ISO: $($tbWinISO.Text)" }

    if ($missing.Count -gt 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Paths not found:`n`n" + ($missing -join "`n") + "`n`nSave anyway?",
            "Missing paths", 'YesNo', 'Warning')
        if ($ans -eq 'No') { return }
    }

    $newConfig = @"
@{
    # === VMware Settings ===
    VMware = @{
        WorkstationPath = "$($tbVMWPath.Text)"
        VMRunPath       = "$vmrunDerived"
        DefaultVMFolder = "$($tbVMFolder.Text)"
        TemplateFolder  = "$($tbTmplFolder.Text)"
        TemplateName    = "$($tbTmplName.Text)"
    }

    # === ISO Paths ===
    ISOs = @{
        WindowsServer = "$($tbWinISO.Text)"
        RockyLinux    = "$($tbRockyISO.Text)"
    }

    # === CyberArk Installation Media ===
    CyberArkMedia = @{
        BasePath           = "$($tbCABase.Text)"
        VaultFolder        = "Server"
        VaultInstaller     = "Server\setup.exe"
        CPMFolder          = "CPM"
        PVWAFolder         = "PVWA"
        PSMFolder          = "PSM"
        MasterKeyFolder    = "keys\master"
        OperatorKeyFolder  = "keys\operator"
        LicenseFile        = "License\License.xml"
        ClientFolder       = "Client\Client"
        PTAFolder          = "PTA"
        PSMPFolder         = "PSMP"
    }

    # === Network Configuration ===
    Network = @{
        Type       = "NAT"
        VMNetName  = "$($tbVMNet.Text)"
        Subnet     = "$($tbSubnet.Text)"
        Gateway    = "$($tbGateway.Text)"
        DNS        = "$($tbDNS.Text)"
        SubnetMask = "$($tbMask.Text)"
    }

    # === Domain Configuration ===
    Domain = @{
        Name             = "$($Config.Domain.Name)"
        NetBIOSName      = "$($Config.Domain.NetBIOSName)"
        SafeModePassword = "$($Config.Domain.SafeModePassword)"
        DomainAdminUser  = "$($Config.Domain.DomainAdminUser)"
        DomainAdminPass  = "$($Config.Domain.DomainAdminPass)"
    }

    # === Local Admin ===
    LocalAdmin = @{
        Username = "$($Config.LocalAdmin.Username)"
        Password = "$($Config.LocalAdmin.Password)"
    }

    # === VM Definitions ===
    VMs = @(
        @{
            Name        = "DC01"
            Role        = "DomainController"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 30
            IPAddress   = "$($tbDC01IP.Text)"
            OS          = "WindowsServer2022"
            Description = "Domain Controller, DNS, CA"
        },
        @{
            Name        = "VAULT01"
            Role        = "Vault"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 30
            IPAddress   = "$($tbVaultIP.Text)"
            OS          = "WindowsServer2022"
            Description = "CyberArk Primary Vault"
        },
        @{
            Name        = "COMP01"
            Role        = @("CPM", "PVWA", "PSM")
            CPUs        = 4
            MemoryMB    = 8192
            DiskGB      = 60
            IPAddress   = "$($tbCompIP.Text)"
            OS          = "WindowsServer2022"
            Description = "CyberArk Components Server"
        },
        @{
            Name        = "PTA01"
            Role        = "PTA"
            CPUs        = 4
            MemoryMB    = 8192
            DiskGB      = 60
            IPAddress   = "$($tbPtaIP.Text)"
            OS          = "RockyLinux9"
            Description = "CyberArk Privileged Threat Analytics"
        },
        @{
            Name        = "PSMP01"
            Role        = "PSMP"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 40
            IPAddress   = "$($tbPsmpIP.Text)"
            OS          = "RockyLinux9"
            Description = "CyberArk PSM for SSH Proxy"
        }
    )
}
"@

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($ConfigPath, $newConfig, $utf8NoBom)
        $lblStatus.Text      = "Saved to $ConfigPath"
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
        $form.DialogResult   = 'OK'
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to save:`n$($_.Exception.Message)",
            "Error", 'OK', 'Error') | Out-Null
    }
})

$btnCancel.Add_Click({ $form.Close() })
$form.ShowDialog() | Out-Null
