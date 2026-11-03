## test-author — fail

- changed 4 test file(s); 4 finding(s) about its assertions still open after 2 round(s)

- SPECs in the contract: 11
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-14
- tests/integration/resume-loop-state-test.sh — SPEC-7
- tests/integration/resume-entry-points-test.sh — SPEC-9
- tests/unit/hydrate-stage-test.sh — SPEC-13
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: done — added [#1805/SPEC-13] sentinel test in hydrate-stage-test.sh; the test fails when plugin.sh is reverted to calling _hydrate_put_back inline.
- answered: test-author finding 1: nothing to do — the current file already has [#1805/SPEC-1] tags on assert_contains at lines 141-143; finding is stale from before a prior round's fix.
- answered: test-author finding 2: nothing to do — from-stage-rehydrate-test.sh lines 124-126 already carry [#1805/SPEC-3]; finding is stale.
- answered: test-author finding 3: nothing to do — from-stage-rehydrate-test.sh lines 212-214 already carry [#1805/SPEC-4]; finding is stale.
- answered: test-author finding 1: nothing to do — `[#1805/SPEC-1]` tags are already present on all `assert_contains` assertions for `_artifact_persist_restore + _artifact_persist_put_back`
- answered: checker finding 2: done — changed SPEC-1/SPEC-2 fixture to `artifact-snapshot-coverage`; SPEC-14 assertion now verifies the fixture those SPECs actually run against is cyclic
