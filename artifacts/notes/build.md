# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 25 — All acceptance tests pass; pipeline-resume-test.sh fixed

## Fix applied in this iteration

**Root cause**: `tests/integration/pipeline-resume-test.sh` lines 338-340 had two stale
assertions from the old design where `--from-stage` required `--resume`:
- `assert_eq "--from-stage without --resume exits 1" "1" "$_noresume_rc"`
- `assert_contains "--from-stage without --resume says it needs --resume" ... "only valid with --resume"`

The design for #1805 changed `--from-stage` to work standalone (RQFROM-1). The runner was
already correctly fixed in a prior iteration (exits 0, runs from the named stage), but the
test file still expected exit 1.

**Fix**: Updated `pipeline-resume-test.sh` lines 309-340:
- Changed section title and print_test_section to "integration: --from-stage without --resume works standalone"
- Updated comment to describe the new behavior per RQFROM-1
- Changed `assert_eq` to expect 0 (exit 0 for standalone `--from-stage`)
- Removed the `assert_contains` for "only valid with --resume" (behavior no longer applies)

**Verified**: All 22 tests in pipeline-resume-test.sh pass after the fix.

## Prior iteration fixes (all still present in code)

### Iteration 24 fix (cycle_dispatch_stage ID fallback)
Added ID-based fallback in `cycle_dispatch_stage` (runner.sh:3282-3288): when
`resolve_stage_plugin` returns empty, try `_find_plugin_for_stage` as backward-compat lookup.
This made fresh-run tests work with mock plugins that use id-based (not role-based) matching.

### DSITER-1 guard (cycle-orchestrator.sh:2460)
`_ZBUILD_RESUME_ACTIVE` guard wraps `_persisted_iter` read; flag consumed immediately at 2470
(`_ZBUILD_RESUME_ACTIVE=false`); else branch sets `_start_iter=1`.

### DSCMBR-1 resume_first_iter (cycle-orchestrator.sh:1367+)
`_resume_first_iter` passed from cycle orchestrator to `_cycle_iter_dispatch` → `_cycle_dispatch`.
Pre-scan at 1406-1438 handles all-members-complete edge case (Scenario A vs B).

### security/red-team fix (_ZBUILD_FROM_STAGE_EMIT_START cleared)
runner.sh:2321-2325 exports `_ZBUILD_FROM_STAGE_EMIT_START=false` in the `! $resume_mode` fresh-run
block to prevent stale parent-process inheritance.

### DSFSTG-3 fix (resume_mode=false after skip_until_stage clear)
Both runner.sh:3658 (cycle:* arm) and runner.sh:3985 (stage:* arm) now do:
`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`

### scope-code finding 1 fix
Removed the guard `if [[ -n "$from_stage" ]] && ! $resume_mode` that made
`skip_restore=false` branch unreachable. `--from-stage` now works without `--resume`.

## Shape-floor golden files
- tests/golden/full-pipeline/event-sequence.golden — NOT changed by this branch (git diff empty)
- tests/golden/parity/event-sequence.golden — NOT changed by this branch (git diff empty)
- Both files verified correct by the test run (887 tests pass, shape-floor tests included)
