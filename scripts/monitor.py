#!/usr/bin/env python3
"""
Token Monitor — Real-time TUI dashboard for MCP shell proxy.
Keys: q=quit  p=pause/resume  r=refresh  +/-=speed  h=help
"""

import json, sys, os, time, signal, threading
from pathlib import Path
from datetime import datetime, timezone

REPO        = Path(__file__).resolve().parent.parent
CACHE       = REPO / ".cache" / "mcp"
EVENTS_F    = CACHE / "events.jsonl"
STATS_F     = CACHE / "session-stats.json"
STATE_F     = REPO / "workflow-state.json"

THRESHOLDS  = {"bash_waste_per_event": 400, "cache_hit_rate_min": 0.65}
STEP_BUDGETS = {1:8000, 2:12000, 3:10000, 4:18000, 5:18000, 6:14000, 7:12000, 8:10000, 9:8000}

try:
    from rich.live import Live
    from rich.table import Table
    from rich.console import Console
    from rich.panel import Panel
    from rich.columns import Columns
    from rich.text import Text
    from rich.rule import Rule
    from rich.layout import Layout
    from rich.console import Group as RGroup
    from rich import box
    USE_RICH = True
except ImportError:
    USE_RICH = False

# ── Keyboard input (no extra deps) ────────────────────────────

_state        = {"quit": False, "paused": False, "force_refresh": False, "help": False}
_interval_ref = [2.0]

def _key_reader():
    try:
        import tty, termios, select
        fd  = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
        try:
            while not _state["quit"]:
                if select.select([sys.stdin], [], [], 0.05)[0]:
                    ch = os.read(fd, 1).decode("utf-8", errors="ignore").lower()
                    if   ch == "q": _state["quit"]         = True
                    elif ch == "p": _state["paused"]        = not _state["paused"]
                    elif ch == "r": _state["force_refresh"] = True
                    elif ch == "h": _state["help"]          = not _state["help"]
                    elif ch == "+": _interval_ref[0]        = max(0.5, _interval_ref[0] - 0.5)
                    elif ch == "-": _interval_ref[0]        = min(10.0, _interval_ref[0] + 0.5)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception:
        pass

# ── Data loading ──────────────────────────────────────────────

def load_stats():
    try: return json.loads(STATS_F.read_text()) if STATS_F.exists() else {}
    except Exception: return {}

def load_events(last_n=80):
    if not EVENTS_F.exists(): return []
    try:
        events = []
        for line in EVENTS_F.read_text().strip().split("\n")[-last_n:]:
            if line.strip():
                try: events.append(json.loads(line))
                except: pass
        return events
    except Exception: return []

def load_workflow_state():
    try: return json.loads(STATE_F.read_text()) if STATE_F.exists() else {}
    except Exception: return {}

# ── Computation ───────────────────────────────────────────────

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
        ts       = turn[-1].get("ts","")[:19].replace("T"," "),
        agent    = next((e.get("agent","?") for e in turn if e.get("agent","unknown") != "unknown"), "?"),
        tools    = [e.get("tool","") for e in turn if e.get("type") == "mcp"],
        bash_cmds= [e.get("cmd","") for e in turn if e.get("type") == "bash"],
        saved    = sum(e.get("saved_tokens",0) for e in turn),
        consumed = sum(e.get("output_tokens",0) for e in turn),
        waste    = sum(e.get("waste_tokens",0) for e in turn),
        cost     = sum(e.get("cost_usd",0) for e in turn),
    )

def calc_hit_rate(stats):
    tools = stats.get("tools", {})
    calls = sum(t.get("calls",0) for t in tools.values())
    hits  = sum(t.get("hits",0) for t in tools.values())
    return hits / calls if calls else 0.0

def session_duration(stats):
    start = stats.get("session_start")
    if not start: return "——:——:——"
    try:
        delta = datetime.now(timezone.utc) - datetime.fromisoformat(start.replace("Z","+00:00"))
        h, rem = divmod(int(delta.total_seconds()), 3600)
        m, s   = divmod(rem, 60)
        return f"{h:02d}:{m:02d}:{s:02d}"
    except: return "——:——:——"

