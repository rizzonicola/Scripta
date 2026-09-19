# Compila sqlite3.dll dall'amalgamation ufficiale di SQLite per l'architettura
# indicata. Serve a Windows perché sqflite_common_ffi NON include SQLite: se la
# versione di 'sqlite3' risolta da pub non lo porta già nel bundle, l'app
# crasha all'avvio (impossibile caricare sqlite3.dll).
#
# Va eseguito in una shell con l'ambiente MSVC già caricato per l'architettura
# di destinazione (ilammy/msvc-dev-cmd), così 'cl' produce la DLL corretta
# (x64 oppure ARM64, anche in cross-compilazione da un runner x64).
#
# Uso: pwsh tools/windows_sqlite_dll.ps1 -OutDir <cartella> [-Year 2025] [-Version 3500400]
#
# NOTA: Year/Version puntano a un URL di sqlite.org (formato
# https://www.sqlite.org/<anno>/sqlite-amalgamation-<versione>.zip, con la
# versione scritta come MNNPPFF: 3.50.4 -> 3500400). Se sqlite.org non la
# serve più, aggiornare i due valori con una release attuale.
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Year = "2025",
  [string]$Version = "3500400"
)
$ErrorActionPreference = "Stop"

if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
  throw "Compilatore 'cl' non trovato: caricare prima l'ambiente MSVC (ilammy/msvc-dev-cmd)."
}

$work = Join-Path $env:RUNNER_TEMP "sqlite-build"
if (-not $env:RUNNER_TEMP) { $work = Join-Path ([IO.Path]::GetTempPath()) "sqlite-build" }
New-Item -ItemType Directory -Force -Path $work | Out-Null
Push-Location $work
try {
  $url = "https://www.sqlite.org/$Year/sqlite-amalgamation-$Version.zip"
  Write-Host "Scarico $url"
  Invoke-WebRequest -Uri $url -OutFile sqlite.zip
  Expand-Archive -Path sqlite.zip -DestinationPath . -Force
  $src = Get-ChildItem -Recurse -Filter sqlite3.c | Select-Object -First 1
  if (-not $src) { throw "sqlite3.c non trovato nell'archivio scaricato." }

  Push-Location $src.DirectoryName
  # /LD = DLL; SQLITE_API esporta i simboli (sqlite3_open, ...) dalla DLL.
  cl /nologo /O2 /MD /LD sqlite3.c "/DSQLITE_API=__declspec(dllexport)" /DSQLITE_THREADSAFE=1 /DSQLITE_ENABLE_FTS5 /Fe:sqlite3.dll
  if ($LASTEXITCODE -ne 0) { throw "Compilazione di sqlite3.dll fallita." }

  # Mostra l'architettura reale della DLL prodotta (deve combaciare con l'app).
  dumpbin /headers sqlite3.dll | Select-String -Pattern "machine"

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Copy-Item sqlite3.dll -Destination $OutDir -Force
  Pop-Location
  Write-Host "sqlite3.dll copiata in $OutDir"
} finally {
  Pop-Location
}
