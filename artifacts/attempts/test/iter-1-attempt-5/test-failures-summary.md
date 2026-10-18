# Test stage summary

- verdict: fail
- passed: 804
- failed: 2
- exit_code: 1

## Failing files

- tests/unit/dispatch-rc-guard-test.sh — ✗ [SPEC-1] core/plugin-registry/lifecycle.sh GREW a private rc (0 → 2)
- tests/unit/stage-timeout-precedence-test.sh — ✗ [#1801/SPEC-3] isolation: plugin_hook_call spawns 'sleep 5400' watchdog when no template value and no ZBUILD_STAGE_TIMEOUT_S

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-1] core/plugin-registry/lifecycle.sh GREW a private rc (0 → 2)
    [2mA new engine path returns an rc outside {0,1}. rc carries two facts (ADR-054 §4): result on disk (0), failed (1). Put what you were encoding on a declared channel — disposition (core/pipeline/disposition.sh) for recoverability, routing state (ADR-045) for the backward edge.[0m
  [38;2;248;113;113m✗[0m [SPEC-2] plugin_hook_call returns nothing outside {0,1}
    [2mexpected: 0, got: 2[0m
  [38;2;248;113;113m✗[0m [SPEC-7] lifecycle.sh still has 0 legacy rc returns after write-boundary wiring (#1809)
  [38;2;248;113;113m✗[0m [#1801/SPEC-3] isolation: plugin_hook_call spawns 'sleep 5400' watchdog when no template value and no ZBUILD_STAGE_TIMEOUT_S
    [2mno 'sleep 5400' captured in fake-sleep log — pre-change: no watchdog; post-change: must spawn 'sleep 5400' as default[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.CIkzRB/tests/unit/dispatch-rc-guard-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.CIkzRB/tests/unit/stage-timeout-precedence-test.sh
  [38;2;74;222;128m✓[0m [SPEC-17] parallel_dispatch_stage checks for an abort before plugin_hook_call
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 36 tests failed[0m
  [38;2;0;212;255m[#1801/SPEC-3] isolation: 5400 s default confirmed by running plugin_hook_call[0m
  [38;2;248;113;113m[1m1 of 6 tests failed[0m
```
