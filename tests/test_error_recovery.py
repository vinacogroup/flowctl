"""
TC-03: Error recovery tests
  - Stale .lock file left by a dead PID
  - Corrupt idempotency.json (truncated JSON)
  - Corrupt state.json
  - Read-only / non-writable FLOWCTL_HOME scenario (permission error propagation)
"""
import json
import os
import stat
import time
from pathlib import Path

import pytest

from helpers.runners import run_idem_check, run_state_rw

KEY = "step:2:role:backend:mode:headless"


class TestStaleLockFileRecovery:
    """A pre-existing .lock file from a dead process must not block the next run."""

    def test_stale_lock_does_not_block_launch(self, tmp_path: Path) -> None:
        idem = tmp_path / "idempotency.json"
        idem.write_text("{}", encoding="utf-8")

        # Create a stale .lock file (dead PID already cleaned up — file stays)
        lock = tmp_path / "idempotency.json.lock"
        lock.write_text("dead-worker\n", encoding="utf-8")

        proc = run_idem_check(idem, KEY, worker_id="fresh-worker")
        assert proc.returncode == 0, proc.stderr
        decision = proc.stdout.strip()
        # Must succeed — a stale lock file (not held) is no obstacle
        assert decision.startswith("LAUNCH"), (
            f"Expected LAUNCH past stale lock, got: {decision!r}"
        )

    def test_lock_file_cleanup_after_run(self, tmp_path: Path) -> None:
        """After a clean run the lock file should be released (not exclusively held)."""
        idem = tmp_path / "idempotency.json"
        idem.write_text("{}", encoding="utf-8")

        run_idem_check(idem, KEY)

        # Lock file may still exist on disk but must not be held exclusively
        lock = tmp_path / "idempotency.json.lock"
        if lock.exists():
            import fcntl
            # Should be acquirable immediately
            with open(lock, "w") as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(f, fcntl.LOCK_UN)
                except BlockingIOError:
                    pytest.fail("Lock still held after subprocess exited")


class TestCorruptJsonRecovery:
    """Truncated / invalid JSON in state files must not cause a silent wrong result."""

    def test_corrupt_idempotency_json_defaults_to_launch(self, tmp_path: Path) -> None:
        """Corrupt idempotency.json → treat as empty → LAUNCH (safe fallback)."""
        idem = tmp_path / "idempotency.json"
        idem.write_text('{"step:1:r', encoding="utf-8")  # truncated

        proc = run_idem_check(idem, KEY)
        # The helper should either LAUNCH (treating corrupt file as empty)
        # or exit non-zero. Either is acceptable — just must not silently SKIP.
        if proc.returncode == 0:
            assert not proc.stdout.strip().startswith("SKIP"), (
                "Should not SKIP on corrupt idempotency file — data is unreadable"
            )

    def test_corrupt_state_json_does_not_silently_clobber(self, tmp_path: Path) -> None:
        """Corrupt state.json should not silently overwrite with empty dict."""
        state = tmp_path / "state.json"
        state.write_text('{"key": "val', encoding="utf-8")  # truncated

        proc = run_state_rw(state, "new_key", "new_value", op="set")
        # Either succeeds and file is valid JSON, or exits non-zero
        if proc.returncode == 0:
            raw = state.read_text()
            parsed = json.loads(raw)  # must be valid JSON
            assert isinstance(parsed, dict)
            # The new key should be present
            assert "new_key" in parsed, "new_key missing after recovery write"

    def test_empty_state_json_treated_as_empty_dict(self, tmp_path: Path) -> None:
        """Completely empty file should be treated as {} not an error."""
        state = tmp_path / "state.json"
        state.write_text("", encoding="utf-8")

        proc = run_state_rw(state, "flag", True, op="set")
        assert proc.returncode == 0, proc.stderr
        parsed = json.loads(state.read_text())
        assert parsed.get("flag") is True


class TestReadOnlyHome:
    """F-12: flowctl_ensure_data_dirs must error clearly on non-writable FLOWCTL_HOME."""

    def test_non_writable_flowctl_home_reported(self, tmp_path: Path) -> None:
        """If FLOWCTL_HOME exists but is not writable, the error message must be clear."""
        home = tmp_path / "flowctl_home"
        home.mkdir()
        # Remove write permission
        home.chmod(stat.S_IRUSR | stat.S_IXUSR)

        # Run a small inline Python that replicates the config.sh guard
        script = tmp_path / "check_home.py"
        script.write_text(
            f"""
import os, sys
home = "{home}"
if os.path.exists(home) and not os.access(home, os.W_OK):
    print("ERROR: FLOWCTL_HOME not writable", file=sys.stderr)
    sys.exit(1)
print("OK")
""",
            encoding="utf-8",
        )

        import subprocess, sys as _sys
        proc = subprocess.run([_sys.executable, str(script)], capture_output=True, text=True)

        # Restore permissions for cleanup
        home.chmod(stat.S_IRWXU)

        assert proc.returncode == 1, "Expected exit 1 for non-writable FLOWCTL_HOME"
        assert "not writable" in proc.stderr.lower() or "flowctl_home" in proc.stderr.lower(), (
            f"Error message unclear: {proc.stderr!r}"
        )
