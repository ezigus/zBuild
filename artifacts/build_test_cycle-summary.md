## build_test_cycle — round 1

- design: pass — design_produced
- test-author: fail — changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them
- build: pass — build_complete
- test: fail — 1 of 917 tests failed; the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, and the design names it nowhere — not in a step, a SPEC, WIRING or its text: nothing asks for this change — take it out, or name what asks for it
- issue-acceptance: fail — judged the change against the issue: 1 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for
