#!/usr/bin/env bash
# Tests: resume rehydrates completed-stage artifacts from the git state branch
# before the dispatch loop. (issue #1805, ADR-006 §3.6)
#
# DSRHYD-1 [code]: on resume, before the dispatch loop, the runner calls
#   _artifact_persist_restore and _artifact_persist_put_back and places
#   completed-stage artifacts from the git state branch into
#   ZBUILD_ARTIFACT_DIR; a complete stage emits no stage.start event.
#
# DSRHYD-2 [code]: a complete stage whose primary artifact is absent from both
#   disk and the git state branch causes the resume to exit 1 before any
#   stage.start event is emitted.
#
# DSAMDR-1 / DSAMDR-2 [no-code]: ADR-006 step 3.6 and ADR-050 §6 are amended.
#
# The other entry paths are in resume-rehydrate-paths-test.sh; the fresh-run
# side of the ADR-006 / ADR-050 §6 boundary is in resume-fresh-run-test.sh.
#
# DSCYCL-1 [no-code]: the test fixture contains a pipeline stage of type: cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
ADR_006="$REPO_ROOT/docs/adr/ADR-006-resume-contract.md"
ADR_050="$REPO_ROOT/docs/adr/ADR-050-prior-work-reuse-contract.md"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "resume-rehydrate — artifact restore on resume (#1805)"
setup_test_env "resume-rehydrate-1805"
export ZBUILD_CONTRACT_VALIDATOR=warn

_ZB_ID="$(zb_test_issue)"

# ── Shared infrastructure ─────────────────────────────────────────────────────

# Create a git repo that the runner will use (CWD of the subprocess).
# The state branch is written here; the runner also reads from here.
WORK_REPO="$(setup_git_temp_repo resume-rehydrate-work)"
git -C "$WORK_REPO" config user.email t@e.st
git -C "$WORK_REPO" config user.name t

install_template_overlay "$WORK_REPO" artifact-snapshot-coverage

# Create mock plugins (intake + cycled for the artifact-snapshot-coverage cyclic fixture;
# cycled is the member of the cyc cycle stage, declared roles:[builder]).
# intake declares its role: the fixture stage asks for roles: [intake] (ADR-047 §5).
mock_plugin_factory "intake" "agent" 0 "" "intake" >/dev/null
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── SPEC-1: resume rehydrates artifacts from git state branch ─────────────────
print_test_section "[#1805/DSRHYD-1] on resume, artifacts restored from git state branch into ZBUILD_ARTIFACT_DIR"

# Given — a run has been interrupted; stage intake is marked complete with its artifact
#   present in the git state branch; stage cyc was the interrupted stage.
S1_STATE_DIR="$TEST_TEMP_DIR/s1-state"
S1_EVENTS_DIR="$TEST_TEMP_DIR/s1-events"
S1_EVENTS_JSONL="$S1_EVENTS_DIR/events.jsonl"
S1_STATE_FILE="$S1_STATE_DIR/pipeline-state.json"
mkdir -p "$S1_STATE_DIR/artifacts" "$S1_EVENTS_DIR"

# Write the intake primary artifact so the snapshot captures it.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$S1_STATE_DIR/artifacts/intake-result.json"

# Snapshot the artifact onto the state branch in WORK_REPO.
_s1_snap_rc=0
( export ZBUILD_STATE_DIR="$S1_STATE_DIR"
  cd "$WORK_REPO" && _artifact_persist_snapshot "$S1_STATE_DIR" "$_ZB_ID" ) \
    >"$TEST_TEMP_DIR/s1-snap.log" 2>&1 || _s1_snap_rc=$?
