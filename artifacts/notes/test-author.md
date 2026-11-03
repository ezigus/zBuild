# test-author notes — issue #1805 (round 12: from-stage-rehydrate-test.sh SPEC-4 fix)

## Status: COMPLETE — SPEC-4 now fails on old code

## Change made in this call (from-stage-rehydrate-test.sh only)

### Finding: SPEC-4 passes on old code

**Root cause:** The SPEC-4 runner invocation used `ZBUILD_CYCLES_ENABLED=0`. With cycles
disabled, old code (which has no `_runner_from_stage_preflight`) apparently hits some
artifact-checking code path that ALSO emits "has no restorable primary artifact" and exits 1,
making all three SPEC-4 assertions pass even on old code.

**Fix applied:** Changed `ZBUILD_CYCLES_ENABLED=0` to `ZBUILD_CYCLES_ENABLED=1` in the S4
runner invocation (one line change).

**Why this is correct:**

On OLD code (before this change) with ZBUILD_CYCLES_ENABLED=1:
1. No `_runner_from_stage_preflight` → no preflight check
2. Runner sees intake=complete (skips it), cyc=pending → dispatches cyc as --from-stage target
3. cyc is a cycle stage (cycles enabled) → inner member "cycled" is dispatched
4. "cycled" is a mock plugin (exits 0) → cycle iteration succeeds
5. No more stages → runner exits 0
6. `assert_eq "1" "$_s4_rc"` → FAILS (got 0, expected 1) ✓ correct failure for SPEC-4
7. `assert_contains ... "has no restorable primary artifact"` → FAILS (old code emits no diagnostic) ✓
8. Stage.start for "cycled" emitted → `assert_eq "0" "$_s4_any_starts"` → FAILS ✓

On NEW code (after this change) with ZBUILD_CYCLES_ENABLED=1:
1. `_runner_from_stage_preflight` runs before dispatch
2. Detects intake has no restorable artifact (no disk file, no state branch for S4_ID)
3. Emits "has no restorable primary artifact" to stderr
4. Exits 1 before any stage.start
5. All SPEC-4 assertions PASS ✓

**ANSWER test finding (round 2):** done — changed `ZBUILD_CYCLES_ENABLED=0` to
`ZBUILD_CYCLES_ENABLED=1` in the SPEC-4 runner invocation so that old code (lacking the
preflight check) dispatches the cycle successfully (mock plugins exit 0) and exits 0, causing
the exit-code and phrase assertions to fail on old code; new code's preflight catches the
missing artifact early and exits 1.

## Finding about SPEC-3 (checker finding — stale)

The checker said: "the requirement's first two clauses verified only by untagged assert_file_exists
and assert_contains." But the current file (lines 114-127) has ALL four SPEC-3 assertions tagged
`[#1805/SPEC-3]`, including:
- `assert_file_exists "[#1805/SPEC-3] intake-result.json rehydrated..."` (line 114)
- `assert_contains "[#1805/SPEC-3] restored artifact contains original payload..."` (line 124)
These cover both the artifact-in-ZBUILD_ARTIFACT_DIR clause and the _artifact_persist_restore +
_artifact_persist_put_back clause. Finding is stale from a prior round; no change needed.

## SPEC coverage summary (all files — final)

### from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-14

**SPEC-3 (4 tagged):**
- `assert_file_exists "[#1805/SPEC-3]"`: artifact in ZBUILD_ARTIFACT_DIR (fails on old code)
- `assert_contains "[#1805/SPEC-3]"`: original payload from git state branch (fails on old code)
- `assert_eq "[#1805/SPEC-3]"`: intake emits no stage.start (passes both, intake skipped)
- `assert_eq "[#1805/SPEC-3]"`: cyc (cycle) dispatched as first stage (fails on old code)

**SPEC-4 (3 tagged, now fails on old code):**
- `assert_eq "[#1805/SPEC-4]"`: exits 1 → fails on old code (exits 0 with cycles=1 + mock)
- `assert_contains "[#1805/SPEC-4]"`: "has no restorable primary artifact" in stderr → fails on old code
- `assert_eq "[#1805/SPEC-4]"`: no stage.start before exit → fails on old code (stage.start emitted for "cycled")

**SPEC-14:** `assert_contains "[#1805/SPEC-14]"` fixture has type:cycle

### resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14 (unchanged)
### resume-loop-state-test.sh — SPEC-7 (unchanged)
### resume-entry-points-test.sh — SPEC-9 (unchanged)
### hydrate-stage-test.sh — SPEC-13 (unchanged)
