## issue-acceptance — fail

- The diff introduces a regression in `runner-release-exit-paths-test.sh` SPEC-5 (hard-kill exit path) where `release` does not run — directly violating R-4 — and `npm test` is red, violating R-10.

- NOT MET: R-4: release and persist still run after a timed-out run — the SPEC-5 assertion "cleanup dispatched with scope=release for: intake build" fails with "no release from: intake build | marker=", a regression caused by this diff's changes to `_runner_abort_trap()` (reordering `_runner_restore_stderr` before `trap ':' INT TERM`) and the watchdog fd-close relocation (moving `exec {_RUNNER_ERR_FD}>&-` from the spawn line into the watchdog body, leaving the parent holding the fd open on the hard-kill path where the abort trap never fires)
- NOT MET: R-10: `npm test` + `npm run lint` green — 1 of 19 tests in `runner-release-exit-paths-test.sh` fails
- NOT SURE: R-1: regression-test reddens at merge-base — the issue requires this be verified — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: no evidence of a merge-base run is shown — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: R-9: ADR-054 §9 vs §11 — the issue says "§9" but REQUIREMENTS/SPEC-6 say "§11" — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: previous notes note the discrepancy but cannot confirm the issue's numbering was a draft error rather than a distinct requirement to amend the existing §9 — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
