# Skill Catalog

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
