## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — DSCLA-10 rewritten. The original SPEC described an end-to-end run-refusal scenario (set up `zbuild:claimed`, refuse run, check schema coverage), but RQCLA-10 simply requires the event be registered in `config/event-schema.json`. The test-author's direct schema check is correct for the requirement. DSCLA-10 now reads: When config/event-schema.json is read, Then pipeline.refused.claimed is present among the registered event names. No Given needed; the [code] status is kept because adding the entry to the schema file is a code step (test fails on old code where it is absent).
