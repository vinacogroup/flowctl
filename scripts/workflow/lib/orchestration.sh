#!/usr/bin/env bash

cmd_team() {
  local action="${1:-status}"
  shift || true

  local step
  step=$(wf_require_initialized_workflow)
  local step_status
  step_status=$(wf_json_get "steps.$step.status")
  local step_name
  step_name=$(wf_get_step_name "$step")
  local role_list
  role_list=$(wf_get_step_roles_csv "$step")
  local dispatch_dir="$REPO_ROOT/workflows/dispatch/step-$step"
  local reports_dir="$dispatch_dir/reports"
  local logs_dir="$dispatch_dir/logs"

  case "$action" in
    start|delegate)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM step-based delegate${NC}"
      echo -e "Current step: ${BOLD}$step — $step_name${NC}"
      echo -e "Spawn roles: ${YELLOW}${role_list}${NC}"
      if [[ "$step_status" == "pending" ]]; then
        echo -e "Step đang pending, auto start step trước khi delegate..."
        cmd_start
      fi
      echo -e "Dispatch workers headless..."
      cmd_dispatch --headless "$@"
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
    monitor)
      local stale_seconds="300"
      local retry_delay_seconds="60"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --stale-seconds)
            stale_seconds="${2:-300}"
            shift 2
            ;;
          --retry-delay-seconds)
            retry_delay_seconds="${2:-60}"
            shift 2
            ;;
          *)
            echo -e "${RED}Unknown option for team monitor: $1${NC}"
            echo -e "Usage: flowctl team monitor [--stale-seconds N] [--retry-delay-seconds N]\n"
            exit 1
            ;;
        esac
      done
      [[ "$stale_seconds" =~ ^[0-9]+$ ]] || stale_seconds="300"
      [[ "$retry_delay_seconds" =~ ^[0-9]+$ ]] || retry_delay_seconds="60"
      echo -e "\n${BLUE}${BOLD}[TEAM] PM monitor${NC}"
      python3 - <<PY
import json
import os
import calendar
import time
from pathlib import Path

state = json.loads(Path("$STATE_FILE").read_text(encoding="utf-8"))
step = str($step)
repo_root = Path("$REPO_ROOT")
dispatch_dir = repo_root / "workflows" / "dispatch" / f"step-{step}"
reports_dir = dispatch_dir / "reports"
logs_dir = dispatch_dir / "logs"
idem_path = Path("$IDEMPOTENCY_FILE")
sessions_path = Path("$ROLE_SESSIONS_FILE")
heartbeats_path = Path("$HEARTBEATS_FILE")
budget_state_path = Path("$BUDGET_STATE_FILE")
budget_policy_path = Path("$BUDGET_POLICY_FILE")
stale_seconds = int("$stale_seconds")
retry_delay_seconds = int("$retry_delay_seconds")
now_ts = time.time()

idem = json.loads(idem_path.read_text(encoding="utf-8")) if idem_path.exists() else {}
sessions = json.loads(sessions_path.read_text(encoding="utf-8")) if sessions_path.exists() else {}
budget_state = json.loads(budget_state_path.read_text(encoding="utf-8")) if budget_state_path.exists() else {}
budget_policy = json.loads(budget_policy_path.read_text(encoding="utf-8")) if budget_policy_path.exists() else {}
latest_hb_by_role = {}
if heartbeats_path.exists():
    for line in heartbeats_path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            row = json.loads(s)
        except Exception:
            continue
        if str(row.get("step")) != step:
            continue
        role = (row.get("role") or "").strip()
        ts = (row.get("timestamp") or "").strip()
        if not role or not ts:
            continue
        prev = latest_hb_by_role.get(role)
        if prev is None or ts > prev:
            latest_hb_by_role[role] = ts

step_obj = state.get("steps", {}).get(step, {})
primary = (step_obj.get("agent") or "").strip()
supports = [s.strip() for s in (step_obj.get("support_agents") or []) if s and s.strip()]
roles = []
for role in [primary] + supports:
    if role and role not in roles:
        roles.append(role)

