# Test stage summary

- verdict: fail
- passed: 116
- failed: 5
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1806/SPEC-6] [SPEC-4] external execs ≤ FORK_BUDGET
    [2m5111 > 4500 — see the call sites above; ADR-065 §2: the budget only ratchets down[0m
  [38;2;248;113;113m✗[0m [SPEC-3] …and PATCHes the persisted id
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [#1806/SPEC-3] first PATCH fired (setup)
    [2mno PATCH in GH_LOG[0m
  [38;2;248;113;113m✗[0m [#1806/SPEC-4] first PATCH fired (setup)
  [38;2;248;113;113m✗[0m [SPEC-8] no eb_emit_event in the sidecar
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-8] the sidecar never sources the event bus
    [2mexpected: 0, got: 3[0m
  [38;2;248;113;113m✗[0m forced-fail: test.result_write.fallback event emitted
    [2mevents.jsonl: [0m
unit: FAIL tests/e2e/fork-budget-test.sh
unit: FAIL tests/unit/cli-status-comment-test.sh
unit: FAIL tests/unit/run-status-comment-loop-test.sh
unit: FAIL tests/unit/run-status-comment-render-test.sh
unit: FAIL tests/unit/test-plugin-result-write-fallback-test.sh
tests/e2e/fork-budget-test.sh: line 78: BASH_XTRACEFD: 7: invalid value for trace file descriptor
  [38;2;74;222;128m✓[0m [SPEC-6] …and no counted pool line runs more than once per work unit (max 1)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-4] unknown run id → rc 1
  [38;2;74;222;128m✓[0m [SPEC-4] names the run id
  [38;2;74;222;128m✓[0m [SPEC-4] no gh call
  [38;2;74;222;128m✓[0m [#1806/SPEC-5] sidecar emitted at least one event to its events file
  [38;2;74;222;128m✓[0m [#1806/SPEC-5] all sidecar events carry stage=run-status-comment
  [38;2;248;113;113m[1m2 of 29 tests failed[0m
  [38;2;248;113;113m[1m2 of 48 tests failed[0m
  [38;2;0;212;255m9. test.result_write.fallback declared by the test plugin's manifest[0m
  [38;2;74;222;128m✓[0m schema: test.result_write.fallback declared in provides.events
  [38;2;74;222;128m✓[0m schema: test.result_write.fallback is in the composed known set
  [38;2;248;113;113m[1m1 of 41 tests failed[0m
```
