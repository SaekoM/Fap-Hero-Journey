#!/usr/bin/env python3
"""Coverage gate: report extracted display keys with no CSV translation row.

Uses the same `translatable` heuristic as split_batches so the two agree on
what 'needs a translation'. Prints keys grouped by kind for triage, and a
final COVERAGE number. Intended to run after merge_csv.py.
"""

import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def looks_display(key: str) -> bool:
    if not key or not key.strip():
        return False
    if "_" in key and " " not in key:
        return False
    return bool(re.search(r"[A-Za-z]{3}", key))


# Godot's automatic translation only fires on a complete literal assigned to a
# text sink. Pure-signal names, dict keys harvested only as 'dynamic', and
# known non-display kinds are excluded from the 'must be translated' set.
NONDISPLAY_KINDS = {"dynamic"}
# Signal names the statement-merging extractor mis-attributes to a display
# ternary (they appear in connect() calls near the item toast builder); they
# never reach a text sink.
NONDISPLAY_KEYS = {
    "DeviceAdded", "DeviceRemoved", "ItemActivated", "ItemRefused",
    "ItemUsed", "SaveRequested", "SkipRoundRequested", "Master", "Drop",
}


def main():
    extracted = json.loads((ROOT / "i18n_work" / "extracted_strings.json").read_text(encoding="utf-8"))
    with open(ROOT / "locale" / "zh_CN.csv", encoding="utf-8") as f:
        rd = csv.reader(f)
        next(rd)  # header
        csv_keys = {row[0] for row in rd if row}

    # a key is covered if it or its .upper() (style_button uppercases raw text)
    # has a CSV row
    def covered(k: str) -> bool:
        return k in csv_keys or k.upper() in csv_keys

    missing = {}
    for e in extracted:
        k = e["key"]
        kinds = {s["kind"] for s in e["sites"]}
        if kinds <= NONDISPLAY_KINDS or k in NONDISPLAY_KEYS:
            continue
        if not looks_display(k):
            continue
        if covered(k):
            continue
        # skip only TRUE identifier-shaped single tokens: no space at all, and
        # lowercase-id / number / path shaped. Anything with a space is treated as
        # display text — "COVER IMAGE" and "Clip tags" are real UI labels, and the
        # old two-word heuristic silently skipped every one of them.
        if re.fullmatch(r"[a-z0-9_\-\./:]+|[A-Z0-9_\-\./:]+|[A-Za-z0-9_\-\./:]*[0-9][A-Za-z0-9_\-\./:]*", k):
            continue
        missing.setdefault(k, sorted(kinds))

    print(f"CSV rows: {len(csv_keys)}")
    print(f"uncovered display keys: {len(missing)}")
    by_kind = {}
    for k, kinds in missing.items():
        key = ",".join(kinds)
        by_kind.setdefault(key, []).append(k)
    for kinds, ks in sorted(by_kind.items(), key=lambda x: -len(x[1])):
        print(f"\n[{kinds}] {len(ks)}")
        for k in sorted(ks)[:60]:
            print("   ", repr(k)[:90])
    if "--list" in sys.argv:
        (ROOT / "i18n_work" / "uncovered.json").write_text(
            json.dumps(sorted(missing), ensure_ascii=False, indent=1), encoding="utf-8")
        print("\nwrote i18n_work/uncovered.json")


if __name__ == "__main__":
    main()
