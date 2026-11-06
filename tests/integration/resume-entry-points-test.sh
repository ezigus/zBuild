#!/usr/bin/env bash
# Tests: all three resume entry paths invoke _runner_resume_rehydrate before
# the dispatch loop. (issue #1805, ADR-006 §3.5)
#
# ENTR-1 [code]: All three resume entry paths (--resume flag to runner.sh,
#   auto-resume on detecting status=interrupted, zbuild pipeline resume
#   --run-id) invoke _runner_resume_rehydrate before the dispatch loop.
#   Its test must FAIL on the code as it was before this change.
#
# Three sub-tests, each with a separate work repo, state dir, and events dir:
#   Path 1 — bash runner.sh --resume
#   Path 2 — bash runner.sh (no --resume; state status=interrupted → auto_resume)
#   Path 3 — bash zbuild pipeline resume --run-id
#
# Discriminating assertion for all paths: intake-result.json is present in
# ZBUILD_ARTIFACT_DIR after the runner call (artifact restored from state branch).
# Before this change: no rehydration → artifact absent → FAILS.
# After this change: _runner_resume_rehydrate restores it → PASSES.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "resume-entry-points — all resume paths rehydrate artifacts (#1805)"
setup_test_env "resume-entry-points-1805"
export ZBUILD_CONTRACT_VALIDATOR=warn

# Common mock plugins for all three paths.
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
# cycled sub-stage used by the artifact-snapshot-coverage cyclic fixture (SPEC-13 sub-case).
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── Shared helper: set up a work repo with a state branch for one path ──────────
# Usage: _setup_path_state <label> <issue_id> → sets:
#   P_WORK_REPO, P_STATE_DIR, P_STATE_FILE, P_EVENTS_DIR, P_EVENTS_JSONL
_setup_path_state() {
    local label="$1" issue_id="$2"

    P_WORK_REPO="$(setup_git_temp_repo "ep-${label}")"
    install_template_overlay "$P_WORK_REPO" artifact-snapshot-coverage

    P_STATE_DIR="$TEST_TEMP_DIR/${label}-state"
    P_EVENTS_DIR="$TEST_TEMP_DIR/${label}-events"
    P_STATE_FILE="$P_STATE_DIR/pipeline-state.json"
    P_EVENTS_JSONL="$P_EVENTS_DIR/events.jsonl"
    mkdir -p "$P_STATE_DIR/artifacts" "$P_EVENTS_DIR"

    # Write the intake artifact so the snapshot captures it.
    printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
        > "$P_STATE_DIR/artifacts/intake-result.json"

    # Snapshot onto the state branch.
    local _snap_rc=0
    ( export ZBUILD_STATE_DIR="$P_STATE_DIR"
      cd "$P_WORK_REPO" && _artifact_persist_snapshot "$P_STATE_DIR" "$issue_id" ) \
        >"$TEST_TEMP_DIR/${label}-snap.log" 2>&1 || _snap_rc=$?
    if [[ "$_snap_rc" -ne 0 ]]; then
        assert_fail "setup-${label}: snapshot to state branch failed" \
            "rc=$_snap_rc; $(cat "$TEST_TEMP_DIR/${label}-snap.log" 2>/dev/null | tail -5)"
    fi

    # Remove artifact from disk; it now lives only on the state branch.
    rm -f "$P_STATE_DIR/artifacts/intake-result.json"
}

# ── PATH 1: --resume flag to runner.sh ────────────────────────────────────────
print_test_section "[#1805/ENTR-1] path 1: bash runner.sh --resume restores artifacts"

# Given — a run has been interrupted; stage intake is marked complete with its artifact
#   present in the git state branch; run state is persisted in the state dir.
P1_ID="$(zb_test_issue)"
_setup_path_state "p1" "$P1_ID"
P1_WORK_REPO="$P_WORK_REPO"
P1_STATE_DIR="$P_STATE_DIR"
P1_STATE_FILE="$P_STATE_FILE"
P1_EVENTS_DIR="$P_EVENTS_DIR"
P1_EVENTS_JSONL="$P_EVENTS_JSONL"

