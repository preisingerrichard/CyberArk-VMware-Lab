<#
.SYNOPSIS
    Alternative execution via PowerShell Remoting (WinRM)
    More reliable than vmrun for complex scripts
#>

function New-LabSession {
    param(
        [string]$ComputerName,
        [string]$Username,
        [string]$Password
    )

    $effectiveUsername = $Username
    if (
        $ComputerName -match '^\d{1,3}(\.\d{1,3}){3}$' -and
        $Username -notmatch '^[^\\]+\\' -and
        $Username -notmatch '@'
    ) {
        $effectiveUsername = ".\$Username"
    }

    $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object PSCredential($effectiveUsername, $secPass)

    # For lab remoting to an IP, TrustedHosts may be required.
    # Updating it needs elevation, so only try when necessary and don't fail early
    # before we even attempt the session.
    $needsTrustedHosts = $ComputerName -match '^\d{1,3}(\.\d{1,3}){3}$'
    if ($needsTrustedHosts) {
        $currentTrustedHosts = $null
        try {
            $currentTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        } catch {
            $currentTrustedHosts = $null
        }

        $isAlreadyTrusted = (
            $currentTrustedHosts -eq '*' -or
            ($currentTrustedHosts -split ',' | ForEach-Object { $_.Trim() }) -contains $ComputerName
        )

        if (-not $isAlreadyTrusted) {
            try {
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $ComputerName -Force -Concatenate -ErrorAction Stop
            } catch {
                Write-Warning "Could not update WSMan TrustedHosts for $ComputerName. Continuing to attempt the session with the current client configuration."
            }
        }
    }

    $sessionOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck
    $session = New-PSSession -ComputerName $ComputerName -Credential $cred -SessionOption $sessionOptions -ErrorAction Stop

    return $session
}

function Invoke-LabRemoteScript {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )

    Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Copy-LabFileRemote {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Copy-Item -Path $SourcePath -Destination $DestinationPath -ToSession $Session -Force -Recurse
}

Export-ModuleMember -Function *
