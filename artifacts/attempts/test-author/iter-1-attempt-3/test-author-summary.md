## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-4, DSCLA-8
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — the unit test exercises `zbuild_claim_acquire` as a pure function; it has no runner or stage machinery, so "no stage has yet been dispatched" cannot be asserted there. The integration test covers this: `teardown-repeat-signal-test.sh`'s `[DSCLA-1/5]` assertion has the stage plugin check whether `zbuild:claimed` is in the claim store at the moment the stage runs, which fails (marker not written) if the claim was not acquired before dispatch.
- answered: test-author finding 2: done — added `# Given`, `# When`, `# Then`, and `# Cleanup` section comments to the CI sub-case (_dscla2b_*) in the DSCLA-2 block of `claim-coordinator-unit-test.sh`.
- answered: test-author finding 3: wrong — the unit test exercises `zbuild_claim_acquire`'s return value; runner.sh invocation belongs in an integration test. The "runner exits non-zero before any stage is dispatched" assertion is covered by the DSCLA-9 section in `teardown-repeat-signal-test.sh`, which starts the full runner with `zbuild:claimed` pre-populated and asserts non-zero exit and no stage marker created.
- answered: test-author finding 4: done — added an assertion in `teardown-repeat-signal-test.sh` DSCLA-5 that checks `$ZBUILD_CLAIM_STORE/$_DSCLA5_ISSUE/comment.txt` contains "finished"; fails on base code because that file is never written.
- answered: test-author finding 5: done — added the same "comment shows finished status" assertion for DSCLA-6, checking `$ZBUILD_CLAIM_STORE/$_DSCLA6_ISSUE/comment.txt`.
- answered: test-author finding 6: done — added the same "comment shows finished status" assertion for DSCLA-7, checking `$ZBUILD_CLAIM_STORE/$_DSCLA7_ISSUE/comment.txt`.
- answered: test-author finding 7: done — changed `# Restore backend` to `# Cleanup: restore previous backend and plain gh mock` in the DSCLA-8 section.
- answered: test-author finding 8: done — the spurious `print_test_results; exit "$FAIL"` between the T-series and the DSCLA assertions was removed in the previous pass; the current file has no early exit between T5 and the DSCLA section, so DSCLA-1's assertion runs on base code.
- answered: test-author finding 9: done — the `[DSCLA-5]` "absent after normal exit" assertion now gates on `_DSCLA5_PRESENT`: if the stage never confirmed `zbuild:claimed` was present (which is the case on base code), the assertion calls `assert_fail` with "was never acquired — cannot verify release"; same gate added to DSCLA-6 and DSCLA-7 for consistency.
