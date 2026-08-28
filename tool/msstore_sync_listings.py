#!/usr/bin/env python3
"""Sync Microsoft Store listing text from store-assets/msstore/listings/*.json.

Uses the classic Partner Center submission API (MSIX apps —
manage.devcenter.microsoft.com). Creates a pending submission if needed,
merges listing JSON into it, uploads Desktop screenshots from
store-assets/msstore/screenshots/ into *every* language via one ZIP on
fileUploadUrl (flat unique names like fr-fr-01.png — required; sharing
en-us image ids does not populate localized listings), then commits.

The modern listing-assets API (api.store.microsoft.com) is MSI/EXE-only and
does not work for this product.

Env (required):
  AZURE_AD_TENANT_ID
  AZURE_AD_APPLICATION_CLIENT_ID
  AZURE_AD_APPLICATION_SECRET
  STORE_PRODUCT_ID          (default 9P4PMM405RZH)

Flags:
  --dry-run     print plan only
  --inspect     print pending status + image counts per language; no write
  --no-commit   update pending submission but do not commit
  --listings DIR  (default: store-assets/msstore/listings)
  --screenshots DIR  (default: store-assets/msstore/screenshots)
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LISTINGS = ROOT / "store-assets" / "msstore" / "listings"
DEFAULT_SCREENSHOTS = ROOT / "store-assets" / "msstore" / "screenshots"
DEFAULT_PRODUCT = "9P4PMM405RZH"
RESOURCE = "https://manage.devcenter.microsoft.com"
API = f"{RESOURCE}/v1.0/my"

# Logos / icons can stay as shared Uploaded refs; Screenshots must be
# PendingUpload per language (Partner Center leaves localized listings empty
# when only en-us screenshot ids are copied).
KEEP_IMAGE_TYPES = {
    "Icon",
    "StoreLogoSquare",
    "StoreLogo9x16",
    "PromotionalArt16x9",
    "PromotionalArtwork2400X1200",
}


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        die(f"missing env {name}")
    return v


def http_json(
    method: str,
    url: str,
    token: str,
    body: dict | None = None,
    *,
    empty_body: bool = False,
) -> tuple[int, dict | list | None, bytes]:
    data = None
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if empty_body:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = "0"
        data = b""
    elif body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
            code = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        code = e.code
    parsed: dict | list | None
    if not raw:
        parsed = None
    else:
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            parsed = None
    return code, parsed, raw


def get_token(tenant: str, client_id: str, client_secret: str) -> str:
    url = f"https://login.microsoftonline.com/{tenant}/oauth2/token"
    form = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "resource": RESOURCE,
        }
    ).encode()
    req = urllib.request.Request(
        url, data=form, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read().decode())
    token = payload.get("access_token")
    if not token:
        die(f"token response missing access_token: {payload}")
    return token


def load_listings(dir_path: Path) -> dict[str, dict]:
    if not dir_path.is_dir():
        die(f"listings dir not found: {dir_path}")
    out: dict[str, dict] = {}
    for path in sorted(dir_path.glob("*.json")):
        if path.name.startswith("_"):
            continue
        lang = path.stem.lower()
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            die(f"{path}: expected object")
        for req in ("title", "shortDescription", "description", "features"):
            if req not in data:
                die(f"{path}: missing {req}")
        if not isinstance(data["features"], list) or not data["features"]:
            die(f"{path}: features must be a non-empty list")
        out[lang] = data
    if "en-us" not in out:
        die("en-us.json is required (screenshot/icon source of truth)")
    return out


def load_screenshot_files(dir_path: Path) -> list[Path]:
    if not dir_path.is_dir():
        return []
    files = sorted(
        p
        for p in dir_path.iterdir()
        if p.is_file() and p.suffix.lower() in (".png", ".jpg", ".jpeg")
    )
    return files


# Immutable in Partner Center ??? PUT 409. PendingCommit is the editable draft.
# CommitStarted means our PUT already landed; do not poll Partner Center.
LOCKED_STATUSES = {
    "PreProcessing",
    "Certification",
    "PendingCertification",
    "Publishing",
}

COMMIT_IN_FLIGHT = {
    "CommitStarted",
    "PendingPublication",
}


def submission_status(sub: dict, status_payload: dict | None = None) -> str:
    if status_payload and status_payload.get("status"):
        return str(status_payload["status"])
    return str(sub.get("status") or sub.get("substatus") or "")


def package_file_id(pkg: dict) -> str:
    return str(pkg.get("fileId") or pkg.get("id") or "")


def merge_application_packages(clone: list | None, locked: list | None) -> list:
    """Keep every clone package (Partner Center rejects dropping them) and
    add any extra packages from the locked submission (new MSIX uploads).
    """
    out: list = []
    seen: set[str] = set()
    for pkg in clone or []:
        if not isinstance(pkg, dict):
            continue
        fid = package_file_id(pkg)
        if fid:
            seen.add(fid)
        out.append(pkg)
    added = 0
    for pkg in locked or []:
        if not isinstance(pkg, dict):
            continue
        fid = package_file_id(pkg)
        if fid and fid in seen:
            continue
        out.append(pkg)
        added += 1
        if fid:
            seen.add(fid)
    if added:
        print(f"  merged {added} extra package(s) from locked submission")
    print(f"  applicationPackages now {len(out)} (clone kept all existing fileIds)")
    return out


def wait_until_pending_id_gone(
    app_url: str,
    token: str,
    gone_id: str,
    *,
    timeout_s: int = 180,
) -> dict:
    """Wait until `gone_id` is no longer the pending submission.

    A concurrent run (or the API) may already have created a replacement;
    that new pending is success, not a stuck delete.
    """
    deadline = time.time() + timeout_s
    last_app: dict | None = None
    while time.time() < deadline:
        code, app, raw = http_json("GET", app_url, token)
        if code != 200 or not isinstance(app, dict):
            die(f"GET application failed HTTP {code}: {raw[:500]!r}")
        last_app = app
        pending = app.get("pendingApplicationSubmission") or {}
        pid = pending.get("id")
        if pid != gone_id:
            return app
        print(f"  waiting for pending {pid} to clear???")
        time.sleep(5)
    die("pending submission still present after delete; try again in Partner Center")
    return last_app or {}


def recreate_locked_submission(
    app_url: str,
    token: str,
    locked_id: str,
    locked: dict,
) -> tuple[str, dict]:
    """Delete a locked pending submission and clone a fresh one.

    New submissions clone last *published* packages. Merge in any extra
    packages from the locked payload so an in-flight MSIX is not dropped,
    without omitting published fileIds (PUT 400 InvalidParameterValue).
    """
    locked_packages = locked.get("applicationPackages") or []
    print(f"deleting locked submission {locked_id} (status={submission_status(locked)!r})")
    code, _, raw = http_json("DELETE", f"{app_url}/submissions/{locked_id}", token)
    if code not in (200, 204, 404):
        die(f"DELETE submission failed HTTP {code}: {raw[:800]!r}")
    app = wait_until_pending_id_gone(app_url, token, locked_id)
    pending = app.get("pendingApplicationSubmission") or {}
    if pending.get("id"):
        new_id = pending["id"]
        print(f"using replacement pending {new_id}")
    else:
        print("creating replacement submission???")
        code, created, raw = http_json(
            "POST", f"{app_url}/submissions", token, empty_body=True
        )
        if code not in (200, 201) or not isinstance(created, dict) or not created.get("id"):
            die(f"create submission failed HTTP {code}: {raw[:800]!r}")
        new_id = created["id"]
        print(f"created submission {new_id}")
    sub_url = f"{app_url}/submissions/{new_id}"
    code, sub, raw = http_json("GET", sub_url, token)
    if code != 200 or not isinstance(sub, dict):
        die(f"GET new submission failed HTTP {code}: {raw[:500]!r}")
    sub["applicationPackages"] = merge_application_packages(
        sub.get("applicationPackages"),
        locked_packages,
    )
    return new_id, sub


def base_listing_from_file(data: dict, images: list) -> dict:
    return {
        "title": data["title"],
        "shortTitle": data.get("shortTitle") or data["title"],
        "voiceTitle": data.get("voiceTitle") or data["title"],
        "shortDescription": data["shortDescription"],
        "description": data["description"],
        "features": data["features"],
        "keywords": data.get("keywords") or [],
        "releaseNotes": data.get("releaseNotes") or "",
        "copyrightAndTrademarkInfo": data.get("copyrightAndTrademarkInfo") or "",
        "licenseTerms": data.get("licenseTerms")
        or "GPL-3.0-or-later. See https://github.com/JAVPApp/JAVP/blob/main/LICENSE",
        "privacyPolicy": data.get("privacyPolicy") or "",
        "supportContact": data.get("supportContact") or "",
        "websiteUrl": data.get("websiteUrl") or "",
        "devStudio": data.get("devStudio") or "Cubeweb",
        "minimumHardware": data.get("minimumHardware") or "",
        "recommendedHardware": data.get("recommendedHardware") or "",
        "images": images,
    }


def screenshot_image_counts(
    listings: dict, *, uploaded_only: bool = False
) -> dict[str, int]:
    """Count Screenshot images per language.

    By default, PendingUpload rows count as present. That matters for
    recreate gates: after commit, Partner Center keeps shots as
    PendingUpload until processing promotes them to Uploaded — a re-run
    must not treat that window as "incomplete" and delete the submission.

    Pass uploaded_only=True for post-commit verify (require Uploaded + id).
    """
    out: dict[str, int] = {}
    for lang, listing in sorted(listings.items()):
        base = (listing or {}).get("baseListing") or {}
        images = base.get("images") or []
        n = 0
        for img in images:
            if not isinstance(img, dict):
                continue
            if str(img.get("imageType") or "") != "Screenshot":
                continue
            status = str(img.get("fileStatus") or "")
            if status in ("PendingDelete",):
                continue
            if uploaded_only:
                if status == "PendingUpload" or not img.get("id"):
                    continue
            n += 1
        out[lang] = n
    return out


def print_inspect(sub: dict, status: str, status_payload: dict | None) -> None:
    print(f"submission id={sub.get('id')} status={status}")
    details = sub.get("statusDetails") or {}
    if isinstance(status_payload, dict) and status_payload.get("statusDetails"):
        details = status_payload.get("statusDetails") or details
    errors = details.get("errors") or []
    warnings = details.get("warnings") or []
    if errors:
        print("errors:")
        for err in errors:
            print(f"  - {err}")
    if warnings:
        print("warnings:")
        for warn in warnings:
            print(f"  - {warn}")
    counts = screenshot_image_counts(sub.get("listings") or {})
    missing = [lang for lang, n in counts.items() if n < 1]
    print("screenshot counts by language:")
    for lang, n in counts.items():
        mark = " OK" if n >= 1 else " MISSING"
        print(f"  {lang}: {n}{mark}")
    if missing:
        print(f"languages missing screenshots: {', '.join(missing)}")
    else:
        print("all listed languages have ???1 Screenshot")


def keep_logo_images(en_images: list | None) -> list[dict]:
    kept: list[dict] = []
    for img in en_images or []:
        if not isinstance(img, dict):
            continue
        if str(img.get("imageType") or "") in KEEP_IMAGE_TYPES:
            kept.append(dict(img))
    return kept


def pending_delete_old_screenshots(prev_images: list | None) -> list[dict]:
    out: list[dict] = []
    for img in prev_images or []:
        if not isinstance(img, dict):
            continue
        if str(img.get("imageType") or "") != "Screenshot":
            continue
        if not img.get("id"):
            # Stuck PendingUpload rows have no id — omit them from the PUT
            # (they are replaced by fresh PendingUpload entries).
            continue
        doomed = dict(img)
        doomed["fileStatus"] = "PendingDelete"
        out.append(doomed)
    return out


def screenshot_zip_name(lang: str, path: Path) -> str:
    """Flat unique zip member name (no folders).

    Nested paths like ``fr-fr/01-desktop.png`` stay PendingUpload forever.
    Flat shared names only bind to one language. Flat *unique* names work.
    """
    return f"{lang}-{path.name}"


def pending_upload_screenshots(lang: str, files: list[Path]) -> list[dict]:
    images: list[dict] = []
    for path in files:
        images.append(
            {
                "fileName": screenshot_zip_name(lang, path),
                "fileStatus": "PendingUpload",
                "imageType": "Screenshot",
                "description": "JAVP",
            }
        )
    return images


def build_images_for_lang(
    lang: str,
    logo_source_images: list | None,
    prev_lang_images: list | None,
    screenshot_files: list[Path],
) -> list[dict]:
    images: list[dict] = []
    images.extend(keep_logo_images(logo_source_images))
    images.extend(pending_delete_old_screenshots(prev_lang_images))
    images.extend(pending_upload_screenshots(lang, screenshot_files))
    return images


def zip_screenshots(langs: list[str], files: list[Path]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for lang in langs:
            for path in files:
                zf.write(path, arcname=screenshot_zip_name(lang, path))
    return buf.getvalue()


def upload_zip_to_sas(file_upload_url: str, zip_bytes: bytes) -> None:
    """Upload ZIP to Partner Center SAS URL (BlockBlob) without azure-storage."""
    req = urllib.request.Request(
        file_upload_url,
        data=zip_bytes,
        method="PUT",
        headers={
            "x-ms-blob-type": "BlockBlob",
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(zip_bytes)),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            code = resp.status
            resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        die(f"blob upload failed HTTP {e.code}: {raw[:800]!r}")
    if code not in (200, 201):
        die(f"blob upload unexpected HTTP {code}")
    print(f"uploaded screenshots zip ({len(zip_bytes)} bytes) HTTP {code}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--listings", type=Path, default=DEFAULT_LISTINGS)
    ap.add_argument("--screenshots", type=Path, default=DEFAULT_SCREENSHOTS)
    ap.add_argument("--product-id", default=os.environ.get("STORE_PRODUCT_ID", DEFAULT_PRODUCT))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--inspect",
        action="store_true",
        help="Print pending status and screenshot counts; do not modify.",
    )
    ap.add_argument("--no-commit", action="store_true")
    ap.add_argument(
        "--force",
        action="store_true",
        help="Delete any pending submission (even CommitStarted with "
        "screenshot refs) and open a fresh one before uploading listings.",
    )
    ap.add_argument(
        "--recreate-if-locked",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Delete a PreProcessing pending submission and open a new one "
        "(keeps its packages). Default on; --no-recreate-if-locked to skip.",
    )
    args = ap.parse_args()

    listings_files = load_listings(args.listings)
    screenshot_files = load_screenshot_files(args.screenshots)
    print(f"loaded {len(listings_files)} listings from {args.listings}", flush=True)
    print(
        f"loaded {len(screenshot_files)} screenshot(s) from {args.screenshots}",
        flush=True,
    )

    tenant = env("AZURE_AD_TENANT_ID")
    client_id = env("AZURE_AD_APPLICATION_CLIENT_ID")
    client_secret = env("AZURE_AD_APPLICATION_SECRET")
    product_id = args.product_id

    if args.dry_run:
        print("dry-run langs:", ", ".join(sorted(listings_files)))
        print("dry-run screenshots:", ", ".join(p.name for p in screenshot_files) or "(none)")
        return 0

    token = get_token(tenant, client_id, client_secret)
    app_url = f"{API}/applications/{product_id}"
    code, app, raw = http_json("GET", app_url, token)
    if code != 200 or not isinstance(app, dict):
        die(f"GET application failed HTTP {code}: {raw[:500]!r}")

    pending = app.get("pendingApplicationSubmission")
    published = app.get("lastPublishedApplicationSubmission") or {}
    if pending and pending.get("id"):
        sub_id = pending["id"]
        print(f"using existing pending submission {sub_id}")
    else:
        if args.inspect:
            print("no pending submission")
            if published.get("id"):
                print(f"(last published {published.get('id')})")
            return 0
        print("creating pending submission???")
        code, created, raw = http_json(
            "POST", f"{app_url}/submissions", token, empty_body=True
        )
        if code not in (200, 201) or not isinstance(created, dict) or not created.get("id"):
            die(f"create submission failed HTTP {code}: {raw[:800]!r}")
        sub_id = created["id"]
        print(f"created submission {sub_id}")

    sub_url = f"{app_url}/submissions/{sub_id}"
    code, sub, raw = http_json("GET", sub_url, token)
    if code != 200 or not isinstance(sub, dict):
        die(f"GET submission failed HTTP {code}: {raw[:500]!r}")

    code_st, st, _ = http_json("GET", f"{sub_url}/status", token)
    status = submission_status(sub, st if isinstance(st, dict) else None)
    if code_st == 200 and isinstance(st, dict):
        print(f"pending status={status}")

    if args.inspect:
        print_inspect(sub, status, st if isinstance(st, dict) else None)
        print("(published was", published.get("id"), ")")
        return 0

    have_langs = set(sub.get("listings") or {})
    want_langs = set(listings_files)
    counts = screenshot_image_counts(sub.get("listings") or {})
    screenshots_complete = want_langs and all(
        counts.get(lang, 0) >= 1 for lang in want_langs
    )
    listings_already = want_langs <= have_langs and screenshots_complete

    if args.force and pending and pending.get("id"):
        print(
            f"--force: deleting pending {sub_id} (status={status}) "
            "to re-upload listings + Desktop screenshots"
        )
        print_inspect(sub, status, st if isinstance(st, dict) else None)
        sub_id, sub = recreate_locked_submission(app_url, token, sub_id, sub)
        sub_url = f"{app_url}/submissions/{sub_id}"
        status = submission_status(sub)
        print(f"replacement pending status={status}")
        have_langs = set(sub.get("listings") or {})
        counts = screenshot_image_counts(sub.get("listings") or {})
        screenshots_complete = want_langs and all(
            counts.get(lang, 0) >= 1 for lang in want_langs
        )
        listings_already = want_langs <= have_langs and screenshots_complete
    elif status in COMMIT_IN_FLIGHT:
        # Do not delete/recreate while Partner Center is processing a commit.
        # Screenshots often stay PendingUpload until processing finishes; a
        # re-run must not treat that as stuck. Use --force to break a draft.
        print(
            "commit already in flight (status="
            f"{status}); listings were submitted earlier — "
            "not polling Partner Center. Check certification there."
        )
        print_inspect(sub, status, st if isinstance(st, dict) else None)
        print("(published was", published.get("id"), ")")
        print("hint: re-run with --force if the Partner Center UI is still draft")
        return 0

    if listings_already and status in LOCKED_STATUSES and not args.force:
        print(
            "listings + screenshots already on pending submission "
            f"({len(have_langs)} langs, status={status}); not replacing"
        )
        return 0

    if args.recreate_if_locked and status in LOCKED_STATUSES:
        sub_id, sub = recreate_locked_submission(app_url, token, sub_id, sub)
        sub_url = f"{app_url}/submissions/{sub_id}"

    if not screenshot_files:
        die(
            f"no Desktop screenshots in {args.screenshots} "
            "(need ???1 PNG/JPG, Store requires ???1366??768)"
        )

    existing = sub.get("listings") or {}
    en_existing = (existing.get("en-us") or {}).get("baseListing") or {}
    en_images = en_existing.get("images") or []

    new_listings: dict = {}
    for lang, data in listings_files.items():
        prev = existing.get(lang) or {}
        prev_images = ((prev.get("baseListing") or {}).get("images")) or []
        images = build_images_for_lang(
            lang, en_images, prev_images, screenshot_files
        )
        new_listings[lang] = {
            "baseListing": base_listing_from_file(data, images),
            "platformOverrides": prev.get("platformOverrides") or {},
        }

    dropped = sorted(set(existing) - set(new_listings))
    if dropped:
        print("dropping langs not in git:", ", ".join(dropped))

    sub["listings"] = new_listings
    print(
        "PUT listings:",
        ", ".join(sorted(new_listings)),
        f"({len(screenshot_files)} screenshots ?? {len(new_listings)} langs)",
    )
    code, updated, raw = http_json("PUT", sub_url, token, sub)
    raw_text = raw.decode("utf-8", errors="replace") if raw else ""
    if code == 409 and "being processed" in raw_text:
        print("PUT 409 already processing ??? listings commit is in flight; done.")
        return 0
    if (
        code == 409
        and args.recreate_if_locked
        and "PreProcessing" in raw_text
    ):
        print("PUT 409 PreProcessing ??? deleting and recreating???")
        sub_id, sub = recreate_locked_submission(app_url, token, sub_id, sub)
        sub_url = f"{app_url}/submissions/{sub_id}"
        existing = sub.get("listings") or {}
        en_existing = (existing.get("en-us") or {}).get("baseListing") or {}
        en_images = en_existing.get("images") or en_images
        new_listings = {}
        for lang, data in listings_files.items():
            prev = existing.get(lang) or {}
            prev_images = ((prev.get("baseListing") or {}).get("images")) or []
            images = build_images_for_lang(
                lang, en_images, prev_images, screenshot_files
            )
            new_listings[lang] = {
                "baseListing": base_listing_from_file(data, images),
                "platformOverrides": prev.get("platformOverrides") or {},
            }
        sub["listings"] = new_listings
        code, updated, raw = http_json("PUT", sub_url, token, sub)
    if code != 200 or not isinstance(updated, dict):
        die(f"PUT submission failed HTTP {code}: {raw[:1200]!r}")
    print("PUT ok; langs now:", ", ".join(sorted((updated.get("listings") or {}))))

    file_upload_url = updated.get("fileUploadUrl") or sub.get("fileUploadUrl")
    if not file_upload_url:
        die("submission has no fileUploadUrl for screenshot zip")
    upload_zip_to_sas(
        str(file_upload_url),
        zip_screenshots(sorted(new_listings), screenshot_files),
    )
    print(
        "note: PendingUpload → Uploaded happens during commit processing, "
        "not before; committing now with per-language zip paths"
    )

    if args.no_commit:
        print("skipping commit (--no-commit)")
        return 0

    print("committing submission???")
    code, _, raw = http_json("POST", f"{sub_url}/commit", token, empty_body=True)
    if code not in (200, 202):
        die(f"commit failed HTTP {code}: {raw[:1200]!r}")
    print(f"commit accepted (HTTP {code}). Partner Center will certify asynchronously.")

    # Poll briefly so logs show whether shots actually bound.
    print("post-commit screenshot check???")
    deadline = time.time() + 120
    while time.time() < deadline:
        code, check, raw = http_json("GET", sub_url, token)
        if code != 200 or not isinstance(check, dict):
            print(f"  GET after commit HTTP {code}; stopping poll")
            break
        code_st, st, _ = http_json("GET", f"{sub_url}/status", token)
        status = submission_status(check, st if isinstance(st, dict) else None)
        counts = screenshot_image_counts(
            check.get("listings") or {}, uploaded_only=True
        )
        missing = [lang for lang in new_listings if counts.get(lang, 0) < 1]
        print(
            f"  status={status} uploaded_ok="
            f"{sum(1 for n in counts.values() if n >= 1)}/{len(new_listings)}"
        )
        if not missing:
            print("all langs have Uploaded screenshots after commit")
            break
        if status in LOCKED_STATUSES | COMMIT_IN_FLIGHT and time.time() > deadline - 30:
            # still processing; leave it
            pass
        time.sleep(8)
    else:
        print(
            "warning: not every language shows Uploaded screenshots yet; "
            "check Partner Center (may still be processing)"
        )

    print("(published was", published.get("id"), ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
