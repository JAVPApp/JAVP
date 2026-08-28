# Roadmap

Product direction for JAVP. Ordered by priority; no fake dates — ship when solid.

## Principles

- BYO media; credentials stay on the device by default.
- **Non-cloud first** — every core feature must work with zero account.
- Optional **premium cloud** later (sync only), never required for playback or library.
- Borrow good UX from peer players; do not copy paid-cloud gatekeeping of basics
  (favorites, resume, profiles).

## Done / solid

- Live TV, VOD, and EPG on **SQLite** (native); web keeps in-memory lists.
- Live quality variants, remembered preferred stream, first-tune prompt, list badges.
- Catalog Versions, multi-source filters, Xtream category-first live, EPG gzip / conditional GET.
- Trackers: SIMKL, Trakt, Letterboxd (export), Serializd, BetaSeries.
- Multi-profile + folder / WebDAV / Google Drive sync; LAN device pairing.
- Player: PiP / mini window, gestures, torrents, Android downloads, cast, sleep timer,
  open in external player, Android TV leanback polish.
- Desktop layout mode (Auto / Desktop / TV) + Steam Deck Game Mode entry.
- TMDB Popular/Trending ∩ local catalog discovery shelves.
- Public GPL-3.0-or-later release (`0.6.0`).

Leftover catalog work is retiring remaining RAM **indexes** (group / hay) that
still scan maps — not warming SQLite back into `_vodStreamCache`.

## Near

- Harden folder / WebDAV / Drive sync and pairing (folder path still local).
- Decoder fallback / clearer errors → offer external player.
- EPG preload affordance; live display-mode gesture if it still helps.
- Soft “try TV layout?” suggestion when heuristics are unsure (Settings always wins).

## Mid

- **Incremental extraction** — peel domains out of façades; map:
  [architecture.md](architecture.md).
- **Live multi-view** — in-tree but `AppCapabilities.multiView == false` until
  the second decoder and TV chrome are solid. Re-enable with `usesMediaKit`.
- Retire remaining full-map VOD indexes once DB covers browse/search. Do **not**
  copy SQLite pages into `_vodStreamCache`. Keep source-shaped fetch adapters
  (do not fold M3U / custom / Xtream / Stalker / media-server into one parser).
- **HLS live recording** — concatenate `.ts` when the source has no catchup.

## Peer ideas — triage

| Idea | Verdict |
| --- | --- |
| Live SD/HD/4K grouping + remembered pick | **Done** |
| Open in external player | **Done** (no progress tracking) |
| Sleep timer | **Done** |
| QR LAN pairing | **Done** |
| VOD SQLite + FTS | **Done** |
| TMDB Popular/Trending ∩ local | **Done** |
| Auto decoder fallback | Mid |
| EPG preload / pinch live layout | Mid |
| Multi-screen concurrent-stream alerts | **Skip** (cloud/IAP model) |
| Sports score overlays | **Skip** |
| Paywall gating favorites / resume / profiles | **Skip** |
| Native Rust playlist loader | **Last resort** — only if huge M3U/XMLTV still slow after SQLite ingest |

## Distribution

Sideload ([updater.javp.app](https://updater.javp.app/)) stays the default.
Store channels **disable in-app updates** when the store owns them.

| Channel | Status | Notes |
| --- | --- | --- |
| **WinGet** | Scaffolding | [`deploy/winget/README.md`](../deploy/winget/README.md) |
| **Play Store** | Live / docs | [play-store.md](play-store.md) |
| **Microsoft Store** | Live + CI | [microsoft-store.md](microsoft-store.md) |
| **Fire TV** | Planned | [fire-tv.md](fire-tv.md) |
| **AppGallery** | Planned | Android APK; NEXT HAP is separate — [harmonyos.md](harmonyos.md) |
| **Honor / Galaxy** | Planned | Same store-APK pattern |
| **App Store** (iOS / tvOS) | Planned | [app-store.md](app-store.md) |
| **Mac App Store** | Planned | [mac-app-store.md](mac-app-store.md) |
| **Flathub / Homebrew** | Planned | Need sandbox / notarization answers |
| **F-Droid** | Maybe | Only if inclusion is cheap |
| **RuStore / mainland CN stores** | Skip for now | ID / entity barriers |

## Ports

| Port | Status | Notes |
| --- | --- | --- |
| Steam Deck / SteamOS | Fun | Linux zip + layout + Game Mode desktop |
| Windows / Linux ARM64 | Shipping path | CI package keys |
| Flutter web | Alpha | [web.md](web.md) |
| Samsung Tizen | Experimental | [smart-tv.md](smart-tv.md) |
| LG webOS | Experimental | Placeholder `webos/` — [webos.md](webos.md) |
| HarmonyOS NEXT | Interesting | Needs HAP; not the AppGallery APK |

## Later / optional premium

- Account **cloud sync** (resume, lists, prefs, **tracker tokens**) as a paid
  add-on — must not regress offline / BYO.
- Cross-device resume without a self-hosted folder.
- AMOLED true-black theme; opt-in crash reports (off by default).

## Explicit non-goals

- Mandatory cloud account.
- Bundled content / IPTV reseller lock-in.
- Native playlist loader “because another app has one.”
- Sports score overlays.
- Paywalling core library / resume / favorites.
