# Test stage summary

- verdict: fail
- passed: 742
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/state-root-isolation-test.sh — ✗ Pipeline cannot start — inputs missing for declared stages:

## Failing lines (extracted)

```
    ✗ Pipeline cannot start — inputs missing for declared stages:
    ✗ Pipeline failed: status=failed stage=intake rc=1 run_id=nested-suite issue=96990001 (took 1.9s)
    ✗ Stage intake failed (rc=1, finished 19:51:08 UTC · 1.4s)
  DIAGNOSTIC: copied state: {  "schema_version": 1,  "run_id": "nested-suite",  "issue": 96990001,  "engine_sha": "887c1f4c09cc08040828c3639c861fc3e7eb6c0f",  "engine_branch": "zbuild/issue-1847-phase-0-f-migrate-the-monitor-plugin-to",  "stage_statuses": {    "intake": "failed"  },  "current_iteration": 0,  "self_heal_count": {},  "scope_manifest_hash": "",  "cost_ledger_pointer": 0,  "claim_lease_id": "",  "plugin_state": 
  [38;2;248;113;113m✗[0m [SPEC-7] nested run used the fixture roster
    [2mstage_statuses keys=intake (expected the intake→build fixture, not the built-in fallback)[0m
integration: FAIL /Users/ericziegler/.zbuild/repos/ezigus/zBuild/issues/1847/runs/20260928144733-57620/scratch/test/zbuild-test-stage.wZkPsG/tests/integration/state-root-isolation-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 21 tests failed[0m
```
