#!/usr/bin/env python3
"""Token Monitor - web dashboard for MCP shell proxy.
Opens browser at http://localhost:3170. Ctrl+C to stop.
"""

import json, sys, signal, socket, threading, webbrowser
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

# -- Data loading (same sources as monitor.py) ---------------------------------

def load_stats():
    try: return json.loads(STATS_F.read_text()) if STATS_F.exists() else {}
    except: return {}

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

def build_api_data():
    """Build complete JSON payload for the dashboard."""
    stats  = load_stats()
    events = load_events()
    wf     = load_flow_state()
    turns  = group_into_turns(events)
    alerts = check_alerts(stats, events)

    step     = wf.get("current_step", 0)
    consumed = stats.get("total_consumed_tokens") or stats.get("total_consumed", 0)
    saved    = stats.get("total_saved_tokens")    or stats.get("total_saved",    0)
    budget   = STEP_BUDGETS.get(step, 12000)

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
        "step":      step,
        "step_name": (wf.get("steps",{}).get(str(step),{}) or {}).get("name", ""),
        "consumed":  consumed,
        "saved":     saved,
        "cost_usd":  round(stats.get("total_cost_usd",0), 6),
        "saved_usd": round(stats.get("total_saved_usd",0), 6),
        "waste_tok": stats.get("bash_waste_tokens", 0),
        "eff_pct":   round(saved / (consumed + saved) * 100, 1) if (consumed + saved) else 0,
        "budget":    budget,
        "bud_pct":   round(consumed / budget * 100, 1) if budget else 0,
        "duration":  session_duration(stats),
        "tools":     tools_data,
        "activity":  [compute_turn_summary(t) for t in turns[-10:]],
        "calls":     build_calls_log(events),
        "alerts":    alerts,
        "ts":        datetime.now().strftime("%H:%M:%S"),
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

@media(max-width:768px){.stats,.main{grid-template-columns:1fr}}
</style>
</head>
<body>

<div class="hdr">
  <span class="hdr-title">&#9670; FLOWCTL MONITOR</span>
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

async function fetchAll() {
  if (paused) return;
  try {
    const r = await fetch('/api/data');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    render(await r.json());
    setCss('ldot', 'opacity', '1');
  } catch (_) {
    setCss('ldot', 'opacity', '.4');
  }
}

fetchAll();
setInterval(fetchAll, 2000);
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

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self._send(HTML.encode(), "text/html; charset=utf-8")
        elif path == "/api/data":
            self._send(json.dumps(build_api_data()).encode(), "application/json")
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
    port, once = 3170, False
    for arg in sys.argv[1:]:
        if arg == "--once":
            once = True
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

    print(f"[flowctl monitor] Dashboard: {url}")
    print("[flowctl monitor] Ctrl+C to stop")
    threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()

if __name__ == "__main__":
    main()
