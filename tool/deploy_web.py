#!/usr/bin/env python3
"""Publish the Flutter web companion to FTP (web.javp.app).

Policy: production site tracks stable/main releases. Prefer GitHub Actions
Build Web on a GitHub Release (or main + publish_ftp). Local use is for
emergencies / first bring-up — not routine Dev publishes.

Prefer a dedicated FTP account whose home is the site docroot:

  export JAVP_WEB_FTP_HOST=…
  export JAVP_WEB_FTP_USER=javpweb
  export JAVP_WEB_FTP_PASS=…
  export JAVP_WEB_FTP_PORT=21
  export JAVP_WEB_FTP_DIR=/          # usually account home = site root
  export JAVP_WEB_PUBLIC_BASE=https://web.javp.app

Falls back to updater ``JAVP_FTP_*`` + ``JAVP_WEB_FTP_DIR`` (subdirectory)
when ``JAVP_WEB_FTP_HOST`` is unset.

Examples:

  flutter build web --release --dart-define=JAVP_DISTRIBUTION=sideload --pwa-strategy=none
  python3 tool/deploy_web.py
  python3 tool/deploy_web.py --dry-run
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WEB_DIR = ROOT / "build" / "web"
SKIP_NAMES = {".DS_Store", "Thumbs.db"}


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required env {name}")
    return value


def _web_ftp_credentials() -> tuple[str, int, str, str, str]:
    """Return host, port, user, password, remote_dir for the companion FTP."""
    if os.environ.get("JAVP_WEB_FTP_HOST", "").strip():
        host = _env("JAVP_WEB_FTP_HOST")
        port = int(os.environ.get("JAVP_WEB_FTP_PORT") or "21")
        user = os.environ.get("JAVP_WEB_FTP_USER") or "javpweb"
        password = _env("JAVP_WEB_FTP_PASS")
        remote_dir = os.environ.get("JAVP_WEB_FTP_DIR", "/")
        return host, port, user, password, remote_dir

    # Fallback: same account as updater, files under JAVP_WEB_FTP_DIR prefix.
    host = _env("JAVP_FTP_HOST")
    port = int(os.environ.get("JAVP_FTP_PORT") or "21")
    user = os.environ.get("JAVP_FTP_USER") or "javp"
    password = _env("JAVP_FTP_PASS")
    remote_dir = os.environ.get("JAVP_FTP_DIR", "/")
    return host, port, user, password, remote_dir


def _using_dedicated_web_ftp() -> bool:
    return bool(os.environ.get("JAVP_WEB_FTP_HOST", "").strip())


def _remote_file_prefix() -> str:
    """Path prefix relative to the FTP cwd (empty for dedicated account root)."""
    if _using_dedicated_web_ftp():
        # Dedicated account home is the docroot — don't nest under web/.
        raw = (os.environ.get("JAVP_WEB_REMOTE_PREFIX") or "").strip()
    else:
        raw = (os.environ.get("JAVP_WEB_FTP_DIR") or "web").strip()
    return "/".join(p for p in raw.replace("\\", "/").split("/") if p and p != ".")


def _remote_tmp_name(remote_name: str) -> str:
    remote_path = Path(remote_name)
    return str(remote_path.with_name(f".{remote_path.name}.uploading")).replace(
        "\\", "/"
    )


def _remote_parent_dirs(local_files: list[tuple[Path, str]]) -> list[str]:
    return sorted(
        {
            str(Path(remote_name).parent).replace("\\", "/")
            for _, remote_name in local_files
            if Path(remote_name).parent != Path(".")
        }
    )


def _ftp_ensure_dir(ftp, directory: str) -> None:
    parts = [p for p in directory.replace("\\", "/").split("/") if p and p != "."]
    for i in range(len(parts)):
        partial = "/".join(parts[: i + 1])
        try:
            ftp.mkd(partial)
        except Exception:
            pass


def upload_web_ftplib(local_files: list[tuple[Path, str]]) -> None:
    from ftplib import FTP

    host, port, user, password, remote_dir = _web_ftp_credentials()
    print(
        f"Uploading {len(local_files)} file(s) via ftplib to "
        f"{user}@{host}:{port} cwd {remote_dir!r}"
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


def upload_web_lftp(local_files: list[tuple[Path, str]]) -> None:
    if shutil.which("lftp") is None:
        upload_web_ftplib(local_files)
        return

    host, port, user, password, remote_dir = _web_ftp_credentials()
    commands = [
        "set ssl:verify-certificate no",
        "set ftp:ssl-allow no",
        "set ftp:passive-mode true",
        "set net:timeout 120",
        "set net:max-retries 5",
        f"cd {remote_dir}" if remote_dir not in ("", ".", "/") else "",
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
    print(f"Uploading {len(local_files)} file(s) via lftp cwd {remote_dir!r}")
    subprocess.check_call(cmd)


def _cache_bust_entrypoint(web_dir: Path) -> str:
    """Point the loader at uniquely named assets so CDN edges cannot serve a
    stale ``main.dart.js`` / ``flutter_bootstrap.js`` after a redeploy.

    Cloudflare was HITting ``main.dart.js`` for 12h even after FTP updates.
    The bust token is a short content hash of ``main.dart.js`` so every rebuilt
    bundle gets a new URL even when Flutter's ``.last_build_id`` is unchanged.
    """
    import hashlib

    main_js = web_dir / "main.dart.js"
    bootstrap = web_dir / "flutter_bootstrap.js"
    index = web_dir / "index.html"
    if not main_js.is_file() or not bootstrap.is_file() or not index.is_file():
        raise SystemExit(
            f"Missing main.dart.js, flutter_bootstrap.js, or index.html in {web_dir}"
        )

    digest = hashlib.sha1(main_js.read_bytes()).hexdigest()[:12]
    build_id = digest

    busted_main = f"main.{build_id}.dart.js"
    shutil.copy2(main_js, web_dir / busted_main)

    text = bootstrap.read_text(encoding="utf-8")
    # Flutter / prior deploys may already have rewritten mainJsPath.
    import re

    text, n = re.subn(
        r'"mainJsPath":"main(?:\.[A-Za-z0-9]+)?\.dart\.js"',
        f'"mainJsPath":"{busted_main}"',
        text,
        count=1,
    )
    if n != 1 and busted_main not in text:
        raise SystemExit(
            "Could not rewrite flutter_bootstrap.js mainJsPath for cache bust"
        )

    busted_bootstrap = f"flutter_bootstrap.{build_id}.js"
    (web_dir / busted_bootstrap).write_text(text, encoding="utf-8")
    # Keep unversioned bootstrap in sync for direct hits / tooling.
    bootstrap.write_text(text, encoding="utf-8")

    index_html = index.read_text(encoding="utf-8")
    if f'src="{busted_bootstrap}"' not in index_html:
        index_html, n = re.subn(
            r'src=(["\'])flutter_bootstrap(?:\.[A-Za-z0-9]+)?\.js\1',
            f'src="{busted_bootstrap}"',
            index_html,
            count=1,
        )
        if n != 1:
            raise SystemExit(
                "Could not find flutter_bootstrap.js script tag in index.html"
            )
        index.write_text(index_html, encoding="utf-8")
    print(f"Cache-bust entrypoint → {busted_bootstrap} → {busted_main}")
    return busted_main


def collect_web_uploads(web_dir: Path, *, remote_prefix: str) -> list[tuple[Path, str]]:
    if not web_dir.is_dir():
        raise SystemExit(
            f"Missing web build at {web_dir} — run: "
            "flutter build web --release --dart-define=JAVP_DISTRIBUTION=sideload "
            "--pwa-strategy=none"

        )
    index = web_dir / "index.html"
    if not index.is_file():
        raise SystemExit(f"Missing {index}")

    _cache_bust_entrypoint(web_dir)

    uploads: list[tuple[Path, str]] = []
    for path in sorted(web_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.name in SKIP_NAMES:
            continue
        rel = path.relative_to(web_dir).as_posix()
        remote = f"{remote_prefix}/{rel}" if remote_prefix else rel
        uploads.append((path.resolve(), remote))

    htaccess = ROOT / "deploy" / "web.htaccess"
    if htaccess.is_file():
        remote = f"{remote_prefix}/.htaccess" if remote_prefix else ".htaccess"
        uploads.append((htaccess.resolve(), remote))

    nginx = ROOT / "deploy" / "web.nginx.conf"
    if nginx.is_file():
        remote = (
            f"{remote_prefix}/web.nginx.conf" if remote_prefix else "web.nginx.conf"
        )
        uploads.append((nginx.resolve(), remote))

    return uploads


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--web-dir",
        type=Path,
        default=DEFAULT_WEB_DIR,
        help="Flutter web build output (default: build/web)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List uploads only; skip FTP",
    )
    args = parser.parse_args()

    prefix = _remote_file_prefix()
    uploads = collect_web_uploads(args.web_dir.resolve(), remote_prefix=prefix)
    public = (
        os.environ.get("JAVP_WEB_PUBLIC_BASE") or "https://web.javp.app"
    ).rstrip("/")
    dedicated = _using_dedicated_web_ftp()

    print(f"Companion files: {len(uploads)}")
    print(
        "FTP mode: "
        + ("dedicated JAVP_WEB_FTP_* account" if dedicated else "updater account + prefix")
    )
    print(f"Remote prefix: {prefix or '(account root)'}/")
    print(f"Public base: {public}/")
    for local, remote in uploads[:12]:
        print(f"  {remote}  ({local.stat().st_size} B)")
    if len(uploads) > 12:
        print(f"  … and {len(uploads) - 12} more")

    if args.dry_run:
        print("Dry run — skip FTP")
        return 0

    _web_ftp_credentials()
    if os.environ.get("JAVP_FTP_BACKEND", "ftplib").lower() == "lftp":
        upload_web_lftp(uploads)
    else:
        upload_web_ftplib(uploads)

    print(f"Published web companion → {public}/")
    if not dedicated:
        print(
            "Tip: set JAVP_WEB_FTP_HOST/USER/PASS for a dedicated account "
            "whose home is the web.javp.app docroot."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
