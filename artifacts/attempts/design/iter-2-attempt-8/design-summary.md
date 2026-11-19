## design — fail

- the design fails 2 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — Rewrote DSCLA-8 Given/When to describe the unit-level behavior: "Given: core/claim/claim.sh is loaded / When: zbuild_claim_acquire is called with an empty string as the issue argument." The old integration-level phrasing ("the run is started with --goal and no --issue") is replaced with the unit behavior the test-author correctly implemented. The Then/And assertions are unchanged.
- answered: test-author finding 2: done — Rewrote DSCLA-10 to drop the "event-schema emitted-coverage check runs against the codebase" framing. RQCLA-10 requires the event to be registered in `config/event-schema.json`; checking the file directly for the event name string is both sufficient and what the test-author implemented. New When/Then: "When: config/event-schema.json is read / Then: the file contains an entry for the event name pipeline.refused.claimed."
