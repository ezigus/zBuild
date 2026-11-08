#!/usr/bin/env bash
# Tests: --from-stage <s> rehydrates completed-stage artifacts before dispatching <s>.
# (issue #1805, ADR-006 §3.5 / _runner_from_stage_preflight)
#
# DSFSTG-1 [code]: --from-stage <s> rehydrates all stages before <s> via
#   _artifact_persist_restore and _artifact_persist_put_back, places their
#   artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and
#   emits no stage.start for any earlier stage.
#
# DSFSTG-2 [code]: --from-stage <s> when a stage before <s> has no restorable
#   artifact emits the diagnostic phrase "has no restorable primary artifact"
#   to stderr and exits 1 before any stage.start event is emitted.
#
# DSCYCL-1 [no-code]: the test fixture contains a pipeline stage of type: cycle.
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
print_test_section "[#1805/DSFSTG-1] --from-stage rehydrates stages before <s> and dispatches <s> first"

# Given — a previous run completed stages before <s> (intake is complete); their artifacts
#   are present in the git state branch; a new invocation uses --from-stage cyc.
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
    assert_fail "[#1805/DSFSTG-1] setup: snapshot to state branch failed" \
        "rc=$_s3_snap_rc; $(cat "$TEST_TEMP_DIR/s3-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/DSFSTG-1] setup: state branch populated"
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
# When — the runner starts with --from-stage cyc.
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

# Then — artifacts from every stage before cyc appear in ZBUILD_ARTIFACT_DIR before
# the dispatch loop starts; stage cyc is dispatched as the first stage; no stage.start
# for any stage before cyc.

# [#1805/DSFSTG-1]: intake artifact must be in ZBUILD_ARTIFACT_DIR after --from-stage.
# Before the change: no rehydration → file absent → FAILS.
# After the change: _runner_from_stage_preflight restores it → PASSES.
assert_file_exists \
    "[#1805/DSFSTG-1] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR via --from-stage" \
    "$S3_STATE_DIR/artifacts/intake-result.json"

# [#1805/DSFSTG-1]: the restored artifact must carry the payload originally snapshotted to
# the git state branch — this proves _artifact_persist_restore read from git and
# _artifact_persist_put_back placed it in ZBUILD_ARTIFACT_DIR (not re-created fresh by
# the runner through any other mechanism).
# Before the change: no restore → file absent → content="" → FAILS.
# After the change: git state restore → original content present → PASSES.
_s3_restored_content="$(cat "$S3_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/DSFSTG-1] restored artifact contains original payload (proves _artifact_persist_restore + _artifact_persist_put_back used git state branch)" \
    "$_s3_restored_content" "prior-run intake"

# [#1805/DSFSTG-1]: pipeline.resume must appear in the events log BEFORE the first
# cycle.start event, proving _runner_from_stage_preflight (which calls
# _artifact_persist_restore and _artifact_persist_put_back) completed before the
# dispatch loop reached stage cyc. pipeline.resume is emitted at the end of the
# preflight / rehydration step, before the dispatch loop begins. cycle.start is emitted
# when cyc (the --from-stage target) is first dispatched.
# Before the change: no preflight → pipeline.resume absent OR no ordering guarantee →
#   resume_lineno=0 → assert 0 > 0 → FAILS.
# After the change: preflight runs → pipeline.resume emitted → dispatch loop starts →
#   cycle.start emitted → resume_lineno < cyc_start_lineno → PASSES.
_s3_resume_lineno=0
_s3_first_dispatch_lineno=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_resume_lineno="$(awk '/"pipeline.resume"/{print NR; exit}' "$S3_EVENTS_JSONL" 2>/dev/null)"
    _s3_resume_lineno="${_s3_resume_lineno:-0}"
    _s3_first_dispatch_lineno="$(awk '/"cycle.start"/{print NR; exit}' "$S3_EVENTS_JSONL" 2>/dev/null)"
    _s3_first_dispatch_lineno="${_s3_first_dispatch_lineno:-0}"
fi
assert_gt "[#1805/DSFSTG-1] pipeline.resume event emitted (from-stage preflight ran before dispatch loop)" \
    "$_s3_resume_lineno" "0"
assert_gt "[#1805/DSFSTG-1] pipeline.resume precedes first dispatch event (artifact restored before dispatch loop started)" \
    "$_s3_first_dispatch_lineno" "$_s3_resume_lineno"

# [#1805/DSFSTG-1]: intake must emit no stage.start event (it was skipped).
# Before the change: no rehydration means intake might be re-dispatched → stage.start emitted → FAILS.
# After the change: intake is complete and skipped entirely → no stage.start → PASSES.
_s3_intake_starts=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-1] intake emits no stage.start when skipped via --from-stage" \
    "0" "$_s3_intake_starts"

