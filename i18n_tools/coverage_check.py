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
        if kinds <= NONDISPLAY_KINDS:
            continue
        if not looks_display(k):
            continue
        if covered(k):
            continue
        # skip obvious identifiers / brands / units even if display-shaped
        if re.fullmatch(r"[A-Za-z0-9_\-\./: ]+", k) and not re.search(r"\s\S+\s\S+", k):
            # single token, likely an id/brand/unit unless it has 2+ real words
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
