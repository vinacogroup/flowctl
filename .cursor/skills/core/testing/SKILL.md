---
name: testing
description: "Testing strategy and execution patterns across unit, integration, and E2E"
triggers: ["test", "qa", "regression", "coverage"]
when-to-use: "Use when designing, implementing, or reviewing automated test strategy and suites."
when-not-to-use: "Do not use for architecture tradeoff decisions without test implementation scope."
prerequisites: []
estimated-tokens: 6405
roles-suggested: ["qa", "backend", "frontend", "tech-lead"]
version: "1.0.0"
tags: ["testing", "quality"]
---
# Kỹ Năng Testing
# Skill: Software Testing | Used by: QA, Backend Dev, Frontend Dev | Version: 1.0.0

## 1. Testing Strategy Tổng Quan

### 1.1 Testing Pyramid
```
           ▲
          /E\          E2E Tests
         /   \         (ít nhất, chạy chậm, expensive)
        /─────\
       / Intg  \       Integration Tests
      /─────────\      (vừa phải, test boundaries)
     /  Unit     \     Unit Tests
    /─────────────\    (nhiều nhất, chạy nhanh, rẻ)
```

**Target distribution:**
- Unit Tests: 70% (fast, isolated, many)
- Integration Tests: 20% (test service boundaries, API contracts)
- E2E Tests: 10% (critical user journeys, slow but comprehensive)

### 1.2 Testing Types trong Dự Án

| Type | Tool | What | When |
|------|------|------|------|
| Unit | Jest/Vitest/pytest | Functions, classes, components | During development |
| Integration | Jest/pytest | API endpoints, service interactions | Step 4, 5 |
| Contract | Pact | API contracts frontend↔backend | Before Step 6 |
| E2E | Playwright | Critical user journeys | Step 6, 7 |
| Performance | k6 | Load, stress, spike testing | Step 7 |
| Security | OWASP ZAP + Snyk | DAST + dependency audit | Step 7, 8 |
| Accessibility | axe-core | WCAG compliance | Step 5, 7 |
| Visual Regression | Playwright + Percy | UI screenshot comparison | Step 5, 7 |

## 2. Unit Testing Best Practices

### 2.1 AAA Pattern (Arrange, Act, Assert)

```typescript
describe('UserService', () => {
  describe('createUser', () => {

    it('should create a user with hashed password', async () => {
      // ====== ARRANGE ======
      const mockRepo = createMockRepository<User>()
      const mockHasher = { hash: jest.fn().mockResolvedValue('hashed_password') }
      const service = new UserService(mockRepo, mockHasher)

      const input = {
        email: 'test@example.com',
        password: 'rawPassword123',
        name: 'John Doe',
      }

      mockRepo.save.mockResolvedValue({
        id: 'uuid-123',
        ...input,
        password: 'hashed_password',
        createdAt: new Date(),
      })

      // ====== ACT ======
      const result = await service.createUser(input)

      // ====== ASSERT ======
      expect(result.id).toBeDefined()
      expect(result.email).toBe('test@example.com')
      expect(result.password).toBeUndefined()  // Password should not be in response
      expect(mockHasher.hash).toHaveBeenCalledWith('rawPassword123')
      expect(mockRepo.save).toHaveBeenCalledTimes(1)
    })

    it('should throw ConflictException when email already exists', async () => {
      // Arrange
      const mockRepo = createMockRepository<User>()
      mockRepo.findByEmail.mockResolvedValue({ id: 'existing' })

      const service = new UserService(mockRepo, mockHasher)

      // Act & Assert
      await expect(
        service.createUser({ email: 'existing@example.com', password: 'pass', name: 'Jane' })
      ).rejects.toThrow(ConflictException)

      await expect(
        service.createUser({ email: 'existing@example.com', password: 'pass', name: 'Jane' })
      ).rejects.toThrow('Email already registered')
    })

    it('should throw ValidationException for invalid email format', async () => {
      const service = new UserService(createMockRepository(), mockHasher)

      await expect(
        service.createUser({ email: 'not-an-email', password: 'pass', name: 'Jane' })
      ).rejects.toThrow(ValidationException)
    })

  })
})
```

### 2.2 Test Doubles

