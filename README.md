# Icecast Metadata Updater

Narzędzie aktualizuje tytuły metadanych (`song`) w aktywnych mountach Icecast o prefiksie `outside_`.
Dla każdego mounta pobiera pogodę dla miasta wywnioskowanego z nazwy mounta, np.:

- `outside_krakow` -> `Kraków`
- `outside_lodz` -> `Łódź`
- `outside_zabki` -> `Ząbki` (można nadpisać przez `city_overrides`)

Dodatkowo może aktualizować osobny mount (np. `tuner`) danymi z API FM-DX:

- częstotliwość (`freq`)
- RDS PS (`ps`)

## Jak to działa

1. Pobiera aktywne źródła z `status-json.xsl`.
2. Filtruje mounty zaczynające się od `outside_`.
3. Pobiera geolokalizację miasta, aktualną pogodę oraz jakość powietrza z Open-Meteo.
   Dane obejmują m.in. temperaturę, wiatr, opad (`precipitation/rain/showers/snowfall`)
   oraz europejski indeks jakości powietrza (`AQI`).
4. Wysyła update przez Icecast: `/admin/metadata?mode=updinfo`.
   Na starszych instalacjach, gdy trzeba, automatycznie przechodzi na `/admin/metadata.xsl`.
5. (Opcjonalnie) dla mounta `tuner` pobiera dane z `http://127.0.0.1:8080/api`
   i ustawia tytuł wg szablonu, np. `Tuner: 93.000 MHz | RDS: RMF FM`.
   Częstotliwość odświeżania tunera ustawiasz osobno przez `tuner.interval_seconds`
   (np. `5`), niezależnie od `update.interval_seconds` dla pogody.
6. Sekcje `outside_*` możesz całkowicie wyłączyć przez `outside.enabled=false`
   (przydatne dla osobnego wariantu Tuner-only).

## Pliki

- `weather_metadata_updater.py` - główny skrypt
- `config_wizard.py` - interaktywny kreator konfiguracji `config.json`
- `install_online.sh` - instalator online (pobranie + weryfikacja + instalacja z `latest.json`)
- `install_tuner_only.sh` - instalator online profilu Tuner-only (bez `outside_*`)
- `doctor.sh` - szybka diagnostyka konfiguracji, polaczenia i uslug
- `start_updater.sh` - start produkcyjny (UTF-8, lock, log, watchdog, opcjonalny check update przy starcie)
- `install.sh` - instalator (kopiowanie plików + konfiguracja usługi `systemd --user`)
- `update.sh` - aktualizacja programu i restart usługi
- `auto_update.sh` - silnik automatycznej aktualizacji z manifestu
- `enable_auto_update.sh` - włączenie/wyłączenie auto-update (timer systemd użytkownika)
- `auto_update.example.conf` - przykład konfiguracji auto-update
- `make_installer_bundle.sh` - tworzy paczkę `.tar.gz`, manifest `latest.json` i opcjonalnie publikuje je do katalogu WWW
- `config.example.json` - przykładowa konfiguracja
- `config.tuner-only.example.json` - przykładowa konfiguracja tylko dla tunera
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
python3 ~/icecast-metadata-updater/config_wizard.py --config ~/icecast-metadata-updater/config.json
```

Domyślnie instalator przy pierwszym uruchomieniu tworzy `config.json` z `config.example.json`
(bez kopiowania Twojego lokalnego `config.json`).

Instalacja do innego katalogu:

```bash
./install.sh --install-dir "$HOME/moj-updater-icecast"
```

Jeśli świadomie chcesz skopiować lokalny `config.json` obok instalatora:

```bash
./install.sh --use-source-config
```

## Kreator konfiguracji

Kreator prowadzi krok po kroku przez:

- adres Icecast (lokalny lub zdalny),
- loginy i hasła,
- interwał odświeżania,
- wybór trybu tytułu (`classic` / `outside` / `weather`),
- opcjonalne mapowania `city_overrides`,
- test połączenia do `status-json.xsl`.

Uruchomienie:

```bash
cd ~/icecast-metadata-updater
python3 config_wizard.py --config config.json
```

## Instalacja 1 komendą (online)

Instalacja bez ręcznego pobierania paczki:

```bash
curl -fsSL https://kazpar.pl/icecast-updater/install_online.sh | bash
```

Instalator online:

- pobiera `latest.json`,
- pobiera najnowszą paczkę,
- weryfikuje sumę SHA256,
- uruchamia `install.sh`,
- opcjonalnie uruchamia kreator i auto-update.

Wariant Tuner-only (bez `outside_*`):

```bash
curl -fsSL https://kazpar.pl/icecast-updater/install_tuner_only.sh | bash
```

Skrypt ustawia profil:

- `outside.enabled=false`
- `tuner.enabled=true`
- zachowuje backup poprzedniego `config.json`
- pyta, czy uruchomic kreator `config_wizard.py` po instalacji

## Diagnostyka

Szybki test konfiguracji i polaczenia z Icecast:

```bash
~/icecast-metadata-updater/doctor.sh --install-dir ~/icecast-metadata-updater --config ~/icecast-metadata-updater/config.json --run-dry-run
```

Skrypt sprawdza:

- konfiguracje (`base_url`, hasla, prefiks mountow),
- dostep do `status-json.xsl`,
- endpoint metadata (`/admin/metadata` lub `/admin/metadata.xsl`),
- status uslugi i timera `systemd --user`,
- log `logs/updater.log`,
- opcjonalnie test `--once --dry-run`.

## Paczka dla znajomego

Tworzenie paczki z najnowszą wersją:

```bash
./make_installer_bundle.sh
```

Tworzenie i od razu publikacja pod stronę (np. `kazpar.pl`):

```bash
./make_installer_bundle.sh \
  --publish-dir "$HOME/www/icecast-updater" \
  --site-url "https://kazpar.pl/icecast-updater" \
  --clean-publish
