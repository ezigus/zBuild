#!/usr/bin/env bash
# Tests: a resume rehydrates completed-stage artifacts on the auto-resume and
# `zbuild pipeline resume --run-id` paths, and dispatches the interrupted leaf
# stage with stage.start. (issue #1805, ADR-006 §3.6)
#
# DSRHYD-1 [code] paths 2 and 3; DSDSPK-1 [code]: the interrupted leaf stage k
#   emits stage.start on resume.
# Split from resume-rehydrate-test.sh.
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

print_test_header "resume-rehydrate-paths — rehydrate on every resume path (#1805)"
setup_test_env "resume-rehydrate-paths-1805"
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

# ── DSDSPK-1 leaf-stage branch: leaf stage k emits stage.start on resume ─────
# [#1805/DSDSPK-1] Then (leaf-stage branch): when k is a leaf stage, a stage.start
# event is emitted for k. The cycle-stage sub-case above exercises the cycle.start +
# member-stage.start branch. This sub-case uses resume-minimal (intake → build → test,
# all leaf stages) with intake=complete and build=pending, so k=build is a leaf stage.
print_test_section "[#1805/DSDSPK-1] leaf stage k (build) emits stage.start on resume (leaf-stage branch)"

# Given — a run with stages intake (k-1, complete) and build (k, leaf stage,
#   interrupted, pending); stages 1…k-1 are marked complete with their artifacts
#   present in ZBUILD_ARTIFACT_DIR after rehydration.
_DSPK_LEAF_ID="$(zb_test_issue)"
_DSPK_LEAF_STATE_DIR="$TEST_TEMP_DIR/dspk-leaf-state"
_DSPK_LEAF_EVENTS_DIR="$TEST_TEMP_DIR/dspk-leaf-events"
_DSPK_LEAF_EVENTS_JSONL="$_DSPK_LEAF_EVENTS_DIR/events.jsonl"
_DSPK_LEAF_STATE_FILE="$_DSPK_LEAF_STATE_DIR/pipeline-state.json"
mkdir -p "$_DSPK_LEAF_STATE_DIR/artifacts" "$_DSPK_LEAF_EVENTS_DIR"

_DSPK_LEAF_WORK_REPO="$(setup_git_temp_repo dspk-leaf-work)"
# resume-minimal: intake → build → test; linear, no cycles; stages have no roles.
install_template_overlay "$_DSPK_LEAF_WORK_REPO" resume-minimal

# Create mock plugins for build and test (resolved by stage ID; no roles declared).
# intake plugin already created at top of file; build and test need new entries.
mock_plugin_factory "build" "agent" 0 >/dev/null
mock_plugin_factory "test" "agent" 0 >/dev/null

# Write intake artifact and snapshot to the state branch to simulate a run
# that completed intake (k-1) before being interrupted at build (k).
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$_DSPK_LEAF_STATE_DIR/artifacts/intake-result.json"

_dspk_leaf_snap_rc=0
( export ZBUILD_STATE_DIR="$_DSPK_LEAF_STATE_DIR"
  cd "$_DSPK_LEAF_WORK_REPO" && _artifact_persist_snapshot "$_DSPK_LEAF_STATE_DIR" "$_DSPK_LEAF_ID" ) \
    >"$TEST_TEMP_DIR/dspk-leaf-snap.log" 2>&1 || _dspk_leaf_snap_rc=$?
