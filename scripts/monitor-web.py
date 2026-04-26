#!/usr/bin/env python3
"""Token Monitor - web dashboard for MCP shell proxy.
Opens browser at http://localhost:3170. Ctrl+C to stop.
"""

import json, sys, signal, socket, socketserver, threading, webbrowser, time, queue as _queue, os as _os
from pathlib import Path
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# REPO = project root where the user ran `flowctl monitor`.
# For global installs, __file__ is inside the npm global dir — use FLOWCTL_PROJECT_ROOT
# (set by flowctl.sh) or cwd as the project root, not the script directory.
_script_parent = Path(__file__).resolve().parent.parent
_cwd_root      = Path(_os.getcwd())

# Windows/Git Bash: env vars may contain MSYS paths (/c/Users/...) that are not
# valid Windows paths for pathlib. Normalize via resolve() after constructing.
def _normalize_path(p: Path) -> Path:
    """Resolve MSYS/mixed-case paths to a canonical OS path."""
    try:
        return p.resolve()
    except Exception:
        return p

_env_root = _normalize_path(Path(_os.environ["FLOWCTL_PROJECT_ROOT"])) \
    if "FLOWCTL_PROJECT_ROOT" in _os.environ else None

def _detect_repo() -> Path:
    # Priority: env var > cwd (if has state file) > script parent (local install)
    if _env_root is not None:
        if not _env_root.exists():
            import sys
            print(f"[monitor-web] WARNING: FLOWCTL_PROJECT_ROOT={_env_root!r} does not exist; "
                  f"falling back to cwd={_cwd_root!r}", file=sys.stderr)
        elif not _os.access(_env_root, _os.R_OK):
            import sys
            print(f"[monitor-web] WARNING: FLOWCTL_PROJECT_ROOT={_env_root!r} is not readable; "
                  f"falling back to cwd={_cwd_root!r}", file=sys.stderr)
        elif (_env_root / "flowctl-state.json").exists():
            return _env_root
        else:
            import sys
            print(f"[monitor-web] WARNING: FLOWCTL_PROJECT_ROOT={_env_root!r} has no "
                  f"flowctl-state.json; falling back to cwd={_cwd_root!r}", file=sys.stderr)
    if (_cwd_root / "flowctl-state.json").exists():
        return _cwd_root
    return _script_parent  # local install fallback

REPO         = _detect_repo()
STATE_F      = REPO / "flowctl-state.json"

# Prefer FLOWCTL_CACHE_DIR / _EVENTS_F / _STATS_F set by flowctl.sh (v1.1+ home dir layout).
# Fallback: legacy .cache/mcp/ inside the project root (pre-v1.1 or no env vars).
_legacy_cache = REPO / ".cache" / "mcp"
CACHE    = _normalize_path(Path(_os.environ.get("FLOWCTL_CACHE_DIR", str(_legacy_cache))))
EVENTS_F = _normalize_path(Path(_os.environ.get("FLOWCTL_EVENTS_F",  str(CACHE / "events.jsonl"))))
STATS_F  = _normalize_path(Path(_os.environ.get("FLOWCTL_STATS_F",   str(CACHE / "session-stats.json"))))

THRESHOLDS   = {"bash_waste_per_event": 400, "cache_hit_rate_min": 0.65}
STEP_BUDGETS  = {1:8000,2:12000,3:10000,4:18000,5:18000,6:14000,7:12000,8:10000,9:8000}

# -- Global registry paths (for --global mode) ---------------------------------

FLOWCTL_HOME    = Path.home() / ".flowctl"
REGISTRY_GLOBAL = FLOWCTL_HOME / "registry.json"
GLOBAL_MODE     = False  # set by --global flag

def load_registry() -> dict:
    try:
        return json.loads(REGISTRY_GLOBAL.read_text()) if REGISTRY_GLOBAL.exists() else {"projects": {}}
    except Exception:
        return {"projects": {}}

def _enrich_from_meta(proj: dict) -> dict:
    """Try to fill missing cache_dir from ~/.flowctl/projects/*/meta.json (v1.1+ layout)."""
    if proj.get("cache_dir"):
        return proj
    pid = proj.get("project_id", "")
    if not pid:
        return proj
    # Search home dir for a meta.json whose project_id matches
    projects_dir = FLOWCTL_HOME / "projects"
    if projects_dir.exists():
        for entry in projects_dir.iterdir():
            meta_f = entry / "meta.json"
            if meta_f.exists():
                try:
                    meta = json.loads(meta_f.read_text())
                    if meta.get("project_id") == pid:
                        proj = dict(proj)
                        proj["cache_dir"]   = meta.get("cache_dir",   str(entry / "cache"))
                        proj["runtime_dir"] = meta.get("runtime_dir", str(entry / "runtime"))
                        return proj
                except Exception:
                    pass
    return proj

def discover_projects() -> dict:
    """Discover all projects from ~/.flowctl/projects/*/meta.json + REPO fallback.

    Primary source: meta.json files written by `flowctl init` (v1.1+ layout).
    Secondary source: legacy registry.json (pre-v1.1 backward compat).
    Fallback: current REPO's flowctl-state.json (local install / in-project run).
    """
    now_ts = datetime.now(timezone.utc).timestamp()
    result: dict = {}

    # --- Primary: scan ~/.flowctl/projects/*/meta.json ---
    # L-08: project membership is determined solely by meta.json presence.
    # events.jsonl is only consulted for the last-seen timestamp; a missing file
    # yields last_ts=0 (project never active) but the project is still included.
    projects_dir = FLOWCTL_HOME / "projects"
    if projects_dir.exists():
        for entry in projects_dir.iterdir():
            if not entry.is_dir():
                continue
            meta_f = entry / "meta.json"
            if not meta_f.exists():
                continue
            try:
                meta      = json.loads(meta_f.read_text())
                pid       = meta.get("project_id")
                if not pid:
                    continue
                cache_dir = meta.get("cache_dir", str(entry / "cache"))
                ef        = Path(cache_dir) / "events.jsonl"
                last_ts   = ef.stat().st_mtime if ef.exists() else 0  # missing = never active
                result[pid] = {
                    "project_id":   pid,
                    "project_name": meta.get("project_name", entry.name),
                    "path":         meta.get("path", ""),
                    "cache_dir":    cache_dir,
                    "runtime_dir":  meta.get("runtime_dir", str(entry / "runtime")),
                    "active":       (now_ts - last_ts) < 600,
                    "last_seen":    datetime.fromtimestamp(last_ts, tz=timezone.utc).isoformat() if last_ts else "",
                }
            except Exception:
                pass

    # --- Secondary: legacy registry.json (backward compat) ---
    for pid, proj in load_registry().get("projects", {}).items():
        if pid not in result:
            try:
                last_ts = datetime.fromisoformat(proj["last_seen"].replace("Z", "+00:00")).timestamp()
            except Exception:
                last_ts = 0
            proj = dict(proj)
            proj["active"] = (now_ts - last_ts) < 600
            proj = _enrich_from_meta(proj)
            result[pid] = proj

    # --- Fallback: current REPO (in-project run or local install) ---
    local_state = REPO / "flowctl-state.json"
    if local_state.exists() and not any(p.get("path") == str(REPO) for p in result.values()):
        try:
            s   = json.loads(local_state.read_text())
            pid = s.get("flow_id", "_local")
            if pid not in result:
                result[pid] = {
                    "project_id":   pid,
                    "project_name": s.get("project_name", REPO.name),
                    "path":         str(REPO),
                    "cache_dir":    _os.environ.get("FLOWCTL_CACHE_DIR", str(CACHE)),
                    "active":       True,
                    "last_seen":    datetime.now(timezone.utc).isoformat(),
                }
        except Exception:
            pass

    return result

