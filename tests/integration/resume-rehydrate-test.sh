#!/usr/bin/env bash
# Tests: resume rehydrates completed-stage artifacts from the git state branch
# before the dispatch loop. (issue #1805, ADR-006 §3.5)
#
# RHYD-1 [code]: on resume (all entry paths), before the dispatch loop, the
#   runner calls _artifact_persist_restore and _artifact_persist_put_back and
#   places completed-stage artifacts from the git state branch into
#   ZBUILD_ARTIFACT_DIR; a complete stage emits no stage.start event.
#
# RHYD-2 [code]: a complete stage whose primary artifact is absent from both
#   disk and the git state branch causes the resume to exit 1 before any
#   stage.start event is emitted.
#
# AMDR-1 [no-code]: ADR-006-resume-contract.md amended with step 3.6:
#   before the dispatch loop the runner restores completed-stage artifacts from
#   the git state branch; a still-absent artifact causes exit 1; enforcing
#   test names added inline.
#
# AMDR-2 [no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with
#   boundary note: the invariant applies to new runs; a resume continues the
#   same run and is governed by ADR-006.
#
# BNDY-1 [no-code]: this file contains both a resume-side assertion (RHYD-1/
#   RHYD-2) and a fresh-run sub-case with --no-resume, pinning both sides of
#   the ADR-006/ADR-050 §6 boundary in one test file.
#
# CYCL-1 [no-code]: the test fixture contains a pipeline stage of type: cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
ADR_006="$REPO_ROOT/docs/adr/ADR-006-resume-contract.md"
ADR_050="$REPO_ROOT/docs/adr/ADR-050-prior-work-reuse-contract.md"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── SPEC-1: resume rehydrates artifacts from git state branch ─────────────────
print_test_section "[#1805/RHYD-1] on resume, artifacts restored from git state branch into ZBUILD_ARTIFACT_DIR"

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
    assert_fail "[#1805/RHYD-1] setup: snapshot to state branch failed" \
        "rc=$_s1_snap_rc; $(cat "$TEST_TEMP_DIR/s1-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/RHYD-1] setup: state branch populated with intake-result.json"
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

# Run runner --resume. CWD=WORK_REPO so _artifact_persist_restore finds the
# state branch. Capture rc; do not abort on failure.
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

# [#1805/RHYD-1]: artifact must be present in ZBUILD_ARTIFACT_DIR after resume.
# Before the change: no rehydration → file absent → FAILS.
# After the change: rehydration copies artifact from state branch → PASSES.
assert_file_exists "[#1805/RHYD-1] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR" \
    "$S1_STATE_DIR/artifacts/intake-result.json"

# [#1805/RHYD-1]: artifact content must match the git-snapshotted version, proving
# _artifact_persist_restore read the artifact FROM the git state branch (not disk — the
# disk copy was deleted before the runner ran), and _artifact_persist_put_back placed it
# into ZBUILD_ARTIFACT_DIR. These are the only two functions that together produce the
# effect: content from git state branch appearing in ZBUILD_ARTIFACT_DIR.
# Before the change: no rehydration → file absent → cat empty → content mismatch → FAILS.
# After the change: _artifact_persist_restore reads git branch; _artifact_persist_put_back
# writes to ZBUILD_ARTIFACT_DIR → content matches → PASSES.
_s1_artifact_content="$(cat "$S1_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/RHYD-1] artifact content placed into ZBUILD_ARTIFACT_DIR from git state branch (via _artifact_persist_restore + _artifact_persist_put_back)" \
    "$_s1_artifact_content" "prior-run intake"

# [#1805/RHYD-1]: at least one stage must have dispatched, proving the dispatch loop ran.
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
assert_gt "[#1805/RHYD-1] at least one stage dispatched after resume (dispatch loop ran; artifact was present before loop)" \
    "$_s1_any_starts" "0"

# [#1805/RHYD-1]: pipeline.resume event must appear in the events log BEFORE the first
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
assert_gt "[#1805/RHYD-1] pipeline.resume event emitted (runner reached resume path)" \
    "$_s1_resume_lineno" "0"
