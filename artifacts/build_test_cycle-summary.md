## build_test_cycle — round 1

- test-author: fail — 2 assertion(s) still do not test what their SPEC says after 2 rounds
- build: pass — build_complete
- test: fail — 4 of 820 tests failed; the shape floor failed: missing_floor_files
- issue-acceptance: fail — `npm test` fails with four test failures — including a hard-kill exit-path regression in `runner-release-exit-paths-test.sh` that directly contradicts R-4 — `npm run lint` fails on eight new test files, R-2's critical sub-assertion is unfalsifiable, and R-5's test aborts with a bash syntax error before its end-to-end assertions run.
