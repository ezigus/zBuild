#!/usr/bin/env bash
# Tests: --from-stage with a leaf target, combined --resume --from-stage, and
# the R4a guard. (issue #1805, ADR-006)
#
# DSFSTG-1 [code]: a leaf <s> emits stage.start.
# DSFSTG-3 [code]: in combined --resume --from-stage <s>, the stages after <s>
#   run even when the interrupted run marked them complete.
# DSFSTG-4 [code]: --from-stage without --resume refuses, even when the run
#   would auto-resume (flat state file or the latest link).
# Split from from-stage-rehydrate-test.sh.
#
# DSCYCL-1 [no-code]: the test fixture contains a pipeline stage of type: cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "from-stage-resume-guard — --from-stage targets and the --resume guard (#1805)"
setup_test_env "from-stage-resume-guard-1805"
export ZBUILD_CONTRACT_VALIDATOR=warn

# Shared by the sections below: a work repo with the cyclic fixture, and the mocks.
S3_WORK_REPO="$(setup_git_temp_repo fs-guard-shared)"
install_template_overlay "$S3_WORK_REPO" artifact-snapshot-coverage
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "cycled" "agent" 0 "" "builder" >/dev/null
S3_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# ── SPEC-3c: --from-stage with a leaf stage as target ─────────────────────────
# DSFSTG-1 Then clause: "when <s> is a leaf stage, a stage.start event is emitted for <s>".
# S3 and S5 both pass a cycle stage (cyc) to --from-stage; the leaf-stage branch of the
# Then clause is never exercised there. This sub-case uses resume-minimal
# (intake → build → test; all leaf stages) and targets build as <s>.
print_test_section "[#1805/DSFSTG-1] --from-stage with leaf <s>=build: stage.start emitted for leaf <s>"

# Given — a previous run completed intake (a leaf stage); its artifact is present in
#   the git state branch; a new invocation uses --from-stage build (also a leaf stage).
S6_ID="$(zb_test_issue)"
S6_STATE_DIR="$TEST_TEMP_DIR/s6-state"
S6_EVENTS_DIR="$TEST_TEMP_DIR/s6-events"
S6_EVENTS_JSONL="$S6_EVENTS_DIR/events.jsonl"
S6_STATE_FILE="$S6_STATE_DIR/pipeline-state.json"
mkdir -p "$S6_STATE_DIR/artifacts" "$S6_EVENTS_DIR"

S6_WORK_REPO="$(setup_git_temp_repo fs-rehydrate-s6)"
install_template_overlay "$S6_WORK_REPO" resume-minimal

# Add mock for test stage (intake and build mocks already exist in S3_PLUGINS_ROOT).
mock_plugin_factory "test" "agent" 0 >/dev/null

# Create intake primary artifact so the snapshot picks it up.
printf '{"result_contract":3,"outcome":"pass","reason":"prior-run-leaf-intake"}' \
    > "$S6_STATE_DIR/artifacts/intake-result.json"

# Snapshot onto the state branch.
_s6_snap_rc=0
( export ZBUILD_STATE_DIR="$S6_STATE_DIR"
  cd "$S6_WORK_REPO" && _artifact_persist_snapshot "$S6_STATE_DIR" "$S6_ID" ) \
    >"$TEST_TEMP_DIR/s6-snap.log" 2>&1 || _s6_snap_rc=$?
if [[ "$_s6_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSFSTG-1] setup s6: snapshot failed" \
        "rc=$_s6_snap_rc; $(cat "$TEST_TEMP_DIR/s6-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/DSFSTG-1] setup s6: state branch populated (leaf-stage --from-stage path)"
fi

# Remove from disk — the artifact lives only on the state branch.
rm -f "$S6_STATE_DIR/artifacts/intake-result.json"

# State: intake=complete, build=pending, test=pending.
jq -n \
    --arg run_id "s6-fs-leaf-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S6_ID" \
    '{
        schema_version: 1, run_id: $run_id, issue: $issue,
        stage_statuses: {intake: "complete", build: "pending", test: "pending"},
        current_iteration: 0, self_heal_count: {}, scope_manifest_hash: "",
        cost_ledger_pointer: 0, claim_lease_id: "", plugin_state: {},
        status: "in_progress", updated_at: $now
    }' > "$S6_STATE_FILE"

