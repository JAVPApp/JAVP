# Notices

JAVP (Just Another Video Player) is free software licensed under the
**GNU General Public License v3.0 or later**. See the root [`LICENSE`](LICENSE)
file and https://javp.app.

Copyright (C) 2026 xemles and contributors.

## Third-party software

This project depends on packages under their own licenses (MIT, BSD,
Apache-2.0, GPL, LGPL, proprietary SDKs, and similar), including but not
limited to:

| Component | Typical license | Notes |
| --- | --- | --- |
| Flutter / Dart SDK & many `*_flutter` plugins | BSD-style | See each package `LICENSE` |
| media_kit / media_kit_video / media_kit_libs_* | MIT | Playback stack; native `libmpv` / FFmpeg builds may include LGPL/GPL components from upstream |
| rqbit_engine / librqbit | Apache-2.0 | Embedded Rust BitTorrent engine + localhost HTTP stream API |
| Google Play services Cast framework | Google proprietary SDK | Used only on Android for Chromecast; subject to Google Cast SDK terms |
| Other pub dependencies (`provider`, `http`, `sqflite`, …) | MIT / BSD / Apache-2.0 | See `pubspec.lock` + each package license |

Those third-party licenses continue to apply to those components. Binary
releases should ship with this `NOTICE` (or equivalent) so recipients can
identify bundled open-source parts.

## Third-party services & trademarks (not software licenses)

These are **not** shipped in the app. Users optionally connect their own
accounts / keys. JAVP is not affiliated with or endorsed by these parties.

### TMDB

Optional metadata enrichment uses [The Movie Database (TMDB) API](https://www.themoviedb.org/).

- Users must supply **their own** API key.
- Use must comply with the [TMDB API Terms of Use](https://www.themoviedb.org/documentation/api/terms-of-use), including **attribution**, cache limits, and **non-commercial** use unless you have a separate commercial agreement with TMDB.
- In-app notice (Settings → Integrations → TMDB):

  > This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.

### SIMKL

Optional scrobbling uses the SIMKL API with a **user-supplied** client id and token. Comply with SIMKL’s developer / API terms for your own key.

### Media servers (Jellyfin / Emby / Plex)

Clients talk to **servers the user configures** (URL + credentials, or
Plex account sign-in). You must have the right to access that server and
its libraries. Plex / Jellyfin / Emby names and logos are trademarks of
their respective owners.

### IPTV / catalogs / torrents

JAVP does **not** ship playlists, credentials, or torrent indexes. Users add
their own M3U / Xtream / Stalker / JSON catalog / magnet sources. Using the
app with content you do not have rights to is your responsibility and may
violate law or third-party terms.

### Google Cast

Optional Chromecast support uses Google’s Cast SDK on Android. Subject to
Google Cast SDK terms.
