---
name: gitnexus-integration
description: "GitNexus workflows for impact analysis, context lookup, and safe refactoring"
triggers: ["gitnexus", "impact", "context", "refactor"]
when-to-use: "Use when modifying symbols and needing blast-radius/context before code changes."
when-not-to-use: "Do not use for non-code tasks where call-graph analysis is unnecessary."
prerequisites: ["gitnexus index up-to-date"]
estimated-tokens: 5053
roles-suggested: ["tech-lead", "backend", "frontend", "devops", "qa"]
version: "1.0.0"
tags: ["analysis", "refactoring"]
---
# Kỹ Năng Tích Hợp GitNexus
# Skill: GitNexus Git Intelligence Integration | Version: 1.0.0

## 1. Giới Thiệu GitNexus

GitNexus là công cụ git intelligence được sử dụng để enhance tất cả git operations với AI-powered intelligence. GitNexus cung cấp:
- **Smart commits**: Tự động generate descriptive commit messages từ diff
- **Branch strategy**: Intelligent branch naming và management
- **PR automation**: Generate PR descriptions, detect breaking changes
- **Code review**: Automated code analysis, security scanning, complexity check
- **Merge intelligence**: Conflict resolution suggestions, merge strategy recommendations
- **Repository insights**: Code health metrics, contribution analytics

## 2. GitNexus CLI Reference

### 2.1 Branch Operations

```bash
# Tạo branch mới với smart naming
gitnexus branch create "<description>" --from "<base-branch>"
# → Tự động suggest: feature/us-001-user-authentication

# List branches với context
gitnexus branch list --status
# → Shows: branch name, last commit, days since last commit, open PRs

# Analyze branch health
gitnexus branch health "<branch-name>"
# → Shows: divergence from base, conflicts risk, stale status

# Clean up merged branches
gitnexus branch cleanup --merged --older-than "30d"

# Get branch naming suggestion
gitnexus branch suggest "<ticket-id>" "<description>"
# → Outputs: feature/us-001-add-user-profile
```

### 2.2 Commit Operations

```bash
# Smart commit (analyzes diff to generate message)
gitnexus commit
# → Analyzes staged changes, suggests commit message following conventional commits

# Commit với specific type
gitnexus commit --type "feat" --scope "api" \
  --message "add user profile endpoint with avatar upload"

# Commit với breaking change notice
gitnexus commit --type "feat" --scope "api" \
  --message "change user ID format from integer to UUID" \
  --breaking "User ID format changed from int to UUID, requires migration"

# Batch commit (commit multiple logical changes separately)
gitnexus commit --batch
# → Interactive: groups related changes into separate commits

# Validate commit message before committing
gitnexus commit validate "<message>"
# → Returns: valid/invalid with feedback

# Show commit history in smart format
gitnexus log --format "smart" --since "1 week ago"
```

### 2.3 Pull Request Operations

```bash
# Create PR với smart description
gitnexus pr create \
  --title "<title>" \
  --base "<base-branch>" \
  --reviewers "<comma,separated,usernames>" \
  --labels "<comma,separated,labels>"

# Auto-generate PR description từ commit history
gitnexus pr describe --pr "<pr-number>"
gitnexus pr describe --auto  # Generate for current branch's pending PR

# Analyze PR before creation
gitnexus pr analyze --base "<base-branch>"
# → Shows: files changed, breaking changes, security findings, test coverage delta

# Update PR description
gitnexus pr update --pr "<pr-number>" --description "<new-description>"

# Check PR status
gitnexus pr status --pr "<pr-number>"
# → Shows: CI status, review status, conflicts, merge readiness

# List PRs with smart filtering
gitnexus pr list --status "open|review-needed|approved|blocked"

# Merge PR với strategy
gitnexus merge --pr "<pr-number>" --strategy "squash|rebase|merge"

# Close PR without merging
gitnexus pr close --pr "<pr-number>" --reason "<reason>"
```

### 2.4 Code Review Operations

