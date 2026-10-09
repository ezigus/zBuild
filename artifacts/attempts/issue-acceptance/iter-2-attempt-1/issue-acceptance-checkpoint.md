# Acceptance checkpoint — issue #1752

## Files read (second pass)
- test-results.json (re-read): 2 failures (not 9 — build stage fixed prior breakages), exit_code: 1
- Lint failures: SC2034 for ZBUILD_NEGCTL_KILL_GRACE in run-tests.sh:36 and run-mutation.sh:125 — shown in stage error output

## Current state (after build stage fixed earlier breakages)

### Remaining failures
1. **npm test — 2 pre-existing failures** (NOT caused by this PR):
   - `security-lens-test.sh`: `legacy/scripts/lib/compound-audit.sh` missing — legacy/ excluded from issue worktrees per ADR-059 §2
   - `scope-manifest-b1-regression-test.sh` SPEC-5: legacy/ missing for same reason

2. **npm run lint — SC2034 failures** (CAUSED by this PR):
   - `run-tests.sh line 36/37`: `ZBUILD_NEGCTL_KILL_GRACE` assigned (without export or assigned via export but build-stage may have changed it) — shellcheck cannot see its use inside sourced function
   - `run-mutation.sh line 125`: same SC2034 issue

## Requirement verdicts
- R-1: MET — timeout-cmd.sh created; all 6 sites converted; SPEC-8 passes
- R-2: MET — lint-bare-timeout.sh created and wired; release.sh:629 has allow comment
- R-3: MET — SPEC-9 passes (timeout-cmd-helper-test.sh in 184 passing tests)
- R-4: MET — SPEC-3 passes (inert_build test passes)
- R-5: MET — ADR-036 amended with dated paragraph + Enforced by section
- R-6: NOT MET — npm test exits 1 (2 legacy/ failures); npm run lint exits 1 (SC2034)

## Final verdict
VERDICT: fail
REASON: npm run lint fails (SC2034 on ZBUILD_NEGCTL_KILL_GRACE in run-tests.sh and run-mutation.sh — assigned in script body but used only inside sourced function, invisible to shellcheck); npm test exits 1 from two pre-existing legacy/ exclusion failures unrelated to this PR but R-6 requires green.
UNMET: R-6
