#!/usr/bin/env bash

cmd_dispatch() {
  local auto_launch="false"
  local headless="false"
  local trust_workspace="false"
  local dry_run="false"
  local force_run="false"
  local max_retries="3"
  local role_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --launch) auto_launch="true" ;;
      --headless) headless="true" ;;
      --trust) trust_workspace="true" ;;
      --dry-run) dry_run="true" ;;
      --force-run) force_run="true" ;;
      --max-retries) max_retries="${2:-3}"; shift ;;
      --role) role_filter="${2:-}"; shift ;;
      *)
        echo -e "${RED}Unknown option for dispatch: $1${NC}"
        echo -e "Usage: bash scripts/workflow.sh dispatch [--launch|--headless] [--trust] [--dry-run] [--force-run] [--max-retries N] [--role name]\n"
        exit 1
        ;;
    esac
    shift
  done
  [[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries="3"
  role_filter="${role_filter#@}"

  if [[ "$auto_launch" == "true" && "$headless" == "true" ]]; then
    echo -e "${RED}Không thể dùng đồng thời --launch và --headless.${NC}"
    echo -e "Chọn một mode chạy worker.\n"
    exit 1
  fi

  local step
  step=$(wf_require_initialized_workflow)
  local workflow_id
  workflow_id=$(WF_STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json
import os
import uuid
from pathlib import Path

path = Path(os.environ["WF_STATE_FILE"])
data = json.loads(path.read_text(encoding="utf-8"))
wid = (data.get("workflow_id") or "").strip()
if not wid:
    wid = f"wf-{uuid.uuid4()}"
    data["workflow_id"] = wid
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
print(wid)
PY
)
  local run_id
  run_id="run-$(date -u '+%Y%m%dT%H%M%SZ')-$RANDOM"
  local dispatch_mode="manual"
  [[ "$headless" == "true" ]] && dispatch_mode="headless"
  [[ "$auto_launch" == "true" ]] && dispatch_mode="launch"

  local dispatch_dir="$REPO_ROOT/workflows/dispatch/step-$step"
  local reports_dir="$dispatch_dir/reports"
  local runtime_dir="$REPO_ROOT/workflows/runtime"
  wf_ensure_dir "$dispatch_dir"
  wf_ensure_dir "$reports_dir"
  wf_ensure_dir "$runtime_dir"
  [[ -f "$IDEMPOTENCY_FILE" ]] || echo '{}' > "$IDEMPOTENCY_FILE"
  [[ -f "$ROLE_SESSIONS_FILE" ]] || echo '{}' > "$ROLE_SESSIONS_FILE"
  [[ -f "$HEARTBEATS_FILE" ]] || : > "$HEARTBEATS_FILE"

  WF_STEP="$step" WF_STATE="$STATE_FILE" WF_REPO="$REPO_ROOT" WF_DISPATCH="$dispatch_dir" WF_REPORTS="$reports_dir" WF_POLICY_FILE="$ROLE_POLICY_FILE" WF_TRUST_REQUESTED="$trust_workspace" WF_DISPATCH_MODE="$dispatch_mode" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["WF_STATE"])
repo_root = Path(os.environ["WF_REPO"])
step = str(os.environ["WF_STEP"])
dispatch_dir = Path(os.environ["WF_DISPATCH"])
reports_dir = Path(os.environ["WF_REPORTS"])
policy_path = Path(os.environ["WF_POLICY_FILE"])
trust_requested = os.environ.get("WF_TRUST_REQUESTED", "false").lower() == "true"
dispatch_mode = os.environ.get("WF_DISPATCH_MODE", "manual")

data = json.loads(state_path.read_text(encoding="utf-8"))
s = data["steps"][step]

primary = s.get("agent", "").strip()
supports = [a.strip() for a in s.get("support_agents", []) if a and a.strip()]
roles = []
for role in [primary] + supports:
    if role and role not in roles:
        roles.append(role)

policy = {"defaults": {"allow_trust": False, "allowed_modes": ["manual", "headless", "launch"]}, "roles": {}}
if policy_path.exists():
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
defaults = policy.get("defaults", {})
role_overrides = policy.get("roles", {})

def role_allow_trust(role: str) -> bool:
    role_cfg = role_overrides.get(role, {})
    return bool(role_cfg.get("allow_trust", defaults.get("allow_trust", False)))

def role_allowed_modes(role: str):
    role_cfg = role_overrides.get(role, {})
    modes = role_cfg.get("allowed_modes", defaults.get("allowed_modes", ["manual", "headless", "launch"]))
    return [str(m).strip() for m in modes if str(m).strip()]

violations = []
for role in roles:
    modes = role_allowed_modes(role)
    if dispatch_mode not in modes:
        violations.append(f"@{role}: mode '{dispatch_mode}' not allowed (allowed={modes})")
    if trust_requested and not role_allow_trust(role):
        violations.append(f"@{role}: --trust is denied by policy")

if violations:
    print("POLICY_VIOLATION|" + " ; ".join(violations))
    raise SystemExit(2)

step_name = s.get("name", "")
kickoff_candidates = sorted((repo_root / "workflows" / "steps").glob(f"{int(step):02d}-*.md"))
kickoff_rel = str(kickoff_candidates[0].relative_to(repo_root)) if kickoff_candidates else ""

plan_candidates = sorted((repo_root / "plans").glob("*/plan.md"))
latest_plan = str(plan_candidates[-1].relative_to(repo_root)) if plan_candidates else ""

for role in roles:
    brief_path = dispatch_dir / f"{role}-brief.md"
    report_path = reports_dir / f"{role}-report.md"
    brief = f"""# Worker Brief — Step {step} ({step_name})

Role: @{role}
Current step: {step}
Workspace: {repo_root}

## Input bắt buộc
- workflow-state.json
"""
    if kickoff_rel:
        brief += f"- {kickoff_rel}\n"
    if latest_plan:
        brief += f"- {latest_plan}\n"
    brief += f"""
## Nhiệm vụ
1. Thực hiện phần việc của role @{role} cho step hiện tại.
2. Không chạm file ngoài scope role nếu không cần thiết.
3. Ghi kết quả vào report file dưới đây.

## Report output (bắt buộc)
Ghi vào: {report_path.relative_to(repo_root)}

Format khuyến nghị:
- SUMMARY: ...
- DELIVERABLE: relative/path/to/file
- DECISION: ...
- BLOCKER: ...
- NEXT: ...
"""
    brief_path.write_text(brief, encoding="utf-8")

print("OK")
PY

  echo -e "\n${GREEN}${BOLD}Dispatch bundles đã tạo:${NC} ${BOLD}${dispatch_dir#$REPO_ROOT/}${NC}"
  echo -e "Trace: workflow_id=${BOLD}${workflow_id}${NC} run_id=${BOLD}${run_id}${NC}"
  echo -e "Dùng các lệnh sau để chạy worker sessions song song:\n"

  local commands_file="$dispatch_dir/agent-commands.txt"
  local trust_flag=""
  [[ "$trust_workspace" == "true" ]] && trust_flag="--trust"
  WF_STEP="$step" WF_STATE="$STATE_FILE" WF_REPO="$REPO_ROOT" WF_DISPATCH="$dispatch_dir" WF_COMMANDS="$commands_file" WF_TRUST="$trust_flag" WF_ROLE_SESSIONS="$ROLE_SESSIONS_FILE" WF_ROLE_FILTER="$role_filter" python3 - <<'PY'
import json
import os
from pathlib import Path

state_path = Path(os.environ["WF_STATE"])
repo_root = Path(os.environ["WF_REPO"])
step = str(os.environ["WF_STEP"])
dispatch_dir = Path(os.environ["WF_DISPATCH"])
commands_file = Path(os.environ["WF_COMMANDS"])
trust_flag = os.environ.get("WF_TRUST", "").strip()
role_sessions_path = Path(os.environ["WF_ROLE_SESSIONS"])
role_filter = (os.environ.get("WF_ROLE_FILTER", "") or "").strip()

role_sessions = {}
if role_sessions_path.exists():
    role_sessions = json.loads(role_sessions_path.read_text(encoding="utf-8"))

data = json.loads(state_path.read_text(encoding="utf-8"))
s = data["steps"][step]
primary = s.get("agent", "").strip()
supports = [a.strip() for a in s.get("support_agents", []) if a and a.strip()]
roles = []
for role in [primary] + supports:
    if role and role not in roles:
        roles.append(role)
if role_filter:
    roles = [r for r in roles if r == role_filter]

machine_lines = []
for role in roles:
    brief_rel = (dispatch_dir / f"{role}-brief.md").relative_to(repo_root)
    print(f"  # @{role}")
    prompt = f"Bạn là @{role}. Đọc brief tại {brief_rel} và thực hiện đúng yêu cầu."
    trust_part = f"{trust_flag} " if trust_flag else ""
    role_chat = (role_sessions.get("roles", {}) or {}).get(role, {}).get("chat_id", "")
    if role_chat:
        cmd = f'agent {trust_part}--workspace "{repo_root}" --resume "{role_chat}" "{prompt}"'
    else:
        cmd = f'agent {trust_part}--workspace "{repo_root}" "{prompt}"'
    print(f"  {cmd}")
    machine_lines.append(f"{role}|{cmd}")
    print()

commands_file.write_text("\n".join(machine_lines) + ("\n" if machine_lines else ""), encoding="utf-8")
PY

  if [[ -n "$role_filter" && ! -s "$commands_file" ]]; then
    echo -e "${YELLOW}Không tìm thấy role '$role_filter' trong step $step.${NC}\n"
    exit 1
  fi

  if [[ "$headless" == "true" ]]; then
    local logs_dir="$dispatch_dir/logs"
    wf_ensure_dir "$logs_dir"
    local launched=0
    local skipped=0
    while IFS='|' read -r role cmd; do
      [[ -z "$role" || -z "$cmd" ]] && continue
      local report_path="$reports_dir/${role}-report.md"
      local log_path="$logs_dir/${role}.log"
      local capture_script="$REPO_ROOT/scripts/workflow/lib/stream_json_capture.py"
      local correlation_id="${workflow_id}/${run_id}/${step}/${role}"
      local role_chat_id
      role_chat_id=$(WF_ROLE_SESSIONS_FILE="$ROLE_SESSIONS_FILE" WF_ROLE="$role" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["WF_ROLE_SESSIONS_FILE"])
role = os.environ["WF_ROLE"]
if not path.exists():
    print("")
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
print((data.get("roles", {}) or {}).get(role, {}).get("chat_id", ""))
PY
)
      if [[ -z "$role_chat_id" && "$dry_run" != "true" ]]; then
        local new_chat
        new_chat=$(agent --workspace "$REPO_ROOT" create-chat 2>/dev/null | python3 -c 'import re,sys; t=sys.stdin.read(); c=re.findall(r"[a-f0-9]{8}-[a-f0-9-]{20,}", t, flags=re.I); lines=[ln.strip() for ln in t.splitlines() if ln.strip()]; print(c[-1] if c else (lines[-1] if lines else ""))')
        if [[ "$new_chat" =~ ^[A-Za-z0-9-]{8,}$ ]]; then
          role_chat_id="$new_chat"
          WF_ROLE_SESSIONS_FILE="$ROLE_SESSIONS_FILE" WF_ROLE="$role" WF_CHAT_ID="$role_chat_id" WF_STEP="$step" python3 - <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path

