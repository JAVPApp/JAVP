# Flutter web companion (web.javp.app) — **alpha**

Browser build is an **alpha companion**, not a full replacement for native apps.
Prefer Android / desktop for daily use.

Playback uses the browser `video_player` stack (HTTPS progressive / HLS where
CORS and codecs allow). Sources and library UI work; many native features are
gated off (`AppCapabilities`).

## Limits

| Area | Web | Native |
| --- | --- | --- |
| Torrents / Cast / PiP / downloads / LAN pairing | No | Yes |
| Stream / poster proxy | **No** — browser talks to sources directly | N/A |
| HTTP (plain) streams on `https://web.javp.app` | Mixed content blocked | Yes |
| HTTPS → HTTP redirects | Not followed | Followed |
| Local folder sync | No | Yes (where pickers exist) |
| Google Drive / WebDAV sync | Yes (GIS + Drive) | Yes |
| Self-update | Redeploy static site | Sideload updater |

Copy blames the **web app / browser**, not the user’s playlist. HTTP-only lists
show a banner; prefer **Download the app**, or allow insecure content for
`web.javp.app` in Chrome/Edge, then Retry.

## Google Drive

Same **Web** OAuth client as Android `serverClientId`. In Cloud Console →
Credentials → Web client:

1. **Authorized JavaScript origins:** `https://web.javp.app`, plus
   `http://localhost` / `http://localhost:<port>` for local runs
2. Enable **Google Drive API**
3. `web/index.html` includes `google-signin-client_id` for GIS

Sign-in is **two steps**: identity button, then **Allow Drive access** (popup
must be user-gesture). Origin should send
`Cross-Origin-Opener-Policy: same-origin-allow-popups` (see `deploy/web.nginx.conf`).
PWA service worker is disabled for the same reason.

## Deep links

- `https://javp.app/add?…` (native + landing)
- Landing may offer **Open in web app** → `https://web.javp.app/add?…`
- Path URL strategy; host must SPA-fallback to `index.html`

## Build & deploy

```bash
flutter build web --release \
  --dart-define=JAVP_DISTRIBUTION=sideload \
  --pwa-strategy=none
```

Output: `build/web/`.

**Policy:** `web.javp.app` tracks **stable / main** only — not Dev. Actions
publish on GitHub Release (`v*`) or manual **Build Web → publish_ftp** from
`main`. Prefer that over ad-hoc `tool/deploy_web.py` once past bring-up.

## Related

[features.md](features.md) · [sync.md](sync.md) · [roadmap.md](roadmap.md)
