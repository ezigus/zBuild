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

### F12 — SPEC-5 finite CI variable list (spec-correspondence finding)
The test checks a finite enumerated set of CI/CD platform variables (GITHUB_ACTIONS, CI, TRAVIS,
CIRCLECI, RUNNER_OS, BUILD_BUILDID) but the requirement prohibits any platform-specific variable,
a category with no fixed boundary. Added as open question — the finite-list grep approach may be
accepted as sufficient but needs explicit confirmation.

## Revised step list (final — 9 items)

1. Fix run-limit-precedence-test.sh: syntax error + lint-test-errexit + SPEC-2 disposition
2. Fix run-watchdog-clean-exit-test.sh: lint-test-errexit + SPEC-3 PID check
3. Fix run-timed-out-test.sh: lint-test-errexit + P2 falsifiability + persist on all paths
4. Fix resume-after-run-timeout-test.sh: lint-test-errexit + SPEC-4 timing
5. Fix core/pipeline/runner.sh: disown watchdog (integration timeout fix) + persist in fixture
6. Fix template.sh wiring: add end-to-end template runner invocation to run-limit-precedence-test.sh
7. Fix run-open-items.sh coverage: update/add run-open-items-test.sh count assertion (5→6)
8. Update golden files: regenerate event-sequence.golden files
9. Verify ADR-054 §11 Enforced by entries: confirm they name existing test files

## Coverage matrix

| Finding | Step |
|---|---|
| Syntax error run-limit-precedence-test.sh L173 | step-1 |
| lint-test-errexit 8 files | steps 1–4 |
| Integration test timeouts (disown missing) | step-5 |
| template.sh inert | step-6 |
| run-open-items.sh untested | step-7 |
| SPEC-1 P2 unfalsifiable + persist on all paths | step-3 |
| SPEC-2 disposition=misconfigured missing | step-1 |
| SPEC-3 watchdog PID not proved gone | step-2 |
| SPEC-4 timing assertion non-inferential | step-4 |
| SPEC-5 finite CI variable list | open question |
| SPEC-6 npm test/lint not executed in test | resolved by all other steps passing |
| Golden files not updated | step-8 |
| ADR-054 §11 Enforced by entries | step-9 |
| R-9/§9 vs §11 | open question |

## Acceptance criteria coverage (final check — second plan cycle)

All 10 issue AC items are covered:
- AC-1 timed_out with in-flight stage name + limit → step-3 (run-timed-out-test.sh, P1)
- AC-2 watchdog fires during inter-dispatch idle → step-3 (P2 falsifiability fix)
- AC-3 whole process group dies (TERM → KILL after 10 s) → step-3 (P3)
- AC-4 release and persist run after timed_out → step-3 (assert persist) + step-5 (fixture)
- AC-5 precedence layers + validation → step-1 (SPEC-2 + syntax fix) + step-6 (template end-to-end)
- AC-6 run inside limit untouched, watchdog gone → step-2 (SPEC-3 kill -0 check)
- AC-7 resumed run gets fresh limit → step-4 (resume-after-run-timeout-test.sh timing fix)
- AC-8 same locally and CI, no platform branch → covered by SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §9/§11 + ADR-025 Enforced by entries → step-9
- AC-10 npm test + npm run lint green → all steps collectively

No step defers testing, treats behavior as optional, or adds inert files.
plan.json on disk is correct — no changes needed this cycle.

## Third cycle review (after test + issue-acceptance failures confirmed)

All 5 test failures and all 7 issue-acceptance findings are already covered by the 9-step plan:

| Stage finding | Step |
|---|---|
| core-pipeline-runner-test.sh timeout | step-5 (disown) |
| core-pipeline-strategy-test.sh timeout | step-5 (disown) |
| vision-admission-gate-test.sh timeout | step-5 (disown) |
| lint-test-errexit-test.sh [L5] fails (meta-test) | steps 1–4 (fix the 8 violations) |
| run-limit-precedence-test.sh L173 syntax error | step-1 |
| R-4 persist missing from always_run test | step-3 + step-5 |
| R-5 template.sh inert + syntax error | step-1 + step-6 |
| R-2 P2 unfalsifiable | step-3 |
| R-10 npm test + lint fail | all steps collectively |
| R-9 §9 vs §11 ambiguity | open question |

No new findings. plan.json has 9 steps and remains accurate.

## Fourth cycle review (re-entry after plan stage re-ran)

Same test failures and issue-acceptance findings as cycle 3 — no new findings introduced.
plan.json on disk has 9 steps and correctly covers every finding and every acceptance criterion.
No changes to plan.json are needed.
