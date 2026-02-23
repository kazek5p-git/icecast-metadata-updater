#!/usr/bin/env python3
"""Update Icecast stream titles with current city weather for outside_* mounts."""

from __future__ import annotations

import argparse
import base64
import configparser
import html
import json
import re
import sys
import time
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, unquote, urlparse
from urllib.request import Request, urlopen


WMO_WEATHER = {
    0: "bezchmurnie",
    1: "głównie pogodnie",
    2: "częściowe zachmurzenie",
    3: "zachmurzenie",
    45: "mgła",
    48: "szadź",
    51: "lekka mżawka",
    53: "mżawka",
    55: "silna mżawka",
    56: "marznąca mżawka",
    57: "silna marznąca mżawka",
    61: "słaby deszcz",
    63: "deszcz",
    65: "silny deszcz",
    66: "marznący deszcz",
    67: "silny marznący deszcz",
    71: "słabe opady śniegu",
    73: "opady śniegu",
    75: "silne opady śniegu",
    77: "ziarna śnieżne",
    80: "przelotny słaby deszcz",
    81: "przelotny deszcz",
    82: "silne przelotne opady",
    85: "przelotny śnieg",
    86: "silny przelotny śnieg",
    95: "burza",
    96: "burza z gradem",
    99: "silna burza z gradem",
}

