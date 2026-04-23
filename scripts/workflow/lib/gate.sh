#!/usr/bin/env bash

write_gate_report() {
  local step="$1"
  local status="$2"
  local detail="$3"
  local actor="$4"
  local reports_dir="$REPO_ROOT/workflows/gates/reports"
  ensure_dir "$reports_dir"

  local ts_human
  ts_human="$(now)"
  local ts_iso
  ts_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local jsonl_file="$reports_dir/gate-events.jsonl"
  local md_file="$reports_dir/step-${step}-gate.md"

  WF_STEP="$step" WF_STATUS="$status" WF_ACTOR="$actor" WF_DETAIL="$detail" WF_TS_ISO="$ts_iso" WF_TS_HUMAN="$ts_human" WF_JSONL="$jsonl_file" python3 - <<'PY'
import json
import os
from pathlib import Path

event = {
  "timestamp": os.environ["WF_TS_ISO"],
  "timestamp_local": os.environ["WF_TS_HUMAN"],
  "step": int(os.environ["WF_STEP"]),
  "status": os.environ["WF_STATUS"],
  "actor": os.environ["WF_ACTOR"],
  "detail": os.environ["WF_DETAIL"]
}
path = Path(os.environ["WF_JSONL"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
PY

  {
    echo "## [$ts_human] $status"
    echo "- actor: $actor"
    echo "- detail: $detail"
    echo ""
  } >> "$md_file"
}

evaluate_gate() {
  local step="$1"
  python3 - <<PY
import json
from pathlib import Path

state_path = Path("$STATE_FILE")
gate_path = Path("$QA_GATE_FILE")
repo_root = Path("$REPO_ROOT")
step = str($step)

if not state_path.exists():
    print("GATE_FAIL|workflow-state.json not found")
    raise SystemExit(1)

if not gate_path.exists():
    print(f"GATE_FAIL|Gate policy not found: {gate_path}")
    raise SystemExit(1)

state = json.loads(state_path.read_text(encoding="utf-8"))
gate = json.loads(gate_path.read_text(encoding="utf-8"))
step_obj = state.get("steps", {}).get(step)
if not step_obj:
    print(f"GATE_FAIL|Step {step} not found in workflow state")
    raise SystemExit(1)

errors = []
status = (step_obj.get("status") or "").strip()
approval = (step_obj.get("approval_status") or "").strip()
deliverables = step_obj.get("deliverables", []) or []
decisions = step_obj.get("decisions", []) or []
blockers = step_obj.get("blockers", []) or []
open_blockers = [b for b in blockers if not b.get("resolved")]

reports_dir = repo_root / "workflows" / "dispatch" / f"step-{step}" / "reports"
report_count = len(list(reports_dir.glob("*-report.md"))) if reports_dir.exists() else 0

g = gate.get("defaults", {})
allowed_statuses = g.get("allowed_step_statuses_for_approve", ["in_progress"])
min_reports = int(g.get("min_worker_reports", 1))
min_deliverables = int(g.get("min_deliverables", 1))
min_decisions = int(g.get("min_decisions", 0))
require_no_open_blockers = bool(g.get("require_no_open_blockers", True))
deny_if_already_approved = bool(g.get("deny_if_already_approved", True))

if status not in allowed_statuses:
    errors.append(
        f"Step status must be one of {allowed_statuses}, current={status or 'empty'}"
    )
if deny_if_already_approved and approval == "approved":
    errors.append("Step already approved; refusing duplicate approve")
if report_count < min_reports:
    errors.append(f"Need >= {min_reports} worker report(s), found {report_count}")
if len(deliverables) < min_deliverables:
    errors.append(f"Need >= {min_deliverables} deliverable(s), found {len(deliverables)}")
if len(decisions) < min_decisions:
    errors.append(f"Need >= {min_decisions} decision(s), found {len(decisions)}")
if require_no_open_blockers and open_blockers:
    errors.append(f"Open blockers must be 0, found {len(open_blockers)}")

if errors:
    print("GATE_FAIL|" + " ; ".join(errors))
    raise SystemExit(1)

print(
    f"GATE_OK|step={step} reports={report_count} deliverables={len(deliverables)} "
    f"decisions={len(decisions)} open_blockers={len(open_blockers)}"
)
PY
}