```bash
# Automated review của PR
gitnexus review --pr "<pr-number>"
# → Full analysis: style, security, performance, complexity

# Review specific files
gitnexus review --files "src/api/*.ts" \
  --focus "security,performance"

# Review với specific criteria
gitnexus review --pr "<pr-number>" \
  --check "conventional-commits,test-coverage,security,performance"

# Add review comment
gitnexus review comment --pr "<pr-number>" \
  --file "<file-path>" \
  --line "<line-number>" \
  --comment "<review comment>" \
  --type "BLOCKER|IMPORTANT|SUGGESTION|NITPICK"

# Approve PR
gitnexus review approve --pr "<pr-number>" \
  --comment "<optional approval message>"

# Request changes
gitnexus review request-changes --pr "<pr-number>" \
  --comment "<what needs to change>"

# Get review summary
gitnexus review summary --pr "<pr-number>"
# → Shows: all comments grouped by file and severity
```

### 2.5 Repository Intelligence

```bash
# Code health metrics
gitnexus health
# → Shows: test coverage, complexity, duplication, dependency health

# Security scan
gitnexus security scan
# → SAST analysis: vulnerabilities, hardcoded secrets, dependency CVEs

gitnexus security scan --type "sast|dast|dependency|secrets"

# Performance analysis
gitnexus perf analyze --file "<file-path>"
# → Identifies potential performance issues

# Detect breaking changes
gitnexus breaking-changes --base "<branch>" --head "<branch>"
# → Lists: API changes, removed exports, signature changes

# Dependency analysis
gitnexus deps analyze
# → Shows: dependency tree, unused deps, outdated deps, security issues

gitnexus deps update --type "patch|minor|major" --dry-run

# Git blame intelligence
gitnexus blame "<file-path>" --lines "<start>-<end>"
# → Shows: who changed what, linked to PRs and issues

# Contribution analytics
gitnexus stats --period "sprint|month|quarter"
# → Per-agent/author: commits, PRs, reviews, code added/removed
```

### 2.6 Merge & Conflict Operations

```bash
# Smart merge với conflict suggestions
gitnexus merge "<branch>" --smart
# → Analyzes conflicts, suggests resolution strategies

# Check merge feasibility before merging
gitnexus merge check "<source>" --into "<target>"
# → Shows: conflict risk, test impact, breaking changes

# Resolve conflicts with AI assistance
gitnexus conflict resolve "<file>"
# → Suggests resolution based on intent of both changes

# Cherry-pick với context
gitnexus cherry-pick "<commit-sha>" --context
# → Explains what the commit does, confirms before applying

# Rebase với smart handling
gitnexus rebase "<base-branch>" --smart
# → Handles conflicts intelligently, maintains commit history integrity
```

## 3. GitNexus Workflow Per Step

### Step 1: Requirements Analysis

```bash
# Setup project repository nếu chưa có
gitnexus init --project-type "web-app|api|fullstack" \
  --team-size "{n}" \
  --flowctl "gitflow"

# Tạo branch cho requirements docs
gitnexus branch create "requirements analysis PRD and user stories" \
  --from "main"
# → Creates: docs/requirements-analysis-prd-and-user-stories

# Commit requirements documents
gitnexus commit --type "docs" --scope "requirements" \
  --message "add PRD v1.0 with 25 user stories"

# Commit user story updates
gitnexus commit --type "docs" --scope "requirements" \
  --message "update acceptance criteria for US-001 through US-010"

# Create PR cho review
gitnexus pr create \
  --title "docs(requirements): add PRD and user stories for {project}" \
  --base "main" \
  --reviewers "pm,tech-lead" \
  --labels "documentation,requirements,needs-review"

# Generate PR description
gitnexus pr describe --auto
```

### Step 2: System Design

```bash
# Branch cho architecture docs
gitnexus branch create "system design architecture and ADRs" \
  --from "develop"

# Commit architecture docs
gitnexus commit --type "docs" --scope "architecture" \
  --message "add system architecture design v1.0"

gitnexus commit --type "docs" --scope "adr" \
  --message "add ADR-001: choose PostgreSQL as primary database"

gitnexus commit --type "docs" --scope "api" \
  --message "add OpenAPI specification draft for all endpoints"

# Security check on design docs (check for sensitive info)
gitnexus security scan --type "secrets"

# PR
gitnexus pr create \
  --title "docs(architecture): system design and ADRs" \
  --base "develop" \
  --reviewers "tech-lead,pm" \
  --labels "architecture,design,needs-review"
```

