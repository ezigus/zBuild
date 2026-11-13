# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 35 — All acceptance tests pass; issue-acceptance findings addressed

## Changes made this iteration (iteration 35)

### issue-acceptance finding 1 — Remove extra SRE events

Removed:
- `eb_emit_event "state.write"` from `_runner_resume_rehydrate` in runner.sh
- `eb_emit_event "stage.verdict.stale_artifact"` from `_runner_from_stage_preflight` in runner.sh
- `eb_emit_event "stage.verdict.stale_artifact"` from cycle:* dispatch arm in runner.sh
- `eb_emit_event "stage.verdict.stale_artifact"` from stage:* dispatch arm in runner.sh
- `eb_emit_event "cycle.history.lost"` from DSCMBR-1 blob-update failure path in cycle-orchestrator.sh

### issue-acceptance finding 2 — Remove path-traversal guards from artifact-persist.sh

Removed the dotdot-traversal guard lines from `_artifact_persist_put_back` in
`core/state/artifact-persist.sh`. Kept only the stage-io/ exclusion (matching
original semantics).

### issue-acceptance finding 3 — Remove resume_mode save/restore around preflight gate

The original save/restore (`_pre_preflight_resume`) was designed to prevent
a spurious persona-missing failure when `--from-stage foo` is given without `--resume`.
Instead of modifying resume_mode temporarily, I added an early from-stage guard
BEFORE the preflight gate that rejects `--from-stage without --resume` immediately,
so the preflight never runs in that case. This is cleaner:
- No resume_mode mutation needed around the preflight call
- The from-stage guard fires before persona preflight can produce a spurious error
- Existing test pipeline-resume-test.sh "from-stage without --resume says it needs --resume" passes

### lens-security-code finding 1 / lens-red-team-code finding 1 — _ZBUILD_FROM_STAGE_EMIT_START

Already fixed in a previous iteration. `export _ZBUILD_FROM_STAGE_EMIT_START=false`
IS present at runner.sh line 2322 (inside the `if ! $resume_mode` block).
Answers: wrong — not reproduced.

### lens-scope-code finding 1 — skip_restore=false dead code

Already removed in a previous iteration. The `_runner_from_stage_preflight` function
has no `skip_restore` parameter. Answers: wrong — already removed.

### lens-correctness-code finding 1 — pre-scan 'all complete'

The described edge case (all stage_statuses complete from iter k-1, interrupted at
start of iter k after one member completed) is NOT covered by any acceptance test.
DSCMBR-1 test sets `stage_statuses.test = "aborted"` making `_cid_nc == 1`,
bypassing the `_cid_nc == 0` branch entirely. All 888 acceptance tests pass.
The edge case is beyond RQLOOP-1's scope (mid-round interruption).
Answers: wrong — not reproduced by acceptance tests.

## Verification results (iteration 35)

All 6 test files pass:
- tests/integration/pipeline-resume-test.sh — 23 tests
- tests/integration/from-stage-rehydrate-test.sh — 35 tests
- tests/integration/resume-rehydrate-test.sh — 51 tests
- tests/integration/resume-loop-state-test.sh — 11 tests
- tests/integration/resume-entry-points-test.sh — 18 tests
- tests/unit/hydrate-stage-test.sh — 25 tests
