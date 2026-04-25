#!/usr/bin/env bash
# retro.sh — Retrospective snapshot sau khi approve
# Extracts patterns → workflows/retro/lessons.json → dùng cho War Room bước tiếp theo

cmd_retro() {
  local step="${1:-}"
  if [[ -z "$step" ]]; then
    step=$(wf_json_get "current_step")
    # Retro thường chạy sau approve, lấy step vừa approved
    local prev_step=$(( step - 1 ))
    [[ "$prev_step" -ge 1 ]] && step="$prev_step"
  fi

  local step_name
  step_name=$(wf_get_step_name "$step")
  local reports_dir="$REPO_ROOT/workflows/dispatch/step-$step/reports"
  local wr_dir="$REPO_ROOT/workflows/dispatch/step-$step/war-room"
  local merc_dir="$REPO_ROOT/workflows/dispatch/step-$step/mercenaries"
  local lessons_file="$REPO_ROOT/workflows/retro/lessons.json"

  echo -e "\n${BOLD}${CYAN}🔄 RETRO — Step $step: $step_name${NC}\n"

  # Extract patterns from step
  local retro_data
  retro_data=$(python3 - <<PY
import json
from pathlib import Path
from datetime import datetime

state_path = Path("$STATE_FILE")
repo_root = Path("$REPO_ROOT")
step = str($step)
reports_dir = Path("$reports_dir")
merc_dir = Path("$merc_dir")
lessons_file = Path("$lessons_file")

data = json.loads(state_path.read_text())
step_obj = data["steps"].get(step, {})

# Count blockers and who had them
blocker_counts = {}
blockers_by_type = []
for b in step_obj.get("blockers", []):
    src = b.get("source", "unknown")
    role = src.split("/")[-1].replace("-report.md", "") if src else "unknown"
    blocker_counts[role] = blocker_counts.get(role, 0) + 1
    desc = b.get("description", "")
    resolved = b.get("resolved", False)
    blocker_pattern = "technical" if any(w in desc.lower() for w in ["api", "db", "schema", "code", "build"]) else "scope"
    blocker_type = "resolved" if resolved else "unresolved"
    blockers_by_type.append(f"{blocker_type}:{blocker_pattern}:{role}")

# Count decisions
n_decisions = len([d for d in step_obj.get("decisions", []) if d.get("type") != "rejection"])

# Mercenaries used
mercs_used = []
if merc_dir.exists():
    for f in merc_dir.glob("*-output.md"):
        parts = f.stem.replace("-output", "").split("-")
        mtype = parts[0] if parts else "unknown"
        mercs_used.append(mtype)

# Duration
started = step_obj.get("started_at", "")
completed = step_obj.get("completed_at", datetime.now().isoformat())

# Patterns to record
patterns = []
for role, count in blocker_counts.items():
    patterns.append(f"Step {step}: @{role} had {count} blocker(s)")
if mercs_used:
    patterns.append(f"Step {step}: mercenaries used: {', '.join(set(mercs_used))}")
if n_decisions > 5:
    patterns.append(f"Step {step}: high decision count ({n_decisions}) — consider splitting")

blocker_patterns = [b.split(":")[1] for b in blockers_by_type]
blocker_types = list(set(blocker_patterns))

retro = {
    "step": step,
    "step_name": "$step_name",
    "timestamp": datetime.now().isoformat(),
    "n_decisions": n_decisions,
    "blocker_counts": blocker_counts,
    "blocker_types": blocker_types,
    "mercenaries_used": list(set(mercs_used)),
    "patterns": patterns,
}

# Load + merge with existing lessons
existing = {"patterns": [], "steps": {}}
if lessons_file.exists():
    try:
        existing = json.loads(lessons_file.read_text())
    except Exception:
        pass

existing["patterns"] = (existing.get("patterns", []) + patterns)[-20:]  # keep last 20
existing["steps"][step] = retro

lessons_file.parent.mkdir(parents=True, exist_ok=True)
lessons_file.write_text(json.dumps(existing, indent=2, ensure_ascii=False))

print(json.dumps(retro, ensure_ascii=False))
PY
)

  # Display summary
  echo "$retro_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'  Step {d[\"step\"]}: {d[\"step_name\"]}')
print(f'  Decisions made   : {d[\"n_decisions\"]}')
bc = d.get('blocker_counts', {})
if bc:
    roles = ', '.join(f'@{r}({c})' for r,c in bc.items())
    print(f'  Blockers by role : {roles}')
else:
    print(f'  Blockers         : none')
mu = d.get('mercenaries_used', [])
if mu:
    print('  Mercenaries used : ' + ', '.join(mu))
patterns = d.get('patterns', [])
if patterns:
    print()
    print('  Patterns detected:')
    for p in patterns:
        print(f'    - {p}')
"

  echo ""
  echo -e "${GREEN}✓${NC} Lessons saved: ${CYAN}workflows/retro/lessons.json${NC}"
  echo ""
}
