#!/usr/bin/env python3
"""Compute untranslated keys per batch and split into work chunks (~200 each)."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BATCH_DIR = ROOT / "i18n_work" / "batches"
FRAG_DIR = ROOT / "i18n_work" / "fragments"
WORK_DIR = ROOT / "i18n_work" / "work"
WORK_DIR.mkdir(parents=True, exist_ok=True)
CHUNK_MAX = 210


def main():
    translated = set()
    for frag in FRAG_DIR.glob("*.json"):
        translated |= set(json.loads(frag.read_text(encoding="utf-8")).keys())

    for batch_file in sorted(BATCH_DIR.glob("*.json")):
        name = batch_file.stem
        entries = json.loads(batch_file.read_text(encoding="utf-8"))
        missing = [e for e in entries if e["key"] not in translated]
        print(f"{name}: batch={len(entries)} missing={len(missing)}")
        if not missing:
            continue
        n = max(1, -(-len(missing) // CHUNK_MAX))
        per = -(-len(missing) // n)
        for i in range(n):
            chunk = missing[i * per : (i + 1) * per]  # contiguous slices keep like terms together
            out = WORK_DIR / f"{name}_{chr(97 + i)}.json" if n > 1 else WORK_DIR / f"{name}.json"
            out.write_text(json.dumps(chunk, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"  wrote {out.name}: {len(chunk)} keys")


if __name__ == "__main__":
    main()