# -- SSE broadcaster (push to all connected browser clients) -------------------

class SSEBroadcaster:
    """Thread-safe: push data dict into the queue of each connected SSE client."""
    def __init__(self):
        self._clients: list = []
        self._lock = threading.Lock()

    def subscribe(self):
        q = _queue.Queue(maxsize=50)
        with self._lock:
            self._clients.append(q)
        return q

    def unsubscribe(self, q):
        with self._lock:
            self._clients = [c for c in self._clients if c is not q]

    def broadcast(self, data: dict):
        msg = f"data: {json.dumps(data)}\n\n"
        dead = []
        with self._lock:
            clients = list(self._clients)
        for q in clients:
            try:
                q.put_nowait(msg)
            except _queue.Full:
                # Client queue is full — consider it dead (too slow to consume)
                dead.append(q)
            except Exception as e:
                # Unexpected error: log to stderr so it's visible, still remove client
                import sys
                print(f"[monitor-web] broadcast error for client {q}: {e}", file=sys.stderr)
                dead.append(q)
        for q in dead:
            self.unsubscribe(q)

BROADCASTER = SSEBroadcaster()

# -- File watcher (poll mtime every 200ms, no external deps) -------------------

class FileWatcher(threading.Thread):
    """
    Poll file mtimes. On change → broadcast typed SSE event:
      {type:"project_update", project_id, data}
    paths_map: {filepath: meta_dict | None}
      None  → current project (calls build_api_data(), uses STATE_F for project_id)
      dict  → {project_id, cache_dir, state_path} for a non-current project
    Interval: 200ms for current project files, 500ms for others.
    """
    def __init__(self, paths_map: dict, current_interval: float = 0.2, other_interval: float = 0.5):
        super().__init__(daemon=True, name="FileWatcher")
        self._map     = dict(paths_map)   # {path: meta | None}
        self._cur_iv  = current_interval
        self._oth_iv  = other_interval
        self._mtimes: dict = {}
        self._lock    = threading.Lock()

    def add_paths(self, paths_map: dict):
        with self._lock:
            self._map.update(paths_map)

    def run(self):
        cycle = 0
        while True:
            check_other = (cycle % max(1, round(self._oth_iv / self._cur_iv)) == 0)
            with self._lock:
                items = list(self._map.items())
            for path, meta in items:
                is_current = (meta is None)
                if not is_current and not check_other:
                    continue
                try:
                    mtime = _os.stat(path).st_mtime
                    if self._mtimes.get(path) != mtime:
                        self._mtimes[path] = mtime
                        try:
                            if is_current:
                                data = build_api_data()
                                pid  = data.get("project_id", "")
                            else:
                                pid  = meta["project_id"]
                                data = build_project_data(
                                    meta["cache_dir"], meta["state_path"]
                                )
                            BROADCASTER.broadcast({"type": "project_update", "project_id": pid, "data": data})
                        except Exception:
                            pass
                except FileNotFoundError:
                    pass
            cycle += 1
            time.sleep(self._cur_iv)

# -- Data loading (same sources as monitor.py) ---------------------------------

def load_stats():
    try: return json.loads(STATS_F.read_text()) if STATS_F.exists() else {}
    except: return {}

def flatten_stats(stats: dict) -> dict:
    """Normalize {all_time:{...}} (new schema) and flat (legacy schema) to a common shape."""
    at = stats.get("all_time", stats)  # fall back to root for legacy flat schema
    cs = stats.get("current_session", {})
    return {
        "total_consumed_tokens": at.get("total_consumed_tokens", 0),
        "total_saved_tokens":    at.get("total_saved_tokens",    0),
        "total_cost_usd":        at.get("total_cost_usd",        0),
        "total_saved_usd":       at.get("total_saved_usd",       0),
        "bash_waste_tokens":     at.get("bash_waste_tokens",     0),
        "tools":                 at.get("tools",                 {}),
        "session_start":         cs.get("session_start") or stats.get("session_start"),
        "daily":                 stats.get("daily", {}),
    }

def load_events(last_n=100):
    if not EVENTS_F.exists(): return []
    try:
        result = []
        for line in EVENTS_F.read_text().strip().split("\n")[-last_n:]:
            if line.strip():
                try: result.append(json.loads(line))
                except: pass
        return result
    except: return []

def load_flow_state():
    try: return json.loads(STATE_F.read_text()) if STATE_F.exists() else {}
    except: return {}

# -- Computation ---------------------------------------------------------------

def group_into_turns(events, gap_sec=2.0):
    turns, current = [], []
    for e in events:
        try: ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).timestamp()
        except: ts = 0
        e["_ts"] = ts
        if current and ts - current[-1]["_ts"] > gap_sec:
            turns.append(current); current = []
        current.append(e)
    if current: turns.append(current)
    return turns

def compute_turn_summary(turn):
    return dict(
        ts        = turn[-1].get("ts", "")[:19].replace("T", " "),
        agent     = next((e.get("agent","?") for e in turn if e.get("agent","unknown") != "unknown"), "?"),
        tools     = [e.get("tool","") for e in turn if e.get("type") == "mcp"],
        bash_cmds = [e.get("cmd","") for e in turn if e.get("type") == "bash"],
        saved     = sum(e.get("saved_tokens",0) for e in turn),
        consumed  = sum(e.get("output_tokens",0) for e in turn),
        waste     = sum(e.get("waste_tokens",0) for e in turn),
        cost      = sum(e.get("cost_usd",0) for e in turn),
    )

def calc_hit_rate(stats):
    tools = stats.get("tools", {})
    calls = sum(t.get("calls",0) for t in tools.values())
    hits  = sum(t.get("hits",0) for t in tools.values())
    return hits / calls if calls else 0.0

def session_duration(stats):
    start = stats.get("session_start")
    if not start: return "--:--:--"
    try:
        delta = datetime.now(timezone.utc) - datetime.fromisoformat(start.replace("Z","+00:00"))
        h, rem = divmod(int(delta.total_seconds()), 3600)
        m, s   = divmod(rem, 60)
        return f"{h:02d}:{m:02d}:{s:02d}"
    except: return "--:--:--"

def check_alerts(stats, events):
    alerts = []
    hr = calc_hit_rate(stats)
    if 0 < hr < THRESHOLDS["cache_hit_rate_min"]:
        alerts.append(f"Cache hit rate {hr:.0%} below {THRESHOLDS['cache_hit_rate_min']:.0%} threshold")
    waste = sum(e.get("waste_tokens",0) for e in events[-20:] if e.get("type") == "bash")
    if waste > THRESHOLDS["bash_waste_per_event"] * 3:
        alerts.append(f"High bash waste recently: ~{waste:,} tok - use MCP tools instead")
    return alerts

def build_calls_log(events, last_n=40):
    """Individual proxy call log — newest first."""
    mcp_events = [e for e in events if e.get("type") == "mcp"]
    result = []
    for e in reversed(mcp_events[-last_n:]):
        result.append({
            "ts":         (e.get("ts",""))[11:19],   # HH:MM:SS
            "tool":       e.get("tool","?"),
            "cache":      e.get("cache","?"),         # "hit" | "miss"
            "out_tok":    e.get("output_tokens", 0),
            "bash_equiv": e.get("bash_equiv", 0),
            "saved_tok":  e.get("saved_tokens", 0),
            "dur_ms":     e.get("duration_ms", 0),
            "agent":      e.get("agent","?"),
        })
    return result

