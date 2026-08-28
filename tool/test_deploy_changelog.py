#!/usr/bin/env python3
"""Unit checks for auto changelog helpers in deploy_update.py."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tool" / "deploy_update.py"


def load_module():
    spec = importlib.util.spec_from_file_location("deploy_update", MODULE_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ResolveChangelogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_placeholder_release_line_is_replaced_by_auto(self):
        auto = "What's new since v0.0.1:\n- Cool fix"
        self.mod.build_git_changelog = lambda **_: auto  # type: ignore[method-assign]
        out = self.mod.resolve_changelog("Release v0.1.0", version_name="0.1.0", auto=True)
        self.assertEqual(out, auto)

    def test_manual_notes_stand_alone_without_changelog_md(self):
        auto = "What's new since v0.0.1:\n- Cool fix"
        self.mod.build_git_changelog = lambda **_: auto  # type: ignore[method-assign]
        out = self.mod.resolve_changelog(
            "Hotfix for Chromecast",
            version_name="0.1.1",
            auto=True,
            changelog_md="",
        )
        self.assertEqual(out, "Hotfix for Chromecast")
        self.assertNotIn("Cool fix", out)

    def test_changelog_md_is_payload_and_strips_dev_notes(self):
        md = """# Changelog

## Unreleased

## 0.4.2-dev+55 (2026-08-12)

Dev channel bump (`dev`).

### Features
- TV posters zoom on focus.

### Dev notes
- Overlay lift ~1.32×; vodCacheRevision untouched.

## 0.4.2-dev+50 (2026-08-12)

### Fixes
- Watch live stays on Home.

### Dev notes
- Last-close SQLite snapshot.

## 0.4.1+45 (2026-08-12)

### Fixes
- Old stable note.
"""
        out = self.mod.resolve_changelog(
            "0.4.2-dev+55: TV posters zoom…",
            version_name="0.4.2-dev",
            auto=True,
            channel="dev",
            changelog_md=md,
        )
        self.assertIn("TV posters zoom on focus.", out)
        self.assertIn("Watch live stays on Home.", out)
        self.assertIn("## 0.4.2-dev+55", out)
        self.assertIn("## 0.4.2-dev+50", out)
        self.assertNotIn("vodCacheRevision", out)
        self.assertNotIn("Last-close SQLite", out)
        self.assertNotIn("Dev notes", out)
        self.assertNotIn("Dev channel bump", out)
        self.assertNotIn("Old stable note", out)
        self.assertNotIn("0.4.2-dev+55: TV posters zoom", out)

    def test_stable_includes_matching_dev_prerelease_history(self):
        md = """# Changelog

## 0.4.2+56 (2026-08-13)

Stable release from main.

## 0.4.2-dev+56 (2026-08-13)

### Fixes
- Mini player on Back.

### Dev notes
- hidden

## 0.4.2-dev+50 (2026-08-12)

### Features
- Pairing.

## 0.4.1+45 (2026-08-12)

### Fixes
- Old stable note.
"""
        out = self.mod.public_changelog_from_markdown(md, version_name="0.4.2")
        self.assertIn("Stable release from main.", out)
        self.assertIn("Mini player on Back.", out)
        self.assertIn("Pairing.", out)
        self.assertNotIn("hidden", out)
        self.assertNotIn("Old stable note", out)
        dev = self.mod.public_changelog_from_markdown(md, version_name="0.4.2-dev")
        self.assertNotIn("Stable release from main.", dev)
        self.assertIn("Mini player on Back.", dev)
        self.assertIn("Pairing.", dev)

    def test_releases_include_older_marketing_versions_for_channel(self):
        md = """# Changelog

## Unreleased

### Fixes
- New cut.

## 0.4.2-dev+55 (2026-08-12)

### Features
- TV posters.

### Dev notes
- hidden

## 0.4.2+56 (2026-08-13)

Stable only.

## 0.4.1+45 (2026-08-12)

### Fixes
- Prior stable.

## 0.4.1-dev+40 (2026-08-11)

### Features
- Old dev line.
"""
        dev = self.mod.public_changelog_releases(
            md, version_name="0.4.2-dev", version_code=62, channel="dev"
        )
        codes = [row.get("versionCode") for row in dev]
        titles = [row["title"] for row in dev]
        notes = "\n".join(row["notes"] for row in dev)
        self.assertEqual(codes[0], 62)
        self.assertTrue(titles[0].startswith("0.4.2-dev+62"))
        self.assertIn(55, codes)
        self.assertIn(40, codes)
        self.assertNotIn(56, codes)
        self.assertNotIn(45, codes)
        self.assertIn("New cut.", notes)
        self.assertIn("TV posters.", notes)
        self.assertIn("Old dev line.", notes)
        self.assertNotIn("hidden", notes)
        self.assertNotIn("Stable only.", notes)
        self.assertNotIn("Prior stable.", notes)

        stable = self.mod.public_changelog_releases(
            md, version_name="0.4.2", version_code=56, channel="stable"
        )
        stable_codes = [row.get("versionCode") for row in stable]
        stable_notes = "\n".join(row["notes"] for row in stable)
        self.assertIn(56, stable_codes)
        self.assertIn(45, stable_codes)
        self.assertIn(55, stable_codes)
        self.assertNotIn(40, stable_codes)
        self.assertIn("New cut.", stable_notes)
        self.assertIn("Prior stable.", stable_notes)
        self.assertIn("TV posters.", stable_notes)
        self.assertNotIn("Old dev line.", stable_notes)
        self.assertNotIn("hidden", stable_notes)

    def test_releases_skip_duplicate_cut_when_unreleased_matches_heading(self):
        md = """# Changelog

## Unreleased

### Fixes
- Same notes.

## 0.4.2-dev+62 (2026-08-13)

