#!/usr/bin/env bash
# Build Cloudflare Pages per Scripta Web/PWA.
#
# Cloudflare Pages → Settings → Build:
#   Build command:      bash tool/web/cloudflare_build.sh
#   Build output:       build/web
#   Root directory:     / (root del repository)
#
# Non usa segreti. Se il build image non ha già Flutter 3.44.4, scarica
# l'SDK ufficiale nella cache locale della build e ne verifica il checksum
# PRIMA di estrarre/eseguire qualsiasi binario. FLUTTER_BIN può essere
# impostata (variabile non segreta) per usare un SDK preinstallato.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FLUTTER_VERSION="3.44.4"
FLUTTER_ARCHIVE="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
# SHA-256 dell'archivio ufficiale 3.44.4 (linux stable). Va aggiornato insieme
# a FLUTTER_VERSION: è il confine di fiducia della cache, che altrimenti
# eseguirebbe un SDK scritto da chiunque possa popolare ~/.cache.
FLUTTER_ARCHIVE_SHA256="c853cda0312a162854c481fe6a1bc286d84fbb74bfab7037c39750061dc9b466"

FLUTTER_CACHE_DIR="${SCRIPTA_FLUTTER_CACHE:-$HOME/.cache/scripta-flutter}"
FLUTTER_SDK_DIR="${SCRIPTA_FLUTTER_SDK:-${FLUTTER_CACHE_DIR}/flutter_${FLUTTER_VERSION}}"
FLUTTER_STAMP="${FLUTTER_SDK_DIR}/.scripta-sdk-sha256"

verify_archive() {
  local archive="$1"
  local actual
  actual="$(sha256sum "${archive}" | awk '{print $1}')"
  if [[ "${actual}" != "${FLUTTER_ARCHIVE_SHA256}" ]]; then
    echo "ERRORE: checksum dell'archivio Flutter non valido." >&2
    echo "  atteso:  ${FLUTTER_ARCHIVE_SHA256}" >&2
    echo "  ottenuto: ${actual}" >&2
    return 1
  fi
}

# La cache è attendibile solo se contiene il marcatore scritto dopo aver
# verificato l'archivio. Una directory creata da una versione precedente (o
# manomessa) non ha il marcatore giusto e viene reinstallata.
cached_sdk_is_verified() {
  [[ -x "${FLUTTER_SDK_DIR}/bin/flutter" ]] || return 1
  [[ -f "${FLUTTER_STAMP}" ]] || return 1
  [[ "$(head -n 1 "${FLUTTER_STAMP}")" == "${FLUTTER_ARCHIVE_SHA256}" ]]
}

install_flutter_sdk() {
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "ERRORE: 'sha256sum' non è disponibile nel build image." >&2
    echo "Senza di esso non è possibile verificare l'SDK Flutter scaricato." >&2
    exit 1
  fi

  echo "Flutter ${FLUTTER_VERSION} non trovato o non verificato: download dell'SDK ufficiale..."
  mkdir -p "$(dirname "${FLUTTER_SDK_DIR}")"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  curl -fL --retry 3 --retry-delay 5 \
    -o "${tmp_dir}/flutter.tar.xz" "${FLUTTER_ARCHIVE}"
  verify_archive "${tmp_dir}/flutter.tar.xz"
  tar -xJf "${tmp_dir}/flutter.tar.xz" -C "${tmp_dir}"
  rm -rf "${FLUTTER_SDK_DIR}"
  mv "${tmp_dir}/flutter" "${FLUTTER_SDK_DIR}"
  printf '%s\n' "${FLUTTER_ARCHIVE_SHA256}" > "${FLUTTER_STAMP}"

  trap - EXIT
  rm -rf "${tmp_dir}"
}

flutter_reports_version() {
  local binary="$1"
  [[ -x "${binary}" ]] || return 1
  "${binary}" --version 2>/dev/null | head -n 1 | grep -q "${FLUTTER_VERSION}"
}

# 1. Override esplicito: chi imposta FLUTTER_BIN/SCRIPTA_FLUTTER_SDK si assume
#    la responsabilità dell'SDK fornito. Si verifica comunque la versione.
# 2. Flutter già presente nel build image: è infrastruttura fidata, non una
#    cache scrivibile dal repository.
# 3. Cache locale dello script: accettata solo con marcatore di checksum.
if [[ -n "${FLUTTER_BIN:-}" ]]; then
  if ! flutter_reports_version "${FLUTTER_BIN}"; then
    echo "ERRORE: FLUTTER_BIN non è un Flutter ${FLUTTER_VERSION} eseguibile." >&2
    exit 1
  fi
  FLUTTER="${FLUTTER_BIN}"
  FLUTTER_SDK_DIR="$(cd "$(dirname "${FLUTTER}")/.." && pwd)"
elif [[ -n "${SCRIPTA_FLUTTER_SDK:-}" ]]; then
  FLUTTER="${SCRIPTA_FLUTTER_SDK}/bin/flutter"
  if ! flutter_reports_version "${FLUTTER}"; then
    echo "ERRORE: SCRIPTA_FLUTTER_SDK non contiene Flutter ${FLUTTER_VERSION}." >&2
    exit 1
  fi
elif command -v flutter >/dev/null 2>&1 &&
  flutter_reports_version "$(command -v flutter)"; then
  FLUTTER="$(command -v flutter)"
  FLUTTER_SDK_DIR="$(cd "$(dirname "${FLUTTER}")/.." && pwd)"
else
  if ! cached_sdk_is_verified; then
    install_flutter_sdk
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
