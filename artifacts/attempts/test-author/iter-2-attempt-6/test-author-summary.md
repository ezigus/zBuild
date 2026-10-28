## test-author — timed_out

- the author did not finish (router_timeout) — what it wrote is kept for the next attempt

- SPECs in the contract: 6
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/run-timed-out-test.sh — SPEC-1
- tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6
- tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3
- tests/integration/resume-after-run-timeout-test.sh — SPEC-4
- Each [code] requirement's test fails on the code as it is now, and passes once the code is written.
