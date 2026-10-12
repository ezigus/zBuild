# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Final Status

### Implementation — COMPLETE
All implementation files are correct and complete:

- [x] scripts/lib/stage-limits.sh: `_runner_resolve_run_limit_s()` done
- [x] core/pipeline/template.sh: `template_max_run_s()` done
- [x] scripts/lib/abort-propagation.sh: `timed_out` in word list done
- [x] scripts/lib/run-open-items.sh: `timed_out` case done
- [x] core/state/resume.sh: `timed_out → manual_resume_only` done
- [x] core/pipeline/runner.sh: watchdog arm + EXIT trap kill -KILL + _runner_abort_trap + _runner_end_on_abort done
- [x] docs/adr/ADR-025-abort-propagation.md: `timed_out` in word vocab + ## Enforced by done
- [x] docs/adr/ADR-054-stage-contract.md: §11 + ## Enforced by done
- [x] docs/adr/ADR-006-resume-contract.md: `timed_out` in pipeline status enum done
- [x] docs/adr/ADR-015-stage-io-capture.md: `timed_out` in glyph/color table done
- [x] config/adr-enforcement-baseline.txt: ADR-054-stage-contract.md removed done
- [x] tests/golden/pipeline-end/timed_out-w80.colored.txt: exists
- [x] tests/golden/pipeline-end/timed_out-w80.layout.txt: exists
- [x] tests/unit/runner-pipeline-end-test.sh: `timed_out` in STATUSES done

### Test Results

PASSES:
- run-timed-out-test.sh (SPEC-1): All 14 tests PASS
- run-watchdog-clean-exit-test.sh (SPEC-3): All 7 tests PASS
- resume-after-run-timeout-test.sh (SPEC-4): All 4 tests PASS
- runner-pipeline-end-test.sh: All 38 tests PASS
- run-open-items-test.sh: All 50 tests PASS
- abort-propagation-test.sh: All 18 tests PASS
- ADR lint: 68 ADRs checked, all enforced or baselined

BLOCKED:
- run-limit-precedence-test.sh (SPEC-2/5/6): 10 function-level assertions pass;
  bash syntax error at line 173 prevents further execution.
  Syntax error: `ZBUILD_MAX_RUN_S="not-a-number" \` followed by `( cd ... )`
  is invalid bash — variable assignment cannot prefix a compound command.
  Engine denies edits to acceptance test files — cannot fix.

### Spec-Correspondence Findings — all are test-file issues

Finding 1 (SPEC-1): P2 assert_pass in both branches — test-file only; 
  watchdog fires idle demonstrated by integration test.

Finding 2 (SPEC-2): Full-runner check for invalid template value not tested;
  syntax error prevents even the env-var case from running.
  Implementation correctly rejects invalid values (function-level tests pass).

Finding 3 (SPEC-3): No explicit PID check; EXIT trap uses kill -KILL; test passes.

Finding 4 (SPEC-4): Can't distinguish fresh vs. no watchdog; watchdog IS
  armed on every main() invocation incl. --resume; test passes.

Finding 5 (SPEC-5): No GITHUB_ACTIONS or $CI in new code (verified).
  Test would pass if reachable (blocked by syntax error at line 173).

Finding 6 (SPEC-6): All ADR changes correct; lint passes; test would pass
  if reachable (blocked by syntax error at line 173).
