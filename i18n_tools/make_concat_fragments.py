#!/usr/bin/env python3
"""Build full-string translation fragments for concat chains.

Pairs with find_concat_chains.py: for every pure / wrap_tip-wrapped multi-
literal chain, joins the per-piece translations already in zh_CN.csv into one
translation for the FULL concatenated key (the only string Godot looks up at
display time). Prints every join for review and writes
i18n_work/fragments/zz_concat_full.json.
"""

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SINKS = re.compile(
    r"(?:\.text|\.tooltip_text|\.placeholder_text|\.dialog_text|\.window_title"
    r"|\.add_item|\.add_tab|\.set_tab_title|ok_button\(\)\.text|cancel_button\(\)\.text)\s*=\s*"
)
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'')


def unescape(s):
    if "\\" not in s:
        return s
    # only the escapes GDScript writes in source strings; unicode_escape would
    # corrupt non-ASCII characters (it decodes bytes as latin-1)
    for esc, ch in (("\\n", "\n"), ("\\t", "\t"), ('\\"', '"'), ("\\'", "'")):
        s = s.replace(esc, ch)
    return s


def main():
    fulls = json.loads((ROOT / "i18n_work" / "concat_full_keys.json").read_text(encoding="utf-8"))
    rows = {}
    with open(ROOT / "locale" / "zh_CN.csv", encoding="utf-8") as f:
        rd = csv.reader(f)
        next(rd)
        for r in rd:
            rows[r[0]] = r[1]

    pieces_map = {}
    for base in ("scripts", "Globals"):
        for p in (ROOT / base).rglob("*.gd"):
            lines = p.read_text(encoding="utf-8").splitlines()
            i = 0
            while i < len(lines):
                m = SINKS.search(lines[i])
                if not m:
                    i += 1
                    continue
                buf = lines[i][m.end():]
                j = i
                depth = buf.count("(") - buf.count(")")
                while depth > 0 and j + 1 < len(lines):
                    j += 1
                    buf += "\n" + lines[j]
                    depth += lines[j].count("(") - lines[j].count(")")
                if "tr(" not in buf and "+" in buf:
                    lits = [a or b for a, b in LIT.findall(buf)]
                    if len(lits) >= 2:
                        full = "".join(unescape(x) for x in lits)
                        if full in fulls:
                            pieces_map.setdefault(full, [unescape(x) for x in lits])
                i = j + 1 if j > i else i + 1

    missing = []
    frag = {}
    for full in fulls:
        pieces = pieces_map.get(full)
        if pieces is None:
            missing.append(full)
            continue
        zh_parts = []
        for pc in pieces:
            zh = rows.get(pc) or rows.get(pc.upper())
            if zh is None:
                missing.append((full[:40], pc[:60]))
                zh_parts.append(None)
            else:
                zh_parts.append(zh)
        if all(z is not None for z in zh_parts):
            frag[full] = "".join(zh_parts)

    print(f"generated: {len(frag)} | sites without source match: {len(missing)}")
    for m in missing[:10]:
        print("  MISSING:", str(m)[:110])
    for k, v in frag.items():
        print("----")
        print("EN:", k.replace("\n", "\\n"))
        print("ZH:", v.replace("\n", "\\n"))
    (ROOT / "i18n_work" / "fragments" / "zz_concat_full.json").write_text(
        json.dumps(frag, indent=1, ensure_ascii=False), encoding="utf-8"
    )
    print(f"wrote fragments/zz_concat_full.json: {len(frag)}")


if __name__ == "__main__":
    main()
