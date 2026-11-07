# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE — all acceptance tests pass

## Root cause of FRSH-1 failure (iteration 10)

The `[#1805/FRSH-1]` assertion in cycle-member-dispatch-events-test.sh expects 2 `stage.start` events
for cycle members on a fresh run. The test mocks `cycle_dispatch_stage` without emitting `stage.start`.
The emission was in runner.sh's `cycle_dispatch_stage` (lines 3211-3216), which the mock replaces.
Result: count=0, expected 2 → FAILS.

**Fix:** Move `stage.start` emission for cycle leaf members into `_cycle_iter_dispatch` in
cycle-orchestrator.sh, AFTER the CMBR-1 skip guard, BEFORE the `cycle_dispatch_stage` call.
Remove the duplicate emission from runner.sh's `cycle_dispatch_stage`.

**Safety:** 
- CMBR-1: skip guard fires before stage.start → complete members still skipped → CMBR-1 test passes
- ITER-1: tracking `cycle_dispatch_stage` calls → unchanged → still passes  
- FRSH-2: full integration test, runner.sh used → stage.start still emitted → still passes
- SKIP-1/DSPK-1: full integration tests → stage.start still emitted correctly → still passes
- golden files: same event count, just emitted from orchestrator instead of runner hook

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.
7. **runner.sh (ENTR-2)** — Added auto-resume via latest symlink (per-run layout discovery).
8. **runner.sh (sre-code-4)** — Added `readlink -f` failure guard: capture result into `_lr_resolved_dir`; if empty, warn and fall back to `resume_mode=false`.
9. **cycle-orchestrator.sh (CMBR-1 iteration 8)** — Added `_resume_first_iter` parameter to `_cycle_iter_dispatch`; call site passes `true` only for `iter == _start_iter && _start_iter > 1`; skip guard checks `stage_statuses[$s]` and continues if "complete".
10. **[iteration 10] cycle-orchestrator.sh + runner.sh** — Move stage.start emission for leaf cycle members into the orchestrator (before cycle_dispatch_stage call, after CMBR-1 skip guard); remove from runner.sh's cycle_dispatch_stage.
