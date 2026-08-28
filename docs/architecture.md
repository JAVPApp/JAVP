# Architecture

JAVP grew by shipping features, not by designing a framework. This page is the
edit map. **Extract domains. Do not green-field rewrite the app.** Keep public
method names on `LibraryProvider` / `PlaybackProvider` stable (forward to domain
files).

Product overview: [features.md](features.md). Build how-to: [develop.md](develop.md).

## Hard rule

| Changing… | Edit here | Never dump into |
| --- | --- | --- |
| Tracker sync / scrobble / Sync Now | `lib/providers/library/tracker_sync_<source>.dart` (+ `lib/services/trackers/`) | `library_provider.dart` or one mega tracker file |
| VOD query / variants | `lib/providers/library/library_vod.dart` | Façade body |
| Live index / catchup | `lib/providers/library/library_live.dart` | Same |
| EPG | `lib/providers/library/library_epg.dart` | Same |
| Source add/sync | `lib/providers/library/library_sources.dart` | Catalog / TV screens |
| Downloads / offline play | `lib/providers/library/library_downloads.dart` | Same |
| Playback engine / VAST / DVR | `lib/providers/playback/*.dart` | `LibraryProvider` |
| New product domain | **new** `lib/services/<domain>/` + thin forwarder | Growing the façade |

If a change could go in the façade *or* a domain file, put it in the domain file.

## Where to edit

