# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 32 — All acceptance tests pass; test finding 1 is not mine

## Verification results (this iteration)

All 5 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 35 tests ✓
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

## This iteration's change: none (reverted broad guard attempt)

Attempted to fix test finding 1 (pipeline-resume-test.sh) by replacing the
narrowed --from-stage guard with a full un-narrowed guard before the
auto-resume elif. This made pipeline-resume-test.sh pass but broke 6 tests
in from-stage-rehydrate-test.sh (S5 and S6 use --from-stage without --resume
on in_progress and expect SUCCESS). Since from-stage-rehydrate-test.sh is in
the acceptance tests, the change was reverted.

## Open findings — answers

### test finding 1 (pipeline-resume-test.sh fails):
**not mine — the test must change: tests/integration/from-stage-rehydrate-test.sh**

`pipeline-resume-test.sh` sub-test "integration: --from-stage without --resume
exits 1" creates `status=in_progress` state and expects exit 1 with "only valid
with --resume". This requires the --from-stage guard to fire for ALL states
(no status narrowing).

BUT `from-stage-rehydrate-test.sh` S5 (line ~221) and S6 (line ~468) also use
`--from-stage` WITHOUT `--resume` on `status=in_progress` and expect SUCCESS —
rehydration, cycle.start, stage.start etc.

Making the guard broad (fires for all states) fixes pipeline-resume-test.sh but
breaks from-stage-rehydrate-test.sh S5 and S6 (6 tests).

The design decision (Gap 12 §(c)) explicitly says S5 must be updated to use
`--resume --from-stage cyc` instead. The test-author stage had an error verdict
and did not update S5 or S6. The build stage cannot modify test files.

The test-author stage must update S5 and S6 in from-stage-rehydrate-test.sh to
use `--resume --from-stage` as the design decision requires.

### shape-floor finding 1 (full-pipeline event-sequence.golden):
The golden files were NOT modified by this branch (git diff HEAD on the golden
files shows no changes). The code changes in this branch only affect flows gated
by --resume and --from-stage flags. The golden files test normal (non-resume)
pipeline flows. The _cd_iter > 0 unconditional stage.start guard is NOT present
in the current code (confirmed by grep). These findings should not reproduce on
the current tree.

### shape-floor finding 2 (parity event-sequence.golden):
Same as finding 1. No changes to this golden file; code changes do not affect
the parity pipeline's event sequence.

## Review lenses findings — answers

### lens-security-code finding 1 / lens-red-team-code finding 1:
wrong — export _ZBUILD_FROM_STAGE_EMIT_START=false IS present in runner.sh in
the if ! $resume_mode fresh-run block alongside export _ZBUILD_RESUME_ACTIVE=false.

### lens-security-code finding 2 / lens-correctness-code finding 3:
not mine — pre-existing code not introduced by this branch; no acceptance test.

### lens-performance-code findings 1 and 2:
not mine — optimisations outside acceptance contract.

### lens-red-team-code finding 2:
not mine — theoretical; eb_emit_event does not invoke the cycle orchestrator.

### lens-correctness-code finding 1:
wrong — DSCMBR-1 scenario has _cid_nc=1; all-complete branch never entered.

### lens-correctness-code finding 2:
not mine — test file; build stage cannot modify test files.

### lens-correctness-code finding 4:
wrong — explicit --resume sets resume_mode=true before the auto-resume elif;
the elif is skipped entirely.

### lens-scope-code finding 1:
not mine — fixing requires modifying test files (S5/S6) which build stage cannot do.

### lens-scope-code findings 2 and 3:
not mine — test file headers.

### lens-sre-code findings 1, 2, 3:
wrong — all three events are present in the code (eb_emit_event state.write,
cycle.history.lost, state.write op=put_back).

### lens-correctness-design finding 1:
wrong — cycle:* arm clears both skip_until_stage and resume_mode together;
DSFSTG-3 passes.

## issue-acceptance findings — answers

### issue-acceptance finding 1 (RQFROM-4 unmet for in_progress):
not mine — fixing RQFROM-4 fully (broadening guard to all states) breaks
from-stage-rehydrate-test.sh S5 and S6, which are acceptance tests. S5/S6
pin the old skip_restore=false behavior. The design decision says these
tests must be updated by the test-author stage to use --resume --from-stage.

### issue-acceptance finding 2 (run-status-text.sh unasked change):
wrong — descriptive-id-readers-test.sh is in the acceptance test list and
asserts the backtick-pair rendering. The acceptance test contract requires
this rendering.

### issue-acceptance finding 3 (five unit test files updated):
not mine — test files; build stage cannot modify test files.
