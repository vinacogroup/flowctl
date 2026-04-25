---
name: documentation
description: "Practical documentation standards for technical specs, guides, and handoffs"
triggers: ["docs", "readme", "spec", "handoff"]
when-to-use: "Use for writing or improving technical documentation with clear structure and intent."
when-not-to-use: "Do not use for code changes that need implementation-first workflows."
prerequisites: []
estimated-tokens: 4324
roles-suggested: ["pm", "tech-lead", "ui-ux", "backend", "frontend"]
version: "1.0.0"
tags: ["docs", "communication"]
---
# Kỹ Năng Documentation
# Skill: Technical Documentation | Used by: All agents | Version: 1.0.0

## 1. Tổng Quan

Documentation là một phần không thể tách rời của quality software. Tất cả agents phải đảm bảo:
- Code được document đầy đủ cho người đọc tiếp theo
- Decisions được recorded để future maintainers hiểu "why"
- APIs được spec'd để enable independent development
- Processes được document để onboarding nhanh hơn

## 2. Code Documentation Standards

### 2.1 TypeScript/JavaScript (JSDoc)

```typescript
/**
 * Xử lý yêu cầu đặt lại mật khẩu cho người dùng.
 *
 * Quy trình:
 * 1. Kiểm tra email tồn tại trong hệ thống
 * 2. Tạo token reset ngẫu nhiên (64 bytes, hex-encoded)
 * 3. Lưu token với TTL 1 giờ vào Redis
 * 4. Gửi email chứa reset link
 *
 * @param email - Email của người dùng cần reset password
 * @returns Promise<void> - Luôn resolve thành công (không tiết lộ email có tồn tại không)
 *
 * @throws {ValidationError} Khi email không đúng định dạng
 * @throws {EmailDeliveryError} Khi không gửi được email (sau 3 lần retry)
 *
 * @example
 * ```typescript
 * // Usage trong controller
 * await authService.initiatePasswordReset('user@example.com')
 * // → Sends reset email if email exists, silently succeeds if not
 * ```
 *
 * @security
 * - Luôn return success dù email có tồn tại hay không (prevent enumeration)
 * - Token được hash trước khi lưu vào database
 * - Token expired sau 1 giờ
 */
async initiatePasswordReset(email: string): Promise<void> {
  // Implementation
}

/**
 * Repository để quản lý User entities trong PostgreSQL.
 *
 * @example
 * ```typescript
 * const repo = new UserRepository(dataSource)
 * const user = await repo.findActiveByEmail('user@example.com')
 * ```
 */
export class UserRepository {

  /**
   * Tìm user active theo email (case-insensitive).
   *
   * @param email - Email cần tìm (sẽ được lowercase trước khi query)
   * @returns User nếu tìm thấy và đang active, null nếu không tìm thấy hoặc inactive
   */
  async findActiveByEmail(email: string): Promise<User | null> {
    return this.dataSource.getRepository(User).findOne({
      where: {
        email: email.toLowerCase(),
        status: UserStatus.ACTIVE,
      },
    })
  }
}
```

### 2.2 Python (Docstrings - Google Style)

```python
def calculate_order_total(
    items: list[OrderItem],
    discount_code: str | None = None,
    user_tier: str = "standard"
) -> OrderTotal:
    """
    Tính tổng giá trị đơn hàng bao gồm discount và thuế.

    Args:
        items: Danh sách các items trong đơn hàng. Không được rỗng.
        discount_code: Mã giảm giá tùy chọn. None nếu không áp dụng.
        user_tier: Tier của người dùng ('standard', 'premium', 'enterprise').
                   Ảnh hưởng đến discount rate. Mặc định là 'standard'.

    Returns:
        OrderTotal object chứa:
        - subtotal: Tổng trước discount và thuế
        - discount_amount: Số tiền được giảm
        - tax_amount: Số tiền thuế (VAT 10%)
        - total: Tổng cuối cùng

    Raises:
        ValidationError: Khi items list rỗng hoặc có item với quantity <= 0
        InvalidDiscountError: Khi discount_code không hợp lệ hoặc đã hết hạn
        ValueError: Khi user_tier không được hỗ trợ

    Example:
        >>> items = [OrderItem(product_id="p1", quantity=2, unit_price=50.0)]
        >>> total = calculate_order_total(items, discount_code="SAVE10")
        >>> print(f"Total: {total.total}")  # Total: 90.0
    """
    if not items:
        raise ValidationError("Order must have at least one item")

    # Calculate subtotal
    subtotal = sum(item.quantity * item.unit_price for item in items)
    # ... rest of implementation
```

