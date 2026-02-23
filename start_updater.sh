#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/kazek/icecast-metadata-updater"
LOG_DIR="$PROJECT_DIR/logs"
LOCK_FILE="/tmp/icecast_weather_updater.lock"

mkdir -p "$LOG_DIR"

# Wymuszamy UTF-8 dla logow i skladania tytulow.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8

exec /usr/bin/flock -n "$LOCK_FILE" \
  /usr/bin/python3 "$PROJECT_DIR/weather_metadata_updater.py" \
  --config "$PROJECT_DIR/config.json" \
  >> "$LOG_DIR/updater.log" 2>&1
