# Test stage summary

- verdict: fail
- passed: 742
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh (exceeded 480s, rc=137) — timed out before finishing (last check that passed: [SPEC-7] the reported member is re-run rather than reused (5 vs 1 without the report))

## Failing lines (extracted)

```
unit: TIMEOUT /Users/ericziegler/.zbuild/repos/ezigus/zBuild/issues/1847/runs/20260928144733-57620/scratch/test/zbuild-test-stage.1Y1fSa/tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh (exceeded 480s, rc=137)
health: progress=0 (no progress) - defects=0 → score=0
── end stage-io: build_test_cycle ✓ ──
  [38;2;74;222;128m✓[0m [SPEC-7] the reported member is re-run rather than reused (5 vs 1 without the report)
  [38;2;0;212;255mSPEC-6: a denied scope request routes back to design instead of ending the run[0m
══ build_test_cycle [cycle] seq=1 input ════════════════════════ 19:23:47 UTC ══
(no feedback — first iteration)
  [38;2;0;212;255mSPEC-5: empty_diff on the tree a previous iteration FAILED ⇒ that failure is reused, not re-run[0m
  [38;2;74;222;128m✓[0m [SPEC-5] the FAILING test member is dispatched exactly ONCE across 5 iterations
  [38;2;74;222;128m✓[0m [SPEC-5b] the FAILING acceptance-gate (iteration-aware) is re-dispatched every iteration
```
