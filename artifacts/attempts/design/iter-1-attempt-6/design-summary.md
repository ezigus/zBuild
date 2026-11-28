## design — fail

- the design fails 3 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: DSFND-5: done — the outside assumptions still don't accept both runs proceeding, except for the known limit RQLIM-1 that the issue itself accepts and ADR-005 §5 will state.
- answered: RLREDTEAM-2: done — the assumptions still address cross-connection comment visibility, and ADR-005 §5 records it.
- answered: RLSCOPE-2: wrong — the loser exits before runner.sh starts its progress comment, so its concurrent claim record is its only comment, and DSRACE-3 covers marking it not started.