def check_alerts(stats, events):
    alerts = []
    hr = calc_hit_rate(stats)
    if 0 < hr < THRESHOLDS["cache_hit_rate_min"]:
        alerts.append(f"Cache hit rate {hr:.0%} — below {THRESHOLDS['cache_hit_rate_min']:.0%} threshold")
    waste = sum(e.get("waste_tokens",0) for e in events[-20:] if e.get("type")=="bash")
    if waste > THRESHOLDS["bash_waste_per_event"] * 3:
        alerts.append(f"High bash waste recently: ~{waste:,} tok — use MCP tools instead")
    return alerts

# ── Render helpers ─────────────────────────────────────────────

def progress_bar(pct, width=10, lo=100, hi=150):
    """Colored progress bar. lo/hi are warn/danger thresholds (for budget bars)."""
    filled = max(0, min(width, int(pct / 100 * width)))
    color  = "green" if pct <= lo else ("yellow" if pct <= hi else "red")
    return f"[{color}]{'█'*filled}[/{color}][dim]{'░'*(width-filled)}[/dim]"

def eff_bar(pct, width=8):
    filled = max(0, min(width, int(pct / 100 * width)))
    color  = "green" if pct >= 65 else ("yellow" if pct >= 35 else "red")
    return f"[{color}]{'█'*filled}[/{color}][dim]{'░'*(width-filled)}[/dim]"

def hit_bar(rate, width=8):
    filled = int(rate * width)
    color  = "green" if rate >= 0.8 else ("yellow" if rate >= 0.6 else "red")
    return f"[{color}]{'█'*filled}[/{color}][dim]{'░'*(width-filled)}[/dim]"

# ── Rich renderer ─────────────────────────────────────────────

