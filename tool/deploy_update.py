#!/usr/bin/env python3
"""Build (optional) and publish JAVP APKs + latest.json via FTP.

Public endpoints (Cloudflare):
  stable → https://updater.javp.app/          (download page)
           https://updater.javp.app/latest.json
           https://updater.javp.app/javp.apk                 (universal)
           https://updater.javp.app/javp-arm64-v8a.apk
           https://updater.javp.app/javp-armeabi-v7a.apk
  dev    → https://updater.javp.app/dev/      (JAVP Dev download page)
           https://updater.javp.app/dev/latest.json
           https://updater.javp.app/dev/javp-arm64-v8a.apk

x86_64 ships only inside the universal APK — standalone x86 splits cost a
full build and ~70 MB of upload to serve emulators. Devices that report it
fall through to the universal build in AppUpdateInfo.resolveApk.

Credentials — never commit the origin FTP host/IP (Cloudflare hides it):
  export JAVP_FTP_HOST=…          # required — origin FTP host/IP
  export JAVP_FTP_PASS=…
  export JAVP_FTP_PORT=21         # optional
  export JAVP_FTP_USER=javp       # optional
  export JAVP_FTP_DIR=/           # optional — FTP chroot / deploy root
  export JAVP_PUBLIC_BASE=https://updater.javp.app
  export JAVP_UPDATE_CHANNEL=stable  # optional — default channel

Examples:
  python tool/deploy_update.py --build
  python tool/deploy_update.py --channel dev --build
  python tool/deploy_update.py --apk-dir build/app/outputs/flutter-apk
  python tool/deploy_update.py --channel dev --apk-dir build/app/outputs/flutter-apk
  python tool/deploy_update.py --apk javp.apk --changelog "Hold-to-2x polish"
  python tool/deploy_update.py --check-apk-signing --apk-dir build/app/outputs/flutter-apk
  # After publish, prune versioned archives older than the newest 3 releases
  # (short names stay, as do versions still listed in latest.json releases[]).
  # Override with --keep-versions N or --no-cleanup.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Ephemeral CI / `flutter run --release` debug keys. Publishing these breaks
# in-app updates because each machine gets a different Android Debug cert.
_DEBUG_SIGNER_MARKERS = (
    "CN=Android Debug",
    "CN = Android Debug",
)

CHANNELS = ("stable", "dev")

# Flutter --split-per-abi output names → public filenames / latest.json keys.
# Sideload / sideloadDev flavors prefix (or infix) the APK name. Legacy
# unflavored names are still accepted so older CI artifacts keep working.
SPLIT_APKS = (
    ("arm64-v8a", "app-sideload-arm64-v8a-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-sideload-armeabi-v7a-release.apk", "javp-armeabi-v7a.apk"),
)
SPLIT_APKS_DEV = (
    ("arm64-v8a", "app-sideloadDev-arm64-v8a-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-sideloadDev-armeabi-v7a-release.apk", "javp-armeabi-v7a.apk"),
)
# Current Flutter flavor naming puts the ABI before the flavor.
SPLIT_APKS_FLAVOR_ABI = (
    ("arm64-v8a", "app-arm64-v8a-sideload-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-armeabi-v7a-sideload-release.apk", "javp-armeabi-v7a.apk"),
)
SPLIT_APKS_FLAVOR_ABI_DEV = (
    ("arm64-v8a", "app-arm64-v8a-sideloadDev-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-armeabi-v7a-sideloadDev-release.apk", "javp-armeabi-v7a.apk"),
    # Some Flutter/AGP combos lowercase the flavor segment in the APK name.
    ("arm64-v8a", "app-arm64-v8a-sideloaddev-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-armeabi-v7a-sideloaddev-release.apk", "javp-armeabi-v7a.apk"),
)
SPLIT_APKS_LEGACY = (
    ("arm64-v8a", "app-arm64-v8a-release.apk", "javp-arm64-v8a.apk"),
    ("armeabi-v7a", "app-armeabi-v7a-release.apk", "javp-armeabi-v7a.apk"),
)
# The universal APK still carries x64, so emulators and Chromebooks are served.
SPLIT_TARGET_PLATFORMS = "android-arm64,android-arm"
SPLIT_TARGET_PLATFORMS_ARM64 = "android-arm64"

UNIVERSAL_BUILD = ("universal", "app-sideload-release.apk", "javp.apk")
UNIVERSAL_BUILD_DEV = ("universal", "app-sideloadDev-release.apk", "javp.apk")
UNIVERSAL_BUILD_LEGACY = ("universal", "app-release.apk", "javp.apk")


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"Missing required env var: {name}")
    return value


def normalize_channel(raw: str | None) -> str:
    channel = (raw or "stable").strip().lower()
    if channel in ("development",):
        channel = "dev"
    if channel in ("main",):
        channel = "stable"
    if channel not in CHANNELS:
        raise SystemExit(f"Unknown channel {raw!r}; expected one of {CHANNELS}")
    return channel


def channel_remote_prefix(channel: str) -> str:
    """FTP / public path prefix for the channel (stable stays at host root)."""
    channel = normalize_channel(channel)
    return "" if channel == "stable" else f"{channel}/"


def channel_android_flavor(channel: str) -> str:
    """Product flavor that publishes/installs this update channel."""
    return "sideloadDev" if normalize_channel(channel) == "dev" else "sideload"


def channel_build_args(channel: str) -> tuple[str, ...]:
    """Always pass flavor + dart-defines together so Play/sideload cannot drift."""
    channel = normalize_channel(channel)
    return (
        "--flavor",
        channel_android_flavor(channel),
        "--dart-define=JAVP_DISTRIBUTION=sideload",
        f"--dart-define=JAVP_UPDATE_CHANNEL={channel}",
    )


# Back-compat alias for callers/tests that still expect the stable build args.
SIDELOAD_BUILD_ARGS = channel_build_args("stable")


def channel_manifest_url(public_base: str, channel: str) -> str:
    base = public_base.rstrip("/")
    prefix = channel_remote_prefix(channel)
    return f"{base}/{prefix}latest.json"


def channel_apk_url(public_base: str, channel: str, remote_name: str = "javp.apk") -> str:
    base = public_base.rstrip("/")
    prefix = channel_remote_prefix(channel)
    return f"{base}/{prefix}{remote_name}"


_DOWNLOAD_PAGE_CHANNEL_STAMP = "__JAVP_CHANNEL__"


def stamp_download_page(channel: str, dest: Path, *, source: Path | None = None) -> Path:
    """Copy deploy/download.html with the channel stamp filled in.

    The page also auto-detects /dev/ from the URL path when the stamp is left
    unsubstituted (handy for local previews).
    """
    channel = normalize_channel(channel)
    src = source or (ROOT / "deploy" / "download.html")
    text = src.read_text(encoding="utf-8")
    if _DOWNLOAD_PAGE_CHANNEL_STAMP not in text:
        raise SystemExit(
            f"{src} is missing {_DOWNLOAD_PAGE_CHANNEL_STAMP!r} (needed for channel branding)"
        )
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        text.replace(_DOWNLOAD_PAGE_CHANNEL_STAMP, channel),
        encoding="utf-8",
    )
    return dest

# Permanent short names (download page / deep links) — never pruned.
_PROTECTED_REMOTE_NAMES = frozenset(
    {
        "javp.apk",
        "javp-arm64-v8a.apk",
        "javp-armeabi-v7a.apk",
        "javp-windows-x64.zip",
        "javp-setup.exe",
        "javp-linux-x64.zip",
        "javp-macos-arm64.zip",
        "javp-macos-x64.zip",
        "latest.json",
        "index.html",
        "download.html",
        "javp_logo.png",
    }
)

# Versioned APK: javp-0.2.28+30.apk / javp-arm64-v8a-0.2.28+30.apk
_VERSIONED_APK_RE = re.compile(
    r"^(?P<stem>.+)-(?P<version>[^+]+)\+(?P<code>\d+)\.apk$",
    re.IGNORECASE,
)
# Versioned desktop: javp-0.2.28+30-windows-x64.zip
_VERSIONED_DESKTOP_RE = re.compile(
    r"^javp-(?P<version>[^+]+)\+(?P<code>\d+)-(?P<suffix>.+)$",
    re.IGNORECASE,
)


def parse_versioned_artifact(name: str) -> tuple[str, int] | None:
    """Return (versionName, versionCode) for a versioned updater artifact, else None."""
    base = Path(name).name
    if base in _PROTECTED_REMOTE_NAMES:
        return None
    # Desktop first — APK regex would not match non-.apk names anyway, but
    # desktop names also contain version+code and must not be mis-parsed.
    m = _VERSIONED_DESKTOP_RE.match(base)
    if m and not base.lower().endswith(".apk"):
        return m.group("version"), int(m.group("code"))
    m = _VERSIONED_APK_RE.match(base)
    if m:
        return m.group("version"), int(m.group("code"))
    return None


def plan_versioned_cleanup(
    filenames: list[str] | tuple[str, ...],
    *,
    keep: int = 3,
    protected_codes: set[int] | frozenset[int] | None = None,
) -> list[str]:
    """Return versioned artifact basenames older than the newest [keep] releases.

    Groups by (versionCode, versionName), keeps the highest codes, and never
    proposes protected short names / site files. [protected_codes] are extra
    versionCodes to retain because the manifest's ``releases[]`` still lists
    them — pruning them would leave changelog entries without downloadable
    files while still hiding the notes between skipped builds.
    """
    if keep < 1:
        raise ValueError("keep must be >= 1")
    protected = set(protected_codes or ())

    groups: dict[tuple[int, str], list[str]] = {}
    for raw in filenames:
        base = Path(raw).name
        if base in _PROTECTED_REMOTE_NAMES or base.startswith("."):
            continue
        parsed = parse_versioned_artifact(base)
        if parsed is None:
            continue
        version_name, version_code = parsed
        groups.setdefault((version_code, version_name), []).append(base)

    ordered = sorted(groups.keys(), key=lambda item: (item[0], item[1]), reverse=True)
    keep_keys = set(ordered[:keep])
    keep_keys.update(key for key in groups if key[0] in protected)
    to_delete: list[str] = []
    for key, names in groups.items():
        if key not in keep_keys:
            to_delete.extend(names)
    return sorted(set(to_delete))


def release_version_codes(releases: list[dict] | None) -> set[int]:
    """versionCodes still referenced by a manifest ``releases[]`` history.

    Entries without a ``versionCode`` (compared by marketing version) are
    skipped — there is no code to anchor a versioned artifact to.
    """
    codes: set[int] = set()
    for row in releases or []:
        code = row.get("versionCode")
        if isinstance(code, int) and not isinstance(code, bool):
            codes.add(code)
    return codes


def read_pubspec_version() -> tuple[str, int]:
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s#]+)", text, re.M)
    if not match:
        raise SystemExit("Could not parse version from pubspec.yaml")
    raw = match.group(1).strip()
    if "+" in raw:
        name, code = raw.split("+", 1)
    else:
        name, code = raw, "1"
    return name, int(code)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git_output(args: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["git", *args],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def previous_release_tag(current_tag: str | None = None) -> str | None:
    """Newest v* tag that isn't the current HEAD tag."""
    tags = [
        t.strip()
        for t in _git_output(["tag", "-l", "v*", "--sort=-creatordate"]).splitlines()
        if t.strip()
    ]
    if not current_tag:
        exact = _git_output(["describe", "--tags", "--exact-match", "HEAD"])
        current_tag = exact or None
    for tag in tags:
        if tag != current_tag:
            return tag
    return None


# Paths that ship in the app binary / affect end users. Commits that touch
# none of these are treated as internal (tooling, docs, CI, Cloud env, …).
_CHANGELOG_APP_PATH_PREFIXES = (
    "lib/",
    "android/",
    "ios/",
    "macos/",
    "windows/",
    "linux/",
    "assets/",
    "packages/",
)

# Conventional-commit types that are almost never user-facing by themselves.
# Prefer feat:/fix: (or an unprefixed subject) for public notes.
_CHANGELOG_SKIP_CONVENTIONAL = re.compile(
    r"^(chore|ci|test|docs|build|style|refactor)(\([^)]*\))?!?:\s+",
    re.I,
)

# Subject patterns for release/tooling noise that still touches app paths
# (e.g. version bumps that also tweak a client id string).
_CHANGELOG_SKIP_SUBJECT = (
    re.compile(r"^merge(\s|$)", re.I),
    re.compile(r"^merge pull request\b", re.I),
    re.compile(r"^bump to\b", re.I),
    re.compile(r"\bfor (dev|stable) channel publish\b", re.I),
    re.compile(r"^release\s+v?\d[\w.+-]*\b.*(notes|changelog)\b", re.I),
    re.compile(r"^version bump\b", re.I),
    re.compile(r"\bcursor cloud\b", re.I),
    re.compile(r"\bcloud agent\b", re.I),
    re.compile(r"\bagents\.md\b", re.I),
    re.compile(r"\b(local_release|deploy_update)\b", re.I),
    re.compile(r"\bprojectionist mode\b", re.I),
    re.compile(r"\bout of public release notes\b", re.I),
    re.compile(r"\bjavp-discord\b", re.I),
    re.compile(r"\bdiscord bot\b", re.I),
)


