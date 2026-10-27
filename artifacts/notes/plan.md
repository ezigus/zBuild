# Plan notes — issue #1801

## Reading the issue

Issue: stage timeouts silently stop applying — fallback orchestrator ignores --timeout, hung stage reports success.

### Already done (do not rebuild)
- Whole-stage `timeout_s:` per stage in templates (ADR-063 amendment), enforced in `plugin_hook_call` via lifecycle.sh watchdog.
- `stage_timeout_s` / `ZBUILD_STAGE_TIMEOUT_S` superseded — do not touch.

### Problems still present
1. `orch-sequential` ignores `--timeout`; `orch_load_backend` silently falls back to it when backend not found; `_orch_load_backend` defaults to sequential when config unreadable, discards warning. No `backend.degraded` event.
2. Strategies (`_strategy_run_map`, `_fanout`, `_sequential`) pass `orch_collect --timeout "${ZBUILD_ORCH_TIMEOUT:-300}"` — cuts off stages whose `timeout_s:` is > 300 s.
3. `_runner_dispatch_always_run` reads `router.timeout_s` (fallback `ZBUILD_RELEASE_TIMEOUT:-30`) as a whole-stage bound for teardown stages — wrong; should use `timeout_s:`.
4. Hand-rolled TERM→2s→KILL in `_runner_dispatch_always_run`; hand-rolled TERM/0.5s/KILL in `_orch_local_kill_slot`; `zbuild_pg_kill` exists as shared helper and should be used.

### Decisions (binding)
1. `orch-sequential` is retired — plugin dir + golden deleted; no built-in lookup; sequential/orch-sequential treated as unknown.
2. Missing or unreadable backend → `misconfigured` hard error naming backend. No fallback.
3. No flat collect deadline — strategies drop `ZBUILD_ORCH_TIMEOUT`; `timeout_s:` is the only limit.
4. `router.timeout_s` bounds one model call only. `always_run` stages use `timeout_s:` (30s/120s in shipped templates).
5. Kill via `zbuild_pg_kill` in both places.

## Plan structure: 15 steps

Original 13 steps, updated for test-stage open findings, plus 2 new steps; updated again for design-stage findings.

### Changes from prior plan

**Step 3 modified**: Add `.github/issues/keepers-manifest.yaml` to areas — the guard test named it as still
referencing orch-sequential. Also `tests/integration/orch-backend-misconfigured-test.sh` (a new
test file) contains an orch-sequential reference and must be cleaned.

**Step 6 modified**: The test must check timed_out propagation for all three strategies (map, fanout,
sequential-strategy), not only fanout — test-author finding 1. The variable that must be checked is
`_ORCH_COLLECT_OUTCOME` from the collect call.

**Step 7 modified (test stage)**: The strategy implementation must set `_ZB_STRATEGY_OUTCOME=timed_out` (not
`failed`) when the collect call returns a timed_out outcome via `_ORCH_COLLECT_OUTCOME`. The test
failure message was: "got '<empty>'; old code passes collect_rc=1 → _ZB_STRATEGY_OUTCOME=failed" —
meaning the implementation maps collect_rc=1 to failed, but must read _ORCH_COLLECT_OUTCOME first.

**Step 8 modified**: The test must separately verify release at 30s AND persist at 120s as two hung-
stage scenarios — test-author finding 2.

**Step 9 modified**: The runner regression shows the always_run dispatch changes broke pre-existing
tests (`always-run-exit-paths-test.sh` SPEC-5: a 60s release hook held the exit; `runner-release-
exit-paths-test.sh` SPEC-5: cleanup not dispatched). The fix must correctly route always_run dispatch
to use timeout_s: without breaking the dispatch of cleanup stages for prior pipeline stages.

**Step 2 modified**: Deleting `orch-sequential-test.sh` must be confirmed safe by checking whether
the behaviors it asserted are now covered by other tests — test-author finding 3.

**NEW step 13**: Fix `set -e` mid-file lint violations in `orch-timeout-applies-test.sh`
(8 occurrences), `orch-backend-misconfigured-test.sh` (2 occurrences), and
`orch-kill-uses-pg-kill-guard-test.sh` (1 occurrence) — replace with `cmd || rc=$?` pattern.

**NEW step 14**: Fix the `core/pipeline/runner.sh` regression that broke 14+ integration tests
(happy path exits 0; always-run dispatch; cleanup dispatch; pipeline.end not emitted; stage manifests
contract broken). These all trace to the step 9 build changes to runner.sh.

**Old step 13** (npm test + lint green) becomes **step 15**.

### Changes from design stage

**Step 3 modified (design)**: SPEC-11 requires adding a NEW pool isolation assertion tagged
`[#1801/SPEC-11]` to `plugins/tool/orch-mock/tests/orch-mock-test.sh` (not just migrating existing
tests). SPEC-12 requires updating 5 additional test files that iterate or assert on orch-sequential
behavior: `tests/unit/adr059-no-tmpdir-defaults-test.sh`, `tests/unit/core-orch-run-id-isolation-test.sh`,
`tests/unit/dispatch-rc-guard-test.sh`, `tests/unit/stdin-spawn-guard-test.sh`,
`tests/unit/summary-mandatory-test.sh`. These are now added to step-3's areas and description.
Two golden event-sequence files added to areas in case pipeline-event changes from deletion land there.

**Step 7 modified (design)**: Original plan said "remove ZBUILD_ORCH_TIMEOUT argument from collect
calls." Design requires REPLACING it with `template_stage_time_limit "$stage"`. Simply removing the
argument would prevent `orch_collect` from ever emitting `_ORCH_COLLECT_OUTCOME=timed_out`, breaking
SPEC-1. The stage's declared timeout_s: (default 900 s) is passed instead of the flat 300 s cap.
`scripts/lib/stage-time-limit.sh` added to step-7's areas since strategies must source it.

**Step 9 modified (design)**: `tests/unit/exit-path-teardown-budget-guard-test.sh` added to areas.
Its SPEC-1 and SPEC-3 assertions grep for the variable renamed from `ZBUILD_RELEASE_TIMEOUT` to
`_SPEC5_STAGE_TIMEOUT` in `runner-release-exit-paths-test.sh`; without updating the guard test,
the budget guard breaks on the rename. The step-9 description now names this update explicitly.

### Open questions
None.

## Acceptance criteria mapping (updated)

- [AC1] hung stage ends timed_out → steps 6+7
- [AC2] stage > 300s completes → steps 6+7
- [AC3] orch-sequential gone, guard test, SPEC-11 pool isolation → steps 2+3
- [AC4] missing/unreadable backend → misconfigured, from installed tree → steps 4+5
- [AC5] release/persist bounded by timeout_s: → steps 8+9
- [AC6] kill through zbuild_pg_kill, no orphans → steps 10+11
- [AC7] scope discovery → step 1
- [AC8] ADR-011, ADR-017 Enforced by → step 12
- [AC9] npm test + lint green → step 15
