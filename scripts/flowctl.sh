#!/usr/bin/env bash
# ============================================================
# IT Product Team Workflow — CLI Manager
# Quản lý flowctl state, approvals, và transitions
#
# Usage:
#   flowctl <command> [args]
#   flowctl <command> [args]
#
# Commands:
#   init --project "Name" [--no-setup]   Khởi tạo + mặc định chạy scripts/setup.sh (Graphify/MCP)
#   status                   Xem trạng thái hiện tại
#   start                    Bắt đầu step hiện tại
#   approve [--by "Name"]    Approve step hiện tại → advance
#   gate-check               Kiểm tra QA gate cho step hiện tại
#   reject "reason"          Reject step với lý do
#   conditional "items"      Approve có điều kiện
#   blocker add "desc"       Thêm blocker
#   blocker resolve <id>     Resolve blocker
#   blocker reconcile        Auto-resolve blockers khi điều kiện đã thỏa
#   decision "desc"          Ghi nhận quyết định
#   dispatch [--launch|--headless] [--trust] [--dry-run] [--force-run] [--max-retries N] [--role name] [--budget-override-reason text]
#                            Tạo briefs; launch UI hoặc chạy headless nền
#   collect                  Gom worker reports vào flowctl-state
#   team <start|delegate|sync|status|monitor|recover|budget-reset|run>
#                            PM-only orchestration: step-based spawn/collect/summary
#   brainstorm [topic]       One-shot: init (if needed) + step-based delegate
#   summary                  In summary của step hiện tại
#   release-dashboard        PM release summary cho approve decision
#   reset <step>             Reset về step cụ thể (cần confirm)
#   history                  Lịch sử approvals
#   mcp --shell-proxy|--workflow-state
#                            Chạy MCP servers qua flowctl wrapper
# ============================================================

set -euo pipefail

WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
WORKFLOW_CLI_CMD="${WORKFLOW_CLI_CMD:-flowctl}"

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
source "$LIB_DIR/complexity.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/war_room.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/mercenary.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/retro.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/cursor_dispatch.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/orchestration.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/reporting.sh"

# ── Commands ─────────────────────────────────────────────────

