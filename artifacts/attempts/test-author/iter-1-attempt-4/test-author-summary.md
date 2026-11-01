## test-author — pass

- changed 1 test file(s); acceptance assertions for 6 SPEC(s) from the design contract

- SPECs in the contract: 6
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- plugins/agent/intake/tests/intake-result-test.sh — SPEC-3, SPEC-4
- tests/unit/plugin-primary-output-atomic-test.sh — SPEC-5, SPEC-6, SPEC-7, SPEC-8
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: check finding 1: done — changed SPEC-7 assertion from a whole-file grep to a two-step check: extract only the `"lint"` key's line, then check that line for the invocation; now fails if the string is in any other target
