## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: DSFND-6: done — the line that listed `core/claim/claim.sh` after DSRACE-15's `covers:` was the WIRING block, which sat right under DSRACE-15 and was probably read as part of it. I moved DSRACE-15 up, next to the REMOVED line, so WIRING no longer follows it. DSRACE-15's `covers:` names only intake requirements (RQTST-1, RQTST-7, RQPORT-1, RQSCP-2). I have not re-run the design check, so I can't confirm this clears the finding.
- answered: DSFND-7: done — same cause and same fix as DSFND-6, this time for `plugins/claim-coordinator/github-labels/plugin.sh`.
- answered: DSFND-8: done — I replaced the last `And:` in DSRACE-9 with "the outcome is the same whatever time the run's own clock shows". A test can observe that: it makes the fake GitHub drop `created_at` from the record POST reply, then checks that the claim is not acquired and that the record and label are gone, under different clock readings.
