# Test stage summary

- verdict: fail
- passed: 767
- failed: 2
- exit_code: 1

## Failing files

- plugins/agent/plan/tests/plan-integration-test.sh — ✗ [SPEC-3] max_turns plan_run returns rc=10 — expected: 10, got: 1
- tests/unit/dispatch-rc-guard-test.sh — ✗ [SPEC-1] core/pipeline/runner.sh SHRANK (36 → 35) — lower the pin

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-1] core/pipeline/runner.sh SHRANK (36 → 35) — lower the pin
    [2mProgress must be locked in: set core/pipeline/runner.sh to 35 in _PINNED so the next change cannot spend the slack.[0m
  [38;2;248;113;113m✗[0m [SPEC-3] max_turns plan_run returns rc=10
    [2mexpected: 10, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-3] no fake plan.json written on scope_too_large
    [2mfile should not exist: /home/runner/work/_temp/zbuild-state/scratch/test/plugin-plan-integration.pn1IA5/state/artifacts/plan.json[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.2ezFSL/tests/unit/dispatch-rc-guard-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.2ezFSL/plugins/agent/plan/tests/plan-integration-test.sh
  [38;2;74;222;128m✓[0m [SPEC-5] the 130 arm is still present in _cycle_handle_terminal_rc
  [38;2;0;212;255m6. write-boundary wiring leaves lifecycle.sh rc-clean[0m
  [38;2;74;222;128m✓[0m [SPEC-7] lifecycle.sh still has 0 legacy rc returns after write-boundary wiring (#1809)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 24 tests failed[0m
  [38;2;74;222;128m✓[0m [#1835/SPEC-8] config error writes plan.json
  [38;2;74;222;128m✓[0m [#1835/SPEC-8] config error disposition=misconfigured
  [38;2;248;113;113m[1m2 of 50 tests failed[0m
```
