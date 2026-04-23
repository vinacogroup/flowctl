#!/usr/bin/env bash
# ============================================================
# IT Product Team Workflow — CLI Manager
# Quản lý workflow state, approvals, và transitions
#
# Usage:
#   bash scripts/workflow.sh <command> [args]
#
# Commands:
#   init --project "Name"    Khởi tạo workflow cho project mới
#   status                   Xem trạng thái hiện tại
#   start                    Bắt đầu step hiện tại
#   approve [--by "Name"]    Approve step hiện tại → advance
#   reject "reason"          Reject step với lý do
#   conditional "items"      Approve có điều kiện
#   blocker add "desc"       Thêm blocker
#   blocker resolve <id>     Resolve blocker
#   decision "desc"          Ghi nhận quyết định
#   dispatch [--launch|--headless] [--trust] [--dry-run]
#                            Tạo briefs; launch UI hoặc chạy headless nền
#   collect                  Gom worker reports vào workflow-state
#   team <start|sync|status|run>
#                            PM-only orchestration: dispatch/collect/summary
#   summary                  In summary của step hiện tại
#   reset <step>             Reset về step cụ thể (cần confirm)
#   history                  Lịch sử approvals
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/workflow-state.json"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ── JSON helpers (dùng python3 nếu jq không có) ─────────────
json_get() {
  python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
keys = '$1'.split('.')
val = data
for k in keys:
    val = val[k] if isinstance(val, dict) and k in val else None
print(val if val is not None else '')
" 2>/dev/null || echo ""
}

json_set() {
  # $1 = dot-path, $2 = value (string), $3 = type (string|number|null)
  python3 -c "
import json, sys
from datetime import datetime

with open('$STATE_FILE', 'r') as f:
    data = json.load(f)

keys = '$1'.split('.')
obj = data
for k in keys[:-1]:
    obj = obj.setdefault(k, {})

val = '$2'
typ = '${3:-string}'
if typ == 'number':
    obj[keys[-1]] = int(val)
elif typ == 'null' or val == 'null':
    obj[keys[-1]] = None
elif typ == 'bool':
    obj[keys[-1]] = val.lower() == 'true'
else:
    obj[keys[-1]] = val

data['updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
}

json_append() {
  # $1 = dot-path to array, $2 = JSON object string
  python3 -c "
import json
from datetime import datetime

with open('$STATE_FILE', 'r') as f:
    data = json.load(f)

keys = '$1'.split('.')
obj = data
for k in keys[:-1]:
    obj = obj[k]

arr = obj.setdefault(keys[-1], [])
arr.append(json.loads('''$2'''))

data['updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
}

now() { date '+%Y-%m-%d %H:%M:%S'; }
today() { date '+%Y-%m-%d'; }

ensure_dir() { mkdir -p "$1"; }

# ── Commands ─────────────────────────────────────────────────

cmd_init() {
  local project_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) project_name="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$project_name" ]] && {
    echo -n "Tên dự án: "; read -r project_name
  }

  python3 -c "
import json
from datetime import datetime

with open('$STATE_FILE', 'r') as f:
    data = json.load(f)

data['project_name'] = '$project_name'
data['created_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
data['updated_at'] = data['created_at']
data['current_step'] = 1
data['overall_status'] = 'in_progress'
data['steps']['1']['status'] = 'pending'

with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"

  echo -e "\n${GREEN}${BOLD}Project \"$project_name\" đã được khởi tạo!${NC}"
  echo -e "${CYAN}Step hiện tại: 1 — Requirements Analysis${NC}"
  echo -e "Agent cần dùng: ${YELLOW}@pm${NC} (hỗ trợ: @tech-lead)"
  echo -e "\nBắt đầu bằng: ${BOLD}bash scripts/workflow.sh start${NC}\n"
}

