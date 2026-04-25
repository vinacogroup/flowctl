#!/usr/bin/env bash
# war_room.sh — Parallel War Room Protocol
# PM + TechLead align TRƯỚC khi dispatch full team
# Output: context-digest.md dùng cho tất cả workers

WF_WAR_ROOM_THRESHOLD="${WF_WAR_ROOM_THRESHOLD:-3}"

cmd_war_room() {
  local step
  step=$(wf_require_initialized_workflow)
  local step_name
  step_name=$(wf_get_step_name "$step")
  local wr_dir="$REPO_ROOT/workflows/dispatch/step-$step/war-room"
  wf_ensure_dir "$wr_dir"

  # Check complexity
  local score
  score=$(wf_complexity_score "$step")
  if [[ "$score" -lt "$WF_WAR_ROOM_THRESHOLD" ]]; then
    echo -e "${GREEN}[war-room]${NC} Complexity score=$score (< $WF_WAR_ROOM_THRESHOLD) — War Room skipped."
    echo -e "  → Generating context digest directly...\n"
    _war_room_generate_digest "$step" "$step_name" "$wr_dir" "simple"
    return 0
  fi

  echo -e "\n${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${MAGENTA}║  🔥 WAR ROOM — Step $step: $step_name${NC}"
  echo -e "${BOLD}${MAGENTA}║  Complexity: $score/5 — PM + TechLead align trước khi dispatch${NC}"
  echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}\n"

  # Generate war room briefs
  _war_room_generate_briefs "$step" "$step_name" "$wr_dir"

  # Output spawn board for War Room agents (parallel)
  _war_room_spawn_board "$step" "$step_name" "$wr_dir"

  echo -e "${YELLOW}${BOLD}⏸  Sau khi PM + TechLead hoàn thành War Room:${NC}"
  echo -e "  Chạy: ${BOLD}flowctl war-room merge${NC}"
  echo -e "  Để merge outputs → context-digest.md → sẵn sàng dispatch full team\n"
}

cmd_war_room_merge() {
  local step
  step=$(wf_require_initialized_workflow)
  local step_name
  step_name=$(wf_get_step_name "$step")
  local wr_dir="$REPO_ROOT/workflows/dispatch/step-$step/war-room"

  local pm_out="$wr_dir/pm-analysis.md"
  local tl_out="$wr_dir/tech-lead-assessment.md"

  if [[ ! -f "$pm_out" && ! -f "$tl_out" ]]; then
    echo -e "${RED}[war-room merge]${NC} Chưa có output từ PM hoặc TechLead."
    echo -e "  Cần file: ${pm_out#$REPO_ROOT/} và ${tl_out#$REPO_ROOT/}\n"
    exit 1
  fi

  _war_room_generate_digest "$step" "$step_name" "$wr_dir" "full"
  echo -e "${GREEN}✓${NC} Context digest đã tạo — sẵn sàng chạy ${BOLD}cursor-dispatch${NC}\n"
}

# ── Internal helpers ────────────────────────────────────────────

