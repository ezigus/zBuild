## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team finding 3: done — added CMBR-1 iter=1 sub-case in resume-loop-state-test.sh; asserts build (complete in iter=1) is NOT dispatched and test IS dispatched on resume with `_start_iter=1`; fails on current code (`_start_iter > 1` bug) and passes after fix.
- answered: lens-correctness finding 4: nothing to do — the finding is incorrect about the semantics; `zb_engine_loop_state rounds=2` gives `current_iter=2` which the test comment explicitly describes as "iter 2 in_progress = current interrupted iter"; all 882 tests pass with rounds=2 asserting `_start_iter=2 = current_iter=2`; changing to rounds=1 would assert `_start_iter=2` from `current_iter=1`, but the passing tests show code uses `_start_iter=current_iter`, so the test would fail on correct new code.
- answered: lens-red-team finding 4: done — added `assert_eq "0" "$_s12_cycled_starts"` to FRSH-1 sub-case in resume-rehydrate-test.sh; verifies cycle members do NOT emit stage.start on fresh runs; fails on current code (unconditional `iter > 0` guard fires on all runs); passes after the guard is removed or gated by `_ZBUILD_RESUME_ACTIVE`.
- answered: lens-scope finding 3: nothing to do — the FSTG-1 assertion at line 185 correctly tests the requirement that `stage.start` is emitted for `<s>`'s first cycle member; weakening to `cycle.member.dispatch.start` would allow the test to pass on incompletely-fixed code where the CMBR-1 `_start_iter > 1` bug still exists; keeping `stage.start > 0` correctly fails when only the `iter > 0` guard is removed without also fixing CMBR-1 for `_start_iter=1`.
- answered: lens-scope finding 4: nothing to do from test-author — `cycle-member-dispatch-events-test.sh` is not in my testfile list and cannot be changed by this stage.
