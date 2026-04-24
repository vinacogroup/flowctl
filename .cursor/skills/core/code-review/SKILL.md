---
name: code-review
description: "Structured review workflow for correctness, risk, and maintainability"
triggers: ["review", "pull-request", "refactor", "quality"]
when-to-use: "Use for code review requests, defect prevention, and pre-merge quality checks."
when-not-to-use: "Do not use for production incident triage; use debugging or incident-response skills."
prerequisites: []
estimated-tokens: 3386
roles-suggested: ["tech-lead", "backend", "frontend", "qa"]
version: "1.0.0"
tags: ["quality", "review"]
---
# Kỹ Năng Code Review
# Skill: Code Review | Used by: Tech Lead, all developers | Version: 1.0.0

## 1. Triết Lý Code Review

Code review không chỉ là tìm bugs - đây là quá trình collaborative learning, knowledge sharing, và maintaining collective code ownership. Mục tiêu:
- **Quality**: Bắt defects sớm trước khi reach production
- **Knowledge sharing**: Spread domain và technical knowledge
- **Consistency**: Maintain codebase style và patterns
- **Mentoring**: Help junior developers grow
- **Security**: Catch security vulnerabilities

## 2. Review Mindset

### 2.1 Reviewer Mindset
- **Collaborative, not adversarial**: "We" not "you" - chúng ta cùng improve code
- **Specific, not vague**: "Line 45 has N+1 query" not "performance is bad"
- **Constructive**: Always suggest alternative nếu có thể
- **Kind và respectful**: Critique code, not the person
- **Thorough but timely**: Review kỹ nhưng trong SLA

### 2.2 Author Mindset
- **Grateful, not defensive**: Reviews make code better
- **Understand before responding**: Read carefully, ask clarification nếu unclear
- **Explain your reasoning**: Context helps reviewers understand decisions
- **Small PRs are better**: Easier to review, faster feedback

## 3. Review Comment Categories

### 3.1 Comment Severity Levels
```
[BLOCKER]  - Phải fix TRƯỚC KHI merge. Security issues, correctness bugs,
             breaking changes không documented. Stops PR.

[IMPORTANT] - Strong recommendation. Should fix unless có valid reason.
              Discuss before proceeding. May delay merge.

[SUGGESTION] - Nice to have. Author decides. Won't block merge.
               Good for future consideration.

[NITPICK]  - Minor style/formatting. Author's call. Encouraged to fix
             but won't block.

[QUESTION] - Cần giải thích. Không nhất thiết có vấn đề.
             Phải trả lời.

[PRAISE]   - Positive feedback. Acknowledge good work.
             No action needed.

[INFO]     - Educational note. Sharing knowledge.
             No action needed.
```

### 3.2 Comment Format
```markdown
**[BLOCKER] Security: SQL Injection vulnerability**

The query on line 47 directly interpolates user input:
```sql
SELECT * FROM users WHERE name = '${userName}'
```

This is vulnerable to SQL injection. Use parameterized queries:
```sql
SELECT * FROM users WHERE name = $1
// With: [userName]
```

Ref: OWASP SQL Injection Prevention Cheat Sheet
```

## 4. Checklist Review Theo Loại File

### 4.1 Backend API Endpoints (Controller Layer)

```markdown
## Controller Review Checklist

### Input Validation
- [ ] Tất cả request params được validate (type, format, length, range)
- [ ] Tất cả request body được validate với schema (DTO/Zod/Joi)
- [ ] File uploads: type check, size limit, virus scan
- [ ] Query params: page/limit với min/max enforcement
- [ ] Path params: validate format (UUID, numeric, etc.)

### Authentication & Authorization
- [ ] Auth guard applied (không bỏ sót endpoint nào)
- [ ] Role/permission check ở đúng cấp (service, không chỉ controller)
- [ ] Resource ownership check (user can only access their own resources)
- [ ] Admin-only endpoints properly protected

### Response Handling
- [ ] Correct HTTP status codes (200, 201, 204, 400, 401, 403, 404, 409, 500)
- [ ] Consistent response format (success/error structure)
- [ ] Sensitive data không có trong response (passwords, tokens, internal IDs)
- [ ] Pagination response includes total, page, limit
- [ ] Error messages không expose internal details

### Documentation
- [ ] OpenAPI/Swagger decorators hoàn chỉnh
- [ ] All response types documented
- [ ] Auth requirements documented
```

### 4.2 Service Layer

```markdown
## Service Review Checklist

### Business Logic
- [ ] Business rules được validate đầy đủ
- [ ] Edge cases được handle (empty lists, null values, concurrent updates)
- [ ] Transactions used khi cần (multiple DB operations)
- [ ] Idempotency considered cho write operations

### Error Handling
- [ ] Specific exception types (NotFound, Conflict, Validation, etc.)
- [ ] Error messages helpful và consistent
- [ ] Exception propagation đúng (không swallow errors)
- [ ] Logging ở mức phù hợp (không log PII)

### Performance
- [ ] N+1 query problems không tồn tại
- [ ] Batch operations instead of loops khi có thể
- [ ] Appropriate caching cho expensive operations
- [ ] Async operations handled correctly (không missing await)

### Testability
- [ ] Dependencies injected (không hardcoded)
- [ ] External calls isolated trong separate services/adapters
- [ ] Pure functions where possible
```

