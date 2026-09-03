# Test stage summary

- verdict: fail
- passed: 666
- failed: 4
- exit_code: 1

## Failing lines (extracted)

```
  FAIL  registry-role-resolution.md  (no-op patch)
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/tests/unit/design-router-timeout-reiter-test.sh
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: router loop timed out (reason=router_timeout) — writing gate-failing marker to re-iterate
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
  [38;2;74;222;128m✓[0m [SPEC-1] timeout marker FAILS the design-gate (ACCEPTANCE_MISSING) → re-iterate
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: router rc=137 → verdict=error reason=router_oom_kill
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
  [38;2;248;113;113m✗[0m [SPEC-10-guard] spurious did_not_finish sidecar on happy path
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: router loop timed out (reason=router_timeout) — writing gate-failing marker to re-iterate
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: failed to write timeout marker to /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-tier-buf.JCMvYk/tmp-unit/design-router-timeout-reiter.iHhSr8/t4/state/artifacts/design.md
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/590611/events.db": unable to open database file
  [38;2;248;113;113m✗[0m [SPEC-10-guard] spurious did_not_finish sidecar on happy path
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/tests/unit/design-budget-prompt-injection-test.sh
  [38;2;248;113;113m✗[0m [SPEC-8] scope charter missing from prompt
    [2mexpected 'MUST actively search the repo'[0m
  [38;2;248;113;113m✗[0m [SPEC-8] scope charter missing from prompt
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/tests/unit/design-v2-result-contract-test.sh
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/1541122/events.db": unable to open database file
  [38;2;248;113;113m✗[0m [SPEC-1] sidecar written before atomic_write of design.md
    [2mexpected: PRESENT, got: UNSET[0m
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: plan.json not found at /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-tier-buf.JCMvYk/tmp-unit/design-v2-result-contract.CaO0GO/t2/state/artifacts/plan.json
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/1541122/events.db": unable to open database file
[38;2;248;113;113m[1m✗[0m _design_stage_run_inner: router loop timed out (reason=router_timeout) — writing gate-failing marker to re-iterate
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/1541122/events.db": unable to open database file
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/1541122/events.db": unable to open database file
[event-bus] WARN: sqlite3 failed: Error: unable to open database "/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/.zbuild-nested-state/ephemeral-events/1541122/events.db": unable to open database file
  [38;2;248;113;113m✗[0m [SPEC-1] sidecar written before atomic_write of design.md
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.jYyF0q/tests/e2e/parity-local-vs-ci-test.sh
  [38;2;248;113;113m✗[0m event type sequence identical in local and CI modes
    [2mexpected: memory.backend.init
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
  [38;2;248;113;113m✗[0m event type sequence identical in local and CI modes
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
```