### Step 3: UI/UX Design

```bash
# Branch cho design assets
gitnexus branch create "UI UX design system and component specs" \
  --from "develop"

# Commit design tokens
gitnexus commit --type "feat" --scope "design" \
  --message "add design tokens for colors, typography, spacing"

# Commit component specs
gitnexus commit --type "docs" --scope "design" \
  --message "add component specification for Button, Input, Modal, Table"

# PR
gitnexus pr create \
  --title "feat(design): add design system v1.0" \
  --base "develop" \
  --reviewers "ui-ux,frontend-dev,pm" \
  --labels "design,ui-ux,needs-review"
```

### Step 4: Backend Development

```bash
# Feature branches từ develop
gitnexus branch create "user authentication API endpoints" \
  --from "develop"
# → Creates: feature/user-authentication-api-endpoints

# Smart commits trong development
gitnexus commit  # Let GitNexus analyze và suggest message

# Hoặc manual commit
gitnexus commit --type "feat" --scope "auth" \
  --message "implement JWT authentication with refresh token rotation"

gitnexus commit --type "feat" --scope "api" \
  --message "add POST /api/v1/auth/login endpoint"

gitnexus commit --type "feat" --scope "api" \
  --message "add POST /api/v1/auth/logout with token blacklisting"

gitnexus commit --type "test" --scope "auth" \
  --message "add unit tests for auth service, 95% coverage"

gitnexus commit --type "feat" --scope "db" \
  --message "add migration for users and refresh_tokens tables"

# Trước khi tạo PR - analyze changes
gitnexus pr analyze --base "develop"
# → Check breaking changes, security, test coverage

# Security scan
gitnexus security scan
# → Must pass before creating PR

# Kiểm tra code quality
gitnexus health
# → Check complexity, duplication

# Tạo PR
gitnexus pr create \
  --title "feat(auth): implement JWT authentication system" \
  --base "develop" \
  --reviewers "tech-lead" \
  --labels "backend,feature,needs-review"

gitnexus pr describe --auto
# → Auto-generate description từ commit history và diff
```

### Step 5: Frontend Development

```bash
# Branch từ develop
gitnexus branch create "login page and authentication flow" \
  --from "develop"
# → Creates: feature/login-page-and-authentication-flow

# Commits
gitnexus commit --type "feat" --scope "ui" \
  --message "add LoginPage component with form validation"

gitnexus commit --type "feat" --scope "api" \
  --message "integrate auth API service with token management"

gitnexus commit --type "feat" --scope "store" \
  --message "add auth store with persist and session handling"

gitnexus commit --type "test" --scope "ui" \
  --message "add component tests for LoginPage and AuthForm"

gitnexus commit --type "perf" --scope "ui" \
  --message "optimize bundle size with code splitting for auth routes"

# Check performance impact
gitnexus perf analyze --file "src/pages/auth/"

# PR
gitnexus pr create \
  --title "feat(ui): implement login page and auth flow" \
  --base "develop" \
  --reviewers "tech-lead,ui-ux" \
  --labels "frontend,feature,needs-review,needs-design-review"
```

### Step 6: Integration Testing

```bash
# Branch cho integration fixes
gitnexus branch create "integration fixes post-testing" \
  --from "develop"

# Commit fixes tìm thấy trong integration
gitnexus commit --type "fix" --scope "api" \
  --message "fix CORS configuration for frontend origin"

gitnexus commit --type "fix" --scope "auth" \
  --message "fix token expiry timing mismatch between frontend and backend"

# Track integration test results
gitnexus commit --type "test" --scope "integration" \
  --message "add E2E tests for complete user registration flow"

# Breaking changes detection
gitnexus breaking-changes --base "main" --head "develop"
# → List any API changes that might affect frontend
```

### Step 7: QA Testing

```bash
# Branches cho bug fixes từ QA
gitnexus branch create "fix BUG-042 user profile image not saving" \
  --from "develop"
# → Creates: fix/bug-042-user-profile-image-not-saving

gitnexus commit --type "fix" --scope "api" \
  --message "fix image upload path handling for user profiles"

gitnexus commit --type "test" --scope "api" \
  --message "add regression test for image upload bug BUG-042"

# PR cho bug fixes - link đến bug report
gitnexus pr create \
  --title "fix(api): resolve user profile image upload failure" \
  --base "develop" \
  --reviewers "tech-lead,qa" \
  --labels "bug,backend,qa-verified"

# Sau khi QA verify fix
gitnexus review approve --pr "<pr-number>" \
  --comment "QA verified: BUG-042 resolved. Test TC-089 passing on staging."
```

