# Test stage summary

- verdict: fail
- passed: 816
- failed: 4
- exit_code: 1

## Failing files

- tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: build stage_status=failed in state)
- tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: sequential: runner exits non-zero when stage fails (rc=1))
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
- tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: [SPEC-8] runner message references --condense)

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
unit: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.gH68rE/tests/unit/vision-admission-gate-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.gH68rE/tests/integration/core-pipeline-runner-test.sh (exceeded 480s, rc=137)
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.gH68rE/tests/integration/core-pipeline-strategy-test.sh (exceeded 480s, rc=137)
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.gH68rE/tests/integration/runner-release-exit-paths-test.sh
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
  [38;2;74;222;128m✓[0m [SPEC-6] the blocked hook does not outlive the run
  [38;2;0;212;255mSPEC-6b: a hook child that ignores TERM does not outlive the run[0m
  [38;2;74;222;128m✓[0m [SPEC-6b] a hook child that ignores TERM does not outlive the run
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
