## build_test_cycle — round 3

- test-author: pass — changed 0 test file(s); acceptance assertions for 2 SPEC(s) from the design contract
- build: pass — build_complete
- test: fail — 1 of 830 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — core/pipeline/runner.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
- issue-acceptance: fail — The test suite fails (SPEC-8 in `runner-map-parallel-stage-envelope-test.sh` is broken), and the acceptance check proved that reverting `runner.sh` to its old version leaves every remaining test green — meaning the run-stops behavior added there has no test that would catch it absent or wrong.
