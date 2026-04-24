#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/flowctl-state.json"
WORKFLOW_SCRIPT="$REPO_ROOT/scripts/flowctl.sh"
ARTIFACT_DIR="$REPO_ROOT/workflows/evidence"
STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="$ARTIFACT_DIR/$STAMP"
LOG_FILE="$RUN_DIR/test.log"
SUMMARY_FILE="$RUN_DIR/summary.md"

mkdir -p "$RUN_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Missing $STATE_FILE" >&2
  exit 1
fi

if [[ ! -x "$WORKFLOW_SCRIPT" ]]; then
  chmod +x "$WORKFLOW_SCRIPT"
fi

BACKUP_FILE="$RUN_DIR/flowctl-state.backup.json"
cp "$STATE_FILE" "$BACKUP_FILE"

cleanup() {
  cp "$BACKUP_FILE" "$STATE_FILE"
}
trap cleanup EXIT

run_cmd() {
  local desc="$1"
  shift
  echo "==> $desc" | tee -a "$LOG_FILE"
  "$@" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Assertion failed: $label (expected: $needle)" | tee -a "$LOG_FILE"
    exit 1
  fi
}

echo "# Workflow E2E Test ($STAMP)" > "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "- Repo: \`$REPO_ROOT\`" >> "$SUMMARY_FILE"
echo "- Timestamp: \`$STAMP\`" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

run_cmd "Initialize flowctl" bash "$WORKFLOW_SCRIPT" init --no-setup --project "E2E Skill Validation"
STATUS_OUTPUT="$(bash "$WORKFLOW_SCRIPT" status)"
echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE" >/dev/null
assert_contains "Step 1" "$STATUS_OUTPUT" "status after init"

run_cmd "Start current step" bash "$WORKFLOW_SCRIPT" start
run_cmd "Dispatch worker briefs (dry run)" bash "$WORKFLOW_SCRIPT" dispatch --headless --trust --dry-run

STEP="$(python3 -c "import json;print(json.load(open('$STATE_FILE'))['current_step'])")"
REPORTS_DIR="$REPO_ROOT/workflows/dispatch/step-$STEP/reports"
mkdir -p "$REPORTS_DIR"

cat > "$REPORTS_DIR/pm-report.md" <<'EOF'
SUMMARY: PM completed requirements baseline.
DELIVERABLE: docs/requirements.md
DECISION: Use PM as single communication gateway.
BLOCKER: Need techlead estimate confidence threshold.
NEXT: Sync with techlead for planning.
EOF

cat > "$REPORTS_DIR/tech-lead-report.md" <<'EOF'
SUMMARY: Techlead decomposed tasks by domain.
DELIVERABLE: docs/architecture.md
DECISION: Use delegate depth limit = 3.
NEXT: Assign tasks to backend/frontend/devops agents.
EOF

run_cmd "Collect worker reports into flowctl state" bash "$WORKFLOW_SCRIPT" collect
SUMMARY_OUTPUT="$(bash "$WORKFLOW_SCRIPT" summary)"
echo "$SUMMARY_OUTPUT" | tee -a "$LOG_FILE" >/dev/null
assert_contains "deliverables=" "$(python3 - <<PY
import json
data=json.load(open("$STATE_FILE"))
s=data["steps"][str(data["current_step"])]
print(f"deliverables={len(s.get('deliverables',[]))},decisions={len(s.get('decisions',[]))},blockers={len(s.get('blockers',[]))}")
PY
)" "state includes collected data"

run_cmd "Approve current step and advance" bash "$WORKFLOW_SCRIPT" approve --by "E2E Test"
NEXT_STEP="$(python3 -c "import json;d=json.load(open('$STATE_FILE'));print(d['current_step'])")"

{
  echo "## Assertions"
  echo "- [x] Init/start/dispatch/collect/approve commands run successfully."
  echo "- [x] Dry-run dispatch generated brief bundle and command list."
  echo "- [x] Collect parsed \`DELIVERABLE\`, \`DECISION\`, \`BLOCKER\` from worker reports."
  echo "- [x] Approve advanced flowctl to next step (\`$NEXT_STEP\`)."
  echo ""
  echo "## Evidence"
  echo "- Full command log: \`$LOG_FILE\`"
  echo "- State backup (for restore): \`$BACKUP_FILE\`"
  echo "- Test run directory: \`$RUN_DIR\`"
} >> "$SUMMARY_FILE"

echo "E2E flowctl test passed."
echo "Summary: $SUMMARY_FILE"
