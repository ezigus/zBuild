# Test stage summary

- failed: tests/unit/status-row-findings-test.sh
- verdict: fail
- passed: 886
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/status-row-findings-test.sh — ✗ [W8] …and the SPEC each failing test is for — expected: what failed: `CMBR-1`, `FRSH-2`, got: what failed: 2 findings (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q07SJe/tests/unit/status-row-findings-test.sh
  [38;2;74;222;128m✓[0m [W6] …and the first line is said once
  [38;2;74;222;128m✓[0m [W7] a try run again for its findings shows as failed
  [38;2;74;222;128m✓[0m [W7] …one with no findings stays unusable
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
  [38;2;248;113;113m✗[0m [W8] …and the SPEC each failing test is for
    [2mexpected: what failed: `CMBR-1`, `FRSH-2`, got: what failed: 2 findings[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — DSFSTG-4: its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong
