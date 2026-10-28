## issue-acceptance — fail

- The diff introduces two proven regressions — release dispatch is broken on the hard-kill (SPEC-5) exit path, and `sigterm-aborts-pipeline-test.sh` hangs for the full 480 s timeout — leaving R-4 and R-10 definitively unmet and undermining confidence in R-1 and R-3 through the same abort-trap code path.

- NOT MET: R-4 (`runner-release-exit-paths-test.sh` SPEC-5 proves release is not dispatched after a hard kill
- NOT MET: persist stage is neither constructed nor tested in any scenario)
- NOT MET: R-10 (`npm test` exits non-zero: SPEC-5 cleanup failure + `sigterm-aborts-pipeline-test.sh` 480 s timeout, both caused by this diff's changes to `_runner_abort_trap` ordering and the watchdog fd-close)
- NOT SURE: R-9 (ADR-054 amended as §11 per REQUIREMENTS/SPEC-6, but the issue text says "§9" — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: cannot confirm from the diff whether the issue's §9 was a superseded draft number or a genuine separate section that was not amended) — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
