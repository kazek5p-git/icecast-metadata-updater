#!/usr/bin/env python3
"""Interaktywny kreator konfiguracji config.json."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from copy import deepcopy
from getpass import getpass
from pathlib import Path
from typing import Any, TextIO
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

TITLE_TEMPLATE_PRESETS = {
    "outside": (
        "(outside from {city_ascii}, quality 320kbps mp3 "
        "temperatura: {temp}°C, odczuwalna {feels}°C, wiatr {wind} km/h{wind_details_clause}, "
        "{condition}{precip_clause}{pressure_clause}{humidity_clause}{air_clause})"
    ),
    "weather": (
        "temperatura: {temp}°C, odczuwalna {feels}°C, wiatr {wind} km/h{wind_details_clause}, "
        "{condition}{precip_clause}{pressure_clause}{humidity_clause}{air_clause}"
    ),
    "classic": (
        "{city}: Temperatura: {temp}°C, odczuwalna {feels}°C, "
        "wiatr {wind} km/h{wind_details_clause}, {condition}{precip_clause}{pressure_clause}{humidity_clause}{air_clause}"
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
    "outside": {
        "enabled": True,
    },
    "tuner": {
        "enabled": True,
        "mount_name": "tuner",
        "interval_seconds": 5,
        "api_url": "http://127.0.0.1:8080/api",
        "title_template": "Tuner: {freq} MHz | RDS: {ps}",
    },
    "title_mode": "outside",
}

PROMPT_IN: TextIO = sys.stdin
PROMPT_OUT: TextIO = sys.stdout


def configure_prompt_streams() -> None:
    global PROMPT_IN, PROMPT_OUT

    if os.environ.get("CONFIG_WIZARD_USE_STDIN") == "1":
        PROMPT_IN = sys.stdin
        PROMPT_OUT = sys.stdout
        return

    tty_path = Path("/dev/tty")
    if sys.stdin.isatty() and sys.stdout.isatty():
        PROMPT_IN = sys.stdin
        PROMPT_OUT = sys.stdout
        return

    if tty_path.exists():
        try:
            PROMPT_IN = tty_path.open("r", encoding="utf-8", errors="replace")
            PROMPT_OUT = tty_path.open("w", encoding="utf-8", errors="replace", buffering=1)
            return
        except OSError:
            pass

    PROMPT_IN = sys.stdin
    PROMPT_OUT = sys.stdout


def echo(message: str = "") -> None:
    print(message, file=PROMPT_OUT, flush=True)


def prompt_line(prompt: str) -> str:
    PROMPT_OUT.write(prompt)
    PROMPT_OUT.flush()
    line = PROMPT_IN.readline()
    if line == "":
        raise EOFError(
            "Brak interaktywnego wejscia dla kreatora. "
            "Uruchom go z terminala albo przez instalator, ktory korzysta z /dev/tty."
        )
    return line.rstrip("\r\n")


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


def ensure_dict(data: dict[str, Any], key: str) -> dict[str, Any]:
    current = data.get(key)
    if isinstance(current, dict):
        return current
    data[key] = {}
    return data[key]


def to_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "t", "yes", "y", "on"}:
            return True
        if lowered in {"0", "false", "f", "no", "n", "off"}:
            return False
    return default


def is_placeholder_password(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    raw = value.strip().upper()
    return raw.startswith("CHANGE_ME") or raw == ""


def print_section(title: str) -> None:
    echo("")
    echo(f"=== {title} ===")


def prompt_text(label: str, default: str | None = None, allow_empty: bool = False) -> str:
    while True:
        suffix = f" [{default}]" if default not in (None, "") else ""
        answer = prompt_line(f"{label}{suffix}: ").strip()
        if answer:
            return answer
        if default is not None:
            return default
        if allow_empty:
            return ""
        echo("To pole nie moze byc puste.")


def prompt_yes_no(label: str, default: bool = True) -> bool:
    marker = "T/n" if default else "t/N"
    while True:
        answer = prompt_line(f"{label} [{marker}]: ").strip().lower()
        if not answer:
            return default
        if answer in {"t", "tak", "y", "yes"}:
            return True
        if answer in {"n", "nie", "no"}:
            return False
        echo("Wpisz 't' lub 'n'.")


def prompt_int(label: str, default: int, minimum: int = 0) -> int:
    while True:
        raw = prompt_line(f"{label} [{default}]: ").strip()
        if not raw:
            return default
        try:
            value = int(raw)
        except ValueError:
            echo("Podaj liczbe calkowita.")
            continue
        if value < minimum:
            echo(f"Minimalna wartosc to {minimum}.")
            continue
        return value


def prompt_minutes(label: str, default: int) -> int:
    return prompt_int(label, default, minimum=1)


def prompt_choice(label: str, options: list[tuple[str, str]], default_key: str) -> str:
    idx_map = {str(idx): key for idx, (key, _desc) in enumerate(options, start=1)}
    while True:
        echo(label)
        for idx, (key, desc) in enumerate(options, start=1):
            marker = " (domyslnie)" if key == default_key else ""
            echo(f"  {idx}. {key}{marker} - {desc}")
        raw = prompt_line("Wybor [ENTER = domyslny]: ").strip()
        if not raw:
            return default_key
        if raw in idx_map:
            return idx_map[raw]
        raw_lower = raw.lower()
        if any(raw_lower == key for key, _desc in options):
            return raw_lower
        echo("Wpisz numer opcji albo nazwe trybu.")


def prompt_password(label: str, existing_value: str | None) -> str:
    has_existing = bool(existing_value)
    while True:
        suffix = " [ENTER = bez zmian]" if has_existing else ""
        if os.environ.get("CONFIG_WIZARD_USE_STDIN") == "1":
            value = prompt_line(f"{label}{suffix}: ").strip()
        else:
            value = getpass(f"{label}{suffix}: ", stream=PROMPT_OUT)
        if value:
            return value
        if has_existing:
            return existing_value or ""
        echo("Haslo nie moze byc puste.")


def split_url_parts(
    raw_url: str | None,
    default_scheme: str,
    default_host: str,
    default_port: str,
    default_path: str,
) -> tuple[str, str, str, str]:
    scheme = default_scheme
    host = default_host
    port = default_port
    path = default_path

    value = str(raw_url or "").strip()
    if not value:
        return scheme, host, port, path

    if "://" not in value:
        value = f"{default_scheme}://{value}"

    parsed = urlparse(value)
    if parsed.scheme:
        scheme = parsed.scheme
    if parsed.hostname:
        host = parsed.hostname
    try:
        if parsed.port is not None:
            port = str(parsed.port)
    except ValueError:
        pass

    cleaned_path = parsed.path.rstrip("/")
    if cleaned_path and cleaned_path != "/":
        path = cleaned_path

    return scheme, host, port, path


def normalize_port(raw_port: str) -> str:
    value = raw_port.strip()
    if not value:
        raise ValueError("Port nie moze byc pusty.")
    try:
        port = int(value)
    except ValueError as exc:
        raise ValueError("Port musi byc liczba calkowita.") from exc
    if port < 1 or port > 65535:
        raise ValueError("Port musi byc w zakresie 1-65535.")
    return str(port)


def normalize_path(raw_path: str, default_path: str = "") -> str:
    value = raw_path.strip()
    if not value:
        return default_path.strip()
    if value == "/":
        return ""
    if not value.startswith("/"):
        value = "/" + value
    return value.rstrip("/")


def build_url(scheme: str, host: str, port: str, path: str = "") -> str:
    host_value = host.strip()
    if not host_value:
        raise ValueError("Host nie moze byc pusty.")
    port_value = normalize_port(port)
    path_value = normalize_path(path)
    return f"{scheme}://{host_value}:{port_value}{path_value}"


def prompt_service_url(
    service_label: str,
    raw_url: str | None,
    default_host: str,
    default_port: str,
    default_path: str = "",
) -> str:
    scheme, host, port, path = split_url_parts(
        raw_url,
        default_scheme="http",
        default_host=default_host,
        default_port=default_port,
        default_path=default_path,
    )

    use_https = prompt_yes_no(f"Czy {service_label} dziala przez HTTPS?", scheme == "https")
    scheme = "https" if use_https else "http"
    host = prompt_text(f"Host {service_label}", host)
    while True:
        port_raw = prompt_text(f"Port {service_label}", port)
        try:
            port = normalize_port(port_raw)
            break
        except ValueError as exc:
            echo(f"Blad: {exc}")
    path = prompt_text(f"Sciezka URL {service_label} (opcjonalnie)", path, allow_empty=True)
    return build_url(scheme, host, port, path)


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


def format_error(exc: Exception) -> str:
    if isinstance(exc, HTTPError):
        return f"HTTP {exc.code}: {exc.reason}"
    if isinstance(exc, URLError):
        return str(exc.reason)
    return str(exc)


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
    icecast = ensure_dict(config, "icecast")
    streams = ensure_dict(config, "streams")
    base_url = str(icecast.get("base_url", "")).rstrip("/")
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
    prefix = str(streams.get("mount_prefix", "outside_"))
    for source in sources:
        if not isinstance(source, dict):
            continue
        mount = extract_mount(source)
        if mount:
            mounts.append(mount)

    outside_mounts = sorted({mount for mount in mounts if mount.startswith(prefix)})
    echo("")
    echo("Test polaczenia z Icecast: OK")
    echo(f"- endpoint: {status_url}")
    echo(f"- liczba aktywnych zrodel: {len(mounts)}")
    echo(f"- liczba mountow z prefiksem '{prefix}': {len(outside_mounts)}")
    if outside_mounts:
        preview = ", ".join(outside_mounts[:6])
        if len(outside_mounts) > 6:
            preview += ", ..."
        echo(f"- wykryte mounty: {preview}")
    else:
        echo("- nie wykryto mountow z tym prefiksem")


def run_tuner_api_test(config: dict[str, Any]) -> None:
    tuner = ensure_dict(config, "tuner")
    api_url = str(tuner.get("api_url", "")).strip()
    if not api_url:
        raise ValueError("Brak tuner.api_url.")

    data = http_get_json(api_url)
    if not isinstance(data, dict):
        raise ValueError("API tunera nie zwrocilo obiektu JSON.")

    tx_info = data.get("txInfo")
    if not isinstance(tx_info, dict):
        tx_info = {}

    echo("")
    echo("Test API tunera: OK")
    echo(f"- endpoint: {api_url}")
    echo(f"- freq: {data.get('freq', 'brak')}")
    echo(f"- ps: {data.get('ps', 'brak') or 'brak'}")
    echo(f"- rt: {data.get('rt0', 'brak') or 'brak'}")
    tx_name = tx_info.get("tx")
    tx_city = tx_info.get("city")
    if tx_name or tx_city:
        echo(f"- stacja: {tx_name or 'brak'} / {tx_city or 'brak'}")


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


def detect_profile(config: dict[str, Any]) -> str:
    outside_enabled = to_bool(deep_get(config, "outside", "enabled"), default=True)
    tuner_enabled = to_bool(deep_get(config, "tuner", "enabled"), default=True)
    if tuner_enabled and not outside_enabled:
        return "tuner-only"
    return "standard"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interaktywny kreator konfiguracji Icecast Metadata Updater"
    )
    parser.add_argument("--config", default="config.json", help="Sciezka do pliku config.json")
    parser.add_argument(
        "--profile",
        choices=("auto", "standard", "tuner-only"),
        default="auto",
        help="Tryb kreatora: standard, tuner-only albo auto",
    )
    parser.add_argument(
        "--no-test",
        action="store_true",
        help="Pomin testy polaczenia po zapisaniu konfiguracji",
    )
    return parser.parse_args()


def main() -> int:
    configure_prompt_streams()
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    config_path = Path(args.config).expanduser()
    if not config_path.is_absolute():
        config_path = (Path.cwd() / config_path).resolve()

    try:
        config = build_initial_config(script_dir, config_path)
    except Exception as exc:
        print(f"Blad odczytu konfiguracji: {exc}", file=sys.stderr)
        return 2

    profile = args.profile if args.profile != "auto" else detect_profile(config)

    echo("=== Kreator konfiguracji Icecast Metadata Updater ===")
    echo("Pola sa opisane osobno: host, port, login i hasla.")
    echo("ENTER przyjmuje wartosc domyslna.")
    echo(f"Tryb konfiguracji: {profile}")

    print_section("Icecast")
    base_url = prompt_service_url(
        "Icecast",
        deep_get(config, "icecast", "base_url"),
        default_host="127.0.0.1",
        default_port="8888",
    )

    source_user = prompt_text(
        "Uzytkownik source",
        str(deep_get(config, "icecast", "source_user", default=DEFAULT_CONFIG["icecast"]["source_user"])),
    )
    existing_source_password = deep_get(config, "icecast", "source_password")
    if is_placeholder_password(existing_source_password):
        existing_source_password = None
    source_password = prompt_password(
        "Haslo source",
        str(existing_source_password) if existing_source_password else None,
    )

    existing_metadata_user = deep_get(config, "icecast", "metadata_user")
    existing_metadata_password = deep_get(config, "icecast", "metadata_password")
    if is_placeholder_password(existing_metadata_password):
        existing_metadata_password = None

    same_as_source_default = not existing_metadata_user or str(existing_metadata_user) == str(source_user)
    if prompt_yes_no("Czy metadata ma uzywac tych samych danych co source?", same_as_source_default):
        metadata_user = source_user
        metadata_password = source_password
    else:
        metadata_user = prompt_text(
            "Uzytkownik metadata",
            str(existing_metadata_user) if existing_metadata_user else "admin",
        )
        metadata_password = prompt_password(
            "Haslo metadata",
            str(existing_metadata_password) if existing_metadata_password else None,
        )

    existing_status_user = deep_get(config, "icecast", "status_user")
    existing_status_password = deep_get(config, "icecast", "status_password")
    if is_placeholder_password(existing_status_password):
        existing_status_password = None

    if prompt_yes_no("Czy status-json.xsl wymaga osobnego logowania?", bool(existing_status_user)):
        status_user = prompt_text(
            "Uzytkownik status-json",
            str(existing_status_user) if existing_status_user else metadata_user,
        )
        status_password = prompt_password(
            "Haslo status-json",
            str(existing_status_password) if existing_status_password else None,
        )
    else:
        status_user = None
        status_password = None

    tuner_enabled_default = to_bool(deep_get(config, "tuner", "enabled"), default=True)
    outside_enabled_default = to_bool(deep_get(config, "outside", "enabled"), default=True)

    if profile == "tuner-only":
        outside_enabled = False
        tuner_enabled = True
    else:
        outside_enabled = prompt_yes_no("Czy wlaczyc sekcje outside_*?", outside_enabled_default)
        tuner_enabled = prompt_yes_no("Czy wlaczyc sekcje tuner / FMDX?", tuner_enabled_default)

    update_cfg = ensure_dict(config, "update")
    streams_cfg = ensure_dict(config, "streams")
    weather_cfg = ensure_dict(config, "weather")
    outside_cfg = ensure_dict(config, "outside")
    tuner_cfg = ensure_dict(config, "tuner")
    icecast_cfg = ensure_dict(config, "icecast")

    if outside_enabled:
        print_section("Outside / pogoda")
        mount_prefix = prompt_text(
            "Prefiks mountow outside",
            str(deep_get(config, "streams", "mount_prefix", default="outside_")),
        ).lstrip("/")

        current_interval_seconds = int(
            deep_get(config, "update", "interval_seconds", default=DEFAULT_CONFIG["update"]["interval_seconds"])
        )
        default_interval_minutes = max(1, round(current_interval_seconds / 60))
        interval_minutes = prompt_minutes("Interwal odswiezania pogody (minuty)", default_interval_minutes)

        existing_mode_raw = str(deep_get(config, "title_mode", default=DEFAULT_CONFIG["title_mode"])).lower().strip()
        default_mode = existing_mode_raw if existing_mode_raw in TITLE_TEMPLATE_PRESETS else "outside"
        title_mode = prompt_choice(
            "Tryb tytulu metadanych dla outside_*:",
            [
                ("classic", "Miasto: Temperatura..., opis pelny"),
                ("outside", "outside from Miasto..., opis pelny"),
                ("weather", "sam opis pogody bez nazwy miasta"),
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
        if prompt_yes_no("Czy wpisac wlasny title_template dla outside_*?", existing_is_custom):
            custom_default = existing_template if existing_template else TITLE_TEMPLATE_PRESETS[title_mode]
            config["title_template"] = prompt_text("Wlasny title_template", custom_default)
        else:
            config.pop("title_template", None)
        config["title_mode"] = title_mode

        if prompt_yes_no("Czy zmienic ustawienia pogody (kraj / jezyk / strefa)?", False):
            weather_cfg["country_code"] = prompt_text(
                "Kod kraju (country_code)",
                str(weather_cfg.get("country_code", "PL")),
            ).upper()
            weather_cfg["language"] = prompt_text(
                "Jezyk (language)",
                str(weather_cfg.get("language", "pl")),
            )
            weather_cfg["timezone"] = prompt_text(
                "Strefa czasowa (timezone)",
                str(weather_cfg.get("timezone", "Europe/Warsaw")),
            )

        existing_overrides = deep_get(config, "streams", "city_overrides", default={})
        if not isinstance(existing_overrides, dict):
            existing_overrides = {}
        city_overrides: dict[str, str] = {}
        if existing_overrides and prompt_yes_no(
            f"Czy zachowac istniejace city_overrides ({len(existing_overrides)})?",
            True,
        ):
            city_overrides.update({str(key): str(value) for key, value in existing_overrides.items()})

        if prompt_yes_no("Czy dodac nowe mapowania city_overrides?", False):
            echo("Podawaj pary: mount -> miasto. Puste pole mount konczy dodawanie.")
            while True:
                mount = prompt_text("Mount (np. outside_gdansk)", allow_empty=True).lstrip("/")
                if not mount:
                    break
                city = prompt_text("Miasto")
                city_overrides[mount] = city

        streams_cfg["mount_prefix"] = mount_prefix
        streams_cfg["city_overrides"] = city_overrides
        update_cfg["interval_seconds"] = interval_minutes * 60
    else:
        outside_cfg["enabled"] = False

    if tuner_enabled:
        print_section("Tuner / FMDX")
        tuner_cfg["mount_name"] = prompt_text(
            "Mount tunera w Icecast",
            str(deep_get(config, "tuner", "mount_name", default="tuner")).lstrip("/"),
        ).lstrip("/")
        tuner_cfg["interval_seconds"] = prompt_int(
            "Interwal odswiezania tunera (sekundy)",
            int(deep_get(config, "tuner", "interval_seconds", default=5)),
            minimum=2,
        )
        tuner_cfg["api_url"] = prompt_service_url(
            "API tunera FMDX",
            deep_get(config, "tuner", "api_url"),
            default_host="127.0.0.1",
            default_port="8080",
            default_path="/api",
        )
        existing_tuner_template = str(
            deep_get(config, "tuner", "title_template", default=DEFAULT_CONFIG["tuner"]["title_template"])
        ).strip()
        if prompt_yes_no("Czy zmienic title_template tunera?", False):
            tuner_cfg["title_template"] = prompt_text("Title template tunera", existing_tuner_template)
        elif not existing_tuner_template:
            tuner_cfg["title_template"] = DEFAULT_CONFIG["tuner"]["title_template"]

    icecast_cfg["base_url"] = base_url
    icecast_cfg["source_user"] = source_user
    icecast_cfg["source_password"] = source_password
    icecast_cfg["metadata_user"] = metadata_user
    icecast_cfg["metadata_password"] = metadata_password
    icecast_cfg["status_user"] = status_user
    icecast_cfg["status_password"] = status_password

    outside_cfg["enabled"] = outside_enabled
    tuner_cfg["enabled"] = tuner_enabled
    if "dry_run" not in update_cfg:
        update_cfg["dry_run"] = False

    if not outside_enabled and not tuner_enabled:
        echo("")
        echo("UWAGA: wylaczyles outside_* i tuner. Program nie bedzie nic aktualizowal.")

    config_path.parent.mkdir(parents=True, exist_ok=True)
    with config_path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    echo("")
    echo(f"Zapisano konfiguracje: {config_path}")

    if not args.no_test:
        if prompt_yes_no("Wykonac test polaczenia do Icecast?", True):
            try:
                run_status_test(config)
            except Exception as exc:
                echo("")
                echo("Test polaczenia z Icecast: BLAD")
                echo(f"- {format_error(exc)}")

        if tuner_enabled and prompt_yes_no("Wykonac test API tunera?", profile == "tuner-only"):
            try:
                run_tuner_api_test(config)
            except Exception as exc:
                echo("")
                echo("Test API tunera: BLAD")
                echo(f"- {format_error(exc)}")

    echo("")
    echo("Kolejny krok:")
    echo(f"python3 {script_dir / 'weather_metadata_updater.py'} --config {config_path} --once --dry-run")
    echo("Jesli wynik jest poprawny, zrestartuj usluge:")
    echo("systemctl --user restart icecast-metadata-updater.service")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nPrzerwano przez uzytkownika.")
        raise SystemExit(130)
    except EOFError as exc:
        print(f"\nBlad kreatora: {exc}", file=sys.stderr)
        raise SystemExit(3)
