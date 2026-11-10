## build_test_cycle — round 1

- design: pass — design_produced
- test-author: fail — the author did not finish (router_timeout) — what it wrote is kept for the next attempt
- build: pass — build_complete
- test: fail — 1 of 887 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — DSFSTG-4: its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong
- issue-acceptance: fail — the model call failed (router_timeout) — the change was not judged
