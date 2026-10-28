# Test stage summary

- verdict: fail
- passed: 818
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/always-run-exit-paths-test.sh — ✗ [#1801/SPEC-5] persist hook was entered (always_run persist stage dispatched) — file not found: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.YlXA1N/spec5p-entered
- tests/integration/orch-backend-misconfigured-test.sh — ✗ [#1801/SPEC-4] runner.sh must check _ZBUILD_ORCH_BACKEND_DISPOSITION after sourcing contract.sh — grep found no _ZBUILD_ORCH_BACKEND_DISPOSITION in runner.sh; old code has no disposition gate

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1801/SPEC-5] persist hook was entered (always_run persist stage dispatched)
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.YlXA1N/spec5p-entered[0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-4] runner.sh must check _ZBUILD_ORCH_BACKEND_DISPOSITION after sourcing contract.sh
    [2mgrep found no _ZBUILD_ORCH_BACKEND_DISPOSITION in runner.sh; old code has no disposition gate[0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-4] e2e: pipeline output must name absent backend as 'misconfigured'
    [2moutput did not contain 'misconfigured'; old code: no runner.sh gate, orch_spawn stub fires with 'not implemented' instead; got: ⚠ backend.missing: orchestrator=sequential configured but plugin not found
  [38;2;248;113;113m✗[0m [#1801/SPEC-4] e2e: pipeline output must name the missing backend
    [2moutput did not contain 'bash-parallel'; got: ⚠ backend.missing: orchestrator=sequential configured but plugin not found
  [38;2;248;113;113m✗[0m [#1801/SPEC-10] e2e: pipeline output must name unreadable plugin.sh as 'misconfigured'
    [2moutput did not contain 'misconfigured'; old code: no runner.sh gate; got: ⚠ backend.missing: orchestrator=sequential configured but plugin not found
  [38;2;248;113;113m✗[0m [#1801/SPEC-10] e2e: pipeline output must name the misconfigured backend
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.fEMKds/tests/integration/always-run-exit-paths-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.fEMKds/tests/integration/orch-backend-misconfigured-test.sh
  [38;2;74;222;128m✓[0m [SPEC-6] an unresolvable always-run stage does not fail the run
  [38;2;0;212;255m[#1801/SPEC-5] static: always-run-minimal.yaml release.timeout_s at stage level[0m
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] always-run-minimal.yaml: release.timeout_s is 2 at stage level (not under router:)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 14 tests failed[0m
  [38;2;248;113;113m[1m5 of 19 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-4/SPEC-10: its test does not pass on the new code — the code or the test is wrong
