#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import json
import sys
from pathlib import Path

package = json.loads(Path("package.json").read_text(encoding="utf-8"))
declared_files = set(package.get("files", []))

required_runtime_files = [
    "bin",
    "scripts/flowctl.sh",
    "scripts/setup.sh",
    "scripts/merge_cursor_mcp.py",
    "scripts/monitor-web.py",
    "scripts/token-audit.py",
    "scripts/hooks",
    "scripts/workflow",
    "templates",
    # Cursor agent/rule/skill dirs — must be packaged so `flowctl init` can scaffold them
    ".cursor/agents",
    ".cursor/commands",
    ".cursor/rules",
    ".cursor/skills",
    ".cursorrules",
    # Workflow dispatch/gate/policy templates
    "workflows/dispatch",
    "workflows/gates",
    "workflows/policies",
]

missing_from_package = [path for path in required_runtime_files if path not in declared_files]
missing_on_disk      = [path for path in required_runtime_files if not Path(path).exists()]

errors = []
if missing_from_package:
    errors.append("Missing from package.json files: " + ", ".join(missing_from_package))
if missing_on_disk:
    errors.append("Missing on disk: " + ", ".join(missing_on_disk))

# Verify bin/flowctl is executable
bin_flowctl = Path("bin/flowctl")
if bin_flowctl.exists() and not bin_flowctl.stat().st_mode & 0o111:
    errors.append("bin/flowctl is not executable")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)

print(f"Package files OK ({len(required_runtime_files)} paths verified)")
PY
