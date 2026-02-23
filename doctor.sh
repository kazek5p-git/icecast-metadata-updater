#!/usr/bin/env bash
set -euo pipefail

DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONFIG_PATH=""
TIMEOUT=12
LOG_LINES=20
RUN_DRY_RUN=0

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

print_help() {
  cat <<EOF
Uzycie:
  ./doctor.sh [opcje]

Opcje:
  --install-dir KATALOG   Katalog instalacji (domyslnie: $DEFAULT_INSTALL_DIR)
  --config PLIK           Sciezka do config.json (domyslnie: <install-dir>/config.json)
  --timeout SEK           Timeout zapytan HTTP (domyslnie: $TIMEOUT)
  --log-lines N           Ile linii loga pokazac (domyslnie: $LOG_LINES)
  --run-dry-run           Wykonaj dodatkowy test: weather_metadata_updater.py --once --dry-run
  -h, --help              Pomoc
EOF
}

ok() {
  echo "[OK] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
  echo "[WARN] $1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
  echo "[BLAD] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

mask_secret() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "(puste)"
    return
  fi
  local len="${#value}"
  if [[ "$len" -le 2 ]]; then
    echo "*** (${len} znaki)"
    return
  fi
  local first="${value:0:1}"
  local last="${value: -1}"
  echo "${first}***${last} (${len} znakow)"
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
    --timeout)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --timeout" >&2; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --log-lines)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --log-lines" >&2; exit 1; }
      LOG_LINES="$2"
      shift 2
      ;;
    --run-dry-run)
      RUN_DRY_RUN=1
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

if [[ -z "$CONFIG_PATH" ]]; then
  if [[ -f "$INSTALL_DIR/config.json" ]]; then
    CONFIG_PATH="$INSTALL_DIR/config.json"
  else
    CONFIG_PATH="./config.json"
  fi
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Brak pliku konfiguracyjnego: $CONFIG_PATH" >&2
  exit 2
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -lt 1 ]]; then
  echo "Niepoprawna wartosc --timeout: $TIMEOUT" >&2
  exit 1
fi