# When — the runner starts with --resume --from-stage build (a leaf stage, not a cycle stage).
set +e
( cd "$S6_WORK_REPO" && env \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S6_STATE_DIR" \
    ZBUILD_STATE_FILE="$S6_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S6_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S6_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template resume-minimal \
        --resume --from-stage build --issue "$S6_ID" ) \
    >"$TEST_TEMP_DIR/s6-stdout.txt" 2>"$TEST_TEMP_DIR/s6-stderr.txt"
_s6_rc=$?
set -e

# Then — when <s>=build is a leaf stage, a stage.start event is emitted for <s>.
# This covers the "when <s> is a leaf stage, a stage.start event is emitted for <s>"
# sub-clause of DSFSTG-1 (not covered by S3/S5 which only test cycle-stage targets).
# Before the change: no --from-stage leaf-stage support, or runner dispatches intake
#   first → no stage.start for build, OR intake dispatched before build → assertion fails.
# After the change: preflight rehydrates intake; build is dispatched as the first unit
#   → stage.start emitted for build (leaf stage) → PASSES.
_s6_build_starts=0
if [[ -f "$S6_EVENTS_JSONL" ]]; then
    _s6_build_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="build") | .type' \
        "$S6_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-1] stage.start emitted for leaf <s>=build (leaf-stage dispatch branch; covers DSFSTG-1 Then: when <s> is a leaf stage, stage.start is emitted for <s>)" \
    "$_s6_build_starts" "0"

# [#1805/DSFSTG-1]: no stage.start for intake (stage before leaf <s>=build).
# Before the change: intake dispatched → stage.start emitted for intake → count=1 → assert 0==1 → FAILS.
# After the change: intake is rehydrated (not dispatched) → no stage.start for intake → PASSES.
_s6_intake_starts=0
if [[ -f "$S6_EVENTS_JSONL" ]]; then
    _s6_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
        "$S6_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-1] no stage.start for intake when skipped via --from-stage leaf <s>=build" \
    "0" "$_s6_intake_starts"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "from-stage-rehydrate test uses a fixture containing a cyclic stage"

# Then — the test fixtures used by from-stage-rehydrate-test.sh contain a pipeline stage
#   of type: cycle, verified by an assert_contains tagged .
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
assert_contains "from-stage-rehydrate test uses a cyclic fixture (type: cycle)" \
    "$_s13_fs_content" "type: cycle"

# : confirm the cyclic pipeline ran (intake dispatched in the fresh run).
_s13_fs_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$_S13_FS_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "cyclic fixture pipeline ran in from-stage-rehydrate test (intake dispatched)" \
    "1" "$_s13_fs_intake_starts"

# ── SPEC-10: combined --resume --from-stage <s>: stages after <s> dispatched despite being marked complete ──
print_test_section "[#1805/DSFSTG-3] combined --resume --from-stage <s>: stages after <s> dispatched despite being marked complete in interrupted run"

# Given — a previous run was interrupted; stages before cyc (intake=complete) and
#   stages after cyc (verify=complete) are both marked complete in persisted state;
#   cyc (the target) is pending (the interrupted stage); the runner is invoked with
#   --resume --from-stage cyc (auto-resume active).
# This sub-case uses the from-stage-combined-resume fixture:
#   [intake (leaf), cyc (cycle with cycled), verify (leaf)].

S10_ID="$(zb_test_issue)"
S10_STATE_DIR="$TEST_TEMP_DIR/s10-state"
S10_EVENTS_DIR="$TEST_TEMP_DIR/s10-events"
S10_EVENTS_JSONL="$S10_EVENTS_DIR/events.jsonl"
S10_STATE_FILE="$S10_STATE_DIR/pipeline-state.json"
mkdir -p "$S10_STATE_DIR/artifacts" "$S10_EVENTS_DIR"

# Fresh git repo; _artifact_persist_snapshot writes the state branch here.
S10_WORK_REPO="$(setup_git_temp_repo fs-rehydrate-s10)"
# Protect fixture install: on before-code state from-stage-combined-resume may not
# exist. With the guard, the script continues; the runner won't run; events stay
# absent; the assert_gt assertions below FAIL naturally for the right reason.
_s10_tpl_rc=0
install_template_overlay "$S10_WORK_REPO" from-stage-combined-resume 2>/dev/null \
    || _s10_tpl_rc=$?

