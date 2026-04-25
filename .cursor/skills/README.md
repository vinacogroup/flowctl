# Skill Catalog

## Core Skills

| Skill | Roles | Steps |
|-------|-------|-------|
| `code-review` | tech-lead, backend, frontend, qa | 4-8 |
| `documentation` | all | all |
| `testing` | backend, frontend, qa | 4-7 |
| `gitnexus-integration` | tech-lead, backend, frontend, devops, qa | 4-8 only |
| `graphify-integration` | pm, tech-lead, ui-ux | all (nếu graph > 10 nodes) |
| `requirement-analysis` | pm | 1 |
| `api-design` | backend, tech-lead | 2, 4 |
| `architecture-decision` | tech-lead | 2 |
| `debugging` | backend, frontend, devops, qa | 4-8 |
| `deployment` | devops | 6, 8, 9 |
| `ux-research` | ui-ux | 3 |
| `security-review` | tech-lead, backend, devops, qa | 4, 7, 9 |

## Skill-Guard Rule
Mỗi agent chỉ được load skills nằm trong `## Skills Available` của agent file đó.
Xem `.cursor/agents/<role>-agent.md` để biết danh sách cho từng role.

## Layout

- `core/<name>/SKILL.md`: foundational skills shipped with flowctl.
- `extended/<name>/SKILL.md`: optional/specialized skills.
- `INDEX.json`: generated metadata catalog.

## Commands

- `flowctl skills build-index`
- `flowctl skills lint`
- `flowctl skills list`
- `flowctl skills search "<query>"`
- `flowctl skills load <name>`

## Author Checklist

1. Create `SKILL.md` under `core/` or `extended/`.
2. Add valid frontmatter (see `docs/skill-contract.md`).
3. Run `flowctl skills lint`.
4. Run `flowctl skills build-index`.
5. Verify `flowctl skills search` and `flowctl skills load`.

## Notes

- Indexing ignores legacy files in `.cursor/skills/` root.
- Only `core/` and `extended/` are considered source of truth.