if ! [[ "$LOG_LINES" =~ ^[0-9]+$ ]] || [[ "$LOG_LINES" -lt 1 ]]; then
  echo "Niepoprawna wartosc --log-lines: $LOG_LINES" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! readarray -t CFG < <(
  python3 - "$CONFIG_PATH" <<'PY'
import configparser
import json
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
with cfg_path.open("r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("CONFIG_ERROR: root JSON musi byc obiektem")

def g(*keys, default=None):
    cur = data
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur

def darkice_defaults():
    for path in (Path("/etc/darkice.cfg"), Path("/etc/darkice2.cfg")):
        if not path.exists():
            continue
        parser = configparser.ConfigParser(interpolation=None)
        try:
            parser.read(path, encoding="utf-8")
        except Exception:
            continue
        for section in parser.sections():
            if not section.startswith("icecast"):
                continue
            server = parser.get(section, "server", fallback="").strip()
            port = parser.get(section, "port", fallback="").strip()
            password = parser.get(section, "password", fallback="").strip()
            if server and port:
                return {
                    "base_url": f"http://{server}:{port}",
                    "source_password": password,
                }
    return {}

defaults = darkice_defaults()

base_url = str(g("icecast", "base_url", default=defaults.get("base_url", "http://127.0.0.1:8888"))).strip()
if not base_url:
    base_url = "http://127.0.0.1:8888"

source_user = str(g("icecast", "source_user", default="source")).strip() or "source"
source_password = g("icecast", "source_password", default=defaults.get("source_password", ""))
metadata_user = g("icecast", "metadata_user", default=None)
metadata_password = g("icecast", "metadata_password", default=None)
status_user = g("icecast", "status_user", default=None)
status_password = g("icecast", "status_password", default=None)
mount_prefix = str(g("streams", "mount_prefix", default="outside_")).strip().lstrip("/")

if metadata_user in (None, ""):
    metadata_user = source_user
if metadata_password in (None, ""):
    metadata_password = source_password

def norm(v):
    if v is None:
        return ""
    return str(v).strip()

print(base_url.rstrip("/"))
print(mount_prefix)
print(source_user)
print(norm(source_password))
print(norm(metadata_user))
print(norm(metadata_password))
print(norm(status_user))
print(norm(status_password))
PY
); then
  echo "Nie udalo sie odczytac configu: $CONFIG_PATH" >&2
  exit 2
fi

if [[ "${#CFG[@]}" -lt 8 ]]; then
  echo "Konfiguracja jest niepelna: $CONFIG_PATH" >&2
  exit 2
fi

BASE_URL="${CFG[0]}"
MOUNT_PREFIX="${CFG[1]}"
SOURCE_USER="${CFG[2]}"
SOURCE_PASSWORD="${CFG[3]}"
METADATA_USER="${CFG[4]}"
METADATA_PASSWORD="${CFG[5]}"
STATUS_USER="${CFG[6]}"
STATUS_PASSWORD="${CFG[7]}"

echo "=== Icecast Metadata Updater Doctor ==="
echo "Instalacja : $INSTALL_DIR"
echo "Config      : $CONFIG_PATH"
echo ""
echo "-- Konfiguracja --"
echo "base_url          : $BASE_URL"
echo "mount_prefix      : $MOUNT_PREFIX"
echo "source_user       : $SOURCE_USER"
echo "source_password   : $(mask_secret "$SOURCE_PASSWORD")"
echo "metadata_user     : $METADATA_USER"
echo "metadata_password : $(mask_secret "$METADATA_PASSWORD")"
if [[ -n "$STATUS_USER" ]]; then
  echo "status_user       : $STATUS_USER"
  echo "status_password   : $(mask_secret "$STATUS_PASSWORD")"
else
  echo "status auth       : brak (status-json bez logowania)"
fi

if [[ -z "$SOURCE_PASSWORD" ]]; then
  fail "Brak icecast.source_password w config.json."
else
  ok "Haslo source jest ustawione."
fi

if [[ -z "$METADATA_USER" || -z "$METADATA_PASSWORD" ]]; then
  fail "Brak danych metadata_user/metadata_password."
else
  ok "Dane metadata sa ustawione."
fi

STATUS_URL="$BASE_URL/status-json.xsl"
STATUS_BODY="$TMP_DIR/status.json"

echo ""
echo "-- Test status-json.xsl --"
STATUS_CURL_ARGS=(-fsS --max-time "$TIMEOUT" --connect-timeout 5)
if [[ -n "$STATUS_USER" || -n "$STATUS_PASSWORD" ]]; then
  STATUS_CURL_ARGS+=(-u "$STATUS_USER:$STATUS_PASSWORD")
fi

if curl "${STATUS_CURL_ARGS[@]}" "$STATUS_URL" -o "$STATUS_BODY"; then
  ok "Polaczenie z $STATUS_URL"
else
  fail "Nie mozna pobrac $STATUS_URL"
fi

OUTSIDE_MOUNTS_PREVIEW=""
FIRST_MOUNT=""
if [[ -s "$STATUS_BODY" ]]; then
  if readarray -t STATUS_META < <(
    python3 - "$STATUS_BODY" "$MOUNT_PREFIX" <<'PY'
import json, sys
from urllib.parse import urlparse

status_path = sys.argv[1]
prefix = sys.argv[2]
with open(status_path, "r", encoding="utf-8") as f:
    data = json.load(f)

sources = data.get("icestats", {}).get("source", [])
if isinstance(sources, dict):
    sources = [sources]
if not isinstance(sources, list):
    raise SystemExit("BAD_STATUS_FORMAT")

mounts = []
for src in sources:
    if not isinstance(src, dict):
        continue
    listen = str(src.get("listenurl", "")).strip()
    mount = ""
    if listen:
        parsed = urlparse(listen)
        path = parsed.path.strip()
        if path.startswith("/"):
            mount = path.lstrip("/")
    if not mount:
        raw = str(src.get("mount", "")).strip()
        if raw.startswith("/"):
            raw = raw.lstrip("/")
        mount = raw
    if mount:
        mounts.append(mount)

outside = sorted({m for m in mounts if m.startswith(prefix)})
print(len(mounts))
print(len(outside))
print(", ".join(outside[:8]))
print(mounts[0] if mounts else "")
PY
  ); then
    TOTAL_SOURCES="${STATUS_META[0]:-0}"
    TOTAL_OUTSIDE="${STATUS_META[1]:-0}"
    OUTSIDE_MOUNTS_PREVIEW="${STATUS_META[2]:-}"
    FIRST_MOUNT="${STATUS_META[3]:-}"
    ok "status-json parsuje sie poprawnie (zrodla: $TOTAL_SOURCES)"
    if [[ "$TOTAL_OUTSIDE" -gt 0 ]]; then
      ok "Wykryto mounty z prefiksem '$MOUNT_PREFIX': $TOTAL_OUTSIDE"
      if [[ -n "$OUTSIDE_MOUNTS_PREVIEW" ]]; then
        echo "  Mounty: $OUTSIDE_MOUNTS_PREVIEW"
      fi
    else
      warn "Brak aktywnych mountow z prefiksem '$MOUNT_PREFIX'."
    fi
  else
    fail "Nie udalo sie sparsowac status-json.xsl."
  fi
fi

echo ""
echo "-- Test endpointu metadata --"
if [[ -z "$METADATA_USER" || -z "$METADATA_PASSWORD" ]]; then
  fail "Pomijam test metadata: brak metadata_user/metadata_password."
else
  PROBE_QUERY="mode=updinfo&mount=%2F__doctor_probe__&song=doctor-probe"
  METADATA_OK=0
  METADATA_REACHABLE=0
  for endpoint in "/admin/metadata" "/admin/metadata.xsl"; do
    body_path="$TMP_DIR/meta$(echo "$endpoint" | tr '/.' '__').txt"
    http_code="$(
      curl -sS --max-time "$TIMEOUT" --connect-timeout 5 \
        -u "$METADATA_USER:$METADATA_PASSWORD" \
        -o "$body_path" -w "%{http_code}" \
        "$BASE_URL$endpoint?$PROBE_QUERY" || true
    )"
    body_text="$(tr -d '\r' < "$body_path" 2>/dev/null || true)"

    if [[ "$http_code" == "404" ]]; then
      warn "Endpoint $endpoint nie istnieje (HTTP 404), probuje kolejny."
      continue
    fi
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
      fail "Brak autoryzacji do $endpoint (HTTP $http_code)."
      METADATA_OK=1
      break
    fi
    if [[ "$http_code" == "400" ]]; then
      if echo "$body_text" | grep -qiE "authentication required|unauthorized|forbidden"; then
        fail "Endpoint $endpoint odpowiedzial HTTP 400, ale odrzucil autoryzacje."
      else
        warn "Endpoint $endpoint odpowiada HTTP 400 (stare Icecasty tak czasem odpowiadaja na probe)."
        METADATA_REACHABLE=1
      fi
      METADATA_OK=1
      break
    fi
    if [[ "$http_code" == "000" || -z "$http_code" ]]; then
      warn "Brak odpowiedzi z $endpoint."
      continue
    fi
    if [[ "$http_code" =~ ^2 ]]; then
      if echo "$body_text" | grep -qiE "authentication required|unauthorized|forbidden"; then
        fail "Endpoint $endpoint odpowiedzial, ale odrzucil autoryzacje."
      elif echo "$body_text" | grep -qiE "no such mount|mountpoint does not exist|unknown mount|not found"; then
        ok "Endpoint $endpoint dziala, autoryzacja OK (test na fikcyjnym mouncie)."
        METADATA_REACHABLE=1
      elif echo "$body_text" | grep -qi "Mountpoint will not accept URL updates"; then
        fail "Endpoint $endpoint dziala, ale konto nie moze aktualizowac metadanych."
      else
        ok "Endpoint $endpoint odpowiada poprawnie (HTTP $http_code)."
        METADATA_REACHABLE=1
      fi
      METADATA_OK=1
      break
    fi

    warn "Endpoint $endpoint odpowiedzial HTTP $http_code."
  done

  if [[ "$METADATA_OK" -eq 0 ]]; then
    fail "Nie udalo sie zweryfikowac /admin/metadata ani /admin/metadata.xsl."
  elif [[ "$METADATA_REACHABLE" -eq 0 ]]; then
    warn "Nie potwierdzono wprost aktualizacji metadanych (sprawdz prawa konta i mounty)."
  fi
