#!/usr/bin/env python3
"""Smoke-test --javp-sync hello → job → done/error (no real Xtream needed).

Sends a deliberately unreachable xtreamVod job so the worker must answer with
an error (or done) NDJSON event. Exit 0 = protocol round-trip works.
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

JOB = {
    "v": 1,
    "t": "job",
    "op": "xtreamVod",
    "reason": "manual",
    "profileId": "smoke",
    "source": {
        "id": "smoke-unreachable",
        "name": "Smoke",
        "type": "xtream",
        "createdAt": "2024-01-01T00:00:00.000Z",
        "serverUrl": "http://127.0.0.1:1",
        "username": "u",
        "password": "p",
        "enabled": True,
    },
}


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

    deadline = time.time() + 90
    hello = False
    terminal: dict | None = None
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
            t = msg.get("t")
            if t == "hello":
                hello = True
                proc.stdin.write(json.dumps(JOB) + "\n")
                proc.stdin.flush()
                proc.stdin.close()
                continue
            if t in ("done", "error"):
                terminal = msg
                break
            # progress heartbeats are fine
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
            err = proc.stderr.read()[-3000:]
        except Exception:
            pass

    if hello and terminal is not None:
        print(f"OK: hello + {terminal.get('t')} event")
        print(json.dumps(terminal)[:500])
        return 0

    print("FAIL: incomplete protocol", file=sys.stderr)
    print(f"hello={hello} terminal={terminal}", file=sys.stderr)
    print("stdout lines:", lines[-15:], file=sys.stderr)
    if err:
        print("stderr tail:", err, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