defaults = (budget_policy.get("defaults", {}) if isinstance(budget_policy, dict) else {})
run_caps = (defaults.get("run_caps", {}) if isinstance(defaults, dict) else {})
max_tokens_total = max(1, int(run_caps.get("max_tokens_total", 100000)))
max_runtime_total = max(1, int(run_caps.get("max_runtime_seconds", 3600)))
max_cost_total = max(0.000001, float(run_caps.get("max_cost_usd", 5.0)))
run_budget = budget_state.get("run", {}) if isinstance(budget_state, dict) else {}
breaker = budget_state.get("breaker", {}) if isinstance(budget_state, dict) else {}
role_budget_map = budget_state.get("roles", {}) if isinstance(budget_state, dict) else {}

def role_status(role: str):
    key = f"step:{step}:role:{role}:mode:headless"
    entry = idem.get(key, {})
    report_path = reports_dir / f"{role}-report.md"
    has_report = report_path.exists()
    pid = entry.get("pid")
    launched = entry.get("status") == "launched"
    completed = entry.get("status") == "completed"
    retry = entry.get("retry_policy") or {}
    attempt_count = int(retry.get("attempt_count", 0))
    max_retries = int(retry.get("max_retries", 3))
    remaining = max(0, max_retries - attempt_count)

    log_path = Path(entry.get("log_path", str(logs_dir / f"{role}.log")))
    log_age = None
    if log_path.exists():
        log_age = int(now_ts - log_path.stat().st_mtime)
    hb_age = None
    hb_ts = latest_hb_by_role.get(role)
    if hb_ts:
        try:
            hb_epoch = calendar.timegm(time.strptime(hb_ts, "%Y-%m-%dT%H:%M:%SZ"))
            hb_age = int(now_ts - hb_epoch)
        except Exception:
            hb_age = None
    activity_age = hb_age if hb_age is not None else log_age

    running = False
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)
            running = True
        except OSError:
            running = False

    log_text = ""
    if log_path.exists():
        try:
            content = log_path.read_text(encoding="utf-8", errors="ignore")
            log_text = content[-4000:].lower()
        except Exception:
            log_text = ""

    if has_report or completed:
        status = "done"
    elif launched and running:
        status = "stale" if (activity_age is not None and activity_age > stale_seconds) else "running"
    elif launched and not running:
        status = "blocked"
    else:
        status = "pending"

    permanent_markers = [
        "failed to trust workspace",
        "permission denied",
        "unauthorized",
        "invalid api key",
        "command not found",
        "syntaxerror",
        "traceback",
    ]
    transient_markers = [
        "timed out",
        "timeout",
        "rate limit",
        "temporarily unavailable",
        "connection reset",
        "network",
        "econn",
    ]

    policy_class = "policy"
    if status in ("running", "done"):
        policy_class = "n/a"
    elif any(m in log_text for m in permanent_markers):
        policy_class = "permanent"
    elif status == "stale" or any(m in log_text for m in transient_markers):
        policy_class = "transient"
    else:
        policy_class = "policy"

    if status == "done":
        next_action = "none"
    elif status == "running":
        next_action = "wait"
    elif policy_class == "permanent":
        next_action = "manual-fix"
    elif policy_class == "transient":
        if remaining > 0:
            next_action = f"retry-in-{retry_delay_seconds}s"
        else:
            next_action = "retry-exhausted"
    else:
        next_action = "inspect-policy"

    chat_id = ((sessions.get("roles", {}) or {}).get(role, {}) or {}).get("chat_id", "")
    budget_row = (role_budget_map.get(role, {}) if isinstance(role_budget_map, dict) else {})
    role_tokens = int(budget_row.get("tokens_est", 0))
    role_runtime = int(budget_row.get("runtime_seconds", 0))
    role_cost = float(budget_row.get("cost_usd", 0.0))
    return {
        "role": role,
        "status": status,
        "pid": pid if isinstance(pid, int) else "-",
        "chat_id": chat_id,
        "correlation_id": entry.get("correlation_id", ""),
        "log_age": "-" if log_age is None else f"{log_age}s",
        "hb_age": "-" if hb_age is None else f"{hb_age}s",
        "policy_class": policy_class,
        "next_action": next_action,
        "retry_budget": f"{attempt_count}/{max_retries}",
        "report": "yes" if has_report else "no",
        "budget_tokens": role_tokens,
        "budget_runtime": role_runtime,
        "budget_cost": round(role_cost, 4),
    }