### Step 8: DevOps Deployment

```bash
# Infrastructure branch
gitnexus branch create "setup production infrastructure" \
  --from "main"

# IaC commits
gitnexus commit --type "feat" --scope "infra" \
  --message "provision EKS cluster with 3 node groups"

gitnexus commit --type "ci" --scope "pipeline" \
  --message "add complete CI/CD pipeline with 6 stages"

gitnexus commit --type "feat" --scope "infra" \
  --message "configure monitoring stack: Prometheus, Grafana, Loki"

# Release branch preparation
gitnexus branch create "release/v1.0.0" --from "develop"

# Version bump
gitnexus commit --type "chore" --scope "release" \
  --message "bump version to 1.0.0 and update changelog"

# Production deployment PR
gitnexus pr create \
  --title "deploy: release v1.0.0 to production" \
  --base "main" \
  --reviewers "tech-lead,pm,devops" \
  --labels "deployment,production,release"

gitnexus pr describe --auto
# → Include deployment checklist, rollback plan
```

### Step 9: Review & Release

```bash
# Final merge
gitnexus merge --pr "<release-pr-number>" \
  --strategy "merge"  # Keep full history for release

# Tag release
gitnexus tag create "v1.0.0" \
  --message "Release v1.0.0: {brief description}"

# Generate release notes
gitnexus release notes \
  --from "v0.9.0" \
  --to "v1.0.0" \
  --format "markdown|github-release"

# Post-release: merge back to develop
gitnexus branch create "sync main to develop after release" \
  --from "main"
gitnexus merge "main" --into "develop" --strategy "merge"
```

## 4. Code Review Workflow với GitNexus

### 4.1 Reviewer Workflow
```bash
# 1. Get PR context
gitnexus pr status --pr "<pr-number>"
gitnexus pr describe --pr "<pr-number>"

# 2. Automated analysis
gitnexus review --pr "<pr-number>"
# → Full automated review report

# 3. Manual review nếu cần focus vào specific areas
gitnexus review --pr "<pr-number>" \
  --focus "security,performance,architecture"

# 4. Add targeted comments
gitnexus review comment --pr "<pr-number>" \
  --file "src/api/auth.service.ts" \
  --line "45" \
  --comment "[BLOCKER] This token comparison is vulnerable to timing attacks. Use crypto.timingSafeEqual() instead." \
  --type "BLOCKER"

gitnexus review comment --pr "<pr-number>" \
  --file "src/api/user.service.ts" \
  --line "123" \
  --comment "[SUGGESTION] Consider caching this user lookup since it's called frequently." \
  --type "SUGGESTION"

# 5. Final review decision
# If everything looks good:
gitnexus review approve --pr "<pr-number>" \
  --comment "LGTM. Well-structured code with good test coverage. One nitpick resolved."

# If changes needed:
gitnexus review request-changes --pr "<pr-number>" \
  --comment "Please address the BLOCKER comments before re-review."

# 6. After changes are made, re-review
gitnexus review --pr "<pr-number>" --only-changed
# → Review only changed files since last review
```

### 4.2 Author Response Workflow
```bash
# Check review comments
gitnexus review summary --pr "<pr-number>"

# Address each comment
# Make changes locally...
gitnexus commit --type "fix" --scope "<scope>" \
  --message "address review: use timingSafeEqual for token comparison"

# Push updates
git push

# Mark comments as resolved (hoặc respond)
gitnexus review resolve --pr "<pr-number>" \
  --comment-id "<id>" \
  --response "Fixed by using crypto.timingSafeEqual() in commit abc1234"

# Request re-review
gitnexus pr update --pr "<pr-number>" \
  --ready-for-review \
  --comment "All BLOCKER and IMPORTANT comments addressed. Ready for re-review."
```

## 5. Smart Commit Message Examples

