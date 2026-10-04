# AION 2 Stream Tracker

Jeden plik `aion2tracker.exe` (V + SQLite, HTML wbudowany w exe). Co 15 minut zbiera z **oficjalnego API AION 2**
(`aion2.plaync.com`, to samo, z którego korzysta shugo.gg) dane postaci streamerów i pokazuje je na żywym wykresie.

## Uruchomienie

```
aion2tracker.exe --port 8080 --password TajneHaslo
```

| parametr | opis |
|---|---|
| `--help` | pomoc |
| `--port`, `-p` | port HTTP (domyślnie 8080) |
| `--password` | hasło do `/admin/` (albo zmienna środowiskowa `A2T_PASSWORD`) |
| `--db` | plik bazy (domyślnie `aion2tracker.db` obok exe — tworzony automatycznie) |
| `--interval` | co ile minut zbierać dane (domyślnie 15, cykle wyrównane do :00/:15/:30/:45) |
| `--host` | adres nasłuchu (domyślnie `0.0.0.0`) |

- `http://<host>:8080/` — publiczny wykres (tylko odczyt).
- `http://<host>:8080/admin/` — panel admina:
  - **z hasłem** działa z każdego adresu, wymaga logowania; **5 złych haseł z jednego IP = blokada tego IP na 1 minutę**
    (IP = adres połączenia; za reverse proxy na tej samej maszynie — ostatni wpis `X-Forwarded-For`, którego klient nie podrobi).
    Hasło idzie otwartym tekstem, jeśli nie ma HTTPS — wystawiając panel do internetu, postaw przed nim reverse proxy z TLS.
  - **bez hasła** działa tylko z localhost (sprawdzany jest adres gniazda TCP; żądania z nagłówkami proxy są traktowane jako zdalne).

## Co jest zbierane (na próbkę)

Combat Power, Item Level, poziom, klasa, Daevanion (suma + każda tablica `otwarte/wszystkie`), statystyki bogów (suma + każdy bóg),
broń (nazwa, grade, `+enchant/max`, exceed ◆0–5, atak), stigmy (suma poziomów + lista).

### Jak to leży w bazie (SQLite, schemat v3)

Zwykłe kolumny, bez JSON-a, i **zapis tylko zmian**: jeśli od poprzedniego odczytu nic się nie zmieniło, nie powstaje nowy
wiersz (wykres trzyma wartość aż do następnej zmiany; „ostatni odczyt” pokazuje czas ostatniego udanego zapytania).

| tabela | zawartość | zapis |
|---|---|---|
| `samples` | cp, item_level, level, sumy (daevanion, bogowie, stigmy), enchant/exceed broni — ~32 B/wiersz | gdy cokolwiek się zmieni |
| `sample_boards` + `boards` | otwarte węzły per tablica (słownik nazw i maksimów) | gdy zmienią się tablice |
| `sample_gods` | 10 kolumn (justice … space) | gdy zmienią się bogowie |
| `sample_weapon` | id, nazwa, grade, enchant, exceed, max, atak | gdy zmieni się broń |
| `sample_stigmas` + `skills` | poziom + założona, per stigma (słownik nazw) | gdy zmienią się stigmy |
| `avatars` | PNG/JPEG 192×192 jako BLOB (wgrany i portret z gry) | przy uploadzie / zmianie portretu |
| `players`, `teams`, `meta` | konfiguracja i status | status raz na cykl, jedną transakcją |

Cykl z 14 graczami i 1–2 zmianami zapisuje ~4–5 stron (16–20 KB) do WAL (wcześniej ~400 KB).
**Spike'i CP z eventów PvP** (skok o >60% i >30k, np. 100k → 480k → 100k) nie są zapisywane; jeśli taka wartość utrzyma
się przez 8 kolejnych odczytów (2 h), jest traktowana jako prawdziwa. Starsze bazy (v1/v2) są migrowane automatycznie
przy starcie (także przy imporcie) — z usunięciem duplikatów i spike'ów; wcześniej obok powstaje kopia `*.db.bak-v2`.

## Wykres

- tryby: CP, Item Level, Daevanion Σ / per tablica, Bogowie Σ / per bóg, Broń (+enchant + ◆exceed), Stigmy Σ, Poziom;
- prawa krawędź = teraz (0), oś X względna (−15m, −6h, −2d…), suwak/presety okna czasu, Ctrl+kółko = zoom;
- najechanie na kropkę → tooltip ze wszystkimi danymi i deltami; klik w gracza → wyróżnienie;
- „Przyrost Δ” (zmiana od początku okna), „Od zera”, linie gładkie/schodki/proste, filtr teamów, ranking pod wykresem;
- **Link do OBS** kopiuje URL samego wykresu z przezroczystym tłem (`?obs=1&bg=transparent&mode=…&range=…`).

