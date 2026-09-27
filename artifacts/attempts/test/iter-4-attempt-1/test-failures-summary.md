# Test stage summary

- verdict: fail
- passed: 740
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m all tiers free of the printf|grep -q SIGPIPE antipattern
    [2mfound 1 occurrence(s); see list above (#1015, #1260)[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.1dwZVn/tests/unit/sigpipe-antipattern-guard-test.sh
  [38;2;74;222;128m✓[0m [#1884] grep without -q             -> NOT an offender
  [38;2;0;212;255m[#1886] every '| head' is converted or justified[0m
  [38;2;74;222;128m✓[0m [#1886] no unjustified '| head' in scripts/, core/ or plugins/
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 9 tests failed[0m
```
