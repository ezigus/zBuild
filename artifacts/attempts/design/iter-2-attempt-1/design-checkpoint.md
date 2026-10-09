# Design checkpoint — issue #1752 — REFINED (iter 3)

## Status: Writing final design.md with new SPECs for spec-coverage findings

## Key findings (confirmed)

**6 probe sites confirmed:**
1. `scripts/lib/acceptance-block.sh:359-381` — DEFINITION of `_acceptance_timeout_prefix` (moves to timeout-cmd.sh, acceptance-block.sh gets guard-source)
2. `core/router/route.sh:1046-1048` — bare inline probe (no -k) → use helper
3. `core/router/route.sh:1943-1945` — bare inline probe (no -k) → use helper  
4. `scripts/run-tests.sh:32-44` — 12-line probe with -k → use helper
5. `scripts/run-mutation.sh:121-136` — 16-line probe with -k → use helper
6. `scripts/lib/gh-automation.sh:190-200` — 6-line probe (no -k) → use helper

## Spec-coverage findings addressed

**Finding 1/3**: Added SPEC-8 — structural test that each converted file contains `_acceptance_timeout_prefix` and zero old `command -v gtimeout` inline patterns.

**Finding 2**: The inline `command -v gtimeout` pattern won't be caught by the bare-timeout lint (timeout is used as argument to `command -v`, not as a command invocation). SPEC-8 structural grep addresses this.

**Finding 4**: Added SPEC-9 — per-site regression test for the four non-acceptance-gate sites (route.sh ×2, run-tests.sh, run-mutation.sh, gh-automation.sh) on a gtimeout-only PATH environment.

**Finding 5**: Added SPEC-10 — per-caller kill-grace bridge verification: ZBUILD_TEST_KILL_GRACE for run-tests.sh, ZBUILD_MUTATION_KILL_GRACE for run-mutation.sh.

## All SPECs
- SPEC-1[code]: helper on gtimeout-only PATH → _ACCEPTANCE_TOUT=gtimeout (R-1, R-3)
- SPEC-2[code]: no binary → empty, returns 0 (R-1, R-3)
- SPEC-3[code]: inert_build regression (R-4)
- SPEC-4[code]: lint exits 1/0 on bare timeout / clean / allow (R-2)
- SPEC-5[no-code]: release.sh:629 allow comment (R-2)
- SPEC-6[no-code]: ADR-036 amendment + Enforced by (R-5)
- SPEC-7[code]: package.json wires lint-bare-timeout.sh (R-2, R-6)
- SPEC-8[code]: structural check — each of 6 sites has _acceptance_timeout_prefix, no old inline pattern (R-1, R-2)
- SPEC-9[code]: per-site regression on gtimeout-only host for non-acceptance sites (R-1, R-3)
- SPEC-10[code]: per-caller kill-grace bridge (run-tests/mutation env vars) (R-3)