if [[ "$_s1_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSRHYD-1] setup: snapshot to state branch failed" \
        "rc=$_s1_snap_rc; $(cat "$TEST_TEMP_DIR/s1-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/DSRHYD-1] setup: state branch populated with intake-result.json"
fi

# Remove the artifact from disk to simulate the "artifacts not on disk" scenario.
rm -f "$S1_STATE_DIR/artifacts/intake-result.json"

# Write state file: intake=complete, cyc=pending.
jq -n \
    --arg run_id "s1-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_ZB_ID" \
    '{
        schema_version: 1,
        run_id: $run_id,
        issue: $issue,
        stage_statuses: {intake: "complete", cyc: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "in_progress",
        updated_at: $now
    }' > "$S1_STATE_FILE"

# When — the run is resumed via the --resume flag entry path (path 1).
set +e
( cd "$WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S1_STATE_DIR" \
    ZBUILD_STATE_FILE="$S1_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S1_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S1_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --resume --issue "$_ZB_ID" ) \
    >"$TEST_TEMP_DIR/s1-stdout.txt" 2>"$TEST_TEMP_DIR/s1-stderr.txt"
_s1_rc=$?
set -e

# Then — artifacts appear byte-identical, no stage.start for intake.
# [#1805/DSRHYD-1]: artifact must be present in ZBUILD_ARTIFACT_DIR after resume.
# Before the change: no rehydration → file absent → FAILS.
# After the change: rehydration copies artifact from state branch → PASSES.
assert_file_exists "[#1805/DSRHYD-1] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR" \
    "$S1_STATE_DIR/artifacts/intake-result.json"

# [#1805/DSRHYD-1]: artifact content must be byte-identical to what was snapshotted to the
# git state branch, proving _artifact_persist_restore read the artifact FROM the git state
# branch (not disk — the disk copy was deleted before the runner ran), and
# _artifact_persist_put_back placed it into ZBUILD_ARTIFACT_DIR byte-for-byte. These are
# the only two functions that together produce the effect: content from git state branch
# appearing byte-identically in ZBUILD_ARTIFACT_DIR.
# Before the change: no rehydration → file absent → content="" → not equal → FAILS.
# After the change: _artifact_persist_restore reads git branch; _artifact_persist_put_back
# writes to ZBUILD_ARTIFACT_DIR → content exactly matches the snapshotted payload → PASSES.
_s1_artifact_content="$(cat "$S1_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_eq \
    "[#1805/DSRHYD-1] artifact content is byte-identical to its state at interruption (via _artifact_persist_restore + _artifact_persist_put_back from git state branch)" \
    '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' "$_s1_artifact_content"

# [#1805/DSRHYD-1]: at least one stage must have dispatched, proving the dispatch loop ran.
# Combined with artifact-present (from git) and no-intake-stage.start, this establishes
# that the artifact was placed BEFORE the dispatch loop: the loop's first dispatchable
# stage (the cycle member cycled) ran and the artifact was already there.
# Before the change: runner may abort or dispatch stages in unexpected order → 0 dispatches.
# After the change: rehydrate → loop skips intake → dispatches cyc (cycle) → cycled dispatches.
_s1_any_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSRHYD-1] at least one stage dispatched after resume (dispatch loop ran; artifact was present before loop)" \
    "$_s1_any_starts" "0"

# [#1805/DSRHYD-1]: pipeline.resume event must appear in the events log BEFORE the first
# stage.start, proving _runner_resume_rehydrate (which calls _artifact_persist_restore
# then _artifact_persist_put_back) completed before the dispatch loop dispatched anything.
# The runner emits pipeline.resume immediately after _runner_resume_rehydrate returns,
# before entering the dispatch loop. pipeline.resume at a lower line number than the first
# stage.start proves the rehydration call completed before any stage was dispatched.
# Before the change: pipeline.resume may still be emitted (it predates #1805) but artifact
# absent → content assertion above already fails. This assertion adds the explicit
# "before the dispatch loop" ordering evidence, orthogonal to the artifact assertions.
_s1_resume_lineno=0
_s1_first_start_lineno=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$S1_EVENTS_JSONL" 2>/dev/null)"
    _s1_resume_lineno="${_s1_resume_lineno:-0}"
    _s1_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$S1_EVENTS_JSONL" 2>/dev/null)"
    _s1_first_start_lineno="${_s1_first_start_lineno:-0}"
fi
assert_gt "[#1805/DSRHYD-1] pipeline.resume event emitted (runner reached resume path)" \
    "$_s1_resume_lineno" "0"
assert_gt "[#1805/DSRHYD-1] pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1_first_start_lineno" "$_s1_resume_lineno"

# [#1805/DSRHYD-1]: intake must NOT have a stage.start event (it was complete and skipped).
_s1_intake_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    # Use wc -l (not grep -c ... || echo 0): grep -c exits 1 on 0 matches, causing
    # || echo 0 to fire and producing "0\n0" instead of "0". wc -l always exits 0.
    _s1_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSRHYD-1] intake emits no stage.start (complete stage skipped)" \
    "0" "$_s1_intake_starts"

