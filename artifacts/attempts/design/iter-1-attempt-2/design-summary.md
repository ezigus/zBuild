## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Rewrote `DSADR-3` on its own line with its `When:` and `Then:` parts indented beneath it: `When: scripts/lib/compat.sh is sourced after the probe change` / `Then: declare -f zbuild_sed_inplace exits 0 (the function is defined under its original name)`.
