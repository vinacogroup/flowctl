---
name: graphify-integration
description: "Graphify code structure graph — query_graph, get_node, get_neighbors, shortest_path. Steps 4-8 only."
triggers: ["graphify", "query_graph", "code structure", "dependency graph"]
when-to-use: "Use when you need to understand code structure, call graphs, or module dependencies (steps 4-8)."
when-not-to-use: "Do NOT use for requirements, decisions, blockers, or step outcomes — use wf_step_context() instead."
prerequisites: ["graphify-out/graph.json must exist (run: python3 -m graphify update .)"]
estimated-tokens: 800
roles-suggested: ["tech-lead", "backend", "frontend", "devops", "qa"]
version: "2.0.0"
tags: ["graph", "code-structure"]
---
# Graphify Code Structure Graph
# Skill: Graphify Integration | Version: 2.0.0

## ⚠️ Quan Trọng: Graphify là Code Graph, KHÔNG phải Workflow Graph

Graphify tự động extract code structure từ source code.
- ✅ **Chứa**: functions, classes, modules, imports, call relationships
- ❌ **KHÔNG chứa**: requirements, decisions, blockers, step outcomes, project data
- ❌ **KHÔNG có write API**: `graphify_update_node`, `graphify_snapshot` không tồn tại

Để load workflow context → dùng **`wf_step_context()`** thay thế.

---

## 1. Khi Nào Dùng Graphify

Chỉ dùng ở **steps 4-8** (Backend, Frontend, Integration, QA, DevOps) khi cần:
- Hiểu codebase structure trước khi implement
- Tìm dependencies của một module/service
- Trace call flows giữa các components
- Xác định high-impact code (god nodes) trước khi refactor

---

## 2. Cách Dùng — Direct File Access (KHÔNG có MCP server)

Graphify **không** có MCP server. Đọc output files trực tiếp:

```bash
# Build graph (một lần sau khi clone / khi code thay đổi lớn)
python3 -m graphify update .

# Files output:
#   graphify-out/graph.json       ← full graph: nodes, edges, clusters, call_graph
#   graphify-out/GRAPH_REPORT.md  ← human-readable overview
```

**Đọc overview trước:**
```bash
cat graphify-out/GRAPH_REPORT.md   # clusters, top nodes, stats
```

**Đọc graph data khi cần chi tiết:**
```python
import json
graph = json.load(open("graphify-out/graph.json"))
# graph["nodes"]   — dict of id → {name, type, file, line, ...}
# graph["edges"]   — list of {source, target, type}
# graph["clusters"] — list of related-code groups
```

---

## 3. Workflow Trước Khi Query

```
1. Kiểm tra graph tồn tại: ls graphify-out/graph.json
2. Đọc overview: graphify-out/GRAPH_REPORT.md
3. Query cụ thể bằng ngôn ngữ tự nhiên
```

Nếu `graph.json` chưa có: `python3 -m graphify update .`

---

## 4. Patterns Đọc Graph Theo Role

### Backend Dev (Step 4)
```python
import json
g = json.load(open("graphify-out/graph.json"))
# Tìm nodes liên quan đến database/auth
db_nodes = [n for n in g["nodes"].values() if "db" in n["name"].lower() or "repo" in n["name"].lower()]
# Tìm edges gọi đến UserService
user_callers = [e for e in g["edges"] if e["target"] == "UserService"]
```

### Tất cả roles
```bash
# Bước 1 — luôn đọc overview trước
cat graphify-out/GRAPH_REPORT.md

# Bước 2 — tìm nodes theo tên/file
python3 -c "
import json
g = json.load(open('graphify-out/graph.json'))
keyword = 'auth'  # thay bằng keyword cần tìm
hits = [n for n in g.get('nodes', {}).values() if keyword in n.get('name','').lower()]
for h in hits[:10]: print(h.get('name'), '—', h.get('file',''))
"

# Bước 3 — xem cluster (nhóm code liên quan)
python3 -c "
import json
g = json.load(open('graphify-out/graph.json'))
for c in g.get('clusters', [])[:5]: print(c)
"
```

---

## 5. Lazy Loading Rule

Chỉ dùng Graphify khi graph có data:
```bash
# Check trước khi query
ls graphify-out/graph.json 2>/dev/null && echo "Graph available" || echo "Run: python3 -m graphify update ."
```

Graph rỗng hoặc stale → đọc code trực tiếp, không query graph.

---

## 6. Rebuild Graph

```bash
# Từ project root
python3 -m graphify update .

# Output: graphify-out/graph.json
# Overview: graphify-out/GRAPH_REPORT.md
```

Git hook tự động rebuild khi commit (nếu đã cài `python3 -m graphify hook install`).
