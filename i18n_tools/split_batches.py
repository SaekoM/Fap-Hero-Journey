#!/usr/bin/env python3
"""Split extracted_strings.json into translation batches by module.

Batches map to the parallel translation children. Keys whose only sites are
non-translatable (identifiers, pure placeholders, bare symbols) are dropped.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "i18n_work" / "batches"
OUT.mkdir(parents=True, exist_ok=True)

BATCHES = {
    "builder": [
        "journey_builder", "graph_view", "journey_package",
    ],
    "player": [
        "game_loop", "end_screen", "shop_screen", "inventory",
        "storyboard_screen", "fork_screen", "boss", "device", "override",
        "media", "ui",
    ],
    "shell": [
        "journey_select", "main", "options", "globals",
    ],
    "data": [
        "data", "catalog", "const", "tagchip",
    ],
}

SKIP_RE = re.compile(r"^(?:[\s%p dfsdv.,:;~\-_—♦↳✎▶❚⏭◇◆▰▱✓＋…×*#/()&|<>⚠⌨▶■◀▲▼↑↓✕✚☰⇄]+)$")


def batch_of(sites):
    for site in sites:
        f = site["file"].replace("\\", "/")
        parts = f.split("/")
        # scripts/<module>/File.gd | scenes/<module>/File.tscn | Globals/File | data/...
        if parts[0] in ("scripts", "scenes"):
            module = parts[1]
        elif parts[0] == "Globals":
            module = "globals"
        else:
            module = parts[0]
        kind = site["kind"]
        if kind.startswith("catalog:") or kind in ("const", "data", "tagchip"):
            return "data"
        for name, mods in BATCHES.items():
            if name != "data" and module in mods:
                return name
        return "player"
    return "player"


def translatable(key: str) -> bool:
    if not key or not key.strip():
        return False
    if not re.search(r"[A-Za-z]{3}", key):
        return False  # no real word -> symbols/numbers/units
    if SKIP_RE.match(key):
        return False
    # snake_case identifiers
    if "_" in key and " " not in key:
        return False
    return True


def main():
    data = json.loads((ROOT / "i18n_work" / "extracted_strings.json").read_text(encoding="utf-8"))
    per_batch = {name: {} for name in BATCHES}
    skipped = []
    for entry in data:
        key = entry["key"]
        if not translatable(key):
            skipped.append(key)
            continue
        b = batch_of(entry["sites"])
        per_batch[b].setdefault(key, entry["sites"][0]["kind"])
    for name, keys in per_batch.items():
        payload = [{"key": k, "kind": kind} for k, kind in sorted(keys.items())]
        (OUT / f"{name}.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"{name}: {len(payload)} keys")
    print(f"skipped (non-translatable): {len(skipped)}")


if __name__ == "__main__":
    main()