cmd_status() {
  [[ ! -f "$STATE_FILE" ]] && { echo "workflow-state.json không tìm thấy. Chạy: bash setup.sh"; exit 1; }

  local step overall project
  step=$(json_get "current_step")
  overall=$(json_get "overall_status")
  project=$(json_get "project_name")

  echo -e "\n${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}${BOLD}   Workflow Status${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  [[ -n "$project" ]] && echo -e "  Project: ${BOLD}$project${NC}"
  echo -e "  Status:  ${YELLOW}$overall${NC}"
  echo ""

  # In tất cả steps
  python3 -c "
import json

with open('$STATE_FILE') as f:
    data = json.load(f)

current = data.get('current_step', 0)
steps = data.get('steps', {})

icons = {
    'completed': '\033[0;32m✓\033[0m',
    'in_progress': '\033[1;33m→\033[0m',
    'approved': '\033[0;32m✓\033[0m',
    'pending': '\033[0;90m○\033[0m',
    'rejected': '\033[0;31m✗\033[0m',
}

for n in range(1, 10):
    s = steps.get(str(n), {})
    name = s.get('name', '')
    status = s.get('status', 'pending')
    agent = s.get('agent', '')
    icon = icons.get(status, '○')

    prefix = '  '
    if n == current:
        prefix = '\033[1m→ \033[0m'

    approval = ''
    if s.get('approval_status'):
        approval = f\" [{s['approval_status'].upper()}]\"

    print(f'{prefix}{icon} Step {n}: {name} (@{agent}){approval}')
"

  echo ""

  # Blockers
  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)
step = str(data.get('current_step', 1))
blockers = data.get('steps', {}).get(step, {}).get('blockers', [])
open_blockers = [b for b in blockers if not b.get('resolved')]
if open_blockers:
    print(f'\033[0;31m  Blockers ({len(open_blockers)}):\033[0m')
    for i, b in enumerate(open_blockers):
        print(f'    [{i}] {b.get(\"description\", \"\")}')
    print()
"

  echo -e "  Dùng ${CYAN}bash scripts/workflow.sh approve${NC} sau khi step hoàn thành\n"
}

cmd_start() {
  local step
  step=$(json_get "current_step")
  [[ -z "$step" || "$step" == "0" ]] && {
    echo -e "${YELLOW}Workflow chưa được khởi tạo. Chạy: bash scripts/workflow.sh init${NC}"
    exit 1
  }

  json_set "steps.$step.status" "in_progress"
  json_set "steps.$step.started_at" "$(now)"

  local name agent
  name=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$step']['name'])")
  agent=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$step']['agent'])")

  echo -e "\n${GREEN}${BOLD}Step $step — $name đã bắt đầu${NC}"
  echo -e "Agent chính: ${YELLOW}@$agent${NC}"
  echo -e "\nKhởi động Graphify context:"
  echo -e "  ${CYAN}graphify_query(\"step:$step:context\")${NC}"
  echo -e "  ${CYAN}gitnexus_get_architecture()${NC}"
  echo -e "\nXem agent guide: ${BOLD}.cursor/agents/${agent}-agent.md${NC}\n"
}

cmd_approve() {
  local by="${2:-Human}"
  local step
  step=$(json_get "current_step")
  local name
  name=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$step']['name'])")

  json_set "steps.$step.status" "completed"
  json_set "steps.$step.approval_status" "approved"
  json_set "steps.$step.completed_at" "$(now)"
  json_set "steps.$step.approved_at" "$(now)"
  json_set "steps.$step.approved_by" "$by"

  # Advance to next step
  local next_step=$((step + 1))
  if [[ $next_step -le 9 ]]; then
    json_set "current_step" "$next_step" "number"
    local next_name next_agent
    next_name=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$next_step']['name'])")
    next_agent=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$next_step']['agent'])")

    echo -e "\n${GREEN}${BOLD}✓ Step $step — $name: APPROVED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "\n${CYAN}${BOLD}→ Tiếp theo: Step $next_step — $next_name${NC}"
    echo -e "Agent: ${YELLOW}@$next_agent${NC}"
    echo -e "Bắt đầu: ${BOLD}bash scripts/workflow.sh start${NC}\n"
  else
    json_set "overall_status" "completed"
    echo -e "\n${GREEN}${BOLD}🎉 WORKFLOW HOÀN THÀNH! Project đã release.${NC}\n"
  fi
}

