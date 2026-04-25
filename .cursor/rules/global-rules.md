# Quy Tắc Toàn Cục - Global Rules
# Áp dụng cho: Tất cả agents | Version: 2.0.0 | Cập nhật: 2026-04-23

## 1. Nguyên Tắc Cơ Bản

### 1.1 Tôn Trọng Quy Trình
Mọi agent đều PHẢI tuân thủ quy trình 9 bước. Không có agent nào được:
- Bỏ qua bất kỳ bước nào trong flowctl
- Bắt đầu bước tiếp theo mà không có human approval rõ ràng
- Tự ý thay đổi scope mà không có PM approval
- Commit trực tiếp vào nhánh `main` hoặc `master`

### 1.2 Transparency & Documentation
- **Mọi quyết định phải được documented**: Không có quyết định quan trọng nào được đưa ra mà không ghi lại
- **Mọi thay đổi phải có lý do**: Khi thay đổi approach hoặc scope, phải ghi lại nguyên nhân
- **Mọi risk phải được escalate ngay**: Nếu phát hiện risk, phải report cho relevant agents trong vòng 2 giờ

### 1.3 Evidence Requirements (BẮT BUỘC)

Mọi DELIVERABLE claim trong report PHẢI có evidence xác thực:

```markdown
# Format bắt buộc trong report:
DELIVERABLE: path/to/file.ts — mô tả ngắn gọn
EVIDENCE: file_exists          ← file đã tồn tại trên disk (collect tự verify)

DELIVERABLE: API /users endpoint
EVIDENCE: test_output — 12 tests passed (0 failed)

DELIVERABLE: Design mockup
EVIDENCE: figma_url — https://figma.com/...
```

**Quy tắc:**
- Nếu DELIVERABLE là file path → collect script tự động verify file tồn tại. Nếu không có file thực → report bị flag ⚠️ UNVERIFIED.
- Nếu DELIVERABLE không phải file → PHẢI có tag `EVIDENCE:` với proof cụ thể (test output, URL, git commit hash, v.v.)
- Report thiếu EVIDENCE hoặc bị UNVERIFIED → PM **không được approve** step.
- **Không có EVIDENCE = không có done.**

### 1.3 Communication Standards
- Sử dụng structured markdown cho tất cả communications
- Tag agents khi cần input: `@pm`, `@tech-lead`, `@backend`, `@frontend`, `@ui-ux`, `@devops`, `@qa`
- Sử dụng tiếng Việt cho documentation, English cho code và technical terms
- Cấu trúc tin nhắn chuẩn:
  ```
  [AGENT_NAME] → [TARGET_AGENT/ALL]
  Ưu tiên: [CRITICAL/HIGH/MEDIUM/LOW]
  Chủ đề: [Subject]
  Nội dung: [Content]
  Hành động yêu cầu: [Required Action / None]
  Deadline: [Date or N/A]
  ```

### 1.4 Cấp Độ Ưu Tiên
| Level | Thời Gian Phản Hồi | Ví Dụ |
|-------|-------------------|-------|
| CRITICAL | < 1 giờ | Security incident, production down |
| HIGH | < 8 giờ (same day) | Blocking bug, approval needed |
| MEDIUM | < 2 ngày | Review request, non-blocking issue |
| LOW | Theo sprint schedule | Minor improvements, docs updates |

## 2. Quy Tắc Sử Dụng Graphify

> **⚠️ Lazy loading rule**: Chỉ query Graphify khi graph có data (> 10 nodes). Nếu graph trống
> hoặc sparse → bỏ qua Layer 1, đọc file trực tiếp. Dùng `flowctl audit-tokens` để kiểm tra
> trạng thái graph. Query graph rỗng = overhead thuần túy.