# [#1805/DSFSTG-1]: stage <s>=cyc must be dispatched as the first stage and a stage.start
# event must be emitted. artifact-snapshot-coverage has intake (leaf) then cyc (cycle).
# --from-stage cyc means intake is skipped and cyc is the first thing dispatched.
# A cycle stage's inner member (cycled) emits stage.start with stage=cycled when cyc
# dispatches it; this is the first stage.start event and proves cyc was dispatched first.
# Before the change: without rehydration the runner may re-dispatch intake first →
#   stage.start for intake before cycled → no cycled stage.start OR intake dispatched → FAILS.
# After the change: intake is skipped; cyc dispatches cycled as first stage → PASSES.
_s3_cycled_started=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_cycled_started="$(jq -r 'select(.type=="stage.start" and .data.stage=="cycled") | .type' \
        "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] stage.start emitted for cycled (inner member of cyc; proves --from-stage target cyc was dispatched as first stage)" \
    "$_s3_cycled_started" "0"

# [#1805/DSFSTG-1]: pipeline.skip_to_stage must be emitted when --from-stage is active.
# RQFROM-2 says the event must be emitted and no earlier stage dispatched after it.
# Before the change: no --from-stage support → no pipeline.skip_to_stage event →
#   _s3_skip_stage_count=0 → assert 0 > 0 → FAILS.
# After the change: runner emits pipeline.skip_to_stage → PASSES.
_s3_skip_stage_count=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_skip_stage_count="$(jq -r 'select(.type=="pipeline.skip_to_stage") | .type' \
        "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] pipeline.skip_to_stage emitted when --from-stage is active (--resume path)" \
    "$_s3_skip_stage_count" "0"

# [#1805/DSFSTG-1]: no stage before <s>=cyc dispatched after pipeline.skip_to_stage.
# intake must not appear as a stage.start event after pipeline.skip_to_stage fires.
# Before the change: skip_to_stage absent → lineno=0 → guard skips → intake_after=0
#   but skip_stage_count=0 assertion above already fails.
# After the change: skip_to_stage fires before dispatch loop; intake is rehydrated
#   not dispatched → no stage.start for intake after skip_to_stage → PASSES.
_s3_skip_lineno=0
_s3_intake_after_skip=0
if [[ -f "$S3_EVENTS_JSONL" ]]; then
    _s3_skip_lineno="$(awk '/"pipeline.skip_to_stage"/{print NR; exit}' "$S3_EVENTS_JSONL" 2>/dev/null)"
    _s3_skip_lineno="${_s3_skip_lineno:-0}"
    if [[ "$_s3_skip_lineno" -gt 0 ]]; then
        _s3_intake_after_skip="$(awk -v n="$_s3_skip_lineno" \
            'NR>n && /"stage\.start"/ && /"intake"/ {c++} END{print c+0}' \
            "$S3_EVENTS_JSONL" 2>/dev/null)"
    fi
fi
assert_eq "[#1805/DSFSTG-1] no stage before <s>=cyc dispatched after pipeline.skip_to_stage (--resume path; RQFROM-2)" \
    "0" "$_s3_intake_after_skip"

# ── SPEC-3b: --from-stage WITHOUT --resume exercises skip_restore=false branch ──
# This sub-case covers the plain `--from-stage <s>` path (no --resume flag),
# which routes through _runner_from_stage_preflight with skip_restore=false —
# the branch that performs the git archive restore itself rather than relying on
# a prior resume rehydration step. The existing S3 sub-case always uses
# `--resume --from-stage` (skip_restore=true); without this sub-case that
# substantively different restore path is never exercised.
# (Addresses lens-scope-code finding 1.)
print_test_section "[#1805/DSFSTG-1] --from-stage WITHOUT --resume rehydrates stages before <s> (skip_restore=false branch)"

# Given — a previous run completed intake; its artifact is present in the git
#   state branch; a new invocation uses --from-stage cyc WITHOUT --resume.
S5_ID="$(zb_test_issue)"
S5_STATE_DIR="$TEST_TEMP_DIR/s5-state"
S5_EVENTS_DIR="$TEST_TEMP_DIR/s5-events"
S5_EVENTS_JSONL="$S5_EVENTS_DIR/events.jsonl"
S5_STATE_FILE="$S5_STATE_DIR/pipeline-state.json"
mkdir -p "$S5_STATE_DIR/artifacts" "$S5_EVENTS_DIR"

# Fresh git repo; _artifact_persist_snapshot writes the state branch here.
S5_WORK_REPO="$(setup_git_temp_repo fs-rehydrate-s5)"
install_template_overlay "$S5_WORK_REPO" artifact-snapshot-coverage

