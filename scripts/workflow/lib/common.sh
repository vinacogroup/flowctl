#!/usr/bin/env bash

# Shared colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

wf_now() { date '+%Y-%m-%d %H:%M:%S'; }
wf_today() { date '+%Y-%m-%d'; }
wf_ensure_dir() { mkdir -p "$1"; }

wf_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
wf_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
wf_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
wf_error() { echo -e "${RED}[ERROR]${NC} $*"; }

wf_warn_deprecated() {
  local legacy_name="$1"
  local new_name="$2"

  # Per-process dedup (fast path — avoids file I/O on repeat calls in same shell)
  local key="WF_DEPRECATED_WARNED_${legacy_name//[^a-zA-Z0-9]/_}"
  if [[ "${!key:-0}" == "1" ]]; then
    return 0
  fi
  printf -v "$key" '%s' "1"
  export "$key"

  # Cross-process dedup: warn only once per day per function name.
  # Uses ~/.flowctl/seen-deprecations.txt — format: "YYYY-MM-DD funcname"
  local today
  today=$(date +%Y-%m-%d 2>/dev/null || echo "0000-00-00")
  local seen_file="${FLOWCTL_HOME:-$HOME/.flowctl}/seen-deprecations.txt"
  local marker="${today} ${legacy_name}"
  if [[ -f "$seen_file" ]] && grep -qF "$marker" "$seen_file" 2>/dev/null; then
    return 0
  fi
  # Append marker (create file if missing; prune entries older than 7 days)
  mkdir -p "$(dirname "$seen_file")" 2>/dev/null || true
  echo "$marker" >> "$seen_file" 2>/dev/null || true
  # Prune: keep only lines from last 7 days (best-effort, non-blocking)
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import sys
from pathlib import Path
from datetime import datetime, timedelta
p = Path(sys.argv[1])
if not p.exists(): sys.exit(0)
cutoff = (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')
lines = [l for l in p.read_text().splitlines() if l >= cutoff]
p.write_text('\n'.join(lines) + '\n')
" "$seen_file" 2>/dev/null || true
  fi

  echo -e "${YELLOW}[deprecation] '${legacy_name}' is kept for compatibility; use '${new_name}' instead.${NC}" >&2
}

# Backward-compatible aliases (Phase 5.2)
now() { wf_warn_deprecated "now" "wf_now"; wf_now "$@"; }
today() { wf_warn_deprecated "today" "wf_today"; wf_today "$@"; }
ensure_dir() { wf_warn_deprecated "ensure_dir" "wf_ensure_dir"; wf_ensure_dir "$@"; }