### 2.3 Inline Comments - Khi Nên Viết

```typescript
// ✅ GOOD: Explain "why", not "what"

// Rate limiting để prevent brute force attacks - allow 5 attempts per 15 minutes
const rateLimiter = new RateLimiter({ max: 5, windowMs: 15 * 60 * 1000 })

// Use constant-time comparison to prevent timing attacks
// Regular string equality leaks information through execution time
const isValid = timingSafeEqual(
  Buffer.from(providedToken),
  Buffer.from(storedToken)
)

// PostgreSQL JSONB operators: @> means "contains"
// More efficient than extracting and comparing individual fields
const query = 'SELECT * FROM events WHERE metadata @> $1'

// Debounce 300ms to avoid hammering the search API on every keystroke
const debouncedSearch = useMemo(
  () => debounce(handleSearch, 300),
  [handleSearch]
)

// ❌ BAD: State the obvious
const total = price * quantity  // Multiply price by quantity (obvious!)
const user = await getUser(id)  // Get user by id (obvious!)
```

## 3. API Documentation (OpenAPI 3.0)

### 3.1 OpenAPI Specification Template

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: "{Project Name} API"
  version: "1.0.0"
  description: |
    RESTful API cho {Project Name}.

    ## Authentication
    Tất cả endpoints (trừ `/auth/login`, `/auth/register`) yêu cầu
    JWT Bearer token trong Authorization header.

    ```
    Authorization: Bearer <access_token>
    ```

    Access token hết hạn sau 15 phút. Sử dụng refresh token để lấy token mới.

    ## Rate Limiting
    - Public endpoints: 20 requests/minute
    - Authenticated endpoints: 100 requests/minute
    - Admin endpoints: 1000 requests/minute

    Headers trả về:
    - `X-RateLimit-Limit`: Maximum requests per window
    - `X-RateLimit-Remaining`: Remaining requests in current window
    - `X-RateLimit-Reset`: Unix timestamp khi window reset

  contact:
    name: Tech Lead
    email: tech-lead@company.com

servers:
  - url: https://api.example.com/v1
    description: Production
  - url: https://staging-api.example.com/v1
    description: Staging
  - url: http://localhost:3000/api/v1
    description: Development

security:
  - BearerAuth: []

components:
  securitySchemes:
    BearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT

  schemas:
    # Reusable schemas
    PaginatedResponse:
      type: object
      properties:
        data:
          type: array
        meta:
          type: object
          properties:
            total: { type: integer }
            page: { type: integer }
            limit: { type: integer }
            totalPages: { type: integer }

    ErrorResponse:
      type: object
      required: [error, message]
      properties:
        error:
          type: string
          example: "VALIDATION_ERROR"
        message:
          type: string
          example: "One or more fields are invalid"
        details:
          type: array
          items:
            type: object
            properties:
              field: { type: string }
              message: { type: string }

    User:
      type: object
      properties:
        id:
          type: string
          format: uuid
          readOnly: true
        email:
          type: string
          format: email
        name:
          type: string
          minLength: 1
          maxLength: 100
        role:
          type: string
          enum: [user, admin]
        createdAt:
          type: string
          format: date-time
          readOnly: true

paths:
  /users:
    get:
      summary: Danh sách users với phân trang
      description: |
        Trả về danh sách users. Chỉ admin mới có thể gọi endpoint này.

        Kết quả được sắp xếp theo `createdAt` giảm dần (mới nhất trước).
      operationId: listUsers
      tags: [Users]
      security:
        - BearerAuth: []
      parameters:
        - name: page
          in: query
          schema: { type: integer, minimum: 1, default: 1 }
        - name: limit
          in: query
          schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
        - name: search
          in: query
          description: Search theo name hoặc email (case-insensitive)
          schema: { type: string, maxLength: 100 }
      responses:
        '200':
          description: Danh sách users
          content:
            application/json:
              schema:
                allOf:
                  - $ref: '#/components/schemas/PaginatedResponse'
                  - type: object
                    properties:
                      data:
                        type: array
                        items:
                          $ref: '#/components/schemas/User'
        '401':
          description: Chưa xác thực
          content:
            application/json:
              schema: { $ref: '#/components/schemas/ErrorResponse' }
        '403':
          description: Không có quyền (chỉ admin)
          content:
            application/json:
              schema: { $ref: '#/components/schemas/ErrorResponse' }
