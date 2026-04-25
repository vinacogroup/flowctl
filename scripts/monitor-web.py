#!/usr/bin/env python3
"""Token Monitor - web dashboard for MCP shell proxy.
Opens browser at http://localhost:3170. Ctrl+C to stop.
"""

import json, sys, signal, socket, threading, webbrowser, time, queue as _queue, os as _os
from pathlib import Path
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

REPO         = Path(__file__).resolve().parent.parent
CACHE        = REPO / ".cache" / "mcp"
EVENTS_F     = CACHE / "events.jsonl"
STATS_F      = CACHE / "session-stats.json"
STATE_F      = REPO / "flowctl-state.json"

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

def discover_projects() -> dict:
    """All projects in registry + always include current REPO if it has a state file."""
    reg    = load_registry()
    now_ts = datetime.now(timezone.utc).timestamp()
    result = {}

    for pid, proj in reg.get("projects", {}).items():
        try:
            last_ts = datetime.fromisoformat(proj["last_seen"].replace("Z","+00:00")).timestamp()
        except Exception:
            last_ts = 0
        proj = dict(proj)
        proj["active"] = (now_ts - last_ts) < 600
        result[pid] = proj

    # Always include current directory (even if not yet in registry)
    local_state = REPO / "flowctl-state.json"
    if not any(p.get("path") == str(REPO) for p in result.values()) and local_state.exists():
        try:
            s   = json.loads(local_state.read_text())
            pid = s.get("flow_id", "_local")
            result[pid] = {
                "project_id":   pid,
                "project_name": s.get("project_name", REPO.name),
                "path":         str(REPO),
                "cache_dir":    str(CACHE),
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
            try:    q.put_nowait(msg)
            except: dead.append(q)
        for q in dead:
            self.unsubscribe(q)

BROADCASTER = SSEBroadcaster()

# -- File watcher (poll mtime every 200ms, no external deps) -------------------

class FileWatcher(threading.Thread):
    """Poll file mtimes every 200ms. On change → broadcast fresh data to all SSE clients."""
    def __init__(self, paths: list, interval: float = 0.2):
        super().__init__(daemon=True, name="FileWatcher")
        self.paths    = list(paths)
        self.interval = interval
        self._mtimes: dict = {}

    def add_path(self, path: str):
        self.paths.append(path)

    def run(self):
        while True:
            for path in self.paths:
                try:
                    mtime = _os.stat(path).st_mtime
                    if self._mtimes.get(path) != mtime:
                        self._mtimes[path] = mtime
                        try:
                            BROADCASTER.broadcast(build_api_data())
                        except Exception:
                            pass
                except FileNotFoundError:
                    pass
            time.sleep(self.interval)

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

.project-tabs{display:flex;gap:4px;flex-wrap:wrap}
.ptab{padding:2px 10px;border-radius:4px;border:1px solid var(--border);
  background:var(--elevated);color:var(--muted);font-size:11px;cursor:pointer;
  font-family:var(--mono);transition:color .2s,border-color .2s,background .2s}
.ptab:hover{color:var(--text);border-color:var(--blue)}
.ptab.active{background:var(--blue);color:#fff;border-color:var(--blue)}
.ptab .pdot{display:inline-block;width:5px;height:5px;border-radius:50%;
  background:var(--muted);margin-right:4px;vertical-align:middle}
.ptab .pdot.live{background:var(--green);box-shadow:0 0 4px var(--green)}
.overview-panel{background:var(--surface);border:1px solid var(--border);
  border-radius:var(--r);overflow:hidden;margin-bottom:8px}

@media(max-width:768px){.stats,.main{grid-template-columns:1fr}}
</style>
</head>
<body>

<div class="hdr">
  <span class="hdr-title">&#9670; FLOWCTL</span>
  <div class="project-tabs" id="project-tabs"></div>
  <span class="sep">|</span>
  <span id="hproject" class="hdr-project">-</span>
  <span class="sep">|</span>
  <span id="hstep" class="hdr-step">Step -</span>
  <span id="hsname" class="hdr-sname"></span>
  <span class="sep">|</span>
  <span class="hdr-dur">&#9201;&thinsp;<span id="hdur">--:--:--</span></span>
  <button class="btn" id="pbtn" onclick="togglePause()">Pause</button>
  <span class="live" id="ldot">LIVE</span>
  <span class="hdr-time" id="htime"></span>
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

// ── Project tabs (multi-project) ─────────────────────────────
let _projects  = {};
let _activePid = null;  // null = show current project via SSE; string = specific project

function fetchProjects() {
  fetch('/api/projects').then(r => r.json()).then(d => {
    _projects = d.projects || {};
    renderTabs();
    // If multiple projects exist and user hasn't manually selected one, stay on SSE view
    if (Object.keys(_projects).length > 1 && _activePid !== null) {
      renderProjectView(_activePid);
    }
  }).catch(() => {});
}

function renderTabs() {
  const el  = document.getElementById('project-tabs');
  if (!el) return;
  const ids = Object.keys(_projects);
  if (ids.length <= 1) { el.innerHTML = ''; return; }

  const allBtn = `<button class="ptab${_activePid===null?' active':''}" onclick="selectProject(null)">All&thinsp;(${ids.length})</button>`;
  const tabs = ids.map(pid => {
    const p   = _projects[pid] || {};
    const dot = p.active ? 'live' : '';
    const act = _activePid === pid ? ' active' : '';
    return `<button class="ptab${act}" onclick="selectProject('${esc(pid)}')">` +
           `<span class="pdot ${dot}"></span>${esc(p.project_name || pid)}</button>`;
  }).join('');
  el.innerHTML = allBtn + tabs;
}

function selectProject(pid) {
  _activePid = pid;
  renderTabs();
  renderProjectView(pid);
}

function renderProjectView(pid) {
  document.getElementById('overview-panel')?.remove();
  if (pid === null) {
    // "All Projects" aggregate view
    const ps  = Object.values(_projects).filter(p => !p.error);
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
      project_name:  `All Projects (${ps.length})`,
      project_id:    '',
      eff_pct:       s ? Math.round(tot.saved / s * 100) : 0,
      budget:        0, bud_pct: 0, step: null, step_name: '',
      tools:         _mergeTools(ps), calls: _mergeCalls(ps),
      activity:      [], alerts:  [], duration: '--:--:--',
      ts:            new Date().toLocaleTimeString(),
    });
    _renderOverview(ps);
  } else {
    const p = _projects[pid];
    if (!p || p.error) return;
    const s = (p.consumed||0) + (p.saved||0);
    render({
      ...p,
      eff_pct:  s ? Math.round(p.saved / s * 100) : 0,
      budget:   12000,
      bud_pct:  p.consumed ? Math.round(p.consumed / 12000 * 100) : 0,
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
    .map(t => ({...t, rate: t.calls ? t.hits / t.calls : 0}))
    .sort((a,b) => b.calls - a.calls);
}

function _mergeCalls(projects) {
  return projects
    .flatMap(p => (p.calls||[]).map(c => ({...c, _proj: p.project_name})))
    .sort((a,b) => (b.ts||'').localeCompare(a.ts||''))
    .slice(0, 40);
}

function _renderOverview(projects) {
  const panel = document.createElement('div');
  panel.id = 'overview-panel'; panel.className = 'overview-panel';
  const rows = projects.map(p => {
    const dot = p.active
      ? '<span style="color:var(--green)">&#9679;</span>'
      : '<span style="color:var(--muted)">&#9675;</span>';
    const blk = p.open_blockers
      ? `<span style="color:var(--red)">&#9888;${esc(p.open_blockers)}</span>` : '-';
    return `<tr>
      <td>${dot} <span class="c-blue" style="cursor:pointer"
        onclick="selectProject('${esc(p.project_id)}')">${esc(p.project_name)}</span></td>
      <td class="c-muted">Step ${esc(p.step||'-')}</td>
      <td>${blk}</td>
      <td class="c-green">+${esc(fmt(p.saved||0))}</td>
      <td class="c-muted" style="font-size:10px">${esc((p.today_saved||0).toLocaleString())}</td>
    </tr>`;
  }).join('');
  panel.innerHTML = `<div class="ptitle">Projects Overview</div>
    <table><thead><tr>
      <th>Project</th><th>Step</th><th>Blockers</th><th>Saved (all)</th><th>Today</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
  const alertsEl = document.getElementById('alerts');
  if (alertsEl) alertsEl.before(panel); else document.body.appendChild(panel);
}

fetchProjects();
setInterval(fetchProjects, 5000);

let _es = null;

function connectSSE() {
  if (_es) { try { _es.close(); } catch(_) {} }
  _es = new EventSource('/api/stream');
  _es.onmessage = (e) => {
    if (paused) return;
    try { render(JSON.parse(e.data)); setCss('ldot','opacity','1'); } catch(_) {}
  };
  _es.onerror = () => {
    setCss('ldot','opacity','.4');
    // Auto-reconnect after 3s if connection fully closed
    setTimeout(() => { if (_es && _es.readyState === EventSource.CLOSED) connectSSE(); }, 3000);
  };
  _es.onopen = () => { setCss('ldot','opacity','1'); };
}

// Fetch initial data immediately, then connect SSE for live updates
fetch('/api/data')
  .then(r => r.json())
  .then(d => { render(d); connectSSE(); })
  .catch(() => connectSSE());
</script>
</body></html>
"""

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
            # Send current state immediately on connect
            self.wfile.write(f"data: {json.dumps(build_api_data())}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    msg = q.get(timeout=25)
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
                except _queue.Empty:
                    # Keepalive ping every 25s to prevent proxy timeouts
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            BROADCASTER.unsubscribe(q)

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
            result   = {}
            for pid, proj in projects.items():
                try:
                    result[pid] = build_project_data(
                        proj["cache_dir"],
                        str(Path(proj["path"]) / "flowctl-state.json")
                    )
                    result[pid]["active"] = proj.get("active", False)
                except Exception as e:
                    result[pid] = {
                        "project_id":   pid,
                        "project_name": proj.get("project_name", "?"),
                        "error":        str(e),
                    }
            self._send(json.dumps({"projects": result}).encode(), "application/json")
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
    httpd = HTTPServer(("127.0.0.1", port), MonitorHandler)

    def _stop(*_):
        print("\n[flowctl monitor] Stopping...")
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    # Start file watcher for SSE push (watches events + stats for changes)
    watch_paths = [str(p) for p in [EVENTS_F, STATS_F] if p.exists()]
    if not watch_paths:
        watch_paths = [str(EVENTS_F)]  # watch even if not yet created
    FileWatcher(watch_paths).start()

    print(f"[flowctl monitor] Dashboard: {url}")
    print("[flowctl monitor] Ctrl+C to stop")
    threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()

if __name__ == "__main__":
    main()
