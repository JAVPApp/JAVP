#!/usr/bin/env python3
"""Guard: macOS AppIcon PNGs are the JAVP mark, not Flutter's default."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPICONSET = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
DEV_ICONS = ROOT / "macos" / "Runner" / "Resources" / "AppIconDev"
ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)


class MacosAppIconTest(unittest.TestCase):
    def test_contents_json_lists_expected_files(self) -> None:
        data = json.loads((APPICONSET / "Contents.json").read_text(encoding="utf-8"))
        names = {entry["filename"] for entry in data["images"]}
        self.assertEqual({f"app_icon_{size}.png" for size in ICON_SIZES}, names)

    def test_stable_and_dev_pngs_exist_at_listed_sizes(self) -> None:
        for size in ICON_SIZES:
            stable = APPICONSET / f"app_icon_{size}.png"
            dev = DEV_ICONS / f"app_icon_{size}.png"
            self.assertTrue(stable.is_file(), f"missing {stable}")
            self.assertTrue(dev.is_file(), f"missing {dev}")
            self.assertGreater(stable.stat().st_size, 200)
            self.assertGreater(dev.stat().st_size, 200)

    def test_stable_icon_is_red_brand_not_flutter_blue(self) -> None:
        from PIL import Image

        img = Image.open(APPICONSET / "app_icon_256.png").convert("RGBA")
        self.assertEqual(img.size, (256, 256))
        # Sample a band of interior pixels. Flutter's template is blue on white;
        # JAVP's mark is red-dominant.
        red_pixels = 0
        blue_pixels = 0
        for y in range(64, 192, 8):
            for x in range(64, 192, 8):
                r, g, b, a = img.getpixel((x, y))
                if a < 32:
                    continue
                if r > g + 20 and r > b + 20:
                    red_pixels += 1
                if b > r + 20 and b > g:
                    blue_pixels += 1
        self.assertGreater(red_pixels, 20, "macOS AppIcon is not the red JAVP mark")
        self.assertEqual(blue_pixels, 0, "macOS AppIcon still looks like Flutter blue")

    def test_dev_icon_is_yellow_brand(self) -> None:
        from PIL import Image

        img = Image.open(DEV_ICONS / "app_icon_256.png").convert("RGBA")
        self.assertEqual(img.size, (256, 256))
        yellow_pixels = 0
        for y in range(64, 192, 8):
            for x in range(64, 192, 8):
                r, g, b, a = img.getpixel((x, y))
                if a < 32:
                    continue
                if r > 140 and g > 100 and b < 80:
                    yellow_pixels += 1
        self.assertGreater(yellow_pixels, 20, "macOS Dev icon is not the yellow JAVP mark")


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
