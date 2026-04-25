# Quy Tắc Review và Approval
# Áp dụng cho: Tất cả agents | Version: 1.0.0 | Cập nhật: 2026-04-23

## 1. Tổng Quan Review Process

Review và approval là bắt buộc sau mỗi flowctl step. Không có step nào được bỏ qua. Mục đích:
- Đảm bảo chất lượng trước khi chuyển sang phase tiếp theo
- Cung cấp human oversight tại mỗi decision point
- Phát hiện issues sớm để giảm chi phí fix
- Tạo audit trail cho toàn bộ dự án

## 2. Các Loại Review

### 2.1 Step Review (Sau Mỗi Workflow Step)
- **Purpose**: Verify step deliverables trước khi approve để proceed
- **Reviewers**: PM + Tech Lead (và thêm tùy theo step)
- **SLA**: 24-48 giờ từ khi submit
- **Output**: Approval document với trạng thái rõ ràng

### 2.2 Code Review (Trong Mỗi Step)
- **Purpose**: Technical quality check trước khi merge
- **Reviewers**: Tech Lead (mandatory) + 1 peer reviewer
- **SLA**: 24 giờ cho PR được submit
- **Output**: PR approved hoặc changes requested

### 2.3 Design Review (Step 3, 5)
- **Purpose**: Verify design implementation fidelity
- **Reviewers**: UI/UX Agent + Frontend Dev
- **SLA**: 24 giờ
- **Output**: Design sign-off hoặc revision list

### 2.4 Security Review (Steps 2, 4, 8)
- **Purpose**: Security architecture và implementation review
- **Reviewers**: Tech Lead + DevOps
- **SLA**: 48 giờ
- **Output**: Security clearance hoặc findings list

### 2.5 UAT (User Acceptance Testing) - Step 9
- **Purpose**: Stakeholder validation trước release
- **Reviewers**: PM + Stakeholders
- **SLA**: 3-5 ngày
- **Output**: UAT sign-off hoặc rejection list

## 3. Step Review Details (Per Step)

### Step 1: Requirements Analysis Review

**Reviewers**: PM + 1 Stakeholder representative

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả user stories có Acceptance Criteria rõ ràng | Yes/No |
| User stories theo format BDD (Given/When/Then) | Yes/No |
| MoSCoW prioritization đã được stakeholder confirm | Yes/No |
| Technical feasibility đã được Tech Lead confirm | Yes/No |
| Business objectives rõ ràng và measurable | Yes/No |
| Scope được define rõ ràng (in-scope và out-of-scope) | Yes/No |
| Dependencies đã được identify | Yes/No |
| Graphify knowledge graph hoàn chỉnh | Yes/No |

**Required Artifacts**:
- [ ] Product Requirements Document (PRD) hoàn chỉnh
- [ ] User Story Map
- [ ] Priority matrix (MoSCoW)
- [ ] Stakeholder sign-off document
- [ ] Graphify snapshot: `requirements-baseline`

---

### Step 2: System Design Review

**Reviewers**: Tech Lead + PM + (optional) Security Reviewer

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Architecture diagram rõ ràng và complete | Yes/No |
| Tất cả ADRs documented với rationale | Yes/No |
| API contracts được define (OpenAPI spec) | Yes/No |
| Database schema reviewed và approved | Yes/No |
| Non-functional requirements addressed | Yes/No |
| Security architecture reviewed (threat model) | Yes/No |
| Scalability được thiết kế cho projected load | Yes/No |
| Tech stack decisions documented và justified | Yes/No |

**Required Artifacts**:
- [ ] System Architecture Document với diagrams
- [ ] Architecture Decision Records (ADRs)
- [ ] OpenAPI specification draft
- [ ] Database Entity Relationship Diagram (ERD)
- [ ] Non-functional requirements specification
- [ ] Technology stack rationale
- [ ] Graphify snapshot: `architecture-baseline`

---

### Step 3: UI/UX Design Review

