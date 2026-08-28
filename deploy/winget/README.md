# Winget manifests

Source manifests for submitting **JAVPApp.JAVP** to
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs).

Community path once merged:

```text
manifests/j/JAVPApp/JAVP/<version>/
```

## Current package

| Field | Value |
| --- | --- |
| Identifier | `JAVPApp.JAVP` |
| Installer | Inno Setup (`javp-setup.exe`) |
| Scope | per-user (`%LOCALAPPDATA%\Programs\JAVP`) |
| Silent | WinGet defaults for `InstallerType: inno` |

Locale manifests should use stable public URLs (`javp.app` and this GitHub
repo). License is **GPL-3.0-or-later** (`LicenseUrl` → the repo `LICENSE`).
Prefer `javp.app` for support / download links so WinGet validation stays
reliable if GitHub rate-limits or paths move.

## Automation (GitHub Actions)

After the **first** version is accepted into winget-pkgs
([PR #414628](https://github.com/microsoft/winget-pkgs/pull/414628)), each
stable `vX.Y.Z` tag:

1. Auto-creates the GitHub Release when missing (`create-stable-release.yml`).
2. Builds + attaches the setup exe (`Deploy update`).
3. Opens a winget-pkgs PR via [WinGet Releaser](https://github.com/vedantmgoyal9/winget-releaser)
   (`fork-user: xemles`).

Local FTP (`tool/local_release.sh`) still publishes `updater.javp.app`; WinGet
reads the installer from the GitHub Release asset.

### One-time secret

1. As **xemles**, create a [classic PAT](https://github.com/settings/tokens/new) with **`public_repo`**.
2. In **JAVPApp/JAVP** → Settings → Secrets and variables → Actions, add **`WINGET_TOKEN`**.
3. Keep the [xemles/winget-pkgs](https://github.com/xemles/winget-pkgs) fork; the action pushes branches there.

Manual retry: **Actions → Publish to WinGet → Run workflow** with the release tag
(e.g. `v0.3.0`). The release must already include `javp-setup.exe`.

## Manual bump (fallback)

1. Publish the new setup exe to `updater.javp.app` (see `docs/updates.md`).
2. Copy `0.3.0/` to the new version folder and update version / URL / SHA256.
3. Open a PR under `manifests/j/JAVPApp/JAVP/<version>/`.

Validate locally (optional):

```powershell
winget validate --manifest deploy/winget/JAVPApp.JAVP/0.3.0
winget install --manifest deploy/winget/JAVPApp.JAVP/0.3.0
```
