#!/usr/bin/env python3
"""Cross-checks for the zh_CN localisation:

1. tr("...") literals in code that have no CSV row (they would display English).
2. Strings whose .to_upper() result reaches a text sink, where the uppercased
   form has no CSV row (runtime lookup happens on the uppercased form).
3. CSV keys containing a lone '%' (possible literal percent) whose usage sites
   apply the % operator — those would crash or corrupt at runtime.
"""

import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LIT = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'')
TR_CALL = re.compile(r"\btr\(\s*")
SINKS = re.compile(r"(?:\.text|\.tooltip_text|\.placeholder_text|\.dialog_text|\.add_item|\.add_tab)\s*=[^=]")
SPEC = re.compile(r"%(?:\d+\$)?[#0\-]*\d*(?:\.\d+)?[a-zA-Z%]")


def unescape(s: str) -> str:
    # only the escapes GDScript writes in source strings; unicode_escape would
    # corrupt non-ASCII characters (it decodes bytes as latin-1)
    for esc, ch in (("\\n", "\n"), ("\\t", "\t"), ('\\"', '"'), ("\\'", "'")):
        s = s.replace(esc, ch)
    return s


def main():
    rows = {}
    with open(ROOT / "locale" / "zh_CN.csv", encoding="utf-8") as f:
        rd = csv.reader(f)
        next(rd)
        for r in rd:
            rows[r[0]] = r[1]

    # 1. tr("literal") without a CSV row
    miss_tr = []
    for base in ("scripts", "Globals"):
        for p in (ROOT / base).rglob("*.gd"):
            src = p.read_text(encoding="utf-8")
            for m in TR_CALL.finditer(src):
                rest = src[m.end():]
                lm = LIT.match(rest.lstrip())
                if lm:
                    key = unescape(lm.group(1) if lm.group(1) is not None else lm.group(2))
                    if key and key not in rows and key.upper() not in rows:
                        ln = src[: m.start()].count("\n") + 1
                        miss_tr.append((str(p.relative_to(ROOT)), ln, key[:70]))
    print(f"tr() literals with no CSV row: {len(miss_tr)}")
    for f, ln, k in miss_tr[:25]:
        print(f"  {f}:{ln}  {k!r}")

    # 2. <expr>.to_upper() assigned to a text sink -> uppercase form must be a key
    miss_up = []
    for base in ("scripts", "Globals"):
        for p in (ROOT / base).rglob("*.gd"):
            lines = p.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                sm = SINKS.search(line)
                if sm and ".to_upper()" in line:
                    lm = LIT.search(line)
                    if lm:
                        key = unescape(lm.group(1) if lm.group(1) is not None else lm.group(2))
                        if key.upper() not in rows:
                            miss_up.append((str(p.relative_to(ROOT)), i + 1, key.upper()[:60]))
    print(f"to_upper sink literals with no uppercase CSV row: {len(miss_up)}")
    for f, ln, k in miss_up[:25]:
        print(f"  {f}:{ln}  {k!r}")

    # 3. lone-% keys formatted at runtime
    lone = [k for k in rows if "%" in SPEC.sub("", k)]
    bad = []
    for k in lone:
        for base in ("scripts", "Globals"):
            for p in (ROOT / base).rglob("*.gd"):
                src = p.read_text(encoding="utf-8")
                if k in src:
                    for lm in re.finditer(re.escape(k), src):
                        tail = src[lm.end(): lm.end() + 400]
                        # a % operator applied to this literal (tr(...) % or "..." %)
                        after = tail.split("\n")[0]
                        if re.search(r"(%\s*[A-Za-z_(\[]|\btr\()", after) and re.search(r"[%]\s", tail[:200]):
                            bad.append((k[:50], str(p.relative_to(ROOT))))
                            break
                    else:
                        continue
                    break
    print(f"lone-% keys formatted at runtime: {len(bad)}")
    for k, f in bad[:10]:
        print(f"  {k!r}  @ {f}")


if __name__ == "__main__":
    main()
