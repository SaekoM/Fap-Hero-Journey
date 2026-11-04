#!/usr/bin/env python3
"""Extract user-facing UI strings from the Fap Hero Journey codebase.

The UI is built dynamically in GDScript/C#, and Godot 4's automatic translation
looks up the exact string assigned to each text-bearing property. So the
localization strategy is:

  1. static assignments (.text = "Start")        -> no code change; the literal
     itself becomes the CSV key.
  2. composite assignments (format/concat)       -> need a tr() wrap (code edit);
     the format/concat literal becomes the key.
  3. tooltips routed through UITheme.wrap_tip()  -> no per-call change; wrap_tip
     gains an internal tr() and the inner literal becomes the key.
  4. data-driven strings (shop_items.json, tags.json, JourneyData catalogs...) ->
     the displayed English value becomes the key.

Outputs (under i18n_work/):
  extracted_strings.json   every candidate key with provenance
  needs_code_edit.json     sites that must gain an explicit tr() call
  stats.txt                quick counts

Usage: python i18n_tools/extract_strings.py
"""

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "i18n_work"
OUT.mkdir(exist_ok=True)

GD_DIRS = ["scripts", "Globals"]
CS_DIRS = ["Globals"]

# sinks whose whole expression we capture
SINK_RE = re.compile(
    r"(?:\.text\s*=|\.tooltip_text\s*=|\.placeholder_text\s*=|\.title\s*=|"
    r"\.dialog_text\s*=|\.subtitle\s*=|\.window_title\s*=|"
    r"\.add_item\s*\(|\.add_icon_item\s*\(|\.add_check_item\s*\(|"
    r"\.add_radio_check_item\s*\(|\.add_separator\s*\(|\.set_item_text\s*\(|"
    r"\.add_tab\s*\(|\.set_tab_title\s*\()"
)
CS_SINK_RE = re.compile(
    r"(?:\.Text\s*=|\.TooltipText\s*=|\.PlaceholderText\s*=|\.Title\s*=|"
    r"\.DialogText\s*=|\.AddItem\s*\()"
)

# calls that uppercase the raw text (translation key must match the uppercased form)
STYLE_UPPER_RE = re.compile(r"\b(?:style_button|style_button_subtle)\s*\(")
TAG_CHIP_RE = re.compile(r"\bmake_tag_chip\s*\(")

STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"' + r"|'(?:\\.|[^'\\])*'")
FORMAT_HINT_RE = re.compile(r"%[sdfv]|\.format\s*\(")

GD_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f",
    "v": "\v", "0": "\0", "\\": "\\", '"': '"', "'": "'",
}


