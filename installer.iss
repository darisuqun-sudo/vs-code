#ifndef CodeOSSPayloadDir
  #define CodeOSSPayloadDir "VSCode-win32-x64"
#endif
#ifndef CodeOSSAppVersion
  #define CodeOSSAppVersion "1.140.0"
#endif

[Setup]
AppName=Code - OSS
AppVersion={#CodeOSSAppVersion}
DefaultDirName={autopf}\Code - OSS
DefaultGroupName=Code - OSS
UninstallDisplayIcon={app}\Code - OSS.exe
OutputDir=Output
OutputBaseFilename=Code-OSS-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
SignTool=CodeOSSPublicSign
SignedUninstaller=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#CodeOSSPayloadDir}\*"; DestDir: "{app}"; Excludes: "\debug.log"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Code - OSS"; Filename: "{app}\Code - OSS.exe"
Name: "{autodesktop}\Code - OSS"; Filename: "{app}\Code - OSS.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Code - OSS.exe"; Description: "{cm:LaunchProgram,Code - OSS}"; Flags: nowait postinstall skipifsilent
