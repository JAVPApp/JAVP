# LG webOS port (experimental)

Flutter for webOS:
[flutter-webos](https://github.com/lg-flutter-webos/flutter-webos).

## Requirements

- **webOS TV 26 Re:New** or later
- **Ubuntu** host for the toolchain (22.04 / 24.04 / 26.04). On Windows: WSL2
  or DevContainer
- Developer Mode on the TV (Key Server + passphrase)

## Status in this repo

Dart-side preparation is shared with Tizen:

- `JAVP_HOST=webos` → TV shell + `video_player` backend
- Same feature gates as Tizen (no torrents / Cast / PiP / APK updater / Drive
  Sign-In) — [smart-tv.md](smart-tv.md), `AppCapabilities`

A **placeholder** [`webos/`](../webos/) folder is in-repo (README only). Full
platform scaffolding is generated on a Linux machine with flutter-webos:

```bash
git clone https://github.com/lg-flutter-webos/flutter-webos.git
# follow doc/getting-started.md (SDK + NDK + CLI on PATH)

cd /path/to/javp/app
flutter-webos create --platforms webos .
flutter-webos pub get
flutter-webos custom-devices add   # register TV IP + SSH key
flutter-webos run -d <device_id> \
  --dart-define=JAVP_HOST=webos \
  --dart-define=JAVP_DISTRIBUTION=sideload
```

## Luna / ACG

Native webOS features go through Luna Service and must be declared in the app
info / ACG. Prefer keeping media in Flutter/`video_player` until a concrete
Luna need appears.

## Related

[smart-tv.md](smart-tv.md) · [features.md](features.md) · [roadmap.md](roadmap.md)