def build_project_data(cache_dir: str, state_path: str) -> dict:
    """Build dashboard data for any project by its cache_dir and state_path."""
    _cache  = Path(cache_dir)
    _events = _cache / "events.jsonl"
    _stats  = _cache / "session-stats.json"
    _state  = Path(state_path)

    raw_stats = {}
    try: raw_stats = json.loads(_stats.read_text()) if _stats.exists() else {}
    except: pass

    events = []
    if _events.exists():
        try:
            for line in _events.read_text().strip().split("\n")[-100:]:
                if line.strip():
                    try: events.append(json.loads(line))
                    except: pass
        except: pass

    wf = {}
    try: wf = json.loads(_state.read_text()) if _state.exists() else {}
    except: pass

    stats = flatten_stats(raw_stats)
    step  = wf.get("current_step", 0)
    today = datetime.now().strftime("%Y-%m-%d")
    day   = raw_stats.get("daily", {}).get(today, {})

    open_blockers = len([
        b for st in wf.get("steps", {}).values()
        for b in st.get("blockers", []) if not b.get("resolved")
    ])

    tools_data = [
        {"name": n, "calls": t.get("calls",0), "hits": t.get("hits",0),
         "rate": round(t.get("hits",0)/t.get("calls",1),3) if t.get("calls") else 0,
         "saved": t.get("saved",0)}
        for n, t in sorted(stats["tools"].items(), key=lambda x: -x[1].get("calls",0))
    ]

    return {
        "project_id":     wf.get("flow_id", ""),
        "project_name":   wf.get("project_name", Path(cache_dir).parent.name),
        "step":           step,
        "step_name":      (wf.get("steps", {}).get(str(step), {}) or {}).get("name", ""),
        "consumed":       stats["total_consumed_tokens"],
        "saved":          stats["total_saved_tokens"],
        "cost_usd":       round(stats["total_cost_usd"], 6),
        "saved_usd":      round(stats["total_saved_usd"], 6),
        "waste_tok":      stats["bash_waste_tokens"],
        "today_consumed": day.get("consumed", 0),
        "today_saved":    day.get("saved",    0),
        "open_blockers":  open_blockers,
        "tools":          tools_data,
        "calls":          build_calls_log(events),
        "activity":       [compute_turn_summary(t) for t in group_into_turns(events)[-5:]],
    }

def build_api_data():
    """Build complete JSON payload for the dashboard."""
    raw_stats = load_stats()
    stats     = flatten_stats(raw_stats)
    events    = load_events()
    wf        = load_flow_state()
    turns     = group_into_turns(events)
    alerts    = check_alerts(stats, events)

    step     = wf.get("current_step", 0)
    consumed = stats["total_consumed_tokens"]
    saved    = stats["total_saved_tokens"]
    budget   = STEP_BUDGETS.get(step, 12000)
    today    = datetime.now().strftime("%Y-%m-%d")
    day      = raw_stats.get("daily", {}).get(today, {})

    tools_data = [
        {
            "name":  name,
            "calls": t.get("calls",0),
            "hits":  t.get("hits",0),
            "rate":  round(t.get("hits",0) / t.get("calls",1), 3) if t.get("calls",0) else 0,
            "saved": t.get("saved",0),
        }
        for name, t in sorted((stats.get("tools") or {}).items(), key=lambda x: -x[1].get("calls",0))
    ]

    return {
        "step":           step,
        "step_name":      (wf.get("steps",{}).get(str(step),{}) or {}).get("name", ""),
        "project_id":     wf.get("flow_id", ""),
        "project_name":   wf.get("project_name", ""),
        "consumed":       consumed,
        "saved":          saved,
        "cost_usd":       round(stats["total_cost_usd"], 6),
        "saved_usd":      round(stats["total_saved_usd"], 6),
        "waste_tok":      stats["bash_waste_tokens"],
        "eff_pct":        round(saved / (consumed + saved) * 100, 1) if (consumed + saved) else 0,
        "budget":         budget,
        "bud_pct":        round(consumed / budget * 100, 1) if budget else 0,
        "duration":       session_duration(stats),
        "today_consumed": day.get("consumed", 0),
        "today_saved":    day.get("saved",    0),
        "tools":          tools_data,
        "activity":       [compute_turn_summary(t) for t in turns[-10:]],
        "calls":          build_calls_log(events),
        "alerts":         alerts,
        "ts":             datetime.now().strftime("%H:%M:%S"),
    }

# -- HTML dashboard (inline, zero external file deps) -------------------------

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>flowctl monitor</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Fira+Sans:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0a0a0f;--surface:#12121a;--elevated:#1a1a2e;--border:#2a2a3e;
  --text:#e2e8f0;--muted:#94a3b8;
  --blue:#3b82f6;--green:#22c55e;--amber:#f59e0b;--red:#ef4444;
  --mono:'Fira Code',Consolas,monospace;
  --sans:'Fira Sans',system-ui,sans-serif;
  --r:8px;
}
body{font-family:var(--sans);background:var(--bg);color:var(--text);min-height:100vh;padding:14px;font-size:13px;line-height:1.5}

.hdr{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:10px 14px;
  background:var(--surface);border:1px solid var(--border);border-radius:var(--r);margin-bottom:10px}
.hdr-title{font-family:var(--mono);font-size:14px;font-weight:600;color:var(--blue);letter-spacing:.05em}
.sep{color:var(--border)}
.hdr-step{font-weight:600}
.hdr-sname{color:var(--muted);font-size:12px}
.hdr-project{font-family:var(--mono);font-size:12px;font-weight:600;color:var(--green)}
.hdr-dur{font-family:var(--mono);color:var(--muted);font-size:12px}
.hdr-time{font-family:var(--mono);font-size:11px;color:var(--muted);margin-left:auto}

.live{display:inline-flex;align-items:center;gap:5px;font-size:11px;font-weight:600}
.live::before{content:'';width:7px;height:7px;border-radius:50%;
  background:var(--green);box-shadow:0 0 6px var(--green);animation:blink 2s ease-in-out infinite}
.live.paused::before{background:var(--amber);box-shadow:0 0 6px var(--amber);animation:none}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.35}}
@media(prefers-reduced-motion:reduce){.live::before{animation:none}}

.btn{padding:3px 10px;border-radius:5px;border:1px solid var(--border);background:var(--elevated);
  color:var(--muted);font-size:11px;cursor:pointer;transition:color .2s,border-color .2s}
.btn:hover{color:var(--text);border-color:var(--blue)}

.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:8px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);padding:12px 14px}
.clabel{font-size:9px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);margin-bottom:5px}
.cval{font-family:var(--mono);font-size:20px;font-weight:600;line-height:1;margin-bottom:3px;transition:color .3s}
.csub{font-family:var(--mono);font-size:11px;color:var(--muted)}
.card.consumed .cval{color:var(--amber);text-shadow:0 0 10px rgba(245,158,11,.2)}
.card.saved .cval{color:var(--green);text-shadow:0 0 10px rgba(34,197,94,.2)}

.pbar-wrap{display:flex;align-items:center;gap:6px;margin-top:5px}
.pbar-track{flex:1;height:3px;background:var(--elevated);border-radius:2px;overflow:hidden}
.pbar-fill{height:100%;border-radius:2px;transition:width .5s ease,background .3s}

.budget{display:flex;align-items:center;gap:10px;padding:9px 14px;
  background:var(--surface);border:1px solid var(--border);border-radius:var(--r);margin-bottom:8px}
