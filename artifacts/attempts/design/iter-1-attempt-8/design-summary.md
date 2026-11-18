## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Changed DSCLA-10 from `[code]` with a `Then` that names the event-schema emitted-coverage check (which the design check correctly identifies as describing how a test verifies rather than a code output) to `[no-code]` with no Given/When/Then. Config registration in event-schema.json is config work; [no-code] is the right status and the optional Given/When/Then are omitted to avoid the naming-the-tool problem entirely. The test author writes a test that must pass after the change.
- not answered: test-author finding 1
