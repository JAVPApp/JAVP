# Cursor rules

Five files. Only three are always on.

| File | When it attaches |
| --- | --- |
| `l10n.mdc` | Always — English via `add_en.py`, never locale ARBs |
| `semver.mdc` | Always — agent PRs do not bump `X.Y.Z` / `+N` |
| `open-pr-branches.mdc` | Always — do not merge `dev` into sibling PRs |
| `ui-isolate.mdc` | Live / VOD / EPG / catalog / isolate files, or a list-load freeze |
| `dev-build-means-publish.mdc` | Deploy scripts / `docs/updates.md`, or “dev build” / ship testers |

Code map: [`docs/architecture.md`](../../docs/architecture.md). Process (changelog, Cloud, publish): [`AGENTS.md`](../../AGENTS.md).
