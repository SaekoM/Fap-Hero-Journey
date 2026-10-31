#!/usr/bin/env python3
"""Locate each runtime-audit MISS in the source tree.

Reads the audit output (lines starting with 'MISS | '), strips audit-only
decorations (⏎ line-break markers, wrapped/unwrapped duplicates), and greps
every .gd/.tscn for the text. Prints: text -> file:line hits.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    misses = []
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
        if line.startswith("MISS | "):
            t = line[len("MISS | "):].replace(" ⏎ ", " ")
            if t not in misses:
                misses.append(t)

    sources = {}
    for base in ("scripts", "Globals", "scenes"):
        for p in (ROOT / base).rglob("*"):
            if p.suffix in (".gd", ".tscn"):
                try:
                    sources[str(p.relative_to(ROOT))] = p.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    pass

    for t in misses:
        hits = []
        for rel, src in sources.items():
            if t in src:
                for i, l in enumerate(src.split("\n"), 1):
                    if t in l:
                        hits.append(f"{rel}:{i}")
        mark = "FOUND" if hits else "NONE "
        print(f"{mark} {t[:70]!r}")
        for h in hits[:3]:
            print(f"       {h}")


if __name__ == "__main__":
    main()
