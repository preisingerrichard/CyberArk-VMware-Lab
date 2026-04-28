@{
    Vault = @{
        AdminUser          = "Administrator"
        AdminPassword      = "Cyberark1"
        MasterPassword     = "Cyberark1"
        VaultAddress       = "192.168.100.20"
        VaultPort          = 1858
        InstallPath        = "C:\Program Files (x86)\PrivateArk\Server"
        SafesFolder        = "C:\PrivateArk\Safes"
        SafeModeTimeout    = 300

        # Paths as they will appear INSIDE the guest VM after copy.
        # License and key paths match what the installer wizard expects
        # (verified via setup.exe /r on VAULT01).
        Guest = @{
            InstallFolder     = "C:\LabSetup\Vault"
            MasterKeyFolder   = "C:\LabSetup\keys\master"
            OperatorKeyFolder = "C:\LabSetup\keys\operator"
            LicenseFile       = "C:\LabSetup\License\License.xml"
            LogFile           = "C:\LabSetup\Logs\vault_install.log"
        }
    }

    CPM = @{
        ServiceUser     = "CyberArk-CPM"
        ServicePassword = "CPM!S3rv1ce2024"
        InstallPath     = "C:\Program Files (x86)\CyberArk\CPM"
        Guest = @{
            InstallFolder = "C:\LabSetup\CPM"
            LogFile       = "C:\LabSetup\Logs\cpm_install.log"
        }
    }

    PVWA = @{
        ServiceUser     = "CyberArk-PVWA"
        ServicePassword = "PVWA!S3rv1ce2024"
        InstallPath     = "C:\CyberArk\PVWA"
        WebAppName      = "PasswordVault"
        IISPort         = 443
        Guest = @{
            InstallFolder = "C:\LabSetup\PVWA"
            LogFile       = "C:\LabSetup\Logs\pvwa_install.log"
        }
    }

    PSM = @{
        ServiceUser     = "CyberArk-PSM"
        ServicePassword = "PSM!S3rv1ce2024"
        InstallPath     = "C:\Program Files (x86)\CyberArk\PSM"
        Guest = @{
            InstallFolder = "C:\LabSetup\PSM"
            LogFile       = "C:\LabSetup\Logs\psm_install.log"
        }
    }

    ServiceAccounts = @(
        @{ Name = "CyberArk-CPM";  Description = "CPM Service Account" },
        @{ Name = "CyberArk-PVWA"; Description = "PVWA Service Account" },
        @{ Name = "CyberArk-PSM";  Description = "PSM Service Account" }
    )
}