### 2.1 Khi Nào Phải Update Graphify
- ✅ Khi định nghĩa requirement mới hoặc cập nhật requirement
- ✅ Khi đưa ra architecture decision (ADR)
- ✅ Khi implement component/service mới
- ✅ Khi phát hiện dependency mới giữa components
- ✅ Khi một flowctl step hoàn thành
- ✅ Khi bug được confirmed với root cause rõ ràng
- ✅ Khi có risk mới được phát hiện
- ❌ KHÔNG cần update với minor code changes hoặc typo fixes

### 2.2 Node Naming Convention
```
# Services/Components
service:{name}                  # e.g., service:user-api
component:{name}                # e.g., component:UserCard

# Requirements
requirement:us-{number}         # e.g., requirement:us-001
requirement:epic-{number}       # e.g., requirement:epic-01

# Design
design:screen:{name}            # e.g., design:screen:login
design:component:{name}         # e.g., design:component:Button
design:token:{name}             # e.g., design:token:color-primary

# Infrastructure
infra:{resource-type}           # e.g., infra:database, infra:cluster

# Quality & Testing
test-case:tc-{number}           # e.g., test-case:tc-001
defect:bug-{number}             # e.g., defect:bug-042

# Architecture Decisions
adr:{number}                    # e.g., adr:001

# Workflow Progress
step:{step-name}                # e.g., step:requirements-analysis
```

### 2.3 Relationship Types (Chuẩn Hóa)
```
# Architecture relationships
--relation "calls"              # Service A gọi Service B
--relation "depends-on"         # A phụ thuộc vào B
--relation "persists-to"        # Service lưu data vào database
--relation "reads-from"         # Service đọc từ database/cache
--relation "integrates-with"    # Tích hợp với external system

# Requirements relationships
--relation "implements"         # Component thực hiện requirement
--relation "decomposed-to"      # Epic phân rã thành user stories
--relation "requested-by"       # Requirement được yêu cầu bởi stakeholder
--relation "blocked-by"         # US bị chặn bởi US khác

# Testing relationships
--relation "validates"          # Test xác nhận requirement
--relation "covers"             # Test bao phủ component/function
--relation "reported-by"        # Bug được báo cáo bởi test case

# Design relationships
--relation "designed-as"        # Requirement được thiết kế thành screen
--relation "uses"               # Screen sử dụng component
```

### 2.4 Graphify Query Patterns Chuẩn
```bash
# Load context trước khi bắt đầu step
graphify query "{domain}:*" --filter "status=active"
graphify query "{domain}:{entity}" --depth 2  # Load related nodes

# Cập nhật trạng thái
graphify update "{node-id}" --status "{status}" --updated-at "{date}"

# Tạo relationship
graphify link "{source-id}" "{target-id}" --relation "{type}"

# Snapshot sau khi hoàn thành step
graphify snapshot "{step-name}-{date}"
```

## 3. Quy Tắc Sử Dụng GitNexus

> **⚠️ Scope restriction**: GitNexus MCP tools (`gitnexus_*`) chỉ được phép dùng ở **steps 4-8**
> (code steps: Backend Dev, Frontend Dev, Integration, QA, DevOps). Steps 1-3 không có
> codebase để index — gọi GitNexus ở đây là overhead lãng phí. Agent tự động skip nếu
> `current_step < 4`.

### 3.1 Branch Strategy (Gitflow)
```
main            # Production - always deployable, protected
develop         # Integration branch - base cho tất cả feature branches
feature/*       # New features
fix/*           # Bug fixes
release/*       # Release preparation
hotfix/*        # Urgent production fixes
docs/*          # Documentation only
infra/*         # Infrastructure và DevOps changes
test/*          # Test code additions
chore/*         # Non-functional changes (deps, configs)
```

### 3.2 Conventional Commit Format
```
{type}({scope}): {description}

[optional body]

[optional footer: Breaking change, closes issue]
```

