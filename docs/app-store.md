# Apple App Store (iOS / tvOS)

There is **no iOS or tvOS target** in this repo yet (macOS desktop is a
separate unsigned zip). The **App Store** is a planned channel: iPhone / iPad
first, **Apple TV** as the 10-foot listing (same role as Fire TV / Android TV).

Sideload does not apply on iOS the way it does on Android. TestFlight is the
beta path; the store owns production updates.

## Channels (same pattern as Play / Microsoft Store)

| Channel | Artifact | Self-update | Define |
| --- | --- | --- | --- |
| **sideload** (desktop / Android only) | zip / APK | Yes | `JAVP_DISTRIBUTION=sideload` |
| **appstore** (planned) | IPA / tvOS → App Store Connect | No (App Store updates) | `JAVP_DISTRIBUTION=appstore` |

Add `AppDistribution.appstore` in [`lib/config/distribution.dart`](../lib/config/distribution.dart)
(aliases `ios` / `apple`). Settings / About should say updates come from the
App Store.

## What has to exist before a listing

1. `flutter create --platforms=ios,tvos .` (needs a Mac + Xcode).
2. Apple Developer Program ($99/year) and an App Store Connect app named **JAVP**.
3. Bundle ID (likely `app.javp.javp` or `com.javp.javp` — pick one and keep it).
4. Signing, capabilities (network, background audio), privacy nutrition labels.
5. A TV shell on tvOS (reuse Android TV rail / focus; Siri Remote).
6. **Try demo** for review — same CC / Blender + public HLS path as Play.

## Policy notes for JAVP

Apple review is stricter than Play for this kind of app:

- **BYO only** — no bundled commercial IPTV or catalogs. Reviewer notes must
  match Play: Try demo, no login, torrents/IPTV empty until the user adds
  sources they have rights to.
- **Torrents** — a BitTorrent engine on an App Store binary is a likely
  rejection. Gate torrents off for `appstore` builds (`AppCapabilities`).
- **Cleartext HTTP** — Android allows it for local IPTV. App Transport Security
  will not; local / `.local` exceptions need an explicit ATS policy, not a
  global `NSAllowsArbitraryLoads` if we can avoid it.
- **IAP** — if a paid unlock ever ships on iOS, it has to go through StoreKit.
  Sideload Stripe / site checkout is not a substitute on this channel.
- **No self-update** — no `updater.javp.app` install path.

## Mac App Store (separate channel)

Not this listing. Own binary, own App Store Connect record:
[`mac-app-store.md`](mac-app-store.md).

## Checklist when ready to land

- [ ] iOS + tvOS platform folders on a Mac
- [ ] `JAVP_DISTRIBUTION=appstore` + torrents / self-update gated off
- [ ] ATS / local-network policy that still allows LAN pairing + IPTV hosts
- [ ] Apple Developer account + App Store Connect listing (iPhone, iPad, Apple TV)
- [ ] TestFlight smoke-test (phone + Apple TV)
- [ ] Try demo reviewer notes; privacy nutrition labels

## Related

- Mac App Store (not iOS): [`mac-app-store.md`](mac-app-store.md)
- Play Store copy / Try demo: [`play-store.md`](play-store.md)
- Fire TV: [`fire-tv.md`](fire-tv.md)
- Huawei AppGallery / HarmonyOS: [`harmonyos.md`](harmonyos.md)
- Microsoft Store: [`microsoft-store.md`](microsoft-store.md)
- Smart TV ports (not Apple): [`smart-tv.md`](smart-tv.md), [`webos.md`](webos.md)
- Apple: [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
