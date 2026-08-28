#!/usr/bin/env python3
"""Read, add, or update one English string in lib/l10n/app_en.arb.

Agents and humans use this instead of opening the ARB (or any translation file).

  python3 tool/l10n/add_en.py cancel
  python3 tool/l10n/add_en.py searchHistoryHint "Search history"
  python3 tool/l10n/add_en.py cancel "Close" --update
  python3 tool/l10n/add_en.py addedToName "Added to {name}" --description "My List snackbar"

Does **not** translate, does **not** rewrite locale ARBs, and does **not**
commit generated Dart. ``flutter gen-l10n`` / ``flutter pub get`` fills
AppLocalizations locally (gitignored). Missing locale strings fall back to
English until Weblate / a human edits ``lib/l10n/app_<locale>.arb``.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog import (  # noqa: E402
    EN_ARB,
    ROOT,
    dump_arb,
    get_en_message,
    insert_en_message,
    parse_arb,
    update_en_message,
)


def _maybe_gen_l10n() -> None:
    flutter = shutil.which("flutter")
    if not flutter:
        print(
            "flutter not on PATH — run `flutter gen-l10n` (or `flutter pub get`) "
            "before analyze/test so the new getter exists locally.",
            file=sys.stderr,
        )
        return
    proc = subprocess.run(
        [flutter, "gen-l10n"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        print(
            f"warning: flutter gen-l10n failed ({err or proc.returncode}). "
            "The English ARB was still updated.",
            file=sys.stderr,
        )
        return
    print("ran flutter gen-l10n (generated Dart is gitignored)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("key", help="camelCase ARB / l10n getter name")
    parser.add_argument(
        "english",
        nargs="?",
        default=None,
        help="English UI string (placeholders: {name}). Omit to print the current value.",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="Overwrite an existing English string (does not edit other locales).",
    )
    parser.add_argument(
        "--description",
        metavar="TEXT",
        help="Optional translator note stored on @key in app_en.arb",
    )
    parser.add_argument(
        "--skip-gen-l10n",
        action="store_true",
        help="Do not run flutter gen-l10n after writing the ARB",
    )
    args = parser.parse_args()

    if not EN_ARB.is_file():
        print(f"missing {EN_ARB}", file=sys.stderr)
        return 1

    data = parse_arb(EN_ARB.read_text(encoding="utf-8"))

    if args.english is None:
        if args.update:
            print("--update requires an English string", file=sys.stderr)
            return 1
        try:
            value = get_en_message(data, args.key)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(value)
        return 0

    try:
        if args.update:
            updated = update_en_message(
                data,
                args.key,
                args.english,
                description=args.description,
            )
            action = "updated"
        else:
            updated = insert_en_message(
                data,
                args.key,
                args.english,
                description=args.description,
            )
            action = "added"
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    EN_ARB.write_text(dump_arb(updated), encoding="utf-8")
    rel = EN_ARB.relative_to(ROOT)
    print(f"{action} {args.key} in {rel}")
    print(f"use l10n.{args.key} in Dart. Do not edit other locale ARBs.")
    if not args.skip_gen_l10n:
        _maybe_gen_l10n()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
