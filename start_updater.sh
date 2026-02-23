#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/icecast_weather_updater_${USER}.lock"
LOG_FILE="$LOG_DIR/updater.log"
AUTO_UPDATE_CONF="$PROJECT_DIR/auto_update.conf"
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

log_watchdog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

run_startup_update_check() {
  local check_on_start
  local check_timeout
  local exit_code

  if [[ ! -f "$AUTO_UPDATE_CONF" ]]; then
    return
  fi

  # shellcheck source=/dev/null
  source "$AUTO_UPDATE_CONF"

  if [[ -z "${UPDATE_MANIFEST_URL:-}" ]]; then
    log_watchdog "STARTUP: pomijam auto-update (brak UPDATE_MANIFEST_URL w auto_update.conf)"
    return
  fi

  check_on_start="${UPDATE_CHECK_ON_START:-1}"
  if [[ "$check_on_start" != "1" ]]; then
    log_watchdog "STARTUP: auto-update przy starcie wylaczony (UPDATE_CHECK_ON_START=$check_on_start)"
    return
  fi

  if [[ ! -x "$PROJECT_DIR/auto_update.sh" ]]; then
    log_watchdog "STARTUP: brak auto_update.sh, pomijam sprawdzenie aktualizacji"
    return
  fi

  check_timeout="${UPDATE_CHECK_TIMEOUT_SEC:-180}"
  log_watchdog "STARTUP: sprawdzam aktualizacje..."

  if command -v timeout >/dev/null 2>&1 && [[ "$check_timeout" =~ ^[0-9]+$ ]] && [[ "$check_timeout" -gt 0 ]]; then
    if timeout "${check_timeout}s" "$PROJECT_DIR/auto_update.sh" --install-dir "$PROJECT_DIR" >> "$LOG_FILE" 2>&1; then
      log_watchdog "STARTUP: sprawdzenie aktualizacji zakonczone."
    else
      exit_code=$?
      if [[ "$exit_code" -eq 124 ]]; then
        log_watchdog "STARTUP: timeout sprawdzania aktualizacji (${check_timeout}s), kontynuuje uruchomienie."
      else
        log_watchdog "STARTUP: sprawdzanie aktualizacji zakonczone kodem $exit_code, kontynuuje uruchomienie."
      fi
    fi
    return
  fi

  if "$PROJECT_DIR/auto_update.sh" --install-dir "$PROJECT_DIR" >> "$LOG_FILE" 2>&1; then
    log_watchdog "STARTUP: sprawdzenie aktualizacji zakonczone."
  else
    exit_code=$?
    log_watchdog "STARTUP: sprawdzanie aktualizacji zakonczone kodem $exit_code, kontynuuje uruchomienie."
  fi
}

run_startup_update_check

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