.blabel{font-size:11px;color:var(--muted);flex-shrink:0}
.btrack{flex:1;height:5px;background:var(--elevated);border-radius:3px;overflow:hidden}
.bfill{height:100%;border-radius:3px;transition:width .5s ease,background .3s}
.bpct{font-family:var(--mono);font-size:12px;font-weight:600;width:38px;text-align:right;flex-shrink:0;transition:color .3s}
.bof{font-size:11px;color:var(--muted);flex-shrink:0}

.main{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);overflow:hidden}
.ptitle{font-size:10px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;
  color:var(--blue);padding:9px 12px 7px;border-bottom:1px solid var(--border)}

table{width:100%;border-collapse:collapse}
th{font-size:9px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--muted);text-align:left;padding:5px 12px;border-bottom:1px solid var(--border)}
th:not(:first-child){text-align:right}
td{padding:6px 12px;border-bottom:1px solid rgba(42,42,62,.4);font-family:var(--mono);font-size:11px}
td:not(:first-child){text-align:right}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--elevated)}

.hbar{display:inline-block;width:44px;height:3px;background:var(--elevated);border-radius:2px;vertical-align:middle;overflow:hidden}
.hfill{height:100%;border-radius:2px;transition:width .5s}

.calls-panel{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);overflow:hidden;margin-bottom:8px}
.ptitle-sub{font-size:9px;font-weight:400;color:var(--muted);text-transform:lowercase;letter-spacing:.02em;margin-left:6px}
.badge{display:inline-block;padding:1px 6px;border-radius:3px;font-size:9px;font-weight:700;letter-spacing:.06em;line-height:1.4}
.badge-hit{background:rgba(34,197,94,.12);color:var(--green)}
.badge-miss{background:rgba(239,68,68,.10);color:var(--red)}
.badge-unk{background:rgba(148,163,184,.1);color:var(--muted)}
.alerts{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);padding:9px 14px;transition:border-color .3s}
.aok{color:var(--green);font-family:var(--mono);font-size:12px}
.awarn{color:var(--amber);font-family:var(--mono);font-size:12px;margin-bottom:3px}
.awarn:last-child{margin-bottom:0}

.c-blue{color:var(--blue)}.c-green{color:var(--green)}.c-amber{color:var(--amber)}
.c-red{color:var(--red)}.c-muted{color:var(--muted)}
.empty td{color:var(--muted);font-style:italic;text-align:left!important}

/* ── Project Switcher dropdown ─────────────────────────── */
.sw-wrap{position:relative;display:inline-block}
.sw-btn{display:flex;align-items:center;gap:6px;padding:3px 10px;border-radius:5px;
  border:1px solid var(--border);background:var(--elevated);color:var(--text);
  font-size:11px;font-family:var(--mono);cursor:pointer;transition:border-color .2s}
.sw-btn:hover{border-color:var(--blue)}
.sw-btn .sw-dot{width:6px;height:6px;border-radius:50%;background:var(--muted);flex-shrink:0}
.sw-btn .sw-dot.live{background:var(--green);box-shadow:0 0 4px var(--green)}
.sw-btn .sw-caret{color:var(--muted);font-size:9px;margin-left:2px}
.sw-menu{display:none;position:absolute;top:calc(100% + 4px);left:0;min-width:230px;
  background:var(--surface);border:1px solid var(--border);border-radius:var(--r);
  box-shadow:0 8px 24px rgba(0,0,0,.5);z-index:100;overflow:hidden}
.sw-menu.open{display:block}
.sw-item{display:flex;align-items:center;gap:8px;padding:7px 12px;cursor:pointer;
  font-size:11px;transition:background .15s;font-family:var(--mono)}
.sw-item:hover{background:var(--elevated)}
.sw-item.active{background:rgba(59,130,246,.12);color:var(--blue)}
.sw-item .pdot{width:6px;height:6px;border-radius:50%;background:var(--muted);flex-shrink:0}
.sw-item .pdot.live{background:var(--green);box-shadow:0 0 4px var(--green)}
.sw-item .pdot.idle{background:var(--amber)}
.sw-item-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sw-item-meta{font-size:10px;color:var(--muted);white-space:nowrap}
.sw-divider{height:1px;background:var(--border);margin:3px 0}
.sw-all{color:var(--blue)}
.sw-settings{color:var(--muted);font-size:10px}
/* ── Project Cards (All view) ──────────────────────────── */
.cards-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));
  gap:8px;margin-bottom:8px}
.project-card{background:var(--surface);border:1px solid var(--border);
  border-radius:var(--r);padding:12px;cursor:pointer;transition:border-color .2s}
.project-card:hover{border-color:var(--blue)}
.pc-header{display:flex;align-items:center;gap:6px;margin-bottom:8px}
.pc-name{font-weight:600;font-size:12px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pc-step{font-size:10px;color:var(--muted);font-family:var(--mono);white-space:nowrap}
.pc-stats{font-family:var(--mono);font-size:11px;color:var(--muted);margin-bottom:6px;line-height:1.8}
.pc-footer{display:flex;align-items:center;justify-content:space-between;font-size:10px}
.pc-eff{color:var(--green);font-family:var(--mono)}
.pc-blk{color:var(--red)}
.pc-open{padding:2px 8px;border-radius:4px;border:1px solid var(--border);
  background:var(--elevated);color:var(--blue);font-size:10px;cursor:pointer;
  transition:background .15s}
.pc-open:hover{background:var(--border)}
/* ── Settings Panel ────────────────────────────────────── */
.settings-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:200}
.settings-overlay.open{display:flex;align-items:center;justify-content:center}
.settings-panel{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);
  padding:20px;min-width:300px;max-width:420px;width:90%}
.settings-title{font-size:13px;font-weight:600;color:var(--text);margin-bottom:14px}
.settings-row{display:flex;align-items:center;justify-content:space-between;
  margin-bottom:10px;font-size:12px;color:var(--muted)}
.settings-row input[type=number]{width:70px;background:var(--elevated);border:1px solid var(--border);
  border-radius:4px;color:var(--text);padding:3px 6px;font-family:var(--mono);font-size:12px}
