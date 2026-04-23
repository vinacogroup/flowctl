#!/usr/bin/env python3
"""
Token Monitor — Real-time terminal dashboard for MCP shell proxy.
Run in a separate terminal: python3 scripts/monitor.py
Or: bash scripts/workflow.sh monitor
"""

import json, sys, os, time, signal
from pathlib import Path
from datetime import datetime, timezone
from collections import defaultdict

REPO      = Path(__file__).resolve().parent.parent
CACHE     = REPO / ".cache" / "mcp"
EVENTS_F  = CACHE / "events.jsonl"
STATS_F   = CACHE / "session-stats.json"
STATE_F   = REPO / "workflow-state.json"
BASELINES_F = CACHE / "_baselines.json"

# Thresholds for alerts
THRESHOLDS = {
    "bash_waste_per_event": 400,   # tokens
    "cache_hit_rate_min":   0.65,
    "step_budget_ratio":    2.0,
}

# Step typical token budgets (will be updated from actuals)
STEP_BUDGETS = { 1: 8000, 2: 12000, 3: 10000, 4: 18000, 5: 18000, 6: 14000, 7: 12000, 8: 10000, 9: 8000 }

# ANSI codes (used when rich not available)
R = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; BLU = "\033[34m"; MAG = "\033[35m"; CYN = "\033[36m"

# ── Try rich ──────────────────────────────────────────────────

try:
    from rich.live import Live
    from rich.table import Table
    from rich.console import Console
    from rich.panel import Panel
    from rich.columns import Columns
    from rich.text import Text
    from rich import box
    USE_RICH = True
except ImportError:
    USE_RICH = False

# ── Data loading ──────────────────────────────────────────────

def load_stats():
    if not STATS_F.exists():
        return {}
    try:
        return json.loads(STATS_F.read_text())
    except Exception:
        return {}

def load_events(last_n=80):
    if not EVENTS_F.exists():
        return []
    try:
        lines = EVENTS_F.read_text().strip().split("\n")
        events = []
        for l in lines[-last_n:]:
            if l.strip():
                try: events.append(json.loads(l))
                except: pass
        return events
    except Exception:
        return []

def load_workflow_state():
    if not STATE_F.exists():
        return {}
    try:
        return json.loads(STATE_F.read_text())
    except Exception:
        return {}

def load_baselines():
    if not BASELINES_F.exists():
        return {}
    try:
        return json.loads(BASELINES_F.read_text())
    except Exception:
        return {}

# ── Computation ───────────────────────────────────────────────

def group_into_turns(events, gap_sec=2.0):
    """Group events within 2-second windows into 'turns'."""
    turns = []
    current = []
    for e in events:
        try:
            ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).timestamp()
        except Exception:
            ts = 0
        e["_ts_epoch"] = ts
        if current:
            prev_ts = current[-1]["_ts_epoch"]
            if ts - prev_ts > gap_sec:
                turns.append(current)
                current = []
        current.append(e)
    if current:
        turns.append(current)
    return turns

def compute_turn_summary(turn):
    mcp_hits   = sum(1 for e in turn if e.get("type") == "mcp" and e.get("cache") == "hit")
    mcp_misses = sum(1 for e in turn if e.get("type") == "mcp" and e.get("cache") == "miss")
    saved      = sum(e.get("saved_tokens", 0) for e in turn)
    consumed   = sum(e.get("output_tokens", 0) for e in turn)
    waste      = sum(e.get("waste_tokens", 0) for e in turn)
    agent      = next((e.get("agent","?") for e in turn if e.get("agent") and e.get("agent") != "unknown"), "?")
    tools      = [e.get("tool","bash") for e in turn if e.get("type") == "mcp"]
    bash_cmds  = [e.get("cmd","") for e in turn if e.get("type") == "bash"]
    ts         = turn[-1].get("ts","")[:19].replace("T"," ")
    return dict(ts=ts, agent=agent, mcp_hits=mcp_hits, mcp_misses=mcp_misses,
                saved=saved, consumed=consumed, waste=waste, tools=tools, bash_cmds=bash_cmds)

def calc_hit_rate(stats, tool=None):
    tools = stats.get("tools", {})
    if tool:
        t = tools.get(tool, {})
        calls = t.get("calls", 0)
        hits  = t.get("hits", 0)
        return hits / calls if calls else 0
    total_calls = sum(t.get("calls",0) for t in tools.values())
    total_hits  = sum(t.get("hits",0) for t in tools.values())
    return total_hits / total_calls if total_calls else 0

def session_duration(stats):
    start = stats.get("session_start")
    if not start:
        return "—"
    try:
        t0 = datetime.fromisoformat(start.replace("Z","+00:00"))
        delta = datetime.now(timezone.utc) - t0
        h, rem = divmod(int(delta.total_seconds()), 3600)
        m, s = divmod(rem, 60)
        return f"{h:02d}:{m:02d}:{s:02d}"
    except Exception:
        return "—"

# ── Alerts ────────────────────────────────────────────────────

