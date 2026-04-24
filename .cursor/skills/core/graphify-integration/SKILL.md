---
name: graphify-integration
description: "Graphify usage patterns for architecture discovery and dependency context"
triggers: ["graphify", "architecture", "dependency", "query"]
when-to-use: "Use when you need architecture-level context and relationship mapping from Graphify."
when-not-to-use: "Do not use when task scope is strictly local and does not require graph traversal."
prerequisites: []
estimated-tokens: 4696
roles-suggested: ["tech-lead", "backend", "frontend", "devops"]
version: "1.0.0"
tags: ["graph", "architecture"]
---
# Kỹ Năng Tích Hợp Graphify
# Skill: Graphify Knowledge Graph Integration | Version: 1.0.0

## 1. Giới Thiệu Graphify

Graphify là công cụ knowledge graph được sử dụng để xây dựng và truy vấn đồ thị tri thức về dự án. Mỗi agent sử dụng Graphify để:
- **Hiểu context**: Query graph để load relevant knowledge trước khi làm việc
- **Chia sẻ knowledge**: Update graph với decisions và discoveries
- **Track relationships**: Document dependencies và connections
- **Audit trail**: Lưu trữ lịch sử quyết định

## 2. Graphify CLI Reference

### 2.1 Basic Commands

```bash
# Query commands
graphify query <node-id-or-pattern>
graphify query <pattern> --filter "key=value"
graphify query <pattern> --depth <number>  # Load N levels of related nodes
graphify query <pattern> --format "json|table|tree"

# Update commands
graphify update <node-id> --<property> "<value>"
graphify update <node-id> --status "<status>"
graphify update <node-id> --tags "<comma,separated,tags>"

# Create new node
graphify create <node-type>:<node-id> \
  --title "<title>" \
  --description "<description>" \
  --properties '{"key": "value"}'

# Relationship commands
graphify link <source-id> <target-id> --relation "<relation-type>"
graphify unlink <source-id> <target-id> --relation "<relation-type>"
graphify relations <node-id>  # List all relationships

# Snapshot commands (freeze state at a point in time)
graphify snapshot "<snapshot-name>"
graphify snapshot list
graphify snapshot load "<snapshot-name>"

# Search
graphify search "<text-query>"
graphify search "<text-query>" --type "<node-type>"
```

### 2.2 Advanced Query Syntax

```bash
# Filter by multiple properties
graphify query "requirement:*" \
  --filter "status=approved" \
  --filter "priority=must"

# Query with relationship traversal
graphify query "service:user-api" \
  --depth 2 \
  --relations "calls,depends-on"

# Query by tag
graphify query "*" --tags "security,critical"

# Aggregate queries
graphify aggregate "requirement:*" --count
graphify aggregate "defect:*" --group-by "severity"

# Export graph
graphify export "step:requirements" \
  --format "graphml|json|csv" \
  --output "requirements-graph.json"
```

## 3. Sử Dụng Graphify Theo Workflow Step

### Step 1: Requirements Analysis