**Types chuẩn hóa:**
| Type | Mô Tả | Ví Dụ |
|------|--------|-------|
| `feat` | Tính năng mới | `feat(api): add user profile endpoint` |
| `fix` | Bug fix | `fix(auth): resolve token refresh race condition` |
| `docs` | Documentation | `docs(readme): update setup guide` |
| `style` | Formatting | `style(ui): fix button alignment` |
| `refactor` | Code restructure | `refactor(service): extract validation logic` |
| `test` | Tests | `test(api): add integration tests for auth` |
| `chore` | Build/configs | `chore(deps): update dependencies` |
| `perf` | Performance | `perf(db): optimize user query with index` |
| `ci` | CI/CD | `ci(pipeline): add security scanning stage` |
| `deploy` | Deployment | `deploy(prod): release v1.2.0` |
| `revert` | Revert commit | `revert: revert broken migration` |

**Scopes hợp lệ:** `api`, `ui`, `db`, `auth`, `infra`, `docs`, `design`, tên module cụ thể

### 3.3 PR Requirements
Mọi PR phải có:
- [ ] Title theo conventional commit format
- [ ] Description: What (cái gì thay đổi), Why (tại sao), How (cách implement), Testing (đã test gì)
- [ ] Linked issue/ticket
- [ ] Screenshots/recordings cho UI changes
- [ ] `gitnexus pr describe --auto` được chạy
- [ ] Minimum 1 reviewer (Tech Lead cho backend/frontend)
- [ ] All CI checks passing

### 3.4 Merge Strategy
| Source → Target | Strategy | Allowed By |
|----------------|---------|-----------|
| feature → develop | Squash merge | Tech Lead |
| fix → develop | Squash merge | Tech Lead |
| develop → release | Merge commit | Tech Lead |
| release → main | Merge commit | Tech Lead + PM |
| hotfix → main | Merge commit | Tech Lead + PM (emergency) |
| hotfix → develop | Merge commit | Tech Lead |

## 4. Code Quality Standards

### 4.1 Mandatory Quality Gates (Tất Cả Code Phải Pass)
```yaml
Lint:
  JavaScript/TypeScript: ESLint - 0 errors, 0 warnings
  Python: Pylint - score >= 9.0 / 10.0
  Go: golangci-lint - 0 issues
  CSS/SCSS: Stylelint - 0 errors

Type Checking:
  TypeScript: strict mode, 0 errors
  Python: mypy strict, 0 errors

Test Coverage:
  Lines: >= 80%
  Branches: >= 75%
  Functions: >= 85%

Security:
  SAST: No Critical, no High findings
  Dependencies: No Critical CVEs (CVSS >= 9.0)
  Secrets scan: 0 secrets detected

Complexity:
  Cyclomatic complexity: <= 10 per function
  File length: <= 500 lines (exceptions need review)
  Function length: <= 50 lines
```

### 4.2 Documentation Requirements
```
Public API/Function phải có:
  - Purpose description (1-2 sentences)
  - Parameters với types và descriptions
  - Return value description
  - Exceptions/errors thrown
  - Usage example (cho complex functions)

Module/File phải có:
  - Module-level docstring/comment
  - Responsibility description
  - Author (agent role)
```

### 4.3 Naming Conventions
```
Files:          kebab-case          (user-profile.service.ts)
Classes:        PascalCase          (UserProfileService)
Functions:      camelCase           (getUserById)
Variables:      camelCase           (currentUser)
Constants:      UPPER_SNAKE_CASE    (MAX_RETRY_COUNT)
DB Tables:      snake_case          (user_profiles)
DB Columns:     snake_case          (created_at)
CSS Classes:    kebab-case          (user-avatar)
Environment:    UPPER_SNAKE_CASE    (DATABASE_URL)
```