```typescript
// === MOCK (verify interactions) ===
const mockEmailService = {
  sendWelcomeEmail: jest.fn().mockResolvedValue(undefined),
  sendPasswordReset: jest.fn().mockResolvedValue(undefined),
}

// Verify it was called correctly
expect(mockEmailService.sendWelcomeEmail).toHaveBeenCalledWith({
  to: 'user@example.com',
  name: 'John',
})

// === STUB (control return values) ===
const stubRepo = {
  findById: jest.fn().mockResolvedValue(mockUser),
  findAll: jest.fn().mockResolvedValue([mockUser1, mockUser2]),
  save: jest.fn().mockImplementation((entity) => Promise.resolve({ ...entity, id: 'new-id' })),
}

// === SPY (wrap real implementation) ===
const service = new UserService(realRepo, emailService)
const createSpy = jest.spyOn(service, 'createUser')

await service.createUser(data)

expect(createSpy).toHaveBeenCalledTimes(1)
expect(createSpy).toHaveBeenCalledWith(data)

// === FAKE (simplified working implementation) ===
class FakeUserRepository implements UserRepository {
  private users: Map<string, User> = new Map()

  async findById(id: string): Promise<User | null> {
    return this.users.get(id) ?? null
  }

  async save(user: User): Promise<User> {
    const id = user.id ?? generateId()
    const saved = { ...user, id }
    this.users.set(id, saved)
    return saved
  }

  async findByEmail(email: string): Promise<User | null> {
    for (const user of this.users.values()) {
      if (user.email === email) return user
    }
    return null
  }
}
```

### 2.3 Testing Edge Cases

```typescript
describe('calculateDiscount', () => {
  // Happy path
  it('should apply 10% discount for orders over $100', () => {
    expect(calculateDiscount(150, 'STANDARD')).toBe(15)
  })

  // Boundary conditions
  it('should NOT apply discount for orders exactly $100', () => {
    expect(calculateDiscount(100, 'STANDARD')).toBe(0)
  })

  it('should apply discount for orders $100.01', () => {
    expect(calculateDiscount(100.01, 'STANDARD')).toBeCloseTo(10.001)
  })

  // Invalid inputs
  it('should throw for negative amount', () => {
    expect(() => calculateDiscount(-50, 'STANDARD')).toThrow(ValidationError)
  })

  it('should return 0 for zero amount', () => {
    expect(calculateDiscount(0, 'STANDARD')).toBe(0)
  })

  // Null/undefined handling
  it('should handle null coupon code gracefully', () => {
    expect(calculateDiscount(150, null)).toBe(0)
  })

  // Large numbers
  it('should handle very large order amounts', () => {
    expect(calculateDiscount(1_000_000, 'STANDARD')).toBe(100_000)
  })

  // Concurrent scenarios (nếu có side effects)
  it('should be idempotent - same result on multiple calls', () => {
    const result1 = calculateDiscount(200, 'VIP')
    const result2 = calculateDiscount(200, 'VIP')
    expect(result1).toBe(result2)
  })
})
```

## 3. Integration Testing

### 3.1 API Integration Tests (Supertest)

```typescript
import request from 'supertest'
import { createTestApp } from '../helpers/test-app'
import { createTestDatabase, clearDatabase } from '../helpers/test-database'

describe('POST /api/v1/users', () => {
  let app: Express
  let db: TestDatabase

  beforeAll(async () => {
    db = await createTestDatabase()
    app = createTestApp({ database: db })
  })

  afterAll(async () => {
    await db.close()
  })

  afterEach(async () => {
    await clearDatabase(db)
  })

  it('201: creates user successfully with valid data', async () => {
    const response = await request(app)
      .post('/api/v1/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        email: 'newuser@example.com',
        password: 'SecurePass123!',
        name: 'New User',
      })
      .expect(201)

    expect(response.body).toMatchObject({
      id: expect.any(String),
      email: 'newuser@example.com',
      name: 'New User',
    })
    expect(response.body.password).toBeUndefined()  // Password never in response

    // Verify persisted in database
    const dbUser = await db.users.findByEmail('newuser@example.com')
    expect(dbUser).not.toBeNull()
    expect(dbUser!.password).not.toBe('SecurePass123!')  // Should be hashed
  })

  it('400: returns validation errors for invalid data', async () => {
    const response = await request(app)
      .post('/api/v1/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        email: 'not-valid-email',
        password: '123',  // Too short
      })
      .expect(400)

    expect(response.body.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ field: 'email', message: expect.any(String) }),
        expect.objectContaining({ field: 'password', message: expect.any(String) }),
        expect.objectContaining({ field: 'name', message: expect.any(String) }),
      ])
    )
  })

  it('409: returns conflict when email already exists', async () => {
    // Create user first
    await db.users.create({ email: 'existing@example.com', name: 'Existing', password: 'hashed' })

    await request(app)
      .post('/api/v1/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ email: 'existing@example.com', password: 'pass123!', name: 'Duplicate' })
      .expect(409)
  })

  it('401: returns unauthorized without auth token', async () => {
    await request(app)
      .post('/api/v1/users')
      .send({ email: 'test@example.com', password: 'pass', name: 'Test' })
      .expect(401)
  })

  it('403: returns forbidden for non-admin users', async () => {
    await request(app)
      .post('/api/v1/users')
      .set('Authorization', `Bearer ${regularUserToken}`)
      .send({ email: 'test@example.com', password: 'pass', name: 'Test' })
      .expect(403)
  })
})
```

