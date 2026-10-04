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


[CustomMessages]
english.ConfigDirTitle=Choose layout data folder
english.ConfigDirDescription=Store layouts, item backups, and archives separately from the program.
english.ConfigDirInfo=Choose an absolute folder outside your desktop and program folder. The selected folder stores your actual layout data and backups. Only a small storage.json preference remains in Local AppData. Changing this folder does not move, copy, or delete any old data; keep your previous folder and backups.
english.ConfigDirPrompt=Layout data folder:
english.ConfigDirInvalid=Choose an absolute drive or UNC folder outside the desktop and installed program folder.
english.ConfigDirReparse=The data path contains a symbolic link or directory junction. Choose a direct folder path.
english.ConfigDirUnreadable=The saved storage preference is invalid or unreadable. Choose the data folder explicitly; existing data and the old preference will be retained as a backup. Silent installation requires /CONFIGDIR=<absolute folder>.
english.ConfigDirPending=The previous data folder has an unfinished transaction. Open the old tool using that folder and finish recovery before changing the data folder. Keeping the same folder is allowed.
english.ConfigDirCreate=Cannot create the selected data folder. Check the drive, access permissions, and available space.
english.ConfigDirWrite=Cannot write to the selected data folder. Check access permissions and available space.
english.ConfigDirSave=Cannot save the storage preference. The old preference and data are preserved.
chinesesimp.ConfigDirTitle=选择布局数据存放目录
chinesesimp.ConfigDirDescription=布局、项目备份与收纳库可存放在程序目录之外。
chinesesimp.ConfigDirInfo=请选择桌面和程序安装目录之外的绝对路径。布局和实际备份存放在您选择的目录中，系统 AppData 仅保留一个很小的 storage.json 路径设置文件。修改目录不会搬迁、复制或删除原有数据，请保留原目录和备份。
chinesesimp.ConfigDirPrompt=布局数据目录：
chinesesimp.ConfigDirInvalid=请选择桌面与程序安装目录之外的盘符绝对路径或 UNC 文件夹。
chinesesimp.ConfigDirReparse=数据路径包含符号链接或目录联接，请选择直接指向实际文件夹的路径。
chinesesimp.ConfigDirUnreadable=已保存的存储路径设置无效或无法读取，请明确重新选择目录；旧设置会保留为备份，原数据不会改变。静默安装时必须指定 /CONFIGDIR=<绝对目录>。
chinesesimp.ConfigDirPending=原数据目录存在未完成的事务，请先使用原目录打开旧工具并完成恢复，再更换数据目录。继续使用原目录不受限制。
chinesesimp.ConfigDirCreate=无法创建所选数据目录，请检查磁盘、访问权限与剩余空间。
chinesesimp.ConfigDirWrite=无法写入所选数据目录，请检查访问权限与剩余空间。
chinesesimp.ConfigDirSave=无法保存存储路径设置，原设置和数据已保留。

[Code]
var
  ConfigDirPage: TInputDirWizardPage;
  InitialConfigDir: string;
  KnownPreviousRoot: string;
  StoragePreference: string;
  StoragePreferenceError: string;
  HasConfigDirOverride: Boolean;
  ExistingPreferenceValid: Boolean;
  TempSequence: Integer;

function MoveFileExW(ExistingFile, NewFile: string; Flags: Cardinal): Bool;
  external 'MoveFileExW@kernel32.dll stdcall';
function GetFileAttributesW(FileName: string): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function GetCurrentProcessId: Cardinal;
  external 'GetCurrentProcessId@kernel32.dll stdcall';

function IsAbsoluteDataPath(Value: string): Boolean;
var
  Rest: string;
  Separator, Index: Integer;
