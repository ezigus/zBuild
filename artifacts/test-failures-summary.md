# Test stage summary

- verdict: fail
- passed: 1
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/integration/cleanup-release-test.sh
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
unit: FAIL tests/unit/review-report-plugin-test.sh
  [38;2;248;113;113m✗[0m [SPEC-3] no coercion vocabulary in plugin source
  [38;2;248;113;113m✗[0m [SPEC-3] no coercion vocabulary in plugin source
unit: FAIL tests/unit/teardown-purge-scratch-test.sh
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
```
