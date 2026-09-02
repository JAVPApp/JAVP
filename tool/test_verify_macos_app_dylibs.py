#!/usr/bin/env python3
"""Guard: macOS packaging rejects absolute host dylib load paths."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "tool" / "verify_macos_app_dylibs.sh"
PODSPEC = ROOT / "packages" / "rqbit_engine" / "macos" / "rqbit_engine.podspec"

# Portable otool -L lines (script greps leading whitespace + absolute paths).
PORTABLE_OTOOL = """\
javp:
\t/usr/lib/libSystem.B.dylib
\t@rpath/librqbit_engine.dylib
\t@rpath/FlutterMacOS.framework/FlutterMacOS
"""

BAD_OTOOL = """\
javp:
\t/usr/lib/libSystem.B.dylib
\t/Users/builder/librqbit_engine.dylib
\t@rpath/FlutterMacOS.framework/FlutterMacOS
"""


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _make_app(tmp: Path, *, with_dylib: bool = True) -> Path:
    app = tmp / "javp.app"
    macos = app / "Contents" / "MacOS"
    frameworks = app / "Contents" / "Frameworks"
    macos.mkdir(parents=True)
    frameworks.mkdir(parents=True)
    (macos / "javp").write_bytes(b"fake")
    if with_dylib:
        (frameworks / "librqbit_engine.dylib").write_bytes(b"fake")
    return app


def _stub_otool(bin_dir: Path, payload: str) -> None:
    # Echo a fixed otool -L dump for any path; enough for the verifier's grep.
    script = f"""#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{payload}
EOF
"""
    _write_executable(bin_dir / "otool", script)


class VerifyMacosAppDylibsTest(unittest.TestCase):
    def test_podspec_rewrites_install_name_to_rpath(self) -> None:
        text = PODSPEC.read_text(encoding="utf-8")
        self.assertIn("@rpath/librqbit_engine.dylib", text)
        self.assertIn("install_name_tool", text)
        self.assertIn("-install_name", text)
        self.assertIn("codesign", text)

    def test_accepts_portable_rpath_load_commands(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            app = _make_app(tmp)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            _stub_otool(bin_dir, PORTABLE_OTOOL)
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}
            proc = subprocess.run(
                ["bash", str(VERIFY), str(app)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("portable", proc.stdout.lower())

    def test_rejects_absolute_users_load_path(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            app = _make_app(tmp)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            _stub_otool(bin_dir, BAD_OTOOL)
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}
            proc = subprocess.run(
                ["bash", str(VERIFY), str(app)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Absolute host library paths", proc.stderr)

    def test_rejects_missing_rqbit_dylib(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            app = _make_app(tmp, with_dylib=False)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            _stub_otool(bin_dir, PORTABLE_OTOOL)
            env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}
            proc = subprocess.run(
                ["bash", str(VERIFY), str(app)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("librqbit_engine.dylib missing", proc.stderr)


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
