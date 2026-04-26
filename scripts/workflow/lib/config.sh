#!/usr/bin/env bash

# Centralized runtime/config paths for flowctl engine.
# WORKFLOW_ROOT: nơi chứa flowctl engine/scripts (global package hoặc local repo).
# PROJECT_ROOT: project đang được điều phối flowctl (mặc định current working dir).
: "${WORKFLOW_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
: "${PROJECT_ROOT:=$PWD}"

REPO_ROOT="$PROJECT_ROOT"
STATE_FILE="$REPO_ROOT/flowctl-state.json"
QA_GATE_FILE="$REPO_ROOT/workflows/gates/qa-gate.v1.json"
WORKFLOW_LOCK_DIR="$REPO_ROOT/.flowctl-lock"

# ── flowctl Home Directory (~/.flowctl) ───────────────────────
# All volatile/generated runtime data lives outside the repo so
# developers don't need .gitignore magic and data persists across clones.
#
# Layout:
#   ~/.flowctl/
#     config.json                     ← global settings
#     registry.json                   ← project registry
#     projects/
#       <slug>-<short-id>/            ← per-project data dir
#         meta.json                   ← project metadata
#         cache/                      ← shell-proxy cache (replaces .cache/mcp/)
#           events.jsonl
#           session-stats.json
#           wf_state.json, _baselines.json, _gen.json
#         runtime/                    ← workflow runtime (replaces workflows/runtime/)
#           idempotency.json
#           role-sessions.json
#           heartbeats.jsonl
#           budget-state.json
#           budget-events.jsonl
#           traceability-map.jsonl
#           evidence/
#           release-dashboard/
#
# flowctl-state.json stays in the repo (source of truth, team-shared).
# workflows/policies/ stays in the repo (version-controlled config).
# ─────────────────────────────────────────────────────────────

# Windows: $HOME is a MSYS path (/c/Users/...) — convert to mixed format for Python compat.
_home_native="$HOME"
command -v cygpath &>/dev/null 2>&1 && _home_native="$(cygpath -m "$HOME")"
FLOWCTL_HOME="${FLOWCTL_HOME:-$_home_native/.flowctl}"

# Fast bash-only parse of flow_id + project_name from state file (no python overhead).
_fl_id=""
_fl_name=""
if [[ -f "$STATE_FILE" ]]; then
  _fl_id=$(grep -o '"flow_id"[^,}]*' "$STATE_FILE" 2>/dev/null \
           | grep -o '"[^"]*"[[:space:]]*$' | tr -d '"' | tr -d ' ' || true)
  _fl_name=$(grep -o '"project_name"[^,}]*' "$STATE_FILE" 2>/dev/null \
             | sed 's/.*"project_name"[^"]*"\([^"]*\)".*/\1/' || true)
fi

# Derive data dir slug: lowercase alphanum+dash, max 32 chars, no leading/trailing dash.
_flowctl_make_slug() {
  local name="$1"
  printf '%s' "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^[-]*//;s/[-]*$//' \
    | cut -c1-32
}

if [[ -n "$_fl_id" ]]; then
  # Short ID = chars 4-11 of flow_id (skip "wf-", take 8 hex chars from UUID)
  _fl_short="${_fl_id:3:8}"
  _fl_slug="$(_flowctl_make_slug "${_fl_name:-project}")"
  [[ -z "$_fl_slug" ]] && _fl_slug="project"
  : "${FLOWCTL_DATA_DIR:=$FLOWCTL_HOME/projects/${_fl_slug}-${_fl_short}}"
else
  # No flow_id yet (before first init) — use repo-local fallback
  : "${FLOWCTL_DATA_DIR:=$REPO_ROOT/.cache/flowctl}"
fi

: "${FLOWCTL_CACHE_DIR:=$FLOWCTL_DATA_DIR/cache}"
: "${FLOWCTL_RUNTIME_DIR:=$FLOWCTL_DATA_DIR/runtime}"
: "${FLOWCTL_EVENTS_F:=$FLOWCTL_CACHE_DIR/events.jsonl}"
: "${FLOWCTL_STATS_F:=$FLOWCTL_CACHE_DIR/session-stats.json}"

# Runtime file paths — now inside FLOWCTL_RUNTIME_DIR (outside repo)
IDEMPOTENCY_FILE="$FLOWCTL_RUNTIME_DIR/idempotency.json"
ROLE_SESSIONS_FILE="$FLOWCTL_RUNTIME_DIR/role-sessions.json"
HEARTBEATS_FILE="$FLOWCTL_RUNTIME_DIR/heartbeats.jsonl"
BUDGET_STATE_FILE="$FLOWCTL_RUNTIME_DIR/budget-state.json"
BUDGET_EVENTS_FILE="$FLOWCTL_RUNTIME_DIR/budget-events.jsonl"
EVIDENCE_DIR="$FLOWCTL_RUNTIME_DIR/evidence"
TRACEABILITY_FILE="$FLOWCTL_RUNTIME_DIR/traceability-map.jsonl"
RELEASE_DASHBOARD_DIR="$FLOWCTL_RUNTIME_DIR/release-dashboard"

# Policy files stay in repo (version-controlled)
ROLE_POLICY_FILE="$REPO_ROOT/workflows/policies/role-policy.v1.json"
BUDGET_POLICY_FILE="$REPO_ROOT/workflows/policies/budget-policy.v1.json"

# Ensure data dirs exist (idempotent, no-op if already created)
flowctl_ensure_data_dirs() {
  # Validate FLOWCTL_HOME is writable before attempting to create sub-dirs.
  # Silently degraded writes (e.g. root-owned ~/.flowctl) are worse than a clear error.
  if [[ -e "$FLOWCTL_HOME" && ! -w "$FLOWCTL_HOME" ]]; then
    echo -e "${RED}[flowctl] ERROR: FLOWCTL_HOME ($FLOWCTL_HOME) exists but is not writable.${NC}" >&2
    echo -e "${YELLOW}[flowctl] Fix: sudo chown \$USER \"$FLOWCTL_HOME\" or set FLOWCTL_HOME to a writable path.${NC}" >&2
    return 1
  fi
  mkdir -p \
    "$FLOWCTL_CACHE_DIR" \
    "$FLOWCTL_RUNTIME_DIR/evidence" \
    "$FLOWCTL_RUNTIME_DIR/release-dashboard" \
    "$FLOWCTL_HOME/projects" \
    2>/dev/null || {
    echo -e "${RED}[flowctl] ERROR: Failed to create data dirs under $FLOWCTL_HOME. Check permissions.${NC}" >&2
    return 1
  }
}

# Module directory for dynamic source in entrypoint.
LIB_DIR="$WORKFLOW_ROOT/scripts/workflow/lib"