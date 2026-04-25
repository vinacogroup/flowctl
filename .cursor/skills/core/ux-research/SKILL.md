---
name: ux-research
description: "UX research methods, user interview frameworks, usability testing, and design validation. Use when conducting user research, analyzing user behavior, creating personas, defining user flows, running usability tests, or validating design decisions with data. Trigger on 'UX', 'user research', 'persona', 'user flow', 'usability', 'design validation', 'UI/UX'."
triggers: ["ux", "user-research", "persona", "user-flow", "usability", "design-validation", "wireframe", "prototype"]
when-to-use: "Step 3 (UI/UX Design). Also Step 1 for user discovery, Step 7 for usability testing."
when-not-to-use: "Do not use for backend API design or infrastructure decisions."
prerequisites: []
estimated-tokens: 1000
roles-suggested: ["ui-ux"]
version: "1.0.0"
tags: ["ux", "design", "research"]
---
# Skill: UX Research | UI/UX Agent | Step 3

## 1. Research Methods by Phase

| Phase | Method | Time | Output |
|-------|--------|------|--------|
| Discovery | Stakeholder interview | 30min | Pain points list |
| Discovery | Competitor analysis | 2h | Feature matrix |
| Definition | User persona | 1h | Persona doc |
| Definition | User journey map | 2h | Journey diagram |
| Design | Wireframe | 2-4h | Lo-fi mockups |
| Validation | Usability test | 1h/user | Issue list |

## 2. Persona Template

```markdown
## Persona: [Name]
**Role**: [Job title / user type]
**Age**: X | **Tech comfort**: Low/Medium/High

### Goals
- [Primary goal]
- [Secondary goal]

### Pain Points
- [Pain 1]
- [Pain 2]

### Behaviors
- Uses [device/platform] for [task]
- Prefers [interaction style]

### Quote
"[Representative quote capturing their perspective]"
```

## 3. User Flow Format

```
[Entry point] → [Step 1] → [Decision?]
                              ├─ Yes → [Step 2a] → [Goal achieved ✓]
                              └─ No  → [Step 2b] → [Error state ✗]
                                           └─ [Recovery path]
```

Mỗi flow phải có: happy path + error states + edge cases.

## 4. Design Review Checklist

Trước khi submit design cho approval:
- [ ] Mỗi user story có wireframe/mockup tương ứng
- [ ] Mobile và desktop breakpoints đã được design
- [ ] Error states đã được design (không chỉ happy path)
- [ ] Empty states đã được design
- [ ] Loading states đã được design
- [ ] Accessibility: contrast ratio ≥ 4.5:1 (WCAG AA)
- [ ] Design tokens (màu, font, spacing) sử dụng nhất quán
- [ ] Handoff notes cho frontend đầy đủ (dimensions, assets, interactions)

## 5. Usability Test Script

```markdown
### Pre-test
"Tôi không test bạn — tôi test sản phẩm. Không có câu trả lời đúng/sai.
 Vui lòng nói to những gì bạn đang nghĩ khi thao tác."

### Tasks (3-5 tasks, 5-10 min/task)
Task 1: "Bạn muốn [thực hiện hành động X]. Hãy thử làm điều đó."
→ Observe: Clicks, hesitations, errors, verbalizations

### Metrics
- Task completion rate
- Time on task
- Error rate
- Satisfaction score (1-5)
```
