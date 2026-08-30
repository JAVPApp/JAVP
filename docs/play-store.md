# Play Store builds

Public listing: [JAVP on Google Play](https://play.google.com/store/apps/details?id=com.javp.javp)
(`com.javp.javp`).

JAVP ships two Android **distribution** flavors from the same codebase:

| Flavor | Artifact | Self-update | Permission |
| --- | --- | --- | --- |
| **sideload** (default) | APK → [updater.javp.app](https://updater.javp.app/) | Yes | `REQUEST_INSTALL_PACKAGES` |
| **play** | AAB → Play Console | No (Play handles updates) | Permission stripped |

Both use `applicationId` `com.javp.javp`. Switching a device from sideload to Play (or the reverse) usually requires uninstalling first when the signing certificates differ (Play App Signing vs your upload/sideload key).

Compile-time channel is `JAVP_DISTRIBUTION` (`sideload` | `play`). Always pass it together with `--flavor` so Dart and the Android manifest stay aligned.

## Build

```bash
# Sideload APKs (same as CI / deploy_update.py)
python tool/build_distribution.py sideload --split-per-abi
python tool/build_distribution.py sideload

# Play Store upload
python tool/build_distribution.py play
# → build/app/outputs/bundle/playRelease/app-play-release.aab
```

Equivalent Flutter commands:

```bash
flutter build apk --release --flavor sideload \
  --dart-define=JAVP_DISTRIBUTION=sideload --split-per-abi

flutter build appbundle --release --flavor play \
  --dart-define=JAVP_DISTRIBUTION=play
```

Local run:

```bash
flutter run --flavor sideload --dart-define=JAVP_DISTRIBUTION=sideload
flutter run --flavor play --dart-define=JAVP_DISTRIBUTION=play
```

## Release signing

Sideload updates **require a stable keystore**. Each GitHub Actions runner has its
own Android Debug key — publishing those made every release uninstall-only.

1. Create an upload keystore (once), if you do not already have one:

   ```bash
   keytool -genkey -v -keystore android/upload-keystore.jks -keyalg RSA \
     -keysize 2048 -validity 10000 -alias javp
   ```

2. Copy `android/key.properties.example` → `android/key.properties` (gitignored) and fill in paths/passwords. Put the `.jks` next to it or use a path relative to the `android/` directory.

3. Release builds use that keystore when `key.properties` exists; otherwise they fall back to the debug key (fine for local `flutter run --release`, **not** for updater.javp.app).

4. **CI (Deploy update)** requires these repo secrets and refuses to publish without them:
   - `ANDROID_KEYSTORE_BASE64` — `base64 -w0 android/upload-keystore.jks`
   - `ANDROID_KEYSTORE_PASSWORD`
   - `ANDROID_KEY_PASSWORD`
   - `ANDROID_KEY_ALIAS` (usually `javp`)

   The workflow writes `key.properties` on the runner, sets `JAVP_REQUIRE_RELEASE_SIGNING=1`, and runs `python tool/deploy_update.py --check-apk-signing` so Android Debug certs never reach FTP.

5. Local publish (`tool/deploy_update.py --build`) also refuses debug-signed APKs. Keep the same `android/key.properties` on build machines.

6. In Play Console, enroll **Play App Signing** and upload the AAB signed with your upload key.

7. Add the keystore SHA-256 to [`https://javp.app/.well-known/assetlinks.json`](https://javp.app/.well-known/assetlinks.json) for App Links (source lives in the site repo). Also register **Play App Signing** SHA-256 there once Play builds ship.

8. **Google Drive on Play builds:** Cloud Console needs an Android OAuth client for `com.javp.javp` + the **Play App Signing** SHA-1 (separate client from upload/sideload). Android client ids are not baked into the APK — see [sync.md](sync.md).

## What the Play flavor changes in the app

- No `REQUEST_INSTALL_PACKAGES`
- No Settings → Updates / launch update prompts
- About still shows the version; subtitle notes updates come from Google Play
- `UpdateProvider` refuses download/install even if called

## Reviewer demo (Try demo)

Welcome includes **Try demo**, which loads a bundled Creative Commons / open-movie
catalog (`assets/demo/catalog.json`) — Blender open movies as short progressive
trailers / clips plus public HLS live feeds (W3C, Blender CDN, Wikimedia Commons;
the old Google `gtv-videos-bucket` and Archive.org HD hosts are too slow or 403).
No copyrighted commercial titles. Streams are remote HTTPS; the APK only ships JSON.

Verify URLs still work before a Play upload:

```bash
python tool/verify_demo_catalog.py
```

Play Console → App access instructions:

> On first launch tap **Try demo**. Open any title under Open movies and press Play,
> or open **Live** and pick a Demo live channel (public HLS test feeds — not commercial TV).
> Demo streams are Creative Commons / Blender Foundation open movies (trailers and
> short clips from W3C / Blender / Wikimedia) and public HLS samples (Akamai / Apple /
> Mux). Torrents and real IPTV stay empty until the user adds their own sources.

Hosted mirror (optional deep link / notes): `https://javp.app/demo/catalog.json`
(`https://javp.app/add?type=custom&url=https://javp.app/demo/catalog.json&name=Demo`).

## Android App Links

One-click add uses verified App Links on `https://javp.app/add?…` (plus the
custom scheme `javp://add`). Statement file:

`https://javp.app/.well-known/assetlinks.json`

Package: `com.javp.javp` (stable sideload / Play). Dev sideload uses
`com.javp.javp.dev` — add a separate `assetlinks.json` target with the upload
keystore fingerprint (same cert as stable sideload). Fingerprints in that file
must include **every** signing cert that ships to devices:

1. **Sideload / upload keystore** (SHA-256 from `keytool -list -v -keystore …`).
2. **Play App Signing** cert (Play Console → App integrity → App signing key
   certificate), once Play builds are live.

After changing fingerprints, redeploy the site and reinstall the app (or
`adb shell pm verify-app-links --re-verify com.javp.javp`). Check with:

```bash
adb shell pm get-app-links com.javp.javp
```

A plain Play Store listing URL cannot auto-add a source after install. Deferred
add would need Play Install Referrer (out of scope); users install, then open
the same `https://javp.app/add?…` link again.

## Upload artifact

After `android/key.properties` + `upload-keystore.jks` exist:

```bash
python tool/build_distribution.py play
# → build/app/outputs/bundle/playRelease/app-play-release.aab
```

Back up `android/upload-keystore.jks` and the store/key passwords (also written to
`android/.upload_keystore_password.txt` locally — gitignored). Losing the upload
key complicates future updates.

## Play Console paste-ready copy

**App name:** JAVP  
**Package:** `com.javp.javp`  
**Category:** Video Players & Editors  
**Free**  
**Privacy policy:** https://javp.app/privacy.html  

**Short description (≤80 chars):**  
Bring-your-own media player for Android & Android TV — your files, servers, catalogs.

**Full description:**  
JAVP (Just Another Video Player) plays media you bring yourself: local videos, Jellyfin, Emby, Plex, custom JSON catalogs, IPTV playlists, and more.  

JAVP does not host, index, or bundle commercial media. You connect your own sources; credentials stay on the device.  

Features include a gesture-friendly player (hold-to-2×, scrub, PiP), Home shelves, Catalog, Live TV when your source supports it, optional downloads, and optional profile sync (folder / WebDAV / Google Drive).  

To try the app without your own library, choose Try demo on first launch for Creative Commons / open Blender sample titles.

**App access / review notes:**  
JAVP is a bring-your-own media player. It does not host or index media. To review: launch app → Try demo → open any Open movies title → Play. Demo streams are Creative Commons / open Blender samples (trailers and short clips) plus public HLS test feeds. Torrents and IPTV require user-supplied sources and are empty in demo. No login required.

**Data safety (summary):** No analytics or ads SDKs. Data stays on device unless the user enables sync or optional integrations (SIMKL, TMDB, Trakt, Serializd, BetaSeries, Plex, Google Drive). See privacy policy.

**Target audience:** Not designed for children; 18+ recommended (user-supplied media / IPTV).

## Publishing API (after the Console draft exists)

Same pattern as Microsoft Store / `msstore`: **create the app once in Play
Console** (a draft is enough), then later AAB + listing art go through
[`tool/play_publish.py`](../tool/play_publish.py).

Google’s API will not create the Play app for you, and a brand-new draft with
**no binary yet** sometimes still needs the first AAB dropped in the Console
UI. After that, Internal testing updates are scripted.

### One-time service account

1. Google Cloud project linked from Play Console → **Setup → API access**.
2. Enable **Google Play Android Developer API**.
3. Create a service account → download the JSON key.
4. In Play Console → API access, invite that account (Release to testing /
   production as you prefer — Internal-only is enough to start).
5. Save the JSON as `android/play-service-account.json` (gitignored) or put
   the file contents in repo secret `PLAY_SERVICE_ACCOUNT_JSON`.

```bash
pip install google-api-python-client google-auth google-auth-httplib2 httplib2
# PowerShell
$env:PLAY_SERVICE_ACCOUNT_JSON = "android/play-service-account.json"
python tool/play_publish.py
python tool/play_publish.py --listing   # phone screenshots + feature/icon/TV banner
python tool/play_publish.py --dry-run
```

## CI — package updates (like Microsoft Store)

After the Play app **draft exists** and the first AAB has been accepted,
stable GitHub Releases auto-build and submit the Play AAB (same pattern as
the Microsoft Store job on Deploy update). Manual retry / track override
uses **Publish to Google Play**.

| Workflow | When |
| --- | --- |
| [`deploy-update.yml`](../.github/workflows/deploy-update.yml) `play` job | On **Release published** — builds Play AAB, attaches to the Release, submits to **internal** testing when secrets exist (`continue-on-error`) |
| [`publish-play.yml`](../.github/workflows/publish-play.yml) | Manual (`workflow_dispatch`) — choose track, draft vs completed, optional listing art; use to promote to production or retry |

Sideload APKs stay on Deploy update / `local_release.sh`; Play is a separate
job because the AAB is a full Android native build (~90+ minutes).

### Secrets (repo → Settings → Secrets → Actions)

| Secret | Where to get it |
| --- | --- |
| `ANDROID_KEYSTORE_*` | Same upload keystore as sideload / Deploy update |
| `PLAY_SERVICE_ACCOUNT_JSON` | Play Console → Setup → API access → service account JSON (file contents) |

Until `PLAY_SERVICE_ACCOUNT_JSON` exists, CI still builds the AAB and uploads
it as the `javp-play-aab` artifact (and attaches it to a Release) for a manual
Console upload.

Dispatch inputs (manual workflow): **track** (`internal` / `alpha` / `beta` /
`production`), **status** (`completed` or `draft`), **listing** (re-upload
screenshots + graphics), **notes** (en-US release notes).

Defaults on Release: package `com.javp.javp`, track `internal`, status
`completed` (internal testers can install). Promote to production in Console
or re-run **Publish to Google Play** with `track=production`. Use
`--status draft` / the draft status input to upload without rolling a track
out.

Listing PNGs come from [`store/play/listing/phone/`](../store/play/listing/phone/)
and [`store/play/graphics/`](../store/play/graphics/).

## Advertising ID (Play Console)

JAVP does **not** read or use the Google Advertising ID (GAID / AAID). There is
no AdMob, Firebase Analytics, or `play-services-ads-identifier` in the app.
Google Cast and Google Sign-In (Drive sync) do not use the ad ID in JAVP.
Optional VAST pre-roll in user-supplied catalogs fires HTTP impression /
tracking URLs only — not GAID.

The **play** flavor merged manifest does not declare
`com.google.android.gms.permission.AD_ID` (verified on `playRelease`). The play
manifest strips that permission if a dependency ever merges it.

**Play Console → Policy → App content → Advertising ID:** answer **No** — the
app does not use advertising ID. If you previously answered Yes, change it to
No; you do **not** need a new AAB for that correction alone (the existing AAB
already omits the permission).

## Android 15 foreground services + boot

Play Console **static analysis** flags any merged manifest that declares both
`BOOT_COMPLETED` and a restricted foreground service type (`dataSync`,
`mediaPlayback`, etc.) — even when the boot receiver never starts an FGS.
Warnings may cite `MainActivity.mediaPendingIntent`; that is PiP transport
(`RemoteAction` PendingIntents), not a mediaPlayback service.

| Build | Boot receiver | FGS |
| --- | --- | --- |
| **sideload** | `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED` — EPG alarms reschedule after reboot | `DownloadKeepAliveService` (`dataSync`) while downloads run |
| **play** | `MY_PACKAGE_REPLACED` only — no `RECEIVE_BOOT_COMPLETED`; EPG reschedule on next app launch | Same `dataSync` FGS, never from boot |

The play flavor manifest strips `BOOT_COMPLETED`, `RECEIVE_BOOT_COMPLETED`, and
any merged `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. Verify after build:

```bash
# PowerShell — merged playRelease manifest must not contain BOOT_COMPLETED
Select-String -Path build/app/intermediates/merged_manifest/playRelease/processPlayReleaseMainManifest/AndroidManifest.xml -Pattern BOOT_COMPLETED
# (no matches)
```

## Still required in Play Console

The app draft can exist before any AAB. Still finish Data safety, content
rating, and store listing text in the Console (API does not replace those
questionnaires). Then upload via `play_publish.py` to **internal testing**,
smoke-test, and promote.

Fire TV / Amazon Appstore is a separate planned channel (APK, not this AAB): [`fire-tv.md`](fire-tv.md). Huawei AppGallery / HarmonyOS: [`harmonyos.md`](harmonyos.md). Apple App Store (iOS / tvOS): [`app-store.md`](app-store.md).
