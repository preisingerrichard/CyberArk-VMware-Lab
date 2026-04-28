@{
    # === VMware Settings ===
    VMware = @{
        WorkstationPath = "C:\Program Files (x86)\VMware\VMware Workstation"
        VMRunPath       = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
        DefaultVMFolder = "F:\VMs\CyberArk"
        TemplateFolder  = "F:\VMs\Templates"
        TemplateName    = "WS2022-Tmpl"
    }

    # === ISO Paths ===
    ISOs = @{
        WindowsServer = "F:\VMWare\CyberArk-VMware-Lab\ISO\SERVER_EVAL_x64FRE_en-us.iso"
    }

    # === CyberArk Installation Media ===
    CyberArkMedia = @{
        BasePath           = "F:\VMWare\CyberArk-VMware-Lab\Installers"
        VaultFolder        = "Server"
        VaultInstaller     = "Server\setup.exe"
        # Component installer folders
        # Each folder must contain an InstallationAutomation\ subdirectory
        # with the CyberArk PS automation scripts (v12+ installation method).
        CPMFolder          = "CPM"
        PVWAFolder         = "PVWA"
        PSMFolder          = "PSM"

        # ============================================================
        # Key folders — these are FOLDERS, not .iso files
        # The Vault installer prompts for paths to these directories
        # ============================================================

        # Master key folder
        # Contains: recprv.key, recpub.key, rndbase.dat, server.key
        MasterKeyFolder   = "keys\master"

        # Operator key folder
        # Contains: recpub.key, rndbase.dat, server.key
        OperatorKeyFolder = "keys\operator"

        # License file
        LicenseFile = "License\License.xml"

        # PrivateArk Client installer folder
        # Contains: setup.exe, setup.ini, etc.
        ClientFolder      = "Client\Client"
    }

    # === Network Configuration ===
    Network = @{
        Type           = "NAT"         # NAT or Custom
        VMNetName      = "VMnet8"      # VMware virtual network
        Subnet         = "192.168.100.0/24"
        Gateway        = "192.168.100.2"
        DNS            = "192.168.100.10"
        SubnetMask     = "255.255.255.0"
    }

    # === Domain Configuration ===
    Domain = @{
        Name              = "cyberark.lab"
        NetBIOSName       = "CYBERARKLAB"
        SafeModePassword  = "Cyb3rArk!Lab2024"
        DomainAdminUser   = "Administrator"
        DomainAdminPass   = "Cyberark!Local2024"  # Same as LocalAdmin.Password - DC promotion inherits the local admin password
    }

    # === Local Admin ===
    LocalAdmin = @{
        Username = "Administrator"
        Password = "Cyberark!Local2024"
    }

    # === VM Definitions ===
    VMs = @(
        @{
            Name        = "DC01"
            Role        = "DomainController"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 30
            IPAddress   = "192.168.100.10"
            OS          = "WindowsServer2022"
            Description = "Domain Controller, DNS, CA"
        },
        @{
            Name        = "VAULT01"
            Role        = "Vault"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 30
            IPAddress   = "192.168.100.20"
            OS          = "WindowsServer2022"
            Description = "CyberArk Primary Vault"
        },
        @{
            Name        = "COMP01"
            Role        = @("CPM", "PVWA", "PSM")
            CPUs        = 4
            MemoryMB    = 8192
            DiskGB      = 60
            IPAddress   = "192.168.100.30"
            OS          = "WindowsServer2022"
            Description = "CyberArk Components Server"
        }
        # Optional: Separate servers for each component
        # @{
        #     Name        = "CPM01"
        #     Role        = "CPM"
        #     CPUs        = 2
        #     MemoryMB    = 4096
        #     DiskGB      = 60
        #     IPAddress   = "192.168.100.31"
        #     OS          = "WindowsServer2022"
        #     Description = "Central Policy Manager"
        # },
        # @{
        #     Name        = "PVWA01"
        #     Role        = "PVWA"
        #     CPUs        = 2
        #     MemoryMB    = 4096
        #     DiskGB      = 60
        #     IPAddress   = "192.168.100.32"
        #     OS          = "WindowsServer2022"
        #     Description = "Password Vault Web Access"
        # },
        # @{
        #     Name        = "PSM01"
        #     Role        = "PSM"
        #     CPUs        = 2
        #     MemoryMB    = 4096
        #     DiskGB      = 80
        #     IPAddress   = "192.168.100.33"
        #     OS          = "WindowsServer2022"
        #     Description = "Privileged Session Manager"
        # },
        # @{
        #     Name        = "PSMP01"
        #     Role        = "PSMP"
        #     CPUs        = 2
        #     MemoryMB    = 2048
        #     DiskGB      = 40
        #     IPAddress   = "192.168.100.34"
        #     OS          = "RHEL8"
        #     Description = "PSM for SSH Proxy"
        # }
    )
}