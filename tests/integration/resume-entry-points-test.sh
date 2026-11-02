#!/usr/bin/env bash
# Tests: all three resume entry paths invoke _runner_resume_rehydrate before
# the dispatch loop. (issue #1805, ADR-006 §3.5)
#
# SPEC-9 [code]: All three resume entry paths (--resume flag to runner.sh,
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
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── Shared helper: set up a work repo with a state branch for one path ──────────
# Usage: _setup_path_state <label> <issue_id> → sets:
#   P_WORK_REPO, P_STATE_DIR, P_STATE_FILE, P_EVENTS_DIR, P_EVENTS_JSONL
_setup_path_state() {
    local label="$1" issue_id="$2"

    P_WORK_REPO="$(setup_git_temp_repo "ep-${label}")"
    install_template_overlay "$P_WORK_REPO" runner-state-dir-minimal

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
print_test_section "[#1805/SPEC-9] path 1: bash runner.sh --resume restores artifacts"

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
        stage_statuses: {intake: "complete", build: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "in_progress",
        updated_at: $now
    }' > "$P1_STATE_FILE"

set +e
( cd "$P1_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$P1_STATE_DIR" \
    ZBUILD_STATE_FILE="$P1_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$P1_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P1_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template runner-state-dir-minimal \
        --resume --issue "$P1_ID" ) \
    >"$TEST_TEMP_DIR/p1-stdout.txt" 2>"$TEST_TEMP_DIR/p1-stderr.txt"
set -e

# [#1805/SPEC-9] path 1 assertion: artifact restored.
# Before change: no rehydration → file absent → FAILS.
# After change: _runner_resume_rehydrate restores it → PASSES.
assert_file_exists \
    "[#1805/SPEC-9] path 1 (--resume flag): intake-result.json restored from state branch" \
    "$P1_STATE_DIR/artifacts/intake-result.json"

# ── PATH 2: auto-resume on detecting status=interrupted ───────────────────────
print_test_section "[#1805/SPEC-9] path 2: auto-resume on status=interrupted restores artifacts"

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
        stage_statuses: {intake: "complete", build: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "interrupted",
        updated_at: $now
    }' > "$P2_STATE_FILE"

# No --resume flag: runner detects status=interrupted and auto-resumes.
set +e
( cd "$P2_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$P2_STATE_DIR" \
    ZBUILD_STATE_FILE="$P2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$P2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$P2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template runner-state-dir-minimal ) \
    >"$TEST_TEMP_DIR/p2-stdout.txt" 2>"$TEST_TEMP_DIR/p2-stderr.txt"
set -e

# [#1805/SPEC-9] path 2 assertion: artifact restored via auto-resume.
# Before change: no rehydration → file absent → FAILS.
# After change: auto-resume path invokes _runner_resume_rehydrate → PASSES.
assert_file_exists \
    "[#1805/SPEC-9] path 2 (auto-resume/interrupted): intake-result.json restored from state branch" \
    "$P2_STATE_DIR/artifacts/intake-result.json"

# ── PATH 3: zbuild pipeline resume --run-id ───────────────────────────────────
print_test_section "[#1805/SPEC-9] path 3: zbuild pipeline resume --run-id restores artifacts"

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
        stage_statuses: {intake: "complete", build: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "interrupted",
        updated_at: $now
    }' > "$P3_STATE_FILE"

# zbuild pipeline resume reads ZBUILD_STATE_DIR and finds the state file by run_id.
# It sets status=in_progress and calls runner with --resume.
# The runner's CWD must be P3_WORK_REPO so _artifact_persist_restore finds the branch.
set +e
( cd "$P3_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=0 \
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
        --template runner-state-dir-minimal ) \
    >"$TEST_TEMP_DIR/p3-stdout.txt" 2>"$TEST_TEMP_DIR/p3-stderr.txt"
set -e

# [#1805/SPEC-9] path 3 assertion: artifact restored via zbuild pipeline resume.
# Before change: no rehydration → file absent → FAILS.
# After change: zbuild pipeline resume → runner --resume → _runner_resume_rehydrate → PASSES.
assert_file_exists \
    "[#1805/SPEC-9] path 3 (zbuild pipeline resume): intake-result.json restored from state branch" \
    "$P3_STATE_DIR/artifacts/intake-result.json"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "[#1805/SPEC-13] resume-entry-points test uses a fixture containing a cyclic stage"

# Install a cyclic fixture into a dedicated work repo to establish that this test
# file's setup installs a pipeline containing a cyclic stage (SPEC-13 requirement).
_S13_EP_WORK="$(setup_git_temp_repo ep-s13-cycle-check)"
install_template_overlay "$_S13_EP_WORK" artifact-snapshot-coverage
_s13_ep_content="$(cat "$REPO_ROOT/tests/fixtures/templates/artifact-snapshot-coverage.yaml")"
assert_contains "[#1805/SPEC-13] resume-entry-points test installs a fixture with type: cycle" \
    "$_s13_ep_content" "type: cycle"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
