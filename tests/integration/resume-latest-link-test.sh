#!/usr/bin/env bash
# Tests: auto-resume with no ZBUILD_STATE_FILE finds the interrupted run's
# per-run state through the state root's `latest` link (issue #1805, ADR-006,
# ADR-059 §1), with the state root reached through a symlink.
#
# DSENTR-2 [code]: the runner follows $ZBUILD_STATE_ROOT/latest, auto-resumes
#   the interrupted run, and restores its artifacts before the dispatch loop.
# Split from resume-entry-points-test.sh, which covers the three named paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "resume-latest-link — auto-resume finds the run through the latest link (#1805)"
setup_test_env "resume-latest-link-1805"
export ZBUILD_CONTRACT_VALIDATOR=warn

# Common mock plugins for all three paths.
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
# cycled sub-stage used by the artifact-snapshot-coverage cyclic fixture (SPEC-13 sub-case).
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── Shared helper: set up a work repo with a state branch for one path ──────────
# Usage: _setup_path_state <label> <issue_id> <run_id> → sets:
#   P_WORK_REPO, P_STATE_DIR, P_STATE_FILE, P_EVENTS_DIR, P_EVENTS_JSONL
#   State is at <TEST_TEMP_DIR>/<label>-state-root/runs/<run_id>/ (per DSENTR-1 Given).
_setup_path_state() {
    local label="$1" issue_id="$2" run_id="$3"

    P_WORK_REPO="$(setup_git_temp_repo "ep-${label}")"
    install_template_overlay "$P_WORK_REPO" artifact-snapshot-coverage

    # State layout: per-run path <state-root>/runs/<run_id>/ (DSENTR-1 Given:
    # "state is persisted in runs/<run_id>/").
    local _P_STATE_ROOT="$TEST_TEMP_DIR/${label}-state-root"
    P_STATE_DIR="$_P_STATE_ROOT/runs/$run_id"
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

# ── PATH 4 (DSENTR-2): auto-resume via `latest` symlink, no ZBUILD_STATE_FILE ───
print_test_section "[#1805/DSENTR-2] auto-resume via latest symlink (no ZBUILD_STATE_FILE set)"

# Given — a previous run stored state at $ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json
#   with status=interrupted; $ZBUILD_STATE_ROOT/latest symlinks to that per-run dir;
#   ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset.
P4_ID="$(zb_test_issue)"
P4_RUN_ID="e2-p4-resume-1805"
P4_WORK_REPO="$(setup_git_temp_repo "ep-p4")"
install_template_overlay "$P4_WORK_REPO" artifact-snapshot-coverage

# The state root is reached through a symlink, as on macOS (/var is a link to
# /private/var) or a linked home: the containment check must compare real paths.
mkdir -p "$TEST_TEMP_DIR/p4-state-root-real"
ln -sfn "$TEST_TEMP_DIR/p4-state-root-real" "$TEST_TEMP_DIR/p4-state-root"
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
# [#1805/DSENTR-2]: pipeline.resume event emitted (auto-resume fired via latest symlink).
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
assert_gt "[#1805/DSENTR-2] auto-resume via latest symlink: pipeline.resume event emitted (resume_mode=true)" \
    "$_p4_resume_lineno" "0"

# [#1805/DSENTR-2]: artifacts were restored BEFORE any stage.start event. The runner emits
#   pipeline.resume immediately after _runner_resume_rehydrate returns, before the dispatch
#   loop. A pipeline.resume line number lower than the first stage.start line number proves
#   the rehydration completed before any stage was dispatched.
# Before change: auto-resume not triggered → no pipeline.resume → resume_lineno=0 →
#   the assert_gt resume > 0 above already fails; this assertion adds explicit ordering
#   evidence that the artifact was placed BEFORE the dispatch loop.
# After change: auto-resume via latest → pipeline.resume emitted before dispatch →
#   first_start_lineno > resume_lineno → PASSES.
_p4_first_start_lineno=0
if [[ -f "$P4_EVENTS_JSONL" ]]; then
    _p4_first_start_lineno="$(awk '/"stage.start"/{print NR; exit}' "$P4_EVENTS_JSONL" 2>/dev/null)"
    _p4_first_start_lineno="${_p4_first_start_lineno:-0}"
fi
assert_gt "[#1805/DSENTR-2] auto-resume via latest symlink: pipeline.resume precedes first stage.start (artifact restored before dispatch loop)" \
    "$_p4_first_start_lineno" "$_p4_resume_lineno"

# [#1805/DSENTR-2]: completed-stage artifacts restored from the per-run state directory
#   before any stage.start event is emitted.
# Before change: auto-resume not triggered → no rehydration call → artifact absent → FAILS.
# After change: auto-resume via latest → _runner_resume_rehydrate → artifact restored → PASSES.
assert_file_exists \
    "[#1805/DSENTR-2] auto-resume via latest symlink: intake-result.json restored from per-run state dir" \
    "$P4_RUN_DIR/artifacts/intake-result.json"

# [#1805/DSENTR-2]: no stage.start event for intake (a stage marked complete in the
#   per-run state file). The dispatch loop must skip it.
# Before change: no resume_mode → intake dispatched normally → intake_starts=1 → FAILS.
# After change: resume_mode → dispatch loop skips intake → intake_starts=0 → PASSES.
_p4_intake_starts=0
if [[ -f "$P4_EVENTS_JSONL" ]]; then
    _p4_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$P4_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSENTR-2] auto-resume via latest symlink: no stage.start for intake (complete stage skipped)" \
    "0" "$_p4_intake_starts"

print_test_results
cleanup_test_env
