#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
MANIFEST_URL=""
INTERVAL=""
RANDOM_DELAY=""
ON_BOOT_SEC=""
CHECK_ON_START=""
CHECK_TIMEOUT_SEC=""
RUN_NOW=0
DISABLE=0

DEFAULT_INTERVAL="1d"
DEFAULT_RANDOM_DELAY="1h"
DEFAULT_ON_BOOT_SEC="20m"
DEFAULT_CHECK_ON_START="1"
DEFAULT_CHECK_TIMEOUT_SEC="180"

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
  --interval CZAS         OnUnitActiveSec dla timera (domyslnie: $DEFAULT_INTERVAL)
  --random-delay CZAS     RandomizedDelaySec (domyslnie: $DEFAULT_RANDOM_DELAY)
  --on-boot-sec CZAS      OnBootSec dla timera (domyslnie: $DEFAULT_ON_BOOT_SEC)
  --check-on-start        Sprawdz aktualizacje przy starcie programu (start_updater.sh)
  --no-check-on-start     Nie sprawdzaj aktualizacji przy starcie programu
  --check-timeout-sec N   Timeout sprawdzania przy starcie programu (domyslnie: $DEFAULT_CHECK_TIMEOUT_SEC)
  --run-now               Uruchom aktualizacje od razu po wlaczeniu timera
  --disable               Wylacz auto-update (timer+service)

Wszystkie ustawienia sa zapisywane do:
  <install-dir>/auto_update.conf

Przyklady:
  ./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json"
  ./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json" --interval 12h --run-now
  ./enable_auto_update.sh --check-on-start --on-boot-sec 5m
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
    --on-boot-sec)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --on-boot-sec" >&2; exit 1; }
      ON_BOOT_SEC="$2"
      shift 2
      ;;
    --check-on-start)
      CHECK_ON_START="1"
      shift
      ;;
    --no-check-on-start)
      CHECK_ON_START="0"
      shift
      ;;
    --check-timeout-sec)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --check-timeout-sec" >&2; exit 1; }
      CHECK_TIMEOUT_SEC="$2"
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

if [[ ! -x "$INSTALL_DIR/auto_update.sh" ]]; then
  echo "Brak auto_update.sh w $INSTALL_DIR" >&2
  echo "Uruchom najpierw instalator: $SCRIPT_DIR/install.sh" >&2
  exit 1
fi

CONFIG_PATH="$INSTALL_DIR/auto_update.conf"
if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_PATH"
  MANIFEST_URL="${MANIFEST_URL:-${UPDATE_MANIFEST_URL:-}}"
  INTERVAL="${INTERVAL:-${UPDATE_TIMER_INTERVAL:-}}"
  RANDOM_DELAY="${RANDOM_DELAY:-${UPDATE_TIMER_RANDOM_DELAY:-}}"
  ON_BOOT_SEC="${ON_BOOT_SEC:-${UPDATE_TIMER_ON_BOOT_SEC:-}}"
  CHECK_ON_START="${CHECK_ON_START:-${UPDATE_CHECK_ON_START:-}}"
  CHECK_TIMEOUT_SEC="${CHECK_TIMEOUT_SEC:-${UPDATE_CHECK_TIMEOUT_SEC:-}}"
fi

INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"
RANDOM_DELAY="${RANDOM_DELAY:-$DEFAULT_RANDOM_DELAY}"
ON_BOOT_SEC="${ON_BOOT_SEC:-$DEFAULT_ON_BOOT_SEC}"
CHECK_ON_START="${CHECK_ON_START:-$DEFAULT_CHECK_ON_START}"
CHECK_TIMEOUT_SEC="${CHECK_TIMEOUT_SEC:-$DEFAULT_CHECK_TIMEOUT_SEC}"

if [[ -z "$MANIFEST_URL" ]]; then
  echo "Podaj --manifest-url URL (albo ustaw UPDATE_MANIFEST_URL w $CONFIG_PATH)" >&2
  exit 1
fi

if [[ "$CHECK_ON_START" != "0" && "$CHECK_ON_START" != "1" ]]; then
  echo "Niepoprawne CHECK_ON_START=$CHECK_ON_START (dopuszczalne: 0 albo 1)" >&2
  exit 1
fi

if ! [[ "$CHECK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$CHECK_TIMEOUT_SEC" -lt 1 ]]; then
  echo "Niepoprawne CHECK_TIMEOUT_SEC=$CHECK_TIMEOUT_SEC (musi byc dodatnia liczba calkowita)" >&2
  exit 1
fi

mkdir -p "$USER_SYSTEMD_DIR"

cat > "$CONFIG_PATH" <<EOF
UPDATE_MANIFEST_URL="$MANIFEST_URL"
UPDATE_TIMER_INTERVAL="$INTERVAL"
UPDATE_TIMER_RANDOM_DELAY="$RANDOM_DELAY"
UPDATE_TIMER_ON_BOOT_SEC="$ON_BOOT_SEC"
UPDATE_CHECK_ON_START="$CHECK_ON_START"
UPDATE_CHECK_TIMEOUT_SEC="$CHECK_TIMEOUT_SEC"
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
OnBootSec=$ON_BOOT_SEC
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
echo "Config: $CONFIG_PATH"
echo "Timer interval: $INTERVAL"
echo "Timer random delay: $RANDOM_DELAY"
echo "Timer on boot: $ON_BOOT_SEC"
echo "Check on program start: $CHECK_ON_START"
echo "Startup check timeout (s): $CHECK_TIMEOUT_SEC"
echo "Timer: $TIMER_NAME ($(systemctl --user is-active "$TIMER_NAME"), $(systemctl --user is-enabled "$TIMER_NAME"))"
echo "Sprawdzenie: systemctl --user status $TIMER_NAME"
