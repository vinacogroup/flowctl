#!/usr/bin/env bash
# mercenary.sh — On-demand Mercenary Pool
# Workers declare NEEDS_SPECIALIST in report → PM scans → spawns mercenaries → re-injects

MERCENARY_TYPES="researcher security-auditor ux-validator tech-validator data-analyst"

# Scan all reports for NEEDS_SPECIALIST declarations
# Returns JSON array of pending mercenary requests
wf_mercenary_scan() {
  local step="${1:-}"
  [[ -z "$step" ]] && step=$(wf_json_get "current_step")
  local reports_dir="$REPO_ROOT/workflows/dispatch/step-$step/reports"

  python3 - <<PY
import json, re
from pathlib import Path

reports_dir = Path("$reports_dir")
requests = []

# Guard: always output valid JSON even if reports dir doesn't exist
if not reports_dir.exists():
    print("[]")
    raise SystemExit(0)

for report_file in sorted(reports_dir.glob("*-report.md")):
    role = report_file.stem.replace("-report", "")
    content = report_file.read_text(encoding="utf-8")

    # Parse NEEDS_SPECIALIST blocks
    # Format:
    # ## NEEDS_SPECIALIST
    # - type: researcher
    #   query: "..."
    #   blocking: "..."
    in_block = False
    current = {}
    for line in content.splitlines():
        stripped = line.strip()
        if stripped == "## NEEDS_SPECIALIST":
            in_block = True
            continue
        if in_block:
            if stripped.startswith("## ") and stripped != "## NEEDS_SPECIALIST":
                if current:
                    requests.append({**current, "requested_by": role, "report": str(report_file.relative_to(Path("$REPO_ROOT")))})
                    current = {}
                in_block = False
                continue
            m = re.match(r'^-\s+type:\s+(.+)$', stripped)
            if m:
                if current:
                    requests.append({**current, "requested_by": role, "report": str(report_file.relative_to(Path("$REPO_ROOT")))})
                current = {"type": m.group(1).strip()}
            elif current:
                for key in ("query", "blocking", "priority"):
                    m2 = re.match(rf'^{key}:\s+"?(.+?)"?\s*$', stripped)
                    if m2:
                        current[key] = m2.group(1).strip()

    if current and in_block:
        requests.append({**current, "requested_by": role, "report": str(report_file.relative_to(Path("$REPO_ROOT")))})

print(json.dumps(requests, ensure_ascii=False))
PY
}

cmd_mercenary() {
  local subcmd="${1:-scan}"; shift || true

  case "$subcmd" in
    scan)    _mercenary_scan_cmd "$@" ;;
    spawn)   _mercenary_spawn_board "$@" ;;
    *)
      echo "Usage: mercenary [scan|spawn]"
      ;;
  esac
}