```bash
# === STEP 1 START: Load context ===
graphify query "project:*" --depth 1
graphify query "stakeholder:*"
graphify query "business-objective:*"

# Tạo project node nếu chưa có
graphify create project:{name} \
  --title "{Project Name}" \
  --description "{Project description}" \
  --properties '{"start_date": "YYYY-MM-DD", "target_release": "YYYY-MM-DD"}'

# === TRONG QUÁ TRÌNH THU THẬP REQUIREMENTS ===

# Tạo stakeholder nodes
graphify create stakeholder:{name} \
  --title "{Stakeholder Name}" \
  --properties '{"role": "{role}", "department": "{dept}", "priority": "high|medium|low"}'

# Tạo business objective nodes
graphify create business-objective:{id} \
  --title "{Objective Title}" \
  --description "{What business goal this serves}" \
  --properties '{"success-metric": "{how to measure}", "priority": "must|should|could"}'

# Tạo epic nodes
graphify create requirement:epic-{n} \
  --title "{Epic Title}" \
  --description "{Epic description}"
graphify link requirement:epic-{n} business-objective:{id} --relation "supports"
graphify link requirement:epic-{n} stakeholder:{name} --relation "requested-by"

# Tạo user story nodes
graphify create requirement:us-{nn} \
  --title "{US Title}: As a {user}, I want {feature}, so that {benefit}" \
  --properties '{
    "priority": "must|should|could|wont",
    "story_points": "{estimate}",
    "acceptance_criteria": "[{ac1}, {ac2}]",
    "status": "draft"
  }'
graphify link requirement:us-{nn} requirement:epic-{n} --relation "belongs-to"
graphify link requirement:us-{nn} stakeholder:{name} --relation "requested-by"

# Track dependencies giữa user stories
graphify link requirement:us-{nn} requirement:us-{mm} --relation "blocked-by"

# === STEP 1 END: Update status và snapshot ===
graphify update step:requirements-analysis --status "completed"
graphify update project:{name} --properties '{"requirements_count": "{n}", "stories_count": "{m}"}'
graphify snapshot "requirements-baseline-v1"
```

---

### Step 2: System Design

```bash
# === STEP 2 START: Load requirements context ===
graphify query "requirement:*" --filter "status=approved"
graphify query "business-objective:*"
graphify query "project:constraints"

# === KIẾN TRÚC SYSTEM ===

# Tạo service/component nodes
graphify create service:{name} \
  --title "{Service Name}" \
  --description "{What this service does}" \
  --properties '{
    "technology": "{tech stack}",
    "responsibility": "{main responsibility}",
    "team": "{owning team}"
  }'

# Tạo database nodes
graphify create database:{name} \
  --title "{Database Name}" \
  --properties '{
    "type": "postgres|mysql|mongodb|redis",
    "purpose": "{what data it stores}",
    "ha": "true|false"
  }'

# Tạo external service nodes
graphify create external:{name} \
  --title "{External Service Name}" \
  --properties '{
    "type": "payment|email|sms|auth|storage",
    "provider": "{provider name}",
    "sla": "{uptime sla}"
  }'

# Service relationships
graphify link service:{a} service:{b} --relation "calls"
graphify link service:{name} database:{db} --relation "persists-to"
graphify link service:{name} database:{cache} --relation "reads-from"
graphify link service:{name} external:{ext} --relation "integrates-with"

# Link services đến requirements
graphify link service:{name} requirement:us-{nn} --relation "implements"

# === ARCHITECTURE DECISIONS (ADR) ===
graphify create adr:{nnn} \
  --title "ADR-{nnn}: {Decision Title}" \
  --properties '{
    "status": "accepted",
    "context": "{why decision needed}",
    "decision": "{what was decided}",
    "rationale": "{why this option}",
    "consequences": "{trade-offs}"
  }'
graphify link adr:{nnn} service:{name} --relation "affects"
graphify link adr:{nnn} database:{name} --relation "affects"

# === STEP 2 END ===
graphify update step:system-design --status "completed"
graphify snapshot "architecture-baseline-v1"
```

---

### Step 3: UI/UX Design

```bash
# === STEP 3 START ===
graphify query "requirement:us-*" --filter "component=ui"
graphify query "service:*" --filter "type=api"
graphify query "project:brand-guidelines"

# === DESIGN SYSTEM ===

# Design tokens
graphify create design:token:color-primary \
  --properties '{"value": "#2563EB", "category": "color", "usage": "primary CTAs"}'

graphify create design:token:typography-base \
  --properties '{"value": "16px/1.5 Inter", "category": "typography"}'

# Components
graphify create design:component:{Name} \
  --title "{Component Name}" \
  --properties '{
    "type": "atom|molecule|organism",
    "figma_url": "{url}",
    "states": ["default", "hover", "active", "disabled", "error"],
    "status": "draft|review|approved"
  }'

# Screens
graphify create design:screen:{name} \
  --title "{Screen Name}" \
  --properties '{
    "route": "/{path}",
    "figma_url": "{url}",
    "responsive": "mobile|tablet|desktop|all"
  }'

# Link screens đến requirements
graphify link design:screen:{name} requirement:us-{nn} --relation "implements"
graphify link design:screen:{name} design:component:{Name} --relation "uses"

# Design decisions
graphify create design-decision:{id} \
  --title "{Decision}" \
  --properties '{
    "context": "{why this design}",
    "chosen": "{chosen approach}",
    "alternatives": "{what else was considered}"
  }'

# === STEP 3 END ===
graphify update step:ui-ux-design --status "completed"
graphify snapshot "design-system-v1"
```

