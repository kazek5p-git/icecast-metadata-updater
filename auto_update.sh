#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$SCRIPT_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONFIG_PATH=""
MANIFEST_URL_OVERRIDE=""
ALLOW_DOWNGRADE_OVERRIDE=""
RELEASE_INFO_PATH=""

print_help() {
  cat <<EOF
Uzycie:
  ./auto_update.sh [--install-dir KATALOG] [--config PLIK] [--manifest-url URL] [--allow-downgrade]

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

read_release_info_field() {
  local path="$1"
  local field="$2"
  [[ -f "$path" ]] || return 0
  python3 - "$path" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    raise SystemExit(0)

value = str(data.get(field, "")).strip()
if value:
    print(value)
PY
}

release_time_not_newer() {
  local current_release_time="$1"
  local latest_release_time="$2"
  python3 - "$current_release_time" "$latest_release_time" <<'PY'
import sys
from datetime import datetime

def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))

try:
    current = parse_iso(sys.argv[1])
    latest = parse_iso(sys.argv[2])
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if latest <= current else 1)
PY
}

write_release_info() {
  local path="$1"
  local version="$2"
  local generated_at="$3"
  python3 - "$path" "$version" "$generated_at" <<'PY'
import json
import sys

path, version, generated_at = sys.argv[1:4]
payload = {
    "version": version,
    "generated_at_utc": generated_at,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
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
    --manifest-url)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --manifest-url" >&2; exit 1; }
      MANIFEST_URL_OVERRIDE="$2"
      shift 2
      ;;
    --allow-downgrade)
      ALLOW_DOWNGRADE_OVERRIDE="1"
      shift
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
RELEASE_INFO_PATH="$INSTALL_DIR/RELEASE_INFO.json"

if [[ ! -f "$CONFIG_PATH" && -z "$MANIFEST_URL_OVERRIDE" ]]; then
  echo "Brak pliku konfiguracji auto-update: $CONFIG_PATH" >&2
  exit 2
fi

require_cmd curl
require_cmd python3
require_cmd tar
require_cmd sha256sum

if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_PATH"
fi

if [[ -n "$MANIFEST_URL_OVERRIDE" ]]; then
  UPDATE_MANIFEST_URL="$MANIFEST_URL_OVERRIDE"
fi

UPDATE_ALLOW_DOWNGRADE="${UPDATE_ALLOW_DOWNGRADE:-0}"
if [[ "$ALLOW_DOWNGRADE_OVERRIDE" == "1" ]]; then
  UPDATE_ALLOW_DOWNGRADE="1"
fi

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
generated_at_utc = str(data.get('generated_at_utc', '')).strip()
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
print(generated_at_utc)
PY
); then
  echo "Nieprawidlowy manifest: $UPDATE_MANIFEST_URL" >&2
  exit 2
fi

if [[ "${#META[@]}" -lt 4 ]]; then
  echo "Nieprawidlowy manifest: brak wymaganych pol" >&2
  exit 2
fi

LATEST_VERSION="${META[0]}"
TARBALL_URL="${META[1]}"
EXPECTED_SHA="${META[2]}"
LATEST_GENERATED_AT_UTC="${META[3]}"

CURRENT_VERSION="unknown"
if [[ -f "$INSTALL_DIR/.installed_version" ]]; then
  CURRENT_VERSION="$(head -n 1 "$INSTALL_DIR/.installed_version" | tr -d '[:space:]')"
fi
CURRENT_RELEASE_VERSION="$(read_release_info_field "$RELEASE_INFO_PATH" version)"
CURRENT_GENERATED_AT_UTC="$(read_release_info_field "$RELEASE_INFO_PATH" generated_at_utc)"
if [[ "$CURRENT_VERSION" == "unknown" && -n "$CURRENT_RELEASE_VERSION" ]]; then
  CURRENT_VERSION="$CURRENT_RELEASE_VERSION"
fi

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
  if [[ -n "$LATEST_GENERATED_AT_UTC" && ! -f "$RELEASE_INFO_PATH" ]]; then
    write_release_info "$RELEASE_INFO_PATH" "$LATEST_VERSION" "$LATEST_GENERATED_AT_UTC"
  fi
  echo "Auto-update: brak zmian (wersja $CURRENT_VERSION)"
  exit 0
fi

if [[ "$UPDATE_ALLOW_DOWNGRADE" != "1" ]] && [[ -n "$CURRENT_GENERATED_AT_UTC" && -n "$LATEST_GENERATED_AT_UTC" ]]; then
  if release_time_not_newer "$CURRENT_GENERATED_AT_UTC" "$LATEST_GENERATED_AT_UTC"; then
    echo "Auto-update: pomijam starsza lub rowna publikacje ($LATEST_VERSION, $LATEST_GENERATED_AT_UTC)"
    echo "Aktualnie zainstalowane: $CURRENT_VERSION ($CURRENT_GENERATED_AT_UTC)"
    exit 0
  fi
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
if [[ -n "$LATEST_GENERATED_AT_UTC" ]]; then
  write_release_info "$RELEASE_INFO_PATH" "$LATEST_VERSION" "$LATEST_GENERATED_AT_UTC"
fi
echo "Auto-update: zakonczono pomyslnie, nowa wersja $LATEST_VERSION"
echo "Zycze dobrej pogody na streamach i w realu."
