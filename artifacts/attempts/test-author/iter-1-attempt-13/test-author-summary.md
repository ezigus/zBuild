## test-author — unusable

- changed 1 test file(s); 4 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, FRSH-1, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `grep -q "prior-run intake" <<< "$_s12_prior_artifact_content"` check tagged `[#1805/FRSH-1]` that asserts the prior-run content is not in ZBUILD_ARTIFACT_DIR after a fresh `--no-resume` run.
- answered: test-author finding 2: nothing to do — BNDY-1 is a no-code structural requirement that the file contains both resume-side (RHYD-1/RHYD-2) and fresh-run (BNDY-1) sub-cases. Both are present. A test cannot assert that another assertion coexists in the same file.
- answered: test-author finding 3: nothing to do — the design instruction for `hydrate-stage-test.sh` only requires the sentinel test for `hydrate_run`; the current test does exactly that. The resume-path proof (that `_artifact_persist_restore + _artifact_persist_put_back` are called on resume) is established by RHYD-1 in `resume-rehydrate-test.sh` via content comparison: the artifact content `"prior-run intake"` exists only on the git state branch (not disk), so its presence in ZBUILD_ARTIFACT_DIR after resume proves both functions were called.