path = Path(os.environ["WF_ROLE_SESSIONS_FILE"])
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
roles = data.setdefault("roles", {})
roles[os.environ["WF_ROLE"]] = {
    "chat_id": os.environ["WF_CHAT_ID"],
    "last_step": int(os.environ["WF_STEP"]),
    "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
}
path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
PY
          echo -e "${CYAN}[session] created role chat for @${role}:${NC} ${role_chat_id}"
        else
          echo -e "${YELLOW}[session] could not create chat for @${role}, fallback to one-shot command.${NC}"
        fi
      fi
      local base_cmd="$cmd"
      if [[ -n "$role_chat_id" ]]; then
        local trust_part=""
        [[ "$trust_workspace" == "true" ]] && trust_part="--trust "
        base_cmd="agent ${trust_part}--workspace \"$REPO_ROOT\" --resume \"$role_chat_id\""
      fi
      local headless_cmd
      headless_cmd="${base_cmd} -p \"Thực hiện task theo brief, và GHI report đầy đủ vào file ${report_path}. Chỉ trả lời ngắn 'done' sau khi ghi file.\" --output-format stream-json --stream-partial-output 2>&1 | python3 \"${capture_script}\" --step \"${step}\" --role \"${role}\" --workflow-id \"${workflow_id}\" --run-id \"${run_id}\" --log-path \"${log_path}\" --heartbeats-path \"${HEARTBEATS_FILE}\""
      local idem_key="step:${step}:role:${role}:mode:headless"
      local idem_decision
      idem_decision=$(WF_IDEMPOTENCY_FILE="$IDEMPOTENCY_FILE" WF_IDEMPOTENCY_KEY="$idem_key" WF_FORCE_RUN="$force_run" WF_MAX_RETRIES="$max_retries" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["WF_IDEMPOTENCY_FILE"])
