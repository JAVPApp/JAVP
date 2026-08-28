#!/usr/bin/env python3
"""Structural contracts for deploy/download.html (updater.javp.app)."""

from __future__ import annotations

import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = ROOT / "deploy" / "download.html"
DEPLOY_UPDATE = ROOT / "tool" / "deploy_update.py"


def load_deploy_update():
    spec = importlib.util.spec_from_file_location("deploy_update", DEPLOY_UPDATE)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def html_without_script(html: str) -> str:
    return re.sub(r"<script\b[^>]*>.*?</script>", "", html, flags=re.I | re.S)


class DownloadPageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = DOWNLOAD.read_text(encoding="utf-8")
        cls.mod = load_deploy_update()
        cls.static = html_without_script(cls.html)

    def test_channel_stamp_present(self):
        self.assertIn('var CHANNEL_STAMP = "__JAVP_CHANNEL__";', self.html)
        self.assertIn('data-channel="__JAVP_CHANNEL__"', self.html)

    def test_os_tabs_cover_all_platforms(self):
        for os_id in ("android", "windows", "linux", "macos"):
            self.assertIn(f'id="os-{os_id}"', self.html)
            self.assertIn(f'data-os="{os_id}"', self.html)
            self.assertIn(f'id="tab-{os_id}"', self.html)
            self.assertIn(f'id="panel-{os_id}"', self.html)

    def test_radios_drive_panels_with_css(self):
        self.assertIn("#os-android:checked ~ #panel-android", self.html)
        self.assertIn("#os-windows:checked ~ #panel-windows", self.html)
        self.assertIn("#os-linux:checked ~ #panel-linux", self.html)
        self.assertIn("#os-macos:checked ~ #panel-macos", self.html)
        self.assertIn(".hero {\n      display: none;", self.html)

    def test_static_links_work_without_javascript(self):
        self.assertIn('type="radio"', self.static)
        self.assertIn('href="javp-arm64-v8a.apk"', self.static)
        self.assertIn('href="javp.apk"', self.static)
        self.assertIn('href="javp-setup.exe"', self.static)
        self.assertIn("apps.microsoft.com/detail/9P4PMM405RZH", self.static)
        self.assertIn("Get it from Microsoft Store", self.static)
        self.assertIn('href="javp-linux-x64.zip"', self.static)
        self.assertIn('href="javp-macos-arm64.zip"', self.static)
        self.assertNotIn("<noscript>", self.html)

    def test_other_builds_are_details_not_a_wall(self):
        self.assertGreaterEqual(self.static.count("<details"), 3)
        self.assertIn("Other Android builds", self.static)
        self.assertIn("Other Windows builds", self.static)

    def test_script_stays_optional_and_small(self):
        scripts = re.findall(r"<script\b[^>]*>(.*?)</script>", self.html, flags=re.I | re.S)
        self.assertEqual(len(scripts), 1)
        js = scripts[0]
        self.assertLess(len(js), 6000, "keep the enhancement script tiny for old WebViews")
        self.assertNotIn("fetch(", js)
        self.assertIn("XMLHttpRequest", js)
        self.assertIn("parseRequestedOs", js)
        self.assertIn("Trust Android first", js)

    def test_channel_switcher(self):
        self.assertIn('id="channel-stable"', self.html)
        self.assertIn('id="channel-dev"', self.html)
        self.assertIn('href="dev/"', self.html)
        self.assertIn("Early testers (unstable)", self.html)
        self.assertIn("You are on the Dev channel.", self.html)
        self.assertNotIn('aria-label="Release channel"', self.html)

    def test_no_em_dashes(self):
        self.assertNotIn("\u2014", self.html)
        self.assertNotIn("\u2013", self.html)

    def test_missing_platform_copy(self):
        self.assertIn("does not include a", self.html)
        self.assertIn("Get the stable app", self.html)

    def test_no_google_fonts(self):
        self.assertNotIn("fonts.googleapis.com", self.html)

    def test_stamp_download_page_fills_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "download.html"
            out = self.mod.stamp_download_page("dev", dest)
            text = out.read_text(encoding="utf-8")
            self.assertIn('var CHANNEL_STAMP = "dev";', text)
            self.assertIn('data-channel="dev"', text)
            self.assertNotIn("__JAVP_CHANNEL__", text)
            self.assertIn('data-os="linux"', text)

            stable = self.mod.stamp_download_page("stable", Path(tmp) / "stable.html")
            stamped = stable.read_text(encoding="utf-8")
            self.assertIn('var CHANNEL_STAMP = "stable";', stamped)
            self.assertIn('data-channel="stable"', stamped)


if __name__ == "__main__":
    unittest.main()
