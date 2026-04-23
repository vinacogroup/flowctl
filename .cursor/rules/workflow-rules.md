# Quy Tắc Workflow - IT Product Development
# Áp dụng cho: Tất cả agents | Version: 2.0.0 | Cập nhật: 2026-04-23

## 1. Tổng Quan Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│          IT PRODUCT DEVELOPMENT WORKFLOW - 9 STEPS              │
├──────────────────────────────────────┬──────────────────────────┤
│ Step 1: Requirements Analysis        │ PM (primary)             │
│         ↓ [APPROVAL GATE]            │ Tech Lead (secondary)    │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 2: System Design                │ Tech Lead (primary)      │
│         ↓ [APPROVAL GATE]            │ Backend Dev, PM          │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 3: UI/UX Design                 │ UI/UX (primary)          │
│         ↓ [APPROVAL GATE]            │ Frontend Dev, PM         │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 4: Backend Development          │ Backend Dev (primary)    │
│         ↓ [APPROVAL GATE]            │ Tech Lead (reviewer)     │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 5: Frontend Development         │ Frontend Dev (primary)   │
│         ↓ [APPROVAL GATE]            │ UI/UX (reviewer)         │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 6: Integration Testing          │ Tech Lead (primary)      │
│         ↓ [APPROVAL GATE]            │ Backend + Frontend       │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 7: QA Testing                   │ QA (primary)             │
│         ↓ [APPROVAL GATE]            │ All Developers           │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 8: DevOps & Deployment          │ DevOps (primary)         │
│         ↓ [APPROVAL GATE]            │ Tech Lead, PM            │
├──────────────────────────────────────┼──────────────────────────┤
│ Step 9: Review & Release             │ PM + Tech Lead (primary) │
│         ↓ [FINAL APPROVAL]           │ All agents               │
└──────────────────────────────────────┴──────────────────────────┘
```

## 2. Quy Tắc Bắt Đầu Step (Entry Rules)

### 2.1 Điều Kiện Bắt Đầu (Entry Criteria)
Trước khi bắt đầu bất kỳ step nào, lead agent PHẢI verify:
- [ ] Step trước đã được APPROVED với approval document hợp lệ (trừ Step 1)
- [ ] Tất cả blockers từ step trước đã được resolve hoặc formally accepted
- [ ] Graphify đã cập nhật với trạng thái step trước
- [ ] Tất cả artifacts từ step trước đã được commit vào git
- [ ] Các agents cần thiết cho step mới đã được notify

### 2.2 Quy Trình Khởi Động Step (Kickoff Protocol)
```
1. Lead agent verify entry criteria
2. Query Graphify để load context từ các steps trước
   → graphify query "step:{previous-step}" --include-children
3. Query GitNexus để hiểu trạng thái codebase
   → gitnexus status --branch develop
4. Tạo branch mới theo convention
   → gitnexus branch create "{type}/{step-name}-{description}"
5. Tạo Step Kickoff Document (format bên dưới)
6. Notify tất cả agents liên quan
7. Bắt đầu thực hiện step
```

### 2.3 Step Kickoff Document Format
```markdown
# Step {N}: {Step Name} - Kickoff

**Ngày bắt đầu**: {YYYY-MM-DD}
**Lead Agent**: {Agent Name}
**Support Agents**: {Agent Names}
**Estimated Duration**: {X days}
**Previous Step Approval**: [{Link to approval doc}]

## Mục Tiêu Bước Này
{Danh sách objectives cụ thể}

## Context Từ Graphify
{Key insights loaded từ knowledge graph}

## GitNexus Branch
{Branch name và strategy}

## Kế Hoạch Thực Hiện
{Chi tiết plan với milestones}

## Dependencies
{Những gì cần từ step trước, và những gì cung cấp cho step sau}

