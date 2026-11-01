#!/usr/bin/env bash
# Tests: resume rehydrates completed-stage artifacts from the git state branch
# before the dispatch loop. (issue #1805, ADR-006 §3.5)
#
# SPEC-1 [code]: on resume, runner calls _artifact_persist_restore +
#   _artifact_persist_put_back and places completed-stage artifacts into
#   ZBUILD_ARTIFACT_DIR before the dispatch loop; the complete stage emits
#   no stage.start event.
#
# SPEC-2 [code]: a complete stage whose primary artifact is absent from both
#   disk and the git state branch causes the resume to exit 1 before any
#   stage.start event is emitted.
#
# SPEC-5 [no-code]: ADR-006-resume-contract.md amended with step 3.5:
#   before the dispatch loop the runner restores completed-stage artifacts from
#   the git state branch; a still-absent artifact causes exit 1; enforcing
#   test names added inline.
#
# SPEC-6 [no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with
#   boundary note: the invariant applies to new runs; a resume continues the
#   same run and is governed by ADR-006.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
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

install_template_overlay "$WORK_REPO" runner-state-dir-minimal

# Create mock plugins (intake + build, each declaring a primary artifact).
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── SPEC-1: resume rehydrates artifacts from git state branch ─────────────────
print_test_section "[#1805/SPEC-1] resume restores completed-stage artifact into ZBUILD_ARTIFACT_DIR"

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
    assert_fail "[#1805/SPEC-1] setup: snapshot to state branch failed" \
        "rc=$_s1_snap_rc; $(cat "$TEST_TEMP_DIR/s1-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/SPEC-1] setup: state branch populated with intake-result.json"
fi

# Remove the artifact from disk to simulate the "artifacts not on disk" scenario.
rm -f "$S1_STATE_DIR/artifacts/intake-result.json"

# Write state file: intake=complete, build=pending.
jq -n \
    --arg run_id "s1-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_ZB_ID" \
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
    }' > "$S1_STATE_FILE"

# Run runner --resume. CWD=WORK_REPO so _artifact_persist_restore finds the
# state branch. Capture rc; do not abort on failure.
set +e
( cd "$WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S1_STATE_DIR" \
    ZBUILD_STATE_FILE="$S1_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S1_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S1_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template runner-state-dir-minimal --resume --issue "$_ZB_ID" ) \
    >"$TEST_TEMP_DIR/s1-stdout.txt" 2>"$TEST_TEMP_DIR/s1-stderr.txt"
_s1_rc=$?
set -e

# [#1805/SPEC-1]: artifact must be present in ZBUILD_ARTIFACT_DIR after resume.
# Before the change: no rehydration → file absent → FAILS.
# After the change: rehydration copies artifact from state branch → PASSES.
assert_file_exists "[#1805/SPEC-1] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR" \
    "$S1_STATE_DIR/artifacts/intake-result.json"

# [#1805/SPEC-1]: intake must NOT have a stage.start event (it was complete and skipped).
_s1_intake_starts=0
if [[ -f "$S1_EVENTS_JSONL" ]]; then
    _s1_intake_starts="$(grep -c '"type":"stage.start"' "$S1_EVENTS_JSONL" \
        | xargs | grep -c '^[1-9]' 2>/dev/null || true)"
    # More precise: count stage.start events whose data.stage == "intake"
    _s1_intake_starts="$(jq -r 'select(.type=="stage.start") | .data.stage // empty' \
        "$S1_EVENTS_JSONL" 2>/dev/null | grep -c '^intake$' 2>/dev/null || echo 0)"
fi
assert_eq "[#1805/SPEC-1] intake emits no stage.start (complete stage skipped)" \
    "0" "$_s1_intake_starts"

# ── SPEC-2: missing artifact causes resume to exit 1 ─────────────────────────
print_test_section "[#1805/SPEC-2] missing artifact causes resume exit 1 before any stage.start"

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
install_template_overlay "$WORK_REPO2" runner-state-dir-minimal

# State: intake=complete but NO artifact on disk and NO state branch.
jq -n \
    --arg run_id "s2-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S2_ID" \
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
    }' > "$S2_STATE_FILE"

set +e
( cd "$WORK_REPO2" && env \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S2_STATE_DIR" \
    ZBUILD_STATE_FILE="$S2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template runner-state-dir-minimal --resume --issue "$_S2_ID" ) \
    >"$TEST_TEMP_DIR/s2-stdout.txt" 2>"$TEST_TEMP_DIR/s2-stderr.txt"
_s2_rc=$?
set -e

# [#1805/SPEC-2]: runner must exit 1 when artifact absent from disk AND state branch.
# Before the change: runner warns about stale artifact and continues → exits 0 → FAILS.
# After the change: runner exits 1 after failing to restore the artifact → PASSES.
assert_eq "[#1805/SPEC-2] resume exits 1 when primary artifact cannot be restored" \
    "1" "$_s2_rc"

# [#1805/SPEC-2]: no stage.start event must be emitted before the exit.
# (exit 1 happens before the dispatch loop reaches any stage)
_s2_any_starts=0
if [[ -f "$S2_EVENTS_JSONL" ]]; then
    _s2_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/SPEC-2] no stage.start emitted before exit 1" \
    "0" "$_s2_any_starts"

# ── SPEC-5: ADR-006 amended with artifact-restore step 3.5 ───────────────────
print_test_section "[#1805/SPEC-5] ADR-006 amended: step 3.5 restores artifacts before dispatch loop"

# [#1805/SPEC-5]: ADR-006 must contain the amendment text describing artifact
# restoration in the resume sequence and exit 1 for an absent artifact.
# This passes after the doc change; it need not fail before.
_adr006="$(cat "$ADR_006" 2>/dev/null || true)"

assert_contains "[#1805/SPEC-5] ADR-006 step 3.5 describes artifact restore before dispatch loop" \
    "$_adr006" "artifact"

assert_contains "[#1805/SPEC-5] ADR-006 step 3.5 names the enforcing test" \
    "$_adr006" "resume-rehydrate-test.sh"

# ── SPEC-6: ADR-050 §6 amended with resume boundary note ─────────────────────
print_test_section "[#1805/SPEC-6] ADR-050 §6 amended with boundary note distinguishing resume from new runs"

_adr050="$(cat "$ADR_050" 2>/dev/null || true)"

# [#1805/SPEC-6]: §6 must explicitly state that a resume is governed by ADR-006,
# not by ADR-050's prior-work invariant.
assert_contains "[#1805/SPEC-6] ADR-050 §6 names ADR-006 as governing resume" \
    "$_adr050" "ADR-006"

assert_contains "[#1805/SPEC-6] ADR-050 §6 boundary note distinguishes new runs from resume" \
    "$_adr050" "resume"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
