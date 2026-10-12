## issue-acceptance — fail

- `npm test` fails with 21 tests — `runner-release-exit-paths-test.sh` SPEC-6b directly fails (child ignoring TERM outlives the run), `orch-sequential-retired-guard-test.sh` fails because the new file `tests/unit/orch-backend-misconfigured-test.sh` references "orch-sequential" in its prose and the guard's exclusion list does not cover it, and removing the orch-sequential fallback without ensuring bash-parallel is always resolvable in test contexts breaks `orch_spawn` on every integration test pipeline path.

- NOT MET: R-2: runner-release-exit-paths-test SPEC-6b fails — a hook child ignoring TERM outlives the run under the new watchdog
- NOT MET: R-8: orch-sequential-retired-guard-test fails — tests/unit/orch-backend-misconfigured-test.sh references "orch-sequential" in its comment text, the guard's exclusion list does not cover this new test file
- NOT MET: R-1: broad integration pipeline failures (orch_spawn not implemented in test contexts — bash-parallel not found, hard-error path fires) mean the hung-hook watchdog is unreachable on most dispatch routes under test
- NOT MET: R-13: npm test fails (21 tests fail, including 16 integration tests)
- NOT MET: additionally, orch.backend.misconfigured and plugin.run.timed_out are not registered in event-schema.json (event-schema-emitted-coverage-test.sh fails), and set -m inside plugin_hook_call leaks into the runner shell (runner-job-control-abort-test.sh fails)
- NOT SURE: R-11: design-prompt-scope-charter-test.sh fails because design stage_timeout_s=3900 was not in the grep-rl scope (the test pinned design.timeout_s=600 and was not found or updated), suggesting the pre-coding grep-rl search missed at least one pinning test — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
