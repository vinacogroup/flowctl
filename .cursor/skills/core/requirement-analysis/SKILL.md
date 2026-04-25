---
name: requirement-analysis
description: "Structured requirement gathering and analysis for PM agents. Use when collecting stakeholder requirements, writing user stories, defining acceptance criteria, MoSCoW prioritization, or producing a PRD. Trigger on any Step 1 task or when the word 'requirement', 'user story', 'PRD', 'acceptance criteria', or 'scope' appears."
triggers: ["requirement", "user-story", "PRD", "acceptance-criteria", "scope", "stakeholder", "MoSCoW"]
when-to-use: "Step 1 (Requirements Analysis), backlog grooming, scope definition, feature specification."
when-not-to-use: "Do not use for technical design, code review, or bug analysis — those have dedicated skills."
prerequisites: []
estimated-tokens: 1200
roles-suggested: ["pm"]
version: "1.0.0"
tags: ["requirements", "pm", "planning"]
---
# Skill: Requirement Analysis | PM Agent | Step 1

## 1. Quy Trình Thu Thập Requirements

### 1.1 Stakeholder Interview Framework
Thu thập theo 5 chiều:
- **Goal**: Mục tiêu kinh doanh là gì? Thành công trông như thế nào?
- **Users**: Ai sẽ dùng? Pain points hiện tại là gì?
- **Constraints**: Budget, timeline, technical limits?
- **Out-of-scope**: Cái gì chắc chắn KHÔNG làm trong version này?
- **Success metrics**: Đo thành công bằng gì? (số liệu cụ thể)

### 1.2 User Story Format
```
As a [user type],
I want to [action],
So that [benefit/value].

Acceptance Criteria:
- GIVEN [context] WHEN [action] THEN [outcome]
- GIVEN [context] WHEN [action] THEN [outcome]
```

### 1.3 MoSCoW Prioritization
| Priority | Mô tả | Tỉ lệ khuyến nghị |
|----------|-------|-------------------|
| **Must Have** | Không có = product không ship được | ~60% |
| **Should Have** | Quan trọng nhưng có workaround | ~20% |
| **Could Have** | Nice to have, cut nếu cần | ~15% |
| **Won't Have** | Explicitly out of scope v1 | ~5% |

## 2. PRD Structure (bắt buộc)
```markdown
# PRD: [Feature/Product Name]
**Version**: X.X | **Status**: Draft/Review/Approved | **Date**: YYYY-MM-DD

## Executive Summary (2-3 câu)

## Problem Statement
- Current state: ...
- Desired state: ...
- Gap: ...

## User Stories
[Danh sách theo epic]

## Acceptance Criteria
[Chi tiết per story]

## MoSCoW
[Bảng prioritization]

## Out of Scope
[Explicit list]

## Success Metrics
[Measurable KPIs]

## Dependencies & Risks
[Known blockers, assumptions]
```

## 3. Quality Checklist
Trước khi submit PRD cho approval:
- [ ] Mỗi User Story có ít nhất 2 Acceptance Criteria (GIVEN/WHEN/THEN)
- [ ] Mọi Must Have item đã được stakeholder confirm
- [ ] Out-of-scope list đã được PM và Tech Lead đồng ý
- [ ] Success metrics có số liệu cụ thể (không dùng "improve", "better")
- [ ] Tech Lead đã review feasibility của tất cả Must Have items