jq -n \
    --arg run_id "s9-p1-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$P1_ID" \
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
    }' > "$P1_STATE_FILE"

# When — the run is resumed via the --resume flag entry path.
set +e
( cd "$P1_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$P1_STATE_DIR" \
    ZBUILD_STATE_FILE="$P1_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$P1_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P1_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --resume --issue "$P1_ID" ) \
    >"$TEST_TEMP_DIR/p1-stdout.txt" 2>"$TEST_TEMP_DIR/p1-stderr.txt"
set -e

# Then — completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR before any stage.start event.
# [#1805/ENTR-1] path 1: artifact restored.
# Before change: no rehydration → file absent → FAILS.
# After change: _runner_resume_rehydrate restores it → PASSES.
assert_file_exists \
    "[#1805/ENTR-1] path 1 (--resume flag): intake-result.json restored from state branch" \
    "$P1_STATE_DIR/artifacts/intake-result.json"

# [#1805/ENTR-1] path 1: pipeline.resume event must be emitted BEFORE the first
# stage.start. The runner emits pipeline.resume immediately after
# _runner_resume_rehydrate returns, before entering the dispatch loop. A
# pipeline.resume line number lower than the first stage.start line number
# proves the rehydration call completed before any stage was dispatched.
# Before change: no _runner_resume_rehydrate → no pipeline.resume event →
#   resume_lineno=0 → assert 0 > 0 → FAILS.
# After change: _runner_resume_rehydrate called → pipeline.resume emitted before
#   dispatch loop → resume_lineno > 0 and < first_start_lineno → PASSES.
_p1_resume_lineno=0
_p1_first_start_lineno=0
if [[ -f "$P1_EVENTS_JSONL" ]]; then
    _p1_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$P1_EVENTS_JSONL" 2>/dev/null)"
    _p1_resume_lineno="${_p1_resume_lineno:-0}"
    _p1_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$P1_EVENTS_JSONL" 2>/dev/null)"
    _p1_first_start_lineno="${_p1_first_start_lineno:-0}"
fi
assert_gt "[#1805/ENTR-1] path 1 (--resume flag): pipeline.resume event emitted (rehydration ran before dispatch)" \
    "$_p1_resume_lineno" "0"
assert_gt "[#1805/ENTR-1] path 1 (--resume flag): pipeline.resume precedes first stage.start (rehydration before dispatch loop)" \
    "$_p1_first_start_lineno" "$_p1_resume_lineno"

# [#1805/ENTR-1] path 1: no stage.start event must be emitted for intake (a stage marked
# complete in the interrupted run's state). The runner skips complete stages on resume;
# only the interrupted stage (build) may emit stage.start.
# Before change: resume doesn't skip complete stages → intake dispatched → intake_starts=1 →
#   assert 0==1 → FAILS.
# After change: _runner_resume_rehydrate marks intake complete/rehydrated → dispatch loop
#   skips it → intake_starts=0 → PASSES.
_p1_intake_starts=0
if [[ -f "$P1_EVENTS_JSONL" ]]; then
    _p1_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$P1_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/ENTR-1] path 1 (--resume flag): no stage.start for intake (complete stage skipped before dispatch loop)" \
    "0" "$_p1_intake_starts"

# ── PATH 2: auto-resume on detecting status=interrupted ───────────────────────
print_test_section "[#1805/ENTR-1] path 2: auto-resume on status=interrupted restores artifacts"

# Given — a run has been interrupted (status=interrupted); stage intake is marked
#   complete with its artifact present in the git state branch.
P2_ID="$(zb_test_issue)"
_setup_path_state "p2" "$P2_ID"
P2_WORK_REPO="$P_WORK_REPO"
P2_STATE_DIR="$P_STATE_DIR"
P2_STATE_FILE="$P_STATE_FILE"
P2_EVENTS_DIR="$P_EVENTS_DIR"
P2_EVENTS_JSONL="$P_EVENTS_JSONL"