---

### Step 4: Backend Development

```bash
# === STEP 4 START ===
graphify query "architecture:backend"
graphify query "api:contracts"
graphify query "requirement:us-*" --filter "component=backend,status=approved"

# === API IMPLEMENTATION TRACKING ===

# Track API endpoints
graphify create api:endpoint:{method}-{path} \
  --title "{HTTP Method} {/api/v1/path}" \
  --properties '{
    "method": "GET|POST|PUT|DELETE|PATCH",
    "path": "/api/v1/{resource}",
    "auth": "required|optional|public",
    "status": "planned|in-progress|implemented|tested",
    "implemented_in": "{file:line}"
  }'
graphify link api:endpoint:{id} requirement:us-{nn} --relation "implements"
graphify link api:endpoint:{id} service:{name} --relation "belongs-to"

# Track service implementations
graphify update service:{name} \
  --properties '{"status": "implemented", "test_coverage": "{percentage}%"}'

# Track database changes
graphify create db:migration:{name} \
  --title "Migration: {description}" \
  --properties '{
    "file": "{migration-file-name}",
    "type": "create_table|add_column|add_index|...",
    "reversible": "true|false"
  }'
graphify link db:migration:{name} database:{name} --relation "modifies"

# Business rules documentation
graphify create business-rule:{id} \
  --title "{Rule Name}" \
  --description "{Rule description}" \
  --properties '{"implemented_in": "{file}:{function}", "tested_by": "test-{n}"}'

# === STEP 4 END ===
graphify update step:backend-development --status "completed"
graphify update project:{name} --properties '{"api_coverage": "{percentage}%"}'
graphify snapshot "backend-implementation-v1"
```

---

### Step 5: Frontend Development

```bash
# === STEP 5 START ===
graphify query "design:component:*" --filter "status=approved"
graphify query "api:endpoint:*" --filter "status=implemented"
graphify query "design:screen:*"

# === UI IMPLEMENTATION TRACKING ===

# Track component implementations
graphify create component:{Name} \
  --title "{Component Name}" \
  --properties '{
    "type": "ui-component",
    "status": "implemented",
    "story": "storybook:{path}",
    "tested": "true",
    "test_file": "{path-to-test}"
  }'
graphify link component:{Name} design:component:{Name} --relation "implements"

# Track page implementations
graphify create page:{name} \
  --title "{Page Name}" \
  --properties '{
    "route": "/{path}",
    "status": "implemented"
  }'
graphify link page:{name} design:screen:{name} --relation "implements"
graphify link page:{name} api:endpoint:{id} --relation "consumes"

# State management
graphify create state:slice:{name} \
  --title "{State Slice Name}" \
  --properties '{
    "managed_by": "zustand|redux|react-query|pinia",
    "shape": "{brief description of state shape}"
  }'

# === STEP 5 END ===
graphify update step:frontend-development --status "completed"
graphify snapshot "frontend-implementation-v1"
```

---

### Step 6: Integration Testing

