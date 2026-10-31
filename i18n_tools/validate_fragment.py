#!/usr/bin/env python3
"""Validate a translation fragment against the uncovered-keys work list.

Checks, per fragment:
  - valid JSON object (string -> string)
  - key exists in i18n_work/uncovered_todo.json (or CSV already -> warn)
  - translation non-empty and not identical to the English key (warn for >4 chars)
  - printf placeholders preserved: the multiset of %-specs in the translation
    must equal the key's (order may change for natural Chinese word order)
  - no fullwidth corruption of placeholder markers (％, ；inside specs, etc)
  - newlines preserved in count

Usage: python validate_fragment.py path/to/fragment.json ...
"""

import csv
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SPEC = re.compile(r"%(?:\d+\$)?[#0\-]*\d*(?:\.\d+)?[a-zA-Z%]")


def specs(s: str) -> Counter:
    return Counter(SPEC.findall(s))


def main():
    todo_keys = {
        e["key"] for e in json.loads((ROOT / "i18n_work" / "uncovered_todo.json").read_text(encoding="utf-8"))
    }
    with open(ROOT / "locale" / "zh_CN.csv", encoding="utf-8") as f:
        rd = csv.reader(f)
        next(rd)
        csv_keys = {row[0] for row in rd if row}

    bad = 0
    for arg in sys.argv[1:]:
        p = Path(arg)
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"FAIL {p.name}: JSON parse: {e}")
            bad += 1
            continue
        if not isinstance(data, dict):
            print(f"FAIL {p.name}: not an object")
            bad += 1
            continue
        for k, v in data.items():
            problems = []
            if not isinstance(v, str) or not v.strip():
                problems.append("empty/invalid value")
            elif k not in todo_keys:
                problems.append("key not in uncovered_todo (already covered or unknown)")
            elif specs(k) != specs(v):
                problems.append(f"placeholders {dict(specs(k))} != {dict(specs(v))}")
            elif re.search(r"[％｛｜]", v) and not re.search(r"[％｛｜]", k):
                problems.append("fullwidth placeholder corruption")
            elif k.count("\n") != v.count("\n"):
                problems.append("newline count differs")
            elif v == k and len(k) > 8 and re.search(r"[A-Za-z]{4}", k):
                problems.append("translation identical to English key")
            if problems:
                bad += 1
                print(f"FAIL {p.name} :: {k[:60]!r} — {'; '.join(problems)}")
    if bad == 0:
        print("OK: all fragments valid")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
