## issue-acceptance — fail

- The test suite reports 2 failures — a regression on the hard-kill release exit path and the persist always_run hook never entering — and the installed-tree testing required by R-4 is absent from the delivered test.

- NOT MET: R-4: `orch-backend-misconfigured-test.sh` tests `orch_load_backend` by sourcing it from the checkout in isolation
- NOT MET: the issue explicitly requires testing from the installed tree (`install.sh` layout), not only the checkout — no such end-to-end test exists
- NOT MET: R-5: `always-run-exit-paths-test.sh` [#1801/SPEC-5] persist hook was never entered (sentinel file absent, runner exited in 0 s without dispatching the persist always_run stage)
- NOT MET: `runner-release-exit-paths-test.sh` [SPEC-5] release cleanup not dispatched on the hard-kill exit path (regression)
- NOT MET: R-9: `npm test` exits 1 with 2 failing tests
- NOT SURE: R-7: test scope discovery (grep-rl for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, `_orch_local_kill_slot` in `tests/`) — process requirement that nothing in the diff or output confirms was completed — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
