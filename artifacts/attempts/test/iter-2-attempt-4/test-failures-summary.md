# Test stage summary

- 2 test(s) failed
- verdict: fail
- passed: 14
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/e2e/claim-race-test.sh
unit: FAIL tests/e2e/parity-local-vs-ci-test.sh
  [38;2;74;222;128m✓[0m release removed claimed:releaser label
  [38;2;0;212;255m5. list_claims emits JSON array of current holders[0m
  [38;2;74;222;128m✓[0m list_claims contains the claimed issue
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 9 tests failed[0m
  [38;2;248;113;113m✗[0m 3-way race must produce ≤1 winner
  [38;2;74;222;128m✓[0m all artifact contents identical across modes (sha256, timestamps normalized)
  [38;2;74;222;128m✓[0m normalized state.json matches golden snapshot
  [38;2;74;222;128m✓[0m artifact filename list matches golden snapshot
  [38;2;248;113;113m[1m1 of 15 tests failed[0m
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
