## test-author — fail

- changed 4 test file(s); 3 assertion(s) still do not test what their SPEC says after 2 round(s)

- SPECs in the contract: 8
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/unit/test-plugin-result-write-fallback-test.sh — SPEC-1
- tests/unit/test-result-reason-contract-test.sh — SPEC-2
- plugins/agent/intake/tests/intake-result-test.sh — SPEC-3, SPEC-4
- tests/unit/plugin-primary-output-atomic-test.sh — SPEC-5, SPEC-6, SPEC-7, SPEC-8
- Each [code] requirement's test fails on the code as it is now, and passes once the code is written.
