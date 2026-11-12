# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Sixtieth pass — issue-acceptance finding 1 addressed

### What changed this pass

**issue-acceptance finding 1 (RQFROM-4 unmet):**
The build stage introduced two RQFROM-4 violations:
1. A `skip_restore=false` path in `_runner_from_stage_preflight` for `--from-stage` without `--resume`
2. A narrowed pre-auto-resume guard (interrupted-status only) letting `in_progress` states bypass rejection

The worktree guard fires only for `interrupted` status. For `in_progress`, auto-resume fires first setting `resume_mode=true`, then the post-auto-resume guard `! $resume_mode` is false → exit 0.

The base code (and correct) guard appears BEFORE auto-resume with no status narrowing:
`if [[ -n "$from_stage" ]] && ! $resume_mode; then error "--from-stage is only valid with --resume"`.

Design changes this pass:
- Gap 12 description: "without any status narrowing — guard fires for ALL states" + remove `skip_restore=false`
- Decision paragraph: same clarification added
- Gap 12 step: "full, un-narrowed guard", "no `[[ "$_fsg_status" == "interrupted" ]]` condition", "remove `skip_restore=false`"
- from-stage-rehydrate-test.sh step: added item (5) — update S5 to use `--resume --from-stage cyc`
- DSFSTG-1 Given/When: changed to `--resume --from-stage <s>`
- Finding 32: updated; Finding 33: new

DSFSTG-4 remains [done] — base code had the guard correct.

### SPEC count

- [code] 12: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1
- [done] 1: DSFSTG-4
- [no-code] 2: DSFRSH-1, DSFRSH-2
- [doc] 2: DSAMDR-1, DSAMDR-2
- REMOVED 4: DSDISP-1, DSBNDY-1, DSLEGC-1, DSCYCL-1

### Requirement coverage

- RQRESU-1: DSRHYD-1; RQRESU-2: DSRHYD-1, DSRHYD-2; RQRESU-3: DSSKIP-1, DSDSPK-1
- RQFROM-1: DSFSTG-1, DSFSTG-3; RQFROM-2: DSFSTG-1; RQFROM-3: DSFSTG-2; RQFROM-4: DSFSTG-4
- RQLOOP-1: DSITER-1, DSCMBR-1; RQPATH-1: DSENTR-1, DSENTR-2
- RQGUAR-1: DSFRSH-1; RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1[doc]; RQADR-2: DSAMDR-2[doc]; RQHYDR-1: DSRHYD-1, DSDLGT-1

### Key decisions

- Gap 12: guard restored BEFORE auto-resume, WITHOUT status narrowing; `skip_restore=false` removed; S5 → `--resume --from-stage`
- Gap 11: `resume_mode=false` after clearing `skip_until_stage` (DSFSTG-3)
- Gap 9: `resume_first_iter=true` flag in `_cycle_dispatch` (DSCMBR-1)
- Gap 8: auto-resume symlink check (DSENTR-2)
- Gap 7: remove `_cd_iter > 0` unconditional guard

### issue-acceptance finding 2 (run-status-text.sh unasked)

Design does not cover run-status-text.sh. Build stage added it out of scope. Answer: not mine.

### DSENTR-2 critical constraint

DSENTR-2 test must NOT set ZBUILD_STATE_FILE — if set, the symlink check is false.