.settings-row input[type=checkbox]{accent-color:var(--blue);width:14px;height:14px;cursor:pointer}
.settings-actions{display:flex;gap:8px;margin-top:16px;justify-content:flex-end}
.settings-save{padding:4px 14px;border-radius:5px;border:none;background:var(--blue);
  color:#fff;font-size:12px;cursor:pointer}
.settings-cancel{padding:4px 14px;border-radius:5px;border:1px solid var(--border);
  background:var(--elevated);color:var(--muted);font-size:12px;cursor:pointer}
.settings-cancel:hover{color:var(--text)}

@media(max-width:768px){.stats,.main{grid-template-columns:1fr}}
</style>
</head>
<body>

<div class="hdr">
  <span class="hdr-title">&#9670; FLOWCTL</span>
  <div class="sw-wrap" id="sw-wrap">
    <button class="sw-btn" id="sw-btn" onclick="toggleSwitcher(event)">
      <span class="sw-dot" id="sw-dot"></span>
      <span id="sw-label">-</span>
      <span class="sw-caret">&#9660;</span>
    </button>
    <div class="sw-menu" id="sw-menu"></div>
  </div>
  <span class="sep">|</span>
  <span id="hstep" class="hdr-step">Step -</span>
  <span id="hsname" class="hdr-sname"></span>
  <span class="sep">|</span>
  <span class="hdr-dur">&#9201;&thinsp;<span id="hdur">--:--:--</span></span>
  <button class="btn" id="pbtn" onclick="togglePause()">Pause</button>
  <span class="live" id="ldot">LIVE</span>
  <span class="hdr-time" id="htime"></span>
</div>

<!-- Settings modal -->
<div class="settings-overlay" id="settings-overlay" onclick="closeSettings(event)">
  <div class="settings-panel" onclick="event.stopPropagation()">
    <div class="settings-title">&#9881; Dashboard Settings</div>
    <div class="settings-row"><span>Monitor Port</span><input type="number" id="cfg-port" value="3170" min="1024" max="65535"></div>
    <div class="settings-row"><span>Auto-open browser</span><input type="checkbox" id="cfg-browser" checked></div>
    <div class="settings-row"><span>Show idle projects</span><input type="checkbox" id="cfg-idle" checked></div>
    <div class="settings-row"><span>Idle threshold (min)</span><input type="number" id="cfg-idle-min" value="10" min="1" max="1440"></div>
    <div class="settings-actions">
      <button class="settings-cancel" onclick="closeSettings()">Cancel</button>
      <button class="settings-save" onclick="saveSettings()">Save</button>
    </div>
  </div>
</div>

<div class="stats">
  <div class="card consumed">
    <div class="clabel">Consumed</div>
    <div class="cval" id="s-consumed">-</div>
    <div class="csub" id="s-cost">$-</div>
  </div>
  <div class="card saved">
    <div class="clabel">Saved</div>
    <div class="cval" id="s-saved">-</div>
    <div class="csub" id="s-susd">$-</div>
  </div>
  <div class="card">
    <div class="clabel">Efficiency</div>
    <div class="cval" id="s-eff" style="color:var(--muted)">-%</div>
    <div class="pbar-wrap"><div class="pbar-track"><div class="pbar-fill" id="eff-fill" style="width:0"></div></div></div>
    <div class="csub" id="s-waste">waste -</div>
  </div>
</div>

<div class="budget">
  <span class="blabel" id="blabel">Step - budget</span>
  <div class="btrack"><div class="bfill" id="bfill" style="width:0"></div></div>
  <span class="bpct" id="bpct">-%</span>
  <span class="bof" id="bof">of ~- tokens</span>
</div>

<div class="main">
  <div class="panel">
    <div class="ptitle">MCP Tools</div>
    <table><thead><tr><th>Tool</th><th>Calls</th><th>Hits</th><th>Hit%</th><th>Bar</th><th>Saved</th></tr></thead>
    <tbody id="tools-body"><tr class="empty"><td colspan="6">No data yet</td></tr></tbody></table>
  </div>
  <div class="panel">
    <div class="ptitle">Recent Activity</div>
    <table><thead><tr><th>Time</th><th>Agent</th><th>Ops</th><th>Cost</th><th>Tok</th></tr></thead>
    <tbody id="act-body"><tr class="empty"><td colspan="5">No activity yet</td></tr></tbody></table>
  </div>
</div>

<div class="panel calls-panel">
  <div class="ptitle">Proxy Call Log <span class="ptitle-sub">newest first · last 40</span></div>
  <table><thead><tr>
    <th>Time</th><th>Tool</th><th>Cache</th>
    <th>Out&thinsp;tok</th><th>Bash&thinsp;equiv</th><th>Saved</th><th>ms</th>
  </tr></thead>
  <tbody id="calls-body"><tr class="empty"><td colspan="7">No proxy calls yet</td></tr></tbody></table>
</div>

<div class="alerts" id="alerts">
  <span class="aok">&#10003; No alerts</span>
</div>

<script>
'use strict';
let paused = false;

// Escape all dynamic strings before inserting into DOM via textContent
function esc(s) {
  const d = document.createElement('div');
  d.textContent = String(s ?? '');
  return d.innerHTML;
}

const fmt = n => (typeof n === 'number' ? n : 0).toLocaleString();
const ef  = p => p >= 65 ? 'var(--green)' : p >= 35 ? 'var(--amber)' : 'var(--red)';
const bf  = p => p > 150 ? 'var(--red)'  : p > 100 ? 'var(--amber)' : 'var(--green)';
const hc  = r => r >= 80 ? 'c-green'     : r >= 60 ? 'c-amber'      : 'c-red';

function set(id, text)     { const el = document.getElementById(id); if (el) el.textContent = text; }
function setCss(id, prop, val) { const el = document.getElementById(id); if (el) el.style[prop] = val; }

function togglePause() {
  paused = !paused;
  document.getElementById('pbtn').textContent = paused ? 'Resume' : 'Pause';
  const dot = document.getElementById('ldot');
  dot.textContent = paused ? 'PAUSED' : 'LIVE';
  dot.className   = paused ? 'live paused' : 'live';
}

function renderTools(tools) {
  const tbody = document.getElementById('tools-body');
  if (!tools || !tools.length) {
    tbody.innerHTML = '<tr class="empty"><td colspan="6">No tool calls yet</td></tr>';
    return;
  }
  // Build rows using DOM to avoid XSS - tool names come from system but we escape anyway
  tbody.innerHTML = '';
  tools.forEach(t => {
    const rp  = (t.rate * 100).toFixed(0);
    const cc  = hc(t.rate * 100);
    const bc  = t.rate >= .8 ? 'var(--green)' : t.rate >= .6 ? 'var(--amber)' : 'var(--red)';
    const row = document.createElement('tr');
    row.innerHTML = [
      `<td class="c-blue">${esc(t.name)}</td>`,
      `<td>${esc(t.calls)}</td>`,
      `<td class="${cc}">${esc(t.hits)}</td>`,
      `<td class="${cc}">${esc(rp)}%</td>`,
      `<td><span class="hbar"><span class="hfill" style="width:${esc(rp)}%;background:${bc}"></span></span></td>`,
      `<td class="c-muted">~${esc(fmt(t.saved))}</td>`,
    ].join('');
    tbody.appendChild(row);
  });
}

function renderActivity(activity) {
  const tbody = document.getElementById('act-body');
  const acts  = (activity || []).slice(-8).reverse();
  if (!acts.length) {
    tbody.innerHTML = '<tr class="empty"><td colspan="5">No activity yet</td></tr>';
    return;
  }
  tbody.innerHTML = '';
  acts.forEach(a => {
    const toolSpans = (a.tools || []).slice(0, 3).map(t => `<span class="c-blue">${esc(t)}</span>`).join(' ');
    const moreSpan  = (a.tools || []).length > 3 ? `<span class="c-muted">+${esc((a.tools.length - 3))}</span>` : '';
    // Truncate bash cmd to 12 chars to limit exposure; escaped via esc()
    const bashSpan  = (a.bash_cmds || []).slice(0, 1)
      .map(c => `<span class="c-red">bash</span><span class="c-muted">:${esc(String(c).slice(0, 12))}</span>`).join('');
    const ops = [toolSpans, moreSpan, bashSpan].filter(Boolean).join(' ') || '<span class="c-muted">-</span>';
    const tc  = a.saved > a.consumed ? 'c-green' : a.consumed > 0 ? 'c-red' : 'c-muted';
    const row = document.createElement('tr');
    row.innerHTML = [
      `<td class="c-muted">${esc((a.ts || '').slice(-8))}</td>`,
      `<td class="c-muted">${esc(a.agent || '?')}</td>`,
      `<td>${ops}</td>`,
      `<td class="c-muted">${a.cost ? '$' + esc(a.cost.toFixed(4)) : '-'}</td>`,
      `<td class="${tc}">${esc(fmt(a.consumed))}</td>`,
    ].join('');
    tbody.appendChild(row);
  });
}

function renderCalls(calls) {
  const tbody = document.getElementById('calls-body');
  if (!calls || !calls.length) {
    tbody.innerHTML = '<tr class="empty"><td colspan="7">No proxy calls yet</td></tr>';
    return;
  }
  tbody.innerHTML = '';
  calls.forEach(c => {
    const isHit  = c.cache === 'hit';
    const isMiss = c.cache === 'miss';
    const badgeCls = isHit ? 'badge-hit' : isMiss ? 'badge-miss' : 'badge-unk';
    const badgeTxt = isHit ? 'HIT' : isMiss ? 'MISS' : esc(c.cache).toUpperCase();
    const savedCls = c.saved_tok > 0 ? 'c-green' : 'c-muted';
    const row = document.createElement('tr');
    row.innerHTML = [
      `<td class="c-muted">${esc(c.ts)}</td>`,
      `<td class="c-blue">${esc(c.tool)}</td>`,
      `<td><span class="badge ${badgeCls}">${badgeTxt}</span></td>`,
      `<td class="c-muted">${esc(c.out_tok)}</td>`,
      `<td class="c-muted">${esc(c.bash_equiv)}</td>`,
      `<td class="${savedCls}">+${esc(fmt(c.saved_tok))}</td>`,
      `<td class="c-muted">${esc(c.dur_ms)}</td>`,
    ].join('');
    tbody.appendChild(row);
  });
}

function render(d) {
  set('hproject', d.project_name || d.project_id || '?');
  set('hstep',  'Step ' + (d.step || '-'));
  set('hsname', d.step_name || '');
  set('hdur',   d.duration  || '--:--:--');
  set('htime',  d.ts || '');

  set('s-consumed', fmt(d.consumed) + ' tok');
  set('s-cost',     '$' + (d.cost_usd  || 0).toFixed(4));
  set('s-saved',    fmt(d.saved)    + ' tok');
  set('s-susd',     '$' + (d.saved_usd || 0).toFixed(4));

  const ep = d.eff_pct || 0;
  setCss('s-eff', 'color', ef(ep));
  set('s-eff', ep.toFixed(0) + '%');
  setCss('eff-fill', 'width',      Math.min(ep, 100) + '%');
  setCss('eff-fill', 'background', ef(ep));
  set('s-waste', 'waste ~' + fmt(d.waste_tok) + ' tok');

  const bp = d.bud_pct || 0;
  set('blabel', 'Step ' + (d.step || '-') + ' budget');
  set('bpct',   bp.toFixed(0) + '%');
  setCss('bpct',  'color',      bf(bp));
  set('bof', 'of ~' + fmt(d.budget) + ' typical');
  setCss('bfill', 'width',      Math.min(bp, 100) + '%');
  setCss('bfill', 'background', bf(bp));

  renderTools(d.tools);
  renderActivity(d.activity);
  renderCalls(d.calls);

  const al = document.getElementById('alerts');
  if (!d.alerts || !d.alerts.length) {
    al.innerHTML = '<span class="aok">&#10003; No alerts</span>';
    al.style.borderColor = 'var(--border)';
  } else {
    al.innerHTML = '';
    d.alerts.forEach(a => {
      const div = document.createElement('div');
      div.className   = 'awarn';
      div.textContent = '⚠ ' + a;  // textContent: no XSS risk
      al.appendChild(div);
    });
    al.style.borderColor = 'var(--amber)';
  }
}

// ── Project Switcher ─────────────────────────────────────────
// _activePid sentinel values:
//   undefined  = live SSE mode (current project, auto-updates via SSE)
//   null       = "All Projects" aggregate + cards view
//   'wf-...'   = specific project static view
let _projects  = {};
let _activePid = undefined;
let _curPid    = '';  // project_id of the current (local) project

function _sortedProjects() {
  return Object.values(_projects)
    .sort((a,b) => {
      const sa = a.sort_key || [2,999999];
      const sb = b.sort_key || [2,999999];
      return sa[0] !== sb[0] ? sa[0] - sb[0] : sa[1] - sb[1];
    });
}

function _ageSuffix(secs) {
  if (!secs || secs >= 999999) return 'idle';
  if (secs < 60)   return secs + 's ago';
  if (secs < 3600) return Math.floor(secs/60) + 'm ago';
  return Math.floor(secs/3600) + 'h ago';
}

function _dotClass(p) {
  const s = p.active_seconds_ago || 999999;
  if (s < 600)   return 'live';
  if (s < 3600)  return 'idle';
  return '';
}

function fetchProjects() {
  fetch('/api/projects').then(r => r.json()).then(d => {
    _projects = d.projects || {};
    renderSwitcher();
    if (_activePid !== undefined) renderProjectView(_activePid);
  }).catch(() => {});
}

function toggleSwitcher(e) {
  e.stopPropagation();
  document.getElementById('sw-menu').classList.toggle('open');
}
document.addEventListener('click', () => {
  document.getElementById('sw-menu')?.classList.remove('open');
});

function renderSwitcher() {
  const btn  = document.getElementById('sw-btn');
  const menu = document.getElementById('sw-menu');
  const dot  = document.getElementById('sw-dot');
  const lbl  = document.getElementById('sw-label');
  if (!menu) return;

  const sorted = _sortedProjects();
  const multi  = sorted.length > 1;

  // Update button label
  if (_activePid === null) {
    lbl.textContent = `All Projects (${sorted.length})`;
    dot.className   = 'sw-dot';
  } else if (_activePid && _projects[_activePid]) {
    const p = _projects[_activePid];
    lbl.textContent = p.project_name || _activePid;
    dot.className   = 'sw-dot ' + _dotClass(p);
  } else if (_curPid && _projects[_curPid]) {
    const p = _projects[_curPid];
    lbl.textContent = p.project_name || _curPid;
    dot.className   = 'sw-dot ' + _dotClass(p);
  } else {
    lbl.textContent = '-';
    dot.className   = 'sw-dot';
  }

  if (!multi) { menu.innerHTML = ''; return; }

  const items = sorted.map(p => {
    const act  = _activePid === p.project_id ? ' active' : '';
    const dc   = _dotClass(p);
    const age  = _ageSuffix(p.active_seconds_ago);
    const step = p.step ? `Step ${p.step}` : '';
    return `<div class="sw-item${act}" onclick="selectProject('${esc(p.project_id)}');document.getElementById('sw-menu').classList.remove('open')">
      <span class="pdot ${dc}"></span>
      <span class="sw-item-name">${esc(p.project_name||p.project_id)}</span>
      <span class="sw-item-meta">${esc(step)}&nbsp;&nbsp;${esc(age)}</span>
    </div>`;
  }).join('');
  const allAct = _activePid === null ? ' active' : '';
  menu.innerHTML = items
    + `<div class="sw-divider"></div>`
    + `<div class="sw-item sw-all${allAct}" onclick="selectProject(null);document.getElementById('sw-menu').classList.remove('open')">&#9671; All Projects (${sorted.length})</div>`
    + `<div class="sw-divider"></div>`
    + `<div class="sw-item sw-settings" onclick="openSettings();document.getElementById('sw-menu').classList.remove('open')">&#9881; Settings</div>`;
}

function selectProject(pid) {
  _activePid = pid;
  renderSwitcher();
  renderProjectView(pid);
}

function renderProjectView(pid) {
  document.getElementById('cards-panel')?.remove();
  if (pid === null) {
    const ps  = _sortedProjects().filter(p => !p.error);
    const tot = { consumed:0, saved:0, cost_usd:0, saved_usd:0, waste_tok:0 };
    ps.forEach(p => {
      tot.consumed  += p.consumed  || 0;
      tot.saved     += p.saved     || 0;
      tot.cost_usd  += p.cost_usd  || 0;
      tot.saved_usd += p.saved_usd || 0;
      tot.waste_tok += p.waste_tok || 0;
    });
    const s = tot.consumed + tot.saved;
    render({
      ...tot,
      project_name: `All Projects (${ps.length})`,
      project_id:   '',
      eff_pct:      s ? Math.round(tot.saved/s*100) : 0,
      budget: 0, bud_pct: 0, step: null, step_name: '',
      tools: _mergeTools(ps), calls: _mergeCalls(ps),
      activity: [], alerts: [], duration: '--:--:--',
      ts: new Date().toLocaleTimeString(),
    });
    _renderCards(ps);
  } else {
    const p = _projects[pid];
    if (!p || p.error) return;
    const s = (p.consumed||0) + (p.saved||0);
    render({
      ...p,
      eff_pct:  s ? Math.round(p.saved/s*100) : 0,
      budget:   12000,
      bud_pct:  p.consumed ? Math.round(p.consumed/12000*100) : 0,
      alerts:   p.open_blockers ? [`${p.open_blockers} open blocker(s)`] : [],
      duration: '--:--:--',
      ts:       new Date().toLocaleTimeString(),
    });
  }
}

function _mergeTools(projects) {
  const m = {};
  projects.forEach(p => (p.tools||[]).forEach(t => {
    if (!m[t.name]) m[t.name] = {name:t.name, calls:0, hits:0, saved:0};
    m[t.name].calls += t.calls; m[t.name].hits += t.hits; m[t.name].saved += t.saved;
  }));
  return Object.values(m)
    .map(t => ({...t, rate: t.calls ? t.hits/t.calls : 0}))
    .sort((a,b) => b.calls - a.calls);
}

function _mergeCalls(projects) {
  return projects
    .flatMap(p => (p.calls||[]).map(c => ({...c, _proj: p.project_name})))
    .sort((a,b) => (b.ts||'').localeCompare(a.ts||''))
    .slice(0, 40);
}

function _renderCards(projects) {
  const grid = document.createElement('div');
  grid.id = 'cards-panel'; grid.className = 'cards-grid';

  if (!projects.length) {
    grid.innerHTML = '<div style="color:var(--muted);font-size:12px;padding:12px">No projects yet. Run <code>flowctl init</code> to start.</div>';
  } else {
    grid.innerHTML = projects.map(p => {
      const dc   = _dotClass(p);
      const s    = (p.consumed||0) + (p.saved||0);
      const eff  = s ? Math.round(p.saved/s*100) : 0;
      const blk  = p.open_blockers ? `<span class="pc-blk">&#9888; ${p.open_blockers}</span>` : '';
      return `<div class="project-card" onclick="selectProject('${esc(p.project_id)}')">
        <div class="pc-header">
          <span class="pdot ${dc}"></span>
          <span class="pc-name">${esc(p.project_name||p.project_id)}</span>
          <span class="pc-step">Step ${esc(p.step||'-')}/9</span>
        </div>
        <div class="pc-stats">
          <span class="c-amber">${fmt(p.consumed||0)}</span> consumed &nbsp;
          <span class="c-green">+${fmt(p.saved||0)}</span> saved<br>
          <span class="c-muted">today +${(p.today_saved||0).toLocaleString()}</span>
        </div>
        <div class="pc-footer">
          <span class="pc-eff">${eff}% eff</span>
          ${blk}
          <button class="pc-open" onclick="event.stopPropagation();selectProject('${esc(p.project_id)}')">Open &#8594;</button>
        </div>
      </div>`;
    }).join('');
  }
  const alertsEl = document.getElementById('alerts');
  if (alertsEl) alertsEl.before(grid); else document.body.appendChild(grid);
}

// ── Settings ─────────────────────────────────────────────────
function openSettings() {
  fetch('/api/settings').then(r => r.json()).then(cfg => {
    const mon = cfg.monitor || {};
    const def = cfg.defaults || {};
    document.getElementById('cfg-port').value        = mon.default_port   || 3170;
    document.getElementById('cfg-browser').checked   = mon.auto_open_browser !== false;
    document.getElementById('cfg-idle').checked      = cfg.show_idle_projects !== false;
    document.getElementById('cfg-idle-min').value    = def.idle_threshold_min || 10;
    document.getElementById('settings-overlay').classList.add('open');
  }).catch(() => {
    document.getElementById('settings-overlay').classList.add('open');
  });
}
function closeSettings(e) {
  if (e && e.target !== document.getElementById('settings-overlay')) return;
  document.getElementById('settings-overlay').classList.remove('open');
}
function saveSettings() {
  const cfg = {
    monitor: {
      default_port:      parseInt(document.getElementById('cfg-port').value)||3170,
      auto_open_browser: document.getElementById('cfg-browser').checked,
    },
    show_idle_projects: document.getElementById('cfg-idle').checked,
    defaults: {
      idle_threshold_min: parseInt(document.getElementById('cfg-idle-min').value)||10,
    }
  };
  fetch('/api/settings', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify(cfg),
  }).then(r => r.json()).then(() => {
    document.getElementById('settings-overlay').classList.remove('open');
  }).catch(() => {});
}

