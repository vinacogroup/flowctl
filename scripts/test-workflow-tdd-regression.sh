#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/scripts/workflow.sh"
STATE_FILE="$REPO_ROOT/workflow-state.json"
RUNTIME_DIR="$REPO_ROOT/workflows/runtime"
TEST_ROOT="$REPO_ROOT/workflows/evidence/tdd"
STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="$TEST_ROOT/$STAMP"
LOG_FILE="$RUN_DIR/test.log"
SUMMARY_FILE="$RUN_DIR/summary.md"

mkdir -p "$RUN_DIR"
mkdir -p "$RUNTIME_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Missing workflow-state.json" >&2
  exit 1
fi

BACKUP_STATE="$RUN_DIR/workflow-state.backup.json"
cp "$STATE_FILE" "$BACKUP_STATE"

cleanup() {
  cp "$BACKUP_STATE" "$STATE_FILE"
  rm -rf "$REPO_ROOT/.workflow-lock" 2>/dev/null || true
}
trap cleanup EXIT

log() {
  echo "$1" | tee -a "$LOG_FILE"
}

run_cmd() {
  local title="$1"
  shift
  log ""
  log "==> $title"
  "$@" >> "$LOG_FILE" 2>&1
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

expect_failure() {
  local title="$1"
  shift
  log ""
  log "==> $title"
  if "$@" >> "$LOG_FILE" 2>&1; then
    log "FAIL: expected failure but command succeeded"
    exit 1
  else
    log "PASS: failed as expected"
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

get_step_counts() {
  python3 - <<PY
import json
d=json.load(open("$STATE_FILE"))
s=d["steps"][str(d["current_step"])]
print(f"{len(s.get('deliverables', []))},{len(s.get('decisions', []))},{len(s.get('blockers', []))}")
PY
}

log "# TDD Regression Run ($STAMP)"
log "repo=$REPO_ROOT"

expect_success "Initialize isolated test workflow" bash "$WORKFLOW" init --project "TDD Regression"
python3 - <<PY
import json
from pathlib import Path
p=Path("$STATE_FILE")
d=json.loads(p.read_text(encoding="utf-8"))
s=d["steps"]["1"]
s["status"]="pending"
s["started_at"]=None
s["completed_at"]=None
s["approved_at"]=None
s["approved_by"]=None
s["approval_status"]=None
s["deliverables"]=[]
s["blockers"]=[]
s["decisions"]=[]
d["current_step"]=1
d["overall_status"]="in_progress"
p.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
PY
log "PASS: normalized step 1 state after init"
expect_success "Start step 1" bash "$WORKFLOW" start

expect_failure "Approve must be blocked before reports/collect" bash "$WORKFLOW" approve --by "TDD"
expect_failure "Policy should deny trust for restricted roles" bash "$WORKFLOW" dispatch --headless --trust --dry-run

expect_success "Dispatch dry-run for step 1" bash "$WORKFLOW" team delegate --dry-run
monitor_output="$(bash "$WORKFLOW" team monitor --stale-seconds 1)"
assert_contains "$monitor_output" "Summary: running=" "team monitor should render runtime summary"
assert_contains "$monitor_output" "corr=" "team monitor should show correlation key"
assert_contains "$monitor_output" "policy=" "team monitor should classify policy type"
assert_contains "$monitor_output" "retry=" "team monitor should show retry budget"
recover_output="$(bash "$WORKFLOW" team recover --role pm --mode retry --dry-run)"
assert_contains "$recover_output" "PM recover" "team recover should be available"

REPORT_DIR="$REPO_ROOT/workflows/dispatch/step-1/reports"
mkdir -p "$REPORT_DIR"
cat > "$REPORT_DIR/pm-report.md" <<'EOF'
SUMMARY: PM baseline done.
DELIVERABLE: docs/requirements.md
DECISION: Keep PM gateway model.
BLOCKER: Need confidence threshold from tech-lead.
NEXT: Sync tech-lead.
EOF
cat > "$REPORT_DIR/tech-lead-report.md" <<'EOF'
SUMMARY: Technical constraints mapped.
DELIVERABLE: docs/architecture.md
DECISION: Use depth limit=3 for delegation.
NEXT: Prepare step 2 breakdown.
EOF
log "PASS: seeded worker reports"

expect_success "Collect worker reports" bash "$WORKFLOW" collect
counts_after_collect_1="$(get_step_counts)"

summary_after_collect="$(bash "$WORKFLOW" summary)"
assert_contains "$summary_after_collect" "Deliverables (4)" "collect should merge deliverables"
decisions_count="$(python3 - <<PY
import json
d=json.load(open("$STATE_FILE"))
s=d["steps"][str(d["current_step"])]
print(len(s.get("decisions", [])))
PY
)"
if [[ "$decisions_count" -lt 2 ]]; then
  log "FAIL: collect should merge decisions (expected >=2, got $decisions_count)"
  exit 1
fi
log "PASS: collect should merge decisions (count=$decisions_count)"

expect_success "Repeated collect should be idempotent" bash "$WORKFLOW" collect
counts_after_collect_2="$(get_step_counts)"
if [[ "$counts_after_collect_1" != "$counts_after_collect_2" ]]; then
  log "FAIL: collect idempotency broken ($counts_after_collect_1 -> $counts_after_collect_2)"
  exit 1
fi
log "PASS: collect idempotency preserved ($counts_after_collect_2)"

expect_failure "Gate must fail while blocker is open" bash "$WORKFLOW" gate-check

blocker_id="$(python3 - <<PY
import json
d=json.load(open("$STATE_FILE"))
s=d["steps"][str(d["current_step"])]
open_ids=[b["id"] for b in s.get("blockers",[]) if not b.get("resolved")]
print(open_ids[0] if open_ids else "")
PY
)"
if [[ -z "$blocker_id" ]]; then
  log "FAIL: expected one open blocker"
  exit 1
