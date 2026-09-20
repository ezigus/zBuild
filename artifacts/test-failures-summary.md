# Test stage summary

- verdict: fail
- passed: 686
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
    [2mexpected: 0, got: 1[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.BGivWm/tests/unit/lint-grep-c-test.sh
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.BGivWm/tests/integration/engine-isolation-test.sh (exceeded 480s, rc=124)
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-2] refusal names both roots, the install remedy, and the override
  [38;2;74;222;128m✓[0m [SPEC-3] --dev-engine permits the run and warns about mid-run edits
  [38;2;74;222;128m✓[0m [SPEC-4] ZBUILD_DEV_ENGINE=1 is an equivalent escape hatch
  [38;2;74;222;128m✓[0m [SPEC-5] engine outside the target repo is permitted (installed shape)
  [38;2;74;222;128m✓[0m [SPEC-6] non-pipeline subcommands are unaffected by the guard
  [38;2;74;222;128m✓[0m [SPEC-7] the guard still refuses when the engine is reached via a symlink
    _1840_s21_count="$(grep -c '^[[:space:]]*-[[:space:]]' <<< "$_1840_s21_events" 2>/dev/null || echo 0)"  lint-grep-c: 1 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with 
```
