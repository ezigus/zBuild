## Checkpoint — test-author, issue #1752 — ITERATION 2

### Files written
- tests/unit/timeout-cmd-helper-test.sh — DONE (SPECs 1, 2, 3, 8, 9, 10)
- tests/unit/lint-bare-timeout-test.sh — DONE (SPECs 4, 5, 6, 7)

### Iteration 2 changes
spec-correspondence found SPEC-9 partial (loop called helper 5× identically) and SPEC-6 partial (missing dated paragraph, lint-failure phrase, and Enforced-by section checks).

SPEC-9 fix: replace the generic loop with five distinct per-site tests:
- site 1 & 2 (route.sh sync/loop): use `_s9_route_sync` / `_s9_route_loop`, timeout 120
- site 3 (run-tests.sh): use `_rt_tout`, export ZBUILD_NEGCTL_KILL_GRACE bridge, timeout 480
- site 4 (run-mutation.sh): use `_mut_tout`, export ZBUILD_NEGCTL_KILL_GRACE bridge, timeout 300
- site 5 (gh-automation.sh): use `_s9_gha`, timeout 120
Each checks its site-specific variable (not _ACCEPTANCE_TOUT directly).

SPEC-6 fix: replace grep-on-content with:
1. Original checks: _acceptance_timeout_prefix, scripts/lib/timeout-cmd.sh (grep on file)
2. NEW: dated amendment paragraph (grep for date+#1752 on same line)
3. NEW: "lint failure" phrase (grep for bare.*timeout.*lint failure)
4. REPLACED: lint-bare-timeout.sh and lint-bare-timeout-test.sh now checked under ## Enforced by (using awk)

### Key verified facts
- ADR-036 line 978: `### Amendment (2026-10-09, #1752) — every timeout...` has date + #1752
- ADR-036 line 987: `A bare \`timeout\` call...is a lint failure`
- ADR-036 line 1008: `## Enforced by` followed by line 1010 with both filenames
- SPEC-9 still fails before change (timeout-cmd.sh source fails, and SPEC-8 fails first)
