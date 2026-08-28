# Huawei AppGallery (HarmonyOS)

JAVP already **sideloads** onto many Huawei phones that still run an
**Android-compatible** HarmonyOS build (same APK as Android / Android TV). That
covers the devices where AppGallery and “open unknown sources” still accept an
APK.

**HarmonyOS NEXT** (no Android app runtime) is a different product: it needs a
native HAP, which this repo does not build yet. Do not claim NEXT support until
there is a real HAP on hardware.

Listing on [Huawei AppGallery](https://developer.huawei.com/consumer/en/appgallery/)
is the planned store channel for **Huawei** phones that still run
Android-compatible HarmonyOS — same idea as Play / Amazon, not a replacement
for sideload.

**Honor is not AppGallery.** Honor split in 2020 and has its own
[Honor App Market](https://developer.honor.com/) console. Same store-APK
pattern (`JAVP_DISTRIBUTION=honor`), separate account and listing. Do not
assume an AppGallery publish reaches Honor devices.

## Channels (same pattern as Play / Microsoft Store)

| Channel | Artifact | Self-update | Define |
| --- | --- | --- | --- |
| **sideload** (default) | APK → [updater.javp.app](https://updater.javp.app/) | Yes | `JAVP_DISTRIBUTION=sideload` |
| **huawei** (planned) | APK → AppGallery Connect | No (AppGallery updates) | `JAVP_DISTRIBUTION=huawei` |

Do **not** ship the sideload APK to AppGallery: it includes
`REQUEST_INSTALL_PACKAGES` and the in-app updater. Store builds must not
self-update.

The `play` flavor already strips that permission, but it is an **AAB** whose
About copy says Google Play. AppGallery wants an **APK** (or AppGallery’s own
package flow) and Settings copy that says Huawei AppGallery — add a `huawei`
product flavor that mirrors `play`, plus `AppDistribution.huawei` in
[`lib/config/distribution.dart`](../lib/config/distribution.dart) (aliases
`appgallery` / `harmonyos`). Do not reuse `appstore` — that name is reserved
for Apple.

## What works today vs NEXT

| Surface | Status |
| --- | --- |
| Sideload APK on HarmonyOS with Android compatibility | Works like Android (same binary) |
| AppGallery listing (Android APK channel) | Planned — this doc |
| HarmonyOS NEXT native HAP | Not started — port, not this listing. NEXT dropped the Android app runtime; an APK will not install. Needs a HAP (DevEco / Flutter-for-Harmony) on hardware before any AppGallery NEXT listing. |

Huawei devices without GMS already skip Chromecast / Google Drive soft-fail the
same way Fire TV does; folder / WebDAV sync still work.

## One-time AppGallery Connect

1. Register at [Huawei Developer](https://developer.huawei.com/) and open
   **AppGallery Connect**.
2. Create an Android / phone & tablet app; reserve the name **JAVP** if
   available.
3. Package: `com.javp.javp` (same as sideload / Play) unless AppGallery
   requires a distinct identity — document the choice here if it diverges.
4. AppGallery signing may differ from Play App Signing — users often cannot
   cross-update between sideload, Play, and AppGallery without uninstalling.

## Listing assets

Confirm current sizes in AppGallery Connect; typical phone listing needs:

| Asset | Typical size | Used for |
| --- | --- | --- |
| App icon | 512×512 | Store |
| Screenshots | phone + optional tablet | Store listing |
| Feature graphic / promo | per console form | Store banner |

Reuse Play short/full description from [`play-store.md`](play-store.md) where it
fits. Privacy: `https://javp.app/privacy`.

## First submission

1. Build the `huawei` APK (once the flavor exists), signed with the upload
   keystore — same key as sideload / Play upload, not a debug cert.
2. AppGallery Connect → new version → upload the APK.
3. Complete content rating, data privacy, and listing graphics.
4. App access / reviewer notes: same **Try demo** path as Play (bundled CC /
   Blender catalog + public HLS). JAVP does not host or index commercial media.
5. Submit. First publish is manual; expect region / age / content checks.

## Policy notes for JAVP

- **No self-update** on `huawei` builds (`Distribution.enablesSelfUpdate` must
  be false). Users get updates from AppGallery only.
- BYO player + Try demo is the same story as Play. Do not bundle commercial
  IPTV or copyrighted catalogs.
- **No Google Play Services** on many Huawei devices. Chromecast and Google
  Drive (`google_sign_in`) must fail soft; folder / WebDAV sync still work.
- Do not market the Android APK as “HarmonyOS NEXT native.” NEXT users need a
  HAP when/if that port exists.

## Checklist when ready to land

- [ ] `huawei` product flavor (mirror `play`: no `REQUEST_INSTALL_PACKAGES`)
- [ ] `JAVP_DISTRIBUTION=huawei` + Settings / About “Updates via AppGallery”
- [ ] Huawei Developer + AppGallery Connect app
- [ ] Upload APK + Try demo reviewer notes
- [ ] Smoke-test on a Huawei phone (Android-compatible HarmonyOS): install,
      D-pad N/A, no in-app updater
- [ ] Explicit non-claim for HarmonyOS NEXT until a HAP exists

## Related

- Sideload APKs: [`docs/updates.md`](updates.md)
- Android Play: [`docs/play-store.md`](play-store.md)
- Fire TV / Amazon: [`docs/fire-tv.md`](fire-tv.md)
- Microsoft Store: [`docs/microsoft-store.md`](microsoft-store.md)
- Apple App Store: [`docs/app-store.md`](app-store.md)
- WinGet: [`deploy/winget/README.md`](../deploy/winget/README.md)
- Honor App Market (separate console): [developer.honor.com](https://developer.honor.com/)
- Huawei: [AppGallery Connect](https://developer.huawei.com/consumer/en/appgallery/)
