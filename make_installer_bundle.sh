#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/dist"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: $1" >&2
    exit 1
  fi
}

require_cmd tar
require_cmd sha256sum

if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VERSION="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)"
else
  VERSION="$(date +%Y%m%d-%H%M%S)"
fi

PKG_NAME="icecast-metadata-updater-$VERSION"
STAGE_DIR="$(mktemp -d)"
PKG_DIR="$STAGE_DIR/$PKG_NAME"

mkdir -p "$PKG_DIR/systemd"
mkdir -p "$OUT_DIR"

cp "$SCRIPT_DIR/weather_metadata_updater.py" "$PKG_DIR/"
cp "$SCRIPT_DIR/start_updater.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/install.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/config.example.json" "$PKG_DIR/"
cp "$SCRIPT_DIR/README.md" "$PKG_DIR/"
cp "$SCRIPT_DIR/systemd/icecast-metadata-updater.service" "$PKG_DIR/systemd/"

chmod +x "$PKG_DIR/start_updater.sh" "$PKG_DIR/install.sh" "$PKG_DIR/update.sh"

ARCHIVE_PATH="$OUT_DIR/$PKG_NAME.tar.gz"
(
  cd "$STAGE_DIR"
  tar -czf "$ARCHIVE_PATH" "$PKG_NAME"
)

CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

rm -rf "$STAGE_DIR"

echo "Paczka gotowa: $ARCHIVE_PATH"
echo "Suma SHA256: $CHECKSUM_PATH"
echo "Instalacja u znajomego:"
echo "  tar -xzf $(basename "$ARCHIVE_PATH")"
echo "  cd $PKG_NAME"
echo "  ./install.sh"
