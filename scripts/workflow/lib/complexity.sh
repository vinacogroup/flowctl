#!/usr/bin/env bash
# complexity.sh — Auto-score step complexity để quyết định có cần War Room không
# Score 1-5:  1-2 = simple (skip War Room), 3-5 = complex (trigger War Room)

# Returns: integer 1-5
wf_complexity_score() {
  local step="${1:-}"
  [[ -z "$step" ]] && step=$(wf_json_get "current_step")

  python3 - <<PY
import json
from pathlib import Path

state_path = Path("$STATE_FILE")
data = json.loads(state_path.read_text(encoding="utf-8"))
step = str($step)
s = data["steps"].get(step, {})

score = 1

# Rule 1: number of roles involved
primary = s.get("agent", "")
supports = [a for a in s.get("support_agents", []) if a and a != primary]
n_roles = 1 + len(supports)
if n_roles >= 4:
    score += 2
elif n_roles >= 3:
    score += 1

# Rule 2: step type (code steps are inherently complex)
code_steps = {"4", "5", "6"}
complex_steps = {"2", "7", "8"}
if step in code_steps:
    score += 2
elif step in complex_steps:
    score += 1

# Rule 3: open blockers from prior steps (carry-over complexity)
open_blockers = 0
for sn, sobj in data["steps"].items():
    if int(sn) < int(step):
        for b in sobj.get("blockers", []):
            if not b.get("resolved"):
                open_blockers += 1
if open_blockers > 0:
    score += 1

# Clamp to 1-5
score = max(1, min(5, score))
print(score)
PY
}

wf_complexity_tier() {
  local score="$1"
  if [[ "$score" -le 1 ]]; then
    echo "MICRO"
  elif [[ "$score" -le 3 ]]; then
    echo "STANDARD"
  else
    echo "FULL"
  fi
}

cmd_complexity() {
  local step
  step=$(wf_require_initialized_workflow)
  local score
  score=$(wf_complexity_score "$step")
  local tier
  tier=$(wf_complexity_tier "$score")

  local label verdict color
  case "$tier" in
    MICRO)
      label="MICRO"; color="$GREEN"
      verdict="1 agent, no brief/report ceremony → PM assign trực tiếp"
      ;;
    STANDARD)
      label="STANDARD"; color="$YELLOW"
      verdict="1-3 agents, brief + report, no War Room → dispatch thẳng"
      ;;
    FULL)
      label="FULL"; color="$RED"
      verdict="Full flow: War Room → Dispatch all agents → Collect → Phase B"
      ;;
  esac

  echo -e "\n${BOLD}Complexity Score — Step $step${NC}"
  echo -e "  Score : ${color}${BOLD}$score / 5${NC} ($label)"
  echo -e "  Tier  : ${color}${BOLD}$tier${NC}"
  echo -e "  Action: $verdict\n"
}
