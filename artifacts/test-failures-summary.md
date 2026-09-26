# Test stage summary

- verdict: fail
- passed: 738
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m all tiers free of the printf|grep -q SIGPIPE antipattern
    [2mfound 1 occurrence(s); see list above (#1015, #1260)[0m
[38;2;248;113;113m[1m✗[0m validate: missing required input deploy-result.json
  [38;2;248;113;113m✗[0m [SPEC-9] validate_agent_run exits 0 in dry-run
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-9] validate-result.json verdict=healthy
    [2mexpected: healthy, got: error[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zB2fnx/tests/unit/sigpipe-antipattern-guard-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zB2fnx/tests/integration/per-run-state-isolation-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zB2fnx/tests/integration/deployed-template-e2e-test.sh
  [38;2;74;222;128m✓[0m [#1884] grep without -q             -> NOT an offender
  [38;2;0;212;255m[#1886] every '| head' is converted or justified[0m
  [38;2;74;222;128m✓[0m [#1886] no unjustified '| head' in scripts/, core/ or plugins/
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 9 tests failed[0m
[38;2;0;212;255m[1m  per-run state isolation (#887)[0m
[2m  ══════════════════════════════════════════[0m
  [38;2;74;222;128m✓[0m T1: run-aaa exits 0
/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zB2fnx/plugins/agent/validate/plugin.sh: line 74: ZBUILD_STAGE_INPUTS: unbound variable
  [38;2;74;222;128m✓[0m [SPEC-9] monitor_stage_run exits 0 in dry-run
  [38;2;74;222;128m✓[0m [SPEC-9] monitor-report.json written
  [38;2;248;113;113m[1m2 of 25 tests failed[0m
```
