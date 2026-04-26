#!/usr/bin/env bash

wf_budget_init_artifacts() {
  wf_ensure_dir "$(dirname "$BUDGET_STATE_FILE")"
  wf_ensure_dir "$(dirname "$BUDGET_EVENTS_FILE")"
  [[ -f "$BUDGET_STATE_FILE" ]] || cat > "$BUDGET_STATE_FILE" <<'JSON'
{
  "breaker": {
    "state": "closed",
    "reason": "",
    "opened_at": "",
    "last_transition_at": "",
    "cooldown_seconds": 300,
    "probe_role": ""
  },
  "run": {
    "flow_id": "",
    "run_id": "",
    "step": 0,
    "started_at": "",
    "consumed_tokens_est": 0,
    "consumed_runtime_seconds": 0,
    "consumed_cost_usd": 0.0,
    "last_updated_at": "",
    "override_used": false,
    "override_reason": "",
    "override_at": ""
  },
  "roles": {}
}
JSON
  [[ -f "$BUDGET_EVENTS_FILE" ]] || : > "$BUDGET_EVENTS_FILE"
}

wf_budget_prelaunch_check() {
  local step="$1"
  local role="$2"
  local flow_id="$3"
  local run_id="$4"
  local max_retries="$5"
  local dry_run="${6:-false}"
  local override_reason="${7:-}"
  local correlation_id="${8:-}"
  WF_BUDGET_STATE_FILE="$BUDGET_STATE_FILE" \
  WF_BUDGET_EVENTS_FILE="$BUDGET_EVENTS_FILE" \
  WF_BUDGET_POLICY_FILE="$BUDGET_POLICY_FILE" \
  WF_STATE_FILE="$STATE_FILE" \
  WF_STEP="$step" WF_ROLE="$role" WF_FLOW_ID="$flow_id" WF_WORKFLOW_ID="$flow_id" WF_RUN_ID="$run_id" \
  WF_MAX_RETRIES="$max_retries" WF_BUDGET_DRY_RUN="$dry_run" WF_OVERRIDE_REASON="$override_reason" WF_CORRELATION_ID="$correlation_id" python3 - <<'PY'
import json, os, fcntl, time, random
from datetime import datetime, timezone
from pathlib import Path

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_iso(ts):
    if not ts:
        return None
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None

state_path = Path(os.environ["WF_BUDGET_STATE_FILE"])
events_path = Path(os.environ["WF_BUDGET_EVENTS_FILE"])
policy_path = Path(os.environ["WF_BUDGET_POLICY_FILE"])
flow_state_path = Path(os.environ["WF_STATE_FILE"])

# Acquire exclusive lock on budget state before any read-check-write to prevent
# concurrent headless workers from bypassing the token cap.
_lock_path = str(state_path) + ".lock"
_lock_fd = open(_lock_path, "w")
_deadline = time.monotonic() + 15
while True:
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() > _deadline:
            import sys
            print("[budget] lock timeout; proceeding without exclusive lock", file=sys.stderr)
            break
        time.sleep(0.05 + random.uniform(0, 0.05))

def _unlock_and_exit(code=0):
    """Release budget lock and exit. Use instead of raise SystemExit() after lock acquisition."""
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
    except Exception:
        pass
    _lock_fd.close()
    raise SystemExit(code)

step = int(os.environ["WF_STEP"])
role = os.environ["WF_ROLE"]
flow_id = os.environ["WF_FLOW_ID"]
run_id = os.environ["WF_RUN_ID"]
max_retries = int(os.environ.get("WF_MAX_RETRIES", "3"))
dry_run = os.environ.get("WF_BUDGET_DRY_RUN", "false").lower() == "true"
override_reason = (os.environ.get("WF_OVERRIDE_REASON", "") or "").strip()
correlation_id = (os.environ.get("WF_CORRELATION_ID", "") or "").strip()
now = now_iso()
now_dt = parse_iso(now)

if not policy_path.exists():
    print("ALLOW|budget policy missing; guard disabled")
    _unlock_and_exit(0)

state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
policy = json.loads(policy_path.read_text(encoding="utf-8"))
if not policy.get("enabled", True):
    print("ALLOW|budget policy disabled")
    _unlock_and_exit(0)

defaults = policy.get("defaults", {})
run_caps = defaults.get("run_caps", {})
role_caps = defaults.get("role_caps", {})
estimate = defaults.get("estimate_per_launch", {})
thresholds = defaults.get("soft_thresholds", [0.7, 0.9])
breaker_cfg = defaults.get("circuit_breaker", {})
role_overrides = policy.get("roles", {}).get(role, {})
if role_overrides:
    role_caps = {**role_caps, **(role_overrides.get("role_caps", {}))}
    estimate = {**estimate, **(role_overrides.get("estimate_per_launch", {}))}

state.setdefault("breaker", {})
state.setdefault("run", {})
state.setdefault("roles", {})
breaker = state["breaker"]
run = state["run"]
roles = state["roles"]

cooldown_seconds = int(breaker_cfg.get("cooldown_seconds", breaker.get("cooldown_seconds", 300)))
breaker["cooldown_seconds"] = cooldown_seconds
breaker.setdefault("state", "closed")
breaker.setdefault("probe_role", "")
breaker.setdefault("opened_at", "")
breaker.setdefault("reason", "")
breaker.setdefault("last_transition_at", "")

if run.get("run_id") != run_id or run.get("step") != step:
    run.update(
        {
            "flow_id": flow_id,
            "run_id": run_id,
            "step": step,
            "started_at": now,
            "consumed_tokens_est": 0,
            "consumed_runtime_seconds": 0,
            "consumed_cost_usd": 0.0,
            "last_updated_at": now,
            "override_used": False,
            "override_reason": "",
            "override_at": "",
        }
    )
    roles.clear()
    breaker.update(
        {
            "state": "closed",
            "reason": "",
            "opened_at": "",
            "last_transition_at": now,
            "probe_role": "",
        }
    )

events = []
opened_at_dt = parse_iso(breaker.get("opened_at", ""))
if breaker["state"] == "open" and opened_at_dt is not None and now_dt is not None:
    elapsed = (now_dt - opened_at_dt).total_seconds()
    if elapsed >= cooldown_seconds:
        breaker["state"] = "half-open"
        breaker["last_transition_at"] = now
        breaker["probe_role"] = ""
        events.append({
            "timestamp": now,
            "type": "breaker_transition",
            "to_state": "half-open",
            "reason": "cooldown_elapsed",
            "flow_id": flow_id,
            "run_id": run_id,
            "step": step,
            "correlation_id": correlation_id,
        })

if breaker["state"] == "open":
    override_used = bool(run.get("override_used", False))
    if override_reason and not override_used:
        run["override_used"] = True
        run["override_reason"] = override_reason
        run["override_at"] = now
        breaker["state"] = "half-open"
        breaker["reason"] = "override_from_open"
        breaker["probe_role"] = role
        breaker["last_transition_at"] = now
        events.append({
            "timestamp": now,
            "type": "budget_override_used",
            "flow_id": flow_id,
            "run_id": run_id,
            "step": step,
            "role": role,
            "reason": override_reason,
            "from_breaker": "open",
            "correlation_id": correlation_id,
        })
    elif override_reason and override_used:
        print("BLOCK|budget_override_already_used")
        _unlock_and_exit(0)
    elif not override_reason:
        if not dry_run:
            state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
            if events:
                with events_path.open("a", encoding="utf-8") as f:
                    for ev in events:
                        f.write(json.dumps(ev, ensure_ascii=False) + "\n")
        print("BLOCK|breaker=open")
        _unlock_and_exit(0)
if breaker["state"] == "open":
    if not dry_run:
        state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
        if events:
            with events_path.open("a", encoding="utf-8") as f:
                for ev in events:
                    f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    print("BLOCK|breaker=open")
    _unlock_and_exit(0)

if breaker["state"] == "half-open":
    probe_role = (breaker.get("probe_role") or "").strip()
    if probe_role and probe_role != role:
        print(f"BLOCK|breaker=half-open probe_role={probe_role}")
        _unlock_and_exit(0)
    if not probe_role:
        breaker["probe_role"] = role
        breaker["last_transition_at"] = now
        events.append({
            "timestamp": now,
            "type": "probe_assigned",
            "flow_id": flow_id,
            "run_id": run_id,
            "step": step,
            "role": role,
            "correlation_id": correlation_id,
        })

consumed_tokens = int(run.get("consumed_tokens_est", 0))
consumed_runtime = int(run.get("consumed_runtime_seconds", 0))
consumed_cost = float(run.get("consumed_cost_usd", 0.0))
role_row = roles.setdefault(role, {"tokens_est": 0, "runtime_seconds": 0, "cost_usd": 0.0, "attempt_count": 0, "status": "pending"})

delta_tokens = int(estimate.get("tokens_est", 2500))
delta_runtime = int(estimate.get("runtime_seconds", 300))
delta_cost = float(estimate.get("cost_usd", 0.02))

projected_tokens = consumed_tokens + delta_tokens
projected_runtime = consumed_runtime + delta_runtime
projected_cost = consumed_cost + delta_cost

role_projected_tokens = int(role_row.get("tokens_est", 0)) + delta_tokens
role_projected_runtime = int(role_row.get("runtime_seconds", 0)) + delta_runtime
role_projected_cost = float(role_row.get("cost_usd", 0.0)) + delta_cost
role_projected_attempts = int(role_row.get("attempt_count", 0)) + 1

breaches = []
if projected_tokens > int(run_caps.get("max_tokens_total", 100000)):
    breaches.append("max_tokens_total")
if projected_runtime > int(run_caps.get("max_runtime_seconds", 3600)):
    breaches.append("max_runtime_seconds")
if projected_cost > float(run_caps.get("max_cost_usd", 5.0)):
    breaches.append("max_cost_usd")
if role_projected_tokens > int(role_caps.get("max_tokens_per_role", 40000)):
    breaches.append("max_tokens_per_role")
if role_projected_runtime > int(role_caps.get("max_runtime_per_role_seconds", 1800)):
    breaches.append("max_runtime_per_role_seconds")
if role_projected_cost > float(role_caps.get("max_cost_per_role_usd", 2.0)):
    breaches.append("max_cost_per_role_usd")
if role_projected_attempts > max_retries:
    breaches.append("max_retries")

override_used = bool(run.get("override_used", False))
if breaches and override_reason and not override_used:
    events.append({
        "timestamp": now,
        "type": "budget_override_used",
        "flow_id": flow_id,
        "run_id": run_id,
        "step": step,
        "role": role,
        "reason": override_reason,
        "breaches": breaches,
        "correlation_id": correlation_id,
    })
    run["override_used"] = True
    run["override_reason"] = override_reason
    run["override_at"] = now
    breaches = []

if breaches and override_reason and override_used:
    print("BLOCK|budget_override_already_used")
    _unlock_and_exit(0)

if breaches:
    # Exponential backoff on cooldown: each re-open from half-open increases
    # cooldown by 1.5x, capped at 1800s. Prevents thrashing between half-open/open.
    prev_cooldown = int(breaker.get("cooldown_seconds", cooldown_seconds))
    was_half_open = (breaker.get("state") == "half-open")
    if was_half_open:
        new_cooldown = min(int(prev_cooldown * 1.5), 1800)
    else:
        new_cooldown = cooldown_seconds
    breaker["state"] = "open"
    breaker["opened_at"] = now
    breaker["last_transition_at"] = now
    breaker["reason"] = ",".join(breaches)
    breaker["probe_role"] = ""
    breaker["cooldown_seconds"] = new_cooldown
    events.append({
        "timestamp": now,
        "type": "breaker_opened",
        "flow_id": flow_id,
        "run_id": run_id,
        "step": step,
        "role": role,
        "breaches": breaches,
        "cooldown_seconds": new_cooldown,
        "correlation_id": correlation_id,
    })
    if not dry_run:
        if flow_state_path.exists():
            ws = json.loads(flow_state_path.read_text(encoding="utf-8"))
            s = ws.get("steps", {}).get(str(step), {})
            s["status"] = "blocked"
            blockers = s.setdefault("blockers", [])
            blockers.append({
                "id": f"BUDGET-{now.replace(':','').replace('-','')}",
                "description": f"Budget breaker opened: {','.join(breaches)}",
                "created_at": now,
                "resolved": False,
                "source": "budget-guardrail",
            })
            ws["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            flow_state_path.write_text(json.dumps(ws, indent=2, ensure_ascii=False), encoding="utf-8")
        state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
        with events_path.open("a", encoding="utf-8") as f:
            for ev in events:
                f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    print(f"BLOCK|cap_breached={','.join(breaches)}")
    _unlock_and_exit(0)

if dry_run:
    print(
        f"ALLOW|tokens={projected_tokens}/{int(run_caps.get('max_tokens_total', 100000))}"
        f" runtime={projected_runtime}/{int(run_caps.get('max_runtime_seconds', 3600))}"
        f" cost={round(projected_cost, 4)}/{float(run_caps.get('max_cost_usd', 5.0))}"
        " dry_run=true"
    )
    _unlock_and_exit(0)

run["consumed_tokens_est"] = projected_tokens
run["consumed_runtime_seconds"] = projected_runtime
run["consumed_cost_usd"] = round(projected_cost, 6)
run["last_updated_at"] = now
role_row["tokens_est"] = role_projected_tokens
role_row["runtime_seconds"] = role_projected_runtime
role_row["cost_usd"] = round(role_projected_cost, 6)
role_row["attempt_count"] = role_projected_attempts
role_row["status"] = "reserved"
role_row["updated_at"] = now
role_row["correlation_id"] = correlation_id
run["last_correlation_id"] = correlation_id

for t in thresholds:
    try:
        threshold = float(t)
    except Exception:
        continue
    if threshold <= 0:
        continue
    max_tokens_total = max(1, int(run_caps.get("max_tokens_total", 100000)))
    ratio = projected_tokens / max_tokens_total
    if ratio >= threshold:
        events.append({
            "timestamp": now,
            "type": "soft_alert",
            "metric": "tokens",
            "threshold": threshold,
            "value": projected_tokens,
            "max": max_tokens_total,
            "flow_id": flow_id,
            "run_id": run_id,
            "step": step,
            "role": role,
            "correlation_id": correlation_id,
        })

state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
if events:
    with events_path.open("a", encoding="utf-8") as f:
        for ev in events:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")

result = (
    f"ALLOW|tokens={projected_tokens}/{int(run_caps.get('max_tokens_total', 100000))}"
    f" runtime={projected_runtime}/{int(run_caps.get('max_runtime_seconds', 3600))}"
    f" cost={round(projected_cost, 4)}/{float(run_caps.get('max_cost_usd', 5.0))}"
)

# Release budget lock before printing result
try:
    fcntl.flock(_lock_fd, fcntl.LOCK_UN)
except Exception:
    pass
_lock_fd.close()

print(result)
PY
}

wf_budget_mark_role_completed() {
  local step="$1"
  local role="$2"
  WF_BUDGET_STATE_FILE="$BUDGET_STATE_FILE" \
  WF_BUDGET_EVENTS_FILE="$BUDGET_EVENTS_FILE" \
  WF_STEP="$step" WF_ROLE="$role" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

path = Path(os.environ["WF_BUDGET_STATE_FILE"])
events_path = Path(os.environ["WF_BUDGET_EVENTS_FILE"])
step = int(os.environ["WF_STEP"])
role = os.environ["WF_ROLE"]
if not path.exists():
    raise SystemExit(0)
state = json.loads(path.read_text(encoding="utf-8"))
run = state.get("run", {})
if int(run.get("step", 0)) != step:
    raise SystemExit(0)
roles = state.setdefault("roles", {})
row = roles.setdefault(role, {})
row["status"] = "done"
row["updated_at"] = now_iso()
breaker = state.setdefault("breaker", {})
if breaker.get("state") == "half-open" and breaker.get("probe_role") == role:
    breaker["state"] = "closed"
    breaker["reason"] = ""
    breaker["opened_at"] = ""
    breaker["probe_role"] = ""
    breaker["last_transition_at"] = now_iso()
    ev = {
        "timestamp": now_iso(),
        "type": "breaker_transition",
        "to_state": "closed",
        "reason": "half_open_probe_succeeded",
        "flow_id": run.get("flow_id", ""),
        "run_id": run.get("run_id", ""),
        "step": step,
        "role": role,
    }
    with events_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")
path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
PY
}

wf_budget_manual_reset() {
  local reason="${1:-manual reset}"
  WF_BUDGET_STATE_FILE="$BUDGET_STATE_FILE" \
  WF_BUDGET_EVENTS_FILE="$BUDGET_EVENTS_FILE" \
  WF_REASON="$reason" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

state_path = Path(os.environ["WF_BUDGET_STATE_FILE"])
events_path = Path(os.environ["WF_BUDGET_EVENTS_FILE"])
reason = os.environ.get("WF_REASON", "manual reset")
if not state_path.exists():
    print("BUDGET_RESET|state_missing")
    raise SystemExit(0)

state = json.loads(state_path.read_text(encoding="utf-8"))
run = state.get("run", {})
breaker = state.setdefault("breaker", {})
breaker["state"] = "closed"
breaker["reason"] = reason
breaker["opened_at"] = ""
breaker["probe_role"] = ""
breaker["last_transition_at"] = now_iso()
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")

events_path.parent.mkdir(parents=True, exist_ok=True)
with events_path.open("a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": now_iso(),
        "type": "breaker_transition",
        "to_state": "closed",
        "reason": reason,
        "flow_id": run.get("flow_id", ""),
        "run_id": run.get("run_id", ""),
        "step": run.get("step", 0),
    }, ensure_ascii=False) + "\n")

print("BUDGET_RESET|breaker=closed")
PY
}
