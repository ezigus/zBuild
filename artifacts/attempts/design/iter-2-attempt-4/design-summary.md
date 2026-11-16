## design — fail

- the design fails 2 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — The original DSCLA-2 combined local and CI sub-cases in a single `Then:` clause ("local runs) or the CI run URL (CI runs)"), which let the test author choose different assertion styles for each sub-case — checking `_ZBUILD_CLAIM_HOLDER` for CI rather than the rendered output. I split DSCLA-2 into two SPECs: DSCLA-2 (local run) and new DSCLA-12 (CI run). Both now say explicitly "When: `rsc_render_header` is called with the run id and holder string" and "Then: the rendered header contains `<!-- zbuild-holder: ... -->`", making it unambiguous that both sub-cases must assert the renderer's output, not the internal holder variable.
