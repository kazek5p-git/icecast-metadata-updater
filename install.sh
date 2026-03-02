#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="icecast-metadata-updater.service"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USE_SOURCE_CONFIG=0

print_help() {
  cat <<EOF
Uzycie:
  ./install.sh [--install-dir KATALOG] [--use-source-config]

Opcje:
  --install-dir KATALOG   Katalog docelowy instalacji (domyslnie: $DEFAULT_INSTALL_DIR)
  --use-source-config     Jesli istnieje localny config.json obok instalatora,
                          skopiuj go przy pierwszej instalacji.

Przyklady:
  ./install.sh
  ./install.sh --install-dir "$HOME/moj-updater-icecast"
  ./install.sh --use-source-config
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

detect_source_version() {
  if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    head -n 1 "$SCRIPT_DIR/VERSION" | tr -d '[:space:]'
    return 0
  fi

  if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" rev-parse --short HEAD
    return 0
  fi

  local base
  base="$(basename "$SCRIPT_DIR")"
  if [[ "$base" =~ ^icecast-metadata-updater-([0-9a-fA-F]{7,40})$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  echo "unknown"
}

copy_file() {
  local src="$1"
  local dst="$2"
  local src_real
  local dst_real
  src_real="$(readlink -f "$src")"
  dst_real="$(readlink -f "$dst" 2>/dev/null || true)"
  if [[ -n "$dst_real" && "$src_real" == "$dst_real" ]]; then
    return 0
  fi
  cp -f "$src" "$dst"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --install-dir" >&2; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --use-source-config)
      USE_SOURCE_CONFIG=1
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

if [[ "$INSTALL_DIR" == *" "* ]]; then
  echo "Katalog instalacji nie moze zawierac spacji: $INSTALL_DIR" >&2
  exit 1
fi

require_cmd python3
require_cmd systemctl

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "Brak dostepu do systemd --user w tej sesji." >&2
  echo "Uruchom instalator w normalnej sesji uzytkownika (nie przez su bez sesji user systemd)." >&2
  exit 1
fi

for needed in \
  "$SCRIPT_DIR/weather_metadata_updater.py" \
  "$SCRIPT_DIR/config_wizard.py" \
  "$SCRIPT_DIR/doctor.sh" \
  "$SCRIPT_DIR/start_updater.sh" \
  "$SCRIPT_DIR/auto_update.sh" \
  "$SCRIPT_DIR/auto_update.example.conf" \
  "$SCRIPT_DIR/enable_auto_update.sh" \
  "$SCRIPT_DIR/install_tuner_only.sh" \
  "$SCRIPT_DIR/update.sh" \
  "$SCRIPT_DIR/config.example.json" \
  "$SCRIPT_DIR/config.tuner-only.example.json" \
  "$SCRIPT_DIR/systemd/icecast-metadata-updater.service"; do
  if [[ ! -f "$needed" ]]; then
    echo "Brak wymaganego pliku: $needed" >&2
    exit 1
  fi
done

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/systemd" "$INSTALL_DIR/logs" "$USER_SYSTEMD_DIR"

copy_file "$SCRIPT_DIR/weather_metadata_updater.py" "$INSTALL_DIR/weather_metadata_updater.py"
copy_file "$SCRIPT_DIR/config_wizard.py" "$INSTALL_DIR/config_wizard.py"
copy_file "$SCRIPT_DIR/doctor.sh" "$INSTALL_DIR/doctor.sh"
copy_file "$SCRIPT_DIR/start_updater.sh" "$INSTALL_DIR/start_updater.sh"
copy_file "$SCRIPT_DIR/auto_update.sh" "$INSTALL_DIR/auto_update.sh"
copy_file "$SCRIPT_DIR/auto_update.example.conf" "$INSTALL_DIR/auto_update.example.conf"
copy_file "$SCRIPT_DIR/enable_auto_update.sh" "$INSTALL_DIR/enable_auto_update.sh"
copy_file "$SCRIPT_DIR/install_tuner_only.sh" "$INSTALL_DIR/install_tuner_only.sh"
copy_file "$SCRIPT_DIR/update.sh" "$INSTALL_DIR/update.sh"
copy_file "$SCRIPT_DIR/install.sh" "$INSTALL_DIR/install.sh"
copy_file "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md"
copy_file "$SCRIPT_DIR/config.example.json" "$INSTALL_DIR/config.example.json"
copy_file "$SCRIPT_DIR/config.tuner-only.example.json" "$INSTALL_DIR/config.tuner-only.example.json"
copy_file "$SCRIPT_DIR/systemd/icecast-metadata-updater.service" "$INSTALL_DIR/systemd/icecast-metadata-updater.service"
if [[ -f "$SCRIPT_DIR/install_online.sh" ]]; then
  copy_file "$SCRIPT_DIR/install_online.sh" "$INSTALL_DIR/install_online.sh"
  chmod +x "$INSTALL_DIR/install_online.sh"
fi
if [[ -f "$SCRIPT_DIR/make_installer_bundle.sh" ]]; then
  copy_file "$SCRIPT_DIR/make_installer_bundle.sh" "$INSTALL_DIR/make_installer_bundle.sh"
  chmod +x "$INSTALL_DIR/make_installer_bundle.sh"
fi

chmod +x "$INSTALL_DIR/start_updater.sh" "$INSTALL_DIR/config_wizard.py" \
  "$INSTALL_DIR/doctor.sh" "$INSTALL_DIR/auto_update.sh" "$INSTALL_DIR/enable_auto_update.sh" \
  "$INSTALL_DIR/install_tuner_only.sh" \
  "$INSTALL_DIR/install.sh" "$INSTALL_DIR/update.sh"

if [[ ! -f "$INSTALL_DIR/config.json" ]]; then
  if [[ "$USE_SOURCE_CONFIG" -eq 1 && -f "$SCRIPT_DIR/config.json" ]]; then
    copy_file "$SCRIPT_DIR/config.json" "$INSTALL_DIR/config.json"
    echo "Utworzono $INSTALL_DIR/config.json z lokalnego config.json"
  else
    copy_file "$SCRIPT_DIR/config.example.json" "$INSTALL_DIR/config.json"
    echo "Utworzono $INSTALL_DIR/config.json z config.example.json"
  fi
else
  echo "Zachowano istniejacy $INSTALL_DIR/config.json"
fi

SOURCE_VERSION="$(detect_source_version)"
echo "$SOURCE_VERSION" > "$INSTALL_DIR/.installed_version"
echo "Wersja zainstalowana: $SOURCE_VERSION"

SERVICE_PATH="$USER_SYSTEMD_DIR/$SERVICE_NAME"
cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=Aktualizacja metadanych Icecast na podstawie pogody
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/start_updater.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
if systemctl --user is-active --quiet "$SERVICE_NAME"; then
  systemctl --user restart "$SERVICE_NAME"
else
  systemctl --user start "$SERVICE_NAME"
fi

LINGER_STATE="unknown"
if command -v loginctl >/dev/null 2>&1; then
  LINGER_STATE="$(loginctl show-user "$USER" -p Linger 2>/dev/null | awk -F= '{print $2}')"
fi

echo
echo "Instalacja zakonczona."
echo "Katalog: $INSTALL_DIR"
echo "Usluga: $SERVICE_NAME"
echo "Status: $(systemctl --user is-active "$SERVICE_NAME")"
echo "Autostart: $(systemctl --user is-enabled "$SERVICE_NAME")"
echo "Log: $INSTALL_DIR/logs/updater.log"
echo "Kreator konfiguracji: python3 $INSTALL_DIR/config_wizard.py --config $INSTALL_DIR/config.json"
echo "Diagnostyka: $INSTALL_DIR/doctor.sh --install-dir $INSTALL_DIR --config $INSTALL_DIR/config.json"
echo "Instalator online: $INSTALL_DIR/install_online.sh"

if [[ "$LINGER_STATE" != "yes" ]]; then
  echo
  echo "Uwaga: Linger != yes. Zeby usluga startowala bez logowania, ustaw:"
  echo "  sudo loginctl enable-linger $USER"
fi