# Create intake primary artifact so the snapshot picks it up.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run-noresume-intake"}' \
    > "$S5_STATE_DIR/artifacts/intake-result.json"

# Snapshot onto the state branch in S5_WORK_REPO.
_s5_snap_rc=0
( export ZBUILD_STATE_DIR="$S5_STATE_DIR"
  cd "$S5_WORK_REPO" && _artifact_persist_snapshot "$S5_STATE_DIR" "$S5_ID" ) \
    >"$TEST_TEMP_DIR/s5-snap.log" 2>&1 || _s5_snap_rc=$?
if [[ "$_s5_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSFSTG-1] setup s5: snapshot failed" \
        "rc=$_s5_snap_rc; $(cat "$TEST_TEMP_DIR/s5-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/DSFSTG-1] setup s5: state branch populated (no-resume path)"
fi

# Remove the artifact from disk — it now lives only on the state branch.
rm -f "$S5_STATE_DIR/artifacts/intake-result.json"

# State file: intake=complete, cyc=pending — the runner needs to know intake
# was done in the prior run so it rehydrates rather than dispatches it.
jq -n \
    --arg run_id "s5-fs-noresume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S5_ID" \
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
    }' > "$S5_STATE_FILE"

# When — the runner starts with --from-stage cyc and NO --resume flag.
# This exercises the skip_restore=false branch of _runner_from_stage_preflight,
# where the function performs the git archive restore itself.
set +e
( cd "$S5_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S5_STATE_DIR" \
    ZBUILD_STATE_FILE="$S5_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S5_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S5_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --from-stage cyc --issue "$S5_ID" ) \
    >"$TEST_TEMP_DIR/s5-stdout.txt" 2>"$TEST_TEMP_DIR/s5-stderr.txt"
_s5_rc=$?
set -e

# Then — intake artifact must appear in ZBUILD_ARTIFACT_DIR before cyc dispatches.
# Before the change: skip_restore=false path does not exist / no rehydration →
#   file absent → FAILS.
# After the change: _runner_from_stage_preflight with skip_restore=false restores
#   the artifact from the git state branch → PASSES.
assert_file_exists \
    "[#1805/DSFSTG-1] intake-result.json rehydrated via --from-stage without --resume (skip_restore=false branch)" \
    "$S5_STATE_DIR/artifacts/intake-result.json"

# Then — restored artifact must contain the original payload.
_s5_restored_content="$(cat "$S5_STATE_DIR/artifacts/intake-result.json" 2>/dev/null || true)"
assert_contains \
    "[#1805/DSFSTG-1] restored artifact contains prior-run payload (--from-stage without --resume; skip_restore=false used git state branch)" \
    "$_s5_restored_content" "prior-run-noresume-intake"

# Then — intake emits no stage.start (it was rehydrated, not dispatched).
# Before the change: intake would be re-dispatched normally → stage.start for intake → FAILS.
# After the change: intake is skipped via preflight rehydration → no stage.start → PASSES.
_s5_intake_starts=0
if [[ -f "$S5_EVENTS_JSONL" ]]; then
    _s5_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S5_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-1] intake emits no stage.start when skipped via --from-stage without --resume" \
    "0" "$_s5_intake_starts"

# [#1805/DSFSTG-1]: pipeline.skip_to_stage must be emitted when --from-stage is active
# (plain --from-stage without --resume; skip_restore=false branch).
# Before the change: no --from-stage support → no pipeline.skip_to_stage event → FAILS.
# After the change: runner emits pipeline.skip_to_stage on the no-resume path → PASSES.
_s5_skip_stage_count=0
if [[ -f "$S5_EVENTS_JSONL" ]]; then
    _s5_skip_stage_count="$(jq -r 'select(.type=="pipeline.skip_to_stage") | .type' \
        "$S5_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] pipeline.skip_to_stage emitted when --from-stage active without --resume (skip_restore=false branch; RQFROM-2)" \
    "$_s5_skip_stage_count" "0"

# [#1805/DSFSTG-1]: no stage before <s>=cyc dispatched after pipeline.skip_to_stage
# (plain --from-stage without --resume path).
_s5_skip_lineno=0
_s5_intake_after_skip=0
if [[ -f "$S5_EVENTS_JSONL" ]]; then
    _s5_skip_lineno="$(awk '/"pipeline.skip_to_stage"/{print NR; exit}' "$S5_EVENTS_JSONL" 2>/dev/null)"
    _s5_skip_lineno="${_s5_skip_lineno:-0}"
    if [[ "$_s5_skip_lineno" -gt 0 ]]; then
        _s5_intake_after_skip="$(awk -v n="$_s5_skip_lineno" \
            'NR>n && /"stage\.start"/ && /"intake"/ {c++} END{print c+0}' \
            "$S5_EVENTS_JSONL" 2>/dev/null)"
    fi