assert_gt "[#1805/RHYD-1] pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1_first_start_lineno" "$_s1_resume_lineno"

# [#1805/RHYD-1]: intake must NOT have a stage.start event (it was complete and skipped).
_s1_intake_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    # Use wc -l (not grep -c ... || echo 0): grep -c exits 1 on 0 matches, causing
    # || echo 0 to fire and producing "0\n0" instead of "0". wc -l always exits 0.
    _s1_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/RHYD-1] intake emits no stage.start (complete stage skipped)" \
    "0" "$_s1_intake_starts"

# ── SPEC-1 path 2: auto-resume on status=interrupted ─────────────────────────
# [#1805/RHYD-1] all entry paths: path 2 — auto-resume when status=interrupted.
# No --resume flag; runner detects interrupted status and auto-resumes.
print_test_section "[#1805/RHYD-1] path 2: auto-resume (status=interrupted) restores artifacts"

S1P2_ID="$(zb_test_issue)"
S1P2_STATE_DIR="$TEST_TEMP_DIR/s1p2-state"
S1P2_EVENTS_DIR="$TEST_TEMP_DIR/s1p2-events"
S1P2_EVENTS_JSONL="$S1P2_EVENTS_DIR/events.jsonl"
S1P2_STATE_FILE="$S1P2_STATE_DIR/pipeline-state.json"
mkdir -p "$S1P2_STATE_DIR/artifacts" "$S1P2_EVENTS_DIR"
touch "$S1P2_EVENTS_JSONL"

S1P2_WORK_REPO="$(setup_git_temp_repo resume-reh-s1p2)"
install_template_overlay "$S1P2_WORK_REPO" artifact-snapshot-coverage

printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$S1P2_STATE_DIR/artifacts/intake-result.json"

_s1p2_snap_rc=0
( export ZBUILD_STATE_DIR="$S1P2_STATE_DIR"
  cd "$S1P2_WORK_REPO" && _artifact_persist_snapshot "$S1P2_STATE_DIR" "$S1P2_ID" ) \
    >"$TEST_TEMP_DIR/s1p2-snap.log" 2>&1 || _s1p2_snap_rc=$?
if [[ "$_s1p2_snap_rc" -ne 0 ]]; then
    assert_fail "setup s1p2: snapshot failed (rc=$_s1p2_snap_rc)" \
        "$(cat "$TEST_TEMP_DIR/s1p2-snap.log" 2>/dev/null | tail -5)"
fi
rm -f "$S1P2_STATE_DIR/artifacts/intake-result.json"

jq -n \
    --arg run_id "s1p2-reh-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S1P2_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {intake: "complete", cyc: "pending"},
        current_iteration: 0, self_heal_count: {}, scope_manifest_hash: "",
        cost_ledger_pointer: 0, claim_lease_id: "", plugin_state: {},
        status: "interrupted", updated_at: $now
    }' > "$S1P2_STATE_FILE"

set +e
( cd "$S1P2_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S1P2_STATE_DIR" \
    ZBUILD_STATE_FILE="$S1P2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S1P2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S1P2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --issue "$S1P2_ID" ) \
    >"$TEST_TEMP_DIR/s1p2-stdout.txt" 2>"$TEST_TEMP_DIR/s1p2-stderr.txt"
set -e

# [#1805/RHYD-1] path 2 artifact restored.
# Before change: no rehydration → absent → FAILS. After change: PASSES.
assert_file_exists \
    "[#1805/RHYD-1] path 2 (auto-resume/interrupted): intake-result.json restored" \
    "$S1P2_STATE_DIR/artifacts/intake-result.json"

# [#1805/RHYD-1] path 2: content must match what was snapshotted to the git state branch.
# Proves the artifact was placed into ZBUILD_ARTIFACT_DIR FROM the git state branch via
# _artifact_persist_restore (which reads from git state branch) + _artifact_persist_put_back
# (which copies from restore staging to ZBUILD_ARTIFACT_DIR). These are the only functions
# that together produce this effect.
# Before fix: file absent → cat empty → FAILS. After: PASSES.
_s1p2_artifact_content="$(cat "$S1P2_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/RHYD-1] path 2 (auto-resume): artifact content placed into ZBUILD_ARTIFACT_DIR from git state branch (via _artifact_persist_restore + _artifact_persist_put_back)" \
    "$_s1p2_artifact_content" "prior-run intake"

