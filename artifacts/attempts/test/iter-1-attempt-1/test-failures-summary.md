# Test stage summary

- verdict: fail
- passed: 824
- failed: 6
- exit_code: 1

## Failing files

- tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: build stage_status=failed in state)
- tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: sequential: runner exits non-zero when stage fails (rc=1))
- tests/unit/lint-test-errexit-test.sh — ✗ [L5] the real tree passes — expected: 0, got: 1
- tests/unit/run-limit-precedence-test.sh — /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/run-limit-precedence-test.sh: line 173: syntax error near unexpected token `('
- tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: [SPEC-8] runner message references --condense)

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [L5] the real tree passes
    [2mexpected: 0, got: 1[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/run-limit-precedence-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/lint-test-errexit-test.sh
unit: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137)
lint: FAIL (npm run lint)
/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/run-limit-precedence-test.sh: line 173: syntax error near unexpected token `('
/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/tests/unit/run-limit-precedence-test.sh: line 173: `( cd "$MISCFG_OVERLAY" && bash "$RUNNER" --template limit-single --goal "test misconfigured limit" ) \'
  [38;2;74;222;128m✓[0m [#1944/SPEC-2] negative template value → rc=1
  [38;2;74;222;128m✓[0m [#1944/SPEC-2] non-integer ZBUILD_MAX_RUN_S → rc=1
  [38;2;74;222;128m✓[0m [#1944/SPEC-2] ZBUILD_MAX_RUN_S=0 → rc=1
  [38;2;0;212;255m[#1944/SPEC-2] misconfigured run: runner rejects invalid limit before dispatch[0m
lint-test-errexit: tests/unit/run-watchdog-clean-exit-test.sh:80 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/unit/run-watchdog-clean-exit-test.sh:131 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: 8 file(s) switch stop-on-error on mid-file
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-7] pipeline.end says the gate refused (status=preflight_failed)
  [38;2;74;222;128m✓[0m [SPEC-7] runner names search paths in message
  [38;2;74;222;128m✓[0m [SPEC-7] runner includes zbuild vision init hint
  [38;2;74;222;128m✓[0m [SPEC-8] runner rc=1 on malformed vision (enforce)
  [38;2;74;222;128m✓[0m [SPEC-8] pipeline.end says the gate refused (status=preflight_failed)
  [38;2;74;222;128m✓[0m [SPEC-8] runner message references --condense
/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.YMRLO3/scripts/run-tests.sh: line 171: 1804492 Killed                  "${_rt_tout[@]}" bash "$1" < /dev/null 3> /dev/null > "$2" 2>&1
  [38;2;74;222;128m✓[0m events.jsonl present on failure
  [38;2;74;222;128m✓[0m pipeline.end status=failed emitted
  [38;2;74;222;128m✓[0m pipeline.end names the failing stage
  [38;2;74;222;128m✓[0m stage.fail event emitted
  [38;2;74;222;128m✓[0m build stage_status=failed in state
  [38;2;74;222;128m✓[0m orch_spawn count == orch_shutdown count
  [38;2;74;222;128m✓[0m no pool directories left after fanout (orch_shutdown cleaned up)
  [38;2;0;212;255m3. sequential halt-on-fail: only one dispatch when first fails[0m
▸ merge_policy: auto_unless_flagged
  [38;2;74;222;128m✓[0m sequential: runner exits non-zero when stage fails (rc=1)
  [38;2;0;212;255m4. composite strategy: emits deferral error (Phase 1 deferred)[0m
lint-test-errexit: tests/integration/run-timed-out-test.sh:273 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/integration/run-timed-out-test.sh:334 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/unit/run-limit-precedence-test.sh:176 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/integration/resume-after-run-timeout-test.sh:133 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/integration/run-timed-out-test.sh:137 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/integration/run-timed-out-test.sh:224 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
```