key = os.environ["WF_IDEMPOTENCY_KEY"]
force_run = os.environ.get("WF_FORCE_RUN", "false").lower() == "true"
max_retries = int(os.environ.get("WF_MAX_RETRIES", "3"))
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
entry = data.get(key, {})
status = entry.get("status", "")
pid = entry.get("pid")
attempt_count = int((entry.get("retry_policy") or {}).get("attempt_count", 0))
running = False
if isinstance(pid, int) and pid > 0:
    try:
        os.kill(pid, 0)
        running = True
    except OSError:
        running = False

if force_run:
    print(f"LAUNCH|force-run enabled|prev_status={status or 'none'}")
elif status == "launched" and running:
    print(f"SKIP|already launched with running pid={pid}")
elif status == "completed":
    print("SKIP|already completed; use --force-run to rerun")
elif attempt_count >= max_retries:
    print(f"SKIP|retry budget exhausted ({attempt_count}/{max_retries}); use --force-run")
else:
    reason = "first launch" if not status else f"resume from status={status}"
    print(f"LAUNCH|{reason}")
PY
)
      if [[ "${idem_decision%%|*}" == "SKIP" ]]; then
        echo -e "${YELLOW}[idempotency] skip @${role}:${NC} ${idem_decision#SKIP|}"
        skipped=$((skipped + 1))
        continue
      fi
      if [[ "$dry_run" == "true" ]]; then
        echo -e "${CYAN}[dry-run] would run headless @${role}:${NC} ${headless_cmd}"
        launched=$((launched + 1))
        continue
      fi
      nohup bash -lc "$headless_cmd" >/dev/null 2>&1 &
      local worker_pid=$!
      WF_IDEMPOTENCY_FILE="$IDEMPOTENCY_FILE" WF_IDEMPOTENCY_KEY="$idem_key" WF_STEP="$step" WF_ROLE="$role" WF_PID="$worker_pid" WF_LOG="$log_path" WF_REPORT="$report_path" WF_WORKFLOW_ID="$workflow_id" WF_RUN_ID="$run_id" WF_CORRELATION_ID="$correlation_id" WF_MAX_RETRIES="$max_retries" python3 - <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path

