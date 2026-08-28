#!/usr/bin/env bash
# Build Android + Linux on this host, optionally pull Windows/macOS from a
# GitHub Release, then FTP-publish to updater.javp.app.
#
# Prerequisites:
#   - .env with JAVP_FTP_* (see .env.example)
#   - android/key.properties + upload-keystore.jks
#   - Flutter/Android SDK/JDK on PATH (see NOTES.txt)
#   - rustup + cargo on PATH (rqbit_engine); cargo-ndk is installed if missing
#   - gh authenticated to JAVPApp/JAVP (only if downloading Release assets)
#
# Usage:
#   ./tool/local_release.sh v0.2.29
#   ./tool/local_release.sh v0.3.0 --channel stable --changelog "…"
#   ./tool/local_release.sh --channel dev --changelog "dev bump"
#   ./tool/local_release.sh --channel dev --windows-zip ./w.zip --windows-installer ./s.exe
#   ./tool/local_release.sh --channel dev --full-clean   # flutter clean + wipe build/
#
# Dev channel auto-bumps pubspec +build (max(local, live /dev/latest.json)+1)
# before building so the in-app updater sees each publish. Pubspec bump is not
# committed. After FTP, deploy_update folds changelog fragments into CHANGELOG.md
# and (by default) commits/pushes that fold so the next hybrid reset stays clean.
# Skip the Dev pubspec bump with JAVP_SKIP_DEV_BUILD_BUMP=1 (or
# JAVP_DEV_BUILD_BUMPED=1 if the queue script already bumped).
#
# Cleanup (always runs first via tool/clean_build.py):
#   Default: clears prior release artifacts only —
#     build/app/outputs, build/linux-dist, build/windows-dist,
#     build/release-download, android/app/build/outputs
#   --full-clean: flutter clean + wipe build/ (+ ephemeral dirs)
#   Does not touch keystores, .env, pub cache, or build/preserve.
#
# Flutter cannot cross-compile Windows from Linux (needs MSVC on Windows).
# On a Linux host, Dev defaults to Android + Linux only when no Windows zip/tag
# is given. That soft-skip is for Linux bots — NOT for the Windows ship host
# (agents there must build Windows locally; see AGENTS.md “Dev build”).
# Hybrid Dev (bot): pass --windows-zip / --windows-installer pointing at paths
# that a parallel GHA download will populate; this script waits for those files
# (JAVP_WIN_ARTIFACT_WAIT_SEC, default 5400) before FTP publish.
#
# Soft-fail: if override paths never appear, log ERROR and publish Android+Linux
# unless JAVP_REQUIRE_GHA_WINDOWS=1.
#
# Stable flow: tag vX.Y.Z (CI auto-creates the GitHub Release if missing) →
# wait for Deploy update (Windows; macOS on x.Y.0; Store/WinGet) → run this
# script with the tag. This script also creates the Release when absent so a
# forgotten "Publish release" click cannot strand Store/WinGet.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG=""
CHANNEL=stable
CHANGELOG=""
CHANGELOG_FILE=""
NO_AUTO_CHANGELOG=0
SKIP_UNIVERSAL=0
SKIP_WINDOWS=0
FULL_CLEAN=0
REPO="${JAVP_GITHUB_REPO:-JAVPApp/JAVP}"
WIN_ZIP_OVERRIDE=""
WIN_SETUP_OVERRIDE=""
MAC_ZIP_OVERRIDE=""
MAC_X64_ZIP_OVERRIDE=""

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    --changelog) CHANGELOG="${2:?}"; shift 2 ;;
    --changelog-file) CHANGELOG_FILE="${2:?}"; shift 2 ;;
    --no-auto-changelog) NO_AUTO_CHANGELOG=1; shift ;;
    --skip-universal) SKIP_UNIVERSAL=1; shift ;;
    --skip-windows) SKIP_WINDOWS=1; shift ;;
    --windows-zip) WIN_ZIP_OVERRIDE="${2:?}"; shift 2 ;;
    --windows-installer) WIN_SETUP_OVERRIDE="${2:?}"; shift 2 ;;
    --macos-zip) MAC_ZIP_OVERRIDE="${2:?}"; shift 2 ;;
    --macos-x64-zip) MAC_X64_ZIP_OVERRIDE="${2:?}"; shift 2 ;;
    --full-clean) FULL_CLEAN=1; shift ;;
    --repo) REPO="${2:?}"; shift 2 ;;
    -*)
      echo "Unknown flag: $1" >&2
      usage 1
      ;;
    *)
      if [[ -z "$TAG" ]]; then TAG="$1"; shift
      else echo "Unexpected arg: $1" >&2; usage 1
      fi
      ;;
  esac