cmd_reject() {
  local reason="${2:-Không có lý do}"
  local step
  step=$(json_get "current_step")
  local name
  name=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps']['$step']['name'])")

  json_set "steps.$step.approval_status" "rejected"
  json_set "steps.$step.status" "in_progress"

  # Append rejection note
  json_append "steps.$step.decisions" "{\"type\": \"rejection\", \"reason\": \"$reason\", \"date\": \"$(today)\"}"

  echo -e "\n${RED}${BOLD}✗ Step $step — $name: REJECTED${NC}"
  echo -e "Lý do: $reason"
  echo -e "\nAddress concerns rồi chạy lại: ${BOLD}bash scripts/workflow.sh approve${NC}\n"
}

cmd_add_blocker() {
  local desc="${2:-}"
  [[ -z "$desc" ]] && { echo -n "Mô tả blocker: "; read -r desc; }

  local step
  step=$(json_get "current_step")
  local id="B$(date +%Y%m%d%H%M%S)"

  json_append "steps.$step.blockers" "{\"id\": \"$id\", \"description\": \"$desc\", \"created_at\": \"$(now)\", \"resolved\": false}"

  # Update metrics
  python3 -c "
import json
with open('$STATE_FILE') as f: d = json.load(f)
d['metrics']['total_blockers'] = d['metrics'].get('total_blockers', 0) + 1
with open('$STATE_FILE', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
"

  echo -e "\n${YELLOW}Blocker đã được ghi nhận: [$id] $desc${NC}"
  echo -e "Resolve: ${BOLD}bash scripts/workflow.sh blocker resolve $id${NC}\n"
}

cmd_resolve_blocker() {
  local id="${2:-}"
  [[ -z "$id" ]] && { echo "Usage: blocker resolve <id>"; exit 1; }

  local step
  step=$(json_get "current_step")

  python3 -c "
import json
from datetime import datetime

with open('$STATE_FILE') as f:
    data = json.load(f)

step = str(data.get('current_step', 1))
blockers = data.get('steps', {}).get(step, {}).get('blockers', [])
for b in blockers:
    if b.get('id') == '$id':
        b['resolved'] = True
        b['resolved_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print('Blocker $id đã được resolved')
"
}

cmd_add_decision() {
  local desc="${2:-}"
  [[ -z "$desc" ]] && { echo -n "Quyết định: "; read -r desc; }

  local step
  step=$(json_get "current_step")
  local id="D$(date +%Y%m%d%H%M%S)"

  json_append "steps.$step.decisions" "{\"id\": \"$id\", \"description\": \"$desc\", \"date\": \"$(today)\"}"

  python3 -c "
import json
with open('$STATE_FILE') as f: d = json.load(f)
d['metrics']['total_decisions'] = d['metrics'].get('total_decisions', 0) + 1
with open('$STATE_FILE', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
"

  echo -e "${GREEN}Quyết định đã được ghi nhận: [$id]${NC}\n"
}

cmd_dispatch() {
  local auto_launch="false"
  local headless="false"
  local trust_workspace="false"
  local dry_run="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --launch) auto_launch="true" ;;
      --headless) headless="true" ;;
      --trust) trust_workspace="true" ;;
      --dry-run) dry_run="true" ;;
      *)
        echo -e "${RED}Unknown option for dispatch: $1${NC}"
        echo -e "Usage: bash scripts/workflow.sh dispatch [--launch|--headless] [--trust] [--dry-run]\n"
        exit 1
        ;;
    esac
    shift
  done

  if [[ "$auto_launch" == "true" && "$headless" == "true" ]]; then
    echo -e "${RED}Không thể dùng đồng thời --launch và --headless.${NC}"
    echo -e "Chọn một mode chạy worker.\n"
    exit 1
  fi

  local step
  step=$(json_get "current_step")
  [[ -z "$step" || "$step" == "0" ]] && {
    echo -e "${YELLOW}Workflow chưa được khởi tạo. Chạy: bash scripts/workflow.sh init${NC}"
    exit 1
  }

  local dispatch_dir="$REPO_ROOT/workflows/dispatch/step-$step"
  local reports_dir="$dispatch_dir/reports"
  ensure_dir "$dispatch_dir"
  ensure_dir "$reports_dir"

  WF_STEP="$step" WF_STATE="$STATE_FILE" WF_REPO="$REPO_ROOT" WF_DISPATCH="$dispatch_dir" WF_REPORTS="$reports_dir" python3 - <<'PY'
