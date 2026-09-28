## issue-acceptance — fail

- The SPEC-23 assertions added to `tests/integration/deployed-template-e2e-test.sh` are inert — the acceptance-gate confirms that reverting those changes breaks no TESTFILE assertions, meaning the test does not exercise the non-default `ZBUILD_ARTIFACT_DIR` path in a way that fails without the implementation.

- NOT MET: result written to ZBUILD_ARTIFACT_DIR (non-default path) verified by a live integration test — the wiring for SPEC-23 in tests/integration/deployed-template-e2e-test.sh is inert