fi

echo ""
echo "-- Status uslug systemd --"
if command -v systemctl >/dev/null 2>&1; then
  SERVICE_NAME="icecast-metadata-updater.service"
  TIMER_NAME="icecast-metadata-updater-autoupdate.timer"

  service_active="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
  service_enabled="$(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
  timer_active="$(systemctl --user is-active "$TIMER_NAME" 2>/dev/null || true)"
  timer_enabled="$(systemctl --user is-enabled "$TIMER_NAME" 2>/dev/null || true)"

  if [[ "$service_active" == "active" ]]; then
    ok "Usluga $SERVICE_NAME jest aktywna."
  else
    warn "Usluga $SERVICE_NAME nie jest aktywna (stan: ${service_active:-unknown})."
  fi

  if [[ "$service_enabled" == "enabled" ]]; then
    ok "Autostart $SERVICE_NAME jest wlaczony."
  else
    warn "Autostart $SERVICE_NAME: ${service_enabled:-unknown}."
  fi

  if [[ "$timer_enabled" == "enabled" || "$timer_active" == "active" ]]; then
    ok "Timer auto-update ($TIMER_NAME) jest skonfigurowany."
  else
    warn "Timer auto-update ($TIMER_NAME) nie jest wlaczony."
  fi
else
  warn "Brak komendy systemctl - pomijam test uslug."
