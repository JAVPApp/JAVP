#!/usr/bin/env python3
"""Free disk / clear stale outputs between local JAVP releases.

Default (artifact mode): removes only prior **release** outputs so the next
`local_release.sh` does not pick up stale APKs/zips. Leaves Flutter/Gradle
intermediates, `.dart_tool`, keystores, `.env`, and pub/Gradle caches alone
so incremental builds stay fast.

  - build/app/outputs          (APK / AAB / flutter-apk)
  - build/linux-dist           (sideload Linux zip staging)
  - build/windows-dist         (Windows zip / setup staging)
  - build/release-download     (gh release download staging)
  - android/app/build/outputs  (Gradle-copied APK outputs, if present)

Does not delete build/preserve (hand-staged override zips).

Usage:
  python3 tool/clean_build.py
  python3 tool/clean_build.py --full-clean   # flutter clean + wipe build/ (+ ephemeral)
  python3 tool/clean_build.py --deep         # also drop Gradle caches (slower next build)
  python3 tool/clean_build.py --full-clean --deep
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Paths cleared on every local release (and by default when run alone).
ARTIFACT_TARGETS = [
    ROOT / "build" / "app" / "outputs",
    ROOT / "build" / "linux-dist",
    ROOT / "build" / "windows-dist",
    ROOT / "build" / "release-download",
    ROOT / "android" / "app" / "build" / "outputs",
]

# Extra paths wiped only with --full-clean (after `flutter clean`).
FULL_CLEAN_TARGETS = [
    ROOT / "build",
    ROOT / ".dart_tool" / "flutter_build",
    ROOT / "android" / "app" / "build",
    ROOT / "android" / "build",
    ROOT / "linux" / "flutter" / "ephemeral",
    ROOT / "windows" / "flutter" / "ephemeral",
    ROOT / "macos" / "Flutter" / "ephemeral",
]


def _rm(path: Path) -> int:
    if not path.exists():
        return 0
    try:
        if path.is_symlink() or path.is_file():
            size = path.stat().st_size if path.is_file() else 0
            path.unlink(missing_ok=True)
            print(f"  removed file {path.relative_to(ROOT)}")
            return size
        # Rough size before delete (du is slow; walk tops out quickly enough).
        size = 0
        for p in path.rglob("*"):
            try:
                if p.is_file():
                    size += p.stat().st_size
            except OSError:
                pass
        shutil.rmtree(path, ignore_errors=True)
        print(f"  removed dir  {path.relative_to(ROOT)}  (~{size / (1024**3):.2f} GiB)")
        return size
    except OSError as exc:
        print(f"  skip {path}: {exc}", file=sys.stderr)
        return 0


def _flutter_clean() -> None:
    flutter = shutil.which("flutter")
    if flutter is None:
        print("  flutter not on PATH — skipping `flutter clean`", file=sys.stderr)
        return
    print("  running flutter clean")
    subprocess.run([flutter, "clean"], cwd=ROOT, check=False)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Clean JAVP release artifacts (default) or full build tree"
    )
    parser.add_argument(
        "--full-clean",
        action="store_true",
        help="Run flutter clean and wipe build/ plus platform ephemeral dirs",
    )
    parser.add_argument(
        "--deep",
        action="store_true",
        help="Also remove android/.gradle and ~/.gradle/caches (next build redownloads)",
    )
    args = parser.parse_args()

    if args.full_clean:
        print(f"Full-cleaning under {ROOT}")
        _flutter_clean()
        targets = list(FULL_CLEAN_TARGETS)
    else:
        print(f"Cleaning release artifacts under {ROOT}")
        targets = list(ARTIFACT_TARGETS)

    if args.deep:
        targets.append(ROOT / "android" / ".gradle")
        targets.append(Path.home() / ".gradle" / "caches")

    freed = 0
    for path in targets:
        freed += _rm(path)

    print(f"Done — ~{freed / (1024**3):.2f} GiB freed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