path = Path(os.environ["WF_IDEMPOTENCY_FILE"])
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
key = os.environ["WF_IDEMPOTENCY_KEY"]
prev = data.get(key, {})
prev_retry = prev.get("retry_policy") or {}
attempt_count = int(prev_retry.get("attempt_count", 0)) + 1
max_retries = int(os.environ.get("WF_MAX_RETRIES", "3"))
data[key] = {
    "status": "launched",
    "step": int(os.environ["WF_STEP"]),
    "role": os.environ["WF_ROLE"],
    "workflow_id": os.environ["WF_WORKFLOW_ID"],
    "run_id": os.environ["WF_RUN_ID"],
    "correlation_id": os.environ["WF_CORRELATION_ID"],
    "pid": int(os.environ["WF_PID"]),
    "log_path": os.environ["WF_LOG"],
    "report_path": os.environ["WF_REPORT"],
    "retry_policy": {
        "attempt_count": attempt_count,
        "max_retries": max_retries,
        "last_launch_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "last_failure_class": "",
    },
    "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
}
path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
PY
      launched=$((launched + 1))
    done < "$commands_file"

    if [[ "$dry_run" == "true" ]]; then
      echo -e "\n${GREEN}${BOLD}Dry-run headless dispatch complete.${NC} launch_candidates=${launched}, skipped=${skipped}"
    else
      echo -e "\n${GREEN}${BOLD}Headless dispatch complete.${NC} launched=${launched}, skipped=${skipped}"
      echo -e "Logs: ${BOLD}${logs_dir#$REPO_ROOT/}${NC}"
      echo -e "Reports target: ${BOLD}${reports_dir#$REPO_ROOT/}${NC}"
    fi
  elif [[ "$auto_launch" == "true" ]]; then
    if [[ "$(uname -s)" != "Darwin" ]]; then
      echo -e "${YELLOW}--launch hiện chỉ hỗ trợ macOS (Terminal + osascript).${NC}"
      echo -e "Chạy thủ công theo lệnh ở trên.\n"
    elif ! command -v osascript >/dev/null 2>&1; then
      echo -e "${YELLOW}Không tìm thấy osascript, không thể auto-launch.${NC}"
      echo -e "Chạy thủ công theo lệnh ở trên.\n"
    else
      local launched=0
      while IFS='|' read -r role cmd; do
        [[ -z "$role" || -z "$cmd" ]] && continue
        if [[ "$dry_run" == "true" ]]; then
          echo -e "${CYAN}[dry-run] would launch @${role}:${NC} $cmd"
          launched=$((launched + 1))
          continue
        fi
        local as_cmd="$cmd"
        as_cmd="${as_cmd//\\/\\\\}"
        as_cmd="${as_cmd//\"/\\\"}"
        osascript -e "tell application \"Terminal\" to activate" \
                  -e "tell application \"Terminal\" to do script \"${as_cmd}\"" >/dev/null
        launched=$((launched + 1))
      done < "$commands_file"
      if [[ "$dry_run" == "true" ]]; then
        echo -e "\n${GREEN}${BOLD}Dry-run launch complete.${NC} total_sessions=${launched}"
      else
        echo -e "\n${GREEN}${BOLD}Auto-launch complete.${NC} total_sessions=${launched}"
      fi
    fi
  fi

  echo -e "Sau khi workers xong, chạy: ${BOLD}bash scripts/workflow.sh collect${NC}\n"
}

