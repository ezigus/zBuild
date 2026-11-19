## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: not answered: test-author finding 2:** done — this is the acceptance-gate-code finding 1 that the test-author correctly escalated as "not mine" (shape-change-paths.txt is outside test-author scope). Fixed by adding DSCLA-18[no-code]: when `_test_compute_target_files` is called with `ZBUILD_TEST_CHANGED_FILES=core/claim/claim.sh`, the targeted set includes every file in `config/shape-tests.txt`. This test fails when `core/claim/claim.sh` is absent from `config/shape-change-paths.txt`, making the entry's presence testable and resolving the REACHABILITY FAIL.
