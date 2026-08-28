# Mac App Store

Separate from the **unsigned macOS zip** on [updater.javp.app](https://updater.javp.app/)
and from the planned **iOS / tvOS App Store** listing
([`app-store.md`](app-store.md)). Same Apple Developer account, different binary.

Sideload macOS is App Sandbox **off** so media, LAN pairing, cleartext IPTV hosts,
and torrents work. A Mac App Store build has to flip that: sandbox **on**, store
owns updates, torrents off.

## Channels

| Channel | Artifact | Self-update | Define |
| --- | --- | --- | --- |
| **sideload** (default) | unsigned `.app` zip | Yes | `JAVP_DISTRIBUTION=sideload` |
| **macappstore** (planned) | signed / sandboxed `.pkg` → App Store Connect | No (App Store updates) | `JAVP_DISTRIBUTION=macappstore` |

Do **not** reuse `appstore` for this binary — that name is reserved for iOS / tvOS.
Settings / About should say updates come from the Mac App Store.

## What has to exist

1. Apple Developer Program (same $99 as iOS) and a **Mac** App Store Connect
   record named **JAVP**.
2. Hardened Runtime + notarization-class signing (the zip today is unsigned).
3. App Sandbox entitlements that still allow: network, user-selected files,
   LAN pairing, local / IPTV HTTP if review will accept a narrow ATS exception.
4. **No** `updater.javp.app` install path. **No** torrents (`AppCapabilities`).
5. **Try demo** — same CC / Blender + public HLS path as Play.

## Policy notes

- Review is the iOS story plus sandbox: file access, network, and “player for
  user-supplied playlists” must be explicit in the reviewer notes.
- Do not ship the sideload zip to the Mac App Store.
- Homebrew Cask is a different channel (notarized zip / cask, not MAS).

## Checklist when ready to land

- [ ] `JAVP_DISTRIBUTION=macappstore` + torrents / self-update gated off
- [ ] Sandbox entitlements that still play local files + LAN IPTV
- [ ] Mac App Store Connect listing (not the iPhone record)
- [ ] Try demo reviewer notes
- [ ] Smoke-test: install from TestFlight / MAS, no in-app updater

## Related

- Unsigned zip / updater: [`docs/updates.md`](updates.md)
- iOS / tvOS: [`docs/app-store.md`](app-store.md)
- Play Try demo copy: [`docs/play-store.md`](play-store.md)
- Apple: [Mac App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
