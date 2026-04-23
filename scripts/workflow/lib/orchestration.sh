#!/usr/bin/env bash

cmd_team() {
  local action="${1:-status}"
  shift || true

  local step
  step=$(require_initialized_workflow)
  local step_status
  step_status=$(json_get "steps.$step.status")
  local step_name
  step_name=$(get_step_name "$step")
  local role_list
  role_list=$(get_step_roles_csv "$step")
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
      echo -e "  ${BOLD}bash scripts/workflow.sh team sync${NC}\n"
      ;;
    *)
      echo -e "${RED}Unknown team action: $action${NC}"
      echo -e "Usage: bash scripts/workflow.sh team <start|delegate|sync|status|run>\n"
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
  step=$(json_get "current_step")

  if [[ -z "$step" || "$step" == "0" ]]; then
    local effective_project="$project_name"
    [[ -z "$effective_project" ]] && effective_project="Auto Brainstorm Project"
    echo -e "${CYAN}Workflow chưa init, tự khởi tạo project: ${BOLD}${effective_project}${NC}"
    cmd_init --project "$effective_project"
    step=$(json_get "current_step")
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