# [#1805/DSSKIP-1]: dispatch-unit loop skips a stage marked complete whose primary
# artifact is present after rehydration, emitting no stage.start for that stage.
# Given — a run is being resumed; intake is marked complete in persisted state
#   (s1 state file above: stage_statuses.intake="complete"); its primary artifact
#   is present in ZBUILD_ARTIFACT_DIR after rehydration (the DSRHYD-1 path 1 runner
#   call above placed it there via _artifact_persist_restore + _artifact_persist_put_back).
#   The dispatch-unit loop is exercised by the cyclic fixture run with ZBUILD_CYCLES_ENABLED=1.
# When — the dispatch-unit loop reaches stage intake (same DSRHYD-1 path 1 runner call;
#   the loop executes after _runner_resume_rehydrate places the artifact).
# Then — no stage.start event is emitted for that stage (the loop sees resume_mode=1
#   and the artifact is present → it skips without dispatching).
# Before the change: dispatch-unit loop has no skip guard conditioned on resume_mode
#   and artifact presence → dispatches intake → stage.start emitted → FAILS.
# After the change: skip guard checks resume_mode + artifact present → skips → PASSES.
assert_eq "[#1805/DSSKIP-1] dispatch-unit loop emits no stage.start for complete stage whose artifact is present after rehydration (intake skipped)" \
    "0" "$_s1_intake_starts"

# [#1805/DSDSPK-1]: stage k (the interrupted stage) must emit stage.start when the
# dispatch loop reaches it on resume. The fixture has intake=complete (stage k-1)
# and cyc=pending (stage k). Cycles dispatch their inner members: cycled emits
# stage.start with stage=cycled. This proves the dispatch loop reached and dispatched
# stage k (cyc), not just that any stage ran.
# Given — a run with stages intake (k-1) and cyc (k) was interrupted during stage k;
#   intake is marked complete with its artifact present in ZBUILD_ARTIFACT_DIR after
#   rehydration (the DSRHYD-1 path 1 runner call above placed it there).
# When — the dispatch loop reaches stage cyc (k) during resume (same runner call as DSRHYD-1 path 1).
# Then — stage cyc dispatches its inner member cycled, which emits stage.start,
#   confirming stage k was dispatched and was not skipped.
# Before the change: runner may abort before dispatching cyc → 0 cycled starts → FAILS.
# After the change: rehydrate → loop skips intake → dispatches cyc → cycled dispatches → PASSES.
_s1_cycled_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_cycled_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="cycled") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSDSPK-1] stage k (cyc → member cycled) dispatched and emits stage.start on resume (interrupted stage was dispatched)" \
    "$_s1_cycled_starts" "0"

