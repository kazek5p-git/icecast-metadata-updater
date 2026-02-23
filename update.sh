#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/icecast-metadata-updater"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
PULL_LATEST=0
USE_SOURCE_CONFIG=0

print_help() {
  cat <<EOF
Uzycie:
  ./update.sh [--install-dir KATALOG] [--pull] [--use-source-config]

Opcje:
  --install-dir KATALOG   Katalog docelowy instalacji (domyslnie: $DEFAULT_INSTALL_DIR)
  --pull                  Przed aktualizacja wykonaj: git pull --ff-only
  --use-source-config     Przy pierwszej instalacji kopiuj lokalny config.json

Przyklady:
  ./update.sh
  ./update.sh --pull
  ./update.sh --install-dir "$HOME/moj-updater-icecast"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --install-dir" >&2; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --pull)
      PULL_LATEST=1
      shift
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

if [[ "$PULL_LATEST" -eq 1 ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "Brak komendy git, nie moge wykonac --pull" >&2
    exit 1
  fi
  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Biezacy katalog nie jest repozytorium git, pomijam --pull" >&2
    exit 1
  fi
  git -C "$SCRIPT_DIR" pull --ff-only
fi

INSTALL_ARGS=(--install-dir "$INSTALL_DIR")
if [[ "$USE_SOURCE_CONFIG" -eq 1 ]]; then
  INSTALL_ARGS+=(--use-source-config)
fi

"$SCRIPT_DIR/install.sh" "${INSTALL_ARGS[@]}"

echo
echo "Aktualizacja zakonczona."
echo "Wersja z katalogu: $SCRIPT_DIR"
echo "Instalacja: $INSTALL_DIR"
