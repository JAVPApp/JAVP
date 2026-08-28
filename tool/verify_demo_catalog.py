#!/usr/bin/env python3
"""Verify every playUrl / poster / thumbnail in the demo catalog is reachable.

Fetches the first 1 KiB (Range) so we confirm progressive media, not just HEAD.
Exit 0 only if every URL returns HTTP 200 or 206 with a media-ish content type.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "assets/demo/catalog.json"


def collect_urls(node: object, out: set[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key in {"playUrl", "posterUrl", "thumbnailUrl", "url"} and isinstance(
                value, str
            ):
                if value.startswith("http"):
                    out.add(value)
            else:
                collect_urls(value, out)
    elif isinstance(node, list):
        for item in node:
            collect_urls(item, out)


def check(url: str) -> tuple[bool, str]:
    is_hls = url.lower().endswith(".m3u8") or "/hls/" in url.lower()
    headers = {
        "User-Agent": "JAVP-demo-catalog-verify/1.0",
    }
    if not is_hls:
        headers["Range"] = "bytes=0-1023"
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            code = resp.status
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
            body = resp.read(64 if is_hls else 16)
            ctype_l = ctype.lower()
            if code in (200, 206) and "html" not in ctype_l:
                if is_hls:
                    text = body.decode("utf-8", errors="ignore")
                    ok = "#EXTM3U" in text or "mpegurl" in ctype_l or "m3u" in ctype_l
                    return ok, f"{code} {ctype} (hls peek)"
                return True, f"{code} {ctype} ({len(body)}B peek)"
            return False, f"{code} {ctype}"
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 — report any network failure
        return False, str(exc)


def main() -> int:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    urls: set[str] = set()
    collect_urls(data, urls)
    print(f"Checking {len(urls)} URL(s) from {CATALOG.relative_to(ROOT)}…")
    failed = 0
    for url in sorted(urls):
        ok, detail = check(url)
        mark = "OK " if ok else "FAIL"
        print(f"  {mark} {detail}  {url}")
        if not ok:
            failed += 1
    if failed:
        print(f"\n{failed} URL(s) failed", file=sys.stderr)
        return 1
    print("\nAll demo URLs reachable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
