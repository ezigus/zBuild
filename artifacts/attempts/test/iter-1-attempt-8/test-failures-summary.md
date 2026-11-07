# Test stage summary

- failed: tests/integration/cycle-member-dispatch-events-test.sh, tests/integration/resume-rehydrate-test.sh
- verdict: fail
- passed: 880
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/cycle-member-dispatch-events-test.sh — ✗ [#1805/FRSH-1] fresh cycle run: cycle member stages (build, review) emit stage.start (dispatched from stage 1; _cd_iter > 0 guard fires at iter 1) — expected: 2, got: 0 (and 1 more failing check in this file)
- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/FRSH-2] cycle stage cyc dispatched on fresh run (cycle.start emitted; dispatch-unit skip guard conditional on resume_mode — does not silently skip cyc) — expected >0, got: 0 (and 1 more failing check in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.VfZRuC/tests/integration/cycle-member-dispatch-events-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.VfZRuC/tests/integration/resume-rehydrate-test.sh
  [38;2;74;222;128m✓[0m an inner LEAF member still reports its own disposition
  [38;2;74;222;128m✓[0m review NOT dispatched after a failing inner cycle (#1208 halt, no rescue)
  [38;2;74;222;128m✓[0m outer cycle halts rc=1, outcome failed, reason blocking_member_failure (propagated)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 25 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/FRSH-1] fresh cycle run: cycle member stages (build, review) emit stage.start (dispatched from stage 1; _cd_iter > 0 guard fires at iter 1)
  [38;2;0;212;255mresume-rehydrate test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m [#1805/CYCL-1] resume-rehydrate (RHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle
  [38;2;74;222;128m✓[0m resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)
  [38;2;248;113;113m[1m1 of 47 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/FRSH-2] cycle stage cyc dispatched on fresh run (cycle.start emitted; dispatch-unit skip guard conditional on resume_mode — does not silently skip cyc)
    [2mexpected: 2, got: 0[0m
    [2mexpected >0, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
