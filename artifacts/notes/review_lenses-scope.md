# scope lens notes — issue #1753

## Reading plan
1. tests/unit/runner-map-parallel-stage-envelope-test.sh — verify SPEC-4 present, awk window ≥128
2. tests/unit/engine-combines-map-test.sh — verify SPEC-1 tests
3. core/pipeline/runner.sh context around line 3725 — verify stop block placement
4. core/pipeline/strategies/map.sh — verify flagged logic and _ZB_MAP_UNFINISHED

## Findings

### 1. map.sh line 157 change — correct, minimal
`[[ "$outcome" == fail ]]` → `[[ "$outcome" != pass ]]`  
Delivers SPEC-1. No wider scope creep.

### 2. runner.sh stop block (lines 3728–3742) — correct placement
Sits between existing strategy-failure block and `_update_stage_status`. Delivers SPEC-4.
Asymmetry vs existing block: new block writes `_zbuild_state_set_stage_verdict "$state_file" "$_mg_id" "failed"` while the original block at 3718–3727 does not. Low finding.

### 3. ADR-040 amendment — complete
Text adds "runner.sh stops the run", `Enforced by` names SPEC-1 and SPEC-4. SPEC-2 satisfied.

### 4. engine-combines-map-test.sh
SPEC-1 tests: timed_out, out_of_turns, interrupted, then fail/unusable/throttled/rate_limited/unavailable/misconfigured/broken. All 10 non-pass outcomes covered.
M2 header at line 18 still says "failed" only — not updated to reflect broadened behavior. Low finding.

### 5. runner-map-parallel-stage-envelope-test.sh
awk window widened to `count>=128` per design (from 115). SPEC-8 regression addressed.
#1753/SPEC-4 tested in three assertions: (a) static grep for ZBUILD_RUN_FLAGGED check, (b) return 1 inside if-block, (c) runtime eval with ZBUILD_RUN_FLAGGED=yes verifying _update_stage_status not called. All correct.

### 6. No out-of-scope files changed. All 5 changed files are in planned scope.

### 7. Planned files NOT changed (expected — scope says verification-only):
tests/integration/map-members-reported-test.sh, merge-policy-auto-unless-flagged-test.sh,
tests/unit/merge-v2-result-test.sh, pr-delivery-v2-result-test.sh, pr-open-v2-inputs-test.sh, pr-open-v2-result-test.sh,
plugins/agent/pr-delivery/plugin.sh, plugins/tool/merge/plugin.sh, plugins/tool/pr-open/tests/pr-open-test.sh.
Not findings per instructions.