def check_alerts(stats, events):
    alerts = []
    # Cache hit rate
    hr = calc_hit_rate(stats)
    if hr > 0 and hr < THRESHOLDS["cache_hit_rate_min"]:
        alerts.append(f"⚠️  Cache hit rate {hr:.0%} below {THRESHOLDS['cache_hit_rate_min']:.0%} threshold")
    # Recent bash waste
    recent_waste = sum(e.get("waste_tokens",0) for e in events[-20:] if e.get("type")=="bash")
    if recent_waste > THRESHOLDS["bash_waste_per_event"] * 3:
        alerts.append(f"⚠️  High bash waste recently: ~{recent_waste:,} tokens — use MCP tools")
    return alerts

# ── Rich renderer ─────────────────────────────────────────────

def render_rich(console):
    stats   = load_stats()
    events  = load_events(100)
    wf      = load_workflow_state()
    turns   = group_into_turns(events)
    alerts  = check_alerts(stats, events)

    step       = wf.get("current_step", 0)
    step_name  = (wf.get("steps",{}).get(str(step),{}) or {}).get("name","—")
    consumed   = stats.get("total_consumed_tokens") or stats.get("total_consumed", 0)
    saved      = stats.get("total_saved_tokens") or stats.get("total_saved", 0)
    cost_usd   = stats.get("total_cost_usd", 0)
    saved_usd  = stats.get("total_saved_usd", 0)
    waste_tok  = stats.get("bash_waste_tokens", 0)
    efficiency = consumed + saved
    eff_pct    = saved / efficiency * 100 if efficiency else 0
    bar_filled = int(eff_pct / 10)
    eff_bar    = "█" * bar_filled + "░" * (10 - bar_filled)
    budget     = STEP_BUDGETS.get(step, 12000)
    budget_pct = consumed / budget * 100 if budget else 0
    dur        = session_duration(stats)

    # ── Header panel ──
    header_txt = Text()
    header_txt.append(f"📊 TOKEN MONITOR", style="bold cyan")
    header_txt.append(f"  |  Step {step}: {step_name}", style="white")
    header_txt.append(f"  |  {dur}", style="dim")
    header_panel = Panel(header_txt, box=box.HORIZONTALS, style="cyan")

    # ── Summary table ──
    sum_table = Table(box=box.SIMPLE, show_header=False, padding=(0,1))
    sum_table.add_column(width=22); sum_table.add_column(width=22); sum_table.add_column(width=22)
    sum_table.add_row(
        Text(f"CONSUMED\n~{consumed:,} tokens\n${cost_usd:.4f}", style="yellow"),
        Text(f"SAVED\n~{saved:,} tokens\n${saved_usd:.4f}", style="green"),
        Text(f"EFFICIENCY\n{eff_pct:.0f}%  {eff_bar}\nWaste: ~{waste_tok:,} tok", style="cyan"),
    )

    # ── Step budget ──
    bud_bar = "█" * min(int(budget_pct / 10), 10) + "░" * max(0, 10 - int(budget_pct / 10))
    bud_color = "red" if budget_pct > 150 else ("yellow" if budget_pct > 100 else "green")
    bud_txt = Text(f"Step {step} budget: {budget_pct:.0f}% of ~{budget:,} typical  {bud_bar}", style=bud_color)

    # ── Per-tool table ──
    tool_table = Table(title="MCP Tools", box=box.SIMPLE, padding=(0,1))
    tool_table.add_column("Tool", style="cyan", width=18)
    tool_table.add_column("Calls", justify="right", width=6)
    tool_table.add_column("Hit%", justify="right", width=6)
    tool_table.add_column("Saved", justify="right", width=8)
    tool_table.add_column("Bar", width=12)
    for name, t in sorted((stats.get("tools") or {}).items(), key=lambda x: -x[1].get("saved",0)):
        calls = t.get("calls",0); hits = t.get("hits",0); sv = t.get("saved",0)
        rate  = hits/calls if calls else 0
        bar   = "█" * int(rate*10) + "░" * (10-int(rate*10))
        color = "green" if rate >= 0.8 else ("yellow" if rate >= 0.6 else "red")
        tool_table.add_row(name, str(calls), f"[{color}]{rate:.0%}[/{color}]", f"~{sv:,}", f"[{color}]{bar[:10]}[/{color}]")

    # ── Recent activity (turns) ──
    act_table = Table(title="Recent Activity (grouped by turn)", box=box.SIMPLE, padding=(0,1))
    act_table.add_column("Time", width=8, style="dim")
    act_table.add_column("Agent", width=10, style="cyan")
    act_table.add_column("Operations", width=28)
    act_table.add_column("Net tokens", justify="right", width=12)
    for turn in turns[-8:]:
        s = compute_turn_summary(turn)
        ops = []
        for tool in s["tools"]: ops.append(f"[green]{tool}[/green]")
        for cmd in s["bash_cmds"][:2]:
            short = cmd[:20] + "…" if len(cmd) > 20 else cmd
            ops.append(f"[red]bash: {short}[/red]")
        net = s["saved"] - s["consumed"] - s["waste"]
        net_str = f"[green]+{s['saved']:,}[/green]" if s["saved"] > s["consumed"] else f"[red]-{s['consumed']:,}[/red]"
        if s["waste"]: net_str += f" [red]⚠{s['waste']:,}[/red]"
        act_table.add_row(s["ts"][-8:], s["agent"] or "—", "  ".join(ops) or "—", net_str)

    # ── Alerts ──
    alert_lines = "\n".join(alerts) if alerts else "✓ No alerts"
    alert_style = "red bold" if alerts else "green"
    alert_panel = Panel(Text(alert_lines, style=alert_style), title="Alerts", box=box.SIMPLE)

    from rich.layout import Layout
    layout = Layout()
    layout.split_column(
        Layout(header_panel, size=3),
        Layout(sum_table, size=5),
        Layout(bud_txt, size=1),
        Layout(Columns([tool_table, act_table]), size=14),
        Layout(alert_panel, size=3),
    )
    return layout

