---
name: security-review
description: "Security vulnerability assessment, OWASP Top 10 checking, authentication/authorization review, and security hardening. Use when reviewing code for security issues, assessing authentication flows, checking for injection vulnerabilities, auditing dependencies, or producing a security report. Trigger on 'security', 'vulnerability', 'auth', 'OWASP', 'injection', 'XSS', 'CSRF', 'pentest', 'audit'."
triggers: ["security", "vulnerability", "auth", "OWASP", "injection", "XSS", "CSRF", "pentest", "audit", "CVE"]
when-to-use: "Step 4-5 (during dev), Step 7 (QA security pass), Step 9 (pre-release). Any time auth or data handling code changes."
when-not-to-use: "Do not use for performance optimization or UX design."
prerequisites: []
estimated-tokens: 1500
roles-suggested: ["tech-lead", "backend"]
version: "1.0.0"
tags: ["security", "tech-lead", "backend"]
---
# Skill: Security Review | Tech Lead / Backend | Steps 4, 7, 9

## 1. OWASP Top 10 Checklist (2021)

| # | Vulnerability | Check |
|---|--------------|-------|
| A01 | Broken Access Control | [ ] AuthZ on every endpoint? Principle of least privilege? |
| A02 | Cryptographic Failures | [ ] Sensitive data encrypted at rest + in transit? TLS 1.2+? |
| A03 | Injection (SQL/NoSQL/OS) | [ ] All inputs parameterized/sanitized? ORM used correctly? |
| A04 | Insecure Design | [ ] Threat model exists? Business logic flaws? |
| A05 | Security Misconfiguration | [ ] Debug mode off in prod? Default creds changed? |
| A06 | Vulnerable Components | [ ] `npm audit` / `pip-audit` clean? No known CVEs? |
| A07 | Auth/Identity Failures | [ ] Brute force protection? Session management? |
| A08 | Data Integrity Failures | [ ] Dependency pinned? CI/CD pipeline signed? |
| A09 | Logging Failures | [ ] Security events logged? No sensitive data in logs? |
| A10 | SSRF | [ ] URL inputs validated? Internal network accessible? |

## 2. Authentication Review

```
Password storage:  bcrypt/argon2 (NOT md5/sha1/plain)
Session tokens:    cryptographically random, ≥ 128 bits
JWT:               short expiry (≤ 15min access), refresh token rotation
API keys:          hashed in DB, shown once at creation only
MFA:               TOTP/WebAuthn for admin roles
```

## 3. Input Validation Rules

```python
# Always validate
- Type check (expected type?)
- Range check (min/max length, value bounds?)
- Format check (regex for email, UUID, etc.)
- Whitelist allowed values when possible

# Never trust
- User-supplied file names (path traversal)
- User-supplied HTML (XSS) → sanitize or escape
- User-supplied SQL values → parameterized queries only
- User-supplied redirect URLs → whitelist domains
```

## 4. Security Report Format

```markdown
## Security Review Report — [Component/PR]
**Reviewer**: @tech-lead | **Date**: YYYY-MM-DD | **Scope**: [files/endpoints reviewed]

### Critical Issues (must fix before merge)
- [Issue]: [Description] | [File:line] | [Fix recommendation]

### High Issues (fix before release)
- [Issue]: ...

### Medium Issues (fix in next sprint)
- [Issue]: ...

### Low / Informational
- [Issue]: ...

### Passed Checks
- [x] SQL injection: parameterized queries used throughout
- [x] ...

### Overall Status: PASS / FAIL / CONDITIONAL
```

## 5. Dependency Audit Commands

```bash
# Node.js
npm audit --audit-level=high
npx snyk test

# Python
pip-audit
bandit -r src/ -ll

# Check for secrets in code
git log --all --full-history -- '*.env'
grep -r "password\s*=\|api_key\s*=" --include="*.py" --include="*.js"
```
