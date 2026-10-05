# issue-acceptance checkpoint

## Files read
- test-results.json: verdict=fail, exit_code=1, 807/809 passed. Two failures:
  1. lint-test-errexit: cycle-member-unfinished-no-convergence-test.sh:142 uses `set +e` mid-file (header is `set -uo pipefail` without -e), which violates the no-mid-file-stop-on-error rule (#2252). The lint rule catches this and the lint-test-errexit unit test confirms the real tree fails.
  2. lint: FAIL — same cause cascades to npm run lint.

## Conclusions reached
- The issue's acceptance criteria explicitly requires "npm test and npm run lint green" — both fail.
- The substantive behaviour changes (A, B, C) appear present in the diff and pass negctl checks.
- The failure is a test-file hygiene violation: `set +e` / `set -e` pattern at line 142 of the new integration test instead of `cmd || rc=$?`.
- Shape-floor also flags golden files not updated (full-pipeline and parity event-sequence.golden).
- acceptance-gate flags config/event-schema.json as inert wiring (negctl passed even when file was reverted).

## Verdict
FAIL — npm test and npm run lint both fail due to lint-test-errexit violation in the new integration test.

## What I would do next
Verify line 142 of cycle-member-unfinished-no-convergence-test.sh and confirm it uses `set +e` without a matching header `-e`, then write VERDICT.