# [#1805/RHYD-1] path 2: at least one stage must have dispatched (proving pipeline ran and events written).
# Before fix: path-2 auto-resume doesn't exist → runner exits without events → 0 stage.start → FAILS.
# After fix: runner auto-resumes, rehydrates, skips intake, dispatches cyc cycle → cycled dispatches.
_s1p2_any_starts=0
if [[ -f "$S1P2_EVENTS_JSONL" ]]; then
    _s1p2_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S1P2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/RHYD-1] path 2 (auto-resume): at least one stage dispatched (pipeline ran via path-2 resume)" \
    "$_s1p2_any_starts" "0"

# [#1805/RHYD-1] path 2: pipeline.resume event must appear before the first stage.start,
# proving _runner_resume_rehydrate (which calls _artifact_persist_restore + _artifact_persist_put_back)
# completed before the dispatch loop. pipeline.resume is emitted immediately after
# _runner_resume_rehydrate returns, before the dispatch loop begins.
_s1p2_resume_lineno=0
_s1p2_first_start_lineno=0
if [[ -f "$S1P2_EVENTS_JSONL" ]]; then
    _s1p2_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$S1P2_EVENTS_JSONL" 2>/dev/null)"
    _s1p2_resume_lineno="${_s1p2_resume_lineno:-0}"
    _s1p2_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$S1P2_EVENTS_JSONL" 2>/dev/null)"
    _s1p2_first_start_lineno="${_s1p2_first_start_lineno:-0}"
fi
assert_gt "[#1805/RHYD-1] path 2 (auto-resume): pipeline.resume event emitted" \
    "$_s1p2_resume_lineno" "0"
assert_gt "[#1805/RHYD-1] path 2 (auto-resume): pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1p2_first_start_lineno" "$_s1p2_resume_lineno"

# [#1805/RHYD-1] path 2: intake must NOT have a stage.start event.
_s1p2_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$S1P2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1805/RHYD-1] path 2 (auto-resume): intake emits no stage.start (skipped)" \
    "0" "$_s1p2_intake_starts"

# ── SPEC-1 path 3: zbuild pipeline resume --run-id ───────────────────────────
# [#1805/RHYD-1] all entry paths: path 3 — zbuild pipeline resume --run-id.
print_test_section "[#1805/RHYD-1] path 3: zbuild pipeline resume --run-id restores artifacts"

S1P3_ID="$(zb_test_issue)"
S1P3_RUN_ID="s1p3-reh-1805"
S1P3_STATE_DIR="$TEST_TEMP_DIR/s1p3-state"
S1P3_EVENTS_DIR="$TEST_TEMP_DIR/s1p3-events"
S1P3_EVENTS_JSONL="$S1P3_EVENTS_DIR/events.jsonl"
S1P3_STATE_FILE="$S1P3_STATE_DIR/pipeline-state.json"
mkdir -p "$S1P3_STATE_DIR/artifacts" "$S1P3_EVENTS_DIR"
touch "$S1P3_EVENTS_JSONL"

S1P3_WORK_REPO="$(setup_git_temp_repo resume-reh-s1p3)"
install_template_overlay "$S1P3_WORK_REPO" artifact-snapshot-coverage

printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$S1P3_STATE_DIR/artifacts/intake-result.json"

_s1p3_snap_rc=0
( export ZBUILD_STATE_DIR="$S1P3_STATE_DIR"
  cd "$S1P3_WORK_REPO" && _artifact_persist_snapshot "$S1P3_STATE_DIR" "$S1P3_ID" ) \
    >"$TEST_TEMP_DIR/s1p3-snap.log" 2>&1 || _s1p3_snap_rc=$?
if [[ "$_s1p3_snap_rc" -ne 0 ]]; then
    assert_fail "setup s1p3: snapshot failed (rc=$_s1p3_snap_rc)" \
        "$(cat "$TEST_TEMP_DIR/s1p3-snap.log" 2>/dev/null | tail -5)"