begin
  Result := False;
  if (Copy(Value, 1, 4) = '\\?\') or (Copy(Value, 1, 4) = '\\.\') then Exit;
  for Index := 1 to Length(Value) do begin
    if (Ord(Value[Index]) < 32) or (Value[Index] = '"') or (Value[Index] = '<') or
      (Value[Index] = '>') or (Value[Index] = '|') or (Value[Index] = '*') or
      (Value[Index] = '?') then Exit;
    if (Value[Index] = ':') and (Index <> 2) then Exit;
  end;
  if Length(Value) >= 3 then begin
    if (((Value[1] >= 'A') and (Value[1] <= 'Z')) or
        ((Value[1] >= 'a') and (Value[1] <= 'z'))) and
       (Value[2] = ':') and (Value[3] = '\') then begin
      Result := True;
      Exit;
    end;
  end;
  if Copy(Value, 1, 2) = '\\' then begin
    Rest := Copy(Value, 3, Length(Value));
    Separator := Pos('\', Rest);
    if (Separator <= 1) or (Length(Rest) <= Separator) then Exit;
    Result := Rest[Separator + 1] <> '\';
  end;
end;

function CanonicalDataPath(Value: string): string;
var
  Index: Integer;
begin
  Value := Trim(Value);
  StringChangeEx(Value, '/', '\', True);
  if not IsAbsoluteDataPath(Value) then begin
    Result := '';
    Exit;
  end;
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Value));
  if not IsAbsoluteDataPath(Result) then begin
    Result := '';
    Exit;
  end;
  { Win32 strips trailing dots/spaces in names; reject those aliases rather than
    letting Desktop. bypass the desktop-subtree guard. }
  for Index := 1 to Length(Result) do begin
    if (Result[Index] = '.') or (Result[Index] = ' ') then begin
      if Index = Length(Result) then begin
        Result := '';
        Exit;
      end;
      if Result[Index + 1] = '\' then begin
        Result := '';
        Exit;
      end;
    end;
  end;
end;

function InsideFolder(Path, Folder: string): Boolean;
begin
  Folder := RemoveBackslashUnlessRoot(Folder);
  Result := (CompareText(Path, Folder) = 0) or
    (CompareText(Copy(Path, 1, Length(AddBackslash(Folder))), AddBackslash(Folder)) = 0);
end;

procedure JsonSkipSpace(Value: string; var Position: Integer);
begin
  while Position <= Length(Value) do begin
    if not ((Value[Position] = ' ') or (Value[Position] = #9) or
      (Value[Position] = #10) or (Value[Position] = #13)) then Exit;
    Position := Position + 1;
  end;
end;

function JsonTake(Value: string; var Position: Integer; Expected: Char): Boolean;
begin
  JsonSkipSpace(Value, Position);
  Result := False;
  if Position > Length(Value) then Exit;
  if Value[Position] <> Expected then Exit;
  Position := Position + 1;
  Result := True;
end;

function HexDigit(Value: Char): Integer;
begin
  Result := -1;
  if (Value >= '0') and (Value <= '9') then Result := Ord(Value) - Ord('0')
  else if (Value >= 'a') and (Value <= 'f') then Result := Ord(Value) - Ord('a') + 10
  else if (Value >= 'A') and (Value <= 'F') then Result := Ord(Value) - Ord('A') + 10;
end;

function JsonString(Value: string; var Position: Integer; var Text: string): Boolean;
var
  Character: Char;
  Code, Digit, Index: Integer;
begin
  Result := False;
  Text := '';
  if not JsonTake(Value, Position, '"') then Exit;
  while Position <= Length(Value) do begin
    Character := Value[Position];
    Position := Position + 1;
    if Character = '"' then begin
      Result := True;
      Exit;
    end;
    if Ord(Character) < 32 then Exit;
    if Character = '\' then begin
      if Position > Length(Value) then Exit;
      Character := Value[Position];
      Position := Position + 1;
      case Character of
        '"', '\', '/': Text := Text + Character;
        'b': Text := Text + #8;
        'f': Text := Text + #12;
        'n': Text := Text + #10;
        'r': Text := Text + #13;
        't': Text := Text + #9;
        'u': begin
          Code := 0;
          for Index := 1 to 4 do begin
            if Position > Length(Value) then Exit;
            Digit := HexDigit(Value[Position]);
            if Digit < 0 then Exit;
            Code := Code * 16 + Digit;
            Position := Position + 1;
          end;
          Text := Text + Chr(Code);
        end;
      else
        Exit;
      end;
    end else Text := Text + Character;
  end;
end;

function ReadStorageRoot(FileName: string; var ProfileRoot: string): Boolean;
var
  Raw: AnsiString;
  Value, Key: string;
  Position: Integer;
  HasSchema, HasRoot, Finished: Boolean;
begin
  Result := False;
  ProfileRoot := '';
  if not LoadStringFromFile(FileName, Raw) then Exit;
  Value := UTF8Decode(Raw);
  if (Length(Value) > 0) and (Value[1] = #$FEFF) then Delete(Value, 1, 1);
  Position := 1;
  HasSchema := False;
  HasRoot := False;
  Finished := False;
  if not JsonTake(Value, Position, '{') then Exit;
  while not Finished do begin
    if not JsonString(Value, Position, Key) then Exit;
    if not JsonTake(Value, Position, ':') then Exit;
    if Key = 'SchemaVersion' then begin
      if HasSchema or not JsonTake(Value, Position, '1') then Exit;
      HasSchema := True;
    end else if Key = 'ProfileRoot' then begin
      if HasRoot or not JsonString(Value, Position, ProfileRoot) then Exit;
      HasRoot := True;
    end else Exit;
    JsonSkipSpace(Value, Position);
    if Position > Length(Value) then Exit;
    if Value[Position] = '}' then begin
      Position := Position + 1;
      Finished := True;
    end else if not JsonTake(Value, Position, ',') then Exit;
  end;
  JsonSkipSpace(Value, Position);
  ProfileRoot := CanonicalDataPath(ProfileRoot);
  Result := HasSchema and HasRoot and (ProfileRoot <> '') and (Position > Length(Value));
end;

function EscapeJson(Value: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '';
  for Index := 1 to Length(Value) do begin
    Character := Value[Index];
    case Ord(Character) of
      34: Result := Result + '\"';
      92: Result := Result + '\\';
      8: Result := Result + '\b';
      9: Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
    else
      if Ord(Character) < 32 then
        Result := Result + '\u00' + Copy('0123456789abcdef', (Ord(Character) div 16) + 1, 1) +
          Copy('0123456789abcdef', (Ord(Character) mod 16) + 1, 1)
      else Result := Result + Character;
    end;
  end;
end;

function NewOwnedTempName(Folder: string): string;
begin
  repeat
    TempSequence := TempSequence + 1;
    Result := AddBackslash(Folder) + '.DesktopLayoutSwitcher-install-' +
      IntToStr(GetCurrentProcessId) + '-' + IntToStr(TempSequence) + '.tmp';
  until not FileExists(Result) and not DirExists(Result);
end;

function ValidateConfigDir(Value: string; var Normalized: string): string;
var
  Probe, Parent, DesktopRoot, ProgramRoot: string;
  Attributes: Cardinal;
begin
  Result := '';
  Normalized := CanonicalDataPath(Value);
  DesktopRoot := CanonicalDataPath(ExpandConstant('{userdesktop}'));
  ProgramRoot := CanonicalDataPath(ExpandConstant('{app}'));
  if (Normalized = '') or (DesktopRoot = '') or (ProgramRoot = '') then begin
    Result := CustomMessage('ConfigDirInvalid');
    Exit;
  end;
  if InsideFolder(Normalized, DesktopRoot) or InsideFolder(Normalized, ProgramRoot) then begin
    Result := CustomMessage('ConfigDirInvalid');
    Exit;
  end;
  if FileExists(Normalized) then begin
    Result := CustomMessage('ConfigDirInvalid');
    Exit;
  end;
  Probe := Normalized;
  repeat
    Attributes := GetFileAttributesW(Probe);
    if (Attributes <> $FFFFFFFF) and ((Attributes and $400) <> 0) then begin
      Result := CustomMessage('ConfigDirReparse');
      Exit;
    end;
    Parent := RemoveBackslashUnlessRoot(ExtractFileDir(Probe));
    if (Parent = '') or (CompareText(Parent, Probe) = 0) then Break;
    Probe := Parent;
  until False;
  if (KnownPreviousRoot <> '') and (CompareText(Normalized, KnownPreviousRoot) <> 0) and
      FileExists(AddBackslash(KnownPreviousRoot) + 'data\transaction.json') then begin
    Result := CustomMessage('ConfigDirPending') + #13#10 + KnownPreviousRoot;
  end;
end;

function InitializeSetup: Boolean;
var
  Index: Integer;
  Argument: string;
begin
  StoragePreference := ExpandConstant('{localappdata}\DesktopLayoutSwitcher\storage.json');
  InitialConfigDir := ExpandConstant('{localappdata}\DesktopLayoutSwitcher\profiles');
  KnownPreviousRoot := CanonicalDataPath(InitialConfigDir);
  if FileExists(StoragePreference) or DirExists(StoragePreference) then begin
    ExistingPreferenceValid := ReadStorageRoot(StoragePreference, KnownPreviousRoot);
    if ExistingPreferenceValid then InitialConfigDir := KnownPreviousRoot
    else begin
      InitialConfigDir := '';
      StoragePreferenceError := CustomMessage('ConfigDirUnreadable');
    end;
  end;
  for Index := 1 to ParamCount do begin
    Argument := ParamStr(Index);
    if CompareText(Copy(Argument, 1, 11), '/CONFIGDIR=') = 0 then begin
      HasConfigDirOverride := True;
      InitialConfigDir := Copy(Argument, 12, Length(Argument));
    end;
  end;
  Result := True;
  { Values[] expands paths when assigning them. Reject the raw command-line
    value before the directory page can turn a relative path into an absolute one. }
  if HasConfigDirOverride and (CanonicalDataPath(InitialConfigDir) = '') then begin
    Log(CustomMessage('ConfigDirInvalid'));
    SuppressibleMsgBox(CustomMessage('ConfigDirInvalid'), mbError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;
  if StoragePreferenceError <> '' then begin
    Log(StoragePreferenceError + ' ' + StoragePreference);
    if WizardSilent and not HasConfigDirOverride then begin
      SuppressibleMsgBox(StoragePreferenceError, mbError, MB_OK, IDOK);
      Result := False;
    end;
  end;
end;

procedure InitializeWizard;
begin
  ConfigDirPage := CreateInputDirPage(wpSelectDir, CustomMessage('ConfigDirTitle'),
    CustomMessage('ConfigDirDescription'), CustomMessage('ConfigDirInfo'), False, '');
  ConfigDirPage.Add(CustomMessage('ConfigDirPrompt'));
  ConfigDirPage.Edits[0].Text := InitialConfigDir;
  if (StoragePreferenceError <> '') and not HasConfigDirOverride and not WizardSilent then
    MsgBox(StoragePreferenceError, mbError, MB_OK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Error, Normalized: string;
begin
  Result := True;
  if CurPageID = ConfigDirPage.ID then begin
    Error := ValidateConfigDir(ConfigDirPage.Edits[0].Text, Normalized);
    if Error <> '' then begin
      SuppressibleMsgBox(Error, mbError, MB_OK, IDOK);
      Result := False;
    end else ConfigDirPage.Values[0] := Normalized;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): string;
var
  Normalized, Probe: string;
begin
  Result := ValidateConfigDir(ConfigDirPage.Edits[0].Text, Normalized);
  if Result <> '' then Exit;
  ConfigDirPage.Values[0] := Normalized;
  if not ForceDirectories(Normalized) then begin
    Result := CustomMessage('ConfigDirCreate');
    Exit;
  end;
  Probe := NewOwnedTempName(Normalized);
  if not SaveStringToFile(Probe, '', False) then begin
    Result := CustomMessage('ConfigDirWrite');
    Exit;
  end;
  if not DeleteFile(Probe) then Result := CustomMessage('ConfigDirWrite');
end;

procedure SaveStoragePreference;
var
  Folder, Temp, Json: string;
  Raw: AnsiString;
begin
  if ExistingPreferenceValid and
      (CompareText(ConfigDirPage.Values[0], KnownPreviousRoot) = 0) then Exit;
  Folder := ExtractFileDir(StoragePreference);
  if not ForceDirectories(Folder) then RaiseException(CustomMessage('ConfigDirSave'));
  Temp := NewOwnedTempName(Folder);
  Json := '{"SchemaVersion":1,"ProfileRoot":"' + EscapeJson(ConfigDirPage.Values[0]) + '"}' + #13#10;
  Raw := UTF8Encode(#$FEFF + Json);
  try
    if not SaveStringToFile(Temp, Raw, False) then RaiseException(CustomMessage('ConfigDirSave'));
    if FileExists(StoragePreference) and not FileCopy(StoragePreference, StoragePreference + '.bak', False) then
      RaiseException(CustomMessage('ConfigDirSave'));
    if not MoveFileExW(Temp, StoragePreference, $1 or $8) then
      RaiseException(CustomMessage('ConfigDirSave'));
  finally
    if FileExists(Temp) then DeleteFile(Temp);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then SaveStoragePreference;
end;
