# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 12

## Status: COMPLETE

All 6 SPECs have their assertions written. All 5 test files verified on disk.

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 (complete)
- [#1944/SPEC-1] P1: runner exits non-zero on timed-out path
- [#1944/SPEC-1] P1: pipeline-state.json status=timed_out
- [#1944/SPEC-1] P1: pipeline.end status=timed_out event emitted
- [#1944/SPEC-1] P1: pipeline.end event carries in-flight stage name
- [#1944/SPEC-1] P1: pipeline.end event carries limit_s (numeric)
- [#1944/SPEC-1] P2: runner exits non-zero (watchdog fires regardless of dispatch state)
- [#1944/SPEC-1] P2: pipeline status=timed_out (watchdog fires regardless of dispatch state)
- [#1944/SPEC-1] P2: fast-one completed before watchdog fired (watchdog fires independently)
- [#1944/SPEC-1] P3: runner exits non-zero (not still running)
- [#1944/SPEC-1] P3: runner exits within TERM+10s+buffer
- [#1944/SPEC-1] P3: TERM-ignoring stage process is dead (PID killed)
- [#1944/SPEC-1] P4: runner exits non-zero on timed-out path
- [#1944/SPEC-1] P4: pipeline status=timed_out
- [#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path
- [#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path

### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 (complete)
- [#1944/SPEC-2] _runner_resolve_run_limit_s is defined in stage-limits.sh
- [#1944/SPEC-2] precedence: no template, no env → default 20700
- [#1944/SPEC-2] precedence: env ZBUILD_MAX_RUN_S=3600 used when no template value
- [#1944/SPEC-2] precedence: template value wins over ZBUILD_MAX_RUN_S
- [#1944/SPEC-2] precedence: template value wins over default
- [#1944/SPEC-2] non-integer template value → rc=1
- [#1944/SPEC-2] template value=0 → rc=1
- [#1944/SPEC-2] negative template value → rc=1
- [#1944/SPEC-2] non-integer ZBUILD_MAX_RUN_S → rc=1
- [#1944/SPEC-2] ZBUILD_MAX_RUN_S=0 → rc=1
- [#1944/SPEC-2] template_max_run_s() returns max_run_s value from YAML
- [#1944/SPEC-2] template_max_run_s() returns empty when max_run_s absent
- [#1944/SPEC-2] invalid ZBUILD_MAX_RUN_S → runner exits non-zero + no dispatch + names source
- [#1944/SPEC-2] invalid template max_run_s → runner exits non-zero + no dispatch + names source
- [#1944/SPEC-5] stage-limits.sh: no GITHUB_ACTIONS reference
- [#1944/SPEC-5] stage-limits.sh: no bare $CI in non-comment code
- [#1944/SPEC-5] runner.sh: no GITHUB_ACTIONS in code lines
- [#1944/SPEC-5] runner.sh: no bare $CI in non-comment code
- [#1944/SPEC-5] stage-limits.sh and runner.sh: no TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID
- [#1944/SPEC-6] ADR-025 word vocabulary includes timed_out
- [#1944/SPEC-6] ADR-025 ## Enforced by cites new tests
- [#1944/SPEC-6] ADR-054 §11 exists
- [#1944/SPEC-6] ADR-054 ## Enforced by cites run-limit tests
- [#1944/SPEC-6] ADR-054-stage-contract.md removed from baseline
- [#1944/SPEC-6] run_end_words timed_out describes the wall-clock limit
- [#1944/SPEC-6] lint-adr-enforced-by passes
- [#1944/SPEC-6] lint-test-errexit passes

### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 (complete, round 11 fix)
- [#1944/SPEC-3] S3-1: _runner_resolve_run_limit_s is defined
- [#1944/SPEC-3] S3-2: clean run exits 0
- [#1944/SPEC-3] S3-2: pipeline status is complete (not timed_out)
- [#1944/SPEC-3] S3-2: pipeline status is NOT timed_out
- [#1944/SPEC-3] S3-3: no pipeline.end/timed_out event after clean run
- [#1944/SPEC-3] S3-4: clean run with max_run_s=4 exits 0
- [#1944/SPEC-3] S3-4: UNCONDITIONAL sleep 5 → jq read (no if-guard)
  → three-way assert: timed_out=fail, non-empty=pass, empty=fail
- [#1944/SPEC-3] S3-4: watchdog killed: abort sentinel absent after runner exits

### tests/unit/run-open-items-test.sh — O9 (updated to 6)
- [O9]: 6 loop-ending lines (updated from 5→6 in prior round for timed_out arm)

### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 (complete)
- [#1944/SPEC-4] P1: get_resume_recommendation(timed_out) = manual_resume_only
- [#1944/SPEC-4] P2: _runner_resolve_run_limit_s defined in stage-limits.sh
- [#1944/SPEC-4] P3: resumed run did not time out (status not timed_out)
- [#1944/SPEC-4] P3: no pipeline.end/timed_out event in resumed run
- [#1944/SPEC-4] P4: resumed run exits 1 (watchdog fired, not outer timeout)
- [#1944/SPEC-4] P4: resumed run with slow stage ends timed_out (watchdog is armed)

## Failures from test stage that are NOT in scope

The following failures from the test stage are outside my named testfiles and cannot be addressed here:
- tests/integration/core-pipeline-runner-test.sh — TIMEOUT (existing file, not mine)
- tests/integration/core-pipeline-strategy-test.sh — TIMEOUT (existing file, not mine)
- tests/integration/runner-release-exit-paths-test.sh [SPEC-5] — FAIL (existing file, not mine; the SPEC-5 there refers to a different feature)
- tests/unit/vision-admission-gate-test.sh — TIMEOUT (existing file, not mine)
- tests/golden/full-pipeline/event-sequence.golden — golden file, not in my named testfiles
- tests/golden/parity/event-sequence.golden — golden file, not in my named testfiles

## LOOP_COMPLETE
