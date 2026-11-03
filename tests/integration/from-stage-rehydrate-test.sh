#!/usr/bin/env bash
# Tests: --from-stage <s> rehydrates completed-stage artifacts before dispatching <s>.
# (issue #1805, ADR-006 §3.5 / _runner_from_stage_preflight)
#
# SPEC-3 [code]: --from-stage <s> rehydrates all stages before <s> via
#   _artifact_persist_restore and _artifact_persist_put_back, places their
#   artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and
#   emits no stage.start for any earlier stage.
#
# SPEC-4 [code]: --from-stage <s> when a stage before <s> has no restorable
#   artifact exits 1 before dispatching anything and names the missing stage
#   in stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "from-stage-rehydrate — artifact restore on --from-stage (#1805)"
setup_test_env "from-stage-rehydrate-1805"
export ZBUILD_CONTRACT_VALIDATOR=warn

# ── SPEC-3: --from-stage rehydrates stages before <s> from git state branch ──
print_test_section "[#1805/SPEC-3] --from-stage rehydrates prior-stage artifacts and skips their stage.start"

S3_ID="$(zb_test_issue)"
S3_STATE_DIR="$TEST_TEMP_DIR/s3-state"
S3_EVENTS_DIR="$TEST_TEMP_DIR/s3-events"
S3_EVENTS_JSONL="$S3_EVENTS_DIR/events.jsonl"
S3_STATE_FILE="$S3_STATE_DIR/pipeline-state.json"
mkdir -p "$S3_STATE_DIR/artifacts" "$S3_EVENTS_DIR"

# Create a git repo; _artifact_persist_snapshot writes the state branch here.
S3_WORK_REPO="$(setup_git_temp_repo fs-rehydrate-s3)"
install_template_overlay "$S3_WORK_REPO" artifact-snapshot-coverage

# Create mock plugins (intake + cycled for the artifact-snapshot-coverage cyclic fixture;
# cycled is the inner member of the cyc cycle stage, roles:[builder]).
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
# cycled: inner member of cyc cycle stage (used by SPEC-3 and SPEC-13 sub-case).
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
S3_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# Create the intake primary artifact so the snapshot picks it up.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$S3_STATE_DIR/artifacts/intake-result.json"

# Snapshot onto the state branch in S3_WORK_REPO.
_s3_snap_rc=0
( export ZBUILD_STATE_DIR="$S3_STATE_DIR"
  cd "$S3_WORK_REPO" && _artifact_persist_snapshot "$S3_STATE_DIR" "$S3_ID" ) \
    >"$TEST_TEMP_DIR/s3-snap.log" 2>&1 || _s3_snap_rc=$?
if [[ "$_s3_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/SPEC-3] setup: snapshot to state branch failed" \
        "rc=$_s3_snap_rc; $(cat "$TEST_TEMP_DIR/s3-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/SPEC-3] setup: state branch populated"
fi

# Remove the artifact from disk; it now lives only on the state branch.
rm -f "$S3_STATE_DIR/artifacts/intake-result.json"

# Write state file: intake=complete, cyc=pending, status=in_progress.
jq -n \
    --arg run_id "s3-fs-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S3_ID" \
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
    }' > "$S3_STATE_FILE"

# Run runner with --from-stage cyc. CWD=S3_WORK_REPO so the state branch
# is reachable. Artifact must be restored before cyc (the cycle) dispatches.
set +e
( cd "$S3_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S3_STATE_DIR" \
    ZBUILD_STATE_FILE="$S3_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S3_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S3_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --resume --from-stage cyc --issue "$S3_ID" ) \
    >"$TEST_TEMP_DIR/s3-stdout.txt" 2>"$TEST_TEMP_DIR/s3-stderr.txt"
_s3_rc=$?
set -e

# [#1805/SPEC-3]: intake artifact must be in ZBUILD_ARTIFACT_DIR after --from-stage.
# Before the change: no rehydration → file absent → FAILS.
# After the change: _runner_from_stage_preflight restores it → PASSES.
assert_file_exists \
    "[#1805/SPEC-3] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR via --from-stage" \
    "$S3_STATE_DIR/artifacts/intake-result.json"

# [#1805/SPEC-3]: the restored artifact must carry the payload originally snapshotted to
# the git state branch — this proves _artifact_persist_restore read from git and
# _artifact_persist_put_back placed it in ZBUILD_ARTIFACT_DIR (not re-created fresh by
# the runner through any other mechanism).
# Before the change: no restore → file absent → content="" → FAILS.
# After the change: git state restore → original content present → PASSES.
_s3_restored_content="$(cat "$S3_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/SPEC-3] restored artifact contains original payload (proves _artifact_persist_restore + _artifact_persist_put_back used git state branch)" \
    "$_s3_restored_content" "prior-run intake"

# [#1805/SPEC-3]: intake must emit no stage.start event (it was skipped).
# Before the change: no rehydration means intake might be re-dispatched → stage.start emitted → FAILS.
# After the change: intake is complete and skipped entirely → no stage.start → PASSES.
_s3_intake_starts=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/SPEC-3] intake emits no stage.start when skipped via --from-stage" \
    "0" "$_s3_intake_starts"

# [#1805/SPEC-3]: cyc (the cycle stage) must be dispatched as the first stage.
# artifact-snapshot-coverage has intake (leaf) then cyc (cycle). --from-stage cyc means
# intake is skipped and cyc is the first thing dispatched: the cycle emits cycle.start
# with cycle_id=cyc (cycles do not emit stage.start; their inner members do).
# Before the change: without rehydration the runner may re-dispatch intake first → FAILS.
# After the change: intake is skipped; cyc (the --from-stage target) dispatches → PASSES.
_s3_cyc_started=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_cyc_started="$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="cyc") | .data.cycle_id' \
        "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/SPEC-3] cyc (cycle) dispatched as the first stage (--from-stage target, intake skipped)" \
    "1" "$_s3_cyc_started"