fi
expect_success "Resolve blocker" bash "$WORKFLOW" blocker resolve "$blocker_id"
expect_success "Gate passes after blocker resolution" bash "$WORKFLOW" gate-check
expect_success "Approve advances step when gate passes" bash "$WORKFLOW" approve --by "TDD"

current_step="$(python3 -c "import json;d=json.load(open('$STATE_FILE'));print(d['current_step'])")"
assert_contains "$current_step" "2" "approve should advance to step 2"

python3 - <<PY
import json
from pathlib import Path
p=Path("$REPO_ROOT/workflows/runtime/idempotency.json")
d=json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
d["step:2:role:tech-lead:mode:headless"]={
  "status":"completed",
  "step":2,
  "role":"tech-lead",
  "updated_at":"$STAMP"
}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
PY
log "PASS: seeded idempotency completed record for step 2 tech-lead"

dispatch_output="$(bash "$WORKFLOW" dispatch --headless --dry-run 2>&1)"
assert_contains "$dispatch_output" "[idempotency] skip @tech-lead" "idempotency should skip completed role"

dispatch_force_output="$(bash "$WORKFLOW" dispatch --headless --dry-run --force-run 2>&1)"
assert_contains "$dispatch_force_output" "would run headless @tech-lead" "force-run should bypass idempotency skip"

expect_failure "Approve must fail when --by value missing" bash "$WORKFLOW" approve --by

expect_success "Approve skip-gate should bypass gate and advance step" bash "$WORKFLOW" approve --skip-gate --by "TDD-BYPASS"
step_after_bypass="$(python3 -c "import json;d=json.load(open('$STATE_FILE'));print(d['current_step'])")"
assert_contains "$step_after_bypass" "3" "skip-gate approve should advance to step 3"

gate_events="$(python3 - <<PY
from pathlib import Path
p=Path("$REPO_ROOT/workflows/gates/reports/gate-events.jsonl")
print(p.read_text(encoding="utf-8") if p.exists() else "")
PY
)"
assert_contains "$gate_events" "\"status\": \"BYPASS\"" "gate report should include BYPASS event"
assert_contains "$gate_events" "\"actor\": \"TDD-BYPASS\"" "gate report should include bypass actor"

expect_failure "Mutating command should fail when active lock held" bash -lc "mkdir \"$REPO_ROOT/.workflow-lock\" && echo \"\$\$\" > \"$REPO_ROOT/.workflow-lock/pid\" && bash \"$WORKFLOW\" decision \"lock-conflict\""
rm -rf "$REPO_ROOT/.workflow-lock"

expect_success "Reset command should return workflow to step 1" bash -lc "printf 'yes\n' | bash \"$WORKFLOW\" reset 1"
step_after_reset="$(python3 -c "import json;d=json.load(open('$STATE_FILE'));print(d['current_step'])")"
assert_contains "$step_after_reset" "1" "reset should set current_step back to 1"

{
  echo "# TDD Regression Summary"
  echo ""
  echo "- Run: \`$STAMP\`"
  echo "- Result: PASS"
  echo "- Log: \`$LOG_FILE\`"
  echo ""
  echo "## Covered Behaviors"
  echo "- approve blocked by QA gate before evidence"
  echo "- collect merges deliverables/decisions/blockers"
  echo "- collect idempotency on repeated runs"
  echo "- gate fails on open blocker, passes after resolve"
  echo "- approve advances workflow step when gate passes"
  echo "- idempotency skip + force-run override behavior"
  echo "- role policy denies restricted trust mode"
  echo "- team monitor reports runtime role statuses"
  echo "- correlation ID surfaced in monitor output"
  echo "- timeout/retry policy class surfaced in monitor output"
  echo "- team recover runbook actions exposed via CLI"
  echo "- approve argument validation (--by requires value)"
  echo "- approve --skip-gate writes BYPASS gate audit"
  echo "- active lock blocks mutating command"
  echo "- reset flow returns workflow to requested step"
} > "$SUMMARY_FILE"

echo "TDD regression suite passed."
echo "Summary: $SUMMARY_FILE"
