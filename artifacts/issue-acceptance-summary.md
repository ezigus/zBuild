## issue-acceptance — fail

- `npm test` and `npm run lint` both fail — the new integration test `tests/integration/cycle-member-unfinished-no-convergence-test.sh` uses `set +e`/`set -e` mid-file at line 142 while its header is only `set -uo pipefail`, violating the lint-test-errexit rule (#2252) and causing the lint-test-errexit unit test's L5 assertion to fail.

- NOT MET: `npm test` and `npm run lint` green (both fail: lint-test-errexit violation at cycle-member-unfinished-no-convergence-test.sh:142
- NOT MET: shape-floor golden files not updated)
