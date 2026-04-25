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
]

missing_from_package = [path for path in required_runtime_files if path not in declared_files]
missing_on_disk = [path for path in required_runtime_files if not Path(path).exists()]

if missing_from_package or missing_on_disk:
    if missing_from_package:
        print("Missing from package.json files:", ", ".join(missing_from_package), file=sys.stderr)
    if missing_on_disk:
        print("Missing on disk:", ", ".join(missing_on_disk), file=sys.stderr)
    sys.exit(1)

print("Package runtime files are declared.")
PY