## Risks Đã Biết
{Rủi ro đã được identify}
```

## 3. Quy Tắc Thực Hiện Step (Execution Rules)

### 3.1 Progress Tracking (Daily)
Mỗi ngày trước 17:00, lead agent cập nhật progress:
```markdown
## Daily Update - {YYYY-MM-DD}
- **Hoàn thành hôm nay**: {list}
- **Đang làm**: {list}
- **Blockers**: {list hoặc "Không có"}
- **Kế hoạch ngày mai**: {list}
- **Completion estimate**: {X%}
```

### 3.2 Decision Logging
Mọi quyết định quan trọng PHẢI được ghi lại ngay khi đưa ra:
```markdown
## Decision Record - DR-{YYYYMMDD}-{NNN}

**Ngày**: {YYYY-MM-DD}
**Người quyết định**: {Agent} [{Human Approval: Yes/No}]
**Vấn đề**: {Problem statement}

**Các lựa chọn đã xem xét**:
1. **Option A**: {description} - Pros: {pros} | Cons: {cons}
2. **Option B**: {description} - Pros: {pros} | Cons: {cons}

**Quyết định chọn**: {Chosen option}
**Lý do**: {Rationale}
**Tác động**: {Impact on other steps/components}

**Graphify update**:
  graphify update "decision:{id}" --status "accepted"
```

### 3.3 Blocker Management
Khi gặp blocker:
1. **Ngay lập tức**: Ghi vào step document với severity
2. **Trong 1 giờ**: Notify lead agent và Tech Lead (CRITICAL) hoặc Team (HIGH)
3. **Nếu blocker > 4 giờ**: Escalate lên PM
4. **Luôn luôn**: Tìm workaround tạm thời nếu có thể
5. **Update timeline**: Cập nhật estimated completion nếu bị ảnh hưởng

### 3.4 Scope Management
| Quy Mô Thay Đổi | Effort | Người Approve |
|----------------|--------|--------------|
| Minor fix | < 2 giờ | Tech Lead |
| Moderate change | 2-8 giờ | PM + Tech Lead |
| Major scope change | > 8 giờ | Formal Change Request → PM + Stakeholders |

**Quy trình Change Request:**
```markdown
## Change Request - CR-{NNN}

**Ngày yêu cầu**: {date}
**Requested by**: {Agent}
**Step bị ảnh hưởng**: Step {N} - {Name}

**Mô tả thay đổi**: {description}

**Lý do thay đổi**: {reason}

**Impact Analysis**:
- Timeline: +{N} ngày
- Effort: +{N} giờ
- Cost: {estimated impact}
- Other steps affected: {list}

**Alternatives nếu không thay đổi**: {what happens if rejected}

**Quyết định**: [ ] Approved [ ] Rejected [ ] Modified
**Người quyết định**: {PM/Stakeholder}
**Ngày quyết định**: {date}
```

## 4. Quy Tắc Kết Thúc Step (Completion Rules)

### 4.1 Definition of Done (DoD Toàn Cục)
Áp dụng cho mọi step trước khi request approval:
- [ ] Tất cả deliverables của step đã được hoàn thành
- [ ] Tất cả tests liên quan đã pass
- [ ] Tất cả documentation đã được cập nhật
- [ ] Graphify đã được cập nhật với step completion
- [ ] GitNexus đã commit tất cả changes với proper messages
- [ ] Step Summary document đã được tạo
- [ ] Review Checklist đã được điền đầy đủ
- [ ] Approval Request đã được chuẩn bị

### 4.2 Step Summary Requirements
Step Summary PHẢI bao gồm các sections sau (xem template chi tiết):
1. **Executive Summary**: 5-10 câu cho PM và stakeholders (không kỹ thuật)
2. **Technical Summary**: Chi tiết kỹ thuật cho Tech Lead và developers
3. **Deliverables Hoàn Thành**: Danh sách với links/locations
4. **Metrics Đạt Được**: KPIs, coverage %, performance numbers
5. **Issues Gặp Phải & Giải Pháp**: Problems và cách resolve
6. **Risks Mới Phát Hiện**: Risk register update
7. **Dependencies cho Step Tiếp Theo**: Gì cần chuẩn bị
8. **Lessons Learned**: Bài học cho future steps
9. **Graphify Knowledge Graph Update**: Những gì đã add vào graph
10. **GitNexus Activity**: Commits, PRs, branches trong step này

### 4.3 Handoff Protocol (Chuyển Giao Bước)
Khi chuyển từ step N sang step N+1:
1. Lead agent của step N tạo handoff briefing document
2. Brief lead agent của step N+1 (1-on-1 hoặc team sync)
3. Briefing cover: decisions made, known issues, dependencies, gotchas
4. Tất cả artifacts phải accessible (links trong handoff doc)
5. Graphify context được verify đã sync
6. Overlap period 1-2 ngày nếu cần (cả hai agents cùng làm việc)
7. Lead agent step N available cho questions trong 3 ngày sau

## 5. Approval Gate Process

### 5.1 Quy Trình Approval Chuẩn
```
Step Completion
      │
      ▼
