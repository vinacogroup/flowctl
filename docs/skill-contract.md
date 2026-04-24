# Skill Contract

This document defines the frontmatter contract for `.cursor/skills/core/**/SKILL.md` and `.cursor/skills/extended/**/SKILL.md`.

## Required Fields

```yaml
---
name: code-review
description: "Structured review workflow for correctness, risk, and maintainability"
triggers: ["review", "pr", "refactor"]
when-to-use: "Use for code review requests, design checks, and pre-merge audits."
when-not-to-use: "Do not use for runtime incident triage; use incident-response/debugging skills."
estimated-tokens: 3386
version: "1.0.0"
---
```

- `name`: unique kebab-case identifier.
- `description`: one line, max 120 chars.
- `triggers`: array of at least 3 keywords.
- `when-to-use`: short guidance on valid scenarios.
- `when-not-to-use`: short guidance on exclusions.
- `estimated-tokens`: numeric estimate for body size.
- `version`: semantic version (`x.y.z`).

## Optional Fields

```yaml
prerequisites: ["gitnexus impact_analysis"]
roles-suggested: ["backend", "qa", "tech-lead"]
tags: ["quality", "review"]
```

- `prerequisites`: required tools/context before use.
- `roles-suggested`: default matching roles.
- `tags`: categorical filters.

## Validation Rules

- Frontmatter must be wrapped by `---` markers.
- Duplicate `name` values are invalid.
- Arrays must contain strings only.
- `estimated-tokens` must be `> 0`.

## Index Projection

`flowctl skills build-index` projects valid frontmatter into `.cursor/skills/INDEX.json`.
Only skills under `core/` and `extended/` are indexed.

## Authoring Notes

- Keep body content practical and executable.
- Prefer concise checklists over long prose.
- Include role-specific examples in body.
- Bump `version` when behavior changes.
