# Test stage summary

- failed: tests/unit/lint-grep-c-test.sh
- verdict: fail
- passed: 892
- failed: 2
- exit_code: 1

## Failing files

- tests/unit/lint-grep-c-test.sh — ✗ [SPEC-5] real scripts/ core/ plugins/ tree is clean — expected: 0, got: 1 (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.y1CLyw/tests/unit/lint-grep-c-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 21 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
lint-action-versions: OK — no action version drift detected.
lint-grep-c: tests/unit/route-loop-terminated-reasons-test.sh:159 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _dslock1_nds="$(grep -c '_ROUTE_LOOP_TERMINATED_REASON="no_done_sentinel"' "$_route_sh" 2>/dev/null || echo 0)"
lint-grep-c: tests/unit/route-loop-terminated-reasons-test.sh:168 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _dslock1_rot="$(grep -c '"router_out_of_turns"' "$_classify_sh" 2>/dev/null || echo 0)"
lint-grep-c: 2 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.
    [2mexpected: 0, got: 1[0m
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — plugins/agent/build/plugin.sh is not changed by this change — name a file the change touches, or write WIRING: none
