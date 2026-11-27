## build_test_cycle — round 1

- design: pass — design_produced
- test-author: fail — the author did not finish (router_timeout) — what it wrote is kept for the next attempt
- build: pass — build_complete
- test: fail — 986 of 986 tests passed; the acceptance check failed: the acceptance check failed — DSRACE-1/DSRACE-2/DSRACE-3/DSRACE-4/DSRACE-5/DSRACE-7: no assertion in the test files carries its tag — add one labelled with it; core/claim/claim.sh/plugins/claim-coordinator/github-labels/plugin.sh: no test file carries a requirement's tag, so putting it back could not be checked
- issue-acceptance: fail — judged the change against the issue: 6 requirement(s) not met or not sure
