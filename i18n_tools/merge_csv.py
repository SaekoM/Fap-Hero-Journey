#!/usr/bin/env python3
"""Merge translation fragments + manual keys into locale/zh_CN.csv.

Inputs:
  i18n_work/extracted_strings.json  - the authoritative key set (from the code)
  i18n_work/manual_keys.json        - keys the extractor can't see (consts, ids)
  i18n_work/batches/*.json          - key lists per batch (validity reference)
  i18n_work/fragments/*.json        - {english key: zh translation} per batch
  i18n_work/uppercase_keys.json     - keys that also need an UPPERCASE variant
                                      (buttons pass through .to_upper() in
                                      UITheme.style_button / make_tag_chip)

Output: locale/zh_CN.csv  (Godot CSV translation, header "keys,zh_CN", UTF-8)

Godot's automatic translation looks up the exact string assigned to a text
property, so the key column must match the source literals byte-for-byte.
"""

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_CSV = ROOT / "locale" / "zh_CN.csv"


def main():
    extracted = json.loads((ROOT / "i18n_work" / "extracted_strings.json").read_text(encoding="utf-8"))
    valid_keys = {e["key"] for e in extracted}
    manual = json.loads((ROOT / "i18n_work" / "manual_keys.json").read_text(encoding="utf-8"))
    upper_candidates = set(json.loads((ROOT / "i18n_work" / "uppercase_keys.json").read_text(encoding="utf-8")))

    translations = {}
    dropped = []
    frag_dir = ROOT / "i18n_work" / "fragments"
    for frag in sorted(frag_dir.glob("*.json")):
        data = json.loads(frag.read_text(encoding="utf-8"))
        for key, zh in data.items():
            if not isinstance(zh, str) or zh.strip() == "":
                dropped.append((frag.name, key, "empty translation"))
                continue
            if key in translations and translations[key] != zh:
                print(f"CONFLICT {key!r}: {translations[key]!r} vs {zh!r} ({frag.name})")
            translations[key] = zh

    missing = []
    for key in sorted(translations):
        if key not in valid_keys and key not in manual:
            dropped.append(("merge", key, "key not in extracted/manual"))
    # keep them anyway? no - dead rows would rot. Log and drop.
    translations = {k: v for k, v in translations.items() if k in valid_keys or k in manual}
    for frag_name, key, why in dropped:
        missing.append(f"{frag_name}: {why}: {key!r}")

    for key, zh in manual.items():
        if key not in translations:
            translations[key] = zh

    # uppercase variants (same translation; Chinese has no case)
    rows = {}
    for key, zh in translations.items():
        rows[key] = zh
    for key in upper_candidates:
        if key not in translations:
            continue
        up = key.upper()
        if up != key and up not in rows:
            rows[up] = translations[key]

    OUT_CSV.parent.mkdir(exist_ok=True)
    with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n", quoting=csv.QUOTE_ALL)
        w.writerow(["keys", "zh_CN"])
        for key in sorted(rows):
            w.writerow([key, rows[key]])

    print(f"wrote {OUT_CSV.relative_to(ROOT)}: {len(rows)} rows "
          f"({len(translations)} base + {len(rows) - len(translations)} uppercase variants)")
    if missing:
        print(f"dropped {len(missing)} entries:")
        for m in missing[:40]:
            print("  " + m)


if __name__ == "__main__":
    main()
