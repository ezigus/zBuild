## issue-acceptance — fail

- `npm run lint` exits 1 due to SC2034 warnings on `ZBUILD_NEGCTL_KILL_GRACE` in `run-tests.sh` and `run-mutation.sh` (assigned in script body but used only inside the sourced helper, invisible to shellcheck); `npm test` also exits 1 from two pre-existing `legacy/` exclusion failures (`security-lens-test.sh`, `scope-manifest-b1-regression-test.sh`) unrelated to this PR but counted against R-6.

- NOT MET: R-6: `npm test` exits 1 (security-lens-test.sh and scope-manifest-b1-regression-test.sh fail from missing `legacy/` tree excluded by ADR-059 §2)
- NOT MET: `npm run lint` exits 1 (SC2034 on `ZBUILD_NEGCTL_KILL_GRACE` in run-tests.sh:36 and run-mutation.sh:125 — shellcheck cannot see the variable's use inside the sourced `_acceptance_timeout_prefix` function)
