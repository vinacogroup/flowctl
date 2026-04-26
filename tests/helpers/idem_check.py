#!/usr/bin/env python3
"""
Standalone helper: runs the idempotency check + atomic claim logic extracted
from scripts/workflow/lib/dispatch.sh.

Invoked by concurrency tests via subprocess so we exercise the real fcntl
locking code in separate processes (threads share a file-descriptor table
and cannot test LOCK_NB contention properly).

Usage:
    WF_IDEMPOTENCY_FILE=... WF_IDEMPOTENCY_KEY=... \
    WF_FORCE_RUN=false WF_MAX_RETRIES=3 \
    python3 tests/helpers/idem_check.py
"""
import json
import os
import fcntl
import time
import random
import sys
from pathlib import Path
from datetime import datetime

path = Path(os.environ["WF_IDEMPOTENCY_FILE"])
key = os.environ["WF_IDEMPOTENCY_KEY"]
force_run = os.environ.get("WF_FORCE_RUN", "false").lower() == "true"
max_retries = int(os.environ.get("WF_MAX_RETRIES", "3"))
worker_id = os.environ.get("WF_WORKER_ID", str(os.getpid()))

lock_path = str(path) + ".lock"
deadline = time.monotonic() + 10

lock_fd = open(lock_path, "w")
try:
    while True:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() > deadline:
                print(f"LAUNCH|lock-timeout; proceeding in degraded mode", file=sys.stderr)
                break
            time.sleep(0.05 + random.uniform(0, 0.05))

    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    entry = data.get(key, {})
    status = entry.get("status", "")
    pid = entry.get("pid")
    attempt_count = int((entry.get("retry_policy") or {}).get("attempt_count", 0))
    running = False
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)
            running = True
        except OSError:
            running = False

    if force_run:
        decision = f"LAUNCH|force-run enabled|prev_status={status or 'none'}"
    elif status == "launched" and running:
        decision = f"SKIP|already launched with running pid={pid}"
    elif status == "launching":
        launched_at = entry.get("launching_at", "")
        age = 999
        if launched_at:
            try:
                age = (
                    datetime.now()
                    - datetime.strptime(launched_at, "%Y-%m-%d %H:%M:%S")
                ).total_seconds()
            except Exception:
                pass
        if age < 60:
            decision = "SKIP|another dispatch is mid-launch (launching state < 60s old)"
        else:
            decision = f"LAUNCH|stale launching state ({int(age)}s); retrying"
    elif status == "completed":
        decision = "SKIP|already completed; use --force-run to rerun"
    elif attempt_count >= max_retries:
        decision = f"SKIP|retry budget exhausted ({attempt_count}/{max_retries}); use --force-run"
    else:
        reason = "first launch" if not status else f"resume from status={status}"
        decision = f"LAUNCH|{reason}"

    if decision.startswith("LAUNCH"):
        prev = data.get(key, {})
        data[key] = {
            **prev,
            "status": "launching",
            "launching_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "_claimed_by": worker_id,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

    print(decision)
finally:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    except Exception:
        pass
    lock_fd.close()
