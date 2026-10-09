# Design checkpoint — issue #1752 — REFINED (iter 4)

## Status: Refining design.md for spec-correspondence and issue-acceptance findings

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

## Spec-correspondence finding resolutions

**SPEC-6 (partial):** Test checks 6 specific things: mentions _acceptance_timeout_prefix; names scripts/lib/timeout-cmd.sh; has dated #1752 heading; states "bare timeout call is lint failure"; lint-bare-timeout.sh under Enforced by; lint-bare-timeout-test.sh under Enforced by. Spec over-promised "every timeout bound... resolves through _acceptance_timeout_prefix". Fix: reword SPEC-6 to precisely match these 6 checks.

**SPEC-9 (partial):** Test simulates the per-site bridging pattern inline (sets ZBUILD_NEGCTL_KILL_GRACE from site env var, calls helper, copies to site array). Does NOT source actual run-tests.sh/run-mutation.sh. Spec said "converted probe logic for each site" implying actual file testing. Fix: reword SPEC-9 to "simulates each site's bridging pattern (setting ZBUILD_NEGCTL_KILL_GRACE from the site's env var, calling _acceptance_timeout_prefix, capturing to the site's result array) on a gtimeout-only PATH", noting SPEC-8 structurally confirms each site uses the helper.

## issue-acceptance finding resolutions

**Finding 1 (pre-existing legacy failures):** scope-manifest-b1-regression-test.sh SPEC-5 and security-lens-test.sh both fail because they need legacy/ files excluded by ADR-059 §2. These are pre-existing and cannot be fixed in this PR. The design should note this limitation for R-6.

**Finding 2 (SC2034):** Commit 8bd73572 already fixed this by using `export ZBUILD_NEGCTL_KILL_GRACE=...` in both run-tests.sh and run-mutation.sh. The design should add a note that callers MUST export (not just assign) ZBUILD_NEGCTL_KILL_GRACE to prevent shellcheck SC2034.

## All SPECs (revised)
- SPEC-1[code]: helper on gtimeout-only PATH → _ACCEPTANCE_TOUT[0]=gtimeout (R-1, R-3)
- SPEC-2[code]: no binary → empty, returns 0 (R-1, R-3)
- SPEC-3[code]: inert_build regression (R-4)
- SPEC-4[code]: lint exits 1/0 on bare timeout / clean / allow (R-2)
- SPEC-5[no-code]: release.sh:629 allow comment (R-2)
- SPEC-6[no-code]: ADR-036 has dated #1752 amendment referencing _acceptance_timeout_prefix + timeout-cmd.sh + lint-failure statement + Enforced-by section naming both files (R-5)
- SPEC-7[code]: package.json lint script contains lint-bare-timeout.sh; live repo passes linter (R-2, R-6)
- SPEC-8[code]: structural check — each of 6 sites has _acceptance_timeout_prefix, no old inline pattern (R-1, R-2)
- SPEC-9[code]: per-site bridging simulation on gtimeout-only PATH for five non-acceptance sites (R-1, R-3)
- SPEC-10[code]: per-caller kill-grace bridge (run-tests/mutation env vars) (R-3)