cmd_collect() {
  local step
  step=$(wf_require_initialized_workflow)

  local reports_dir="$REPO_ROOT/workflows/dispatch/step-$step/reports"
  if [[ ! -d "$reports_dir" ]]; then
    echo -e "${YELLOW}Chưa có thư mục reports: ${reports_dir#$REPO_ROOT/}${NC}"
    echo -e "Chạy ${BOLD}bash scripts/workflow.sh dispatch${NC} trước.\n"
    exit 1
  fi

  local collect_raw
  collect_raw=$(python3 - <<PY
import json
from datetime import datetime
from pathlib import Path

state_path = Path("$STATE_FILE")
repo_root = Path("$REPO_ROOT")
step = str($step)
reports_dir = Path("$reports_dir")
report_files = sorted(reports_dir.glob("*-report.md"))

if not report_files:
    print("NO_REPORTS")
    raise SystemExit(0)

data = json.loads(state_path.read_text(encoding="utf-8"))
step_obj = data["steps"][step]
deliverables = step_obj.setdefault("deliverables", [])
decisions = step_obj.setdefault("decisions", [])
blockers = step_obj.setdefault("blockers", [])

def has_deliverable(target: str) -> bool:
    return any(target in d for d in deliverables)

def has_decision(source: str, description: str) -> bool:
    for d in decisions:
        if d.get("source") == source and d.get("description") == description:
            return True
    return False

def has_blocker(source: str, description: str) -> bool:
    for b in blockers:
        if b.get("source") == source and b.get("description") == description and not b.get("resolved"):
            return True
    return False

new_decisions = 0
new_blockers = 0
new_deliverables = 0

for rf in report_files:
    rel = str(rf.relative_to(repo_root))
    if not has_deliverable(rel):
        deliverables.append(f"{rel} — Worker report")
        new_deliverables += 1

    for line in rf.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("DECISION:"):
            desc = s[len("DECISION:"):].strip()
            if desc:
                if not has_decision(rel, desc):
                    decisions.append({
                        "id": f"D{datetime.now().strftime('%Y%m%d%H%M%S%f')}",
                        "description": desc,
                        "date": datetime.now().strftime("%Y-%m-%d"),
                        "source": rel,
                    })
                    new_decisions += 1
        elif s.startswith("BLOCKER:"):
            desc = s[len("BLOCKER:"):].strip()
            if desc:
                if not has_blocker(rel, desc):
                    blockers.append({
                        "id": f"B{datetime.now().strftime('%Y%m%d%H%M%S%f')}",
                        "description": desc,
                        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                        "resolved": False,
                        "source": rel,
                    })
                    new_blockers += 1
        elif s.startswith("DELIVERABLE:"):
            item = s[len("DELIVERABLE:"):].strip()
            if item and not has_deliverable(item):
                deliverables.append(item)
                new_deliverables += 1

data["metrics"]["total_decisions"] = max(data["metrics"].get("total_decisions", 0), 0) + new_decisions
data["metrics"]["total_blockers"] = max(data["metrics"].get("total_blockers", 0), 0) + new_blockers
data["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

state_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

idempotency_path = repo_root / "workflows" / "runtime" / "idempotency.json"
if idempotency_path.exists():
    idempotency = json.loads(idempotency_path.read_text(encoding="utf-8"))
    for rf in report_files:
        role = rf.name.replace("-report.md", "")
        key = f"step:{step}:role:{role}:mode:headless"
        if key in idempotency:
            idempotency[key]["status"] = "completed"
            idempotency[key]["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    idempotency_path.write_text(json.dumps(idempotency, indent=2, ensure_ascii=False), encoding="utf-8")

print(f"COLLECTED reports={len(report_files)} deliverables+={new_deliverables} decisions+={new_decisions} blockers+={new_blockers}")
PY
)
  local collect_status="$?"
  if [[ "$collect_status" -ne 0 ]]; then
    echo -e "${RED}Collect thất bại.${NC}\n"
    exit 1
  fi

  if [[ "$collect_raw" == "NO_REPORTS" ]]; then
    echo -e "${YELLOW}Chưa có worker report nào trong ${reports_dir#$REPO_ROOT/}.${NC}"
    echo -e "Mẫu report: ${BOLD}workflows/templates/agent-dispatch-template.md${NC}\n"
    exit 0
  fi

  local collect_output
  collect_output=$(python3 - <<PY
import json
from pathlib import Path
state = json.loads(Path("$STATE_FILE").read_text(encoding="utf-8"))
step = str($step)
s = state["steps"][step]
print(f"Step {step}: deliverables={len(s.get('deliverables', []))}, decisions={len(s.get('decisions', []))}, blockers={len(s.get('blockers', []))}")
PY
)

  echo -e "\n${GREEN}${BOLD}Collect hoàn tất.${NC}"
  echo -e "${collect_output}"
  echo -e "Kiểm tra nhanh: ${BOLD}bash scripts/workflow.sh summary${NC}\n"
}
