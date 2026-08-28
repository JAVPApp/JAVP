# Profiles & sync

**Settings → Profiles.** Each profile has its own history, sources, preferences,
optional lock PIN, and sync target on the device.

## Profiles

- A **PIN** (⋮ on the active profile) is required to **open** that profile. It
  stays on the device and is **never** written to a sync snapshot.
- If the last profile was locked, JAVP shows a picker so someone else can open
  an unlocked profile.
- Removing a profile deletes only this device’s copy; Drive / WebDAV / the
  folder is left alone.
- A phone can **add a profile on the TV** over LAN pairing (scan QR → Send →
  **Add as a new profile on the other device**), with optional sync settings
  for that new profile.

## Sync backends

Each profile picks one target:

| Target | Good for |
| --- | --- |
| **Synced folder** | Syncthing, a Drive / Dropbox / Nextcloud **desktop** folder, a mounted share |
| **WebDAV** | Nextcloud, ownCloud, most NAS boxes |
| **Google Drive** | Phone / TV without a mirrored folder — OAuth into a `javp/` folder in Drive |

Automatic sync (on by default for that profile) runs on open, on resume, and
after local changes. While a title is playing, auto-sync still **pushes** but
defers applying the merge into memory until playback ends. Source edits push
within a few seconds. Closing or backgrounding with a push pending finishes
that push.

## Google Drive OAuth

| Platform | Flow |
| --- | --- |
| **Android** | Google Sign-In (no client secret in the APK) |
| **Desktop** | System browser → `http://127.0.0.1:<port>/` + PKCE |
| **Web** | Google Identity Services button |

### Cloud Console clients

1. **Android** OAuth clients — **one client per (package + SHA-1)**. Play
   Services matches by signing cert; Android client ids are **not** passed to
   `google_sign_in` (`clientId` is unsupported on Android).

   | Package | SHA-1 to register |
   | --- | --- |
   | `com.javp.javp` | Debug, **upload/sideload release**, and **Play App Signing** (separate clients if SHA-1s differ) |
   | `com.javp.javp.dev` | Same release/upload SHA-1 as sideload Dev |

   Known fingerprints (upload/sideload; add Play’s App Signing SHA-1 separately
   in Console):

   - Debug: `4D:8F:E2:58:D1:05:F7:A5:10:EE:90:E7:18:75:BC:BC:B1:8A:3B:4A`
   - Release (upload): `88:12:36:93:51:FA:15:C8:52:D4:D3:00:98:CC:FB:51:EC:4D:34:99`

   If Play Sign-In fails with “confirm the release SHA-1…”, register the
   **Play Console → App integrity → App signing** SHA-1 for `com.javp.javp`.

2. **Web** client — `serverClientId` for Sign-In on both Android packages
   (bundled as `GOOGLE_OAUTH_CLIENT_ID`).

3. **Desktop** client — loopback PKCE (bundled desktop client id). The Web
   client cannot use loopback redirects.

Google still requires the Desktop **client secret** at token exchange. Public
desktop builds POST code/refresh to `https://javp.app/api/google-oauth.php`
(secret stays server-side). Private builds may use
`--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=…`.

Scope: `drive.file` (app-created files under `javp/` in My Drive).

Folder sync pointed at the Google Drive **desktop** folder remains a fine
alternative to OAuth Drive.

## Snapshot format & merge

One JSON file per profile: `javp/profiles/<id>.json`.

| Behavior | Detail |
| --- | --- |
| **History** | Merge entry-by-entry. Removals travel as tombstones (`id` + `url:<playUrl>`). Clearing history wins via an empty section with a newer stamp. |
| **Everything else** | Last-write-wins per section (sources, favorites, …). |
| **Not synced** | Derived catalogs / channel indexes / bulk EPG — rebuilt by re-fetching sources. |
| **Off the wire** | Tracker OAuth tokens, Drive tokens, profile PINs (`want*Link` only). |
| **Plex** | Source includes server token, plex.tv token, and LAN/remote/relay URLs so another device can reach the same server. |

**Library data on the wire:** sources (+ secrets), history (slim rows +
tombstones), watchlist, favorites, recent channels, preferred qualities,
collections, playlists, EPG reminders, tracker statuses needed before the next
pull. Settings prefs: captions, skip segments, track languages, downloads,
metadata, display, live scrub, media-server quality.

## Concurrent writes

Compare-and-swap: loser re-merges instead of overwriting. WebDAV uses ETag
`If-Match`. Folder / Drive re-read immediately before write. Unreadable
snapshots are copied aside as `.damaged-<time>.json.bak`.

First sync: an untouched install adopts the remote copy; a device that already
has sources/history only fills gaps (an empty remote cannot wipe a real
library). “Has synced before” stamps are written only after a successful run.

## Stable ↔ Dev on one device

| OS | Behavior |
| --- | --- |
| **Desktop** | Stable and Dev share one app-data identity — sources/passwords persist across channels. |
| **Android** | `com.javp.javp` ↔ `com.javp.javp.dev` via ContentProvider (`*.shared_sources`), same-signer checks. Fresh install adopts the sibling when local storage is empty (or sibling stamp is newer). |

Older builds that still define `com.javp.permission.SHARED_SOURCES` can block
installing the other package until updated.

## Export / import (no Drive)

**Settings → Profiles → Export / import sources** → `javp-sources.json`
(`kind: javp-sources`). Secrets: omit, AES-256-GCM passphrase, or plaintext
after confirmation. Import: replace or add/update.

## Restore on another device

Welcome → **Restore from sync**, or **Profiles → Find profiles on this
target** / **Add profile from another sync target**.

## Related

- [Sources](sources.md) · [Features](features.md) · OAuth code:
  `lib/services/sync/google_drive_auth.dart`
