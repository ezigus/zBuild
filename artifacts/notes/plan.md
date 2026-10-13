# Plan notes — issue #1944 (run-level wall-clock limit) — REVISION after build/test cycle

## What the build produced (15 files changed)

The build ran the original 7-step plan. All implementation files were written. Tests fail.

## Findings mapped to plan items

### F1 — Syntax error: run-limit-precedence-test.sh line 173
`MISCFG_OVERLAY=... ( cd ... && bash ... )` — bash does not allow env-var assignment before a
subshell literal `(...)`. The token `(` is unexpected in that context. Fix: export the variable
first, or move the assignment inside the subshell.

### F2 — lint-test-errexit: 8 files
All four new test files use `set +e` / `set -e` mid-file. Their headers say `set -uo pipefail`
(no `-e`). The lint rule says: once you're in a file without errexit, turning it on partway
through means an unexpected non-zero after that point kills the file without logging. Rule:
replace every `set +e; cmd; set -e` block with `cmd || rc=$?` pattern.

Files: run-timed-out-test.sh (lines 137, 224, 273, 334), run-limit-precedence-test.sh (line 176),
run-watchdog-clean-exit-test.sh (lines 80, 131), resume-after-run-timeout-test.sh (line 133).

### F3 — Integration test timeouts (3 pre-existing tests)
core-pipeline-runner-test.sh, core-pipeline-strategy-test.sh, vision-admission-gate-test.sh all
timeout after 480 s. These were passing before this change. Root cause: the watchdog background
subshell (sleeping 20700 s by default) is not `disown`ed. When the runner script exits, bash
still tracks the background job. The test framework, which invokes the runner via a subshell and
may wait on it, gets blocked waiting for that 20700 s sleep.
Fix: `disown $_RUNNER_WATCHDOG_PID` in runner.sh immediately after spawning the watchdog.

### F4 — template.sh inert (acceptance-gate finding)
Reverting template.sh made no test fail. This means the test suite never exercises the template
max_run_s path end-to-end. run-limit-precedence-test.sh tests _runner_resolve_run_limit_s
directly but never invokes the runner with a fixture template file containing `max_run_s:`.
Fix: add a test case that runs the runner with a fixture template, asserts the resolved limit
comes from the template value.

### F5 — run-open-items.sh untested (acceptance-gate finding)
Reverting run-open-items.sh + config/adr-enforcement-baseline.txt made no test fail.
run-open-items-test.sh (in design scope) should have a count assertion updated from 5→6 for the
new timed_out arm in run_end_words, per the design's `supersedes` block. That assertion is either
missing or checking the wrong count.

### F6 — persist missing from always_run test
issue-acceptance: `persist` never appears in the always_run list, never constructed, never
asserted. The design says "release and persist execute on every timed-out exit path" (SPEC-1
R-4). The always_run fixture in the integration test likely only has `release`.

### F7 — P2 in run-timed-out-test.sh unfalsifiable
P2 (watchdog fires during inter-dispatch idle) calls `assert_pass` in both branches of a
conditional. Whatever the outcome, the assertion passes. Fix: assert something that only holds
when the watchdog fired during idle — e.g., first-stage result exists but second stage was
never dispatched.

### F8 — SPEC-2 disposition check missing in pipeline-state.json
The misconfigured runner test checks rc=1 and that the dispatch loop was not reached, but does
not check that pipeline-state.json carries `disposition=misconfigured`. The issue acceptance
criterion requires this.

### F9 — SPEC-3: watchdog PID not proved gone
The test proves the abort sentinel is absent (so the watchdog didn't fire), but a watchdog that
is still sleeping also leaves the sentinel absent. The assertion must check `! kill -0 $pid 2>/dev/null`.

### F10 — Golden files not updated
shape-floor: tests/golden/full-pipeline/event-sequence.golden and
tests/golden/parity/event-sequence.golden were not updated. If the timed_out run path emits new
events those files must be regenerated.

### F11 — ADR-054 §9 vs §11
The issue says "ADR-054 §9 amended" but §9 already exists as "Per-stage router configuration
surface". The build correctly added §11. The Enforced by entries in §11 must name test files
that exist on disk. This is a doc/lint sanity check.

## Revised step list

1. Fix run-limit-precedence-test.sh: syntax error + lint-test-errexit + SPEC-2 disposition
2. Fix run-watchdog-clean-exit-test.sh: lint-test-errexit + SPEC-3 PID check
3. Fix run-timed-out-test.sh: lint-test-errexit + P2 falsifiability + persist on all paths
4. Fix resume-after-run-timeout-test.sh: lint-test-errexit + SPEC-4 timing
5. Fix core/pipeline/runner.sh: disown watchdog (integration timeout fix) + persist in fixture
6. Fix template.sh wiring: add end-to-end template runner invocation to run-limit-precedence-test.sh
7. Fix run-open-items.sh coverage: update/add run-open-items-test.sh count assertion (5→6)
8. Update golden files: regenerate event-sequence.golden files
9. Verify ADR-054 §11 Enforced by entries: confirm they name existing test files
