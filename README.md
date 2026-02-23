# Icecast Metadata Updater

Narzędzie aktualizuje tytuły metadanych (`song`) w aktywnych mountach Icecast o prefiksie `outside_`.
Dla każdego mounta pobiera pogodę dla miasta wywnioskowanego z nazwy mounta, np.:

- `outside_krakow` -> `Kraków`
- `outside_lodz` -> `Łódź`
- `outside_zabki` -> `Ząbki` (można nadpisać przez `city_overrides`)

## Jak to działa

1. Pobiera aktywne źródła z `status-json.xsl`.
2. Filtruje mounty zaczynające się od `outside_`.
3. Pobiera geolokalizację miasta i aktualną pogodę z Open-Meteo.
   Dane obejmują m.in. temperaturę, wiatr oraz opad (`precipitation/rain/showers/snowfall`),
   w tym opady mieszane (`deszcz ze śniegiem`).
4. Wysyła update przez Icecast: `/admin/metadata?mode=updinfo`.
   Na starszych instalacjach, gdy trzeba, automatycznie przechodzi na `/admin/metadata.xsl`.

## Pliki

- `weather_metadata_updater.py` - główny skrypt
- `start_updater.sh` - start produkcyjny (UTF-8, lock, log, watchdog)
- `install.sh` - instalator (kopiowanie plików + konfiguracja usługi `systemd --user`)
- `config.example.json` - przykładowa konfiguracja
- `systemd/icecast-metadata-updater.service` - wzór usługi użytkownika systemd

## Instalacja (uniwersalna)

Wymagania:

- Linux z `systemd --user`
- `python3`

Szybka instalacja:

```bash
git clone <URL_REPO> icecast-metadata-updater
cd icecast-metadata-updater
./install.sh
```

Instalacja do innego katalogu:

```bash
./install.sh --install-dir "$HOME/moj-updater-icecast"
```

## Uruchomienie

Tryb jednorazowy:

```bash
python3 weather_metadata_updater.py --once
```

Tryb ciągły (domyślnie co 120 s):

```bash
python3 weather_metadata_updater.py
```

Autostart po restarcie realizuje usługa `systemd --user`:

```bash
systemctl --user enable --now icecast-metadata-updater.service
```

Log działania:

- `logs/updater.log`
- przy awarii pojawi się wpis `WATCHDOG: ... restart in 10s`

Status usługi:

```bash
systemctl --user status icecast-metadata-updater.service
```

Zatrzymanie / restart usługi:

```bash
systemctl --user stop icecast-metadata-updater.service
systemctl --user restart icecast-metadata-updater.service
```

## Konfiguracja

Domyślnie skrypt próbuje wykryć `base_url` i `source_password` z:

- `/etc/darkice.cfg`
- `/etc/darkice2.cfg`

Możesz podać wszystko ręcznie przez `config.json` (na bazie `config.example.json`) albo argumenty CLI:

```bash
python3 weather_metadata_updater.py \
  --base-url http://127.0.0.1:8888 \
  --source-user source \
  --source-password YOUR_PASSWORD \
  --metadata-user admin \
  --metadata-password YOUR_ADMIN_PASSWORD \
  --interval-seconds 120
```

## Najważniejsze opcje

- `--once` - uruchamia tylko jeden cykl
- `--dry-run` - nie wysyła update, tylko loguje
- `--mount-prefix outside_` - prefiks mountów
- `--interval-seconds 120` - interwał odświeżania
- `--title-template "{city}: {temp}°C, ..."` - format tytułu
  Dostępne pola: `{city}`, `{temp}`, `{feels}`, `{wind}`, `{condition}`, `{precip}`,
  `{precipitation_mm}`, `{rain_mm}`, `{showers_mm}`, `{snowfall_cm}`, `{mount}`.

## Uwaga dot. uprawnień

Jeśli zobaczysz komunikat `Mountpoint will not accept URL updates`, to dany mount
nie przyjmuje aktualizacji przez aktualne konto. W praktyce zwykle trzeba użyć
konta admin (`metadata_user` / `metadata_password`) zamiast samego `source`.

## Uwaga dot. polskich znaków

Skrypt wysyła metadata w UTF-8. Klienci audio (np. `ffprobe`, wiele playerów) pokazują
polskie znaki poprawnie. Na starszym Icecaście `status-json.xsl` może czasem pokazywać
zniekształcone znaki, ale nie musi to oznaczać błędu po stronie słuchacza.
