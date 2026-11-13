# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 34 — All acceptance tests pass; guard un-narrowed

## Changes made this iteration

### Un-narrowed the --from-stage guard (RQFROM-4 fix)

**File:** `core/pipeline/runner.sh`

**What changed:** Replaced the narrowed pre-auto-resume guard that only fired for
`status=interrupted` with the full un-narrowed guard that fires for ALL statuses.

Old (narrowed, broken):
```bash
if [[ -n "$from_stage" ]] && ! $resume_mode && [[ -f "$state_file" ]]; then
    _fsg_status="$(get_state_field "$state_file" '.status' '')"
    if [[ "$_fsg_status" == "interrupted" ]]; then
        error "--from-stage is only valid with --resume"
        return 1
    fi
fi
```

New (full, correct):
```bash
if [[ -n "$from_stage" ]] && ! $resume_mode; then
    error "--from-stage is only valid with --resume"
    _usage
    return 1
fi
```

**Why this works:**
- The guard fires before the auto-resume elif block
- For `status=in_progress` with `--from-stage intake --no-resume`: guard fires -> exit 1 (passes test)
- For `--resume --from-stage build`: `resume_mode=true` from argument parsing -> guard skipped
- S6 in from-stage-rehydrate-test.sh already uses `--resume --from-stage build` (line 530)
- The post-auto-resume guard at line ~2309 and the within-symlink guard at line ~2276 become
  dead code but are harmless defense-in-depth

## Verification results (this iteration)

All 6 test files pass:
- tests/integration/pipeline-resume-test.sh — 23 tests (was failing 2, now fixed)
- tests/integration/from-stage-rehydrate-test.sh — 35 tests
- tests/integration/resume-rehydrate-test.sh — 51 tests
- tests/integration/resume-loop-state-test.sh — 11 tests
- tests/integration/resume-entry-points-test.sh — 18 tests
- tests/unit/hydrate-stage-test.sh — 25 tests

## Shape-floor findings

Shape-floor findings 1-7 were all verified as "wrong — not reproduced" in previous iterations.
No golden files or shape-floor test files changed by this branch.
