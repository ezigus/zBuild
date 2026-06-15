# ADR-035 — Orchestrator Run-State Isolation (scratch & pool dirs)

**Status:** Accepted (2026-06-15)
**Related:** ADR-024 (subprocess environment isolation), ADR-023 (install isolation), ADR-011 (pluggable orchestrator backends)
**Issue:** #898; the orchestrator analog of #887/#889 (per-run state isolation)

## Context

PR #889 (closes #887) isolated `~/.zbuild/state` to `runs/<run_id>/` so concurrent
`pipeline start` runs — across repos and issues — never share `pipeline-state.json`,
`artifacts/`, or `events.jsonl`. But the **orchestrator's own** working directories
were left shared, run-global:

- **Scratch** — `ZBUILD_ORCH_SCRATCH`, defaulted to a flat `~/.zbuild/state/orch`
  at *source* time in `core/orch/contract.sh` (before `run_id` exists). Work-unit
  temp files (`wu-XXXXXX`) from every run accumulate there.
- **Pool dirs** — `${TMPDIR}/zbuild-pool-<pool_id>`, created by
  `plugins/tool/orch-bash-parallel/plugin.sh`.

Both use unique names (mktemp / `pid`+nanosecond `pool_id`), so there is **no active
filename collision** between concurrent runs — the corruption class #887 fixed does
not recur here. The remaining hazards are (1) shared dirs that cannot be torn down
with a single run, accumulating cruft, and (2) unscoped cleanup/globbing over a
shared namespace — the same shape that made `core-pipeline-strategy-test.sh` flaky
under parallel dogfooding (#897). Surfaced by dogfood `run_id 20260615100734-32729`.

## Decision

Namespace the orchestrator scratch and pool dirs **per run_id**, mirroring #889's
default-only re-root (an explicit override always wins):

1. **Scratch** → `~/.zbuild/state/runs/<run_id>/orch`. The default is computed at
   **use-time** in `_strategy_orch_scratch_dir` (`core/pipeline/strategies/common.sh`),
   not at `contract.sh` source-time, because `ZBUILD_RUN_ID` is only known after the
   runner generates it (exported before any stage dispatch). `contract.sh` no longer
   bakes the flat default. Explicit `ZBUILD_ORCH_SCRATCH` overrides. Because the
   scratch now lives under `runs/<run_id>/`, #889's per-run state teardown reaps it.

2. **Pool dirs** → `${TMPDIR}/zbuild-runs/<run_id>/zbuild-pool-<pool_id>`, in
   `_orch_par_pool_dir` (bash-parallel backend) and `_orch_seq_pool_dir`
   (sequential backend) — both backends are covered. Explicit `ZBUILD_POOL_ROOT`
   overrides. Pool dirs are reaped by `orch_shutdown` (and grouped under
   `zbuild-runs/<run_id>/` so a crashed run's pools are trivially identifiable);
   they are intentionally NOT added to `cleanup.sh`'s single-level
   `ZBUILD_TMPDIR_PATTERNS` scanner — same as the pre-#898 flat `zbuild-pool-*`
   dirs, which were never in it either (no leak regression).

`run_id` falls back to `default` only if somehow unset, preserving behavior outside
a runner-managed pipeline.

## Consequences

- Concurrent runs get fully isolated orch working dirs; per-run teardown is clean.
- The scratch default moves from source-time (`contract.sh`) to use-time
  (`common.sh`) — the only reader. No other consumer depends on `contract.sh`
  setting `ZBUILD_ORCH_SCRATCH`.
- Tests that hardcoded the flat `${TMPDIR}/zbuild-pool-*` path must derive it from
  `_orch_par_pool_dir` instead (`core-orch-parallel-test.sh` updated).
- Explicit `ZBUILD_ORCH_SCRATCH` / `ZBUILD_POOL_ROOT` overrides are unaffected (every
  test that sets them keeps working).

## Verification

- `tests/unit/core-orch-run-id-isolation-test.sh` — distinct run_ids yield distinct
  scratch + pool dirs; explicit overrides win.
- `tests/unit/core-orch-parallel-test.sh` — pool layout asserted at the per-run path.
- `core-orch-contract-test`, `core-pipeline-strategy-test`, `strategy-platform-env-test`
  — unregressed.

## Implementation Notes (#898)

- `core/orch/contract.sh` — removed the source-time flat default of
  `ZBUILD_ORCH_SCRATCH`; the default is now computed at use-time (run_id is not
  known at source time).
- `core/pipeline/strategies/common.sh` — new `_strategy_orch_scratch_dir` resolves
  the scratch dir (explicit `ZBUILD_ORCH_SCRATCH`, else
  `~/.zbuild/state/runs/<run_id>/orch`); `_strategy_make_work_unit` consumes it.
- `plugins/tool/orch-bash-parallel/plugin.sh` (`_orch_par_pool_dir`) and
  `plugins/tool/orch-sequential/plugin.sh` (`_orch_seq_pool_dir`) — both root pool
  dirs at `${ZBUILD_POOL_ROOT:-${TMPDIR}/zbuild-runs/<run_id>}/zbuild-pool-<id>`.
- Tests — `tests/unit/core-orch-run-id-isolation-test.sh` (new); the unit and
  integration `core-orch-parallel-test.sh` derive the pool path via
  `_orch_par_pool_dir` instead of hardcoding the flat `${TMPDIR}/zbuild-pool-*`.
