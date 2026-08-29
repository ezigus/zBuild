# Test failures summary

## Failing lines (extracted)

```
unit: FAIL plugins/tool/test/tests/test-test.sh
  [38;2;0;212;255mT13. _test_extract_failing_files extracts FAIL paths[0m
  [38;2;74;222;128m✓[0m T13b: empty output when no FAIL lines
  [38;2;248;113;113m✗[0m [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir
    [2mexpected: 0, got: 0
  [38;2;248;113;113m✗[0m [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir
unit: FAIL tests/integration/test-plugin-tmpdir-cleanup-test.sh
  [38;2;248;113;113m✗[0m success: artifact written
    [2mexpected: 0, got: null[0m
  [38;2;248;113;113m✗[0m success: artifact written
```
