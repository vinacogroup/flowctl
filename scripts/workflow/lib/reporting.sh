#!/usr/bin/env bash

cmd_summary() {
  local step
  step=$(wf_json_get "current_step")

  python3 -c "
import json, sys

# Windows cp1252 fix: reconfigure stdout to UTF-8
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$STATE_FILE') as f:
    data = json.load(f)

step = str(data.get('current_step', 1))
s = data['steps'].get(step, {})

print(f'''
\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Step {step} Summary: {s.get(\"name\", \"\")}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
Agent:      @{s.get(\"agent\", \"\")}
Status:     {s.get(\"status\", \"pending\")}
Started:    {s.get(\"started_at\", \"—\")}
Completed:  {s.get(\"completed_at\", \"—\")}
Approval:   {s.get(\"approval_status\", \"pending\")}

Deliverables ({len(s.get(\"deliverables\", []))}):''')

for d in s.get('deliverables', []):
    print(f'  ✓ {d}')

blockers = s.get('blockers', [])
open_b = [b for b in blockers if not b.get('resolved')]
print(f'\nBlockers: {len(blockers)} total, {len(open_b)} open')
for b in open_b:
    print(f'  ! {b.get(\"description\", \"\")}')

decisions = s.get('decisions', [])
print(f'\nDecisions ({len(decisions)}):')
for d in decisions:
    if d.get('type') != 'rejection':
        print(f'  → {d.get(\"description\", \"\")}')

print()
"
}

cmd_history() {
  python3 -c "
import json, sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$STATE_FILE') as f:
    data = json.load(f)

print(f'\033[1mApproval History — {data.get(\"project_name\", \"Project\")}\033[0m')
print()

for n in range(1, 10):
    s = data['steps'].get(str(n), {})
    status = s.get('approval_status')
    if status:
        icon = '✓' if status == 'approved' else ('✗' if status == 'rejected' else '~')
        color = '\033[0;32m' if status == 'approved' else ('\033[0;31m' if status == 'rejected' else '\033[1;33m')
        print(f'  {color}{icon}\033[0m Step {n}: {s.get(\"name\",\"\")} — {status.upper()} by {s.get(\"approved_by\", \"?\")} @ {s.get(\"approved_at\", \"?\")}')
print()
"
}

