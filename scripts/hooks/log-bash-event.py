#!/usr/bin/env python3
"""
PostToolUse hook — Detect expensive bash commands, log as waste events.
Receives JSON on stdin from Claude Code hooks system.

Architecture note:
  This hook is the DETECTION layer (fires after bash runs, logs waste).
  shell-proxy.js is the PREVENTION layer (agents call wf_* tools instead of bash).
  Together they give full visibility: proxy tracks savings, hook tracks leakage.
"""

import json, sys, re, os
from pathlib import Path
from datetime import datetime

# Claude Code runs hooks with cwd = project root; FLOWCTL_PROJECT_ROOT overrides for manual use
REPO = Path(os.environ.get('FLOWCTL_PROJECT_ROOT', os.getcwd()))

# Prefer FLOWCTL_EVENTS_F / FLOWCTL_STATS_F set by flowctl.sh (v1.1+ home dir layout).
# Fallback: legacy .cache/mcp/ in project root for pre-v1.1 installs or hooks
# spawned without the flowctl env vars (e.g. direct Claude Code invocation).
_cache_default = REPO / ".cache" / "mcp"
EVENTS  = Path(os.environ.get('FLOWCTL_EVENTS_F', str(_cache_default / "events.jsonl")))
STATS_F = Path(os.environ.get('FLOWCTL_STATS_F',  str(_cache_default / "session-stats.json")))

def _read_project_identity() -> tuple:
    state_f = REPO / "flowctl-state.json"
    try:
        s = json.loads(state_f.read_text()) if state_f.exists() else {}
        return s.get("flow_id", ""), s.get("project_name", REPO.name)
    except Exception:
        return "", REPO.name

_PROJECT_ID, _PROJECT_NAME = _read_project_identity()

# (pattern, mcp_alternative, mcp_alt_tokens)
# mcp_alt_tokens = expected token cost of the MCP tool output.
# Must stay in sync with BASH_EQUIV in scripts/workflow/mcp/shell-proxy.js:
#   bash_equiv is what bash costs; mcp_alt_tokens is what MCP costs.
#   waste = output_tokens - mcp_alt_tokens
WASTEFUL_PATTERNS = [
    (r"git\s+log",                           "wf_git()",        110),
    (r"git\s+status",                        "wf_git()",        110),
    (r"git\s+diff",                          "wf_git()",        110),
    (r"git\s+branch",                        "wf_git()",        110),
    (r"cat\s+flowctl-state",                 "wf_state()",       95),
    (r"cat\s+.*\.json",                      "wf_read(path)",   400),
    (r"ls\s+-la?",                           "wf_files()",       90),
    (r"find\s+\.",                           "wf_files()",       90),
    (r"wc\s+-l",                             "wf_read(path)",   400),
    (r"python3.*flowctl-state",              "wf_state()",       95),
    (r"bash\s+scripts/flowctl\.sh\s+status", "wf_state()",       95),
]

def estimate_tokens(text: str) -> int:
    if not text: return 0
    chars = len(text)
    quotes = text.count('"')
    non_ascii = sum(1 for c in text if ord(c) > 127)
    json_ratio = quotes / max(chars, 1)
    viet_ratio = non_ascii / max(chars, 1)
    if json_ratio > 0.05: return chars // 3
    if viet_ratio > 0.15: return chars // 2
    return chars // 4

def ensure_cache():
    EVENTS.parent.mkdir(parents=True, exist_ok=True)

def log_event(event):
    ensure_cache()
    event["ts"]           = datetime.utcnow().isoformat() + "Z"
    event["project_id"]   = _PROJECT_ID
    event["project_name"] = _PROJECT_NAME
    with open(EVENTS, "a") as f:
        f.write(json.dumps(event) + "\n")
    update_stats(event)

def update_stats(event):
    stats = {}
    try:
        if STATS_F.exists():
            stats = json.loads(STATS_F.read_text())
    except Exception:
        pass
    stats["bash_waste_tokens"] = stats.get("bash_waste_tokens", 0) + event.get("waste_tokens", 0)
    stats["bash_calls"]        = stats.get("bash_calls", 0) + 1
    try:
        STATS_F.write_text(json.dumps(stats, indent=2))
    except Exception:
        pass

def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        sys.exit(0)

    # Claude Code PostToolUse hook format:
    # {"tool_name": "Bash", "tool_input": {"command": "..."}, "tool_response": {"output": "..."}}
    tool_name = data.get("tool_name", "")
    if tool_name != "Bash":
        sys.exit(0)

    tool_input    = data.get("tool_input", {}) or {}
    tool_response = data.get("tool_response", {}) or {}
    command = tool_input.get("command", "") or ""
    output  = str(tool_response.get("output", "") or "")

    output_tokens = estimate_tokens(output)

    # Check for wasteful patterns
    suggestion     = None
    waste_tokens   = 0
    mcp_alt_tokens = 0
    for pattern, alt, mcp_tok in WASTEFUL_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            mcp_alt_tokens = mcp_tok
            waste_tokens   = max(0, output_tokens - mcp_alt_tokens)
            suggestion     = alt
            break

    if waste_tokens > 0:
        # Print warning to stderr (visible in terminal, not injected into agent context)
        short_cmd = command[:60] + "…" if len(command) > 60 else command
        sys.stderr.write(
            f"\n⚠️  TOKEN WASTE DETECTED\n"
            f"   Command    : {short_cmd}\n"
            f"   Bash cost  : ~{output_tokens:,} tokens\n"
            f"   Use instead: {suggestion} (~{mcp_alt_tokens} tokens)\n"
            f"   Wasted     : ~{waste_tokens:,} tokens\n\n"
        )
        sys.stderr.flush()

    # Always log bash calls for monitoring
    log_event({
        "type":          "bash",
        "cmd":           command[:120],
        "output_tokens": output_tokens,
        "waste_tokens":  waste_tokens,
        "suggestion":    suggestion,
    })

    sys.exit(0)

if __name__ == "__main__":
    main()
