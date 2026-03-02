#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$SCRIPT_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONFIG_PATH=""
DEFAULT_SIGNING_PUBLIC_KEY_PEM="$(cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAnpQJ54tJH9aqvshmNu/X
IT60xtkZ1iTNYq+JtV4MmADRsJf5Y/WYMZUn65ngrdcdnOQDFti4Qomw0PJ9LLNO
1RxrkOaBQ26PCtUdJzdB+EYrHpD5ixiTVR6auDLyZ27efy7iOcQ0tNIJztQOGL1n
tEI2RcE+t813WVW/XN8AZlIpzRaOHRmpUi91C8IIBoGXcSPJYPfFDHMju2cJkKkW
SefGATP4JbqG/78kRiZHxG7+7HOZSziLJmM+ri+5ABbrrL1mRaHnMFs+SYsH0cDe
zHVovTovi6fr9y3cclKaysnxMxx/G6jLkYaSQ16CQiyZpE1wAQL9yB3Hu15joFjA
otZAfAC8G4EZsaJzJKn3E7J3A3sNAzAvEkTgfqn1nVDeeJeVDNsVomfp/Swqd3ah
yKPwcoVDQ8D/ILwAbR2PxyhFv9h0zwvjO13SfVwUZrhr+eXoRaoy2w9XRwGUKfQF
efbmVifkHNtW9YyT+YV47bWL3SDu9W2dkBfaJ2J7Z+pvAgMBAAE=
-----END PUBLIC KEY-----
EOF
)"

