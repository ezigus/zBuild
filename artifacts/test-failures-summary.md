# Test stage summary

- failed: tests/unit/lint-grep-c-test.sh
- verdict: fail
- passed: 909
- failed: 2
- exit_code: 1

## Failing files

- tests/unit/lint-grep-c-test.sh — ✗ [SPEC-5] real scripts/ core/ plugins/ tree is clean — expected: 0, got: 1 (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.iT2dos/tests/unit/lint-grep-c-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 21 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
validate-mechanics-yaml: OK — 18 mechanics validated
lint-doc-freshness: OK — 39 plugin(s), 18 mechanic(s) — all checks passed.
lint-action-versions: OK — no action version drift detected.
lint-grep-c: plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh:419 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _dscla10_emitted_note="(runner emits it: $(grep -cF 'pipeline.refused.claimed' "$_dscla10_runner" 2>/dev/null || echo 0) occurrence(s))"
lint-grep-c: 1 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.
    [2mexpected: 0, got: 1[0m
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — config/shape-change-paths.txt was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