# [#1805/DSDSPK-1]: when k is a cycle stage, cycle.start must be emitted for k (cyc) itself.
# The requirement says: "when k is a cycle stage, a cycle.start event is emitted for k AND
# stage.start is emitted for k's first cycle member". The cycled member's stage.start
# (above) proves the member was dispatched. This assertion proves the cycle stage itself
# (cyc) emitted cycle.start — the cycle.start half of the DSDSPK-1 Then clause.
# Before the change: runner may abort before dispatching cyc → no cycle.start emitted
#   → count=0 → FAILS.
# After the change: rehydrate → dispatch loop reaches cyc → cycle.start emitted for cyc
#   → count=1 → PASSES.
_s1_cyc_cycle_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_cyc_cycle_starts="$(jq -r 'select(.type=="cycle.start") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSDSPK-1] cycle.start emitted for stage k (cyc) on resume (cycle.start half of Then: cycle stage k was dispatched)" \
    "$_s1_cyc_cycle_starts" "0"

# ── SPEC-2: missing artifact causes resume to exit 1 ─────────────────────────
print_test_section "[#1805/DSRHYD-2] absent artifact causes resume to exit 1 before any stage.start"

# Given — a run is being resumed; stage intake is marked complete in persisted state;
#   its primary artifact is absent from both disk and the git state branch.
S2_STATE_DIR="$TEST_TEMP_DIR/s2-state"
S2_EVENTS_DIR="$TEST_TEMP_DIR/s2-events"
S2_EVENTS_JSONL="$S2_EVENTS_DIR/events.jsonl"
S2_STATE_FILE="$S2_STATE_DIR/pipeline-state.json"
mkdir -p "$S2_STATE_DIR/artifacts" "$S2_EVENTS_DIR"

# Use a fresh WORK_REPO2 for SPEC-2 so SPEC-1's state branch is not present.
# A new issue identity guarantees no state branch exists.
_S2_ID="$(zb_test_issue)"
WORK_REPO2="$(setup_git_temp_repo resume-rehydrate-work2)"
git -C "$WORK_REPO2" config user.email t@e.st
git -C "$WORK_REPO2" config user.name t
install_template_overlay "$WORK_REPO2" artifact-snapshot-coverage

# State: intake=complete but NO artifact on disk and NO state branch.
jq -n \
    --arg run_id "s2-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S2_ID" \
    '{
        schema_version: 1,
        run_id: $run_id,
        issue: $issue,
        stage_statuses: {intake: "complete", cyc: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "in_progress",
        updated_at: $now
    }' > "$S2_STATE_FILE"

# When — the runner processes that stage during resume rehydration.
set +e
( cd "$WORK_REPO2" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S2_STATE_DIR" \
    ZBUILD_STATE_FILE="$S2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --resume --issue "$_S2_ID" ) \
    >"$TEST_TEMP_DIR/s2-stdout.txt" 2>"$TEST_TEMP_DIR/s2-stderr.txt"
_s2_rc=$?
set -e

# Then — runner exits 1; no stage.start event emitted.
# [#1805/DSRHYD-2]: runner must exit 1 when artifact absent from disk AND state branch.
# Before the change: runner warns about stale artifact and continues → exits 0 → FAILS.
# After the change: runner exits 1 after failing to restore the artifact → PASSES.
assert_eq "[#1805/DSRHYD-2] resume exits 1 when primary artifact cannot be restored" \
    "1" "$_s2_rc"

# [#1805/DSRHYD-2]: no stage.start event must be emitted before the exit.
# (exit 1 happens before the dispatch loop reaches any stage)
_s2_any_starts=0
if [[ -f "$S2_EVENTS_JSONL" ]]; then
    _s2_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSRHYD-2] no stage.start emitted before exit 1" \
    "0" "$_s2_any_starts"

# ── SPEC-5: ADR-006 amended with artifact-restore step 3.5 ───────────────────
print_test_section "[#1805/DSAMDR-1] ADR-006 amended: step 3.6 restores artifacts before dispatch loop"

# Then — ADR-006-resume-contract.md contains step 3.6 describing artifact
# restoration before the dispatch loop; enforcing test names and exit 1 clause present.
# [#1805/DSAMDR-1]: ADR-006 must contain the amendment text describing artifact
# restoration in the resume sequence and exit 1 for an absent artifact.
# This passes after the doc change; it need not fail before.
_adr006="$(cat "$ADR_006" 2>/dev/null || true)"

assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 added (step number present)" \
    "$_adr006" "3.6"

assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 names _runner_resume_rehydrate" \
    "$_adr006" "_runner_resume_rehydrate"

assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 names resume-rehydrate-test.sh as enforcing test" \
    "$_adr006" "resume-rehydrate-test.sh"

assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 names resume-entry-points-test.sh as enforcing test" \
    "$_adr006" "resume-entry-points-test.sh"

# [#1805/DSAMDR-1]: ADR-006 must document that a still-absent artifact causes exit 1.
# Before the doc change: the clause is absent → FAILS. After change: PASSES.
assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 documents still-absent artifact causes exit 1" \
    "$_adr006" "exit 1"

# [#1805/DSAMDR-1]: ADR-006 step 3.6 must say restoration happens "before the dispatch loop".
# Before the doc change: phrase absent → FAILS. After change: PASSES.
assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 documents restore happens before the dispatch loop" \
    "$_adr006" "before the dispatch loop"

# [#1805/DSAMDR-1]: ADR-006 step 3.6 must say artifacts are restored "from the git state branch".
# Before the doc change: phrase absent → FAILS. After change: PASSES.
assert_contains "[#1805/DSAMDR-1] ADR-006 step 3.6 documents artifacts restored from the git state branch" \
    "$_adr006" "git state branch"

# ── SPEC-6: ADR-050 §6 amended with resume boundary note ─────────────────────
print_test_section "[#1805/DSAMDR-2] ADR-050 §6 amended: resume governed by ADR-006; new-run invariant governs new runs"

# Then — ADR-050 §6 contains the boundary note distinguishing new runs from resumes;
# the note names ADR-006 as governing resumes and says a resume continues the same run.
# Extract §6 from ADR-050: content from the "### 6." heading up to (not including) "### 7."
_adr050_s6="$(awk \
    '/^### 6\./{p=1} p && /^### [0-9]+\./ && !/^### 6\./{exit} p{print}' \
    "$ADR_050" 2>/dev/null || true)"

# [#1805/DSAMDR-2]: §6 boundary note must say the invariant applies to new runs
# and that a resume is governed by ADR-006.
assert_contains "[#1805/DSAMDR-2] ADR-050 §6 boundary note says invariant applies to new runs" \
    "$_adr050_s6" "new run"

assert_contains "[#1805/DSAMDR-2] ADR-050 §6 boundary note names ADR-006 as governing resume" \
    "$_adr050_s6" "ADR-006"

# [#1805/DSAMDR-2]: §6 must say "a resume continues the same run" (not just reference ADR-006).
# Before the doc change: clause absent → FAILS. After change: PASSES.
assert_contains "[#1805/DSAMDR-2] ADR-050 §6 boundary note says a resume continues the same run" \
    "$_adr050_s6" "continues the same run"

# [#1805/DSAMDR-2]: §6's Enforced-by section must cite resume-fresh-run-test.sh and
# resume-entry-points-test.sh by name. The requirement says "§6's Enforced by section
# updated to cite resume-fresh-run-test.sh (DSFRSH-2 for the new-run side) and
# resume-entry-points-test.sh (DSENTR-1 for the resume side)". A §6 that only adds the
# boundary prose but omits the Enforced-by update would still pass the three assertions
# above but fail these two, ensuring the Enforced-by section was actually updated.
# This requirement need not fail before this change (no-code property); it must pass after.
assert_contains "[#1805/DSAMDR-2] ADR-050 §6 Enforced-by section cites resume-fresh-run-test.sh (DSFRSH-2 for new-run side)" \
    "$_adr050_s6" "resume-fresh-run-test.sh"

assert_contains "[#1805/DSAMDR-2] ADR-050 §6 Enforced-by section cites resume-entry-points-test.sh (DSENTR-1 for resume side)" \
    "$_adr050_s6" "resume-entry-points-test.sh"

print_test_results
cleanup_test_env
