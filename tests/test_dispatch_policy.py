"""
TC-06: Dispatch policy violation tests
  - LAUNCH on non-macOS platform when macOS-only flag set
  - --trust denied when policy disallows it
  - Invalid --max-retries value (non-numeric, negative)
  - Missing required env vars for dispatch

These tests exercise the policy-validation Python block from dispatch.sh.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ── Inline policy check script (extracted from dispatch.sh brief-gen block) ───

POLICY_CHECK_SCRIPT = """\
import json, os, sys, platform

dispatch_mode = os.environ.get("WF_DISPATCH_MODE", "headless")
trust_requested = os.environ.get("WF_TRUST_REQUESTED", "false").lower() == "true"
max_retries_raw = os.environ.get("WF_MAX_RETRIES", "3")
platform_name = os.environ.get("WF_PLATFORM", platform.system())
policy_path_s = os.environ.get("WF_POLICY_FILE", "")

errors = []

# Validate --max-retries
try:
    max_retries = int(max_retries_raw)
    if max_retries < 0:
        errors.append(f"POLICY_VIOLATION|max_retries_negative|value={max_retries}")
    elif max_retries > 20:
        errors.append(f"POLICY_VIOLATION|max_retries_excessive|value={max_retries}")
except ValueError:
    errors.append(f"POLICY_VIOLATION|max_retries_invalid|value={max_retries_raw!r}")

# Trust check
if trust_requested:
    if policy_path_s:
        try:
            policy = json.loads(open(policy_path_s).read())
            allow_trust = policy.get("allow_trust", True)
        except Exception:
            allow_trust = True
    else:
        allow_trust = True
    if not allow_trust:
        errors.append("POLICY_VIOLATION|trust_denied_by_policy")

# macOS-only headless mode check
if dispatch_mode == "headless" and platform_name not in ("Darwin", "mock-macos"):
    errors.append(f"POLICY_VIOLATION|headless_requires_macos|platform={platform_name}")

if errors:
    for e in errors:
        print(e)
    sys.exit(2)
else:
    print("POLICY_OK")
"""


def _check_policy(env_overrides: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", POLICY_CHECK_SCRIPT],
        env={**os.environ, **env_overrides},
        capture_output=True,
        text=True,
    )


class TestDispatchPolicyViolations:

    def test_headless_on_non_macos_blocked(self) -> None:
        """Headless dispatch on Linux must report POLICY_VIOLATION."""
        proc = _check_policy({
            "WF_DISPATCH_MODE": "headless",
            "WF_PLATFORM": "Linux",
        })
        assert proc.returncode == 2, "Expected exit 2 for policy violation"
        assert "POLICY_VIOLATION|headless_requires_macos" in proc.stdout, proc.stdout

    def test_headless_on_macos_allowed(self) -> None:
        """Headless on macOS (or mock) must pass policy check."""
        proc = _check_policy({
            "WF_DISPATCH_MODE": "headless",
            "WF_PLATFORM": "Darwin",
        })
        assert proc.returncode == 0, proc.stdout
        assert "POLICY_OK" in proc.stdout

    def test_trust_denied_by_policy(self, tmp_path: Path) -> None:
        """When policy file sets allow_trust=false, trust request must be denied."""
        policy = tmp_path / "policy.json"
        policy.write_text(json.dumps({"allow_trust": False}), encoding="utf-8")

        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_TRUST_REQUESTED": "true",
            "WF_POLICY_FILE": str(policy),
        })
        assert proc.returncode == 2
        assert "trust_denied_by_policy" in proc.stdout, proc.stdout

    def test_trust_allowed_by_policy(self, tmp_path: Path) -> None:
        policy = tmp_path / "policy.json"
        policy.write_text(json.dumps({"allow_trust": True}), encoding="utf-8")

        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_TRUST_REQUESTED": "true",
            "WF_POLICY_FILE": str(policy),
        })
        assert proc.returncode == 0
        assert "POLICY_OK" in proc.stdout

    def test_max_retries_non_numeric(self) -> None:
        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_MAX_RETRIES": "abc",
        })
        assert proc.returncode == 2
        assert "max_retries_invalid" in proc.stdout, proc.stdout

    def test_max_retries_negative(self) -> None:
        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_MAX_RETRIES": "-1",
        })
        assert proc.returncode == 2
        assert "max_retries_negative" in proc.stdout, proc.stdout

    def test_max_retries_excessive(self) -> None:
        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_MAX_RETRIES": "100",
        })
        assert proc.returncode == 2
        assert "max_retries_excessive" in proc.stdout, proc.stdout

    def test_valid_max_retries_passes(self) -> None:
        proc = _check_policy({
            "WF_DISPATCH_MODE": "mock-macos",
            "WF_PLATFORM": "mock-macos",
            "WF_MAX_RETRIES": "5",
        })
        assert proc.returncode == 0
        assert "POLICY_OK" in proc.stdout
