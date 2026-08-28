#!/usr/bin/env python3
"""Ensure a GitHub Release exists for a stable vX.Y.Z tag.

Stable WinGet / Microsoft Store / desktop Release assets only run on
``release: published``. Tagging alone is not enough. This helper creates the
Release when missing (CI on tag push, or local_release before downloading
desktop artifacts). Draft Releases for the tag are published so
``release: published`` fires.

Usage:
  python3 tool/ensure_github_release.py v0.6.0
  python3 tool/ensure_github_release.py v0.6.0 --repo JAVPApp/JAVP --dry-run
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STABLE_TAG_RE = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)$")


def _run(
    args: list[str],
    *,
    check: bool = True,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=check,
        capture_output=capture,
        text=True,
        cwd=ROOT,
    )


def release_notes_for_tag(tag: str, changelog: Path) -> str:
    ver = tag[1:] if tag.startswith("v") else tag
    if not changelog.is_file():
        return f"JAVP {ver}"
    text = changelog.read_text(encoding="utf-8")
    pat = re.compile(
        rf"(?ms)^## {re.escape(ver)}(?:\+\d+)?[^\n]*\n(.*?)(?=^## |\Z)"
    )
    match = pat.search(text)
    body = (match.group(1).strip() if match else "").strip()
    return body or f"JAVP {ver}"


def release_state(tag: str, repo: str) -> str | None:
    """Return 'published', 'draft', or None if no Release for the tag.

    ``gh release view`` / the tags API omit drafts, so a draft that owns the
    tag looks missing and ``gh release create`` then fails. List includes drafts.
    """
    proc = _run(
        [
            "gh",
            "release",
            "list",
            "--repo",
            repo,
            "--json",
            "tagName,isDraft",
            "-L",
            "200",
        ],
        check=False,
        capture=True,
    )
    if proc.returncode == 0:
        try:
            items = json.loads(proc.stdout or "[]")
        except json.JSONDecodeError:
            items = []
        for item in items:
            if item.get("tagName") == tag:
                return "draft" if item.get("isDraft") else "published"

    # Fallback: published-only view (list may be truncated or unavailable).
    proc = _run(
        ["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft"],
        check=False,
        capture=True,
    )
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return "published"
    return "draft" if data.get("isDraft") else "published"


def publish_draft(tag: str, repo: str) -> None:
    print(f"Publishing draft GitHub Release {tag}")
    _run(
        [
            "gh",
            "release",
            "edit",
            tag,
            "--repo",
            repo,
            "--draft=false",
        ]
    )
    print(
        "Published. Deploy update will build desktop assets and submit Store/WinGet."
    )


def create_release(tag: str, repo: str, notes: str) -> None:
    title = tag[1:]
    print(f"Creating GitHub Release {tag}")
    _run(
        [
            "gh",
            "release",
            "create",
            tag,
            "--repo",
            repo,
            "--title",
            title,
            "--notes",
            notes,
            "--verify-tag",
        ]
    )
    print(
        "Created. Deploy update will build desktop assets and submit Store/WinGet."
    )


def ensure_release(
    tag: str,
    *,
    repo: str,
    dry_run: bool = False,
    notes_file: Path | None = None,
) -> str:
    """Create or publish the Release if needed.

    Returns 'exists' | 'created' | 'published' | 'skipped'.
    """
    match = STABLE_TAG_RE.fullmatch(tag)
    if not match:
        print(f"Tag {tag} is not a stable vX.Y.Z — skipping Release create.")
        return "skipped"

    state = release_state(tag, repo)
    if state == "published":
        print(f"Release {tag} already exists — nothing to do.")
        return "exists"
    if state == "draft":
        if dry_run:
            print(f"[dry-run] would publish draft Release {tag}")
            return "published"
        publish_draft(tag, repo)
        return "published"

    notes = (
        notes_file.read_text(encoding="utf-8").strip()
        if notes_file and notes_file.is_file()
        else release_notes_for_tag(tag, ROOT / "CHANGELOG.md")
    )
    if dry_run:
        print(f"[dry-run] would create Release {tag} ({tag[1:]})")
        print(notes[:500] + ("…" if len(notes) > 500 else ""))
        return "created"

    try:
        create_release(tag, repo, notes)
        return "created"
    except subprocess.CalledProcessError:
        # Concurrent create, or a draft that list missed: treat as success when
        # a published Release is present; publish if we find a draft.
        state = release_state(tag, repo)
        if state == "published":
            print(f"Release {tag} already exists (concurrent create) — OK.")
            return "exists"
        if state == "draft":
            publish_draft(tag, repo)
            return "published"
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Stable tag, e.g. v0.6.0")
    parser.add_argument(
        "--repo",
        default="",
        help="owner/name (default: gh repo from cwd, else JAVPApp/JAVP)",
    )
    parser.add_argument(
        "--notes-file",
        type=Path,
        help="Optional release notes file (default: CHANGELOG section)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be created without calling gh",
    )
    args = parser.parse_args(argv)

    repo = args.repo.strip()
    if not repo:
        proc = _run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            check=False,
            capture=True,
        )
        repo = (proc.stdout or "").strip() if proc.returncode == 0 else "JAVPApp/JAVP"

    ensure_release(
        args.tag.strip(),
        repo=repo,
        dry_run=args.dry_run,
        notes_file=args.notes_file,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