// ── SSE v2 ───────────────────────────────────────────────────
fetchProjects();
setInterval(fetchProjects, 60000);  // reduced from 5s → 60s (SSE handles real-time)

let _es = null;

function connectSSE() {
  if (_es) { try { _es.close(); } catch(_) {} }
  _es = new EventSource('/api/stream');
  _es.onmessage = (e) => {
    if (paused) return;
    try {
      const msg = JSON.parse(e.data);
      // Typed event: {type:"project_update", project_id, data}
      if (msg.type === 'project_update') {
        const pid  = msg.project_id;
        const data = msg.data;
        if (!pid) return;
        // Keep _projects cache up to date
        if (_projects[pid]) {
          _projects[pid] = {..._projects[pid], ...data, sort_key: _projects[pid].sort_key};
        }
        // Update switcher dot (activity state may have changed)
        renderSwitcher();
        // Only push to main view if user is watching this project or in live mode
        if (_activePid === undefined && (pid === _curPid || !_curPid)) {
          render(data); setCss('ldot','opacity','1');
        } else if (_activePid === pid) {
          const s = (data.consumed||0) + (data.saved||0);
          render({...data,
            eff_pct:  s ? Math.round(data.saved/s*100) : 0,
            budget:   12000,
            bud_pct:  data.consumed ? Math.round(data.consumed/12000*100) : 0,
            alerts:   data.open_blockers ? [`${data.open_blockers} open blocker(s)`] : [],
            duration: '--:--:--', ts: new Date().toLocaleTimeString(),
          });
          setCss('ldot','opacity','1');
        } else if (_activePid === null) {
          renderProjectView(null);  // refresh All view cards
        }
      } else {
        // Legacy flat payload — treat as current project update
        if (_activePid !== undefined) return;
        render(msg); setCss('ldot','opacity','1');
      }
    } catch(_) {}
  };
  _es.onerror = () => {
    setCss('ldot','opacity','.4');
    setTimeout(() => { if (_es && _es.readyState === EventSource.CLOSED) connectSSE(); }, 3000);
  };
  _es.onopen = () => { setCss('ldot','opacity','1'); };
}