import json
import os
from pathlib import Path

state_path = Path(os.environ["WF_STATE"])
repo_root = Path(os.environ["WF_REPO"])
step = str(os.environ["WF_STEP"])
dispatch_dir = Path(os.environ["WF_DISPATCH"])
reports_dir = Path(os.environ["WF_REPORTS"])

data = json.loads(state_path.read_text(encoding="utf-8"))
s = data["steps"][step]

primary = s.get("agent", "").strip()
supports = [a.strip() for a in s.get("support_agents", []) if a and a.strip()]
roles = []
for role in [primary] + supports:
    if role and role not in roles:
        roles.append(role)

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
  echo -e "Dùng các lệnh sau để chạy worker sessions song song:\n"

  local commands_file="$dispatch_dir/agent-commands.txt"
  local trust_flag=""
  [[ "$trust_workspace" == "true" ]] && trust_flag="--trust"
  WF_STEP="$step" WF_STATE="$STATE_FILE" WF_REPO="$REPO_ROOT" WF_DISPATCH="$dispatch_dir" WF_COMMANDS="$commands_file" WF_TRUST="$trust_flag" python3 - <<'PY'
import json
import os
from pathlib import Path

state_path = Path(os.environ["WF_STATE"])
repo_root = Path(os.environ["WF_REPO"])
step = str(os.environ["WF_STEP"])
dispatch_dir = Path(os.environ["WF_DISPATCH"])
commands_file = Path(os.environ["WF_COMMANDS"])
trust_flag = os.environ.get("WF_TRUST", "").strip()

data = json.loads(state_path.read_text(encoding="utf-8"))
s = data["steps"][step]
primary = s.get("agent", "").strip()
supports = [a.strip() for a in s.get("support_agents", []) if a and a.strip()]
roles = []
for role in [primary] + supports:
    if role and role not in roles:
        roles.append(role)

machine_lines = []
for role in roles:
    brief_rel = (dispatch_dir / f"{role}-brief.md").relative_to(repo_root)
    print(f"  # @{role}")
    prompt = f"Bạn là @{role}. Đọc brief tại {brief_rel} và thực hiện đúng yêu cầu."
    trust_part = f"{trust_flag} " if trust_flag else ""
    cmd = f'agent {trust_part}--workspace "{repo_root}" "{prompt}"'
    print(f"  {cmd}")
    machine_lines.append(f"{role}|{cmd}")
    print()

commands_file.write_text("\n".join(machine_lines) + ("\n" if machine_lines else ""), encoding="utf-8")
PY

  if [[ "$headless" == "true" ]]; then
    local logs_dir="$dispatch_dir/logs"
    ensure_dir "$logs_dir"
    local launched=0
    while IFS='|' read -r role cmd; do
      [[ -z "$role" || -z "$cmd" ]] && continue
      local report_path="$reports_dir/${role}-report.md"
      local log_path="$logs_dir/${role}.log"
      local headless_cmd
      headless_cmd="${cmd} -p \"Thực hiện task theo brief, và GHI report đầy đủ vào file ${report_path}. Chỉ trả lời ngắn 'done' sau khi ghi file.\" --output-format text > \"${log_path}\" 2>&1"
      if [[ "$dry_run" == "true" ]]; then
        echo -e "${CYAN}[dry-run] would run headless @${role}:${NC} ${headless_cmd}"
        launched=$((launched + 1))
        continue
      fi
      nohup bash -lc "$headless_cmd" >/dev/null 2>&1 &
      launched=$((launched + 1))
    done < "$commands_file"

    if [[ "$dry_run" == "true" ]]; then
      echo -e "\n${GREEN}${BOLD}Dry-run headless dispatch complete.${NC} total_sessions=${launched}"
    else
      echo -e "\n${GREEN}${BOLD}Headless dispatch complete.${NC} total_sessions=${launched}"
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
  step=$(json_get "current_step")
  [[ -z "$step" || "$step" == "0" ]] && {
    echo -e "${YELLOW}Workflow chưa được khởi tạo. Chạy: bash scripts/workflow.sh init${NC}"
    exit 1
  }

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

