#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/scripts/flowctl.sh"
STATE_FILE="$REPO_ROOT/flowctl-state.json"
RUNTIME_DIR="$REPO_ROOT/workflows/runtime"
BUDGET_STATE_FILE="$RUNTIME_DIR/budget-state.json"
TRACEABILITY_FILE="$RUNTIME_DIR/traceability-map.jsonl"
TEST_ROOT="$REPO_ROOT/workflows/evidence/chaos"
STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="$TEST_ROOT/$STAMP"
LOG_FILE="$RUN_DIR/test.log"
SUMMARY_FILE="$RUN_DIR/summary.md"

mkdir -p "$RUN_DIR"
mkdir -p "$RUNTIME_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Missing flowctl-state.json" >&2
  exit 1
fi

BACKUP_STATE="$RUN_DIR/flowctl-state.backup.json"
cp "$STATE_FILE" "$BACKUP_STATE"
BACKUP_BUDGET="$RUN_DIR/budget-state.backup.json"
if [[ -f "$BUDGET_STATE_FILE" ]]; then
  cp "$BUDGET_STATE_FILE" "$BACKUP_BUDGET"
fi

cleanup() {
  cp "$BACKUP_STATE" "$STATE_FILE"
  if [[ -f "$BACKUP_BUDGET" ]]; then
    cp "$BACKUP_BUDGET" "$BUDGET_STATE_FILE"
  fi
  rm -rf "$REPO_ROOT/.flowctl-lock" 2>/dev/null || true
  rm -f "$TRACEABILITY_FILE" 2>/dev/null || true
}
trap cleanup EXIT

log() {
  echo "$1" | tee -a "$LOG_FILE"
}

expect_success() {
  local title="$1"
  shift
  log ""
  log "==> $title"
  if "$@" >> "$LOG_FILE" 2>&1; then
    log "PASS: $title"
  else
    log "FAIL: $title"
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    log "FAIL: $label (missing: $needle)"
    exit 1
  fi
  log "PASS: $label"
}

log "# Chaos Suite Run ($STAMP)"
log "repo=$REPO_ROOT"

expect_success "Initialize flowctl baseline" bash "$WORKFLOW" init --no-setup --project "Chaos Regression"
expect_success "Start step 1 baseline" bash "$WORKFLOW" start

REPORT_DIR="$REPO_ROOT/workflows/dispatch/step-1/reports"
LOGS_DIR="$REPO_ROOT/workflows/dispatch/step-1/logs"
mkdir -p "$REPORT_DIR" "$LOGS_DIR"
cat > "$REPORT_DIR/pm-report.md" <<'EOF'
SUMMARY: PM chaos baseline.
DELIVERABLE: docs/chaos-requirements.md
DECISION: Continue with controlled chaos tests.
EOF
cat > "$REPORT_DIR/tech-lead-report.md" <<'EOF'
SUMMARY: Tech lead chaos baseline.
DELIVERABLE: docs/chaos-architecture.md
DECISION: Keep fail-closed behavior.
EOF
echo "not a json line" > "$RUNTIME_DIR/heartbeats.jsonl"
echo '{"bad":"json"}' >> "$RUNTIME_DIR/heartbeats.jsonl"
echo '{"step":1,"role":"pm","timestamp":"2026-04-23T00:00:00Z"}' >> "$RUNTIME_DIR/heartbeats.jsonl"

monitor_output="$(bash "$WORKFLOW" team monitor --stale-seconds 1)"
assert_contains "$monitor_output" "Summary: running=" "team monitor survives corrupted heartbeat lines"

expect_success "Collect under heartbeat corruption" bash "$WORKFLOW" collect

python3 - <<PY
import json
from pathlib import Path
p=Path("$BUDGET_STATE_FILE")
state=json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
state.setdefault("breaker", {})
state.setdefault("run", {})
state.setdefault("roles", {})
state["breaker"].update({
    "state": "half-open",
    "reason": "chaos_probe",
    "opened_at": "2026-04-23T00:00:00Z",
    "last_transition_at": "2026-04-23T00:00:00Z",
    "cooldown_seconds": 300,
    "probe_role": "pm"
})
state["run"].update({
    "flow_id": "wf-chaos",
    "run_id": "run-chaos",
    "step": 1
})
state["roles"]["pm"]={"tokens_est":1000,"runtime_seconds":30,"cost_usd":0.01,"attempt_count":1,"status":"reserved"}
p.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
PY
expect_success "Collect should close half-open breaker probe" bash "$WORKFLOW" collect
breaker_state="$(python3 - <<PY
import json
from pathlib import Path
p=Path("$BUDGET_STATE_FILE")
d=json.loads(p.read_text(encoding="utf-8"))
print(d.get("breaker",{}).get("state",""))
PY
)"
assert_contains "$breaker_state" "closed" "budget breaker closes after probe role completes"

mkdir -p "$LOGS_DIR"
cat > "$REPORT_DIR/backend-report.md" <<'EOF'
SUMMARY: backend placeholder
EOF
echo "worker crashed" > "$LOGS_DIR/backend.log"
python3 - <<PY
import json
from pathlib import Path
p=Path("$RUNTIME_DIR/idempotency.json")
d=json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
d["step:1:role:backend:mode:headless"]={"status":"launched","pid":999999}
p.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
PY
expect_success "Rollback recovery removes role artifacts" bash "$WORKFLOW" team recover --role backend --mode rollback
if [[ -f "$REPORT_DIR/backend-report.md" || -f "$LOGS_DIR/backend.log" ]]; then
  log "FAIL: rollback should remove backend report/log"
  exit 1
fi
log "PASS: rollback removed backend report/log"

rm -rf "$REPO_ROOT/.flowctl-lock"
mkdir -p "$REPO_ROOT/.flowctl-lock"
echo "999999" > "$REPO_ROOT/.flowctl-lock/pid"
expect_success "Stale lock is reclaimed automatically" bash "$WORKFLOW" decision "chaos lock reclaim"
log "PASS: stale lock reclaimed"

trace_dump="$(python3 - <<PY
from pathlib import Path
p=Path("$TRACEABILITY_FILE")
print(p.read_text(encoding="utf-8") if p.exists() else "")
PY
)"
assert_contains "$trace_dump" "\"event_type\": \"task\"" "collect writes task traceability under chaos"

{
  echo "# Chaos Suite Summary"
  echo ""
  echo "- Run: \`$STAMP\`"
  echo "- Result: PASS"
  echo "- Log: \`$LOG_FILE\`"
  echo ""
  echo "## Covered Chaos Scenarios"
  echo "- monitor tolerates corrupted heartbeat JSON lines"
  echo "- collect succeeds with noisy runtime artifacts"
  echo "- budget breaker half-open probe closes on successful role completion"
  echo "- team recover rollback removes orphan report/log and marks idempotency path"
  echo "- stale flowctl lock is reclaimed and mutating command proceeds"
  echo "- traceability events still emitted under chaos conditions"
} > "$SUMMARY_FILE"

echo "Chaos test suite passed."
echo "Summary: $SUMMARY_FILE"
