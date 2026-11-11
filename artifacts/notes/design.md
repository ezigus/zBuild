# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fifty-eighth pass — three SPEC fixes

### What changed this pass

**design finding 1 (DSFSTG-1 fourth And):** Removed positive obligation "is emitted."
Changed from: "`pipeline.skip_to_stage` is emitted when `--from-stage` is active; no stage before <s> is dispatched after that event"
Changed to: "If `pipeline.skip_to_stage` appears in the event log, no stage before <s> emits stage.start after it"
RQFROM-2 prohibits the sequence (emit + earlier dispatch), not the absence of the event.

**design finding 2 (DSITER-1 third And):** Replaced internal `iter=1` counter with observable event proxy.
Changed from: "When _ZBUILD_RESUME_ACTIVE is false or unset (fresh run or nested-loop re-entry), the loop starts at iter=1"
Changed to: "When the cycle orchestrator runs with _ZBUILD_RESUME_ACTIVE unset (fresh run or nested-loop re-entry), stage.start is emitted for a member of the first iteration — no prior iterations are skipped"
Observable via event log.

**acceptance-gate finding 1 (DSFSTG-4):** Changed from [code] back to [done].
Root cause: Base code has the guard (`--from-stage is only valid with --resume`) at runner.sh line 1737, BEFORE the auto-resume elif check at line 2081. So the test passes on base code. The [code] classification was wrong; [done] with evidence is correct.
Evidence: `core/pipeline/runner.sh:"--from-stage is only valid with --resume"` (guard in `main()` before auto-resume check)
The Gap 12 FIX STEP remains in the steps block — the branch accidentally moved the guard after auto-resume; the step restores the guard to its pre-branch position to preserve the [done] property.

### SPEC count (after this pass)

- [code] 12: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1
- [done] 1: DSFSTG-4
- [no-code] 5: DSAMDR-1, DSAMDR-2, DSFRSH-1, DSFRSH-2, DSCYCL-1
- REMOVED 3: DSDISP-1, DSBNDY-1, DSLEGC-1

### Requirement coverage (all 15 current requirements)

- RQRESU-1: DSRHYD-1
- RQRESU-2: DSRHYD-1, DSRHYD-2
- RQRESU-3: DSSKIP-1, DSDSPK-1
- RQRESU-4: DSRHYD-1, DSSKIP-1, DSDSPK-1, DSCYCL-1
- RQFROM-1: DSFSTG-1, DSFSTG-3
- RQFROM-2: DSFSTG-1, DSCYCL-1
- RQFROM-3: DSFSTG-2, DSCYCL-1
- RQFROM-4: DSFSTG-4[done]
- RQLOOP-1: DSITER-1, DSCMBR-1, DSCYCL-1
- RQPATH-1: DSENTR-1, DSENTR-2, DSCYCL-1
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1
- RQADR-2: DSAMDR-2
- RQHYDR-1: DSRHYD-1, DSDLGT-1

### Key design decisions (unchanged)

- Gap 7: _cd_iter > 0 guard in _cycle_dispatch must be removed (issue-acceptance finding 2)
- Gap 8: auto-resume symlink check for per-run layout (DSENTR-2[code])
- Gap 9: _cycle_dispatch resume_first_iter=true flag (DSCMBR-1[code])
- Gap 11: resume_mode=false immediately when skip_until_stage cleared (DSFSTG-3[code])
- Gap 12: --from-stage guard restored before auto-resume — BRANCH REGRESSION FIX
  (base code already had it right at runner.sh line 1737, before auto-resume at 2081;
  the branch moved it after; the step restores it; DSFSTG-4 is [done])

### DSENTR-2 critical constraint

The DSENTR-2 test must NOT set ZBUILD_STATE_FILE. If it does, the symlink check
`[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` is false and the new
code path is never reached.
