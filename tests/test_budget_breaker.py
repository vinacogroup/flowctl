"""
TC-07: Budget / circuit breaker state machine tests
  - open → half-open probe after cooldown
  - Override while breaker is open
  - Probe success → breaker closes
  - Manual reset → breaker returns to closed
  - Half-open re-open → exponential backoff on cooldown (L-04)
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

# ── Inline Python that replicates the breaker state-machine portion of budget.sh

BREAKER_EVAL_SCRIPT = """\
import json, os, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

state_path = Path(os.environ["WF_BUDGET_STATE_FILE"])
action     = os.environ.get("WF_ACTION", "check")   # check | probe_success | reset | reopen
role       = os.environ.get("WF_ROLE", "backend")
now_s      = os.environ.get("WF_NOW", "")           # override for testing

def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

def now_iso():
    return datetime.now(timezone.utc).isoformat()

now = parse_iso(now_s) if now_s else datetime.now(timezone.utc)

state   = json.loads(state_path.read_text()) if state_path.exists() else {}
breaker = state.setdefault("breaker", {
    "state": "closed",
    "opened_at": "",
    "cooldown_seconds": 300,
})

cooldown_seconds = int(breaker.get("cooldown_seconds", 300))

if action == "check":
    bstate = breaker.get("state", "closed")

    # Transition open → half-open after cooldown
    if bstate == "open":
        opened_at_dt = parse_iso(breaker.get("opened_at", ""))
        if opened_at_dt and (now - opened_at_dt).total_seconds() >= cooldown_seconds:
            breaker["state"] = "half-open"
            bstate = "half-open"

    if bstate == "open":
        print("BLOCK|breaker=open")
    elif bstate == "half-open":
        probe_role = breaker.get("probe_role", "")
        if probe_role and probe_role != role:
            print(f"BLOCK|breaker=half-open probe_role={probe_role}")
        else:
            breaker["probe_role"] = role
            print(f"ALLOW|breaker=half-open probe_role={role}")
    else:
        print("ALLOW|breaker=closed")

elif action == "probe_success":
    # Probe completed successfully → close the breaker
    breaker["state"] = "closed"
    breaker["probe_role"] = ""
    breaker["opened_at"] = ""
    print("BREAKER_CLOSED|probe_success")

elif action == "reset":
    # Manual reset
    breaker["state"]        = "closed"
    breaker["probe_role"]   = ""
    breaker["opened_at"]    = ""
    breaker["cooldown_seconds"] = 300
    print("BREAKER_RESET")

elif action == "reopen":
    # Re-opening from half-open state → exponential backoff (L-04)
    was_half_open = (breaker.get("state") == "half-open")
    prev_cooldown = int(breaker.get("cooldown_seconds", cooldown_seconds))
    if was_half_open:
        new_cooldown = min(int(prev_cooldown * 1.5), 1800)
    else:
        new_cooldown = cooldown_seconds
    breaker["state"]        = "open"
    breaker["opened_at"]    = now.isoformat()
    breaker["cooldown_seconds"] = new_cooldown
    print(f"BREAKER_OPEN|cooldown={new_cooldown}")

