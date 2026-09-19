; Installer Inno Setup di Scripta per Windows (un unico Scripta-windows-<arch>-setup.exe).
;
; Non richiede modifiche al progetto: impacchetta il bundle prodotto da
; `flutter build windows --release` (exe + flutter_windows.dll + data/ +
; sqlite3.dll + runtime VC++ copiati dal workflow) in un solo eseguibile.
;
; Parametri (passati da riga di comando a ISCC, vedi windows_release.yml):
;   /DSourceDir=<cartella del bundle Release>   (obbligatorio)
;   /DArch=x64|arm64                            (default x64)
;   /DAppVersion=0.8.2                          (default 0.0.0)
;   /DAppVersionNumeric=0.8.2                   (solo cifre e punti, per le proprietà del file)
;   /DOutDir=<cartella di output>               (default ..\dist)
;
; Installazione per-utente di default (%LOCALAPPDATA%\Programs\Scripta): non
; servono privilegi di amministratore. Chi vuole può scegliere "per tutti gli
; utenti" dalla finestra iniziale.

#ifndef SourceDir
  #error "Definire /DSourceDir=<cartella del bundle Release>"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppVersionNumeric
  #define AppVersionNumeric "0.0.0"
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif

#define AppName "Scripta"
#define AppExe "scripta.exe"

[Setup]
; GUID FISSO: identifica l'app tra un aggiornamento e l'altro (non cambiarlo,
; altrimenti Windows tratterebbe ogni versione come un'app diversa).
AppId={{8D5C2B7A-4E1F-4B6A-9C3D-2F7A1E5B9D40}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Scripta
VersionInfoVersion={#AppVersionNumeric}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutDir}
OutputBaseFilename=Scripta-windows-{#Arch}-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
#if Arch == "arm64"
; Windows ARM64 nativo
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64 (installabile anche su Windows ARM64 tramite emulazione)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
