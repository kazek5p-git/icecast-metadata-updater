# Icecast Metadata Updater

Narzędzie aktualizuje tytuly metadanych (`song`) w aktywnych mountach Icecast o prefiksie `outside_`.
Dla kazdego mounta pobiera pogode dla miasta wywnioskowanego z nazwy mounta, np.:

- `outside_krakow` -> `Krakow`
- `outside_lodz` -> `Lodz`
- `outside_zabki` -> `Zabki` (mozna nadpisac przez `city_overrides`)

## Jak to dziala

1. Pobiera aktywne zrodla z `status-json.xsl`.
2. Filtruje mounty zaczynajace sie od `outside_`.
3. Pobiera geolokalizacje miasta i aktualna pogode z Open-Meteo.
4. Wysyla update przez Icecast: `/admin/metadata?mode=updinfo`.

## Pliki

- `weather_metadata_updater.py` - glowny skrypt
- `config.example.json` - przykladowa konfiguracja

## Uruchomienie

Tryb jednorazowy:

```bash
python3 weather_metadata_updater.py --once
```

Tryb ciagly (domyslnie co 120 s):

```bash
python3 weather_metadata_updater.py
```

## Konfiguracja

Domyslnie skrypt probuje wykryc `base_url` i `source_password` z:

- `/etc/darkice.cfg`
- `/etc/darkice2.cfg`

Mozesz podac wszystko recznie przez `config.json` (na bazie `config.example.json`) albo argumenty CLI:

```bash
python3 weather_metadata_updater.py \
  --base-url http://127.0.0.1:8888 \
  --source-user source \
  --source-password YOUR_PASSWORD \
  --metadata-user admin \
  --metadata-password YOUR_ADMIN_PASSWORD \
  --interval-seconds 120
```

## Najwazniejsze opcje

- `--once` - uruchamia tylko jeden cykl
- `--dry-run` - nie wysyla update, tylko loguje
- `--mount-prefix outside_` - prefiks mountow
- `--interval-seconds 120` - interwal odswiezania
- `--title-template "{city}: {temp}C, ..."` - format tytulu

## Uwaga dot. uprawnien

Jesli zobaczysz komunikat `Mountpoint will not accept URL updates`, to dany mount
nie przyjmuje aktualizacji przez aktualne konto. W praktyce zwykle trzeba uzyc
konta admin (`metadata_user` / `metadata_password`) zamiast samego `source`.
