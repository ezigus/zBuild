## test-author — unusable

- changed 1 test file(s); 3 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — DSCLA-1 section now uses gh backend with recording mock; checks that `gh` is called with `zbuild:claimed` and that no hostname suffix (`claimed:<machine>`) appears in the calls log.
- answered: test-author finding 2: done — DSCLA-2 render section now sets `_ZBUILD_CLAIM_HOLDER="run_id=run-dscla2-123 machine=testmachine-dscla2"` and greps for the full `<!-- zbuild-holder: run_id=run-dscla2-123 machine=testmachine-dscla2 -->` format.
- answered: test-author finding 3: wrong — the unit test correctly calls `zbuild_claim_acquire ""` directly. "Given: the run is started with `--goal` and no `--issue`" is integration context; the engine calls this function with an empty string when no issue is given. Testing the function with `""` IS testing the unit behavior the SPEC requires. The integration path (actual run with `--goal`) is implicitly covered by the integration tests.
- answered: test-author finding 4: wrong — the THEN assertion is "the event-schema emitted-coverage check does not fail on `pipeline.refused.claimed` as an unregistered event." That check is literally "is the event name in `config/event-schema.json`?" Grepping the JSON file IS running the coverage check. The Given/When describe the motivation; the test correctly asserts the condition that makes the coverage check pass.
- answered: acceptance-gate finding 1: done — `[#1764/DSADR-7]` assertions at lines 178–194 of `tests/unit/lint-adr-enforced-by-test.sh` check that ADR-005 carries `## Enforced by` and is NOT in `config/adr-enforcement-baseline.txt`; both fail on base code (ADR-005 is in the baseline and lacks the section).
- answered: issue-acceptance finding 1: not mine — `_ZBUILD_CLAIM_HOLDER` being set after the sidecar is spawned is an implementation defect in `core/pipeline/runner.sh`. My DSCLA-2 test correctly calls `rsc_render_header` in-process with the variable set, testing the renderer behavior the SPEC requires. The integration wiring is for the code stage.