```

Skrypt utworzy pliki w `dist/`:

- `icecast-metadata-updater-<wersja>.tar.gz`
- `icecast-metadata-updater-<wersja>.tar.gz.sha256`
- `CHANGELOG.md` (opis zmian z historii commitow)
- `latest.json` (manifest dla auto-update, zawiera tez `changes` z lista zmian)
- `install_online.sh` (instalator online)
- `doctor.sh` (skrypt diagnostyczny)

Przy publikacji do WWW dodatkowo tworzy:

- `index.html` (czytelna strona aktualizacji)

Aktualizacja u znajomego po wypakowaniu nowej paczki:

```bash
./update.sh --install-dir "$HOME/icecast-metadata-updater"
python3 ~/icecast-metadata-updater/config_wizard.py --config ~/icecast-metadata-updater/config.json
```

Aktualizacja u znajomego przy instalacji z Git:

```bash
./update.sh --pull
```

## Auto-update z domeny

Po stronie autora (u Ciebie):

1. Zbuduj paczkę:

```bash
./make_installer_bundle.sh \
  --publish-dir "$HOME/www/icecast-updater" \
  --site-url "https://kazpar.pl/icecast-updater" \
  --clean-publish
```

2. Pliki są gotowe pod adresem:

- `https://kazpar.pl/icecast-updater/`
- `https://kazpar.pl/icecast-updater/latest.json`
- `https://kazpar.pl/icecast-updater/install_online.sh`
- `https://kazpar.pl/icecast-updater/doctor.sh`
- `https://kazpar.pl/icecast-updater/CHANGELOG.md`

Rekomendowane (bezpieczenstwo): publikuj paczki z podpisem cyfrowym:

```bash
./make_installer_bundle.sh \
  --publish-dir "$HOME/www/icecast-updater" \
  --site-url "https://kazpar.pl/icecast-updater" \
  --clean-publish \
  --signing-key "$HOME/.keys/icecast_updater_signing_private.pem"
```

Wtedy `latest.json` zawiera pola `signature_required`, `signature_algo` i `signature`,
a instalatory online/auto-update weryfikuja podpis paczki (poza SHA256).

Po stronie znajomego (jednorazowo):

```bash
cd ~/icecast-metadata-updater
./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json" --run-now
```

Skrypt zapisuje wszystkie ustawienia aktualizacji do:

- `~/icecast-metadata-updater/auto_update.conf`

W tym pliku masz teraz w jednym miejscu:

- adres `latest.json` (`UPDATE_MANIFEST_URL`),
- interwał timera (`UPDATE_TIMER_INTERVAL`),
- losowe opóźnienie (`UPDATE_TIMER_RANDOM_DELAY`),
- sprawdzenie po starcie systemu (`UPDATE_TIMER_ON_BOOT_SEC`),
- sprawdzenie przy starcie programu (`UPDATE_CHECK_ON_START`),
- opóźnienie checka przy starcie programu (`UPDATE_CHECK_ON_START_DELAY_SEC`),
- timeout sprawdzenia przy starcie (`UPDATE_CHECK_TIMEOUT_SEC`).
- opcjonalna sciezka do klucza publicznego (`SIGNING_PUBLIC_KEY_PATH`),
- wymuszenie podpisu (`ALLOW_UNSIGNED=0` domyslnie).

Po ręcznej zmianie tych wartości uruchom ponownie:

```bash
./enable_auto_update.sh --manifest-url "https://kazpar.pl/icecast-updater/latest.json"
```

Sprawdzenie statusu:

```bash
systemctl --user status icecast-metadata-updater-autoupdate.timer
```

Wyłączenie auto-update:

```bash
./enable_auto_update.sh --disable
```

## Integracja z kazpar.pl (szybki workflow)

Jednym poleceniem robisz nową wersję i publikujesz ją na stronie:

```bash
cd ~/icecast-metadata-updater
./make_installer_bundle.sh \
  --publish-dir "$HOME/www/icecast-updater" \
  --site-url "https://kazpar.pl/icecast-updater" \
  --clean-publish
```

Efekt:

- `latest.json` wskazuje najnowszą paczkę i zawiera pole `changes`
- `CHANGELOG.md` pokazuje ostatnie zmiany (historia commitow)
- znajomy aktualizuje się automatycznie przez swój timer `systemd --user`
- Ty utrzymujesz aktualizacje przez zwykłe pliki statyczne na WWW (bez ingerencji w Icecast)

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
- `--title-mode classic|outside|weather` - szybki wybór gotowego formatu tytułu
- `--title-template "(outside from {city_ascii}, quality 320kbps mp3 temperatura: {temp}°C, ...)"` - format tytułu
  Dostępne pola: `{city}`, `{city_ascii}`, `{temp}`, `{feels}`, `{wind}`, `{wind_details}`, `{wind_details_clause}`,
  `{wind_gust}`, `{wind_direction}`, `{wind_direction_deg}`, `{condition}`, `{cloud_cover_pct}`, `{precip}`, `{precip_clause}`,
  `{pressure}`, `{pressure_clause}`, `{pressure_hpa}`, `{humidity}`, `{humidity_clause}`, `{humidity_pct}`, `{air}`, `{air_clause}`, `{aqi}`,
  `{precipitation_mm}`, `{rain_mm}`, `{showers_mm}`, `{snowfall_cm}`, `{mount}`.
  `{city_ascii}` to nazwa miasta bez polskich znaków (np. `Łódź` -> `Lodz`).
  `{wind_details}` zawiera np. `w porywach do 24 km/h, kierunek południowo-zachodni`, a `{wind_details_clause}` to ten sam tekst z przecinkiem.
  Dla opisów z `zachmurzenie` pole `{condition}` automatycznie dopisuje procent, np. `zachmurzenie (82%)`.
  `{precip}` jest puste przy braku opadów, a `{precip_clause}` to gotowy fragment z przecinkiem.
  `{pressure}` jest puste, gdy brak danych ciśnienia, a `{pressure_clause}` to gotowy fragment z przecinkiem.
  `{humidity}` jest puste, gdy brak danych wilgotności, a `{humidity_clause}` to gotowy fragment z przecinkiem.
  `{air}` jest puste, gdy brak danych AQI, a `{air_clause}` to gotowy fragment z przecinkiem.
  Jeśli ustawisz własne `title_template`, to ma ono wyższy priorytet niż `title_mode`.
  Dla starszych konfiguracji ze starym domyślnym układem `classic` program pyta
  o potwierdzenie migracji tylko w trybie interaktywnym. W usłudze (bez TTY)
  pozostawia dotychczasowy układ, bez wymuszenia.

Opcje konfiguracyjne dla tunera (w `config.json`):

- `outside.enabled` - `true/false`, wlacza/wylacza sekcje `outside_*`
- `tuner.enabled` - `true/false`, wlacza/wylacza aktualizacje mounta tunera
- `tuner.title_template` - szablon dla tunera
  Dostepne pola tunera: `{freq}`, `{ps}`, `{station}`, `{tx}`, `{tx_city}`, `{power}`, `{distance}`, `{signal}`, `{pi}`, `{azimuth}`, `{rt}`, `{mount}`.

## Uwaga dot. uprawnień

Jeśli zobaczysz komunikat `Mountpoint will not accept URL updates`, to dany mount
nie przyjmuje aktualizacji przez aktualne konto. W praktyce zwykle trzeba użyć
konta admin (`metadata_user` / `metadata_password`) zamiast samego `source`.

## Uwaga dot. polskich znaków

Skrypt wysyła metadata w UTF-8. Klienci audio (np. `ffprobe`, wiele playerów) pokazują
polskie znaki poprawnie. Na starszym Icecaście `status-json.xsl` może czasem pokazywać
zniekształcone znaki, ale nie musi to oznaczać błędu po stronie słuchacza.

## Automatyczne wydania (GitHub Releases)

Release tworzy sie automatycznie po wypchnieciu taga w formacie `vX.Y.Z`.

Przyklad:

```bash
git tag v2026.03.02.1
git push origin main --tags
```

Workflow buduje nowa paczke instalacyjna (`.tar.gz`), sumy SHA256 i publikuje je jako GitHub Release.
