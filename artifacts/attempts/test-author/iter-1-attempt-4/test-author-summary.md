## test-author — interrupted

- the author did not finish (signal) — what it wrote is kept for the next attempt

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/orch-timeout-applies-test.sh — SPEC-1
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5
- tests/integration/always-run-exit-paths-test.sh — SPEC-5
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh — SPEC-6
- tests/unit/lint-adr-enforced-by-test.sh — SPEC-7
- plugins/tool/orch-mock/tests/orch-mock-test.sh — SPEC-11
- tests/unit/adr059-no-tmpdir-defaults-test.sh — SPEC-12
- tests/unit/core-orch-run-id-isolation-test.sh — SPEC-12
- tests/unit/dispatch-rc-guard-test.sh — SPEC-12
- tests/unit/stdin-spawn-guard-test.sh — SPEC-12
- tests/unit/summary-mandatory-test.sh — SPEC-12
- Each [code] requirement's test fails on the code as it is now, and passes once the code is written.
