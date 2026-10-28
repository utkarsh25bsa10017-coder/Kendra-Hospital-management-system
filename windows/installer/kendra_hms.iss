; Windows installer for Kendra HMS (Inno Setup 6, free).
; The GitHub workflow builds it after `flutter build windows --release`:
;   iscc /DAppVersion=1.0.0 windows\installer\kendra_hms.iss
; Output: build\installer\Kendra-HMS-windows-setup.exe

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExe "kendra_hms.exe"
#define SourceDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Keep this id fixed: Windows uses it to recognise upgrades of the same app.
AppId={{1EFE4772-89AA-42C5-8E39-6E2542775846}
AppName=Kendra HMS
AppVersion={#AppVersion}
AppPublisher=Kendra HMS
DefaultDirName={autopf}\Kendra HMS
DefaultGroupName=Kendra HMS
DisableProgramGroupPage=yes
; Installs for everyone by default; people without admin rights can choose
; "only for me" instead.
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=Kendra-HMS-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kendra HMS"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Kendra HMS"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Kendra HMS}"; Flags: nowait postinstall skipifsilent
