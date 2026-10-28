## build_test_cycle — round 1

- test-author: pass — authored acceptance assertions for 12 SPEC(s) from the design contract
- build: error — router_timeout
- test: fail — 2 of 820 tests failed; the shape floor failed: missing_floor_files
- issue-acceptance: fail — The test suite reports 2 failures — a regression on the hard-kill release exit path and the persist always_run hook never entering — and the installed-tree testing required by R-4 is absent from the delivered test.