### 3.2 Contract Tests (Pact)

```typescript
// Consumer side (Frontend defines expected contract)
describe('User API Contract', () => {
  const provider = new PactV3({
    consumer: 'frontend-app',
    provider: 'user-api',
  })

  it('can get a user by ID', async () => {
    await provider.addInteraction({
      states: [{ description: 'a user with ID user-123 exists' }],
      uponReceiving: 'a request for user by ID',
      withRequest: {
        method: 'GET',
        path: '/api/v1/users/user-123',
        headers: { Authorization: like('Bearer token') },
      },
      willRespondWith: {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: {
          id: like('user-123'),
          email: like('user@example.com'),
          name: like('John Doe'),
          role: like('user'),
          createdAt: like('2026-04-23T10:00:00.000Z'),
          // Verify password is NOT in response
        },
      },
    })

    const result = await userService.getUserById('user-123', 'Bearer token')
    expect(result.id).toBe('user-123')
  })
})
```

## 4. E2E Testing với Playwright

### 4.1 Page Object Model Setup

```typescript
// tests/e2e/pages/BasePage.ts
export abstract class BasePage {
  constructor(protected page: Page) {}

  async waitForLoaded(): Promise<void> {
    await this.page.waitForLoadState('networkidle')
  }

  async takeScreenshot(name: string): Promise<void> {
    await this.page.screenshot({ path: `screenshots/${name}.png` })
  }
}

// tests/e2e/pages/LoginPage.ts
export class LoginPage extends BasePage {
  private emailInput = () => this.page.getByLabel('Email')
  private passwordInput = () => this.page.getByLabel('Mật khẩu')
  private submitButton = () => this.page.getByRole('button', { name: 'Đăng nhập' })
  private errorMessage = () => this.page.getByRole('alert')

  async navigate() {
    await this.page.goto('/login')
    await this.waitForLoaded()
  }

  async login(email: string, password: string) {
    await this.emailInput().fill(email)
    await this.passwordInput().fill(password)
    await this.submitButton().click()
  }

  async getErrorMessage() {
    return this.errorMessage().textContent()
  }

  async isOnPage() {
    return this.page.url().includes('/login')
  }
}

// tests/e2e/pages/DashboardPage.ts
export class DashboardPage extends BasePage {
  async isOnPage() {
    return this.page.url().includes('/dashboard')
  }

  async getWelcomeMessage() {
    return this.page.getByTestId('welcome-message').textContent()
  }
}
```

### 4.2 E2E Test Implementation

