# Test author notes — Issue #1801

## Summary of work
Round 20 — Checker round 2 fix: added [#1801/SPEC-5] hard-kill assertion; also
fixed SPEC-4/SPEC-10 e2e ZBUILD_PLUGINS_ROOT environment so tests are self-contained.

## Changes made in this round

### 1. runner-release-exit-paths-test.sh — [#1801/SPEC-5] hard-kill path assertion

Checker finding (round 2): "none of the tagged lines test the pre-existing [SPEC-5]
(#1829) hard-kill exit path cleanup assertion that the requirement explicitly mandates
must also pass."

Added after `_assert_released "SPEC-5" intake build` in the SPEC-5 hard-kill section
(inside the `else` block, before the closing `fi`):

```bash
_hk_marker="$(cat "$RELEASE_MARKER" 2>/dev/null || true)"
if grep -q '^intake:release$' <<< "$_hk_marker" && \
   grep -q '^build:release$'  <<< "$_hk_marker"; then
    assert_pass "[#1801/SPEC-5] hard-kill path: EXIT trap dispatched cleanup for intake and build"
else
    assert_fail "[#1801/SPEC-5] hard-kill path: EXIT trap must dispatch cleanup for intake and build" \
        "expected intake:release and build:release in marker; ..."
fi
```

FAILS on old code (EXIT trap not invoked on TERM→KILL path → marker empty).
PASSES on new code (EXIT trap dispatches teardown before kill grace expires).

### 2. orch-backend-misconfigured-test.sh — ZBUILD_PLUGINS_ROOT in e2e subshells

Acceptance check finding: "SPEC-4/SPEC-10: its test does not pass on the new code".

Root cause: `ZBUILD_PLUGINS_ROOT` exported from unit test sections (pointing to
`$_S10_PLUGINS` or `$_EMPTY_PLUGINS`) was inherited by the e2e subshells. The
runner would use the wrong plugins directory, potentially finding the backend in
the real repo root via the last-resort check instead of the temp install.

Fix: added `ZBUILD_PLUGINS_ROOT="$_E2E_S4_INSTALL/plugins"` to the SPEC-4 e2e
subshell and `ZBUILD_PLUGINS_ROOT="$_E2E_S10_INSTALL/plugins"` to the SPEC-10 e2e
subshell. This makes each test self-contained — the runner scans only the temp
install's plugins dir (where bash-parallel is absent/unreadable), not the
inherited empty/broken dir from unit tests.

FAILS on old code: sequential fallback finds orch-sequential in install → outputs
backend.missing warning, not "misconfigured bash-parallel".
PASSES on new code: sequential fallback removed, bash-parallel absent → disposition
= misconfigured → gate fires → output "misconfigured bash-parallel".

## State of all checker/test findings

### Checker round 2 finding (SPEC-5 hard-kill path)
Status: FIXED — added [#1801/SPEC-5] assertion in SPEC-5 hard-kill section.

### Test stage SPEC-4/SPEC-10 e2e acceptance check
Status: FIXED — added explicit ZBUILD_PLUGINS_ROOT to both e2e subshells.

### Test stage SPEC-5 persist hook not entered
Status: Expected failure on old code — [code] SPEC assertion that fails before
_runner_dispatch_always_run is implemented for persist stage. Correct as-is.

## Full list of test files with assertions

- tests/integration/orch-timeout-applies-test.sh — SPEC-1 ✓
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10 ✓
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3 ✓
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5 ✓ (hard-kill [#1801/SPEC-5] added)
- tests/integration/always-run-exit-paths-test.sh — SPEC-5 ✓
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh — SPEC-6 ✓
- tests/unit/lint-adr-enforced-by-test.sh — SPEC-7 ✓
- plugins/tool/orch-mock/tests/orch-mock-test.sh — SPEC-11 ✓
- tests/unit/adr059-no-tmpdir-defaults-test.sh — SPEC-12 ✓
- tests/unit/core-orch-run-id-isolation-test.sh — SPEC-12 ✓
- tests/unit/dispatch-rc-guard-test.sh — SPEC-12 ✓
- tests/unit/stdin-spawn-guard-test.sh — SPEC-12 ✓
- tests/unit/summary-mandatory-test.sh — SPEC-12 ✓
- tests/unit/exit-path-teardown-budget-guard-test.sh — existing checks updated ✓
- tests/unit/plugin-artifact-goldens-test.sh — existing checks updated ✓