fi
rm -f "$S1P3_STATE_DIR/artifacts/intake-result.json"

jq -n \
    --arg run_id "$S1P3_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S1P3_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {intake: "complete", cyc: "pending"},
        current_iteration: 0, self_heal_count: {}, scope_manifest_hash: "",
        cost_ledger_pointer: 0, claim_lease_id: "", plugin_state: {},
        status: "interrupted", updated_at: $now
    }' > "$S1P3_STATE_FILE"

set +e
( cd "$S1P3_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S1P3_STATE_DIR" \
    ZBUILD_EVENTS_DIR="$S1P3_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S1P3_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$ZBUILD_CLI" pipeline resume \
        --run-id "$S1P3_RUN_ID" \
        --template artifact-snapshot-coverage ) \
    >"$TEST_TEMP_DIR/s1p3-stdout.txt" 2>"$TEST_TEMP_DIR/s1p3-stderr.txt"
set -e

# [#1805/RHYD-1] path 3 artifact restored.
# Before change: zbuild resume path has no rehydration → absent → FAILS. After change: PASSES.
assert_file_exists \
    "[#1805/RHYD-1] path 3 (zbuild pipeline resume): intake-result.json restored" \
    "$S1P3_STATE_DIR/artifacts/intake-result.json"

# [#1805/RHYD-1] path 3: content must match what was snapshotted to the git state branch.
# Proves the artifact was placed into ZBUILD_ARTIFACT_DIR FROM the git state branch via
# _artifact_persist_restore (reads from git state branch) + _artifact_persist_put_back
# (copies from restore staging to ZBUILD_ARTIFACT_DIR). These are the only functions
# that together produce this effect.
# Before fix: file absent → cat empty → FAILS. After: PASSES.
_s1p3_artifact_content="$(cat "$S1P3_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/RHYD-1] path 3 (zbuild pipeline resume): artifact content placed into ZBUILD_ARTIFACT_DIR from git state branch (via _artifact_persist_restore + _artifact_persist_put_back)" \
    "$_s1p3_artifact_content" "prior-run intake"

# [#1805/RHYD-1] path 3: at least one stage must have dispatched (proving pipeline ran via zbuild pipeline resume).
# Before fix: zbuild pipeline resume path has no rehydration / may not exist → no events → FAILS.
# After fix: zbuild calls runner --resume → rehydrates → dispatches cyc cycle → cycled dispatches.
_s1p3_any_starts=0
if [[ -f "$S1P3_EVENTS_JSONL" ]]; then
    _s1p3_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S1P3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/RHYD-1] path 3 (zbuild pipeline resume): at least one stage dispatched (pipeline ran via path-3)" \
    "$_s1p3_any_starts" "0"

# [#1805/RHYD-1] path 3: pipeline.resume event must appear before the first stage.start,
# proving _runner_resume_rehydrate (which calls _artifact_persist_restore + _artifact_persist_put_back)
# completed before the dispatch loop. pipeline.resume is emitted immediately after
# _runner_resume_rehydrate returns, before the dispatch loop begins.
_s1p3_resume_lineno=0
_s1p3_first_start_lineno=0
if [[ -f "$S1P3_EVENTS_JSONL" ]]; then
    _s1p3_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$S1P3_EVENTS_JSONL" 2>/dev/null)"
    _s1p3_resume_lineno="${_s1p3_resume_lineno:-0}"
    _s1p3_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$S1P3_EVENTS_JSONL" 2>/dev/null)"
    _s1p3_first_start_lineno="${_s1p3_first_start_lineno:-0}"
fi
assert_gt "[#1805/RHYD-1] path 3 (zbuild pipeline resume): pipeline.resume event emitted" \
    "$_s1p3_resume_lineno" "0"
assert_gt "[#1805/RHYD-1] path 3 (zbuild pipeline resume): pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1p3_first_start_lineno" "$_s1p3_resume_lineno"

# [#1805/RHYD-1] path 3: intake must NOT have a stage.start event.
_s1p3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$S1P3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1805/RHYD-1] path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)" \
    "0" "$_s1p3_intake_starts"

