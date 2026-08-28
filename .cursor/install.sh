#!/usr/bin/env bash
# Idempotent Cursor Cloud Build install for JAVP.
# Runs during Builds (not on every agent prompt) so Discord auto-fix starts warm.
set -euo pipefail

export FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"
export PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"
# Prefer the image pub cache when present; fall back to home.
if [[ -d /opt/pub-cache && -w /opt/pub-cache ]]; then
  export PUB_CACHE=/opt/pub-cache
else
  export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not on PATH — Cloud Dockerfile should provide it at ${FLUTTER_HOME}" >&2
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo missing — Cursor Cloud bootstrap requires it in the Dockerfile" >&2
  exit 1
fi

flutter config --no-analytics >/dev/null 2>&1 || true
dart --disable-analytics >/dev/null 2>&1 || true

# Root package + path deps (libtorrent / media_kit fork).
flutter pub get

# Warm nested package lockfiles when present (no native compile).
if [[ -f packages/libtorrent_flutter/pubspec.yaml ]]; then
  (cd packages/libtorrent_flutter && dart pub get) || true
fi
if [[ -f packages/media_kit_libs_android_video/pubspec.yaml ]]; then
  (cd packages/media_kit_libs_android_video && dart pub get) || true
fi

# Cheap semantic check — catches broken deps without Android SDK.
flutter analyze --no-fatal-infos --no-fatal-warnings || true

echo "JAVP cloud install complete (Flutter $(flutter --version | head -1))"
