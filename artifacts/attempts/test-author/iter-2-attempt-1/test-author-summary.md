## test-author — unusable

- changed 2 test file(s); 4 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: config/adr-enforcement-baseline.txt was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it: done — added `[#1764/DSADR-7]` assertions to `tests/unit/lint-adr-enforced-by-test.sh`; they fail on base code (ADR-005 is in the baseline, no `## Enforced by` section) and pass once the change removes the entry and adds the section.
- answered: issue-acceptance finding 1: The issue requires this and the change does not meet it: RQCLA-2: `_ZBUILD_CLAIM_HOLDER` is set by `zbuild_claim_acquire` (in `core/claim/claim.sh`) AFTER the run-status sidecar is already spawned: not mine — this is an implementation defect in `core/pipeline/runner.sh` (spawning the sidecar before the claim is set). My DSCLA-2 and DSCLA-12 tests correctly test the renderer's behavior (calling `rsc_render_header` in-process with the variable set), which is what the SPEC requires of the render function. Fixing the sidecar spawn ordering belongs to the code stage.
- not answered: test-author finding 1
- not answered: acceptance-gate finding 1
- not answered: issue-acceptance finding 1