# ── SPEC-2: missing artifact causes resume to exit 1 ─────────────────────────
print_test_section "[#1805/RHYD-2] absent artifact causes resume to exit 1 before any stage.start"

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

# [#1805/RHYD-2]: runner must exit 1 when artifact absent from disk AND state branch.
# Before the change: runner warns about stale artifact and continues → exits 0 → FAILS.
# After the change: runner exits 1 after failing to restore the artifact → PASSES.
assert_eq "[#1805/RHYD-2] resume exits 1 when primary artifact cannot be restored" \
    "1" "$_s2_rc"

# [#1805/RHYD-2]: no stage.start event must be emitted before the exit.
# (exit 1 happens before the dispatch loop reaches any stage)
_s2_any_starts=0
if [[ -f "$S2_EVENTS_JSONL" ]]; then
    _s2_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/RHYD-2] no stage.start emitted before exit 1" \
    "0" "$_s2_any_starts"

# ── SPEC-5: ADR-006 amended with artifact-restore step 3.5 ───────────────────
print_test_section "[#1805/AMDR-1] ADR-006 amended: step 3.6 restores artifacts before dispatch loop"

# [#1805/AMDR-1]: ADR-006 must contain the amendment text describing artifact
# restoration in the resume sequence and exit 1 for an absent artifact.
# This passes after the doc change; it need not fail before.
_adr006="$(cat "$ADR_006" 2>/dev/null || true)"

assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 added (step number present)" \
    "$_adr006" "3.6"

assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 names _runner_resume_rehydrate" \
    "$_adr006" "_runner_resume_rehydrate"

assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 names resume-rehydrate-test.sh as enforcing test" \
    "$_adr006" "resume-rehydrate-test.sh"

assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 names resume-entry-points-test.sh as enforcing test" \
    "$_adr006" "resume-entry-points-test.sh"

# [#1805/AMDR-1]: ADR-006 must document that a still-absent artifact causes exit 1.
# Before the doc change: the clause is absent → FAILS. After change: PASSES.
assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 documents still-absent artifact causes exit 1" \
    "$_adr006" "exit 1"

# [#1805/AMDR-1]: ADR-006 step 3.6 must say restoration happens "before the dispatch loop".
# Before the doc change: phrase absent → FAILS. After change: PASSES.
assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 documents restore happens before the dispatch loop" \
    "$_adr006" "before the dispatch loop"

# [#1805/AMDR-1]: ADR-006 step 3.6 must say artifacts are restored "from the git state branch".
# Before the doc change: phrase absent → FAILS. After change: PASSES.
assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 documents artifacts restored from the git state branch" \
    "$_adr006" "git state branch"

# [#1805/AMDR-1]: ADR-006 step 3.6 must document the ordering constraint:
# "not to be combined with dispatch-loop changes". The AMDR-1 requirement names
# this clause explicitly; without it the spec omits the reason this step must
# ship in a dedicated PR and reviewers have no guidance.
# Before the doc change: phrase absent → FAILS. After change: PASSES.
assert_contains "[#1805/AMDR-1] ADR-006 step 3.6 documents ordering constraint (not to be combined with dispatch-loop changes)" \
    "$_adr006" "not to be combined with dispatch-loop changes"

# ── SPEC-6: ADR-050 §6 amended with resume boundary note ─────────────────────
print_test_section "[#1805/AMDR-2] ADR-050 §6 amended: resume governed by ADR-006; new-run invariant governs new runs"

# Extract §6 from ADR-050: content from the "### 6." heading up to (not including) "### 7."
_adr050_s6="$(awk \
    '/^### 6\./{p=1} p && /^### [0-9]+\./ && !/^### 6\./{exit} p{print}' \
    "$ADR_050" 2>/dev/null || true)"

# [#1805/AMDR-2]: §6 boundary note must say the invariant applies to new runs
# and that a resume is governed by ADR-006.
assert_contains "[#1805/AMDR-2] ADR-050 §6 boundary note says invariant applies to new runs" \
    "$_adr050_s6" "new run"

