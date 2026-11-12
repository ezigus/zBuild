# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fifty-ninth pass — three test-author findings fixed

### What changed this pass

**test-author finding 1 (DSAMDR-1):** Changed from [no-code] to [doc].
The SPEC described what ADR-006-resume-contract.md contains — a file content assertion, not observable runtime behaviour. No test can verify prose amendment correctness by running the system. [doc] is the correct type: "say, on its one line, what the doc must tell a reader; the doc is read to check it." TESTFILES entry removed (docs have no tests).

**test-author finding 2 (DSAMDR-2):** Changed from [no-code] to [doc].
Same reason as DSAMDR-1. TESTFILES entry removed.

**test-author finding 3 (DSCYCL-1):** Changed to REMOVED.
The SPEC described what test files and pipeline fixture YAML files contain, not observable runtime behaviour. RQRESU-4 (the methodology requirement DSCYCL-1 was anchoring) was removed by intake. The other requirements it listed (RQLOOP-1, RQFROM-2, RQFROM-3, RQPATH-1) are fully covered by [code] SPECs whose behaviors inherently require cycle-containing fixtures to exercise the guarded code paths: DSITER-1, DSCMBR-1, DSFSTG-1 (cycle.start branch of Then), DSENTR-1, DSENTR-2. TESTFILES entry removed.

### Also cleaned up this pass

- **RQRESU-4 removed from covers fields**: DSRHYD-1, DSSKIP-1, DSDSPK-1 all had `RQRESU-4` in their covers fields, but RQRESU-4 was removed by intake. Those references are cleaned up.
- **Steps updated**: Steps that said "(retag to [#1805/DSCYCL-1])" or "(add [#1805/DSCYCL-1] assertion)" had those sub-tasks removed. Step numbering updated within affected steps.
- **Finding 1, 2, 3, 8, 26** updated to reflect these changes.

### SPEC count (after this pass)

- [code] 12: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1
- [done] 1: DSFSTG-4
- [no-code] 2: DSFRSH-1, DSFRSH-2
- [doc] 2: DSAMDR-1, DSAMDR-2
- REMOVED 4: DSDISP-1, DSBNDY-1, DSLEGC-1, DSCYCL-1

### Requirement coverage (all 14 current requirements)

- RQRESU-1: DSRHYD-1
- RQRESU-2: DSRHYD-1, DSRHYD-2
- RQRESU-3: DSSKIP-1, DSDSPK-1
- RQFROM-1: DSFSTG-1, DSFSTG-3
- RQFROM-2: DSFSTG-1 (cycle.start branch of Then)
- RQFROM-3: DSFSTG-2
- RQFROM-4: DSFSTG-4[done]
- RQLOOP-1: DSITER-1, DSCMBR-1
- RQPATH-1: DSENTR-1, DSENTR-2
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1[doc]
- RQADR-2: DSAMDR-2[doc]
- RQHYDR-1: DSRHYD-1, DSDLGT-1

RQRESU-4 removed by intake — no longer in any covers field.

### Key design decisions (unchanged)

- Gap 7: _cd_iter > 0 guard in _cycle_dispatch must be removed (issue-acceptance finding 2)
- Gap 8: auto-resume symlink check for per-run layout (DSENTR-2[code])
- Gap 9: _cycle_dispatch resume_first_iter=true flag (DSCMBR-1[code])
- Gap 11: resume_mode=false immediately when skip_until_stage cleared (DSFSTG-3[code])
- Gap 12: --from-stage guard restored before auto-resume — BRANCH REGRESSION FIX
  (base code already had it right before auto-resume check;
  the branch moved it after; the step restores it; DSFSTG-4 is [done])

### DSENTR-2 critical constraint

The DSENTR-2 test must NOT set ZBUILD_STATE_FILE. If it does, the symlink check
`[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` is false and the new
code path is never reached.

### Pipeline fixtures need cycles (methodology note, not a SPEC)

DSITER-1, DSCMBR-1, DSFSTG-1 (cycle.start branch), DSDSPK-1 (cycle k case), DSENTR-1/2 all
exercise code paths that only activate for cycle stages. The build stage must use cycle-containing
fixtures for these tests to be meaningful — but this is implementation guidance, not a design contract.
