## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Extended DSADR-7 to explicitly cover the §2 Enforced by bullet. DSADR-7 now reads: "ADR-005 has an ## Enforced by section with the §1 bullet extended to include §1(c)'s tests (claim-coordinator-unit-test.sh [DSCLA-3]: refused — non-zero exit, no stage, event emitted; teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder), and the §2 bullet extended to include [DSCLA-12] for the CI holder rendering case covers: RQADR-4"
- answered: test-author finding 1: done — Reverted DSCLA-10 to the iter-3-attempt-1 formulation that passed the design check. The Then was "the string is found in the file" — explicitly disallowed by the SPEC rules ("never what a file contains"). The correct formulation has `Given: zbuild:claimed is on the issue`, `When: the run is refused and emits pipeline.refused.claimed`, `Then: the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event`. This is an observable outcome (the check's pass/fail result), not file content. The test-author must write the test to run the coverage check as the SPEC describes, not replace it with a grep of the JSON file.
- not answered: design finding 2
