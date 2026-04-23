#!/usr/bin/env bash

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
import json
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

require_initialized_workflow() {
  local step
  step=$(json_get "current_step")
  if [[ -z "$step" || "$step" == "0" ]]; then
    echo -e "${YELLOW}Workflow chưa được khởi tạo. Chạy: bash scripts/workflow.sh init${NC}" >&2
    exit 1
  fi
  echo "$step"
}

get_step_name() {
  local step="$1"
  python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps'][str($step)]['name'])"
}

get_step_agent() {
  local step="$1"
  python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps'][str($step)]['agent'])"
}

get_step_roles_csv() {
  local step="$1"
  python3 - <<PY
import json
d = json.load(open("$STATE_FILE"))
s = d["steps"].get(str($step), {})
roles = []
for r in [s.get("agent","")] + s.get("support_agents", []):
    r = (r or "").strip()
    if r and r not in roles:
        roles.append("@" + r)
print(", ".join(roles))
PY
}
