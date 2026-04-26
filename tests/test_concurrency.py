"""
TC-01: Parallel idempotency dispatch — exactly one LAUNCH winner
TC-02: Parallel wf_json_set / interleaved append+set — no data corruption

These tests spawn real subprocesses to exercise fcntl.LOCK_EX | LOCK_NB
under genuine OS-level contention.  Threads cannot replicate this because
they share the same file-descriptor table.
"""
import json
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import pytest

from helpers.runners import run_idem_check, run_state_rw


# ---------------------------------------------------------------------------
# TC-01: 5 parallel headless dispatches → exactly one LAUNCH
# ---------------------------------------------------------------------------


class TestIdempotencyConcurrency:
    """TC-01 — parallel dispatch races for the same key."""

    KEY = "step:1:role:pm:mode:headless"
    N_WORKERS = 5

    def _launch_parallel(self, idem_file: Path, n: int) -> list[str]:
        """Spawn n subprocesses simultaneously, collect their stdout decisions."""
        results: list[str] = [""] * n

        def run(idx: int) -> tuple[int, str]:
            proc = run_idem_check(
                idem_file,
                self.KEY,
                worker_id=f"worker-{idx}",
            )
            assert proc.returncode == 0, (
                f"worker-{idx} exited {proc.returncode}: {proc.stderr}"
            )
            return idx, proc.stdout.strip()

        with ThreadPoolExecutor(max_workers=n) as pool:
            futs = [pool.submit(run, i) for i in range(n)]
            for fut in as_completed(futs):
                idx, decision = fut.result()
                results[idx] = decision

        return results

    def test_exactly_one_launch(self, idem_file: Path) -> None:
        """Under 5-way contention only one worker should win LAUNCH."""
        decisions = self._launch_parallel(idem_file, self.N_WORKERS)

        launches = [d for d in decisions if d.startswith("LAUNCH")]
        skips = [d for d in decisions if d.startswith("SKIP")]

        assert len(launches) == 1, (
            f"Expected exactly 1 LAUNCH, got {len(launches)}.\nDecisions: {decisions}"
        )
        assert len(skips) == self.N_WORKERS - 1, (
            f"Expected {self.N_WORKERS - 1} SKIPs, got {len(skips)}.\nDecisions: {decisions}"
        )

    def test_idempotency_file_written_correctly(self, idem_file: Path) -> None:
        """Winner must write status='launching' atomically before releasing lock."""
        self._launch_parallel(idem_file, self.N_WORKERS)

        data = json.loads(idem_file.read_text())
        assert self.KEY in data, "idempotency.json missing claimed key"
        entry = data[self.KEY]
        assert entry["status"] == "launching", (
            f"Expected status='launching', got: {entry['status']}"
        )
        assert "launching_at" in entry, "launching_at timestamp missing"
        assert "_claimed_by" in entry, "_claimed_by field missing (claim not written)"

    def test_idempotency_file_remains_valid_json(self, idem_file: Path) -> None:
        """File must not be corrupted by concurrent writes."""
        self._launch_parallel(idem_file, self.N_WORKERS)
        raw = idem_file.read_text()
        parsed = json.loads(raw)  # raises if invalid
        assert isinstance(parsed, dict)

    def test_second_round_all_skip(self, idem_file: Path) -> None:
        """After one LAUNCH sets status='launching', all subsequent calls must SKIP."""
        # Seed: first round finds a winner
        self._launch_parallel(idem_file, self.N_WORKERS)

        # Second round: status is 'launching' (< 60s), all must SKIP
        decisions2 = self._launch_parallel(idem_file, self.N_WORKERS)
        launches2 = [d for d in decisions2 if d.startswith("LAUNCH")]
        assert len(launches2) == 0, (
            f"Expected no LAUNCH in round 2 (launching state fresh), got: {launches2}"
        )

    def test_force_run_overrides_skip(self, idem_file: Path) -> None:
        """--force-run must always yield LAUNCH regardless of existing status."""
        # Seed a completed entry
        idem_file.write_text(
            json.dumps({self.KEY: {"status": "completed", "retry_policy": {"attempt_count": 0}}}),
            encoding="utf-8",
        )
        proc = run_idem_check(idem_file, self.KEY, force_run=True)
        assert proc.returncode == 0
        assert proc.stdout.strip().startswith("LAUNCH|force-run"), proc.stdout

    def test_retry_budget_exhausted(self, idem_file: Path) -> None:
        """When attempt_count >= max_retries, expect SKIP not LAUNCH."""
        idem_file.write_text(
            json.dumps({self.KEY: {"status": "failed", "retry_policy": {"attempt_count": 3}}}),
            encoding="utf-8",
        )
        proc = run_idem_check(idem_file, self.KEY, max_retries=3)
        assert proc.returncode == 0
        assert proc.stdout.strip().startswith("SKIP|retry budget exhausted"), proc.stdout

    def test_stale_launching_state_triggers_relaunch(self, idem_file: Path) -> None:
        """A 'launching' entry older than 60s should be treated as stale → LAUNCH."""
        from datetime import datetime, timedelta

        old_ts = (datetime.now() - timedelta(seconds=120)).strftime("%Y-%m-%d %H:%M:%S")
        idem_file.write_text(
            json.dumps({self.KEY: {"status": "launching", "launching_at": old_ts}}),
            encoding="utf-8",
        )
        proc = run_idem_check(idem_file, self.KEY)
        assert proc.returncode == 0
        decision = proc.stdout.strip()
        assert decision.startswith("LAUNCH|stale launching"), (
            f"Expected stale-launch recovery, got: {decision}"
        )


