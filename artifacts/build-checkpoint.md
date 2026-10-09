# Build Checkpoint — Issue #1752

## Files Read
- tests/unit/timeout-cmd-helper-test.sh: acceptance tests for SPEC-1/2/3/8/9/10
- tests/unit/lint-bare-timeout-test.sh: acceptance tests for SPEC-4/5/6/7
- scripts/lib/acceptance-block.sh:340-381: _acceptance_timeout_prefix lives here (lines 359-381)
- plugins/agent/build/lib/summary.sh:23-26: guard-sources acceptance-block.sh via `declare -F _acceptance_timeout_prefix`
- scripts/run-tests.sh:30-44: inline probe block to replace
- scripts/run-mutation.sh:119-136: inline probe block to replace
- scripts/lib/gh-automation.sh:191-195: inline probe to replace (no -k flag)
- core/router/route.sh:1046-1048 and 1943-1944: two inline probe sites
- scripts/release.sh:629: bare `timeout` call
- docs/adr/ADR-036-acceptance-contract-teeth.md: needs amendment + Enforced-by section
- package.json: lint script needs lint-bare-timeout.sh appended

## Key Conclusions
1. Create scripts/lib/timeout-cmd.sh with _acceptance_timeout_prefix moved from acceptance-block.sh
2. acceptance-block.sh: remove function, add guard-source of timeout-cmd.sh
3. summary.sh guard must still work: after move, _acceptance_timeout_prefix comes from timeout-cmd.sh; summary.sh guards on `declare -F _acceptance_timeout_prefix` - this still works since acceptance-block.sh will guard-source timeout-cmd.sh which defines the function
4. route.sh: add one guard-source near top, replace 2 inline probes, use _ACCEPTANCE_TOUT array
5. run-tests.sh: bridge ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}" before helper call
6. run-mutation.sh: bridge ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_MUTATION_KILL_GRACE:-10}" before helper call
7. gh-automation.sh: needs guard-source, then _acceptance_timeout_prefix "$timeout_secs"
8. lint-bare-timeout.sh: new file - scans core/ scripts/ plugins/ for bare `timeout` word
9. release.sh:629: add # lint-bare-timeout:allow: release tooling comment
10. package.json: append && bash scripts/lib/lint-bare-timeout.sh
11. ADR-036: add dated amendment + Enforced-by section

## What's Next
- Create scripts/lib/timeout-cmd.sh
- Update acceptance-block.sh
- Update route.sh (both sites)
- Update run-tests.sh
- Update run-mutation.sh
- Update gh-automation.sh
- Create scripts/lib/lint-bare-timeout.sh
- Update release.sh
- Update package.json
- Update ADR-036