```typescript
// tests/e2e/auth.spec.ts
import { test, expect } from '@playwright/test'
import { LoginPage } from './pages/LoginPage'
import { DashboardPage } from './pages/DashboardPage'

// Fixtures
const TEST_USER = {
  email: 'testuser@example.com',
  password: 'TestPass123!',
  name: 'Test User',
}

test.describe('Authentication Flow', () => {
  test.describe('Login', () => {

    test('TC-E2E-001: Successful login redirects to dashboard', async ({ page }) => {
      const loginPage = new LoginPage(page)
      const dashboardPage = new DashboardPage(page)

      await loginPage.navigate()
      await loginPage.login(TEST_USER.email, TEST_USER.password)

      await expect(page).toHaveURL(/\/dashboard/)
      await expect(dashboardPage.isOnPage()).resolves.toBe(true)
    })

    test('TC-E2E-002: Failed login shows error message', async ({ page }) => {
      const loginPage = new LoginPage(page)

      await loginPage.navigate()
      await loginPage.login('wrong@email.com', 'wrongpassword')

      const error = await loginPage.getErrorMessage()
      expect(error).toContain('Email hoặc mật khẩu không đúng')
      await expect(loginPage.isOnPage()).resolves.toBe(true)
    })

    test('TC-E2E-003: Empty form validation', async ({ page }) => {
      const loginPage = new LoginPage(page)

      await loginPage.navigate()
      await page.getByRole('button', { name: 'Đăng nhập' }).click()

      await expect(page.getByText('Email không được để trống')).toBeVisible()
      await expect(page.getByText('Mật khẩu không được để trống')).toBeVisible()
    })

    test('TC-E2E-004: Login form accessible via keyboard', async ({ page }) => {
      const loginPage = new LoginPage(page)

      await loginPage.navigate()

      // Tab đến email input
      await page.keyboard.press('Tab')
      await expect(page.getByLabel('Email')).toBeFocused()

      // Tab đến password
      await page.keyboard.press('Tab')
      await expect(page.getByLabel('Mật khẩu')).toBeFocused()

      // Tab đến submit button
      await page.keyboard.press('Tab')
      await expect(page.getByRole('button', { name: 'Đăng nhập' })).toBeFocused()

      // Press Enter to submit
      await page.getByLabel('Email').fill(TEST_USER.email)
      await page.getByLabel('Mật khẩu').fill(TEST_USER.password)
      await page.getByRole('button', { name: 'Đăng nhập' }).press('Enter')

      await expect(page).toHaveURL(/\/dashboard/)
    })
  })

  test.describe('Logout', () => {

    test.beforeEach(async ({ page }) => {
      // Login first
      const loginPage = new LoginPage(page)
      await loginPage.navigate()
      await loginPage.login(TEST_USER.email, TEST_USER.password)
      await expect(page).toHaveURL(/\/dashboard/)
    })

    test('TC-E2E-005: Logout clears session', async ({ page }) => {
      await page.getByRole('button', { name: 'Đăng xuất' }).click()

      await expect(page).toHaveURL(/\/login/)

      // Try to navigate to protected route
      await page.goto('/dashboard')
      await expect(page).toHaveURL(/\/login/)  // Should redirect back to login
    })
  })
})
```

### 4.3 Playwright Configuration

```typescript
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 4 : undefined,
  reporter: [
    ['html', { outputFolder: 'playwright-report' }],
    ['junit', { outputFile: 'test-results/e2e-results.xml' }],
    ['allure-playwright'],
  ],
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },
    {
      name: 'mobile-chrome',
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'mobile-safari',
      use: { ...devices['iPhone 14'] },
    },
  ],
})
```

## 5. Performance Testing với k6

### 5.1 Load Test Script