def decode_gd_literal(raw: str) -> str:
    """Decode a GDScript string literal (including its quotes) to its value."""
    body = raw[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            if n == "u" and i + 5 < len(body):
                out.append(chr(int(body[i + 2:i + 6], 16)))
                i += 6
                continue
            if n == "U" and i + 9 < len(body):
                out.append(chr(int(body[i + 2:i + 10], 16)))
                i += 10
                continue
            if n == "x" and i + 3 < len(body):
                out.append(chr(int(body[i + 2:i + 4], 16)))
                i += 4
                continue
            out.append(GD_ESCAPES.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_comment(line: str) -> str:
    """Remove a trailing # comment, respecting string literals."""
    out = []
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "#":
            break
        out.append(c)
        i += 1
    return "".join(out)


def logical_lines(text: str):
    """Yield (start_line, end_line, joined_statement) joining paren continuations.

    Tracks paren/bracket/brace depth (outside string literals) plus trailing
    backslash continuations. Statements are joined with a space.
    """
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        start = i
        buf = []
        depth = 0
        while i < n:
            stripped = strip_comment(lines[i])
            buf.append(stripped)
            for ch in stripped:
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    depth = max(0, depth - 1)
            i += 1
            cont = stripped.rstrip().endswith("\\")
            if depth == 0 and not cont:
                break
        yield start + 1, i, " ".join(b.strip() for b in buf if b.strip())


def depth_of(expr: str) -> int:
    d = 0
    for ch in expr:
        if ch in "([{":
            d += 1
        elif ch in ")]}":
            d -= 1
    return d


def split_top(expr: str, seps: str):
    """Split an expression on separator chars at depth 0 (quote-aware)."""
    parts = []
    cur = []
    quote = None
    d = 0
    i = 0
    while i < len(expr):
        c = expr[i]
        if quote:
            cur.append(c)
            if c == "\\" and i + 1 < len(expr):
                cur.append(expr[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            cur.append(c)
            i += 1
            continue
        if c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        if d == 0 and c in seps:
            parts.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def _rhs_eq(expr: str) -> int:
    """Index of the '=' that starts the right-hand side — the first one outside
    any string literal, skipping escaped quotes. -1 when there is none."""
    quote = None
    i = 0
    while i < len(expr):
        c = expr[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "=":
            return i
        i += 1
    return -1


def looks_display(key: str) -> bool:
    """Heuristic: does this literal read like user-facing text?"""
    if not key or not key.strip():
        return False
    if "_" in key and " " not in key:
        return False  # snake_case identifier
    has_word = bool(re.search(r"[A-Za-z]{3}", key))
    if not has_word:
        return False
    return True


def classify(expr: str):
    """Classify the assigned expression; return (kind, literals)."""
    literals = [decode_gd_literal(m.group(0)) for m in STRING_RE.finditer(expr)]
    if not literals:
        return "dynamic", []
    # ternary: both branches may hold literals; each is a complete display string
    if re.search(r"\bif\s+.+\belse\b", expr):
        return "ternary", literals
    if FORMAT_HINT_RE.search(expr):
        return "format", literals
    parts = split_top(expr, "+")
    if len(parts) > 1:
        # pure literal concat? (all top-level parts are string literals)
        if all(p.strip().startswith(("\"", "'")) for p in parts if p.strip()):
            joined = "".join(decode_gd_literal(p.strip()) for p in parts if p.strip())
            return "concat_pure", [joined]
        return "concat", literals
    if re.search(r"\bstr\s*\(", expr):
        return "dynamic", literals
    if len(literals) == 1:
        residue = STRING_RE.sub("", expr)
        residue = re.sub(r"\s", "", residue)
        if residue in ("", "="):
            return "static", literals
        return "expression", literals
    return "expression", literals


def main():
    records = []          # every key candidate
    edits = []            # sites needing tr()
    upper_pairs = set()   # (key) that also need an UPPERCASE variant

    def add_key(key, path, line, kind, raw):
        if key is None or key == "":
            return
        p = Path(path)
        rel = str(p.relative_to(ROOT)) if p.is_absolute() else str(p).replace("\\", "/")
        records.append({
            "key": key, "file": rel, "line": line,
            "kind": kind, "raw": raw[:220],
        })

    # ---------------- GDScript ----------------
    gd_files = []
    for d in GD_DIRS:
        gd_files += sorted((ROOT / d).rglob("*.gd"))
    gd_files = [f for f in gd_files if "addons" not in f.parts and "tests" not in f.parts]

    for path in gd_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        lines_raw = text.split("\n")
        styled_vars = {}  # var name -> line of style_button call
        # first pass: find style_button/style_button_subtle targets
        for ln, l in enumerate(lines_raw, 1):
            m = STYLE_UPPER_RE.search(l)
            if m:
                tail = l[m.end():]
                vm = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", tail)
                if vm:
                    styled_vars[vm.group(1)] = ln

        for start, end, stmt in logical_lines(text):
            m = SINK_RE.search(stmt)
            if not m:
                # tag chips with a literal label
                tm = TAG_CHIP_RE.search(stmt)
                if tm:
                    tail = stmt[tm.end():]
                    lm = re.match(r'\s*"((?:\\.|[^"\\])*)"', tail)
                    if lm:
                        val = decode_gd_literal('"' + lm.group(1) + '"')
                        add_key(val, path, start, "tagchip", stmt)
                        upper_pairs.add(val)
                continue
            # target var for uppercase matching
            head = stmt[: m.start()]
            vm = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(?:text|tooltip_text|"
                            r"placeholder_text|title|dialog_text|subtitle|add_item|"
                            r"add_icon_item|add_check_item|add_radio_check_item|"
                            r"add_separator|set_item_text|add_tab|set_tab_title)", head)
            var = vm[-1] if vm else None
            expr = stmt[m.end():]
            # expression begins after '=' for property sinks. The '=' must be found
            # OUTSIDE string literals — a display string like "Off = unlimited."
            # otherwise truncates the expression mid-literal and drops it entirely.
            if stmt[m.start():].split("(")[0].strip().endswith("=") or ".text" in stmt[m.start():m.start()+6]:
                eq = _rhs_eq(expr)
                if eq != -1 and ".add" not in m.group(0) and ".set_" not in m.group(0):
                    expr = expr[eq + 1:]
            kind, lits = classify(expr)

            is_wraptip = "wrap_tip" in stmt
            for lit in lits:
                k = "static" if is_wraptip else kind
                add_key(lit, path, start, k, stmt)
            if kind == "format" and any(looks_display(l) for l in lits):
                edits.append({
                    "file": str(Path(path).relative_to(ROOT)), "line": start,
                    "end_line": end, "kind": kind, "stmt": stmt[:400],
                })
            elif kind == "concat" and any(looks_display(l) for l in lits):
                edits.append({
                    "file": str(Path(path).relative_to(ROOT)), "line": start,
                    "end_line": end, "kind": kind, "stmt": stmt[:400],
                })
            # uppercase variants for buttons that are later styled
            if var and var in styled_vars and abs(styled_vars[var] - start) <= 60:
                for lit in lits:
                    u = lit.upper()
                    if u != lit:
                        upper_pairs.add(lit)

    # ---------------- C# ----------------
    cs_files = []
    for d in CS_DIRS:
        cs_files += sorted((ROOT / d).rglob("*.cs"))
    for path in cs_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for start, end, stmt in logical_lines(text):
            if CS_SINK_RE.search(stmt):
                for lit in [decode_gd_literal(m.group(0)) for m in STRING_RE.finditer(stmt)]:
                    add_key(lit, path, start, "cs", stmt)

    # ---------------- display-helper parameters (1 hop) ----------------
    # Helper functions whose string PARAMETERS are assigned straight to a text
    # sink (build_centered_modal(title...), show_name_or_discard(msg...),
    # _flash_music_error(msg...)) receive literal args at call sites that never
    # appear on a sink line. Find the display params, then harvest literal args
    # from every call site repo-wide.
    FUNC_RE = re.compile(r"^func\s+(\w+)\s*\(([^)]*)\)")
    display_helpers = {}  # func name -> set of 0-based param indexes
    file_funcs = {}       # path -> [(name, start_line, end_line, params)]
    for path in gd_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.split("\n")
        funcs = []
        for idx, l in enumerate(lines):
            m = FUNC_RE.match(l)
            if m:
                params = [p.strip().split(":")[0].strip() for p in m.group(2).split(",") if p.strip()]
                funcs.append((m.group(1), idx, params))
        for fi, (name, start, params) in enumerate(funcs):
            end = funcs[fi + 1][1] if fi + 1 < len(funcs) else len(lines)
            body = lines[start:end]
            for pi, param in enumerate(params):
                if not param:
                    continue
                pat = re.compile(
                    r"\.(?:text|tooltip_text|placeholder_text|dialog_text|title|ok_button_text|cancel_button_text)\s*=\s*"
                    + re.escape(param) + r"\b"
                    + r"|\.(?:text|tooltip_text|dialog_text|title)\s*=\s*" + re.escape(param) + r"\.to_upper\(\)")
                if any(pat.search(b) for b in body):
                    display_helpers.setdefault(name, set()).add(pi)

    if display_helpers:
        all_gd = []
        for d in GD_DIRS:
            all_gd += sorted((ROOT / d).rglob("*.gd"))
        call_res = {n: re.compile(r"\b" + re.escape(n) + r"\s*\(") for n in display_helpers}
        for path in all_gd:
            if "addons" in path.parts or "tests" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for start, end, stmt in logical_lines(text):
                for name, positions in display_helpers.items():
                    cm = call_res[name].search(stmt)
                    if not cm:
                        continue
                    tail = stmt[cm.end():]
                    args = split_top(tail, ",")
                    for pos in positions:
                        if pos < len(args):
                            lm = re.match(r'\s*"((?:\\.|[^"\\])*)"', args[pos])
                            if lm:
                                val = decode_gd_literal('"' + lm.group(1) + '"')
                                add_key(val, path, start, "helper", stmt[:200])

    # ---------------- button-spec dicts ----------------
    # Modal/toast builders take specs like [{"text": "OK", ...}] and assign
    # spec["text"] to a Button at runtime — the literal here IS the lookup key.
    for path in gd_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for i, l in enumerate(text.split("\n"), 1):
            for m in re.finditer(r'"text"\s*:\s*"((?:\\.|[^"\\])*)"', l):
                val = decode_gd_literal('"' + m.group(1) + '"')
                if looks_display(val) or val.isupper():
                    add_key(val, path, i, "btnspec", l.strip()[:200])

    # ---------------- scene (.tscn) properties ----------------
    # Nodes loaded from scenes assign their text at load time; Godot's automatic
    # translation looks those strings up exactly like code-assigned ones, so the
    # scene literals become CSV keys with no scene edits.
    SCENE_PROP_RE = re.compile(
        r'^(text|placeholder_text|dialog_text|title|tooltip_text)\s*=\s*"((?:\\.|[^"\\])*)"'
    )
    for path in sorted((ROOT / "scenes").rglob("*.tscn")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for ln, l in enumerate(text.split("\n"), 1):
            m = SCENE_PROP_RE.match(l.strip())
            if m:
                val = decode_gd_literal('"' + m.group(2) + '"')
                add_key(val, path, ln, "scene", l.strip())

    # ---------------- data files & known constants ----------------
    # shop items + tags
    import json as _json
    shop = _json.loads((ROOT / "data" / "shop_items.json").read_text(encoding="utf-8"))
    for it in shop:
        add_key(it.get("name", ""), "data/shop_items.json", 0, "data", "shop name")
        add_key(it.get("description", ""), "data/shop_items.json", 0, "data", "shop desc")
    tags = _json.loads((ROOT / "data" / "tags.json").read_text(encoding="utf-8"))
    for t in tags:
        add_key(t.get("label", ""), "data/tags.json", 0, "data", "tag label")
        upper_pairs.add(t.get("label", ""))

    # JourneyData catalogs: pull display-ish fields from array-of-dict constants
    jd_path = ROOT / "scripts" / "journey_builder" / "JourneyData.gd"
    jd = jd_path.read_text(encoding="utf-8", errors="replace")
    # strip comments (replaced with spaces to preserve offsets) so quote chars in
    # comments can't confuse the bracket scanner
    jd_scan = []
    for ln in jd.split("\n"):
        jd_scan.append(strip_comment(ln))
    jd_clean = "\n".join(jd_scan)
    for cm in re.finditer(r"const\s+(\w+)\s*:\s*(Array|Dictionary)\s*=\s*[\[{]", jd_clean):
        cname = cm.group(1)
        if cname not in ("CURSE_CATALOG", "SENSORY_CATALOG", "BLESSING_CATALOG", "AXIS_EFFECT_LABELS"):
            continue
        open_ch = "[" if cm.group(2) == "Array" else "{"
        close_ch = "]" if cm.group(2) == "Array" else "}"
        idx = cm.end() - 1
        d = 0
        j = idx
        in_str = None
        while j < len(jd_clean):
            c = jd_clean[j]
            if in_str:
                if c == "\\":
                    j += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c in "\"'":
                in_str = c
            elif c == open_ch:
                d += 1
            elif c == close_ch:
                d -= 1
                if d == 0:
                    break
            j += 1
        body = jd_clean[idx:j + 1]
        if d != 0:
            print(f"WARN: unbalanced bracket scanning {cname}", file=sys.stderr)
            continue
        for fm in re.finditer(r'"(name|desc|description|label|title|hint|substitute)"\s*:\s*"((?:\\.|[^"\\])*)"', body):
            add_key(decode_gd_literal('"' + fm.group(2) + '"'),
                    "scripts/journey_builder/JourneyData.gd",
                    jd_clean[: cm.start()].count("\n") + 1, "catalog:" + cname, fm.group(0))
        if cname == "AXIS_EFFECT_LABELS":
            # Dictionary values are display labels
            for vm in re.finditer(r":\s*\"((?:\\.|[^\"\\])*)\"", body):
                add_key(decode_gd_literal('"' + vm.group(1) + '"'),
                        "scripts/journey_builder/JourneyData.gd",
                        jd_clean[: cm.start()].count("\n") + 1, "catalog:" + cname, vm.group(0))

    # known constant lists that reach the UI
    const_sources = [
        ("Globals/SettingsService.gd", r"const\s+AUTO_TWIST_STEPS\s*:\s*Array\s*=\s*\[([^\]]*)\]"),
        ("Globals/UITheme.gd", r"const\s+COLOUR_MODE_NAMES\s*:\s*Dictionary\s*=\s*\{(.*?)\}"),
    ]
    for rel, pat in const_sources:
        p = ROOT / rel
        if not p.exists():
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(pat, t, re.S):
            for lit in [decode_gd_literal(x.group(0)) for x in STRING_RE.finditer(m.group(1))]:
                add_key(lit, rel, t[: m.start()].count("\n") + 1, "const", m.group(0)[:120])

    # ---------------- write outputs ----------------
    seen = {}
    for r in records:
        # keep only display-like strings for expression/ternary/dynamic kinds;
        # static/format/concat/data kinds are always real UI strings
        if r["kind"] in ("expression", "dynamic", "ternary") and not looks_display(r["key"]):
            continue
        seen.setdefault(r["key"], []).append(r)
    keys = sorted(seen.keys())
    (OUT / "extracted_strings.json").write_text(
        json.dumps([{"key": k, "sites": seen[k]} for k in keys], ensure_ascii=False, indent=1),
        encoding="utf-8")
    (OUT / "needs_code_edit.json").write_text(
        json.dumps(edits, ensure_ascii=False, indent=1), encoding="utf-8")
    with open(OUT / "stats.txt", "w", encoding="utf-8") as f:
        f.write(f"unique keys: {len(keys)}\n")
        f.write(f"code-edit sites: {len(edits)}\n")
        by_kind = {}
        for k in keys:
            for s in seen[k]:
                by_kind[s["kind"]] = by_kind.get(s["kind"], 0) + 1
        for kind, c in sorted(by_kind.items()):
            f.write(f"  {kind}: {c}\n")
        f.write(f"uppercase variants needed: {len(upper_pairs)}\n")
    seen_upper = set()
    for k in keys:
        if len(k) <= 26 and re.search(r"[A-Za-z]", k) and not k.endswith((".", "?", "!", "…", ":")):
            seen_upper.add(k)
    for r in records:
        if len(r["key"]) <= 26 and re.search(r"[A-Za-z]", r["key"]):
            seen_upper.add(r["key"])
    (OUT / "uppercase_keys.json").write_text(
        json.dumps(sorted(seen_upper), ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"unique keys: {len(keys)}")
    print(f"code-edit sites: {len(edits)}")
    for kind in sorted({s['kind'] for k in keys for s in seen[k]}):
        print(f"  {kind}: {sum(1 for k in keys for s in seen[k] if s['kind']==kind)}")


if __name__ == "__main__":
    main()
