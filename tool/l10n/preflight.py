#!/usr/bin/env python3
"""Fail-fast l10n gate. Does not rewrite ARBs.

Exit 1 if Dart `l10n.foo` / AppLocalizations usages are missing from
lib/l10n/app_en.arb. Missing translations in other locales are OK.

Usage:
  python3 tool/l10n/preflight.py
  python3 tool/l10n/preflight.py --from-git origin/dev
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_l10n import print_errors, run_preflight


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-git",
        metavar="REF",
        help="Read catalog + Dart from a git ref instead of the worktree.",
    )
    args = parser.parse_args()
    code, errors, messages, langs = run_preflight(from_git=args.from_git)
    if errors:
        print_errors(errors)
        return 1
    src = args.from_git or "worktree"
    print(
        f"OK — l10n preflight ({src}): {len(messages)} keys × {len(langs)} locales."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
