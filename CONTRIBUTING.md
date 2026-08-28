# Contributing

Thanks for looking at the code. JAVP is a bring-your-own media player — no
bundled content, credentials stay on the device. Licensed under the
**GNU GPL-3.0-or-later** ([`LICENSE`](LICENSE)).

## How to contribute

1. Fork and clone (once the repo is public), or push a branch if you have write access.
2. Branch from **`dev`** for features and non-urgent fixes. Use **`main`** only
   for critical hotfixes that must ship with the next stable cut.
3. Keep PRs focused. Prefer small, reviewable diffs.
4. Open a PR against `dev` (or `main` for hotfixes). Use the PR template.
5. CI runs `flutter analyze`, `flutter test`, l10n preflight, and changelog
   fragment checks. Prefer green checks before asking for review.

By submitting a contribution, you agree it may be distributed under the same
GPL-3.0-or-later terms.

## Issues

Use the issue forms (bug / feature). For chat, use Discord. For security, see
[`SECURITY.md`](SECURITY.md) — do not file public issues for vulnerabilities.

## Before you write code

1. **[docs/architecture.md](docs/architecture.md)** — where to edit. Extract into
   domain files; do not grow `library_provider.dart` / `playback_provider.dart`
   with new product logic.
2. **[docs/develop.md](docs/develop.md)** — build, flavors, desktop, l10n.
3. Product map: **[docs/features.md](docs/features.md)**,
   **[docs/sources.md](docs/sources.md)**, **[docs/playback.md](docs/playback.md)**.
4. Match existing style. Do not reformat files you did not need to touch.

## Where things live

| Area | Path |
| --- | --- |
| App state façades | `lib/providers/` |
| Domain methods | `lib/providers/library/`, `lib/providers/playback/` |
| Tracker sync | `lib/providers/library/tracker_sync_<source>.dart` |
| Business / clients | `lib/services/` |
| Persistence | `lib/services/storage/` |
| Screens | `lib/screens/` |
| Layout / capabilities | `lib/platform/` |
| OS window / tray / deep links | `lib/services/platform/` |

If a change could go in a façade *or* a domain file / service, put the logic in
the domain file or service and keep a thin method on the provider.

## Localization

English source of truth: `lib/l10n/app_en.arb`.

```bash
python3 tool/l10n/add_en.py camelCaseKey "English"
python3 tool/l10n/preflight.py
```

Do not hand-edit other `app_*.arb` files or generated `app_localizations*.dart`.
Missing locales fall back to English. See `tool/l10n/README.md`.

## Changelog

Add **one new file** under `changelog/unreleased/` (see that folder’s README).
Do not edit `CHANGELOG.md` Unreleased. Do not bump `pubspec.yaml` versions.

- User-facing bullets: what people see in the app.
- `### Dev notes`: internals (stripped from the in-app updater).
- Do **not** name copyrighted titles, real movies/shows, or third-party catalog
  brands in public notes.

## Secrets and fixtures

- Never commit `.env`, keystores, Play/service-account JSON, or real playlist
  credentials.
- In tests, use `example.com` / `catalog.example` hosts and fictional titles
  (`Sample Show`, `Sample Film`). Do not paste live IPTV panels or torrent
  index URLs.

## Checks

```bash
flutter analyze
flutter test
python3 tool/l10n/preflight.py   # if you touched English strings
```

On Linux / CI, `flutter build linux --release` is the usual desktop compile
check. Do not dispatch GitHub Actions just to “see if it builds.”

## Pull requests

- One concern per PR. Extraction PRs should not change behavior.
- Keep `LibraryProvider` / `PlaybackProvider` public method names stable.
- Tests for new pure helpers; do not add a widget test that needs a full
  catalog unless you are fixing that screen.

## Security

See [`SECURITY.md`](SECURITY.md) for private vulnerability reports.
