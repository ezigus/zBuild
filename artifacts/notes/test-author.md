# test-author notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — the target test file
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — the ADR being amended
- `scripts/lib/test-helpers.sh` — assert helpers, setup_test_env, etc.
- `core/pipeline/disposition.sh` — outcome vocabulary
- `scripts/lib/stage-result.sh` — stage_result_write function

## Outcome vocabulary (from disposition.sh)

`outcome_vocabulary()` returns: `pass fail unusable timed_out out_of_turns interrupted
throttled rate_limited unavailable misconfigured broken`

Full non-pass set (10 words): `fail unusable timed_out out_of_turns interrupted throttled
rate_limited unavailable misconfigured broken`

## SPEC-1 gap analysis

**Requirement**: When ANY map member's outcome is not `pass`, `_strategy_run_map` exports
`ZBUILD_RUN_FLAGGED=yes`.

**Pre-existing SPEC-1-tagged assertions** (3 sub-tests): timed_out, out_of_turns, interrupted.
**Pre-existing M2 test** (no SPEC-1 tag): covers `fail`.

**Logical gap**: An implementation gated on exactly {timed_out, out_of_turns, interrupted}
would pass all three SPEC-1 assertions while leaving `fail`, `unusable`, `throttled`,
`rate_limited`, `unavailable`, `misconfigured`, `broken` unflagged.

**Fix**: Add a loop over the remaining non-pass outcomes (`unusable`, `throttled`,
`rate_limited`, `unavailable`, `misconfigured`, `broken`, `fail`) tagged [#1753/SPEC-1].
Together with the three already-tagged sub-tests, every outcome in outcome_vocabulary()
other than `pass` is covered by the SPEC-1 tag.

## SPEC-2 analysis

SPEC-2 has no testfile (blank). The ADR-040 #2368-part-2 amendment already:
- States: "ZBUILD_RUN_FLAGGED is `yes` when any element's outcome is not `pass`"
- Has an inline "Enforced by:" entry naming `tests/unit/engine-combines-map-test.sh`
  SPEC-1 (#1753 — any non-pass outcome sets `ZBUILD_RUN_FLAGGED=yes`)
No additional assertion to write.

## Implementation plan

Insert after the interrupted sub-test in SPEC-1 section, before cleanup_test_env:

```bash
# sub-tests: remaining non-pass outcomes — prove "any non-pass", not just the three
# unfinished cases above. All 10 non-pass outcomes from outcome_vocabulary() are now
# tagged [#1753/SPEC-1]: the three above + fail/unusable/throttled/rate_limited/
# unavailable/misconfigured/broken here. No implementation can pass all assertions
# by hard-coding only a subset.
_spec1_outcome=""
orch_dispatch() {
    local _e; _e="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$2" | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//")"
    if [[ "$_e" == b ]]; then stage_result_write "$ART/lens-$_e.json" "$_spec1_outcome" "test: $_spec1_outcome"
    else stage_result_write "$ART/lens-$_e.json" pass "nothing found"; fi
    printf 'slot\n'
}
for _spec1_outcome in unusable throttled rate_limited unavailable misconfigured broken fail; do
    rm -f "$ART"/lens-*.json
    _run_map a b c
    assert_eq "[#1753/SPEC-1] $_spec1_outcome outcome → ZBUILD_RUN_FLAGGED=yes" "yes" "${ZBUILD_RUN_FLAGGED:-unset}"
done
unset _spec1_outcome
```

The loop uses `_spec1_outcome` as a dynamic variable read by `orch_dispatch` at call time
(same shell process, no subshell). This is the same pattern as the existing sub-tests;
it defines the function once and iterates over the remaining outcomes.

## Status
- SPEC-1: **fix written** — loop added after existing 3 sub-tests
- SPEC-2: **no testfile, already satisfied by ADR content**