## Języki

Wykres i panel admina mają przełącznik **PL / EN** (zapamiętywany w przeglądarce; `?lang=en` w URL, także w linku do OBS).
Domyślny język strony ustawia się w adminie (automatycznie = język przeglądarki). Komunikaty błędów z serwera i błędy
workera też są tłumaczone (nagłówek `X-Lang` / `Accept-Language`).

## Panel admina

Wyszukiwarka postaci działa jak na shugo.gg: domyślnie **🌍 Global** (wszystkie regiony naraz: EU, NA East/West, SA, Azja),
wynik pokazuje klasę, poziom, serwer (region) i rasę; kliknięcie wyniku ustawia nick i serwer.
Gracze (wyświetlany nick, nick w grze, serwer, avatar, team, kolor, sort),
przełączniki **Aktywny** (worker zbiera) i **Na wykresie** (widoczny publicznie), teamy z kolorami, domyślny tryb/okno,
eksport bazy oraz **import ze scalaniem** (teamy po nazwie, gracze po serwer+nick, próbki po gracz+czas — duplikaty pomijane).

### Avatary

Upload w panelu wysyła oryginalny plik (PNG/JPG/GIF/BMP; WebP/AVIF/HEIC przeglądarka najpierw konwertuje do PNG, max 15 MB).
Serwer dekoduje go, przycina środek do kwadratu, skaluje do 192×192 (mniejszych nie powiększa) i zapisuje w bazie
jako PNG (z przezroczystością) albo JPEG (zdjęcia). Portret postaci z gry worker też pobiera, skaluje i trzyma w bazie
(odświeżany raz na dobę). Wykres pokazuje: wgrany avatar → portret z gry → inicjały. Avatary są w eksporcie/imporcie bazy.

## Budowanie

Wymaga V (testowane na 0.5.0) i gcc z MSYS2 UCRT64. Jednorazowo: `v run %VROOT%\vlib\db\sqlite\install_thirdparty_sqlite.vsh`.
Potem `build.bat`. Wynik to statyczny exe zależny tylko od systemowych DLL Windows.

### Linux

`build_linux.bat` (na Windowsie) robi w pełni statyczną binarkę Linux x86-64: `build\linux\aion2tracker`
(musl, zero zależności — działa na każdej dystrybucji, HTML i SQLite w środku). Wymaga dodatkowo **zig** w PATH
(`winget install zig.zig`). V generuje tylko kod C dla Linuxa, a `zig cc` kompiluje go razem z libgc, mbedtls, SQLite,
stb_image i cJSON; obiekty bibliotek są cache'owane w `build\linux\obj` (`build_linux.bat clean` = od zera).

```
scp build/linux/aion2tracker serwer:~/
./aion2tracker --port 8080 --password TajneHaslo     # baza powstaje obok binarki
```

Na Linuxie klient HTTPS w V to mbedtls (na Windowsie schannel) z domyślnym timeoutem odczytu 550 ms — za mało dla API
AION 2, dlatego build ustawia `-d mbedtls_client_read_timeout_ms=20000`.

### Docker

`Dockerfile` pakuje statyczną binarkę z `build_linux.bat` do obrazu `scratch` (~4 MB: sama binarka, bez systemu).
Baza to wyłącznie SQLite w `/data/aion2tracker.db` na wolumenie (persistent), kontener działa jako użytkownik bez roota.

```
build_linux.bat
docker build -t aion2tracker .
docker run -d --name aion2tracker --restart unless-stopped -p 8080:8080 -e A2T_PASSWORD=TajneHaslo -v aion2data:/data aion2tracker
```

albo `docker compose up -d --build` (hasło w `A2T_PASSWORD` albo w pliku `.env` obok `docker-compose.yml`).
W Dockerze hasło jest konieczne — bez niego panel odpowiada tylko na połączenia z wnętrza kontenera.
Dodatkowe flagi dopisuje się na końcu `docker run … aion2tracker --interval 10`. Backup: eksport z panelu albo kopia wolumenu.

`vendor/veb` to kopia modułu `veb` z V 0.5.0 z jedną poprawką (oznaczoną `aion2tracker patch` w `veb_picoev.v`):
upstream gubił końcówkę ciała żądania, gdy nagłówki przyszły osobnym pakietem, i upload wisiał do timeoutu.
`build.bat` ustawia `-path "vendor|@vlib|@vmodules"`, więc `import veb` bierze poprawioną wersję.

Do pracy nad HTML bez przebudowy: `set A2T_WEB_DIR=web` — strony są wtedy czytane z dysku.
