#!/usr/bin/env python3
"""Regression: Dart l10n keys missing from app_en.arb must fail preflight."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
L10N = Path(__file__).resolve().parent
sys.path.insert(0, str(L10N))

from catalog import (  # noqa: E402
    collect_dart_l10n_usages,
    dart_l10n_keys_missing,
    dump_arb,
    get_en_message,
    insert_en_message,
    parse_arb,
    parse_generated_getters,
    preflight_errors,
    update_en_message,
)


class DartCatalogDriftTests(unittest.TestCase):
    def test_usage_regex_catches_context_l10n_and_app_localizations_of(self):
        text = """
        final a = context.l10n.searchHistoryHint;
        final b = l10n.externalPlayer;
        final c = AppLocalizations.of(context).addProfileFromOtherTarget;
        final d = _uiL10n.sourceSyncConnecting;
        import 'package:javp/l10n/for_you_shelf_l10n.dart';
        """
        used = collect_dart_l10n_usages(text)
        self.assertIn("searchHistoryHint", used)
        self.assertIn("externalPlayer", used)
        self.assertIn("addProfileFromOtherTarget", used)
        self.assertIn("sourceSyncConnecting", used)
        self.assertNotIn("dart", used)

    def test_generated_getters_parse_get_and_parameterized(self):
        generated = """
