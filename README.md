# AION 2 Stream Tracker

A single executable (`aion2tracker.exe` / Linux `aion2tracker`, written in V, SQLite and HTML compiled in). Every 15 minutes
it collects streamers' character data from the **official AION 2 API** (`aion2.plaync.com` — the same API shugo.gg uses)
and shows it on a live chart.

## Running

```
aion2tracker.exe --port 8080 --password SecretPassword
```

| flag | description |
|---|---|
| `--help` | help |
| `--port`, `-p` | HTTP port (default 8080) |
| `--password` | password for `/admin/` (or the `A2T_PASSWORD` environment variable) |
| `--db` | database file (default `aion2tracker.db` next to the executable — created automatically) |
| `--interval` | collection interval in minutes (default 15; cycles are aligned to :00/:15/:30/:45) |
| `--host` | listen address (default `0.0.0.0`) |

- `http://<host>:8080/` — public chart (read-only).
- `http://<host>:8080/admin/` — admin panel:
  - **with a password** it is reachable from any address and requires login; **5 wrong passwords from one IP block that
    IP for 1 minute** (IP = the connection's address; behind a reverse proxy on the same machine, the last
    `X-Forwarded-For` entry, which the client cannot forge). Without HTTPS the password travels in plain text — when exposing
    the panel to the internet, put a reverse proxy with TLS in front of it.
  - **without a password** it only works from localhost (the TCP socket address is checked; requests carrying proxy
    headers are treated as remote).

## What is collected

Combat Power, Item Level, level, class, Daevanion (total + each board `open/total`), god stats (total + each god),
weapon (name, grade, `+enchant/max`, exceed ◆0–5, attack), stigmas (sum of levels + list).

### How it is stored (SQLite, schema v3)

Plain columns, no JSON, and **only changes are written**: if nothing changed since the previous read, no new row is
created (the chart holds a value until the next change; "last update" shows the time of the last successful read).

| table | contents | written |
|---|---|---|
| `samples` | cp, item_level, level, totals (daevanion, gods, stigmas), weapon enchant/exceed — ~32 B/row | when anything changes |
| `sample_boards` + `boards` | open nodes per board (dictionary of names and node counts) | when the boards change |
| `sample_gods` | 10 columns (justice … space) | when the god stats change |
| `sample_weapon` | id, name, grade, enchant, exceed, max, attack | when the weapon changes |
| `sample_stigmas` + `skills` | level + equipped, per stigma (dictionary of names) | when the stigmas change |
| `avatars` | 192×192 PNG/JPEG as BLOBs (uploaded and in-game portrait) | on upload / when the portrait changes |
| `players`, `teams`, `meta` | configuration and status | status once per cycle, in one transaction |

A cycle with 14 players and 1–2 changes writes ~4–5 pages (16–20 KB) to the WAL (previously ~400 KB).

**CP spikes from PvP events** (a jump of >60% and >30k, e.g. 100k → 480k → 100k) are not stored; if such a value persists
for 8 consecutive reads (2 h), it is accepted as real. Older databases (v1/v2) are migrated automatically on startup
(and on import), with duplicates and spikes removed; a copy `*.db.bak-v2` is made next to the database first.

## Chart

- modes: CP, Item Level, Daevanion Σ / per board, Gods Σ / per god, Weapon (+enchant + ◆exceed), Stigmas Σ, Level;
- the right edge is "now" (0), the X axis is relative (−15m, −6h, −2d…), time-window slider and presets, Ctrl+wheel = zoom;
- hovering a dot shows a tooltip with all the data and deltas; clicking a player highlights them;
- "Gain Δ" (change since the start of the window), "From zero", smooth/steps/linear lines, team filter, ranking below the chart;
- **OBS link** copies the URL of the chart alone with a transparent background (`?obs=1&bg=transparent&mode=…&range=…`).

## Languages

The chart and the admin panel have a **PL / EN** switch (remembered by the browser; `?lang=en` in the URL, also in the OBS
link). The page's default language is set in the admin panel (automatic = browser language). Server error messages and
worker errors are translated too (`X-Lang` / `Accept-Language` header).

## Admin panel

The character search works like shugo.gg: **🌍 Global** by default (all regions at once: EU, NA East/West, SA, Asia);
results show class, level, server (region) and race; clicking a result fills in the character name and server.
Players (display name, character name, server, avatar, team, color, sort order),
**Active** (the worker collects data) and **On chart** (publicly visible) switches, teams with colors, default mode/window,
database export and **import with merging** (teams matched by name, players by server + character name, samples by
player + time — duplicates are skipped).

### Avatars

The upload sends the original file (PNG/JPG/GIF/BMP; WebP/AVIF/HEIC are first converted to PNG by the browser, max 15 MB).
The server decodes it, crops the center to a square, scales it to 192×192 (smaller images are not upscaled) and stores it in
the database as PNG (with transparency) or JPEG (photos). The worker also downloads the character's in-game portrait,
scales it and keeps it in the database (refreshed once a day). The chart shows: uploaded avatar → in-game portrait →
initials. Avatars are included in database export/import.

## Building

Requires V (tested with 0.5.0) and gcc from MSYS2 UCRT64. Once: `v run %VROOT%\vlib\db\sqlite\install_thirdparty_sqlite.vsh`.
Then `build.bat`. The result is a static executable that depends only on Windows system DLLs.

`vendor/veb` is a copy of the `veb` module from V 0.5.0 with one fix (marked `aion2tracker patch` in `veb_picoev.v`):
upstream lost the tail of a request body when the headers arrived in a separate packet, and uploads hung until the timeout.
The build scripts pass `-path "vendor|@vlib|@vmodules"`, so `import veb` picks up the fixed version.

To work on the HTML without rebuilding: `set A2T_WEB_DIR=web` — the pages are then read from disk.

### Linux

`build_linux.bat` (run on Windows) produces a fully static Linux x86-64 binary: `build\linux\aion2tracker`
(musl, zero dependencies — runs on any distribution, HTML and SQLite inside). It additionally requires **zig** in PATH
(`winget install zig.zig`). V only generates the C code for Linux, and `zig cc` compiles it together with libgc, mbedtls,
SQLite, stb_image and cJSON; the library objects are cached in `build\linux\obj` (`build_linux.bat clean` = from scratch).

```
scp build/linux/aion2tracker server:~/
./aion2tracker --port 8080 --password SecretPassword     # the database is created next to the binary
```

On Linux, V's HTTPS client is mbedtls (on Windows it is schannel) with a default read timeout of 550 ms — too short for
the AION 2 API, so the build sets `-d mbedtls_client_read_timeout_ms=20000`.

### Docker

The `Dockerfile` packs the static binary from `build_linux.bat` into a `scratch` image (~4 MB: just the binary, no OS).
The database is SQLite only, in `/data/aion2tracker.db` on a (persistent) volume; the container runs as a non-root user.

```
build_linux.bat
docker build -t aion2tracker .
docker run -d --name aion2tracker --restart unless-stopped -p 8080:8080 -e A2T_PASSWORD=SecretPassword -v aion2data:/data aion2tracker
```

or `docker compose up -d --build` (password in `A2T_PASSWORD` or in an `.env` file next to `docker-compose.yml`).
In Docker a password is required — without one the admin panel only answers connections from inside the container.
Extra flags go at the end: `docker run … aion2tracker --interval 10`. Backups: export from the admin panel, or copy the volume.