### 4.4 Error Handling Standards
```typescript
// ✅ Đúng: Specific error types với meaningful messages
throw new ValidationError(`Field 'email' is required, received: ${typeof value}`)
throw new NotFoundError(`User with id '${id}' not found in database`)
throw new ConflictError(`Username '${username}' is already taken`)

// ❌ Sai: Generic errors
throw new Error('Something went wrong')

// ❌ Sai: Silent failure (swallow errors)
try {
  await doSomething()
} catch (e) {
  // nothing here
}

// ✅ Đúng: Log và re-throw hoặc handle gracefully
try {
  await doSomething()
} catch (error) {
  logger.error('Operation failed', { error, context })
  throw new ServiceError('Operation failed', { cause: error })
}
```

## 5. Security Standards

### 5.1 Authentication & Authorization
- Tất cả API endpoints phải có authentication (trừ public endpoints explicitly marked)
- Authorization check ở service layer (không chỉ controller)
- JWT: Access token <= 15 phút, Refresh token <= 7 ngày
- Refresh tokens phải stored securely và revocable

### 5.2 Input Validation Rules
```
RULE 1: Validate ALL user inputs tại boundary (controller/API layer)
RULE 2: Sanitize ALL inputs trước database operations
RULE 3: Validate AGAIN tại service layer cho business rules
RULE 4: NEVER trust client-side validation alone
RULE 5: Whitelist validation preferred over blacklist
```

### 5.3 Secrets Management
```
FORBIDDEN: Hardcoded passwords, API keys, connection strings trong code
FORBIDDEN: Secrets trong source code, config files committed to git, logs
FORBIDDEN: Secrets trong error messages hay debug output
REQUIRED:  Tất cả secrets trong environment variables
REQUIRED:  Production secrets trong secret manager (Vault/AWS SM/GCP SM)
REQUIRED:  Khác nhau cho mỗi environment (dev, staging, prod)
REQUIRED:  Secret rotation plan được document
```

### 5.4 Data Privacy
- PII phải encrypted at rest (AES-256 minimum)
- PII KHÔNG được log (mask trước khi log: email → `u***@example.com`)
- Data retention policy phải implemented
- GDPR compliance nếu serving EU users (right to deletion, data export)

## 6. Performance Standards

### 6.1 Backend API Targets
| Percentile | Target | Action |
|-----------|--------|--------|
| p50 median | < 50ms | Monitor |
| p95 | < 200ms | Investigate nếu exceeded |
| p99 | < 500ms | Urgent fix required |
| Max | < 1000ms | Critical alert, immediate action |

### 6.2 Frontend Performance
| Metric | Target | Tool |
|--------|--------|------|
| LCP (Largest Contentful Paint) | < 2.5s | Lighthouse |
| FID/INP (Interaction to Next Paint) | < 100ms | Lighthouse |
| CLS (Cumulative Layout Shift) | < 0.1 | Lighthouse |
| TTFB (Time to First Byte) | < 600ms | Lighthouse |
| Bundle JS/route | < 250KB gzipped | Bundle Analyzer |

### 6.3 Database
- Queries > 100ms phải được analyzed và optimized
- N+1 queries KHÔNG được phép trong production code
- Pagination required cho tất cả list endpoints (default: 20, max: 100)
- Connection pooling required

## 7. Approval Gate Rules

### 7.1 Ai Có Thể Approve Từng Step
| Step | Approvers Bắt Buộc |
|------|-------------------|
| 1 - Requirements | PM + ít nhất 1 Stakeholder |
| 2 - System Design | Tech Lead + PM |
| 3 - UI/UX Design | UI/UX Designer + PM |
| 4 - Backend Dev | Tech Lead |
| 5 - Frontend Dev | Tech Lead + UI/UX |
| 6 - Integration | Tech Lead |
| 7 - QA Testing | QA Lead + PM |
| 8 - DevOps | DevOps + Tech Lead + PM |
| 9 - Release | PM + Tech Lead + Stakeholder |

