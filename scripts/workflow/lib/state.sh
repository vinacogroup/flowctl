#!/usr/bin/env bash

wf_json_get() {
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

wf_json_set() {
  # $1 = dot-path, $2 = value (string), $3 = type (string|number|null)
  python3 -c "
import json, fcntl
from datetime import datetime

with open('$STATE_FILE', 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
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

    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
}

wf_json_append() {
  # $1 = dot-path to array, $2 = JSON object string
  python3 -c "
import json, fcntl
from datetime import datetime

with open('$STATE_FILE', 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    data = json.load(f)

    keys = '$1'.split('.')
    obj = data
    for k in keys[:-1]:
        obj = obj[k]

    arr = obj.setdefault(keys[-1], [])
    arr.append(json.loads('''$2'''))

    data['updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
}

wf_require_initialized_flow() {
  local step
  step=$(wf_json_get "current_step")
  if [[ -z "$step" || "$step" == "0" ]]; then
    echo -e "${YELLOW}Workflow chưa được khởi tạo. Chạy: flowctl init${NC}" >&2
    exit 1
  fi
  echo "$step"
}

# Canonical name in older modules / docs
wf_require_initialized_workflow() { wf_require_initialized_flow "$@"; }

wf_get_step_name() {
  local step="$1"
  python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps'][str($step)]['name'])"
}

wf_get_step_agent() {
  local step="$1"
  python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['steps'][str($step)]['agent'])"
}

wf_get_step_roles_csv() {
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

# Backward-compatible aliases (Phase 5.2)
json_get() { wf_warn_deprecated "json_get" "wf_json_get"; wf_json_get "$@"; }
json_set() { wf_warn_deprecated "json_set" "wf_json_set"; wf_json_set "$@"; }
json_append() { wf_warn_deprecated "json_append" "wf_json_append"; wf_json_append "$@"; }
require_initialized_flow() { wf_warn_deprecated "require_initialized_flow" "wf_require_initialized_flow"; wf_require_initialized_flow "$@"; }
require_initialized_workflow() { wf_warn_deprecated "require_initialized_workflow" "wf_require_initialized_workflow"; wf_require_initialized_workflow "$@"; }
get_step_name() { wf_warn_deprecated "get_step_name" "wf_get_step_name"; wf_get_step_name "$@"; }
get_step_agent() { wf_warn_deprecated "get_step_agent" "wf_get_step_agent"; wf_get_step_agent "$@"; }
get_step_roles_csv() { wf_warn_deprecated "get_step_roles_csv" "wf_get_step_roles_csv"; wf_get_step_roles_csv "$@"; }
