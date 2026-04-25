---
name: debugging
description: "Systematic bug diagnosis and root cause analysis for all agents. Use when investigating failures, tracing unexpected behavior, analyzing error logs, or writing bug reports. Trigger on 'bug', 'error', 'fail', 'crash', 'not working', 'unexpected', 'exception', 'debug', or any production incident."
triggers: ["bug", "error", "fail", "crash", "exception", "debug", "incident", "not-working", "broken"]
when-to-use: "Any step when a bug or unexpected behavior is found. Steps 4-8 most common. QA step 7 always."
when-not-to-use: "Do not use for feature development or design — this skill is purely for diagnosis."
prerequisites: []
estimated-tokens: 1100
roles-suggested: ["backend", "frontend", "tech-lead", "qa"]
version: "1.0.0"
tags: ["debugging", "quality", "all-roles"]
---
# Skill: Debugging | All Dev Roles | Steps 4-8

## 1. Scientific Debugging Protocol

**Không đoán mò. Luôn theo quy trình:**

```
1. OBSERVE    — Ghi lại chính xác symptom (error message, stack trace, behavior)
2. HYPOTHESIZE — Đặt giả thuyết nguyên nhân (ít nhất 2-3 candidates)
3. TEST        — Verify/falsify từng giả thuyết bằng evidence
4. ROOT CAUSE  — Xác định root cause (không phải symptom)
5. FIX         — Fix root cause, không phải symptom
6. VERIFY      — Reproduce original bug → confirm fixed
7. DOCUMENT    — Ghi BLOCKER:/DECISION: vào report nếu cần
```

## 2. Information Gathering

Trước khi bắt đầu debug, thu thập:
```
- Full error message + stack trace (copy exact, không paraphrase)
- Steps to reproduce (minimal reproduction case)
- Expected vs actual behavior
- Last known good state (git commit, version)
- Environment (dev/staging/prod, OS, versions)
- Recent changes (last 24h git log)
```

## 3. Common Patterns

### Backend
```bash
# Logs trước tiên
tail -f logs/app.log | grep ERROR
# Isolate với unit test
# Check DB state: query trực tiếp
# Check env vars: missing/wrong values
```

### Frontend
```
1. Check Network tab — status codes, request/response
2. Check Console — error messages
3. Isolate component — render trong isolation
4. Check state — Redux/Zustand devtools
```

### Integration / Async
```
1. Trace request ID qua toàn bộ flow
2. Check message queue depth / dead letter queue
3. Verify timeout values khớp nhau giữa services
4. Check clock drift giữa services
```

## 4. Bug Report Format

```markdown
## Bug: [Short title]
**Severity**: Critical/High/Medium/Low
**Found by**: @[role] | **Date**: YYYY-MM-DD

### Symptom
[Exact error message / behavior]

### Reproduce
1. Step 1
2. Step 2
3. → Expected: ... | Actual: ...

### Root Cause
[Specific code/config/data issue]

### Fix Applied
[What was changed, file:line]

### Verification
[How confirmed fixed]
```

## 5. Escalation Rule
- Nếu debug > 30 phút không tìm được root cause → khai báo `BLOCKER:` trong report
- Nếu bug là security vulnerability → escalate CRITICAL ngay lập tức tới @tech-lead
