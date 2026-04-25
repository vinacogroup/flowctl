---
name: architecture-decision
description: "Architecture Decision Record (ADR) writing, system design trade-off analysis, and technology selection. Use when making significant technical decisions, choosing between architectural patterns, evaluating tech stack options, or documenting design rationale. Trigger on 'architecture', 'ADR', 'design decision', 'tech stack', 'trade-off', 'system design'."
triggers: ["architecture", "ADR", "design-decision", "tech-stack", "trade-off", "system-design", "pattern"]
when-to-use: "Step 2 (System Design), any cross-cutting technical decision that will be hard to reverse."
when-not-to-use: "Do not use for day-to-day implementation choices — only significant, hard-to-reverse decisions."
prerequisites: []
estimated-tokens: 900
roles-suggested: ["tech-lead"]
version: "1.0.0"
tags: ["architecture", "tech-lead", "design"]
---
# Skill: Architecture Decision | Tech Lead | Step 2

## 1. ADR Format (Architecture Decision Record)

```markdown
# ADR-{NNN}: {Title}
**Date**: YYYY-MM-DD | **Status**: Proposed / Accepted / Deprecated / Superseded
**Deciders**: @tech-lead, @[relevant agents]

## Context
[Mô tả vấn đề cần giải quyết. Constraints hiện tại.]

## Decision
[Quyết định đã chọn — viết ngắn gọn, rõ ràng]

## Options Considered
| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| Option A | ... | ... | ✅ Chosen |
| Option B | ... | ... | ❌ |
| Option C | ... | ... | ❌ |

## Consequences
**Positive**: [Lợi ích]
**Negative**: [Trade-offs phải chấp nhận]
**Risks**: [Rủi ro cần theo dõi]

## Implementation Notes
[Hướng dẫn implement nếu cần]
```

## 2. Trade-off Analysis Framework

Đánh giá theo 6 chiều (1-5 mỗi chiều):
- **Performance**: Throughput, latency
- **Scalability**: Horizontal/vertical scale
- **Maintainability**: Ease of change, team familiarity
- **Reliability**: Fault tolerance, recovery
- **Security**: Attack surface, compliance
- **Cost**: Infrastructure, dev time, licensing

## 3. Khi Nào Cần ADR

✅ **Cần ADR** khi:
- Chọn database / message broker / cache layer
- Chọn authentication strategy
- Chọn deployment pattern (monolith vs microservices)
- API versioning strategy
- Bất kỳ quyết định nào mà rollback tốn > 1 ngày dev

❌ **Không cần ADR** khi:
- Chọn thư viện utility nhỏ
- Naming conventions
- Implementation detail có thể refactor dễ dàng

## 4. Quality Gate
- [ ] Ít nhất 2 options được so sánh
- [ ] Consequences (cả positive lẫn negative) đã được liệt kê
- [ ] PM đã acknowledge business impact
- [ ] ADR được lưu vào `docs/adr/ADR-NNN-title.md`
- [ ] Graphify node `adr:{NNN}` được update