if [[ "$_dspk_leaf_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSDSPK-1] setup (leaf): snapshot to state branch failed" \
        "rc=$_dspk_leaf_snap_rc; $(cat "$TEST_TEMP_DIR/dspk-leaf-snap.log" 2>/dev/null | tail -5)"
fi
rm -f "$_DSPK_LEAF_STATE_DIR/artifacts/intake-result.json"

# State: intake=complete (k-1), build=pending (k = interrupted leaf stage).
jq -n \
    --arg run_id "dspk-leaf-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_DSPK_LEAF_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {intake: "complete", build: "pending"},
        current_iteration: 0, self_heal_count: {}, scope_manifest_hash: "",
        cost_ledger_pointer: 0, claim_lease_id: "", plugin_state: {},
        status: "in_progress", updated_at: $now
    }' > "$_DSPK_LEAF_STATE_FILE"

# When — the dispatch loop reaches stage build (k, leaf) during resume (--resume flag).
set +e
( cd "$_DSPK_LEAF_WORK_REPO" && env \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$_DSPK_LEAF_STATE_DIR" \
    ZBUILD_STATE_FILE="$_DSPK_LEAF_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$_DSPK_LEAF_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$_DSPK_LEAF_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template resume-minimal --resume --issue "$_DSPK_LEAF_ID" ) \
    >"$TEST_TEMP_DIR/dspk-leaf-stdout.txt" 2>"$TEST_TEMP_DIR/dspk-leaf-stderr.txt"
set -e

# Then — when k is a leaf stage, a stage.start event is emitted for k (build).
# Before the change: runner has no rehydration + dispatch-skip logic → it may exit
#   before dispatching build, OR it dispatches intake again instead of skipping it.
#   Either way, build emits no stage.start because the skip-and-dispatch path is absent
#   → _dspk_leaf_build_starts=0 → assert 0 > 0 → FAILS.
# After the change: rehydrate places intake artifact → dispatch loop skips intake
#   (resume_mode + artifact present) → dispatches build (leaf stage k) →
#   stage.start emitted for build → count >= 1 → PASSES.
_dspk_leaf_build_starts=0
if [[ -f "$_DSPK_LEAF_EVENTS_JSONL" ]]; then
    _dspk_leaf_build_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="build") | .type' \
        "$_DSPK_LEAF_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSDSPK-1] leaf stage k (build) is dispatched and emits stage.start on resume (leaf-stage branch: when k is a leaf stage, a stage.start event is emitted for k)" \
    "$_dspk_leaf_build_starts" "0"

# [#1805/DSDSPK-1]: complete stage intake (k-1) must NOT emit stage.start on resume.
# This confirms skip-then-dispatch: k-1 rehydrated+skipped, k dispatched.
_dspk_leaf_intake_starts=0
if [[ -f "$_DSPK_LEAF_EVENTS_JSONL" ]]; then
    _dspk_leaf_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$_DSPK_LEAF_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSDSPK-1] complete stage intake (k-1) emits no stage.start on resume (skipped by rehydration; only k dispatched)" \
    "0" "$_dspk_leaf_intake_starts"

# ── SPEC-1 path 2: auto-resume on status=interrupted ─────────────────────────
# [#1805/DSRHYD-1] all entry paths: path 2 — auto-resume when status=interrupted.
# No --resume flag; runner detects interrupted status and auto-resumes.
print_test_section "[#1805/DSRHYD-1] path 2: auto-resume (status=interrupted) restores artifacts"

# Given — a run has been interrupted (status=interrupted); stage intake is marked
#   complete with its artifact present in the git state branch; stage cyc was the
#   interrupted stage.
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

# When — the run is resumed via the auto-resume entry path (no --resume flag;
#   runner detects status=interrupted and auto-resumes).
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

# Then — the completed stage's artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical
#   to their state at the time of interruption; no stage.start event emitted for intake.
# [#1805/DSRHYD-1] path 2 artifact restored.
# Before change: no rehydration → absent → FAILS. After change: PASSES.
assert_file_exists \
    "[#1805/DSRHYD-1] path 2 (auto-resume/interrupted): intake-result.json restored" \
    "$S1P2_STATE_DIR/artifacts/intake-result.json"

# [#1805/DSRHYD-1] path 2: content must be byte-identical to what was snapshotted to the git
# state branch. Proves the artifact was placed into ZBUILD_ARTIFACT_DIR FROM the git state
# branch via _artifact_persist_restore (reads from git state branch) +
# _artifact_persist_put_back (copies to ZBUILD_ARTIFACT_DIR). These are the only functions
# that together produce this effect.
# Before fix: file absent → content="" → not equal → FAILS. After fix: PASSES.
_s1p2_artifact_content="$(cat "$S1P2_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_eq \
    "[#1805/DSRHYD-1] path 2 (auto-resume): artifact content is byte-identical to its state at interruption (via _artifact_persist_restore + _artifact_persist_put_back from git state branch)" \
    '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' "$_s1p2_artifact_content"

