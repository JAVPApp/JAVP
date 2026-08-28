# Features & navigation

Map of what the app shows and which routes back it. Capabilities that differ by
platform live in `lib/platform/app_capabilities.dart`.

## Shell tabs

| Tab | Route | Role |
| --- | --- | --- |
| **Home** | `/home` | Continue watching, For you, My List teasers, favorites, discovery |
| **TV** | `/tv` | Live channels, EPG, catchup entry |
| **Catalog** | `/catalog` | Movies & series shelves / browse |
| **Music** | `/music` | Optional — enable in **Settings → Appearance** |
| **Library** | `/library` | Local files, URLs, magnets, downloads |
| **Settings** | `/settings` | Hub → sub-pages below |

Phone uses a bottom bar; tablets / desktop / TV use a navigation rail when the
layout mode says so (**Appearance → Layout**: Auto / Desktop / TV).

## Other screens

| Route | Purpose |
| --- | --- |
| `/welcome` | First-run / restore from sync |
| `/sources` | Add, edit, sync, remove sources |
| `/search` | Global search |
| `/history` | Watch history |
| `/mylist` | My List + tracker shelves |
| `/sports` | Sports schedule / follows |
| `/series`, `/title` | Title / series detail |
| `/player` | VOD / file / torrent playback |
| `/tv/watch` | Fullscreen live zapper |
| `/cast` | Cast remote |
| `/captions` | Caption style editor |
| `/downloads`, `/downloaded-series` | Offline downloads (Android) |
| `/genres`, `/collections`, `/playlists` | Browse helpers |
| `/add`, `/pair` | Deep-link entry → sources / home |

## Settings

| Page | Contents |
| --- | --- |
| **General** | UI language, content languages, updates (sideload), about, desktop close-to-tray, Discord RPC |
| **Appearance** | Cover orientation, Music tab, layout mode |
| **Parental** | PIN, hide adult rows / sources / Live groups |
| **Profiles** | Multi-profile, lock PIN, sync backend, export/import, find profiles |
| **Integrations** | Metadata provider (off / SIMKL / Trakt / TMDB), tracker accounts, TMDB key, Discord |
| **Playback** | Skip segments, downloads prefs, stream quality, audio/subs, gestures, decoder, cast |
| **Network** | HTTP(S) / SOCKS5 proxy + per-route toggles |
| **Sports** | League / team follows |
| **Diagnostics** | On-device logs (no upload), share / clear |

## Platform capabilities (summary)

| Feature | Android | Desktop | Web / Smart TV |
| --- | --- | --- | --- |
| media_kit playback | Yes | Yes | No (`video_player`) |
| Torrents | Yes | Yes | No |
| Offline downloads | Yes | No | No |
| PiP | System PiP | Mini-window path | No |
| Chromecast | Phone / Android TV | — | No |
| DLNA / AirPlay | Yes | Yes | No |
| Google Drive sync | Sign-In | Loopback PKCE | GIS |
| Self-update | Sideload flavors only | Sideload builds | No |
| LAN pairing / phone remote | Yes | Yes | No |
| Live multi-view | Code present, **gated off** | Same | No |

Exact gates: `AppCapabilities` in code. Distribution (`sideload` / `play` /
`msstore`) is separate from update channel (`stable` / `dev`) — see
[develop.md](develop.md) and [updates.md](updates.md).

## Related

- [Sources](sources.md) · [Playback](playback.md) · [Profiles & sync](sync.md)
- [Architecture](architecture.md) · [Roadmap](roadmap.md)
