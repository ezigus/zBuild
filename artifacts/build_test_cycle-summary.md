## build_test_cycle — round 1

- test-author: pass — authored acceptance assertions for 6 SPEC(s) from the design contract
- build: pass — build_complete
- test: fail — 2 of 821 tests failed; the shape floor failed: missing_floor_files
- issue-acceptance: fail — The diff introduces two proven regressions — release dispatch is broken on the hard-kill (SPEC-5) exit path, and `sigterm-aborts-pipeline-test.sh` hangs for the full 480 s timeout — leaving R-4 and R-10 definitively unmet and undermining confidence in R-1 and R-3 through the same abort-trap code path.
