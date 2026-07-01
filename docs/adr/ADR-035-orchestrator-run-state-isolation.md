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

## Amendment — run-artifact hygiene for the event log (#run-hygiene)

**Status:** Accepted (2026-07-01) · Extends #887/#889 (the runner-side isolation
this ADR is the orchestrator analog of) and ADR-041 (flock chokepoint).

#887/#889 isolated a *runner-managed* run's state under `runs/<run_id>/`, and the
runner exports `ZBUILD_EVENTS_*` to follow that dir. Two gaps remained:

1. **Ad-hoc/unpinned emitters still defaulted to the shared global default.**
   `core/event-bus/event-bus.sh` defaulted `ZBUILD_EVENTS_DIR` to
   `${HOME}/.zbuild/state` at source time, so any invocation that sourced the
   event-bus *without* going through the runner (ad-hoc scripts, direct plugin
   tests) appended to the durable shared `events.jsonl`/`events.db`, which grows
   unbounded, and its `.lock` siblings were never reaped.
2. **A killed run left a stale `events.jsonl.lock`.** `flock` releases on fd
   close at process death, but the on-disk lock *file* lingers, and bash defers
   a `TERM` trap behind a foreground `wait`, so an exit-time cleanup is not a
   guarantee. A stale lock could make a later run's `flock -w` wait out its
   bounded window.

**Decision (additive, default-only — an explicit pin always wins):**

- **Unpinned event location → ephemeral, not global.** When *no* `ZBUILD_EVENTS_*`
  is pinned, the event-bus defaults to a process-scoped
  `${TMPDIR}/zbuild-ephemeral-events.<pid>` dir instead of the durable
  `${HOME}/.zbuild/state`. When only `ZBUILD_EVENTS_JSONL` is pinned, the dir
  (hence the SQLite mirror + lock) is *derived* from it, so a pinned jsonl never
  leaks a mirror/lock back to the global default. Engine runs are unaffected
  (the runner still pins `ZBUILD_EVENTS_*` to `runs/<run_id>/`).
- **`--no-resume` clears stale artifacts at startup.** The runner rotates the
  run's own event log + locks and clears the shared global-default
  `events.{jsonl,db}` + `.lock` files at startup. Startup-time clearing — not an
  exit-time trap — is the guarantee against a stale lock hanging a later run.
- **Best-effort trap teardown** removes the run's own `.lock` siblings on exit
  (belt-and-suspenders to the authoritative `--no-resume` clear).
- The ephemeral dir joins `cleanup.sh`'s `ZBUILD_TMPDIR_PATTERNS`
  (`zbuild-ephemeral-events.*`) so `zbuild cleanup` reaps it.

**Implementation:** `core/event-bus/event-bus.sh` (default resolution),
`core/pipeline/runner.sh` (`_runner_reset_event_artifacts`,
`_runner_clear_stale_global_event_artifacts`, `--no-resume` startup clear,
`_runner_abort_trap` lock teardown), `scripts/lib/cleanup.sh` (pattern).
Verified by `tests/integration/per-run-state-isolation-test.sh` T7–T9.
