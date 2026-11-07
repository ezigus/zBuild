## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: nothing to do — the SPEC (DSITER-1 Given) explicitly states `current_iter=2` represents "iter 1 completed before interruption"; the test follows the SPEC; it correctly fails on old code (ignores `current_iter`, starts at iter=1 → `assert_eq 2 1` → FAIL) and passes on new code (reads `current_iter=2`, starts at iter=2 → PASS); if the writer has a bug (correctness finding 1, fix: code), that is a code issue.
- answered: lens-correctness-code finding 3: nothing to do — same reasoning as finding 2; the DSCMBR-1 scenario also uses `current_iter=2` per the SPEC; changing to `current_iter=1` would require `_start_iter = current_iter + 1` semantics, contradicting what DSITER-1/DSCMBR-1 prescribe.
- answered: lens-scope-code finding 1: nothing to do — the DSENTR-2 sub-case (path 4, lines 425+) already uses `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`; the new latest-symlink branch IS exercised by path 4; the finding incorrectly claimed "every entry-point sub-test sets ZBUILD_STATE_FILE explicitly" — paths 1-3 do, path 4 does not.
