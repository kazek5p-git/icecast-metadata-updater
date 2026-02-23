#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
MANIFEST_URL=""
INTERVAL="1d"
RANDOM_DELAY="1h"
RUN_NOW=0
DISABLE=0

SERVICE_NAME="icecast-metadata-updater-autoupdate.service"
TIMER_NAME="icecast-metadata-updater-autoupdate.timer"
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

print_help() {
  cat <<EOF
Uzycie:
  ./enable_auto_update.sh [opcje]

Opcje:
  --manifest-url URL      Adres manifestu latest.json (wymagane przy wlaczaniu)
  --install-dir KATALOG   Katalog instalacji programu (domyslnie: $DEFAULT_INSTALL_DIR)
  --interval CZAS         OnUnitActiveSec dla timera (domyslnie: 1d)
  --random-delay CZAS     RandomizedDelaySec (domyslnie: 1h)
  --run-now               Uruchom aktualizacje od razu po wlaczeniu timera
  --disable               Wylacz auto-update (timer+service)

Przyklady:
  ./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json"
  ./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json" --interval 12h --run-now
  ./enable_auto_update.sh --disable
EOF
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
    --interval)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --interval" >&2; exit 1; }
      INTERVAL="$2"
      shift 2
      ;;
    --random-delay)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --random-delay" >&2; exit 1; }
      RANDOM_DELAY="$2"
      shift 2
      ;;
    --run-now)
      RUN_NOW=1
      shift
      ;;
    --disable)
      DISABLE=1
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

if [[ "$DISABLE" -eq 1 ]]; then
  systemctl --user disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$USER_SYSTEMD_DIR/$SERVICE_NAME" "$USER_SYSTEMD_DIR/$TIMER_NAME"
  systemctl --user daemon-reload
  echo "Auto-update wylaczony."
  exit 0
fi

if [[ -z "$MANIFEST_URL" ]]; then
  echo "Podaj --manifest-url URL" >&2
  exit 1
fi

if [[ ! -x "$INSTALL_DIR/auto_update.sh" ]]; then
  echo "Brak auto_update.sh w $INSTALL_DIR" >&2
  echo "Uruchom najpierw instalator: $SCRIPT_DIR/install.sh" >&2
  exit 1
fi

mkdir -p "$USER_SYSTEMD_DIR"

cat > "$INSTALL_DIR/auto_update.conf" <<EOF
UPDATE_MANIFEST_URL="$MANIFEST_URL"
EOF

cat > "$USER_SYSTEMD_DIR/$SERVICE_NAME" <<UNIT
[Unit]
Description=Automatyczna aktualizacja Icecast Metadata Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/auto_update.sh --install-dir $INSTALL_DIR
UNIT

cat > "$USER_SYSTEMD_DIR/$TIMER_NAME" <<UNIT
[Unit]
Description=Timer auto-update Icecast Metadata Updater

[Timer]
OnBootSec=20m
OnUnitActiveSec=$INTERVAL
RandomizedDelaySec=$RANDOM_DELAY
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now "$TIMER_NAME"

if [[ "$RUN_NOW" -eq 1 ]]; then
  systemctl --user start "$SERVICE_NAME"
fi

echo "Auto-update wlaczony."
echo "Manifest: $MANIFEST_URL"
echo "Timer: $TIMER_NAME ($(systemctl --user is-active "$TIMER_NAME"), $(systemctl --user is-enabled "$TIMER_NAME"))"
echo "Sprawdzenie: systemctl --user status $TIMER_NAME"
