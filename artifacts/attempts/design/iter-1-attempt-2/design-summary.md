## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: DSFND-1: wrong — DSCLG-6 already ends in `covers: RQADR-2`. It does not cover `scripts/release.sh`, so I left the SPEC unchanged. `scripts/release.sh` appears only in the issue's RQLOCK-5 text, and DSCLG-1 to DSCLG-4 cover RQLOCK-5.
- answered: DSFND-2: done — I removed the write-order claim from DSCLG-2. Its last line now reads: each new section sits above the earlier existing section, with the header intact and no section duplicated, whichever call finishes first. That is the wording the finding accepted.
