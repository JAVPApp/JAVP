#!/usr/bin/env python3
"""Package Flutter Windows Release into a portable zip and Inno Setup installer.

Outputs (default):
  build/windows-dist/javp-windows-x64.zip
  build/windows-dist/javp-setup.exe

ARM64 (zip only by default when --arch arm64):
  build/windows-dist/javp-windows-arm64.zip

Examples:
  python tool/package_windows.py
  python tool/package_windows.py --release-dir path/to/Release
  python tool/package_windows.py --arch arm64 --skip-installer
  python tool/package_windows.py --skip-installer
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "build" / "windows-dist"
ISS = ROOT / "windows" / "installer" / "javp.iss"


def infer_arch(release_dir: Path) -> str:
    """Infer x64|arm64 from a Flutter build path (…/windows/{arch}/runner/Release)."""
    parts = [p.lower() for p in release_dir.resolve().parts]
    if "arm64" in parts:
        return "arm64"
    if "x64" in parts:
        return "x64"
    return "x64"


def default_release_dir(arch: str) -> Path:
    return ROOT / "build" / "windows" / arch / "runner" / "Release"


def read_pubspec_version() -> tuple[str, int]:
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([^\s#+]+)\+(\d+)\s*$", text, re.M)
    if not m:
        raise SystemExit("Could not parse version: from pubspec.yaml")
    return m.group(1), int(m.group(2))


def find_iscc() -> Path | None:
    env = os.environ.get("ISCC") or os.environ.get("INNO_SETUP_ISCC")
    if env:
        p = Path(env)
        if p.is_file():
            return p
    which = shutil.which("ISCC") or shutil.which("ISCC.exe")
    if which:
        return Path(which)
    for base in (
        Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")),
        Path(os.environ.get("ProgramFiles", r"C:\Program Files")),
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs",
    ):
        for cand in (
            base / "Inno Setup 6" / "ISCC.exe",
            base / "Inno Setup 5" / "ISCC.exe",
        ):
            if cand.is_file():
                return cand
    return None


PORTABLE_MARKER_NAME = "portable"
PORTABLE_MARKER_TEXT = (
    "Keep this file so JAVP stores library, cache, and settings in the data "
    "folder next to javp.exe. The installed setup.exe app ignores this file "
    "and keeps using AppData.\n"
)


def zip_release(release_dir: Path, zip_path: Path) -> None:
    if zip_path.exists():
        zip_path.unlink()
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(release_dir.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(release_dir).as_posix())
        # Not copied into the Inno SourceDir — only the zip is portable.
        zf.writestr(PORTABLE_MARKER_NAME, PORTABLE_MARKER_TEXT)
    print(f"wrote {zip_path} ({zip_path.stat().st_size} bytes)")


def build_installer(
    *,
    release_dir: Path,
    out_dir: Path,
    version_name: str,
    iscc: Path,
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Inno VersionInfoVersion wants N.N.N[.N]; strip any +build suffix.
    clean_version = version_name.split("+", 1)[0]
    setup_path = out_dir / "javp-setup.exe"
    if setup_path.exists():
        setup_path.unlink()
    cmd = [
        str(iscc),
        f"/DMyAppVersion={clean_version}",
        f"/DSourceDir={release_dir}",
        f"/DOutputDir={out_dir}",
        "/DOutputBaseFilename=javp-setup",
        str(ISS),
    ]
    print("running:", " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=str(ROOT))
    if not setup_path.is_file():
        raise SystemExit(f"ISCC finished but missing {setup_path}")
    print(f"wrote {setup_path} ({setup_path.stat().st_size} bytes)")
    return setup_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--release-dir",
        type=Path,
        default=None,
        help="Flutter Windows Release folder (contains javp.exe)",
    )
    parser.add_argument(
        "--arch",
        choices=("x64", "arm64"),
        default=None,
        help="CPU arch for zip name and default release-dir (default: infer)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT,
        help="Output directory for zip + setup.exe",
    )
    parser.add_argument(
        "--skip-zip",
        action="store_true",
        help="Do not write the portable zip",
    )
    parser.add_argument(
        "--skip-installer",
        action="store_true",
        help="Do not build the Inno Setup installer",
    )
    parser.add_argument(
        "--version-name",
        help="Override app version shown in the installer (default: pubspec)",
    )
    args = parser.parse_args()

    if args.release_dir is not None:
        release_dir = args.release_dir.resolve()
        arch = args.arch or infer_arch(release_dir)
    else:
        arch = args.arch or "x64"
        release_dir = default_release_dir(arch).resolve()

    out_dir = args.out_dir.resolve()
    exe = release_dir / "javp.exe"
    if not exe.is_file():
        raise SystemExit(f"Missing {exe} — build with: flutter build windows --release")

    version_name, _code = read_pubspec_version()
    if args.version_name:
        version_name = args.version_name

    # ARM64 ships zip-only for now (no separate Inno product yet).
    skip_installer = bool(args.skip_installer) or arch == "arm64"

    if not args.skip_zip:
        zip_release(release_dir, out_dir / f"javp-windows-{arch}.zip")

    if not skip_installer:
        iscc = find_iscc()
        if iscc is None:
            raise SystemExit(
                "ISCC.exe not found. Install Inno Setup 6 "
                "(winget install --id JRSoftware.InnoSetup -e) "
                "or set ISCC to the compiler path."
            )
        build_installer(
            release_dir=release_dir,
            out_dir=out_dir,
            version_name=version_name,
            iscc=iscc,
        )
    elif arch == "arm64" and not args.skip_installer:
        print("Skipping Inno installer for windows-arm64 (zip only)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
