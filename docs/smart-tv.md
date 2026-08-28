# Smart TV ports (Tizen / webOS)

Shipping product remains **Android + Android TV**. Experimental Flutter ports
target **Samsung Tizen** and **LG webOS** with a reduced feature set.

## MVP intent

- 10-foot TV shell (left rail, remote focus)
- Jellyfin / Emby / Plex, custom catalog, M3U / Xtream over HTTP(S)
- Playback via `video_player` (+ `video_player_tizen` on Samsung)
- History / resume on-device
- Phone → TV source QR pairing (LAN `HttpServer`)

## Disabled

| Feature | Why |
| --- | --- |
| Torrents | No rqbit build |
| Chromecast / DLNA / AirPlay | This binary *is* the TV |
| PiP / sideload updater / local file picker | Android / APK paths |
| Google Sign-In (Drive) | Needs GMS |
| Full libass / rich track picking | media_kit only |

Gates: [`app_capabilities.dart`](../lib/platform/app_capabilities.dart).
Host: `--dart-define=JAVP_HOST=android|tizen|webos`
([`javp_host.dart`](../lib/config/javp_host.dart)).

## Samsung Tizen

Needs [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen) + Tizen
SDK. Smart TVs: **Tizen 6.0 (2021+)**.

```bash
flutter-tizen pub get
flutter-tizen run -d <tv_or_emulator> \
  --dart-define=JAVP_HOST=tizen \
  --dart-define=JAVP_DISTRIBUTION=sideload
```

- `video_player_tizen` does **not** work on the emulator — use a real TV
- Manifest: [`tizen/tizen-manifest.xml`](../tizen/tizen-manifest.xml)
- Signing: Samsung certificate profile before installing a TPK

## LG webOS

See [webos.md](webos.md). Host tooling is **Ubuntu** (WSL2/Docker on Windows).
webOS **26 Re:New+** only for flutter-webos.

## Related

[features.md](features.md) · [develop.md](develop.md) · [roadmap.md](roadmap.md)
