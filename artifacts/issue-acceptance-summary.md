## issue-acceptance — fail

- `npm test` fails — `runner-release-exit-paths-test.sh` SPEC-5 (release stage on the hard-kill exit path) regresses after the `{_RUNNER_ERR_FD}>&-` change, and the shape_floor floor is breached; R-10 is directly unmet and the regression bears on R-4.

- NOT MET: R-10: test suite fails (1 regression + shape_floor breach — neither is a pre-existing failure, both are introduced by this diff)
- NOT MET: R-4: `persist` is never constructed or tested in the timed_out scenario (only `release` appears in the `timeout-with-release.yaml` template), and the SPEC-5 regression in `runner-release-exit-paths-test.sh` shows that the hard-kill exit path no longer dispatches `release` at all after the FD-close change — so even the `release` half of R-4 is not safely covered on the kill escalation path
- NOT SURE: R-9: the issue specifies "ADR-054 §9" as the section to amend, but the diff adds §11 — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: cannot determine from the diff alone whether §9 was also updated or whether the issue carried a draft-numbering error — the ADR file is in the changed-files list but the section numbers cannot be verified here — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
