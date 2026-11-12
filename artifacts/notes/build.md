# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 33 — All acceptance tests pass; two changes made

## Changes made this iteration

### 1. Reverted run-status-text.sh (unasked change)
- Removed the `# Append an empty code span...` comment and the
  `if [[ -n "$_out" ]]; then _rcl="$_out${_in}\`\`"; else _rcl="$_in"; fi` line
- Restored to original: `_rcl="$_out$_in"`
- Reason: descriptive-id-readers-test.sh R8 was FAILING because of this change.
  R8 expects `failed \`[#1805/DSFSTG-1]\` and \`[#1805/SPEC-2]\`` but the change
  produced `failed \`[#1805/DSFSTG-1]\` and \`[#1805/SPEC-2]\`\`\`` (extra backtick pair).
- Addresses: acceptance-gate finding 1, issue-acceptance finding 2

### 2. Removed dead skip_restore=false branch from _runner_from_stage_preflight
- Removed the `local _fsp_skip_restore="${6:-false}"` local and the
  `if ! $_fsp_skip_restore; then ... fi` block that restored artifacts from git
- Updated function comment to reflect it only verifies (restoration is done by
  _runner_resume_rehydrate before this call)
- Updated call site to remove `"$resume_mode"` as 6th argument
- Reason: skip_restore=false is dead code — the post-auto-resume guard
  (`if [[ -n "$from_stage" ]] && ! $resume_mode`) ensures the function is never reached
  when `resume_mode=false`. When `from_stage` is set and `resume_mode=false`, the guard
  fires and returns 1. When `resume_mode=true` (always at that point), `skip_restore=true`
  was passed. So `skip_restore=false` was unreachable.
- Addresses: lens-scope-code finding 1

## Verification results (this iteration)

All 5 acceptance test files pass:
- tests/integration/from-stage-rehydrate-test.sh — 35 tests
- tests/integration/resume-rehydrate-test.sh — 51 tests
- tests/integration/resume-loop-state-test.sh — 11 tests
- tests/integration/resume-entry-points-test.sh — 18 tests
- tests/unit/hydrate-stage-test.sh — 25 tests
- tests/unit/descriptive-id-readers-test.sh — 29 tests (was failing, now fixed)

## Open conflict: test finding 1 / issue-acceptance finding 1

### pipeline-resume-test.sh still fails:
"integration: --from-stage without --resume exits 1" and "says it needs --resume"
both fail.

### Why this cannot be fixed:
The test creates `status=in_progress` state with recent timestamp and runs
`--from-stage intake` WITHOUT `--resume`. It expects exit 1 (RQFROM-4).

BUT `from-stage-rehydrate-test.sh` S6 (lines 519-530) ALSO uses `--from-stage build`
WITHOUT `--resume` on `status=in_progress` and expects SUCCESS (stage.start for build,
no stage.start for intake). S6 is an ACCEPTANCE TEST.

Fixing RQFROM-4 fully (broadening the guard to fire for all states before auto-resume)
would break S6. S6 must be updated by the test-author stage to use `--resume --from-stage build`.

The issue-acceptance stage's previous rejection of "not mine" was about S5 (now fixed).
S6 was not checked. This new answer cites S6 specifically.

## Shape-floor findings 3-7
All pass locally:
- bash tests/unit/core-pipeline-template-test.sh - All 74 tests passed
- bash tests/unit/shape-floor-content-stable-test.sh - All 7 tests passed
- bash tests/unit/shape-floor-summary-plain-test.sh - All 7 tests passed
- bash tests/unit/template-simple-yaml-test.sh - All 84 tests passed
- bash tests/unit/template-resolvability-preflight-test.sh - All 26 tests passed

Golden files unchanged (git diff HEAD shows no changes to golden files).
