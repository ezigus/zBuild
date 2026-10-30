## build_test_cycle — round 1

- test-author: fail — changed 4 test file(s); 1 assertion(s) still do not test what their SPEC says after 2 round(s)
- build: pass — build_complete
- test: fail — 1 of 831 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — SPEC-5 (the file stopped after SPEC-4), SPEC-8 (the file stopped after SPEC-7): its test never ran on the code from before this change — an earlier step in its test file stops the file there, so it is not shown to fail on the old code
- issue-acceptance: fail — The test suite fails because `tests/unit/core-pipeline-cycle-convergence-test.sh` still asserts `ne` is a valid op (expecting `rc=0`) and now returns `rc=1` after the evaluator correctly rejects it — a file the issue's own scope grep (`grep -rln "op: *ne\b"`) would have matched, but the diff does not touch.
