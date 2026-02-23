#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MANIFEST_URL="https://kazpar.pl/icecast-updater/latest.json"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"

MANIFEST_URL="$DEFAULT_MANIFEST_URL"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
RUN_WIZARD=1
WIZARD_NO_TEST=0
ASSUME_YES=0

print_help() {
  cat <<EOF
Uzycie:
  ./install_online.sh [opcje]

Opcje:
  --manifest-url URL      URL do latest.json (domyslnie: $DEFAULT_MANIFEST_URL)
  --install-dir KATALOG   Katalog instalacji (domyslnie: $DEFAULT_INSTALL_DIR)
  --no-wizard             Nie uruchamiaj kreatora config_wizard.py po instalacji
  --wizard-no-test        Przy uruchomieniu kreatora pomin test status-json.xsl
  --yes                   Bez pytan potwierdzajacych (tryb automatyczny)
  -h, --help              Pomoc

Przyklad:
  curl -fsSL https://kazpar.pl/icecast-updater/install_online.sh | bash
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

ask_yes_no() {
  local question="$1"
  local default_yes="${2:-1}"
  local marker="T/n"
  if [[ "$default_yes" -eq 0 ]]; then
    marker="t/N"
  fi

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi

  while true; do
    local ans
    read -r -p "$question [$marker]: " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ -z "$ans" ]]; then
      if [[ "$default_yes" -eq 1 ]]; then
        return 0
      fi
      return 1
    fi
    if [[ "$ans" == "t" || "$ans" == "tak" || "$ans" == "y" || "$ans" == "yes" ]]; then
      return 0
    fi
    if [[ "$ans" == "n" || "$ans" == "nie" || "$ans" == "no" ]]; then
      return 1
    fi
    echo "Wpisz t lub n."
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-url)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --manifest-url" >&2; exit 1; }
      MANIFEST_URL="$2"
      shift 2
      ;;
    --install-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --install-dir" >&2; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-wizard)
      RUN_WIZARD=0
      shift
      ;;
    --wizard-no-test)
      WIZARD_NO_TEST=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
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

require_cmd curl
require_cmd tar
require_cmd sha256sum
require_cmd python3
require_cmd systemctl

TMP_DIR="$(mktemp -d)"
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

MANIFEST_PATH="$TMP_DIR/latest.json"
echo "Pobieram manifest: $MANIFEST_URL"
curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_PATH"

if ! readarray -t META < <(
  python3 - "$MANIFEST_PATH" "$MANIFEST_URL" <<'PY'
import json, sys
from urllib.parse import urljoin

manifest_path = sys.argv[1]
manifest_url = sys.argv[2]
with open(manifest_path, "r", encoding="utf-8") as f:
    data = json.load(f)

version = str(data.get("version", "")).strip()
sha256 = str(data.get("sha256", "")).strip().lower()
tarball_url = str(data.get("tarball_url", "")).strip()
if not tarball_url:
    tarball = str(data.get("tarball", "")).strip()
    if tarball:
      tarball_url = urljoin(manifest_url, tarball)

if not version:
    raise SystemExit("Manifest bez pola version")
if not tarball_url:
    raise SystemExit("Manifest bez pola tarball_url lub tarball")
if not sha256:
    raise SystemExit("Manifest bez pola sha256")

print(version)
print(tarball_url)
print(sha256)
PY
); then
  echo "Nieprawidlowy manifest: $MANIFEST_URL" >&2
  exit 2
fi

if [[ "${#META[@]}" -lt 3 ]]; then
  echo "Nieprawidlowy manifest: brak wymaganych pol" >&2
  exit 2
fi

VERSION="${META[0]}"
TARBALL_URL="${META[1]}"
EXPECTED_SHA="${META[2]}"
ARCHIVE_NAME="$(basename "$TARBALL_URL")"
ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"

echo "Wersja do instalacji: $VERSION"
echo "Pobieram paczke: $TARBALL_URL"
curl -fsSL "$TARBALL_URL" -o "$ARCHIVE_PATH"

ACTUAL_SHA="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "Bledna suma SHA256 paczki" >&2
  echo "Oczekiwano: $EXPECTED_SHA" >&2
  echo "Otrzymano : $ACTUAL_SHA" >&2
  exit 3
fi
echo "SHA256 OK"

EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

PKG_DIR=""
for d in "$EXTRACT_DIR"/*; do
  if [[ -d "$d" && -x "$d/install.sh" ]]; then
    PKG_DIR="$d"
    break
  fi
done

if [[ -z "$PKG_DIR" ]]; then
  echo "Nie znaleziono install.sh w paczce" >&2
  exit 4
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  echo
  echo "Instalacja zostanie wykonana do: $INSTALL_DIR"
  if ! ask_yes_no "Kontynuowac?" 1; then
    echo "Anulowano."
    exit 0
  fi
fi

"$PKG_DIR/install.sh" --install-dir "$INSTALL_DIR"

if [[ "$RUN_WIZARD" -eq 1 && -x "$INSTALL_DIR/config_wizard.py" ]]; then
  if ask_yes_no "Uruchomic kreator konfiguracji teraz?" 1; then
    WIZARD_ARGS=(--config "$INSTALL_DIR/config.json")
    if [[ "$WIZARD_NO_TEST" -eq 1 ]]; then
      WIZARD_ARGS+=(--no-test)
    fi
    python3 "$INSTALL_DIR/config_wizard.py" "${WIZARD_ARGS[@]}"
  fi
fi

if [[ -x "$INSTALL_DIR/enable_auto_update.sh" ]]; then
  if ask_yes_no "Wlaczyc auto-update z aktualnego manifestu?" 1; then
    "$INSTALL_DIR/enable_auto_update.sh" \
      --manifest-url "$MANIFEST_URL" \
      --install-dir "$INSTALL_DIR" \
      --run-now
  fi
fi

echo
echo "Instalacja online zakonczona."
echo "Wersja: $VERSION"
echo "Katalog: $INSTALL_DIR"