done

# Linux-host Dev: default to Android+Linux when no Windows paths are provided.
# Windows ship hosts should pass --windows-zip (or build + package locally) —
# do not treat this soft-skip as “Dev build done” on a machine that can compile
# Windows (AGENTS.md).
if [[ "$CHANNEL" == "dev" && "$SKIP_WINDOWS" -eq 0 && -z "$WIN_ZIP_OVERRIDE" ]]; then
  SKIP_WINDOWS=1
fi

if [[ -z "$TAG" && "$SKIP_WINDOWS" -eq 0 && -z "$WIN_ZIP_OVERRIDE" ]]; then
  echo "Missing release tag (e.g. v0.2.29), or pass --skip-windows / --windows-zip" >&2
  usage 1
fi

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
: "${JAVP_FTP_HOST:?Set JAVP_FTP_HOST in .env}"
: "${JAVP_FTP_PASS:?Set JAVP_FTP_PASS in .env}"

export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export PATH="${HOME}/.cargo/bin:/opt/flutter/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${JAVA_HOME}/bin:${PATH}"
if ! command -v cargo >/dev/null 2>&1; then
  echo "Missing cargo — install rustup (https://rustup.rs). rqbit_engine needs it for Linux and Android." >&2
  exit 1
fi
if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "==> Installing cargo-ndk"
  cargo install cargo-ndk --locked
fi
if [[ -z "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_HOME}/ndk" ]]; then
  ANDROID_NDK_HOME="$(ls -d "${ANDROID_HOME}/ndk"/* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  export ANDROID_NDK_HOME ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
fi
export JAVP_REQUIRE_RELEASE_SIGNING=1
export GRADLE_OPTS="${GRADLE_OPTS:--Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2}"

if [[ ! -f android/key.properties ]]; then
  echo "Missing android/key.properties — see docs/play-store.md" >&2
  exit 1
fi

if [[ "$FULL_CLEAN" -eq 1 ]]; then
  echo "==> Full-cleaning previous build tree (flutter clean + wipe build/)"
  python3 tool/clean_build.py --full-clean
else
  echo "==> Cleaning previous release artifacts"
  python3 tool/clean_build.py
fi

echo "==> l10n preflight (app_en.arb vs Dart)"
python3 tool/l10n/preflight.py

echo "==> Changelog fragments (changelog/unreleased/ + leftover CHANGELOG.md Unreleased)"
python3 tool/changelog_fragments.py count

# Stable marketing bumps (e.g. 0.4.2-dev → 0.5.0) miss ## *-dev+N headings.
# Auto-roll orphan Dev history into the stable section (or fail if still thin)
# before the long Android/Linux builds.
if [[ "$CHANNEL" == "stable" && "${JAVP_SKIP_STABLE_ROLLUP:-0}" != "1" ]]; then
  echo "==> Stable changelog roll-up / thin-notes preflight"
  python3 tool/deploy_update.py --channel stable --ensure-stable-changelog
fi

# Locale ARBs are translations (not generated). flutter pub get / flutter build
# run gen-l10n from app_en.arb + app_<locale>.arb.

