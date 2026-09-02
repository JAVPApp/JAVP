#!/usr/bin/env bash
# Fail a packaged javp.app that still embeds absolute host dylib paths, or is
# missing librqbit_engine.dylib. Used by build-macos.yml / deploy-update.yml.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 path/to/javp.app" >&2
  exit 2
fi

BIN="$APP/Contents/MacOS/javp"
if [[ ! -f "$BIN" ]]; then
  echo "::error::Missing macOS binary at $BIN" >&2
  exit 1
fi

DYLIB="$(find "$APP" -name 'librqbit_engine.dylib' -print -quit)"
if [[ -z "$DYLIB" ]]; then
  echo "::error::librqbit_engine.dylib missing from app bundle — torrent engine will not load" >&2
  find "$APP/Contents" -maxdepth 3 -type f -name '*.dylib' 2>/dev/null | head -50 >&2 || true
  exit 1
fi
echo "Found bundled dylib: $DYLIB"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "=== $BIN ==="
  otool -L "$BIN"
  while IFS= read -r -d '' f; do
    echo "=== $f ==="
    otool -L "$f"
  done < <(find "$APP" -name '*.dylib' -print0)
} >"$TMP"

cat "$TMP"

# Absolute paths from the build host (or Homebrew) must not appear as load
# commands — they crash dyld on end-user machines.
if grep -E '^\s+/Users/|^\s+/opt/homebrew/|^\s+/usr/local/opt/' "$TMP"; then
  echo "::error::Absolute host library paths embedded in the macOS app (see above). Fix install names (@rpath / @loader_path) before shipping." >&2
  exit 1
fi

if ! grep -q 'librqbit_engine\.dylib' "$TMP"; then
  echo "::error::No load command references librqbit_engine.dylib" >&2
  exit 1
fi

echo "macOS dylib load paths look portable."