def render_rich(live_mode=False):
    stats  = load_stats()
    events = load_events(100)
    wf     = load_workflow_state()
    turns  = group_into_turns(events)
    alerts = check_alerts(stats, events)

    step      = wf.get("current_step", 0)
    step_name = (wf.get("steps",{}).get(str(step),{}) or {}).get("name","—")
    consumed  = stats.get("total_consumed_tokens") or stats.get("total_consumed", 0)
    saved     = stats.get("total_saved_tokens")    or stats.get("total_saved",    0)
    cost_usd  = stats.get("total_cost_usd",   0)
    saved_usd = stats.get("total_saved_usd",  0)
    waste_tok = stats.get("bash_waste_tokens", 0)
    eff_pct   = saved / (consumed + saved) * 100 if (consumed + saved) else 0
    budget    = STEP_BUDGETS.get(step, 12000)
    bud_pct   = consumed / budget * 100 if budget else 0
    dur       = session_duration(stats)
    now_str   = datetime.now().strftime("%H:%M:%S")
    paused    = _state["paused"]

    # ── Header ──
    status_badge = "[bold yellow] ⏸ PAUSED [/bold yellow]" if paused else "[bold green] ● LIVE [/bold green]"
    header = Panel(
        Text.from_markup(
            f"[bold cyan]◆ TOKEN MONITOR[/bold cyan]  [dim]│[/dim]"
            f"  [dim]Step[/dim] [bold]{step}[/bold][dim]  {step_name}[/dim]"
            f"  [dim]│[/dim]  [dim]⏱[/dim] [white]{dur}[/white]"
            f"  [dim]│[/dim]  {status_badge}"
            f"  [dim]│[/dim]  [dim]{now_str}  {_interval_ref[0]:.1f}s[/dim]"
        ),
        box=box.HORIZONTALS, style="cyan", padding=(0, 1),
    )

    # ── Stats row ──
    eff_color = "green" if eff_pct >= 65 else ("yellow" if eff_pct >= 35 else "red")
    consumed_panel = Panel(
        Text.from_markup(
            f"[dim]CONSUMED[/dim]\n"
            f"[bold yellow]{consumed:,}[/bold yellow] [dim]tokens[/dim]\n"
            f"[dim]${cost_usd:.4f} USD[/dim]"
        ),
        box=box.ROUNDED, border_style="yellow", padding=(0, 2),
    )
    saved_panel = Panel(
        Text.from_markup(
            f"[dim]SAVED[/dim]\n"
            f"[bold green]{saved:,}[/bold green] [dim]tokens[/dim]\n"
            f"[dim]${saved_usd:.4f} USD[/dim]"
        ),
        box=box.ROUNDED, border_style="green", padding=(0, 2),
    )
    eff_panel = Panel(
        Text.from_markup(
            f"[dim]EFFICIENCY[/dim]\n"
            f"[bold {eff_color}]{eff_pct:.0f}%[/bold {eff_color}]  {eff_bar(eff_pct)}\n"
            f"[dim]waste ~{waste_tok:,} tok[/dim]"
        ),
        box=box.ROUNDED, border_style=eff_color, padding=(0, 2),
    )
    # Table-based stats row fills terminal width evenly (Columns doesn't respect expand)
    stats_tbl = Table(box=None, show_header=False, padding=(0, 0), expand=True)
    stats_tbl.add_column(ratio=1); stats_tbl.add_column(ratio=1); stats_tbl.add_column(ratio=1)
    stats_tbl.add_row(consumed_panel, saved_panel, eff_panel)
    stats_row = stats_tbl

    # ── Budget bar ──
    bud_color  = "red" if bud_pct > 150 else ("yellow" if bud_pct > 100 else "green")
    budget_txt = Text.from_markup(
        f"  [dim]Step {step} budget[/dim]  "
        f"[bold {bud_color}]{bud_pct:.0f}%[/bold {bud_color}]"
        f"  {progress_bar(min(bud_pct, 100), 14)}"
        f"  [dim]of ~{budget:,} typical[/dim]"
    )

    # ── MCP Tools table ──
    tool_table = Table(
        title="[bold]MCP Tools[/bold]", box=box.SIMPLE_HEAD,
        padding=(0,1), title_style="cyan", border_style="dim",
    )
    tool_table.add_column("Tool",  style="cyan", width=20, no_wrap=True)
    tool_table.add_column("Calls", justify="right", width=5)
    tool_table.add_column("Hits",  justify="right", width=6)
    tool_table.add_column("Hit%",  justify="right", width=5)
    tool_table.add_column("Bar",   width=10)
    tool_table.add_column("Saved", justify="right", width=8, style="dim")
    for name, t in sorted((stats.get("tools") or {}).items(), key=lambda x: -x[1].get("calls",0)):
        calls = t.get("calls",0); hits = t.get("hits",0); sv = t.get("saved",0)
        rate  = hits / calls if calls else 0
        color = "green" if rate >= 0.8 else ("yellow" if rate >= 0.6 else "red")
        tool_table.add_row(
            name, str(calls),
            f"[{color}]{hits}[/{color}]",
            f"[{color}]{rate:.0%}[/{color}]",
            hit_bar(rate), f"~{sv:,}",
        )

    # ── Recent Activity table ──
    act_table = Table(
        title="[bold]Recent Activity[/bold]", box=box.SIMPLE_HEAD,
        padding=(0,1), title_style="cyan", border_style="dim",
    )
    act_table.add_column("Time", width=8,  style="dim", no_wrap=True)
    act_table.add_column("Ops",  width=28, no_wrap=True)
    act_table.add_column("Cost", justify="right", width=9,  style="dim", no_wrap=True)
    act_table.add_column("Tok",  justify="right", width=9,  no_wrap=True)
    for turn in turns[-9:]:
        s   = compute_turn_summary(turn)
        tool_parts = [f"[cyan]{t}[/cyan]" for t in s["tools"][:3]]
        if len(s["tools"]) > 3: tool_parts.append(f"[dim]+{len(s['tools'])-3}[/dim]")
        bash_parts = [f"[red]bash[/red][dim]:{c[:12]}[/dim]" for c in s["bash_cmds"][:1]]
        ops = "  ".join(tool_parts + bash_parts) or "[dim]—[/dim]"
        tok_color = "green" if s["saved"] > s["consumed"] else ("red" if s["consumed"] > 0 else "dim")
        tok_str   = f"[{tok_color}]{s['consumed']:,}[/{tok_color}]"
        if s["waste"]: tok_str += f"[red]⚠[/red]"
        act_table.add_row(
            s["ts"][-8:], ops,
            f"[dim]${s['cost']:.4f}[/dim]" if s["cost"] else "[dim]—[/dim]",
            tok_str,
        )

    # ── Alerts ──
    if alerts:
        alert_body = "\n".join(f"[bold red]⚠[/bold red]  {a}" for a in alerts)
        alert_panel = Panel(Text.from_markup(alert_body), title="Alerts",
                            box=box.ROUNDED, border_style="red", padding=(0,1))
    else:
        alert_panel = Panel(Text.from_markup("[green]✓[/green]  No alerts"), title="Alerts",
                            box=box.ROUNDED, border_style="dim green", padding=(0,1))

    # ── Help overlay ──
    help_panel = None
    if _state["help"]:
        help_panel = Panel(
            Text.from_markup(
                "[bold cyan]Keyboard Shortcuts[/bold cyan]\n\n"
                "  [bold white]q[/bold white]  Quit              "
                "[bold white]p[/bold white]  Pause / Resume\n"
                "  [bold white]r[/bold white]  Force refresh     "
                "[bold white]h[/bold white]  Toggle this help\n"
                "  [bold white]+[/bold white]  Faster (−0.5s)    "
                "[bold white]-[/bold white]  Slower (+0.5s)"
            ),
            box=box.ROUNDED, border_style="cyan", padding=(1,2),
        )

    # ── Footer ──
    footer = Rule(
        "[dim][bold]q[/bold] quit  "
        "[bold]p[/bold] pause  "
        "[bold]r[/bold] refresh  "
        "[bold]+[/bold]/[bold]-[/bold] speed  "
        "[bold]h[/bold] help[/dim]",
        style="dim",
    )

    if not live_mode:
        items = [header, stats_row, budget_txt, Columns([tool_table, act_table], expand=True)]
        if help_panel:
            items.append(help_panel)
        items += [alert_panel, footer]
        return RGroup(*items)

    # Layout for Live(screen=True) — properly partitions terminal height
    alert_height = len(alerts) + 3  # content lines + panel borders
    layout = Layout()
    layout.split_column(
        Layout(name="header",  size=3),
        Layout(name="stats",   size=5),
        Layout(name="budget",  size=1),
        Layout(name="main",    ratio=1),
        Layout(name="alerts",  size=max(alert_height, 4)),
        Layout(name="footer",  size=1),
    )
    layout["header"].update(header)
    layout["stats"].update(stats_row)
    layout["budget"].update(budget_txt)
    if help_panel:
        layout["main"].update(help_panel)
    else:
        layout["main"].split_row(
            Layout(tool_table, name="tools"),
            Layout(act_table,  name="activity"),
        )
    layout["alerts"].update(alert_panel)
    layout["footer"].update(footer)
    return layout

