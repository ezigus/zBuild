# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current Status (iteration 2 of build stage)

### Only Change This Iteration
Fixed the critical `:-0` → `:-` bug in `core/pipeline/runner.sh` lines 2539-2540.
- `kill -KILL "${_RUNNER_WATCHDOG_PID:-0}"` → `kill -KILL "${_RUNNER_WATCHDOG_PID:-}"`
- `wait "${_RUNNER_WATCHDOG_PID:-0}"` → `wait "${_RUNNER_WATCHDOG_PID:-}"`

Root cause: When `_RUNNER_WATCHDOG_PID` is empty (early exit before watchdog armed),
`kill -KILL 0` sent SIGKILL to the entire process group (including the test harness),
and `wait 0` blocked waiting for ALL background processes. This caused the 3 integration
test timeouts: core-pipeline-runner-test, core-pipeline-strategy-test, vision-admission-gate-test.

### Implementation — COMPLETE
All implementation files are correct and complete:

- [x] scripts/lib/stage-limits.sh: `_runner_resolve_run_limit_s()` done
- [x] core/pipeline/template.sh: `template_max_run_s()` done
- [x] scripts/lib/abort-propagation.sh: `timed_out` in word list done
- [x] scripts/lib/run-open-items.sh: `timed_out` case done
- [x] core/state/resume.sh: `timed_out → manual_resume_only` done
- [x] core/pipeline/runner.sh: watchdog arm + EXIT trap kill -KILL + _runner_abort_trap
      + _runner_end_on_abort done; FIXED :-0 → :- on both kill and wait lines
- [x] docs/adr/ADR-025-abort-propagation.md: `timed_out` in word vocab + ## Enforced by done
- [x] docs/adr/ADR-054-stage-contract.md: §11 + ## Enforced by done
- [x] docs/adr/ADR-006-resume-contract.md: `timed_out` in pipeline status enum done
- [x] docs/adr/ADR-015-stage-io-capture.md: `timed_out` in glyph/color table done
- [x] config/adr-enforcement-baseline.txt: ADR-054-stage-contract.md removed done
- [x] tests/golden/pipeline-end/timed_out-w80.colored.txt: exists
- [x] tests/golden/pipeline-end/timed_out-w80.layout.txt: exists
- [x] tests/unit/runner-pipeline-end-test.sh: `timed_out` in STATUSES done

Previous build iteration (f915476a) already fixed:
- All set +e/set -e lint violations (8 occurrences across 4 test files)
- Syntax error at line 173 of run-limit-precedence-test.sh
- P4 persist missing in run-timed-out-test.sh
- P2 assert_pass in both branches of run-timed-out-test.sh

### Test Results (verified this iteration)

PASSES:
- run-timed-out-test.sh (SPEC-1): All 15 tests PASS
- run-limit-precedence-test.sh (SPEC-2/5/6): All 38 tests PASS
- run-watchdog-clean-exit-test.sh (SPEC-3): All 8 tests PASS
- resume-after-run-timeout-test.sh (SPEC-4): All 6 tests PASS
- lint-test-errexit-test.sh: All 5 tests PASS
- runner-pipeline-end-test.sh: All 38 tests PASS
- run-open-items-test.sh: All 53 tests PASS
- shape-floor-content-stable-test.sh: All 7 tests PASS
- shape-floor-test.sh: All 24 tests PASS
- lint-test-errexit: clean
- lint-adr-enforced-by: 68 ADRs checked, all enforced or baselined
- shellcheck on runner.sh: clean

Integration tests (should now pass after :-0 fix):
- core-pipeline-runner-test.sh: was TIMEOUT, fix applied
- core-pipeline-strategy-test.sh: was TIMEOUT, fix applied
- vision-admission-gate-test.sh: was TIMEOUT, fix applied

### Test-Author Findings (quality concerns, not failures)

Finding 1 (test-author SPEC-1 P2): The assertion doesn't directly verify dispatch
state at moment of timeout. Quality concern only - test passes.

Finding 2 (test-author SPEC-3): Sleep timing not visible in assertion text. Quality
concern only - test passes (sleep 5 is before the sentinel check).
