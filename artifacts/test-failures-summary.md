# Test stage summary

- verdict: fail
- passed: 835
- failed: 7
- exit_code: 1

## Failing files

- tests/unit/cli-status-comment-test.sh — ✗ [SPEC-3] …and PATCHes the persisted id — expected: 1, got: 0
- tests/unit/lint-grep-c-test.sh — ✗ [SPEC-5] real scripts/ core/ plugins/ tree is clean — expected: 0, got: 1
- tests/unit/run-status-comment-loop-test.sh — ✗ [#1806/SPEC-3] first PATCH fired (setup)
- tests/unit/run-status-comment-render-test.sh — ✗ [SPEC-8] no eb_emit_event in the sidecar — expected: 0, got: 1
- tests/unit/test-plugin-result-write-fallback-test.sh — ✗ forced-fail: test.result_write.fallback event emitted

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-3] …and PATCHes the persisted id
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [#1806/SPEC-3] first PATCH fired (setup)
    [2mno PATCH in GH_LOG[0m
  [38;2;248;113;113m✗[0m [#1806/SPEC-4] first PATCH fired (setup)
  [38;2;248;113;113m✗[0m [SPEC-8] no eb_emit_event in the sidecar
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-8] the sidecar never sources the event bus
    [2mexpected: 0, got: 3[0m
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
  [38;2;248;113;113m✗[0m forced-fail: test.result_write.fallback event emitted
    [2mevents.jsonl: [0m
  [38;2;248;113;113m✗[0m [SPEC-4] external execs ≤ FORK_BUDGET
    [2m5110 > 4500 — see the call sites above; ADR-065 §2: the budget only ratchets down[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/unit/cli-status-comment-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/unit/run-status-comment-loop-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/unit/run-status-comment-render-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/unit/lint-grep-c-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/unit/test-plugin-result-write-fallback-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-4] unknown run id → rc 1
  [38;2;74;222;128m✓[0m [SPEC-4] names the run id
  [38;2;74;222;128m✓[0m [SPEC-4] no gh call
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;74;222;128m✓[0m [#1806/SPEC-5] sidecar emitted at least one event to its events file
  [38;2;74;222;128m✓[0m [#1806/SPEC-5] all sidecar events carry stage=run-status-comment
  [38;2;248;113;113m[1m2 of 29 tests failed[0m
  [38;2;248;113;113m[1m2 of 48 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
  [38;2;0;212;255m9. test.result_write.fallback declared by the test plugin's manifest[0m
  [38;2;74;222;128m✓[0m schema: test.result_write.fallback declared in provides.events
  [38;2;74;222;128m✓[0m schema: test.result_write.fallback is in the composed known set
  [38;2;248;113;113m[1m1 of 41 tests failed[0m
validate-mechanics-yaml: OK — 18 mechanics validated
lint-doc-freshness: OK — 56 plugin(s), 18 mechanic(s) — all checks passed.
lint-action-versions: OK — no action version drift detected.
lint-grep-c: tests/unit/run-status-comment-loop-test.sh:336 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _sc5_event_count="$(grep -c '' "$SC5_EVENTS" 2>/dev/null || echo 0)"
lint-grep-c: 1 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8Cal2Q/tests/e2e/fork-budget-test.sh
```
