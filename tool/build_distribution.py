#!/usr/bin/env python3
"""Build JAVP for sideload (APK) or Google Play (AAB).

Examples:
  python tool/build_distribution.py sideload
  python tool/build_distribution.py sideload --split-per-abi
  python tool/build_distribution.py sideload-dev
  python tool/build_distribution.py sideload-dev --split-per-abi
  python tool/build_distribution.py play
  python tool/build_distribution.py play --apk   # Play APK for local install tests
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

DISTRIBUTIONS = {
    "sideload": {
        "flavor": "sideload",
        "defines": (
            "JAVP_DISTRIBUTION=sideload",
            "JAVP_UPDATE_CHANNEL=stable",
        ),
        "default_target": "apk",
    },
    "sideload-dev": {
        "flavor": "sideloadDev",
        "defines": (
            "JAVP_DISTRIBUTION=sideload",
            "JAVP_UPDATE_CHANNEL=dev",
        ),
        "default_target": "apk",
    },
    "play": {
        "flavor": "play",
        "defines": ("JAVP_DISTRIBUTION=play",),
        "default_target": "appbundle",
    },
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Build sideload or Play Store JAVP")
    parser.add_argument(
        "distribution",
        choices=sorted(DISTRIBUTIONS),
        help="sideload → updater.javp.app APKs; sideload-dev → /dev channel; play → Play Console AAB",
    )
    parser.add_argument(
        "--release",
        action="store_true",
        default=True,
        help="Release mode (default)",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Debug mode instead of release",
    )
    parser.add_argument(
        "--split-per-abi",
        action="store_true",
        help="APK only: one APK per ABI",
    )
    parser.add_argument(
        "--apk",
        action="store_true",
        help="Force APK even for play (local install testing)",
    )
    parser.add_argument(
        "--appbundle",
        action="store_true",
        help="Force app bundle (AAB)",
    )
    args = parser.parse_args()
    meta = DISTRIBUTIONS[args.distribution]

    if args.appbundle:
        target = "appbundle"
    elif args.apk:
        target = "apk"
    else:
        target = meta["default_target"]

    mode = "debug" if args.debug else "release"
    cmd = [
        "flutter",
        "build",
        target,
        f"--{mode}",
        "--flavor",
        meta["flavor"],
    ]
    for define in meta["defines"]:
        cmd.append(f"--dart-define={define}")
    if target == "apk" and args.split_per_abi:
        cmd.append("--split-per-abi")

    print(" ".join(cmd))
    # On Windows, `flutter` is often a .bat that CreateProcess cannot find without shell.
    flutter = "flutter.bat" if sys.platform.startswith("win") else "flutter"
    cmd[0] = flutter
    subprocess.check_call(cmd, cwd=ROOT, shell=sys.platform.startswith("win"))

    out = ROOT / "build/app/outputs"
    if target == "appbundle":
        print(f"\nAAB under: {out / 'bundle'}")
    else:
        print(f"\nAPKs under: {out / 'flutter-apk'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode) from exc