**Reviewers**: UI/UX Designer + PM + Frontend Dev (feasibility)

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả screens/views được design | Yes/No |
| Design system (tokens) được define | Yes/No |
| Responsive design (mobile, tablet, desktop) | Yes/No |
| Accessibility specs included | Yes/No |
| User flows documented | Yes/No |
| Component library complete | Yes/No |
| Design tokens exportable cho dev handoff | Yes/No |
| PM confirm design meets requirements | Yes/No |

**Required Artifacts**:
- [ ] Figma file với tất cả screens và components
- [ ] Design system documentation
- [ ] Design tokens (JSON export)
- [ ] User flow diagrams
- [ ] Responsive design specs
- [ ] Accessibility annotations
- [ ] Component usage guidelines
- [ ] Graphify snapshot: `design-system-baseline`

---

### Step 4: Backend Development Review

**Reviewers**: Tech Lead (mandatory)

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả API endpoints implement và tested | Yes/No |
| OpenAPI spec updated và accurate | Yes/No |
| Test coverage >= 80% | Yes/No |
| SAST scan pass (no Critical/High) | Yes/No |
| All migrations reversible và tested | Yes/No |
| Authentication và authorization correct | Yes/No |
| Performance benchmarks met | Yes/No |
| Code review từ Tech Lead completed | Yes/No |

**Required Artifacts**:
- [ ] All feature PRs merged vào develop
- [ ] Updated OpenAPI specification
- [ ] Test coverage report (>= 80%)
- [ ] SAST scan results
- [ ] Performance benchmark results
- [ ] Database migration files
- [ ] API integration guide cho frontend
- [ ] Graphify snapshot: `backend-implementation`

---

### Step 5: Frontend Development Review

**Reviewers**: Tech Lead + UI/UX Designer

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả screens implemented | Yes/No |
| Design fidelity - pixel perfect | Yes/No |
| Responsive trên tất cả breakpoints | Yes/No |
| Accessibility audit pass (axe-core) | Yes/No |
| Core Web Vitals đạt targets | Yes/No |
| Component tests coverage >= 80% | Yes/No |
| TypeScript: 0 errors | Yes/No |
| UI/UX sign-off đã nhận | Yes/No |

**Required Artifacts**:
- [ ] All feature PRs merged
- [ ] Component test coverage report
- [ ] Lighthouse scores (>= 90)
- [ ] Accessibility audit report
- [ ] Cross-browser test results
- [ ] Storybook stories cho tất cả components
- [ ] UI/UX design review sign-off
- [ ] Graphify snapshot: `frontend-implementation`

---

### Step 6: Integration Testing Review

**Reviewers**: Tech Lead

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả integration points tested | Yes/No |
| API contracts verified (contract tests) | Yes/No |
| End-to-end happy paths working | Yes/No |
| Error handling tested (network, timeout, API errors) | Yes/No |
| Performance integrated test pass | Yes/No |
| Data flow verified end-to-end | Yes/No |
| Third-party integrations verified | Yes/No |

**Required Artifacts**:
- [ ] Integration test results report
- [ ] Contract test results
- [ ] E2E test results (happy paths)
- [ ] Error scenario test results
- [ ] Performance test results
- [ ] Integration issues log và resolutions
- [ ] Graphify snapshot: `integration-verified`

---

### Step 7: QA Testing Review

**Reviewers**: QA Lead + PM

**Review Criteria (Quality Gate)**:
| Criterion | Threshold | Actual |
|-----------|-----------|--------|
| Test case execution rate | >= 98% | {actual} |
| Test pass rate | >= 95% | {actual} |
| Open Critical bugs | = 0 | {actual} |
| Open High bugs | = 0 | {actual} |
| Security scan (DAST) | Clean | {actual} |
| Performance p95 | < 500ms | {actual} |
| Accessibility (axe) | 0 critical | {actual} |

**Required Artifacts**:
- [ ] Test execution report
- [ ] Bug report với traceability matrix
- [ ] Performance test report (k6/JMeter)
- [ ] Security scan report (OWASP ZAP)
- [ ] Accessibility audit report
- [ ] Go/No-Go recommendation document
- [ ] Graphify snapshot: `qa-complete`

---

### Step 8: DevOps Deployment Review

