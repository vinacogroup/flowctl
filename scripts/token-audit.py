#!/usr/bin/env python3
"""
flowctl token-audit — Phân tích token usage thực tế từ MCP events
Usage: flowctl audit-tokens [--days N] [--step N] [--format table|markdown|json] [--limit N]
"""

import argparse
import json
import os
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# ── ANSI colors ──────────────────────────────────────────────────────────────
R = "\033[31m"; Y = "\033[33m"; G = "\033[32m"; C = "\033[36m"
B = "\033[1m";  NC = "\033[0m"

def color(text, code): return f"{code}{text}{NC}"
def red(t): return color(t, R)
def yel(t): return color(t, Y)
def grn(t): return color(t, G)
def cyn(t): return color(t, C)
def bold(t): return color(t, B)

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT = Path(os.environ.get("FLOWCTL_PROJECT_ROOT",
                  os.environ.get("REPO_ROOT", Path(__file__).parent.parent)))
# Prefer FLOWCTL_CACHE_DIR / FLOWCTL_EVENTS_F / FLOWCTL_STATS_F set by flowctl.sh
# (v1.1+ home dir layout). Fallback: legacy .cache/mcp/ in project root.
_legacy_cache = REPO_ROOT / ".cache" / "mcp"
CACHE_DIR   = Path(os.environ.get("FLOWCTL_CACHE_DIR",  str(_legacy_cache)))
EVENTS_FILE = Path(os.environ.get("FLOWCTL_EVENTS_F",   str(CACHE_DIR / "events.jsonl")))
STATS_FILE  = Path(os.environ.get("FLOWCTL_STATS_F",    str(CACHE_DIR / "session-stats.json")))
GRAPHIFY_FILE = REPO_ROOT / ".graphify" / "graph.json"

# ── Overhead tools: chạy để setup context, không phải actual work ────────────
OVERHEAD_TOOLS = {
    "wf_state", "wf_step_context", "wf_git", "wf_files",
    "wf_read", "wf_env", "wf_reports_status", "wf_cache_invalidate",
    # graphify MCP tools (actual names from graphify.serve)
    "query_graph", "get_node", "get_neighbors", "get_community",
    "god_nodes", "graph_stats", "shortest_path",
    # legacy aliases (kept for backwards compat with old events)
    "graphify_query", "graphify_search", "graphify_get_dependencies",
    "graphify_get_clusters", "graphify_update_node", "graphify_snapshot",
    "gitnexus_query", "gitnexus_get_context", "gitnexus_detect_changes",
    "gitnexus_impact_analysis", "gitnexus_find_related", "gitnexus_get_architecture",
    "workflow_get_state", "workflow_add_decision", "workflow_add_blocker",
    "workflow_resolve_blocker", "workflow_request_approval",
}


def load_events(days: int | None = None, step: int | None = None) -> list[dict[str, Any]]:
    if not EVENTS_FILE.exists():
        return []
    events: list[dict[str, Any]] = []
    cutoff = None
    if days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    for line in EVENTS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if cutoff:
            ts_str = e.get("ts", "")
            if ts_str:
                try:
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    if ts < cutoff:
                        continue
                except ValueError:
                    pass
        if step is not None and e.get("step") not in (None, step, str(step)):
            continue
        events.append(e)
    return events


