# Unreleased changelog fragments

Each PR adds **one new unique file** here so agents never share `CHANGELOG.md`
`## Unreleased` (that causes merge conflicts on `dev`).

## Name

`pr-<short-slug>.md` or `{YYYYMMDD}-{slug}.md`. If the name already exists, pick
another (append `-2`, a timestamp, etc.).

## Format

```md
### Fixes
- user-facing bullet testers should see in the in-app updater

Never name copyrighted titles, real movies/shows, or catalog brands in
user-facing bullets. Tests may use dummy titles; public notes describe
behavior only.

### Dev notes
- implementation / cache internals (stripped at publish)
```

Use `### Features`, `### Fixes`, `### Player`, or another `###` heading as
appropriate. Do **not** bump versions. Do **not** edit `CHANGELOG.md` Unreleased.

## Publish

`tool/deploy_update.py` / `tool/local_release.sh` concatenates these files with
any leftover `## Unreleased` bullets still in `CHANGELOG.md`, strips
`### Dev notes` for `latest.json`, and **after a successful publish** folds the
assembled notes under `## version+build (date)`, clears Unreleased, and deletes
these fragment files (so the next cut only includes new notes). Hybrid Dev
commits that fold so `git reset --hard origin/dev` does not restore them.
Do **not** fold on ordinary agent PRs — only publish does.
