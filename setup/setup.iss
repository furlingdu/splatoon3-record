#define AppVersion "3.0.0"
#define NSOClientId "71b963c1b7b6d119"
#define AppName "Splatoon3 Record"

[Setup]
AppId={{9A70C1D8-1B4B-4A32-8F9A-7D1E2C3B4A50}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=澪度
AppPublisherURL=https://github.com/furlingdu/splatoon3-record
AppSupportURL=https://github.com/furlingdu/splatoon3-record/issues
AppUpdatesURL=https://github.com/furlingdu/splatoon3-record/releases
DefaultDirName={localappdata}\Programs\Splatoon3 Record
DefaultGroupName=Splatoon3 Record
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Splatoon3Record3.0.0X64Setup
SetupIconFile=..\assets\images\appIcon.ico
UninstallDisplayIcon={app}\splatoon3record.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
LicenseFile=..\LICENSE

[Languages]
Name: "ChineseSimplified"; MessagesFile: "..\third_party\innosetup\ChineseSimplified.isl"

[Tasks]
Name: "DesktopIcon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\assets\images\appIcon.ico"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\desktop_multi_window_plugin.dll"

[Icons]
Name: "{group}\Splatoon3 Record"; Filename: "{app}\splatoon3record.exe"
Name: "{userdesktop}\Splatoon3 Record"; Filename: "{app}\splatoon3record.exe"; Tasks: DesktopIcon

[Run]
Filename: "{app}\splatoon3record.exe"; Description: "运行 Splatoon3 Record"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Classes\npf{#NSOClientId}"; ValueType: string; ValueName: ""; ValueData: "URL:Nintendo Switch Online"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\npf{#NSOClientId}"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\npf{#NSOClientId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\splatoon3record.exe"" ""%1"""

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function OldInstallDir(): String;
var
  Candidate: String;
begin
  Result := '';
  Candidate := ExpandConstant('{localappdata}\Programs\Splatoon3 Record');
  if FileExists(Candidate + '\Splatoon3 Record.exe') then Result := Candidate;
  if Result = '' then
  begin
    Candidate := ExpandConstant('{localappdata}\Programs\splatoon3record');
    if FileExists(Candidate + '\Splatoon3 Record.exe') then Result := Candidate;
  end;
  if Result = '' then
  begin
    Candidate := ExpandConstant('{localappdata}\Programs\splatoon3-record');
    if FileExists(Candidate + '\Splatoon3 Record.exe') then Result := Candidate;
  end;
end;

procedure RemoveOldInstall();
var
  OldDir: String;
  Uninstaller: String;
  Code: Integer;
begin
  OldDir := OldInstallDir();
  if OldDir = '' then Exit;
  Uninstaller := OldDir + '\Uninstall Splatoon3 Record.exe';
  if not FileExists(Uninstaller) then Uninstaller := OldDir + '\unins000.exe';
  if FileExists(Uninstaller) then
    Exec(Uninstaller, '/S', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function InitializeSetup(): Boolean;
begin
  RemoveOldInstall();
  Result := True;
end;




