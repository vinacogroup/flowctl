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

## 2. MCP Tools (4 tools thực tế)

```
query_graph(query, budget?)     — Hỏi về code structure bằng ngôn ngữ tự nhiên
get_node(node_id)               — Chi tiết một node (functions, callers, callees)
get_neighbors(node_id, depth?)  — Dependencies/dependents của node
shortest_path(source, target)   — Đường ngắn nhất giữa 2 nodes
```

Ngoài ra (nếu có trong MCP server):
```
graph_stats()      — Thống kê: nodes, edges, communities
god_nodes(limit?)  — Nodes có nhiều connections nhất (high-impact)
get_community(id)  — Xem cluster code liên quan
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

## 4. Query Patterns Theo Role

### Backend Dev (Step 4)
```
query_graph("database access patterns")
query_graph("authentication middleware")
query_graph("API request handling flow")
get_neighbors("UserService")        ← upstream callers + downstream deps
god_nodes(10)                       ← high-impact modules cần cẩn thận
```

### Frontend Dev (Step 5)
```
query_graph("component hierarchy")
query_graph("state management patterns")
query_graph("API integration layer")
get_neighbors("AuthContext")        ← components using auth
```

### Tech Lead / Integration (Steps 2, 6)
```
query_graph("service dependencies")
query_graph("external integrations")
shortest_path("UserController", "Database")   ← trace call path
graph_stats()                                 ← codebase overview
```

### QA (Step 7)
```
query_graph("API endpoints")
query_graph("error handling paths")
query_graph("authentication flow")
get_neighbors("PaymentService")     ← integration test scope
```

### DevOps (Step 8)
```
query_graph("service entry points")
query_graph("external service calls")
god_nodes(5)                        ← critical services → deploy cẩn thận
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
