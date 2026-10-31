#!/usr/bin/env python3
"""Scan for text-bearing sinks the main extractor may have missed."""
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
pat = re.compile(
    r"(ok_button\(\)\.text|cancel_button\(\)\.text|\.window_title|\.add_tab\("
    r"|\.set_tab_title\(|\.placeholder_text\s*=[^=\n]*\"[A-Za-z]"
    r"|\.dialog_text\s*=\s*\"[A-Za-z])"
)
count = 0
for base in ("scripts", "Globals"):
    for root, dirs, fs in os.walk(ROOT / base):
        dirs[:] = [d for d in dirs if d not in ("addons", "tests")]
        for f in fs:
            if not f.endswith((".gd", ".cs")):
                continue
            p = Path(root) / f
            for i, l in enumerate(p.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
                if pat.search(l):
                    print(f"{p.relative_to(ROOT)}:{i}", l.strip()[:110])
                    count += 1
print("total", count)