# status=interrupted → get_resume_recommendation → auto_resume → resume_mode=true.
jq -n \
    --arg run_id "s9-p2-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$P2_ID" \
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
        status: "interrupted",
        updated_at: $now
    }' > "$P2_STATE_FILE"

# When — the run is resumed via the auto-resume entry path (no --resume flag;
#   runner detects status=interrupted and auto-resumes).
set +e
( cd "$P2_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$P2_STATE_DIR" \
    ZBUILD_STATE_FILE="$P2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$P2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage ) \
    >"$TEST_TEMP_DIR/p2-stdout.txt" 2>"$TEST_TEMP_DIR/p2-stderr.txt"
set -e

# Then — completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR before any stage.start event.
# [#1805/ENTR-1] path 2: artifact restored via auto-resume.
# Before change: no rehydration → file absent → FAILS.
# After change: auto-resume path invokes _runner_resume_rehydrate → PASSES.
assert_file_exists \
    "[#1805/ENTR-1] path 2 (auto-resume/interrupted): intake-result.json restored from state branch" \
    "$P2_STATE_DIR/artifacts/intake-result.json"

# [#1805/ENTR-1] path 2: pipeline.resume event emitted before first stage.start,
# proving _runner_resume_rehydrate was called before the dispatch loop.
# Before change: no _runner_resume_rehydrate → pipeline.resume absent →
#   resume_lineno=0 → assert 0 > 0 → FAILS.
# After change: auto-resume path calls _runner_resume_rehydrate →
#   pipeline.resume emitted before dispatch loop → PASSES.
_p2_resume_lineno=0
_p2_first_start_lineno=0
if [[ -f "$P2_EVENTS_JSONL" ]]; then
    _p2_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$P2_EVENTS_JSONL" 2>/dev/null)"
    _p2_resume_lineno="${_p2_resume_lineno:-0}"
    _p2_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$P2_EVENTS_JSONL" 2>/dev/null)"
    _p2_first_start_lineno="${_p2_first_start_lineno:-0}"
fi
assert_gt "[#1805/ENTR-1] path 2 (auto-resume): pipeline.resume event emitted (rehydration ran before dispatch)" \
    "$_p2_resume_lineno" "0"
assert_gt "[#1805/ENTR-1] path 2 (auto-resume): pipeline.resume precedes first stage.start (rehydration before dispatch loop)" \
    "$_p2_first_start_lineno" "$_p2_resume_lineno"

# [#1805/ENTR-1] path 2: no stage.start event must be emitted for intake (a stage
# marked complete in the interrupted run's state). Complete stages are skipped on resume.
# Before change: resume doesn't skip complete stages → intake dispatched →
#   intake_starts=1 → assert 0==1 → FAILS.
# After change: dispatch loop skips intake → intake_starts=0 → PASSES.
_p2_intake_starts=0
if [[ -f "$P2_EVENTS_JSONL" ]]; then
    _p2_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$P2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/ENTR-1] path 2 (auto-resume): no stage.start for intake (complete stage skipped before dispatch loop)" \
    "0" "$_p2_intake_starts"

# ── PATH 3: zbuild pipeline resume --run-id ───────────────────────────────────
print_test_section "[#1805/ENTR-1] path 3: zbuild pipeline resume --run-id restores artifacts"

# Given — a run has been interrupted (status=interrupted); stage intake is marked
#   complete with its artifact present in the git state branch; run state persisted
#   with a known run_id.
P3_ID="$(zb_test_issue)"
_setup_path_state "p3" "$P3_ID"
P3_WORK_REPO="$P_WORK_REPO"
P3_STATE_DIR="$P_STATE_DIR"
P3_STATE_FILE="$P_STATE_FILE"
P3_EVENTS_DIR="$P_EVENTS_DIR"
P3_EVENTS_JSONL="$P_EVENTS_JSONL"
P3_RUN_ID="s9-p3-resume-1805"

