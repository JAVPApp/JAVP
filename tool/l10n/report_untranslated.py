#!/usr/bin/env python3
"""Report localization keys that still need human translation."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog import SRC, find_untranslated, load_catalog

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = Path(__file__).resolve().parent / "l10n-untranslated.md"


def _summarize(by_locale: dict) -> list[tuple[str, int, int]]:
    rows: list[tuple[str, int, int]] = []
    for lang in sorted(by_locale):
        missing = sum(1 for e in by_locale[lang] if e["status"] == "missing")
        fallback = sum(
            1 for e in by_locale[lang] if e["status"] == "english_fallback"
        )
        if missing or fallback:
            rows.append((lang, missing, fallback))
    return rows


def render_markdown(by_locale: dict, *, total_keys: int) -> str:
    rows = _summarize(by_locale)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Untranslated localization report",
        "",
        f"Generated: {generated}",
        "",
        "Source catalog: `lib/l10n/app_en.arb` ({0} keys).".format(total_keys),
        "",
        "Statuses:",
        "",
        "- **missing** — locale ARB has no string; Flutter gen-l10n falls back to English.",
        "- **english_fallback** — locale string equals English (needs translation).",
        "",
        "## Summary",
        "",
        "| Locale | Missing | English fallback |",
        "| --- | ---: | ---: |",
    ]
    if not rows:
        lines.append("| *(none)* | 0 | 0 |")
    else:
        for lang, missing, fallback in rows:
            lines.append(f"| {lang} | {missing} | {fallback} |")

    for lang, missing, fallback in rows:
        if not missing and not fallback:
            continue
        lines.extend(["", f"## {lang}", ""])
        if missing:
            lines.append(f"### Missing ({missing})")
            lines.append("")
            for entry in by_locale[lang]:
                if entry["status"] != "missing":
                    continue
                en = entry["en"].replace("\n", " ")
                lines.append(f"- `{entry['key']}` — \"{en}\"")
        if fallback:
            lines.append("")
            lines.append(f"### English fallback ({fallback})")
            lines.append("")
            for entry in by_locale[lang]:
                if entry["status"] != "english_fallback":
                    continue
                en = entry["en"].replace("\n", " ")
                if len(en) > 120:
                    en = en[:117] + "…"
                lines.append(f"- `{entry['key']}` — \"{en}\"")

    lines.append("")
    return "\n".join(lines)


def render_json(by_locale: dict, *, total_keys: int) -> str:
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": str(SRC.relative_to(ROOT)),
        "total_keys": total_keys,
        "locales": {
            lang: {
                "missing": [
                    {"key": e["key"], "en": e["en"]}
                    for e in entries
                    if e["status"] == "missing"
                ],
                "english_fallback": [
                    {"key": e["key"], "en": e["en"]}
                    for e in entries
                    if e["status"] == "english_fallback"
                ],
            }
            for lang, entries in sorted(by_locale.items())
        },
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write",
        type=Path,
        metavar="PATH",
        help=f"Write markdown report (default: {DEFAULT_OUT.name}).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON to stdout instead of markdown.",
    )
    parser.add_argument(
        "--brief",
        action="store_true",
        help="Print one summary line per locale with pending work.",
    )
    args = parser.parse_args()

    langs, messages = load_catalog()
    by_locale = find_untranslated(langs, messages)
    rows = _summarize(by_locale)

    if args.json:
        sys.stdout.write(render_json(by_locale, total_keys=len(messages)))
        return 0

    if args.brief:
        if not rows:
            print("All locales have non-English strings for every key.")
            return 0
        for lang, missing, fallback in rows:
            print(f"{lang}: missing={missing}, english_fallback={fallback}")
        return 0

    report = render_markdown(by_locale, total_keys=len(messages))
    out_path = (args.write or DEFAULT_OUT).resolve()
    if args.write is not None or DEFAULT_OUT.parent.exists():
        out_path.write_text(report, encoding="utf-8")
        print(f"Wrote {out_path.relative_to(ROOT.resolve())}")
    else:
        sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
