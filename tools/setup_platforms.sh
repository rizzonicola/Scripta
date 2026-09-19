#!/usr/bin/env bash
# Genera (se mancanti) le cartelle di piattaforma ios/, macos/, windows/ e
# applica le personalizzazioni di Scripta. IDEMPOTENTE: si può rilanciare
# senza effetti collaterali (le cartelle già presenti non vengono ricreate,
# le patch riconoscono se sono già applicate).
#
# Uso:  bash tools/setup_platforms.sh [ios] [macos] [windows] [all]
#       (senza argomenti = all)
#
# Richiede: Flutter SDK nel PATH, python3 (con Pillow per le icone).
# Dopo l'esecuzione conviene fare il commit di ios/ macos/ windows/: i
# workflow GitHub lanciano comunque questo script, ma con le cartelle già
# committate lo step di generazione viene saltato.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PLATFORMS=("$@")
if [ ${#PLATFORMS[@]} -eq 0 ] || [ "${PLATFORMS[0]}" = "all" ]; then
  PLATFORMS=(ios macos windows)
fi

# --- 1) Quali piattaforme mancano? ------------------------------------------
MISSING=()
for p in "${PLATFORMS[@]}"; do
  if [ ! -d "$ROOT/$p" ]; then MISSING+=("$p"); fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  CSV="$(IFS=,; echo "${MISSING[*]}")"
  echo ">> Genero le piattaforme mancanti: $CSV"

  # Rete di sicurezza: 'flutter create' su un progetto esistente NON dovrebbe
  # sovrascrivere nulla, ma il codice esistente (lib/, pubspec.yaml,
  # android/, linux/, test/, assets/) è prezioso (es. la correzione in
  # markdown_rendered_view.dart): lo salviamo e lo ripristiniamo se cambia.
  BACKUP="$(mktemp -d)"
  PROTECTED=(lib pubspec.yaml android linux test assets l10n.yaml analysis_options.yaml)
  for f in "${PROTECTED[@]}"; do
    [ -e "$ROOT/$f" ] && cp -a "$ROOT/$f" "$BACKUP/"
  done

  # --org + --project-name => bundle id io.github.scripta (come Android).
  flutter create --platforms="$CSV" --org io.github --project-name scripta .

  for f in "${PROTECTED[@]}"; do
    if [ -e "$BACKUP/$f" ]; then
      if ! diff -rq "$BACKUP/$f" "$ROOT/$f" >/dev/null 2>&1; then
        echo "!! flutter create ha modificato '$f': ripristino l'originale."
        rm -rf "$ROOT/$f"
        cp -a "$BACKUP/$f" "$ROOT/$f"
      fi
    fi
  done
  rm -rf "$BACKUP"
else
  echo ">> Cartelle già presenti (${PLATFORMS[*]}): salto 'flutter create'."
fi

# --- 2) Patch mirate (nomi, entitlement, target minimi) ---------------------
python3 "$ROOT/tools/patch_platforms.py" "${PLATFORMS[@]}"

# --- 3) Icone da assets/icons ------------------------------------------------
python3 "$ROOT/tools/generate_icons.py" "${PLATFORMS[@]}"

echo ">> Fatto."
