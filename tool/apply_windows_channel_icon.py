#!/usr/bin/env python3
"""Select the Windows app icon for a sideload update channel.

Stable keeps the tracked red `app_icon.ico`.
Dev copies yellow `app_icon_dev.ico` over `app_icon.ico` so the EXE (Runner.rc)
and Inno Setup installer both pick up Dev branding.

Intended for CI / throwaway working trees before `flutter build windows`.
Regenerate the yellow asset with: python3 tool/gen_branding_assets.py
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "windows" / "runner" / "resources"
STABLE_ICO = RESOURCES / "app_icon.ico"
DEV_ICO = RESOURCES / "app_icon_dev.ico"


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
        print(f"Windows icon: keeping Stable red ({STABLE_ICO.name})")
        return 0

    if not DEV_ICO.is_file():
        print(f"Missing {DEV_ICO} — run tool/gen_branding_assets.py", file=sys.stderr)
        return 1
    if not STABLE_ICO.is_file():
        print(f"Missing {STABLE_ICO}", file=sys.stderr)
        return 1

    shutil.copyfile(DEV_ICO, STABLE_ICO)
    print(f"Windows icon: applied Dev yellow ({DEV_ICO.name} -> {STABLE_ICO.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