// Fetch initial data, set _curPid, then connect SSE.
// If no current project (running from outside a project dir), default to All Projects view.
fetch('/api/data')
  .then(r => r.json())
  .then(d => {
    _curPid = d.project_id || '';
    if (!_curPid) {
      // Global mode: no local project — show All Projects view
      _activePid = null;
      fetchProjects();
    } else {
      render(d);
    }
    connectSSE();
  })
  .catch(() => { connectSSE(); fetchProjects(); });
</script>
</body></html>
"""

# -- Threaded HTTP server -------------------------------------------------------
# HTTPServer is single-threaded by default. An SSE connection's `while True` loop
# blocks the main thread → all subsequent requests (e.g. /api/projects) queue up
# indefinitely (browser shows "pending"), and Ctrl+C can't interrupt serve_forever().
#
# ThreadingMixIn spawns a new thread per connection, so:
#   • /api/projects responds immediately even while SSE is open
#   • serve_forever() stays in its polling loop → shutdown flag is checked → Ctrl+C works
#   • daemon_threads=True: SSE threads die automatically when the main thread exits

class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads      = True   # background threads die when main thread exits
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        """Suppress routine client-disconnect errors (browser refresh, tab close, etc.)."""
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)):
            return  # Normal — not a server bug
        super().handle_error(request, client_address)

# -- HTTP handler --------------------------------------------------------------

class MonitorHandler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # silence access log

    def _send(self, body: bytes, ctype: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type",   ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control",  "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _sse_stream(self):
        self.send_response(200)
        self.send_header("Content-Type",      "text/event-stream")
        self.send_header("Cache-Control",     "no-cache")
        self.send_header("Connection",        "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        q = BROADCASTER.subscribe()
        try:
            # Send current project state immediately on connect (typed event)
            cur = build_api_data()
            init_msg = {"type": "project_update", "project_id": cur.get("project_id",""), "data": cur}
            self.wfile.write(f"data: {json.dumps(init_msg)}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    msg = q.get(timeout=25)
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
                except _queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            BROADCASTER.unsubscribe(q)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/settings":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body   = self.rfile.read(length)
                new_cfg = json.loads(body)
                cfg_path = FLOWCTL_HOME / "config.json"
                cfg_path.parent.mkdir(parents=True, exist_ok=True)
                # Merge with existing (don't wipe unknown keys)
                existing = {}
                try:
                    existing = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
                except Exception:
                    pass
                def deep_merge(base: dict, patch: dict) -> dict:
                    out = dict(base)
                    for k, v in patch.items():
                        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
                    return out
                merged = deep_merge(existing, new_cfg)
                cfg_path.write_text(json.dumps(merged, indent=2))
                self._send(json.dumps({"ok": True}).encode(), "application/json")
            except Exception as e:
                self._send(json.dumps({"error": str(e)}).encode(), "application/json", 400)
        else:
            self._send(b'{"error":"not found"}', "application/json", 404)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self._send(HTML.encode(), "text/html; charset=utf-8")
        elif path == "/api/data":
            self._send(json.dumps(build_api_data()).encode(), "application/json")
        elif path == "/api/stream":
            self._sse_stream()
        elif path == "/api/projects":
            projects = discover_projects()
            now_ts   = datetime.now(timezone.utc).timestamp()
            result   = {}
            for pid, proj in projects.items():
                cache_dir = proj.get("cache_dir")
                proj_path = proj.get("path")
                if not cache_dir or not proj_path:
                    result[pid] = {
                        "project_id":   pid,
                        "project_name": proj.get("project_name", "?"),
                        "error":        "missing cache_dir or path (registry entry stale — restart shell-proxy)",
                    }
                    continue
                try:
                    pdata = build_project_data(
                        cache_dir,
                        str(Path(proj_path) / "flowctl-state.json")
                    )
                    pdata["active"] = proj.get("active", False)
                    # active_seconds_ago: seconds since last event file change
                    try:
                        ef = Path(cache_dir) / "events.jsonl"
                        age = int(now_ts - _os.stat(str(ef)).st_mtime) if ef.exists() else 999999
                    except Exception:
                        age = 999999
                    pdata["active_seconds_ago"] = age
                    # sort_key: active projects first (age < 600), then by age asc
                    pdata["sort_key"] = (0 if age < 600 else 1, age)
                    result[pid] = pdata
                except Exception as e:
                    result[pid] = {
                        "project_id":   pid,
                        "project_name": proj.get("project_name", "?"),
                        "active":       proj.get("active", False),
                        "active_seconds_ago": 999999,
                        "sort_key":     (2, 999999),
                        "error":        str(e),
                    }
            self._send(json.dumps({"projects": result}).encode(), "application/json")
        elif path == "/api/settings":
            cfg_path = FLOWCTL_HOME / "config.json"
            try:
                cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
            except Exception:
                cfg = {}
            self._send(json.dumps(cfg).encode(), "application/json")
        elif path == "/api/health":
            self._send(b'{"ok":true}', "application/json")
        else:
            self._send(b'{"error":"not found"}', "application/json", 404)

# -- Main ----------------------------------------------------------------------

def _find_port(start: int) -> int:
    for p in range(start, start + 10):
        with socket.socket() as s:
            try: s.bind(("127.0.0.1", p)); return p
            except OSError: continue
    return start

def main():
    global GLOBAL_MODE
    port, once = 3170, False
    for arg in sys.argv[1:]:
        if   arg == "--once":           once        = True
        elif arg == "--global":         GLOBAL_MODE = True
        elif arg.startswith("--port="):
            try: port = int(arg.split("=")[1])
            except: pass

    if once:
        print(json.dumps(build_api_data(), indent=2))
        return

    port  = _find_port(port)
    url   = f"http://localhost:{port}"
    httpd = ThreadingHTTPServer(("127.0.0.1", port), MonitorHandler)

    def _stop(*_):
        print("\n[flowctl monitor] Stopping...")
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    # Build FileWatcher paths_map: {filepath: meta | None}
    # None = current project (uses build_api_data + STATE_F for project_id)
    # dict = {project_id, cache_dir, state_path} for non-current projects
    try:
        cur_pid = load_flow_state().get("flow_id", "")
    except Exception:
        cur_pid = ""

    watch_map: dict = {}
    # Current project — always watch even if file doesn't exist yet
    for p in [EVENTS_F, STATS_F]:
        watch_map[str(p)] = None

    # Other projects from ~/.flowctl/projects/
    # L-08: scan meta.json to build the project list; do NOT gate on events.jsonl
    # existence — new/idle projects that haven't written any events yet must still
    # be registered so the FileWatcher picks them up the moment they become active.
    if (FLOWCTL_HOME / "projects").exists():
        for entry in (FLOWCTL_HOME / "projects").iterdir():
            meta_f = entry / "meta.json"
            if not meta_f.exists():
                continue
            try:
                meta = json.loads(meta_f.read_text())
                pid  = meta.get("project_id", "")
                if not pid or pid == cur_pid:
                    continue
                cdir  = meta.get("cache_dir", str(entry / "cache"))
                spath = str(Path(meta.get("path", "")) / "flowctl-state.json")
                ef    = Path(cdir) / "events.jsonl"
                # Register eagerly — FileWatcher tolerates non-existent paths and
                # will begin tracking as soon as the file is created.
                watch_map[str(ef)] = {"project_id": pid, "cache_dir": cdir, "state_path": spath}
            except Exception:
                pass

    FileWatcher(watch_map).start()

    print(f"[flowctl monitor] Dashboard: {url}")
    print("[flowctl monitor] Ctrl+C to stop")
    threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()

if __name__ == "__main__":
    main()
