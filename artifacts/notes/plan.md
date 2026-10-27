# Plan notes — issue #1944 (run-level wall-clock limit) — REVISION after cycle 7 (test + issue-acceptance)

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

### F12 — SPEC-5 finite CI variable list (spec-correspondence finding)
The test checks a finite enumerated set of CI/CD platform variables (GITHUB_ACTIONS, CI, TRAVIS,
CIRCLECI, RUNNER_OS, BUILD_BUILDID) but the requirement prohibits any platform-specific variable,
a category with no fixed boundary. Added as open question — the finite-list grep approach may be
accepted as sufficient but needs explicit confirmation.

### F13 — SPEC-3 state-file re-read missing (test-author finding, cycle 5)
test-author (verdict: fail): SPEC-3's assertion never re-reads pipeline-state.json after
explicitly waiting past max_run_s=4s. The "status remains stage-driven result, not timed_out"
sub-claim is left to implication from sentinel absence rather than a direct state-file
verification. Fix: after the runner exits cleanly, explicitly sleep past max_run_s, then
re-read pipeline-state.json and assert its status field is the stage-driven result (not timed_out).
This is an addition to step-2 alongside the existing kill -0 check.

### F14 — runner-release-exit-paths-test.sh SPEC-5 regression (NEW — cycle 7)
Test output: `✗ [SPEC-5] cleanup dispatched with scope=release for: intake build` with
`no release from: intake build | marker=`. This test was passing before this change.
Root cause: the watchdog is still running when the runner's EXIT trap fires after a hard-kill
(SIGKILL-style, simulating an external timeout). While the EXIT trap dispatches `release`,
the watchdog's timer expires and zbuild_pg_kill kills the whole process group — including the
release dispatch — before release can write its marker.
Fix: the EXIT trap in runner.sh must kill (disarm) the watchdog PID at the very beginning of
the trap body, before dispatching release or persist. This is distinct from the disown fix
(which addresses bash job-control blocking on exit) — the watchdog process must be explicitly
killed, not just disowned.
This finding also reinforces that `persist` must be added to the always_run list in runner.sh
(production code), not only in test fixtures — issue-acceptance confirms persist is absent from
every always_run list in the change.

## Cycle 7 update: step-5 description expanded

The existing step-5 covered: disown watchdog + persist in always_run fixture.
F14 requires step-5 to also cover:
- Kill the watchdog PID at the start of the EXIT trap (disarm) so it cannot fire during release/persist dispatch
- Add persist to always_run in runner.sh production code (not only fixture)

The number of steps stays at 9. Only step-5's description is updated.

## Coverage matrix (cycle 7)

| Finding | Step |
|---|---|
| Syntax error run-limit-precedence-test.sh L173 | step-1 |
| lint-test-errexit 8 files | steps 1–4 |
| Integration test timeouts (disown missing) | step-5 |
| Watchdog fires during EXIT trap, killing release (SPEC-5 regression) | step-5 |
| persist absent from always_run in production runner.sh | step-5 |
| template.sh inert | step-6 |
| run-open-items.sh untested | step-7 |
| SPEC-1 P2 unfalsifiable + persist on all paths | step-3 |
| SPEC-2 disposition=misconfigured missing | step-1 |
| SPEC-3 watchdog PID not proved gone | step-2 |
| SPEC-3 state-file re-read missing (test-author F13) | step-2 |
| SPEC-4 timing assertion non-inferential | step-4 |
| SPEC-5 finite CI variable list | open question |
| SPEC-6 npm test/lint not executed in test | resolved by all other steps passing |
| Golden files not updated | step-8 |
| ADR-054 §11 Enforced by entries | step-9 |
| R-9/§9 vs §11 | open question |

## Acceptance criteria coverage (cycle 7 — unchanged from cycle 5/6)

All 10 issue AC items are covered:
- AC-1 timed_out with in-flight stage name + limit → step-3 (run-timed-out-test.sh, P1)
- AC-2 watchdog fires during inter-dispatch idle → step-3 (P2 falsifiability fix)
- AC-3 whole process group dies (TERM → KILL after 10 s) → step-3 (P3)
- AC-4 release and persist run after timed_out → step-3 (assert persist) + step-5 (production always_run + watchdog disarm)
- AC-5 precedence layers + validation → step-1 (SPEC-2 + syntax fix) + step-6 (template end-to-end)
- AC-6 run inside limit untouched, watchdog gone → step-2 (SPEC-3 kill -0 check + state-file re-read)
- AC-7 resumed run gets fresh limit → step-4 (resume-after-run-timeout-test.sh timing fix)
- AC-8 same locally and CI, no platform branch → covered by SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §9/§11 + ADR-025 Enforced by entries → step-9
- AC-10 npm test + npm run lint green → all steps collectively

No step defers testing, treats behavior as optional, or adds inert files.
