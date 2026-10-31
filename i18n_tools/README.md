# i18n tools — zh_CN localisation pipeline

Scripts used to build and maintain `locale/zh_CN.csv` (the Simplified Chinese
translation). Run everything from the project root.

## Pipeline

1. **Extract** — `python i18n_tools/extract_strings.py` scans `scripts/`,
   `Globals/` and `scenes/` for every string that reaches a text sink
   (`.text`, `.tooltip_text`, `.placeholder_text`, `add_item`, BBCode, scene
   files, …) and writes `i18n_work/extracted_strings.json`: one entry per
   unique key, with the file/line/kind of each usage site.

2. **Coverage gate** — `python i18n_tools/coverage_check.py` prints every
   display-shaped key that has no CSV row yet, grouped by kind, plus a final
   `COVERAGE` number. This is the definition of "the translation is
   complete": **zero uncovered display keys**.

3. **Translate** — translations live as `{english key: zh_CN}` JSON fragments
   in `i18n_work/fragments/*.json` (`i18n_work/` is gitignored scratch —
   regenerate with steps 1–2 if lost). Keys must match the extracted key
   byte-for-byte; `i18n_tools/validate_fragment.py fragment.json…` checks
   key match, printf placeholders, newlines and fullwidth corruption.
   `i18n_work/GLOSSARY.md` (mirrored here) fixes the terminology.

4. **Merge** — `python i18n_tools/merge_csv.py` folds all fragments plus
   `i18n_work/manual_keys.json` (keys the extractor can't see: consts, ids,
   anything that flows through a variable at runtime) into `locale/zh_CN.csv`,
   and adds UPPERCASE variants for every key in `i18n_work/uppercase_keys.json`
   (strings that pass through `.to_upper()` before a text sink — e.g. CatalogPicker
   headings — are looked up in their uppercased form).

5. **Probe** — `Godot --headless --path . --script i18n_tools/probe_i18n.gd` (spot-checks lookups)
   and `probe2.gd` (end-to-end: concat full keys, tr()-wrapped pieces, format templates,
   uppercase variants).

## The concatenation rule (why find_concat_chains.py exists)

Godot 4 auto-translation looks up the **stored** string at display time; there is no
per-literal injection at assignment. So `hint.text = ("a" + "b")` stores `"ab"` and only a
CSV row for the FULL `"ab"` can ever match — per-piece keys silently miss.
`find_concat_chains.py` finds every multi-literal chain reaching a text sink without `tr()`;
pure chains are fixed by adding the full string as a key (`make_concat_fragments.py` joins
the piece translations, `apply_concat_translations.py` writes hand-polished ones), while
chains that mix identifiers get the literals wrapped in `tr()` by hand.
`audit_crosscheck.py` cross-checks code ↔ CSV both ways: `tr()` literals without a row,
`.to_upper()` results without an uppercase row (uppercase forms are what get looked up),
and lone-`%` keys that a `%` operator would corrupt at runtime.

## Runtime notes

- Godot 4 auto-translates any string assigned to a text property by looking
  it up in the registered CSV translation at runtime. Format/concatenation
  sites wrap the template in `tr("…")` explicitly so the lookup hits before
  `%`-substitution; each literal piece of a concatenated sentence is looked
  up separately, so long hints are split across CSV rows per source literal.
- The CJK glyphs come from `assets/fonts/NotoSansCJKsc-Regular.otf`, installed
  as a global glyph fallback in `Globals/UITheme.gd`; `UITheme.wrap_tip` is
  display-width aware so CJK tooltips wrap.
- UI language lives in `SettingsService` (`locale/language`, `auto` follows
  the OS), selectable under Options → GENERAL → UI LANGUAGE.
- `i18n_work/.gdignore` keeps the scratch directory out of the exported pack.
