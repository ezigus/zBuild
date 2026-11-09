## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — protected the `install_template_overlay "$S10_WORK_REPO" from-stage-combined-resume` call in from-stage-rehydrate-test.sh with `|| _s10_tpl_rc=$?`; script now continues past fixture-not-found on before-code, reaching the DSFSTG-3 assertions which then fail naturally (no events file → `assert_gt 0 0` fails).
- answered: acceptance-gate finding 1: done — the [#1805/DSFSTG-3] tag is present in from-stage-rehydrate-test.sh at lines 718, 732, 743; the fixture-guard fix above ensures the assertions are reached on before-code runs and fail there.
- answered: acceptance-gate finding 2: done — with the `install_template_overlay` guard, the script no longer exits before DSFSTG-3's assertions; on before-code the runner produces no events and `assert_gt 0 0` fails at the first DSFSTG-3 assertion.
- answered: issue-acceptance finding 1: not mine — `tests/integration/pipeline-resume-test.sh` is not in my named testfiles; removing its stale `--from-stage without --resume` assertions is a code-stage responsibility (the runner's --from-stage behavior changed and that test must be updated to match the new behavior).
- answered: lens-correctness-code finding 2: wrong — the DSCMBR-1 test sets `test="aborted"` deliberately (not "complete") to represent a member that was interrupted mid-run; "aborted" is the correct persisted status for an interrupted stage in zBuild state. The "all members complete" pre-scan branch is an edge case not covered by any named ISSUE REQUIREMENT; RQLOOP-1's specified behaviors are all covered.
- answered: lens-correctness-design finding 1: not mine — this is a design/code observation about `skip_until_stage` clearing in `runner.sh`; my output is test assertions only and I cannot touch implementation files.
