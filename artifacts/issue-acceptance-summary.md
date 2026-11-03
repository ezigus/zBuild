## issue-acceptance — fail

- The dispatch-unit loop changes introduced by this diff regress retry behavior on non-resume paths, breaking the R-13/R-14 guards that require fresh runs to behave exactly as before.

- 2 requirement(s) not met — each is a finding, sent to the stages that can fix it
- NOT SURE: R-5 (ADR-006 amended with step 3.6 naming enforcing tests inline) — `docs/adr/ADR-006-resume-contract.md` is listed as changed in prior work but its content is not in the diff shown; I cannot verify the amendment includes the required step 3.6 wording and the enforcing test names `resume-rehydrate-test.sh` / `resume-entry-points-test.sh` cited inline. — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: R-6 (ADR-050 §6 amended with boundary note distinguishing resume from new-run) — `docs/adr/ADR-050-prior-work-reuse-contract.md` is listed as changed in prior work but its content is not in the diff shown; I cannot verify the §6 boundary note was added as specified. — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
