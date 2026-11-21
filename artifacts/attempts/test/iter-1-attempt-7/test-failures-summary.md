# Test stage summary

- failed: tests/e2e/parity-local-vs-ci-test.sh
- verdict: fail
- passed: 916
- failed: 1
- exit_code: 1

## Failing files

- tests/e2e/parity-local-vs-ci-test.sh — ✗ event sequence matches golden snapshot — golden mismatch (run UPDATE_GOLDEN=1 to regenerate) (and 1 more failing check in this file)

## Failing lines (extracted)

```
  ✗ event sequence matches golden snapshot ⏎ golden mismatch (run UPDATE_GOLDEN=1 to regenerate)
  ✗ event sequence matches golden snapshot
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zocGNj/tests/e2e/parity-local-vs-ci-test.sh
  ✓ all artifact contents identical across modes (sha256, timestamps normalized)
  ✓ normalized state.json matches golden snapshot
  ✓ artifact filename list matches golden snapshot
  ──────────────────────────────────────────
  1 of 15 tests failed
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, and the design names it nowhere — not in a step, a SPEC, WIRING or its text: nothing asks for this change — take it out, or name what asks for it