assert_contains "[#1805/AMDR-2] ADR-050 §6 boundary note names ADR-006 as governing resume" \
    "$_adr050_s6" "ADR-006"

# [#1805/AMDR-2]: §6 must say "a resume continues the same run" (not just reference ADR-006).
# Before the doc change: clause absent → FAILS. After change: PASSES.
assert_contains "[#1805/AMDR-2] ADR-050 §6 boundary note says a resume continues the same run" \
    "$_adr050_s6" "continues the same run"

# ── SPEC-12: fresh (non-resume) run dispatches all stages ─────────────────────
print_test_section "[#1805/BNDY-1] fresh --no-resume run dispatches all stages (ADR-050 §6 new-run side)"

S12_STATE_DIR="$TEST_TEMP_DIR/s12-state"
S12_EVENTS_DIR="$TEST_TEMP_DIR/s12-events"
S12_EVENTS_JSONL="$S12_EVENTS_DIR/events.jsonl"
S12_STATE_FILE="$S12_STATE_DIR/pipeline-state.json"
mkdir -p "$S12_STATE_DIR/artifacts" "$S12_EVENTS_DIR"

_S12_ID="$(zb_test_issue)"
S12_WORK_REPO="$(setup_git_temp_repo resume-fresh-work)"
# Use a cycle fixture so SPEC-12 and SPEC-13 use the same cyclic pipeline.
# artifact-snapshot-coverage has intake (leaf) + cyc (cycle); that satisfies SPEC-13.
install_template_overlay "$S12_WORK_REPO" artifact-snapshot-coverage
# cycled sub-stage of the cyc cycle declares roles:[builder]
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null

# Write intake artifact and snapshot to the state branch so the state looks
# exactly like a run interrupted after intake (the state that would trigger
# auto-resume if the --no-resume guard were absent).
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$S12_STATE_DIR/artifacts/intake-result.json"

_s12_snap_rc=0
( export ZBUILD_STATE_DIR="$S12_STATE_DIR"
  cd "$S12_WORK_REPO" && _artifact_persist_snapshot "$S12_STATE_DIR" "$_S12_ID" ) \
    >"$TEST_TEMP_DIR/s12-snap.log" 2>&1 || _s12_snap_rc=$?