rows = [role_status(r) for r in roles]
counts = {"running": 0, "stale": 0, "blocked": 0, "done": 0, "pending": 0}
for row in rows:
    counts[row["status"]] = counts.get(row["status"], 0) + 1

print(f"Step {step}: {step_obj.get('name','')}")
print(f"Dispatch dir: {dispatch_dir.relative_to(repo_root)}")
used_tokens = int(run_budget.get("consumed_tokens_est", 0))
used_runtime = int(run_budget.get("consumed_runtime_seconds", 0))
used_cost = float(run_budget.get("consumed_cost_usd", 0.0))
eta_to_cap_seconds = "-"
if counts["running"] > 0 and used_runtime > 0:
    avg_runtime = used_runtime / max(1, len(rows))
    remain_runtime = max(0, max_runtime_total - used_runtime)
    eta_to_cap_seconds = int(remain_runtime / max(1, counts["running"]))
print(
    f"Budget: tokens={used_tokens}/{max_tokens_total} ({(used_tokens/max_tokens_total)*100:.1f}%) "
    f"runtime={used_runtime}/{max_runtime_total}s ({(used_runtime/max_runtime_total)*100:.1f}%) "
    f"cost=\${used_cost:.4f}/\${max_cost_total:.4f} ({(used_cost/max_cost_total)*100:.1f}%) "
    f"breaker={(breaker.get('state') or 'closed')} eta_to_cap={eta_to_cap_seconds if eta_to_cap_seconds == '-' else str(eta_to_cap_seconds)+'s'}"
)
print(
    f"Summary: running={counts['running']} stale={counts['stale']} "
    f"blocked={counts['blocked']} done={counts['done']} pending={counts['pending']}"
)
print("")
for row in rows:
    chat = row["chat_id"][:12] + "..." if row["chat_id"] and len(row["chat_id"]) > 15 else (row["chat_id"] or "-")
    corr = row["correlation_id"][:28] + "..." if row["correlation_id"] and len(row["correlation_id"]) > 31 else (row["correlation_id"] or "-")
    print(
        f"- @{row['role']}: {row['status']:<7} "
        f"pid={row['pid']} report={row['report']} log_age={row['log_age']} hb_age={row['hb_age']} "
        f"policy={row['policy_class']} action={row['next_action']} retry={row['retry_budget']} "
        f"budget=t:{row['budget_tokens']} rt:{row['budget_runtime']}s c:{row['budget_cost']:.4f} "
        f"chat={chat} corr={corr}"
    )
print("")
PY
      ;;
    recover)
      local role=""
      local mode="resume"
      local dry_run="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --role)
            role="${2:-}"
            shift 2
            ;;
          --mode)
            mode="${2:-resume}"
            shift 2
            ;;
          --dry-run)
            dry_run="true"
            shift
            ;;
          *)
            echo -e "${RED}Unknown option for team recover: $1${NC}"
            echo -e "Usage: flowctl team recover --role <name> [--mode resume|retry|rollback] [--dry-run]\n"
            exit 1
            ;;
        esac
      done
      role="${role#@}"
      [[ -n "$role" ]] || { echo -e "${RED}team recover requires --role <name>${NC}\n"; exit 1; }
      if [[ "$mode" != "resume" && "$mode" != "retry" && "$mode" != "rollback" ]]; then
        echo -e "${RED}Invalid recover mode: $mode${NC}"
        echo -e "Allowed modes: resume | retry | rollback\n"
        exit 1
      fi
      echo -e "\n${BLUE}${BOLD}[TEAM] PM recover${NC}"
      echo -e "Step: ${BOLD}$step${NC} role=@${role} mode=${mode} dry_run=${dry_run}"
      if [[ "$mode" == "rollback" ]]; then
        local reports_dir="$REPO_ROOT/workflows/dispatch/step-$step/reports"
        local logs_dir="$REPO_ROOT/workflows/dispatch/step-$step/logs"
        local report_path="$reports_dir/${role}-report.md"
        local log_path="$logs_dir/${role}.log"
        if [[ "$dry_run" == "true" ]]; then
          echo -e "${CYAN}[dry-run] would rollback role @${role}:${NC} remove report/log and mark idempotency rolled_back"
          echo ""
          exit 0
        fi
        rm -f "$report_path" "$log_path"
        WF_IDEMPOTENCY_FILE="$IDEMPOTENCY_FILE" WF_STEP="$step" WF_ROLE="$role" python3 - <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path

