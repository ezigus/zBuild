## issue-acceptance — fail

- The diff adds e2e tests for SPEC-4/SPEC-10 and static template assertions for SPEC-5, but `runner.sh` still contains no `_ZBUILD_ORCH_BACKEND_DISPOSITION` gate (the core implementation change those tests require), so five of the new assertions fail immediately, the always-run persist hook is still not dispatched at runtime (SPEC-5 behavioral failure), and the test suite exits non-zero.

- NOT MET: R-4: tests added but implementation gate absent from runner.sh — e2e output shows `backend.missing: orchestrator=sequential` not `misconfigured bash-parallel`, confirming the disposition check never runs
- NOT MET: R-5: `[#1801/SPEC-5] persist hook was entered` still fails — the always_run persist stage is not dispatched at runtime, the static template assertions pass vacuously without exercising the watchdog path
- NOT MET: R-9: TEST VERDICT is fail, exit_code 1, five assertions red