print_help() {
  cat <<EOF
Uzycie:
  ./auto_update.sh [--install-dir KATALOG] [--config PLIK]

Domyslnie config jest czytany z:
  <install-dir>/auto_update.conf
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --install-dir" >&2; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --config)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --config" >&2; exit 1; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Nieznana opcja: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

if [[ -z "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$INSTALL_DIR/auto_update.conf"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Brak pliku konfiguracji auto-update: $CONFIG_PATH" >&2
  exit 2
fi

require_cmd curl
require_cmd python3
require_cmd tar
require_cmd sha256sum

# shellcheck source=/dev/null
source "$CONFIG_PATH"

ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
SIGNING_PUBLIC_KEY_PATH="${SIGNING_PUBLIC_KEY_PATH:-}"

if [[ -z "${UPDATE_MANIFEST_URL:-}" ]]; then
  echo "Brak UPDATE_MANIFEST_URL w $CONFIG_PATH" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

MANIFEST_PATH="$TMP_DIR/latest.json"
curl -fsSL "$UPDATE_MANIFEST_URL" -o "$MANIFEST_PATH"

if ! readarray -t META < <(
  python3 - "$MANIFEST_PATH" "$UPDATE_MANIFEST_URL" <<'PY'
import json, sys
from urllib.parse import urljoin

manifest_path = sys.argv[1]
manifest_url = sys.argv[2]
with open(manifest_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

version = str(data.get('version', '')).strip()
sha256 = str(data.get('sha256', '')).strip().lower()
tarball_url = str(data.get('tarball_url', '')).strip()
signature = str(data.get('signature', '')).strip()
signature_algo = str(data.get('signature_algo', '')).strip().lower()
signature_required = bool(data.get('signature_required', False))
if not tarball_url:
    tarball = str(data.get('tarball', '')).strip()
    if tarball:
        tarball_url = urljoin(manifest_url, tarball)

if not version:
    raise SystemExit('Manifest bez pola version')
if not tarball_url:
    raise SystemExit('Manifest bez pola tarball_url lub tarball')
if not sha256:
    raise SystemExit('Manifest bez pola sha256')

print(version)
print(tarball_url)
print(sha256)
print(signature)
print(signature_algo)
print('1' if signature_required else '0')
PY
); then
  echo "Nieprawidlowy manifest: $UPDATE_MANIFEST_URL" >&2
  exit 2
fi

if [[ "${#META[@]}" -lt 6 ]]; then
  echo "Nieprawidlowy manifest: brak wymaganych pol" >&2
  exit 2
fi

LATEST_VERSION="${META[0]}"
TARBALL_URL="${META[1]}"
EXPECTED_SHA="${META[2]}"
MANIFEST_SIGNATURE="${META[3]}"
MANIFEST_SIGNATURE_ALGO="${META[4]}"
MANIFEST_SIGNATURE_REQUIRED="${META[5]}"

CURRENT_VERSION="unknown"
if [[ -f "$INSTALL_DIR/.installed_version" ]]; then
  CURRENT_VERSION="$(head -n 1 "$INSTALL_DIR/.installed_version" | tr -d '[:space:]')"
fi

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
  echo "Auto-update: brak zmian (wersja $CURRENT_VERSION)"
  exit 0
fi

echo "Auto-update: aktualizacja $CURRENT_VERSION -> $LATEST_VERSION"

ARCHIVE_PATH="$TMP_DIR/update.tar.gz"
curl -fsSL "$TARBALL_URL" -o "$ARCHIVE_PATH"

ACTUAL_SHA="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "Bledna suma SHA256 paczki" >&2
  echo "Oczekiwano: $EXPECTED_SHA" >&2
  echo "Otrzymano : $ACTUAL_SHA" >&2
  exit 3
fi

if [[ -n "$MANIFEST_SIGNATURE" ]]; then
  if [[ "$MANIFEST_SIGNATURE_ALGO" != "rsa-sha256" ]]; then
    echo "Nieobslugiwany algorytm podpisu: $MANIFEST_SIGNATURE_ALGO" >&2
    exit 5
  fi

  require_cmd openssl
  SIGNATURE_PATH="$TMP_DIR/update.sig"
  PUBKEY_PATH="$TMP_DIR/updater_signing_public.pem"

  python3 - "$MANIFEST_SIGNATURE" "$SIGNATURE_PATH" <<'PY'
import base64
import sys

signature_b64 = sys.argv[1].strip()
out_path = sys.argv[2]
try:
    raw = base64.b64decode(signature_b64, validate=True)
except Exception as exc:
    raise SystemExit(f"Nieprawidlowy podpis base64 w manifescie: {exc}")

with open(out_path, "wb") as f:
    f.write(raw)
PY

  if [[ -n "$SIGNING_PUBLIC_KEY_PATH" ]]; then
    if [[ ! -f "$SIGNING_PUBLIC_KEY_PATH" ]]; then
      echo "Brak pliku klucza publicznego: $SIGNING_PUBLIC_KEY_PATH" >&2
      exit 5
    fi
    cp -f "$SIGNING_PUBLIC_KEY_PATH" "$PUBKEY_PATH"
  elif [[ -f "$INSTALL_DIR/signing/updater_signing_public.pem" ]]; then
    cp -f "$INSTALL_DIR/signing/updater_signing_public.pem" "$PUBKEY_PATH"
  else
    printf '%s\n' "$DEFAULT_SIGNING_PUBLIC_KEY_PEM" > "$PUBKEY_PATH"
  fi

  if ! openssl dgst -sha256 -verify "$PUBKEY_PATH" -signature "$SIGNATURE_PATH" "$ARCHIVE_PATH" >/dev/null 2>&1; then
    echo "Blad weryfikacji podpisu paczki" >&2
    exit 5
  fi
  echo "Auto-update: podpis paczki OK"
else
  if [[ "$MANIFEST_SIGNATURE_REQUIRED" == "1" && "$ALLOW_UNSIGNED" -ne 1 ]]; then
    echo "Manifest wymaga podpisu paczki, ale pole signature jest puste." >&2
    exit 5
  fi
  if [[ "$ALLOW_UNSIGNED" -eq 1 ]]; then
    echo "Auto-update: pomijam podpis (ALLOW_UNSIGNED=1)"
  else
    echo "Auto-update: manifest bez podpisu cyfrowego (kontynuacja z sama kontrola SHA256)."
  fi
fi

EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

PKG_DIR=""
for d in "$EXTRACT_DIR"/*; do
  if [[ -d "$d" && -x "$d/update.sh" ]]; then
    PKG_DIR="$d"
    break
  fi
done

if [[ -z "$PKG_DIR" ]]; then
  echo "Nie znaleziono update.sh w paczce" >&2
  exit 4
fi

"$PKG_DIR/update.sh" --install-dir "$INSTALL_DIR"

echo "$LATEST_VERSION" > "$INSTALL_DIR/.installed_version"
echo "Auto-update: zakonczono pomyslnie, nowa wersja $LATEST_VERSION"
echo "Zycze dobrej pogody na streamach i w realu."
