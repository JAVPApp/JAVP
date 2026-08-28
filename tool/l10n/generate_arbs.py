#!/usr/bin/env python3
"""No-op compatibility shim.

English lives in ``lib/l10n/app_en.arb``. Locale ARBs are translations
(Weblate / humans). This script used to rewrite every locale from
``messages.json``; doing that now would clobber translations and re-inflate
agent diffs.

Older Discord/release wrappers may still invoke this file — exit 0.
Add English with::

    python3 tool/l10n/add_en.py <key> "English string"
"""

from __future__ import annotations

import sys

print(
    "generate_arbs.py is a no-op. Add English with:\n"
    '  python3 tool/l10n/add_en.py <key> "English string"\n'
    "Translations live in lib/l10n/app_<locale>.arb (not agent-edited).",
    file=sys.stderr,
)
raise SystemExit(0)
