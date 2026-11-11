# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 28 — All acceptance tests pass, all review_lenses findings verified wrong/not-mine

## Verification results (this iteration)

All 6 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/unit/descriptive-id-readers-test.sh — 29 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 32 tests ✓
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

## Review lenses findings — all verified in-place or not-mine

### Security / Red-team findings (1 & 1): _ZBUILD_FROM_STAGE_EMIT_START cleared
Both lens-security-code finding 1 and lens-red-team-code finding 1 claim
`_ZBUILD_FROM_STAGE_EMIT_START` is never cleared in the non-from-stage startup path.
WRONG: runner.sh:2335 has `export _ZBUILD_FROM_STAGE_EMIT_START=false` in the
`if ! $resume_mode` block, right alongside `export _ZBUILD_RESUME_ACTIVE=false` at 2330.

### Correctness-code finding 1: pre-scan logic
Claims "pre-scan concludes 'all complete = all from prior iter' even when some members
completed in the current interrupted iteration." WRONG: when build=complete and test=aborted,
`_cid_nc=1` (test is not complete), so the "all complete" branch at lines 1354-1381 is never
entered. The DSCMBR-1 guard in the main loop at 1457-1483 handles it correctly.
The all-complete check only activates when `_cid_nc==0`, and within that branch the
iter-array check distinguishes scenario A (iteration completed = skip all) from
B (statuses from prior iteration = fresh dispatch).

### SRE findings (1, 2, 3): machine-readable events already present
- sre-1 (cycle_state_write_iter_start failure): cycle-orchestrator.sh:2500-2506 emits
  `eb_emit_event "state.write" "op=iter_start" ... "reason=write_failed"`. Already done.
- sre-2 (jq blob update failure): cycle-orchestrator.sh:1473-1481 emits
  `eb_emit_event "cycle.history.lost" ... "reason=blob_update_failed"`. Already done.
- sre-3 (_artifact_persist_put_back failure): runner.sh:1706-1713 emits
  `eb_emit_event "state.write" "op=put_back" ... "reason=io_error"`. Already done.

### Correctness-design finding 1: skip_until_stage/resume_mode interaction
Claims resume skip guard activates for stages after <s> in combined --resume --from-stage.
WRONG: both dispatch-unit arms do `[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`
(cycle:* arm at line 3666, stage:* arm at line 3991). Fix is in place and verified by
DSFSTG-3 test (all 32 from-stage tests pass).

### Scope-code finding 1: skip_restore=false branch reachable
Previous finding said unreachable. WRONG: the guard at lines 2210-2218 was narrowed to
fire only when `status=interrupted`. For --from-stage without --resume on a non-interrupted
run (status=in_progress or no state file), resume_mode stays false and _runner_from_stage_preflight
is called with skip_restore="false", making the git-restore branch reachable.

### Not-mine findings
- lens-security-code finding 2: pre-existing ${cyc_id//-/_} vs ${cyc_id//[^a-zA-Z0-9_-]/} gap
- lens-performance-code findings 1 & 2: optimisations outside acceptance contract
- lens-red-team-code finding 2: theoretical future risk not required by acceptance tests
- lens-correctness-code finding 2: test file, cannot change
- lens-correctness-code findings 3 & 4: defensive improvements beyond requirements
- lens-scope-code findings 2 & 3: test files, cannot change

## All prior iteration fixes (still present)

### Iteration 26 fix: _rsc_code_labels_v trailing backtick pair
Modified scripts/lib/run-status-text.sh.

### DSITER-1 guard (cycle-orchestrator.sh)
`_ZBUILD_RESUME_ACTIVE` guard wraps `_persisted_iter` read; flag consumed immediately.

### DSCMBR-1 resume_first_iter (cycle-orchestrator.sh)
`_resume_first_iter` passed from cycle orchestrator to `_cycle_iter_dispatch` → `_cycle_dispatch`.

### Security/red-team fix (_ZBUILD_FROM_STAGE_EMIT_START cleared)
runner.sh exports `_ZBUILD_FROM_STAGE_EMIT_START=false` in the `! $resume_mode` fresh-run block.

### DSFSTG-3 fix (resume_mode=false after skip_until_stage clear)
Both runner.sh cycle:* arm and stage:* arm do:
`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`

### DSFSTG-4 guard placement (Gap 12 fix)
Two-guard approach; pre-auto-resume guard fires for interrupted-status + --from-stage + no --resume.

### DSENTR-2 latest symlink auto-resume (runner.sh)
Auto-resume elif branch checks `$state_dir/latest/pipeline-state.json` when flat path absent.

### ADR amendments
- ADR-006: step 3.6 added with enforcing tests
- ADR-050: §6 boundary note and Enforced by citations added
