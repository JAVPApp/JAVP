# Agent notes (JAVP)

**Code map:** [`docs/architecture.md`](docs/architecture.md) — where to edit.
**Product map:** [`docs/features.md`](docs/features.md),
[`docs/sources.md`](docs/sources.md), [`docs/playback.md`](docs/playback.md),
[`docs/sync.md`](docs/sync.md).

Do **not** add tracker / VOD / live / EPG / source-sync logic to
`library_provider.dart`; use `lib/providers/library/*.dart` (trackers →
`tracker_sync_<source>.dart`). This file is process (changelog, Cloud,
publish), not the architecture map.

## Public changelogs / release notes

`CHANGELOG.md` plus **`changelog/unreleased/*.md` fragments** are what the
in-app updater sends (`latest.json` → `changelog`). `tool/deploy_update.py`
concatenates leftover **Unreleased** with those unique files, plus the current
version section(s), and **strips `### Dev notes`**. After a successful publish it
**consumes** those notes (fold under `## version+build`, clear Unreleased, delete
fragments) so the next cut does not repeat them. Git commit bullets are only
a fallback when there are no matching notes. `--changelog` is ignored when
those notes exist — it must not replace them.

**Agent PRs:** add a **new unique file** under `changelog/unreleased/` (e.g.
`pr-short-slug.md`). Never edit `CHANGELOG.md` ## Unreleased (merge conflicts).
Do not bump versions. After a successful FTP publish, `deploy_update.py`
**consumes** fragments — agents must not fold/clear on ordinary PRs.

On the **`dev` branch**, published cuts must stay `## X.Y.Z-dev+N`. Renaming a
cut to stable `## X.Y.Z+N` (e.g. after merging `main`) **drops it from**
`/dev/latest.json` — Dev only lists `*-dev` headings. Keep the `-dev+N` title
on `dev` even when stable already shipped the same `+N`.

When writing fragment / changelog bullets:

- **User-facing** bullets: what people see in the app.
- **Never** name copyrighted titles, real movies/shows, or third-party catalog
  brands in public notes. Describe the behavior; keep concrete titles in tests only.
- **`### Dev notes`**: implementation, cache internals, identifiers — stay in git;
  testers never see them.
- Do **not** list internal tooling (`.cursor/`, Cloud Dockerfiles, `AGENTS.md`,
  CI-only, `tool/`/`deploy/` publish scripts), pure chore/refactor/test/docs, or
  version-bump / “Dev channel publish” commits.
- Prefer `feat:` / `fix:` for user-visible work; `chore:` / `ci:` / `test:` /
  `docs:` / `build:` / `refactor:` for internal work so auto-notes can skip them.
- Keep Projectionist Mode and similar easter eggs out of public notes.

When a platform can be built on the current machine, **build it locally**.
Do **not** dispatch `build-windows.yml` / `build-macos.yml` / `deploy-update.yml`
to check a PR or get a signed APK this host can already produce.

**“Dev build” / ship testers** means FTP-publish `/dev/latest.json` (Android +
Windows + Linux on the Windows ship host) — not `flutter build apk` alone.
Recipe: [`.cursor/rules/dev-build-means-publish.mdc`](.cursor/rules/dev-build-means-publish.mdc)
and [`docs/updates.md`](docs/updates.md). Cloud does not ship signed APKs.

Verify a PR with `flutter analyze`, `flutter test`, and on Cloud
`flutter build linux --release`. GitHub **CI** (`.github/workflows/ci.yml`)
runs analyze + test on PRs to `main`/`dev`, alongside l10n and changelog
fragment workflows. Do **not** dispatch `build-linux.yml` just to verify —
only when shipping Linux from a host that cannot compile Linux.

## Localization preflight

`lib/l10n/app_en.arb` is the English source of truth. Other `app_<locale>.arb`
files are translations — agents must not edit them. Generated
`app_localizations*.dart` is gitignored.

```bash
python3 tool/l10n/add_en.py camelCaseKey "English"
python3 tool/l10n/preflight.py
```

Do **not** Read `app_en.arb` wholesale, translate, or commit generated Dart.
Run `preflight.py` before Deploy update / Windows GHA. See `tool/l10n/README.md`.

## UI isolate (Windows focus / clicks)

Native catalogs are SQLite. Do not copy a huge `List<MediaItem>` / EPG list
onto the UI isolate. Rule:
[`.cursor/rules/ui-isolate.mdc`](.cursor/rules/ui-isolate.mdc).
Map: [`docs/architecture.md`](docs/architecture.md) Catalog storage.

## Cursor Cloud specific instructions

Cloud agents use `.cursor/environment.json` + `.cursor/Dockerfile`. Builds run
`.cursor/install.sh` ahead of prompts so deps are warm.

- **Do** follow [`docs/architecture.md`](docs/architecture.md) for edit sites.
  Tracker sync → `tracker_sync_<source>.dart`; do not grow the façade.
- **Do** edit Dart/Flutter source, run `flutter analyze`, `dart format`, and
  focused tests when cheap.
- **Do** add English with `tool/l10n/add_en.py`; run `preflight.py`.
- **Do** add a short user-facing bullet in a **new** `changelog/unreleased/` file.
  Never edit `CHANGELOG.md` Unreleased; never bump versions or edit signing.
- **Do not** expect a full Android SDK / keystore / emulator in the cloud VM.
  Shipping signed APKs is the **local build host** job (`tool/local_release.sh`).
- **Do not** dispatch `build-linux.yml` from Cloud to *verify* a PR — run
  `flutter build linux --release` in the VM instead.
- Work from the requested git ref (`main` = Stable, `dev` = Early tester). Open
  a PR; do not push straight to those branches unless explicitly told.

## Open PR branches / review bots

After a merge to `dev`, **do not** bulk-update other open PR branches — see
[`.cursor/rules/open-pr-branches.mdc`](.cursor/rules/open-pr-branches.mdc).

## Stable changelog roll-up

Dev publish consumes fragments under `## X.Y.Z-dev+N`. A later stable marketing
bump does **not** match those headings unless Dev history is rolled into the new
stable section first.

**Automatic (preferred):** `deploy_update.py` / `local_release.sh` on **stable**
call `ensure_stable_changelog_rollup`: they detect orphan `*-dev+N` sections,
merge them into `## {stable}+{build}`, and **fail** if notes are still thin.
Escape hatches: `JAVP_SKIP_STABLE_ROLLUP=1`, `--no-stable-rollup`,
`--skip-stable-rollup-preflight`.

**Manual / merge `dev`→`main` checklist:**

1. Merge onto `main` and set `pubspec` to the stable cut.
2. Marketing bump: `python3 tool/rollup_dev_changelog.py --auto` then `--write`.
3. Same-lineage (`0.5.1-dev` → `0.5.1`): retitle/compact headings in `CHANGELOG.md`.
4. Only then tag / `local_release.sh --channel stable`.

```bash
python3 tool/rollup_dev_changelog.py --auto --write
```

Then publish (or `--manifest-only` to fix a thin live changelog without a new cut).