# status=interrupted so zbuild doesn't refuse (aborted requires --force;
# interrupted is accepted). zbuild changes it to in_progress, then runner sees --resume.
jq -n \
    --arg run_id "$P3_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$P3_ID" \
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
        status: "interrupted",
        updated_at: $now
    }' > "$P3_STATE_FILE"

# When — the run is resumed via zbuild pipeline resume --run-id entry path.
# zbuild pipeline resume reads ZBUILD_STATE_DIR and finds the state file by run_id.
# It sets status=in_progress and calls runner with --resume.
# The runner's CWD must be P3_WORK_REPO so _artifact_persist_restore finds the branch.
set +e
( cd "$P3_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$P3_STATE_DIR" \
    ZBUILD_EVENTS_DIR="$P3_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P3_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$ZBUILD_CLI" pipeline resume \
        --run-id "$P3_RUN_ID" \
        --template artifact-snapshot-coverage ) \
    >"$TEST_TEMP_DIR/p3-stdout.txt" 2>"$TEST_TEMP_DIR/p3-stderr.txt"
set -e

# Then — completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR before any stage.start event.
# [#1805/ENTR-1] path 3: artifact restored via zbuild pipeline resume.
# Before change: no rehydration → file absent → FAILS.
# After change: zbuild pipeline resume → runner --resume → _runner_resume_rehydrate → PASSES.
assert_file_exists \
    "[#1805/ENTR-1] path 3 (zbuild pipeline resume): intake-result.json restored from state branch" \
    "$P3_STATE_DIR/artifacts/intake-result.json"

# [#1805/ENTR-1] path 3: pipeline.resume event emitted before first stage.start,
# proving zbuild pipeline resume invokes _runner_resume_rehydrate before the
# dispatch loop.
# Before change: no _runner_resume_rehydrate → pipeline.resume absent →
#   resume_lineno=0 → assert 0 > 0 → FAILS.
# After change: zbuild calls runner --resume → _runner_resume_rehydrate called →
#   pipeline.resume emitted before dispatch loop → PASSES.
_p3_resume_lineno=0
_p3_first_start_lineno=0
if [[ -f "$P3_EVENTS_JSONL" ]]; then
    _p3_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$P3_EVENTS_JSONL" 2>/dev/null)"
    _p3_resume_lineno="${_p3_resume_lineno:-0}"
    _p3_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$P3_EVENTS_JSONL" 2>/dev/null)"
    _p3_first_start_lineno="${_p3_first_start_lineno:-0}"
fi
assert_gt "[#1805/ENTR-1] path 3 (zbuild pipeline resume): pipeline.resume event emitted (rehydration ran before dispatch)" \
    "$_p3_resume_lineno" "0"
assert_gt "[#1805/ENTR-1] path 3 (zbuild pipeline resume): pipeline.resume precedes first stage.start (rehydration before dispatch loop)" \
    "$_p3_first_start_lineno" "$_p3_resume_lineno"

# [#1805/ENTR-1] path 3: no stage.start event must be emitted for intake (a stage
# marked complete in the interrupted run's state). Complete stages are skipped on resume.
# Before change: resume doesn't skip complete stages → intake dispatched →
#   intake_starts=1 → assert 0==1 → FAILS.
# After change: dispatch loop skips intake → intake_starts=0 → PASSES.
_p3_intake_starts=0
if [[ -f "$P3_EVENTS_JSONL" ]]; then
    _p3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$P3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/ENTR-1] path 3 (zbuild pipeline resume): no stage.start for intake (complete stage skipped before dispatch loop)" \
    "0" "$_p3_intake_starts"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-entry-points test uses a fixture containing a cyclic stage"

