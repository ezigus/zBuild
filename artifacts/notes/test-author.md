# test-author notes — issue #1805 (round 35: fix DSPK-1 and FRSH-2 findings)

## Status: COMPLETE

## What was done this round

Fixed two open findings from previous test-author run, both in
`tests/integration/resume-rehydrate-test.sh`.

### Finding 1 (DSPK-1): Added cycle.start assertion for stage k

The previous test asserted `stage.start` for `cycled` (member of cyc) but never
asserted `cycle.start` for `cyc` itself. The DSPK-1 requirement says "when k is a
cycle stage, a cycle.start event is emitted for k AND stage.start is emitted for k's
first cycle member". The cycle.start half was unproven.

Added after the existing `_s1_cycled_starts` assertion:
```bash
_s1_cyc_cycle_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_cyc_cycle_starts="$(jq -r 'select(.type=="cycle.start") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSPK-1] cycle.start emitted for stage k (cyc) on resume ..." \
    "$_s1_cyc_cycle_starts" "0"
```

Fail direction: before code change, runner aborts before dispatching cyc → no
cycle.start → count=0 → FAILS.
Pass direction: after change, dispatch loop reaches cyc → cycle.start emitted → PASSES.

### Finding 2 (FRSH-2): Added cycle.start assertion proving cyc not silently skipped

The previous test asserted intake dispatches (count=1) and no stage.skip events,
but a skip guard that silently skips cyc WITHOUT emitting stage.skip would pass
undetected. Added `cycle.start` count > 0 assertion after the existing FRSH-2 assertions:

```bash
_frsh2_cyc_cycle_starts=0
if [[ -f "$_S_FRSH2_EVENTS_JSONL" ]]; then
    _frsh2_cyc_cycle_starts="$(jq -r 'select(.type=="cycle.start") | .type' \
        "$_S_FRSH2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/FRSH-2] cycle stage cyc dispatched on fresh run (cycle.start emitted; ..." \
    "$_frsh2_cyc_cycle_starts" "0"
```

FRSH-2 is [no-code]: need not fail before, must pass after.
Catches a hypothetical skip guard that silently suppresses cyc → no cycle.start → FAILS.

## Notes on ZBUILD_CYCLES_ENABLED
The FRSH-2 runner call already has `ZBUILD_CYCLES_ENABLED=1` set (line ~816),
so the cycle stage `cyc` will be processed and `cycle.start` will be emitted
on a fresh run when the code is correct.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- RHYD-1 ✓ (3 paths: artifact-present, byte-identical, pipeline.resume before stage.start)
- RHYD-2 ✓ (exit 1 when artifact absent; no stage.start before exit)
- AMDR-1 ✓ (ADR-006 step 3.6 present with all required text)
- AMDR-2 ✓ (ADR-050 §6 boundary note + test citations)
- DSPK-1 ✓ (fixed: stage k emits stage.start for cycled member + cycle.start for cyc)
- FRSH-1 ✓ (intake dispatched; no stage.skip; no prior-run artifact)
- SKIP-1 ✓ (no stage.start for complete stage with artifact present)
- FRSH-2 ✓ (fixed: intake dispatches + no stage.skip + cycle.start for cyc)
- CYCL-1 ✓ (fixture has type:cycle)

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1 ✓
- FSTG-2 ✓
- CYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- ITER-1 ✓
- CMBR-1 ✓

### tests/integration/resume-entry-points-test.sh
- ENTR-1 ✓ (all 3 paths)
- ENTR-2 ✓ (auto-resume via latest symlink, PATH 4)

### tests/integration/cycle-member-dispatch-events-test.sh
- FRSH-1 ✓

## Findings answered this round

ANSWER test-author finding 1: done — added assert_gt "[#1805/DSPK-1] cycle.start emitted
  for stage k (cyc) on resume" assertion after the existing DSPK-1 cycled-member assertion
  in resume-rehydrate-test.sh. The cycle.start half of the DSPK-1 Then clause is now proven.

ANSWER test-author finding 2: done — added assert_gt "[#1805/FRSH-2] cycle stage cyc
  dispatched on fresh run (cycle.start emitted...)" assertion after the existing FRSH-2
  assertions. This catches a silent skip of cyc that emits no stage.skip event.