```bash
# === STEP 6 START ===
graphify query "api:endpoint:*"
graphify query "service:*"
graphify query "component:*"

# === INTEGRATION TEST TRACKING ===

# Track integration test results
graphify create integration-test:{scenario} \
  --title "{Test Scenario Name}" \
  --properties '{
    "type": "contract|e2e|api",
    "status": "pass|fail|blocked",
    "executed_on": "{date}"
  }'
graphify link integration-test:{scenario} api:endpoint:{id} --relation "tests"

# Track integration issues
graphify create integration-issue:{id} \
  --title "{Issue Description}" \
  --properties '{
    "severity": "critical|high|medium|low",
    "status": "open|resolved",
    "root_cause": "{analysis}"
  }'
graphify link integration-issue:{id} service:{a} --relation "between"
graphify link integration-issue:{id} service:{b} --relation "between"

# === STEP 6 END ===
graphify update step:integration-testing --status "completed"
graphify snapshot "integration-verified-v1"
```

---

### Step 7: QA Testing

```bash
# === STEP 7 START ===
graphify query "requirement:us-*" --filter "status=implemented"
graphify query "api:endpoint:*"
graphify query "design:screen:*"

# === QA TEST TRACKING ===

# Create test cases
graphify create test-case:tc-{nnn} \
  --title "{Test Case Title}" \
  --properties '{
    "type": "functional|regression|performance|security|accessibility",
    "priority": "critical|high|medium|low",
    "status": "pass|fail|blocked|not-run",
    "automated": "true|false",
    "execution_date": "{date}"
  }'
graphify link test-case:tc-{nnn} requirement:us-{nn} --relation "validates"

# Track defects
graphify create defect:bug-{nnn} \
  --title "{Bug Title}" \
  --properties '{
    "severity": "critical|high|medium|low",
    "priority": "p1|p2|p3|p4",
    "status": "open|in-progress|resolved|closed|wont-fix",
    "found_in": "staging|dev",
    "reported_date": "{date}",
    "resolved_date": "{date}"
  }'
graphify link defect:bug-{nnn} test-case:tc-{nnn} --relation "found-by"
graphify link defect:bug-{nnn} requirement:us-{nn} --relation "blocks"

# Quality metrics
graphify update quality:metrics \
  --properties '{
    "test_coverage": "{percentage}%",
    "pass_rate": "{percentage}%",
    "open_critical": "{count}",
    "open_high": "{count}",
    "total_defects": "{count}",
    "resolved_defects": "{count}"
  }'

# Go/No-Go record
graphify update "quality:gate-decision" \
  --properties '{
    "decision": "go|no-go",
    "date": "{date}",
    "decided_by": "QA Lead + PM",
    "rationale": "{reason}"
  }'

# === STEP 7 END ===
graphify update step:qa-testing --status "completed"
graphify snapshot "qa-complete-v1"
```

---

### Step 8: DevOps Deployment

```bash
# === STEP 8 START ===
graphify query "architecture:infrastructure"
graphify query "service:*" --filter "status=ready-for-deployment"

# === INFRASTRUCTURE TRACKING ===

# Track infrastructure components
graphify create infra:cluster \
  --title "Kubernetes Cluster" \
  --properties '{
    "provider": "aws-eks|gke|aks",
    "region": "{region}",
    "k8s_version": "{version}",
    "node_count": "{n}"
  }'

graphify create infra:database \
  --title "Production Database" \
  --properties '{
    "type": "postgres|mysql|mongodb",
    "ha": "true",
    "backup_schedule": "daily",
    "version": "{version}"
  }'

# Track CI/CD pipeline
graphify create cicd:pipeline:main \
  --title "Main CI/CD Pipeline" \
  --properties '{
    "platform": "github-actions|gitlab-ci|jenkins",
    "stages": "lint,security,test,build,deploy-staging,deploy-production",
    "avg_duration": "{minutes}min"
  }'

# Track environments
graphify create env:staging \
  --properties '{
    "url": "https://staging.{domain}.com",
    "status": "healthy",
    "last_deployed": "{date}"
  }'

graphify create env:production \
  --properties '{
    "url": "https://{domain}.com",
    "status": "healthy",
    "deployment_strategy": "blue-green|canary|rolling",
    "last_deployed": "{date}"
  }'

# === DEPLOYMENT EVENTS ===
graphify create deployment:{version} \
  --title "Deployment v{version}" \
  --properties '{
    "version": "{semver}",
    "environment": "production",
    "strategy": "blue-green",
    "started_at": "{timestamp}",
    "completed_at": "{timestamp}",
    "status": "success|failed|rolled-back"
  }'

# === STEP 8 END ===
graphify update step:devops-deployment --status "completed"
graphify snapshot "infrastructure-production-v1"
```

