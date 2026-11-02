## build_test_cycle — round 2

- design: pass — design_produced
- test-author: fail — changed 2 test file(s); 3 finding(s) about its assertions still open after 2 round(s)
- build: error — router_out_of_turns
- test: fail — 7 of 11 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — plugins/tool/hydrate/plugin.sh was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
- issue-acceptance: fail — The test suite fails across 12 tests; the live dispatch-unit loop still dispatches completed stages on resume, --from-stage still re-dispatches skipped stages, the R-9 iteration-count assertion was deleted rather than fixed, and the cycle-orchestrator.sh change introduces regressions that break four unrelated cycle tests.