_mercenary_scan_cmd() {
  local step
  step=$(wf_require_initialized_workflow)
  local requests
  requests=$(wf_mercenary_scan "$step")
  local count
  count=$(echo "$requests" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [[ "$count" -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} Không có NEEDS_SPECIALIST requests trong step $step reports.\n"
    return 0
  fi

  echo -e "\n${YELLOW}${BOLD}🔍 MERCENARY REQUESTS DETECTED — Step $step${NC}"
  echo -e "  $count request(s) cần resolve:\n"

  echo "$requests" | python3 -c "
import json, sys
requests = json.load(sys.stdin)
for i, r in enumerate(requests, 1):
    print(f'  [{i}] type: {r.get(\"type\",\"?\")}')
    print(f'      by: @{r.get(\"requested_by\",\"?\")}')
    print(f'      query: {r.get(\"query\",\"?\")}')
    print(f'      blocking: {r.get(\"blocking\",\"?\")}')
    print()
"

  echo -e "  Chạy ${BOLD}flowctl mercenary spawn${NC} để tạo spawn board.\n"
}

_mercenary_spawn_board() {
  local mercenary_timeout="3600"  # default: 1h per mercenary task (L-03)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        mercenary_timeout="${2:-3600}"
        [[ "$mercenary_timeout" =~ ^[0-9]+$ ]] || mercenary_timeout="3600"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  local step
  step=$(wf_require_initialized_workflow)
  local step_name
  step_name=$(wf_get_step_name "$step")
  local requests
  requests=$(wf_mercenary_scan "$step")
  local count
  count=$(echo "$requests" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [[ "$count" -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} Không có mercenary requests.\n"
    return 0
  fi

  local merc_dir="$REPO_ROOT/workflows/dispatch/step-$step/mercenaries"
  wf_ensure_dir "$merc_dir"

  echo -e "\n${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║  🔧 PHASE B — MERCENARY SPAWN BOARD — Step $step${NC}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}\n"

  echo "$requests" | python3 - <<PY
import json, sys
from pathlib import Path

requests = json.loads("""$requests""")
step = "$step"
merc_dir = Path("$merc_dir")
repo_root = Path("$REPO_ROOT")

for i, r in enumerate(requests, 1):
    merc_type = r.get("type", "researcher")
    requested_by = r.get("requested_by", "unknown")
    query = r.get("query", "")
    blocking = r.get("blocking", "")
    priority = r.get("priority", "parallel")

    brief_file = merc_dir / f"{merc_type}-{i}-brief.md"
    output_file = merc_dir / f"{merc_type}-{i}-output.md"

    brief = f"""# Mercenary Brief — {merc_type} #{i}

## Context
Requested by: @{requested_by}
Blocking: {blocking}
Priority: {priority}

## Task
{query}

## Output format
Ghi kết quả vào: {str(output_file.relative_to(repo_root))}

Format:
# Mercenary Output — {merc_type} #{i}
## FINDINGS
[kết quả nghiên cứu/phân tích]

## RECOMMENDATION
[lời khuyên cụ thể cho @{requested_by}]

## SOURCES (nếu có)
[links/references]
"""
    brief_file.write_text(brief, encoding="utf-8")
    rel_brief = str(brief_file.relative_to(repo_root))
    rel_output = str(output_file.relative_to(repo_root))

    print(f"  ━━━ [Tab {i}] @mercenary ({merc_type}) — for @{requested_by} ━━━━━━━━━━━━━━━━━━━━━")
    print(f"  Brief:  {rel_brief}")
    print(f"  Output: {rel_output}")
    print(f"  ┌────────────────────────────────────────────────────────────┐")
    print(f"  │ @.cursor/agents/mercenary-agent.md                        ")
    print(f"  │ @{rel_brief}                                              ")
    print(f"  └────────────────────────────────────────────────────────────┘")
    print()
PY

  echo -e "${MAGENTA}${BOLD}━━━ Sau khi mercenaries hoàn thành: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Re-inject outputs vào blocked workers:"

  echo "$requests" | python3 -c "
import json, sys
requests = json.load(sys.stdin)
step = '$step'
for i, r in enumerate(requests, 1):
    role = r.get('requested_by','?')
    mtype = r.get('type','researcher')
    print(f'  flowctl dispatch --role {role}  # re-run @{role} với mercenary output')
"
  echo -e "\n  ${YELLOW}Timeout:${NC} nếu mercenary không hoàn thành trong ${mercenary_timeout}s, re-run thủ công."
  echo -e "  ${YELLOW}Tip:${NC} dùng ${BOLD}flowctl mercenary spawn --timeout <seconds>${NC} để thay đổi.\n"
}

# Wait for all mercenary output files to appear, with timeout.
# Usage: wf_mercenary_wait_outputs <step> [timeout_seconds]
# Returns 0 if all outputs present, 1 if timeout.
wf_mercenary_wait_outputs() {
  local step="$1"
  local timeout_sec="${2:-3600}"
  local merc_dir="$REPO_ROOT/workflows/dispatch/step-$step/mercenaries"
  [[ -d "$merc_dir" ]] || { echo -e "${YELLOW}[mercenary] No mercenary dir for step $step.${NC}"; return 0; }

  local deadline=$(( $(date +%s) + timeout_sec ))
  local pending=1
  while [[ $(date +%s) -lt $deadline ]]; do
    pending=0
    for brief in "$merc_dir"/*-brief.md; do
      [[ -f "$brief" ]] || continue
      local output="${brief%-brief.md}-output.md"
      if [[ ! -f "$output" ]]; then
        pending=1
        break
      fi
    done
    if [[ "$pending" -eq 0 ]]; then
      echo -e "${GREEN}[mercenary] All outputs received.${NC}"
      return 0
    fi
    sleep 10
  done
  echo -e "${RED}[mercenary] Timeout after ${timeout_sec}s — some outputs still missing.${NC}" >&2
  return 1
}

# Inject mercenary outputs into a role's re-run context
wf_mercenary_inject_context() {
  local step="$1" role="$2"
  local merc_dir="$REPO_ROOT/workflows/dispatch/step-$step/mercenaries"
  [[ ! -d "$merc_dir" ]] && return

  local inject=""
  for output_file in "$merc_dir"/*-output.md; do
    [[ -f "$output_file" ]] || continue
    inject+=$'\n'"- @${output_file#$REPO_ROOT/}"
  done

  if [[ -n "$inject" ]]; then
    local brief_file="$REPO_ROOT/workflows/dispatch/step-$step/$role-brief.md"
    if [[ -f "$brief_file" ]]; then
      # Append mercenary context to existing brief
      echo -e "\n## Mercenary Outputs Available\n$inject" >> "$brief_file"
      echo -e "${GREEN}✓${NC} Injected mercenary outputs into @$role brief"
    fi
  fi
}
