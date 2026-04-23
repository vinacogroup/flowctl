#!/usr/bin/env bash

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
  local target="${1:-}"
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
