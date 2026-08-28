#!/usr/bin/env python3
"""Select the macOS app icon for a sideload update channel.

Stable keeps the tracked red `AppIcon.appiconset` PNGs.
Dev copies yellow `Runner/Resources/AppIconDev` over that catalog so Finder
and the Dock pick up Dev branding.

Intended for CI / throwaway working trees before `flutter build macos`.
Regenerate the yellow assets with: python3 tool/gen_branding_assets.py
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPICONSET = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
DEV_ICONS = ROOT / "macos" / "Runner" / "Resources" / "AppIconDev"
ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--channel",
        default="stable",
        choices=("stable", "dev"),
        help="Update channel (default: stable)",
    )
    args = parser.parse_args()

    if args.channel != "dev":
        print(f"macOS icon: keeping Stable red ({APPICONSET.name})")
        return 0

    missing = [
        DEV_ICONS / f"app_icon_{size}.png"
        for size in ICON_SIZES
        if not (DEV_ICONS / f"app_icon_{size}.png").is_file()
    ]
    if missing:
        print(
            f"Missing {missing[0]} — run tool/gen_branding_assets.py",
            file=sys.stderr,
        )
        return 1
    if not APPICONSET.is_dir():
        print(f"Missing {APPICONSET}", file=sys.stderr)
        return 1

    for size in ICON_SIZES:
        name = f"app_icon_{size}.png"
        shutil.copyfile(DEV_ICONS / name, APPICONSET / name)
    print(
        f"macOS icon: applied Dev yellow ({DEV_ICONS.name} -> {APPICONSET.name})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