---

### Step 9: Review & Release

```bash
# === STEP 9 START: Load toàn bộ project state ===
graphify query "step:*"
graphify query "quality:*"
graphify query "deployment:*"
graphify query "requirement:us-*" --filter "priority=must"

# Verify all must-have requirements implemented
graphify query "requirement:us-*" \
  --filter "priority=must,status=implemented" \
  --aggregate count

# === LESSONS LEARNED ===
graphify create lesson-learned:{id} \
  --title "{Lesson Title}" \
  --properties '{
    "category": "process|technical|communication|tooling",
    "description": "{what happened}",
    "impact": "{positive|negative}",
    "recommendation": "{what to do next time}"
  }'

# === RELEASE RECORD ===
graphify create release:v{version} \
  --title "Release v{version}" \
  --properties '{
    "version": "{semver}",
    "release_date": "{date}",
    "release_type": "major|minor|patch",
    "features": "[list of major features]",
    "bug_fixes": "[list of fixes]",
    "known_issues": "[list if any]"
  }'

# === PROJECT CLOSURE ===
graphify update project:{name} \
  --status "released" \
  --properties '{
    "completion_date": "{date}",
    "total_user_stories": "{n}",
    "implemented_stories": "{n}",
    "total_bugs_found": "{n}",
    "bugs_resolved": "{n}"
  }'

# Final snapshot
graphify update step:review-release --status "completed"
graphify snapshot "production-release-v{version}"
```

## 4. Best Practices

### 4.1 Query Trước Khi Làm
```bash
# LUÔN query context trước khi bắt đầu task
graphify query "step:{current-step}" --depth 2

# Load requirements liên quan
graphify query "requirement:*" --filter "component={your-component}"

# Check existing decisions
graphify query "adr:*" --filter "status=accepted"
```

### 4.2 Update Ngay Khi Có Decision
```bash
# ĐỪNG đợi đến cuối step để update
# Update ngay khi:
# - Một quyết định được đưa ra
# - Một dependency được phát hiện
# - Một issue được resolve
```

### 4.3 Snapshot Strategy
```bash
# Snapshot tại các milestones quan trọng:
graphify snapshot "requirements-baseline-v1"    # Sau Step 1 approval
graphify snapshot "architecture-baseline-v1"    # Sau Step 2 approval
graphify snapshot "design-system-v1"            # Sau Step 3 approval
graphify snapshot "backend-implementation-v1"   # Sau Step 4 approval
graphify snapshot "frontend-implementation-v1"  # Sau Step 5 approval
graphify snapshot "integration-verified-v1"     # Sau Step 6 approval
graphify snapshot "qa-complete-v1"              # Sau Step 7 approval
graphify snapshot "infrastructure-v1"           # Sau Step 8 approval
graphify snapshot "release-v{semver}"           # Sau Step 9 approval
```

### 4.4 Relationship Consistency
```bash
# Luôn tạo bidirectional context khi cần
# Ví dụ khi một service implements một requirement:
graphify link service:user-api requirement:us-001 --relation "implements"
# → Giờ bạn có thể query từ cả hai phía
```

## 5. Troubleshooting

### Node Không Tìm Thấy
```bash
# Search với text query
graphify search "{partial-name}" --type "{node-type}"

# List tất cả nodes của một type
graphify query "{type}:*"
```

### Graph Conflict (Hai Agents Update Cùng Node)
```bash
# Check current state
graphify query "{node-id}" --format "json"

# Apply merge resolution
graphify update "{node-id}" --merge --properties '{"resolved": "value"}'
```

### Snapshot Recovery
```bash
# List available snapshots
graphify snapshot list

# Load specific snapshot để compare
graphify snapshot load "{snapshot-name}" --compare-with "current"
```
