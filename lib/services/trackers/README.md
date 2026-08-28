# Trackers

Per-service HTTP clients live under `lib/services/{simkl,trakt,serializd,betaseries,letterboxd}/`.

**Sync orchestration** (one file per source — do not dump into `library_provider.dart`):

| File | Source |
| --- | --- |
| `lib/providers/library/tracker_sync_simkl.dart` | Simkl Sync Now, PIN, scrobble |
| `lib/providers/library/tracker_sync_trakt.dart` | Trakt watchlist |
| `lib/providers/library/tracker_sync_plex.dart` | Plex watchlist |
| `lib/providers/library/tracker_sync_letterboxd.dart` | Letterboxd export import |
| `lib/providers/library/tracker_sync_serializd.dart` | Serializd lists / scrobble |
| `lib/providers/library/tracker_sync_betaseries.dart` | BetaSeries lists |
| `lib/providers/library/tracker_sync_coordinator.dart` | Shared phase, match index, tap router |

Screens still call `library.syncSimklActivity` etc. (same-library extensions).

Shared helpers in this folder:

| File | Job |
| --- | --- |
| `tracker_sync_runner.dart` | `TrackerSyncPhase`, match-index build |
| `tracker_import_mapper.dart` | remote rows → status entries |
| `tracker_progress_merger.dart` | progress merge |
| `tracker_link_intent.dart` | soft link prompts |
| `tracker_log.dart` | sync logging |