### feat commits
```bash
# Backend feature
gitnexus commit --type "feat" --scope "api" \
  --message "add user profile management endpoints

Implements CRUD operations for user profiles:
- GET /api/v1/users/profile - get current user profile
- PUT /api/v1/users/profile - update profile fields
- POST /api/v1/users/profile/avatar - upload avatar image

Closes US-023"

# Frontend feature
gitnexus commit --type "feat" --scope "ui" \
  --message "implement dashboard analytics widgets

Add 4 real-time analytics widgets:
- Active users counter
- Revenue chart (7-day sparkline)
- Recent activity feed
- System health indicators

All widgets use React Query for data fetching with 30s refresh."
```

### fix commits
```bash
gitnexus commit --type "fix" --scope "auth" \
  --message "fix refresh token not invalidated on logout

Previously, refresh tokens were stored but not blacklisted on logout,
allowing reuse of expired sessions.

Fix: Add token to Redis blacklist on logout with TTL matching token expiry.

Fixes BUG-031"
```

### Breaking changes
```bash
gitnexus commit --type "feat" --scope "api" \
  --message "change pagination from page/limit to cursor-based

BREAKING CHANGE: The pagination API has changed from page/limit model
to cursor-based pagination for better performance with large datasets.

Before: GET /api/v1/items?page=2&limit=20
After:  GET /api/v1/items?cursor=<base64>&limit=20

Response now includes 'nextCursor' instead of 'totalPages'.
Frontend must be updated to use new cursor pagination model.

Implements ADR-007"
```

## 6. GitNexus Hooks và Automation

### 6.1 Pre-commit Hooks (Auto-configured by GitNexus)
```bash
# GitNexus tự động cài đặt:
# - Commit message linting (conventional commits)
# - Secret scanning (block commits với secrets)
# - Large file detection (> 10MB)

# Cấu hình
gitnexus hooks configure \
  --commit-msg "conventional-commits" \
  --pre-commit "lint-staged,secret-scan" \
  --pre-push "tests"
```

### 6.2 GitNexus CI Integration
```yaml
# GitHub Actions với GitNexus
- name: GitNexus Analysis
  uses: gitnexus/action@v2
  with:
    token: ${{ secrets.GITNEXUS_TOKEN }}
    checks: |
      conventional-commits
      breaking-changes
      security
      test-coverage
    comment-on-pr: true
    fail-on: "BLOCKER"
```

## 7. Repository Health Monitoring

```bash
# Weekly health check
gitnexus health --full-report

# Output bao gồm:
# - Test coverage trend (last 4 weeks)
# - Complexity trend
# - Dependency health
# - Open PR age (identify stale PRs)
# - Security findings
# - Code duplication trend

# Technical debt report
gitnexus debt report --period "sprint"
# → Shows technical debt items, estimated fix effort

# Security dashboard
gitnexus security dashboard
# → All open security findings với severity và age

# Dependency update suggestions
gitnexus deps update --dry-run
# → Safe updates (patch level): auto-approve candidates
# → Minor/major updates: require manual review
```

## 8. GitNexus Tips và Best Practices

### 8.1 Atomic Commits
```bash
# GOOD: Một commit, một logical change
gitnexus commit --type "feat" --scope "api" \
  --message "add email validation to user registration"

# BAD: Nhiều unrelated changes trong một commit
# → Use gitnexus commit --batch để tách ra
```

### 8.2 Informative PR Titles
```bash
# GOOD: Clear type, scope, và description
"feat(auth): implement OAuth 2.0 Google login integration"
"fix(api): resolve N+1 query in user profile endpoint"
"perf(db): add composite index for order search queries"

# BAD: Vague titles
"fix bug"
"update code"
"WIP"
```

### 8.3 Branch Hygiene
```bash
# Check stale branches regularly
gitnexus branch list --stale --older-than "14d"

# Clean up after PR merge
gitnexus branch cleanup --merged --dry-run
gitnexus branch cleanup --merged  # Actually delete after review
```

### 8.4 Tag Strategy
```bash
# Semantic versioning tags
gitnexus tag create "v{major}.{minor}.{patch}"
# v1.0.0 = major release
# v1.1.0 = new feature(s)
# v1.1.1 = bug fix(es)
# v1.1.1-beta.1 = pre-release
```