ensure_project_scaffold() {
  local overwrite_existing="${1:-false}"
  local template_state="$WORKFLOW_ROOT/templates/flowctl-state.template.json"
  local had_state="false"
  local had_settings="false"
  local state_status="skipped"
  local mcp_status="skipped"
  local settings_status="skipped"

  mkdir -p "$PROJECT_ROOT/.cursor" "$PROJECT_ROOT/.claude"

  [[ -f "$STATE_FILE" ]] && had_state="true"
  [[ -f "$PROJECT_ROOT/.claude/settings.json" ]] && had_settings="true"

  if [[ ! -f "$STATE_FILE" || "$overwrite_existing" == "true" ]]; then
    if [[ -f "$template_state" ]]; then
      cp "$template_state" "$STATE_FILE"
      if [[ "$had_state" == "true" ]]; then
        state_status="overwritten"
      else
        state_status="created"
      fi
    else
      wf_error "Không tìm thấy flowctl state template: $template_state"
      wf_info "Hành động đề xuất: kiểm tra lại file template trong templates/ trước khi chạy init."
      exit 1
    fi
  fi

  local merge_py="$WORKFLOW_ROOT/scripts/merge_cursor_mcp.py"
  if [[ ! -f "$merge_py" ]]; then
    wf_error "Không tìm thấy merge MCP: $merge_py"
    exit 1
  fi
  local py_out="" merge_rc=0
  if [[ "$overwrite_existing" == "true" ]]; then
    py_out="$(python3 "$merge_py" --overwrite --scaffold "$WORKFLOW_CLI_CMD" "$PROJECT_ROOT/.cursor/mcp.json" 2>&1)" || merge_rc=$?
  else
    py_out="$(python3 "$merge_py" --scaffold "$WORKFLOW_CLI_CMD" "$PROJECT_ROOT/.cursor/mcp.json" 2>&1)" || merge_rc=$?
  fi
  if [[ "$merge_rc" -eq 2 ]]; then
    wf_warn ".cursor/mcp.json: JSON không hợp lệ hoặc mcpServers sai kiểu — sửa tay hoặc chạy ${WORKFLOW_CLI_CMD} init --overwrite"
    mcp_status="invalid_json"
  elif [[ "$merge_rc" -ne 0 ]]; then
    if [[ "$py_out" == *"PermissionError"* && "$py_out" == *".cursor/mcp.json"* ]]; then
      wf_warn ".cursor/mcp.json: không có quyền ghi trong môi trường hiện tại — bỏ qua merge MCP cho lần chạy này"
      mcp_status="skipped_permission_denied"
    else
      wf_error "merge_cursor_mcp.py thất bại (exit $merge_rc)"
      exit 1
    fi
  else
    case "$py_out" in
      MCP_STATUS=created)     mcp_status="created" ;;
      MCP_STATUS=overwritten) mcp_status="overwritten" ;;
      MCP_STATUS=merged)      mcp_status="merged" ;;
      MCP_STATUS=unchanged)  mcp_status="unchanged" ;;
      *) mcp_status="updated" ;;
    esac
  fi

  if [[ -f "$WORKFLOW_ROOT/.claude/settings.json" ]]; then
    if [[ ! -f "$PROJECT_ROOT/.claude/settings.json" || "$overwrite_existing" == "true" ]]; then
      cp "$WORKFLOW_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/settings.json"
      if [[ "$had_settings" == "true" ]]; then
        settings_status="overwritten"
      else
        settings_status="created"
      fi
    fi
  fi

  mkdir -p "$PROJECT_ROOT/workflows/runtime/evidence" "$PROJECT_ROOT/workflows/gates/reports"
  local gate_template="$WORKFLOW_ROOT/templates/qa-gate.v1.json"
  if [[ -f "$gate_template" && ! -f "$PROJECT_ROOT/workflows/gates/qa-gate.v1.json" ]]; then
    mkdir -p "$PROJECT_ROOT/workflows/gates"
    cp "$gate_template" "$PROJECT_ROOT/workflows/gates/qa-gate.v1.json"
  fi

  mkdir -p "$PROJECT_ROOT/workflows/policies"
  local budget_template="$WORKFLOW_ROOT/templates/budget-policy.v1.json"
  if [[ -f "$budget_template" && ! -f "$PROJECT_ROOT/workflows/policies/budget-policy.v1.json" ]]; then
    cp "$budget_template" "$PROJECT_ROOT/workflows/policies/budget-policy.v1.json"
  fi
  local role_template="$WORKFLOW_ROOT/templates/role-policy.v1.json"
  if [[ -f "$role_template" && ! -f "$PROJECT_ROOT/workflows/policies/role-policy.v1.json" ]]; then
    cp "$role_template" "$PROJECT_ROOT/workflows/policies/role-policy.v1.json"
  fi

  wf_info "Scaffold status:"
  [[ "$state_status" == "created" || "$state_status" == "overwritten" ]] && \
    wf_success "flowctl-state.json: $state_status" || wf_warn "flowctl-state.json: $state_status"
  [[ "$mcp_status" == "created" || "$mcp_status" == "overwritten" || "$mcp_status" == "merged" || "$mcp_status" == "unchanged" || "$mcp_status" == "skipped_permission_denied" ]] && \
    wf_success ".cursor/mcp.json: $mcp_status" || wf_warn ".cursor/mcp.json: $mcp_status"
  [[ "$settings_status" == "created" || "$settings_status" == "overwritten" ]] && \
    wf_success ".claude/settings.json: $settings_status" || wf_warn ".claude/settings.json: $settings_status"
}

cmd_mcp() {
  local mode="${1:-}"
  local target=""

  case "$mode" in
    --shell-proxy)   target="$WORKFLOW_ROOT/scripts/workflow/mcp/shell-proxy.js" ;;
    --workflow-state) target="$WORKFLOW_ROOT/scripts/workflow/mcp/workflow-state.js" ;;
    *)
      wf_error "MCP mode không hợp lệ: ${mode:-<empty>}"
      wf_info "Usage: ${WORKFLOW_CLI_CMD} mcp --shell-proxy | --workflow-state"
      exit 1
      ;;
  esac

  if [[ ! -f "$target" ]]; then
    wf_error "Không tìm thấy MCP script: $target"
    exit 1
  fi

  exec node "$target"
}