cmd_release_dashboard() {
  local step=""
  local write_file="true"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --step)
        step="${2:-}"
        shift 2
        ;;
      --no-write)
        write_file="false"
        shift
        ;;
      *)
        echo "Usage: release-dashboard [--step N] [--no-write]"
        exit 1
        ;;
    esac
  done
  [[ -n "$step" ]] || step="$(wf_require_initialized_workflow)"
  [[ "$step" =~ ^[0-9]+$ ]] || { echo "Invalid step: $step"; exit 1; }

  local gate_signal gate_ok gate_detail
  gate_signal="$(wf_evaluate_gate "$step" 2>/dev/null || true)"
  if [[ "$gate_signal" == GATE_OK\|* ]]; then
    gate_ok="yes"
    gate_detail="${gate_signal#GATE_OK|}"
  else
    gate_ok="no"
    gate_detail="${gate_signal#GATE_FAIL|}"
    [[ -n "$gate_detail" ]] || gate_detail="gate check not available"
  fi

  local dashboard_output
  dashboard_output=$(WF_STATE_FILE="$STATE_FILE" WF_STEP="$step" WF_REPO_ROOT="$REPO_ROOT" WF_TRACE_FILE="$TRACEABILITY_FILE" WF_BUDGET_FILE="$BUDGET_STATE_FILE" WF_EVIDENCE_DIR="$EVIDENCE_DIR" WF_GATE_OK="$gate_ok" WF_GATE_DETAIL="$gate_detail" python3 - <<'PY'
import json
import os
from pathlib import Path

state_path = Path(os.environ["WF_STATE_FILE"])
repo_root = Path(os.environ["WF_REPO_ROOT"])
step = str(int(os.environ["WF_STEP"]))
trace_path = Path(os.environ["WF_TRACE_FILE"])
budget_path = Path(os.environ["WF_BUDGET_FILE"])
evidence_dir = Path(os.environ["WF_EVIDENCE_DIR"])
gate_ok = os.environ.get("WF_GATE_OK", "no")
gate_detail = os.environ.get("WF_GATE_DETAIL", "n/a")

state = json.loads(state_path.read_text(encoding="utf-8"))
step_obj = state.get("steps", {}).get(step, {})
manifest_path = evidence_dir / f"step-{step}-manifest.json"
manifest = {}
if manifest_path.exists():
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

trace_rows = []
if trace_path.exists():
    for line in trace_path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            row = json.loads(s)
        except Exception:
            continue
        if str(row.get("step")) == step:
            trace_rows.append(row)

task_rows = [r for r in trace_rows if r.get("event_type") == "task"]
approval_rows = [r for r in trace_rows if r.get("event_type") == "approval"]

budget = json.loads(budget_path.read_text(encoding="utf-8")) if budget_path.exists() else {}
run_budget = budget.get("run", {})
breaker = budget.get("breaker", {})

deliverables = step_obj.get("deliverables", []) or []
blockers = step_obj.get("blockers", []) or []
open_blockers = [b for b in blockers if not b.get("resolved")]
decisions = step_obj.get("decisions", []) or []
approval_status = step_obj.get("approval_status") or "pending"
ready = (gate_ok == "yes") and len(open_blockers) == 0 and bool(manifest.get("file_count", 0) > 0) and len(task_rows) > 0

lines = []
lines.append("# Release Dashboard (PM Approval)")
lines.append("")
lines.append(f"- project: {state.get('project_name', '')}")
lines.append(f"- flow_id: {state.get('flow_id', '')}")
lines.append(f"- step: {step} — {step_obj.get('name', '')}")
lines.append(f"- step_status: {step_obj.get('status', 'pending')}")
lines.append(f"- approval_status: {approval_status}")
lines.append(f"- approval_ready: {'yes' if ready else 'no'}")
lines.append("")
lines.append("## Quality Gates")
lines.append(f"- gate_passed: {gate_ok}")
lines.append(f"- gate_detail: {gate_detail}")
lines.append(f"- blockers_open: {len(open_blockers)}")
lines.append("")
lines.append("## Evidence Integrity")
if manifest_path.exists():
    # relative_to() raises ValueError when manifest lives outside REPO_ROOT
    # (e.g. ~/.flowctl/…/evidence/ on Windows).  Fall back to os.path.relpath()
    # which always succeeds, then use the absolute path as a last resort.
    try:
        _manifest_display = str(manifest_path.relative_to(repo_root))
    except ValueError:
        import os as _os
        try:
            _manifest_display = _os.path.relpath(str(manifest_path), str(repo_root))
        except ValueError:
            _manifest_display = str(manifest_path)
else:
    _manifest_display = "missing"
lines.append(f"- evidence_manifest: {_manifest_display}")
lines.append(f"- evidence_files: {manifest.get('file_count', 0)}")
lines.append(f"- evidence_signature: {manifest.get('signature', 'missing')}")
lines.append("")
lines.append("## Traceability")
lines.append(f"- task_trace_events: {len(task_rows)}")
lines.append(f"- approval_trace_events: {len(approval_rows)}")
if task_rows:
    lines.append(f"- latest_task_run_id: {task_rows[-1].get('run_id', '')}")
if task_rows:
    lines.append(f"- latest_task_correlation_id: {task_rows[-1].get('correlation_id', '')}")
lines.append("")
lines.append("## Delivery Summary")
lines.append(f"- deliverables: {len(deliverables)}")
lines.append(f"- decisions: {len(decisions)}")
lines.append("")
lines.append("## Budget Snapshot")
lines.append(f"- breaker_state: {breaker.get('state', 'closed')}")
lines.append(f"- consumed_tokens_est: {run_budget.get('consumed_tokens_est', 0)}")
lines.append(f"- consumed_runtime_seconds: {run_budget.get('consumed_runtime_seconds', 0)}")
lines.append(f"- consumed_cost_usd: {run_budget.get('consumed_cost_usd', 0.0)}")

print("\n".join(lines))
PY
)

  echo "$dashboard_output"
  if [[ "$write_file" == "true" ]]; then
    wf_ensure_dir "$RELEASE_DASHBOARD_DIR"
    local out_file="$RELEASE_DASHBOARD_DIR/step-${step}.md"
    printf "%s\n" "$dashboard_output" > "$out_file"
    echo -e "\n${CYAN}Saved:${NC} ${out_file#$REPO_ROOT/}"
  fi
}

cmd_reset() {
  local target="${1:-}"
  [[ -z "$target" ]] && { echo "Usage: reset <step_number>"; exit 1; }

  echo -e "${RED}${BOLD}CẢNH BÁO: Reset flowctl về Step $target.${NC}"
  echo -e "Tất cả progress từ Step $target trở đi sẽ bị xóa."
  echo -n "Xác nhận? (yes/no): "
  read -r confirm
  [[ "$confirm" != "yes" ]] && { echo "Hủy."; exit 0; }

  python3 -c "
import json
from datetime import datetime

with open('$STATE_FILE') as f:
    data = json.load(f)

target = int('$target')
data['current_step'] = target
data['overall_status'] = 'in_progress'

for n in range(target, 10):
    s = data['steps'].get(str(n), {})
    s['status'] = 'pending'
    s['started_at'] = None
    s['completed_at'] = None
    s['approved_at'] = None
    s['approved_by'] = None
    s['approval_status'] = None
    s['deliverables'] = []
    s['blockers'] = []
    s['decisions'] = []

data['updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f'Workflow đã reset về Step $target')
"
}
