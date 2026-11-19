## build_test_cycle — round 2

- design: pass — design_produced
- test-author: pass — changed 1 test file(s); acceptance assertions for 15 SPEC(s) from the design contract
- build: error — design_steps_not_done
- test: fail — 911 of 911 tests passed; the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
- issue-acceptance: fail — judged the change against the issue: 0 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for
