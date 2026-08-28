#!/usr/bin/env python3
"""Bump pubspec.yaml +build for Dev-channel local_release (no git push).

See docs/updates.md — Dev hybrid publishes often reuse the same origin/dev
pubspec. The in-app updater compares baseVersionCode (+N), so each Dev FTP
publish must advance +build past max(local pubspec, live /dev/latest.json).

  python3 tool/bump_dev_build.py
  python3 tool/bump_dev_build.py --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(r"^(version:\s*)([^\s#]+)(\s*(?:#.*)?)$", re.M)


def parse_pubspec_version(text: str) -> tuple[str, int, re.Match[str]]:
    match = VERSION_RE.search(text)
    if not match:
        raise SystemExit("Could not parse version: from pubspec.yaml")
    raw = match.group(2).strip()
    if "+" in raw:
        name, code_s = raw.split("+", 1)
    else:
        name, code_s = raw, "0"
    try:
        code = int(code_s)
    except ValueError as exc:
        raise SystemExit(f"Invalid pubspec build number: {raw!r}") from exc
    return name, code, match


def fetch_live_base_version_code(manifest_url: str, *, timeout: float = 20.0) -> int | None:
    req = urllib.request.Request(
        manifest_url,
        headers={
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "User-Agent": "javp-bump-dev-build/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        print(f"WARNING: live manifest HTTP {exc.code}: {manifest_url}", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError) as exc:
        print(f"WARNING: could not read live manifest ({exc})", file=sys.stderr)
        return None

    if not isinstance(payload, dict):
        return None
    base = payload.get("baseVersionCode")
    if isinstance(base, bool):
        return None
    if isinstance(base, (int, float)):
        return int(base)
    if isinstance(base, str) and base.strip().isdigit():
        return int(base.strip())

    code = payload.get("versionCode")
    if isinstance(code, bool):
        return None
    if isinstance(code, (int, float)):
        n = int(code)
        return n % 1000 if n >= 1000 else n
    if isinstance(code, str) and code.strip().isdigit():
        n = int(code.strip())
        return n % 1000 if n >= 1000 else n
    return None


def bump_repo(
    repo: Path,
    *,
    manifest_url: str,
    dry_run: bool = False,
) -> tuple[str, int, int]:
    pubspec = repo / "pubspec.yaml"
    if not pubspec.is_file():
        raise SystemExit(f"pubspec.yaml missing under {repo}")

    text = pubspec.read_text(encoding="utf-8")
    name, local_code, match = parse_pubspec_version(text)
    live_code = fetch_live_base_version_code(manifest_url)
    floor = local_code if live_code is None else max(local_code, live_code)
    new_code = floor + 1
    if new_code >= 1000:
        raise SystemExit(
            f"Dev build number {new_code} would break Flutter split-per-abi "
            "encoding (abiIndex*1000 + build). Bump the marketing version "
            "and reset +build instead."
        )

    new_raw = f"{name}+{new_code}"
    new_text = text[: match.start()] + f"{match.group(1)}{new_raw}{match.group(3)}" + text[match.end() :]
    if not dry_run:
        pubspec.write_text(new_text, encoding="utf-8")

    live_s = "none" if live_code is None else str(live_code)
    print(
        f"Dev pubspec bump: {name}+{local_code} → {new_raw} "
        f"(local={local_code}, live_base={live_s}, manifest={manifest_url}"
        f"{', dry-run' if dry_run else ''})"
    )
    return name, local_code, new_code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        type=Path,
        default=ROOT,
        help="Flutter repo root containing pubspec.yaml (default: this checkout)",
    )
    parser.add_argument(
        "--manifest-url",
        default="",
        help="Dev latest.json URL (default: $JAVP_PUBLIC_BASE/dev/latest.json)",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    public_base = os.environ.get("JAVP_PUBLIC_BASE", "https://updater.javp.app").rstrip("/")
    manifest_url = (args.manifest_url or f"{public_base}/dev/latest.json").strip()
    bump_repo(args.repo.resolve(), manifest_url=manifest_url, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