# ── ANSI fallback renderer ────────────────────────────────────

def render_ansi():
    stats   = load_stats()
    events  = load_events(50)
    wf      = load_workflow_state()
    turns   = group_into_turns(events)
    alerts  = check_alerts(stats, events)

    consumed = stats.get("total_consumed_tokens") or stats.get("total_consumed", 0)
    saved    = stats.get("total_saved_tokens") or stats.get("total_saved", 0)
    cost_usd = stats.get("total_cost_usd", 0)
    saved_usd= stats.get("total_saved_usd", 0)
    waste    = stats.get("bash_waste_tokens", 0)
    eff      = saved / (consumed + saved) * 100 if (consumed + saved) else 0
    step     = wf.get("current_step", 0)
    step_name= (wf.get("steps",{}).get(str(step),{}) or {}).get("name","—")
    dur      = session_duration(stats)

    os.system("clear")
    width = 72
    print(f"{BOLD}{CYN}{'─'*width}{R}")
    print(f"{BOLD}{CYN}  📊 TOKEN MONITOR  |  Step {step}: {step_name}  |  {dur}{R}")
    print(f"{CYN}{'─'*width}{R}")
    bar = "█" * int(eff/10) + "░" * (10-int(eff/10))
    print(f"  {YEL}CONSUMED: ~{consumed:>8,} tok  ${cost_usd:.4f}{R}")
    print(f"  {GRN}SAVED:    ~{saved:>8,} tok  ${saved_usd:.4f}{R}")
    print(f"  {CYN}EFFICIENCY: {eff:.0f}%  {bar}  WASTE: ~{waste:,}{R}")
    print(f"{CYN}{'─'*width}{R}")

    # Per-tool
    print(f"{BOLD}  MCP TOOLS{R}")
    for name, t in sorted((stats.get("tools") or {}).items(), key=lambda x: -x[1].get("calls",0)):
        calls = t.get("calls",0); hits = t.get("hits",0); sv = t.get("saved",0)
        rate = hits/calls if calls else 0
        bar = "█"*int(rate*8) + "░"*(8-int(rate*8))
        color = GRN if rate >= 0.8 else (YEL if rate >= 0.6 else RED)
        print(f"  {CYN}{name:<20}{R} {calls:3} calls  {color}{rate:.0%} {bar}{R}  saved ~{sv:,}")
    print(f"{CYN}{'─'*width}{R}")

    # Recent turns
    print(f"{BOLD}  RECENT ACTIVITY{R}")
    for turn in turns[-6:]:
        s = compute_turn_summary(turn)
        tools_str = " ".join(s["tools"][:3])
        waste_str = f" {RED}⚠+{s['waste']:,}waste{R}" if s["waste"] else ""
        saved_str = f"{GRN}+{s['saved']:,}{R}" if s["saved"] else f"{YEL}+0{R}"
        print(f"  {DIM}{s['ts'][-8:]}{R}  {CYN}{s['agent']:<10}{R}  {tools_str:<25}  {saved_str}{waste_str}")
    print(f"{CYN}{'─'*width}{R}")

    # Alerts
    if alerts:
        for a in alerts:
            print(f"  {RED}{BOLD}{a}{R}")
    else:
        print(f"  {GRN}✓ No alerts{R}")
    print(f"{CYN}{'─'*width}{R}")
    print(f"  {DIM}[Ctrl+C to exit]  refresh: 2s{R}")

# ── Main loop ─────────────────────────────────────────────────

def main():
    interval = 2.0
    for arg in sys.argv[1:]:
        if arg == "--once":  interval = 0
        if arg.startswith("--interval="):
            try: interval = float(arg.split("=")[1])
            except: pass

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    if USE_RICH:
        console = Console()
        if interval == 0:
            layout = render_rich(console)
            console.print(layout)
            return
        with Live(render_rich(console), refresh_per_second=1, screen=True) as live:
            while True:
                time.sleep(interval)
                live.update(render_rich(console))
    else:
        if interval == 0:
            render_ansi(); return
        while True:
            render_ansi()
            time.sleep(interval)

if __name__ == "__main__":
    main()
