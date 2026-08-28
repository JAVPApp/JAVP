# Microsoft Store (Windows)

Windows sideload ships via **Inno Setup** (`javp-setup.exe`) and **WinGet**
(`JAVPApp.JAVP`). The **Microsoft Store** is a separate **MSIX** channel through
[Partner Center](https://partner.microsoft.com/). Product overview:
[features.md](features.md). Sideload updates: [updates.md](updates.md).

Partner Center product **JAVP** is reserved (`9P4PMM405RZH`, Cubeweb). Identity
fields are in `pubspec.yaml` `msix_config`. Package updates go through GitHub
Actions + the `msstore` CLI when secrets exist.

## Channels (same pattern as Play)

| Channel | Artifact | Self-update | Define |
| --- | --- | --- | --- |
| **sideload** (default) | zip / Inno / winget | Yes (`updater.javp.app`) | `JAVP_DISTRIBUTION=sideload` |
| **msstore** | MSIX (`--store`) | No (Store updates) | `JAVP_DISTRIBUTION=msstore` |

Always pass the define when building the Store package so Settings / updater
hide in-app install. Store builds are **not** published to `updater.javp.app`
/ `deploy_update.py` FTP — the Store owns delivery.

## Product identity (filled)

| Field | Value |
| --- | --- |
| Store ID | `9P4PMM405RZH` |
| Package/Identity name | `Cubeweb.JAVP` |
| Publisher | `CN=C2181184-0E48-441B-94C4-B746E8C0BF5F` |
| Publisher display name | `Cubeweb` |
| Seller ID | `95689130` |

## Build MSIX (on Windows)

Needs Flutter Windows toolchain + the `msix` dev dependency.

```powershell
powershell -File tool/build_msix.ps1
# or local test package (not for Store):
powershell -File tool/build_msix.ps1 -LocalTest
```

Equivalent:

```powershell
flutter pub get
flutter build windows --release `
  --dart-define=JAVP_DISTRIBUTION=msstore

dart run msix:create --store
```

Output is under `build/windows/` (exact path printed by `msix:create`). The
`--store` flag produces a package for Partner Center; Microsoft signs it after
upload (no local cert required for Store).

### Version

`msix_version` must be four-part (`major.minor.build.revision`). The Store
requires **revision (4th) = 0**. For main/stable releases CI maps
`version: X.Y.Z+N` → `msix_version: X.Y.Z.0` (patch bumps carry the Store
version; `+N` is not encoded). The first Store upload used `0.5.65.0` as a
one-off; the next Store cut is expected at `0.6.x.0`. Keep `msix_version` in
sync locally when bumping (see `.cursor/rules/semver.mdc`).

## First Store submission (manual)

1. Partner Center → **JAVP** → **Start submission** (Submission 1).
2. **Pricing and availability** — Free, worldwide, public / discoverable.
3. **Properties** — category (e.g. Photo & video / Multimedia), privacy URL
   `https://javp.app/privacy.html`.
4. **Age ratings** — complete the questionnaire (18+ / not for children is
   consistent with Play copy).
5. **Packages** — upload the `.msix` / `.msixupload` from `msix:create --store`
   (or the MSIX attached to a GitHub Release by CI).
6. **Store listings** — reuse Play copy from [`play-store.md`](play-store.md)
   where it fits; screenshots required.
7. Submit for certification.

## Store listing copy (git)

Localized Store **text** lives under [`store-assets/msstore/listings/`](../store-assets/msstore/listings/).
Push with `python3 tool/msstore_sync_listings.py` (same `AZURE_AD_*` secrets),
or let CI do it: **Sync Microsoft Store listings** runs only when those JSON
files (or the sync tool) change on `main` — not on every Release. See
[`store-assets/msstore/README.md`](../store-assets/msstore/README.md).

## CI — package updates (like WinGet)

After the app is **live**, a GitHub **Release** for `vX.Y.Z` auto-builds a Store
MSIX and submits when secrets are present. Pushing the tag is enough: CI creates
the Release if it is missing ([`create-stable-release.yml`](../.github/workflows/create-stable-release.yml)).
`tool/local_release.sh` does the same before downloading desktop assets.

| Workflow | When |
| --- | --- |
| [`create-stable-release.yml`](../.github/workflows/create-stable-release.yml) | Push of stable tag `vX.Y.Z` — creates the GitHub Release if missing |
| [`deploy-update.yml`](../.github/workflows/deploy-update.yml) `msstore` job | `release: published` (soft-skip if secrets missing; still attaches MSIX to the Release) |
| [`publish-msstore.yml`](../.github/workflows/publish-msstore.yml) | Manual retry (`workflow_dispatch`) |

Patch Releases skip the macOS job; Deploy update still runs Store/WinGet after
Windows assets attach (`always()` on those jobs so a skipped macOS build cannot
strand them).

### Secrets (repo → Settings → Secrets → Actions)

| Secret | Where to get it |
| --- | --- |
| `SELLER_ID` | Partner Center → Account settings → **95689130** |
| `AZURE_AD_TENANT_ID` | Entra admin center → Overview → Tenant ID |
| `AZURE_AD_APPLICATION_CLIENT_ID` | Entra app registration → Application (client) ID |
| `AZURE_AD_APPLICATION_SECRET` | Same app → Certificates & secrets → New client secret |

### One-time Azure AD setup

1. Associate a Microsoft Entra tenant with Partner Center (Account settings),
   or create one from Partner Center.
2. Register an application in Entra ID (single-tenant is fine).
3. Partner Center → **Account settings** → **User management** →
   **Microsoft Entra applications** → add that app → role **Manager**.
4. Add the four secrets above. Until they exist, CI still builds + attaches
   the MSIX to the GitHub Release for manual upload.

API updates require the product to already be **published** once. First
certification stays a browser submit.

## Policy notes for JAVP

- **No self-update** on `msstore` builds (`Distribution.enablesSelfUpdate` is
  false). Users get updates from the Store only.
- Declare only capabilities you need (default: `internetClient`). Protocol
  handlers / custom capabilities need explicit Store declarations.
- WinGet + Inno remain for non-Store users; they are not replaced by MSIX.

## Checklist

- [x] Paste Partner Center identity into `pubspec.yaml` `msix_config`
- [x] CI workflows for MSIX build + optional `msstore` submit
- [x] Finish Submission 1 listing (pricing Free, age ratings, screenshots)
- [x] Build / upload first MSIX (Windows or GHA artifact)
- [x] Add Azure AD Manager app + four repo secrets
- [x] Store listing JSON in git + `msstore_sync_listings.py` (multi-language push)
- [x] Tag push / `local_release` auto-create GitHub Release so Store is not forgotten

- [ ] Smoke-test Store install after certification
- [ ] Confirm Release auto-submit on the next Stable cut

## Related

- Sideload Windows / WinGet: [`docs/updates.md`](updates.md),
  [`deploy/winget/README.md`](../deploy/winget/README.md)
- Android Play: [`docs/play-store.md`](play-store.md)
- Fire TV / Amazon Appstore: [`docs/fire-tv.md`](fire-tv.md)
- Huawei AppGallery / HarmonyOS: [`docs/harmonyos.md`](harmonyos.md)
- Apple App Store: [`docs/app-store.md`](app-store.md)
- Flutter: [Deploy Windows](https://docs.flutter.dev/deployment/windows)
- Microsoft: [Publish with GitHub Actions](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/github-actions)
