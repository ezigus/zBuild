# Test stage summary

- verdict: fail
- passed: 724
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m mismatch (state=95840002, --issue=95840001) exits non-zero
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m mismatch error message is clear
    [2mstderr:   WARNING: manifest for stage intake has no inputs: block — declare `inputs: []` for zero-input plugins (ADR-020)
✗ No state file found at /home/runner/work/_temp/zbuild-state/scratch/test/runner-state-file-issue-cross-check.Vnq3aL/state/pipeline-state.json; cannot resume[0m
  [38;2;74;222;128m✓[0m matching (state=95840002, --issue=95840002) exits 0 via dry-run
  [38;2;248;113;113m✗[0m corrupt state file + --issue → exits 2 (fail-closed)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m corrupt-JSON error message is clear
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0ini5y/tests/integration/runner-state-file-issue-cross-check-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m4 of 12 tests failed[0m
```