# Run a fresh pipeline against the cyclic fixture (artifact-snapshot-coverage) to
# demonstrate that this test file exercises a pipeline containing a cyclic stage.
_S13_EP_ID="$(zb_test_issue)"
_S13_EP_WORK="$(setup_git_temp_repo ep-s13-cycle-check)"
install_template_overlay "$_S13_EP_WORK" artifact-snapshot-coverage

_S13_EP_STATE_DIR="$TEST_TEMP_DIR/s13ep-state"
_S13_EP_EVENTS_DIR="$TEST_TEMP_DIR/s13ep-events"
_S13_EP_EVENTS_JSONL="$_S13_EP_EVENTS_DIR/events.jsonl"
_S13_EP_STATE_FILE="$_S13_EP_STATE_DIR/pipeline-state.json"
mkdir -p "$_S13_EP_STATE_DIR/artifacts" "$_S13_EP_EVENTS_DIR"

jq -n \
    --arg run_id "s13ep-fresh-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S13_EP_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {}, current_iteration: 0, self_heal_count: {},
        scope_manifest_hash: "", cost_ledger_pointer: 0, claim_lease_id: "",
        plugin_state: {}, status: "in_progress", updated_at: $now
    }' > "$_S13_EP_STATE_FILE"

set +e
( cd "$_S13_EP_WORK" && env \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$_S13_EP_STATE_DIR" \
    ZBUILD_STATE_FILE="$_S13_EP_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$_S13_EP_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$_S13_EP_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    ZBUILD_CYCLES_ENABLED=1 \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --issue "$_S13_EP_ID" ) \
    >"$TEST_TEMP_DIR/s13ep-stdout.txt" 2>"$TEST_TEMP_DIR/s13ep-stderr.txt"
set -e

# : the fixture is cyclic (type: cycle present).
_s13_ep_content="$(cat "$REPO_ROOT/tests/fixtures/templates/artifact-snapshot-coverage.yaml")"
assert_contains "resume-entry-points test uses a cyclic fixture (type: cycle)" \
    "$_s13_ep_content" "type: cycle"

# : confirm the cyclic pipeline ran (intake dispatched in the fresh run).
_s13_ep_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$_S13_EP_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "cyclic fixture pipeline ran in resume-entry-points test (intake dispatched)" \
    "1" "$_s13_ep_intake_starts"

# intake dispatching into a cycle-fixture pipeline is sufficient evidence the pipeline
# executed (not just a non-cyclic path). The cycled sub-stage dispatch depends on the
# cycle-orchestrator implementation and is not required by SPEC-9 (artifact restoration).

# ── PATH 4 (ENTR-2): auto-resume via `latest` symlink, no ZBUILD_STATE_FILE ───
print_test_section "[#1805/ENTR-2] auto-resume via latest symlink (no ZBUILD_STATE_FILE set)"

# Given — a previous run stored state at $ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json
#   with status=interrupted; $ZBUILD_STATE_ROOT/latest symlinks to that per-run dir;
#   ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset.
P4_ID="$(zb_test_issue)"
P4_RUN_ID="e2-p4-resume-1805"
P4_WORK_REPO="$(setup_git_temp_repo "ep-p4")"
install_template_overlay "$P4_WORK_REPO" artifact-snapshot-coverage

P4_STATE_ROOT="$TEST_TEMP_DIR/p4-state-root"
P4_RUN_DIR="$P4_STATE_ROOT/runs/$P4_RUN_ID"
P4_EVENTS_DIR="$TEST_TEMP_DIR/p4-events"
P4_EVENTS_JSONL="$P4_EVENTS_DIR/events.jsonl"
mkdir -p "$P4_RUN_DIR/artifacts" "$P4_EVENTS_DIR"

# Write the intake artifact and snapshot it to the git state branch.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake entr2"}' \
    > "$P4_RUN_DIR/artifacts/intake-result.json"