**Reviewers**: DevOps + Tech Lead + PM

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| All environments provisioned và healthy | Yes/No |
| CI/CD pipeline tất cả stages pass | Yes/No |
| Staging deployment stable >= 24 giờ | Yes/No |
| Monitoring và alerting configured | Yes/No |
| Rollback procedure tested | Yes/No |
| Security scan (Trivy, SAST) pass | Yes/No |
| SSL/TLS certificates valid | Yes/No |
| Database backups verified | Yes/No |

**Required Artifacts**:
- [ ] Infrastructure architecture document
- [ ] CI/CD pipeline documentation
- [ ] Deployment runbook
- [ ] Monitoring dashboard URLs
- [ ] Security scan reports
- [ ] Rollback test evidence
- [ ] Performance test on staging
- [ ] Graphify snapshot: `infrastructure-production`

---

### Step 9: Release Review (Final Approval)

**Reviewers**: PM + Tech Lead + Stakeholder

**Review Criteria**:
| Criterion | Check |
|-----------|-------|
| Tất cả Acceptance Criteria met | Yes/No |
| QA Go/No-Go: GO | Yes/No |
| UAT sign-off từ stakeholders | Yes/No |
| Release notes approved | Yes/No |
| Production deployment successful | Yes/No |
| Post-release monitoring in place | Yes/No |
| Rollback plan ready nếu cần | Yes/No |

**Required Artifacts**:
- [ ] Release notes (user-facing và technical)
- [ ] UAT sign-off document
- [ ] Final QA report
- [ ] Production deployment evidence
- [ ] Post-release monitoring plan
- [ ] Known issues và workarounds (nếu có)
- [ ] Lessons learned document
- [ ] Graphify snapshot: `production-release-v{version}`

## 4. Code Review Process Chi Tiết

### 4.1 Tech Lead Code Review Checklist
Khi review mọi PR, Tech Lead kiểm tra:

**Architecture & Design** (Critical)
- [ ] Code tuân thủ agreed architecture
- [ ] SOLID principles được áp dụng
- [ ] Không có circular dependencies
- [ ] Proper separation of concerns
- [ ] Không có premature optimization

**Code Quality** (High)
- [ ] Functions single responsibility
- [ ] DRY - không duplicate logic
- [ ] Clear naming conventions
- [ ] Adequate error handling
- [ ] Proper logging (không log PII)

**Security** (Critical - Must Pass)
- [ ] Input validation đầy đủ
- [ ] Auth/authz correct
- [ ] No SQL injection risk
- [ ] No XSS risk
- [ ] No sensitive data exposure

**Performance** (High)
- [ ] No N+1 queries
- [ ] Appropriate caching
- [ ] No blocking operations

**Testing** (High - Must Pass)
- [ ] Unit tests present cho business logic
- [ ] Coverage >= 80%
- [ ] Edge cases covered

**Documentation** (Medium)
- [ ] Public APIs documented
- [ ] Complex logic has comments
- [ ] README/ADR updated nếu needed

### 4.2 Code Review Response Times
| PR Size | SLA |
|---------|-----|
| Small (< 100 lines) | 4 giờ |
| Medium (100-300 lines) | 8 giờ (same day) |
| Large (300-500 lines) | 24 giờ |
| Very large (> 500 lines) | Split required |

### 4.3 Review Comment Levels
| Prefix | Ý Nghĩa | Must Fix? |
|--------|---------|----------|
| `[BLOCKER]` | Must fix trước khi merge | Yes |
| `[IMPORTANT]` | Strong suggestion, thảo luận nếu không fix | Discuss |
| `[SUGGESTION]` | Nice to have, có thể defer | No |
| `[QUESTION]` | Cần giải thích | Answer required |
| `[NITPICK]` | Minor style issue | Optional |
| `[PRAISE]` | Positive feedback | No action |

### 4.4 PR Merge Checklist
Trước khi merge bất kỳ PR nào:
- [ ] Tech Lead đã approve
- [ ] All CI checks passing (lint, tests, security, build)
- [ ] All BLOCKER và IMPORTANT comments resolved
- [ ] No merge conflicts
- [ ] PR description complete
- [ ] GitNexus PR description generated

