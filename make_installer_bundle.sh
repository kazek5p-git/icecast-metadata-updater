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

collect_manifest_changes_json() {
  local max_entries=20
  local output=""

  if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if output="$(
      git -C "$SCRIPT_DIR" log --max-count "$max_entries" --date=short --pretty=format:'%h%x1f%ad%x1f%s' \
        | python3 -c 'import json,sys
items = []
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\x1f", 2)
    if len(parts) != 3:
        continue
    short_hash, commit_date, subject = parts
    items.append(f"{commit_date} {short_hash} - {subject}")
print(json.dumps(items, ensure_ascii=False))'
    )"; then
      echo "$output"
      return
    fi
  fi

  echo "[]"
}

write_manifest() {
  local path="$1"
  local version="$2"
  local archive_name="$3"
  local sha256="$4"
  local generated_at="$5"
  local site_url="$6"
  local changelog_name="$7"
  local install_script_name="$8"
  local doctor_script_name="$9"
  local manifest_changes_json="${10:-[]}"

  {
    echo "{"
    echo "  \"version\": \"$version\","
    echo "  \"tarball\": \"$archive_name\","
    echo "  \"changelog\": \"$changelog_name\","
    echo "  \"install_script\": \"$install_script_name\","
    echo "  \"doctor_script\": \"$doctor_script_name\","
    echo "  \"changes\": $manifest_changes_json,"
    if [[ -n "$site_url" ]]; then
      echo "  \"tarball_url\": \"$site_url/$archive_name\","
      echo "  \"sha256_url\": \"$site_url/$archive_name.sha256\","
      echo "  \"changelog_url\": \"$site_url/$changelog_name\","
      echo "  \"install_script_url\": \"$site_url/$install_script_name\","
      echo "  \"doctor_script_url\": \"$site_url/$doctor_script_name\","
    fi
    echo "  \"sha256\": \"$sha256\","
    echo "  \"generated_at_utc\": \"$generated_at\""
    echo "}"
  } > "$path"
}

write_changelog() {
  local path="$1"
  local version="$2"
  local generated_at="$3"
  local max_entries=20

  {
    echo "# Changelog"
    echo
    echo "Automatycznie wygenerowana lista zmian dla publikacji updatera."
    echo
    echo "## Wersja $version ($generated_at UTC)"
    echo

    if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      while IFS=$'\x1f' read -r short_hash commit_date subject; do
        [[ -z "$short_hash" ]] && continue
        echo "- $commit_date $short_hash - $subject"
      done < <(git -C "$SCRIPT_DIR" log --max-count "$max_entries" --date=short --pretty=format:'%h%x1f%ad%x1f%s')
    else
      echo "- Brak historii Git, lista zmian niedostepna."
    fi

    echo
    echo "_Plik wygenerowany przez make_installer_bundle.sh_"
  } > "$path"
}

