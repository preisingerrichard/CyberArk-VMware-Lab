[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-DlgOrder]
Dlg0={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdWelcome-0
Count=9
Dlg1={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdLicense-0
Dlg2={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdRegisterUser-0
Dlg3={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdAskDestPath-0
Dlg4={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SetupType-0
Dlg5={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdSelectFolder-0
Dlg6={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-ASK_ADD_VAULT-0
Dlg7={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-ADD_VAULT-0
Dlg8={E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdFinishReboot-0
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdWelcome-0]
Result=1
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdLicense-0]
Result=1
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdRegisterUser-0]
szName=cyberark.lab
szCompany=cyberark.lab
Result=1
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdAskDestPath-0]
szDir=C:\Program Files (x86)\PrivateArk
Result=1
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SetupType-0]
Result=301
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdSelectFolder-0]
szFolder=PrivateArk
Result=1
[Application]
Name=PrivateArk Client
Version=9.10.2
Company=CyberArk
Lang=0009
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-ASK_ADD_VAULT-0]
Result=1
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-ADD_VAULT-0]
ServerName=primary vault
ServerIP=192.168.100.20
UserName=Administrator
ServerInputPortNumber=1858
RequestTimeout=30000
NTAuth=0
NTAuthAgent=' '
NTAuthAgentKeyFile=' '
SMBGatewayName=' '
HTTPGatewayName=' '
ProtocolType=0
ConnectionTimeoutInSecs=60
bUseConnectionTimeout=0
bUseOnlyHTTP_1_0_InFirewall=0
bUseOnlyHTTP_1_0_InProxy=0
bSharedData=0
bEnhancedSSL=0
bUsePreAuthSecuredSession=0
bTrustSelfSignedCert=0
bAllowThirdPartyUseSSC=0
Proxy_UseProxy=0
Proxy_Protocol=2
Proxy_Address=' '
Proxy_Port=0
Proxy_Username=' '
Proxy_Password=' '
Proxy_UseAuthentication=0
Proxy_LastProxyError=0
Proxy_AuthType=' '
Proxy_LastProxyErrorText=' '
Proxy_Proxy_addr=' '
Proxy_SessionType_ProtocolType=0
Proxy_SessionType_Timeout=0
Proxy_SessionType_LastSend=0
[{E9FE3D71-DF26-11D3-8656-0000E8EFAFE3}-SdFinishReboot-0]
Result=1
BootOption=0
