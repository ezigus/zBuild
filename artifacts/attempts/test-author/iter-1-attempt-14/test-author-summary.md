## test-author — unusable

- changed 2 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, FRSH-1, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added nested-loop re-entry sub-test (clause 2b) to resume-loop-state-test.sh; calls cycle_orchestrator_run without manually clearing `_ZBUILD_RESUME_ACTIVE`, asserts first dispatched iter == 1, fails if implementation does not consume the flag after outer resume use
- answered: test-author finding 2: done — added `assert_eq "[#1805/FRSH-1] fresh run (--no-resume) dispatches all stages from stage 1 (intake dispatched; did not skip to a later stage due to prior state)" "1" "$_s12_intake_starts"` after the BNDY-1 assertion in resume-rehydrate-test.sh
- answered: test-author finding 3: nothing to do — BNDY-1 is a no-code structural requirement that the file contains both sides; both are present (RHYD-1/RHYD-2 assertions at top, BNDY-1 fresh-run sub-case with --no-resume); a test cannot assert that another assertion coexists in the same file — the structural property is satisfied by the file's content
- answered: test-author finding 4: nothing to do — the design instruction for hydrate-stage-test.sh only requires a sentinel test for hydrate_run (which is present and correct); the resume-rehydration path calling `_artifact_persist_put_back` is established by RHYD-1 in resume-rehydrate-test.sh (content `"prior-run intake"` from the git state branch appears in ZBUILD_ARTIFACT_DIR after resume — impossible without both `_artifact_persist_restore` and `_artifact_persist_put_back`)