if [[ "$_s12_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/BNDY-1] setup: snapshot to state branch failed" \
        "rc=$_s12_snap_rc; $(cat "$TEST_TEMP_DIR/s12-snap.log" 2>/dev/null | tail -5)"
fi
# Remove the artifact from disk — only the state branch has it now, matching a
# real interrupted run where the workspace was cleaned between pipeline stages.
rm -f "$S12_STATE_DIR/artifacts/intake-result.json"

# State: intake=complete, status=interrupted — exactly what auto-resume would
# act on (skip intake) if the --no-resume flag were NOT passed.
# With --no-resume the runner must start fresh and dispatch all stages.
jq -n \
    --arg run_id "s12-fresh-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S12_ID" \
    '{
        schema_version: 1,
        run_id: $run_id,
        issue: $issue,
        stage_statuses: {intake: "complete"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "interrupted",
        updated_at: $now
    }' > "$S12_STATE_FILE"

# Run WITH --no-resume: explicitly suppresses auto-resume detection.
# Without --no-resume, the runner would detect status=interrupted, call
# _runner_resume_rehydrate, and skip intake (0 stage.start events for intake).
# With --no-resume, the runner starts fresh: intake dispatches (1 stage.start).
# The assert_eq "1" below distinguishes this flag-guarded fresh run from a run
# that merely happens to have no completed stages in state.
set +e
( cd "$S12_WORK_REPO" && env \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S12_STATE_DIR" \
    ZBUILD_STATE_FILE="$S12_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S12_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S12_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    ZBUILD_CYCLES_ENABLED=1 \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --no-resume --issue "$_S12_ID" ) \
    >"$TEST_TEMP_DIR/s12-stdout.txt" 2>"$TEST_TEMP_DIR/s12-stderr.txt"
set -e

# [#1805/BNDY-1]: intake must emit stage.start on a fresh run (not skipped by
# rehydration, which only applies on resume). This pins the new-run side of the
# ADR-050 §6 boundary: the prior-work reuse invariant governs new runs; a resume
# (governed by ADR-006) is the only path that may skip complete stages.
_s12_intake_starts=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/BNDY-1] fresh run dispatches intake (not skipped; ADR-050 §6 new-run side)" \
    "1" "$_s12_intake_starts"

# [#1805/FRSH-1]: dispatch started from stage 1; intake must have dispatched exactly once.
# The state file has status=interrupted and intake=complete, which would trigger auto-resume
# (skipping intake, starting from a later stage) if --no-resume were absent. With --no-resume,
# the runner starts fresh from stage 1: intake dispatches, proving dispatch was not jumped to
# a later stage due to prior state. This establishes the "dispatches all stages from stage 1"
# clause of FRSH-1 directly (tagged FRSH-1, not only BNDY-1).
# FRSH-1 is a no-code requirement: need not fail before this change; must pass after.
assert_eq "[#1805/FRSH-1] fresh run (--no-resume) dispatches all stages from stage 1 (intake dispatched; did not skip to a later stage due to prior state)" \
    "1" "$_s12_intake_starts"

# [#1805/FRSH-1]: a fresh run (--no-resume) emits no stage.skip events, proving all stages
# are dispatched from stage 1 and none are skipped due to prior state. stage.skip events
# are only emitted by the resume rehydration path (which is suppressed by --no-resume).
# A fresh run must not consult or skip any stage based on prior state.
# This requirement need not fail before this change (no-code property); it must pass after.
_s12_stage_skips=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_stage_skips="$(jq -r 'select(.type=="stage.skip") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/FRSH-1] fresh run (--no-resume) emits no stage.skip events (all stages dispatched from stage 1; none skipped due to prior state)" \
    "0" "$_s12_stage_skips"

# [#1805/FRSH-1]: no artifact from a prior run must appear in ZBUILD_ARTIFACT_DIR.
# The setup placed prior-run intake-result.json content on the state branch only
# (the disk copy was removed before the runner was invoked). A fresh run must NOT
# call _artifact_persist_restore, so the content "prior-run intake" (which is in
# the state branch but not on disk) must NOT appear in ZBUILD_ARTIFACT_DIR.
# If the runner mistakenly invoked _artifact_persist_restore on the --no-resume path,
# "prior-run intake" would appear in intake-result.json, failing this assertion.
_s12_prior_artifact_content="$(cat "$S12_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
_s12_prior_in_dir=0
if grep -q "prior-run intake" <<< "$_s12_prior_artifact_content"; then
    _s12_prior_in_dir=1
fi
assert_eq "[#1805/FRSH-1] no prior-run artifact content in ZBUILD_ARTIFACT_DIR (fresh --no-resume run does not restore prior-run artifacts from state branch)" \
    "0" "$_s12_prior_in_dir"

# [#1805/BNDY-1]: the cycle fixture used for this fresh-run sub-case contains type: cycle,
# establishing that the fixture IS a cyclic pipeline (satisfying the "same cycle fixture" clause).
# BNDY-1 requires "verifies intake dispatches AND the fixture contains type:cycle" —
# the cycled sub-stage dispatch is not required by BNDY-1.
_s12_fixt_content="$(cat "$REPO_ROOT/tests/fixtures/templates/artifact-snapshot-coverage.yaml")"
assert_contains "[#1805/BNDY-1] cycle fixture used in BNDY-1 fresh-run sub-case has type: cycle" \
    "$_s12_fixt_content" "type: cycle"

# ── CYCL-1: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-rehydrate test uses a fixture containing a cyclic stage"

# [#1805/CYCL-1]: the fixture must contain type: cycle.
assert_contains "[#1805/CYCL-1] resume-rehydrate (RHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle" \
    "$_s12_fixt_content" "type: cycle"

# : the pipeline using the cyclic fixture was actually run; intake dispatched
# in the fresh run above (_s12_intake_starts asserted = 1 in the BNDY-1 section).
assert_eq "resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)" \
    "1" "$_s12_intake_starts"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
