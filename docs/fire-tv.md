# Amazon Appstore (Fire TV)

JAVP already **sideloads** onto Fire TV (same APK as Android / Android TV). The
launcher still shows the **square** icon because Fire OS pulls the wide home-row
tile from **Amazon catalog art**, not from `android:banner` in the APK.

Listing on the [Amazon Appstore](https://developer.amazon.com/apps-and-games)
as a **Fire TV** app is the channel that gets those wide tiles — same idea as
Play / Microsoft Store, not a replacement for sideload.

## Channels (same pattern as Play / Microsoft Store)

| Channel | Artifact | Self-update | Define |
| --- | --- | --- | --- |
| **sideload** (default) | APK → [updater.javp.app](https://updater.javp.app/) | Yes | `JAVP_DISTRIBUTION=sideload` |
| **amazon** (planned) | APK → Amazon Developer Console | No (Appstore updates) | `JAVP_DISTRIBUTION=amazon` |

Do **not** ship the sideload APK to Amazon: it includes `REQUEST_INSTALL_PACKAGES`
and the in-app updater. Store builds must not self-update.

The `play` flavor already strips that permission, but it is an **AAB** whose
About copy says Google Play. Fire TV needs an **APK** and Settings copy that
says Amazon Appstore — add an `amazon` product flavor that mirrors `play`, plus
`AppDistribution.amazon` in [`lib/config/distribution.dart`](../lib/config/distribution.dart)
(alias `firetv`). Do not use `appstore` — that name is reserved for Apple.

## Why the icon is square today

- **Google Android TV** uses the APK `android:banner` (`@drawable/tv_banner`,
  320×180). JAVP already declares `LEANBACK_LAUNCHER` + that banner.
- **Fire TV** ignores that for non-store apps and uses `android:icon`. Store
  apps get 16:9 tiles from listing assets you upload in the console (typically
  a 1920×1080 Fire TV banner).
- The current banner is an XML layer-list wrapping the square logo. Even if
  Fire OS honored it, it would not look like a store tile. Ship a real
  **320×180 PNG** for the APK banner when this channel lands.

## One-time Amazon Developer Console

1. Register at [developer.amazon.com](https://developer.amazon.com/) (no Play-style
   $25 fee).
2. Create an Android app; reserve the name **JAVP** if available.
3. Under supported devices, enable **Fire TV** (Fire tablets are optional and
   not the point of this channel).
4. Package: `com.javp.javp` (same as sideload / Play). Amazon signing is a
   different cert than Play App Signing — users cannot cross-update between
   sideload, Play, and Amazon without uninstalling.

## Listing assets (this is the wide tile)

Upload in the console (sizes Amazon currently asks for; confirm in the form):

| Asset | Typical size | Used for |
| --- | --- | --- |
| App icon | 128×128 and 512×512 | Store + some launcher views |
| **Fire TV banner** | **1920×1080** | Home-row wide tile |
| Fire TV screenshots | 1920×1080 | Store listing |

Reuse Play short/full description from [`play-store.md`](play-store.md) where it
fits. Privacy: `https://javp.app/privacy.html`.

## First submission

1. Build the amazon APK (once the flavor exists), signed with the upload
   keystore — same key as sideload / Play upload, not a debug cert.
2. Console → **Add upcoming version** → upload the APK.
3. Complete Fire TV device support, content rating, data privacy, and listing
   graphics (especially the 1920×1080 banner).
4. App access / reviewer notes: same **Try demo** path as Play (bundled CC /
   Blender catalog + public HLS). JAVP does not host or index commercial media.
5. Submit. First publish is manual.

## Policy notes for JAVP

- **No self-update** on `amazon` builds (`Distribution.enablesSelfUpdate` must
  be false). Users get updates from the Appstore only.
- BYO player + Try demo is the same story as Play. Do not bundle commercial
  IPTV or copyrighted catalogs.
- Fire OS has **no Google Play Services**. Chromecast and Google Drive
  (`google_sign_in`) may be weak or missing; they must fail soft (sideload on
  Fire TV already lives with this). Folder / WebDAV sync still work.
- Keep `android.software.leanback` `required="false"` so the same binary can
  still install on phones if Amazon also lists mobile — Fire TV is the target.

## Checklist when ready to land

- [ ] `amazon` product flavor (mirror `play`: no `REQUEST_INSTALL_PACKAGES`)
- [ ] `JAVP_DISTRIBUTION=amazon` + Settings / About “Updates via Amazon Appstore”
- [ ] Replace XML `tv_banner` with a 320×180 PNG (and a Dev variant)
- [ ] 1920×1080 Fire TV store banner + screenshots
- [ ] Amazon Developer account + Fire TV device listing
- [ ] Upload APK + Try demo reviewer notes
- [ ] Smoke-test Fire TV Stick: wide tile, D-pad, no in-app updater

## Related

- Sideload APKs: [`docs/updates.md`](updates.md)
- Android Play: [`docs/play-store.md`](play-store.md)
- Microsoft Store: [`docs/microsoft-store.md`](microsoft-store.md)
- Apple App Store: [`docs/app-store.md`](app-store.md)
- Huawei AppGallery / HarmonyOS: [`docs/harmonyos.md`](harmonyos.md)
- WinGet: [`deploy/winget/README.md`](../deploy/winget/README.md)
- Amazon: [Fire TV app submission](https://developer.amazon.com/docs/app-submission/understand-submission.html)