# Add mock for verify stage (intake and cycled mocks already in S3_PLUGINS_ROOT).
mock_plugin_factory "verify" "agent" 0 >/dev/null

# Create intake primary artifact so the --from-stage preflight can restore it.
printf '{"result_contract":3,"outcome":"pass","reason":"s10-intake-complete"}' \
    > "$S10_STATE_DIR/artifacts/intake-result.json"

# Snapshot onto the state branch (places intake artifact on git state branch).
_s10_snap_rc=0
( export ZBUILD_STATE_DIR="$S10_STATE_DIR"
  cd "$S10_WORK_REPO" && _artifact_persist_snapshot "$S10_STATE_DIR" "$S10_ID" ) \
    >"$TEST_TEMP_DIR/s10-snap.log" 2>&1 || _s10_snap_rc=$?
if [[ "$_s10_snap_rc" -ne 0 ]]; then
    assert_fail "[#1805/DSFSTG-3] setup s10: snapshot failed" \
        "rc=$_s10_snap_rc; $(cat "$TEST_TEMP_DIR/s10-snap.log" 2>/dev/null | tail -5)"
else
    assert_pass "[#1805/DSFSTG-3] setup s10: state branch populated (all-complete interrupted run)"
fi

# Remove from disk — the artifact lives only on the state branch.
rm -f "$S10_STATE_DIR/artifacts/intake-result.json"

# State: intake=complete (before <s>), cyc=pending (<s>, the interrupted stage),
# verify=complete (after <s>). status=in_progress; --resume flag passed explicitly.
jq -n \
    --arg run_id "s10-combined-resume-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S10_ID" \
    '{
        schema_version: 1,
        run_id: $run_id,
        issue: $issue,
        stage_statuses: {intake: "complete", cyc: "pending", verify: "complete"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "in_progress",
        updated_at: $now
    }' > "$S10_STATE_FILE"

# When — the runner is invoked with --resume --from-stage cyc.
# This exercises the combined path where skip_until_stage="cyc" is set,
# cleared when cyc is reached, and resume_mode must be cleared too (Gap 11 fix)
# so the skip guard does not suppress verify despite verify=complete in state.
set +e
( cd "$S10_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S10_STATE_DIR" \
    ZBUILD_STATE_FILE="$S10_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S10_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S10_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template from-stage-combined-resume \
        --resume --from-stage cyc --issue "$S10_ID" ) \
    >"$TEST_TEMP_DIR/s10-stdout.txt" 2>"$TEST_TEMP_DIR/s10-stderr.txt"
_s10_rc=$?
set -e

# Then — cycle.start for cyc is emitted (cyc was dispatched as the --from-stage target).
# Before the change: on old code, --from-stage may not exist or the cycle dispatch
#   path may be incomplete → cycle.start absent → assertion FAILS.
# After the change: skip_until_stage cleared at cyc → cyc dispatched → cycle.start → PASSES.
_s10_cyc_starts=0
if [[ -f "$S10_EVENTS_JSONL" ]]; then
    _s10_cyc_starts="$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="cyc") | .type' \
        "$S10_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-3] cycle.start emitted for cyc (--from-stage target dispatched in combined --resume --from-stage mode)" \
    "$_s10_cyc_starts" "0"

# Then — stage.start for verify is emitted despite verify=complete in interrupted run state.
# This is the Gap 11 assertion: on old code, skip_until_stage is cleared at cyc but
# resume_mode remains true, so the resume skip guard fires for verify (complete) and
# verify is SKIPPED → no stage.start → assertion FAILS on old code.
# After the Gap 11 fix: resume_mode is set to false when skip_until_stage is cleared
# at cyc → skip guard does not fire → verify dispatched → stage.start → PASSES.
_s10_verify_starts=0
if [[ -f "$S10_EVENTS_JSONL" ]]; then
    _s10_verify_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="verify") | .type' \
        "$S10_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_gt "[#1805/DSFSTG-3] stage.start emitted for verify despite verify=complete in interrupted state (Gap 11 fix: resume_mode=false clears skip guard after --from-stage target reached; fails on old code where verify is skipped)" \
    "$_s10_verify_starts" "0"

