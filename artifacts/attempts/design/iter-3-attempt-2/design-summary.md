## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — Changed DSCLA-10 from [code] to [no-code]. The config-only change (adding a string to `config/event-schema.json`) needs no Given/When/Then: a [no-code] test need only pass after the change. The test-author's direct grep of the schema file is a valid implementation. One-liner: "The event-schema coverage tool accepts pipeline.refused.claimed as a known event name."
