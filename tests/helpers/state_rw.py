#!/usr/bin/env python3
"""
Standalone helper: runs the wf_json_set / wf_json_append locking logic
extracted from scripts/workflow/lib/state.sh.

Usage:
    WF_STATE_FILE=... WF_KEY=... WF_VALUE=... WF_OP=set|append \
    python3 tests/helpers/state_rw.py
"""
import json
import fcntl
import time
import random
import os
import sys
from pathlib import Path
from datetime import datetime

path = Path(os.environ["WF_STATE_FILE"])
key = os.environ["WF_KEY"]
value_raw = os.environ["WF_VALUE"]
op = os.environ.get("WF_OP", "set")  # "set" or "append"

try:
    value = json.loads(value_raw)
except json.JSONDecodeError:
    value = value_raw

def do_rw(path: Path, key: str, value, op: str) -> None:
    lock_path = str(path) + ".lock"
    outer_max = 8

    for outer in range(outer_max):
        with open(lock_path, "w") as f:
            for lock_attempt in range(10):
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if lock_attempt == 9:
                        raise RuntimeError("Could not acquire state lock after retries")
                    time.sleep(0.05 * (2 ** lock_attempt) + random.uniform(0, 0.01))

            try:
                raw = path.read_text(encoding="utf-8") if path.exists() else ""
                data = json.loads(raw) if raw.strip() else {}
            except json.JSONDecodeError:
                if outer < outer_max - 1:
                    fcntl.flock(f, fcntl.LOCK_UN)
                    time.sleep(0.1 * (outer + 1))
                    continue
                raise

            if op == "append":
                existing = data.get(key, [])
                if isinstance(existing, list):
                    existing.append(value)
                else:
                    existing = [existing, value]
                data[key] = existing
            else:
                data[key] = value

            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
            fcntl.flock(f, fcntl.LOCK_UN)
            break

do_rw(path, key, value, op)
print(f"OK|{op}|{key}={json.dumps(value)}")