[Lead Agent] Tạo 3 documents:
  1. Step Summary
  2. Review Checklist
  3. Approval Request
      │
      ▼
[Approvers] Review (SLA: 24 giờ cho các steps thông thường,
                         48 giờ cho Step 1, 9)
      │
      ├── APPROVED ──────────────► Ghi lại approval → Proceed
      │
      ├── APPROVED WITH          ► Fix specific issues trong 48h
      │   CONDITIONS               → Auto-approve sau khi fix verified
      │
      ├── REJECTED ──────────────► Address concerns → Re-submit
      │
      └── DEFERRED ──────────────► Cần thêm info → Return trong 24h
```

### 5.2 Approval Statuses
| Status | Ý Nghĩa | Hành Động Tiếp Theo |
|--------|---------|-------------------|
| **APPROVED** | Đủ điều kiện tiến sang step tiếp theo | Proceed ngay |
| **APPROVED WITH CONDITIONS** | Proceed nhưng phải fix issues trong 48h | Proceed + track conditions |
| **REJECTED** | Phải address tất cả concerns | Fix → Re-submit |
| **DEFERRED** | Cần thêm thông tin | Cung cấp info → Return trong 24h |

### 5.3 Approval Timeout & Escalation
- 24 giờ không có response → Reminder notification
- 48 giờ không có response → Automatic escalation lên cấp trên
- 72 giờ không có response → PM quyết định unilaterally

### 5.4 Emergency Approval
Khi có urgency hợp lý:
- Minimum: 1 approver từ required list
- Phải ghi lý do emergency
- Remaining approvers phải ratify trong 24 giờ
- Documented trong approval record

## 6. Parallel Execution Rules

### 6.1 Các Phases Có Thể Chạy Song Song
| Parallel Streams | Điều Kiện |
|-----------------|----------|
| Step 2 (Design) + Step 3 (UI/UX) | API contracts defined trước |
| Step 4 (Backend) + Step 5 (Frontend) | OpenAPI spec finalized và approved |
| QA test prep (Step 7) + Step 6 Integration | Tech Lead approval required |

### 6.2 Điều Kiện Cho Parallel Execution
- Explicit approval từ PM + Tech Lead
- Clear interface contracts giữa parallel workstreams (API spec, design spec)
- Integration checkpoints lên lịch (ít nhất 2x/tuần)
- Conflict resolution protocol: Tech Lead final say
- Graphify track tất cả cross-stream dependencies

### 6.3 Integration Checkpoints
Trong parallel execution, schedule:
```
Day 1 of parallel start: Align on interface contracts
Mid-point: Integration smoke test
3 days before convergence: Full integration test
1 day before convergence: Go/No-go decision
```

## 7. Metrics và Monitoring

### 7.1 Step-level Metrics (Track trong Graphify)
```
graphify update "step:{name}:metrics" \
  --planned-effort "{hours}" \
  --actual-effort "{hours}" \
  --completion "{percentage}" \
  --defects-found "{count}" \
  --scope-changes "{count}"
