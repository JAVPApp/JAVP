#!/usr/bin/env python3
"""Assemble changelog/unreleased fragments and gate shared Unreleased edits.

Usage:
  python3 tool/changelog_fragments.py assemble
  python3 tool/changelog_fragments.py public --version 0.4.3-dev
  python3 tool/changelog_fragments.py check --base origin/dev
  python3 tool/changelog_fragments.py count
  python3 tool/changelog_fragments.py consume --version 0.4.2-dev --build 59
"""

from __future__ import annotations

import argparse
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tool" / "deploy_update.py"


def load_module():
    spec = importlib.util.spec_from_file_location("deploy_update", MODULE_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git_file_at(ref: str, relpath: str, *, cwd: Path) -> str:
    try:
        out = subprocess.check_output(
            ["git", "show", f"{ref}:{relpath}"],
            cwd=cwd,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""
    return out.decode("utf-8")


def cmd_assemble(mod) -> int:
    md = mod.read_repo_changelog_md()
    body = mod.extract_unreleased_body(md)
    sys.stdout.write(body.rstrip() + ("\n" if body.strip() else ""))
    return 0


def cmd_public(mod, version: str) -> int:
    md = mod.read_repo_changelog_md()
    notes = mod.public_changelog_from_markdown(md, version_name=version)
    sys.stdout.write(notes.rstrip() + ("\n" if notes.strip() else ""))
    return 0


def cmd_count(mod) -> int:
    paths = mod.list_unreleased_fragment_paths()
    leftover = mod.extract_unreleased_body(
        mod.read_repo_changelog_md(assemble_fragments=False)
    )
    leftover_n = 1 if leftover.strip() else 0
    print(
        f"{len(paths)} fragment(s) under changelog/unreleased/"
        f"{' + leftover CHANGELOG.md Unreleased' if leftover_n else ''}"
    )
    return 0


def cmd_check(mod, base: str) -> int:
    base_md = git_file_at(base, "CHANGELOG.md", cwd=ROOT)
    head_md = mod.read_repo_changelog_md(assemble_fragments=False)
    errors = mod.check_unreleased_not_edited(base_md, head_md)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print(f"OK — CHANGELOG.md Unreleased unchanged vs {base}")
    return 0


def cmd_consume(mod, version: str, build: int | None) -> int:
    result = mod.consume_unreleased_after_publish(
        version_name=version,
        version_code=build,
    )
    deleted = result.get("deleted") or []
    if not result.get("folded") and not deleted:
        print("Nothing to consume (Unreleased already empty)")
        return 0
    cut = mod.cut_version_token(version, build)
    print(f"Folded into ## {cut}; deleted {len(deleted)} fragment(s)")
    for name in deleted:
        print(f"  - {name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Assemble unique changelog fragments; block shared Unreleased edits."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("assemble", help="Print assembled ## Unreleased body")
    pub = sub.add_parser("public", help="Print updater notes (Dev notes stripped)")
    pub.add_argument("--version", required=True, help="pubspec versionName, e.g. 0.4.3-dev")
    chk = sub.add_parser("check", help="Fail if this tree edited CHANGELOG.md Unreleased")
    chk.add_argument("--base", required=True, help="Git ref of the PR base (e.g. origin/dev)")
    sub.add_parser("count", help="How many fragment files (and leftover Unreleased)")
    cons = sub.add_parser(
        "consume",
        help="Fold Unreleased+fragments into ## version+build and delete fragments",
    )
    cons.add_argument("--version", required=True, help="e.g. 0.4.2-dev or 0.4.3")
    cons.add_argument("--build", type=int, default=None, help="pubspec +N / baseVersionCode")
    args = parser.parse_args()
    mod = load_module()
    if args.cmd == "assemble":
        return cmd_assemble(mod)
    if args.cmd == "public":
        return cmd_public(mod, args.version)
    if args.cmd == "count":
        return cmd_count(mod)
    if args.cmd == "check":
        return cmd_check(mod, args.base)
    if args.cmd == "consume":
        return cmd_consume(mod, args.version, args.build)
    parser.error(f"unknown command {args.cmd}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
