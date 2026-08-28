# Microsoft Store assets (git source of truth)

Listing **text** for Partner Center lives here. CI / `tool/msstore_sync_listings.py`
pushes these into a Store submission (same Entra Manager secrets as
`publish-msstore`).

```
store-assets/msstore/
  listings/          # one JSON per Store language code (en-us.json, fr-fr.json, …)
  screenshots/       # Desktop PNGs (≥1366×768); sync uploads into *every* language
  README.md
```

## Listing JSON shape

```json
{
  "title": "JAVP",
  "shortTitle": "JAVP",
  "voiceTitle": "JAVP",
  "shortDescription": "…",
  "description": "…",
  "features": ["…", "…"],
  "devStudio": "Cubeweb",
  "websiteUrl": "https://javp.app",
  "privacyPolicy": "https://javp.app/privacy.html"
}
```

Filename stem = Partner Center language code (`en-us`, `zh-hans`, `pt-br`, …).
`en-us.json` is required (screenshot/icon source).

## How screenshot upload works (MSIX)

JAVP is an **MSIX** app, so listings use the classic Partner Center submission
API (`manage.devcenter.microsoft.com`). Screenshots go in one ZIP on
`fileUploadUrl`, with a **flat unique filename per language** (e.g.
`fr-fr-01-desktop.png`). Shared names only bind to one language; nested folder
paths stay `PendingUpload`.

The newer `api.store.microsoft.com` listing-assets API (per-PNG SAS URLs) is
documented for **MSI/EXE** products only — it returns “No Product Found” for
this Store ID.

## Push to Partner Center

Manual:

```bash
export AZURE_AD_TENANT_ID=…
export AZURE_AD_APPLICATION_CLIENT_ID=…
export AZURE_AD_APPLICATION_SECRET=…
export STORE_PRODUCT_ID=9P4PMM405RZH   # optional

python3 tool/msstore_sync_listings.py            # create/update + commit
python3 tool/msstore_sync_listings.py --inspect  # status + screenshot counts
python3 tool/msstore_sync_listings.py --no-commit
python3 tool/msstore_sync_listings.py --dry-run
```

**CI:** [`.github/workflows/sync-msstore-listings.yml`](../../.github/workflows/sync-msstore-listings.yml)
runs on **pushes to `main` that touch** `store-assets/msstore/listings/**`,
`store-assets/msstore/screenshots/**`, or the sync tool. Soft-skips if
`AZURE_AD_*` secrets are missing. Manual retry: Actions → **Sync Microsoft Store
listings** → Run workflow.

Package binaries stay on the Release / `publish-msstore` path — this folder is
for listing copy and Desktop store art.
