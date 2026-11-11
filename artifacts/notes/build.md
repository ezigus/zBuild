# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 29 — All acceptance tests pass

## Verification results (this iteration)

All 6 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/unit/descriptive-id-readers-test.sh — 29 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 35 tests ✓ (was 32; S12 added 3 new)
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

## This iteration's fix: RQFROM-4 latest-symlink gap

**Problem**: The pre-auto-resume guard at the `--from-stage` check (which rejects `--from-stage`
without explicit `--resume`) only fires when `[[ -f "$state_file" ]]` (the flat state file
exists). When state lives under a per-run dir (`runs/<run_id>/pipeline-state.json`) and is
found via the `latest` symlink (DSENTR-2 auto-resume path), the flat state file doesn't exist,
so the guard was never reached. The `latest` symlink block would then set `resume_mode=true`
for the interrupted state, and the post-auto-resume guard didn't fire because `resume_mode`
was now `true`.

**Fix**: Added a `--from-stage` guard at the top of the `auto_resume` case inside the
`latest` symlink elif block in `main()` in `core/pipeline/runner.sh`. When `--from-stage`
is set and the `latest` symlink block detects `auto_resume` (meaning `status=interrupted`),
it now errors out with "--from-stage is only valid with --resume" and returns 1 before
setting `resume_mode=true`. This matches the behavior of the flat-file path.

## issue-acceptance findings — answers

### Finding 1 (RQFROM-4 gap): done
Added guard in `auto_resume` case of the `latest` symlink block in `main()` in runner.sh.

### Finding 2 (run-status-text.sh change not required): cannot revert
`tests/unit/descriptive-id-readers-test.sh` is an ACCEPTANCE TEST that expects the new
rendering (with trailing backtick pairs). I cannot change test files. Reverting
run-status-text.sh would break this acceptance test. The change stays.

### Findings 3-7 (test file changes): not mine — test-author owns those files
These are changes to test files in tests/unit/. I cannot modify test files.

## Review lenses findings — all verified in-place or not-mine

### Security / Red-team findings (1 & 1): _ZBUILD_FROM_STAGE_EMIT_START cleared
Both lens-security-code finding 1 and lens-red-team-code finding 1 claim
`_ZBUILD_FROM_STAGE_EMIT_START` is never cleared in the non-from-stage startup path.
WRONG: runner.sh has `export _ZBUILD_FROM_STAGE_EMIT_START=false` in the
`if ! $resume_mode` block, right alongside `export _ZBUILD_RESUME_ACTIVE=false`.

### Correctness-code finding 1: pre-scan logic
Claims "pre-scan concludes 'all complete = all from prior iter' even when some members
completed in the current interrupted iteration." WRONG: when build=complete and test=aborted,
`_cid_nc=1` (test is not complete), so the "all complete" branch is never entered.
The DSCMBR-1 guard in the main loop handles it correctly.

### SRE findings (1, 2, 3): machine-readable events already present
All three verified present in cycle-orchestrator.sh and runner.sh.

### Correctness-design finding 1: skip_until_stage/resume_mode interaction
WRONG: both dispatch-unit arms do `[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`.
Fix is in place and verified by DSFSTG-3 test.

### Scope-code finding 1: skip_restore=false branch reachable
WRONG: the guard was narrowed to fire only when `status=interrupted`. For --from-stage
without --resume on a non-interrupted run, resume_mode stays false and
_runner_from_stage_preflight is called with skip_restore="false".

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
Now extended: also fires for the latest-symlink auto-resume path (this iteration's fix).

### DSENTR-2 latest symlink auto-resume (runner.sh)
Auto-resume elif branch checks `$state_dir/latest/pipeline-state.json` when flat path absent.

### ADR amendments
- ADR-006: step 3.6 added with enforcing tests
- ADR-050: §6 boundary note and Enforced by citations added