# [#1805/DSRHYD-1] path 2: at least one stage must have dispatched (proving pipeline ran and events written).
# Before fix: path-2 auto-resume doesn't exist → runner exits without events → 0 stage.start → FAILS.
# After fix: runner auto-resumes, rehydrates, skips intake, dispatches cyc cycle → cycled dispatches.
_s1p2_any_starts=0
if [[ -f "$S1P2_EVENTS_JSONL" ]]; then
    _s1p2_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S1P2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSRHYD-1] path 2 (auto-resume): at least one stage dispatched (pipeline ran via path-2 resume)" \
    "$_s1p2_any_starts" "0"

# [#1805/DSRHYD-1] path 2: pipeline.resume event must appear before the first stage.start,
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
assert_gt "[#1805/DSRHYD-1] path 2 (auto-resume): pipeline.resume event emitted" \
    "$_s1p2_resume_lineno" "0"
assert_gt "[#1805/DSRHYD-1] path 2 (auto-resume): pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1p2_first_start_lineno" "$_s1p2_resume_lineno"

# [#1805/DSRHYD-1] path 2: intake must NOT have a stage.start event.
_s1p2_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$S1P2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1805/DSRHYD-1] path 2 (auto-resume): intake emits no stage.start (skipped)" \
    "0" "$_s1p2_intake_starts"

# ── SPEC-1 path 3: zbuild pipeline resume --run-id ───────────────────────────
# [#1805/DSRHYD-1] all entry paths: path 3 — zbuild pipeline resume --run-id.
print_test_section "[#1805/DSRHYD-1] path 3: zbuild pipeline resume --run-id restores artifacts"

# Given — a run has been interrupted (status=interrupted); stage intake is marked
#   complete with its artifact present in the git state branch; run state persisted
#   with a known run_id; stage cyc was the interrupted stage.
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

# When — the run is resumed via the zbuild pipeline resume --run-id entry path.
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

# Then — the completed stage's artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical
#   to their state at the time of interruption; no stage.start event emitted for intake.
# [#1805/DSRHYD-1] path 3 artifact restored.
# Before change: zbuild resume path has no rehydration → absent → FAILS. After change: PASSES.
assert_file_exists \
    "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): intake-result.json restored" \
    "$S1P3_STATE_DIR/artifacts/intake-result.json"

# [#1805/DSRHYD-1] path 3: content must be byte-identical to what was snapshotted to the git
# state branch. Proves the artifact was placed into ZBUILD_ARTIFACT_DIR FROM the git state
# branch via _artifact_persist_restore (reads from git state branch) +
# _artifact_persist_put_back (copies to ZBUILD_ARTIFACT_DIR). These are the only functions
# that together produce this effect.
# Before fix: file absent → content="" → not equal → FAILS. After fix: PASSES.
_s1p3_artifact_content="$(cat "$S1P3_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_eq \
    "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): artifact content is byte-identical to its state at interruption (via _artifact_persist_restore + _artifact_persist_put_back from git state branch)" \
    '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' "$_s1p3_artifact_content"

# [#1805/DSRHYD-1] path 3: at least one stage must have dispatched (proving pipeline ran via zbuild pipeline resume).
# Before fix: zbuild pipeline resume path has no rehydration / may not exist → no events → FAILS.
# After fix: zbuild calls runner --resume → rehydrates → dispatches cyc cycle → cycled dispatches.
_s1p3_any_starts=0
if [[ -f "$S1P3_EVENTS_JSONL" ]]; then
    _s1p3_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S1P3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): at least one stage dispatched (pipeline ran via path-3)" \
    "$_s1p3_any_starts" "0"

# [#1805/DSRHYD-1] path 3: pipeline.resume event must appear before the first stage.start,
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
assert_gt "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): pipeline.resume event emitted" \
    "$_s1p3_resume_lineno" "0"
assert_gt "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): pipeline.resume precedes first stage.start (restore before dispatch loop)" \
    "$_s1p3_first_start_lineno" "$_s1p3_resume_lineno"

# [#1805/DSRHYD-1] path 3: intake must NOT have a stage.start event.
_s1p3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$S1P3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1805/DSRHYD-1] path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)" \
    "0" "$_s1p3_intake_starts"

print_test_results
cleanup_test_env