def changelog_path_is_app(path: str) -> bool:
    """True when a changed path is part of the shipped app tree."""
    normalized = path.strip().lstrip("./")
    if not normalized:
        return False
    return normalized.startswith(_CHANGELOG_APP_PATH_PREFIXES)


def changelog_paths_are_user_facing(paths: list[str] | tuple[str, ...] | None) -> bool:
    """False when every changed file is tooling/docs/CI/tests (or empty known set).

    Unknown/empty path lists fall through to subject filters only so a missing
    name-status still produces notes rather than silence.
    """
    if paths is None:
        return True
    cleaned = [p.strip() for p in paths if p and p.strip()]
    if not cleaned:
        return True
    return any(changelog_path_is_app(p) for p in cleaned)


def changelog_subject_is_noise(subject: str) -> bool:
    """True when the commit subject should not appear in public updater notes."""
    text = " ".join(subject.strip().split())
    if not text:
        return True
    if _CHANGELOG_SKIP_CONVENTIONAL.match(text):
        return True
    return any(pat.search(text) for pat in _CHANGELOG_SKIP_SUBJECT)


def is_public_changelog_commit(
    subject: str,
    paths: list[str] | tuple[str, ...] | None = None,
) -> bool:
    """Whether a commit belongs in latest.json / in-app updater notes."""
    if changelog_subject_is_noise(subject):
        return False
    if not changelog_paths_are_user_facing(paths):
        return False
    return True


def _parse_git_log_with_paths(raw: str) -> list[tuple[str, list[str]]]:
    """Parse `git log --pretty=format:%s --name-only` into (subject, paths)."""
    entries: list[tuple[str, list[str]]] = []
    subject: str | None = None
    paths: list[str] = []

    def flush() -> None:
        nonlocal subject, paths
        if subject is not None:
            entries.append((subject, paths))
        subject = None
        paths = []

    for line in raw.splitlines():
        if not line.strip():
            flush()
            continue
        if subject is None:
            subject = " ".join(line.strip().split())
            paths = []
            continue
        # Name-only lines never contain spaces in normal git paths; subjects
        # that somehow appear mid-block are treated as a new commit header when
        # the previous entry already flushed on a blank line.
        paths.append(line.strip())
    flush()
    return entries


_DEV_CHANGELOG_PLACEHOLDER = re.compile(
    r"^Dev build(?:\s@\s[\w./-]+|\s*\(bot-triggered\))?\s*$",
    re.I,
)
_GIT_SHA_RE = re.compile(r"^[0-9a-f]{7,40}$", re.I)


def is_dev_changelog_placeholder(manual: str) -> bool:
    """True for bot/default one-liners that should not block auto-changelog."""
    return bool(_DEV_CHANGELOG_PLACEHOLDER.match(manual.strip()))