### Fixes
- Same notes.
"""
        rows = self.mod.public_changelog_releases(
            md, version_name="0.4.2-dev", version_code=62, channel="dev"
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["versionCode"], 62)

    def test_resolve_changelog_releases_falls_back_to_blob(self):
        rows = self.mod.resolve_changelog_releases(
            version_name="0.1.0",
            changelog_md="",
            changelog="Hotfix for Chromecast",
            version_code=2,
            channel="stable",
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["versionCode"], 2)
        self.assertEqual(rows[0]["notes"], "Hotfix for Chromecast")

    def test_releases_cap(self):
        parts = ["# Changelog\n"]
        for i in range(12, 0, -1):
            parts.append(f"## 0.4.2-dev+{i}\n\n### Fixes\n- n{i}.\n")
        rows = self.mod.public_changelog_releases(
            "\n".join(parts),
            version_name="0.4.2-dev",
            version_code=12,
            channel="dev",
            max_releases=5,
        )
        self.assertEqual(len(rows), 5)
        self.assertEqual([r["versionCode"] for r in rows], [12, 11, 10, 9, 8])


    def test_dev_placeholder_does_not_replace_changelog_md(self):
        md = "## 0.4.2-dev+55\n\n### Fixes\n- Real notes.\n"
        self.mod.build_dev_git_changelog = lambda **_: "This Dev build:\n- x"  # type: ignore[method-assign]
        out = self.mod.resolve_changelog(
            "Dev build @ dev",
            version_name="0.4.2-dev",
            auto=True,
            channel="dev",
            changelog_md=md,
        )
        self.assertIn("Real notes.", out)
        self.assertNotIn("This Dev build", out)

    def test_strip_dev_notes_stops_at_next_h3(self):
        body = (
            "### Features\n- Visible.\n\n"
            "### Dev notes\n- Hidden.\n\n"
            "### Fixes\n- Also visible.\n"
        )
        public = self.mod.public_section_body(body)
        self.assertIn("Visible.", public)
        self.assertIn("Also visible.", public)
        self.assertNotIn("Hidden.", public)
        self.assertNotIn("Dev notes", public)

    def test_fragments_merge_stable_order_and_strip_dev_notes(self):
        leftover = """# Changelog

## Unreleased

### Fixes
- leftover from CHANGELOG.md

### Dev notes
- leftover internal

## 0.4.2-dev+55 (2026-08-12)

