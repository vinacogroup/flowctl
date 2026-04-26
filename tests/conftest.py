"""
Shared pytest fixtures for flowctl tests.
"""
import json
import sys
from pathlib import Path

import pytest

# Ensure helpers/ is importable from all test files
sys.path.insert(0, str(Path(__file__).parent))


@pytest.fixture()
def tmp_dir(tmp_path: Path) -> Path:
    """Return a fresh temporary directory for each test."""
    return tmp_path


@pytest.fixture()
def idem_file(tmp_path: Path) -> Path:
    """Empty idempotency.json in a fresh temp dir."""
    f = tmp_path / "idempotency.json"
    f.write_text("{}", encoding="utf-8")
    return f


@pytest.fixture()
def state_file(tmp_path: Path) -> Path:
    """Empty state JSON file in a fresh temp dir."""
    f = tmp_path / "state.json"
    f.write_text("{}", encoding="utf-8")
    return f
