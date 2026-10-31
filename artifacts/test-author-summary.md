## test-author — fail

- changed 1 test file(s); 1 assertion(s) still do not test what their SPEC says after 2 round(s)

- SPECs in the contract: 8
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/unit/test-plugin-result-write-fallback-test.sh — SPEC-1
- tests/unit/test-result-reason-contract-test.sh — SPEC-2
- plugins/agent/intake/tests/intake-result-test.sh — SPEC-3, SPEC-4
- tests/unit/plugin-primary-output-atomic-test.sh — SPEC-5, SPEC-6, SPEC-7, SPEC-8
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: round-2-checker finding 1: done — changed SPEC-2's primary assertion from `_classify` returning "error" to `runner_read_stage_disposition` returning "broken"; `runner_read_stage_disposition` in verdict.sh returns the string "broken" when the result file carries `outcome=broken`, directly establishing the requirement's claim "returns broken"; confirmed the test fails on unfixed code (via git stash) and passes on the fixed codebase.