```

## 4. Architecture Decision Records (ADR)

### 4.1 ADR Template Chi Tiết

```markdown
# ADR-{NNN}: {Decision Title}

**Ngày tạo**: {YYYY-MM-DD}
**Tác giả**: Tech Lead Agent
**Status**: Proposed | Accepted | Deprecated | Superseded by ADR-{N}
**Được review bởi**: {PM, Tech Lead, relevant devs}

## Context

{Mô tả bối cảnh và vấn đề cần giải quyết. Trả lời câu hỏi:
- Chúng ta đang ở đâu?
- Chúng ta cần giải quyết vấn đề gì?
- Các constraints là gì (technical, business, team)?}

## Problem Statement

{Phát biểu vấn đề một cách súc tích và rõ ràng.}

## Decision

{Quyết định được đưa ra. Một câu rõ ràng, không mơ hồ.}

**Chúng ta sẽ sử dụng {technology/approach} cho {purpose}.**

## Rationale

{Tại sao quyết định này được chọn. Include:
- Tại sao option này tốt hơn các alternatives
- Alignment với các constraints đã identify
- Evidence hoặc data hỗ trợ quyết định này}

## Alternatives Considered

### Option A: {Alternative 1 Name}
**Description**: {Mô tả option}

**Pros**:
- {Advantage 1}
- {Advantage 2}

**Cons**:
- {Disadvantage 1}
- {Disadvantage 2}

**Why not chosen**: {Lý do không chọn option này}

### Option B: {Alternative 2 Name}
{Same format}

## Consequences

### Positive Consequences
- {Benefit 1}
- {Benefit 2}

