# Workflow Lib Architecture

This folder contains modular building blocks for the flowctl engine.

## Module Boundaries

- `config.sh`
  - Centralized paths and runtime constants (`STATE_FILE`, `QA_GATE_FILE`, lock/idempotency files, `ROLE_POLICY_FILE`, budget policy/runtime files).
- `common.sh`
  - Shared shell helpers and output formatting (`wf_now`, `wf_today`, `wf_ensure_dir`, colors).
- `state.sh`
  - State read/write helpers and flowctl metadata helpers.
- `evidence.sh`
  - Immutable evidence manifest capture and checksum verification for step artifacts.
- `traceability.sh`
  - Append-only traceability map linking requirement, task, run metadata, evidence, and approval decisions.
- `lock.sh`
  - Concurrency control (`wf_acquire_flow_lock`, stale lock reclaim).
- `gate.sh`
  - Gate evaluation and gate report audit trail.
- `budget.sh`
  - Budget guardrails (`token/time/cost`) with soft alerts and circuit-breaker transitions (`closed/half-open/open`), correlation-ID budget metering, manual breaker reset, and budget audit events.
- `dispatch.sh`
  - Worker dispatch/collect, role session persistence (`role-sessions.json`), stream-json heartbeat capture (`heartbeats.jsonl`), correlation IDs (`workflowId/runId/step/role`), retry budget metadata, role-targeted dispatch (`--role`), role policy enforcement (`role-policy.v1.json`), and idempotency handling for role-step execution.
- `orchestration.sh`
  - Team-level orchestration commands (`team`, `brainstorm`) including runtime monitor policy classification (`transient`/`permanent`/`policy`), budget heartbeat (`% used`, `eta_to_cap`, breaker state), and recovery action routing (`recover`, `budget-reset`).
- `reporting.sh`
  - Read/report/reset commands (`summary`, `history`, `release-dashboard`, `reset`).

## Entry Point Contract

`scripts/flowctl.sh` is the only CLI entrypoint. It should:

1. load modules in dependency order (`config` first),
2. define command handlers that remain in entrypoint (if any),
3. route CLI commands to `cmd_*` functions.

## Compatibility Notes

- Phase 5.2 keeps legacy helper names as compatibility aliases.
- Aliases emit a one-time deprecation warning and forward to `wf_*`.
- New code should call only `wf_*` helpers.

## Safe Refactor Rule

Run regression suite after every structural change:

`bash test/test-workflow-tdd-regression.sh`
