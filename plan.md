# Workflow Orchestration Improvement Plan

Updated: 2026-04-23
Owner: PM Gateway (`flowctl-conduct`)

## Goal

Build a step-based agent orchestration flow where:
- PM is the only user-facing gateway
- agents spawn by role per step
- approvals are evidence-driven via QA gates
- progress can be monitored with clear operational signals

## Progress Snapshot

- Current maturity score: **10/10**
- Target maturity score: **10/10**
- Current phase: **Release-ready (DoD validated)**

## Checklist

### P0 — Must-Have Safety Controls

- [x] Add one-command flowctl entrypoint in `scripts/flowctl.sh` (`brainstorm`)
- [x] Add slash command scaffolding for `/flowctl-conduct`
- [x] Enforce step-based role delegation (`team delegate`)
- [x] Remove forced `--trust` in delegate path to avoid permission failures
- [x] Add QA gate policy file: `workflows/gates/qa-gate.v1.json`
- [x] Add explicit gate check command: `flowctl gate-check`
- [x] Block `approve` when gate fails (default fail-closed)
- [x] Keep controlled bypass: `approve --skip-gate --by "..."`
- [x] Fix argument parsing bugs in:
  - `blocker add`
  - `blocker resolve`
  - `decision`
- [x] Add gate report artifact per step (pass/fail log with timestamp)
- [x] Add idempotency key for `(runId, step, role)` to prevent duplicate side effects
- [x] Add state lock/lease to prevent race conditions across concurrent runs

### P1 — Observability & Recovery

- [x] Add role session registry file (e.g. `workflows/runtime/role-sessions.json`)
- [x] Persist `role -> chatId` and implement `create-chat` + `resume` strategy
- [x] Add `team monitor` for near-realtime progress (status, stale, blocked, done)
- [x] Parse `stream-json` events into normalized heartbeat records
- [x] Add correlation ID (`workflowId/runId/step/role`) across logs and reports
- [x] Add timeout + retry policy classes (transient vs permanent vs policy)
- [x] Add failure recovery runbook (resume, retry, rollback rules)

### P2 — Production-Grade Governance

- [x] Add policy-as-code for trust/tool permission per role
- [x] Add budget guardrails (token/time caps + circuit breaker)
  - Define budget policy spec in `workflows/policies/budget-policy.v1.json`
  - Enforce per-run caps: `max_tokens_total`, `max_runtime_seconds`, `max_cost_usd`
  - Enforce per-role caps: `max_tokens_per_role`, `max_runtime_per_role_seconds`
  - Add soft-threshold alerts at 70% and 90% budget utilization
  - Add hard-stop circuit breaker on cap breach with fail-closed step state
  - Emit budget events into runtime artifacts for audit (`budget-events.jsonl`)
  - Require explicit PM override reason for one-time budget exception
- [x] Add immutable evidence integrity checks (checksum/signature)
- [x] Add full traceability map:
  - requirement -> task -> runId -> evidence -> approval decision
- [x] Add chaos test suite for orchestration reliability
- [x] Add release dashboard summary for PM approvals

## Operational Commands

### Core

- Start or continue orchestration:
  - `flowctl brainstorm "<topic>"`
- Delegate current step roles:
  - `flowctl team delegate`
- Collect worker reports:
  - `flowctl collect`
- Monitor role runtime state:
  - `flowctl team monitor --stale-seconds 300`
- Recover failed role safely:
  - `flowctl team recover --role <role> --mode resume|retry|rollback --dry-run`
- Check gate:
  - `flowctl gate-check`
- Approve step (when gate passes):
  - `flowctl approve --by "Your Name"`
- PM release dashboard before approval:
  - `flowctl release-dashboard`

### Safety

- Dry run delegate:
  - `flowctl team delegate --dry-run`
- Controlled bypass (exception only):
  - `flowctl approve --skip-gate --by "Your Name"`
- Run TDD regression suite before major refactor:
  - `bash test/test-workflow-tdd-regression.sh`
- Run chaos reliability suite for orchestration failure modes:
  - `bash test/test-workflow-chaos.sh`
- Manual breaker recovery path:
  - `flowctl team budget-reset --reason "manual recovery"`
- Update role policy guardrails:
  - `workflows/policies/role-policy.v1.json`

## Definition of Done for 10/10

- [x] No false approvals (all approvals backed by gate + evidence)
- [x] Idempotent retries for all role-step executions
- [x] Deterministic resume behavior for persistent role sessions
- [x] Observable runtime with actionable alerts for stalls/failures
- [x] Security guardrails for trust and tool permissions
- [x] Automated regression + chaos checks integrated in release flow

## Next Action (Immediate)

- [x] Add budget policy artifact `workflows/policies/budget-policy.v1.json` with per-run and per-role caps
- [x] Add budget meter module in `scripts/workflow/lib/*` to track token/time/cost spend by correlation ID
- [x] Add circuit breaker state transitions (`open`/`half-open`/`closed`) with cooldown + manual reset path
- [x] Add `team monitor` budget view for PM heartbeat (`% used`, `eta to cap`, `breaker state`)
- [x] Add regression tests for budget cutoff, exception audit, and breaker recovery behavior
