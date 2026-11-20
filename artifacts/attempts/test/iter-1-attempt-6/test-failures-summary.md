# Test stage summary

- failed: plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh
- verdict: fail
- passed: 914
- failed: 3
- exit_code: 1

## Failing files

- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — ✗ claimed label contains 'claimed:' prefix — zbuild:claimed (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.yHKulZ/plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh
[event-bus] WARN: unknown event type 'plugin.release.complete' (run_id=run-dscla2-123)
  [38;2;74;222;128m✓[0m [DSCLA-21] coordinator's release hook was called (zbuild:claimed removed from claim store)
  [38;2;74;222;128m✓[0m [DSCLA-21] gh is not invoked directly within zbuild_claim_release
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 36 tests failed[0m
  [38;2;248;113;113m✗[0m claimed label contains 'claimed:' prefix
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.yHKulZ/tests/e2e/claim-race-test.sh
  [38;2;248;113;113m✗[0m 3-way race must produce ≤1 winner
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.yHKulZ/tests/e2e/parity-local-vs-ci-test.sh
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
