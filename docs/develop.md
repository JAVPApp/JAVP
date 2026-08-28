# Develop

Build, run, and platform notes for contributors. Product map:
[features.md](features.md). Edit map: [architecture.md](architecture.md).

## Quick start

```bash
flutter pub get
flutter test

# Stable sideload (public updater.javp.app)
flutter run --flavor sideload \
  --dart-define=JAVP_DISTRIBUTION=sideload \
  --dart-define=JAVP_UPDATE_CHANNEL=stable

# Dev sideload (side-by-side JAVP Dev → /dev/)
flutter run --flavor sideloadDev \
  --dart-define=JAVP_DISTRIBUTION=sideload \
  --dart-define=JAVP_UPDATE_CHANNEL=dev
```

**Android** is the primary mobile target (`minSdk` 24). Cleartext HTTP is
allowed for local / IPTV hosts that still use it.

## Distributions & flavors

| Piece | Values | Role |
| --- | --- | --- |
| `JAVP_DISTRIBUTION` | `sideload` (default), `play`, `msstore` | Who owns updates |
| Android `--flavor` | `sideload`, `sideloadDev`, `play` | Package id / Play vs sideload |
| `JAVP_UPDATE_CHANNEL` | `stable`, `dev` | Which `latest.json` to poll |
| `JAVP_HOST` | `android` (default), `tizen`, `webos` | Smart TV compile switch |
| `JAVP_UI` | `auto`, `desktop`, `tv` | Force shell layout on desktop |

Always pass matching `JAVP_DISTRIBUTION` (and flavor / channel for Android
sideload*). Store docs: [play-store.md](play-store.md),
[microsoft-store.md](microsoft-store.md), [updates.md](updates.md).

## Windows

```bash
flutter run -d windows
flutter build windows --release
```

Package with `python tool/package_windows.py` → portable zip + `javp-setup.exe`.
Publish via `tool/deploy_update.py` ([updates.md](updates.md)). No Android-style
flavor; default `sideload`. Store builds: `--dart-define=JAVP_DISTRIBUTION=msstore`.

**UI freezes:** `UiStallWatchdog` / `UiDebug.mark` →
`%APPDATA%\javp\JAVP\logs\javp.log` (Settings → Diagnostics). Grep
`ui-stall|ui-freeze|jank`.

**Gamepad:** XInput via FFI (`GamepadService`). Linux/macOS have no reader yet.

Prefer local builds; do not dispatch `build-windows.yml` for routine checks.

## Linux

```bash
flutter run -d linux
flutter build linux --release
```

Deps (Debian/Ubuntu): `clang cmake ninja-build pkg-config libgtk-3-dev
liblzma-dev libsecret-1-dev libjsoncpp-dev libmpv-dev` (+ runtime `libmpv` /
`libsecret`). Zip the Flutter bundle; publish with `--linux-zip`. From Windows,
dispatch `build-linux.yml` only when you need an artifact for publish — not for
PR verification.

**Steam Deck:** Layout Auto/Desktop/TV + `linux/packaging/javp-gamemode.desktop`
(`JAVP_UI=tv`).

## macOS

```bash
flutter run -d macos
flutter build macos --release
```

Unsigned zips for now (right-click → Open). Sandbox off so media / network /
torrents work. Prefer a Mac host; CI builds macOS on `vX.Y.0` tags.

## Discord Rich Presence (desktop)

Toggle: **Settings → General**. Application id baked in; override
`DISCORD_CLIENT_ID`. Artwork: safe public poster hosts only — **never**
Jellyfin/Emby/Plex URLs (they embed tokens). Discord must be running locally.

## Desktop UI notes

`DesktopUi.enabled` gates hover, right-click menus, rail, reading-width panes,
and shortcuts (`Ctrl+K` search, `Ctrl+,` settings, …). Tablets (≥600dp short
side) get the rail but **not** desktop pointer chrome.

Player: click play/pause, `F` fullscreen, arrows seek, `M` mute, `P` mini
window, `?` help. Mute + volume slider on desktop; phones use hardware keys.

