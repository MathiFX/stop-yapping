[Setup]
AppId={{F869DE14-DA00-4D18-9CA6-4FED251958FB}
AppName=Stop Yapping
AppVersion={#ReleaseVersion}
AppPublisher=Stop Yapping
DefaultDirName={localappdata}\Programs\Stop Yapping
DisableDirPage=yes
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\StopYapping.exe
UninstallDisplayName=Stop Yapping
PrivilegesRequired=lowest
SetupArchitecture=x64
MinVersion=10.0.22000
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
AppMutex=Local\StopYapping
CloseApplications=no
OutputDir={#OutputFolder}
OutputBaseFilename=StopYapping-Setup-x64
WizardStyle=modern dynamic windows11
#ifdef SignRelease
SignTool=release
SignedUninstaller=yes
SignedUninstallerDir={#SigningFolder}
#endif
DisableWelcomePage=no
SetupIconFile=..\src\StopYapping\stop-yapping.ico
WizardImageFile=Assets\wizard-light.png
WizardImageFileDynamicDark=Assets\wizard-dark.png
WizardSmallImageFile=Assets\stop-yapping.png
WizardSmallImageFileDynamicDark=Assets\stop-yapping.png
InfoBeforeFile=Setup-Notes.txt
Compression=lzma2/fast
SolidCompression=yes

[Tasks]
Name: "startup"; Description: "Start Stop Yapping when I sign in"

[Files]
Source: "{#DriverFolder}\*"; DestDir: "{tmp}\VB-CABLE"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#AppFolder}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Stop Yapping"; Filename: "{app}\StopYapping.exe"; Parameters: "--settings"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Stop Yapping"; ValueData: """{app}\StopYapping.exe"""; Tasks: startup; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Stop Yapping"; Tasks: not startup; Flags: deletevalue

[Run]
Filename: "{app}\StopYapping.exe"; Parameters: "--settings"; Description: "Open Stop Yapping settings"; Flags: postinstall nowait skipifsilent

[Messages]
WelcomeLabel1=Stop Yapping
WelcomeLabel2=Silence your call mic while you dictate with Vowen.
FinishedHeadingLabel=You're all set

[UninstallDelete]
Type: files; Name: "{localappdata}\StopYapping\settings.json"
Type: files; Name: "{localappdata}\StopYapping\settings.json.tmp"
Type: dirifempty; Name: "{localappdata}\StopYapping"

[Code]
function CableInstalled: Boolean;
begin
  Result := RegKeyExists(HKLM64, 'SYSTEM\CurrentControlSet\Services\VBAudioVACMME');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  DriverDirectory, DriverSetup: String;
  ResultCode: Integer;
begin
  Result := '';
  if CableInstalled then
    Exit;

  if WizardSilent then begin
    Result := 'Run Setup interactively the first time so you can approve the VB-Audio driver.';
    Exit;
  end;

  ExtractTemporaryFiles('{tmp}\VB-CABLE\*');
  DriverDirectory := ExpandConstant('{tmp}\VB-CABLE');
  DriverSetup := DriverDirectory + '\VBCABLE_Setup_x64.exe';
  if CompareText(GetSHA256OfFile(DriverSetup), '{#DriverSetupSha256}') <> 0 then begin
    Result := 'The included VB-Audio installer could not be verified.';
    Exit;
  end;
  if not ShellExec('runas', DriverSetup, '', DriverDirectory, SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then begin
    Result := 'Windows could not start the VB-Audio installer. ' + SysErrorMessage(ResultCode);
    Exit;
  end;
  if not CableInstalled then begin
    Result := 'VB-CABLE is not installed yet. If its setup asked for a restart, restart Windows and open this installer again.';
    Exit;
  end;
  MsgBox('VB-CABLE is installed. Restart Windows when you are ready. Before setting up your call apps, check that your regular microphone and headphones are still the Windows defaults.', mbInformation, MB_OK);
end;
