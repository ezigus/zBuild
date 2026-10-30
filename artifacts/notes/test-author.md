# test-author notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — target test file for SPEC-1
- `tests/unit/runner-map-parallel-stage-envelope-test.sh` — target test file for SPEC-4 / SPEC-8 fix
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — the ADR being amended
- `scripts/lib/test-helpers.sh` — assert helpers, setup_test_env, etc.
- `core/pipeline/disposition.sh` — outcome vocabulary
- `scripts/lib/stage-result.sh` — stage_result_write function
- `core/pipeline/runner.sh` lines 3622–3750 — the map:*) dispatch arm

## Outcome vocabulary (from disposition.sh)

`outcome_vocabulary()` returns: `pass fail unusable timed_out out_of_turns interrupted
throttled rate_limited unavailable misconfigured broken`

Full non-pass set (10 words): `fail unusable timed_out out_of_turns interrupted throttled
rate_limited unavailable misconfigured broken`

## SPEC-1 (engine-combines-map-test.sh) — DONE (previous pass)

Written: loop over remaining non-pass outcomes (unusable, throttled, rate_limited,
unavailable, misconfigured, broken, fail) tagged [#1753/SPEC-1]. Together with the
three already-tagged sub-tests (timed_out, out_of_turns, interrupted), all 10 non-pass
outcomes from outcome_vocabulary() are covered.

## SPEC-8 fix (runner-map-parallel-stage-envelope-test.sh) — DONE (previous pass)

count widened from >=115 to >=128. Already on disk at line 46.

## SPEC-4 (runner-map-parallel-stage-envelope-test.sh) — DONE (this pass)

**Requirement**: When `ZBUILD_RUN_FLAGGED=yes` after `_strategy_run_map`, runner.sh's
map dispatch arm returns 1 before calling `_update_stage_status` for the group.

**Round 1 shortcoming**: Only checked ordering (ZBUILD_RUN_FLAGGED before
_update_stage_status). Did NOT verify `return 1` or runtime skipping.

**Three assertions written**:

(a) Static: `ZBUILD_RUN_FLAGGED:-` appears in `spec4_pre_update` (all of MAP_ARM
    before `_update_stage_status`). At baseline: 0 ≠ 1 → FAILS. After #1753: 1 → PASSES.

(b) Static: `return 1` is inside the ZBUILD_RUN_FLAGGED if-block. Extracts the if-block
    with awk, greps for `return 1`. At baseline: block doesn't exist → count=0 ≠ 1 → FAILS.
    After #1753: block has `return 1` → count=1 → PASSES.

(c) Runtime: Extract the `if [[ $_rc -ne 0 ]]...` through `_update_stage_status` portion
    of MAP_ARM. Eval it inside `_spec4_runtime()` with mocked functions, `_rc=0`,
    `ZBUILD_RUN_FLAGGED=yes`. Run in a subshell with `set +e`. Check marker file NOT created.
    At baseline: no stop block → `_update_stage_status` mock creates marker → FAILS.
    After #1753: stop block fires `return 1` → `_update_stage_status` NOT called → PASSES.

**Why subshell isolation works**: `_spec4_runtime` runs in `( _spec4_runtime )`, so mock
function definitions don't leak into the outer shell. B1/B2/B3 sections run their own
subshells and source the real `state_helpers.sh`, unaffected by the mock. ✓

**Sigpipe compliance**: all patterns use `<<< "$var"` (here-strings), not pipes into
grep. `assert_file_not_exists` is from test-helpers.sh (line 283). ✓

## SPEC-2 analysis

SPEC-2 has no testfile (blank). No assertion to write here.

## Status — ALL DONE
- SPEC-1 engine-combines-map-test.sh: DONE (previous pass)
- SPEC-4 runner-map-parallel-stage-envelope-test.sh: DONE (this pass, 3 assertions)
- SPEC-8 fix (count widened to >=128): DONE (previous pass)
- SPEC-2: no testfile; nothing to write