# Dev: advance +build so clients on the previous publish see an update.
# Hybrid queue hard-resets to origin/dev (often a sticky +N); live latest.json
# is the monotonic floor. Marketing version (0.x.y) is left alone; deploy_update
# still appends the -dev versionName suffix.
#
# Always re-check immediately before the Android build: a concurrent git reset
# on this worktree can revert pubspec after the queue's early bump. Pin the
# chosen +N for FTP publish via --version-code so a later revert cannot trip
# same_version_overwrite after a successful build (build OK, latest.json stuck).
DEV_PIN_VERSION_CODE=""
DEV_PIN_VERSION_NAME=""
if [[ "$CHANNEL" == "dev" && "${JAVP_SKIP_DEV_BUILD_BUMP:-0}" != "1" ]]; then
  echo "==> Bumping Dev pubspec build number (pre-build verify)"
  BUMP_SCRIPT="$ROOT/tool/bump_dev_build.py"
  if [[ ! -f "$BUMP_SCRIPT" ]]; then
    BUMP_SCRIPT="${JAVP_BUMP_DEV_SCRIPT:-$ROOT/tool/bump_dev_build.py}"
  fi
  if [[ -f "$BUMP_SCRIPT" ]]; then
    # Re-bump when needed. bump_dev_build is monotonic vs live latest.json; if
    # the queue already advanced past live, this is a no-op write of the same
    # floor+1 only when local was reverted below live.
    if [[ "${JAVP_DEV_BUILD_BUMPED:-0}" != "1" ]]; then
      python3 "$BUMP_SCRIPT" --repo "$ROOT"
    else
      # Queue already bumped; still ensure pubspec > live (repair revert).
      python3 - "$ROOT" "$BUMP_SCRIPT" <<'PY'
import subprocess, sys, re, json, urllib.request
from pathlib import Path
repo = Path(sys.argv[1])
bump = sys.argv[2]
text = (repo / "pubspec.yaml").read_text(encoding="utf-8")
m = re.search(r"^version:\s*([^\s#]+)", text, re.M)
if not m:
    raise SystemExit("pubspec version missing")
raw = m.group(1)
code = int(raw.split("+", 1)[1]) if "+" in raw else 0
url = "https://updater.javp.app/dev/latest.json"
req = urllib.request.Request(url, headers={"User-Agent": "javp-local-release/1.0", "Accept": "application/json", "Cache-Control": "no-cache"})
live = None
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode())
    base = payload.get("baseVersionCode")
    if isinstance(base, (int, float)):
        live = int(base)
    elif isinstance(payload.get("versionCode"), (int, float)):
        n = int(payload["versionCode"])
        live = n % 1000 if n >= 1000 else n
except Exception as exc:
    print(f"WARNING: could not re-check live manifest ({exc})", file=sys.stderr)
if live is not None and code <= live:
    print(f"NOTE: pubspec +{code} <= live +{live} — re-bumping before Android build", file=sys.stderr)
    subprocess.check_call([sys.executable, bump, "--repo", str(repo)])
else:
    print(f"Dev pubspec pin OK: {raw} (live_base={live})")
PY
    fi
  else
    echo "WARNING: no bump script found — pubspec build not advanced" >&2
  fi
  # Pin whatever pubspec now says for the publish step.
  DEV_PIN_VERSION_NAME="$(python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
text = (Path(sys.argv[1]) / "pubspec.yaml").read_text(encoding="utf-8")
m = re.search(r"^version:\s*([^\s#]+)", text, re.M)
raw = m.group(1).strip()
print(raw.split("+", 1)[0] if "+" in raw else raw)
PY
)"
  DEV_PIN_VERSION_CODE="$(python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
