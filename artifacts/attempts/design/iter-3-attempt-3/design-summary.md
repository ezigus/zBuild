## design — fail

- the design fails 2 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — Rewrote DSCLA-10 as `[code]` with simplified Given/When/Then: `When: config/event-schema.json is searched for the string "pipeline.refused.claimed"` / `Then: the string "pipeline.refused.claimed" is found in the file`. This matches the grep-of-JSON-file approach; no coverage tool invocation required. The SPEC is `[code]` because the string is absent from the file before the change.
- not answered: design finding 1