fi

echo ""
echo "-- Logi --"
LOG_PATH="$INSTALL_DIR/logs/updater.log"
if [[ -f "$LOG_PATH" ]]; then
  ok "Znaleziono log: $LOG_PATH"
  echo "Ostatnie $LOG_LINES linii:"
  tail -n "$LOG_LINES" "$LOG_PATH" | sed 's/^/  /'
else
  warn "Brak pliku loga: $LOG_PATH"
fi

if [[ "$RUN_DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "-- Test dry-run --"
  if [[ -f "$INSTALL_DIR/weather_metadata_updater.py" ]]; then
    DRY_OUT="$TMP_DIR/dry_run.log"
    if python3 "$INSTALL_DIR/weather_metadata_updater.py" --config "$CONFIG_PATH" --once --dry-run >"$DRY_OUT" 2>&1; then
      ok "Dry-run wykonany poprawnie."
      echo "Podsumowanie dry-run:"
      tail -n 20 "$DRY_OUT" | sed 's/^/  /'
    else
      fail "Dry-run zakonczony bledem."
      tail -n 30 "$DRY_OUT" | sed 's/^/  /'
    fi
  else
    warn "Brak pliku $INSTALL_DIR/weather_metadata_updater.py (pomijam dry-run)."
  fi
fi

echo ""
echo "=== Podsumowanie ==="
echo "OK   : $PASS_COUNT"
echo "WARN : $WARN_COUNT"
echo "BLAD : $FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