# Then — no stage.skip event emitted for verify (verify is dispatched, not skipped).
# Before the change: verify is skipped → stage.skip might be emitted → verify_skips > 0.
# After the change: resume_mode=false → no skip guard → no stage.skip for verify → PASSES.
_s10_verify_skips=0
if [[ -f "$S10_EVENTS_JSONL" ]]; then
    _s10_verify_skips="$(jq -r 'select(.type=="stage.skip" and .data.stage=="verify") | .type' \
        "$S10_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-3] no stage.skip emitted for verify (stage after --from-stage target must be dispatched, not skipped, in combined --resume --from-stage mode)" \
    "0" "$_s10_verify_skips"

# ── SPEC-4: --from-stage without --resume refuses with diagnostic ─────────────
# [#1805/DSFSTG-4]: --from-stage <s> without explicit --resume exits 1 with the
#   diagnostic "--from-stage is only valid with --resume", even when auto-resume
#   conditions are present (status=interrupted). The guard fires before auto-resume
#   processes state, so no pipeline.resume event is emitted.
print_test_section "[#1805/DSFSTG-4] --from-stage without --resume refuses before auto-resume"

# Given — a state file exists with status=interrupted (auto-resume conditions met);
#   --from-stage is specified on the command line; --resume is NOT given.
S11_ID="$(zb_test_issue)"
S11_STATE_DIR="$TEST_TEMP_DIR/s11-state"
S11_EVENTS_DIR="$TEST_TEMP_DIR/s11-events"
S11_EVENTS_JSONL="$S11_EVENTS_DIR/events.jsonl"
S11_STATE_FILE="$S11_STATE_DIR/pipeline-state.json"
mkdir -p "$S11_STATE_DIR/artifacts" "$S11_EVENTS_DIR"

# State with status=interrupted so auto-resume would otherwise kick in.
jq -n \
    --arg run_id "s11-fs4-1805" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S11_ID" \
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
    }' > "$S11_STATE_FILE"

# Reuse S3_WORK_REPO (artifact-snapshot-coverage template, which has the cyc
# stage). S3_PLUGINS_ROOT is also reused (intake, build, cycled mocks present).

# When — the runner is invoked with --from-stage but no --resume.
set +e
( cd "$S3_WORK_REPO" && env \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$S11_STATE_DIR" \
    ZBUILD_STATE_FILE="$S11_STATE_FILE" \
    ZBUILD_EVENTS_DIR="$S11_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S11_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --from-stage cyc --issue "$S11_ID" ) \
    >"$TEST_TEMP_DIR/s11-stdout.txt" 2>"$TEST_TEMP_DIR/s11-stderr.txt"
_s11_rc=$?
set -e

# Then — the runner exits 1.
# Before change: guard absent → runner auto-resumes (exits 0) or fails for a
#   different reason → exit code != 1 → assertion FAILS.
# After change: guard fires → runner exits 1 → PASSES.
assert_eq "[#1805/DSFSTG-4] --from-stage without --resume exits 1" \
    "1" "$_s11_rc"

# Then — stderr contains the diagnostic "--from-stage is only valid with --resume".
# Before change: guard absent → diagnostic not emitted → FAILS.
# After change: guard emits diagnostic → PASSES.
_s11_stderr="$(cat "$TEST_TEMP_DIR/s11-stderr.txt" 2>/dev/null || true)"
assert_contains \
    "[#1805/DSFSTG-4] stderr contains --from-stage is only valid with --resume" \
    "$_s11_stderr" "--from-stage is only valid with --resume"

# Then — no pipeline.resume event is emitted (guard fires before auto-resume processes
#   state, so auto-resume never runs).
# Before change: auto-resume runs → pipeline.resume emitted → count > 0 → FAILS.
# After change: guard fires before auto-resume → no pipeline.resume → PASSES.
_s11_resume_events=0
if [[ -f "$S11_EVENTS_JSONL" ]]; then
    _s11_resume_events="$(jq -r 'select(.type=="pipeline.resume") | .type' \
        "$S11_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-4] no pipeline.resume event emitted (guard fires before auto-resume)" \
    "0" "$_s11_resume_events"

