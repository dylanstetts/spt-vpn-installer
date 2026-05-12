; SptVpnSetup.iss - Inno Setup script for the SPT-VPN client installer.
;
; Build with: client\build.ps1 (wraps ISCC.exe with the required defines)
;
; Produces: dist\SptVpnSetup.exe
;
; The installer:
;   1. Auto-detects EFT and any existing SPT install.
;   2. Asks for setup mode (first-time install vs custom component pick).
;   3. Asks for the SPT install directory (default = autodetected or
;      {autopf}\SPT) and, if VPN/Mods are selected, the invite token.
;   4. Stages install.ps1 + sync-mods.ps1 + _pin.ps1 + 7zr.exe in {tmp}.
;   5. Runs install.ps1 elevated with -Components flag.
;
; The enrollment URL + pinned cert fingerprint are baked in at build time
; via #define.

#define MyAppName "SPT-VPN Setup"
#define MyAppVersion "0.3.2"
#define MyAppPublisher "Self-hosted SPT"

; -------- BUILD-TIME CONFIG (override on the ISCC command line) ------------
#ifndef EnrollUrl
  #define EnrollUrl "https://20.115.55.17"
#endif
#ifndef EnrollFingerprint
  #define EnrollFingerprint "REPLACE_WITH_SHA256"
#endif
#ifndef SptHostVpnIp
  #define SptHostVpnIp "10.8.0.2"
