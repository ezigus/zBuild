# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status
Investigating failures in second pass.

## What was done in previous iteration (db0e567a)
All key implementation changes committed:
1. `_artifact_persist_put_back` in artifact-persist.sh ✓
2. `_hydrate_put_back` → `_artifact_persist_put_back` in hydrate/plugin.sh ✓
3. hydrate-stage-test.sh redirected ✓
4. `_runner_resume_rehydrate` and `_runner_from_stage_preflight` in runner.sh ✓
5. Resume entry point calls `_runner_resume_rehydrate` ✓
6. Stale-artifact changed from warn+continue to exit 1 ✓
7. `_runner_from_stage_preflight` call before dispatch loop ✓
8. cycle-orchestrator reads current_iter from state ✓
9. ADR-006 step 3.6 added ✓
10. ADR-050 §6 boundary note added ✓

## Test results after second run

### hydrate-stage-test.sh: ALL 24 PASS ✓

### resume-rehydrate-test.sh: 5 of 24 FAIL
Failures:
1. SPEC-1 "intake emits no stage.start" (3 paths) → grep-c bug
2. SPEC-12 "cycled dispatched" → stage.start not emitted for cycle sub-stages
3. SPEC-13 "cycled dispatched" → same

### resume-loop-state-test.sh: 1 of 4 FAIL
- SPEC-7 "no cycle.iteration.complete for iter=1" → grep-c bug

### from-stage-rehydrate-test.sh: 1 of 10 FAIL
- SPEC-3 "intake emits no stage.start" → grep-c bug

### resume-entry-points-test.sh: 2 of 6 FAIL
- SPEC-9 path 2 "artifact restored": runner exits because no --issue flag passed
- SPEC-13 "cycled dispatched" → same grep-c + missing stage.start issue

## Root cause analysis

### Issue 1: grep-c bug (multiple tests)
All "emits no stage.start" assertions use pattern:
```bash
jq ... | grep -c '^stage$' 2>/dev/null || echo 0
```
When grep-c finds 0 matches, it outputs "0" and exits 1. Then "|| echo 0" fires,
producing "0\n0" instead of "0". assert_eq "0" "0\n0" fails.

These assertions CANNOT pass because:
- jq outputs something (build's stage.start event)
- grep-c sees non-matching input → outputs 0, exits 1
- || echo 0 fires → "0\n0"

The ONLY fix is to make jq produce NO output AND grep-c exit 0... which is impossible 
when there are other stage.start events in the file.

WAIT: if there are NO stage.start events at all, jq still outputs nothing, grep-c
gets empty input → outputs 0, exits 1 → || echo 0 → "0\n0".

So these assertions CANNOT pass regardless of implementation.

Unless: I make the runner NOT emit stage.start for other stages either? No, that breaks 
the basic contract.

Actually - I need to reconsider. These are ACCEPTANCE tests. I MUST make them pass.

Let me think: the only way these pass is if grep-c exits 0.
- grep-c exits 0 when it finds ≥1 matches
- If jq outputs "intake" (meaning intake DID dispatch), grep-c matches, exits 0, no || echo 0

But that contradicts SPEC-1 (intake should NOT emit stage.start).

Wait, unless the test design intent is different. Maybe the test was designed for a system
where grep-c with count=0 exits 0 (non-standard)?

Actually looking more carefully at test-helpers.sh:
```bash
assert_eq() {
    if [[ "$expected" == "$actual" ]]; then
```

The comparison is exact string match. "0\n0" != "0".

Hmm. Let me re-read the test more carefully. The FIRST assignment uses `|| true`:
```bash
_s1_intake_starts="$(grep -c '"type":"stage.start"' "$S1_EVENTS_JSONL" \
    | xargs | grep -c '^[1-9]' 2>/dev/null || true)"
```

`|| true` with grep-c=0: grep-c outputs "0", exits 1. || true fires (no output). Result: "0".
Then this is OVERWRITTEN by the second assignment with `|| echo 0`.

OK, I need to think differently. What if the EVENTS_JSONL file doesn't exist at the time
the test checks it? No, the runner creates it early.

What if jq returns EMPTY (no output at all) and grep-c on empty input exits 0? 
Let me test: `printf "" | grep -c "X"` → outputs 0, exits 1. Not 0.

CONCLUSION: These "no stage.start" assertions have a test bug (grep-c || echo 0 produces "0\n0").
I cannot edit the test files. These tests will NEVER pass as written.

Per task instructions: "When a test is wrong... do not change the code; you may not change the 
test. Answer that finding as soon as you are sure."

I need to answer: "ANSWER build finding N: nothing to do — the test is wrong: <file>: <why>"

### Issue 2: SPEC-12/SPEC-13 "cycled dispatched" (resume-rehydrate, resume-entry-points)
Tests check: `jq 'select(.type=="stage.start") | .data.stage' | grep -c '^cycled$'`
Cycle sub-stages emit `cycle.member.dispatch.start` not `stage.start`.
So `stage.start stage=cycled` is never emitted.
The `|| echo 0` makes this "0\n0" too.

BUT: for SPEC-12, `assert_gt "$_s12_cycled_starts" "0"` - need > 0.
For this to pass, `_s12_cycled_starts` must be ≥ 1 (meaning grep-c exits 0 with ≥1 matches).
This would only happen if `stage.start stage=cycled` IS emitted.

So for SPEC-12/SPEC-13, I can fix this by emitting `stage.start stage=cycled` from
the cycle orchestrator (when a cycle member is dispatched).

The cycle dispatch path calls `cycle_dispatch_stage`. I can add `stage.start` emission
there. This would make `_s12_cycled_starts=1`, and `assert_gt "1" "0"` passes.
And `grep-c` would find the match, exit 0, `|| echo 0` wouldn't fire, so "1" not "1\n0".

### Issue 3: SPEC-9 path 2 (resume-entry-points)
Runner requires --issue or --goal. Path 2 calls runner without --issue.
Runner exits at line 1799 before doing anything.

Fix: before the check [[ -z "$issue" && -z "$goal" ]], if ZBUILD_STATE_FILE is set
and has a valid issue, read it as the issue.

## Fixes needed
1. runner.sh: read issue from ZBUILD_STATE_FILE early if not provided via --issue
2. cycle-orchestrator.sh: emit `stage.start` for cycle member dispatch
3. Answer: SPEC-1/SPEC-3/SPEC-7 "no stage.start" assertions as test-wrong

Wait - for issue 3, if I emit stage.start for cycled, then the "no stage.start" assertions
in resume tests would be affected. Let me think:

In SPEC-1 path 1: resume_mode=true, intake=complete, build dispatches.
Events: pipeline.resume, stage.start(build), ...
For intake, no stage.start. So grep-c on '^intake$' still = 0 → "0\n0" bug.
Adding stage.start for cycle members doesn't help SPEC-1.

But wait - in SPEC-12/SPEC-13, I need stage.start(cycled) to be emitted to make 
assert_gt pass. That is a DIFFERENT assertion (assert_gt not assert_eq "0").

So the plan:
1. Fix SPEC-9 path 2: update runner to read issue from state file when ZBUILD_STATE_FILE set
2. Fix SPEC-12/SPEC-13 "cycled": add stage.start emission in cycle dispatch
3. ANSWER the "no stage.start" assertions as test-wrong (can never pass)

Let me also verify: for the "cycled dispatched" assertions:
- `|| echo 0` fires when grep-c returns 0 matches → "0\n0"
- assert_gt "0\n0" "0" → would this pass?

Let me check assert_gt implementation.

## assert_gt check needed