# ── ANSI fallback renderer ────────────────────────────────────

_R="\033[0m"; _B="\033[1m"; _D="\033[2m"
_RED="\033[31m"; _GRN="\033[32m"; _YEL="\033[33m"; _CYN="\033[36m"

def render_ansi():
    stats  = load_stats()
    events = load_events(50)
    wf     = load_workflow_state()
    turns  = group_into_turns(events)
    alerts = check_alerts(stats, events)

    consumed = stats.get("total_consumed_tokens") or stats.get("total_consumed", 0)
    saved    = stats.get("total_saved_tokens")    or stats.get("total_saved",    0)
    cost_usd = stats.get("total_cost_usd",  0)
    waste    = stats.get("bash_waste_tokens", 0)
    eff      = saved / (consumed + saved) * 100 if (consumed + saved) else 0
    step     = wf.get("current_step", 0)
    step_name= (wf.get("steps",{}).get(str(step),{}) or {}).get("name","—")
    dur      = session_duration(stats)
    paused   = _state["paused"]
    W = 72

    # clear screen with ANSI escape (avoids os.system)
    sys.stdout.write("\033[2J\033[H"); sys.stdout.flush()

    status = f"{_YEL}⏸ PAUSED{_R}" if paused else f"{_GRN}● LIVE{_R}"
    print(f"{_B}{_CYN}{'─'*W}{_R}")
    print(f"{_B}{_CYN}  ◆ TOKEN MONITOR{_R}  │  Step {step}: {step_name}  │  {dur}  │  {status}")
    print(f"{_CYN}{'─'*W}{_R}")
    bar = "█"*int(eff/10) + "░"*(10-int(eff/10))
    print(f"  {_YEL}CONSUMED  {consumed:>8,} tok  ${cost_usd:.4f}{_R}")
    print(f"  {_GRN}SAVED     {saved:>8,} tok{_R}")
    print(f"  {_CYN}EFFICIENCY {eff:.0f}%  {bar}  waste ~{waste:,}{_R}")
    print(f"{_CYN}{'─'*W}{_R}")
    print(f"{_B}  MCP TOOLS{_R}")
    for name, t in sorted((stats.get("tools") or {}).items(), key=lambda x: -x[1].get("calls",0)):
        calls=t.get("calls",0); hits=t.get("hits",0); sv=t.get("saved",0)
        rate = hits/calls if calls else 0
        bar  = "█"*int(rate*8) + "░"*(8-int(rate*8))
        c    = _GRN if rate>=0.8 else (_YEL if rate>=0.6 else _RED)
        print(f"  {_CYN}{name:<20}{_R} {calls:3}calls  {c}{hits}/{calls} {rate:.0%} {bar}{_R}  ~{sv:,}saved")
    print(f"{_CYN}{'─'*W}{_R}")
    print(f"{_B}  RECENT ACTIVITY{_R}")
    for turn in turns[-6:]:
        s = compute_turn_summary(turn)
        tools_str = " ".join(s["tools"][:3])
        cost_str  = f"${s['cost']:.4f}"
        print(f"  {_D}{s['ts'][-8:]}{_R}  {_CYN}{s['agent']:<8}{_R}  {tools_str:<24}  {cost_str}")
    print(f"{_CYN}{'─'*W}{_R}")
    if alerts:
        for a in alerts: print(f"  {_RED}{_B}⚠  {a}{_R}")
    else:
        print(f"  {_GRN}✓ No alerts{_R}")
    print(f"{_CYN}{'─'*W}{_R}")
    print(f"  {_D}[q] quit  [p] pause  [r] refresh  [+/-] speed  interval={_interval_ref[0]:.1f}s{_R}")

# ── Main ──────────────────────────────────────────────────────

def main():
    for arg in sys.argv[1:]:
        if arg == "--once": _interval_ref[0] = 0
        elif arg.startswith("--interval="):
            try: _interval_ref[0] = float(arg.split("=")[1])
            except: pass

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    if _interval_ref[0] == 0:
        Console().print(render_rich()) if USE_RICH else render_ansi()
        return

    threading.Thread(target=_key_reader, daemon=True).start()

    if USE_RICH:
        with Live(render_rich(live_mode=True), refresh_per_second=4, screen=True, console=Console()) as live:
            while not _state["quit"]:
                time.sleep(0.1)
                if not _state["paused"] or _state["force_refresh"]:
                    _state["force_refresh"] = False
                    live.update(render_rich(live_mode=True))
    else:
        while not _state["quit"]:
            if not _state["paused"] or _state["force_refresh"]:
                _state["force_refresh"] = False
                render_ansi()
            time.sleep(0.1)

if __name__ == "__main__":
    main()
