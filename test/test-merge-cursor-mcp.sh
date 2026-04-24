#!/usr/bin/env bash
# Unit-style tests for scripts/merge_cursor_mcp.py (merge / overwrite / invalid JSON).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE_PY="$REPO_ROOT/scripts/merge_cursor_mcp.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

run_merge() {
  python3 "$MERGE_PY" "$@"
}

assert_out() {
  local got="$1" want="$2" msg="$3"
  [[ "$got" == "$want" ]] || fail "$msg (expected MCP_STATUS=$want, got: $got)"
}

assert_keys() {
  local f="$1"
  shift
  python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
s = p.get('mcpServers', {})
for k in sys.argv[2:]:
    assert k in s, 'missing server %r' % (k,)
" "$f" "$@" || fail "JSON keys check failed for $f"
}

assert_no_key() {
  local f="$1" k="$2"
  python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert sys.argv[2] not in p.get('mcpServers', {}), 'unexpected key %r' % (sys.argv[2],)
" "$f" "$k" || fail "expected no key $k in $f"
}

[[ -f "$MERGE_PY" ]] || fail "missing $MERGE_PY"

# --- scaffold: fresh file ---
MCP="$TMP/1.json"
out="$(run_merge --scaffold myflowctl "$MCP")"
assert_out "$out" "MCP_STATUS=created" "scaffold empty path"
assert_keys "$MCP" shell-proxy flowctl-state
[[ "$(python3 -c "import json;print(json.load(open('$MCP'))['mcpServers']['shell-proxy']['command'])")" == "myflowctl" ]] \
  || fail "scaffold command injection"

# --- scaffold: merge keeps custom ---
cat > "$MCP" <<'JSON'
{"mcpServers":{"acme":{"command":"acme-cli"}}}
JSON
out="$(run_merge --scaffold myflowctl "$MCP")"
assert_out "$out" "MCP_STATUS=merged" "scaffold merge with custom"
assert_keys "$MCP" acme shell-proxy flowctl-state

# --- scaffold: unchanged when complete ---
out="$(run_merge --scaffold myflowctl "$MCP")"
assert_out "$out" "MCP_STATUS=unchanged" "scaffold second merge"

# --- scaffold: invalid JSON ---
echo '{' > "$MCP"
rc=0
out="$(python3 "$MERGE_PY" --scaffold myflowctl "$MCP" 2>/dev/null)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "invalid JSON exit (got $rc)"
assert_out "$out" "MCP_STATUS=invalid_json" "invalid json status line"

# --- scaffold: mcpServers not object ---
printf '%s\n' '{"mcpServers":[]}' > "$MCP"
rc=0
out="$(python3 "$MERGE_PY" --scaffold myflowctl "$MCP" 2>/dev/null)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "bad mcpServers type exit (got $rc)"
assert_out "$out" "MCP_STATUS=invalid_structure" "invalid mcpServers type"

# --- scaffold: overwrite drops extra servers ---
printf '%s\n' '{"mcpServers":{"acme":{"command":"x"}},"note":"keep"}' > "$MCP"
out="$(run_merge --overwrite --scaffold z "$MCP")"
assert_out "$out" "MCP_STATUS=overwritten" "overwrite status"
assert_keys "$MCP" shell-proxy flowctl-state
assert_no_key "$MCP" acme
python3 -c "import json;d=json.load(open('$MCP')); assert 'note' not in d" || fail "overwrite should drop extra top-level keys"

# --- setup: merge adds graphify etc. ---
MCP="$TMP/setup.json"
printf '%s\n' '{"mcpServers":{"shell-proxy":{"command":"flowctl","args":["mcp","--shell-proxy"]}}}' > "$MCP"
out="$(run_merge --setup "$MCP")"
assert_out "$out" "MCP_STATUS=merged" "setup merge partial"
assert_keys "$MCP" shell-proxy graphify gitnexus flowctl-state

# --- setup: no mcpServers key merges template + keeps top ---
printf '%s\n' '{"version":1}' > "$MCP"
out="$(run_merge --setup "$MCP")"
assert_out "$out" "MCP_STATUS=merged" "setup merge missing mcpServers"
python3 -c "import json;d=json.load(open('$MCP')); assert d.get('version')==1 and 'graphify' in d['mcpServers']" \
  || fail "setup should keep extra top-level keys"

pass "merge_cursor_mcp scenarios (scaffold + setup)"
exit 0
