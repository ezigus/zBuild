# Design checkpoint — issue #1752 — COMPLETE

## Design written to /home/runner/work/_temp/zbuild-state/artifacts/design.md

## Key findings

**6 probe sites confirmed:**
1. `scripts/lib/acceptance-block.sh:359-381` — DEFINITION of `_acceptance_timeout_prefix` (moves to timeout-cmd.sh, acceptance-block.sh gets guard-source)
2. `core/router/route.sh:1046-1048` — bare inline probe (no -k) → use helper
3. `core/router/route.sh:1943-1945` — bare inline probe (no -k) → use helper  
4. `scripts/run-tests.sh:32-44` — 12-line probe with -k → use helper
5. `scripts/run-mutation.sh:121-136` — 16-line probe with -k → use helper
6. `scripts/lib/gh-automation.sh:190-200` — 6-line probe (no -k) → use helper

**Important constraints identified:**
- `plugins/agent/build/lib/summary.sh:23` uses `declare -F _acceptance_timeout_prefix` as guard sentinel for sourcing acceptance-block.sh — after the move, sentinel should be updated to a function unique to acceptance-block.sh
- Kill-grace env var mismatch: run-tests.sh uses `ZBUILD_TEST_KILL_GRACE`, run-mutation.sh uses `ZBUILD_MUTATION_KILL_GRACE`, helper uses `ZBUILD_NEGCTL_KILL_GRACE` — callers must pass the right env var
- `tests/unit/acceptance-negctl-test.sh` NC-P2/NC-P3 test `_acceptance_timeout_prefix` directly — still works after move (function still available via acceptance-block.sh guard-source)
- `scripts/release.sh:629` — bare `timeout` command call, needs `# lint-bare-timeout:allow` exemption
- `config/adr-enforcement-baseline.txt` — ADR-036 is listed; must be removed when `## Enforced by` section is added
- `scripts/lib/test-helpers.sh:374` — creates a `timeout` mock, needs exemption in lint

## Design summary
- SPEC-1[code]: gtimeout-only PATH → _ACCEPTANCE_TOUT uses gtimeout (R-1, R-3)
- SPEC-2[code]: no binary → empty array, returns 0 (R-1, R-3)
- SPEC-3[code]: inert_build regression test (R-4)
- SPEC-4[code]: lint exits 1 on bare timeout, 0 on clean, allow comment suppresses (R-2)
- SPEC-5[no-code]: release.sh:629 has allow comment (R-2)
- SPEC-6[no-code]: ADR-036 amendment + Enforced by section (R-5)
- SPEC-7[code]: package.json wires lint-bare-timeout.sh (R-2, R-6)
