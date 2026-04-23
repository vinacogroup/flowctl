# Workflow Lib Architecture

This folder contains modular building blocks for the workflow engine.

## Module Boundaries

- `config.sh`
  - Centralized paths and runtime constants (`STATE_FILE`, `QA_GATE_FILE`, lock/idempotency files, `ROLE_POLICY_FILE`).
- `common.sh`
  - Shared shell helpers and output formatting (`wf_now`, `wf_today`, `wf_ensure_dir`, colors).
- `state.sh`
  - State read/write helpers and workflow metadata helpers.
- `lock.sh`
  - Concurrency control (`wf_acquire_workflow_lock`, stale lock reclaim).
- `gate.sh`
  - Gate evaluation and gate report audit trail.
- `dispatch.sh`
  - Worker dispatch/collect, role session persistence (`role-sessions.json`), stream-json heartbeat capture (`heartbeats.jsonl`), correlation IDs (`workflowId/runId/step/role`), retry budget metadata, role-targeted dispatch (`--role`), role policy enforcement (`role-policy.v1.json`), and idempotency handling for role-step execution.
- `orchestration.sh`
  - Team-level orchestration commands (`team`, `brainstorm`) including runtime monitor policy classification (`transient`/`permanent`/`policy`) and recovery action routing (`recover`).
- `reporting.sh`
  - Read/report/reset commands (`summary`, `history`, `reset`).

## Entry Point Contract

`scripts/workflow.sh` is the only CLI entrypoint. It should:

1. load modules in dependency order (`config` first),
2. define command handlers that remain in entrypoint (if any),
3. route CLI commands to `cmd_*` functions.

## Compatibility Notes

- Phase 5.2 keeps legacy helper names as compatibility aliases.
- Aliases emit a one-time deprecation warning and forward to `wf_*`.
- New code should call only `wf_*` helpers.

## Safe Refactor Rule

Run regression suite after every structural change:

`bash scripts/test-workflow-tdd-regression.sh`