state["breaker"] = breaker
state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")
"""


def _run_breaker(state_path: Path, action: str = "check", role: str = "backend",
                 now_override: str = "") -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", BREAKER_EVAL_SCRIPT],
        env={
            **os.environ,
            "WF_BUDGET_STATE_FILE": str(state_path),
            "WF_ACTION": action,
            "WF_ROLE": role,
            "WF_NOW": now_override,
        },
        capture_output=True,
        text=True,
    )


def _seed_state(state_path: Path, breaker: dict) -> None:
    state_path.write_text(json.dumps({"breaker": breaker}, indent=2), encoding="utf-8")


class TestBreakerStateMachine:

    def test_closed_breaker_allows(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "closed", "cooldown_seconds": 300})
        proc = _run_breaker(sp, "check")
        assert proc.returncode == 0
        assert "ALLOW|breaker=closed" in proc.stdout

    def test_open_breaker_blocks(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        now_s = datetime.now(timezone.utc).isoformat()
        _seed_state(sp, {"state": "open", "opened_at": now_s, "cooldown_seconds": 300})
        proc = _run_breaker(sp, "check")
        assert "BLOCK|breaker=open" in proc.stdout

    def test_open_transitions_to_half_open_after_cooldown(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        old_open = (datetime.now(timezone.utc) - timedelta(seconds=400)).isoformat()
        _seed_state(sp, {"state": "open", "opened_at": old_open, "cooldown_seconds": 300})

        proc = _run_breaker(sp, "check")
        assert proc.returncode == 0
        assert "ALLOW|breaker=half-open" in proc.stdout, proc.stdout

        state = json.loads(sp.read_text())
        assert state["breaker"]["state"] == "half-open"

    def test_half_open_blocks_non_probe_roles(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "half-open", "probe_role": "backend", "cooldown_seconds": 300})

        proc = _run_breaker(sp, "check", role="frontend")
        assert "BLOCK|breaker=half-open" in proc.stdout

    def test_probe_success_closes_breaker(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "half-open", "probe_role": "backend", "cooldown_seconds": 300})

        proc = _run_breaker(sp, "probe_success")
        assert "BREAKER_CLOSED" in proc.stdout

        state = json.loads(sp.read_text())
        assert state["breaker"]["state"] == "closed"
        assert state["breaker"].get("probe_role", "") == ""

    def test_manual_reset_closes_breaker(self, tmp_path: Path) -> None:
        sp = tmp_path / "budget.json"
        now_s = datetime.now(timezone.utc).isoformat()
        _seed_state(sp, {"state": "open", "opened_at": now_s, "cooldown_seconds": 600})

        proc = _run_breaker(sp, "reset")
        assert "BREAKER_RESET" in proc.stdout

        state = json.loads(sp.read_text())
        assert state["breaker"]["state"] == "closed"
        assert state["breaker"]["cooldown_seconds"] == 300

    def test_reopen_from_half_open_increases_cooldown_l04(self, tmp_path: Path) -> None:
        """L-04: re-opening from half-open multiplies cooldown by 1.5."""
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "half-open", "probe_role": "backend", "cooldown_seconds": 300})

        proc = _run_breaker(sp, "reopen")
        assert "BREAKER_OPEN" in proc.stdout

        state = json.loads(sp.read_text())
        new_cooldown = state["breaker"]["cooldown_seconds"]
        assert new_cooldown == 450, (  # 300 * 1.5 = 450
            f"Expected cooldown=450 after half-open re-open, got {new_cooldown}"
        )

    def test_reopen_from_closed_keeps_base_cooldown(self, tmp_path: Path) -> None:
        """Re-opening from closed state (not half-open) resets to base cooldown."""
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "closed", "cooldown_seconds": 300})

        proc = _run_breaker(sp, "reopen")
        state = json.loads(sp.read_text())
        assert state["breaker"]["cooldown_seconds"] == 300, (
            "Cooldown should stay at base when re-opening from closed (not half-open)"
        )

    def test_cooldown_capped_at_1800_l04(self, tmp_path: Path) -> None:
        """L-04: exponential backoff must be capped at 1800s."""
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "half-open", "cooldown_seconds": 1500})

        proc = _run_breaker(sp, "reopen")
        state = json.loads(sp.read_text())
        assert state["breaker"]["cooldown_seconds"] == 1800, (
            "Cooldown must be capped at 1800s"
        )

    def test_consecutive_reopens_hit_cap(self, tmp_path: Path) -> None:
        """Multiple reopens from half-open must never exceed 1800s cap."""
        sp = tmp_path / "budget.json"
        _seed_state(sp, {"state": "half-open", "cooldown_seconds": 300})

        for _ in range(10):
            # Reopen (stays half-open due to how seeding works)
            state = json.loads(sp.read_text())
            state["breaker"]["state"] = "half-open"
            sp.write_text(json.dumps(state), encoding="utf-8")
            _run_breaker(sp, "reopen")

        final = json.loads(sp.read_text())
        assert final["breaker"]["cooldown_seconds"] <= 1800