```javascript
// tests/performance/load-test.js
import http from 'k6/http'
import { check, sleep, group } from 'k6'
import { Counter, Rate, Trend, Gauge } from 'k6/metrics'
import { htmlReport } from 'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js'

// Custom metrics
const errorRate = new Rate('errors')
const authDuration = new Trend('auth_duration', true)
const apiDuration = new Trend('api_duration', true)

// Test configuration
export const options = {
  scenarios: {
    // Ramp-up test: gradually increase load
    ramp_up: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },   // Warm up
        { duration: '5m', target: 100 },  // Normal load
        { duration: '2m', target: 200 },  // Peak load
        { duration: '5m', target: 200 },  // Sustain peak
        { duration: '2m', target: 0 },    // Ramp down
      ],
    },
    // Spike test: sudden traffic spike
    spike: {
      executor: 'ramping-vus',
      startVUs: 50,
      stages: [
        { duration: '30s', target: 50 },
        { duration: '10s', target: 500 },  // Spike!
        { duration: '1m', target: 500 },   // Sustain spike
        { duration: '10s', target: 50 },   // Return to normal
      ],
    },
  },
  thresholds: {
    http_req_duration: [
      'p(50)<100',   // Median < 100ms
      'p(95)<500',   // 95th < 500ms
      'p(99)<1000',  // 99th < 1 second
    ],
    http_req_failed: ['rate<0.01'],  // Error rate < 1%
    errors: ['rate<0.01'],
    auth_duration: ['p(95)<300'],
    api_duration: ['p(95)<200'],
  },
}

const BASE_URL = __ENV.BASE_URL || 'https://staging.example.com'

function getAuthToken() {
  const response = http.post(`${BASE_URL}/api/v1/auth/login`, JSON.stringify({
    email: `user${__VU}@test.com`,
    password: 'TestPass123!'
  }), {
    headers: { 'Content-Type': 'application/json' }
  })

  authDuration.add(response.timings.duration)

  if (!check(response, { 'login status 200': (r) => r.status === 200 })) {
    errorRate.add(1)
    return null
  }

  errorRate.add(0)
  return JSON.parse(response.body).accessToken
}

export default function() {
  const token = getAuthToken()
  if (!token) return

  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  }

  group('User operations', () => {
    // GET user profile
    const profileRes = http.get(`${BASE_URL}/api/v1/users/me`, { headers })
    apiDuration.add(profileRes.timings.duration)
    check(profileRes, {
      'GET profile 200': (r) => r.status === 200,
      'GET profile < 200ms': (r) => r.timings.duration < 200,
    })
    errorRate.add(profileRes.status !== 200 ? 1 : 0)

    sleep(1)

    // GET paginated list
    const listRes = http.get(`${BASE_URL}/api/v1/products?page=1&limit=20`, { headers })
    apiDuration.add(listRes.timings.duration)
    check(listRes, {
      'GET products 200': (r) => r.status === 200,
      'GET products < 500ms': (r) => r.timings.duration < 500,
      'GET products has data': (r) => {
        const body = JSON.parse(r.body)
        return body.data && body.data.length > 0
      },
    })

    sleep(1)
  })
}

export function handleSummary(data) {
  return {
    'performance-report.html': htmlReport(data),
    'performance-summary.json': JSON.stringify(data),
  }
}
```

## 6. Accessibility Testing

### 6.1 axe-core Integration (Playwright)

```typescript
// tests/accessibility/a11y.spec.ts
import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

test.describe('Accessibility Audit', () => {
  test('TC-A11Y-001: Login page has no WCAG 2.1 AA violations', async ({ page }) => {
    await page.goto('/login')

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze()

    // Report violations in readable format
    if (results.violations.length > 0) {
      const violations = results.violations.map(v => ({
        id: v.id,
        impact: v.impact,
        description: v.description,
        nodes: v.nodes.map(n => n.html).slice(0, 3),
      }))
      console.log('Accessibility violations:', JSON.stringify(violations, null, 2))
    }

    expect(results.violations).toHaveLength(0)
  })

  test('TC-A11Y-002: Dashboard page has no critical violations', async ({ page }) => {
    // Login first
    await page.goto('/login')
    await page.fill('[name=email]', 'test@example.com')
    await page.fill('[name=password]', 'password')
    await page.click('[type=submit]')
    await page.waitForURL(/\/dashboard/)

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa'])
      .exclude('#third-party-widget')  // Exclude known 3rd party issues
      .analyze()

    // Only fail on critical and serious violations
    const criticalViolations = results.violations.filter(
      v => v.impact === 'critical' || v.impact === 'serious'
    )

    expect(criticalViolations).toHaveLength(0)
  })
})
```

### 6.2 Manual A11y Checklist

```markdown
## Accessibility Manual Test Checklist

### Keyboard Navigation
- [ ] Tab qua tất cả interactive elements theo logical order
- [ ] Shift+Tab reverse navigation hoạt động
- [ ] Enter/Space kích hoạt buttons và links
- [ ] Escape đóng modals/dropdowns
- [ ] Arrow keys navigate trong menus, carousels, tabs
- [ ] Không có keyboard traps (phải có escape path)

### Screen Reader Testing (VoiceOver/NVDA)
- [ ] Page title meaningful và unique
- [ ] Heading hierarchy logical (h1 → h2 → h3)
- [ ] Images có meaningful alt text
- [ ] Forms: labels, error messages được announce
- [ ] Dynamic content changes được announce (alerts, loading)
- [ ] Table headers với scope attributes

### Visual
- [ ] Focus indicator clearly visible (2px+ outline)
- [ ] Color contrast passes:
      - Normal text: >= 4.5:1
      - Large text (18pt+): >= 3:1
      - UI components: >= 3:1
- [ ] Không chỉ rely on color để convey information
- [ ] Text có thể scale tới 200% không mất content
```

