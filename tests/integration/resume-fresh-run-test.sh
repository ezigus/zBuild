#!/usr/bin/env bash
# Tests: the new-run side of the ADR-006 / ADR-050 §6 boundary. A fresh run
# (--no-resume, or no --resume on an in_progress state) dispatches every stage,
# whatever an earlier run left on the git state branch. (issue #1805)
#
# DSFRSH-1 [code]: a --no-resume run dispatches all stages from stage 1.
# DSFRSH-2 [code]: a fresh run never skips a stage because of prior-run artifacts.
# The resume side is in resume-rehydrate-test.sh (DSRHYD-1/DSRHYD-2).
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

print_test_header "resume-fresh-run — a new run never skips a stage on prior output (#1805)"
setup_test_env "resume-fresh-run-1805"
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

# ── SPEC-12: fresh (non-resume) run dispatches all stages ─────────────────────
print_test_section "[#1805/DSFRSH-1] fresh --no-resume run dispatches all stages (ADR-050 §6 new-run side)"

# Given — a state dir with status=interrupted and intake=complete exists (simulating a prior
#   interrupted run), and a prior-run artifact is present ONLY on the state branch (disk copy
#   removed), so a resume path would skip intake; the new run uses --no-resume to prevent this.
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
    assert_fail "[#1805/DSFRSH-1] setup: snapshot to state branch failed" \
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

# When — the runner is invoked with --no-resume (explicitly suppresses auto-resume detection).
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
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --no-resume --issue "$_S12_ID" ) \
    >"$TEST_TEMP_DIR/s12-stdout.txt" 2>"$TEST_TEMP_DIR/s12-stderr.txt"
set -e

# Then — a fresh run dispatches all stages from stage 1 with no stage skipped due to
#   prior state and no prior-run artifacts in ZBUILD_ARTIFACT_DIR.
# : intake must emit stage.start on a fresh run (not skipped by
# rehydration, which only applies on resume). This pins the new-run side of the
# ADR-050 §6 boundary: the prior-work reuse invariant governs new runs; a resume
# (governed by ADR-006) is the only path that may skip complete stages.
_s12_intake_starts=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "fresh run dispatches intake (not skipped; ADR-050 §6 new-run side)" \
    "1" "$_s12_intake_starts"

# [#1805/DSFRSH-1]: dispatch started from stage 1; intake must have dispatched exactly once.
# The state file has status=interrupted and intake=complete, which would trigger auto-resume
# (skipping intake, starting from a later stage) if --no-resume were absent. With --no-resume,
# the runner starts fresh from stage 1: intake dispatches, proving dispatch was not jumped to
# a later stage due to prior state. This establishes the "dispatches all stages from stage 1"
# clause of DSFRSH-1 directly (tagged DSFRSH-1, not only DSBNDY-1).
# DSFRSH-1 is a no-code requirement: need not fail before this change; must pass after.
assert_eq "[#1805/DSFRSH-1] fresh run (--no-resume) dispatches all stages from stage 1 (intake dispatched; did not skip to a later stage due to prior state)" \
    "1" "$_s12_intake_starts"

# [#1805/DSFRSH-1]: no stage.skip event must be emitted on a fresh run.
# DSFRSH-1 requires "no stage skipped due to prior state"; this assertion covers the
# event-side observable. stage.skip is emitted if and only if the dispatch-unit skip guard
# fires and skips a stage — which must not happen on a fresh run. The stage.start=1
# assertion above already covers the dispatch-side: if intake were silently skipped (via
# any mechanism), that assertion would catch it.
# DSFRSH-1 is a no-code requirement: must pass on current code; need not fail before.
_s12_stage_skips=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_stage_skips="$(jq -r 'select(.type=="stage.skip") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFRSH-1] fresh run (--no-resume) emits no stage.skip events (no stage skipped due to prior state)" \
    "0" "$_s12_stage_skips"

# [#1805/DSFRSH-1]: the cycle stage (cyc) must have been dispatched on a fresh run.
# This catches a bug where the skip guard erroneously suppresses the cycle stage
# without emitting stage.skip — a scenario the stage.skip==0 assertion above cannot
# detect. cycle.start is emitted by the cycle orchestrator when cyc is dispatched;
# a buggy skip guard that suppresses cyc would yield cycle.start==0 and fail here.
# Passes on current code: cycle stages emit cycle.start normally (confirmed by
# core-pipeline-cycle-orchestrator-test.sh). Would fail after this change if the
# skip guard activates for the cycle stage on a fresh run.
_s12_cyc_cycle_starts=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_cyc_cycle_starts="$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="cyc") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFRSH-1] fresh run dispatches cycle stage (cyc) — cycle.start emitted (cycle stage not erroneously suppressed by skip guard)" \
    "$_s12_cyc_cycle_starts" "0"

