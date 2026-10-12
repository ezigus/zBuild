# Issue-acceptance notes — #1944

## Starting analysis

Working through R-1..R-10 against DIFF and TEST VERDICT (fail).

### Known hard failures from TEST VERDICT
1. `run-limit-precedence-test.sh` — syntax error line 173 (bad env-var prefix on subshell)
2. `lint-test-errexit` — 8 files switch set +e mid-file (new test files all flagged)
3. `core-pipeline-runner-test.sh` — 480s timeout (possibly watchdog leaking into existing tests)
4. `core-pipeline-strategy-test.sh` — 480s timeout (same)
5. `vision-admission-gate-test.sh` — 480s timeout

R-10 is unambiguously unmet: npm test AND npm run lint both fail.

## Reading ADR-054 to check §9 vs §11 discrepancy (R-9)

## Findings per requirement

### R-1
Implementation correct. P1 in run-timed-out-test.sh covers this (status=timed_out, event fields, rc check).
BUT: test file uses `set +e; ...; set -e` pattern flagged by lint-test-errexit → lint fails.
NEGCTL ERROR for SPEC-1 (pipeline problem, not code) — can't verify test reddens at merge-base.
Blocked by R-10 failure.

### R-2
Implementation: background subshell sleeping independently — fires regardless of engine state.
Test P2: both branches of the conditional call assert_pass → the "fires between dispatches" sub-requirement is unfalsifiable.

### R-3
Implementation: TERM→PG then KILL to children after 10s via pgrep -P. P3 checks elapsed time ≤ 17s.
Structurally sound. Blocked by R-10 lint failure.

### R-4
Issue says "release AND persist". Template `timeout-with-release.yaml` only declares `always_run: [release]`.
No persist stage constructed or tested. Unmet.

### R-5
Unit function tested correctly (rc=1 for bad values, precedence layers via mock).
run-limit-precedence-test.sh: syntax error on line 173 — `ZBUILD_MAX_RUN_S="..." \ ( subshell )` is not valid bash.
Template end-to-end test absent (acceptance-gate: template.sh inert when reverted).
Unmet.

### R-6
Test infers reaping indirectly; no direct check that watchdog PID is gone. Lint errors in test file.

### R-7
Test can't distinguish "fresh watchdog" from "no watchdog on resume". Lint errors in test file.

### R-8
SPEC-5 assertions are in run-limit-precedence-test.sh which fails with syntax error → unreachable.
Even if fixed: only GITHUB_ACTIONS + bare $CI checked, not TRAVIS/CIRCLECI/RUNNER_OS.

### R-9
ADR-025: amended correctly (timed_out in vocab, ## Enforced by cites new tests). ✓
ADR-054: issue says "§9" (existing section = "Per-stage router configuration surface", untouched),
diff adds §11 which carries the correct content. Numbering discrepancy.
REQUIREMENTS/SPEC-6 say §11, which matches the diff.
UNSURE whether issue's "§9" meant "amend existing §9" or was a draft numbering error.

### R-10
TEST VERDICT: fail.
lint-test-errexit: 8 new test files use `set +e; ...; set -e` instead of `cmd || rc=$?`.
run-limit-precedence-test.sh: bash syntax error line 173.
Three existing integration tests time out.
Unmet.
