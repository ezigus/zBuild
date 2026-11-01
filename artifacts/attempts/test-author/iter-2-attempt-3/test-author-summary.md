## test-author — pass

- changed 2 test file(s); acceptance assertions for 7 SPEC(s) from the design contract

- SPECs in the contract: 7
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/unit/test-plugin-result-write-fallback-test.sh — SPEC-1
- tests/unit/test-result-reason-contract-test.sh — SPEC-2
- plugins/agent/intake/tests/intake-result-test.sh — SPEC-4
- tests/unit/plugin-primary-output-atomic-test.sh — SPEC-5, SPEC-6, SPEC-7, SPEC-8
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: done** — Fixed the SPEC-1 mock in `test-plugin-result-write-fallback-test.sh` to fail ALL `atomic_write` calls (removed `_1754s1_aw_calls` counter and `if -eq 1` conditional). With all calls failing, old code's fallback `| atomic_write` is also intercepted → `&&` short-circuits → `stage_result_add` not called → prior-round pass survives → assertion `expected broken` fails on old code.
- answered: issue-acceptance finding 1: nothing to do** — SPEC-4 assertions in `intake-result-test.sh` correctly FAIL on old code (no implementation yet); this is the expected state for a test-author stage. The 3 failures (`_intake_run_inner returns non-zero on intake.md failure`, `outcome=broken`, `reason names intake.md`) verify the test is well-written. The code stage must provide the implementation.
- answered: issue-acceptance finding 2: nothing to do** — SPEC-2 uses `runner_read_stage_disposition` which is exactly what the SPEC-2 requirement text specifies ("runner_read_stage_disposition returns broken (not complete)"). The test is correct.