text = (Path(sys.argv[1]) / "pubspec.yaml").read_text(encoding="utf-8")
m = re.search(r"^version:\s*([^\s#]+)", text, re.M)
raw = m.group(1).strip()
print(raw.split("+", 1)[1] if "+" in raw else "1")
PY
)"
  echo "    pinned for publish: ${DEV_PIN_VERSION_NAME}+${DEV_PIN_VERSION_CODE}"
  mkdir -p "$ROOT/build"
  printf '%s\n' "$DEV_PIN_VERSION_CODE" >"$ROOT/build/.javp-dev-version-code"
  printf '%s\n' "$DEV_PIN_VERSION_NAME" >"$ROOT/build/.javp-dev-version-name"
fi

echo "==> Building signed Android APKs (channel=$CHANNEL)"
if [[ "$CHANNEL" == "dev" ]]; then
  FLAVOR=sideloadDev
else
  FLAVOR=sideload
fi
if [[ "$CHANNEL" == "dev" || "$SKIP_UNIVERSAL" -eq 1 ]]; then
  export ORG_GRADLE_PROJECT_mediaKitAndroidAbis=arm64-v8a
  export ORG_GRADLE_PROJECT_rqbitEngineAbis=arm64-v8a
  export MEDIA_KIT_ANDROID_ABIS=arm64-v8a
  flutter build apk --release --split-per-abi \
    --target-platform android-arm64 \
    --flavor "$FLAVOR" \
    --dart-define=JAVP_DISTRIBUTION=sideload \
    --dart-define=JAVP_UPDATE_CHANNEL="$CHANNEL"
else
  flutter build apk --release --split-per-abi \
    --target-platform android-arm64,android-arm \
    --flavor "$FLAVOR" \
    --dart-define=JAVP_DISTRIBUTION=sideload \
    --dart-define=JAVP_UPDATE_CHANNEL="$CHANNEL"
  flutter build apk --release \
    --flavor "$FLAVOR" \
    --dart-define=JAVP_DISTRIBUTION=sideload \
    --dart-define=JAVP_UPDATE_CHANNEL="$CHANNEL"
fi

python3 tool/deploy_update.py --check-apk-signing \
  --channel "$CHANNEL" \
  --apk-dir build/app/outputs/flutter-apk

echo "==> Building Linux zip"
flutter build linux --release --dart-define=JAVP_DISTRIBUTION=sideload
mkdir -p build/linux-dist
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64)
    LINUX_ARCH=arm64
    LINUX_ZIP_KEY=linux-arm64
    ;;
  *)
    LINUX_ARCH=x64
    LINUX_ZIP_KEY=linux-x64
    ;;
esac
LINUX_ZIP_PATH="build/linux-dist/javp-linux-${LINUX_ARCH}.zip"
rm -f "$LINUX_ZIP_PATH"
(cd "build/linux/${LINUX_ARCH}/release/bundle" && zip -qr "$ROOT/$LINUX_ZIP_PATH" .)
ls -lh "$LINUX_ZIP_PATH"

WIN_ZIP=""
WIN_SETUP=""
MAC_ZIP=""
MAC_X64_ZIP=""

wait_for_windows_files() {
  local zip_path="$1"
  local setup_path="$2"
  local timeout="${JAVP_WIN_ARTIFACT_WAIT_SEC:-5400}"
  local start=$SECONDS
  local fail_sentinel
  fail_sentinel="$(dirname "$zip_path")/.gha_windows_failed"
  if [[ -f "$zip_path" && -f "$setup_path" ]]; then
    return 0
  fi
  echo "==> Waiting for Windows artifacts (up to ${timeout}s)"
  echo "    zip=$zip_path"
  echo "    setup=$setup_path"
  while (( SECONDS - start < timeout )); do
    if [[ -f "$fail_sentinel" ]]; then
      echo "    GHA Windows fetch reported failure ($(cat "$fail_sentinel" 2>/dev/null || true))"
      return 1
    fi
    if [[ -f "$zip_path" && -f "$setup_path" ]]; then
      echo "    Windows artifacts ready after $((SECONDS - start))s"
      return 0
    fi
    sleep 5
  done
  return 1
}

