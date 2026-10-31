#!/usr/bin/env python3
"""Extract the data-batch fragment JSON from the child's answer file."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ans = next((ROOT / ".zwork" / "runs" / "491477f1").glob("3-*.md"))
t = ans.read_text(encoding="utf-8")
start = t.find("```json")
end = t.rfind("```")
if start == -1:
    start = t.find("{")
    end = t.rfind("}") + 1
    body = t[start:end]
else:
    body = t[start + 7 : end]
data = json.loads(body)
print("keys:", len(data))
out = ROOT / "i18n_work" / "fragments" / "data.json"
out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
print("saved", out)