_p4_snap_rc=0
( export ZBUILD_STATE_DIR="$P4_RUN_DIR"
  cd "$P4_WORK_REPO" && _artifact_persist_snapshot "$P4_RUN_DIR" "$P4_ID" ) \
    >"$TEST_TEMP_DIR/p4-snap.log" 2>&1 || _p4_snap_rc=$?
if [[ "$_p4_snap_rc" -ne 0 ]]; then
    echo "setup-p4: snapshot to state branch failed (rc=$_p4_snap_rc):" >&2
    cat "$TEST_TEMP_DIR/p4-snap.log" >&2
fi

# Remove artifact from disk; it now lives only on the state branch.
rm -f "$P4_RUN_DIR/artifacts/intake-result.json"

# Create the latest symlink pointing to the per-run state dir.
ln -sfn "$P4_RUN_DIR" "$P4_STATE_ROOT/latest"

# Write state file at the per-run path with status=interrupted and intake=complete.
jq -n \
    --arg run_id "$P4_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$P4_ID" \
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
        status: "interrupted",
        updated_at: $now
    }' > "$P4_RUN_DIR/pipeline-state.json"

# When — runner invoked with ZBUILD_STATE_FILE and ZBUILD_STATE_DIR unset;
#   only ZBUILD_STATE_ROOT is set, pointing to the state root containing the
#   latest symlink. The runner must find state via $ZBUILD_STATE_ROOT/latest.
set +e
( cd "$P4_WORK_REPO" && env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_ROOT="$P4_STATE_ROOT" \
    ZBUILD_EVENTS_DIR="$P4_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P4_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage ) \
    >"$TEST_TEMP_DIR/p4-stdout.txt" 2>"$TEST_TEMP_DIR/p4-stderr.txt"
set -e

# Then
# [#1805/ENTR-2]: pipeline.resume event emitted (auto-resume fired via latest symlink).
# Before change: state_file=$ZBUILD_STATE_ROOT/pipeline-state.json doesn't exist
#   (state only at runs/<run_id>/) → [[ -f "$state_file" ]] is false → auto-resume
#   block not entered → pipeline.resume not emitted → resume_lineno=0 →
#   assert_gt 0 > 0 → FAILS.
# After change: runner follows latest symlink → finds pipeline-state.json with
#   status=interrupted → auto-resumes → pipeline.resume emitted → PASSES.
_p4_resume_lineno=0
if [[ -f "$P4_EVENTS_JSONL" ]]; then
    _p4_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$P4_EVENTS_JSONL" 2>/dev/null)"
    _p4_resume_lineno="${_p4_resume_lineno:-0}"
fi
assert_gt "[#1805/ENTR-2] auto-resume via latest symlink: pipeline.resume event emitted (resume_mode=true)" \
    "$_p4_resume_lineno" "0"

# [#1805/ENTR-2]: completed-stage artifacts restored from the per-run state directory
#   before any stage.start event is emitted.
# Before change: auto-resume not triggered → no rehydration call → artifact absent → FAILS.
# After change: auto-resume via latest → _runner_resume_rehydrate → artifact restored → PASSES.
assert_file_exists \
    "[#1805/ENTR-2] auto-resume via latest symlink: intake-result.json restored from per-run state dir" \
    "$P4_RUN_DIR/artifacts/intake-result.json"

# [#1805/ENTR-2]: no stage.start event for intake (a stage marked complete in the
#   per-run state file). The dispatch loop must skip it.
# Before change: no resume_mode → intake dispatched normally → intake_starts=1 → FAILS.
# After change: resume_mode → dispatch loop skips intake → intake_starts=0 → PASSES.
_p4_intake_starts=0
if [[ -f "$P4_EVENTS_JSONL" ]]; then
    _p4_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$P4_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/ENTR-2] auto-resume via latest symlink: no stage.start for intake (complete stage skipped)" \
    "0" "$_p4_intake_starts"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
