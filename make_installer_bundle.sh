#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/dist"
PUBLISH_DIR=""
SITE_URL=""
CLEAN_PUBLISH=0

print_help() {
  cat <<EOF
Uzycie:
  ./make_installer_bundle.sh [opcje]

Opcje:
  --out-dir KATALOG       Katalog wyjsciowy (domyslnie: $OUT_DIR)
  --publish-dir KATALOG   Publikuj wynik do katalogu WWW
  --site-url URL          Publiczny URL katalogu publikacji (np. https://kazpar.pl/icecast-updater)
  --clean-publish         Przed publikacja usun stare paczki icecast-metadata-updater-*.tar.gz(.sha256)
  -h, --help              Pomoc

Przyklady:
  ./make_installer_bundle.sh
  ./make_installer_bundle.sh --publish-dir "$HOME/www/icecast-updater" --site-url "https://kazpar.pl/icecast-updater"
  ./make_installer_bundle.sh --publish-dir "$HOME/www/icecast-updater" --site-url "https://kazpar.pl/icecast-updater" --clean-publish
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

write_manifest() {
  local path="$1"
  local version="$2"
  local archive_name="$3"
  local sha256="$4"
  local generated_at="$5"
  local site_url="$6"

  {
    echo "{"
    echo "  \"version\": \"$version\","
    echo "  \"tarball\": \"$archive_name\","
    if [[ -n "$site_url" ]]; then
      echo "  \"tarball_url\": \"$site_url/$archive_name\","
      echo "  \"sha256_url\": \"$site_url/$archive_name.sha256\","
    fi
    echo "  \"sha256\": \"$sha256\","
    echo "  \"generated_at_utc\": \"$generated_at\""
    echo "}"
  } > "$path"
}

write_index() {
  local path="$1"
  local version="$2"
  local generated_at="$3"
  local archive_name="$4"
  local site_url="$5"
  local manifest_url_hint

  if [[ -n "$site_url" ]]; then
    manifest_url_hint="$site_url/latest.json"
  else
    manifest_url_hint="<TWOJ_URL>/latest.json"
  fi

  cat > "$path" <<EOF
<!doctype html>
<html lang="pl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Icecast Metadata Updater - aktualizacje</title>
  <style>
    :root {
      --bg: #f4f7fb;
      --panel: #ffffff;
      --text: #18202a;
      --muted: #4d5a69;
      --accent: #0b6ef3;
      --border: #d7dfeb;
      --code-bg: #0f1720;
      --code-text: #f6f8fa;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", "Noto Sans", Arial, sans-serif;
      background: radial-gradient(circle at top left, #e8f0ff, var(--bg) 45%);
      color: var(--text);
      line-height: 1.55;
      padding: 28px 16px;
    }
    main {
      max-width: 860px;
      margin: 0 auto;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 24px;
      box-shadow: 0 10px 30px rgba(8, 20, 38, 0.07);
    }
    h1 { margin: 0 0 8px; font-size: 1.55rem; }
    p { margin: 0 0 12px; color: var(--muted); }
    .meta {
      margin: 18px 0;
      padding: 14px;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: #f8fbff;
    }
    .links {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 8px;
    }
    a.btn {
      text-decoration: none;
      font-weight: 600;
      color: #ffffff;
      background: var(--accent);
      padding: 10px 14px;
      border-radius: 10px;
      border: 1px solid #0a61d4;
    }
    a.btn.alt {
      background: #ffffff;
      color: var(--accent);
      border: 1px solid #a9c6f7;
    }
    pre {
      background: var(--code-bg);
      color: var(--code-text);
      border-radius: 12px;
      padding: 12px;
      overflow: auto;
      font-size: 0.95rem;
    }
    code { font-family: "Cascadia Code", "Fira Code", monospace; }
  </style>
</head>
<body>
  <main>
    <h1>Icecast Metadata Updater</h1>
    <p>Publiczny punkt aktualizacji programu. Paczka i manifest ponizej sa wykorzystywane przez auto-update.</p>
    <section class="meta">
      <p><strong>Wersja:</strong> $version</p>
      <p><strong>Wygenerowano (UTC):</strong> $generated_at</p>
      <div class="links">
        <a class="btn" href="$archive_name">Pobierz paczke</a>
        <a class="btn alt" href="$archive_name.sha256">Suma SHA256</a>
        <a class="btn alt" href="latest.json">Manifest latest.json</a>
      </div>
    </section>
    <p>Przyklad wlaczenia automatycznej aktualizacji u znajomego:</p>
    <pre><code>cd ~/icecast-metadata-updater
./enable_auto_update.sh --manifest-url "$manifest_url_hint" --run-now</code></pre>
  </main>
</body>
</html>
EOF
}

require_cmd tar
require_cmd sha256sum
require_cmd date

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --out-dir" >&2; exit 1; }
      OUT_DIR="$2"
      shift 2
      ;;
    --publish-dir)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --publish-dir" >&2; exit 1; }
      PUBLISH_DIR="$2"
      shift 2
      ;;
    --site-url)
      [[ $# -lt 2 ]] && { echo "Brak wartosci dla --site-url" >&2; exit 1; }
      SITE_URL="$2"
      shift 2
      ;;
    --clean-publish)
      CLEAN_PUBLISH=1
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

if [[ -n "$SITE_URL" ]]; then
  SITE_URL="$(trim_trailing_slash "$SITE_URL")"
fi

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
cp "$SCRIPT_DIR/auto_update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/enable_auto_update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/install.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/auto_update.example.conf" "$PKG_DIR/"
cp "$SCRIPT_DIR/config.example.json" "$PKG_DIR/"
cp "$SCRIPT_DIR/README.md" "$PKG_DIR/"
cp "$SCRIPT_DIR/systemd/icecast-metadata-updater.service" "$PKG_DIR/systemd/"

chmod +x "$PKG_DIR/start_updater.sh" "$PKG_DIR/auto_update.sh" \
  "$PKG_DIR/enable_auto_update.sh" "$PKG_DIR/install.sh" "$PKG_DIR/update.sh"

ARCHIVE_PATH="$OUT_DIR/$PKG_NAME.tar.gz"
(
  cd "$STAGE_DIR"
  tar -czf "$ARCHIVE_PATH" "$PKG_NAME"
)

CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_PATH"
SHA_VALUE="$(awk '{print $1}' "$CHECKSUM_PATH")"
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

LATEST_JSON_PATH="$OUT_DIR/latest.json"
ARCHIVE_NAME="$(basename "$ARCHIVE_PATH")"
write_manifest "$LATEST_JSON_PATH" "$VERSION" "$ARCHIVE_NAME" "$SHA_VALUE" "$GENERATED_AT_UTC" "$SITE_URL"

if [[ -n "$PUBLISH_DIR" ]]; then
  mkdir -p "$PUBLISH_DIR"

  if [[ "$CLEAN_PUBLISH" -eq 1 ]]; then
    find "$PUBLISH_DIR" -maxdepth 1 -type f \
      \( -name 'icecast-metadata-updater-*.tar.gz' -o -name 'icecast-metadata-updater-*.tar.gz.sha256' \) \
      -delete
  fi

  cp -f "$ARCHIVE_PATH" "$PUBLISH_DIR/"
  cp -f "$CHECKSUM_PATH" "$PUBLISH_DIR/"
  cp -f "$LATEST_JSON_PATH" "$PUBLISH_DIR/latest.json"
  write_index "$PUBLISH_DIR/index.html" "$VERSION" "$GENERATED_AT_UTC" "$ARCHIVE_NAME" "$SITE_URL"
fi

rm -rf "$STAGE_DIR"

echo "Paczka gotowa: $ARCHIVE_PATH"
echo "Suma SHA256: $CHECKSUM_PATH"
echo "Manifest: $LATEST_JSON_PATH"
if [[ -n "$PUBLISH_DIR" ]]; then
  echo "Publikacja WWW: $PUBLISH_DIR"
  if [[ -n "$SITE_URL" ]]; then
    echo "URL manifestu: $SITE_URL/latest.json"
    echo "URL strony: $SITE_URL/"
  fi
fi
echo "Instalacja u znajomego:"
echo "  tar -xzf $ARCHIVE_NAME"
echo "  cd $PKG_NAME"
echo "  ./install.sh"
