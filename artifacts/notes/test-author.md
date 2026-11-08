# test-author notes — issue #1805 (round 46)

## Status: COMPLETE

All 16 SPECs confirmed on disk with correct tags.

## Round 46 changes

### test-author finding 1 (fix: test) — DONE
Added two more assertions to `tests/integration/from-stage-rehydrate-test.sh`
in the S5 (plain `--from-stage` without `--resume`) sub-case, tagged
`[#1805/DSFSTG-1]`:

1. `assert_gt` that `cycle.start` is emitted for `cyc` (the `--from-stage`
   target) — proves the cycle stage was dispatched as the first unit.
   Before the change: no `--from-stage` support → cyc never dispatched →
   `cycle.start` absent → `_s5_cyc_starts=0` → `assert 0 > 0` → FAILS.
   After the change: cyc is the first dispatched unit → `cycle.start` emitted
   → PASSES.

2. `assert_gt` that `stage.start` is emitted for `cycled` (cyc's first cycle
   member) — confirms the cycle stage was entered and its first member started.
   Before the change: cyc not dispatched → no `stage.start` for cycled → FAILS.
   After the change: cyc dispatches cycled → `stage.start` emitted → PASSES.

Both assertions are placed after the existing S5 `skip_to_stage` ordering
assertions and before the SPEC-4 (DSFSTG-2) section.

The S3 (--resume --from-stage) sub-case already had these assertions (lines
180-186); the S5 sub-case was the gap the finding identified.

## Round 45 changes (kept)

### test-author finding 1 (previous fix attempt) — INCOMPLETE (now fixed above)
Added two sets of `pipeline.skip_to_stage` assertions to
`tests/integration/from-stage-rehydrate-test.sh`:

1. After the S3 (--resume --from-stage cyc) sub-case's existing assertions:
   - `assert_gt` pipeline.skip_to_stage event emitted (--resume path)
   - `assert_eq` no stage.start for intake after pipeline.skip_to_stage

2. After the S5 (--from-stage cyc, no --resume) sub-case's existing assertions:
   - `assert_gt` pipeline.skip_to_stage event emitted (skip_restore=false path)
   - `assert_eq` no stage.start for intake after pipeline.skip_to_stage

Both sets are tagged [#1805/DSFSTG-1]. These are now supplemented by the
cycle.start and stage.start assertions added in round 46.

### test-author finding 2 (answered: wrong) — NOT changed
The test correctly uses `stage_statuses.test = "aborted"`. The SPEC says
"persisted state records test as in-progress" as a semantic description of
"interrupted before completing", but the actual value `_cycle_state_write_member_atomic`
writes is "aborted". Using "in_progress" would test with an impossible value that
the production code never writes. The test must use the production data shape
so the skip-guard check (`stage_statuses[$s] == "complete"`) is exercised on
real values: build=complete → skipped, test=aborted → dispatched.

## Round 43 changes (kept)

### lens-correctness-code finding 2 (fix: test) — DONE
Changed `stage_statuses.test` from "in_progress" to "aborted" in the DSCMBR-1
iter=2 sub-case in `tests/integration/resume-loop-state-test.sh`.

### lens-scope-code finding 1 (fix: test) — DONE
Added S5 sub-case to `tests/integration/from-stage-rehydrate-test.sh` for
`--from-stage cyc` WITHOUT `--resume` (exercises skip_restore=false branch).

## Round 42 changes (kept)

### lens-scope-code finding 2 (fix: test) — DONE
Added write-side sub-section for [#1805/DSITER-1] in
`tests/integration/resume-loop-state-test.sh`.

## Not mine (fix: code — cannot touch implementation)
- lens-security-code findings 1-4
- lens-red-team-code findings 1-3
- lens-correctness-code finding 1 (stage_statuses not reset between iterations — code fix)
- lens-correctness-code finding 3 (%%/ trailing slash stripping — code fix)
- lens-performance-code finding 1 (double locked_state_update — code fix)
- lens-sre-code findings 1-2 (jq error silencing, missing event on failure — code fixes)
- lens-correctness-design finding 1 (pipeline.skip_to_stage in resume+from-stage — design fix)

## Failing tests from test stage (not in my scope)
- tests/unit/event-schema-emitted-coverage-test.sh — `cycle.state.write.failed` not in
  event-schema.json; this is a code-stage issue (new event type must be registered).
- tests/unit/runner-startup-preflight-test.sh — `_runner_startup_preflight_gate` call
  site not in main(); this is a code-stage issue (function renamed but call site not updated).

## All SPECs coverage (all confirmed on disk with correct tags)

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓ (S3 --resume path: cycle.start + stage.start for cycled + pipeline.skip_to_stage)
- DSFSTG-1 ✓ (S5 no-resume path: cycle.start + stage.start for cycled + pipeline.skip_to_stage)
- DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓ (read-side + write-side assertions), DSCMBR-1 ✓ (iter=2 and iter=1 scenarios), DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
