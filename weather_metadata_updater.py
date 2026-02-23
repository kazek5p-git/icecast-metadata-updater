#!/usr/bin/env python3
"""Update Icecast stream titles with current city weather for outside_* mounts."""

from __future__ import annotations

import argparse
import base64
import configparser
import json
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, unquote, urlparse
from urllib.request import Request, urlopen


WMO_WEATHER = {
    0: "bezchmurnie",
    1: "glownie pogodnie",
    2: "czesciowe zachmurzenie",
    3: "zachmurzenie",
    45: "mgla",
    48: "szadz",
    51: "lekka mzawka",
    53: "mzawka",
    55: "silna mzawka",
    56: "marznaca mzawka",
    57: "silna marznaca mzawka",
    61: "slaby deszcz",
    63: "deszcz",
    65: "silny deszcz",
    66: "marznacy deszcz",
    67: "silny marznacy deszcz",
    71: "slabe opady sniegu",
    73: "opady sniegu",
    75: "silne opady sniegu",
    77: "ziarna sniezne",
    80: "przelotny slaby deszcz",
    81: "przelotny deszcz",
    82: "silne przelotne opady",
    85: "przelotny snieg",
    86: "silny przelotny snieg",
    95: "burza",
    96: "burza z gradem",
    99: "silna burza z gradem",
}

POLISH_CITY_ALIASES = {
    "bialystok": "Białystok",
    "bydgoszcz": "Bydgoszcz",
    "czestochowa": "Częstochowa",
    "gdansk": "Gdańsk",
    "gorzow wielkopolski": "Gorzów Wielkopolski",
    "katowice": "Katowice",
    "krakow": "Kraków",
    "lodz": "Łódź",
    "olsztyn": "Olsztyn",
    "poznan": "Poznań",
    "rzeszow": "Rzeszów",
    "szczecin": "Szczecin",
    "torun": "Toruń",
    "wroclaw": "Wrocław",
    "zabki": "Ząbki",
    "zamosc": "Zamość",
    "zielona gora": "Zielona Góra",
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
        "interval_seconds": 120,
        "dry_run": False,
    },
    "title_template": "{city}: {temp}C, odczuwalna {feels}C, wiatr {wind} km/h, {condition}",
}


@dataclass
class GeoPoint:
    name: str
    latitude: float
    longitude: float


