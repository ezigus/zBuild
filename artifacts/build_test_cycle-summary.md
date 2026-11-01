## build_test_cycle — round 1

- design: pass — design_produced
- test-author: pass — changed 1 test file(s); acceptance assertions for 6 SPEC(s) from the design contract
- build: pass — build_complete_no_changes
- test: fail — 836 of 836 tests passed; the acceptance check failed: the acceptance check failed — plugins/tool/test/plugin.sh was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it;a test file this change added or changed is far slower than the rest of the suite
- issue-acceptance: fail — SPEC-4 is confirmed failing by the test suite — `_intake_run_inner` returns exit 0 with `outcome=pass` when the `intake.md` write fails, directly violating R2's requirement that intake exit non-zero with a reason naming the file.