fi
assert_eq "[#1805/DSFSTG-1] no stage before <s>=cyc dispatched after pipeline.skip_to_stage (no --resume path; RQFROM-2)" \
    "0" "$_s5_intake_after_skip"

# [#1805/DSFSTG-1]: stage <s>=cyc must be dispatched as the first unit on the
# plain --from-stage path; a cycle.start event must be emitted for cyc.
# Before the change: without --from-stage support cyc is never dispatched on this
#   path → no cycle.start → _s5_cyc_starts=0 → assert 0 > 0 → FAILS.
# After the change: cyc is the first dispatched unit → cycle.start emitted → PASSES.
_s5_cyc_starts=0
if [[ -f "$S5_EVENTS_JSONL" ]]; then
    _s5_cyc_starts="$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="cyc") | .type' \
        "$S5_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] cycle.start emitted for <s>=cyc (first dispatch unit on plain --from-stage path)" \
    "$_s5_cyc_starts" "0"

# [#1805/DSFSTG-1]: stage.start for cycled (cyc's first cycle member) on the
# plain --from-stage path; confirms the cycle stage <s> was actually dispatched
# and its first member was started.
# Before the change: cyc not dispatched → no stage.start for cycled → FAILS.
# After the change: cyc dispatches cycled → stage.start emitted → PASSES.
_s5_cycled_started=0
if [[ -f "$S5_EVENTS_JSONL" ]]; then
    _s5_cycled_started="$(jq -r 'select(.type=="stage.start" and .data.stage=="cycled") | .type' \
        "$S5_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] stage.start emitted for cycled (inner member of cyc; proves --from-stage dispatches <s> as first unit on plain path)" \
    "$_s5_cycled_started" "0"

# ── SPEC-4: missing artifact with --from-stage exits 1 and names missing stage ─
print_test_section "[#1805/DSFSTG-2] --from-stage with no restorable artifact emits diagnostic and exits 1"

# Given — --from-stage cyc is active; at least one stage before cyc (intake) has no
#   restorable primary artifact in the git state branch (no state branch for this issue).
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

# When — the runner performs the from-stage preflight check (--resume --from-stage cyc).
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

# Then — diagnostic appears on stderr; runner exits 1 before any stage.start event.
# [#1805/DSFSTG-2]: runner must exit 1 when prior stage has no restorable artifact.
# Before the change: runner has no preflight check → continues → exits 0 → FAILS.
# After the change: _runner_from_stage_preflight exits 1 → PASSES.
assert_eq "[#1805/DSFSTG-2] --from-stage exits 1 when prior stage has no restorable artifact" \
    "1" "$_s4_rc"

# [#1805/DSFSTG-2]: stderr must contain the diagnostic phrase emitted by
# _runner_from_stage_preflight — "has no restorable primary artifact".
# This phrase is absent from the old code (which had no preflight check),
# so this assertion FAILS on old code and PASSES only after the new
# _runner_from_stage_preflight is present at runner.sh:1751.
_s4_stderr="$(cat "$TEST_TEMP_DIR/s4-stderr.txt" 2>/dev/null || true)"
assert_contains \
    "[#1805/DSFSTG-2] stderr contains preflight diagnostic phrase (has no restorable primary artifact)" \
    "$_s4_stderr" "has no restorable primary artifact"

# [#1805/DSFSTG-2]: no stage.start must be emitted before the exit.
_s4_any_starts=0
if [[ -f "$S4_EVENTS_JSONL" ]]; then
    _s4_any_starts="$(jq -r 'select(.type=="stage.start") | .type' \
        "$S4_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-2] no stage.start emitted before exit 1" \
    "0" "$_s4_any_starts"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "from-stage-rehydrate test uses a fixture containing a cyclic stage"

# Then — the test fixtures used by from-stage-rehydrate-test.sh contain a pipeline stage
#   of type: cycle, verified by an assert_contains tagged [#1805/DSCYCL-1].
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
assert_contains "[#1805/DSCYCL-1] from-stage-rehydrate test uses a cyclic fixture (type: cycle)" \
    "$_s13_fs_content" "type: cycle"

# : confirm the cyclic pipeline ran (intake dispatched in the fresh run).
_s13_fs_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$_S13_FS_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "cyclic fixture pipeline ran in from-stage-rehydrate test (intake dispatched)" \
    "1" "$_s13_fs_intake_starts"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
