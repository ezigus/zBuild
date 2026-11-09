## build_test_cycle — round 1

- design: pass — design_produced
- test-author: pass — changed 0 test file(s); acceptance assertions for 17 SPEC(s) from the design contract
- build: pass — build_complete
- test: fail — 1 of 888 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — DSFSTG-3: no assertion in the test files carries its tag — add one labelled with it; DSFSTG-3 (the file stopped after DSFSTG-1): its test never ran on the code from before this change — an earlier step in its test file stops the file there, so it is not shown to fail on the old code
- issue-acceptance: fail — judged the change against the issue: 1 requirement(s) not met or not sure
