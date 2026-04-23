---
description: Step-based auto delegation via workflow engine
---

Run end-to-end workflow orchestration for the current step using the workflow engine.

User input:
$ARGUMENTS

Execution rules:
1. Treat `$ARGUMENTS` as brainstorm topic.
2. Run this command directly:
   `bash scripts/workflow.sh brainstorm "$ARGUMENTS"`
3. If user includes `--dry-run`, `--sync`, `--wait`, or `--project`, pass them through unchanged.
4. After execution, report:
   - Current step and step name
   - Spawned roles
   - Dispatch path and expected reports path
   - Output from `bash scripts/workflow.sh release-dashboard --no-write` (at least `approval_ready`, `gate_passed`, `breaker_state`)
   - Next suggested action (`team sync`, `release-dashboard`, `gate-check`, or `approve`)
   - If breaker is not `closed`, include recovery hint:
     `bash scripts/workflow.sh team budget-reset --reason "manual recovery"`
5. Do not auto-approve any step.
