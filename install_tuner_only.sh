#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SITE_URL="https://kazpar.pl/icecast-updater"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
DEFAULT_TITLE_TEMPLATE="South-east Cracow: {freq} MHz | RDS: {ps} | ST: {station} | ERP: {power} | Dist: {distance} | Signal: {signal}"

SITE_URL="$DEFAULT_SITE_URL"
MANIFEST_URL="$DEFAULT_SITE_URL/latest.json"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
ASSUME_YES=0
NO_RESTART=0
RUN_WIZARD=1
WIZARD_NO_TEST=0

print_help() {
  cat <<EOF
Uzycie:
  ./install_tuner_only.sh [opcje]

Opcje:
  --site-url URL          Bazowy URL publikacji (domyslnie: $DEFAULT_SITE_URL)
  --manifest-url URL      URL do latest.json (nadpisuje --site-url)
  --install-dir KATALOG   Katalog instalacji (domyslnie: $DEFAULT_INSTALL_DIR)
  --yes                   Instalacja bez pytan
  --no-restart            Nie restartuj uslugi po zmianie configu
  --no-wizard             Nie uruchamiaj kreatora config_wizard.py
  --wizard-no-test        Przy uruchomieniu kreatora pomin test status-json.xsl
  -h, --help              Pomoc

Przyklad:
  curl -fsSL https://kazpar.pl/icecast-updater/install_tuner_only.sh | bash
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  echo "$value"
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
    --site-url)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --site-url" >&2; exit 1; }
      SITE_URL="$2"
      shift 2
      ;;
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
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --no-restart)
      NO_RESTART=1
      shift
      ;;
    --no-wizard)
      RUN_WIZARD=0
      shift
      ;;
    --wizard-no-test)
      WIZARD_NO_TEST=1
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
require_cmd python3

SITE_URL="$(trim_trailing_slash "$SITE_URL")"
if [[ "$MANIFEST_URL" == "$DEFAULT_SITE_URL/latest.json" && "$SITE_URL" != "$DEFAULT_SITE_URL" ]]; then
  MANIFEST_URL="$SITE_URL/latest.json"
fi
INSTALL_ONLINE_URL="$SITE_URL/install_online.sh"

ONLINE_ARGS=(--manifest-url "$MANIFEST_URL" --install-dir "$INSTALL_DIR" --no-wizard)
if [[ "$ASSUME_YES" -eq 1 ]]; then
  ONLINE_ARGS+=(--yes)
fi

echo "Instaluje najnowsza wersje updatera z: $MANIFEST_URL"
curl -fsSL "$INSTALL_ONLINE_URL" | bash -s -- "${ONLINE_ARGS[@]}"

CONFIG_PATH="$INSTALL_DIR/config.json"
if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ -f "$INSTALL_DIR/config.example.json" ]]; then
    cp -f "$INSTALL_DIR/config.example.json" "$CONFIG_PATH"
  else
    echo "Brak config.json i config.example.json w $INSTALL_DIR" >&2
    exit 2
  fi
fi

BACKUP_PATH="$CONFIG_PATH.bak_$(date +%Y%m%d_%H%M%S)"
cp -f "$CONFIG_PATH" "$BACKUP_PATH"

python3 - "$CONFIG_PATH" "$DEFAULT_TITLE_TEMPLATE" <<'PY'
import json
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
title_template = sys.argv[2]

with cfg_path.open("r", encoding="utf-8") as f:
    cfg = json.load(f)

if not isinstance(cfg, dict):
    cfg = {}

cfg.setdefault("update", {})
if not isinstance(cfg["update"], dict):
    cfg["update"] = {}
cfg["update"].setdefault("interval_seconds", 600)
cfg["update"].setdefault("dry_run", False)

outside = cfg.setdefault("outside", {})
if not isinstance(outside, dict):
    outside = {}
cfg["outside"] = outside
outside["enabled"] = False

tuner = cfg.setdefault("tuner", {})
if not isinstance(tuner, dict):
    tuner = {}
cfg["tuner"] = tuner
tuner["enabled"] = True
tuner.setdefault("mount_name", "tuner")
tuner.setdefault("api_url", "http://127.0.0.1:8080/api")
tuner.setdefault("interval_seconds", 5)
if not str(tuner.get("title_template", "")).strip():
    tuner["title_template"] = title_template

with cfg_path.open("w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "Zastosowano profil Tuner-only:"
echo "- outside.enabled=false"
echo "- tuner.enabled=true"
echo "- backup configu: $BACKUP_PATH"

if [[ "$NO_RESTART" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user restart icecast-metadata-updater.service || true
    echo "Zrestartowano: icecast-metadata-updater.service"
  fi
fi

if [[ "$RUN_WIZARD" -eq 1 && -x "$INSTALL_DIR/config_wizard.py" ]]; then
  if ask_yes_no "Uruchomic kreator konfiguracji teraz?" 1; then
    WIZARD_ARGS=(--config "$CONFIG_PATH")
    if [[ "$WIZARD_NO_TEST" -eq 1 ]]; then
      WIZARD_ARGS+=(--no-test)
    fi
    python3 "$INSTALL_DIR/config_wizard.py" "${WIZARD_ARGS[@]}"
  fi
fi

echo
echo "Gotowe. Jesli chcesz, mozesz uruchomic test:"
echo "python3 \"$INSTALL_DIR/weather_metadata_updater.py\" --config \"$CONFIG_PATH\" --once --dry-run"

