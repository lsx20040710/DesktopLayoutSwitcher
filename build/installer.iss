#ifndef AppVersion
  #error AppVersion must be supplied by Build-Release.ps1
#endif
#ifndef SourceDir
  #error SourceDir must be supplied by Build-Release.ps1
#endif
#ifndef ReleaseDir
  #error ReleaseDir must be supplied by Build-Release.ps1
#endif

[Setup]
AppId={{3F6A920A-CB83-4458-BAC8-3D88103991A6}
AppName=DesktopLayoutSwitcher
AppVersion={#AppVersion}
AppPublisher=lsx20040710
AppPublisherURL=https://github.com/lsx20040710/DesktopLayoutSwitcher
AppSupportURL=https://github.com/lsx20040710/DesktopLayoutSwitcher/issues
AppUpdatesURL=https://github.com/lsx20040710/DesktopLayoutSwitcher/releases
DefaultDirName={localappdata}\Programs\DesktopLayoutSwitcher
DefaultGroupName=DesktopLayoutSwitcher
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDir}
OutputBaseFilename=DesktopLayoutSwitcher-{#AppVersion}-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\DesktopLayoutSwitcher.exe
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Chinese is bundled with our sources: runner installations omit unofficial languages.
Name: "chinesesimp"; MessagesFile: "{#SourcePath}Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\DesktopLayoutSwitcher.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\DesktopLayoutSwitcher.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\DesktopItems.psm1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\VERSION"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\DesktopLayoutSwitcher"; Filename: "{app}\DesktopLayoutSwitcher.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\DesktopLayoutSwitcher"; Filename: "{app}\DesktopLayoutSwitcher.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\DesktopLayoutSwitcher.exe"; Description: "{cm:LaunchProgram,DesktopLayoutSwitcher}"; Flags: nowait postinstall skipifsilent

; User profiles, desktop item archives, and recovery backups are deliberately not
; installed or removed by the installer. Only the five listed program files move.
