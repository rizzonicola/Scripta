#!/usr/bin/env bash
# Build Cloudflare Pages per Scripta Web/PWA.
#
# Cloudflare Pages → Settings → Build:
#   Build command:      bash tool/web/cloudflare_build.sh
#   Build output:       build/web
#   Root directory:     / (root del repository)
#
# Non usa segreti. Se il build image non ha già Flutter 3.44.4, scarica
# l'SDK ufficiale nella cache locale della build. FLUTTER_BIN può essere
# impostata (variabile non segreta) per usare un SDK preinstallato.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FLUTTER_VERSION="3.44.4"
FLUTTER_ARCHIVE="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_SDK_DIR="${SCRIPTA_FLUTTER_SDK:-$HOME/.cache/scripta-flutter/flutter_${FLUTTER_VERSION}}"

resolve_flutter() {
  if [[ -n "${FLUTTER_BIN:-}" && -x "${FLUTTER_BIN}" ]]; then
    echo "${FLUTTER_BIN}"
    return 0
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi
  return 1
}

FLUTTER="$(resolve_flutter || true)"
if [[ -n "${FLUTTER}" ]] && "${FLUTTER}" --version 2>/dev/null | head -n 1 | grep -q "${FLUTTER_VERSION}"; then
  FLUTTER_SDK_DIR="$(cd "$(dirname "${FLUTTER}")/.." && pwd)"
else
  if [[ ! -x "${FLUTTER_SDK_DIR}/bin/flutter" ]]; then
    echo "Flutter ${FLUTTER_VERSION} non trovato: download dell'SDK ufficiale..."
    mkdir -p "$(dirname "${FLUTTER_SDK_DIR}")"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT
    curl -fL --retry 3 --retry-delay 5 \
      -o "${TMP_DIR}/flutter.tar.xz" "${FLUTTER_ARCHIVE}"
    tar -xJf "${TMP_DIR}/flutter.tar.xz" -C "${TMP_DIR}"
    rm -rf "${FLUTTER_SDK_DIR}"
    mv "${TMP_DIR}/flutter" "${FLUTTER_SDK_DIR}"
    trap - EXIT
    rm -rf "${TMP_DIR}"
  fi
  FLUTTER="${FLUTTER_SDK_DIR}/bin/flutter"
fi

export PATH="${FLUTTER_SDK_DIR}/bin:${PATH}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true

echo "Flutter: $("${FLUTTER}" --version | head -n 1)"
echo "Dart:    $("${FLUTTER_SDK_DIR}/bin/dart" --version)"

if ! command -v unzip >/dev/null 2>&1; then
  echo "ERRORE: 'unzip' non è disponibile nel build image." >&2
  echo "Cloudflare Pages richiede unzip per scaricare il Web SDK di Flutter." >&2
  exit 1
fi

"${FLUTTER}" --disable-analytics >/dev/null 2>&1 || true
"${FLUTTER}" pub get --enforce-lockfile
"${FLUTTER}" precache --web

"${FLUTTER_SDK_DIR}/bin/dart" run tool/web/build_web.dart \
  --flutter "${FLUTTER}" \
  --base-href "/"

echo "Build completata: ${ROOT}/build/web"