## 5. Approval Document Requirements

### 5.1 Approval Document Format
```markdown
# Approval Record: Step {N} - {Step Name}

**Approval Date**: {YYYY-MM-DD HH:MM}
**Submitted by**: {Lead Agent}
**Review Started**: {YYYY-MM-DD}
**Review Completed**: {YYYY-MM-DD}

## Decision

**Status**: APPROVED / APPROVED WITH CONDITIONS / REJECTED / DEFERRED

## Approvers

| Approver | Role | Decision | Date | Signature/Initials |
|----------|------|----------|------|-------------------|
| {Name} | PM | APPROVED | {date} | {initials} |
| {Name} | Tech Lead | APPROVED | {date} | {initials} |
| {Name} | Stakeholder | APPROVED | {date} | {initials} |

## Review Summary

### Strengths
- {What was done well}

### Concerns Raised
- {Concern 1}: {Resolution}
- {Concern 2}: {Resolution}

## Conditions (nếu APPROVED WITH CONDITIONS)

Phải hoàn thành trong {N} ngày:
1. {Condition 1} - Owner: {Agent} - Due: {date}
2. {Condition 2} - Owner: {Agent} - Due: {date}

## Rejection Reasons (nếu REJECTED)

1. {Reason 1} - Must fix: {what is required}
2. {Reason 2} - Must fix: {what is required}

**Re-submission deadline**: {date}

## Authorization to Proceed

[ ] AUTHORIZED to proceed to Step {N+1}
[ ] NOT authorized - see rejection reasons

**Final Decision by**: {PM Name}
**Date**: {YYYY-MM-DD}
```

## 6. Audit Trail

### 6.1 Phải Lưu Trữ Vĩnh Viễn
- Tất cả approval documents
- Tất cả rejection documents với reasons
- Tất cả code review records (PR history)
- ADR documents
- Security review findings và resolutions

### 6.2 Location
```
docs/
  approvals/
    step-01-requirements-approval-{date}.md
    step-02-design-approval-{date}.md
    ...
  reviews/
    code-reviews/     # PR review records
    security/         # Security review findings
    design/           # Design review records
  adr/
    ADR-001-{title}.md
    ADR-002-{title}.md
```

### 6.3 Approval Records
```bash
# Record approval qua flowctl
flowctl approve --by "{approver}" --notes "{conditions if any}"

# Approval tự động ghi vào flowctl-state.json với timestamp + approver
# Xem: flowctl status → hiển thị approval history
```

## 7. Special Review Scenarios

### 7.1 Emergency/Expedited Review
Khi cần review nhanh (production issue, deadline risk):
- PM phải declare "Expedited Review"
- Minimum 1 approver từ required list (không phải tất cả)
- Remaining approvers ratify trong 24 giờ
- Document lý do expedited
- Regular review cycle phải được followed retroactively

### 7.2 Concurrent Steps Review
Khi Steps 4 và 5 chạy parallel:
- Mỗi step có independent review
- Integration review (Step 6) serve as combined review
- Tech Lead phải monitor cả hai streams

### 7.3 Re-review After Rejection
- Chỉ review những phần đã thay đổi (không full review)
- Lead agent phải attach "Changes Made" document
- Original reviewer nên perform re-review (continuity)
- SLA: 12 giờ cho re-review (nhanh hơn initial)

## 8. Metrics cho Review Process

Track trong step summary document (`workflows/steps/NN-*/summary.md`):
```markdown
## Review Metrics
- Review time: {hours}
- Rejection reason: {if applicable}
- Conditions: {list}
```

Target metrics:
- Average review time: < 24 giờ
- Rejection rate: < 20% (cao hơn nghĩa là quality issue trước review)
- Re-submission success rate: > 90%

## 9. Liên Kết

- Global Rules: `.cursor/rules/global-rules.md`
- Workflow Rules: `.cursor/rules/flowctl-rules.md`
- Step Summary Template: `workflows/templates/step-summary-template.md`
- Review Checklist Template: `workflows/templates/review-checklist-template.md`
- Approval Request Template: `workflows/templates/approval-request-template.md`
