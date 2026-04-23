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
#   gate-check               Kiểm tra QA gate cho step hiện tại
#   reject "reason"          Reject step với lý do
#   conditional "items"      Approve có điều kiện
#   blocker add "desc"       Thêm blocker
#   blocker resolve <id>     Resolve blocker
#   decision "desc"          Ghi nhận quyết định
#   dispatch [--launch|--headless] [--trust] [--dry-run] [--force-run] [--max-retries N] [--role name] [--budget-override-reason text]
#                            Tạo briefs; launch UI hoặc chạy headless nền
#   collect                  Gom worker reports vào workflow-state
#   team <start|delegate|sync|status|monitor|recover|budget-reset|run>
#                            PM-only orchestration: step-based spawn/collect/summary
#   brainstorm [topic]       One-shot: init (if needed) + step-based delegate
#   summary                  In summary của step hiện tại
#   release-dashboard        PM release summary cho approve decision
#   reset <step>             Reset về step cụ thể (cần confirm)
#   history                  Lịch sử approvals
# ============================================================

set -euo pipefail

WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Library modules ───────────────────────────────────────────
LIB_DIR="$WORKFLOW_ROOT/scripts/workflow/lib"
# shellcheck source=/dev/null
source "$LIB_DIR/config.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/state.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/evidence.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/traceability.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/lock.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/gate.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/budget.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/dispatch.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/orchestration.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/reporting.sh"

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
  step=$(wf_json_get "current_step")
  overall=$(wf_json_get "overall_status")
  project=$(wf_json_get "project_name")

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
  step=$(wf_require_initialized_workflow)

  wf_json_set "steps.$step.status" "in_progress"
  wf_json_set "steps.$step.started_at" "$(wf_now)"

  local name agent
  name=$(wf_get_step_name "$step")
  agent=$(wf_get_step_agent "$step")

  echo -e "\n${GREEN}${BOLD}Step $step — $name đã bắt đầu${NC}"
  echo -e "Agent chính: ${YELLOW}@$agent${NC}"
  echo -e "\nKhởi động Graphify context:"
  echo -e "  ${CYAN}graphify_query(\"step:$step:context\")${NC}"
  echo -e "  ${CYAN}gitnexus_get_architecture()${NC}"
  echo -e "\nXem agent guide: ${BOLD}.cursor/agents/${agent}-agent.md${NC}\n"
}

cmd_approve() {
  local by="Human"
  local skip_gate="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by)
        if [[ $# -lt 2 ]]; then
          echo -e "${RED}Thiếu giá trị cho --by${NC}"
          exit 1
        fi
        by="$2"
        shift 2
        ;;
      --skip-gate) skip_gate="true"; shift ;;
      *) shift ;;
    esac
  done
  local step
  step=$(wf_require_initialized_workflow)
  if [[ "$skip_gate" != "true" ]]; then
    local gate_result
    if ! gate_result=$(wf_evaluate_gate "$step"); then
      wf_write_gate_report "$step" "FAIL" "${gate_result#GATE_FAIL|}" "$by"
      echo -e "\n${RED}${BOLD}✗ APPROVE BLOCKED BY QA GATE${NC}"
      echo -e "${RED}${gate_result#GATE_FAIL|}${NC}"
      echo -e "\nChạy kiểm tra: ${BOLD}bash scripts/workflow.sh gate-check${NC}"
      echo -e "Hoặc bypass có chủ đích: ${BOLD}bash scripts/workflow.sh approve --skip-gate --by \"Name\"${NC}\n"
      exit 1
    fi
    wf_write_gate_report "$step" "PASS" "${gate_result#GATE_OK|}" "$by"
    echo -e "${GREEN}QA Gate passed:${NC} ${gate_result#GATE_OK|}"
  else
    wf_write_gate_report "$step" "BYPASS" "approve --skip-gate was used" "$by"
  fi
  local name
  name=$(wf_get_step_name "$step")

  wf_json_set "steps.$step.status" "completed"
  wf_json_set "steps.$step.approval_status" "approved"
  wf_json_set "steps.$step.completed_at" "$(wf_now)"
  wf_json_set "steps.$step.approved_at" "$(wf_now)"
  wf_json_set "steps.$step.approved_by" "$by"

  # Advance to next step
  local next_step=$((step + 1))
  if [[ $next_step -le 9 ]]; then
    wf_json_set "current_step" "$next_step" "number"
    local next_name next_agent
    next_name=$(wf_get_step_name "$next_step")
    next_agent=$(wf_get_step_agent "$next_step")

    echo -e "\n${GREEN}${BOLD}✓ Step $step — $name: APPROVED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "\n${CYAN}${BOLD}→ Tiếp theo: Step $next_step — $next_name${NC}"
    echo -e "Agent: ${YELLOW}@$next_agent${NC}"
    echo -e "Bắt đầu: ${BOLD}bash scripts/workflow.sh start${NC}\n"
  else
    wf_json_set "overall_status" "completed"
    echo -e "\n${GREEN}${BOLD}🎉 WORKFLOW HOÀN THÀNH! Project đã release.${NC}\n"
  fi
  local manifest_rel="workflows/runtime/evidence/step-${step}-manifest.json"
  local trace_row
  trace_row=$(wf_traceability_record_approval "$step" "$by" "$([[ "$skip_gate" == "true" ]] && echo "bypass" || echo "approved")" "$manifest_rel" 2>/dev/null || true)
  if [[ -n "$trace_row" ]]; then
    local trace_event_id trace_payload trace_result
    trace_event_id=$(TRACE_ROW="$trace_row" python3 - <<'PY'
import json, os
row=json.loads(os.environ["TRACE_ROW"])
print(row.get("event_id",""))
PY
)
    trace_payload=$(TRACE_ROW="$trace_row" python3 - <<'PY'
import json, os
row=json.loads(os.environ["TRACE_ROW"])
print(json.dumps(row.get("payload", {}), ensure_ascii=False))
PY
)
    trace_result=$(wf_traceability_append_event "$trace_event_id" "approval" "$trace_payload" 2>/dev/null || true)
    [[ -n "$trace_result" ]] && echo -e "${CYAN}${trace_result}${NC}"
  fi
}

