# JAVP Custom Catalog API

Bring-your-own catalogs: host a JSON endpoint, point JAVP at the URL under
**Sources → JSON** (`IptvSourceType.custom`).

JAVP does **not** scrape third-party sites. Your bridge maps *your* library
(Plex, Jellyfin, files, magnets you own, etc.) into this schema.

User-facing source overview: [sources.md](sources.md). App feature map:
[features.md](features.md).

## Contents

- [Modes](#modes)
- [Conventions](#conventions)
- [v1 — Bulk catalog](#v1--bulk-catalog)
  - [Catalog root](#catalog-root)
  - [Item fields](#item-fields)
  - [Play variants](#play-variants)
  - [Seasons and episodes](#seasons-and-episodes)
  - [External subtitles](#external-subtitles)
  - [External audio](#external-audio)
  - [HTTP headers](#http-headers)
  - [Skip segments](#skip-segments)
  - [Cast](#cast)
- [v2 — Query API](#v2--query-api)
- [One-click add](#one-click-add-httpsjavpappadd--javp)

## Conventions

| Topic | Rule |
| --- | --- |
| JSON types | Objects and arrays unless a field table says a string is also accepted |
| Language codes | Prefer ISO 639-1 (`ja`, `en`, `fr`). `jpn` / `eng` / `fra` are accepted. Arrays or CSV: `["ja","en"]` or `"ja,en"` |
| Aliases | Listed in each field table. First name is canonical |
| Times | `*Ms` is milliseconds. Segment `start` / `end` (no `Ms`) are **seconds** |
| Empty vs omit | Omit unused fields. `""` / `[]` / `null` are treated as missing except `vastUrl: false` / `""` (disable ads) |
| IDs | Stable strings. Re-sync updates the same `id` instead of duplicating |

---

## Modes

| Mode | When to use | How JAVP uses it |
| --- | --- | --- |
| **v1 — Bulk dump** | Small/medium libraries (rough guide: under ~5–10k titles) | One GET → import all `items` into on-device catalog |
| **v2 — Query API** | Large libraries | Search / browse / page remotely; only cache what the user opens |

**v1 and v2 are both implemented.** Prefer v2 when the full dump would be huge.

App-side search (Home / Search) filters locally synced items and, for v2 sources, also calls `/search`.

### Optional access token

Premium / private catalogs may require auth. In **Sources → JSON**, open the **Access token**
expandable and paste a token. JAVP sends it on every catalog HTTP request:

```http
Authorization: Bearer <token>
```

If the pasted value already starts with `Bearer `, it is sent unchanged.  
`401` / `403` surface as an auth error (edit the source and update the token).  
Do **not** put tokens in `javp://add` / App Link URLs — add the catalog URL first, then paste the token in the app.

Item-level `httpHeaders` remain for **playback** only; they are separate from catalog auth.
Catalog-root `playHeaders` / `userAgent` are also playback-only (inherited by items that omit their own).

---

## v1 — Bulk catalog

### Request

```http
GET {catalogUrl}
Accept: application/json
```

### Response — object form (preferred)

```json
{
  "name": "My Home Library",
  "version": 1,
  "vastUrl": "https://ads.example.com/vast.xml",
  "min_version": "0.4.3",
  "userAgent": "MyBridge/1.0",
  "playHeaders": {
    "Referer": "https://cdn.example.com/"
  },
  "items": [
    {
      "id": "movie-42",
      "title": "Big Buck Bunny",
      "playUrl": "https://cdn.example.com/bbb.mp4",
      "kind": "vod",
      "thumbnailUrl": "https://cdn.example.com/bbb.jpg",
      "group": "Open Movies",
      "subtitle": "2008 · Blender Foundation",
      "durationMs": 596000,
      "audioLanguages": ["en"],
      "subtitleLanguages": ["en", "fr"],
      "subtitles": [
        {
          "url": "https://cdn.example.com/bbb.en.vtt",
          "language": "en",
          "label": "English",
          "default": true
        }
      ],
      "segments": [
        { "type": "intro", "startMs": 0, "endMs": 90000 }
      ]
    }
  ]
}
```

### Response — bare array (also accepted)

```json
[
  {
    "title": "Live News",
    "url": "https://cdn.example.com/news.m3u8",
    "kind": "live"
  }
]
```

Aliases for the items list: `items`, `entries`, or `media`.

### Catalog root

Fields on the top-level object (v1 dump or v2 descriptor). A bare array of items is also accepted (no root object).

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `name` | no | string | Display name in Sources |
| `version` | no | number | `1` = bulk dump (default). `2` = query API. A non-empty `capabilities` array also selects v2 |
| `items` | v1 yes | array | Title rows. Aliases: `entries`, `media`. v2 may omit this (descriptor only) or include a warm cache |
| `capabilities` | v2 | string[] | Advertised endpoints. Tokens: `search`, `browse`, `groups`, `epg`. `search` enables remote Search. `epg` is optional documentation when `epgUrl` is set |
| `itemCount` | no | number | Approximate library size (v2 UI) |
| `userAgent` | no | string | Default playback User-Agent for every item / episode / variant that omits its own. Aliases: `user-agent`, `ua` |
| `playHeaders` | no | object | Default playback HTTP headers (`Referer`, `Origin`, …). Aliases: `httpHeaders`, `headers`, `playHttpHeaders`. Not catalog-fetch auth |
| `vastUrl` | no | string \| `false` | Catalog-wide VAST/VMAP tag. Aliases: `vast`, `prerollUrl`, `ads.vastUrl` |
| `epgUrl` | no | string | XMLTV guide for live rows. Aliases: `epg`, `epg_url`, `xmltvUrl`, `tvgUrl`, `url-tvg`. Relative URLs resolve against the catalog URL. Match programmes with item `epgChannelId` |
| `min_version` | no | string | Minimum JAVP version. Alias: `minVersion` |
| `platforms` | no | string \| string[] | Client allow-list. Alias: `platform` |
| `requires` | no | string \| string[] | Required client features. Aliases: `require`, `needs` |
| `sources` | no | object[] | Named backends (see below). Alias: `catalogSources` |

### Optional client gating (`min_version`, `platforms`, `requires`)

Catalogs that rely on a newer JAVP, a specific device, or a client feature
(torrents, …) may declare constraints. Omitted fields = any JAVP can use it.

```json
{
  "name": "My Library",
  "version": 1,
  "min_version": "0.4.3",
  "platforms": ["android", "windows", "linux", "macos"],
  "requires": ["torrents"],
  "items": [ ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `min_version` | no | Alias: `minVersion`. Pubspec-style string (`0.4.3`, `0.4.3+57`). Compared to the running JAVP version (`major.minor.patch`). A `0.4.3-dev` install satisfies `0.4.3`. |
| `platforms` | no | Alias: `platform` (string or list). Allow-list of OS / form-factor tokens. Empty / omitted = all. See tokens below. |
| `requires` | no | Aliases: `require`, `needs`. Client features that must be present. Unknown tokens are ignored. |

**Root-level** mismatch (this whole catalog is not for this install): sync fails with a message. Existing cached titles are left as-is.

**Item / variant / episode** mismatch: that row is skipped; the rest of the catalog still syncs.

Platform tokens (any match allows):

| Token | Matches |
| --- | --- |
| `android`, `windows`, `linux`, `macos`, `ios`, `tizen`, `webos`, `web` | That OS / host |
| `tv` | Android TV, Tizen, webOS |
| `desktop` | Windows / Linux / macOS pointer UI |
| `mobile` | Phone / tablet (not TV) |
| `android_tv` | Android + TV only |

Aliases: `win` → `windows`, `mac` → `macos`, `samsung` → `tizen`, `lg` → `webos`, `androidtv` / `firetv` → `android_tv`.

`requires` tokens: `torrents` (aliases `torrent`, `p2p`, `magnets`), `downloads`.

Magnet / `.torrent` `playUrl`s are also skipped automatically when the client has no torrent engine (Smart TV ports), even if `requires` is omitted.

#### Named `sources[]` (optional)

A catalog may advertise several backends and gate them independently. Items and
`playVariants` point at a source with `source` (alias `catalogSource`).

```json
{
  "name": "Mixed Library",
  "version": 1,
  "sources": [
    { "id": "http", "name": "Direct streams" },
    { "id": "p2p", "name": "Magnets", "requires": ["torrents"] }
  ],
  "items": [
    { "id": "bunny-http", "title": "Bunny", "playUrl": "https://cdn.example.com/bbb.mp4", "source": "http" },
    {
      "id": "bunny",
      "title": "Bunny",
      "playVariants": [
        { "id": "http", "label": "HTTP", "playUrl": "https://cdn.example.com/bbb.mp4", "source": "http" },
        { "id": "p2p", "label": "Torrent", "playUrl": "magnet:?xt=urn:btih:…", "source": "p2p" }
      ]
    }
  ]
}
```

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `id` | **yes** | string | Token items/variants use in `source`. Aliases: `key`, `name` (if `id` omitted) |
| `name` | no | string | Label for this backend |
| `min_version` | no | string | Same as catalog root |
| `platforms` | no | string \| string[] | Same as catalog root |
| `requires` | no | string \| string[] | Same as catalog root |

Unsupported named sources are omitted (not a catalog-wide error). The same
`min_version` / `platforms` / `requires` fields work on items and variants.

JAVP also sends client identity on every catalog HTTP request so v2 bridges can
filter server-side:

```http
X-JAVP-Version: 0.4.3+57
X-JAVP-Platform: android
X-JAVP-Device: tv
X-JAVP-Capabilities: torrents,downloads
```

Query aliases (prefixed so they do not collide with bridge `version`):
`javp_version`, `javp_platform`, `javp_device`, `javp_capabilities`
(comma-separated, same tokens as the header), plus the existing `locale`.

Desktop (Windows / Linux / macOS) advertises `torrents` when the engine is
built in. Gate magnets with `requires: ["torrents"]` — do **not** also set
`platforms: ["android"]` or desktop clients will look like they cannot play
magnets (`javp_platform` is `windows` / `linux` / `macos`).

### Item fields

| Field | Required | Notes |
| --- | --- | --- |
| `title` | **yes** | Display name |
| `playUrl` | **yes*** | Stream URL, local path, or `magnet:?…`. *Not required for `kind: "series"` shells or rows that only have `playVariants` |
| `url` / `streamUrl` | * | Aliases for `playUrl` |
| `id` | no | Stable id (recommended). Auto-generated if omitted — breaks clean re-sync |
| `kind` | no | `vod` (default), `live`, `series`, `network`, `local`, `catchup` |
| `thumbnailUrl` | no | Poster / logo. Aliases: `poster`, `logo`, `still`, `stillUrl`, `image`, `imageUrl` |
| `group` | no | Category / shelf. Alias: `category` |
| `subtitle` | no | Secondary **display** line (year, genre…) — not a caption track |
| `durationMs` | no | Duration in milliseconds |
| `channelId` / `streamId` / `epgChannelId` | no | IPTV-style ids |
| `catchupDays` | no | Archive window for live/catchup |
| `tmdbId` | no | TMDB movie/TV id (number or numeric string). **Put this on `/search`, `/browse`, and `/items/{id}` shells** — JAVP uses it for episode stills, skip-intro, and enrichment without guessing the title. Catalogs that only have `anilistId` or `mal:` tags should set `tmdbId` themselves. Aliases: `tmdb_id`, `tmdb`. Optional `tags: ["tmdb:304820"]` |
| `anilistId` | no | Anime-list media id (int). Also accepted on search/browse, not only `/items/{id}`. Catalog ids `anilist-123` are parsed. Aliases: `anilist_id`, `anilist`. Not used to look up TMDB |
| `imdbId` | no | IMDb id (`tt…`) for IntroDB / TheIntroDB |
| `tvdbId` | no | TheTVDB id |
| `torrentFile` / `fileHint` | no | Preferred file name (or substring) inside a multi-file magnet |
| `poster` / `posterUrl` | no | Portrait poster (preferred for VOD shelves) |
| `backdrop` / `backdropUrl` | no | Backdrop / hero art |
| `plot` / `description` | no | Synopsis for the detail screen |
| `genres` | no | Array of strings, or comma-separated string |
| `rating` | no | Numeric **quality** rating (e.g. 7.8). Not used as a popularity score |
| `popularity` | no | Catalog-local heat, **higher = hotter**. Any non-negative scale (seeders, 0–100, play counts, …). JAVP percentile-normalizes **per catalog** so sources do not fight. Aliases: `popular`, `pop`, `heat`. Optional `popularityRank` / `popularity_rank` / `popularRank` (**1 = hottest**) if you only have a rank — inverted to a heat. Do **not** send a generic `rank`. If both heat and rank are set, heat wins |
| `year` | no | Release year |
| `releaseDate` | no | ISO date string when known |
| `trailerUrl` | no | Direct trailer URL (or YouTube watch URL) |
| `trailerKey` / `youtubeTrailer` | no | YouTube video id |
| `cast` | no | `["Name"]` or `[{ "name", "character", "profileUrl", "order" }]` |
| `season` / `seasonNumber` | no | Episode season |
| `episode` / `episodeNumber` | no | Episode number |
| `seriesId` / `parentId` | no | Link episode rows to a series shell `id` |
| `seasons` | no | Nested season/episode tree on a series shell (see below) |
| `audioLanguages` | no | `["ja","en"]` or `"ja,en"`. Aliases: `audio`, `audioLangs` |
| `subtitleLanguages` | no | Known subtitle langs. Aliases: `subLanguages`, `subtitleLangs`, `subs` |
| `subtitles` | no | External subtitle files. Alias: `externalSubtitles` |
| `audioTracks` | no | External audio files. Aliases: `externalAudio`, `audioFiles` |
| `httpHeaders` / `headers` | no | Map of headers used when opening the stream. Aliases: `playHeaders`, `playHttpHeaders` |
| `userAgent` / `user-agent` / `ua` | no | Playback User-Agent for `playUrl` (overrides the default `JAVP` and any `User-Agent` in `httpHeaders`) |
| `drm` / `drmScheme` / `licenseUrl` | no | Marks the row as DRM-protected (Widevine / similar). JAVP cannot play these yet — it shows a clear error and offers an external player. Alias: nested `{ "scheme", "licenseUrl" }` |
| `segments` | no | Skip windows (intro / credits / …) |
| `playVariants` / `variants` | no | Distinct streams for this title (see [Play variants](#play-variants)) |
| `source` / `catalogSource` | no | Named catalog `sources[]` id — gated with that source |
| `min_version` / `platforms` / `requires` | no | Same meaning as catalog root; unmatched rows are skipped |
| `contentRating` / `certification` | no | e.g. `PG-13`, `TV-MA` |
| `adult` / `isAdult` / `is_adult` | no | When `true`/`1`, parental lock hides this row. Missing ⇒ not adult. Prefer camelCase `adult` |
| `studio` / `network` | no | Studio or network label |
| `originalTitle` | no | Original-language title |
| `tags` | no | Freeform tags (array or CSV) |
| `resolution` | no | e.g. `1080p`, `4K`. On a single HLS/DASH `playUrl` this is optional metadata — renditions stay in the player |
| `videoCodec` / `audioCodec` | no | e.g. `hevc`, `aac` |
| `hdr` | no | e.g. `HDR10`, `DV` |
| `updatedAt` | no | ISO timestamp for the row |
| `vastUrl` | no | Per-title VAST/VMAP tag (overrides catalog `vastUrl`). Empty / `false` disables ads for this row |

Rows missing `title`, or missing a playable URL when not a series shell / variant parent, are skipped.

When a parental PIN is set and the session is **locked**, JAVP hides rows with `adult: true` (same path as Xtream `is_adult`). Unlocking with the PIN shows them again. Manual hidden Live groups remain separate.

### Popularity

`rating` is quality. For Catalog **Popular** sort, send a catalog-local heat on each row:

```json
{ "id": "movie-42", "title": "Big Buck Bunny", "playUrl": "…", "popularity": 1840 }
```

Any non-negative number works — torrent seeders, a 0–100 score, watch counts. JAVP does **not** treat this as a global 0–100. Each catalog is percentile-normalized on device so a seeder column cannot swamp another source’s 0–100. TMDB trending/popular still ranks first when a `tmdbId` matches; catalog heat is the fallback before `rating` / year.

If you only have a 1-based chart position, send `popularityRank` (1 = hottest) instead. Generic `rank` is ignored.

JAVP currently sorts Popular **on device** after fetch. A future v2 `/browse?sort=popular` is optional; including `popularity` on `/browse` and v1 dump items is enough.

### Series (contract)

The series episode picker reads **only**:

1. Nested `seasons[].episodes[]` on the series shell (preferred), or  
2. Flat catalog rows with `seriesId` (+ `seasonNumber` / `episodeNumber`)

| Rule | Detail |
| --- | --- |
| Shell `playUrl` | **Optional.** Not required. Never treated as “the only playable thing.” |
| Empty `seasons` | Empty episode UI (even if the shell has a magnet / `playVariants`) |
| Episode `playUrl` | Optional on stubs; fill later via `/items/{episodeId}` or include on `/items/{id}` |
| Episode art | Optional `thumbnailUrl` (aliases: `poster`, `still`, `stillUrl`, `image`, `imageUrl`, `logo`). Use a **per-episode still**, or omit it. Do **not** copy the series poster onto every episode (different size variants of the same cover file still count as the same image). Reused series art is treated as missing. With a BYO TMDB key **and a catalog `tmdbId`**, JAVP fills missing/generic thumbs and “Episode N” titles from TMDB |
| Shell `playVariants` | Optional **show-level** editions only — **not** the episode list |

**Option A — nested seasons on a shell** (preferred for BYO / anime bridges):

```json
{
  "id": "show-42",
  "title": "Example Show",
  "kind": "series",
  "anilistId": 1001,
  "tmdbId": 1001,
  "posterUrl": "https://cdn.example.com/show.jpg",
  "plot": "…",
  "seasons": [
    {
      "seasonNumber": 1,
      "name": "Season 1",
      "episodes": [
        {
          "id": "show-42-s1e1",
          "episodeNumber": 1,
          "title": "Episode 1",
          "thumbnailUrl": "https://cdn.example.com/s1e1-still.jpg",
          "playUrl": "magnet:?xt=urn:btih:…"
        }
      ]
    }
  ]
}
```

**Option B — flat episode rows** linked with `seriesId`:

```json
[
  { "id": "show-1", "title": "Example Show", "kind": "series", "posterUrl": "…" },
  {
    "id": "show-1-s1e1",
    "title": "Pilot",
    "playUrl": "https://cdn.example.com/s1e1.mp4",
    "seriesId": "show-1",
    "seasonNumber": 1,
    "episodeNumber": 1
  }
]
```

### Seasons and episodes

#### Season object (`seasons[]`)

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `seasonNumber` | no | number | Season index. Alias: `season`. Default `0` if omitted |
| `name` | no | string | Display name. Default `Season {n}` |
| `posterUrl` | no | string | Season poster. Alias: `poster` |
| `episodes` | no | object[] | Episode list. Alias: `items` |

#### Episode object (`episodes[]` or flat catalog row)

Nested episodes and `/items/{id}/episodes` rows. Flat v1 rows also use item fields (`seriesId`, `kind`, …).

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `id` | no | string | Stable episode id. Default `{seriesId}-s{season}e{episode}` |
| `episodeNumber` | no | number | Episode index. Alias: `episode` |
| `seasonNumber` | no | number | Overrides the parent season. Alias: `season` |
| `title` | no | string | Episode title. Default `Episode {n}` |
| `plot` | no | string | Synopsis. Alias: `description` |
| `thumbnailUrl` | no | string | Per-episode still. Aliases: `poster`, `posterUrl`, `still`, `stillUrl`, `image`, `imageUrl`, `logo`. Do **not** copy the series poster |
| `durationMs` | no | number | Duration in milliseconds |
| `playUrl` | no | string | Stream / magnet. Alias: `url`. Omit on stubs (v2 progressive resolve) |
| `playVariants` | no | object[] \| string[] | Distinct encodes for this episode (see [Play variants](#play-variants)). Alias: `variants` |
| `torrentFile` | no | string | File inside a batch magnet. Alias: `fileHint` |
| `resolution` | no | string | Metadata when there is a single `playUrl` |
| `httpHeaders` | no | object | Playback headers (overlay catalog / series defaults) |
| `userAgent` | no | string | Playback User-Agent for this episode |
| `tmdbId` | no | number | Episode TMDB id when known |
| `source` | no | string | Named `sources[]` id |
| `min_version` / `platforms` / `requires` | no | same as root | Unmatched episodes are skipped |

#### Batch / multi-file magnets

It is valid to set the **same** batch magnet as `playUrl` on every episode (for example a season pack covering `01–28`). JAVP’s torrent engine selects a file by:

1. Optional `torrentFile` / `fileHint` on the episode, else  
2. Matching `episodeNumber` (and `seasonNumber` when present) against file names (`S01E02`, ` - 02 (`, `E02`, …), else  
3. Largest streamable file (legacy fallback)

### Play variants

`playVariants` (alias `variants`) lists **distinct streams** for one title or episode: separate files, language-specific URLs, different DRM, or different files inside a magnet. Each unique `playUrl` (+ `torrentFile` when set) becomes a sibling encode (player **Version**).

**Do not** list HLS / DASH renditions as variants. One master playlist is enough — the player reads the ladder and offers Auto / 1080p / 4K there:

```json
"playUrl": "https://cdn.example.com/movie.m3u8"
```

Tagging `resolution` on that single URL is optional metadata, not a Versions chip. The same `playUrl` listed twice (once as 1080p and once as 4K) is collapsed to one encode.

Each entry may be a URL string (`"https://…/a.mp4"`) or an object:

```json
"playVariants": [
  {
    "id": "ja-1080",
    "label": "Japanese 1080p",
    "playUrl": "https://cdn.example.com/ja-1080.mp4",
    "resolution": "1080p",
    "audioLanguages": ["ja"],
    "subtitleLanguages": ["en", "fr"],
    "httpHeaders": { "Referer": "https://cdn.example.com/" }
  },
  {
    "id": "fr-4k",
    "label": "French 4K",
    "playUrl": "https://cdn.example.com/fr-2160.mp4",
    "resolution": "4K",
    "hdr": "HDR10",
    "audioLanguages": ["fr"]
  }
]
```

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `playUrl` | **yes** | string | Stream URL, path, or `magnet:?…`. Aliases: `url` |
| `id` | no | string | Stable id for this encode. Default `{parentId}-v{index}` |
| `label` | no | string | Version chip text. Aliases: `title`, `name`. Falls back to `resolution`, then `"Version"` |
| `subtitle` | no | string | Extra display line (not a caption track). Shown next to `label` |
| `resolution` | no | string | e.g. `1080p`, `4K`. Metadata for the Version row |
| `videoCodec` | no | string | e.g. `hevc`, `av1` |
| `audioCodec` | no | string | e.g. `aac`, `eac3` |
| `hdr` | no | string | e.g. `HDR10`, `DV` |
| `torrentFile` | no | string | File name / substring inside a multi-file magnet. Alias: `fileHint` |
| `audioLanguages` | no | string[] \| CSV | Spoken languages **in this stream**. Aliases: `audio`, `audioLangs`. Shown on the title page and used to pick a default encode. Omit to inherit the parent item |
| `subtitleLanguages` | no | string[] \| CSV | Caption languages **in this stream**. Aliases: `subLanguages`, `subtitleLangs`, `subs`. Same inherit rule |
| `subtitles` | no | object[] | External caption files for this encode only. Alias: `externalSubtitles`. Inherit parent if omitted |
| `audioTracks` | no | object[] | External audio files for this encode only. Aliases: `externalAudio`, `audioFiles` |
| `httpHeaders` | no | object | Playback headers for this URL (overlay parent / catalog defaults). Aliases: `headers`, `playHeaders`, `playHttpHeaders` |
| `userAgent` | no | string | Playback User-Agent for this URL. Aliases: `user-agent`, `ua` |
| `source` | no | string | Named catalog `sources[]` id. Alias: `catalogSource` |
| `drm` / `drmScheme` / `licenseUrl` | no | string \| object | Marks this encode DRM-protected (unplayable in JAVP) |
| `min_version` / `platforms` / `requires` | no | same as root | Unmatched variants are skipped |

| Where | Behaviour |
| --- | --- |
| VOD / movie row | Unique `playUrl`s expand to sibling catalog rows → title **Versions**. Same URL stays one encode (languages unioned) |
| Series **shell** | Ignored for the episode picker |
| Nested **episode** / flat episode row | Distinct streams in the episode Version list; same URL collapsed |

### External subtitles

```json
"subtitles": [
  {
    "url": "https://cdn.example.com/en.vtt",
    "language": "en",
    "label": "English",
    "default": true,
    "format": "vtt"
  },
  {
    "url": "https://cdn.example.com/en.forced.srt",
    "language": "en",
    "forced": true
  },
  {
    "url": "https://cdn.example.com/en.sdh.vtt",
    "language": "en",
    "sdh": true
  }
]
```

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `url` | **yes** | string | Caption file URL. Aliases: `uri`, `src`. A bare string in the array is treated as `url` |
| `language` | no | string | ISO language code (`en`, `ja`, `fr`). Alias: `lang` |
| `label` | no | string | Player row text. Aliases: `title`, `name` |
| `default` | no | boolean | Prefer this track on play. Alias: `isDefault` |
| `forced` | no | boolean | Forced / signs-only track. Alias: `isForced` |
| `hearingImpaired` | no | boolean | SDH / CC. Aliases: `sdh`, `cc` |
| `format` | no | string | Hint: `srt`, `vtt`, `ass`. Alias: `type` |

### External audio

Sidecar audio (`.mka`, extra HLS audio, …) offered in the player audio-track menu. A bare URL string in the array is treated as `{ "url": "…" }`.

```json
"audioTracks": [
  { "url": "https://cdn.example.com/ja.mka", "language": "ja", "label": "Japanese", "default": true },
  { "url": "https://cdn.example.com/en.mka", "language": "en", "label": "English" }
]
```

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `url` | **yes** | string | Audio file URL. Aliases: `uri`, `src` |
| `language` | no | string | ISO language code. Alias: `lang` |
| `label` | no | string | Player row text. Aliases: `title`, `name` |
| `default` | no | boolean | Prefer this track on play. Alias: `isDefault` |

These are extra files attached to a stream. They are **not** a substitute for `playVariants` when each language is a different video URL — use variants + `audioLanguages` for that.

### HTTP headers

Sent with the player (and downloads) when opening `playUrl`. Catalog-fetch auth (`Authorization: Bearer` from Sources → Access token) is separate and is **not** applied to streams.

**Catalog root** (optional defaults for every item / episode / variant):

```json
{
  "name": "My Library",
  "userAgent": "MyBridge/1.0",
  "playHeaders": {
    "Referer": "https://cdn.example.com/",
    "Origin": "https://cdn.example.com"
  },
  "items": [ ]
}
```

Aliases at root: `httpHeaders`, `headers`, `playHttpHeaders`. `userAgent` aliases: `user-agent`, `ua`.

**Item / variant / episode** (overlay the catalog defaults; later wins):

```json
"userAgent": "MyBridge/1.0",
"httpHeaders": {
  "Referer": "https://cdn.example.com/",
  "Authorization": "Bearer stream-token"
}
```

`User-Agent` may also be set inside `httpHeaders`. A dedicated `userAgent` field wins. Nested `seasons[].episodes[]` and `playVariants[]` accept the same fields.

Passed to the player when opening `playUrl`. On libmpv backends the `user-agent` property follows this value (instead of always sending `JAVP`).

### Skip segments

Skip-intro / skip-credits windows for the player.

```json
"segments": [
  { "type": "intro", "startMs": 90000, "endMs": 150000 },
  { "type": "credits", "startMs": 5400000 }
]
```

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `type` | **yes** | string | `intro` / `opening`, `recap`, `credits` / `outro` / `endcredits`, `preview` |
| `startMs` | **yes*** | number | Start in milliseconds. `*start` (seconds) is used when `startMs` is omitted |
| `endMs` | no | number | End in milliseconds. Omit = from start to end of media (typical for credits). `end` (seconds) when `endMs` omitted |
| `source` | no | string | Provenance label (default `catalog`) |
| `confidence` | no | number | Optional 0–1 hint |

### Cast

On a title (or v2 `/items/{id}`). Strings or objects:

```json
"cast": [
  "Jane Doe",
  { "name": "John Smith", "character": "The Pilot", "profileUrl": "https://cdn.example.com/js.jpg", "order": 1 }
]
```

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `name` | **yes** | string | Person name. A bare string in the array is this field |
| `character` | no | string | Role. Alias: `role` |
| `profileUrl` | no | string | Headshot. Alias: `image` |
| `order` | no | number | Sort index (default = array index) |

### Playback URLs

- **HTTP(S) progressive / HLS / DASH** — played directly by media_kit  
- **`magnet:?…`** — resolved via BYO torrent engine to a localhost HTTP stream  
- **File paths** — treated like local media when applicable  

---

## v2 — Query API

Point Sources → JSON at the **catalog root** (descriptor). JAVP detects `version: 2` or a non-empty `capabilities` array and does **not** expect a full item dump.

### `GET /catalog` — describe the catalog

Your source URL may be this document, or any URL that returns:

```json
{
  "name": "Huge Library",
  "version": 2,
  "min_version": "0.4.3",
  "platforms": ["android", "windows", "linux", "macos"],
  "capabilities": ["search", "browse", "groups"],
  "itemCount": 128400,
  "userAgent": "MyBridge/1.0",
  "playHeaders": { "Referer": "https://cdn.example.com/" }
}
```

Optional **VAST 4.x** tag (VAST 2/3/4.2 and VMAP):

```json
{
  "name": "Huge Library",
  "version": 2,
  "vastUrl": "https://ads.example.com/vast.xml",
  "capabilities": ["search", "browse", "groups"]
}
```

Aliases: `vast`, `prerollUrl`, or `ads.vastUrl`. The player fetches the tag for VOD (not live / catch-up / offline). It plays linear prerolls, VMAP mid-rolls (`timeOffset` as a clock or percent), and post-rolls (`timeOffset="end"`). Wrappers are followed (max 5). Per-item `vastUrl` overrides the catalog tag; `vastUrl: false` or `""` disables ads for that row.

Optional **XMLTV** guide for live channels:

```json
{
  "name": "Live TV",
  "version": 2,
  "capabilities": ["browse", "epg"],
  "epgUrl": "https://cdn.example.com/guide.xml",
  "items": [
    {
      "id": "news-1",
      "title": "News",
      "kind": "live",
      "playUrl": "https://cdn.example.com/news.m3u8",
      "epgChannelId": "news.1"
    }
  ]
}
```

JAVP downloads that URL as XMLTV and matches programmes to live rows via `epgChannelId` (same as M3U `tvg-id`). Aliases: `epg`, `xmltvUrl`, `tvgUrl`, `url-tvg`. Relative paths resolve against the catalog URL.

The player is a **linear** VAST 4.2 client: progressive/HLS `MediaFile`, skipoffset, click-through, quartile + `progress` tracking, mute/pause/expand, AdChoices `Icon` overlays, image companions, closed captions, and MRC-style viewable impressions. It does **not** execute VPAID, SIMID, or OMID verification scripts (those creatives are skipped and `verificationNotExecuted` is pinged). Failed or empty tags fail open into the title.

If the same response also includes `items`, they are imported as a warm cache.

Root `userAgent` / `playHeaders` are remembered and inherited by later `/search`, `/browse`, `/items/{id}`, and episode responses unless those rows set their own.

### `GET /search`

Remote title search. Wired from in-app **Search** for v2 sources that list `search` in `capabilities`.

```http
GET /search?q=bunny&page=1&limit=50&locale=fr
```

| Query | Required | Type | What it does |
| --- | --- | --- | --- |
| `q` | **yes** | string | Search text |
| `page` | no | number | 1-based page (default `1`) |
| `limit` | no | number | Page size (JAVP sends `50`) |
| `locale` | no | string | App or device language (`fr`, `en`, `ja`) so the bridge can prefer matching audio / titles |

JAVP also appends `javp_version`, `javp_platform`, `javp_device` when not already in the query.

```json
{
  "query": "bunny",
  "page": 1,
  "limit": 50,
  "total": 3,
  "items": [ { "id": "…", "title": "…", "playUrl": "…", "kind": "vod" } ]
}
```

| Response field | Type | What it does |
| --- | --- | --- |
| `items` | object[] | Title rows (same schema as v1 items). Aliases: `entries`, `media` |
| `query` | string | Echo of `q` (optional) |
| `page` | number | Echo (default 1) |
| `limit` | number | Echo (default = `items.length`) |
| `total` | number | Total hits if known (default = `items.length`) |
| `playHeaders` / `userAgent` | object / string | Optional page-level playback defaults |

HTTP `404` means search is unsupported; JAVP falls back to the on-device cache.

### `GET /browse`

List by shelf/category without a text query. Include `popularity` (or `popularityRank`) on items so Catalog **Popular** can rank titles that are not on TMDB trending.

```http
GET /browse?group=movies&page=1&limit=50&locale=fr
```

| Query | Required | Type | What it does |
| --- | --- | --- | --- |
| `group` | no | string | Shelf / category id from `/groups` (omit = mixed / home page) |
| `page` | no | number | 1-based page (default `1`) |
| `limit` | no | number | Page size (JAVP sends `50`) |
| `locale` | no | string | Same as `/search` |

Response shape is the same as `/search` (`items`, `page`, `limit`, `total`).

### Optional query: `locale`

JAVP always sends the **app language** when the user picked one in Settings, otherwise the **device language** (BCP-47 language code, e.g. `fr`, `en`, `ja`) as `locale` on `/search`, `/browse`, `/items/{id}`, and `/items/{id}/episodes`.

Bridges may ignore it, or use it to prefer matching audio / release groups / localized titles. Especially useful on progressive episode resolve:

```http
GET /items/{episodeId}?locale=fr
```

### `GET /items/{id}`

Fetch one title (cast, trailer, nested seasons when available).

```http
GET /items/{id}?locale=fr
```

| Query | Required | Type | What it does |
| --- | --- | --- | --- |
| `locale` | no | string | Prefer matching audio / release group when filling `playUrl` |

Response: a title object (same fields as a v1 item), or `{ "item": { … } }`.

Series shells may return:
- Full `seasons[].episodes[]` with `playUrl`s, or  
- Season stubs / episode stubs **without** `playUrl` (progressive detail)

### Optional: `GET /items/{id}/episodes`

Lazy episode list for a series (avoids resolving every magnet on first open).

```http
GET /items/show-42/episodes?season=1&locale=fr
```

| Query | Required | Type | What it does |
| --- | --- | --- | --- |
| `season` | no | number | Season to list (default = first) |
| `locale` | no | string | Prefer matching audio/subs |
| `resolve` | no | `1` / `true` / `yes` | Fill `playUrl` / `playVariants` in this response (see bulk fill) |
| `limit` | no | number | Max episodes when resolving (JAVP default 24, hard cap 24) |
| `offset` | no | number | Skip this many episodes before the fill window |

```json
{
  "season": 1,
  "episodes": [
    {
      "id": "show-42-s1e1",
      "episodeNumber": 1,
      "title": "Episode 1"
    }
  ]
}
```

| Response field | Type | What it does |
| --- | --- | --- |
| `season` / `seasonNumber` | number | Season these episodes belong to |
| `episodes` | object[] | Episode objects (see [Episode object](#episode-object-episodes-or-flat-catalog-row)). Aliases: `items`, `entries` |
| `seasons` | object[] | Alternate shape: full season tree instead of a flat episode list |
| `resolved` | boolean | Optional; `true` after a `resolve=1` fill |
| (bare array) | object[] | Also accepted as the whole body |

When episode stubs omit `playUrl`, JAVP resolves `GET /items/{episodeId}?locale=` with a
**cold-series gate** (concurrency 1 until first success, then prefetch ≤ 2–3), and on Play /
Versions if still cold. Prefer a short delay (~1s) after this response before background
prefetch so bridges can warm search caches.

#### Bulk fill — `resolve=1` (opt-in)

One search/index pass for the cour; response episodes include `playUrl` / `playVariants`
when found. Use after stub paint (or instead of N parallel episode GETs) for short cours.

```http
GET /items/show-42/episodes?season=1&locale=fr&resolve=1&limit=12
```

```json
{
  "season": 1,
  "resolved": true,
  "episodes": [
    {
      "id": "show-42-s1e1",
      "episodeNumber": 1,
      "title": "Episode 1",
      "playUrl": "magnet:?xt=urn:btih:…",
      "playVariants": [
        {
          "id": "ja",
          "label": "Japanese",
          "playUrl": "magnet:?xt=urn:btih:…",
          "audioLanguages": ["ja"],
          "subtitleLanguages": ["en", "fr"]
        }
      ]
    }
  ]
}
```

Do **not** call `resolve=1` for huge series without a tight `limit`/`offset` window.
Empty `playUrl` on some rows is non-fatal — fall back to per-episode GET.

### Optional: `GET /groups`

```http
GET /groups
```

```json
{
  "groups": [
    { "id": "movies", "name": "Movies", "count": 4200 },
    { "id": "kids", "name": "Kids", "count": 310 }
  ]
}
```

A bare array of group objects is also accepted.

| Field | Required | Type | What it does |
| --- | --- | --- | --- |
| `id` | **yes*** | string | Value sent as `/browse?group=`. Falls back to `name` |
| `name` | **yes*** | string | Shelf label. Falls back to `id` |
| `count` | no | number | Optional title count for the UI |

At least one of `id` / `name` must be non-empty.

### Client behaviour

1. Add source → detect `version: 2` (or `capabilities`)  
2. Do **not** require a bulk `items` dump  
3. Search → call `/search` and cache hits locally  
4. Continue-watching / detail use cached rows + `/items/{id}` when needed  
5. **Series progressive detail** — first paint from `/items/{seriesId}` or `/episodes`
   (stubs OK). Then either:
   - **Bulk (preferred for short cours):** one `GET /items/{id}/episodes?resolve=1&limit=≤24&locale=`
     and merge `playUrl`s into local cache, or  
   - **Per-episode:** cold-series gate (concurrency **1** until first success; optional ~1s
     delay after stub `/episodes`); then prefetch visible rows at concurrency **2–3** max.
     Play / Versions still resolve on demand if cold.  
6. **Simulcast / new episodes** — shell episode lists are soft-revalidated on open  
   after ~30 minutes (and on pull-to-refresh). New episode ids merge in; already  
   resolved magnets are kept when the bridge still returns stubs for those ids  

URL joining: if the source URL ends with `/catalog` or a `.json` file, query paths
(`/search`, `/browse`, `/groups`, `/items/{id}`) are resolved from the **parent**
directory — e.g. `https://host/anime/catalog` → `https://host/anime/search`.

---

## XML (optional later)

Same fields as JSON item objects. Not implemented yet — JSON is the supported format.

---

## Tips for bridge authors

1. Prefer **stable `id`s** so re-sync updates instead of duplicating.  
2. Keep v1 payloads under a few MB when possible; otherwise use v2.  
3. Use HTTPS. Cleartext HTTP works on Android for IPTV-style setups but is discouraged.  
4. For series, emit nested `seasons` (or flat `seriesId` rows). Shell magnets alone do not populate the episode UI.  
5. Magnets in `playUrl` are fine for **legal BYO** torrents only. Shared batch magnets across episodes are supported (file-by-episode selection).  
6. Put cast / trailer / seasons in the item (or v2 `/items/{id}`) so detail works without TMDB.  
7. Prefer `anilistId` **and** `tmdbId` on anime shells (search/browse/item). Map other anime ids to `tmdbId` in the catalog. `tags: ["mal:…"]` is optional and is **not** used by JAVP to look up TMDB.  
8. Do not set episode `thumbnailUrl` to the series cover. Leave it empty so TMDB stills can fill in, or ship real stills.  
9. Large series: prefer `/items/{id}/episodes?season=` or stub-then-fill episode ids.
10. Set `min_version` / `platforms` / `requires` when the catalog (or an individual source / row) needs a newer JAVP, a specific device, or torrents (optional; unmatched catalogs refuse to sync, unmatched rows are skipped).

---

## One-click add (`https://javp.app/add` + `javp://`)

Websites can deep-link into JAVP so users add a catalog, M3U playlist, Xtream, or Stalker/Ministra login with one tap. The app always shows a confirm dialog before adding.

**Prefer HTTPS App Links for public “Add to JAVP” buttons:**

```text
https://javp.app/add?type=custom&url=https%3A%2F%2Fexample.com%2Fcatalog.json&name=My%20Library
```

- **App installed** (verified Android App Links): opens JAVP directly.
- **App missing**: the browser loads [`/add`](https://javp.app/add) — install from [updater.javp.app](https://updater.javp.app/), then **open the same link again**. There is no automatic add after install (Play Store listing URLs also cannot carry that without Install Referrer plumbing).

Keep `javp://add?…` for QR codes, TV pairing paste, and places that cannot use HTTPS.

To build either form without hand-encoding query strings, use the
[add link maker](https://javp.app/link-maker) on the website
(`?type=custom`, `?type=m3u`, `?type=xtream`, or `?type=stalker` opens that mode directly).

HTML example:

```html
<a href="https://javp.app/add?type=custom&url=https%3A%2F%2Fexample.com%2Fcatalog.json&name=My%20Library">
  Add to JAVP
</a>
```

### Custom JSON catalog

```text
https://javp.app/add?type=custom&url=https%3A%2F%2Fexample.com%2Fcatalog.json&name=My%20Library
javp://add?type=custom&url=https%3A%2F%2Fexample.com%2Fcatalog.json&name=My%20Library
```

| Query | Required | Notes |
| --- | --- | --- |
| `type` | yes | `custom`, or aliases `json` / `catalog` |
| `url` | yes | `http`/`https` catalog URL (also `catalog` / `playlist`) |
| `name` | no | Display name in Sources |

### M3U playlist

```text
https://javp.app/add?type=m3u&url=https%3A%2F%2Fexample.com%2Flist.m3u&name=My%20IPTV&epg=https%3A%2F%2Fexample.com%2Fepg.xml
javp://add?type=m3u&url=https%3A%2F%2Fexample.com%2Flist.m3u&name=My%20IPTV&epg=https%3A%2F%2Fexample.com%2Fepg.xml
```

| Query | Required | Notes |
| --- | --- | --- |
| `type` | yes | `m3u`, or aliases `m3u8` / `playlist` |
| `url` | yes | Playlist URL |
| `name` | no | Display name |
| `epg` | no | Optional EPG XML URL (`epgUrl` also accepted) |

### Xtream Codes

```text
https://javp.app/add?type=xtream&url=http%3A%2F%2Fexample.com%3A8080&username=user&password=pass&name=My%20IPTV&alt=http%3A%2F%2Falt.example.com
javp://add?type=xtream&url=http%3A%2F%2Fexample.com%3A8080&username=user&password=pass&name=My%20IPTV&alt=http%3A%2F%2Falt.example.com
```

| Query | Required | Notes |
| --- | --- | --- |
| `type` | yes | `xtream`, or aliases `xc` / `xtream-codes` |
| `url` | yes | Server DNS (`server` / `host` / `dns` also accepted) |
| `username` | yes | Also `user` / `login` |
| `password` | yes | Also `pass` / `pwd` |
| `name` | no | Display name |
| `alt` | no | Optional Samsung/LG DNS (`alternate` / `altDns` / `dns2`) |

The confirm dialog shows server and username only — the password is never displayed. Prefer HTTPS when the portal supports it; credentials in a URL can appear in browser history and share sheets.

### Stalker / Ministra

```text
https://javp.app/add?type=stalker&url=http%3A%2F%2Fportal.example.com&mac=00%3A1A%3A79%3A12%3A34%3A56&name=My%20Portal&serial=ABC123
javp://add?type=stalker&url=http%3A%2F%2Fportal.example.com&mac=00%3A1A%3A79%3A12%3A34%3A56&name=My%20Portal&serial=ABC123
```

| Query | Required | Notes |
| --- | --- | --- |
| `type` | yes | `stalker`, or aliases `ministra` / `mag` / `portal` |
| `url` | yes | Portal URL (`portal` / `server` / `serverUrl` / `host` also accepted) |
| `mac` | yes | Device MAC (`username` / `user` also accepted) |
| `serial` | no | Optional device serial (`password` / `pass` / `sn` also accepted) |
| `name` | no | Display name |

The confirm dialog shows portal and MAC. Prefer HTTPS when the portal supports it; MAC (and serial) in a URL can appear in browser history and share sheets.

If the same type + URL (or Xtream server + username, or Stalker portal + MAC) is already added, JAVP offers a re-sync instead of duplicating.

Jellyfin / Emby / Plex are **not** supported via deep link.

### Phone deep link vs Android TV QR

| Surface | How |
| --- | --- |
| **Phone / tablet with JAVP** | Tap `https://javp.app/add?…` (or `javp://add?…` / QR) → confirm dialog → source syncs on that device |
| **Android TV / desktop host** | **Pair device** shows a `https://javp.app/pair` QR → phone with JAVP opens push/pull (LAN, token + PIN). Without the app, the landing page offers install or **Continue in browser** (LAN form for one `javp://add` / `javp-sources.json`) |

Publishers can put an “Add to JAVP” HTTPS link on the website for phones. For TV setup: open **Sources → Pair device** (or Settings → Profiles), scan with a phone that has JAVP to push sources, or use the browser form URL shown under the QR.

---

## Related in the app

| UI | Behaviour |
| --- | --- |
| Sources → **JSON** | Add catalog URL and sync (v1 dump or v2 descriptor). Optional **Access token** under an expandable for private catalogs |
| `https://javp.app/add?…` / `javp://add?…` | Confirm → add custom / M3U / Xtream / Stalker source and sync |
| TV / desktop pairing | `https://javp.app/pair` QR → app push/pull (or browser landing / LAN form) |
| Home / Search | Local filter + v2 remote `/search` |
| Title detail | Cast, trailer, audio/subs, versions, tech tags |
| Player | Headers, external audio/subs, skip segments |
| Library → magnet | Separate BYO torrent entry (not a remote catalog) |
