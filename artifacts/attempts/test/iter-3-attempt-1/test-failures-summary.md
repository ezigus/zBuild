# Test stage summary

- verdict: fail
- passed: 789
- failed: 1
- exit_code: 1

## Failing files

- plugins/tool/test/tests/test-test.sh — ✗ input banner emitted to fd 3

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m input banner emitted to fd 3
    [2moutput missing: seq=1 input[0m
  [38;2;248;113;113m✗[0m output banner present (seq=1 output)
    [2moutput missing: seq=1 output[0m
  [38;2;74;222;128m✓[0m [#2124] the ✗ line is in the summary
  [38;2;74;222;128m✓[0m [#2124] its detail line follows it
  [38;2;74;222;128m✓[0m [#2124] the ✗ line precedes the noise
  [38;2;74;222;128m✓[0m [#2138] the bash runtime error at the file's tail is in the summary
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pOCllb/plugins/tool/test/tests/test-test.sh
  [38;2;74;222;128m✓[0m [#2138] the lint finding is in the summary
  [38;2;74;222;128m✓[0m [#2138] the lint finding's location is in the summary
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 112 tests failed[0m
  [38;2;0;212;255mT13. _test_extract_failing_files extracts FAIL paths[0m
  [38;2;74;222;128m✓[0m T13b: empty output when no FAIL lines
  [38;2;74;222;128m✓[0m [#2124] the tier's FAIL marker names the file
```
