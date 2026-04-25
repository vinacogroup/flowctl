---
name: deployment
description: "Deployment strategy, CI/CD pipeline setup, infrastructure configuration, and release execution. Use when setting up deployment pipelines, configuring environments, writing Dockerfiles/K8s manifests, planning rollout strategy, or executing releases. Trigger on 'deploy', 'CI/CD', 'Docker', 'Kubernetes', 'pipeline', 'release', 'infrastructure', 'DevOps'."
triggers: ["deploy", "CI/CD", "docker", "kubernetes", "k8s", "pipeline", "release", "infrastructure", "devops", "helm"]
when-to-use: "Step 8 (DevOps), Step 9 (Release). Also Step 6 (Integration) for environment setup."
when-not-to-use: "Do not use for application-level code logic or API design."
prerequisites: []
estimated-tokens: 1300
roles-suggested: ["devops"]
version: "1.0.0"
tags: ["deployment", "devops", "infrastructure"]
---
# Skill: Deployment | DevOps Agent | Steps 6, 8, 9

## 1. Deployment Checklist (pre-deploy)

```markdown
### Code Readiness
- [ ] All tests passing (unit + integration + e2e)
- [ ] No CRITICAL/HIGH security vulnerabilities (bandit/snyk)
- [ ] Dependencies up to date (no known CVEs)
- [ ] Environment variables documented in .env.example

### Infrastructure
- [ ] DB migrations tested on staging
- [ ] Rollback plan documented
- [ ] Health check endpoint responds 200
- [ ] Resource limits set (CPU/memory)

### Observability
- [ ] Logs structured (JSON)
- [ ] Key metrics instrumented
- [ ] Alerts configured for error rate, latency, availability
- [ ] Dashboard created/updated
```

## 2. Deployment Strategies

| Strategy | Use when | Downtime | Rollback |
|----------|----------|----------|----------|
| **Rolling** | Stateless services | Zero | Slow (re-roll) |
| **Blue/Green** | Critical services | Zero | Instant (switch) |
| **Canary** | High-risk changes | Zero | Fast (reduce %) |
| **Recreate** | Dev/staging only | Yes | Fast |

Khuyến nghị default: **Rolling** cho microservices, **Blue/Green** cho monolith.

## 3. Docker Best Practices

```dockerfile
# Multi-stage build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine AS runtime
WORKDIR /app
# Run as non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=builder /app/node_modules ./node_modules
COPY . .
USER appuser
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "server.js"]
```

## 4. CI/CD Pipeline Structure

```yaml
# GitHub Actions pattern
stages:
  - lint-test:      # Fast feedback (< 5 min)
      - lint
      - unit tests
  - build:          # Build artifact
      - docker build + push
  - integration:    # Slower tests (< 15 min)
      - integration tests
      - security scan
  - staging:        # Auto-deploy to staging
      - deploy staging
      - smoke tests
  - production:     # Manual gate
      - manual approval
      - deploy production
      - health check
      - notify
```

## 5. Rollback Protocol

```bash
# Quick rollback (K8s)
kubectl rollout undo deployment/[name]

# Verify rollback
kubectl rollout status deployment/[name]

# DB rollback (if migration)
# ALWAYS test rollback script BEFORE deploy
[migration_tool] rollback --steps 1
```

**Sau rollback**: File incident report với root cause + prevention.
