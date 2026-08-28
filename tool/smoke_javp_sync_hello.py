#!/usr/bin/env python3
"""Smoke-test --javp-sync NDJSON hello (no network job).

Spawns the Release javp.exe with --javp-sync, waits for a hello event on
stdout, then kills the process. Exit 0 = protocol pipe works.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "build" / "windows" / "x64" / "runner" / "Release" / "javp.exe"


def main() -> int:
    if not EXE.is_file():
        print(f"missing exe: {EXE}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["JAVP_SYNC_WORKER"] = "1"

    proc = subprocess.Popen(
        [str(EXE), "--javp-sync"],
        cwd=str(EXE.parent),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    assert proc.stdout is not None
    assert proc.stdin is not None

    deadline = time.time() + 45
    hello = False
    lines: list[str] = []
    try:
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
                continue
            line = line.strip()
            if not line:
                continue
            lines.append(line)
            if not line.startswith("{"):
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("t") == "hello":
                hello = True
                break
    finally:
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    err = ""
    if proc.stderr is not None:
        try:
            err = proc.stderr.read()[-2000:]
        except Exception:
            pass

    if hello:
        print("OK: worker hello received")
        return 0

    print("FAIL: no hello event", file=sys.stderr)
    print("stdout lines:", lines[-10:], file=sys.stderr)
    if err:
        print("stderr tail:", err, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