def load_session_stats() -> dict:
    if not STATS_FILE.exists():
        return {}
    try:
        return json.loads(STATS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def graphify_status() -> dict:
    if not GRAPHIFY_FILE.exists():
        return {"status": "MISSING", "nodes": 0, "relationships": 0}
    try:
        g = json.loads(GRAPHIFY_FILE.read_text(encoding="utf-8"))
        nodes = g.get("nodes", g.get("entities", []))
        rels  = g.get("relationships", g.get("edges", []))
        return {"status": "OK", "nodes": len(nodes), "relationships": len(rels)}
    except Exception:
        return {"status": "CORRUPT", "nodes": 0, "relationships": 0}


def analyze(events: list[dict[str, Any]]) -> dict[str, Any]:
    total_tokens   = 0
    saved_tokens   = 0
    total_cost_usd = 0.0
    saved_cost_usd = 0.0
    cache_hits     = 0
    cache_misses   = 0
    overhead_tokens = 0
    work_tokens    = 0

    per_tool: dict[str, dict] = defaultdict(lambda: {
        "calls": 0, "tokens": 0, "saved": 0, "hits": 0, "misses": 0, "cost_usd": 0.0
    })

    for e in events:
        tool   = e.get("tool") or "unknown"
        out_t  = e.get("output_tokens", 0)
        sav_t  = e.get("saved_tokens", 0)
        cost   = e.get("cost_usd", 0.0)
        saved_c= e.get("saved_usd", 0.0)
        cache  = e.get("cache", "miss")

        total_tokens   += out_t
        saved_tokens   += sav_t
        total_cost_usd += cost
        saved_cost_usd += saved_c

        if cache == "hit":
            cache_hits += 1
        else:
            cache_misses += 1

        if tool in OVERHEAD_TOOLS:
            overhead_tokens += out_t
        else:
            work_tokens += out_t

        per_tool[tool]["calls"]    += 1
        per_tool[tool]["tokens"]   += out_t
        per_tool[tool]["saved"]    += sav_t
        per_tool[tool]["cost_usd"] += cost
        if cache == "hit":
            per_tool[tool]["hits"] += 1
        else:
            per_tool[tool]["misses"] += 1

    total_calls = len(events)
    hit_rate = (cache_hits / total_calls * 100) if total_calls else 0
    overhead_pct = (overhead_tokens / total_tokens * 100) if total_tokens else 0

    return {
        "total_calls":      total_calls,
        "total_tokens":     total_tokens,
        "saved_tokens":     saved_tokens,
        "overhead_tokens":  overhead_tokens,
        "work_tokens":      work_tokens,
        "overhead_pct":     overhead_pct,
        "total_cost_usd":   total_cost_usd,
        "saved_cost_usd":   saved_cost_usd,
        "cache_hits":       cache_hits,
        "cache_misses":     cache_misses,
        "hit_rate":         hit_rate,
        "per_tool":         dict(per_tool),
    }


def infer_tier(work_tokens: int) -> str:
    if work_tokens <= 1500:
        return "MICRO"
    if work_tokens <= 12000:
        return "STANDARD"
    return "FULL"


def event_task_key(event: dict[str, Any]) -> str:
    for key in ("task_id", "run_id", "workflow_run_id", "flowctl_id", "correlation_id"):
        value = event.get(key)
        if value:
            return str(value)

    ts = str(event.get("ts", ""))
    if ts:
        try:
            parsed = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            return f"session-{parsed.date().isoformat()}"
        except ValueError:
            pass
    return "session-unknown"


def analyze_by_task(events: list[dict[str, Any]], limit: int | None = None) -> list[dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for event in events:
        key = event_task_key(event)
        row = rows.setdefault(
            key,
            {
                "task": key,
                "tier": "UNKNOWN",
                "total_tokens": 0,
                "overhead_tokens": 0,
                "work_tokens": 0,
                "calls": 0,
            },
        )
        tool = str(event.get("tool") or "unknown")
        out_t = int(event.get("output_tokens", 0) or 0)

        row["calls"] += 1
        row["total_tokens"] += out_t
        if tool in OVERHEAD_TOOLS:
            row["overhead_tokens"] += out_t
        else:
            row["work_tokens"] += out_t

        if event.get("tier"):
            row["tier"] = str(event["tier"]).upper()

    items = list(rows.values())
    for item in items:
        if item["tier"] == "UNKNOWN":
            item["tier"] = infer_tier(int(item["work_tokens"]))
        work = int(item["work_tokens"])
        overhead = int(item["overhead_tokens"])
        item["ratio"] = round((overhead / work), 2) if work > 0 else None

    items.sort(key=lambda x: int(x["total_tokens"]), reverse=True)
    if limit and limit > 0:
        return items[:limit]
    return items


def flag(value: float, warn: float, crit: float, higher_is_worse: bool = True) -> str:
    if higher_is_worse:
        if value >= crit:
            return red("●")
        if value >= warn:
            return yel("●")
        return grn("●")
    else:
        if value <= crit:
            return red("●")
        if value <= warn:
            return yel("●")
        return grn("●")


def print_table(task_rows: list[dict[str, Any]]) -> None:
    print("Token Audit Report")
    print()
    print(f"Tasks analyzed: {len(task_rows)}")
    print("─" * 78)
    print(f"{'Task':<24} | {'Tier':<8} | {'Total':>8} | {'Overhead':>8} | {'Work':>8} | {'Ratio':>6}")
    print("─" * 78)
    for row in task_rows:
        ratio = f"{row['ratio']}x" if row["ratio"] is not None else "n/a"
        print(
            f"{str(row['task'])[:24]:<24} | {row['tier']:<8} | "
            f"{row['total_tokens']:>8} | {row['overhead_tokens']:>8} | "
            f"{row['work_tokens']:>8} | {ratio:>6}"
        )


def print_markdown(task_rows: list[dict[str, Any]]) -> None:
    print("## Token Audit Report")
    print()
    print(f"Tasks analyzed: {len(task_rows)}")
    print()
    print("| Task | Tier | Total tokens | Overhead | Actual work | Ratio |")
    print("|------|------|--------------|----------|-------------|-------|")
    for row in task_rows:
        ratio = f"{row['ratio']}x" if row["ratio"] is not None else "n/a"
        print(
            f"| {row['task']} | {row['tier']} | {row['total_tokens']} | "
            f"{row['overhead_tokens']} | {row['work_tokens']} | {ratio} |"
        )


def print_summary_recommendations(stats: dict[str, Any]) -> None:
    total = int(stats["total_tokens"])
    overhead = int(stats["overhead_tokens"])
    work = int(stats["work_tokens"])
    overhead_pct = float(stats["overhead_pct"])
    print()
    print("Overhead breakdown:")
    print(f"  Context/setup tools : {overhead} tokens")
    print(f"  Actual work tools   : {work} tokens")
    print(f"  Overhead share      : {overhead_pct:.1f}%")
    print()
    print("Break-even analysis:")
    print("  MICRO tasks: overhead > benefit if total work < ~1,500 tokens")
    print("  STANDARD tasks: break-even around ~4,000 work tokens")
    print("  FULL tasks: break-even around ~12,000 work tokens")
    if total == 0:
        print("Recommendation: no data yet.")
    elif overhead_pct >= 60:
        print("Recommendation: reduce context/tool overhead for small tasks.")
    else:
        print("Recommendation: current overhead/work split is acceptable.")


def print_report(
    stats: dict[str, Any],
    task_rows: list[dict[str, Any]],
    session: dict[str, Any],
    graph: dict[str, Any],
    output_format: str = "table",
) -> None:
    if output_format == "json":
        out = {**stats, "tasks": task_rows, "session": session, "graphify": graph}
        out.pop("per_tool", None)
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return

    if output_format == "markdown":
        print_markdown(task_rows)
        print_summary_recommendations(stats)
        return

    if output_format == "table":
        print_table(task_rows)
        print_summary_recommendations(stats)
        return

    total   = stats["total_tokens"]
    saved   = stats["saved_tokens"]
    ohead   = stats["overhead_tokens"]
    work    = stats["work_tokens"]
    hit_r   = stats["hit_rate"]
    cost    = stats["total_cost_usd"]
    ohead_p = stats["overhead_pct"]
    bash_w  = session.get("bash_waste_tokens", 0)
    bash_c  = session.get("bash_calls", 0)

    # Effective tokens = what would be used WITHOUT the caching system
    potential_saved = saved
    effective_ratio = (ohead / total * 100) if total else 0

    print(f"\n{bold('═══ flowctl Token Audit ═══')}")
    print(f"  Events analyzed : {bold(str(stats['total_calls']))}")
    print(f"  Time range      : all events in events.jsonl\n")

    # ── Token summary ──────────────────────────────────────────────────────
    print(bold("Token Summary"))
    print(f"  Total output tokens    : {bold(str(total)):>10}")
    print(f"  ├─ Overhead (context)  : {yel(str(ohead)):>10}  {ohead_p:5.1f}%  {flag(ohead_p, 40, 60)}")
    print(f"  └─ Actual work         : {grn(str(work)):>10}  {100-ohead_p:5.1f}%")
    print(f"  Saved by cache         : {bold(str(saved)):>10}  {'(none yet)' if saved == 0 else ''}")
    if bash_w > 0:
        print(f"  Bash waste tokens      : {red(str(bash_w)):>10}  (bash calls: {bash_c})")
    print()

    # ── Cache health ───────────────────────────────────────────────────────
    print(bold("Cache Health"))
    hit_flag = flag(hit_r, 50, 20, higher_is_worse=False)
    print(f"  Hit rate      : {bold(f'{hit_r:.1f}%'):>8}  {hit_flag}")
    print(f"  Hits / Misses : {stats['cache_hits']} / {stats['cache_misses']}")
    if hit_r == 0:
        print(f"  {red('⚠ Cache chưa tiết kiệm được bất kỳ token nào.')}")
        print(f"     Kiểm tra: MCP shell-proxy server có đang chạy không?")
        print(f"     Kiểm tra: wf_cache_invalidate có đang flush quá thường xuyên không?\n")
    elif hit_r < 30:
        print(f"  {yel('Cache hit rate thấp — xem xét tăng TTL hoặc reduce invalidation scope.')}\n")
    else:
        print()

    # ── Cost ──────────────────────────────────────────────────────────────
    print(bold("Cost"))
    print(f"  Total cost USD : ${cost:.4f}")
    print(f"  Saved USD      : ${stats['saved_cost_usd']:.4f}")
    print()

    # ── Graphify health ────────────────────────────────────────────────────
    print(bold("Graphify Health"))
    g_status = graph["status"]
    g_nodes  = graph["nodes"]
    g_rels   = graph["relationships"]
    if g_status == "MISSING":
        print(f"  Status : {red('MISSING')}  — graph.json không tồn tại")
        print(f"  {red('⚠ Graphify chưa có graph. Mọi query_graph() đều trả về rỗng.')}")
        print(f"     → Tất cả overhead từ Graphify là lãng phí thuần túy.")
        print(f"     → Fix: Chạy `python3 -m graphify update .` để build code graph.\n")
    elif g_nodes < 10:
        print(f"  Status : {yel('SPARSE')}  — {g_nodes} nodes, {g_rels} relationships")
        print(f"  {yel('Graph quá thưa. Graphify queries ít có giá trị.')}\n")
    else:
        print(f"  Status : {grn('OK')}  — {g_nodes} nodes, {g_rels} relationships\n")

    # ── Per-tool breakdown (top 10 by token) ──────────────────────────────
    print(bold("Top Tools by Token Usage"))
    print(f"  {'Tool':<40} {'Calls':>5}  {'Tokens':>7}  {'Saved':>6}  {'Hit%':>5}  Type")
    print(f"  {'─'*40} {'─'*5}  {'─'*7}  {'─'*6}  {'─'*5}  {'─'*8}")
    per_tool = stats["per_tool"]
    sorted_tools = sorted(per_tool.items(), key=lambda x: -x[1]["tokens"])
    for tool, v in sorted_tools[:15]:
        total_tool_calls = v["hits"] + v["misses"]
        tool_hit_r = (v["hits"] / total_tool_calls * 100) if total_tool_calls else 0
        is_overhead = tool in OVERHEAD_TOOLS
        type_label = yel("overhead") if is_overhead else grn("work")
        saved_str = str(v["saved"]) if v["saved"] > 0 else grn("0") if not is_overhead else red("0")
        print(f"  {tool:<40} {v['calls']:>5}  {v['tokens']:>7}  {v['saved']:>6}  {tool_hit_r:>4.0f}%  {type_label}")
    print()

    # ── Break-even analysis ────────────────────────────────────────────────
    print(bold("Break-Even Analysis (rough estimate)"))
    if total > 0:
        overhead_per_agent = ohead // max(stats["total_calls"] - stats["per_tool"].get("unknown", {}).get("calls", 0), 1)
        print(f"  Avg overhead/tool call : ~{overhead_per_agent} tokens")
        print(f"  Multi-agent worth it when actual work > ~{overhead_per_agent * 3:,} tokens per agent")
        print(f"  → MICRO tasks (< ~1,500 tokens): 1 agent trực tiếp, không dùng overhead tools")
        print(f"  → STANDARD tasks: break-even ~4,000 tokens actual work")
        print(f"  → FULL tasks: break-even ~12,000 tokens actual work")
    print()

    # ── Recommendations ────────────────────────────────────────────────────
    print(bold("Recommendations"))
    recs = []
    if hit_r < 20:
        recs.append(red("CRITICAL") + " Cache không hoạt động — debug shell-proxy MCP server")
    if g_nodes == 0:
        recs.append(red("CRITICAL") + " Graphify trống — agents phải populate graph sau mỗi task")
    if ohead_p > 60:
        recs.append(yel("HIGH") + f" Overhead {ohead_p:.0f}% quá cao — bật lazy context loading")
    if bash_w > 5000:
        recs.append(yel("HIGH") + f" Bash waste {bash_w} tokens — dùng wf_* tools thay bash reads")
    if not recs:
        recs.append(grn("OK") + " Không có vấn đề nghiêm trọng được phát hiện")
    for r in recs:
        print(f"  • {r}")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(description="flowctl token audit")
    parser.add_argument("--days",  type=int, default=None, help="Chỉ phân tích N ngày gần nhất")
    parser.add_argument("--step",  type=int, default=None, help="Lọc theo step")
    parser.add_argument("--format", choices=["table", "markdown", "json", "legacy"], default="table", help="Định dạng output")
    parser.add_argument("--limit", type=int, default=None, help="Giới hạn số task rows hiển thị")
    parser.add_argument("--json",  action="store_true", help="Deprecated: tương đương --format json")
    args = parser.parse_args()

    events  = load_events(days=args.days, step=args.step)
    session = load_session_stats()
    graph   = graphify_status()

    if not events:
        print(f"{yel('Không có events nào trong')} {EVENTS_FILE}")
        print("Chạy một số flowctl commands rồi thử lại.\n")
        return

    stats = analyze(events)
    task_rows = analyze_by_task(events, limit=args.limit)
    output_format = "json" if args.json else args.format
    if output_format == "legacy":
        print_report(stats, task_rows, session, graph, output_format="plain")
        return
    print_report(stats, task_rows, session, graph, output_format=output_format)


if __name__ == "__main__":
    main()
