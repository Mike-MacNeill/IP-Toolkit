#ifndef RuntimeIdentifier
#define RuntimeIdentifier "win-x64"
#endif

[Setup]
AppId={{2F8C7A58-8A4F-4BA2-9451-6BE65357A219}
AppName=IP Toolkit
AppVersion=1.0.0
AppPublisher=IP Toolkit
SetupIconFile=IPToolkit.Windows\Assets\IPToolkit.ico
DefaultDirName={localappdata}\Programs\IP Toolkit
DefaultGroupName=IP Toolkit
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist\installer
OutputBaseFilename=IPToolkit-Setup-{#RuntimeIdentifier}
UninstallDisplayIcon={app}\IPToolkit.Windows.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
#if RuntimeIdentifier == "win-arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64
#endif

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "dist\{#RuntimeIdentifier}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\IP Toolkit"; Filename: "{app}\IPToolkit.Windows.exe"
Name: "{autodesktop}\IP Toolkit"; Filename: "{app}\IPToolkit.Windows.exe"; Tasks: desktopicon