# ── SPEC-4: missing artifact with --from-stage exits 1 and names missing stage ─
print_test_section "[#1805/SPEC-4] --from-stage with no restorable artifact exits 1 naming missing stage"

S4_ID="$(zb_test_issue)"
S4_STATE_DIR="$TEST_TEMP_DIR/s4-state"
S4_EVENTS_DIR="$TEST_TEMP_DIR/s4-events"
S4_EVENTS_JSONL="$S4_EVENTS_DIR/events.jsonl"
S4_STATE_FILE="$S4_STATE_DIR/pipeline-state.json"
mkdir -p "$S4_STATE_DIR/artifacts" "$S4_EVENTS_DIR"

# Fresh repo with no state branch for S4_ID — no artifact anywhere.
S4_WORK_REPO="$(setup_git_temp_repo fs-rehydrate-s4)"
install_template_overlay "$S4_WORK_REPO" artifact-snapshot-coverage

# State: intake=complete, cyc=pending, NO artifact on disk, NO state branch.
jq -n \
    --arg run_id "s4-fs-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S4_ID" \
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
    }' > "$S4_STATE_FILE"

set +e
( cd "$S4_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S4_STATE_DIR" \
    ZBUILD_STATE_FILE="$S4_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S4_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S4_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --resume --from-stage cyc --issue "$S4_ID" ) \
    >"$TEST_TEMP_DIR/s4-stdout.txt" 2>"$TEST_TEMP_DIR/s4-stderr.txt"
_s4_rc=$?
set -e

# [#1805/SPEC-4]: runner must exit 1 when prior stage has no restorable artifact.
# Before the change: runner has no preflight check → continues → exits 0 → FAILS.
# After the change: _runner_from_stage_preflight exits 1 → PASSES.
assert_eq "[#1805/SPEC-4] --from-stage exits 1 when prior stage has no restorable artifact" \
    "1" "$_s4_rc"

# [#1805/SPEC-4]: stderr must contain the diagnostic phrase emitted by
# _runner_from_stage_preflight — "has no restorable primary artifact".
# This phrase is absent from the old code (which had no preflight check),
# so this assertion FAILS on old code and PASSES only after the new
# _runner_from_stage_preflight is present at runner.sh:1751.
_s4_stderr="$(cat "$TEST_TEMP_DIR/s4-stderr.txt" 2>/dev/null || true)"
assert_contains \
    "[#1805/SPEC-4] stderr contains preflight diagnostic phrase (has no restorable primary artifact)" \
    "$_s4_stderr" "has no restorable primary artifact"

# [#1805/SPEC-4]: no stage.start must be emitted before the exit.
_s4_any_starts=0
if [[ -f "$S4_EVENTS_JSONL" ]]; then
    _s4_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S4_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/SPEC-4] no stage.start emitted before exit 1" \
    "0" "$_s4_any_starts"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "from-stage-rehydrate test uses a fixture containing a cyclic stage"

# Run a fresh pipeline against the cyclic fixture (artifact-snapshot-coverage) to
# demonstrate that this test file exercises a pipeline containing a cyclic stage.
_S13_FS_ID="$(zb_test_issue)"
_S13_FS_WORK="$(setup_git_temp_repo fs-s13-cycle-check)"
install_template_overlay "$_S13_FS_WORK" artifact-snapshot-coverage

_S13_FS_STATE_DIR="$TEST_TEMP_DIR/s13fs-state"
_S13_FS_EVENTS_DIR="$TEST_TEMP_DIR/s13fs-events"
_S13_FS_EVENTS_JSONL="$_S13_FS_EVENTS_DIR/events.jsonl"
_S13_FS_STATE_FILE="$_S13_FS_STATE_DIR/pipeline-state.json"
mkdir -p "$_S13_FS_STATE_DIR/artifacts" "$_S13_FS_EVENTS_DIR"

jq -n \
    --arg run_id "s13fs-fresh-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S13_FS_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {}, current_iteration: 0, self_heal_count: {},
        scope_manifest_hash: "", cost_ledger_pointer: 0, claim_lease_id: "",
        plugin_state: {}, status: "in_progress", updated_at: $now
    }' > "$_S13_FS_STATE_FILE"

set +e
( cd "$_S13_FS_WORK" && env \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$_S13_FS_STATE_DIR" \
    ZBUILD_STATE_FILE="$_S13_FS_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$_S13_FS_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$_S13_FS_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --issue "$_S13_FS_ID" ) \
    >"$TEST_TEMP_DIR/s13fs-stdout.txt" 2>"$TEST_TEMP_DIR/s13fs-stderr.txt"
set -e

# : the fixture is cyclic (type: cycle present).
_s13_fs_content="$(cat "$REPO_ROOT/tests/fixtures/templates/artifact-snapshot-coverage.yaml")"
assert_contains "[#1805/SPEC-14] from-stage-rehydrate test uses a cyclic fixture (type: cycle)" \
    "$_s13_fs_content" "type: cycle"

# : confirm the cyclic pipeline ran (intake dispatched in the fresh run).
_s13_fs_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$_S13_FS_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "cyclic fixture pipeline ran in from-stage-rehydrate test (intake dispatched)" \
    "1" "$_s13_fs_intake_starts"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
