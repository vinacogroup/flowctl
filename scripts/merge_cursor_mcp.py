#!/usr/bin/env python3
"""
Merge flowctl MCP server definitions into .cursor/mcp.json.

- No file / empty: write template (scaffold or setup mode).
- --overwrite: replace entire mcpServers with template (other top-level keys dropped).
- Else: parse existing JSON; add only missing server keys from template; keep user servers.
- Invalid JSON: exit 2 (caller should warn and suggest --overwrite).

Prints one line to stdout: MCP_STATUS=<created|overwritten|merged|unchanged|invalid_structure>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def scaffold_template(workflow_cli: str) -> dict[str, Any]:
    return {
        "shell-proxy": {
            "command": workflow_cli,
            "args": ["mcp", "--shell-proxy"],
            "description": (
                "Token-efficient shell proxy — wf_state, wf_git, wf_step_context, "
                "wf_files, wf_read, wf_env. Replaces bash reads with structured cached JSON. "
                "Use BEFORE any bash command."
            ),
        },
        "flowctl-state": {
            "command": workflow_cli,
            "args": ["mcp", "--workflow-state"],
            "description": (
                "Workflow state tracker — flow_get_state, flow_advance_step, "
                "flow_request_approval, flow_add_blocker, flow_add_decision"
            ),
        },
    }


def setup_template() -> dict[str, Any]:
    # NOTE: Graphify does NOT have an MCP server. It is used directly via:
    #   python3 -m graphify update .   → builds graphify-out/graph.json
    #   agents read graphify-out/graph.json + GRAPH_REPORT.md directly.
    return {
        "gitnexus": {
            "command": "npx",
            "args": ["gitnexus", "--mcp", "--repo", "."],
            "env": {"GITNEXUS_AUTO_INDEX": "true"},
            "description": "Code intelligence engine — 16 MCP tools, git diff awareness",
        },
        "flowctl-state": {
            "command": "flowctl",
            "args": ["mcp", "--workflow-state"],
            "description": "Workflow state tracker — current step, approvals, blockers",
        },
        "shell-proxy": {
            "command": "flowctl",
            "args": ["mcp", "--shell-proxy"],
            "description": (
                "Token-efficient shell proxy — wf_state, wf_git, wf_step_context, "
                "wf_files, wf_read, wf_env"
            ),
        },
    }


def write_mcp(path: Path, servers: dict[str, Any], *, keep_extra_top: bool, extra_top: dict[str, Any]) -> None:
    out: dict[str, Any] = dict(extra_top) if keep_extra_top else {}
    out["mcpServers"] = servers
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=Path, help=".cursor/mcp.json path")
    ap.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace mcpServers entirely with the template for this mode.",
    )
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--scaffold", metavar="WORKFLOW_CLI", help="Minimal flowctl MCP entries")
    g.add_argument("--setup", action="store_true", help="Full setup template (graphify + gitnexus + flowctl)")
    args = ap.parse_args()

    path: Path = args.path
    template = setup_template() if args.setup else scaffold_template(args.scaffold)

    had_file = path.is_file() and path.stat().st_size > 0

    if args.overwrite:
        write_mcp(path, dict(template), keep_extra_top=False, extra_top={})
        print("MCP_STATUS=" + ("overwritten" if had_file else "created"))
        return 0

    if not had_file:
        write_mcp(path, dict(template), keep_extra_top=False, extra_top={})
        print("MCP_STATUS=created")
        return 0

    raw = path.read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(
            f".cursor/mcp.json không phải JSON hợp lệ ({e.msg} tại dòng {e.lineno}). "
            f"Sửa file hoặc chạy: flowctl init --overwrite ...",
            file=sys.stderr,
        )
        print("MCP_STATUS=invalid_json")
        return 2

    if not isinstance(data, dict):
        print("Gốc JSON phải là object {...}. Dùng --overwrite để thay thế.", file=sys.stderr)
        print("MCP_STATUS=invalid_structure")
        return 2

    extra_top = {k: v for k, v in data.items() if k != "mcpServers"}
    servers = data.get("mcpServers")

    if servers is None:
        merged = dict(template)
        write_mcp(path, merged, keep_extra_top=True, extra_top=extra_top)
        print("MCP_STATUS=merged")
        return 0

    if not isinstance(servers, dict):
        print(
            "Trường mcpServers không phải object. Sửa tay hoặc dùng flowctl init --overwrite.",
            file=sys.stderr,
        )
        print("MCP_STATUS=invalid_structure")
        return 2

    merged = dict(servers)
    added: list[str] = []
    for name, spec in template.items():
        if name not in merged:
            merged[name] = spec
            added.append(name)

    write_mcp(path, merged, keep_extra_top=True, extra_top=extra_top)
    print("MCP_STATUS=" + ("merged" if added else "unchanged"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