#endif

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={code:DefaultInstallDir}
DefaultGroupName=SPT
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir=dist
OutputBaseFilename=SptVpnSetup
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
UninstallDisplayName={#MyAppName}
UninstallFilesDir={app}\uninst-spt-vpn

[Files]
Source: "install.ps1";   DestDir: "{tmp}"; Flags: dontcopy
Source: "sync-mods.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "_pin.ps1";      DestDir: "{tmp}"; Flags: dontcopy
; 7zr.exe is optional - only required for mods distributed as .7z.
; The script gracefully errors if a .7z mod is encountered without it.
Source: "7zr.exe";       DestDir: "{tmp}"; Flags: dontcopy skipifsourcedoesntexist

[Code]
var
  EftWarnPage:     TOutputMsgWizardPage;
  ModeSelectPage:  TInputOptionWizardPage;
  ComponentsPage:  TInputOptionWizardPage;
  TokenPage:       TInputQueryWizardPage;
  HasEft:          Boolean;
  AutodetectedSpt: String;

function TryRegPath(RootKey: Integer; const SubKey, ValueName: String; var Path: String): Boolean;
var
  V: String;
begin
  Result := False;
  if RegQueryStringValue(RootKey, SubKey, ValueName, V) and (V <> '') then begin
    Path := V;
    Result := True;
  end;
end;

function LooksLikeEftFolder(const P: String): Boolean;
begin
  Result := (P <> '') and DirExists(P) and
            (FileExists(AddBackslash(P) + 'EscapeFromTarkov.exe') or
             DirExists(AddBackslash(P) + 'EscapeFromTarkov_Data'));
end;

function LooksLikeSptFolder(const P: String): Boolean;
var
  B: String;
begin
  Result := False;
  if (P = '') or (not DirExists(P)) then Exit;
  B := AddBackslash(P);
  // SPT.Launcher.exe at root or under \SPT\
  if not (FileExists(B + 'SPT.Launcher.exe') or
          FileExists(B + 'SPT\SPT.Launcher.exe')) then Exit;
  // BepInEx folder at root or under \SPT\
  if not (DirExists(B + 'BepInEx') or
          DirExists(B + 'SPT\BepInEx')) then Exit;
  // mods directory somewhere reasonable
  if (DirExists(B + 'user\mods') or
      DirExists(B + 'SPT\user\mods') or
      DirExists(B + 'BepInEx\plugins')) then
    Result := True;
end;

function FindSptInstall(): String;
var
  DriveIdx, i: Integer;
  Subdirs: TArrayOfString;
  Candidate: String;
begin
  Result := '';
  SetArrayLength(Subdirs, 6);
  Subdirs[0] := 'SPT';
  Subdirs[1] := 'SPT-AKI';
  Subdirs[2] := 'Games\SPT';
  Subdirs[3] := 'Program Files\SPT';
  Subdirs[4] := 'Program Files (x86)\SPT';
  Subdirs[5] := 'SPTarkov';
  for DriveIdx := Ord('C') to Ord('Z') do begin
    for i := 0 to GetArrayLength(Subdirs) - 1 do begin
      Candidate := Chr(DriveIdx) + ':\' + Subdirs[i];
      if LooksLikeSptFolder(Candidate) then begin
        Result := Candidate;
        Exit;
      end;
    end;
  end;
end;

function FindEftInstall(): String;
var
  Path: String;
  DriveIdx: Integer;
  Candidate: String;
  Subdirs: TArrayOfString;
  i: Integer;
begin
  Result := '';

  // Registry locations used by various BSG launcher versions.
  if TryRegPath(HKLM, 'SOFTWARE\Battlestate Games\EFT\Client', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\WOW6432Node\Battlestate Games\EFT\Client', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\Battlestate Games\EFT', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\WOW6432Node\Battlestate Games\EFT', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKCU, 'SOFTWARE\Battlestate Games\EFT\Client', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKCU, 'SOFTWARE\Battlestate Games\EFT', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\Battlestate Games\BsgLauncher', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\WOW6432Node\Battlestate Games\BsgLauncher', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;

  // Uninstall key (BSG launcher writes one of these).
  if TryRegPath(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EscapeFromTarkov', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;
  if TryRegPath(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\EscapeFromTarkov', 'InstallLocation', Path) and LooksLikeEftFolder(Path) then begin Result := Path; Exit; end;

  // Filesystem heuristics - scan common locations on every fixed drive.
  SetArrayLength(Subdirs, 7);
  Subdirs[0] := 'Battlestate Games\EFT';
  Subdirs[1] := 'Program Files\Battlestate Games\EFT';
  Subdirs[2] := 'Program Files (x86)\Battlestate Games\EFT';
  Subdirs[3] := 'Games\EFT';
  Subdirs[4] := 'Games\Escape From Tarkov';
  Subdirs[5] := 'EFT';
  Subdirs[6] := 'Escape From Tarkov';
  for DriveIdx := Ord('C') to Ord('Z') do begin
    for i := 0 to GetArrayLength(Subdirs) - 1 do begin
      Candidate := Chr(DriveIdx) + ':\' + Subdirs[i];
      if LooksLikeEftFolder(Candidate) then begin
        Result := Candidate;
        Exit;
      end;
    end;
  end;
end;

// {code:DefaultInstallDir} - used by DefaultDirName.
function DefaultInstallDir(Param: String): String;
begin
  if AutodetectedSpt <> '' then
    Result := AutodetectedSpt
  else
    Result := ExpandConstant('{autopf}') + '\SPT';
end;

function ModeFirstTime(): Boolean;
begin
  Result := (ModeSelectPage <> nil) and (ModeSelectPage.SelectedValueIndex = 0);
end;

function HasComponent(const Name: String): Boolean;
begin
  Result := False;
  if ComponentsPage = nil then Exit;
  if ModeFirstTime() then begin
    Result := True;
    Exit;
  end;
  if Name = 'VPN'  then Result := ComponentsPage.Values[0];
  if Name = 'SPT'  then Result := ComponentsPage.Values[1];
  if Name = 'Fika' then Result := ComponentsPage.Values[2];
  if Name = 'Mods' then Result := ComponentsPage.Values[3];
end;

function NeedsToken(): Boolean;
begin
  // The invite token is only meaningful for VPN enrollment. Mod sync
  // reuses the same token when VPN is also selected; if the user picks
  // Mods without VPN we let install.ps1 surface that as an error.
  Result := HasComponent('VPN');
end;

function GetSelectedComponents(): String;
var
  Parts: String;
begin
  Parts := '';
  if HasComponent('VPN')  then Parts := Parts + 'VPN,';
  if HasComponent('SPT')  then Parts := Parts + 'SPT,';
  if HasComponent('Fika') then Parts := Parts + 'Fika,';
  if HasComponent('Mods') then Parts := Parts + 'Mods,';
  if Length(Parts) > 0 then
    Parts := Copy(Parts, 1, Length(Parts) - 1);
  Result := Parts;
end;

procedure InitializeWizard;
var
  EftPath: String;
begin
  AutodetectedSpt := FindSptInstall();

  EftPath := FindEftInstall();
  HasEft := EftPath <> '';

  if not HasEft then begin
    EftWarnPage := CreateOutputMsgPage(wpWelcome,
      'Escape From Tarkov not auto-detected',
      'Setup could not auto-detect Escape From Tarkov on this PC.',
      'A legitimate EFT install is required - SPT and Fika clone files from your existing EFT install ' +
      'and cannot work without it. No EFT files are downloaded from the server.'#13#10#13#10 +
      'Setup looked in the usual registry keys and common install paths but found nothing.'#13#10#13#10 +
      'If you DO have EFT installed (e.g. in a non-standard folder, or the BSG launcher has never been ' +
      'run on this account), you can continue anyway - the SPT/Fika installers that run later will ask you ' +
      'to point at your EFT folder.'#13#10#13#10 +
      'Click Next to continue. If you genuinely don''t have EFT installed, Cancel and install it first via:'#13#10 +
      '    https://www.escapefromtarkov.com/launcher');
  end;

  // Setup mode page (first-time install vs custom).
  ModeSelectPage := CreateInputOptionPage(wpWelcome,
    'Setup mode',
    'Choose how much of the SPT + Fika + VPN stack to install',
    'Pick "First-time install" to run everything: WireGuard VPN, SPT, Fika, and mod sync. ' +
    'Pick "Custom" to choose individual components on the next page.',
    True, False);
  ModeSelectPage.Add('&First-time install (VPN + SPT + Fika + Mods)');
  ModeSelectPage.Add('&Custom (choose components)');
  ModeSelectPage.SelectedValueIndex := 0;

  // Component selection page (only used when "Custom" mode is chosen).
  ComponentsPage := CreateInputOptionPage(ModeSelectPage.ID,
    'Choose components',
    'Select which components to install',
    'Tick any combination. Fika requires a valid SPT installation (existing or being installed now); ' +
    'mod sync requires the VPN invite token. The SPT folder is configured on the next page.',
    False, False);
  ComponentsPage.Add('&VPN  (WireGuard tunnel + enrollment)');
  ComponentsPage.Add('&SPT  (download + run SPTInstaller.exe)');
  ComponentsPage.Add('Fi&ka (run Fika-Installer.exe)');
  ComponentsPage.Add('&Mods (sync mods from server manifest)');
  ComponentsPage.Values[0] := True;
  ComponentsPage.Values[1] := True;
  ComponentsPage.Values[2] := True;
  ComponentsPage.Values[3] := True;

  TokenPage := CreateInputQueryPage(wpSelectDir,
    'Server invite',
    'Enter the invite token your server admin gave you',
    'This token enrolls your machine on the SPT VPN. It is single-use ' +
    'and tied to this computer. Only required when the VPN component is selected.');
  TokenPage.Add('Invite token:', False);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  // Skip per-component page in first-time mode.
  if (ComponentsPage <> nil) and (PageID = ComponentsPage.ID) and ModeFirstTime() then
    Result := True;
  // Skip token page if neither VPN nor Mods are selected.
  if (TokenPage <> nil) and (PageID = TokenPage.ID) and (not NeedsToken()) then
    Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (EftWarnPage <> nil) and (CurPageID = EftWarnPage.ID) and (not HasEft) then begin
    if MsgBox('EFT was not auto-detected. Continue anyway?' + #13#10 + #13#10 +
              'Choose Yes only if you''re certain EFT is installed. The SPT/Fika installers will prompt you ' +
              'to point at your EFT folder.',
              mbConfirmation, MB_YESNO) = IDNO then begin
      Result := False;
      Exit;
    end;
  end;
  if (ComponentsPage <> nil) and (CurPageID = ComponentsPage.ID) then begin
    if (not HasComponent('VPN')) and (not HasComponent('SPT')) and
       (not HasComponent('Fika')) and (not HasComponent('Mods')) then begin
      MsgBox('Select at least one component.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if HasComponent('Fika') and (not HasComponent('SPT')) and
       (not LooksLikeSptFolder(WizardDirValue())) then begin
      if MsgBox('Fika is selected but SPT is not, and no valid SPT installation was found at:' + #13#10 +
                '    ' + WizardDirValue() + #13#10 + #13#10 +
                'Fika install will fail without SPT. Continue anyway?',
                mbConfirmation, MB_YESNO) = IDNO then begin
        Result := False;
        Exit;
      end;
    end;
    if HasComponent('Mods') and (not HasComponent('VPN')) then begin
      if MsgBox('Mods is selected but VPN is not. Mod sync requires the invite token, ' +
                'which is only collected when VPN is selected. Without it, mod sync will fail.' + #13#10 + #13#10 +
                'Continue anyway?',
                mbConfirmation, MB_YESNO) = IDNO then begin
        Result := False;
        Exit;
      end;
    end;
  end;
  if (TokenPage <> nil) and (CurPageID = TokenPage.ID) and NeedsToken() then begin
    if Trim(TokenPage.Values[0]) = '' then begin
      MsgBox('Please paste the invite token (required for the VPN component).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function GetToken(Param: string): string;
begin
  if (TokenPage <> nil) and NeedsToken() then
    Result := Trim(TokenPage.Values[0])
  else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PsScript, Cmd, Token, Components: string;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;

  ExtractTemporaryFile('install.ps1');
  ExtractTemporaryFile('sync-mods.ps1');
  ExtractTemporaryFile('_pin.ps1');
  // 7zr.exe may not be shipped; ignore extraction failure.
  try
    ExtractTemporaryFile('7zr.exe');
  except
  end;

  PsScript   := ExpandConstant('{tmp}\install.ps1');
  Token      := GetToken('');
  Components := GetSelectedComponents();

  Cmd :=
    '-NoProfile -ExecutionPolicy Bypass -File "' + PsScript + '"' +
    ' -EnrollUrl "{#EnrollUrl}"' +
    ' -EnrollFingerprint "{#EnrollFingerprint}"' +
    ' -SptHostVpnIp "{#SptHostVpnIp}"' +
    ' -InviteToken "' + Token + '"' +
    ' -Components "' + Components + '"' +
    ' -InstallDir "' + ExpandConstant('{app}') + '"';

  if not Exec('powershell.exe', Cmd, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then begin
    MsgBox('Failed to launch PowerShell: ' + SysErrorMessage(ResultCode),
           mbError, MB_OK);
  end else if ResultCode <> 0 then begin
    MsgBox('Setup script returned exit code ' + IntToStr(ResultCode) + #13#10 +
           'See %ProgramData%\spt-vpn\install.log for details.',
           mbError, MB_OK);
  end;
end;

[Icons]
Name: "{group}\SPT Launcher"; Filename: "{app}\SPT\SPT.Launcher.exe"; WorkingDir: "{app}\SPT"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "C:\Program Files\WireGuard\wireguard.exe"; \
    Parameters: "/uninstalltunnelservice spt-vpn"; \
    Flags: runhidden; RunOnceId: "RemoveSptVpnTunnel"