### 4.3 Database/Repository Layer

```markdown
## Repository Review Checklist

### Query Safety
- [ ] Parameterized queries (không string interpolation)
- [ ] SELECT only needed columns (không SELECT *)
- [ ] JOINs are correct và efficient
- [ ] Indexes exist cho WHERE clauses
- [ ] LIMIT applied cho queries có thể return nhiều rows

### Data Integrity
- [ ] Transactions wrap related operations
- [ ] Optimistic locking cho concurrent updates
- [ ] Soft delete used thay vì hard delete
- [ ] Cascade delete configured đúng

### Migrations
- [ ] Migration có cả up và down
- [ ] Migration là idempotent (safe to run multiple times)
- [ ] Data migrations handle null/empty cases
- [ ] Large table migrations không lock table (use batching)
```

### 4.4 Frontend Components

```markdown
## Component Review Checklist

### React/Vue/Angular Specifics
- [ ] Props/inputs có proper TypeScript types
- [ ] Default props defined cho optional props
- [ ] Event handlers cleanup trong useEffect/onUnmounted
- [ ] Không có memory leaks (subscriptions, timers, event listeners)
- [ ] React: Keys trong lists (không use index khi avoidable)
- [ ] React: Dependencies array trong useEffect complete

### Rendering Performance
- [ ] Unnecessary re-renders avoided (memo, useMemo, useCallback khi cần)
- [ ] Large lists virtualized (react-virtuoso, tanstack-virtual)
- [ ] Images lazy loaded khi ngoài viewport
- [ ] Heavy components lazy loaded với dynamic import

### Accessibility
- [ ] Semantic HTML elements (button không phải div với onClick)
- [ ] ARIA labels cho icon-only buttons
- [ ] Form inputs có associated labels
- [ ] Error messages linked với aria-describedby
- [ ] Tab order logical
- [ ] Focus management sau modal/dialog close

### State Management
- [ ] State minimal (không over-state)
- [ ] Server state managed với React Query/SWR (không local state)
- [ ] Loading, error, empty states đều handled
- [ ] Optimistic updates với proper rollback

### Styling
- [ ] Design tokens used (không hardcoded colors/spacing)
- [ ] Responsive - tested tất cả breakpoints
- [ ] Dark mode support nếu applicable
```

### 4.5 Test Files

```markdown
## Test Review Checklist

### Test Quality
- [ ] Tests có descriptive names (describes behavior, not implementation)
- [ ] Single assertion per test concept (AAA pattern: Arrange, Act, Assert)
- [ ] Tests independent (không order-dependent)
- [ ] Edge cases và error paths covered
- [ ] No test logic errors (asserting wrong thing)

### Mocking
- [ ] Mocks match actual interfaces
- [ ] Không over-mock (integration tests với real dependencies khi có thể)
- [ ] Mock cleanup in afterEach

### Coverage
- [ ] Happy path covered
- [ ] Error paths covered (exceptions, network errors, invalid input)
- [ ] Boundary conditions tested
- [ ] Critical business logic >= 90% coverage

### E2E Tests
- [ ] Tests stable (không flaky với timeouts/race conditions)
- [ ] Test data isolated (cleanup after test)
- [ ] Selectors accessible-friendly (role > label > testid > CSS)
```

## 5. Common Review Findings Và Fixes

### 5.1 Security Findings

```typescript
// ❌ BLOCKER: SQL Injection
const query = `SELECT * FROM users WHERE id = ${userId}`

// ✅ Fix: Parameterized query
const query = `SELECT * FROM users WHERE id = $1`
db.query(query, [userId])

// ---

// ❌ BLOCKER: Timing attack vulnerability
if (providedToken === expectedToken) { ... }

// ✅ Fix: Constant-time comparison
import { timingSafeEqual } from 'crypto'
const safe = timingSafeEqual(
  Buffer.from(providedToken),
  Buffer.from(expectedToken)
)

// ---

// ❌ BLOCKER: Hardcoded secret
const apiKey = "sk-1234567890abcdef"

// ✅ Fix: Environment variable
const apiKey = process.env.OPENAI_API_KEY
if (!apiKey) throw new Error('OPENAI_API_KEY is not configured')

// ---

// ❌ IMPORTANT: Missing authorization check
async getUser(id: string) {
  return this.userRepository.findById(id)  // Any authenticated user can get any user
}

// ✅ Fix: Ownership check
async getUser(id: string, requestingUserId: string) {
  if (id !== requestingUserId && !await this.isAdmin(requestingUserId)) {
    throw new ForbiddenException('Cannot access other users data')
  }
  return this.userRepository.findById(id)
}
```

### 5.2 Performance Findings

