## issue-acceptance — fail

- The build stage timed out after changing only 1 file, leaving the implementation incomplete; `npm test` returns 17 failures including explicit SPEC-5 failures in `always-run-exit-paths-test.sh` proving `_runner_dispatch_always_run` still does not bound always-run stages by `timeout_s:`.

- NOT MET: R-5: `always-run-exit-paths-test.sh` fails "a 60s release hook held the exit" / "the hanging hook was killed before completing" — always_run stages are not bounded by `timeout_s:`
- NOT MET: R-9: `npm test` red (17 integration failures across core-pipeline-runner, design-pipeline, worktree-run-isolation, cycle tests, and others)
- NOT MET: R-1: broad pipeline integration failures cast doubt on orchestrator-route timeout enforcement reaching a working state
- NOT MET: R-2: strategy files (`fanout.sh`, `map.sh`, `sequential.sh`) are listed in changed-files but absent from the diff — `ZBUILD_ORCH_TIMEOUT` removal is unverifiable with a broken test suite
- NOT MET: R-4: installed-tree misconfigured test not present in diff and pipeline is broken
- NOT MET: R-6: `zbuild_pg_kill` wiring in `_orch_local_kill_slot` and the always-run watchdog not visible in the diff and unconfirmable against a failing suite.
