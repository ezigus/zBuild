## design — fail

- the design fails 8 check(s)

- AMDR-1 is marked [done], but its evidence docs/adr/ADR-006-resume-contract.md:"3.6. is not in the code from before this change — this branch added or changed it, so it is not done yet: tag AMDR-1 [code] and give it a test
- AMDR-2 is marked [done], but its evidence docs/adr/ADR-050-prior-work-reuse-contract.md:"Resume is not in the code from before this change — this branch added or changed it, so it is not done yet: tag AMDR-2 [code] and give it a test
- BNDY-1 is marked [done], but its evidence tests/integration/resume-rehydrate-test.sh:"[#1805/BNDY-1] is not in the code from before this change — this branch added or changed it, so it is not done yet: tag BNDY-1 [code] and give it a test
- CYCL-1 is marked [done], but its evidence tests/integration/resume-rehydrate-test.sh:"[#1805/CYCL-1] is not in the code from before this change — this branch added or changed it, so it is not done yet: tag CYCL-1 [code] and give it a test
- CYCL-1 is marked [done], but its evidence tests/integration/from-stage-rehydrate-test.sh:"[#1805/CYCL-1] is not in the code from before this change — this branch added or changed it, so it is not done yet: tag CYCL-1 [code] and give it a test
- the evidence core/pipeline/runner.sh for CYCL-1 names a source file alone — add an exact piece of its text that shows the code already does it: core/pipeline/runner.sh:"run_guard()"
- the evidence core/pipeline/cycle-orchestrator.sh for CYCL-1 names a source file alone — add an exact piece of its text that shows the code already does it: core/pipeline/cycle-orchestrator.sh:"run_guard()"
- the evidence plugins/tool/hydrate/plugin.sh for CYCL-1 names a source file alone — add an exact piece of its text that shows the code already does it: plugins/tool/hydrate/plugin.sh:"run_guard()"

This try is kept as the working copy for the next run; design.md is unchanged.