### Negative Consequences / Trade-offs
- {Trade-off 1}: {How we'll manage this}
- {Technical debt incurred}: {Plan to address}

### Risks
- **{Risk}**: {Probability: High/Med/Low} | {Impact: High/Med/Low}
  → Mitigation: {How to mitigate}

## Implementation Notes

{Hướng dẫn implement decision này nếu cần.
Links đến relevant resources.}

## Related Decisions

- ADR-{id}: {Relationship - "Supersedes" / "Related to" / "Enabled by"}

## Review History

| Date | Action | Reviewer | Notes |
|------|--------|----------|-------|
| {date} | Proposed | {name} | Initial draft |
| {date} | Accepted | Tech Lead + PM | Minor changes to consequence section |
```

### 4.2 Khi Nào Tạo ADR

Tạo ADR khi:
- Chọn primary technology (language, framework, database, cloud)
- Chọn architecture pattern (microservices vs monolith, event-driven vs REST)
- Data storage strategy (SQL vs NoSQL, sharding approach)
- Authentication/authorization approach
- Third-party service integrations
- Deployment strategy (containers, serverless, bare metal)
- Coding conventions departing from standard
- Performance trade-offs (cache-aside vs write-through)

KHÔNG cần ADR cho:
- Routine implementation details
- Bug fixes
- Minor dependency updates
- Style/formatting choices (covered by linters)

## 5. Changelog và Release Notes

### 5.1 CHANGELOG.md Format (Keep a Changelog)

```markdown
# Changelog

All notable changes to this project will be documented in this file.
Format: [Semantic Versioning](https://semver.org/)

## [Unreleased]

### Added
- {Feature được thêm}

### Changed
- {Thay đổi existing functionality}

### Deprecated
- {Feature sẽ bị remove trong tương lai}

### Removed
- {Feature đã bị remove}

### Fixed
- {Bug fixes}

### Security
- {Security fixes - important!}

---

## [1.0.0] - 2026-04-23

### Added
- User authentication with JWT (US-001, US-002)
- Product catalog with search and filtering (US-010 - US-015)
- Shopping cart and checkout flow (US-020 - US-025)
- Order management dashboard for admins (US-030)
- Email notifications for order status changes (US-031)

### Security
- Implemented rate limiting on all auth endpoints
- Added input sanitization for all user-provided content

---

## [0.9.0-beta] - 2026-04-01

### Added
- Beta version for internal testing
```

### 5.2 Release Notes Template (User-facing)

```markdown
# Release Notes - v{version} ({YYYY-MM-DD})

## Tính Năng Mới 🎉

### {Feature Name}
{Mô tả tính năng bằng ngôn ngữ của người dùng cuối.
Focus vào value/benefit, không phải technical detail.}

**Cách sử dụng**: {Brief instructions}

---

## Cải Tiến ✨

- **{Improvement}**: {Mô tả cải tiến và lợi ích}
- **Performance**: {Ứng dụng giờ nhanh hơn X% khi...}

## Sửa Lỗi 🐛

- **{Bug description}**: {Mô tả lỗi và cách đã fix}
- **{Bug description}**: {Mô tả}

## Known Issues ⚠️

- **{Issue}**: {Mô tả issue và workaround nếu có}
  *Dự kiến fix trong v{next-version}*

## Breaking Changes (nếu có) ⛔

{IMPORTANT: Những thay đổi yêu cầu action từ user/developer}

- **{Change}**: {Mô tả và migration steps}

## Upgrade Guide

{Hướng dẫn upgrade nếu có special steps}

---
*Cảm ơn đã sử dụng {Product Name}!*
*Support: support@example.com*
```

## 6. README Template

```markdown
# {Project Name}

{One-liner mô tả project}

[![Build Status](badge-url)](ci-url)
[![Coverage](badge-url)](coverage-url)
[![License](badge-url)](license-url)

## Giới Thiệu

{2-3 đoạn mô tả project là gì, giải quyết vấn đề gì, và tại sao nó tồn tại.}

## Tính Năng Chính

- ✅ {Feature 1}
- ✅ {Feature 2}
- 🚧 {Feature 3 - in progress}

## Cài Đặt

### Yêu Cầu

- Node.js >= 20.0.0
- PostgreSQL >= 16.0
- Redis >= 7.0

### Cài Đặt Nhanh

```bash
# Clone repository
git clone https://github.com/{org}/{repo}.git
cd {repo}

# Install dependencies
npm install

# Setup environment
cp .env.example .env
# Edit .env với credentials của bạn

# Run database migrations
npm run db:migrate

# Seed data (development only)
npm run db:seed

# Start development server
npm run dev
# → http://localhost:3000
```

### Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `DATABASE_URL` | Yes | PostgreSQL connection string | `postgresql://user:pass@localhost/db` |
| `REDIS_URL` | Yes | Redis connection string | `redis://localhost:6379` |
| `JWT_SECRET` | Yes | JWT signing secret (min 32 chars) | `your-secret-here` |
| `SMTP_HOST` | No | Email server host | `smtp.sendgrid.net` |

## Phát Triển

### Project Structure

```
src/
  api/         # API route handlers
  services/    # Business logic
  models/      # Database models
  utils/       # Shared utilities
tests/
  unit/        # Unit tests
  integration/ # Integration tests
  e2e/         # End-to-end tests
docs/
  adr/         # Architecture Decision Records
  api/         # OpenAPI specification
```

### Development Commands

```bash
npm run dev          # Start dev server with hot reload
npm run test         # Run all tests
npm run test:watch   # Run tests in watch mode
npm run test:cov     # Run tests with coverage report
npm run lint         # Run linter
npm run type-check   # TypeScript type check
npm run build        # Build for production
```

### Coding Conventions

- Follow `.cursorrules` cho tất cả conventions
- Run `npm run lint` trước khi commit
- Viết tests cho mọi business logic
- Document public APIs với JSDoc

## Deployment

Xem `.cursor/agents/devops-agent.md` và `workflows/steps/08-devops-deployment.md`

## Contributing

1. Đọc quy trình trong `workflows/it-product-flowctl.md`
2. Tạo branch theo convention: `gitnexus branch create "{description}"`
3. Viết code và tests
4. Submit PR và chờ review

## License

{License type} - xem [LICENSE](LICENSE) để biết thêm.
```

## 7. Documentation Tracking

Lưu documentation status trong step summary và flowctl state:

```bash
# Khi hoàn thành documentation
flowctl add-decision "docs-complete: API={api_pct}%, ADRs={adr_count}, README=updated"

# Cấu trúc docs chuẩn
docs/
  api/openapi.yaml              ← API spec
  adr/ADR-{id}-{title}.md      ← Architecture decisions
  runbooks/                     ← Operational guides
workflows/steps/{N}-*/          ← Step-level docs
```

## 8. Liên Kết

- Global rules cho doc standards: `.cursor/rules/global-rules.md`
- Step summary template: `workflows/templates/step-summary-template.md`
- Tech Lead ADR process: `.cursor/agents/tech-lead-agent.md`
- Code documentation: Trong từng agent definition file