if [[ -n "$WIN_ZIP_OVERRIDE" ]]; then
  WIN_ZIP="$WIN_ZIP_OVERRIDE"
  WIN_SETUP="${WIN_SETUP_OVERRIDE:?--windows-installer required with --windows-zip}"
  if ! wait_for_windows_files "$WIN_ZIP" "$WIN_SETUP"; then
    if [[ "${JAVP_REQUIRE_GHA_WINDOWS:-0}" == "1" ]]; then
      echo "ERROR: Windows artifacts required (JAVP_REQUIRE_GHA_WINDOWS=1) but missing after wait." >&2
      exit 1
    fi
    echo "ERROR: Windows artifacts not ready after wait — publishing Android+Linux only" >&2
    WIN_ZIP=""
    WIN_SETUP=""
  fi
elif [[ "$SKIP_WINDOWS" -eq 0 ]]; then
  echo "==> Ensuring GitHub Release $TAG exists (Store/WinGet need release: published)"
  python3 tool/ensure_github_release.py "$TAG" --repo "$REPO"

  echo "==> Downloading desktop artifacts from GitHub Release $TAG"
  DIST="$ROOT/build/release-download"
  rm -rf "$DIST"
  mkdir -p "$DIST"
  # Deploy update attaches Windows (always) and macOS (x.Y.0). Poll so a Release
  # we just created can finish desktop jobs before we fail.
  WIN_WAIT="${JAVP_RELEASE_ASSET_WAIT_SEC:-7200}"
  WIN_START=$SECONDS
  WIN_ZIP="$DIST/javp-windows-x64.zip"
  WIN_SETUP="$DIST/javp-setup.exe"
  MAC_ZIP="$DIST/javp-macos-arm64.zip"
  MAC_X64_ZIP="$DIST/javp-macos-x64.zip"
  VER="${TAG#v}"
  WANT_MAC=0
  if [[ "$VER" =~ ^[0-9]+\.[0-9]+\.0([.-].*)?$ ]]; then
    WANT_MAC=1
  fi
  while (( SECONDS - WIN_START < WIN_WAIT )); do
    # Stage into a temp dir so a failed download near timeout cannot rm good
    # copies already fetched earlier in the poll loop.
    STAGE="$DIST/.stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    gh release download "$TAG" --repo "$REPO" --dir "$STAGE" \
      --pattern 'javp-windows-x64.zip' \
      --pattern 'javp-setup.exe' \
      --pattern 'javp-macos-arm64.zip' \
      --pattern 'javp-macos-x64.zip' || true
    for name in javp-windows-x64.zip javp-setup.exe javp-macos-arm64.zip javp-macos-x64.zip; do
      if [[ -f "$STAGE/$name" ]]; then
        mv -f "$STAGE/$name" "$DIST/$name"
      fi
    done
    rm -rf "$STAGE"
    if [[ -f "$WIN_ZIP" && -f "$WIN_SETUP" ]]; then
      if [[ "$WANT_MAC" -eq 0 || -f "$MAC_ZIP" ]]; then
        break
      fi
      echo "    Windows ready; waiting for macOS arm64 on $TAG ($((SECONDS - WIN_START))s / ${WIN_WAIT}s)"
    else
      echo "    Waiting for Deploy update Windows assets on $TAG ($((SECONDS - WIN_START))s / ${WIN_WAIT}s)"
    fi
    sleep 30
  done
  if [[ ! -f "$WIN_ZIP" || ! -f "$WIN_SETUP" ]]; then
    echo "Missing Windows artifacts on release $TAG." >&2
    echo "Wait for Actions → Deploy update (Windows), or pass --skip-windows / --windows-zip." >&2
    gh release view "$TAG" --repo "$REPO" || true
    exit 1
  fi
  if [[ "$WANT_MAC" -eq 1 && ! -f "$MAC_ZIP" ]]; then
    echo "WARNING: x.Y.0 tag but no javp-macos-arm64.zip on $TAG yet — FTP without macOS." >&2
  fi
