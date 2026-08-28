# Sources

How media enters JAVP. UI: **Sources** (`/sources`), **Home → +**, or deep links.

## Source types

| Type | Enum | Provides |
| --- | --- | --- |
| **M3U / M3U8** | `m3u` | Live (and playlist streams). Optional EPG URL / `url-tvg`. |
| **Xtream Codes** | `xtream` | Live + optional VOD movies/series (`vodEnabled`). Catchup / timeshift when the panel supports it. Auto EPG discovery when available. |
| **Stalker / Ministra** | `stalker` | MAG-style portal: live (+ portal VOD-style lists when exposed). |
| **Custom JSON** | `custom` | Your catalog (v1 dump or v2 query). Live / VOD / torrents / VAST per catalog. Optional Bearer token, Guide XMLTV. Spec: [catalog-api.md](catalog-api.md). |
| **Jellyfin** | `jellyfin` | Server library (movies, series, live when configured). |
| **Emby** | `emby` | Same pattern as Jellyfin. |
| **Plex** | `plex` | Account sign-in **or** URL + token. LAN / remote / relay URLs travel with the source on sync. |
| **XMLTV** | `xmltv` | EPG-only. Attach to a live or media-server source that can take a guide. |

Local files, pasted URLs, and magnets are **Library** actions, not separate
source rows (playback origin may still be `file` / `url` / `torrent` /
`download`).

## Adding a source

1. Open **Sources** → add, or use a one-click link.
2. Fill server / URL / credentials. Passwords stay in secure storage on device.
3. Sync pulls live / VOD / EPG into SQLite on native builds (web keeps in-memory lists).
4. Catalogs and channel indexes are **not** profile-synced as blobs — other
   devices re-fetch after restore. See [sync.md](sync.md).

### Deep links

| Form | Example |
| --- | --- |
| App Link | `https://javp.app/add?type=xtream&url=…&username=…&password=…&name=…` |
| Custom scheme | `javp://add?type=m3u\|custom\|xtream\|stalker\|…` |

Confirm UI shows server and username — not the password. Prefer HTTPS when
the portal supports it. Full query params: [catalog-api.md](catalog-api.md)
(deep-link section).

Verified Android App Links use
`https://javp.app/.well-known/assetlinks.json` (every signing cert that ships
to devices, including Play App Signing). Details: [play-store.md](play-store.md).

## EPG

- M3U: optional EPG URL on the source, or a separate **XMLTV** source attached later.
- Xtream: discovery / panel EPG when available.
- Media servers: provider guide and/or attached XMLTV.
- Native storage: `EpgProgramDb`. Reminders live with the profile; full EPG is rebuilt after sync.

## Parental controls

**Settings → Parental**: device PIN (not synced), hide source-adult rows, hide
whole sources, hide Live groups. Unlock is required for source management when
locked.

## Proxy

**Settings → Network**: optional HTTP(S) / SOCKS5. Toggle which traffic uses it
(IPTV, catalogs, metadata, media servers, torrents, downloads) with direct
fallback when the proxy fails.

## Pairing (LAN)

On TV / desktop: **Sources → Pair device** (or Profiles) shows a QR
(`https://javp.app/pair` / `javp://pair`). A phone on the same Wi‑Fi with JAVP
can push or pull selected sources (and optionally sync settings / add a profile
on the other device). Browser form can add one source without the app.

Not available on web. See [sync.md](sync.md) for profile + sync pairing options.

## Related

- [Catalog API](catalog-api.md) · [Features](features.md) · [Playback](playback.md)