def _git_commit_is_ancestor(ancestor: str, head: str = "HEAD") -> bool:
    try:
        subprocess.check_call(
            ["git", "merge-base", "--is-ancestor", ancestor, head],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def fetch_live_manifest(
    channel: str = "dev",
    manifest_url: str | None = None,
) -> dict | None:
    """Read the live latest.json for a channel (best-effort)."""
    import urllib.error
    import urllib.request

    public_base = os.environ.get("JAVP_PUBLIC_BASE", "https://updater.javp.app").rstrip("/")
    url = (manifest_url or channel_manifest_url(public_base, channel)).strip()
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "User-Agent": "javp-deploy-update/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def fetch_live_dev_manifest(manifest_url: str | None = None) -> dict | None:
    """Read the live Dev latest.json (best-effort)."""
    return fetch_live_manifest("dev", manifest_url)


BUILD_META_NAME = ".javp-build-meta.json"


def write_build_meta(
    directory: Path,
    *,
    git_commit: str | None,
    version_name: str,
    version_code: int,
) -> Path:
    """Pin the git SHA the APKs in this folder were built from."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / BUILD_META_NAME
    payload = {
        "gitCommit": git_commit,
        "versionName": version_name,
        "versionCode": version_code,
        "writtenAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def read_build_meta(directory: Path | None) -> dict | None:
    if directory is None:
        return None
    path = directory / BUILD_META_NAME
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _manifest_sha(entry: object) -> str | None:
    if not isinstance(entry, dict):
        return None
    sha = entry.get("sha256")
    if isinstance(sha, str) and sha.strip():
        return sha.strip().lower()
    return None


def artifact_hashes_match_live(
    apks_manifest: dict[str, dict[str, str]] | None,
    live: dict | None,
) -> bool:
    """True when local APK sha256s match the live manifest (same binaries)."""
    if not live or not apks_manifest:
        return False
    live_apks = live.get("apks")
    if isinstance(live_apks, dict) and live_apks:
        overlap = False
        for abi, entry in apks_manifest.items():
            live_entry = live_apks.get(abi)
            if not isinstance(live_entry, dict):
                continue
            overlap = True
            local_sha = (entry.get("sha256") or "").strip().lower()
            if local_sha != (_manifest_sha(live_entry) or ""):
                return False
        return overlap
    live_sha = live.get("apkSha256")
    local = apks_manifest.get("universal") or apks_manifest.get("arm64-v8a")
    if isinstance(live_sha, str) and local:
        return live_sha.strip().lower() == (local.get("sha256") or "").strip().lower()
    return False


def live_base_version_code(live: dict | None) -> int | None:
    if not live:
        return None
    base = live.get("baseVersionCode")
    if isinstance(base, bool):
        return None
    if isinstance(base, (int, float)):
        return int(base)
    if isinstance(base, str) and base.strip().isdigit():
        return int(base.strip())
    code = live.get("versionCode")
    if isinstance(code, bool):
        return None
    if isinstance(code, (int, float)):
        n = int(code)
        return n % 1000 if n >= 1000 else n
    if isinstance(code, str) and code.strip().isdigit():
        n = int(code.strip())
        return n % 1000 if n >= 1000 else n
    return None


def _valid_git_sha(value: str | None) -> str | None:
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    return text if _GIT_SHA_RE.fullmatch(text) else None


def resolve_artifact_git_commit(
    *,
    channel: str,
    head: str | None,
    explicit: str | None,
    sidecar_commit: str | None,
    live: dict | None,
    hashes_match_live: bool,
    built_now: bool,
    manifest_only: bool,
) -> str | None:
    """Git SHA of the binaries, not necessarily HEAD.

    Manifest-only / same-hash republishes keep the live SHA so a merge that
    landed after the APK build cannot retag that version as a different tree.
    """
    explicit_sha = _valid_git_sha(explicit)
    if explicit_sha:
        return explicit_sha

    sidecar_sha = _valid_git_sha(sidecar_commit)
    live_sha = None
    if live:
        raw = live.get("gitCommit")
        live_sha = _valid_git_sha(raw if isinstance(raw, str) else None)
    head_sha = _valid_git_sha(head)

    if sidecar_sha:
        return sidecar_sha
    if manifest_only or hashes_match_live:
        return live_sha or sidecar_sha or head_sha
    if built_now:
        return head_sha
    return head_sha


def same_version_overwrite_error(
    *,
    channel: str,
    version_code: int,
    artifact_git_commit: str | None,
    live: dict | None,
    hashes_match_live: bool,
    manifest_only: bool,
    allow: bool,
) -> str | None:
    """Error if this would reuse Dev +N for a different git tree."""
    if allow or manifest_only or normalize_channel(channel) != "dev":
        return None
    live_code = live_base_version_code(live)
    if live_code is None or version_code > live_code:
        return None
    if hashes_match_live:
        return None
    live_raw = live.get("gitCommit") if live else None
    live_sha = _valid_git_sha(live_raw if isinstance(live_raw, str) else None)
    artifact_sha = _valid_git_sha(artifact_git_commit)
    if live_sha and artifact_sha and live_sha == artifact_sha:
        return None
    live_s = (live_sha or "unknown")[:7]
    art_s = (artifact_sha or "HEAD")[:7]
    return (
        f"Refusing to overwrite Dev +{live_code} (git {live_s}) with a different "
        f"tree ({art_s}). Bump pubspec +build and rebuild so testers get a new "
        "versionCode. Changelog-only: --manifest-only. Override: --allow-same-version."
    )


def apply_manifest_only_overlay(
    live: dict,
    *,
    changelog: str,
    git_commit: str | None,
    releases: list[dict] | None = None,
) -> dict:
    """Update notes (and optional git SHA) without retagging binaries."""
    payload = dict(live)
    payload["changelog"] = changelog
    if releases:
        payload["releases"] = releases
    payload["publishedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    sha = _valid_git_sha(git_commit)
    if sha:
        payload["gitCommit"] = sha
    return payload


def merge_live_package(
    manifest: dict,
    *,
    key: str,
    url: str,
    sha256: str,
    kind: str,
) -> dict:
    """Add or replace one packages.* entry on a live overlay."""
    payload = dict(manifest)
    packages = dict(payload.get("packages") or {})
    packages[key] = {"url": url, "sha256": sha256, "kind": kind}
    payload["packages"] = packages
    return payload


def previous_dev_publish_commit(manifest_url: str | None = None) -> str | None:
    """Git SHA recorded on the last Dev publish, when present."""
    payload = fetch_live_dev_manifest(manifest_url)
    if not payload:
        return None
    sha = payload.get("gitCommit")
    if isinstance(sha, str) and _GIT_SHA_RE.fullmatch(sha.strip()):
        return sha.strip()
    return None


def _collect_changelog_bullets(log_args: list[str], *, max_commits: int = 40) -> list[str]:
    # Over-fetch so path/subject filters still leave enough public bullets.
    fetch_count = max(max_commits * 4, max_commits)
    log = _git_output(
        [
            "log",
            *log_args,
            f"--max-count={fetch_count}",
            "--pretty=format:%s",
            "--name-only",
            "--no-merges",
        ]
    )
    bullets: list[str] = []
    seen: set[str] = set()
    for subject, paths in _parse_git_log_with_paths(log):
        if not subject or subject in seen:
            continue
        if not is_public_changelog_commit(subject, paths):
            continue
        seen.add(subject)
        bullets.append(f"- {subject}")
        if len(bullets) >= max_commits:
            break
    return bullets


def _dev_changelog_log_args(
    *,
    max_commits: int,
    manifest_url: str | None,
) -> list[str]:
    """Git log rev args: since previous Dev publish, not since last stable tag."""
    payload = fetch_live_dev_manifest(manifest_url)
    if payload:
        sha = payload.get("gitCommit")
        if isinstance(sha, str) and _GIT_SHA_RE.fullmatch(sha.strip()):
            since = sha.strip()
            if _git_commit_is_ancestor(since):
                return [f"{since}..HEAD"]
        published = payload.get("publishedAt")
        if isinstance(published, str) and published.strip():
            # Transitional fallback when older manifests lack gitCommit.
            return [f"--since={published.strip()}"]
    depth = max(max_commits * 2, max_commits)
    return [f"HEAD~{depth}..HEAD"]


def build_git_changelog(*, max_commits: int = 40) -> str:
    """Build a bullet changelog from user-facing commits since the previous v* tag."""
    current = _git_output(["describe", "--tags", "--exact-match", "HEAD"]) or None
    prev = previous_release_tag(current)
    range_spec = f"{prev}..HEAD" if prev else "HEAD"
    bullets = _collect_changelog_bullets([range_spec], max_commits=max_commits)
    if not bullets:
        return ""

    header = f"What's new since {prev}:" if prev else "What's new:"
    return header + "\n" + "\n".join(bullets)


def build_dev_git_changelog(
    *,
    max_commits: int = 20,
    manifest_url: str | None = None,
) -> str:
    """User-facing commits since the previous Dev publish (not since last stable tag)."""
    log_args = _dev_changelog_log_args(max_commits=max_commits, manifest_url=manifest_url)
    bullets = _collect_changelog_bullets(log_args, max_commits=max_commits)
    if not bullets:
        return ""
    return "This Dev build:\n" + "\n".join(bullets)


_DEV_NOTES_HEADING = re.compile(r"^#{3,6}\s+Dev notes\s*$", re.I)
_ATX_HEADING = re.compile(r"^(#{1,6})\s+\S")
_DEV_CHANNEL_BUMP = re.compile(
    r"^Dev channel bump\s*(?:\(`dev`\))?\.\s*$",
    re.I,
)
_RELEASE_H2 = re.compile(r"^##\s+(?P<title>.+?)\s*$")
_H3 = re.compile(r"^###\s+(?P<title>.+?)\s*$")
_UNRELEASED_SECTION = re.compile(
    r"(^##\s+Unreleased[ \t]*\n)(.*?)(?=^##\s+|\Z)",
    re.M | re.S | re.I,
)
_VERSION_IDENT = re.compile(
    r"^(?P<name>\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)(?:\+(?P<code>\d+))?"
)
UNRELEASED_FRAGMENTS_DIR = ROOT / "changelog" / "unreleased"
_FRAGMENT_SKIP_NAMES = frozenset({"readme.md", ".gitkeep"})


def collapse_blank_lines(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def strip_dev_notes(text: str) -> str:
    """Drop ### Dev notes (until the next heading of the same or higher level)."""
    lines = text.splitlines()
    out: list[str] = []
    skipping = False
    skip_level = 3
    for line in lines:
        heading = _ATX_HEADING.match(line)
        if skipping:
            if heading and len(heading.group(1)) <= skip_level:
                skipping = False
            else:
                continue
        if _DEV_NOTES_HEADING.match(line.strip()):
            hashes = re.match(r"^(#+)", line.strip())
            skip_level = len(hashes.group(1)) if hashes else 3
            skipping = True
            continue
        out.append(line)
    return "\n".join(out)


def strip_changelog_noise(text: str) -> str:
    """Drop publish-only lines that are not user-facing."""
    kept = [
        line
        for line in text.splitlines()
        if not _DEV_CHANNEL_BUMP.match(line.strip())
    ]
    return collapse_blank_lines("\n".join(kept))


def looks_like_full_changelog(text: str) -> bool:
    if re.search(r"^#\s+Changelog\s*$", text, re.M | re.I):
        return True
    return len(re.findall(r"^##\s+", text, re.M)) >= 2


def split_changelog_sections(text: str) -> list[tuple[str, str]]:
    """Return [(h2 title, body), ...] in file order. Preamble before the first ## is dropped."""
    sections: list[tuple[str, list[str]]] = []
    current_title: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        match = _RELEASE_H2.match(line)
        if match:
            if current_title is not None:
                sections.append((current_title, "\n".join(buf)))
            current_title = match.group("title").strip()
            buf = []
            continue
        if current_title is not None:
            buf.append(line)
    if current_title is not None:
        sections.append((current_title, "\n".join(buf)))
    return sections


def parse_heading_ident(title: str) -> str | None:
    stripped = title.strip()
    if stripped.lower() == "unreleased":
        return "unreleased"
    match = _VERSION_IDENT.match(stripped)
    return match.group("name") if match else None


def public_section_body(body: str) -> str:
    return strip_changelog_noise(strip_dev_notes(body))


def heading_matches_publish_version(ident: str | None, version_name: str) -> bool:
    """True when this H2 belongs in the updater notes for [version_name].

    Stable `0.4.2` also includes `0.4.2-dev+N` history. Dev `0.4.2-dev` does
    not include a later stable `0.4.2+N` heading.
    """
    if not ident or ident == "unreleased":
        return False
    if ident == version_name:
        return True
    if version_name.endswith("-dev"):
        return False
    return ident == f"{version_name}-dev"


def this_cut_heading(
    version_name: str,
    version_code: int | None = None,
    *,
    date: str | None = None,
) -> str:
    """H2 the updater / Discord bot slice for this cut, e.g. ``0.4.3+57 (2026-08-13)``."""
    ident = version_name.strip()
    if version_code is not None:
        ident = f"{ident}+{int(version_code)}"
    day = (date or datetime.now(timezone.utc).date().isoformat()).strip()[:10]
    return f"{ident} ({day})" if day else ident


def public_changelog_from_markdown(
    text: str,
    *,
    version_name: str,
    version_code: int | None = None,
    published_date: str | None = None,
) -> str:
    """User-facing Unreleased + matching version sections (Dev notes stripped).

    Assembled ``## Unreleased`` (fragments + leftover) is retitled to
    ``## {versionName}+{build} (date)`` so Discord can slice this cut instead
    of matching an older heading. When Unreleased is empty but ``version_code``
    is set, still emit that cut heading (empty body) so the next publish is not
    announced under a prior ``+N``. For ``0.4.2-dev``, later matching
    ``## 0.4.2-dev+N`` history is still appended. Newer unrelated versions
    above that are skipped.
    """
    if not text.strip() or not version_name.strip():
        return ""
    parts: list[str] = []
    seen_version = False
    cut_title = this_cut_heading(
        version_name, version_code, date=published_date
    )
    had_unreleased_public = False
    for title, body in split_changelog_sections(text):
        ident = parse_heading_ident(title)
        public = public_section_body(body)
        if ident == "unreleased":
            if public:
                had_unreleased_public = True
                parts.append(f"## {cut_title}\n\n{public}")
            continue
        if heading_matches_publish_version(ident, version_name):
            seen_version = True
            if public:
                parts.append(f"## {title}\n\n{public}")
            continue
        if seen_version:
            break
    if (
        not had_unreleased_public
        and version_code is not None
        and not changelog_has_cut_heading("\n\n".join(parts), version_name, version_code)
    ):
        # Empty Unreleased after a prior consume — still label this cut.
        # Same-lineage stable (0.5.1 after ## 0.5.1-dev+N): fold those bodies
        # under ## 0.5.1+N. An empty cut H2 ahead of -dev made Discord announce
        # only the heading.
        if not version_name.endswith("-dev") and parts:
            bodies: list[str] = []
            for part in parts:
                lines = part.splitlines()
                if lines and lines[0].startswith("## "):
                    bodies.append("\n".join(lines[1:]).strip("\n"))
                else:
                    bodies.append(part.strip())
            merged = dedupe_h3_bullets(
                merge_h3_markdown([b for b in bodies if b.strip()])
            )
            parts = [
                f"## {cut_title}\n\n{merged}" if merged.strip() else f"## {cut_title}"
            ]
        else:
            parts.insert(0, f"## {cut_title}")
    return collapse_blank_lines("\n\n".join(parts))


_MAX_CHANGELOG_RELEASES = 40


def section_belongs_to_channel(
    ident: str | None,
    *,
    version_name: str,
    channel: str = "stable",
) -> bool:
    """Which H2s belong in this channel's updater history.

    Dev: ``*-dev`` cuts (and the publish ident). Stable: every non-dev
    marketing cut, plus this cut's ``X.Y.Z-dev`` prerelease history.
    Older ``-dev`` lines stay out of stable — those notes were rolled into
    the matching stable section.
    """
    if not ident or ident == "unreleased":
        return False
    ch = normalize_channel(channel)
    is_dev_ident = ident.endswith("-dev")
    if ch == "dev":
        return is_dev_ident or ident == version_name
    if not is_dev_ident:
        return True
    return heading_matches_publish_version(ident, version_name)


def changelog_release_entry(
    *,
    version_name: str,
    version_code: int | None,
    title: str,
    notes: str,
) -> dict[str, object]:
    """One ``latest.json`` ``releases[]`` row (pubspec +N, not ABI-encoded)."""
    entry: dict[str, object] = {
        "versionName": version_name,
        "title": title.strip(),
        "notes": notes.strip(),
    }
    if version_code is not None:
        entry["versionCode"] = int(version_code)
    return entry


def public_changelog_releases(
    text: str,
    *,
    version_name: str,
    version_code: int | None = None,
    published_date: str | None = None,
    channel: str = "stable",
    max_releases: int = _MAX_CHANGELOG_RELEASES,
) -> list[dict[str, object]]:
    """Structured public H2 sections so the app can slice since the install.

    Newest first. Unreleased is retitled to this cut (same as
    [public_changelog_from_markdown]). Includes older marketing versions on
    this channel, not only the current line. Dev notes are stripped.
    """
    if not text.strip() or not version_name.strip():
        return []
    cut_title = this_cut_heading(
        version_name, version_code, date=published_date
    )
    releases: list[dict[str, object]] = []
    seen_codes: set[int] = set()
    seen_titles: set[str] = set()

    def _append(
        *,
        ident: str,
        code: int | None,
        title: str,
        notes: str,
    ) -> None:
        if not notes.strip():
            return
        if code is not None:
            if code in seen_codes:
                return
            seen_codes.add(code)
        key = title.strip().casefold()
        if key in seen_titles:
            return
        seen_titles.add(key)
        releases.append(
            changelog_release_entry(
                version_name=ident,
                version_code=code,
                title=title,
                notes=notes,
            )
        )

    for title, body in split_changelog_sections(text):
        ident = parse_heading_ident(title)
        public = public_section_body(body)
        if ident == "unreleased":
            if public:
                _append(
                    ident=version_name,
                    code=version_code,
                    title=cut_title,
                    notes=public,
                )
            continue
        if not section_belongs_to_channel(
            ident, version_name=version_name, channel=channel
        ):
            continue
        name, code = parse_section_version(title)
        _append(
            ident=name or ident or version_name,
            code=code,
            title=title,
            notes=public,
        )
        if max_releases > 0 and len(releases) >= max_releases:
            break
    return releases


def releases_from_changelog_text(
    changelog: str,
    *,
    version_name: str,
    version_code: int | None = None,
    published_date: str | None = None,
) -> list[dict[str, object]]:
    """Wrap a git/manual blob as a single release when CHANGELOG.md is empty."""
    notes = (changelog or "").strip()
    if not notes:
        return []
    return [
        changelog_release_entry(
            version_name=version_name,
            version_code=version_code,
            title=this_cut_heading(
                version_name, version_code, date=published_date
            ),
            notes=notes,
        )
    ]


def resolve_changelog_releases(
    *,
    version_name: str,
    changelog_md: str = "",
    changelog: str = "",
    version_code: int | None = None,
    published_date: str | None = None,
    channel: str = "stable",
) -> list[dict[str, object]]:
    """Prefer structured CHANGELOG.md history; fall back to the notes blob."""
    releases = public_changelog_releases(
        changelog_md,
        version_name=version_name,
        version_code=version_code,
        published_date=published_date,
        channel=channel,
    )
    if releases:
        return releases
    return releases_from_changelog_text(
        changelog,
        version_name=version_name,
        version_code=version_code,
        published_date=published_date,
    )


def list_unreleased_fragment_paths(directory: Path | None = None) -> list[Path]:
    """Markdown fragments in filename order (skip README / hidden)."""
    folder = directory or UNRELEASED_FRAGMENTS_DIR
    if not folder.is_dir():
        return []
    paths: list[Path] = []
    for path in folder.iterdir():
        if not path.is_file():
            continue
        if path.name.startswith("."):
            continue
        if path.name.lower() in _FRAGMENT_SKIP_NAMES:
            continue
        if path.suffix.lower() != ".md":
            continue
        paths.append(path)
    return sorted(paths, key=lambda p: p.name.lower())


def split_h3_sections(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Return (preamble, [(### title, body), ...]) in file order."""
    preamble_lines: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    current_title: str | None = None
    buf: list[str] = []
    seen_h3 = False
    for line in text.splitlines():
        match = _H3.match(line)
        if match:
            if current_title is not None:
                sections.append((current_title, buf))
            current_title = match.group("title").strip()
            buf = []
            seen_h3 = True
            continue
        if not seen_h3:
            preamble_lines.append(line)
            continue
        buf.append(line)
    if current_title is not None:
        sections.append((current_title, buf))
    return (
        "\n".join(preamble_lines),
        [(title, "\n".join(body)) for title, body in sections],
    )


def merge_h3_markdown(parts: list[str]) -> str:
    """Merge ### sections across fragments. First-seen heading order; stable append."""
    preambles: list[str] = []
    order: list[str] = []
    display: dict[str, str] = {}
    bodies: dict[str, list[str]] = {}
    for part in parts:
        if not part or not str(part).strip():
            continue
        preamble, sections = split_h3_sections(part)
        cleaned_preamble = collapse_blank_lines(preamble)
        if cleaned_preamble:
            preambles.append(cleaned_preamble)
        for title, body in sections:
            key = title.strip().casefold()
            if key not in display:
                display[key] = title.strip()
                order.append(key)
                bodies[key] = []
            cleaned = collapse_blank_lines(body)
            if cleaned:
                bodies[key].append(cleaned)
    chunks = list(preambles)
    for key in order:
        title = display[key]
        merged = "\n\n".join(bodies[key])
        chunks.append(f"### {title}\n\n{merged}" if merged else f"### {title}")
    return collapse_blank_lines("\n\n".join(chunks))


def extract_unreleased_body(changelog_md: str) -> str:
    for title, body in split_changelog_sections(changelog_md):
        if parse_heading_ident(title) == "unreleased":
            return body.strip("\n")
    return ""


def changelog_preamble(text: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        if _RELEASE_H2.match(line):
            break
        lines.append(line)
    return "\n".join(lines).rstrip()


def replace_unreleased_body(changelog_md: str, new_body: str) -> str:
    """Replace ## Unreleased contents; insert the section if missing."""
    stripped = new_body.strip()
    section_body = f"\n{stripped}\n\n" if stripped else "\n\n"

    def _repl(match: re.Match[str]) -> str:
        return match.group(1) + section_body

    if _UNRELEASED_SECTION.search(changelog_md or ""):
        return _UNRELEASED_SECTION.sub(_repl, changelog_md, count=1)
    section = f"## Unreleased{section_body}"
    preamble = changelog_preamble(changelog_md or "")
    if not (changelog_md or "").strip():
        return f"# Changelog\n\n{section}".rstrip() + "\n"
    rest = (changelog_md or "")[len(preamble) :].lstrip("\n") if preamble else (changelog_md or "")
    if preamble:
        return preamble + "\n\n" + section + rest
    return section + rest


def read_unreleased_fragment_texts(directory: Path | None = None) -> list[str]:
    texts: list[str] = []
    for path in list_unreleased_fragment_paths(directory):
        texts.append(path.read_text(encoding="utf-8"))
    return texts


def assemble_unreleased_body(
    changelog_md: str = "",
    *,
    fragments_dir: Path | None = None,
    fragment_texts: list[str] | None = None,
) -> str:
    """Leftover CHANGELOG.md Unreleased, then unique fragment files (filename order)."""
    leftover = extract_unreleased_body(changelog_md)
    fragments = (
        fragment_texts
        if fragment_texts is not None
        else read_unreleased_fragment_texts(fragments_dir)
    )
    return merge_h3_markdown([leftover, *fragments])


def assemble_changelog_markdown(
    changelog_md: str = "",
    *,
    fragments_dir: Path | None = None,
    fragment_texts: list[str] | None = None,
) -> str:
    """CHANGELOG.md text with ## Unreleased replaced by leftover + fragments."""
    assembled = assemble_unreleased_body(
        changelog_md,
        fragments_dir=fragments_dir,
        fragment_texts=fragment_texts,
    )
    return replace_unreleased_body(changelog_md, assembled)


def cut_version_token(version_name: str, version_code: int | None = None) -> str:
    """Bare ``0.4.2-dev+59`` token (no date) for matching existing H2s."""
    ident = version_name.strip()
    if version_code is not None:
        return f"{ident}+{int(version_code)}"
    return ident


def changelog_has_cut_heading(
    changelog_md: str,
    version_name: str,
    version_code: int | None = None,
) -> bool:
    """True when CHANGELOG already has ``## {version}+{build}`` (date optional)."""
    want = cut_version_token(version_name, version_code)
    for title, _body in split_changelog_sections(changelog_md):
        token = title.strip().split()[0] if title.strip() else ""
        if token == want:
            return True
    return False


def _changelog_from_sections(preamble: str, sections: list[tuple[str, str]]) -> str:
    """Rebuild CHANGELOG.md from preamble + ``[(h2 title, body), ...]``."""
    chunks: list[str] = []
    pre = preamble.rstrip()
    if pre:
        chunks.append(pre)
    for title, body in sections:
        cleaned = body.strip("\n")
        if cleaned:
            chunks.append(f"## {title}\n\n{cleaned}")
        else:
            chunks.append(f"## {title}")
    if not chunks:
        return "# Changelog\n"
    return "\n\n".join(chunks).rstrip() + "\n"


def fold_unreleased_into_version(
    changelog_md: str,
    *,
    version_name: str,
    version_code: int | None = None,
    published_date: str | None = None,
    unreleased_body: str | None = None,
) -> str:
    """Move assembled Unreleased under ``## version+build (date)``; clear Unreleased.

    If that cut heading already exists, merge the assembled body into it (deduped)
    so Dev notes and late fragments are not dropped, then clear Unreleased.
    Empty Unreleased is a no-op aside from normalizing the empty section.
    """
    body = (
        unreleased_body
        if unreleased_body is not None
        else extract_unreleased_body(changelog_md)
    ).strip()
    cleared = replace_unreleased_body(changelog_md, "")
    if not body:
        return cleared
    want = cut_version_token(version_name, version_code)
    preamble = changelog_preamble(cleared)
    sections = split_changelog_sections(cleared)
    merged_sections: list[tuple[str, str]] = []
    found = False
    for title, section_body in sections:
        token = title.strip().split()[0] if title.strip() else ""
        if not found and token == want:
            merged = dedupe_h3_bullets(
                merge_h3_markdown([section_body.strip("\n"), body])
            )
            merged_sections.append((title, merged))
            found = True
        else:
            merged_sections.append((title, section_body.strip("\n")))
    if found:
        return _changelog_from_sections(preamble, merged_sections)
    cut = this_cut_heading(version_name, version_code, date=published_date)
    section = f"## {cut}\n\n{body}\n\n"
    match = _UNRELEASED_SECTION.search(cleared)
    if match:
        return cleared[: match.end()].rstrip() + "\n\n" + section + cleared[match.end() :].lstrip("\n")
    rest = cleared[len(preamble) :].lstrip("\n") if preamble else cleared
    if preamble:
        return preamble + "\n\n## Unreleased\n\n" + section + rest
    return "# Changelog\n\n## Unreleased\n\n" + section + rest


def delete_unreleased_fragments(directory: Path | None = None) -> list[Path]:
    """Delete ``changelog/unreleased/*.md`` fragments (keeps README / hidden)."""
    deleted: list[Path] = []
    for path in list_unreleased_fragment_paths(directory):
        path.unlink(missing_ok=True)
        deleted.append(path)
    return deleted


def consume_unreleased_after_publish(
    *,
    version_name: str,
    version_code: int | None,
    published_date: str | None = None,
    changelog_path: Path | None = None,
    fragments_dir: Path | None = None,
) -> dict[str, object]:
    """Fold leftover + fragments into CHANGELOG; delete consumed fragment files.

    Call after a successful FTP publish so the next Dev/stable cut only sees
    new notes. Hybrid queues hard-reset to origin/dev — pair with
    ``commit_consumed_changelog`` so the fold survives the next sync.
    """
    changelog = changelog_path or (ROOT / "CHANGELOG.md")
    frag_dir = fragments_dir or UNRELEASED_FRAGMENTS_DIR
    raw = changelog.read_text(encoding="utf-8") if changelog.is_file() else ""
    pending = list_unreleased_fragment_paths(frag_dir)
    assembled = assemble_unreleased_body(raw, fragments_dir=frag_dir)
    if not assembled.strip() and not pending:
        return {"folded": False, "deleted": [], "changelog": str(changelog)}
    folded = fold_unreleased_into_version(
        raw,
        version_name=version_name,
        version_code=version_code,
        published_date=published_date,
        unreleased_body=assembled,
    )
    text = folded if folded.endswith("\n") else folded + "\n"
    changelog.parent.mkdir(parents=True, exist_ok=True)
    changelog.write_text(text, encoding="utf-8")
    deleted = delete_unreleased_fragments(frag_dir)
    return {
        "folded": bool(assembled.strip()),
        "deleted": [p.name for p in deleted],
        "changelog": str(changelog),
    }


def commit_consumed_changelog(
    *,
    version_name: str,
    version_code: int | None,
    deleted_names: list[str] | None = None,
    push: bool | None = None,
) -> str | None:
    """Commit CHANGELOG fold + fragment deletes; optionally push (hybrid needs it).

    Skips when there is nothing staged. Does not touch pubspec or other dirt.
    Set ``JAVP_CHANGELOG_CONSUME_GIT=0`` to disable. Push defaults on unless
    ``JAVP_CHANGELOG_CONSUME_PUSH=0``.
    """
    if os.environ.get("JAVP_CHANGELOG_CONSUME_GIT", "1").strip().lower() in {
        "0",
        "false",
        "no",
        "off",
    }:
        return None
    if push is None:
        push = os.environ.get("JAVP_CHANGELOG_CONSUME_PUSH", "1").strip().lower() not in {
            "0",
            "false",
            "no",
            "off",
        }
    cut = cut_version_token(version_name, version_code)
    try:
        subprocess.run(
            ["git", "add", "--", "CHANGELOG.md", "changelog/unreleased"],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        status = subprocess.run(
            ["git", "status", "--porcelain", "--", "CHANGELOG.md", "changelog/unreleased"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if not status:
            return None
        names = ", ".join(deleted_names or []) or "fragments"
        message = f"Changelog: fold Unreleased into {cut} and clear {names}."
        subprocess.run(
            ["git", "commit", "-m", message],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        sha = _git_output(["rev-parse", "HEAD"]) or None
        if push:
            branch = _git_output(["rev-parse", "--abbrev-ref", "HEAD"]) or ""
            if branch and branch != "HEAD":
                subprocess.run(
                    ["git", "push", "origin", f"HEAD:{branch}"],
                    cwd=ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
            else:
                subprocess.run(
                    ["git", "push", "origin", "HEAD"],
                    cwd=ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
        return sha
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"WARNING: changelog consume git commit/push failed: {exc}", file=sys.stderr)
        return None


def maybe_consume_changelog_after_publish(
    *,
    enabled: bool,
    version_name: str,
    version_code: int | None,
) -> None:
    """Fold + delete fragments after FTP; commit so hybrid reset keeps the cut."""
    if not enabled:
        return
    result = consume_unreleased_after_publish(
        version_name=version_name,
        version_code=version_code,
    )
    deleted = list(result.get("deleted") or [])
    if not result.get("folded") and not deleted:
        print("Changelog consume: nothing to fold (Unreleased already empty)")
        return
    print(
        f"Changelog consume: folded into "
        f"{cut_version_token(version_name, version_code)}; "
        f"deleted {len(deleted)} fragment(s)"
    )
    sha = commit_consumed_changelog(
        version_name=version_name,
        version_code=version_code,
        deleted_names=[str(n) for n in deleted],
    )
    if sha:
        print(f"Changelog consume: committed {sha[:12]}")


def version_heading_idents(changelog_md: str) -> set[str]:
    idents: set[str] = set()
    for title, _body in split_changelog_sections(changelog_md):
        ident = parse_heading_ident(title)
        if ident and ident != "unreleased":
            idents.add(ident)
    return idents


def check_unreleased_not_edited(base_md: str, head_md: str) -> list[str]:
    """Fail when a PR still edits shared CHANGELOG.md Unreleased (unless a version cut).

    Allowed: identical Unreleased, emptying Unreleased (publish consume / fold under
    ``## version+build`` — marketing idents may already exist), or adding a new
    marketing version heading.
    """
    base_u = collapse_blank_lines(extract_unreleased_body(base_md))
    head_u = collapse_blank_lines(extract_unreleased_body(head_md))
    if base_u == head_u:
        return []
    # Publish consume clears Unreleased after folding under an existing X.Y.Z-dev line.
    if not head_u.strip():
        return []
    if version_heading_idents(head_md) - version_heading_idents(base_md):
        return []
    return [
        "This PR edits CHANGELOG.md ## Unreleased. Add a unique file under "
        "changelog/unreleased/ instead (e.g. changelog/unreleased/pr-my-fix.md). "
        "Editing Unreleased from every agent PR causes merge conflicts on dev."
    ]


def read_repo_changelog_md(
    path: Path | None = None,
    *,
    fragments_dir: Path | None = None,
    assemble_fragments: bool = True,
) -> str:
    changelog = path or (ROOT / "CHANGELOG.md")
    raw = changelog.read_text(encoding="utf-8") if changelog.is_file() else ""
    if assemble_fragments:
        return assemble_changelog_markdown(raw, fragments_dir=fragments_dir)
    return raw


def resolve_changelog(
    manual: str,
    *,
    version_name: str,
    auto: bool = True,
    channel: str = "stable",
    changelog_md: str = "",
    version_code: int | None = None,
    published_date: str | None = None,
) -> str:
    """Prefer assembled Unreleased fragments + CHANGELOG.md; git is a fallback."""
    manual = manual.strip()
    if re.fullmatch(r"Release v?[\w.+-]+", manual, flags=re.I):
        manual = ""

    ch = normalize_channel(channel)
    if ch == "dev" and is_dev_changelog_placeholder(manual):
        manual = ""
    manual = public_section_body(manual)

    file_notes = public_changelog_from_markdown(
        changelog_md,
        version_name=version_name,
        version_code=version_code,
        published_date=published_date,
    )
    if file_notes:
        # CHANGELOG.md is the payload. --changelog must not replace it.
        return file_notes
    if manual:
        return manual

    if ch == "dev":
        auto_text = build_dev_git_changelog() if auto else ""
        return auto_text or f"JAVP {version_name}"

    auto_text = build_git_changelog() if auto else ""
    return auto_text or f"JAVP {version_name}"


def parse_section_version(title: str) -> tuple[str | None, int | None]:
    """Parse ``0.4.2-dev+62 (date)`` → ``('0.4.2-dev', 62)``."""
    token = title.strip().split()[0] if title.strip() else ""
    match = _VERSION_IDENT.match(token)
    if not match:
        return None, None
    code = match.group("code")
    return match.group("name"), int(code) if code else None


def marketing_xy(version_name: str) -> tuple[int, int] | None:
    """``0.5.1`` / ``0.5.1-dev`` → ``(0, 5)`` for same-series rollup gates."""
    core = version_name.strip().split("-", 1)[0]
    match = re.match(r"^(\d+)\.(\d+)(?:\.|$)", core)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def count_public_bullets(text: str) -> int:
    return sum(
        1
        for line in public_section_body(text).splitlines()
        if line.lstrip().startswith("- ")
    )

def dedupe_h3_bullets(md: str) -> str:
    """Drop duplicate ``- `` bullets within each ### section (casefold)."""
    preamble, sections = split_h3_sections(md)
    chunks: list[str] = []
    if preamble.strip():
        chunks.append(preamble.strip())
    for title, body in sections:
        seen: set[str] = set()
        lines: list[str] = []
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("- "):
                key = re.sub(r"\s+", " ", stripped[2:].strip().casefold())
                if key in seen:
                    continue
                seen.add(key)
            lines.append(line)
        cleaned = collapse_blank_lines("\n".join(lines))
        chunks.append(f"### {title}\n\n{cleaned}" if cleaned else f"### {title}")
    return collapse_blank_lines("\n\n".join(chunks))

def collect_rollup_public_bodies(
    changelog_md: str,
    *,
    since_dev: str,
    min_code: int | None = None,
    max_code: int | None = None,
    also_sections: list[str] | None = None,
) -> list[str]:
    """Public bodies for ``since_dev+N`` (newest first) plus optional also-sections."""
    matched: list[tuple[int, str]] = []
    also_bodies: list[str] = []
    also_wanted = {s.strip() for s in (also_sections or []) if s.strip()}

    for title, body in split_changelog_sections(changelog_md):
        name, code = parse_section_version(title)
        public = public_section_body(body)
        if not public:
            continue
        full = title.strip()
        for want in list(also_wanted):
            if (
                full == want
                or full.startswith(want + " ")
                or full.startswith(want + " (")
            ):
                also_bodies.append(public)
                also_wanted.discard(want)
                break
        if name == since_dev and code is not None:
            if min_code is not None and code < min_code:
                continue
            if max_code is not None and code > max_code:
                continue
            matched.append((code, public))

    matched.sort(key=lambda item: item[0], reverse=True)
    return [body for _, body in matched] + also_bodies

def plan_stable_dev_rollup(changelog_md: str, stable_version: str) -> dict | None:
    """Detect orphan ``X.Y.Z-dev+N`` history that a marketing bump will miss.

    When publishing ``0.5.0``, matching only sees ``## 0.5.0*`` / ``0.5.0-dev*``.
    Notes under ``## 0.4.2-dev+N`` (and intermediate patches like ``0.4.3+57``)
    must be rolled up. Same-lineage ``0.4.2`` + ``0.4.2-dev`` needs no plan —
    ``heading_matches_publish_version`` already includes them.

    Patch follow-ups on an already-rolled line (``0.5.1`` after ``## 0.5.0``)
    must not pull that prior stable (and older ``-dev`` under it) forward again.
    """
    stable_version = stable_version.strip()
    if not stable_version or stable_version.endswith("-dev"):
        return None
    if any(
        parse_heading_ident(title) == f"{stable_version}-dev"
        for title, _body in split_changelog_sections(changelog_md)
    ):
        return None

    target_xy = marketing_xy(stable_version)
    also: list[str] = []
    since_dev: str | None = None
    codes: list[int] = []
    for title, body in split_changelog_sections(changelog_md):
        ident = parse_heading_ident(title)
        if not ident or ident == "unreleased":
            continue
        if ident == stable_version:
            continue
        name, code = parse_section_version(title)
        if name and name.endswith("-dev"):
            if since_dev is None:
                since_dev = name
            if name == since_dev:
                if code is not None:
                    codes.append(code)
                continue
            break
        # Other stable (e.g. 0.4.3 between 0.5.0 and 0.4.2-dev history).
        if since_dev is None:
            if not public_section_body(body):
                continue
            # Prior patch on this X.Y (0.5.0 when publishing 0.5.1) already
            # shipped the rolled history below — do not plan another roll-up.
            if target_xy is not None and marketing_xy(ident or "") == target_xy:
                return None
            token = title.strip().split()[0]
            if token and token not in also:
                also.append(token)
            continue
        break

    if not since_dev or not codes:
        return None
    return {
        "since_dev": since_dev,
        "min_code": min(codes),
        "max_code": max(codes),
        "also_sections": also,
    }

def orphan_dev_bullet_count(changelog_md: str, stable_version: str) -> int:
    plan = plan_stable_dev_rollup(changelog_md, stable_version)
    if not plan:
        return 0
    bodies = collect_rollup_public_bodies(
        changelog_md,
        since_dev=plan["since_dev"],
        min_code=plan["min_code"],
        max_code=plan["max_code"],
        also_sections=plan["also_sections"],
    )
    return sum(count_public_bullets(body) for body in bodies)

def matching_stable_bullet_count(changelog_md: str, version_name: str) -> int:
    return count_public_bullets(
        public_changelog_from_markdown(changelog_md, version_name=version_name)
    )

def stable_changelog_is_thin(
    changelog_md: str,
    version_name: str,
    *,
    min_orphan_bullets: int = 8,
    min_ratio: float = 0.45,
) -> tuple[bool, int, int]:
    """True when matching notes are << orphan ``-dev`` (+ intermediate) history."""
    matching = matching_stable_bullet_count(changelog_md, version_name)
    orphan = orphan_dev_bullet_count(changelog_md, version_name)
    if orphan < min_orphan_bullets:
        return False, matching, orphan
    return matching < orphan * min_ratio, matching, orphan

def rewrite_stable_changelog_section(
    base_md: str,
    *,
    version: str,
    date: str,
    section_body: str,
) -> str:
    """Replace Unreleased + same marketing ``## version`` block with rolled section."""
    preamble_lines: list[str] = []
    rest: list[str] = []
    rest_started = False
    for line in base_md.splitlines(True):
        if not rest_started and line.startswith("## "):
            rest_started = True
        if not rest_started:
            preamble_lines.append(line)
        else:
            rest.append(line)

    marketing = version.split("+", 1)[0]
    out_rest: list[str] = []
    i = 0
    while i < len(rest):
        line = rest[i]
        if line.startswith("## "):
            title = line[3:].strip()
            if title.lower().startswith("unreleased") or title.startswith(marketing):
                i += 1
                while i < len(rest) and not rest[i].startswith("## "):
                    i += 1
                continue
        out_rest.append(line)
        i += 1

    section = f"## {version} ({date})\n\n{section_body.strip()}\n"
    return (
        "".join(preamble_lines).rstrip()
        + "\n\n## Unreleased\n\n"
        + section
        + "\n"
        + "".join(out_rest).lstrip()
    ).rstrip() + "\n"

def build_stable_rollup_body(
    changelog_md: str,
    *,
    since_dev: str,
    min_code: int | None = None,
    max_code: int | None = None,
    also_sections: list[str] | None = None,
    include_unreleased: bool = True,
    preserve_version: str | None = None,
) -> str:
    unreleased = (
        public_section_body(assemble_unreleased_body(changelog_md))
        if include_unreleased
        else ""
    )
    # Keep bullets already folded into the thin matching stable section; rewrite
    # drops that H2, so they must be merged into the rolled body or they vanish.
    preserve_bodies: list[str] = []
    if preserve_version:
        marketing = preserve_version.split("+", 1)[0]
        for title, body in split_changelog_sections(changelog_md):
            if parse_heading_ident(title) == marketing:
                public = public_section_body(body)
                if public:
                    preserve_bodies.append(public)
    bodies = (
        ([unreleased] if unreleased.strip() else [])
        + preserve_bodies
        + collect_rollup_public_bodies(
            changelog_md,
            since_dev=since_dev,
            min_code=min_code,
            max_code=max_code,
            also_sections=also_sections,
        )
    )
    merged = dedupe_h3_bullets(merge_h3_markdown(bodies))
    if not merged.strip():
        raise ValueError("rollup produced an empty public body")
    return merged

def apply_stable_dev_rollup(
    changelog_md: str,
    *,
    stable_version: str,
    version_code: int | None = None,
    date: str | None = None,
    plan: dict | None = None,
) -> tuple[str, int]:
    """Return (updated CHANGELOG.md, public bullet count)."""
    plan = plan or plan_stable_dev_rollup(changelog_md, stable_version.split("+", 1)[0])
    if not plan:
        raise ValueError("no orphan -dev history to roll up")
    marketing = stable_version.split("+", 1)[0]
    cut = stable_version
    if "+" not in cut and version_code is not None:
        cut = f"{marketing}+{int(version_code)}"
    day = (date or datetime.now(timezone.utc).date().isoformat()).strip()[:10]
    body = build_stable_rollup_body(
        changelog_md,
        since_dev=plan["since_dev"],
        min_code=plan.get("min_code"),
        max_code=plan.get("max_code"),
        also_sections=list(plan.get("also_sections") or []),
        preserve_version=marketing,
    )
    updated = rewrite_stable_changelog_section(
        changelog_md,
        version=cut,
        date=day,
        section_body=body,
    )
    return updated, count_public_bullets(body)


# Default thinness gate for stable marketing bumps (see ensure_stable_changelog_rollup).
STABLE_ROLLUP_MIN_ORPHAN = 8
STABLE_ROLLUP_MIN_RATIO = 0.45

def ensure_stable_changelog_rollup(
    *,
    version_name: str,
    version_code: int | None = None,
    changelog_path: Path | None = None,
    fragments_dir: Path | None = None,
    write: bool = True,
    auto: bool = True,
    min_orphan_bullets: int = STABLE_ROLLUP_MIN_ORPHAN,
    min_ratio: float = STABLE_ROLLUP_MIN_RATIO,
) -> dict:
    """Auto-roll orphan ``-dev`` notes into the stable section when thin; else fail.

    Called on stable publish so a ``0.4.2-dev`` → ``0.5.0`` marketing bump cannot
    ship a 3-bullet ``latest.json``. Escape hatch: ``auto=False`` only preflights.

    After a successful roll-up, leftover + fragment notes (including Dev notes) are
    folded into the new cut heading and fragment files are deleted when
    ``write=True``. Otherwise the publish path would reassemble those fragments
    under ``## Unreleased`` and Discord would slice a thin retitled crumb block.
    """
    path = changelog_path or (ROOT / "CHANGELOG.md")
    frag_dir = fragments_dir or UNRELEASED_FRAGMENTS_DIR
    raw = path.read_text(encoding="utf-8") if path.is_file() else ""
    marketing = version_name.strip()
    if marketing.endswith("-dev"):
        return {
            "action": "skipped",
            "reason": "dev-channel",
            "matching": matching_stable_bullet_count(raw, marketing),
            "orphan": 0,
        }

    thin, matching, orphan = stable_changelog_is_thin(
        raw,
        marketing,
        min_orphan_bullets=min_orphan_bullets,
        min_ratio=min_ratio,
    )
    if not thin:
        return {
            "action": "ok",
            "matching": matching,
            "orphan": orphan,
            "path": str(path),
        }

    plan = plan_stable_dev_rollup(raw, marketing)
    detail = (
        f"Stable {marketing} changelog is thin ({matching} matching bullets vs "
        f"{orphan} orphan -dev/intermediate). "
    )
    if plan:
        detail += (
            f"Need roll-up of {plan['since_dev']}+"
            f"{plan['min_code']}..{plan['max_code']}"
            + (
                f" + also {plan['also_sections']}"
                if plan.get("also_sections")
                else ""
            )
            + "."
        )
    if not auto:
        raise SystemExit(
            detail
            + " Run: python3 tool/rollup_dev_changelog.py --auto --write"
        )
    if not plan:
        raise SystemExit(detail + " No auto roll-up plan available.")

    # Capture full Unreleased (public + Dev notes) before rewrite clears it.
    assembled = assemble_unreleased_body(raw, fragments_dir=frag_dir)
    updated, bullets = apply_stable_dev_rollup(
        raw,
        stable_version=marketing,
        version_code=version_code,
        plan=plan,
    )
    if assembled.strip():
        updated = fold_unreleased_into_version(
            updated,
            version_name=marketing,
            version_code=version_code,
            unreleased_body=assembled,
        )
    if write:
        path.write_text(updated, encoding="utf-8")
        # Fragments were folded into the cut — remove so publish won't reassemble.
        delete_unreleased_fragments(frag_dir)

    thin_after, matching_after, orphan_after = stable_changelog_is_thin(
        updated,
        marketing,
        min_orphan_bullets=min_orphan_bullets,
        min_ratio=min_ratio,
    )
    if thin_after:
        raise SystemExit(
            f"After auto roll-up, stable {marketing} is still thin "
            f"({matching_after} vs {orphan_after} orphan). Inspect CHANGELOG.md."
        )
    print(
        f"Stable changelog auto-rollup: wrote {bullets} public bullets into "
        f"{marketing}+{version_code if version_code is not None else '?'} "
        f"(was {matching} matching vs {orphan} orphan)"
    )
    return {
        "action": "rolled",
        "matching_before": matching,
        "orphan": orphan,
        "bullets": bullets,
        "matching_after": matching_after,
        "plan": plan,
        "path": str(path),
        "updated": updated,
    }


# Flutter --split-per-abi encodes versionCode as abiIndex * 1000 + build.
# See flutter_tools/gradle FlutterPluginConstants.ABI_VERSION.
_FLUTTER_ABI_VERSION = {
    "armeabi-v7a": 1,
    "arm64-v8a": 2,
    "x86_64": 3,
    "x86": 4,
}


def flutter_split_version_code(abi: str | None, base_version_code: int) -> int:
    """Match the versionCode Flutter writes into split APKs."""
    if not abi or abi == "universal":
        return base_version_code
    abi_index = _FLUTTER_ABI_VERSION.get(abi)
    if abi_index is None:
        return base_version_code
    return abi_index * 1000 + base_version_code


def build_manifest(
    *,
    version_name: str,
    version_code: int,
    apk_url: str,
    changelog: str,
    force: bool,
    min_version_code: int | None,
    apk_sha256: str | None,
    apks: dict[str, dict[str, str]] | None = None,
    packages: dict[str, dict[str, str]] | None = None,
    channel: str = "stable",
    base_version_code: int | None = None,
    git_commit: str | None = None,
    releases: list[dict] | None = None,
) -> dict:
    # Old sideload builds compare versionCode with the *encoded* split value
    # (arm64 0.2.4+6 → 2006). Advertise arm64 encoding at the top level so
    # those clients see an update; [baseVersionCode] is the pubspec +N for
    # newer clients that normalize ABI offsets.
    base = base_version_code if base_version_code is not None else version_code
    advertised = version_code
    if apks and "arm64-v8a" in apks and advertised < 1000:
        advertised = flutter_split_version_code("arm64-v8a", base)

    payload: dict = {
        "versionName": version_name,
        "versionCode": advertised,
        "baseVersionCode": base,
        "apkUrl": apk_url,
        "changelog": changelog,
        "force": force,
        "channel": normalize_channel(channel),
        "publishedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    if releases:
        payload["releases"] = releases
    if git_commit and _GIT_SHA_RE.fullmatch(git_commit.strip()):
        payload["gitCommit"] = git_commit.strip()
    if min_version_code is not None:
        payload["minVersionCode"] = min_version_code
    if apk_sha256:
        payload["apkSha256"] = apk_sha256
    if apks:
        # Annotate each split with the versionCode Android will install.
        enriched: dict[str, dict[str, str]] = {}
        for abi, entry in apks.items():
            row = dict(entry)
            row.setdefault(
                "versionCode",
                str(flutter_split_version_code(abi, base)),
            )
            enriched[abi] = row
        payload["apks"] = enriched
    if packages:
        # Desktop packages have no ABI split, so the top-level versionCode
        # applies as-is.
        payload["packages"] = packages
    return payload


def _ftp_credentials() -> tuple[str, int, str, str, str]:
    host = _env("JAVP_FTP_HOST")
    port = int(os.environ.get("JAVP_FTP_PORT") or "21")
    user = os.environ.get("JAVP_FTP_USER") or "javp"
    password = _env("JAVP_FTP_PASS")
    remote_dir = os.environ.get("JAVP_FTP_DIR", "/")
    return host, port, user, password, remote_dir


def _remote_tmp_name(remote_name: str) -> str:
    """Atomic upload temp name that keeps subdirectory prefixes intact."""
    remote_path = Path(remote_name)
    return str(remote_path.with_name(f".{remote_path.name}.uploading")).replace("\\", "/")


def _remote_parent_dirs(local_files: list[tuple[Path, str]]) -> list[str]:
    dirs = sorted(
        {
            str(Path(remote_name).parent).replace("\\", "/")
            for _, remote_name in local_files
            if Path(remote_name).parent != Path(".")
        }
    )
    return dirs


def _ftp_ensure_dir(ftp, directory: str) -> None:
    """Create `a/b/c` under the current FTP cwd, ignoring already-exists errors."""
    parts = [p for p in directory.replace("\\", "/").split("/") if p and p != "."]
    if not parts:
        return
    for i in range(len(parts)):
        partial = "/".join(parts[: i + 1])
        try:
            ftp.mkd(partial)
        except Exception:
            pass


def upload_with_ftplib(local_files: list[tuple[Path, str]]) -> None:
    """Atomic put via Python's stdlib — works on Windows without lftp."""
    from ftplib import FTP

    host, port, user, password, remote_dir = _ftp_credentials()
    print(
        f"Uploading {len(local_files)} file(s) via ftplib to "
        f"{host}:{port} deploy root {remote_dir!r}"
    )
    with FTP() as ftp:
        ftp.connect(host, port, timeout=120)
        ftp.login(user, password)
        ftp.set_pasv(True)
        if remote_dir not in ("", ".", "/"):
            ftp.cwd(remote_dir)
        for directory in _remote_parent_dirs(local_files):
            _ftp_ensure_dir(ftp, directory)
        for local, remote_name in local_files:
            tmp_name = _remote_tmp_name(remote_name)
            size_mb = local.stat().st_size / (1024 * 1024)
            print(f"  -> {remote_name} ({size_mb:.1f} MB)")
            with local.open("rb") as fh:
                ftp.storbinary(f"STOR {tmp_name}", fh, blocksize=1024 * 256)
            try:
                ftp.delete(remote_name)
            except Exception:
                pass
            ftp.rename(tmp_name, remote_name)


def upload_with_lftp(local_files: list[tuple[Path, str]]) -> None:
    host, port, user, password, remote_dir = _ftp_credentials()

    if shutil.which("lftp") is None:
        upload_with_ftplib(local_files)
        return

    commands = [
        "set ssl:verify-certificate no",
        "set ftp:ssl-allow no",
        "set ftp:passive-mode true",
        "set net:timeout 120",
        "set net:max-retries 5",
        "set net:persist-retries 5",
        f"cd {remote_dir}" if remote_dir not in ("", ".") else "",
    ]
    for directory in _remote_parent_dirs(local_files):
        commands.append(f"mkdir -p -f {directory}")
    for local, remote_name in local_files:
        tmp_name = _remote_tmp_name(remote_name)
        commands.append(f"put {local.as_posix()} -o {tmp_name}")
        commands.append(f"rm -f {remote_name}")
        commands.append(f"mv {tmp_name} {remote_name}")
    commands.append("bye")
    script = "; ".join(c for c in commands if c)

    cmd = [
        "lftp",
        "-u",
        f"{user},{password}",
        "-e",
        script,
        f"ftp://{host}:{port}",
    ]
    print(f"Uploading {len(local_files)} file(s) via FTP to deploy root {remote_dir!r}")
    subprocess.check_call(cmd)


def cleanup_old_versioned_artifacts(
    *,
    remote_prefix: str = "",
    keep: int = 3,
    protected_codes: set[int] | frozenset[int] | None = None,
) -> None:
    """Delete versioned updater artifacts older than the newest [keep] releases.

    Short names / site files are never removed, and neither are artifacts for
    versionCodes still referenced by the manifest ``releases[]``
    ([protected_codes]). Runs over FTP with the same credentials as publish
    (ftplib so it works after an lftp upload too).
    """
    from ftplib import FTP

    if keep < 1:
        raise SystemExit("--keep-versions must be >= 1")

    host, port, user, password, remote_dir = _ftp_credentials()
    prefix = remote_prefix.strip("/")
    print(
        f"Pruning versioned artifacts (keep last {keep}) "
        f"under {remote_dir!r}/{prefix or '.'}"
    )

    with FTP() as ftp:
        ftp.connect(host, port, timeout=120)
        ftp.login(user, password)
        ftp.set_pasv(True)
        if remote_dir not in ("", ".", "/"):
            ftp.cwd(remote_dir)
        if prefix:
            _ftp_ensure_dir(ftp, prefix)
            ftp.cwd(prefix)

        try:
            listing = ftp.nlst()
        except Exception as exc:
            print(f"  warning: could not list remote dir for cleanup: {exc}")
            return

        basenames = [Path(item).name for item in listing]
        to_delete = plan_versioned_cleanup(
            basenames,
            keep=keep,
            protected_codes=protected_codes,
        )
        if not to_delete:
            print("  nothing to prune")
            return

        present_codes: set[int] = set()
        for name in basenames:
            parsed = parse_versioned_artifact(name)
            if parsed is not None:
                present_codes.add(parsed[1])
        kept = sorted(present_codes, reverse=True)[:keep]
        print(f"  keeping versionCodes: {', '.join(str(c) for c in kept) or '(none)'}")
        print(f"  deleting {len(to_delete)} file(s)")
        for name in to_delete:
            try:
                ftp.delete(name)
                print(f"  - {name}")
            except Exception as exc:
                print(f"  ! failed to delete {name}: {exc}")


def build_release_apks(
    *,
    channel: str = "stable",
    skip_universal: bool | None = None,
    arm64_only: bool | None = None,
) -> Path:
    """Build per-ABI APKs (and optionally the fat universal APK).

    Dev defaults to arm64-only + skip_universal for a fast publish path.
    """
    channel = normalize_channel(channel)
    if arm64_only is None:
        arm64_only = channel == "dev"
    if skip_universal is None:
        skip_universal = channel == "dev"

    build_args = channel_build_args(channel)
    platforms = SPLIT_TARGET_PLATFORMS_ARM64 if arm64_only else SPLIT_TARGET_PLATFORMS
    env = os.environ.copy()
    if arm64_only:
        env.setdefault("ORG_GRADLE_PROJECT_mediaKitAndroidAbis", "arm64-v8a")
        env.setdefault("ORG_GRADLE_PROJECT_rqbitEngineAbis", "arm64-v8a")
        env.setdefault("MEDIA_KIT_ANDROID_ABIS", "arm64-v8a")

    out = ROOT / "build/app/outputs/flutter-apk"
    flavor = channel_android_flavor(channel)
    print(
        f"Building per-ABI release APKs ({flavor}, channel={channel}"
        f"{', arm64-only' if arm64_only else ''})…"
    )
    subprocess.check_call(
        [
            "flutter",
            "build",
            "apk",
            "--release",
            "--split-per-abi",
            "--target-platform",
            platforms,
            *build_args,
        ],
        cwd=ROOT,
        env=env,
    )
    if not skip_universal:
        print(f"Building universal release APK ({flavor}, channel={channel})…")
        subprocess.check_call(
            ["flutter", "build", "apk", "--release", *build_args],
            cwd=ROOT,
            env=env,
        )
    return out


def _flavor_split_rows(flavor: str) -> tuple[tuple[tuple[str, str, str], ...], ...]:
    if flavor == "sideloadDev":
        return (SPLIT_APKS_DEV, SPLIT_APKS_FLAVOR_ABI_DEV)
    return (SPLIT_APKS, SPLIT_APKS_FLAVOR_ABI)


def _apksigner_bin() -> str | None:
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        root = os.environ.get(env)
        if not root:
            continue
        build_tools = Path(root) / "build-tools"
        if not build_tools.is_dir():
            continue
        versions = sorted(
            (p for p in build_tools.iterdir() if p.is_dir()),
            key=lambda p: p.name,
            reverse=True,
        )
        for ver in versions:
            candidate = ver / "apksigner"
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
    which = shutil.which("apksigner")
    return which


def apk_signer_identity(apk: Path) -> str:
    """Return a human-readable signer summary for an APK (best effort)."""
    apksigner = _apksigner_bin()
    if apksigner:
        try:
            out = subprocess.check_output(
                [apksigner, "verify", "--print-certs", str(apk)],
                stderr=subprocess.STDOUT,
                text=True,
            )
            return out
        except subprocess.CalledProcessError as exc:
            return exc.output or str(exc)

    # Fallback: v1 META-INF/*.RSA / *.DSA / *.EC via openssl.
    try:
        with zipfile.ZipFile(apk) as zf:
            cert_names = [
                n
                for n in zf.namelist()
                if n.upper().startswith("META-INF/")
                and n.upper().endswith((".RSA", ".DSA", ".EC"))
            ]
            if not cert_names:
                return "(no v1 cert in APK; install Android build-tools apksigner)"
            chunks: list[str] = []
            for name in cert_names:
                data = zf.read(name)
                with tempfile.NamedTemporaryFile(suffix=".der") as tmp:
                    tmp.write(data)
                    tmp.flush()
                    try:
                        pem = subprocess.check_output(
                            [
                                "openssl",
                                "pkcs7",
                                "-inform",
                                "DER",
                                "-in",
                                tmp.name,
                                "-print_certs",
                            ],
                            stderr=subprocess.DEVNULL,
                        )
                        subj = subprocess.check_output(
                            ["openssl", "x509", "-noout", "-subject", "-fingerprint", "-sha256"],
                            input=pem,
                            stderr=subprocess.DEVNULL,
                        )
                        chunks.append(subj.decode("utf-8", errors="replace"))
                    except (subprocess.CalledProcessError, FileNotFoundError):
                        chunks.append(f"{name}: (openssl unavailable)")
            return "\n".join(chunks)
    except zipfile.BadZipFile as exc:
        return f"(invalid APK: {exc})"


def assert_release_signed_apks(paths: list[Path]) -> None:
    """Abort if any APK is signed with the Android Debug certificate."""
    if not paths:
        raise SystemExit("No APKs to verify for release signing")
    for apk in paths:
        if not apk.is_file():
            raise SystemExit(f"APK missing for signing check: {apk}")
        identity = apk_signer_identity(apk)
        print(f"Signing check: {apk.name}")
        for line in identity.strip().splitlines()[:8]:
            print(f"  {line}")
        lower = identity.lower()
        if any(marker.lower() in lower for marker in _DEBUG_SIGNER_MARKERS):
            raise SystemExit(
                f"Refusing to publish debug-signed APK: {apk}\n"
                "Install android/key.properties + upload-keystore.jks "
                "(see docs/play-store.md) or set ANDROID_KEYSTORE_* CI secrets."
            )
        if "signer #" not in lower and "subject=" not in lower and "cn=" not in lower:
            raise SystemExit(
                f"Could not read signing cert for {apk} — install apksigner "
                "(Android SDK build-tools) before publishing."
            )
    print(f"OK — {len(paths)} APK(s) are not Android Debug-signed")


def collect_apks(
    apk_dir: Path,
    *,
    require_universal: bool,
    flavor: str = "sideload",
) -> dict[str, tuple[Path, str]]:
    """Return abi_key → (local_path, remote_filename)."""
    found: dict[str, tuple[Path, str]] = {}

    # Only accept APKs for the requested flavor. Falling back to the other
    # sideload* flavor (or a leftover stable build in the same folder) once
    # published a Dev armv7/universal signed as stable packaging.
    for rows in _flavor_split_rows(flavor):
        for abi, build_name, remote_name in rows:
            if abi in found:
                continue
            path = apk_dir / build_name
            if path.exists():
                found[abi] = (path.resolve(), remote_name)

    # Unflavored Flutter names are only valid for stable sideload.
    if flavor == "sideload":
        for abi, build_name, remote_name in SPLIT_APKS_LEGACY:
            if abi in found:
                continue
            path = apk_dir / build_name
            if path.exists():
                found[abi] = (path.resolve(), remote_name)

    uni_candidates: list[str] = []
    if flavor == "sideloadDev":
        uni_candidates.append(UNIVERSAL_BUILD_DEV[1])
    else:
        uni_candidates.extend(
            (
                UNIVERSAL_BUILD[1],
                UNIVERSAL_BUILD_LEGACY[1],
                UNIVERSAL_BUILD[2],
            )
        )
    # De-dupe while preserving order.
    seen_uni: set[str] = set()
    ordered_uni: list[str] = []
    for name in uni_candidates:
        if name not in seen_uni:
            seen_uni.add(name)
            ordered_uni.append(name)

    uni_path = next(
        (apk_dir / name for name in ordered_uni if (apk_dir / name).exists()),
        None,
    )
    if uni_path is not None:
        found["universal"] = (uni_path.resolve(), UNIVERSAL_BUILD[2])
    elif require_universal:
        expected = ", ".join(ordered_uni[:3])
        raise SystemExit(f"Universal APK missing under {apk_dir} (expected {expected})")

    if not any(k != "universal" for k in found):
        # Legacy single-APK publish: treat provided universal-only as fine.
        if "universal" in found:
            return found
        raise SystemExit(
            f"No split APKs found under {apk_dir}. "
            "Run: flutter build apk --release --split-per-abi "
            f"--flavor {flavor} --dart-define=JAVP_DISTRIBUTION=sideload "
            f"--dart-define=JAVP_UPDATE_CHANNEL="
            f"{'dev' if flavor == 'sideloadDev' else 'stable'}"
        )
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish JAVP update to updater.javp.app")
    parser.add_argument(
        "--channel",
        default=os.environ.get("JAVP_UPDATE_CHANNEL", "stable"),
        help="Update channel: stable (default) or dev",
    )
    parser.add_argument("--apk", type=Path, help="Path to a single (universal) APK")
    parser.add_argument(
        "--apk-dir",
        type=Path,
        help="Directory with Flutter APK outputs (split + optional universal)",
    )
    parser.add_argument(
        "--check-apk-signing",
        action="store_true",
        help="Verify APKs are not Android Debug-signed, then exit (no FTP)",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Run flutter build apk --split-per-abi and a universal build",
    )
    parser.add_argument(
        "--skip-universal",
        action="store_true",
        help="With --build, skip the fat universal APK (Dev default)",
    )
    parser.add_argument(
        "--with-universal",
        action="store_true",
        help="With --build, force the fat universal APK even for Dev",
    )
    parser.add_argument(
        "--fat-apk",
        action="store_true",
        help="With --build, include all ABIs (default for stable; Dev is arm64-only)",
    )
    parser.add_argument(
        "--manifest-only",
        action="store_true",
        help="Only upload latest.json (changelog overlay; keeps live gitCommit/APKs)",
    )
    parser.add_argument(
        "--git-commit",
        default="",
        help="Git SHA of the binaries (default: build sidecar, else live SHA on "
        "manifest-only / same-hash republish, else HEAD)",
    )
    parser.add_argument(
        "--allow-same-version",
        action="store_true",
        help="Allow overwriting a live Dev +N with a different git tree (default: refuse)",
    )
    parser.add_argument("--apk-url", help="Override legacy apkUrl written into latest.json")
    parser.add_argument(
        "--changelog",
        default="",
        help="Optional highlight; ignored when CHANGELOG.md / fragments have notes",
    )
    parser.add_argument(
        "--changelog-file",
        type=Path,
        help="Full CHANGELOG.md (merged with changelog/unreleased/) or a snippet",
    )
    parser.add_argument(
        "--no-auto-changelog",
        action="store_true",
        help="Do not fall back to git history when changelog fragments / "
        "CHANGELOG.md have no matching section",
    )
    parser.add_argument("--force", action="store_true", help="Mark update as required")
    parser.add_argument("--min-version-code", type=int, help="Minimum supported versionCode")
    parser.add_argument("--version-name", help="Override versionName (default: pubspec)")
    parser.add_argument("--version-code", type=int, help="Override versionCode (default: pubspec)")
    parser.add_argument(
        "--skip-versioned-apk",
        action="store_true",
        help="Do not upload javp-{version}+{code}.apk (Dev default)",
    )
    parser.add_argument(
        "--keep-versioned-apk",
        action="store_true",
        help="Force uploading the versioned APK archive copy",
    )
    parser.add_argument(
        "--keep-versions",
        type=int,
        default=3,
        metavar="N",
        help="After publish, keep versioned artifacts for the newest N releases "
        "(default: 3). Artifacts still referenced by latest.json releases[] are "
        "always kept so changelog history never points at a missing file.",
    )
    parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="Do not prune old versioned artifacts after publish",
    )
    parser.add_argument(
        "--windows-zip",
        type=Path,
        help="Windows Release zip to publish as packages.windows-x64",
    )
    parser.add_argument(
        "--windows-arm64-zip",
        type=Path,
        help="Windows ARM64 Release zip to publish as packages.windows-arm64",
    )
    parser.add_argument(
        "--windows-installer",
        type=Path,
        help="Windows Inno Setup exe to publish as packages.windows-x64-setup",
    )
    parser.add_argument(
        "--linux-zip",
        type=Path,
        help="Linux bundle zip to publish as packages.linux-x64",
    )
    parser.add_argument(
        "--linux-arm64-zip",
        type=Path,
        help="Linux ARM64 bundle zip to publish as packages.linux-arm64",
    )
    parser.add_argument(
        "--macos-zip",
        type=Path,
        help="macOS .app zip to publish as packages.macos-arm64 (Apple Silicon)",
    )
    parser.add_argument(
        "--macos-x64-zip",
        type=Path,
        help="macOS .app zip to publish as packages.macos-x64 (Intel)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Write files locally, skip FTP")
    parser.add_argument(
        "--no-site",
        action="store_true",
        help="Do not upload download.html / logo",
    )
    parser.add_argument(
        "--no-consume-changelog",
        action="store_true",
        help=(
            "Do not fold Unreleased/fragments into CHANGELOG.md after a "
            "successful publish (default: consume so the next cut is empty)"
        ),
    )
    parser.add_argument(
        "--no-stable-rollup",
        action="store_true",
        help="Skip auto roll-up of orphan -dev CHANGELOG sections on stable "
        "(still fails the thin-notes preflight unless --skip-stable-rollup-preflight)",
    )
    parser.add_argument(
        "--skip-stable-rollup-preflight",
        action="store_true",
        help="Do not fail stable publish when matching notes look thin vs -dev history "
        "(emergency escape hatch)",
    )
    parser.add_argument(
        "--ensure-stable-changelog",
        action="store_true",
        help="Only run stable -dev roll-up / thin-notes preflight, then exit "
        "(used by local_release.sh before long builds)",
    )
    args = parser.parse_args()
    if args.keep_versions < 1:
        raise SystemExit("--keep-versions must be >= 1")

    channel = normalize_channel(args.channel)
    remote_prefix = channel_remote_prefix(channel)
    flavor = channel_android_flavor(channel)
    # Always publish versioned APK + desktop names and point latest.json at
    # them (CDN cache-bust). Short aliases still upload for the download page.
    # --skip-versioned-apk is an emergency opt-out only; Dev no longer skips.
    skip_versioned = bool(args.skip_versioned_apk) and not args.keep_versioned_apk
    no_site = args.no_site

    if args.with_universal:
        skip_universal: bool | None = False
    elif args.skip_universal or channel == "dev":
        skip_universal = True
    else:
        skip_universal = False

    version_name, version_code = read_pubspec_version()
    if args.version_name:
        version_name = args.version_name
    if args.version_code is not None:
        version_code = args.version_code
    if channel == "dev" and not version_name.endswith("-dev"):
        # Match Android versionNameSuffix for the installed "JAVP Dev" binary.
        version_name = f"{version_name}-dev"

    if channel == "stable" and not args.skip_stable_rollup_preflight:
        # Marketing bumps (0.4.2-dev → 0.5.0) miss ## *-dev+N headings unless
        # rolled up. Auto-write CHANGELOG.md, then refuse to publish if still thin.
        rollup_result = ensure_stable_changelog_rollup(
            version_name=version_name,
            version_code=version_code,
            write=not args.dry_run,
            auto=not args.no_stable_rollup,
        )
        if args.ensure_stable_changelog:
            print("Stable changelog roll-up / thin-notes preflight OK")
            return 0
    elif args.ensure_stable_changelog:
        print("Skipping stable changelog ensure (channel is not stable)")
        return 0
    else:
        rollup_result = None

    changelog_md = ""
    manual_changelog = args.changelog
    if args.changelog_file:
        file_text = args.changelog_file.read_text(encoding="utf-8")
        if looks_like_full_changelog(file_text):
            changelog_md = assemble_changelog_markdown(file_text)
        else:
            manual_changelog = file_text
    else:
        changelog_md = read_repo_changelog_md()
    if (
        rollup_result
        and rollup_result.get("action") == "rolled"
        and args.dry_run
        and rollup_result.get("updated")
    ):
        # dry-run did not write / delete fragments — use the in-memory roll-up
        # (already folded; do not reassemble on-disk fragments into Unreleased).
        changelog_md = rollup_result["updated"]
    changelog = resolve_changelog(
        manual_changelog,
        version_name=version_name,
        auto=not args.no_auto_changelog,
        channel=channel,
        changelog_md=changelog_md,
        version_code=version_code,
    )
    releases = resolve_changelog_releases(
        version_name=version_name,
        changelog_md=changelog_md,
        changelog=changelog,
        version_code=version_code,
        channel=channel,
    )

    public_base = os.environ.get("JAVP_PUBLIC_BASE", "https://updater.javp.app").rstrip("/")
    live_manifest = fetch_live_manifest(channel)
    head_sha = _git_output(["rev-parse", "HEAD"]) or None

    if args.manifest_only:
        if not live_manifest:
            raise SystemExit(
                "--manifest-only needs a reachable live latest.json "
                "(or publish APKs first)"
            )
        git_commit = resolve_artifact_git_commit(
            channel=channel,
            head=head_sha,
            explicit=args.git_commit or None,
            sidecar_commit=None,
            live=live_manifest,
            hashes_match_live=True,
            built_now=False,
            manifest_only=True,
        )
        manifest = apply_manifest_only_overlay(
            live_manifest,
            changelog=changelog,
            git_commit=git_commit,
            releases=releases,
        )
        extra_uploads: list[tuple[Path, str]] = []
        live_name = str(manifest.get("versionName") or version_name)
        live_code = live_base_version_code(manifest) or version_code

        def attach_package(
            path: Path,
            *,
            key: str,
            short_name: str,
            suffix: str,
            kind: str,
        ) -> None:
            nonlocal manifest
            resolved = path.resolve()
            if not resolved.is_file():
                raise SystemExit(f"{key} package not found: {resolved}")
            digest = sha256_file(resolved)
            versioned = f"javp-{live_name}+{live_code}-{suffix}"
            extra_uploads.append((resolved, f"{remote_prefix}{short_name}"))
            extra_uploads.append((resolved, f"{remote_prefix}{versioned}"))
            manifest = merge_live_package(
                manifest,
                key=key,
                url=channel_apk_url(public_base, channel, versioned),
                sha256=digest,
                kind=kind,
            )

        if args.windows_zip:
            attach_package(
                args.windows_zip,
                key="windows-x64",
                short_name="javp-windows-x64.zip",
                suffix="windows-x64.zip",
                kind="zip",
            )
        if args.windows_installer:
            attach_package(
                args.windows_installer,
                key="windows-x64-setup",
                short_name="javp-setup.exe",
                suffix="setup.exe",
                kind="exe",
            )
        if args.linux_zip:
            attach_package(
                args.linux_zip,
                key="linux-x64",
                short_name="javp-linux-x64.zip",
                suffix="linux-x64.zip",
                kind="zip",
            )
        if args.linux_arm64_zip:
            attach_package(
                args.linux_arm64_zip,
                key="linux-arm64",
                short_name="javp-linux-arm64.zip",
                suffix="linux-arm64.zip",
                kind="zip",
            )
        if args.windows_arm64_zip:
            attach_package(
                args.windows_arm64_zip,
                key="windows-arm64",
                short_name="javp-windows-arm64.zip",
                suffix="windows-arm64.zip",
                kind="zip",
            )
        if args.macos_zip:
            attach_package(
                args.macos_zip,
                key="macos-arm64",
                short_name="javp-macos-arm64.zip",
                suffix="macos-arm64.zip",
                kind="zip",
            )
        if args.macos_x64_zip:
            attach_package(
                args.macos_x64_zip,
                key="macos-x64",
                short_name="javp-macos-x64.zip",
                suffix="macos-x64.zip",
                kind="zip",
            )
        if no_site:
            print("Skipping site upload (--no-site)")
        with tempfile.TemporaryDirectory(prefix="javp-deploy-") as tmp:
            tmp_dir = Path(tmp)
            latest_path = tmp_dir / "latest.json"
            latest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            print(latest_path.read_text(encoding="utf-8"))
            uploads = [*extra_uploads, (latest_path, f"{remote_prefix}latest.json")]
            if args.dry_run:
                print("Dry run — skip FTP")
                return 0
            time.sleep(0.5)
            if os.environ.get("JAVP_FTP_BACKEND", "ftplib").lower() == "lftp":
                upload_with_lftp(uploads)
            else:
                upload_with_ftplib(uploads)
            if not args.no_cleanup:
                cleanup_old_versioned_artifacts(
                    remote_prefix=remote_prefix,
                    keep=args.keep_versions,
                    protected_codes=release_version_codes(releases),
                )
        maybe_consume_changelog_after_publish(
            enabled=not args.no_consume_changelog,
            version_name=version_name,
            version_code=live_code,
        )
        print(f"Published {live_name}+{live_code} ({channel}) [manifest-only]")
        print(f"Manifest: {channel_manifest_url(public_base, channel)}")
        return 0

    apk_map: dict[str, tuple[Path, str]] = {}
    artifact_dir: Path | None = None
    built_now = False
    build_sha = head_sha
    if args.build:
        build_sha = _git_output(["rev-parse", "HEAD"]) or None
        out_dir = build_release_apks(
            channel=channel,
            skip_universal=skip_universal,
            arm64_only=(False if args.fat_apk else None),
        )
        artifact_dir = out_dir
        built_now = True
        write_build_meta(
            out_dir,
            git_commit=build_sha,
            version_name=version_name,
            version_code=version_code,
        )
        apk_map = collect_apks(
            out_dir,
            require_universal=not skip_universal,
            flavor=flavor,
        )
    elif args.apk_dir:
        apk_dir = args.apk_dir.resolve()
        artifact_dir = apk_dir
        try:
            apk_map = collect_apks(
                apk_dir,
                require_universal=False,
                flavor=flavor,
            )
        except SystemExit:
            # Signing checks often omit --channel; accept either sideload flavor.
            if not args.check_apk_signing:
                raise
            other = "sideload" if flavor == "sideloadDev" else "sideloadDev"
            apk_map = collect_apks(
                apk_dir,
                require_universal=False,
                flavor=other,
            )
    elif args.apk:
        apk_map = {"universal": (args.apk.resolve(), "javp.apk")}
    elif args.check_apk_signing:
        raise SystemExit("Provide --apk-dir PATH or --apk PATH with --check-apk-signing")
    elif not args.manifest_only:
        raise SystemExit("Provide --build, --apk-dir PATH, --apk PATH, or --manifest-only")

    if apk_map:
        assert_release_signed_apks([path for path, _remote in apk_map.values()])
    if args.check_apk_signing:
        return 0

    # Legacy apkUrl stays on universal when present so older app builds keep working.
    if "universal" in apk_map:
        default_key = "universal"
    elif "arm64-v8a" in apk_map:
        default_key = "arm64-v8a"
    else:
        default_key = next(iter(apk_map), "universal")

    # Cloudflare edge-caches immutable artifact paths for a long time. Point
    # latest.json at versioned filenames (APK + desktop) so a new release
    # cannot get a HIT on the previous body. Short aliases still upload for
    # the download page / deep links.
    def versioned_remote(stable_name: str) -> str:
        stem = Path(stable_name).stem
        return f"{stem}-{version_name}+{version_code}.apk"

    default_path, default_remote = apk_map.get(default_key, (None, "javp.apk"))
    default_public = (
        versioned_remote(default_remote)
        if default_remote and not skip_versioned
        else (default_remote or "javp.apk")
    )
    apk_url = args.apk_url or channel_apk_url(public_base, channel, default_public)
    apk_sha = sha256_file(default_path) if default_path else None

    apks_manifest: dict[str, dict[str, str]] = {}
    for abi, (path, remote) in apk_map.items():
        public_name = versioned_remote(remote) if not skip_versioned else remote
        apks_manifest[abi] = {
            "url": channel_apk_url(public_base, channel, public_name),
            "sha256": sha256_file(path),
        }

    packages_manifest: dict[str, dict[str, str]] = {}
    # (local path, stable remote name, versioned stem suffix, package key, kind)
    desktop_uploads: list[tuple[Path, str, str, str, str]] = []

    def add_desktop_package(
        path: Path,
        *,
        key: str,
        remote: str,
        versioned_suffix: str,
        kind: str,
    ) -> None:
        """Publish a stable short name plus a versioned cache-bust URL in latest.json."""
        if not path.exists():
            raise SystemExit(f"{key} package not found: {path}")
        desktop_uploads.append((path, remote, versioned_suffix, key, kind))
        # Match APKs: point clients at the versioned filename so a Cloudflare
        # HIT on the previous body cannot cause sha256 mismatches.
        public_name = (
            f"javp-{version_name}+{version_code}-{versioned_suffix}"
            if not skip_versioned
            else remote
        )
        packages_manifest[key] = {
            "url": channel_apk_url(public_base, channel, public_name),
            "sha256": sha256_file(path),
            "kind": kind,
        }

    if args.windows_zip:
        add_desktop_package(
            args.windows_zip.resolve(),
            key="windows-x64",
            remote="javp-windows-x64.zip",
            versioned_suffix="windows-x64.zip",
            kind="zip",
        )
    if args.windows_arm64_zip:
        add_desktop_package(
            args.windows_arm64_zip.resolve(),
            key="windows-arm64",
            remote="javp-windows-arm64.zip",
            versioned_suffix="windows-arm64.zip",
            kind="zip",
        )
    if args.windows_installer:
        add_desktop_package(
            args.windows_installer.resolve(),
            key="windows-x64-setup",
            remote="javp-setup.exe",
            versioned_suffix="setup.exe",
            kind="exe",
        )
    if args.linux_zip:
        add_desktop_package(
            args.linux_zip.resolve(),
            key="linux-x64",
            remote="javp-linux-x64.zip",
            versioned_suffix="linux-x64.zip",
            kind="zip",
        )
    if args.linux_arm64_zip:
        add_desktop_package(
            args.linux_arm64_zip.resolve(),
            key="linux-arm64",
            remote="javp-linux-arm64.zip",
            versioned_suffix="linux-arm64.zip",
            kind="zip",
        )
    if args.macos_zip:
        add_desktop_package(
            args.macos_zip.resolve(),
            key="macos-arm64",
            remote="javp-macos-arm64.zip",
            versioned_suffix="macos-arm64.zip",
            kind="zip",
        )
    if args.macos_x64_zip:
        add_desktop_package(
            args.macos_x64_zip.resolve(),
            key="macos-x64",
            remote="javp-macos-x64.zip",
            versioned_suffix="macos-x64.zip",
            kind="zip",
        )

    sidecar = read_build_meta(artifact_dir)
    sidecar_commit = None
    if sidecar:
        raw = sidecar.get("gitCommit")
        sidecar_commit = raw if isinstance(raw, str) else None
    hashes_match = artifact_hashes_match_live(apks_manifest, live_manifest)
    git_commit = resolve_artifact_git_commit(
        channel=channel,
        head=build_sha if built_now else head_sha,
        explicit=args.git_commit or None,
        sidecar_commit=sidecar_commit,
        live=live_manifest,
        hashes_match_live=hashes_match,
        built_now=built_now,
        manifest_only=False,
    )
    overwrite_err = same_version_overwrite_error(
        channel=channel,
        version_code=version_code,
        artifact_git_commit=git_commit,
        live=live_manifest,
        hashes_match_live=hashes_match,
        manifest_only=False,
        allow=bool(args.allow_same_version),
    )
    if overwrite_err:
        raise SystemExit(overwrite_err)
    if artifact_dir is not None:
        write_build_meta(
            artifact_dir,
            git_commit=git_commit,
            version_name=version_name,
            version_code=version_code,
        )
    if (
        channel == "dev"
        and git_commit
        and head_sha
        and git_commit != head_sha
    ):
        print(
            f"Note: stamping gitCommit {git_commit[:7]} from the APKs "
            f"(HEAD is {head_sha[:7]})."
        )

    manifest = build_manifest(
        version_name=version_name,
        version_code=version_code,
        apk_url=apk_url,
        changelog=changelog,
        force=args.force,
        min_version_code=args.min_version_code,
        apk_sha256=apk_sha,
        apks=apks_manifest or None,
        packages=packages_manifest or None,
        channel=channel,
        base_version_code=version_code,
        git_commit=git_commit,
        releases=releases,
    )

    site_files: list[tuple[Path, str]] = []
    if no_site:
        print("Skipping site upload (--no-site)")

    with tempfile.TemporaryDirectory(prefix="javp-deploy-") as tmp:
        tmp_dir = Path(tmp)
        if not no_site:
            download_page = ROOT / "deploy" / "download.html"
            logo = ROOT / "assets" / "branding" / "javp_logo.png"
            if download_page.exists():
                stamped = stamp_download_page(channel, tmp_dir / "download.html")
                # Short names only — remote_prefix is applied at upload time so
                # Dev never overwrites the stable root page.
                site_files.append((stamped, "index.html"))
                site_files.append((stamped, "download.html"))
            if logo.exists():
                site_files.append((logo, "javp_logo.png"))

        latest_path = tmp_dir / "latest.json"
        latest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(latest_path.read_text(encoding="utf-8"))

        # Upload binaries (and site) BEFORE latest.json. Clients poll the
        # manifest immediately; if it lands first they hit 404 on versioned
        # package URLs while FTP is still pushing ~50MB desktop zips.
        uploads: list[tuple[Path, str]] = []
        if not args.manifest_only:
            for abi, (path, remote) in apk_map.items():
                # Stable names for the download page / deep links.
                uploads.append((path, f"{remote_prefix}{remote}"))
                # Versioned names referenced by latest.json (cache-bust).
                if not skip_versioned:
                    uploads.append(
                        (path, f"{remote_prefix}{versioned_remote(remote)}")
                    )
            if skip_versioned and apk_map:
                print("Skipping versioned APK archive upload (--skip-versioned-apk)")
            for path, remote, versioned_suffix, _key, _kind in desktop_uploads:
                uploads.append((path, f"{remote_prefix}{remote}"))
                if not skip_versioned:
                    uploads.append(
                        (
                            path,
                            f"{remote_prefix}javp-{version_name}+{version_code}"
                            f"-{versioned_suffix}",
                        )
                    )
            uploads.extend(
                (path, f"{remote_prefix}{remote}") for path, remote in site_files
            )
        uploads.append((latest_path, f"{remote_prefix}latest.json"))

        if args.dry_run:
            out = ROOT / "build" / "deploy" / channel
            out.mkdir(parents=True, exist_ok=True)
            shutil.copy2(latest_path, out / "latest.json")
            if not args.manifest_only:
                for _, (path, remote) in apk_map.items():
                    dest = out / remote
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, dest)
                for path, remote, _suffix, _key, _kind in desktop_uploads:
                    dest = out / remote
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, dest)
                for path, remote in site_files:
                    dest = out / remote
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, dest)
            print(f"Dry run wrote files under {out}")
            return 0

        time.sleep(0.5)
        # Prefer ftplib: lftp can sit in do_select for minutes between
        # sequential put/rm/mv commands on Pure-FTPd even when puts themselves
        # run at ~100 MB/s. ftplib finishes the same payload in seconds.
        if os.environ.get("JAVP_FTP_BACKEND", "ftplib").lower() == "lftp":
            upload_with_lftp(uploads)
        else:
            upload_with_ftplib(uploads)

        if not args.no_cleanup:
            cleanup_old_versioned_artifacts(
                remote_prefix=remote_prefix,
                keep=args.keep_versions,
                protected_codes=release_version_codes(releases),
            )

    maybe_consume_changelog_after_publish(
        enabled=not args.no_consume_changelog,
        version_name=version_name,
        version_code=version_code,
    )

    print(f"Published {version_name}+{version_code} ({channel})")
    if not no_site:
        if channel == "dev":
            print(f"Download: {public_base}/dev/")
        else:
            print(f"Download: {public_base}/")
    print(f"Manifest: {channel_manifest_url(public_base, channel)}")
    print(f"APK:      {apk_url}")
    for abi, entry in apks_manifest.items():
        print(f"  {abi}: {entry['url']}")
    for key, entry in packages_manifest.items():
        print(f"  {key}: {entry['url']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
