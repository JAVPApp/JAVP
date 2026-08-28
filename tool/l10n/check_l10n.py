#!/usr/bin/env python3
"""Validate the English ARB catalog against Dart l10n usage.

Exit codes:
  0 — OK (missing translations are never a failure)
  1 — structural English ARB error, or Dart key missing from app_en.arb

This never rewrites locale ARBs. Add English with add_en.py; translations
belong in lib/l10n/app_<locale>.arb (Weblate / humans).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog import ROOT, SRC, load_catalog, load_sources_from_git, preflight_errors  # noqa: E402


def run_preflight(*, from_git: str | None = None) -> tuple[int, list[str], dict, list[str]]:
    """Return (exit_code, errors, messages, langs). Does not rewrite ARBs."""
    if from_git:
        langs, messages, dart_texts, generated, en_arb = load_sources_from_git(
            ROOT, from_git
        )
        errors = preflight_errors(
            langs,
            messages,
            dart_texts=dart_texts,
            generated_dart=generated,
            en_arb=en_arb,
        )
    else:
        langs, messages = load_catalog()
        errors = preflight_errors(langs, messages)
    return (1 if errors else 0), errors, messages, langs


def print_errors(errors: list[str]) -> None:
    print("Localization catalog errors:")
    for err in errors[:80]:
        print(f"  - {err}")
    if len(errors) > 80:
        print(f"  … and {len(errors) - 80} more")
    print(
        'Fix: python3 tool/l10n/add_en.py <key> "English string" '
        "then re-run python3 tool/l10n/preflight.py"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Deprecated alias; validation never rewrites files.",
    )
    parser.add_argument(
        "--from-git",
        metavar="REF",
        help="Read ARBs + Dart from a git ref (no worktree dirty).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Deprecated; ignored (locale ARBs are not generated).",
    )
    args = parser.parse_args()
    del args.check_only, args.strict

    code, errors, messages, langs = run_preflight(from_git=args.from_git)
    if errors:
        print_errors(errors)
        return 1

    src = f"{args.from_git}:lib/l10n/app_en.arb" if args.from_git else SRC.relative_to(ROOT)
    print(
        f"OK — {len(messages)} keys × {len(langs)} locales; "
        f"{src} covers Dart l10n usage."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