path = Path(os.environ["WF_IDEMPOTENCY_FILE"])
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
key = f"step:{os.environ['WF_STEP']}:role:{os.environ['WF_ROLE']}:mode:headless"
entry = data.get(key, {})
retry = entry.get("retry_policy") or {}
entry["status"] = "rolled_back"
entry["pid"] = None
retry["last_failure_class"] = "policy"
entry["retry_policy"] = retry
entry["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
data[key] = entry
path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
PY
        echo -e "${GREEN}Rollback completed for @${role}.${NC}"
        echo -e "Next: ${BOLD}flowctl team recover --role ${role} --mode retry${NC}\n"
        exit 0
      fi
      local dispatch_args=(--headless --force-run --role "$role")
      [[ "$dry_run" == "true" ]] && dispatch_args+=(--dry-run)
      cmd_dispatch "${dispatch_args[@]}"
      ;;
    budget-reset)
      local reason="manual reset by PM"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --reason)
            reason="${2:-manual reset by PM}"
            shift 2
            ;;
          *)
            echo -e "${RED}Unknown option for team budget-reset: $1${NC}"
            echo -e "Usage: flowctl team budget-reset [--reason \"text\"]\n"
            exit 1
            ;;
        esac
      done
      echo -e "\n${BLUE}${BOLD}[TEAM] PM budget reset${NC}"
      wf_budget_init_artifacts
      local reset_result
      reset_result=$(wf_budget_manual_reset "$reason")
      echo -e "${GREEN}${reset_result}${NC}\n"
      ;;
    run)
      echo -e "\n${BLUE}${BOLD}[TEAM] PM run loop (single cycle)${NC}"
      echo -e "Current step: ${BOLD}$step — $step_name${NC}"
      echo -e "Spawn roles: ${YELLOW}${role_list}${NC}"
      if [[ "$step_status" == "pending" ]]; then
        echo -e "Step đang pending, auto start step trước khi delegate..."
        cmd_start
      fi
      cmd_dispatch --headless "$@"
      echo -e "${YELLOW}Workers đang chạy nền. Sau khi đủ thời gian xử lý, chạy:${NC}"
      echo -e "  ${BOLD}flowctl team sync${NC}\n"
      ;;
    *)
      echo -e "${RED}Unknown team action: $action${NC}"
      echo -e "Usage: flowctl team <start|delegate|sync|status|monitor|recover|budget-reset|run>\n"
      exit 1
      ;;
  esac
}

cmd_brainstorm() {
  local project_name=""
  local auto_sync="false"
  local wait_seconds="30"
  local topic_parts=()
  local delegate_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        project_name="${2:-}"
        shift 2
        ;;
      --sync)
        auto_sync="true"
        shift
        ;;
      --wait)
        wait_seconds="${2:-30}"
        shift 2
        ;;
      --launch|--headless|--trust|--dry-run|--force-run)
        delegate_args+=("$1")
        shift
        ;;
      *)
        topic_parts+=("$1")
        shift
        ;;
    esac
  done

  local topic="${topic_parts[*]}"
  local step
  step=$(wf_json_get "current_step")

  if [[ -z "$step" || "$step" == "0" ]]; then
    local effective_project="$project_name"
    [[ -z "$effective_project" ]] && effective_project="Auto Brainstorm Project"
    echo -e "${CYAN}Workflow chưa init, tự khởi tạo project: ${BOLD}${effective_project}${NC}"
    cmd_init --project "$effective_project"
    step=$(wf_json_get "current_step")
  fi

  if [[ -n "$topic" ]]; then
    echo -e "${CYAN}Brainstorm topic:${NC} $topic"
  fi

  if [[ ${#delegate_args[@]} -gt 0 ]]; then
    cmd_team delegate "${delegate_args[@]}"
  else
    cmd_team delegate
  fi

  if [[ "$auto_sync" == "true" ]]; then
    if [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [[ "$wait_seconds" -gt 0 ]]; then
      echo -e "${YELLOW}Đợi ${wait_seconds}s trước khi sync...${NC}"
      sleep "$wait_seconds"
    fi
    cmd_team sync
  fi
}
