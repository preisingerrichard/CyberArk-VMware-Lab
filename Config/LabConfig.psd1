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
        RockyLinux    = "F:\VMWare\CyberArk-VMware-Lab\ISO\Rocky-9.7-x86_64-minimal.iso"
    }

    # === CyberArk Installation Media ===
    CyberArkMedia = @{
        BasePath           = "F:\VMWare\CyberArk-VMware-Lab\Installers"
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
        VMNetName  = "VMnet8"
        Subnet     = "192.168.100.0/24"
        Gateway    = "192.168.100.2"
        DNS        = "192.168.100.10"
        SubnetMask = "255.255.255.0"
    }

    # === Domain Configuration ===
    Domain = @{
        Name             = "cyberark.lab"
        NetBIOSName      = "CYBERARKLAB"
        SafeModePassword = "Cyb3rArk!Lab2024"
        DomainAdminUser  = "Administrator"
        DomainAdminPass  = "Cyberark!Local2024"
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
        },
        @{
            Name        = "PTA01"
            Role        = "PTA"
            CPUs        = 4
            MemoryMB    = 8192   # PTA needs 8GB+; at 4GB the post-install JVM utils (CSR gen) thrash
            DiskGB      = 60
            IPAddress   = "192.168.100.40"
            OS          = "RockyLinux9"
            Description = "CyberArk Privileged Threat Analytics"
        },
        @{
            Name        = "PTA02"
            Role        = "PTA"
            CPUs        = 4
            MemoryMB    = 8192   # PTA needs 8GB+; at 4GB the post-install JVM utils (CSR gen) thrash
            DiskGB      = 60
            IPAddress   = "192.168.100.41"
            OS          = "RockyLinux9"
            Description = "CyberArk PTA - Secondary/DR"
        },
        @{
            Name        = "PSMP01"
            Role        = "PSMP"
            CPUs        = 2
            MemoryMB    = 4096
            DiskGB      = 40
            IPAddress   = "192.168.100.50"
            OS          = "RockyLinux9"
            Description = "CyberArk PSM for SSH Proxy"
        }
    )
}