PRECIPITATION_WEATHER_CODES = {
    51,
    53,
    55,
    56,
    57,
    61,
    63,
    65,
    66,
    67,
    71,
    73,
    75,
    77,
    80,
    81,
    82,
    85,
    86,
    95,
    96,
    99,
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

LEGACY_CLASSIC_TEMPLATE = "{city}: {temp}°C, odczuwalna {feels}°C, wiatr {wind} km/h, {condition}{precip_clause}"


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
    "title_mode": "outside",
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
    title_mode: str
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


def confirm_legacy_title_migration() -> bool:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False

    print(
        "Wykryto stary domyslny format tytulow (classic).",
        flush=True,
    )
    print(
        "Czy chcesz przelaczyc na nowy format 'outside from ...'?",
        flush=True,
    )
    while True:
        answer = input("Zmiana formatu [t/N]: ").strip().lower()
        if answer in {"t", "tak", "y", "yes"}:
            return True
        if answer in {"", "n", "nie", "no"}:
            return False
        print("Wpisz t lub n.", flush=True)


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
    title_mode_raw = first_nonempty(
        args.title_mode,
        deep_get(file_cfg, "title_mode"),
        deep_get(DEFAULT_CONFIG, "title_mode"),
        "outside",
    )
    title_mode = str(title_mode_raw).strip().lower()
    if title_mode not in TITLE_TEMPLATE_PRESETS:
        raise ValueError(
            "Nieznany title_mode: %s (dostepne: %s)"
            % (title_mode, ", ".join(sorted(TITLE_TEMPLATE_PRESETS.keys())))
        )

    title_template_cfg = deep_get(file_cfg, "title_template")
    title_template = ""
    effective_title_mode = title_mode

    if args.title_template:
        title_template = str(args.title_template)
        effective_title_mode = "custom"
    elif args.title_mode is not None or deep_get(file_cfg, "title_mode") is not None:
        title_template = TITLE_TEMPLATE_PRESETS[title_mode]
    elif isinstance(title_template_cfg, str) and title_template_cfg.strip():
        title_template = title_template_cfg.strip()
        if title_template == LEGACY_CLASSIC_TEMPLATE:
            if confirm_legacy_title_migration():
                title_template = TITLE_TEMPLATE_PRESETS["outside"]
                effective_title_mode = "outside"
                log(
                    "Potwierdzono migracje title_template: classic -> outside. "
                    "Aby ustawic to na stale, wpisz w configu title_mode=outside."
                )
            else:
                effective_title_mode = "classic"
                log(
                    "Wykryto stary domyslny title_template (classic). "
                    "Pozostawiam classic. Aby zmienic, ustaw title_mode=outside "
                    "lub uruchom config_wizard.py."
                )
        else:
            for preset_name, preset_template in TITLE_TEMPLATE_PRESETS.items():
                if title_template == preset_template:
                    effective_title_mode = preset_name
                    break
            else:
                effective_title_mode = "custom"
    else:
        title_template = TITLE_TEMPLATE_PRESETS[title_mode]

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
        title_mode=effective_title_mode,
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
        return "słonecznie" if int(is_day) == 1 else "bezchmurnie (noc)"
    return WMO_WEATHER.get(code, f"kod pogody {code}")


def air_quality_description(aqi: int) -> str:
    if aqi <= 20:
        return "bardzo dobra"
    if aqi <= 40:
        return "dobra"
    if aqi <= 60:
        return "umiarkowana"
    if aqi <= 80:
        return "słaba"
    if aqi <= 100:
        return "bardzo słaba"
    return "ekstremalnie słaba"


def air_quality_text(air_quality: dict[str, Any] | None) -> tuple[str, str]:
    if not isinstance(air_quality, dict):
        return "", ""

    raw_aqi = air_quality.get("european_aqi")
    if raw_aqi is None:
        return "", ""

    try:
        aqi_value = int(round(float(raw_aqi)))
    except (TypeError, ValueError):
        return "", ""

    label = air_quality_description(aqi_value)
    return f"jakość powietrza: {label} (AQI {aqi_value})", str(aqi_value)


def pressure_text(weather: dict[str, Any]) -> tuple[str, str]:
    raw_pressure = weather.get("pressure_msl")
    if raw_pressure is None:
        raw_pressure = weather.get("surface_pressure")
    if raw_pressure is None:
        return "", ""

    try:
        pressure_hpa = int(round(float(raw_pressure)))
    except (TypeError, ValueError):
        return "", ""

    return f"ciśnienie {pressure_hpa} hPa", str(pressure_hpa)


def wind_direction_label(degrees: int) -> str:
    directions = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    index = int(((degrees % 360) + 22.5) // 45) % len(directions)
    return directions[index]


def wind_details_text(weather: dict[str, Any]) -> tuple[str, str, str, str, str]:
    gust_text = ""
    gust_kmh = ""
    direction_text = ""
    direction_short = ""
    direction_deg = ""

    raw_gust = weather.get("wind_gusts_10m")
    if raw_gust is not None:
        try:
            gust_value = int(round(float(raw_gust)))
        except (TypeError, ValueError):
            gust_value = None
        if gust_value is not None and gust_value > 0:
            gust_kmh = str(gust_value)
            gust_text = f"w porywach do {gust_value} km/h"

    raw_direction = weather.get("wind_direction_10m")
    if raw_direction is not None:
        try:
            direction_value = int(round(float(raw_direction))) % 360
        except (TypeError, ValueError):
            direction_value = None
        if direction_value is not None:
            direction_deg = str(direction_value)
            direction_short = wind_direction_label(direction_value)
            direction_text = f"kierunek {direction_short}"

    details = ", ".join(part for part in (gust_text, direction_text) if part)
    details_clause = f", {details}" if details else ""
    return details, details_clause, gust_kmh, direction_short, direction_deg


def rain_intensity_label(rain_mm: float) -> str:
    if rain_mm < 0.05:
        return "śladowy deszcz"
    if rain_mm < 0.5:
        return "bardzo lekki deszcz"
    if rain_mm < 1.5:
        return "lekki deszcz"
    if rain_mm < 4.0:
        return "umiarkowany deszcz"
    if rain_mm < 8.0:
        return "silny deszcz"
    return "ulewa"


def snowfall_intensity_label(snow_cm: float) -> str:
    if snow_cm < 0.05:
        return "śladowy śnieg"
    if snow_cm < 0.5:
        return "lekki śnieg"
    if snow_cm < 2.0:
        return "opady śniegu"
    return "silny śnieg"


def mixed_precipitation_label(rain_mm: float, snow_cm: float) -> str:
    rain_score = 0
    if rain_mm >= 0.5:
        rain_score = 1
    if rain_mm >= 1.5:
        rain_score = 2
    if rain_mm >= 4.0:
        rain_score = 3

    snow_score = 0
    if snow_cm >= 0.5:
        snow_score = 1
    if snow_cm >= 1.5:
        snow_score = 2
    if snow_cm >= 3.0:
        snow_score = 3

    score = max(rain_score, snow_score)
    labels = (
        "lekki deszcz ze śniegiem",
        "umiarkowany deszcz ze śniegiem",
        "silny deszcz ze śniegiem",
        "bardzo silny deszcz ze śniegiem",
    )
    return labels[score]


def format_amount(value: float, unit: str) -> str:
    if value < 0.1:
        return f"{value:.2f} {unit}"
    return f"{value:.1f} {unit}"


def precipitation_text(weather: dict[str, Any]) -> str:
    code = int(weather.get("weather_code", -1) or -1)
    precipitation = float(weather.get("precipitation", 0.0) or 0.0)
    rain = float(weather.get("rain", 0.0) or 0.0)
    showers = float(weather.get("showers", 0.0) or 0.0)
    snowfall = float(weather.get("snowfall", 0.0) or 0.0)
    rain_total = rain + showers

    has_rain = rain_total >= 0.03
    has_snow = snowfall >= 0.03
    has_any_precip = precipitation >= 0.03 or has_rain or has_snow

    if not has_any_precip:
        return ""

    if has_rain and has_snow:
        label = mixed_precipitation_label(rain_total, snowfall)
        return (
            f"opad: {label} "
            f"(deszcz {format_amount(rain_total, 'mm')}, śnieg {format_amount(snowfall, 'cm')})"
        )

    # Gdy warunek pogody juz opisuje opad (np. mżawka/deszcz/snieg),
    # nie doklejamy drugiego, bardzo podobnego opisu "opad: ...".
    if code in PRECIPITATION_WEATHER_CODES:
        return ""

    if has_snow:
        return f"opad: {snowfall_intensity_label(snowfall)} ({format_amount(snowfall, 'cm')})"

    return f"opad: {rain_intensity_label(rain_total)} ({format_amount(rain_total, 'mm')})"


def current_weather(point: GeoPoint, cfg: RuntimeConfig) -> dict[str, Any]:
    params = urlencode(
        {
            "latitude": point.latitude,
            "longitude": point.longitude,
            "current": (
                "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day,"
                "wind_gusts_10m,wind_direction_10m,"
                "pressure_msl,surface_pressure,"
                "precipitation,rain,showers,snowfall"
            ),
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


def current_air_quality(point: GeoPoint, cfg: RuntimeConfig) -> dict[str, Any]:
    params = urlencode(
        {
            "latitude": point.latitude,
            "longitude": point.longitude,
            "current": "european_aqi,pm2_5,pm10",
            "timezone": cfg.timezone,
        }
    )
    url = f"https://air-quality-api.open-meteo.com/v1/air-quality?{params}"
    data = http_get_json(url)
    current = data.get("current")
    if not current:
        raise ValueError(f"Brak danych jakości powietrza dla {point.name}")
    return current


def build_title(
    template: str,
    city: str,
    weather: dict[str, Any],
    mount_name: str,
    air_quality: dict[str, Any] | None = None,
) -> str:
    temp = round(float(weather.get("temperature_2m", 0.0)))
    feels = round(float(weather.get("apparent_temperature", temp)))
    wind = round(float(weather.get("wind_speed_10m", 0.0)))
    code = int(weather.get("weather_code", -1))
    condition = weather_description(code, weather.get("is_day"))

    precip = precipitation_text(weather)
    precip_clause = f", {precip}" if precip else ""
    wind_details, wind_details_clause, wind_gust, wind_direction, wind_direction_deg = wind_details_text(weather)
    pressure, pressure_hpa = pressure_text(weather)
    pressure_clause = f", {pressure}" if pressure else ""
    air, aqi = air_quality_text(air_quality)
    air_clause = f", {air}" if air else ""
    city_latin = city.translate(str.maketrans({"Ł": "L", "ł": "l"}))
    city_ascii = unicodedata.normalize("NFKD", city_latin).encode("ascii", "ignore").decode("ascii")
    if not city_ascii:
        city_ascii = city

    return template.format(
        city=city,
        city_ascii=city_ascii,
        temp=temp,
        feels=feels,
        wind=wind,
        wind_details=wind_details,
        wind_details_clause=wind_details_clause,
        wind_gust=wind_gust,
        wind_direction=wind_direction,
        wind_direction_deg=wind_direction_deg,
        condition=condition,
        precip=precip,
        precip_clause=precip_clause,
        pressure=pressure,
        pressure_clause=pressure_clause,
        pressure_hpa=pressure_hpa,
        air=air,
        air_clause=air_clause,
        aqi=aqi,
        precipitation_mm=round(float(weather.get("precipitation", 0.0)), 2),
        rain_mm=round(float(weather.get("rain", 0.0)), 2),
        showers_mm=round(float(weather.get("showers", 0.0)), 2),
        snowfall_cm=round(float(weather.get("snowfall", 0.0)), 2),
        mount=mount_name,
        weather_code=code,
    )


def parse_icecast_message(body: str) -> str:
    xml_match = re.search(r"<message>(.*?)</message>", body, flags=re.IGNORECASE | re.DOTALL)
    if xml_match:
        return html.unescape(xml_match.group(1).strip())

    html_match = re.search(r"Message:\\s*([^<\\n\\r]+)", body, flags=re.IGNORECASE)
    if html_match:
        return html.unescape(html_match.group(1).strip())

    return body.strip() or "Nieznana odpowiedz Icecast"


def update_mount_metadata(cfg: RuntimeConfig, mount_name: str, title: str) -> tuple[bool, str]:
    params = urlencode(
        {
            "mode": "updinfo",
            "mount": f"/{mount_name}",
            "song": title,
        },
        encoding="utf-8",
    )
    endpoints = ("/admin/metadata", "/admin/metadata.xsl")
    last_message = "Brak odpowiedzi z Icecast"

    for endpoint in endpoints:
        url = f"{cfg.base_url}{endpoint}?{params}"
        body = http_get_text(url, auth=(cfg.metadata_user, cfg.metadata_password))
        message = parse_icecast_message(body)
        lowered = message.lower()
        if "metadata update successful" in lowered:
            return True, f"{message} ({endpoint})"

        last_message = f"{message} ({endpoint})"
        if "mountpoint will not accept url updates" not in lowered:
            break

    return False, last_message


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
    air_quality_cache: dict[str, dict[str, Any] | None] = {}
    geo_names: dict[str, str] = {}

    for city in sorted(set(mount_city.values())):
        try:
            point = geocode_city(city, cfg, geocode_cache)
            weather = current_weather(point, cfg)
        except Exception as exc:
            log(f"BLAD pogody dla miasta '{city}': {exc}")
            continue
        try:
            air_quality = current_air_quality(point, cfg)
        except Exception as exc:
            log(f"UWAGA brak danych jakości powietrza dla miasta '{city}': {exc}")
            air_quality = None
        weather_cache[city] = weather
        air_quality_cache[city] = air_quality
        geo_names[city] = point.name

    for mount in mounts:
        city_query = mount_city[mount]
        weather = weather_cache.get(city_query)
        air_quality = air_quality_cache.get(city_query)
        city_name = geo_names.get(city_query)
        if weather is None or city_name is None:
            log(f"POMINIETO {mount}: brak danych pogodowych dla '{city_query}'")
            continue
        title = build_title(cfg.title_template, city_name, weather, mount, air_quality)

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
    parser.add_argument(
        "--title-mode",
        help="Title preset mode: classic, outside or weather",
    )
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
        "Start: base_url=%s mount_prefix=%s interval=%ss dry_run=%s title_mode=%s"
        % (cfg.base_url, cfg.mount_prefix, cfg.interval_seconds, cfg.dry_run, cfg.title_mode)
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
