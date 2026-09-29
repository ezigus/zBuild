# Test stage summary

- verdict: fail
- passed: 2
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1835/SPEC-2] invalid_plan_response disposition=unusable
    [2mexpected: unusable, got: misconfigured[0m
  [38;2;248;113;113m✗[0m [#1835/SPEC-15] plan-summary.md output entry has summary: true
unit: 2/3 passed
unit: FAIL plugins/agent/plan/tests/plan-test.sh
  [38;2;74;222;128m✓[0m [#1835/SPEC-14] manifest declares event: plan.flow_wiring_missing
  [38;2;74;222;128m✓[0m [#1835/SPEC-14] manifest declares event: plan.scope.violation
  [38;2;74;222;128m✓[0m [#1835/SPEC-14] manifest declares event: plan.scope_too_large
  [38;2;74;222;128m✓[0m [#1835/SPEC-14] manifest declares event: plan.router_failed
  [38;2;0;212;255m[#1835/SPEC-15] manifest output entries with summary and checkpoint roles (guard)[0m
```