cmd_init() {
  local project_name=""
  local overwrite_existing="false"
  local run_setup="true"
  [[ "${FLOWCTL_SKIP_SETUP:-}" == "1" ]] && run_setup="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) project_name="$2"; shift 2 ;;
      --overwrite|--force) overwrite_existing="true"; shift ;;
      --no-setup) run_setup="false"; shift ;;
      *) shift ;;
    esac
  done

  ensure_project_scaffold "$overwrite_existing"

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

  if [[ "$run_setup" == "true" ]]; then
    local setup_script="$WORKFLOW_ROOT/scripts/setup.sh"
    if [[ ! -f "$setup_script" ]]; then
      wf_warn "Không tìm thấy setup: $setup_script (bỏ qua)"
    else
      wf_info "Chạy setup (Graphify, MCP, .gitignore)..."
      if FLOWCTL_PROJECT_ROOT="$PROJECT_ROOT" bash "$setup_script"; then
        wf_success "Setup hoàn tất."
      else
        wf_warn "setup.sh thoát không thành công — chạy lại: FLOWCTL_PROJECT_ROOT=\"$PROJECT_ROOT\" bash \"$setup_script\""
      fi
    fi
  fi

  echo ""
  wf_success "Project \"$project_name\" đã được khởi tạo."
  wf_info "Step hiện tại: 1 — Requirements Analysis"
  wf_info "Agent cần dùng: @pm (hỗ trợ: @tech-lead)"
  wf_info "Bước tiếp theo: ${WORKFLOW_CLI_CMD} start"
  wf_warn "Ghi đè scaffold chỉ khi thật sự cần: ${WORKFLOW_CLI_CMD} init --overwrite --project \"$project_name\""
  [[ "$run_setup" == "false" ]] && wf_info "Đã bỏ qua setup (dùng --no-setup hoặc FLOWCTL_SKIP_SETUP=1)."
  echo ""
}

cmd_status() {
  [[ ! -f "$STATE_FILE" ]] && {
    wf_error "Không tìm thấy flowctl-state.json."
    wf_info "Hành động đề xuất: chạy ${WORKFLOW_CLI_CMD} init --project \"Tên dự án\""
    exit 1
  }

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

  echo -e "  Dùng ${CYAN}${WORKFLOW_CLI_CMD} approve${NC} sau khi step hoàn thành\n"
}

cmd_start() {
  local step
  step=$(wf_require_initialized_workflow)

  wf_json_set "steps.$step.status" "in_progress"
  wf_json_set "steps.$step.started_at" "$(wf_now)"

  local name agent
  name=$(wf_get_step_name "$step")
  agent=$(wf_get_step_agent "$step")

  bash "$WORKFLOW_ROOT/scripts/hooks/invalidate-cache.sh" state 2>/dev/null || true
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
      wf_error "Thiếu giá trị cho --by."
      wf_info "Hành động đề xuất: dùng --by \"Tên người duyệt\""
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
      echo ""
      wf_error "APPROVE bị chặn bởi QA Gate."
      wf_error "${gate_result#GATE_FAIL|}"
      wf_info "Hành động đề xuất: chạy ${WORKFLOW_CLI_CMD} gate-check"
      wf_warn "Bypass có chủ đích (có audit trail): ${WORKFLOW_CLI_CMD} approve --skip-gate --by \"Name\""
      echo ""
      exit 1
    fi
    wf_write_gate_report "$step" "PASS" "${gate_result#GATE_OK|}" "$by"
    wf_success "QA Gate passed: ${gate_result#GATE_OK|}"
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
    echo -e "Bắt đầu: ${BOLD}${WORKFLOW_CLI_CMD} start${NC}\n"
  else
    wf_json_set "overall_status" "completed"
    echo -e "\n${GREEN}${BOLD}🎉 WORKFLOW HOÀN THÀNH! Project đã release.${NC}\n"
  fi
  # Invalidate MCP state cache + generate token report
  bash "$WORKFLOW_ROOT/scripts/hooks/invalidate-cache.sh" state 2>/dev/null || true
  python3 "$WORKFLOW_ROOT/scripts/hooks/generate-token-report.py" --step "$step" 2>/dev/null || true

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
  echo -e "\nAddress concerns rồi chạy lại: ${BOLD}${WORKFLOW_CLI_CMD} approve${NC}\n"
}