# ---------------------------------------------------------------------------
# TC-02: 10 parallel wf_json_set — no data corruption
# ---------------------------------------------------------------------------


class TestStateJsonConcurrency:
    """TC-02 — parallel JSON state mutations."""

    N_WORKERS = 10

    def test_parallel_set_no_corruption(self, state_file: Path) -> None:
        """10 concurrent set operations must leave the file as valid JSON
        with all keys present."""
        pairs = [(f"key_{i}", f"value_{i}") for i in range(self.N_WORKERS)]

        def run(idx: int) -> str:
            k, v = pairs[idx]
            proc = run_state_rw(state_file, k, v, op="set")
            assert proc.returncode == 0, f"worker-{idx} failed: {proc.stderr}"
            return proc.stdout.strip()

        with ThreadPoolExecutor(max_workers=self.N_WORKERS) as pool:
            list(pool.map(run, range(self.N_WORKERS)))

        data = json.loads(state_file.read_text())
        for k, v in pairs:
            assert k in data, f"key '{k}' missing after concurrent set"
            assert data[k] == v, f"key '{k}' has wrong value: {data[k]!r}"

    def test_parallel_append_no_duplication_or_loss(self, state_file: Path) -> None:
        """10 concurrent append operations must accumulate exactly N items."""
        LIST_KEY = "events"

        def run(idx: int) -> str:
            proc = run_state_rw(state_file, LIST_KEY, f"event-{idx}", op="append")
            assert proc.returncode == 0, f"worker-{idx} failed: {proc.stderr}"
            return proc.stdout.strip()

        with ThreadPoolExecutor(max_workers=self.N_WORKERS) as pool:
            list(pool.map(run, range(self.N_WORKERS)))

        data = json.loads(state_file.read_text())
        assert LIST_KEY in data
        items = data[LIST_KEY]
        assert isinstance(items, list), f"Expected list, got {type(items)}"
        assert len(items) == self.N_WORKERS, (
            f"Expected {self.N_WORKERS} items, got {len(items)}.\nItems: {items}"
        )
        # All unique values present
        assert set(items) == {f"event-{i}" for i in range(self.N_WORKERS)}, (
            f"Missing or duplicate items: {items}"
        )

    def test_interleaved_append_and_set(self, state_file: Path) -> None:
        """Interleaved set + append on different keys must not corrupt either."""
        LIST_KEY = "log"
        SCALAR_KEY = "counter"
        N = 8

        def run_append(idx: int) -> None:
            proc = run_state_rw(state_file, LIST_KEY, f"log-{idx}", op="append")
            assert proc.returncode == 0, proc.stderr

        def run_set(idx: int) -> None:
            proc = run_state_rw(state_file, SCALAR_KEY, idx, op="set")
            assert proc.returncode == 0, proc.stderr

        tasks = []
        with ThreadPoolExecutor(max_workers=N * 2) as pool:
            for i in range(N):
                tasks.append(pool.submit(run_append, i))
                tasks.append(pool.submit(run_set, i))
            for t in tasks:
                t.result()  # propagate exceptions

        data = json.loads(state_file.read_text())
        # List must be valid and have exactly N entries
        assert isinstance(data.get(LIST_KEY), list), "log key missing or not a list"
        assert len(data[LIST_KEY]) == N, (
            f"Expected {N} log items, got {len(data[LIST_KEY])}"
        )
        # Scalar must be one of the values written
        assert data.get(SCALAR_KEY) in range(N), (
            f"counter has unexpected value: {data.get(SCALAR_KEY)}"
        )

    def test_file_remains_valid_json_under_load(self, state_file: Path) -> None:
        """File must never be left in a corrupt state after concurrent writes."""
        def run(idx: int) -> None:
            run_state_rw(state_file, f"k{idx}", idx, op="set")

        with ThreadPoolExecutor(max_workers=20) as pool:
            list(pool.map(run, range(20)))

        raw = state_file.read_text()
        parsed = json.loads(raw)  # raises ValueError if corrupt
        assert isinstance(parsed, dict)
        assert len(parsed) == 20
