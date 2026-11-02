## test-author — pass

- changed 4 test file(s); acceptance assertions for 10 SPEC(s) from the design contract

- SPECs in the contract: 10
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-13
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-13
- tests/integration/resume-loop-state-test.sh — SPEC-7, SPEC-13
- tests/integration/resume-entry-points-test.sh — SPEC-9, SPEC-13
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: build-tests finding 1: done — added content-matching `[#1805/SPEC-3]` assertion that verifies the restored artifact carries its original payload (proving git-state restore via `_artifact_persist_restore` + `_artifact_persist_put_back`); fails on old code (file absent → empty content), passes after the fix.
- answered: build-tests finding 2: nothing to do — the `assert_contains "[#1805/SPEC-4] stderr names the missing stage (intake)"` is already tagged in the current file; finding was from an earlier version.
- answered: build-tests finding 3: nothing to do — the `[#1805/SPEC-13]` pipeline-run assertion (`assert_eq` for intake dispatched) is already present and tagged in the current file; finding was from an earlier version.
- answered: checker finding 1: done — added `assert_gt "[#1805/SPEC-13] resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)" "$_SPEC7_FIRST_ITER" "-1"` to the SPEC-13 section of `resume-loop-state-test.sh`, proving the cyclic pipeline was actually run and not merely that the fixture file contains `type: cycle`.
- answered: checker finding 1: done — added `assert_gt "[#1805/SPEC-13] cyclic stage 'cycled' dispatched…"` after the existing intake-dispatched assertion; this directly proves the cyclic stage ran, satisfying the "uses a pipeline containing a cyclic stage" half of SPEC-13 for `resume-entry-points-test.sh`.
