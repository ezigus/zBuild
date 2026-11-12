## build_test_cycle — round 2

- design: pass — design_produced
- test-author: error — the check that each assertion tests its SPEC could not be run (unusable)
- build: pass — build_complete_no_changes
- test: fail — 1 of 6 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — scripts/lib/run-status-text.sh was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
- issue-acceptance: fail — judged the change against the issue: 1 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for
