## test-author — timed_out

- the author did not finish (router_timeout) — what it wrote is kept for the next attempt

- SPECs in the contract: 10
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-13
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-13
- tests/integration/resume-loop-state-test.sh — SPEC-7, SPEC-13
- tests/integration/resume-entry-points-test.sh — SPEC-9, SPEC-13
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
