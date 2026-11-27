## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: RLREDTEAM-2: done — The outside assumptions section of the design explicitly acknowledges GitHub's cross-connection comment visibility window. It states that a posted comment may not be visible to another client's read within a sub-second propagation window, creating a narrow residual race where both competing runs could complete their note-post-and-read cycle before the other's note propagates. It explains why this is accepted (closing the window requires sleep, which is prohibited by the determinism rules; the window is extremely narrow in practice), and that ADR-005 §5 will document it. This was added in round 3 and is present in the current design-draft.md.
- answered: RLSCOPE-2: wrong — This finding does not block and was resolved in round 2. Reading B is correct: the loser exits before runner.sh starts its progress comment, so the concurrent claim note the loser posted is its only comment; DSRACE-3 covers it. No change needed.
