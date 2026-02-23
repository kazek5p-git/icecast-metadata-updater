#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/icecast_weather_updater_${USER}.lock"
LOG_FILE="$LOG_DIR/updater.log"
RESTART_DELAY_SECONDS=10

mkdir -p "$LOG_DIR"

# Wymuszamy UTF-8 dla logow i skladania tytulow.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8

# Trzymamy lock przez caly czas dzialania watchdoga, by nie odpalic 2 instancji.
exec 9>"$LOCK_FILE"
if ! /usr/bin/flock -n 9; then
  exit 0
fi

while true; do
  if "$(command -v python3)" "$PROJECT_DIR/weather_metadata_updater.py" \
    --config "$PROJECT_DIR/config.json" \
    >> "$LOG_FILE" 2>&1; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
  printf '[%s] WATCHDOG: updater exited with code %s, restart in %ss\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$EXIT_CODE" \
    "$RESTART_DELAY_SECONDS" \
    >> "$LOG_FILE"
  sleep "$RESTART_DELAY_SECONDS"
done