# [#1805/DSFRSH-1]: no artifact from a prior run must appear in ZBUILD_ARTIFACT_DIR.
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
assert_eq "[#1805/DSFRSH-1] no prior-run artifact content in ZBUILD_ARTIFACT_DIR (fresh --no-resume run does not restore prior-run artifacts from state branch)" \
    "0" "$_s12_prior_in_dir"

# : the cycle fixture used for this fresh-run sub-case contains type: cycle,
# establishing that the fixture IS a cyclic pipeline (satisfying the "same cycle fixture" clause).
# DSBNDY-1 requires "verifies intake dispatches AND the fixture contains type:cycle" —
# the cycled sub-stage dispatch is not required by DSBNDY-1.
_s12_fixt_content="$(cat "$REPO_ROOT/tests/fixtures/templates/artifact-snapshot-coverage.yaml")"
assert_contains "cycle fixture used in fresh-run sub-case has type: cycle" \
    "$_s12_fixt_content" "type: cycle"

# [#1805/DSFRSH-1]: a fresh run must NOT emit stage.start for cycle members (cycled).
# Design (Gap 7): stage.start for cycle members is only emitted via the DSCMBR-1
# resume_first_iter=true path; it must NOT fire unconditionally on fresh runs.
# Before this change (pre-#1805): cycle members never emitted stage.start (they emit
#   cycle.member.dispatch.{start,complete} instead); _s12_cycled_starts=0 → PASSES (no-code ✓).
# After this change with the iter>0 guard bug: stage.start fires for every cycle member
#   dispatch unconditionally (iter starts at 1, so iter>0 is always true) → cycled emits
#   stage.start on fresh runs → _s12_cycled_starts=1 → assert 0==1 → FAILS (exposes bug).
# After fix (iter>0 guard removed or guarded by _ZBUILD_RESUME_ACTIVE):
#   cycle members emit stage.start only via DSCMBR-1 resume path → 0 on fresh run → PASSES.
# This covers RQGUAR-1 on the cycle-member side (the gap red-team finding 4 names).
_s12_cycled_starts=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_cycled_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="cycled") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFRSH-1] no stage.start for cycle member (cycled) on fresh run (cycle members only emit stage.start via DSCMBR-1 resume path; iter>0 guard must not fire unconditionally on fresh runs)" \
    "0" "$_s12_cycled_starts"

# ── DSFRSH-2: fresh run with prior state branch artifacts never skips via dispatch-unit guard ─
print_test_section "[#1805/DSFRSH-2] fresh run (no --resume, in_progress status) never skips stages due to prior-run artifacts in git state branch"

# Given — an issue has prior completed runs with artifacts present in the git state branch;
#   a new run is started with no --resume flag and no status=interrupted state file.
_S_FRSH2_ID="$(zb_test_issue)"
_S_FRSH2_STATE_DIR="$TEST_TEMP_DIR/frsh2-state"
_S_FRSH2_EVENTS_DIR="$TEST_TEMP_DIR/frsh2-events"
_S_FRSH2_EVENTS_JSONL="$_S_FRSH2_EVENTS_DIR/events.jsonl"
_S_FRSH2_STATE_FILE="$_S_FRSH2_STATE_DIR/pipeline-state.json"
mkdir -p "$_S_FRSH2_STATE_DIR/artifacts" "$_S_FRSH2_EVENTS_DIR"

_S_FRSH2_WORK_REPO="$(setup_git_temp_repo frsh2-work)"
install_template_overlay "$_S_FRSH2_WORK_REPO" artifact-snapshot-coverage

# Put prior-run artifact on the state branch to simulate a completed prior run.
# The disk copy is then removed so the artifact lives only on the state branch.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}' \
    > "$_S_FRSH2_STATE_DIR/artifacts/intake-result.json"

_frsh2_snap_rc=0
( export ZBUILD_STATE_DIR="$_S_FRSH2_STATE_DIR"
  cd "$_S_FRSH2_WORK_REPO" && _artifact_persist_snapshot "$_S_FRSH2_STATE_DIR" "$_S_FRSH2_ID" ) \
    >"$TEST_TEMP_DIR/frsh2-snap.log" 2>&1 || _frsh2_snap_rc=$?