else
  echo "==> Skipping Windows (Dev / --skip-windows) — Android + Linux only"
  echo "    (Flutter cannot cross-compile Windows from Linux; needs MSVC.)"
fi

if [[ -n "$MAC_ZIP_OVERRIDE" ]]; then
  MAC_ZIP="$MAC_ZIP_OVERRIDE"
fi
if [[ -n "$MAC_X64_ZIP_OVERRIDE" ]]; then
  MAC_X64_ZIP="$MAC_X64_ZIP_OVERRIDE"
fi

PUBLISH_ARGS=(
  --channel "$CHANNEL"
  --apk-dir build/app/outputs/flutter-apk
)
if [[ "$LINUX_ZIP_KEY" == "linux-arm64" ]]; then
  PUBLISH_ARGS+=(--linux-arm64-zip "$LINUX_ZIP_PATH")
else
  PUBLISH_ARGS+=(--linux-zip "$LINUX_ZIP_PATH")
fi
if [[ -n "$WIN_ZIP" && -f "$WIN_ZIP" ]]; then
  PUBLISH_ARGS+=(--windows-zip "$WIN_ZIP" --windows-installer "$WIN_SETUP")
fi
if [[ -n "${WIN_ARM64_ZIP_OVERRIDE:-}" && -f "$WIN_ARM64_ZIP_OVERRIDE" ]]; then
  PUBLISH_ARGS+=(--windows-arm64-zip "$WIN_ARM64_ZIP_OVERRIDE")
fi
if [[ -n "$MAC_ZIP" && -f "$MAC_ZIP" ]]; then
  echo "Including macOS Apple Silicon zip"
  PUBLISH_ARGS+=(--macos-zip "$MAC_ZIP")
elif [[ "$SKIP_WINDOWS" -eq 0 ]]; then
  echo "No macOS Apple Silicon zip (expected for patch tags) — omitting packages.macos-arm64"
fi
if [[ -n "$MAC_X64_ZIP" && -f "$MAC_X64_ZIP" ]]; then
  echo "Including macOS Intel zip"
  PUBLISH_ARGS+=(--macos-x64-zip "$MAC_X64_ZIP")
elif [[ "$SKIP_WINDOWS" -eq 0 ]]; then
  echo "No macOS Intel zip (expected for patch tags) — omitting packages.macos-x64"
fi
if [[ -n "$CHANGELOG_FILE" ]]; then
  PUBLISH_ARGS+=(--changelog-file "$CHANGELOG_FILE")
elif [[ -n "$CHANGELOG" ]]; then
  PUBLISH_ARGS+=(--changelog "$CHANGELOG")
fi
if [[ "$NO_AUTO_CHANGELOG" -eq 1 ]]; then
  PUBLISH_ARGS+=(--no-auto-changelog)
fi
if [[ "$SKIP_UNIVERSAL" -eq 1 || "$CHANNEL" == "dev" ]]; then
  PUBLISH_ARGS+=(--skip-universal)
fi

if [[ "$CHANNEL" == "dev" && -n "$DEV_PIN_VERSION_CODE" ]]; then
  # Survive pubspec revert during the Windows wait: FTP must advertise the
  # +N baked into the APKs we just built.
  PUBLISH_ARGS+=(--version-code "$DEV_PIN_VERSION_CODE")
  if [[ -n "$DEV_PIN_VERSION_NAME" ]]; then
    PUBLISH_ARGS+=(--version-name "$DEV_PIN_VERSION_NAME")
  fi
  echo "==> Publishing with pinned Dev version ${DEV_PIN_VERSION_NAME}+${DEV_PIN_VERSION_CODE}"
fi

echo "==> Publishing to updater.javp.app"
python3 tool/deploy_update.py "${PUBLISH_ARGS[@]}"

echo "Done. Manifest: https://updater.javp.app/$([ "$CHANNEL" = dev ] && echo 'dev/')latest.json"