abstract class AppLocalizations {
  String get searchHistoryHint;
  String minutesLeft(Object minutes);
}
"""
        getters = parse_generated_getters(generated)
        self.assertEqual(getters, {"searchHistoryHint", "minutesLeft"})

    def test_dart_key_missing_from_catalog_is_detected(self):
        lib = Path(tempfile.mkdtemp(prefix="javp_l10n_"))
        (lib / "widgets").mkdir()
        (lib / "widgets" / "search.dart").write_text(
            "String hint(dynamic l10n) => l10n.searchHistoryHint;\n",
            encoding="utf-8",
        )
        messages = {"cancel": {"en": "Cancel"}}
        missing = dart_l10n_keys_missing(messages, lib=lib)
        self.assertEqual(missing, ["searchHistoryHint"])
        errors = preflight_errors(["en"], messages, lib=lib)
        self.assertTrue(
            any("searchHistoryHint" in err for err in errors),
            errors,
        )
        self.assertTrue(
            any("add_en.py" in err and "searchHistoryHint" in err for err in errors),
            errors,
        )

    def test_catalog_with_key_passes(self):
        lib = Path(tempfile.mkdtemp(prefix="javp_l10n_"))
        (lib / "ok.dart").write_text(
            "String hint(dynamic l10n) => l10n.searchHistoryHint;\n",
            encoding="utf-8",
        )
        messages = {"searchHistoryHint": {"en": "Search history"}}
        self.assertEqual(dart_l10n_keys_missing(messages, lib=lib), [])
        errors = preflight_errors(["en"], messages, lib=lib)
        self.assertEqual(errors, [])

    def test_missing_locale_translation_is_not_a_preflight_error(self):
        lib = Path(tempfile.mkdtemp(prefix="javp_l10n_"))
        (lib / "ok.dart").write_text(
            "String hint(dynamic l10n) => l10n.searchHistoryHint;\n",
            encoding="utf-8",
        )
        messages = {"searchHistoryHint": {"en": "Search history"}}
        errors = preflight_errors(["en", "fr"], messages, lib=lib)
        self.assertEqual(errors, [])

    def test_placeholder_mismatch_in_locale_is_an_error(self):
        messages = {
            "addedToName": {
                "en": "Added to {name}",
                "_placeholders": {"name": {"type": "Object"}},
                "fr": "Ajouté à {title}",
            }
        }
        errors = preflight_errors(["en", "fr"], messages, dart_texts=[""])
        self.assertTrue(any("addedToName.fr" in err for err in errors), errors)

    def test_dump_arb_preserves_live_en_arb_formatting(self):
        original = (ROOT / "lib" / "l10n" / "app_en.arb").read_text(encoding="utf-8")
        self.assertEqual(dump_arb(parse_arb(original)), original)

    def test_insert_en_appends_without_reshuffling(self):
        original = (ROOT / "lib" / "l10n" / "app_en.arb").read_text(encoding="utf-8")
        data = parse_arb(original)
        updated = insert_en_message(data, "zzAgentProbeKey", "Probe")
        dumped = dump_arb(updated)
        self.assertEqual(dumped[:500], original[:500])
        self.assertLess(len(dumped) - len(original), 80)
        self.assertIn('"zzAgentProbeKey": "Probe"', dumped)
        self.assertNotIn("zzAgentProbeKey", original)

    def test_insert_en_message_infers_placeholders_and_rejects_dupes(self):
        data = {"@@locale": "en", "cancel": "Cancel"}
        updated = insert_en_message(
            data,
            "addedToName",
            "Added to {name}",
            description="My List snackbar",
        )
        self.assertEqual(updated["addedToName"], "Added to {name}")
        self.assertEqual(
            updated["@addedToName"]["placeholders"],
            {"name": {"type": "Object"}},
        )
        self.assertEqual(updated["@addedToName"]["description"], "My List snackbar")
        dumped = dump_arb(updated)
        parsed = json.loads(dumped)
        self.assertEqual(list(parsed.keys())[0], "@@locale")
        with self.assertRaises(ValueError):
            insert_en_message(updated, "addedToName", "other")
        with self.assertRaises(ValueError):
            insert_en_message(data, "Bad_Key", "nope")

    def test_get_and_update_en_message(self):
        data = {
            "@@locale": "en",
            "cancel": "Cancel",
            "addedToName": "Added to {name}",
            "@addedToName": {
                "description": "old",
                "placeholders": {"name": {"type": "Object"}},
            },
        }
        self.assertEqual(get_en_message(data, "cancel"), "Cancel")
        with self.assertRaises(ValueError):
            get_en_message(data, "missingKey")
        updated = update_en_message(data, "cancel", "Close")
        self.assertEqual(updated["cancel"], "Close")
        self.assertEqual(list(updated.keys()), list(data.keys()))
        renamed = update_en_message(
            data, "addedToName", "Added into {list}", description="new"
        )
        self.assertEqual(renamed["addedToName"], "Added into {list}")
        self.assertEqual(
            renamed["@addedToName"]["placeholders"],
            {"list": {"type": "Object"}},
        )
        self.assertEqual(renamed["@addedToName"]["description"], "new")
        with self.assertRaises(ValueError):
            update_en_message(data, "missingKey", "nope")

    def test_add_en_cli_get_and_update(self):
        data = {"@@locale": "en", "cancel": "Cancel"}
        self.assertEqual(parse_arb(dump_arb(data))["cancel"], "Cancel")
        updated = update_en_message(insert_en_message(data, "ok", "OK"), "ok", "Okay")
        self.assertEqual(updated["ok"], "Okay")
        self.assertEqual(updated["cancel"], "Cancel")

        proc = subprocess.run(
            [sys.executable, str(L10N / "add_en.py"), "cancel"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "Cancel")

    def test_add_en_script_writes_only_english_arb(self):
        arb_dir = Path(tempfile.mkdtemp(prefix="javp_add_en_"))
        en = arb_dir / "app_en.arb"
        fr = arb_dir / "app_fr.arb"
        en.write_text('{\n  "@@locale": "en",\n  "cancel": "Cancel"\n}\n', encoding="utf-8")
        fr.write_text('{\n  "@@locale": "fr",\n  "cancel": "Annuler"\n}\n', encoding="utf-8")
        proc = subprocess.run(
            [
                sys.executable,
                "-c",
                "import json, sys\n"
                "from pathlib import Path\n"
                "sys.path.insert(0, %r)\n"
                "from catalog import dump_arb, insert_en_message, parse_arb\n"
                "en = Path(%r)\n"
                "data = parse_arb(en.read_text(encoding='utf-8'))\n"
                "updated = insert_en_message(data, 'newThing', 'New thing')\n"
                "en.write_text(dump_arb(updated), encoding='utf-8')\n"
                % (str(L10N), str(en)),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        en_data = json.loads(en.read_text(encoding="utf-8"))
        fr_data = json.loads(fr.read_text(encoding="utf-8"))
        self.assertEqual(en_data["newThing"], "New thing")
        self.assertNotIn("newThing", fr_data)

    def test_preflight_script_passes_on_current_tree(self):
        proc = subprocess.run(
            [sys.executable, str(L10N / "preflight.py")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            proc.returncode,
            0,
            proc.stdout + proc.stderr,
        )

    def test_generate_arbs_is_noop(self):
        proc = subprocess.run(
            [sys.executable, str(L10N / "generate_arbs.py")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("no-op", proc.stderr)


if __name__ == "__main__":
    unittest.main()
