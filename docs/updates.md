# Updates

**Sideload builds only.** Play (`play`) and Microsoft Store (`msstore`) disable
in-app updates — see [play-store.md](play-store.md) and
[microsoft-store.md](microsoft-store.md).

Sideload clients poll **`updater.javp.app`** (cold start + Settings → Updates):

| Platform | Artifact |
| --- | --- |
| **Android** | ABI under `apks` (universal `javp.apk` on stable) → system installer |
| **Windows** | `packages.windows-arm64` or `windows-x64` zip → PowerShell overlay helper. Setup exe is for first install / WinGet, not in-app. |
| **Linux** | `linux-arm64` or `linux-x64` zip → bash helper |
| **macOS** | `macos-arm64` or `macos-x64` unsigned `.app` zip → bash helper + clear quarantine |

Each platform needs its own artifact in the manifest. Download page:
`deploy/download.html`.

## Channels

| Channel | App | Flavor | Manifest |
| --- | --- | --- | --- |
| **stable** | JAVP (`com.javp.javp`) | `sideload` | `/latest.json` |
| **dev** | JAVP Dev (`com.javp.javp.dev`) | `sideloadDev` | `/dev/latest.json` |

**“Dev build”** means FTP-publish `/dev/latest.json` (Android + Windows + Linux
on the Windows ship host) — not `flutter build apk` alone. Recipe:
[`.cursor/rules/dev-build-means-publish.mdc`](../.cursor/rules/dev-build-means-publish.mdc).

Stable and Dev install side by side. Dev never overwrites production updater
files. Play builds never self-update.

## Who builds what

| Piece | Where |
| --- | --- |
| Android APKs + FTP | Local host — `tool/local_release.sh` / `deploy_update.py` |
| Linux zip | Linux host **or** `build-linux.yml` then `--linux-zip` |
| Windows zip + setup | Local `flutter build windows` + `package_windows.py` |
| macOS zip | Actions on **`vX.Y.0`** tags |
| WinGet / MS Store / Play AAB | Actions on Release (secrets optional) |

Release events **do not FTP**. They attach desktop / store artifacts. Tag
`vX.Y.Z` auto-creates the GitHub Release when missing.

### Secrets / local env

- Escape-hatch CI FTP / WinGet: `JAVP_FTP_*`, `ANDROID_KEYSTORE_*`, `WINGET_TOKEN`
- Store optional: Azure AD + `SELLER_ID` ([microsoft-store.md](microsoft-store.md));
  `PLAY_SERVICE_ACCOUNT_JSON` ([play-store.md](play-store.md))
- Local: `.env` from `.env.example` (gitignored); `android/key.properties` + keystore

### Publish

```bash
./tool/local_release.sh v0.6.0 --changelog "What changed"
./tool/local_release.sh --channel dev --changelog "Dev experiment"
```

Each run clears prior release artifacts via `tool/clean_build.py`
(`--full-clean` for `flutter clean`). Dev auto-bumps `+build` from live
`/dev/latest.json` (`bump_dev_build.py`). Stable bumps `version:` manually,
commits, and tags.

**Windows ship host:** Dev publish must include Android + local Windows + Linux
(from GHA). Android-only FTP leaves desktop clients stuck. Soft-skip Windows only
on hosts that cannot compile it (`JAVP_REQUIRE_GHA_WINDOWS=1` to force).

PR build workflows are **manual** — do not dispatch them to verify PRs.
Exception: Windows ship host dispatches `build-linux.yml` for the Linux zip.

## Manifest & changelog

- Versioned filenames for CDN cache-busting; short names for the download page.
- After publish, prune versioned archives older than the newest **3** cuts
  (`--keep-versions`, `--no-cleanup`).
- In-app notes: `changelog/unreleased/*.md` + leftover Unreleased; **Dev notes**
  stripped. Publish folds/clears fragments. Agent PRs add a **new** fragment file
  only — never edit shared Unreleased.
- `releases[]` array for newer clients; legacy `changelog` string kept.
- Stable marketing bumps roll orphan `-dev` sections via
  `ensure_stable_changelog_rollup` (see `AGENTS.md`).

```bash
python tool/package_windows.py
python tool/deploy_update.py \
  --channel stable \
  --apk-dir build/app/outputs/flutter-apk \
  --windows-zip build/windows-dist/javp-windows-x64.zip \
  --windows-installer build/windows-dist/javp-setup.exe \
  --linux-zip path/to/javp-linux-x64.zip \
  --macos-zip path/to/javp-macos-arm64.zip \
  --macos-x64-zip path/to/javp-macos-x64.zip
```

## Manual publish

```bash
# credentials — copy .env.example; never commit FTP host/IP
export JAVP_FTP_HOST='…'
export JAVP_FTP_USER=javp
export JAVP_FTP_PASS='…'
export JAVP_FTP_DIR=/
export JAVP_PUBLIC_BASE=https://updater.javp.app

python tool/deploy_update.py --build --channel stable --changelog "What changed"
python tool/deploy_update.py --build --channel dev --changelog "Dev experiment"
```

Or build APKs yourself, then `--apk-dir …`. Needs `lftp` (or Python `ftplib`
fallback). Flavor / dart-defines must match the channel ([develop.md](develop.md)).
