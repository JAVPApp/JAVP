#!/usr/bin/env python3
"""Unit checks for play_publish.py helpers."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tool" / "play_publish.py"


def load_module():
    spec = importlib.util.spec_from_file_location("play_publish", MODULE_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CommitEditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_commit_edit_sets_changes_not_sent_for_review(self) -> None:
        commit = mock.Mock()
        commit.execute.return_value = {"id": "edit-1"}
        edits = mock.Mock()
        edits.commit.return_value = commit

        self.mod._commit_edit(edits, "com.javp.javp", "edit-1")

        edits.commit.assert_called_once_with(
            packageName="com.javp.javp",
            editId="edit-1",
            changesNotSentForReview=True,
        )
        commit.execute.assert_called_once_with()


if __name__ == "__main__":
    raise SystemExit(unittest.main())