_war_room_generate_briefs() {
  local step="$1" step_name="$2" wr_dir="$3"

  # Load lessons from prior retros
  local lessons_file="$REPO_ROOT/workflows/retro/lessons.json"
  local lessons_text=""
  if [[ -f "$lessons_file" ]]; then
    lessons_text=$(python3 -c "
import json
from pathlib import Path
d = json.loads(Path('$lessons_file').read_text())
items = d.get('patterns', [])[-5:]  # last 5 patterns
for i in items:
    print(f'- {i}')
" 2>/dev/null || true)
  fi

  # Gather prior decisions summary
  local prior_decisions
  prior_decisions=$(python3 - <<PY
import json
from pathlib import Path

data = json.loads(Path("$STATE_FILE").read_text())
step = int($step)
lines = []
for n in range(1, step):
    s = data["steps"].get(str(n), {})
    for d in s.get("decisions", []):
        if d.get("type") != "rejection":
            lines.append(f'- Step {n}: {d.get("description","")}')
print("\n".join(lines[-10:]) if lines else "- Chưa có decisions từ các steps trước")
PY
)

  # PM analysis brief
  cat > "$wr_dir/pm-analysis-brief.md" <<BRIEF
# War Room Brief — @pm — Phân tích scope Step $step: $step_name

## Nhiệm vụ
Bạn là PM Agent. Đây là War Room phase — phân tích scope và business objectives TRƯỚC khi dispatch team.

## Workflow Context (chạy ngay, trước khi làm gì khác)
\`\`\`
wf_step_context()          ← state + decisions + blockers (1 call)
wf_state()                 ← nếu chỉ cần step/status hiện tại
\`\`\`

## Prior Decisions (từ steps trước)
$prior_decisions

## Lessons Learned (từ retro trước)
${lessons_text:-"- Chưa có retro data"}

## Câu hỏi cần trả lời
1. Step $step cần đạt được gì? (business objectives rõ ràng)
2. Ai là primary stakeholder và họ cần gì cụ thể?
3. Scope của step này là gì? Gì không nằm trong scope?
4. Acceptance criteria của step này là gì?
5. Có dependency nào từ step trước cần resolve trước không?
6. Risk nào về timeline hoặc business có thể ảnh hưởng?

## Output (ghi vào file này)
Ghi kết quả vào: ${wr_dir#$REPO_ROOT/}/pm-analysis.md

Format:
\`\`\`markdown
# PM Analysis — Step $step: $step_name
## Business Objectives
## Scope Definition (In / Out)
## Acceptance Criteria
## Risks & Dependencies
## Suggested Definition of Done per Role
\`\`\`

BRIEF

  # TechLead assessment brief
  cat > "$wr_dir/tech-lead-assessment-brief.md" <<BRIEF
# War Room Brief — @tech-lead — Technical Assessment Step $step: $step_name

## Nhiệm vụ
Bạn là Tech Lead. Đây là War Room phase — đánh giá feasibility kỹ thuật TRƯỚC khi dispatch team.

## Context Loading (chạy ngay)
\`\`\`
wf_step_context()              ← workflow state + decisions + blockers
gitnexus_get_architecture()    ← codebase structure (nếu là code step)
\`\`\`
> Graphify (query_graph) chỉ dùng cho câu hỏi về code structure, không có workflow data.

## Prior Decisions (từ steps trước)
$prior_decisions

## Câu hỏi cần trả lời
1. Step $step có feasible về mặt kỹ thuật không? Constraints gì?
2. Ước tính effort thực tế cho từng role (pm, backend, frontend, etc.)
3. Technical risks là gì? (performance, security, scalability)
4. Dependencies kỹ thuật nào cần resolve trước (external APIs, DB schema, etc.)?
5. Có technical debt nào từ steps trước ảnh hưởng đến step này không?
6. Cần mercenary nào không? (researcher, security-auditor, validator, etc.)

## Output (ghi vào file này)
Ghi vào: ${wr_dir#$REPO_ROOT/}/tech-lead-assessment.md

Format:
\`\`\`markdown
# TechLead Assessment — Step $step: $step_name
## Feasibility
## Effort Estimates (per role)
## Technical Risks
## Technical Dependencies
## Mercenary Recommendations (if any)
  - type: researcher|security-auditor|ux-validator|tech-validator
    query: "..."
    priority: before|parallel|after
\`\`\`

BRIEF

  echo -e "${GREEN}✓${NC} War Room briefs đã tạo tại ${CYAN}${wr_dir#$REPO_ROOT/}/${NC}"
}

_war_room_spawn_board() {
  local step="$1" step_name="$2" wr_dir="$3"

  echo ""
  echo -e "${BOLD}▶ WAR ROOM SPAWN BOARD — Spawn 2 agents SONG SONG:${NC}"
  echo ""
  echo -e "  ${BOLD}━━━ [Tab 1] @pm — PM Analysis ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Brief: ${CYAN}${wr_dir#$REPO_ROOT/}/pm-analysis-brief.md${NC}"
  echo -e "  ┌────────────────────────────────────────────────────────────┐"
  echo -e "  │ @.cursor/agents/pm-agent.md                               "
  echo -e "  │ @${wr_dir#$REPO_ROOT/}/pm-analysis-brief.md              "
  echo -e "  └────────────────────────────────────────────────────────────┘"
  echo ""
  echo -e "  ${BOLD}━━━ [Tab 2] @tech-lead — Technical Assessment ━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Brief: ${CYAN}${wr_dir#$REPO_ROOT/}/tech-lead-assessment-brief.md${NC}"
  echo -e "  ┌────────────────────────────────────────────────────────────┐"
  echo -e "  │ @.cursor/agents/tech-lead-agent.md                        "
  echo -e "  │ @${wr_dir#$REPO_ROOT/}/tech-lead-assessment-brief.md     "
  echo -e "  └────────────────────────────────────────────────────────────┘"
  echo ""
}

_war_room_generate_digest() {
  local step="$1" step_name="$2" wr_dir="$3" mode="${4:-full}"
  local digest_file="$REPO_ROOT/workflows/dispatch/step-$step/context-digest.md"

  python3 - <<PY
import json
from pathlib import Path
from datetime import datetime

step = "$step"
step_name = "$step_name"
wr_dir = Path("$wr_dir")
state_path = Path("$STATE_FILE")
repo_root = Path("$REPO_ROOT")
mode = "$mode"

data = json.loads(state_path.read_text())
step_obj = data["steps"].get(step, {})

pm_analysis = ""
tl_assessment = ""
if mode == "full":
    pm_file = wr_dir / "pm-analysis.md"
    tl_file = wr_dir / "tech-lead-assessment.md"
    if pm_file.exists():
        pm_analysis = pm_file.read_text()
    if tl_file.exists():
        tl_assessment = tl_file.read_text()

# Gather prior decisions
prior_decisions = []
for n in range(1, int(step)):
    s = data["steps"].get(str(n), {})
    for d in s.get("decisions", []):
        if d.get("type") != "rejection":
            prior_decisions.append(f"- Step {n}: {d.get('description','')}")

# Open blockers
open_blockers = []
for n, s in data["steps"].items():
    if int(n) < int(step):
        for b in s.get("blockers", []):
            if not b.get("resolved"):
                open_blockers.append(f"- Step {n}: {b.get('description','')}")

digest = f"""# Context Digest — Step {step}: {step_name}
Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Mode: {mode}

---

## 🔍 Workflow Context (chạy để lấy live data — ưu tiên hơn file này)
\`\`\`
wf_step_context()    ← state + decisions + blockers trong 1 call (~300 tokens)
wf_state()           ← nếu chỉ cần step/status
\`\`\`
> Chỉ đọc các sections bên dưới nếu MCP tools unavailable.
> Graphify (query_graph) chỉ dùng cho code structure questions ở steps 4-8.

---

## 📋 Prior Decisions (last 10)
{chr(10).join(prior_decisions[-10:]) if prior_decisions else "- Chưa có decisions từ steps trước"}

## 🚧 Open Blockers
{chr(10).join(open_blockers) if open_blockers else "- Không có blockers mở"}

"""

if pm_analysis:
    digest += f"""## 🎯 PM Analysis (War Room Output)
{pm_analysis}

"""

if tl_assessment:
    digest += f"""## ⚙️ TechLead Assessment (War Room Output)
{tl_assessment}

"""

digest += f"""---
## 📌 How to Use This Digest
- **Layer 1**: Run `wf_step_context()` (cheapest, ~300 tokens, most current)
- **Layer 2**: Run `gitnexus_get_architecture()` if working on code (steps 4-8)
- **Layer 3**: Use `query_graph("specific code question")` for code structure only
- **Layer 4**: Read this file only for sections not covered above
- **Never** read all prior step reports individually
"""

Path("$digest_file").write_text(digest)
print("OK")
PY

  echo -e "${GREEN}✓${NC} Context digest: ${CYAN}${digest_file#$REPO_ROOT/}${NC}"
}