### 7.2 Quy Trình Approval (Chuẩn)
1. Agent hoàn thành step deliverables
2. Agent tạo Step Summary (template: `workflows/templates/step-summary-template.md`)
3. Agent tạo Review Checklist (template: `workflows/templates/review-checklist-template.md`)
4. Agent tạo Approval Request (template: `workflows/templates/approval-request-template.md`)
5. Approvers review tất cả documents (SLA: 24 giờ)
6. Nếu có feedback: Agent address và resubmit
7. Khi approved: Ghi lại approval với timestamp, approver names
8. Update Graphify với step completion status
9. Proceed to next step

### 7.3 Blocking vs. Non-Blocking Issues
**Blocking** (phải resolve trước khi approve):
- Critical hoặc High severity bugs
- Security vulnerabilities (Critical/High)
- Performance SLA breaches
- Missing Acceptance Criteria
- Failed CI/CD checks

**Non-Blocking** (có thể carry forward với PM approval):
- Low/Medium bugs với known workaround
- Minor UX improvements
- Non-critical documentation gaps
- Technical debt (tracked as backlog items)

## 8. Risk Management

### 8.1 Phân Loại Rủi Ro
| Level | Probability | Impact | Action Required |
|-------|------------|--------|----------------|
| Critical | High | High | Xử lý ngay, escalate PM + Tech Lead |
| High | High | Medium hoặc Medium/High | Xử lý trong ngày |
| Medium | Medium | Medium | Xử lý trong sprint |
| Low | Low | Low | Ghi nhận, theo dõi |

### 8.2 Quy Trình Xử Lý Rủi Ro
1. Phát hiện → Ghi vào Graphify risk register trong vòng 2 giờ
2. Đánh giá mức độ → Xác định người chịu trách nhiệm
3. Lập kế hoạch mitigation → Review với Tech Lead/PM
4. Thực hiện mitigation → Cập nhật Graphify
5. Verify resolved → Đóng risk item

### 8.3 Security Incident Response
1. **Immediately**: Classify severity, notify Tech Lead + PM
2. **If Critical**: Stop all deployments, isolate affected systems
3. Create hotfix branch (private nếu sensitive)
4. Fix, verify, và emergency deploy nếu cần
5. Post-mortem: Document lessons learned trong 48 giờ

## 9. Escalation Protocol

### 9.1 Technical Disagreements
1. Discuss trong PR comments (24 giờ)
2. Escalate to Tech Lead nếu không resolve
3. Tech Lead quyết định (binding decision)
4. Document decision trong ADR

### 9.2 Scope Disagreements
1. Flag to PM immediately
2. PM consults stakeholders (24-48 giờ)
3. PM quyết định (binding cho scope)
4. Tech Lead assess technical impact
5. Update roadmap nếu cần

### 9.3 Quality Gate Fails
1. QA Agent documents specific failures
2. Assign bugs đến relevant dev agents
3. Dev agents fix và re-deploy to staging
4. QA re-tests (full regression nếu cần)
5. Nếu deadline conflict: PM + Tech Lead decide trên risk acceptance

## 10. Document Retention

| Loại Document | Lưu Trữ | Location |
|--------------|---------|---------|
| Step summaries | Vĩnh viễn | `docs/summaries/` |
| Review records | Vĩnh viễn | `docs/reviews/` |
| Approval records | Vĩnh viễn | `docs/approvals/` |
| ADRs | Vĩnh viễn | `docs/adr/` |
| Bug reports | Trong issue tracker | Jira/Linear |
| Performance reports | 6 tháng | `docs/performance/` |
| Security reports | Vĩnh viễn (confidential) | Secure storage |

## 11. Liên Kết Tài Nguyên

- Workflow Steps: `workflows/steps/`
- Agent Definitions: `.cursor/agents/`
- Skills: `.cursor/skills/`
- Templates: `workflows/templates/`
- Graphify Integration: `.cursor/skills/graphify-integration.md`
- GitNexus Integration: `.cursor/skills/gitnexus-integration.md`
- Review & Approval Rules: `.cursor/rules/review-rules.md`
- Workflow Rules: `.cursor/rules/flowctl-rules.md`