## 7. Test Data Management

### 7.1 Test Fixtures

```typescript
// tests/fixtures/users.ts
export const testUsers = {
  admin: {
    email: 'admin@test.example.com',
    password: 'AdminPass123!',
    name: 'Test Admin',
    role: 'admin',
  },
  regularUser: {
    email: 'user@test.example.com',
    password: 'UserPass123!',
    name: 'Test User',
    role: 'user',
  },
  inactiveUser: {
    email: 'inactive@test.example.com',
    password: 'InactivePass123!',
    name: 'Inactive User',
    role: 'user',
    status: 'inactive',
  },
}

// Factory pattern cho tạo test data
export function createTestUser(overrides: Partial<User> = {}): User {
  return {
    id: generateTestId(),
    email: `test-${Date.now()}@example.com`,
    name: 'Test User',
    role: 'user',
    status: 'active',
    createdAt: new Date(),
    ...overrides,
  }
}

// Builders cho complex objects
export class OrderBuilder {
  private order: Partial<Order> = {}

  withUser(userId: string): this {
    this.order.userId = userId
    return this
  }

  withItems(items: OrderItem[]): this {
    this.order.items = items
    return this
  }

  withStatus(status: OrderStatus): this {
    this.order.status = status
    return this
  }

  build(): Order {
    return {
      id: generateTestId(),
      status: 'pending',
      createdAt: new Date(),
      ...this.order,
    } as Order
  }
}
```

### 7.2 Database Seeding cho Tests

```typescript
// tests/helpers/seed.ts
export async function seedTestDatabase(db: Database) {
  // Clear existing data
  await db.query('TRUNCATE users, orders, products RESTART IDENTITY CASCADE')

  // Seed users
  const [admin, user] = await Promise.all([
    db.users.create({
      email: 'admin@test.example.com',
      password: await bcrypt.hash('AdminPass123!', 10),
      role: 'admin',
      name: 'Test Admin',
    }),
    db.users.create({
      email: 'user@test.example.com',
      password: await bcrypt.hash('UserPass123!', 10),
      role: 'user',
      name: 'Test User',
    }),
  ])

  return { admin, user }
}
```

## 8. Coverage Reports và Thresholds

### 8.1 Jest Coverage Configuration

```json
// jest.config.json
{
  "coverageThresholds": {
    "global": {
      "branches": 75,
      "functions": 85,
      "lines": 80,
      "statements": 80
    },
    "src/services/**/*.ts": {
      "branches": 90,
      "functions": 90,
      "lines": 90
    },
    "src/api/security/**/*.ts": {
      "branches": 95,
      "functions": 95,
      "lines": 95
    }
  },
  "collectCoverageFrom": [
    "src/**/*.{ts,tsx}",
    "!src/**/*.d.ts",
    "!src/**/*.stories.tsx",
    "!src/index.ts"
  ]
}
```

### 8.2 Coverage Report Interpretation

```
Coverage Summary:
Statements   : 85.23% ( 1247/1463 )   ← >= 80% ✅
Branches     : 78.45% ( 456/581 )     ← >= 75% ✅
Functions    : 88.12% ( 312/354 )     ← >= 85% ✅
Lines        : 85.18% ( 1234/1449 )   ← >= 80% ✅

Uncovered lines (examples to address):
src/services/payment.service.ts | 145, 167-172
→ Investigate: Are these error paths? Add tests for them.

src/api/webhooks.controller.ts | 89-102
→ These lines need integration tests, not just unit tests.
```

## 9. Liên Kết

- QA Agent: `.cursor/agents/qa-agent.md`
- Backend testing details: `.cursor/agents/backend-dev-agent.md`
- Frontend testing details: `.cursor/agents/frontend-dev-agent.md`
- QA Testing step: `workflows/steps/07-qa-testing.md`
- Code review skill: `.cursor/skills/code-review-skill.md`
