# Test stage summary

- verdict: fail
- passed: 26
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m flag-on: monitor mode ON in runner shell
    [2mgot: dash=huB
  [38;2;248;113;113m✗[0m [SPEC-6b] a hook child that ignores TERM does not outlive the run
    [2mpid 3300836 still alive 5s after the runner returned[0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-10] plugin_hook_call has no hand-rolled TERM/KILL for stage dispatch
    [2mfound:         kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true — replace with zbuild_pg_kill[0m
unit: FAIL tests/integration/runner-job-control-abort-test.sh
unit: FAIL tests/integration/runner-release-exit-paths-test.sh
unit: FAIL tests/unit/stage-timeout-dispatch-test.sh
  [38;2;74;222;128m✓[0m status=interrupted
  [38;2;74;222;128m✓[0m pipeline.aborted reason=sigterm emitted
  [38;2;74;222;128m✓[0m no job-control errors in stderr
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;0;212;255mSPEC-6b: a hook child that ignores TERM does not outlive the run[0m
  [38;2;248;113;113m[1m1 of 17 tests failed[0m
  [38;2;74;222;128m✓[0m orch-mock plugin exists (backend-agnostic watchdog can be tested with it)
  [38;2;0;212;255morch-ruflo-hive/plugin.sh has no TERM/KILL for stage dispatch[0m
  [38;2;74;222;128m✓[0m orch-ruflo-hive/plugin.sh carries no TERM/KILL for stage dispatch
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
```