```typescript
// ❌ BLOCKER: N+1 Query
const orders = await Order.findAll()
for (const order of orders) {
  order.user = await User.findById(order.userId)  // N+1!
}

// ✅ Fix: Eager loading
const orders = await Order.findAll({
  include: [{ model: User }]
})

// ---

// ❌ IMPORTANT: Missing pagination
async getProducts(): Promise<Product[]> {
  return this.productRepo.findAll()  // Could return millions of rows
}

// ✅ Fix: Always paginate
async getProducts(page: number = 1, limit: number = 20): Promise<PaginatedResult<Product>> {
  const [items, total] = await this.productRepo.findAndCount({
    skip: (page - 1) * limit,
    take: Math.min(limit, 100),  // Enforce max limit
  })
  return { items, total, page, limit }
}

// ---

// ❌ IMPORTANT: Missing index
// Migration có WHERE clause trên email nhưng không có index

// ✅ Fix: Add index
await queryInterface.addIndex('users', ['email'], { unique: true })

// ---

// ❌ SUGGESTION: Sequential async calls that could be parallel
const user = await getUser(id)
const orders = await getOrders(userId)  // Can run in parallel

// ✅ Fix: Parallel execution
const [user, orders] = await Promise.all([
  getUser(id),
  getOrders(userId),
])
```

### 5.3 Code Quality Findings

```typescript
// ❌ IMPORTANT: Magic numbers/strings
if (status === 2) { ... }  // What is 2?
const TIMEOUT = 86400000   // What is this?

// ✅ Fix: Named constants
const UserStatus = {
  ACTIVE: 1,
  INACTIVE: 2,
  BANNED: 3,
} as const

const ONE_DAY_MS = 24 * 60 * 60 * 1000

// ---

// ❌ IMPORTANT: Error swallowing
try {
  await sendEmail(user.email, template)
} catch (e) {
  // Silently ignore
}

// ✅ Fix: Handle or propagate
try {
  await sendEmail(user.email, template)
} catch (error) {
  logger.error('Failed to send email', { userId: user.id, error })
  // Re-throw if critical, or handle gracefully
  throw new ServiceError('Email delivery failed', { cause: error })
}

// ---

// ❌ NITPICK: Inconsistent naming
async function get_user(userId: string) { ... }  // snake_case in JS/TS

// ✅ Fix: camelCase
async function getUser(userId: string) { ... }
```

### 5.4 Frontend Findings

```tsx
// ❌ BLOCKER: XSS vulnerability
<div dangerouslySetInnerHTML={{ __html: userInput }} />

// ✅ Fix: Sanitize trước hoặc không dùng dangerouslySetInnerHTML
import DOMPurify from 'dompurify'
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(userInput) }} />

// ---

// ❌ IMPORTANT: Memory leak - missing cleanup
useEffect(() => {
  const interval = setInterval(fetchData, 5000)
  // Missing cleanup!
}, [])

// ✅ Fix: Return cleanup function
useEffect(() => {
  const interval = setInterval(fetchData, 5000)
  return () => clearInterval(interval)  // Cleanup on unmount
}, [])

// ---

// ❌ IMPORTANT: Accessibility - no label
<input type="text" placeholder="Enter email" />

// ✅ Fix: Associate label
<label htmlFor="email">Email</label>
<input id="email" type="email" placeholder="Enter email" aria-describedby="email-error" />
<span id="email-error" role="alert">{error}</span>
```

## 6. Review Prioritization

### 6.1 Priority Order cho Tech Lead
1. **Security issues** (Always first)
2. **Correctness bugs** (Logic errors, data corruption risks)
3. **Performance blockers** (N+1, missing indexes, missing pagination)
4. **Breaking changes** (API changes, removed functionality)
5. **Architecture violations** (Layering, coupling, patterns)
6. **Test coverage** (Missing critical tests)
7. **Code quality** (Readability, naming, complexity)
8. **Documentation** (Missing docs for public APIs)
9. **Style** (Formatting, minor naming)

### 6.2 Time Management
```
Review time estimate:
- < 100 LOC changed: 30-60 minutes
- 100-300 LOC: 1-2 hours
- 300-500 LOC: 2-4 hours (consider splitting PR)
- > 500 LOC: Request to split into smaller PRs
```

## 7. Review Metrics (Track trong Graphify)

```bash
graphify update "metric:code-review" \
  --pr-number "{n}" \
  --review-duration-hours "{h}" \
  --blocker-count "{n}" \
  --important-count "{n}" \
  --suggestion-count "{n}" \
  --approved "true|false"

# Team metrics (monthly)
graphify query "metric:code-review:*" \
  --aggregate "avg-duration,blocker-rate,approval-rate"
```

## 8. Liên Kết

- Review rules: `.cursor/rules/review-rules.md`
- GitNexus review commands: `.cursor/skills/gitnexus-integration.md`
- Tech Lead agent review process: `.cursor/agents/tech-lead-agent.md`
- PR templates và checklists: `workflows/templates/review-checklist-template.md`