Cast on desktop = DLNA / AirPlay (not Chromecast SDK).

## Android tablets & TV

Same APK as phones. TV leanback: rail, fullscreen live zapper, remote-friendly
VOD, **Sources → Pair device** QR ([sources.md](sources.md), [sync.md](sync.md)).

## Smart TV / web (experimental)

`--dart-define=JAVP_HOST=tizen|webos` — [smart-tv.md](smart-tv.md),
[webos.md](webos.md). Web companion: [web.md](web.md).

## Layout tree

```
lib/
  platform/               # DesktopUi, TvPlatform, AdaptiveLayout, AppCapabilities
  providers/              # LibraryProvider, PlaybackProvider façades + domains
  screens/                # Home, TV, Catalog, Music, Library, Sports, Settings, …
  screens/player/         # One overlay per backend
  screens/tv/             # Live overlay + pairing panes
  screens/pairing/        # Phone push/pull after javp://pair
  services/storage/       # LibraryStore + SQLite DBs
  services/media_server/  # Jellyfin / Emby / Plex
  services/iptv/          # M3U, Xtream, EPG, VOD grouping
  services/catalog/       # Custom JSON
  services/trackers/      # Shared import / status
  services/pairing/       # LAN QR host + client
  services/torrent/       # Magnet / .torrent → local stream
  services/download/      # Offline downloads (Android)
  services/update/        # Sideload updater
  services/platform/      # OS window / tray / javp://
  config/                 # distribution, host, …
```

## EPG / XMLTV

Live IPTV and media-server live can take programme data from:

1. Standalone **XMLTV** source, attached on the live source edit form  
2. Inline EPG URL on M3U / Xtream (`url-tvg`) when nothing is attached  
3. Provider APIs when XMLTV has no confident channel match  

**Precedence per channel:** guide off → no EPG; else confident XMLTV match wins
over provider API.

**Matching (fail soft):** exact `tvg-id` → normalized id → unique country suffix
→ unique display-name. Native feeds write `EpgProgramDb`; web merges in memory.
Per-list **Use programme guide** toggles Guide / now-playing.

## Home “For you”

Local ranking first (`local_recommender.dart`). Remote boosts when linked:

| Source | Role |
| --- | --- |
| **TMDB** | Similar / recommendations from seeds (BYO API key) |
| **SIMKL** | Similar + plan-to-watch when linked |
| **Trakt** | Recommendations + watchlist when linked; public `/related` otherwise |
| **Letterboxd** | Export ZIP/CSV import only (movies) |
| **Serializd** | Currently Watching seeds |
| **BetaSeries** | Current / not_started → My List |

Unmapped remote titles are dropped. Cache ~6h. Tracker statuses share
`TrackerStatusStore` for CW / For You exclusion. Tokens stay device-local on
file sync ([sync.md](sync.md)).

### Tracker inbound (Sync Now / periodic)

| Source | Statuses | Progress |
| --- | --- | --- |
| SIMKL | watching, dropped, completed, hold | playback when ahead of local |
| Trakt | dropped + watching | playback when ahead |
| Serializd / Letterboxd | shared store | Letterboxd completed → 1.0 |
| BetaSeries | current / stopped / completed | episode progress when present |

Remote playhead applies only when `remote > local + 0.005`. Completed forces
`progress = 1.0`. Dropped / hold / completed exclude Continue Watching and For
You seeds.

## Localization

English source: `lib/l10n/app_en.arb`.

```bash
python3 tool/l10n/add_en.py camelCaseKey "English"
python3 tool/l10n/preflight.py
```

Do not hand-edit other `app_*.arb` or generated localizations. Missing locales
fall back to English. Details: `tool/l10n/README.md`.

## Related store / port docs

[updates.md](updates.md) · [play-store.md](play-store.md) ·
[microsoft-store.md](microsoft-store.md) · [fire-tv.md](fire-tv.md) ·
[harmonyos.md](harmonyos.md) · [app-store.md](app-store.md) ·
[mac-app-store.md](mac-app-store.md) · [catalog-api.md](catalog-api.md)
