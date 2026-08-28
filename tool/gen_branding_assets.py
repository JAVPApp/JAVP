#!/usr/bin/env python3
"""Regenerate Stable branding assets and yellow-tinted Dev icons.

Dev outputs:
  - Android sideloadDev mipmaps / splash / TV banner
  - Windows runner resources/app_icon_dev.ico (applied at Dev build time)
  - macOS Runner/Resources/AppIconDev PNGs (applied at Dev build time)
"""

from __future__ import annotations

import colorsys
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[1]

# Prefer master logo at repo root; fall back to tracked branding asset.
master = root / 'JAVP-logo.png'
fallback = root / 'assets' / 'branding' / 'javp_logo.png'
src_path = master if master.is_file() else fallback
rewrite_stable = src_path == master

src = Image.open(src_path).convert('RGBA')

MIPMAPS = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

# Hue shift: red (~0°) → yellow (~0.14 ≈ 50°). Preserves white play mark + shadows.
YELLOW_HUE = 0.14


def to_yellow(img: Image.Image) -> Image.Image:
    """Recolor red brand pixels to yellow; leave neutrals/white/alpha alone."""
    out = img.copy()
    px = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 8:
                continue
            # Skip near-white / gray (play triangle + soft shadows)
            mx, mn = max(r, g, b), min(r, g, b)
            if mx - mn < 18:
                continue
            # Only remapped warm/red-dominant brand colors
            if r < g + 10 or r < b + 10:
                continue
            h_, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            # Keep saturation/value; park hue in yellow band
            nr, ng, nb = colorsys.hsv_to_rgb(YELLOW_HUE, min(1.0, s * 1.05), v)
            px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return out


MACOS_ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)
MACOS_APPICONSET = (
    root / 'macos' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
)
MACOS_DEV_ICONS = root / 'macos' / 'Runner' / 'Resources' / 'AppIconDev'


def write_mipmaps(base: Image.Image, res_root: Path) -> None:
    for folder, size in MIPMAPS.items():
        dest = res_root / folder
        dest.mkdir(parents=True, exist_ok=True)
        base.resize((size, size), Image.Resampling.LANCZOS).save(
            dest / 'ic_launcher.png',
            optimize=True,
        )


def write_macos_icons(base: Image.Image, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for size in MACOS_ICON_SIZES:
        base.resize((size, size), Image.Resampling.LANCZOS).save(
            dest / f'app_icon_{size}.png',
            optimize=True,
        )


# --- Stable (main) — only when regenerating from master JAVP-logo.png ---
if rewrite_stable:
    assets = root / 'assets' / 'branding'
    assets.mkdir(parents=True, exist_ok=True)
    src.resize((512, 512), Image.Resampling.LANCZOS).save(
        assets / 'javp_logo.png',
        optimize=True,
    )

    main_res = root / 'android' / 'app' / 'src' / 'main' / 'res'
    write_mipmaps(src, main_res)

    src.resize((288, 288), Image.Resampling.LANCZOS).save(
        main_res / 'drawable' / 'splash_logo.png',
        optimize=True,
    )

    web = root / 'web'
    for path, size in {
        'favicon.png': 32,
        'icons/Icon-192.png': 192,
        'icons/Icon-512.png': 512,
        'icons/Icon-maskable-192.png': 192,
        'icons/Icon-maskable-512.png': 512,
    }.items():
        src.resize((size, size), Image.Resampling.LANCZOS).save(
            web / path,
            optimize=True,
        )

# macOS Dock / Finder icon. Always rewrite from the current brand source so the
# asset catalog cannot stay on Flutter's default template PNGs.
write_macos_icons(src, MACOS_APPICONSET)

# --- Dev (sideloadDev): yellow launcher + splash; TV banner picks up yellow mipmap ---
dev_src = to_yellow(src)
dev_res = root / 'android' / 'app' / 'src' / 'sideloadDev' / 'res'
write_mipmaps(dev_src, dev_res)

dev_drawable = dev_res / 'drawable'
dev_drawable.mkdir(parents=True, exist_ok=True)
dev_src.resize((288, 288), Image.Resampling.LANCZOS).save(
    dev_drawable / 'splash_logo.png',
    optimize=True,
)

(dev_drawable / 'tv_banner.xml').write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<!-- Leanback banner 320×180 — Dev (yellow accent) -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item>
        <shape android:shape="rectangle">
            <solid android:color="#0B0C0F" />
            <size android:width="320dp" android:height="180dp" />
        </shape>
    </item>
    <item android:gravity="start|fill_vertical" android:width="10dp">
        <shape android:shape="rectangle">
            <solid android:color="#EAB308" />
        </shape>
    </item>
    <item
        android:bottom="28dp"
        android:drawable="@mipmap/ic_launcher"
        android:gravity="center"
        android:height="88dp"
        android:width="88dp" />
</layer-list>
''',
    encoding='utf-8',
)

# Windows Dev: yellow .ico used by CI when channel=dev (see apply_windows_channel_icon.py).
# Stable keeps windows/runner/resources/app_icon.ico (red) untouched.
WIN_ICO_SIZES = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
win_dev_ico = root / 'windows' / 'runner' / 'resources' / 'app_icon_dev.ico'
win_dev_ico.parent.mkdir(parents=True, exist_ok=True)
dev_src.save(win_dev_ico, format='ICO', sizes=WIN_ICO_SIZES)

# macOS Dev: yellow PNGs copied over the asset catalog at Dev build time
# (see apply_macos_channel_icon.py). Stable keeps AppIcon.appiconset (red).
write_macos_icons(dev_src, MACOS_DEV_ICONS)

scope = 'Stable red + Dev yellow' if rewrite_stable else 'Dev yellow only'
print(f'Regenerated branding from {src_path.name} ({scope})')
print(f'Wrote {win_dev_ico.relative_to(root)}')
print(f'Wrote {MACOS_APPICONSET.relative_to(root)}')
print(f'Wrote {MACOS_DEV_ICONS.relative_to(root)}')
