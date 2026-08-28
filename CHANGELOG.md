# Changelog

User-facing notes are what the in-app updater sends. Put implementation details
under **Dev notes** in that version — those stay in git and are stripped on
publish.

**New PRs:** add a unique file under [`changelog/unreleased/`](changelog/unreleased/)
instead of editing `## Unreleased` below. Publish concatenates those fragments,
folds them under the published `## version+build`, and clears this section.

## Unreleased

### Fixes

- Opening a downloaded series after a restart plays the files already on the
  device instead of fetching episode versions from the catalog.

## 0.6.0

First public open-source release of JAVP under the **GNU GPL-3.0-or-later**.

Bring-your-own media player for Android, Windows, Linux, and macOS: local
files, Jellyfin / Emby / Plex, M3U / Xtream, JSON catalogs, optional trackers
(SIMKL, Trakt, …), and torrents you supply yourself. No bundled content or
credentials.
