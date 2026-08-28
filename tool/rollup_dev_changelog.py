#!/usr/bin/env python3
"""Roll up ## X.Y.Z-dev+N sections into a stable CHANGELOG cut.

Dev publish folds fragments under Dev headings. A later marketing bump
(e.g. 0.5.0) does not match those idents, so stable latest.json looks thin.
This merges public Dev history (+ optional prior patch section + Unreleased
fragments) into one ## version section, with ###-aware merge and bullet dedupe.

Stable publish (`tool/deploy_update.py --channel stable` /
`local_release.sh --channel stable`) runs the same logic automatically and
**fails** if the new stable section is still thin vs orphan `-dev` history.

Usage:
  # Auto-detect orphan -dev lineage for the pubspec (or --stable-version):
  python3 tool/rollup_dev_changelog.py --auto --write

  # Explicit (merge-to-main / recovery):
  python3 tool/rollup_dev_changelog.py \\
    --from-ref origin/dev \\
    --stable-version 0.5.0+58 \\
    --since-dev 0.4.2-dev \\
    --min-code 50 --max-code 63 \\
    --also-section 0.4.3+57 \\
    --write
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))

from deploy_update import (  # noqa: E402
    assemble_unreleased_body,
    collect_rollup_public_bodies,
    count_public_bullets,
    dedupe_h3_bullets,
    ensure_stable_changelog_rollup,
    merge_h3_markdown,
    plan_stable_dev_rollup,
    public_section_body,
    read_pubspec_version,
    rewrite_stable_changelog_section,
    stable_changelog_is_thin,
)


def _git_show(ref: str, path: str) -> str:
    import subprocess

    return subprocess.check_output(
        ["git", "show", f"{ref}:{path}"],
        cwd=ROOT,
        text=True,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--auto",
        action="store_true",
        help="Detect orphan -dev history for --stable-version / pubspec and roll up",
    )
    parser.add_argument(
        "--from-ref",
        default="",
        help="Optional git ref whose CHANGELOG.md supplies -dev sections "
        "(default: working-tree --into-file)",
    )
    parser.add_argument("--into-file", type=Path, default=ROOT / "CHANGELOG.md")
    parser.add_argument(
        "--stable-version",
        default="",
        help="e.g. 0.5.0 or 0.5.0+58 (default with --auto: pubspec)",
    )
    parser.add_argument("--since-dev", default="")
    parser.add_argument("--min-code", type=int, default=None)
    parser.add_argument("--max-code", type=int, default=None)
    parser.add_argument("--also-section", action="append", default=[])
    parser.add_argument("--also-from-ref", default="")
    parser.add_argument("--date", default=dt.date.today().isoformat())
    parser.add_argument("--delete-fragments", action="store_true")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.auto:
        version_name = args.stable_version.strip()
        version_code = None
        if not version_name:
            version_name, version_code = read_pubspec_version()
        elif "+" in version_name:
            version_name, code_s = version_name.split("+", 1)
            version_code = int(code_s)
        do_write = bool(args.write) and not args.dry_run
        if not args.write and not args.dry_run:
            raw = args.into_file.read_text(encoding="utf-8")
            plan = plan_stable_dev_rollup(raw, version_name)
            thin, matching, orphan = stable_changelog_is_thin(raw, version_name)
            print(
                f"Auto plan for {version_name}: thin={thin} "
                f"matching={matching} orphan={orphan} plan={plan}"
            )
            if thin:
                print("Pass --write to apply")
            return 0
        result = ensure_stable_changelog_rollup(
            version_name=version_name,
            version_code=version_code,
            changelog_path=args.into_file,
            write=do_write,
            auto=True,
        )
        print(
            f"{result.get('action')}: matching={result.get('matching', result.get('matching_before'))} "
            f"orphan={result.get('orphan')} bullets={result.get('bullets')}"
        )
        if args.delete_fragments and do_write:
            frag = ROOT / "changelog" / "unreleased"
            for path in sorted(frag.glob("*.md")):
                if path.name.lower() == "readme.md":
                    continue
                path.unlink()
                print(f"deleted {path.name}")
        return 0

    if not args.stable_version:
        raise SystemExit("--stable-version is required (or pass --auto)")
    if not args.since_dev and not args.from_ref:
        # Allow plan from into-file when since-dev omitted
        working_preview = args.into_file.read_text(encoding="utf-8")
        plan = plan_stable_dev_rollup(
            working_preview, args.stable_version.split("+", 1)[0]
        )
        if not plan:
            raise SystemExit(
                "Could not auto-detect --since-dev; pass --since-dev explicitly"
            )
        args.since_dev = plan["since_dev"]
        if args.min_code is None:
            args.min_code = plan["min_code"]
        if args.max_code is None:
            args.max_code = plan["max_code"]
        if not args.also_section:
            args.also_section = list(plan.get("also_sections") or [])

    if not args.since_dev:
        raise SystemExit("--since-dev is required (or pass --auto)")

    source = (
        _git_show(args.from_ref, "CHANGELOG.md")
        if args.from_ref
        else args.into_file.read_text(encoding="utf-8")
    )
    also_src = (
        _git_show(args.also_from_ref, "CHANGELOG.md")
        if args.also_from_ref
        else args.into_file.read_text(encoding="utf-8")
    )
    working = args.into_file.read_text(encoding="utf-8")

    # Prefer -dev bodies from --from-ref; also-sections / Unreleased from working tree.
    unreleased = public_section_body(assemble_unreleased_body(working))
    bodies = (
        ([unreleased] if unreleased.strip() else [])
        + collect_rollup_public_bodies(
            source,
            since_dev=args.since_dev,
            min_code=args.min_code,
            max_code=args.max_code,
            also_sections=[],
        )
        + collect_rollup_public_bodies(
            also_src,
            since_dev="__none__",
            min_code=None,
            max_code=None,
            also_sections=args.also_section,
        )
    )
    merged = dedupe_h3_bullets(merge_h3_markdown(bodies))
    if not merged.strip():
        raise SystemExit("rollup produced an empty public body")

    bullets = count_public_bullets(merged)
    print(
        f"Roll-up {args.stable_version}: {bullets} public bullets "
        f"(dev={args.since_dev} {args.min_code or '…'}..{args.max_code or '…'}, "
        f"also={args.also_section or []})"
    )
    preview = f"## {args.stable_version} ({args.date})\n\n{merged.strip()}\n"
    print(preview[:1500])
    if len(preview) > 1500:
        print("…")

    if args.dry_run and not args.write:
        return 0
    if not args.write:
        raise SystemExit("Pass --write to update CHANGELOG.md (or --dry-run)")

    base = also_src if args.also_from_ref else working
    updated = rewrite_stable_changelog_section(
        base,
        version=args.stable_version,
        date=args.date,
        section_body=merged,
    )
    args.into_file.write_text(updated, encoding="utf-8")
    print(f"Wrote {args.into_file}")

    if args.delete_fragments:
        frag = ROOT / "changelog" / "unreleased"
        for path in sorted(frag.glob("*.md")):
            if path.name.lower() == "readme.md":
                continue
            path.unlink()
            print(f"deleted {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