### Features
- already shipped
"""
        fragments = [
            "### Fixes\n- zebra from a.md\n\n### Dev notes\n- hidden a\n",
            "### Features\n- apple from b.md\n",
        ]
        assembled = self.mod.assemble_changelog_markdown(
            leftover,
            fragment_texts=fragments,
        )
        public = self.mod.public_changelog_from_markdown(
            assembled,
            version_name="0.4.2-dev",
        )
        unreleased = self.mod.extract_unreleased_body(assembled)
        # Leftover headings first, then new headings from later fragments.
        self.assertLess(unreleased.find("### Fixes"), unreleased.find("### Features"))
        self.assertLess(
            unreleased.find("leftover from CHANGELOG.md"),
            unreleased.find("zebra from a.md"),
        )
        self.assertIn("- leftover from CHANGELOG.md", public)
        self.assertIn("- zebra from a.md", public)
        self.assertIn("- apple from b.md", public)
        self.assertIn("already shipped", public)
        self.assertNotIn("leftover internal", public)
        self.assertNotIn("hidden a", public)
        self.assertNotIn("Dev notes", public)
        # Filename order is used when reading a directory.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "pr-zebra.md").write_text("### Fixes\n- zebra file\n", encoding="utf-8")
            (d / "pr-apple.md").write_text("### Fixes\n- apple file\n", encoding="utf-8")
            (d / "README.md").write_text("skip me\n", encoding="utf-8")
            names = [p.name for p in self.mod.list_unreleased_fragment_paths(d)]
            self.assertEqual(names, ["pr-apple.md", "pr-zebra.md"])
            body = self.mod.assemble_unreleased_body("", fragments_dir=d)
            self.assertLess(body.find("apple file"), body.find("zebra file"))
            self.assertNotIn("skip me", body)

    def test_unreleased_is_published_under_this_cut_heading(self):
        md = self.mod.assemble_changelog_markdown(
            "# Changelog\n\n## Unreleased\n\n### Fixes\n- leftover\n\n"
            "## 0.4.2-dev+56 (2026-08-13)\n\n### Player\n- old cut\n",
            fragment_texts=["### Features\n- from fragment\n"],
        )
        out = self.mod.public_changelog_from_markdown(
            md,
            version_name="0.4.2-dev",
            version_code=57,
            published_date="2026-08-13",
        )
        self.assertTrue(out.startswith("## 0.4.2-dev+57 (2026-08-13)"))
        self.assertIn("- leftover", out)
        self.assertIn("- from fragment", out)
        self.assertIn("## 0.4.2-dev+56 (2026-08-13)", out)
        self.assertIn("- old cut", out)
        self.assertNotIn("## Unreleased", out)
        resolved = self.mod.resolve_changelog(
            "Dev build @ dev",
            version_name="0.4.2-dev",
            auto=True,
            channel="dev",
            changelog_md=md,
            version_code=57,
            published_date="2026-08-13",
        )
        self.assertTrue(resolved.startswith("## 0.4.2-dev+57 (2026-08-13)"))
        self.assertNotIn("## Unreleased", resolved)

    def test_second_cut_does_not_repeat_consumed_fragments(self):
        """After publish consumes fragments, the next cut only sees new notes."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            frag = root / "changelog" / "unreleased"
            frag.mkdir(parents=True)
            (frag / "README.md").write_text("keep\n", encoding="utf-8")
            (frag / "pr-first.md").write_text(
                "### Fixes\n- first cut only\n\n### Dev notes\n- hidden first\n",
                encoding="utf-8",
            )
            changelog = root / "CHANGELOG.md"
            changelog.write_text(
                "# Changelog\n\n## Unreleased\n\n"
                "### Features\n- leftover first\n\n"
                "## 0.4.2-dev+56 (2026-08-13)\n\n### Player\n- old cut\n",
                encoding="utf-8",
            )
            first_md = self.mod.assemble_changelog_markdown(
                changelog.read_text(encoding="utf-8"),
                fragments_dir=frag,
            )
            first = self.mod.public_changelog_from_markdown(
                first_md,
                version_name="0.4.2-dev",
                version_code=58,
                published_date="2026-08-13",
            )
            self.assertTrue(first.startswith("## 0.4.2-dev+58 (2026-08-13)"))
            self.assertIn("- first cut only", first)
            self.assertIn("- leftover first", first)

            result = self.mod.consume_unreleased_after_publish(
                version_name="0.4.2-dev",
                version_code=58,
                published_date="2026-08-13",
                changelog_path=changelog,
                fragments_dir=frag,
            )
            self.assertTrue(result["folded"])
            self.assertEqual(result["deleted"], ["pr-first.md"])
            self.assertTrue((frag / "README.md").is_file())
            self.assertFalse((frag / "pr-first.md").exists())

            after = changelog.read_text(encoding="utf-8")
            self.assertIn("## 0.4.2-dev+58 (2026-08-13)", after)
            self.assertIn("- first cut only", after)
            self.assertIn("- leftover first", after)
            self.assertIn("### Dev notes", after)
            self.assertEqual(
                self.mod.extract_unreleased_body(after).strip(),
                "",
            )

            (frag / "pr-second.md").write_text(
                "### Fixes\n- second cut only\n",
                encoding="utf-8",
            )
            second_md = self.mod.assemble_changelog_markdown(
                changelog.read_text(encoding="utf-8"),
                fragments_dir=frag,
            )
            second = self.mod.public_changelog_from_markdown(
                second_md,
                version_name="0.4.2-dev",
                version_code=59,
                published_date="2026-08-13",
            )
            self.assertTrue(second.startswith("## 0.4.2-dev+59 (2026-08-13)"))
            self.assertIn("- second cut only", second)
            self.assertNotIn("- first cut only", second.split("## 0.4.2-dev+58")[0])
            self.assertNotIn("- leftover first", second.split("## 0.4.2-dev+58")[0])
            # Prior cut remains in history below this cut's heading.
            self.assertIn("## 0.4.2-dev+58 (2026-08-13)", second)
            self.assertIn("- first cut only", second)

    def test_empty_unreleased_still_emits_this_cut_heading(self):
        md = (
            "# Changelog\n\n## Unreleased\n\n"
            "## 0.4.2-dev+59 (2026-08-13)\n\n### Fixes\n- prior\n"
        )
        out = self.mod.public_changelog_from_markdown(
            md,
            version_name="0.4.2-dev",
            version_code=60,
            published_date="2026-08-13",
        )
        self.assertTrue(out.startswith("## 0.4.2-dev+60 (2026-08-13)"))
        self.assertIn("## 0.4.2-dev+59 (2026-08-13)", out)
        self.assertIn("- prior", out)

    def test_stable_same_lineage_folds_dev_under_cut_heading(self):
        """Merge from dev leaves ## 0.5.1-dev+N; stable publish must not emit
        an empty ## 0.5.1+N ahead of it (Discord would announce only the H2)."""
        md = (
            "# Changelog\n\n## Unreleased\n\n"
            "## 0.5.1-dev+64 (2026-08-13)\n\n"
            "### Features\n- Cast to TVs.\n\n"
            "### Fixes\n- Android TV Back stays in-app.\n\n"
            "### Dev notes\n- hidden\n"
        )
        out = self.mod.public_changelog_from_markdown(
            md,
            version_name="0.5.1",
            version_code=64,
            published_date="2026-08-13",
        )
        self.assertTrue(out.startswith("## 0.5.1+64 (2026-08-13)"))
        self.assertIn("- Cast to TVs.", out)
        self.assertIn("- Android TV Back stays in-app.", out)
        self.assertNotIn("## 0.5.1-dev+64", out)
        self.assertNotIn("hidden", out)
        # Single stable cut — no second version H2 after the fold.
        self.assertEqual(sum(1 for line in out.splitlines() if line.startswith("## ")), 1)

    def test_check_unreleased_blocks_shared_edits_but_allows_version_cut(self):
        base = "# Changelog\n\n## Unreleased\n\n### Fixes\n- old\n\n## 0.4.2-dev+55\n\n- shipped\n"
        head_conflict = "# Changelog\n\n## Unreleased\n\n### Fixes\n- old\n- new shared edit\n\n## 0.4.2-dev+55\n\n- shipped\n"
        errors = self.mod.check_unreleased_not_edited(base, head_conflict)
        self.assertTrue(errors)
        self.assertIn("changelog/unreleased", errors[0])
        head_cut = (
            "# Changelog\n\n## Unreleased\n\n## 0.4.3-dev+60\n\n### Fixes\n- old\n\n"
            "## 0.4.2-dev+55\n\n- shipped\n"
        )
        self.assertEqual(self.mod.check_unreleased_not_edited(base, head_cut), [])
        self.assertEqual(self.mod.check_unreleased_not_edited(base, base), [])
        # Consume under the same marketing line (0.4.2-dev+59) — Unreleased emptied.
        head_consume = (
            "# Changelog\n\n## Unreleased\n\n## 0.4.2-dev+59 (2026-08-13)\n\n"
            "### Fixes\n- old\n\n## 0.4.2-dev+55\n\n- shipped\n"
        )
        self.assertEqual(self.mod.check_unreleased_not_edited(base, head_consume), [])

    def test_resolve_changelog_uses_assembled_unreleased(self):
        md = self.mod.assemble_changelog_markdown(
            "# Changelog\n\n## Unreleased\n\n### Fixes\n- leftover\n\n## 0.4.2-dev+1\n\n- prior\n",
            fragment_texts=["### Fixes\n- from fragment\n\n### Dev notes\n- secret\n"],
        )
        out = self.mod.resolve_changelog(
            "Dev build @ dev",
            version_name="0.4.2-dev",
            auto=True,
            channel="dev",
            changelog_md=md,
        )
        self.assertIn("leftover", out)
        self.assertIn("from fragment", out)
        self.assertNotIn("secret", out)
        self.assertNotIn("Dev notes", out)


    def test_plan_stable_dev_rollup_detects_marketing_bump(self):
        md = """# Changelog

## Unreleased

## 0.5.0+58 (2026-08-13)

### Fixes

- only three crumbs from Unreleased

## 0.4.3+57 (2026-08-12)

### Fixes

- patch on main while dev continued

## 0.4.2-dev+62 (2026-08-13)

### Features

- big feature A
- big feature B

## 0.4.2-dev+50 (2026-08-12)

### Fixes

- fix C
- fix D
- fix E
- fix F
- fix G
- fix H
- fix I
- fix J

## 0.4.1+40 (2026-08-01)

### Fixes

- ancient
"""
        plan = self.mod.plan_stable_dev_rollup(md, "0.5.0")
        self.assertIsNotNone(plan)
        assert plan is not None
        self.assertEqual(plan["since_dev"], "0.4.2-dev")
        self.assertEqual(plan["min_code"], 50)
        self.assertEqual(plan["max_code"], 62)
        self.assertEqual(plan["also_sections"], ["0.4.3+57"])
        thin, matching, orphan = self.mod.stable_changelog_is_thin(md, "0.5.0")
        self.assertTrue(thin)
        self.assertLess(matching, 5)
        self.assertGreaterEqual(orphan, 8)

        updated, bullets = self.mod.apply_stable_dev_rollup(
            md, stable_version="0.5.0", version_code=58, plan=plan
        )
        self.assertGreaterEqual(bullets, 10)
        thin_after, matching_after, _orphan_after = self.mod.stable_changelog_is_thin(
            updated, "0.5.0"
        )
        self.assertFalse(thin_after)
        self.assertGreaterEqual(matching_after, 10)
        self.assertIn("big feature A", updated)
        self.assertIn("only three crumbs from Unreleased", updated)
        self.assertIn("## 0.5.0+58", updated)

    def test_stable_rollup_consumes_fragments_so_publish_is_not_thin(self):
        """Rolled public notes must not be duplicated under a retitled Unreleased."""
        md = """# Changelog

## Unreleased

## 0.5.0+1 (2026-08-13)

### Fixes

- crumb

## 0.4.2-dev+5 (2026-08-13)

### Features

- a1
- a2
- a3
- a4
- a5
- a6
- a7
- a8
- a9
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "CHANGELOG.md"
            path.write_text(md, encoding="utf-8")
            frag = root / "changelog" / "unreleased"
            frag.mkdir(parents=True)
            (frag / "pr-crumb.md").write_text(
                "### Fixes\n- fragment crumb\n\n"
                "### Dev notes\n- keep me in git\n",
                encoding="utf-8",
            )
            result = self.mod.ensure_stable_changelog_rollup(
                version_name="0.5.0",
                version_code=1,
                changelog_path=path,
                fragments_dir=frag,
                write=True,
                auto=True,
            )
            self.assertEqual(result["action"], "rolled")
            self.assertFalse((frag / "pr-crumb.md").exists())
            written = path.read_text(encoding="utf-8")
            self.assertIn("keep me in git", written)
            self.assertIn("fragment crumb", written)
            assembled = self.mod.assemble_changelog_markdown(
                written, fragments_dir=frag
            )
            public = self.mod.public_changelog_from_markdown(
                assembled,
                version_name="0.5.0",
                version_code=1,
                published_date="2026-08-13",
            )
            # First H2 is the full rolled cut — not a thin fragment-only block.
            self.assertRegex(public, r"^## 0\.5\.0\+1 \(\d{4}-\d{2}-\d{2}\)")
            self.assertIn("- a1", public)
            self.assertIn("- fragment crumb", public)
            self.assertEqual(public.count("## 0.5.0+1"), 1)
            # Must not emit a second retitled crumb heading before the roll-up.
            self.assertNotIn("Dev notes", public)

    def test_consume_merges_into_existing_cut_heading(self):
        """Existing ## version+build must still receive Dev notes / late fragments."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            frag = root / "changelog" / "unreleased"
            frag.mkdir(parents=True)
            (frag / "pr-late.md").write_text(
                "### Fixes\n- already rolled public\n\n"
                "### Dev notes\n- must survive consume\n",
                encoding="utf-8",
            )
            changelog = root / "CHANGELOG.md"
            changelog.write_text(
                "# Changelog\n\n## Unreleased\n\n"
                "## 0.5.0+58 (2026-08-13)\n\n"
                "### Fixes\n- already rolled public\n- from orphan -dev\n",
                encoding="utf-8",
            )
            result = self.mod.consume_unreleased_after_publish(
                version_name="0.5.0",
                version_code=58,
                published_date="2026-08-13",
                changelog_path=changelog,
                fragments_dir=frag,
            )
            self.assertTrue(result["folded"])
            self.assertEqual(result["deleted"], ["pr-late.md"])
            after = changelog.read_text(encoding="utf-8")
            self.assertIn("### Dev notes", after)
            self.assertIn("- must survive consume", after)
            self.assertEqual(after.count("- already rolled public"), 1)
            self.assertEqual(
                self.mod.extract_unreleased_body(after).strip(),
                "",
            )

    def test_plan_stable_dev_rollup_skips_same_lineage(self):
        md = """# Changelog

## Unreleased

## 0.4.2-dev+10 (2026-08-13)

### Fixes

- one
- two
"""
        self.assertIsNone(self.mod.plan_stable_dev_rollup(md, "0.4.2"))
        thin, _m, orphan = self.mod.stable_changelog_is_thin(md, "0.4.2")
        self.assertFalse(thin)
        self.assertEqual(orphan, 0)

    def test_plan_stable_dev_rollup_skips_prior_patch_on_same_xy(self):
        """0.5.1 must not re-roll 0.5.0 (+ older -dev already shipped there)."""
        md = """# Changelog

## Unreleased

## 0.5.1+64 (2026-08-13)

### Features

- Cast to TVs.
- Catalog popular sort.

### Fixes

- Android TV Back stays in-app.

## 0.5.0+58 (2026-08-13)

### Fixes

- prior stable note A
- prior stable note B

## 0.4.2-dev+62 (2026-08-13)

### Features

- a1
- a2
- a3
- a4
- a5
- a6
- a7
- a8
- a9
"""
        self.assertIsNone(self.mod.plan_stable_dev_rollup(md, "0.5.1"))
        thin, matching, orphan = self.mod.stable_changelog_is_thin(md, "0.5.1")
        self.assertFalse(thin)
        self.assertGreaterEqual(matching, 3)
        self.assertEqual(orphan, 0)

    def test_ensure_stable_changelog_rollup_writes(self):
        import tempfile
        from pathlib import Path

        md = """# Changelog

## Unreleased

## 0.5.0+1 (2026-08-13)

### Fixes

- crumb

## 0.4.2-dev+5 (2026-08-13)

### Features

- a1
- a2
- a3
- a4
- a5
- a6
- a7
- a8
- a9
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "CHANGELOG.md"
            path.write_text(md, encoding="utf-8")
            result = self.mod.ensure_stable_changelog_rollup(
                version_name="0.5.0",
                version_code=1,
                changelog_path=path,
                write=True,
                auto=True,
            )
            self.assertEqual(result["action"], "rolled")
            written = path.read_text(encoding="utf-8")
            self.assertIn("a1", written)
            self.assertIn("## 0.5.0+1", written)

    def test_fallback_when_no_git_history(self):
        self.mod.build_git_changelog = lambda **_: ""  # type: ignore[method-assign]
        out = self.mod.resolve_changelog("", version_name="0.2.0", auto=True)
        self.assertEqual(out, "JAVP 0.2.0")

    def test_dev_placeholder_uses_dev_scoped_auto_not_stable_dump(self):
        dev_auto = "This Dev build:\n- fix: one thing"
        self.mod.build_dev_git_changelog = lambda **_: dev_auto  # type: ignore[method-assign]
        self.mod.build_git_changelog = lambda **_: (  # type: ignore[method-assign]
            "What's new since v0.4.0:\n- old cumulative"
        )
        out = self.mod.resolve_changelog(
            "Dev build @ dev",
            version_name="0.4.1-dev",
            auto=True,
            channel="dev",
        )
        self.assertEqual(out, dev_auto)
        self.assertNotIn("What's new since v0.4.0", out)

    def test_dev_explicit_note_skips_auto_append(self):
        self.mod.build_dev_git_changelog = lambda **_: "This Dev build:\n- x"  # type: ignore[method-assign]
        explicit = "Dev build (2 changes):\n\n- feat: A\n- fix: B"
        out = self.mod.resolve_changelog(
            explicit,
            version_name="0.4.1-dev",
            auto=True,
            channel="dev",
        )
        self.assertEqual(out, explicit)

    def test_dev_placeholder_detection(self):
        self.assertTrue(self.mod.is_dev_changelog_placeholder("Dev build @ dev"))
        self.assertTrue(self.mod.is_dev_changelog_placeholder("Dev build (bot-triggered)"))
        self.assertFalse(
            self.mod.is_dev_changelog_placeholder("Dev build:\n\n- fix: thing")
        )


class CollectApksTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_collects_split_and_universal(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "app-arm64-v8a-release.apk").write_bytes(b"a")
            (d / "app-armeabi-v7a-release.apk").write_bytes(b"b")
            (d / "app-x86_64-release.apk").write_bytes(b"c")
            (d / "app-release.apk").write_bytes(b"u")
            found = self.mod.collect_apks(d, require_universal=True)
            # x86_64 is deliberately left on disk and out of the manifest: those
            # devices resolve to the universal APK instead of a dedicated split.
            self.assertEqual(set(found), {"arm64-v8a", "armeabi-v7a", "universal"})
            self.assertEqual(found["arm64-v8a"][1], "javp-arm64-v8a.apk")
            self.assertEqual(found["universal"][1], "javp.apk")

    def test_splits_only_ok_without_universal(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "app-arm64-v8a-release.apk").write_bytes(b"a")
            found = self.mod.collect_apks(d, require_universal=False)
            self.assertEqual(set(found), {"arm64-v8a"})

    def test_collects_sideload_dev_flavor_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "app-sideloadDev-arm64-v8a-release.apk").write_bytes(b"a")
            (d / "app-sideloadDev-release.apk").write_bytes(b"u")
            found = self.mod.collect_apks(
                d,
                require_universal=True,
                flavor="sideloadDev",
            )
            self.assertEqual(set(found), {"arm64-v8a", "universal"})
            self.assertEqual(found["arm64-v8a"][1], "javp-arm64-v8a.apk")

    def test_collects_flavor_abi_sideload_dev_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "app-arm64-v8a-sideloadDev-release.apk").write_bytes(b"a")
            found = self.mod.collect_apks(
                d,
                require_universal=False,
                flavor="sideloadDev",
            )
            self.assertEqual(set(found), {"arm64-v8a"})


class PublicChangelogFilterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_skips_internal_tooling_paths(self):
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Fix Cursor Cloud Dockerfile: install sudo for VM bootstrap.",
                [".cursor/Dockerfile", "AGENTS.md"],
            )
        )
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Fix Dev APK signing check for sideloadDev flavor names.",
                ["tool/deploy_update.py", "tool/local_release.sh"],
            )
        )
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "docs: explain hybrid releases",
                ["docs/updates.md"],
            )
        )
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "chore: tweak CI matrix",
                [".github/workflows/deploy-update.yml"],
            )
        )

    def test_skips_version_bump_and_spoiler_subjects(self):
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Bump to 0.3.3+38 for Dev channel publish.",
                ["pubspec.yaml", "lib/services/serializd/serializd_client.dart"],
            )
        )
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Ship Projectionist Mode easter egg in 0.3.2 and fix Sources l10n.",
                ["lib/screens/about_screen.dart"],
            )
        )
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Keep Projectionist Mode out of public release notes.",
                ["CHANGELOG.md"],
            )
        )

    def test_keeps_user_facing_app_commits(self):
        self.assertTrue(
            self.mod.is_public_changelog_commit(
                "Fix My List UI not refreshing after add/remove.",
                ["lib/providers/library_provider.dart", "test/unit/library_reappear_test.dart"],
            )
        )
        self.assertTrue(
            self.mod.is_public_changelog_commit(
                "Show safe Discord Rich Presence posters (Lunar-style).",
                [
                    "lib/services/discord/discord_presence_artwork.dart",
                    "test/unit/discord_presence_artwork_test.dart",
                ],
            )
        )
        # App Discord RP stays; separate Discord bot/infra does not.
        self.assertFalse(
            self.mod.is_public_changelog_commit(
                "Tune javp-discord idea review prompts",
                ["docs/develop.md"],
            )
        )

    def test_parse_git_log_with_paths(self):
        raw = (
            "Fix My List UI\n"
            "lib/providers/library_provider.dart\n"
            "test/unit/library_reappear_test.dart\n"
            "\n"
            "Fix Cursor Cloud Dockerfile\n"
            ".cursor/Dockerfile\n"
            "AGENTS.md\n"
        )
        parsed = self.mod._parse_git_log_with_paths(raw)
        self.assertEqual(
            parsed,
            [
                (
                    "Fix My List UI",
                    [
                        "lib/providers/library_provider.dart",
                        "test/unit/library_reappear_test.dart",
                    ],
                ),
                (
                    "Fix Cursor Cloud Dockerfile",
                    [".cursor/Dockerfile", "AGENTS.md"],
                ),
            ],
        )

    def test_build_git_changelog_filters_merges_and_noise(self):
        mod = load_module()
        text = mod.build_git_changelog(max_commits=20)
        if not text:
            self.skipTest("no git history available")
        self.assertTrue(text.startswith("What's new"))
        for line in text.splitlines()[1:]:
            self.assertTrue(line.startswith("- "))
            lower = line.lower()
            self.assertFalse(lower.startswith("- merge "))
            self.assertNotIn("cursor cloud", lower)
            self.assertNotIn("bump to ", lower)
            self.assertNotIn("projectionist mode", lower)
            self.assertNotIn("deploy_update", lower)
            self.assertNotIn("local_release", lower)


class ChannelPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_stable_stays_at_root(self):
        self.assertEqual(self.mod.normalize_channel("stable"), "stable")
        self.assertEqual(self.mod.channel_remote_prefix("stable"), "")
        self.assertEqual(self.mod.channel_android_flavor("stable"), "sideload")
        self.assertEqual(
            self.mod.channel_manifest_url("https://updater.javp.app", "stable"),
            "https://updater.javp.app/latest.json",
        )
        self.assertEqual(
            self.mod.channel_apk_url("https://updater.javp.app/", "stable"),
            "https://updater.javp.app/javp.apk",
        )
        self.assertEqual(
            self.mod.channel_apk_url(
                "https://updater.javp.app",
                "stable",
                "javp-arm64-v8a.apk",
            ),
            "https://updater.javp.app/javp-arm64-v8a.apk",
        )

    def test_dev_uses_subdirectory(self):
        self.assertEqual(self.mod.normalize_channel("development"), "dev")
        self.assertEqual(self.mod.channel_remote_prefix("dev"), "dev/")
        self.assertEqual(self.mod.channel_android_flavor("dev"), "sideloadDev")
        self.assertEqual(
            self.mod.channel_manifest_url("https://updater.javp.app", "dev"),
            "https://updater.javp.app/dev/latest.json",
        )
        self.assertEqual(
            self.mod.channel_apk_url("https://updater.javp.app", "dev"),
            "https://updater.javp.app/dev/javp.apk",
        )
        self.assertEqual(
            self.mod.channel_apk_url(
                "https://updater.javp.app",
                "dev",
                "javp-arm64-v8a.apk",
            ),
            "https://updater.javp.app/dev/javp-arm64-v8a.apk",
        )

    def test_manifest_includes_channel(self):
        payload = self.mod.build_manifest(
            version_name="0.1.0-dev",
            version_code=2,
            apk_url="https://updater.javp.app/dev/javp-arm64-v8a.apk",
            changelog="notes",
            force=False,
            min_version_code=None,
            apk_sha256=None,
            channel="dev",
            releases=[
                {
                    "versionName": "0.1.0-dev",
                    "versionCode": 2,
                    "title": "0.1.0-dev+2",
                    "notes": "notes",
                }
            ],
        )
        self.assertEqual(payload["channel"], "dev")
        self.assertEqual(payload["releases"][0]["versionCode"], 2)
        self.assertEqual(
            payload["apkUrl"],
            "https://updater.javp.app/dev/javp-arm64-v8a.apk",
        )

    def test_channel_build_args(self):
        stable = self.mod.channel_build_args("stable")
        self.assertIn("sideload", stable)
        self.assertIn("--dart-define=JAVP_DISTRIBUTION=sideload", stable)
        self.assertIn("--dart-define=JAVP_UPDATE_CHANNEL=stable", stable)

        dev = self.mod.channel_build_args("dev")
        self.assertIn("sideloadDev", dev)
        self.assertIn("--dart-define=JAVP_DISTRIBUTION=sideload", dev)
        self.assertIn("--dart-define=JAVP_UPDATE_CHANNEL=dev", dev)

    def test_remote_tmp_keeps_subdir(self):
        self.assertEqual(
            self.mod._remote_tmp_name("dev/latest.json"),
            "dev/.latest.json.uploading",
        )
        self.assertEqual(
            self.mod._remote_tmp_name("javp.apk"),
            ".javp.apk.uploading",
        )

    def test_stamp_download_page_fills_channel(self):
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "download.html"
            out = self.mod.stamp_download_page("dev", dest)
            text = out.read_text(encoding="utf-8")
            self.assertIn('var CHANNEL_STAMP = "dev";', text)
            self.assertNotIn("__JAVP_CHANNEL__", text)

            dest_stable = Path(tmp) / "stable.html"
            stable = self.mod.stamp_download_page("stable", dest_stable)
            self.assertIn('var CHANNEL_STAMP = "stable";', stable.read_text(encoding="utf-8"))


class ArtifactGitCommitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_manifest_only_keeps_live_sha_not_head(self):
        live = {"gitCommit": "a" * 40, "baseVersionCode": 55}
        head = "b" * 40
        out = self.mod.resolve_artifact_git_commit(
            channel="dev",
            head=head,
            explicit=None,
            sidecar_commit=None,
            live=live,
            hashes_match_live=True,
            built_now=False,
            manifest_only=True,
        )
        self.assertEqual(out, "a" * 40)

    def test_same_hash_republish_keeps_live_sha(self):
        live = {"gitCommit": "a" * 40}
        out = self.mod.resolve_artifact_git_commit(
            channel="dev",
            head="b" * 40,
            explicit=None,
            sidecar_commit=None,
            live=live,
            hashes_match_live=True,
            built_now=False,
            manifest_only=False,
        )
        self.assertEqual(out, "a" * 40)

    def test_sidecar_wins_over_head(self):
        out = self.mod.resolve_artifact_git_commit(
            channel="dev",
            head="b" * 40,
            explicit=None,
            sidecar_commit="c" * 40,
            live={"gitCommit": "a" * 40},
            hashes_match_live=False,
            built_now=True,
            manifest_only=False,
        )
        self.assertEqual(out, "c" * 40)

    def test_explicit_git_commit_wins(self):
        out = self.mod.resolve_artifact_git_commit(
            channel="dev",
            head="b" * 40,
            explicit="d" * 40,
            sidecar_commit="c" * 40,
            live={"gitCommit": "a" * 40},
            hashes_match_live=True,
            built_now=False,
            manifest_only=True,
        )
        self.assertEqual(out, "d" * 40)

    def test_refuse_same_version_different_tree(self):
        live = {"gitCommit": "a" * 40, "baseVersionCode": 55}
        err = self.mod.same_version_overwrite_error(
            channel="dev",
            version_code=55,
            artifact_git_commit="b" * 40,
            live=live,
            hashes_match_live=False,
            manifest_only=False,
            allow=False,
        )
        self.assertIsNotNone(err)
        self.assertIn("Refusing to overwrite", err)

    def test_allow_same_version_when_hashes_match(self):
        live = {"gitCommit": "a" * 40, "baseVersionCode": 55}
        err = self.mod.same_version_overwrite_error(
            channel="dev",
            version_code=55,
            artifact_git_commit="b" * 40,
            live=live,
            hashes_match_live=True,
            manifest_only=False,
            allow=False,
        )
        self.assertIsNone(err)

    def test_new_build_number_ok(self):
        live = {"gitCommit": "a" * 40, "baseVersionCode": 55}
        err = self.mod.same_version_overwrite_error(
            channel="dev",
            version_code=56,
            artifact_git_commit="b" * 40,
            live=live,
            hashes_match_live=False,
            manifest_only=False,
            allow=False,
        )
        self.assertIsNone(err)

    def test_overlay_keeps_apks_and_can_fix_sha(self):
        live = {
            "versionName": "0.4.2-dev",
            "baseVersionCode": 55,
            "gitCommit": "b" * 40,
            "apks": {"arm64-v8a": {"url": "https://example/a.apk", "sha256": "ff"}},
            "changelog": "old",
        }
        out = self.mod.apply_manifest_only_overlay(
            live,
            changelog="new notes",
            git_commit="a" * 40,
            releases=[
                {
                    "versionName": "0.4.2-dev",
                    "versionCode": 55,
                    "title": "0.4.2-dev+55",
                    "notes": "new notes",
                }
            ],
        )
        self.assertEqual(out["changelog"], "new notes")
        self.assertEqual(out["releases"][0]["notes"], "new notes")
        self.assertEqual(out["gitCommit"], "a" * 40)
        self.assertEqual(out["apks"]["arm64-v8a"]["url"], "https://example/a.apk")
        self.assertEqual(out["baseVersionCode"], 55)

    def test_hashes_match_live(self):
        live = {
            "apks": {
                "arm64-v8a": {"sha256": "ABC"},
                "universal": {"sha256": "def"},
            }
        }
        local = {
            "arm64-v8a": {"sha256": "abc"},
            "universal": {"sha256": "DEF"},
        }
        self.assertTrue(self.mod.artifact_hashes_match_live(local, live))
        local["universal"]["sha256"] = "000"
        self.assertFalse(self.mod.artifact_hashes_match_live(local, live))


class MergeLivePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_merge_adds_linux_without_dropping_apks(self):
        live = {
            "versionName": "0.4.2",
            "gitCommit": "a" * 40,
            "apks": {"arm64-v8a": {"url": "https://example/a.apk"}},
            "packages": {
                "windows-x64": {
                    "url": "https://updater.javp.app/javp-0.4.2+56-windows-x64.zip",
                    "sha256": "w" * 64,
                    "kind": "zip",
                }
            },
        }
        out = self.mod.merge_live_package(
            live,
            key="linux-x64",
            url="https://updater.javp.app/javp-0.4.2+56-linux-x64.zip",
            sha256="b" * 64,
            kind="zip",
        )
        self.assertEqual(out["gitCommit"], "a" * 40)
        self.assertEqual(out["apks"]["arm64-v8a"]["url"], "https://example/a.apk")
        self.assertEqual(
            out["packages"]["windows-x64"]["url"],
            "https://updater.javp.app/javp-0.4.2+56-windows-x64.zip",
        )
        self.assertEqual(
            out["packages"]["linux-x64"],
            {
                "url": "https://updater.javp.app/javp-0.4.2+56-linux-x64.zip",
                "sha256": "b" * 64,
                "kind": "zip",
            },
        )
        self.assertNotIn("linux-x64", live.get("packages") or {})

    def test_merge_replaces_existing_linux_entry(self):
        live = {
            "packages": {
                "linux-x64": {
                    "url": "https://old/linux.zip",
                    "sha256": "c" * 64,
                    "kind": "zip",
                }
            }
        }
        out = self.mod.merge_live_package(
            live,
            key="linux-x64",
            url="https://new/linux.zip",
            sha256="d" * 64,
            kind="zip",
        )
        self.assertEqual(out["packages"]["linux-x64"]["url"], "https://new/linux.zip")
        self.assertEqual(out["packages"]["linux-x64"]["sha256"], "d" * 64)


class VersionedCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_parse_apk_and_desktop(self):
        self.assertEqual(
            self.mod.parse_versioned_artifact("javp-0.2.28+30.apk"),
            ("0.2.28", 30),
        )
        self.assertEqual(
            self.mod.parse_versioned_artifact("javp-arm64-v8a-0.2.28+30.apk"),
            ("0.2.28", 30),
        )
        self.assertEqual(
            self.mod.parse_versioned_artifact("javp-0.2.28+30-windows-x64.zip"),
            ("0.2.28", 30),
        )
        self.assertEqual(
            self.mod.parse_versioned_artifact("javp-0.2.29-dev+31-macos-arm64.zip"),
            ("0.2.29-dev", 31),
        )
        self.assertEqual(
            self.mod.parse_versioned_artifact("javp-0.4.2+56-macos-x64.zip"),
            ("0.4.2", 56),
        )

    def test_parse_ignores_short_names(self):
        for name in (
            "javp.apk",
            "javp-arm64-v8a.apk",
            "javp-windows-x64.zip",
            "javp-macos-arm64.zip",
            "javp-macos-x64.zip",
            "javp-setup.exe",
            "latest.json",
            "index.html",
        ):
            self.assertIsNone(self.mod.parse_versioned_artifact(name), name)

    def test_plan_keeps_newest_three_releases(self):
        names = [
            "javp.apk",
            "javp-arm64-v8a.apk",
            "latest.json",
            # code 28
            "javp-0.2.26+28.apk",
            "javp-arm64-v8a-0.2.26+28.apk",
            "javp-0.2.26+28-windows-x64.zip",
            # code 29
            "javp-0.2.27+29.apk",
            "javp-arm64-v8a-0.2.27+29.apk",
            # code 30
            "javp-0.2.28+30.apk",
            "javp-arm64-v8a-0.2.28+30.apk",
            "javp-0.2.28+30-linux-x64.zip",
            # code 31
            "javp-0.2.29+31.apk",
            "javp-arm64-v8a-0.2.29+31.apk",
            "javp-0.2.29+31-setup.exe",
        ]
        to_delete = self.mod.plan_versioned_cleanup(names, keep=3)
        # Keep 31, 30, 29 — delete only 28
        self.assertEqual(
            to_delete,
            [
                "javp-0.2.26+28-windows-x64.zip",
                "javp-0.2.26+28.apk",
                "javp-arm64-v8a-0.2.26+28.apk",
            ],
        )
        for short in ("javp.apk", "javp-arm64-v8a.apk", "latest.json"):
            self.assertNotIn(short, to_delete)

    def test_plan_keep_one(self):
        names = [
            "javp-0.2.27+29.apk",
            "javp-0.2.28+30.apk",
            "javp-0.2.29+31.apk",
        ]
        self.assertEqual(
            self.mod.plan_versioned_cleanup(names, keep=1),
            ["javp-0.2.27+29.apk", "javp-0.2.28+30.apk"],
        )

    def test_plan_rejects_keep_zero(self):
        with self.assertRaises(ValueError):
            self.mod.plan_versioned_cleanup(["javp-0.2.28+30.apk"], keep=0)

    def test_plan_keeps_codes_still_in_releases(self):
        names = [
            "javp-0.2.26+28.apk",
            "javp-arm64-v8a-0.2.26+28.apk",
            "javp-0.2.27+29.apk",
            "javp-0.2.28+30.apk",
            "javp-0.2.29+31.apk",
        ]
        to_delete = self.mod.plan_versioned_cleanup(
            names,
            keep=3,
            protected_codes={28},
        )
        # Newest three (31, 30, 29) plus protected 28 all survive.
        self.assertEqual(to_delete, [])

    def test_release_version_codes_collects_integer_codes(self):
        releases = [
            {"versionName": "0.5.1-dev", "versionCode": 67},
            {"versionName": "0.5.1-dev", "versionCode": 50},
            {"versionName": "0.4.2-dev"},  # marketing-only, no code
        ]
        self.assertEqual(self.mod.release_version_codes(releases), {67, 50})

    def test_release_version_codes_empty_and_non_list(self):
        self.assertEqual(self.mod.release_version_codes(None), set())
        self.assertEqual(self.mod.release_version_codes([]), set())


if __name__ == "__main__":
    unittest.main()