write_index() {
  local path="$1"
  local version="$2"
  local generated_at="$3"
  local archive_name="$4"
  local site_url="$5"
  local changelog_name="$6"
  local install_script_name="$7"
  local doctor_script_name="$8"
  local manifest_url_hint
  local archive_url_hint
  local install_script_url_hint
  local doctor_script_url_hint
  local online_cmd

  if [[ -n "$site_url" ]]; then
    manifest_url_hint="$site_url/latest.json"
    archive_url_hint="$site_url/$archive_name"
    install_script_url_hint="$site_url/$install_script_name"
    doctor_script_url_hint="$site_url/$doctor_script_name"
  else
    manifest_url_hint="<TWOJ_URL>/latest.json"
    archive_url_hint="$archive_name"
    install_script_url_hint="<TWOJ_URL>/$install_script_name"
    doctor_script_url_hint="<TWOJ_URL>/$doctor_script_name"
  fi
  online_cmd="curl -fsSL $install_script_url_hint | bash"

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
    .hero {
      margin-bottom: 18px;
      padding: 16px 18px;
      border: 1px solid #cfe1ff;
      border-radius: 14px;
      background: linear-gradient(130deg, #edf6ff 0%, #fff8ec 50%, #edfaff 100%);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
    }
    .hero-copy { min-width: 0; }
    .hero-kicker {
      margin: 0 0 4px;
      color: #1b4f99;
      font-size: 0.84rem;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      font-weight: 700;
    }
    h1 { margin: 0 0 8px; font-size: 1.55rem; }
    .icon-row {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }
    .icon-chip {
      width: 62px;
      height: 62px;
      border-radius: 14px;
      border: 1px solid #d6e5fb;
      background: #ffffff;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 5px 14px rgba(20, 49, 90, 0.1);
    }
    .icon-chip svg {
      width: 38px;
      height: 38px;
      display: block;
    }
    p { margin: 0 0 12px; color: var(--muted); }
    .meta {
      margin: 18px 0;
      padding: 14px;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: #f8fbff;
    }
    .warn {
      margin: 18px 0;
      padding: 14px;
      border: 1px solid #f3d7a8;
      border-radius: 12px;
      background: #fff8ea;
      color: #5c4320;
    }
    .links {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 8px;
    }
    ol {
      margin: 8px 0 12px;
      padding-left: 22px;
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
    @media (max-width: 760px) {
      main { padding: 18px; }
      .hero {
        flex-direction: column;
        align-items: flex-start;
      }
      .icon-row {
        justify-content: flex-start;
      }
      .icon-chip {
        width: 56px;
        height: 56px;
      }
      .icon-chip svg {
        width: 34px;
        height: 34px;
      }
    }
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <div class="hero-copy">
        <p class="hero-kicker">Pogoda + metadane</p>
        <h1>Icecast Metadata Updater</h1>
        <p>Publiczny punkt aktualizacji programu. Paczka i manifest poniżej są wykorzystywane przez auto-update.</p>
      </div>
      <div class="icon-row" aria-hidden="true">
        <div class="icon-chip">
          <svg viewBox="0 0 64 64" role="presentation">
            <defs>
              <linearGradient id="cloudFill" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stop-color="#e6f2ff"/>
                <stop offset="100%" stop-color="#bcd7ff"/>
              </linearGradient>
            </defs>
            <path d="M16 42h31a9 9 0 0 0 0-18 13 13 0 0 0-24-4 9 9 0 0 0-7 22z" fill="url(#cloudFill)" stroke="#6aa9ff" stroke-width="2"/>
          </svg>
        </div>
        <div class="icon-chip">
          <svg viewBox="0 0 64 64" role="presentation">
            <circle cx="32" cy="32" r="12" fill="#ffbe3d"/>
            <g stroke="#ff9d00" stroke-width="4" stroke-linecap="round">
              <line x1="32" y1="6" x2="32" y2="14"/>
              <line x1="32" y1="50" x2="32" y2="58"/>
              <line x1="6" y1="32" x2="14" y2="32"/>
              <line x1="50" y1="32" x2="58" y2="32"/>
              <line x1="14" y1="14" x2="19" y2="19"/>
              <line x1="45" y1="45" x2="50" y2="50"/>
              <line x1="14" y1="50" x2="19" y2="45"/>
              <line x1="45" y1="19" x2="50" y2="14"/>
            </g>
          </svg>
        </div>
        <div class="icon-chip">
          <svg viewBox="0 0 64 64" role="presentation">
            <path d="M20 40h24a10 10 0 0 0 0-20 13 13 0 0 0-24-4 9 9 0 0 0 0 24z" fill="#7db4ff"/>
            <g stroke="#1f7bf2" stroke-width="3.5" stroke-linecap="round">
              <line x1="22" y1="46" x2="18" y2="54"/>
              <line x1="32" y1="46" x2="28" y2="54"/>
              <line x1="42" y1="46" x2="38" y2="54"/>
            </g>
          </svg>
        </div>
        <div class="icon-chip">
          <svg viewBox="0 0 64 64" role="presentation">
            <circle cx="32" cy="32" r="4" fill="#6aa9ff"/>
            <g stroke="#6aa9ff" stroke-width="3.5" stroke-linecap="round">
              <line x1="32" y1="14" x2="32" y2="50"/>
              <line x1="14" y1="32" x2="50" y2="32"/>
              <line x1="19" y1="19" x2="45" y2="45"/>
              <line x1="45" y1="19" x2="19" y2="45"/>
            </g>
          </svg>
        </div>
      </div>
    </section>
    <section class="meta">
      <p><strong>Wersja:</strong> $version</p>
      <p><strong>Wygenerowano (UTC):</strong> $generated_at</p>
      <div class="links">
        <a class="btn alt" href="$install_script_name">Instalator online</a>
        <a class="btn alt" href="$doctor_script_name">Skrypt doctor.sh</a>
        <a class="btn" href="$archive_name">Pobierz paczkę</a>
        <a class="btn alt" href="$archive_name.sha256">Suma SHA256</a>
        <a class="btn alt" href="latest.json">Manifest latest.json</a>
        <a class="btn alt" href="$changelog_name">Changelog</a>
      </div>
    </section>
    <p><strong>Instalacja 1 komendą (online):</strong></p>
    <pre><code>$online_cmd</code></pre>
    <p>Opis zmian znajduje się w pliku <code>$changelog_name</code>.</p>
    <section class="warn">
      <p><strong>Ważne:</strong> samo pobranie paczki <code>.tar.gz</code> nie uruchamia programu.</p>
      <p>Potrzebna jest instalacja z paczki (działa także od zera, bez wcześniejszej instalacji).</p>
    </section>
    <p><strong>Instalacja ręczna (manualna):</strong></p>
    <ol>
      <li>Pobierz paczkę: <code>$archive_url_hint</code></li>
      <li>Rozpakuj: <code>tar -xzf $archive_name</code></li>
      <li>Wejdź do katalogu i uruchom: <code>./install.sh</code></li>
      <li>Uruchom kreator konfiguracji: <code>python3 ~/icecast-metadata-updater/config_wizard.py --config ~/icecast-metadata-updater/config.json</code></li>
      <li>Sprawdź konfigurację: <code>python3 ~/icecast-metadata-updater/weather_metadata_updater.py --once --dry-run</code></li>
      <li>Opcjonalnie włącz auto-update z manifestu poniżej</li>
    </ol>
    <p>Przykład włączenia automatycznej aktualizacji:</p>
    <pre><code>cd ~/icecast-metadata-updater
./enable_auto_update.sh --manifest-url "$manifest_url_hint" --run-now</code></pre>
    <p>Szybka diagnostyka instalacji:</p>
    <pre><code>~/icecast-metadata-updater/doctor.sh --install-dir ~/icecast-metadata-updater --config ~/icecast-metadata-updater/config.json --run-dry-run</code></pre>
    <p>Alternatywnie pobierz sam skrypt diagnostyczny: <code>$doctor_script_url_hint</code></p>
    <p>Wymagania: Linux, python3, systemd --user.</p>
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
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CHANGELOG_NAME="CHANGELOG.md"
CHANGELOG_PATH="$OUT_DIR/$CHANGELOG_NAME"
INSTALL_SCRIPT_NAME="install_online.sh"
DOCTOR_SCRIPT_NAME="doctor.sh"

mkdir -p "$PKG_DIR/systemd"
mkdir -p "$OUT_DIR"
write_changelog "$CHANGELOG_PATH" "$VERSION" "$GENERATED_AT_UTC"

cp "$SCRIPT_DIR/weather_metadata_updater.py" "$PKG_DIR/"
cp "$SCRIPT_DIR/config_wizard.py" "$PKG_DIR/"
cp "$SCRIPT_DIR/install_online.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/doctor.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/start_updater.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/auto_update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/enable_auto_update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/install.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/update.sh" "$PKG_DIR/"
cp "$SCRIPT_DIR/auto_update.example.conf" "$PKG_DIR/"
cp "$SCRIPT_DIR/config.example.json" "$PKG_DIR/"
cp "$SCRIPT_DIR/README.md" "$PKG_DIR/"
cp "$CHANGELOG_PATH" "$PKG_DIR/$CHANGELOG_NAME"
cp "$SCRIPT_DIR/systemd/icecast-metadata-updater.service" "$PKG_DIR/systemd/"

chmod +x "$PKG_DIR/start_updater.sh" "$PKG_DIR/auto_update.sh" \
  "$PKG_DIR/config_wizard.py" "$PKG_DIR/install_online.sh" \
  "$PKG_DIR/doctor.sh" "$PKG_DIR/enable_auto_update.sh" \
  "$PKG_DIR/install.sh" "$PKG_DIR/update.sh"

ARCHIVE_PATH="$OUT_DIR/$PKG_NAME.tar.gz"
(
  cd "$STAGE_DIR"
  tar -czf "$ARCHIVE_PATH" "$PKG_NAME"
)

CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_PATH"
SHA_VALUE="$(awk '{print $1}' "$CHECKSUM_PATH")"

LATEST_JSON_PATH="$OUT_DIR/latest.json"
ARCHIVE_NAME="$(basename "$ARCHIVE_PATH")"
MANIFEST_CHANGES_JSON="$(collect_manifest_changes_json)"
write_manifest "$LATEST_JSON_PATH" "$VERSION" "$ARCHIVE_NAME" "$SHA_VALUE" "$GENERATED_AT_UTC" "$SITE_URL" "$CHANGELOG_NAME" "$INSTALL_SCRIPT_NAME" "$DOCTOR_SCRIPT_NAME" "$MANIFEST_CHANGES_JSON"

if [[ -n "$PUBLISH_DIR" ]]; then
  mkdir -p "$PUBLISH_DIR"

  if [[ "$CLEAN_PUBLISH" -eq 1 ]]; then
    find "$PUBLISH_DIR" -maxdepth 1 -type f \
      \( -name 'icecast-metadata-updater-*.tar.gz' -o -name 'icecast-metadata-updater-*.tar.gz.sha256' \) \
      -delete
  fi

  cp -f "$ARCHIVE_PATH" "$PUBLISH_DIR/"
  cp -f "$CHECKSUM_PATH" "$PUBLISH_DIR/"
  cp -f "$CHANGELOG_PATH" "$PUBLISH_DIR/$CHANGELOG_NAME"
  cp -f "$SCRIPT_DIR/install_online.sh" "$PUBLISH_DIR/$INSTALL_SCRIPT_NAME"
  cp -f "$SCRIPT_DIR/doctor.sh" "$PUBLISH_DIR/$DOCTOR_SCRIPT_NAME"
  cp -f "$LATEST_JSON_PATH" "$PUBLISH_DIR/latest.json"
  write_index "$PUBLISH_DIR/index.html" "$VERSION" "$GENERATED_AT_UTC" "$ARCHIVE_NAME" "$SITE_URL" "$CHANGELOG_NAME" "$INSTALL_SCRIPT_NAME" "$DOCTOR_SCRIPT_NAME"
fi

rm -rf "$STAGE_DIR"

echo "Paczka gotowa: $ARCHIVE_PATH"
echo "Suma SHA256: $CHECKSUM_PATH"
echo "Changelog: $CHANGELOG_PATH"
echo "Manifest: $LATEST_JSON_PATH"
if [[ -n "$PUBLISH_DIR" ]]; then
  echo "Publikacja WWW: $PUBLISH_DIR"
  if [[ -n "$SITE_URL" ]]; then
    echo "URL manifestu: $SITE_URL/latest.json"
    echo "URL strony: $SITE_URL/"
    echo "URL instalatora online: $SITE_URL/$INSTALL_SCRIPT_NAME"
    echo "URL diagnostyki: $SITE_URL/$DOCTOR_SCRIPT_NAME"
    echo "URL changelogu: $SITE_URL/$CHANGELOG_NAME"
  fi
fi
echo "Instalacja ręczna (manualna):"
echo "  tar -xzf $ARCHIVE_NAME"
echo "  cd $PKG_NAME"
echo "  ./install.sh"
echo "  python3 ~/icecast-metadata-updater/config_wizard.py --config ~/icecast-metadata-updater/config.json"
echo "  ~/icecast-metadata-updater/doctor.sh --install-dir ~/icecast-metadata-updater --config ~/icecast-metadata-updater/config.json --run-dry-run"