@dataclass
class RuntimeConfig:
    base_url: str
    source_user: str
    source_password: str
    metadata_user: str
    metadata_password: str
    status_user: str | None
    status_password: str | None
    mount_prefix: str
    city_overrides: dict[str, str]
    country_code: str
    language: str
    timezone: str
    interval_seconds: int
    dry_run: bool
    title_template: str


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def load_json_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def deep_get(data: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current: Any = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def first_nonempty(*values: Any) -> Any:
    for value in values:
        if value is None:
            continue
        if isinstance(value, str) and value == "":
            continue
        return value
    return None


def parse_darkice_config(path: Path) -> dict[str, str]:
    parser = configparser.ConfigParser(interpolation=None)
    if not path.exists():
        return {}
    parser.read(path, encoding="utf-8")
    for section in parser.sections():
        if not section.startswith("icecast"):
            continue
        server = parser.get(section, "server", fallback="").strip()
        port = parser.get(section, "port", fallback="").strip()
        password = parser.get(section, "password", fallback="").strip()
        if server and port and password:
            return {
                "base_url": f"http://{server}:{port}",
                "source_password": password,
            }
    return {}


def darkice_defaults() -> dict[str, str]:
    candidates = [Path("/etc/darkice.cfg"), Path("/etc/darkice2.cfg")]
    for path in candidates:
        values = parse_darkice_config(path)
        if values:
            log(f"Wykryto ustawienia Icecast z {path}")
            return values
    return {}


def build_runtime_config(args: argparse.Namespace, file_cfg: dict[str, Any]) -> RuntimeConfig:
    defaults = darkice_defaults()

    base_url = first_nonempty(
        args.base_url,
        deep_get(file_cfg, "icecast", "base_url"),
        defaults.get("base_url"),
        deep_get(DEFAULT_CONFIG, "icecast", "base_url"),
    )
    source_user = first_nonempty(
        args.source_user,
        deep_get(file_cfg, "icecast", "source_user"),
        deep_get(DEFAULT_CONFIG, "icecast", "source_user"),
    )
    source_password = first_nonempty(
        args.source_password,
        deep_get(file_cfg, "icecast", "source_password"),
        defaults.get("source_password"),
    )

    if not source_password:
        raise ValueError(
            "Brak hasla source. Ustaw w configu icecast.source_password "
            "albo przez --source-password."
        )

    status_user = first_nonempty(
        args.status_user,
        deep_get(file_cfg, "icecast", "status_user"),
        deep_get(DEFAULT_CONFIG, "icecast", "status_user"),
    )
    status_password = first_nonempty(
        args.status_password,
        deep_get(file_cfg, "icecast", "status_password"),
        deep_get(DEFAULT_CONFIG, "icecast", "status_password"),
    )

    metadata_user = first_nonempty(
        args.metadata_user,
        deep_get(file_cfg, "icecast", "metadata_user"),
        source_user,
    )
    metadata_password = first_nonempty(
        args.metadata_password,
        deep_get(file_cfg, "icecast", "metadata_password"),
        source_password,
    )

    mount_prefix = first_nonempty(
        args.mount_prefix,
        deep_get(file_cfg, "streams", "mount_prefix"),
        deep_get(DEFAULT_CONFIG, "streams", "mount_prefix"),
    )
    country_code = first_nonempty(
        args.country_code,
        deep_get(file_cfg, "weather", "country_code"),
        deep_get(DEFAULT_CONFIG, "weather", "country_code"),
    )
    language = first_nonempty(
        args.language,
        deep_get(file_cfg, "weather", "language"),
        deep_get(DEFAULT_CONFIG, "weather", "language"),
    )
    timezone = first_nonempty(
        args.timezone,
        deep_get(file_cfg, "weather", "timezone"),
        deep_get(DEFAULT_CONFIG, "weather", "timezone"),
    )
    interval_seconds = int(
        first_nonempty(
            args.interval_seconds,
            deep_get(file_cfg, "update", "interval_seconds"),
            deep_get(DEFAULT_CONFIG, "update", "interval_seconds"),
        )
    )
    dry_run = bool(
        first_nonempty(
            args.dry_run,
            deep_get(file_cfg, "update", "dry_run"),
            deep_get(DEFAULT_CONFIG, "update", "dry_run"),
        )
    )
    title_template = first_nonempty(
        args.title_template,
        deep_get(file_cfg, "title_template"),
        deep_get(DEFAULT_CONFIG, "title_template"),
    )

    city_overrides = deep_get(file_cfg, "streams", "city_overrides", default={})
    if not isinstance(city_overrides, dict):
        city_overrides = {}

    return RuntimeConfig(
        base_url=str(base_url).rstrip("/"),
        source_user=str(source_user),
        source_password=str(source_password),
        metadata_user=str(metadata_user),
        metadata_password=str(metadata_password),
        status_user=str(status_user) if status_user else None,
        status_password=str(status_password) if status_password else None,
        mount_prefix=str(mount_prefix).lstrip("/"),
        city_overrides={str(k): str(v) for k, v in city_overrides.items()},
        country_code=str(country_code),
        language=str(language),
        timezone=str(timezone),
        interval_seconds=max(10, interval_seconds),
        dry_run=dry_run,
        title_template=str(title_template),
    )


def auth_header(username: str, password: str) -> str:
    token = f"{username}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(token).decode("ascii")


def http_get_json(
    url: str,
    auth: tuple[str, str] | None = None,
    timeout: int = 12,
    headers: dict[str, str] | None = None,
    retries: int = 2,
) -> Any:
    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            request = Request(url)
            if headers:
                for key, value in headers.items():
                    request.add_header(key, value)
            if auth:
                request.add_header("Authorization", auth_header(auth[0], auth[1]))
            with urlopen(request, timeout=timeout) as response:
                payload = response.read().decode("utf-8", errors="replace")
            return json.loads(payload)
        except Exception as exc:  # pragma: no cover - depends on network
            last_error = exc
            if attempt < retries:
                time.sleep(1 + attempt)
    assert last_error is not None
    raise last_error


def http_get_text(
    url: str,
    auth: tuple[str, str] | None = None,
    timeout: int = 12,
    retries: int = 1,
) -> str:
    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            request = Request(url)
            if auth:
                request.add_header("Authorization", auth_header(auth[0], auth[1]))
            with urlopen(request, timeout=timeout) as response:
                return response.read().decode("utf-8", errors="replace")
        except Exception as exc:  # pragma: no cover - depends on network
            last_error = exc
            if attempt < retries:
                time.sleep(1 + attempt)
    assert last_error is not None
    raise last_error


def extract_mount(source: dict[str, Any]) -> str | None:
    listen_url = str(source.get("listenurl", "")).strip()
    if not listen_url:
        return None
    parsed = urlparse(listen_url)
    mount = parsed.path.strip()
    if not mount.startswith("/"):
        return None
    return mount


def list_outside_mounts(cfg: RuntimeConfig) -> list[str]:
    status_url = f"{cfg.base_url}/status-json.xsl"
    status_auth: tuple[str, str] | None = None
    if cfg.status_user and cfg.status_password:
        status_auth = (cfg.status_user, cfg.status_password)

    data = http_get_json(status_url, auth=status_auth)
    sources = deep_get(data, "icestats", "source", default=[])
    if isinstance(sources, dict):
        sources = [sources]

    result: list[str] = []
    prefix = cfg.mount_prefix
    for source in sources:
        mount = extract_mount(source)
        if not mount:
            continue
        mount_name = mount.lstrip("/")
        if mount_name.startswith(prefix):
            result.append(mount_name)

    return sorted(set(result))


def guess_city_from_mount(mount_name: str, prefix: str, overrides: dict[str, str]) -> str:
    if mount_name in overrides:
        return overrides[mount_name]

    short_name = mount_name
    if short_name.startswith(prefix):
        short_name = short_name[len(prefix) :]

    if short_name in overrides:
        return overrides[short_name]

    decoded = unquote(short_name)
    decoded = decoded.replace("_", " ").replace("-", " ").strip()
    if not decoded:
        return short_name

    alias = POLISH_CITY_ALIASES.get(decoded.lower())
    if alias:
        return alias

    return " ".join(part.capitalize() for part in decoded.split())


def geocode_open_meteo(city: str, cfg: RuntimeConfig, with_country_filter: bool) -> GeoPoint | None:
    params_data = {
        "name": city,
        "count": 1,
        "language": cfg.language,
    }
    if with_country_filter:
        params_data["countryCode"] = cfg.country_code

    params = urlencode(params_data)
    url = f"https://geocoding-api.open-meteo.com/v1/search?{params}"
    data = http_get_json(url)

    results = data.get("results") or []
    if not results:
        return None

    result = results[0]
    country = str(result.get("country_code", "")).upper()
    if country and country != cfg.country_code.upper():
        return None
    return GeoPoint(
        name=str(result.get("name", city)),
        latitude=float(result["latitude"]),
        longitude=float(result["longitude"]),
    )


def geocode_nominatim(city: str, cfg: RuntimeConfig) -> GeoPoint | None:
    params = urlencode(
        {
            "city": city,
            "countrycodes": cfg.country_code.lower(),
            "format": "jsonv2",
            "limit": 1,
            "accept-language": cfg.language,
        }
    )
    url = f"https://nominatim.openstreetmap.org/search?{params}"
    data = http_get_json(
        url,
        headers={"User-Agent": "icecast-metadata-updater/1.0 (local-script)"},
    )
    if not isinstance(data, list) or not data:
        return None

    result = data[0]
    return GeoPoint(
        name=str(result.get("name", city)),
        latitude=float(result["lat"]),
        longitude=float(result["lon"]),
    )


def geocode_city(city: str, cfg: RuntimeConfig, cache: dict[str, GeoPoint]) -> GeoPoint:
    if city in cache:
        return cache[city]

    point = geocode_open_meteo(city, cfg, with_country_filter=True)
    if point is None:
        point = geocode_open_meteo(city, cfg, with_country_filter=False)
    if point is None:
        point = geocode_nominatim(city, cfg)
    if point is None:
        raise ValueError(f"Nie znaleziono miasta: {city}")

    cache[city] = point
    return point


def weather_description(code: int, is_day: int | None = None) -> str:
    if code == 0 and is_day is not None:
        return "slonecznie" if int(is_day) == 1 else "bezchmurnie (noc)"
    return WMO_WEATHER.get(code, f"kod pogody {code}")


def current_weather(point: GeoPoint, cfg: RuntimeConfig) -> dict[str, Any]:
    params = urlencode(
        {
            "latitude": point.latitude,
            "longitude": point.longitude,
            "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day",
            "wind_speed_unit": "kmh",
            "timezone": cfg.timezone,
        }
    )
    url = f"https://api.open-meteo.com/v1/forecast?{params}"
    data = http_get_json(url)
    current = data.get("current")
    if not current:
        raise ValueError(f"Brak danych pogodowych dla {point.name}")
    return current


def build_title(template: str, city: str, weather: dict[str, Any], mount_name: str) -> str:
    temp = round(float(weather.get("temperature_2m", 0.0)))
    feels = round(float(weather.get("apparent_temperature", temp)))
    wind = round(float(weather.get("wind_speed_10m", 0.0)))
    code = int(weather.get("weather_code", -1))
    condition = weather_description(code, weather.get("is_day"))

    return template.format(
        city=city,
        temp=temp,
        feels=feels,
        wind=wind,
        condition=condition,
        mount=mount_name,
        weather_code=code,
    )


def update_mount_metadata(cfg: RuntimeConfig, mount_name: str, title: str) -> tuple[bool, str]:
    params = urlencode(
        {
            "mode": "updinfo",
            "mount": f"/{mount_name}",
            "song": title,
        }
    )
    url = f"{cfg.base_url}/admin/metadata?{params}"
    body = http_get_text(url, auth=(cfg.metadata_user, cfg.metadata_password))
    message_match = re.search(r"<message>(.*?)</message>", body, flags=re.IGNORECASE | re.DOTALL)
    message = message_match.group(1).strip() if message_match else body.strip()
    lowered = message.lower()
    success = "successful" in lowered
    return success, message


def run_cycle(cfg: RuntimeConfig, geocode_cache: dict[str, GeoPoint]) -> None:
    mounts = list_outside_mounts(cfg)
    if not mounts:
        log(f"Brak aktywnych mountow z prefiksem '{cfg.mount_prefix}'")
        return

    log(f"Wykryto mounty: {', '.join(mounts)}")

    mount_city: dict[str, str] = {}
    for mount in mounts:
        city = guess_city_from_mount(mount, cfg.mount_prefix, cfg.city_overrides)
        mount_city[mount] = city

    weather_cache: dict[str, dict[str, Any]] = {}
    geo_names: dict[str, str] = {}

    for city in sorted(set(mount_city.values())):
        try:
            point = geocode_city(city, cfg, geocode_cache)
            weather = current_weather(point, cfg)
        except Exception as exc:
            log(f"BLAD pogody dla miasta '{city}': {exc}")
            continue
        weather_cache[city] = weather
        geo_names[city] = point.name

    for mount in mounts:
        city_query = mount_city[mount]
        weather = weather_cache.get(city_query)
        city_name = geo_names.get(city_query)
        if weather is None or city_name is None:
            log(f"POMINIETO {mount}: brak danych pogodowych dla '{city_query}'")
            continue
        title = build_title(cfg.title_template, city_name, weather, mount)

        if cfg.dry_run:
            log(f"DRY RUN {mount}: {title}")
            continue

        try:
            ok, message = update_mount_metadata(cfg, mount, title)
        except Exception as exc:
            log(f"BLAD {mount}: {exc}")
            continue
        if ok:
            log(f"OK {mount}: {title}")
        else:
            log(f"BLAD {mount}: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Cyclic update of Icecast metadata titles with weather for outside_* mounts."
    )
    parser.add_argument("--config", default="config.json", help="Path to JSON config file")
    parser.add_argument("--once", action="store_true", help="Run a single update cycle")
    parser.add_argument("--interval-seconds", type=int, help="Update interval in seconds")
    parser.add_argument("--base-url", help="Icecast base URL, e.g. http://127.0.0.1:8888")
    parser.add_argument("--source-user", help="Icecast source user")
    parser.add_argument("--source-password", help="Icecast source password")
    parser.add_argument("--metadata-user", help="User for /admin/metadata (default: source user)")
    parser.add_argument(
        "--metadata-password",
        help="Password for /admin/metadata (default: source password)",
    )
    parser.add_argument("--status-user", help="Status endpoint user (optional)")
    parser.add_argument("--status-password", help="Status endpoint password (optional)")
    parser.add_argument("--mount-prefix", help="Mount name prefix, default outside_")
    parser.add_argument("--country-code", help="Geocoding country code, default PL")
    parser.add_argument("--language", help="Geocoding language, default pl")
    parser.add_argument("--timezone", help="Weather timezone, default Europe/Warsaw")
    parser.add_argument("--title-template", help="Title template")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=None,
        help="Do not send metadata updates",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config)

    try:
        file_cfg = load_json_config(config_path)
        cfg = build_runtime_config(args, file_cfg)
    except Exception as exc:
        log(f"BLAD konfiguracji: {exc}")
        return 2

    log(
        "Start: base_url=%s mount_prefix=%s interval=%ss dry_run=%s"
        % (cfg.base_url, cfg.mount_prefix, cfg.interval_seconds, cfg.dry_run)
    )

    geocode_cache: dict[str, GeoPoint] = {}

    try:
        while True:
            cycle_start = time.time()
            try:
                run_cycle(cfg, geocode_cache)
            except Exception as exc:
                log(f"BLAD cyklu: {exc}")

            if args.once:
                break

            elapsed = time.time() - cycle_start
            sleep_seconds = max(1, cfg.interval_seconds - int(elapsed))
            time.sleep(sleep_seconds)
    except KeyboardInterrupt:
        log("Przerwano przez uzytkownika")

    return 0


if __name__ == "__main__":
    sys.exit(main())
