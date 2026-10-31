#!/usr/bin/env python3
"""Find multi-literal concatenation chains reaching text sinks without tr().

Godot 4.x auto-translation looks up the STORED string at display time, so
`hint.text = ("a" + "b")` stores "ab" and only the full "ab" can be a CSV key.
This lists every such chain:
  - pure-literal chains      -> fixable by adding the full string as a CSV key
  - call-wrapped (wrap_tip)  -> same, wrap_tip translates the full arg itself
  - mixed (identifiers/%-op) -> need small code edits (tr() around the literals)

Output: i18n_work/concat_full_keys.json {full_key: {file, line, wrapped}}
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SINKS = re.compile(
    r"(?:\.text|\.tooltip_text|\.placeholder_text|\.dialog_text|\.window_title"
    r"|\.add_item|\.add_tab|\.set_tab_title|ok_button\(\)\.text|cancel_button\(\)\.text)"
    r"\s*=\s*"
)
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'')
WRAPPERS = re.compile(r"\b(?:UITheme\s*\.\s*)?wrap_tip\s*\(|\btr\s*\(|\bstr\s*\(")


def unescape(s: str) -> str:
    # only the escapes GDScript writes in source strings; unicode_escape would
    # corrupt non-ASCII characters (it decodes bytes as latin-1)
    for esc, ch in (("\\n", "\n"), ("\\t", "\t"), ('\\"', '"'), ("\\'", "'")):
        s = s.replace(esc, ch)
    return s


def main():
    pure, mixed, wrapped = [], [], []
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
                        probe = WRAPPERS.sub("", buf)
                        stripped = LIT.sub("", probe)
                        residue_ids = re.search(r"[A-Za-z_][A-Za-z0-9_]*", stripped)
                        fmt_ops = re.search(
                            r"%\s*[A-Za-z_(]", re.sub(r"%%", "", re.sub(r"%[\d.#]*[a-zA-Z]", "", stripped))
                        )
                        is_wrapped = "wrap_tip" in buf
                        full = "".join(unescape(x) for x in lits)
                        rec = (str(p.relative_to(ROOT)).replace("\\", "/"), i + 1, full, buf[:60].replace("\n", " "))
                        if residue_ids or fmt_ops:
                            mixed.append(rec)
                        elif is_wrapped:
                            wrapped.append(rec)
                        else:
                            pure.append(rec)
                i = j + 1 if j > i else i + 1

    print(f"pure-literal chains: {len(pure)}")
    for r in pure:
        print(f"  PURE {r[0]}:{r[1]} | {r[3]}")
    print(f"wrap_tip-wrapped chains: {len(wrapped)}")
    for r in wrapped:
        print(f"  TIP  {r[0]}:{r[1]} | {r[3]}")
    print(f"mixed chains (need code edits): {len(mixed)}")
    for r in mixed:
        print(f"  MIXED {r[0]}:{r[1]} | {r[3]}")

    out = {}
    for f, ln, full, _ in pure + wrapped:
        out.setdefault(full, {"file": f, "line": ln, "wrapped": f in [w[0] for w in wrapped]})
    (ROOT / "i18n_work" / "concat_full_keys.json").write_text(
        json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8"
    )
    print(f"wrote concat_full_keys.json: {len(out)} unique full keys")


if __name__ == "__main__":
    main()
