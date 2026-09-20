# Test stage summary

- verdict: fail
- passed: 688
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dQIieO/tests/integration/engine-isolation-test.sh (exceeded 480s, rc=124)
  [38;2;74;222;128m✓[0m [SPEC-2] refusal names both roots, the install remedy, and the override
  [38;2;74;222;128m✓[0m [SPEC-3] --dev-engine permits the run and warns about mid-run edits
  [38;2;74;222;128m✓[0m [SPEC-4] ZBUILD_DEV_ENGINE=1 is an equivalent escape hatch
  [38;2;74;222;128m✓[0m [SPEC-5] engine outside the target repo is permitted (installed shape)
  [38;2;74;222;128m✓[0m [SPEC-6] non-pipeline subcommands are unaffected by the guard
  [38;2;74;222;128m✓[0m [SPEC-7] the guard still refuses when the engine is reached via a symlink
```
