# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 27 — All acceptance tests pass, no code changes needed

## Verification results (this iteration)

All 6 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/unit/descriptive-id-readers-test.sh — 29 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 32 tests ✓
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

The previously-failing test now passes:
- tests/unit/status-row-findings-test.sh — 19 tests ✓ (W8 fixed in iteration 26)

Golden files are unchanged by this branch:
- git diff HEAD -- tests/golden/full-pipeline/event-sequence.golden → empty
- git diff HEAD -- tests/golden/parity/event-sequence.golden → empty

## Shape-floor golden file finding root cause

The previous test stage flagged the two event-sequence.golden files. This happened because:
1. W8 in status-row-findings-test.sh failed in the previous test run
2. _sf_floor_verified requires _SF_FAILED_COUNT == 0 for golden files
3. With 1 failure, golden files couldn't be verified despite being unmodified
4. W8 is now fixed (iteration 26 fix to _rsc_code_labels_v), so next full run should have 0 failures and golden files will be verified

## Acceptance-gate DSFSTG-4 finding

DSFSTG-4 is [done] per design finding 32. The base code had the guard before auto-resume.
The branch accidentally moved it (regression), Gap 12 restored it. Test correctly passes on
both base code and fixed branch code — this is the expected behavior for [done] requirements.
The acceptance gate flags [done] requirements as "can't verify" but this is expected behavior.

## All prior iteration fixes (still present)

### Iteration 26 fix: _rsc_code_labels_v trailing backtick pair
Modified scripts/lib/run-status-text.sh: append `\`\`` after last label when at least one found.
Old: `_rcl="$_out$_in"`
New: `if [[ -n "$_out" ]]; then _rcl="$_out${_in}\`\`"; else _rcl="$_in"; fi`

### DSITER-1 guard (cycle-orchestrator.sh)
`_ZBUILD_RESUME_ACTIVE` guard wraps `_persisted_iter` read; flag consumed immediately
(`_ZBUILD_RESUME_ACTIVE=false`); else branch sets `_start_iter=1`.

### DSCMBR-1 resume_first_iter (cycle-orchestrator.sh)
`_resume_first_iter` passed from cycle orchestrator to `_cycle_iter_dispatch` → `_cycle_dispatch`.

### Security/red-team fix (_ZBUILD_FROM_STAGE_EMIT_START cleared)
runner.sh exports `_ZBUILD_FROM_STAGE_EMIT_START=false` in the `! $resume_mode` fresh-run
block to prevent stale parent-process inheritance (line ~2335).

### DSFSTG-3 fix (resume_mode=false after skip_until_stage clear)
Both runner.sh cycle:* arm and stage:* arm now do:
`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`

### DSFSTG-4 guard placement (Gap 12 fix)
Two-guard approach:
1. Pre-auto-resume: fires when status=interrupted + --from-stage + no --resume (lines ~2210-2218)
2. Post-auto-resume: fires when resume_mode still false after auto-resume (lines ~2320-2324)

### DSENTR-2 latest symlink auto-resume (runner.sh)
Auto-resume elif branch checks `$state_dir/latest/pipeline-state.json` when flat path absent.

### ADR amendments
- ADR-006: step 3.6 added with enforcing tests
- ADR-050: §6 boundary note and Enforced by citations added