cmd_add_blocker() {
  local desc="${1:-}"
  [[ -z "$desc" ]] && { wf_info "Nhập mô tả blocker:"; read -r desc; }

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
  echo -e "Resolve: ${BOLD}${WORKFLOW_CLI_CMD} blocker resolve $id${NC}\n"
}

cmd_resolve_blocker() {
  local id="${1:-}"
  [[ -z "$id" ]] && { wf_error "Thiếu blocker id."; wf_info "Usage: blocker resolve <id>"; exit 1; }

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

cmd_reconcile_blockers() {
  local step
  step=$(wf_require_initialized_workflow)

  WF_STATE_FILE="$STATE_FILE" WF_REPO_ROOT="$REPO_ROOT" WF_ROLE_POLICY_FILE="$ROLE_POLICY_FILE" WF_STEP="$step" python3 - <<'PY'
import json
import os
import re
from datetime import datetime
from pathlib import Path

state_path = Path(os.environ["WF_STATE_FILE"])
repo_root = Path(os.environ["WF_REPO_ROOT"])
role_policy_path = Path(os.environ["WF_ROLE_POLICY_FILE"])
step = str(os.environ["WF_STEP"])
now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

data = json.loads(state_path.read_text(encoding="utf-8"))
blockers = data.get("steps", {}).get(step, {}).get("blockers", []) or []

roles_cfg = {}
if role_policy_path.exists():
    try:
        roles_cfg = (json.loads(role_policy_path.read_text(encoding="utf-8")) or {}).get("roles", {}) or {}
    except Exception:
        roles_cfg = {}

resolved = []
remaining = []

def all_backtick_paths_exist(desc: str) -> bool:
    paths = re.findall(r"`([^`]+)`", desc or "")
    if not paths:
        return False
    return all((repo_root / p).exists() for p in paths)

def resolve_rule_matched(desc: str) -> tuple[bool, str]:
    text = (desc or "").lower()

    # Specific rule for role-policy blocker: require backend + frontend roles.
    if "role-policy.v1.json" in text:
      if "backend" in roles_cfg and "frontend" in roles_cfg:
          return True, "role-policy covers backend/frontend"
      return False, "role-policy missing backend/frontend"

    # Specific rule for docs traceability blocker.
    if "docs/requirements.md" in text and "docs/architecture.md" in text:
      req_ok = (repo_root / "docs/requirements.md").exists()
      arch_ok = (repo_root / "docs/architecture.md").exists()
      if req_ok and arch_ok:
          return True, "requirements + architecture docs exist"
      missing = []
      if not req_ok:
          missing.append("docs/requirements.md")
      if not arch_ok:
          missing.append("docs/architecture.md")
      return False, "missing: " + ", ".join(missing)

    # Generic heuristic: if all quoted file paths now exist.
    if all_backtick_paths_exist(desc):
        return True, "all referenced backtick paths exist"

    return False, "no reconcile rule matched"

for b in blockers:
    if b.get("resolved"):
        continue
    ok, reason = resolve_rule_matched(b.get("description", ""))
    if ok:
        b["resolved"] = True
        b["resolved_at"] = now
        b["resolved_by"] = "reconcile"
        b["resolution_note"] = reason
        resolved.append((b.get("id", "?"), reason))
    else:
        remaining.append((b.get("id", "?"), reason))

data["updated_at"] = now
state_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

print(f"RECONCILE_OK|step={step}|resolved={len(resolved)}|remaining_open={len(remaining)}")
for bid, reason in resolved:
    print(f"RESOLVED|{bid}|{reason}")
for bid, reason in remaining:
    print(f"OPEN|{bid}|{reason}")
PY
}

cmd_add_decision() {
  local desc="${1:-}"
  [[ -z "$desc" ]] && { wf_info "Nhập nội dung quyết định:"; read -r desc; }

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
  init|start|gate-check|approve|reject|conditional|blocker|decision|dispatch|cursor-dispatch|collect|team|reset|brainstorm|release-dashboard|war-room|mercenary|retro|complexity)
    wf_acquire_flow_lock
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
      reconcile) cmd_reconcile_blockers "$@" ;;
      *)       wf_error "Subcommand blocker không hợp lệ."; wf_info "Usage: blocker [add|resolve|reconcile]" ;;
    esac
    ;;
  decision|d)   cmd_add_decision "$@" ;;
  dispatch)        cmd_dispatch "$@" ;;
  cursor-dispatch|cd) cmd_cursor_dispatch "$@" ;;
  collect)         cmd_collect ;;
  war-room|wr)
    SUBCMD="${1:-start}"; shift || true
    case "$SUBCMD" in
      merge)  cmd_war_room_merge ;;
      *)      cmd_war_room ;;
    esac
    ;;
  mercenary|merc)
    SUBCMD="${1:-scan}"; shift || true
    cmd_mercenary "$SUBCMD" "$@"
    ;;
  monitor|mon)  python3 "$WORKFLOW_ROOT/scripts/monitor.py" "$@" ;;
  retro)        cmd_retro "$@" ;;
  complexity)   cmd_complexity ;;
  mcp)          cmd_mcp "$@" ;;
  team)         cmd_team "$@" ;;
  brainstorm|bs) cmd_brainstorm "$@" ;;
  summary|sum)  cmd_summary ;;
  release-dashboard|dashboard) cmd_release_dashboard "$@" ;;
  history|h)    cmd_history ;;
  reset)        cmd_reset "$@" ;;
  help|--help|-h)
    echo ""
    wf_info "IT Product Workflow CLI"
    echo -e "  init --project \"Name\" [--no-setup]  Khởi tạo dự án (+ setup mặc định)"
    echo -e "  status                 Xem trạng thái"
    echo -e "  start                  Bắt đầu step hiện tại"
    echo -e "  monitor [--once] [--interval=N]"
    echo -e "                         Dashboard theo dõi token theo thời gian thực (mở terminal riêng)"
    echo -e "  mcp --shell-proxy|--workflow-state"
    echo -e "                         Chạy MCP servers qua flowctl wrapper"
    echo -e "  complexity             Đánh giá complexity score của step hiện tại"
    echo -e "  war-room [merge]       Phase 0: PM + TechLead align (complexity-gated)"
    echo -e "  cursor-dispatch [cd] [--skip-war-room] [--merge]"
    echo -e "                         Phase A: Tạo briefs + Spawn Board (auto War Room nếu cần)"
    echo -e "  collect                Phase A collect: gom reports + detect NEEDS_SPECIALIST"
    echo -e "  mercenary [scan|spawn] Phase B: Scan/spawn mercenary specialists"
    echo -e "  retro [step]           Post-approve: extract lessons → .graphify/lessons.json"
    echo -e "  gate-check             Kiểm tra QA gate cho step hiện tại"
    echo -e "  approve [--by Name] [--skip-gate]"
    echo -e "                         Approve và advance (default có QA gate)"
    echo -e "  reject \"reason\"        Reject với lý do"
    echo -e "  blocker add \"desc\"     Thêm blocker"
    echo -e "  blocker resolve <id>   Resolve blocker"
    echo -e "  blocker reconcile      Auto-resolve blockers khi điều kiện đã đủ"
    echo -e "  decision \"desc\"        Ghi nhận quyết định"
    echo -e "  dispatch [--dry-run|--headless] [--role name]"
    echo -e "                         Tạo worker briefs (low-level, dùng cursor-dispatch thay)"
    echo -e "  team <start|delegate|sync|status|monitor|recover|budget-reset|run>"
    echo -e "                         PM-only orchestration cho sub-agents"
    echo -e "  brainstorm [topic]     One-shot auto init + delegate theo current step"
    echo -e "  summary                Tóm tắt step hiện tại"
    echo -e "  release-dashboard      PM release summary"
    echo -e "  history                Lịch sử approvals"
    echo -e "  reset <step>           Reset về step cụ thể"
    echo ""
    wf_info "Mẹo: bắt đầu nhanh với ${WORKFLOW_CLI_CMD} init --project \"Tên dự án\""
    wf_info "Mẹo: xem trạng thái bất kỳ lúc nào với ${WORKFLOW_CLI_CMD} status"
    echo ""
    ;;
  *)
    wf_error "Lệnh không hợp lệ: $CMD"
    wf_info "Hành động đề xuất: dùng --help để xem danh sách lệnh."
    exit 1
    ;;
esac
