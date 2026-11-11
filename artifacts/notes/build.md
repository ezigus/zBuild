# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 30 — All acceptance tests pass

## Verification results (this iteration)

All 6 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/unit/descriptive-id-readers-test.sh — 29 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 35 tests ✓
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

## This iteration's change: comment cleanup only

Reverted the accidental attempt to add a `--from-stage` guard to the `auto_resume)`
case of the flat-state-file block. The guard would break the DSFSTG-1 S5 acceptance
test (from-stage-rehydrate-test.sh), which uses `status=in_progress` with
`--from-stage` without `--resume` for the `skip_restore=false` branch test.

Updated the comment at the DSFSTG-4 guard to explain why `in_progress` is intentionally
allowed to bypass the interrupted-status check: the DSFSTG-1 S5 acceptance test
explicitly requires `status=in_progress` + `--from-stage` without `--resume` to WORK.

## issue-acceptance findings — answers

### Finding 1 (RQFROM-4 gap with status=in_progress):
**wrong** — The acceptance test S5 in from-stage-rehydrate-test.sh (tagged
[#1805/DSFSTG-1]) uses `status=in_progress` with `--from-stage cyc` and NO `--resume`
flag, and explicitly expects the runner to succeed (artifact restored, cycle dispatched).
Adding a guard to the `auto_resume)` case for `in_progress` breaks S5. The existing
code is correct per the acceptance test contract.

### Finding 2 (run-status-text.sh change not required):
**not mine** — `tests/unit/descriptive-id-readers-test.sh` is in the acceptance test
list and expects the new rendering. I cannot change test files. The test-author stage
modified the acceptance test to match this rendering, creating the dependency.

### Findings 3-7 (test file changes): not mine
Test files in tests/unit/ are owned by the test-author stage.

## Review lenses findings — answers

### Security finding 1 / Red-team finding 1: wrong
`export _ZBUILD_FROM_STAGE_EMIT_START=false` IS present in runner.sh at the
`if ! $resume_mode` fresh-run block, right alongside `export _ZBUILD_RESUME_ACTIVE=false`.

### Correctness-code finding 1: wrong
When build=complete and test=aborted (the DSCMBR-1 test scenario), `_cid_nc=1`
(test is not complete), so the "all complete" branch is never entered.

### SRE findings 1, 2, 3: wrong
All three machine-readable events are already present in cycle-orchestrator.sh
and runner.sh.

### Correctness-design finding 1: wrong
Both dispatch-unit arms already do
`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`.

### Scope-code finding 1: wrong
The guard is narrowed to `interrupted` status. For `--from-stage` without `--resume`
on a non-interrupted run, `resume_mode` stays false → `skip_restore=false` is reachable.

### Not-mine findings
- lens-security-code finding 2: pre-existing gap
- lens-performance-code findings 1 & 2: optimisations outside acceptance contract
- lens-red-team-code finding 2: theoretical future risk
- lens-correctness-code findings 2, 3, 4: test file or pre-existing gap
- lens-scope-code findings 2 & 3: test files

## Shape-floor findings 1 & 2: not mine
Golden files tests/golden/full-pipeline/event-sequence.golden and
tests/golden/parity/event-sequence.golden are under tests/ and are owned by the
test-author stage. I cannot modify test files.

## test finding 1 (stage-time-limit-test.sh): not reproduced
Ran tests/integration/stage-time-limit-test.sh on this tree; all 19 tests pass
including [S1]. The failure was a CI timing flake (16s vs ~20s limit), not caused
by this change.

## All prior iteration fixes (still present)

### RQFROM-4 latest-symlink guard (iteration 29)
Added guard in `auto_resume` case of `latest` symlink block to reject `--from-stage`
without explicit `--resume` when state lives under per-run directories.

### DSITER-1 guard (cycle-orchestrator.sh)
`_ZBUILD_RESUME_ACTIVE` guard wraps `_persisted_iter` read; flag consumed immediately.

### DSCMBR-1 resume_first_iter (cycle-orchestrator.sh)
`_resume_first_iter` passed from cycle orchestrator to `_cycle_dispatch`.

### DSFSTG-3 fix (resume_mode=false after skip_until_stage clear)
Both runner.sh dispatch arms do:
`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`

### DSFSTG-4 guard placement (Gap 12 fix)
Pre-auto-resume guard for interrupted-status + latest-symlink path.

### DSENTR-2 latest symlink auto-resume (runner.sh)
Auto-resume elif branch checks `$state_dir/latest/pipeline-state.json`.

### ADR amendments
- ADR-006: step 3.6 added with enforcing tests
- ADR-050: §6 boundary note and Enforced by citations added

### Security/red-team fix
runner.sh exports `_ZBUILD_FROM_STAGE_EMIT_START=false` in fresh-run block.
