# Localization tooling

English UI copy lives in `lib/l10n/app_en.arb` (source of truth). Other
`lib/l10n/app_<locale>.arb` files are translations. `flutter gen-l10n`
(via `flutter pub get` / `flutter build`) generates `AppLocalizations` Dart
into `lib/l10n/`; those Dart files are **gitignored**.

Agents must not read or edit translation catalogs. Use `add_en.py`.

## Daily workflow (agents / English)

```bash
python3 tool/l10n/add_en.py myKey                 # print current English
python3 tool/l10n/add_en.py myNewKey "The English string"
python3 tool/l10n/add_en.py myKey "Reworded" --update
# then use l10n.myNewKey in Dart
python3 tool/l10n/preflight.py
```

Do **not** Read `app_en.arb` wholesale — `add_en.py <key>` prints one string.
Do **not** translate into other locales. Do **not** commit
`lib/l10n/app_localizations*.dart`. Missing locale strings fall back to
English until Weblate or a human fills `app_<locale>.arb`.

## Daily workflow (translators)

Edit `lib/l10n/app_<locale>.arb`, or use Weblate (see below). Never rewrite
locale files from English in bulk — that clobbers real translations.

## CI vs release

| Check | Blocks build? |
| --- | --- |
| Invalid `app_en.arb` (empty English, placeholder mismatch) | **Yes** |
| Dart `l10n.foo` missing from `app_en.arb` | **Yes** — `preflight.py` |
| Locale ARB missing a key / still English | **No** — Flutter falls back to English; tracked by `report_untranslated.py` |
| Generated `app_localizations*.dart` | **N/A** — not committed; `flutter pub get` regenerates |

Release paths (`tool/local_release.sh`, Deploy update) run `preflight.py`
before `flutter build`. Discord hybrid dispatch runs the same preflight and
**does not** `gh workflow run` if it fails. `generate_arbs.py` is a no-op
shim for older wrappers.

## Scripts

- `add_en.py` — print, add, or `--update` one English key in `app_en.arb` (optional `flutter gen-l10n`)
- `preflight.py` — fail-fast English ARB vs Dart (no ARB rewrite); `--from-git REF`
- `check_l10n.py` — same as preflight (`--check-only` / `--strict` are deprecated aliases)
- `report_untranslated.py` — markdown/JSON report of keys needing translation
- `generate_arbs.py` — **no-op** (retired `messages.json` generator)
- `test_check_l10n.py` — `python3 tool/l10n/test_check_l10n.py`

## Weblate

Translations are maintained in-repo as ARB files so releases never depend on
a live TMS. Weblate (hosted or self-hosted) should point at this GitHub repo:

| Field | Value |
| --- | --- |
| File format | ARB |
| File mask | `lib/l10n/app_*.arb` |
| Monolingual base / template | `lib/l10n/app_en.arb` |
| New language | add `lib/l10n/app_<code>.arb` with `{"@@locale": "<code>"}` |

A copy-paste component file is [`weblate.ini`](weblate.ini). Typical setup:

1. Create a Weblate project linked to `JAVPApp/javp` (or your fork).
2. Add a component using the table above (or import `weblate.ini`).
3. Let Weblate open translation PRs (or push to a `weblate-*` branch).
4. Merge translation PRs separately from feature work — agents should not
   touch locale ARBs.

`nativeNames` in `lib/providers/locale_controller.dart` is the picker label
list; add a row there when introducing a new UI language.