cmd_gate_check() {
  local step
  step=$(wf_require_initialized_workflow)
  local result
  if result=$(wf_evaluate_gate "$step"); then
    wf_write_gate_report "$step" "PASS" "${result#GATE_OK|}" "gate-check"
    echo -e "${GREEN}${BOLD}QA Gate: PASS${NC}"
    echo -e "${result#GATE_OK|}\n"
  else
    wf_write_gate_report "$step" "FAIL" "${result#GATE_FAIL|}" "gate-check"
    echo -e "${RED}${BOLD}QA Gate: FAIL${NC}"
    echo -e "${RED}${result#GATE_FAIL|}${NC}\n"
    exit 1
  fi
}

cmd_reject() {
  local reason="${1:-Không có lý do}"
  local step
  step=$(wf_require_initialized_workflow)
  local name
  name=$(wf_get_step_name "$step")

  wf_json_set "steps.$step.approval_status" "rejected"
  wf_json_set "steps.$step.status" "in_progress"

  # Append rejection note
  wf_json_append "steps.$step.decisions" "{\"type\": \"rejection\", \"reason\": \"$reason\", \"date\": \"$(wf_today)\"}"

  echo -e "\n${RED}${BOLD}✗ Step $step — $name: REJECTED${NC}"
  echo -e "Lý do: $reason"
  echo -e "\nAddress concerns rồi chạy lại: ${BOLD}bash scripts/workflow.sh approve${NC}\n"
}

cmd_add_blocker() {
  local desc="${1:-}"
  [[ -z "$desc" ]] && { echo -n "Mô tả blocker: "; read -r desc; }

  local step
  step=$(wf_require_initialized_workflow)
  local id="B$(date +%Y%m%d%H%M%S)"

  wf_json_append "steps.$step.blockers" "{\"id\": \"$id\", \"description\": \"$desc\", \"created_at\": \"$(wf_now)\", \"resolved\": false}"

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
  local id="${1:-}"
  [[ -z "$id" ]] && { echo "Usage: blocker resolve <id>"; exit 1; }

  local step
  step=$(wf_require_initialized_workflow)

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
  local desc="${1:-}"
  [[ -z "$desc" ]] && { echo -n "Quyết định: "; read -r desc; }

  local step
  step=$(wf_require_initialized_workflow)
  local id="D$(date +%Y%m%d%H%M%S)"

  wf_json_append "steps.$step.decisions" "{\"id\": \"$id\", \"description\": \"$desc\", \"date\": \"$(wf_today)\"}"

  python3 -c "
import json
with open('$STATE_FILE') as f: d = json.load(f)
d['metrics']['total_decisions'] = d['metrics'].get('total_decisions', 0) + 1
with open('$STATE_FILE', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
"

  echo -e "${GREEN}Quyết định đã được ghi nhận: [$id]${NC}\n"
}

# ── Main dispatcher ──────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  init|start|gate-check|approve|reject|conditional|blocker|decision|dispatch|collect|team|reset|brainstorm|release-dashboard)
    wf_acquire_workflow_lock
    ;;
  *)
    ;;
esac

case "$CMD" in
  init)         cmd_init "$@" ;;
  status|s)     cmd_status ;;
  start)        cmd_start ;;
  gate-check|gate) cmd_gate_check ;;
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
  brainstorm|bs) cmd_brainstorm "$@" ;;
  summary|sum)  cmd_summary ;;
  release-dashboard|dashboard) cmd_release_dashboard "$@" ;;
  history|h)    cmd_history ;;
  reset)        cmd_reset "$@" ;;
  help|--help|-h)
    echo -e "\n${BOLD}IT Product Workflow CLI${NC}"
    echo -e "  init --project \"Name\"  Khởi tạo dự án mới"
    echo -e "  status                 Xem trạng thái"
    echo -e "  start                  Bắt đầu step hiện tại"
    echo -e "  gate-check             Kiểm tra QA gate cho step hiện tại"
    echo -e "  approve [--by Name] [--skip-gate]"
    echo -e "                         Approve và advance (default có QA gate)"
    echo -e "  reject \"reason\"        Reject với lý do"
    echo -e "  blocker add \"desc\"     Thêm blocker"
    echo -e "  blocker resolve <id>   Resolve blocker"
    echo -e "  decision \"desc\"        Ghi nhận quyết định"
    echo -e "  dispatch [--launch|--headless] [--trust] [--dry-run] [--force-run] [--max-retries N] [--role name] [--budget-override-reason text]"
    echo -e "                         Tạo worker briefs + chạy workers"
    echo -e "  collect                Gom worker reports vào workflow-state"
    echo -e "  team <start|delegate|sync|status|monitor|recover|budget-reset|run>"
    echo -e "                         PM-only orchestration cho sub-agents"
    echo -e "  brainstorm [topic] [--project Name] [--sync] [--wait N] [--dry-run]"
    echo -e "                         One-shot auto init + delegate theo current step"
    echo -e "  summary                Step summary"
    echo -e "  release-dashboard      PM release summary (gate/evidence/traceability/budget)"
    echo -e "  history                Lịch sử approvals"
    echo -e "  reset <step>           Reset về step cụ thể\n"
    ;;
  *)
    echo "Unknown command: $CMD. Dùng --help để xem danh sách lệnh."
    exit 1
    ;;
esac
