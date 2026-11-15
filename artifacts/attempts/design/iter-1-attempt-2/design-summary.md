## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Added DSCLA-9[code] covering the observable side of RQCLA-4: when `zbuild_claim_acquire` returns 1, `runner.sh` prints the holder string in its refusal output. DSCLA-4 keeps the internal mechanism assertion (`_ZBUILD_CLAIM_HOLDER` is set); DSCLA-9 covers the observable output assertion (the runner's stdout/stderr contains the holder string). Both carry `covers: RQCLA-4`.
