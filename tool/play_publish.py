#!/usr/bin/env python3
"""Upload the Play flavor AAB (and optional listing art) via Android Publisher API.

Same idea as the msstore CLI: the Play Console *app* must already exist (a
draft is enough). The first binary on a brand-new app sometimes still has to
go through the Console UI; after that this script owns package updates.

Env (one of):
  PLAY_SERVICE_ACCOUNT_JSON   raw service-account JSON, or a path to the file
  GOOGLE_APPLICATION_CREDENTIALS  path to the JSON file

Optional:
  PLAY_PACKAGE   default com.javp.javp
  PLAY_TRACK     default internal

Examples:
  python tool/play_publish.py
  python tool/play_publish.py --track internal --status draft
  python tool/play_publish.py --listing
  python tool/play_publish.py --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AAB = ROOT / "build/app/outputs/bundle/playRelease/app-play-release.aab"
DEFAULT_PACKAGE = "com.javp.javp"
DEFAULT_TRACK = "internal"
SCOPES = ("https://www.googleapis.com/auth/androidpublisher",)
LISTING_PHONE = ROOT / "store/play/listing/phone"
LISTING_GRAPHICS = ROOT / "store/play/graphics"


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _load_sa_info() -> dict:
    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if raw:
        if raw.startswith("{"):
            try:
                return json.loads(raw)
            except json.JSONDecodeError as e:
                die(f"PLAY_SERVICE_ACCOUNT_JSON is not valid JSON: {e}")
        path = raw
    if not path:
        die(
            "missing Play API credentials. Set PLAY_SERVICE_ACCOUNT_JSON "
            "(JSON or path) or GOOGLE_APPLICATION_CREDENTIALS. "
            "Play Console → Setup → API access → service account JSON. "
            "See docs/play-store.md."
        )
    p = Path(path)
    if not p.is_file():
        die(f"service account file not found: {p}")
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        die(f"service account file is not valid JSON: {e}")


def _pubspec_version() -> tuple[str, str]:
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"(?m)^version:\s*([^\s]+)", text)
    if not m:
        return ("", "")
    spec = m.group(1).strip()
    name, _, code = spec.partition("+")
    return name, code


def _service() -> object:
    try:
        import google_auth_httplib2
        import httplib2
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
    except ImportError:
        die(
            "missing Play API client. Install with:\n"
            "  pip install google-api-python-client google-auth google-auth-httplib2 httplib2"
        )
    info = _load_sa_info()
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=SCOPES
    )
    # Google resumable uploads use 308 Resume Incomplete; httplib2 treats
    # that as a redirect and crashes without a Location header.
    timeout_s = int(os.environ.get("PLAY_HTTP_TIMEOUT", "900"))
    base_http = httplib2.Http(timeout=timeout_s)
    base_http.redirect_codes = set(base_http.redirect_codes) - {308}
    http = google_auth_httplib2.AuthorizedHttp(creds, http=base_http)
    return build(
        "androidpublisher",
        "v3",
        http=http,
        cache_discovery=False,
        num_retries=5,
    )


def _upload_resumable(request, label: str) -> dict:
    response = None
    while response is None:
        status, response = request.next_chunk(num_retries=5)
        if status:
            pct = int(status.progress() * 100)
            print(f"  {label}: {pct}%")
    return response


def _commit_edit(edits, package: str, edit_id: str) -> None:
    """Commit a Play edit.

    changesNotSentForReview=True is required when Console has pending/rejected
    changes that cannot be auto-sent for review (Play API 400 otherwise).
    """
    edits.commit(
        packageName=package,
        editId=edit_id,
        changesNotSentForReview=True,
    ).execute()


def _upload_image(edits, package: str, edit_id: str, image_type: str, path: Path) -> None:
    from googleapiclient.http import MediaFileUpload

    media = MediaFileUpload(str(path), mimetype="image/png", resumable=True)
    request = edits.images().upload(
        packageName=package,
        editId=edit_id,
        language="en-US",
        imageType=image_type,
        media_body=media,
    )
    _upload_resumable(request, path.name)
    print(f"  listing image {image_type}: {path.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish JAVP AAB to Google Play")
    parser.add_argument(
        "--aab",
        type=Path,
        default=DEFAULT_AAB,
        help="Play release AAB (default: build/.../app-play-release.aab)",
    )
    parser.add_argument("--package", default=os.environ.get("PLAY_PACKAGE", DEFAULT_PACKAGE))
    parser.add_argument("--track", default=os.environ.get("PLAY_TRACK", DEFAULT_TRACK))
    parser.add_argument(
        "--status",
        choices=("completed", "draft"),
        default="completed",
        help="Track release status. completed = testers can install (internal).",
    )
    parser.add_argument(
        "--listing",
        action="store_true",
        help="Also upload store/play listing screenshots + graphics (en-US)",
    )
    parser.add_argument("--skip-aab", action="store_true", help="Listing only")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--notes",
        default=os.environ.get("PLAY_RELEASE_NOTES", ""),
        help="en-US release notes (optional; or PLAY_RELEASE_NOTES)",
    )
    args = parser.parse_args()

    aab = args.aab.resolve() if not args.skip_aab else None
    if aab is not None and not aab.is_file():
        die(f"AAB not found: {aab}\nBuild it with: python tool/build_distribution.py play")

    version_name, version_code = _pubspec_version()
    print(f"package={args.package} track={args.track} status={args.status}")
    if version_name:
        print(f"pubspec={version_name}+{version_code}")
    if aab is not None:
        print(f"aab={aab} ({aab.stat().st_size / 1e6:.1f} MB)")
    if args.dry_run:
        print("dry-run: not calling Play API")
        return 0

    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload

    service = _service()
    edits = service.edits()
    try:
        edit = edits.insert(packageName=args.package, body={}).execute()
    except HttpError as e:
        body = e.content.decode("utf-8", errors="replace") if e.content else str(e)
        hint = ""
        if e.resp.status in (403, 404):
            hint = (
                "\nThe Play app must exist (draft is OK) and this service account "
                "must be invited under Play Console → Setup → API access. "
                "If no AAB has ever been uploaded, do the first one in the Console UI."
            )
        die(f"edits.insert failed HTTP {e.resp.status}: {body}{hint}")
    edit_id = edit["id"]
    print(f"edit={edit_id}")

    version_codes: list[str] = []
    try:
        if aab is not None:
            media = MediaFileUpload(
                str(aab),
                mimetype="application/octet-stream",
                resumable=True,
                chunksize=5 * 1024 * 1024,
            )
            print("uploading AAB (resumable, may take several minutes)…")
            request = edits.bundles().upload(
                packageName=args.package,
                editId=edit_id,
                media_body=media,
            )
            bundle = _upload_resumable(request, "AAB")
            code = str(bundle.get("versionCode") or version_code)
            version_codes = [code]
            print(f"uploaded bundle versionCode={code}")

            release: dict = {
                "name": f"{version_name} ({code})" if version_name else code,
                "versionCodes": version_codes,
                "status": args.status,
            }
            notes = args.notes.strip()
            if notes:
                release["releaseNotes"] = [{"language": "en-US", "text": notes[:500]}]
            edits.tracks().update(
                packageName=args.package,
                editId=edit_id,
                track=args.track,
                body={"track": args.track, "releases": [release]},
            ).execute()
            print(f"track {args.track} -> {code} ({args.status})")

        if args.listing:
            phone = sorted(LISTING_PHONE.glob("*.png"))
            if not phone:
                print(f"warning: no phone screenshots in {LISTING_PHONE}")
            else:
                edits.images().deleteall(
                    packageName=args.package,
                    editId=edit_id,
                    language="en-US",
                    imageType="phoneScreenshots",
                ).execute()
                for shot in phone:
                    _upload_image(edits, args.package, edit_id, "phoneScreenshots", shot)
            graphics = {
                "icon": LISTING_GRAPHICS / "hi-res-icon-512.png",
                "featureGraphic": LISTING_GRAPHICS / "feature-graphic-1024x500.png",
                "tvBanner": LISTING_GRAPHICS / "tv-banner-1280x720.png",
            }
            for image_type, path in graphics.items():
                if not path.is_file():
                    print(f"warning: missing {path}")
                    continue
                edits.images().deleteall(
                    packageName=args.package,
                    editId=edit_id,
                    language="en-US",
                    imageType=image_type,
                ).execute()
                _upload_image(edits, args.package, edit_id, image_type, path)

        _commit_edit(edits, args.package, edit_id)
        print("committed Play edit")
    except HttpError as e:
        body = e.content.decode("utf-8", errors="replace") if e.content else str(e)
        try:
            edits.delete(packageName=args.package, editId=edit_id).execute()
        except Exception:
            pass
        die(f"Play API HTTP {e.resp.status}: {body}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
