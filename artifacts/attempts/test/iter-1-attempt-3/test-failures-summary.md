# Test stage summary

- verdict: fail
- passed: 817
- failed: 4
- exit_code: 1

## Failing files

- tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: build stage_status=failed in state)
- tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: sequential: runner exits non-zero when stage fails (rc=1))
- tests/unit/runner-signal-rearm-test.sh — ✗ [SPEC-5] re-arm TERM handler matches the startup install — expected: <startup-not-found>, got: trap '_runner_signal_trap TERM' TERM
- tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: [SPEC-8] runner message references --condense)

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] re-arm TERM handler matches the startup install
    [2mexpected: <startup-not-found>, got: trap '_runner_signal_trap TERM' TERM[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.t8GnJH/tests/unit/runner-signal-rearm-test.sh
unit: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.t8GnJH/tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.t8GnJH/tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.t8GnJH/tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137)
  [38;2;74;222;128m✓[0m [SPEC-4] re-arm INT handler matches the startup install
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-7] pipeline.end says the gate refused (status=preflight_failed)
  [38;2;74;222;128m✓[0m [SPEC-7] runner names search paths in message
  [38;2;74;222;128m✓[0m [SPEC-7] runner includes zbuild vision init hint
  [38;2;74;222;128m✓[0m [SPEC-8] runner rc=1 on malformed vision (enforce)
  [38;2;74;222;128m✓[0m [SPEC-8] pipeline.end says the gate refused (status=preflight_failed)
  [38;2;74;222;128m✓[0m [SPEC-8] runner message references --condense
  [38;2;74;222;128m✓[0m mid-stage failure exits 1
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
```

## The checks of this run
- the shape floor failed: missing_floor_files
