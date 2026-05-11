; SptVpnSetup.iss - Inno Setup script for the SPT-VPN client installer.
;
; Build with: client\build.ps1 (wraps ISCC.exe with the required defines)
;
; Produces: dist\SptVpnSetup.exe
;
; The installer:
;   1. Checks for a legit EFT install (registry + filesystem heuristics).
;   2. Asks for the SPT install directory and the invite token.
;   3. Stages install.ps1 + sync-mods.ps1 + _pin.ps1 + 7zr.exe in {tmp}.
;   4. Runs install.ps1 elevated.
;
; The enrollment URL + pinned cert fingerprint are baked in at build time
; via #define.

#define MyAppName "SPT-VPN Setup"
#define MyAppVersion "0.2.1"
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
DefaultDirName={autopf}\SPT
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
  EftWarnPage: TOutputMsgWizardPage;
  TokenPage:   TInputQueryWizardPage;
  HasEft:      Boolean;

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

procedure InitializeWizard;
var
  EftPath: String;
begin
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
      'run on this account), you can continue anyway - the Fika-Installer that runs next will ask you ' +
      'to point at your EFT folder.'#13#10#13#10 +
      'Click Next to continue. If you genuinely don''t have EFT installed, Cancel and install it first via:'#13#10 +
      '    https://www.escapefromtarkov.com/launcher');
  end;

  TokenPage := CreateInputQueryPage(wpSelectDir,
    'Server invite',
    'Enter the invite token your server admin gave you',
    'This token enrolls your machine on the SPT VPN. It is single-use ' +
    'and tied to this computer.');
  TokenPage.Add('Invite token:', False);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (EftWarnPage <> nil) and (CurPageID = EftWarnPage.ID) and (not HasEft) then begin
    if MsgBox('EFT was not auto-detected. Continue anyway?' + #13#10 + #13#10 +
              'Choose Yes only if you''re certain EFT is installed. The Fika-Installer will prompt you ' +
              'to point at your EFT folder.',
              mbConfirmation, MB_YESNO) = IDNO then begin
      Result := False;
      Exit;
    end;
  end;
  if CurPageID = TokenPage.ID then begin
    if Trim(TokenPage.Values[0]) = '' then begin
      MsgBox('Please paste the invite token.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function GetToken(Param: string): string;
begin
  Result := Trim(TokenPage.Values[0]);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PsScript, Cmd, Token: string;
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

  PsScript := ExpandConstant('{tmp}\install.ps1');
  Token    := GetToken('');

  Cmd :=
    '-NoProfile -ExecutionPolicy Bypass -File "' + PsScript + '"' +
    ' -EnrollUrl "{#EnrollUrl}"' +
    ' -EnrollFingerprint "{#EnrollFingerprint}"' +
    ' -SptHostVpnIp "{#SptHostVpnIp}"' +
    ' -InviteToken "' + Token + '"' +
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
