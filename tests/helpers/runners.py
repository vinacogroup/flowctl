"""
Subprocess runner helpers for flowctl tests.
Centralises the environment setup for helper scripts.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HELPERS_DIR = Path(__file__).parent


def run_idem_check(
    idem_path: Path,
    key: str,
    *,
    force_run: bool = False,
    max_retries: int = 3,
    worker_id: str | None = None,
) -> subprocess.CompletedProcess:
    """Run the idempotency check helper as a subprocess."""
    env = {
        **os.environ,
        "WF_IDEMPOTENCY_FILE": str(idem_path),
        "WF_IDEMPOTENCY_KEY": key,
        "WF_FORCE_RUN": "true" if force_run else "false",
        "WF_MAX_RETRIES": str(max_retries),
        "WF_WORKER_ID": worker_id or str(os.getpid()),
    }
    return subprocess.run(
        [sys.executable, str(HELPERS_DIR / "idem_check.py")],
        env=env,
        capture_output=True,
        text=True,
    )


def run_state_rw(
    state_path: Path,
    key: str,
    value,
    *,
    op: str = "set",
) -> subprocess.CompletedProcess:
    """Run the state read/write helper as a subprocess."""
    env = {
        **os.environ,
        "WF_STATE_FILE": str(state_path),
        "WF_KEY": key,
        "WF_VALUE": json.dumps(value),
        "WF_OP": op,
    }
    return subprocess.run(
        [sys.executable, str(HELPERS_DIR / "state_rw.py")],
        env=env,
        capture_output=True,
        text=True,
    )
