## build_test_cycle — round 1

- test-author: pass — authored acceptance assertions for 6 SPEC(s) from the design contract
- build: pass — build_complete
- test: fail — 1 of 5 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — tests/unit/run-limit-precedence-test.sh/tests/unit/run-limit-precedence-test.sh: its test does not pass on the new code — the code or the test is wrong
- issue-acceptance: fail — The test suite is red — the new SPEC-6 assertion introduced by this diff immediately fails because ADR-054 §11's body does not contain any of the required per-run-limit keywords (`max_run_s`, `wall-clock`, `per-run`, `run-level`, `run limit`), leaving both R-9 and R-10 unmet.