| I want to change… | Start here |
| --- | --- |
| Phone gestures / hold-2× / scrub | `lib/screens/player/gesture_player_controls.dart` |
| Android TV D-pad VOD chrome | `lib/screens/player/tv_remote_player_controls.dart` |
| Smart TV / web chrome | `lib/screens/player/simple_tv_player_controls.dart` |
| Which overlay is used | `lib/screens/player/player_screen.dart` |
| Play / seek / PiP / ads / DVR | `playback_provider.dart` + `playback/` |
| Add / sync / remove a source | `sources_screen.dart` + `library_sources.dart` |
| Tracker Sync Now / scrobble | `tracker_sync_<source>.dart` |
| Live + EPG UI | `tv_screen.dart` (`/iptv` → `/tv`) |
| Movies / series shelves | `catalog_screen.dart` |
| Local files / downloads / magnets | `library_screen.dart` |
| Music / Sports | `music_screen.dart` / `sports_screen.dart` + `sports_provider.dart` |
| Persist per profile | `lib/services/storage/library_store.dart` |
| Large live / VOD / EPG queries | `LiveChannelDb` / `VodCatalogDb` / `EpgProgramDb` |
| Layout: rail vs phone vs TV | [Layout helpers](#layout-helpers) |
| Feature on this port? | `lib/platform/app_capabilities.dart` |

Player chrome tree: [`lib/screens/player/README.md`](../lib/screens/player/README.md).

## The two façades

### `LibraryProvider` + `lib/providers/library/`

Construction and shared state in `library_provider.dart`. Domain methods are
same-library **extensions**:

| File | Domain |
| --- | --- |
| `tracker_sync_simkl.dart` / `_trakt` / `_plex` / `_letterboxd` / `_serializd` / `_betaseries` | Per-tracker Sync Now / scrobble |
| `tracker_sync_coordinator.dart` | Shared phase / match index / tap router |
| `library_sources.dart` | Add / remove / sync / import |
| `library_vod.dart` | `queryVodCatalog`, variants, JSON→DB migrate |
| `library_live.dart` | Live index, catchup, category loads |
| `library_epg.dart` | Guides, now-playing, reminders |
| `library_history.dart` | `recordWatch`, `recordProgress` |
| `library_downloads.dart` | Enqueue / offline play |
| `library_bootstrap.dart` | `bootstrap`, home reveal |

Call sites stay `library.queryVodCatalog` / `library.syncSimklActivity`.
Persistence: `LibraryStore`, `LiveChannelDb`, `VodCatalogDb`, `EpgProgramDb`.

### `PlaybackProvider` + `lib/providers/playback/`

| File | Domain |
| --- | --- |
| `playback_engine.dart` | media_kit / `video_player` bridge |
| `playback_vast.dart` | Preroll / midroll |
| `playback_dvr.dart` | `seekLiveDvr`, `jumpToLive` |

Load-bearing tape-fixes: `_openEpoch` / `_miniGeneration`, `claimVideoSurface`,
`playerLoadingOverlayVisible`, write-behind + `_uiQuiet` on `LibraryProvider`.

## Catalog storage

Native live, VOD, and EPG are **SQLite**. The UI isolate may hold counts, alias
maps, LRU pages, and the current shelf page — **never** the full catalog.

On disk under `{Documents}/JAVP/`: `live_channels.db`, `vod_catalog.db`,
`epg_programs.db`, catalog JSON, offline `downloads/`.

| | Live | VOD | EPG |
| --- | --- | --- | --- |
| **Native** | `LiveChannelDb` | `VodCatalogDb` (FTS5) | `EpgProgramDb` |
| **Web** | In-memory live rows | `_vodStreamCache` | `epg` + index |

**Ingest (native):** worker parses → packed rows → DB write. UI gets counts /
feed ids, not giant `List<MediaItem>`.

**Do not (native):** re-hydrate full live/VOD/EPG lists onto the UI isolate after
SQLite ingest; add a third in-memory full-catalog index; use `yieldUiIfDue` as a
substitute for writing SQLite.

**Web** may hold lists (`kIsWeb`). Keep web/test list paths; do not treat them
as the native source of truth.

## Layout helpers

| Tree | Role |
| --- | --- |
| `lib/platform/` | How the shell **looks** (desktop vs TV, rail, gutters) |
| `lib/services/platform/` | OS services (window, tray, `javp://`, brightness) |

| Question | Use |
| --- | --- |
| Hover / right-click / desktop shortcuts? | `DesktopUi.enabled` |
| 10-foot / D-pad / leanback? | `TvPlatform.isTvShell` |
| User forced TV layout on desktop? | `LayoutModeResolver` / `JAVP_UI` |
| Nav rail / poster columns? | `AdaptiveLayout` |
| Torrents / Cast / Drive / downloads? | `AppCapabilities` |

## Data model

- **`MediaItem`** — one shelf row or playable. Native catalogs stay in SQLite.
- **`IptvSource`** — M3U / Xtream / Stalker / custom / media servers / XMLTV (name is historical).
- **`SeriesInfo`** vs **`MediaDetails`** — season tree vs metadata cache.
- **`SimklMatchIndex`** — generic id/title index for trackers (name is historical).

## Browse surfaces

| Route | Screen | Job |
| --- | --- | --- |
| `/home` | `HomeScreen` | Continue watching, For you, shortcuts |
| `/tv` | `TvScreen` | Live + EPG |
| `/catalog` | `CatalogScreen` | Movies / series |
| `/music` | `MusicScreen` | Optional music browsing |
| `/library` | `LibraryScreen` | Local / downloads / magnets |
| `/sports` | `SportsScreen` | Sports follows / schedule |
| `/sources` | `SourcesScreen` | **Only** place to add/edit sources |
| `/player` | `PlayerScreen` | VOD / local / torrent session |
| `/tv/watch` | `TvLiveOverlayScreen` | Live zapper |

Full route list: [features.md](features.md). Live entry helper:
`lib/services/live_watch_nav.dart`.

## Trackers

Clients under `lib/services/{simkl,trakt,betaseries,serializd,letterboxd}/`.
Orchestration: one `tracker_sync_<source>.dart` each — see
[`lib/services/trackers/README.md`](../lib/services/trackers/README.md).
Tokens stay device-local ([sync.md](sync.md)).

## Extraction campaign

1. Player chrome helpers — done  
2. Domain extensions under `library/` / `playback/` — done  
3. Per-source tracker sync files — done  
4. **Next:** Host interface + move trackers into real classes under `lib/services/trackers/`; same for history  
5. Do not re-hydrate native SQLite catalogs onto the UI isolate  
6. Rename `IptvSource` / `SimklMatchIndex` only when call sites are few  

## Tests and UI isolate

Parse large IPTV catalogs off the UI isolate; never `Isolate.run` a huge
`List<MediaItem>` back in one shot. Native ingest writes SQLite. See
`lib/compat/ui_isolate.dart` and `.cursor/rules/ui-isolate.mdc`.

## Related

| Doc | Role |
| --- | --- |
| [features.md](features.md) / [sources.md](sources.md) / [playback.md](playback.md) | Product map |
| [develop.md](develop.md) | Build / run |
| [sync.md](sync.md) | Profiles & snapshots |
| [catalog-api.md](catalog-api.md) | Custom JSON HTTP |
| [roadmap.md](roadmap.md) | Priorities |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | PR / l10n / changelog |
| `AGENTS.md` | Agent process only — not this map |