if [[ "$_frsh2_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSFRSH-2] setup: snapshot to state branch failed" \
        "rc=$_frsh2_snap_rc; $(cat "$TEST_TEMP_DIR/frsh2-snap.log" 2>/dev/null | tail -5)"
fi
rm -f "$_S_FRSH2_STATE_DIR/artifacts/intake-result.json"

# Fresh state file: status=in_progress (not interrupted), no stage marked complete.
# The runner that sees status != interrupted will NOT auto-resume; without --resume it
# runs fresh. If the dispatch-unit skip guard activates unconditionally (not conditional
# on resume_mode), it would see prior artifacts on the state branch and skip intake.
jq -n \
    --arg run_id "frsh2-fresh-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$_S_FRSH2_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {}, current_iteration: 0, self_heal_count: {},
        scope_manifest_hash: "", cost_ledger_pointer: 0, claim_lease_id: "",
        plugin_state: {}, status: "in_progress", updated_at: $now
    }' > "$_S_FRSH2_STATE_FILE"

# When — the dispatch loop runs with no --resume flag and status=in_progress
#   (not interrupted), so no auto-resume triggers.
set +e
( cd "$_S_FRSH2_WORK_REPO" && env \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$_S_FRSH2_STATE_DIR" \
    ZBUILD_STATE_FILE="$_S_FRSH2_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$_S_FRSH2_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$_S_FRSH2_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage --issue "$_S_FRSH2_ID" ) \
    >"$TEST_TEMP_DIR/frsh2-stdout.txt" 2>"$TEST_TEMP_DIR/frsh2-stderr.txt"
set -e

# Then — every stage emits a stage.start event; no stage.skip event is emitted for any stage.
# [#1805/DSFRSH-2]: intake must emit stage.start (not skipped by dispatch-unit guard).
# This requirement need not fail before this change (no-code property); it must pass after.
# If the skip guard were unconditional (not keyed on resume_mode), it would read the prior
# artifacts from the state branch and skip intake → intake_starts=0 → FAILS.
# After the change: guard is conditional on resume_mode → not active on fresh run →
#   intake dispatches → intake_starts=1 → PASSES.
_frsh2_intake_starts=0
if [[ -f "$_S_FRSH2_EVENTS_JSONL" ]]; then
    _frsh2_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$_S_FRSH2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq \
    "[#1805/DSFRSH-2] fresh run (no --resume, in_progress status) dispatches intake even with prior-run artifacts on git state branch (dispatch-unit skip guard conditional on resume_mode)" \
    "1" "$_frsh2_intake_starts"

# [#1805/DSFRSH-2]: no stage.skip event must be emitted on a fresh run.
# Then: No stage.skip event is emitted for any stage (from the SPEC).
# stage.skip is emitted if and only if the dispatch-unit skip guard fires and skips a
# stage — which must not happen on a fresh run (the guard must be conditional on
# resume_mode). The stage.start=1 assertion above already covers the dispatch-side
# observable: if intake were skipped, intake_starts would not equal 1.
# DSFRSH-2 is a no-code requirement: must pass on current code; need not fail before.
_frsh2_stage_skips=0
if [[ -f "$_S_FRSH2_EVENTS_JSONL" ]]; then
    _frsh2_stage_skips="$(jq -r 'select(.type=="stage.skip") | .type' \
        "$_S_FRSH2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq \
    "[#1805/DSFRSH-2] fresh run (no --resume) emits no stage.skip events (dispatch-unit skip guard does not activate for fresh runs)" \
    "0" "$_frsh2_stage_skips"

# [#1805/DSFRSH-2]: the cycle stage (cyc) must have been dispatched on a fresh run
# even with prior-run artifacts present on the git state branch.
# This catches a bug where the skip guard reads prior artifacts and erroneously
# suppresses cyc without emitting stage.skip — a gap the assertion above cannot detect.
# cycle.start is emitted when the cycle stage is dispatched; a buggy guard that
# activates on a fresh run would yield cycle.start==0 and fail here.
# Passes on current code: cycle stages emit cycle.start normally.
# Would fail after this change if the skip guard (conditional on resume_mode) is
# incorrectly applied to fresh runs.
_frsh2_cyc_cycle_starts=0
if [[ -f "$_S_FRSH2_EVENTS_JSONL" ]]; then
    _frsh2_cyc_cycle_starts="$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="cyc") | .type' \
        "$_S_FRSH2_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt \
    "[#1805/DSFRSH-2] fresh run dispatches cycle stage (cyc) — cycle.start emitted (skip guard conditional on resume_mode does not suppress cycle stage on fresh run)" \
    "$_frsh2_cyc_cycle_starts" "0"

# ── DSCYCL-1: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-fresh-run test uses a fixture containing a cyclic stage"

# Then — the test fixtures used by resume-fresh-run-test.sh contain a pipeline stage of
#   type: cycle, verified by an assert_contains tagged .
# : the fixture must contain type: cycle.
assert_contains "resume-fresh-run (DSFRSH-1/DSFRSH-2) fixture (artifact-snapshot-coverage) contains type: cycle" \
    "$_s12_fixt_content" "type: cycle"

# : the pipeline using the cyclic fixture was actually run; intake dispatched
# in the fresh run above (_s12_intake_starts asserted = 1 in the DSBNDY-1 section).
assert_eq "resume-fresh-run: pipeline with cyclic fixture was actually run (intake dispatched)" \
    "1" "$_s12_intake_starts"

print_test_results
cleanup_test_env
