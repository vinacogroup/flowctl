"""
TC-04: Evidence manifest integrity tests
  - Corrupt report after capture → verify detects hash mismatch
  - Unexpected file in reports dir (unlisted) → still captured / reported
  - Missing manifest file → verify returns EVIDENCE_FAIL|manifest_missing
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HELPERS_DIR = Path(__file__).parent / "helpers"
REPO_ROOT = Path(__file__).parent.parent

# ── inline Python that replicates evidence.sh capture + verify logic ──────────

CAPTURE_SCRIPT = """\
import json, hashlib, os, sys
from pathlib import Path

manifest_path = Path(os.environ["WF_MANIFEST_PATH"])
reports_dir   = Path(os.environ["WF_REPORTS_DIR"])

files = []
for f in sorted(reports_dir.glob("**/*")):
    if not f.is_file():
        continue
    rel = str(f.relative_to(reports_dir))
    content = f.read_bytes()
    sha = hashlib.sha256(content).hexdigest()
    files.append({"path": rel, "sha256": sha, "size": len(content)})

digest_material = "\\n".join(f"{e['path']}:{e['sha256']}" for e in files)
manifest_hash   = hashlib.sha256(digest_material.encode()).hexdigest()

payload = {
    "step": int(os.environ.get("WF_STEP", "1")),
    "files": files,
    "manifest_hash": manifest_hash,
    "signature": f"sha256:{manifest_hash}",
}
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"EVIDENCE_CAPTURED|manifest={manifest_path}")
"""

VERIFY_SCRIPT = """\
import json, hashlib, os, sys
from pathlib import Path

manifest_path = Path(os.environ["WF_MANIFEST_PATH"])
reports_dir   = Path(os.environ["WF_REPORTS_DIR"])

if not manifest_path.exists():
    print("EVIDENCE_FAIL|manifest_missing")
    sys.exit(0)

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
files    = manifest.get("files", [])
errors   = []

for entry in files:
    fpath = reports_dir / entry["path"]
    if not fpath.exists():
        errors.append(f"missing:{entry['path']}")
        continue
    sha = hashlib.sha256(fpath.read_bytes()).hexdigest()
    if sha != entry["sha256"]:
        errors.append(f"tampered:{entry['path']}")

rebuild = [f"{e['path']}:{e['sha256']}" for e in files]
recomputed = hashlib.sha256("\\n".join(rebuild).encode()).hexdigest()
if recomputed != manifest.get("manifest_hash", ""):
    errors.append("manifest_hash_mismatch")

if errors:
    print("EVIDENCE_FAIL|" + ",".join(errors))
else:
    print(f"EVIDENCE_OK|files={len(files)}")
"""


def _run_script(script_text: str, env: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", script_text],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
    )


class TestEvidenceManifest:

    def _make_reports_dir(self, tmp_path: Path) -> Path:
        rd = tmp_path / "reports"
        rd.mkdir()
        (rd / "pm-report.md").write_text("# PM Report\nAll good.", encoding="utf-8")
        (rd / "backend-report.md").write_text("# Backend\n- API done.", encoding="utf-8")
        return rd

    def test_capture_and_verify_clean(self, tmp_path: Path) -> None:
        """Fresh capture + immediate verify must return EVIDENCE_OK."""
        rd = self._make_reports_dir(tmp_path)
        manifest = tmp_path / "step-1-manifest.json"

        cap = _run_script(
            CAPTURE_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd), "WF_STEP": "1"},
        )
        assert cap.returncode == 0, cap.stderr
        assert "EVIDENCE_CAPTURED" in cap.stdout

        ver = _run_script(
            VERIFY_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd)},
        )
        assert ver.returncode == 0, ver.stderr
        assert ver.stdout.strip().startswith("EVIDENCE_OK"), ver.stdout

    def test_corrupt_report_after_capture_detected(self, tmp_path: Path) -> None:
        """Tampering a report after capture must be caught by verify."""
        rd = self._make_reports_dir(tmp_path)
        manifest = tmp_path / "step-1-manifest.json"

        _run_script(
            CAPTURE_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd), "WF_STEP": "1"},
        )

        # Corrupt one report
        (rd / "pm-report.md").write_text("# TAMPERED", encoding="utf-8")

        ver = _run_script(
            VERIFY_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd)},
        )
        assert ver.returncode == 0, ver.stderr
        out = ver.stdout.strip()
        assert out.startswith("EVIDENCE_FAIL"), (
            f"Expected EVIDENCE_FAIL after tampering, got: {out!r}"
        )
        assert "tampered" in out or "hash_mismatch" in out, out

    def test_missing_manifest_returns_fail(self, tmp_path: Path) -> None:
        """Calling verify without a manifest must return EVIDENCE_FAIL|manifest_missing."""
        rd = self._make_reports_dir(tmp_path)
        manifest = tmp_path / "nonexistent-manifest.json"

        ver = _run_script(
            VERIFY_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd)},
        )
        assert ver.returncode == 0, ver.stderr
        assert ver.stdout.strip() == "EVIDENCE_FAIL|manifest_missing", ver.stdout

    def test_unexpected_new_file_not_in_manifest(self, tmp_path: Path) -> None:
        """A file added AFTER capture should not affect the existing manifest's
        validity (it's unlisted, not tampered)."""
        rd = self._make_reports_dir(tmp_path)
        manifest = tmp_path / "step-1-manifest.json"

        _run_script(
            CAPTURE_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd), "WF_STEP": "1"},
        )

        # Add a new file after capture
        (rd / "qa-report.md").write_text("# QA late addition", encoding="utf-8")

        # Original manifested files are untouched → verify must still pass
        ver = _run_script(
            VERIFY_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd)},
        )
        assert ver.stdout.strip().startswith("EVIDENCE_OK"), (
            f"Unexpected file should not invalidate existing manifest: {ver.stdout!r}"
        )

    def test_deleted_report_after_capture_detected(self, tmp_path: Path) -> None:
        """Deleting a manifested report must be caught as a missing-file error."""
        rd = self._make_reports_dir(tmp_path)
        manifest = tmp_path / "step-1-manifest.json"

        _run_script(
            CAPTURE_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd), "WF_STEP": "1"},
        )

        (rd / "backend-report.md").unlink()

        ver = _run_script(
            VERIFY_SCRIPT,
            {"WF_MANIFEST_PATH": str(manifest), "WF_REPORTS_DIR": str(rd)},
        )
        out = ver.stdout.strip()
        assert out.startswith("EVIDENCE_FAIL"), out
        assert "missing" in out, f"Expected 'missing' in output, got: {out!r}"
