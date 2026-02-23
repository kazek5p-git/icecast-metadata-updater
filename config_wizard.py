#!/usr/bin/env python3
"""Interaktywny kreator konfiguracji config.json."""

from __future__ import annotations

import argparse
import base64
import json
import sys
from copy import deepcopy
from getpass import getpass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import Request, urlopen

TITLE_TEMPLATE_PRESETS = {
    "outside": (
        "(outside from {city_ascii}, quality 320kbps mp3 "
        "temperatura: {temp}°C, odczuwalna {feels}°C, wiatr {wind} km/h{wind_details_clause}, "
        "{condition}{precip_clause}{pressure_clause}{air_clause})"
    ),
    "weather": (
        "temperatura: {temp}°C, odczuwalna {feels}°C, wiatr {wind} km/h{wind_details_clause}, "
        "{condition}{precip_clause}{pressure_clause}{air_clause}"
    ),
    "classic": (
        "{city}: Temperatura: {temp}°C, odczuwalna {feels}°C, "
        "wiatr {wind} km/h{wind_details_clause}, {condition}{precip_clause}{pressure_clause}{air_clause}"
    ),
}


DEFAULT_CONFIG = {
    "icecast": {
        "base_url": "http://127.0.0.1:8888",
        "source_user": "source",
        "source_password": None,
        "metadata_user": None,
        "metadata_password": None,
        "status_user": None,
        "status_password": None,
    },
    "streams": {
        "mount_prefix": "outside_",
        "city_overrides": {},
    },
    "weather": {
        "country_code": "PL",
        "language": "pl",
        "timezone": "Europe/Warsaw",
    },
    "update": {
        "interval_seconds": 600,
        "dry_run": False,
    },
    "title_mode": "outside",
}


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"Plik {path} nie zawiera obiektu JSON.")
    return data


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def deep_get(data: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current: Any = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def is_placeholder_password(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    raw = value.strip().upper()
    return raw.startswith("CHANGE_ME") or raw == ""


def prompt_text(label: str, default: str | None = None, allow_empty: bool = False) -> str:
    while True:
        suffix = f" [{default}]" if default is not None else ""
        answer = input(f"{label}{suffix}: ").strip()
        if answer:
            return answer
        if default is not None:
            return default
        if allow_empty:
            return ""
        print("To pole nie może być puste.")


def prompt_yes_no(label: str, default: bool = True) -> bool:
    marker = "T/n" if default else "t/N"
    while True:
        answer = input(f"{label} [{marker}]: ").strip().lower()
        if not answer:
            return default
        if answer in {"t", "tak", "y", "yes"}:
            return True
        if answer in {"n", "nie", "no"}:
            return False
        print("Wpisz 't' lub 'n'.")


def prompt_minutes(label: str, default: int) -> int:
    while True:
        raw = input(f"{label} [{default}]: ").strip()
        if not raw:
            return default
        try:
            value = int(raw)
        except ValueError:
            print("Podaj liczbę całkowitą.")
            continue
        if value < 1:
            print("Minimalna wartość to 1 minuta.")
            continue
        return value


def prompt_choice(label: str, options: list[tuple[str, str]], default_key: str) -> str:
    idx_map = {str(idx): key for idx, (key, _desc) in enumerate(options, start=1)}
    while True:
        print(label)
        for idx, (key, desc) in enumerate(options, start=1):
            marker = " (domyślnie)" if key == default_key else ""
            print(f"  {idx}. {key}{marker} - {desc}")
        raw = input("Wybór [ENTER = domyślny]: ").strip()
        if not raw:
            return default_key
        if raw in idx_map:
            return idx_map[raw]
        raw_lower = raw.lower()
        if any(raw_lower == key for key, _desc in options):
            return raw_lower
        print("Wpisz numer opcji albo nazwę trybu.")


def prompt_password(label: str, existing_value: str | None) -> str:
    has_existing = bool(existing_value)
    while True:
        prompt = f"{label} [ENTER = bez zmian]: " if has_existing else f"{label}: "
        value = getpass(prompt)
        if value:
            return value
        if has_existing:
            return existing_value or ""
        print("Hasło nie może być puste.")


def normalize_base_url(raw: str) -> str:
    value = raw.strip()
    if "://" not in value:
        value = f"http://{value}"
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Dozwolone są tylko schematy http/https.")
    if not parsed.netloc:
        raise ValueError("Brak hosta w adresie Icecast.")
    path = parsed.path.rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path}"


def build_auth_header(username: str, password: str) -> str:
    token = f"{username}:{password}".encode("utf-8")
    encoded = base64.b64encode(token).decode("ascii")
    return f"Basic {encoded}"


def http_get_json(url: str, auth: tuple[str, str] | None = None, timeout: int = 12) -> Any:
    request = Request(url)
    if auth:
        request.add_header("Authorization", build_auth_header(auth[0], auth[1]))
    with urlopen(request, timeout=timeout) as response:
        payload = response.read().decode("utf-8", errors="replace")
    return json.loads(payload)


def extract_mount(source: dict[str, Any]) -> str | None:
    listen_url = str(source.get("listenurl", "")).strip()
    if listen_url:
        parsed = urlparse(listen_url)
        mount = parsed.path.strip()
        if mount.startswith("/"):
            return mount.lstrip("/")
    mount = str(source.get("mount", "")).strip()
    if mount.startswith("/"):
        mount = mount.lstrip("/")
    return mount or None


def run_status_test(config: dict[str, Any]) -> None:
    icecast = config["icecast"]
    streams = config["streams"]
    base_url = str(icecast["base_url"]).rstrip("/")
    status_url = f"{base_url}/status-json.xsl"
    auth: tuple[str, str] | None = None

    status_user = icecast.get("status_user")
    status_password = icecast.get("status_password")
    if status_user and status_password:
        auth = (str(status_user), str(status_password))

    data = http_get_json(status_url, auth=auth)
    sources = deep_get(data, "icestats", "source", default=[])
    if isinstance(sources, dict):
        sources = [sources]
    if not isinstance(sources, list):
        raise ValueError("Niepoprawny format status-json.xsl (pole icestats.source).")

    mounts: list[str] = []
    prefix = str(streams["mount_prefix"])
    for source in sources:
        if not isinstance(source, dict):
            continue
        mount = extract_mount(source)
        if mount:
            mounts.append(mount)

    outside_mounts = sorted({m for m in mounts if m.startswith(prefix)})
    print("")
    print("Test połączenia: OK")
    print(f"- endpoint: {status_url}")
    print(f"- liczba aktywnych źródeł: {len(mounts)}")
    print(f"- liczba mountów z prefiksem '{prefix}': {len(outside_mounts)}")
    if outside_mounts:
        preview = ", ".join(outside_mounts[:6])
        if len(outside_mounts) > 6:
            preview += ", ..."
        print(f"- wykryte mounty: {preview}")
    else:
        print("- nie wykryto mountów z tym prefiksem (to może być normalne, jeśli teraz nie nadają)")


def ensure_dict(data: dict[str, Any], key: str) -> dict[str, Any]:
    current = data.get(key)
    if isinstance(current, dict):
        return current
    data[key] = {}
    return data[key]


def build_initial_config(script_dir: Path, config_path: Path) -> dict[str, Any]:
    initial = deepcopy(DEFAULT_CONFIG)
    example_path = script_dir / "config.example.json"
    if example_path.exists():
        try:
            initial = deep_merge(initial, load_json(example_path))
        except Exception:
            pass
    if config_path.exists():
        initial = deep_merge(initial, load_json(config_path))
    return initial


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interaktywny kreator konfiguracji Icecast Metadata Updater"
    )
    parser.add_argument("--config", default="config.json", help="Ścieżka do pliku config.json")
    parser.add_argument(
        "--no-test",
        action="store_true",
        help="Pomiń test połączenia do status-json.xsl po zapisaniu konfiguracji",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    config_path = Path(args.config).expanduser()
    if not config_path.is_absolute():
        config_path = (Path.cwd() / config_path).resolve()

    try:
        config = build_initial_config(script_dir, config_path)
    except Exception as exc:
        print(f"Błąd odczytu konfiguracji: {exc}", file=sys.stderr)
        return 2

    print("=== Kreator konfiguracji Icecast Metadata Updater ===")
    print("ENTER przyjmuje wartość domyślną.")
    print("")

    raw_base_url = prompt_text(
        "Adres Icecast (base_url)",
        str(deep_get(config, "icecast", "base_url", default=DEFAULT_CONFIG["icecast"]["base_url"])),
    )
    while True:
        try:
            base_url = normalize_base_url(raw_base_url)
            break
        except ValueError as exc:
            print(f"Błąd: {exc}")
            raw_base_url = prompt_text("Adres Icecast (base_url)")

    source_user = prompt_text(
        "Użytkownik source",
        str(deep_get(config, "icecast", "source_user", default=DEFAULT_CONFIG["icecast"]["source_user"])),
    )

    existing_source_password = deep_get(config, "icecast", "source_password")
    if is_placeholder_password(existing_source_password):
        existing_source_password = None
    source_password = prompt_password("Hasło source", str(existing_source_password) if existing_source_password else None)

    existing_metadata_user = deep_get(config, "icecast", "metadata_user")
    existing_metadata_password = deep_get(config, "icecast", "metadata_password")
    if is_placeholder_password(existing_metadata_password):
        existing_metadata_password = None

    same_as_source_default = not existing_metadata_user or str(existing_metadata_user) == str(source_user)
    if prompt_yes_no("Użyć tych samych danych dla metadata (admin/metadata)?", same_as_source_default):
        metadata_user = source_user
        metadata_password = source_password
    else:
        metadata_user = prompt_text(
            "Użytkownik metadata",
            str(existing_metadata_user) if existing_metadata_user else "admin",
        )
        metadata_password = prompt_password(
            "Hasło metadata",
            str(existing_metadata_password) if existing_metadata_password else None,
        )

    existing_status_user = deep_get(config, "icecast", "status_user")
    existing_status_password = deep_get(config, "icecast", "status_password")
    if is_placeholder_password(existing_status_password):
        existing_status_password = None

    use_status_auth_default = bool(existing_status_user)
    if prompt_yes_no("Czy status-json.xsl wymaga logowania?", use_status_auth_default):
        status_user = prompt_text(
            "Użytkownik status-json",
            str(existing_status_user) if existing_status_user else metadata_user,
        )
        status_password = prompt_password(
            "Hasło status-json",
            str(existing_status_password) if existing_status_password else None,
        )
    else:
        status_user = None
        status_password = None

    mount_prefix = prompt_text(
        "Prefiks mountów",
        str(deep_get(config, "streams", "mount_prefix", default=DEFAULT_CONFIG["streams"]["mount_prefix"])),
    ).lstrip("/")

    current_interval_seconds = int(
        deep_get(config, "update", "interval_seconds", default=DEFAULT_CONFIG["update"]["interval_seconds"])
    )
    default_interval_minutes = max(1, round(current_interval_seconds / 60))
    interval_minutes = prompt_minutes("Interwał odświeżania (minuty)", default_interval_minutes)
    interval_seconds = interval_minutes * 60

    existing_mode_raw = str(deep_get(config, "title_mode", default=DEFAULT_CONFIG["title_mode"])).lower().strip()
    default_mode = existing_mode_raw if existing_mode_raw in TITLE_TEMPLATE_PRESETS else "outside"
    title_mode = prompt_choice(
        "Tryb tytułu metadanych:",
        [
            ("classic", "Łódź: Temperatura: 6°C, odczuwalna 4°C, wiatr 12 km/h, porywy 24 km/h, kierunek SW, ciśnienie 1014 hPa, jakość powietrza: dobra (AQI 28)"),
            ("outside", "outside from Lodz, quality 320kbps mp3 temperatura: 6°C, odczuwalna 4°C, wiatr 12 km/h, porywy 24 km/h, kierunek SW, ..."),
            ("weather", "temperatura: 6°C, odczuwalna 4°C, wiatr 12 km/h, porywy 24 km/h, kierunek SW, ..."),
        ],
        default_mode,
    )

    existing_template_raw = deep_get(config, "title_template")
    existing_template = (
        str(existing_template_raw).strip()
        if isinstance(existing_template_raw, str) and str(existing_template_raw).strip()
        else ""
    )
    existing_is_custom = bool(existing_template) and existing_template not in TITLE_TEMPLATE_PRESETS.values()
    if prompt_yes_no("Użyć własnego niestandardowego title_template?", existing_is_custom):
        custom_default = existing_template if existing_template else TITLE_TEMPLATE_PRESETS[title_mode]
        custom_template = prompt_text("Własny title_template", custom_default)
        config["title_template"] = custom_template
    else:
        config.pop("title_template", None)
    config["title_mode"] = title_mode

    weather_cfg = ensure_dict(config, "weather")
    if prompt_yes_no("Zmienić ustawienia pogody (kraj/język/strefa)?", False):
        weather_cfg["country_code"] = prompt_text(
            "Kod kraju (country_code)", str(weather_cfg.get("country_code", "PL"))
        ).upper()
        weather_cfg["language"] = prompt_text("Język (language)", str(weather_cfg.get("language", "pl")))
        weather_cfg["timezone"] = prompt_text(
            "Strefa czasowa (timezone)", str(weather_cfg.get("timezone", "Europe/Warsaw"))
        )

    existing_overrides = deep_get(config, "streams", "city_overrides", default={})
    if not isinstance(existing_overrides, dict):
        existing_overrides = {}
    city_overrides: dict[str, str] = {}
    if existing_overrides and prompt_yes_no(
        f"Zachować istniejące mapowania city_overrides ({len(existing_overrides)})?", True
    ):
        city_overrides.update({str(k): str(v) for k, v in existing_overrides.items()})

    if prompt_yes_no("Dodać nowe mapowania city_overrides?", False):
        print("Podawaj pary: mount -> miasto. Puste pole mount kończy dodawanie.")
        while True:
            mount = prompt_text("Mount (np. outside_gdansk)", allow_empty=True).lstrip("/")
            if not mount:
                break
            city = prompt_text("Miasto", allow_empty=False)
            city_overrides[mount] = city

    icecast_cfg = ensure_dict(config, "icecast")
    streams_cfg = ensure_dict(config, "streams")
    update_cfg = ensure_dict(config, "update")

    icecast_cfg["base_url"] = base_url
    icecast_cfg["source_user"] = source_user
    icecast_cfg["source_password"] = source_password
    icecast_cfg["metadata_user"] = metadata_user
    icecast_cfg["metadata_password"] = metadata_password
    icecast_cfg["status_user"] = status_user
    icecast_cfg["status_password"] = status_password

    streams_cfg["mount_prefix"] = mount_prefix
    streams_cfg["city_overrides"] = city_overrides

    update_cfg["interval_seconds"] = interval_seconds
    if "dry_run" not in update_cfg:
        update_cfg["dry_run"] = False

    config_path.parent.mkdir(parents=True, exist_ok=True)
    with config_path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print("")
    print(f"Zapisano konfigurację: {config_path}")

    if not args.no_test and prompt_yes_no("Wykonać test połączenia status-json.xsl?", True):
        try:
            run_status_test(config)
        except Exception as exc:
            print("")
            print("Test połączenia: BŁĄD")
            print(f"- {exc}")
            print("Sprawdź adres, hasła i dostęp sieciowy do Icecast.")

    print("")
    print("Kolejny krok:")
    print(f"python3 {script_dir / 'weather_metadata_updater.py'} --config {config_path} --once --dry-run")
    print("Jeśli wynik jest poprawny, zrestartuj usługę:")
    print("systemctl --user restart icecast-metadata-updater.service")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nPrzerwano przez użytkownika.")
        raise SystemExit(130)