cmd_team() {
  local action="${1:-status}"
  shift || true

  local step
  step=$(json_get "current_step")
  local dispatch_dir="$REPO_ROOT/workflows/dispatch/step-$step"
  local reports_dir="$dispatch_dir/reports"
  local logs_dir="$dispatch_dir/logs"

  case "$action" in
    start)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM orchestration start${NC}"
      echo -e "Dispatch workers headless + trust workspace..."
      cmd_dispatch --headless --trust "$@"
      ;;
    sync)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM sync${NC}"
      cmd_collect
      cmd_summary
      ;;
    status)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM status${NC}"
      cmd_summary
      echo -e "Dispatch dir: ${BOLD}${dispatch_dir#$REPO_ROOT/}${NC}"
      local report_count log_count
      report_count=$(find "$reports_dir" -maxdepth 1 -type f -name "*-report.md" 2>/dev/null | wc -l | tr -d ' ')
      log_count=$(find "$logs_dir" -maxdepth 1 -type f -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
      echo -e "Reports: ${report_count:-0}"
      echo -e "Logs: ${log_count:-0}"
      echo ""
      ;;
    run)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM run loop (single cycle)${NC}"
      cmd_dispatch --headless --trust "$@"
      echo -e "${YELLOW}Workers đang chạy nền. Sau khi đủ thời gian xử lý, chạy:${NC}"
      echo -e "  ${BOLD}bash scripts/workflow.sh team sync${NC}\n"
      ;;
    *)
      echo -e "${RED}Unknown team action: $action${NC}"
      echo -e "Usage: bash scripts/workflow.sh team <start|sync|status|run>\n"
      exit 1
      ;;
  esac
}

cmd_summary() {
  local step
  step=$(json_get "current_step")

  python3 -c "
import json

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
import json

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

cmd_reset() {
  local target="${2:-}"
  [[ -z "$target" ]] && { echo "Usage: reset <step_number>"; exit 1; }

  echo -e "${RED}${BOLD}CẢNH BÁO: Reset workflow về Step $target.${NC}"
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

# ── Main dispatcher ──────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  init)         cmd_init "$@" ;;
  status|s)     cmd_status ;;
  start)        cmd_start ;;
  approve|a)    cmd_approve "$@" ;;
  reject|r)     cmd_reject "$@" ;;
  conditional)  cmd_reject "$@" ;;
  blocker)
    SUBCMD="${1:-}"; shift || true
    case "$SUBCMD" in
      add)     cmd_add_blocker "$@" ;;
      resolve) cmd_resolve_blocker "$@" ;;
      *)       echo "Usage: blocker [add|resolve]" ;;
    esac
    ;;
  decision|d)   cmd_add_decision "$@" ;;
  dispatch)     cmd_dispatch "$@" ;;
  collect)      cmd_collect ;;
  team)         cmd_team "$@" ;;
  summary|sum)  cmd_summary ;;
  history|h)    cmd_history ;;
  reset)        cmd_reset "$@" ;;
  help|--help|-h)
    echo -e "\n${BOLD}IT Product Workflow CLI${NC}"
    echo -e "  init --project \"Name\"  Khởi tạo dự án mới"
    echo -e "  status                 Xem trạng thái"
    echo -e "  start                  Bắt đầu step hiện tại"
    echo -e "  approve [--by Name]    Approve và advance"
    echo -e "  reject \"reason\"        Reject với lý do"
    echo -e "  blocker add \"desc\"     Thêm blocker"
    echo -e "  blocker resolve <id>   Resolve blocker"
    echo -e "  decision \"desc\"        Ghi nhận quyết định"
    echo -e "  dispatch [--launch|--headless] [--trust] [--dry-run]"
    echo -e "                         Tạo worker briefs + chạy workers"
    echo -e "  collect                Gom worker reports vào workflow-state"
    echo -e "  team <start|sync|status|run>"
    echo -e "                         PM-only orchestration cho sub-agents"
    echo -e "  summary                Step summary"
    echo -e "  history                Lịch sử approvals"
    echo -e "  reset <step>           Reset về step cụ thể\n"
    ;;
  *)
    echo "Unknown command: $CMD. Dùng --help để xem danh sách lệnh."
    exit 1
    ;;
esac
