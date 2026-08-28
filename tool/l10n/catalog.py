"""Shared helpers for the JAVP localization catalog.

Source of truth is ``lib/l10n/app_en.arb``. Other ``app_<locale>.arb`` files
are translations (Weblate / humans). Missing locale strings fall back to
English in ``flutter gen-l10n`` — they are not build blockers.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Iterable, TypedDict

ROOT = Path(__file__).resolve().parents[2]
ARB_DIR = ROOT / "lib" / "l10n"
EN_ARB = ARB_DIR / "app_en.arb"
# Historical alias: reports / --from-git fallbacks.
SRC = EN_ARB

PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")
# `l10n.foo`, `context.l10n.foo`, `_uiL10n.foo` — not `_l10n.dart` filenames.
L10N_USAGE_RE = re.compile(
    r"(?<![A-Za-z0-9_])[A-Za-z0-9_]*[Ll]10n\.([A-Za-z_][A-Za-z0-9_]*)"
)
APP_LOC_USAGE_RE = re.compile(
    r"AppLocalizations\.of\([^)]*\)\s*\??\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)"
)
# Flutter gen-l10n abstract members: `String get foo;` or `String foo(Object x);`
GENERATED_GETTER_RE = re.compile(
    r"^\s+String (?:get )?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|;)",
    re.MULTILINE,
)
# Filename / import leftovers the usage regex can still pick up.
SKIP_USAGE_KEYS = frozenset({"dart", "yaml", "json", "arb", "xml"})
# Flutter ARB message keys must be valid Dart identifiers.
MESSAGE_KEY_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")


class UntranslatedEntry(TypedDict):
    key: str
    en: str
    status: str  # "missing" | "english_fallback"


def parse_arb(text: str) -> dict:
    data = json.loads(text)
    if not isinstance(data, dict):
        raise SystemExit("ARB must be a JSON object")
    return data


def arb_message_keys(text: str) -> set[str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return set()
    if not isinstance(data, dict):
        return set()
    return {
        key
        for key, value in data.items()
        if isinstance(key, str)
        and not key.startswith("@")
        and isinstance(value, str)
    }


def arb_messages(data: dict) -> dict[str, str]:
    return {
        key: value
        for key, value in data.items()
        if isinstance(key, str)
        and not key.startswith("@")
        and isinstance(value, str)
    }


def list_arb_langs(arb_dir: Path | None = None) -> list[str]:
    directory = arb_dir or ARB_DIR
    langs: list[str] = []
    for path in sorted(directory.glob("app_*.arb")):
        lang = path.stem[len("app_") :]
        if lang:
            langs.append(lang)
    if "en" not in langs:
        raise SystemExit("lib/l10n/app_en.arb is required")
    langs.remove("en")
    return ["en", *langs]


def dump_arb(data: dict) -> str:
    """ARB JSON with ``@@locale`` first and existing key order preserved.

    New keys should be appended (see ``insert_en_message``) so adding one
    English string does not reshuffle the file.
    """
    ordered: dict = {}
    if "@@locale" in data:
        ordered["@@locale"] = data["@@locale"]
    for key, value in data.items():
        if key == "@@locale":
            continue
        ordered[key] = value
    return json.dumps(ordered, ensure_ascii=False, indent=2) + "\n"


def infer_placeholders(english: str) -> dict[str, dict[str, str]]:
    names = PLACEHOLDER_RE.findall(english)
    return {name: {"type": "Object"} for name in names}


def _require_message_key(key: str) -> None:
    if not MESSAGE_KEY_RE.match(key):
        raise ValueError(
            f"invalid key {key!r}: use camelCase starting with a letter "
            "(e.g. searchHistoryHint)"
        )


def _require_english(key: str, english: str) -> None:
    if not isinstance(english, str) or not english.strip():
        raise ValueError(f"{key}: English string must be non-empty")


def get_en_message(data: dict, key: str) -> str:
    """Return the English string for ``key``."""
    _require_message_key(key)
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} is not in app_en.arb")
    return value


def insert_en_message(
    data: dict,
    key: str,
    english: str,
    *,
    description: str | None = None,
) -> dict:
    """Return a copy of an English ARB dict with ``key`` added."""
    _require_message_key(key)
    _require_english(key, english)
    if key in data:
        raise ValueError(
            f"{key} already exists in app_en.arb — "
            f'print it with: python3 tool/l10n/add_en.py {key}\n'
            f'or overwrite with: python3 tool/l10n/add_en.py {key} "new" --update'
        )
    out = dict(data)
    out.setdefault("@@locale", "en")
    out[key] = english
    meta: dict = {}
    if description:
        meta["description"] = description
    placeholders = infer_placeholders(english)
    if placeholders:
        meta["placeholders"] = placeholders
    if meta:
        out[f"@{key}"] = meta
    return out


def update_en_message(
    data: dict,
    key: str,
    english: str,
    *,
    description: str | None = None,
) -> dict:
    """Replace the English string for an existing key. Does not touch locale ARBs."""
    _require_message_key(key)
    _require_english(key, english)
    if key not in data or not isinstance(data.get(key), str):
        raise ValueError(
            f"{key} is not in app_en.arb — add it without --update"
        )
    out = dict(data)
    out[key] = english
    meta_key = f"@{key}"
    existing = out.get(meta_key)
    meta: dict = dict(existing) if isinstance(existing, dict) else {}
    if description:
        meta["description"] = description
    placeholders = infer_placeholders(english)
    if placeholders:
        meta["placeholders"] = placeholders
    elif "placeholders" in meta:
        del meta["placeholders"]
    if meta:
        out[meta_key] = meta
    elif meta_key in out:
        del out[meta_key]
    return out


def catalog_from_arb_texts(arb_texts: dict[str, str]) -> tuple[list[str], dict]:
    """Build the in-memory catalog from locale → ARB JSON text."""
    if "en" not in arb_texts:
        raise SystemExit("English ARB is required")
    en_data = parse_arb(arb_texts["en"])
    en_msgs = arb_messages(en_data)
    if not en_msgs:
        raise SystemExit("app_en.arb has no messages")
    messages: dict = {}
    for key, english in en_msgs.items():
        entry: dict = {"en": english}
        meta = en_data.get(f"@{key}")
        if isinstance(meta, dict):
            if "description" in meta:
                entry["_description"] = meta["description"]
            if "placeholders" in meta:
                entry["_placeholders"] = meta["placeholders"]
        messages[key] = entry
    langs = ["en"] + sorted(lang for lang in arb_texts if lang != "en")
    for lang in langs:
        if lang == "en":
            continue
        loc = arb_messages(parse_arb(arb_texts[lang]))
        for key, entry in messages.items():
            if key in loc:
                entry[lang] = loc[key]
    return langs, messages


def load_catalog_from_legacy_messages_text(text: str) -> tuple[list[str], dict]:
    """Parse the retired messages.json shape (git history / --from-git)."""
    data = json.loads(text)
    langs: list[str] = data["langs"]
    messages: dict = data["messages"]
    if "en" not in langs:
        raise SystemExit("messages.json langs must include 'en'")
    return langs, messages


def load_catalog(*, arb_dir: Path | None = None) -> tuple[list[str], dict]:
    directory = arb_dir or ARB_DIR
    langs = list_arb_langs(directory)
    texts: dict[str, str] = {}
    for lang in langs:
        path = directory / f"app_{lang}.arb"
        texts[lang] = path.read_text(encoding="utf-8")
    return catalog_from_arb_texts(texts)


def check_structure(langs: list[str], messages: dict) -> list[str]:
    """Hard failures: invalid catalog shape, not missing translations."""
    errors: list[str] = []
    if not messages:
        errors.append("app_en.arb has no messages")
        return errors

    for key, entry in messages.items():
        if not isinstance(entry, dict):
            errors.append(f"{key}: entry must be an object")
            continue

        en = entry.get("en")
        if not isinstance(en, str) or not en.strip():
            errors.append(f"{key}: missing non-empty 'en' string")
            continue

        en_placeholders = set(PLACEHOLDER_RE.findall(en))
        declared = set((entry.get("_placeholders") or {}).keys())
        if declared and declared != en_placeholders:
            errors.append(
                f"{key}: _placeholders {sorted(declared)} != "
                f"placeholders in en {sorted(en_placeholders)}"
            )

        for lang in langs:
            if lang == "en":
                continue
            value = entry.get(lang)
            if value is None:
                continue
            if not isinstance(value, str):
                errors.append(f"{key}.{lang}: must be a string")
                continue
            if not value.strip():
                errors.append(f"{key}.{lang}: must be non-empty when present")
                continue
            lang_placeholders = set(PLACEHOLDER_RE.findall(value))
            if lang_placeholders != en_placeholders:
                errors.append(
                    f"{key}.{lang}: placeholders {sorted(lang_placeholders)} "
                    f"!= en {sorted(en_placeholders)}"
                )
    return errors


def collect_dart_l10n_usages(text: str) -> set[str]:
    """Keys referenced as `l10n.foo` or `AppLocalizations.of(...).foo`."""
    used = set(L10N_USAGE_RE.findall(text))
    used.update(APP_LOC_USAGE_RE.findall(text))
    return {key for key in used if key not in SKIP_USAGE_KEYS}


def parse_generated_getters(text: str) -> set[str]:
    """Message getters/methods on the gen-l10n abstract class."""
    return set(GENERATED_GETTER_RE.findall(text or ""))


def dart_l10n_keys_used(
    messages: dict | None = None,
    *,
    lib: Path | None = None,
    dart_texts: Iterable[str] | None = None,
) -> set[str]:
    """All Dart l10n keys referenced outside generated AppLocalizations files."""
    del messages  # catalog is not needed to discover usages
    used: set[str] = set()
    if dart_texts is not None:
        for text in dart_texts:
            used.update(collect_dart_l10n_usages(text))
        return used
    lib_dir = lib or (ROOT / "lib")
    if not lib_dir.is_dir():
        return used
    for path in lib_dir.rglob("*.dart"):
        if path.name.startswith("app_localizations"):
            continue
        used.update(
            collect_dart_l10n_usages(path.read_text(encoding="utf-8", errors="replace"))
        )
    return used


def dart_l10n_keys_missing(
    messages: dict,
    *,
    lib: Path | None = None,
    dart_texts: Iterable[str] | None = None,
) -> list[str]:
    """Dart `l10n.foo` usages that are not in the English ARB catalog."""
    used = dart_l10n_keys_used(messages, lib=lib, dart_texts=dart_texts)
    return sorted(used - set(messages))


def preflight_errors(
    langs: list[str],
    messages: dict,
    *,
    lib: Path | None = None,
    dart_texts: Iterable[str] | None = None,
    generated_dart: str | None = None,
    en_arb: str | None = None,
) -> list[str]:
    """Hard failures: bad English ARB / Dart keys missing from app_en.arb.

    Does not fail on untranslated locales — those fall back to English.
    """
    del generated_dart, en_arb  # generated Dart is gitignored; ARB is SoT
    errors = check_structure(langs, messages)
    used = dart_l10n_keys_used(messages, lib=lib, dart_texts=dart_texts)
    catalog = set(messages)
    for key in sorted(used - catalog):
        errors.append(
            f"Dart uses l10n.{key} but lib/l10n/app_en.arb has no such key. "
            f'Fix: python3 tool/l10n/add_en.py {key} "English string"'
        )
    return errors


def git_show(repo: Path, ref: str, path: str) -> str | None:
    proc = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def git_dart_texts(repo: Path, ref: str) -> list[str]:
    proc = subprocess.run(
        [
            "git",
            "grep",
            "-I",
            "-h",
            "-e",
            r"l10n\.",
            "-e",
            r"AppLocalizations\.of",
            ref,
            "--",
            "lib",
            ":!lib/l10n/app_localizations*.dart",
        ],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if proc.returncode not in (0, 1):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        raise SystemExit(f"git grep failed for {ref}: {err}")
    # git grep -h concatenates matching lines; enough for the usage regex.
    return [proc.stdout] if proc.stdout else []


def git_arb_texts(repo: Path, ref: str) -> dict[str, str]:
    proc = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref, "--", "lib/l10n"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        raise SystemExit(f"git ls-tree failed for {ref}: {err}")
    texts: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        name = Path(line).name
        if not (name.startswith("app_") and name.endswith(".arb")):
            continue
        lang = name[len("app_") : -len(".arb")]
        body = git_show(repo, ref, line)
        if body is not None:
            texts[lang] = body
    return texts


def load_sources_from_git(
    repo: Path, ref: str
) -> tuple[list[str], dict, list[str], str | None, str | None]:
    arb_texts = git_arb_texts(repo, ref)
    if "en" in arb_texts:
        langs, messages = catalog_from_arb_texts(arb_texts)
        en_arb = arb_texts["en"]
    else:
        catalog_text = git_show(repo, ref, "tool/l10n/messages.json")
        if catalog_text is None:
            raise SystemExit(
                f"cannot read lib/l10n/app_en.arb or tool/l10n/messages.json from {ref}"
            )
        langs, messages = load_catalog_from_legacy_messages_text(catalog_text)
        en_arb = None
    dart_texts = git_dart_texts(repo, ref)
    generated = git_show(repo, ref, "lib/l10n/app_localizations.dart")
    return langs, messages, dart_texts, generated, en_arb


def find_untranslated(langs: list[str], messages: dict) -> dict[str, list[UntranslatedEntry]]:
    """Keys still missing or using the English fallback per locale."""
    by_locale: dict[str, list[UntranslatedEntry]] = {}
    non_en = [lang for lang in langs if lang != "en"]

    for lang in non_en:
        entries: list[UntranslatedEntry] = []
        for key, item in messages.items():
            en = item.get("en", "")
            value = item.get(lang)
            if value is None or (isinstance(value, str) and not value.strip()):
                entries.append({"key": key, "en": en, "status": "missing"})
            elif value == en:
                entries.append({"key": key, "en": en, "status": "english_fallback"})
        by_locale[lang] = sorted(entries, key=lambda e: e["key"])
    return by_locale