# ── SPEC-4b: --from-stage without --resume refuses even via latest-symlink auto-resume path ──
# [#1805/DSFSTG-4]: when state lives under runs/<run_id>/ and is found via the
#   $ZBUILD_STATE_ROOT/latest symlink (the DSENTR-2 auto-resume path), the guard
#   "--from-stage is only valid with --resume" must still fire when --resume is not
#   given. ZBUILD_STATE_FILE and ZBUILD_STATE_DIR must be unset so the auto-resume
#   symlink guard `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` can fire.
print_test_section "[#1805/DSFSTG-4] --from-stage without --resume refuses via latest-symlink auto-resume path"

# Given — a state file at $ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json with
#   status=interrupted (auto-resume conditions met via latest symlink); --from-stage is
#   specified on the command line; --resume is NOT given; ZBUILD_STATE_FILE and
#   ZBUILD_STATE_DIR are absent from the environment.
S12_ID="$(zb_test_issue)"
S12_RUN_ID="s12-fs4-symlink-1805"
S12_STATE_ROOT="$TEST_TEMP_DIR/s12-state-root"
S12_RUN_DIR="$S12_STATE_ROOT/runs/$S12_RUN_ID"
S12_EVENTS_DIR="$TEST_TEMP_DIR/s12-events"
S12_EVENTS_JSONL="$S12_EVENTS_DIR/events.jsonl"
mkdir -p "$S12_RUN_DIR/artifacts" "$S12_EVENTS_DIR"

# State with status=interrupted so auto-resume would fire via latest symlink.
jq -n \
    --arg run_id "$S12_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson issue "$S12_ID" \
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
    }' > "$S12_RUN_DIR/pipeline-state.json"

# Create the latest symlink pointing to the per-run state dir.
ln -sfn "$S12_RUN_DIR" "$S12_STATE_ROOT/latest"

# When — the runner is invoked with --from-stage but no --resume;
#   ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are explicitly removed from the
#   environment so the auto-resume symlink guard can fire (without these unset,
#   the guard's first condition `-z "${ZBUILD_STATE_FILE:-}"` would not hold).
set +e
( cd "$S3_WORK_REPO" && env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR \
    ZBUILD_CYCLES_ENABLED=1 \
    ZBUILD_PLUGINS_ROOT="$S3_PLUGINS_ROOT" \
    ZBUILD_STATE_ROOT="$S12_STATE_ROOT" \
    ZBUILD_EVENTS_DIR="$S12_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$S12_EVENTS_JSONL" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template artifact-snapshot-coverage \
        --from-stage cyc --issue "$S12_ID" ) \
    >"$TEST_TEMP_DIR/s12-stdout.txt" 2>"$TEST_TEMP_DIR/s12-stderr.txt"
_s12_rc=$?
set -e

# Then — the runner exits 1 (guard fires before auto-resume runs).
# Before change (new branch): guard fires only when flat state file exists; via
#   the latest-symlink path the flat state file is absent → guard skipped →
#   auto-resume fires → runner runs (exit 0 or non-1) → assertion FAILS.
# After change (guard covers symlink path too): exit 1 → PASSES.
assert_eq "[#1805/DSFSTG-4] --from-stage without --resume exits 1 even via latest-symlink auto-resume path" \
    "1" "$_s12_rc"

# Then — stderr contains the diagnostic "--from-stage is only valid with --resume".
# Before change: guard not reached → diagnostic not emitted → FAILS.
# After change: guard fires → diagnostic emitted → PASSES.
_s12_stderr="$(cat "$TEST_TEMP_DIR/s12-stderr.txt" 2>/dev/null || true)"
assert_contains \
    "[#1805/DSFSTG-4] stderr contains --from-stage is only valid with --resume (latest-symlink path)" \
    "$_s12_stderr" "--from-stage is only valid with --resume"

# Then — no pipeline.resume event is emitted (guard fires before auto-resume processes
#   state via the latest symlink, so auto-resume never runs).
# Before change: auto-resume fires via symlink → pipeline.resume emitted → count > 0 → FAILS.
# After change: guard fires before symlink-based auto-resume → no pipeline.resume → PASSES.
_s12_resume_events=0
if [[ -f "$S12_EVENTS_JSONL" ]]; then
    _s12_resume_events="$(jq -r 'select(.type=="pipeline.resume") | .type' \
        "$S12_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[#1805/DSFSTG-4] no pipeline.resume event emitted (guard fires before symlink-based auto-resume)" \
    "0" "$_s12_resume_events"

print_test_results
cleanup_test_env
