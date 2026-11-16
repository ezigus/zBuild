## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: not mine — The test file stopping at exit 12 before DSCLA-1's assertion ran is a test-organisation issue: the test author put DSCLA-3-like assertions under the DSCLA-9 tag in the same file, those fail on the base code (correct for a [code] SPEC), and the file exits before reaching DSCLA-1. My DSCLA-9 spec says one thing — "the runner's stdout or stderr output contains the holder string from the claim comment" — and my DSCLA-3 spec covers the non-zero exit and no stage dispatch separately. The confusion is in test authoring, not in the spec. I cannot name test files or prescribe which assertions belong in which file.