```

### 7.2 Workflow Health Indicators
Cập nhật hàng ngày trong Graphify:
```
Overall Progress:   {N}/9 steps complete
Current Step:       Step {N} - {Name} - {Status}
Open Blockers:      {count}
At-Risk Items:      {count}
Days to Target:     {N}
Quality Gate:       Pass/Fail
Timeline Status:    On track / {N} days delayed
```

### 7.3 Step Retrospective (Sau Mỗi Step)
Format: Quick async retrospective (15 phút hoặc async document)
```markdown
## Step {N} Retrospective

### Went Well ✅
1. {Item}
2. {Item}
3. {Item}

### Needs Improvement ⚠️
1. {Item}
2. {Item}

### Action Items 🎯
| Action | Owner | Due Date |
|--------|-------|----------|
| {action} | {agent} | {date} |
```

## 8. Emergency Procedures

### 8.1 Production Hotfix Trong Khi Workflow Đang Chạy
1. PM quyết định suspend workflow hay không (trong 1 giờ)
2. Tạo `hotfix/{issue}-{description}` branch từ `main`
3. Team hotfix: DevOps + Tech Lead + relevant Backend/Frontend Dev
4. QA sign-off required trước khi deploy (expedited, 2-4 giờ)
5. Merge hotfix vào cả `main` và `develop`/workflow branch
6. Resume workflow sau khi hotfix stable

### 8.2 Workflow Rollback (Về Step Trước)
1. PM PHẢI approve workflow reset (formal decision)
2. Document lý do rollback trong detail
3. Update Graphify: `graphify update "workflow" --rollback-to "step:{N}"`
4. GitNexus: Xác định commits nào cần revert
5. Notify toàn bộ team với impact assessment
6. Re-plan affected steps với updated timeline

### 8.3 Scope Freeze Protocol
Khi vào giai đoạn cuối (Step 7 trở đi):
- **Scope Freeze declared**: PM announces, documented
- **Chỉ accepted**: Critical bug fixes (P1, P2)
- **Rejected**: New feature requests → Backlog for next iteration
- **Rejected**: Non-critical enhancements → Backlog
- **PM có quyền veto** tất cả scope changes không exception

## 9. Step-specific Rules

### Step 1 - Requirements Analysis
- Không được bắt đầu design hoặc code cho đến khi requirements approved
- User Stories phải có Acceptance Criteria dạng BDD (Given/When/Then)
- Tất cả requirements phải được link đến business objective trong Graphify

### Step 2 - System Design
- Architecture phải review performance và scalability với projected load
- Security architecture review bắt buộc (threat modeling)
- Database schema phải được approved trước khi Step 4 bắt đầu

### Step 3 - UI/UX Design
- Tất cả designs phải accessible (WCAG 2.1 AA minimum)
- Mobile designs phải được approved cùng với desktop
- Design handoff phải include: Figma links, design tokens, component specs

### Step 4 - Backend Development
- API implementation phải follow approved OpenAPI spec (không được tự ý thay đổi)
- Database migrations phải reversible và tested
- Không được merge code có security vulnerabilities (SAST fail)

### Step 5 - Frontend Development
- Không được implement UI không có approved design
- Performance budget phải được check trước PR merge
- Accessibility (a11y) audit phải pass trước completion

### Step 6 - Integration Testing
- Contract tests phải pass trước integration tests
- Toàn bộ happy paths phải verified
- Error scenarios phải tested (network errors, API errors, timeout)

### Step 7 - QA Testing
- Test execution report phải được cập nhật real-time
- Không được skip test cases (phải mark as N/A với justification)
- All Critical và High bugs phải resolved trước Go/No-Go

### Step 8 - DevOps Deployment
- Staging deployment phải stable ít nhất 24 giờ trước production
- Rollback plan phải được tested trước production deploy
- Production deploy phải có observability (monitoring, logging, alerting)

### Step 9 - Review & Release
- Stakeholder demo phải được conducted
- Release notes phải được approved bởi PM
- Post-release monitoring plan phải be in place

## 10. Liên Kết

- Approval rules chi tiết: `.cursor/rules/review-rules.md`
- Workflow steps chi tiết: `workflows/steps/`
- Templates: `workflows/templates/`
- Agent definitions: `.cursor/agents/`
