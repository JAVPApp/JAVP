# Playback

Player, downloads, torrents, and cast. Chrome selection:
[`lib/screens/player/README.md`](../lib/screens/player/README.md).

## Engines

| Port | Engine |
| --- | --- |
| Android + desktop (native) | **media_kit** / libmpv |
| Web + Smart TV (`JAVP_HOST=tizen\|webos`) | **`video_player`** |

Feature gates: `AppCapabilities` (`usesMediaKit`, `usesVideoPlayerBackend`).

## Player chrome

| UI | When |
| --- | --- |
| Gesture controls | Phone / desktop media_kit |
| TV remote controls | Android TV D-pad |
| Simple controls | Web / Smart TV |
| Live fullscreen | `/tv/watch` (not under `player/`) |

### Gestures & shortcuts (phone / desktop)

- Hold side strip (or Space) → temporary **2×** (toggle in Playback settings)
- Double-tap sides → seek; burst taps extend
- Brightness / volume side strips
- Lock controls, cinema mode, sleep timer, open in external player

### Live

- Quality variants + remembered preferred stream (first-tune prompt, list badges)
- Scrub modes: timeline vs programme (`LiveScrubMode`)
- Xtream timeshift / catchup when the source supports it
- EPG reminders; jump to live

### Captions

Preferred languages, remember last pick, style editor at `/captions`.
External subs from catalogs when provided.

### Multi-view

Two live panes exist in code (`MultiViewProvider`) but
`AppCapabilities.multiView` is **`false`** until the second decoder / TV chrome
are solid. See [roadmap.md](roadmap.md).

## Picture-in-picture & mini player

- **Android**: system PiP
- **Desktop**: mini-window path where enabled

## Cast

| Protocol | Platforms |
| --- | --- |
| Chromecast | Android phone / Android TV (not desktop UI / web / Smart TV) |
| DLNA + AirPlay | Android + desktop |

Cast remote: `/cast`. Optional transcode fallback in Playback settings.

## Torrents

BYO magnet or `.torrent` → local HTTP stream via embedded **librqbit**
(`rqbit_engine`). Off on web and Smart TV.

- Play from Library or from a custom catalog that exposes torrent items
- Only content you have rights to; no indexes are bundled
- Can feed offline downloads on Android when downloads are enabled

## Offline downloads (Android only)

`AppCapabilities.offlineDownloads`. UI: Library → **Downloads**,
`/downloads`, `/downloaded-series`.

Typical prefs (**Settings → Playback**): Wi‑Fi only, remove after watch,
download-ahead, My List new episodes. DVR / catchup programmes can also land
on disk when the source provides catchup URLs.

After a restart, playing a downloaded series uses files already on disk
(no catalog re-resolve for those episodes).

## Proxy & quality

- **Network** settings: route torrents / downloads / IPTV through the proxy
- **Playback**: preferred live / VOD qualities, software decoder, deinterlace

## Diagnostics

**Settings → Diagnostics**: enable on-device log, verbose hitch, share / copy /
clear. Nothing is uploaded by the app.

## Related

- [Features](features.md) · [Sources](sources.md) · [Architecture](architecture.md)
