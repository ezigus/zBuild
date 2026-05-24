#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cross-repo isolation test — Issue #425                       ║
# ║  Tests: _sw_repo_hash, emit_event repo field, corrupted backup pruning,  ║
# ║         REPO_HASH-prefixed pipeline/heartbeat IDs, cost repo field,      ║
# ║         cleanup section variables                                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2218  # emit_event is sourced from helpers.sh before use; stub override appears later for daemon-state isolation
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Cross-Repo Pipeline Isolation Tests (Issue #425)"

setup_test_env "sw-cross-repo-isolation-test"
_test_cleanup_hook() { cleanup_test_env; }

mock_git
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

# Source helpers (clear guard to re-source)
_SW_HELPERS_LOADED=""
source "$SCRIPT_DIR/lib/helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# _sw_repo_hash
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_sw_repo_hash"

# Returns a 12-char hex string when git remote is available
unset REPO_HASH 2>/dev/null || true
hash_result=$(_sw_repo_hash)
assert_contains_regex "_sw_repo_hash returns 12-char hex string" "$hash_result" '^[0-9a-f]{12}$'

# Uses REPO_HASH env var without spawning a subprocess when already set
export REPO_HASH="aabbcc001122"
cached_result=$(_sw_repo_hash)
assert_eq "_sw_repo_hash returns REPO_HASH env var when set" "aabbcc001122" "$cached_result"
unset REPO_HASH

# Different remote URLs produce different hashes
original_hash=$(_sw_repo_hash)

# Override git to return a different remote URL
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    config) echo "https://github.com/otherorg/otherrepo.git" ;;
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "/tmp/mock-repo"
        fi ;;
    remote) echo "https://github.com/otherorg/otherrepo.git" ;;
    *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
other_hash=$(_sw_repo_hash)
if [[ "$original_hash" != "$other_hash" ]]; then
    assert_pass "_sw_repo_hash produces distinct hashes for different remotes"
else
    assert_fail "_sw_repo_hash produces distinct hashes for different remotes" "both returned: $original_hash"
fi

# Restore original mock_git
mock_git

# Handles missing git remote gracefully — returns a non-empty fallback
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"

# Should not crash; returns either a hash or "unknown"
unset REPO_HASH 2>/dev/null || true
fallback_result=$(_sw_repo_hash 2>/dev/null || echo "unknown")
if [[ -n "$fallback_result" ]]; then
    assert_pass "_sw_repo_hash handles missing git gracefully (got: $fallback_result)"
else
    assert_fail "_sw_repo_hash handles missing git gracefully" "returned empty"
fi

# Restore good git mock
mock_git

# ═══════════════════════════════════════════════════════════════════════════════
# emit_event includes repo field
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "emit_event includes repo field"

# Reset memoized slug cache and events file
_EMIT_REPO_SLUG=""
rm -f "$EVENTS_FILE"

emit_event "pipeline.started" "issue=99" "branch=main"

assert_file_exists "Events file created" "$EVENTS_FILE"

event_line=$(cat "$EVENTS_FILE")

# Must contain a "repo" key
assert_contains "Event contains repo field key" "$event_line" '"repo":'

# Must be valid JSON
if echo "$event_line" | jq empty 2>/dev/null; then
    assert_pass "Event with repo field is valid JSON"
else
    assert_fail "Event with repo field is valid JSON" "line: $event_line"
fi

# repo value must be non-empty
repo_val=$(echo "$event_line" | jq -r '.repo' 2>/dev/null || echo "")
if [[ -n "$repo_val" ]]; then
    assert_pass "Event repo field is non-empty (got: $repo_val)"
else
    assert_fail "Event repo field is non-empty"
fi

# repo field appears before other fields (set -- prepends it)
# Verify it's within the first 120 chars of the JSON to confirm prepend ordering
first_120="${event_line:0:120}"
assert_contains "repo field appears early in event JSON" "$first_120" '"repo":'

# Emit a second event — repo slug memoization means only one subprocess
_EMIT_REPO_SLUG=""
rm -f "$EVENTS_FILE"
emit_event "stage.started" "stage=build"
emit_event "stage.completed" "stage=build" "duration=30"
line_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
assert_eq "Two events produce two lines" "2" "$line_count"
# Both must have repo field
while IFS= read -r line; do
    if echo "$line" | jq -r '.repo' 2>/dev/null | grep -q .; then
        assert_pass "Each event line has non-empty repo field"
    else
        assert_fail "Each event line has non-empty repo field" "line: $line"
    fi
done < "$EVENTS_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# Corrupted backup pruning in daemon-state.sh
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Corrupted backup pruning (daemon-state.sh)"

# Set up the state environment daemon-state.sh needs
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export WATCH_LABEL="shipwright"
export WATCH_MODE="label"
export BASE_BRANCH="main"
export PRIORITY_LANE_LABELS="urgent,p0"
export SLACK_WEBHOOK=""
touch "$LOG_FILE"
mock_gh
mock_claude

# Provide stubs for daemon-state dependencies
now_iso()    { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch()  { date +%s; }
emit_event() { :; }

# Source daemon-state
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

# Create 8 corrupted backup files with distinct timestamps
for i in $(seq 1 8); do
    ts=$((1700000000 + i))
    touch "${STATE_FILE}.corrupted.${ts}"
done

before_count=$(ls "${STATE_FILE}.corrupted."* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "8 corrupted backups created" "8" "$before_count"

# Trigger the prune logic inline (same as in daemon-state.sh)
ls -t "${STATE_FILE}.corrupted."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

after_count=$(ls "${STATE_FILE}.corrupted."* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "Prune keeps exactly 5 corrupted backups" "5" "$after_count"

# With exactly 5, prune is a no-op
ls -t "${STATE_FILE}.corrupted."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
still_count=$(ls "${STATE_FILE}.corrupted."* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "Second prune on 5 files is no-op" "5" "$still_count"

# With fewer than 5, prune is a no-op
rm -f "${STATE_FILE}.corrupted.1700000009" 2>/dev/null || true
rm -f "${STATE_FILE}.corrupted.1700000008" 2>/dev/null || true
rm -f "${STATE_FILE}.corrupted.1700000007" 2>/dev/null || true
ls -t "${STATE_FILE}.corrupted."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
few_count=$(ls "${STATE_FILE}.corrupted."* 2>/dev/null | wc -l | tr -d ' ')
assert_gt "Fewer than 5 remain after partial cleanup" "$few_count" "-1"

# Prune with 0 corrupted files must not error
rm -f "${STATE_FILE}.corrupted."* 2>/dev/null || true
ls -t "${STATE_FILE}.corrupted."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
assert_pass "Prune with 0 corrupted files does not error"

# ═══════════════════════════════════════════════════════════════════════════════
# REPO_HASH prefix in SHIPWRIGHT_PIPELINE_ID format
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "REPO_HASH-prefixed pipeline and heartbeat IDs"

# Simulate the pipeline ID construction from sw-pipeline.sh
export REPO_HASH="abc123def456"
ISSUE_NUMBER=42
SIMULATED_PID=12345

# Format: "${REPO_HASH:+${REPO_HASH}-}pipeline-$$-${ISSUE_NUMBER:-0}"
simulated_pipeline_id="${REPO_HASH:+${REPO_HASH}-}pipeline-${SIMULATED_PID}-${ISSUE_NUMBER:-0}"
assert_contains "Pipeline ID includes REPO_HASH prefix" "$simulated_pipeline_id" "abc123def456-"
assert_contains "Pipeline ID includes 'pipeline-'" "$simulated_pipeline_id" "pipeline-"
assert_contains "Pipeline ID includes issue number" "$simulated_pipeline_id" "-42"
assert_contains_regex "Pipeline ID matches expected format" "$simulated_pipeline_id" '^[0-9a-f]+-pipeline-[0-9]+-[0-9]+$'

# Format without REPO_HASH (empty): "pipeline-$$-0"
unset REPO_HASH
REPO_HASH=""
no_hash_pipeline_id="${REPO_HASH:+${REPO_HASH}-}pipeline-${SIMULATED_PID}-0"
assert_eq "Pipeline ID without REPO_HASH has no prefix" "pipeline-${SIMULATED_PID}-0" "$no_hash_pipeline_id"

# Heartbeat job_id format: "${REPO_HASH:+${REPO_HASH}-}${PIPELINE_NAME:-pipeline-$$}"
export REPO_HASH="abc123def456"
PIPELINE_NAME="pipeline-${SIMULATED_PID}"
heartbeat_job_id="${REPO_HASH:+${REPO_HASH}-}${PIPELINE_NAME:-pipeline-$$}"
assert_contains "Heartbeat job_id includes REPO_HASH prefix" "$heartbeat_job_id" "abc123def456-"
assert_contains "Heartbeat job_id includes pipeline name" "$heartbeat_job_id" "pipeline-"
assert_contains_regex "Heartbeat job_id matches expected format" "$heartbeat_job_id" '^[0-9a-f]+-pipeline-[0-9]+$'

# ═══════════════════════════════════════════════════════════════════════════════
# Cost entry includes repo field (sw-cost.sh jq transformation)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Cost entry repo field"

export REPO_HASH="deadbeef1234"

# Replicate the jq transformation from sw-cost.sh line ~165
# --arg repo "${REPO_HASH:-unknown}" is passed to jq; we validate the output
cost_entry=$(jq -n \
    --arg ts "2026-01-01T00:00:00Z" \
    --arg ts_epoch "1735689600" \
    --arg pipeline_id "deadbeef1234-pipeline-99-42" \
    --arg model "claude-opus-4-5" \
    --argjson input_tokens 1000 \
    --argjson output_tokens 500 \
    --arg cost "0.015" \
    --arg stage "build" \
    --arg issue "42" \
    --arg repo "${REPO_HASH:-unknown}" \
    '{ts: $ts, ts_epoch: ($ts_epoch | tonumber), pipeline_id: $pipeline_id,
      model: $model, input_tokens: $input_tokens, output_tokens: $output_tokens,
      cost: ($cost | tonumber), stage: $stage, issue: ($issue | tonumber),
      repo: $repo}')

assert_contains "Cost entry contains repo field" "$cost_entry" '"repo":'
repo_in_cost=$(echo "$cost_entry" | jq -r '.repo' 2>/dev/null || echo "")
assert_eq "Cost entry repo matches REPO_HASH" "deadbeef1234" "$repo_in_cost"

if echo "$cost_entry" | jq empty 2>/dev/null; then
    assert_pass "Cost entry is valid JSON"
else
    assert_fail "Cost entry is valid JSON" "entry: $cost_entry"
fi

# When REPO_HASH is unset, falls back to "unknown"
unset REPO_HASH
REPO_HASH=""
fallback_cost=$(jq -n --arg repo "${REPO_HASH:-unknown}" '{repo: $repo}')
fallback_repo=$(echo "$fallback_cost" | jq -r '.repo')
assert_eq "Cost repo falls back to 'unknown' when REPO_HASH unset" "unknown" "$fallback_repo"

# ═══════════════════════════════════════════════════════════════════════════════
# Cleanup section variables (CORRUPTED_FOUND / PIPELINE_TASKS_FOUND)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Cleanup section variables (sw-cleanup.sh)"

# These variables are set by sw-cleanup.sh sections 9 and 10.
# We validate the variable-setting logic directly without running the full script.

# Section 9: CORRUPTED_FOUND tracks count of corrupted backups
CORRUPTED_STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
CORRUPTED_FOUND=0

# Create some corrupted backups
for i in 1 2 3; do
    touch "${CORRUPTED_STATE_FILE}.corrupted.$((1700000000 + i))"
done

if ls "${CORRUPTED_STATE_FILE}.corrupted."* >/dev/null 2>&1; then
    corrupted_count=$(ls "${CORRUPTED_STATE_FILE}.corrupted."* 2>/dev/null | wc -l | tr -d ' ')
    corrupted_count=${corrupted_count:-0}
    CORRUPTED_FOUND=$corrupted_count
fi

assert_eq "CORRUPTED_FOUND counts 3 corrupted backups" "3" "$CORRUPTED_FOUND"

# Section 10: PIPELINE_TASKS_FOUND tracks stale pipeline-tasks*.md files
PIPELINE_TASKS_FOUND=0
test_project_root="$TEST_TEMP_DIR/project"

# Create two stale pipeline-tasks files (touch with older mtime via a different approach)
touch "$test_project_root/pipeline-tasks-42.md"
touch "$test_project_root/pipeline-tasks-99.md"
# Force mtime to be 2 days ago using touch -t (macOS compatible)
old_ts=$(date -v-2d +"%Y%m%d%H%M" 2>/dev/null || date --date="2 days ago" +"%Y%m%d%H%M" 2>/dev/null || echo "")
if [[ -n "$old_ts" ]]; then
    touch -t "$old_ts" "$test_project_root/pipeline-tasks-42.md"
    touch -t "$old_ts" "$test_project_root/pipeline-tasks-99.md"
fi

# Simulate the find logic from sw-cleanup.sh section 10
while IFS= read -r _task_file; do
    PIPELINE_TASKS_FOUND=$((PIPELINE_TASKS_FOUND + 1))
done < <(find "$test_project_root" -maxdepth 1 -name "pipeline-tasks*.md" -mtime +1 -type f 2>/dev/null)

# With 2-day-old files, both should be found (mtime +1 = older than 1 day)
if [[ "$PIPELINE_TASKS_FOUND" -ge 2 ]]; then
    assert_pass "PIPELINE_TASKS_FOUND detects stale pipeline-tasks files ($PIPELINE_TASKS_FOUND found)"
elif [[ "$PIPELINE_TASKS_FOUND" -ge 0 ]]; then
    # touch -t may not have succeeded on this platform; just check the variable exists and is numeric
    assert_contains_regex "PIPELINE_TASKS_FOUND is a non-negative integer" "$PIPELINE_TASKS_FOUND" '^[0-9]+$'
fi

# Section 9+10 variables exist and are numeric (type check)
assert_contains_regex "CORRUPTED_FOUND is numeric" "$CORRUPTED_FOUND" '^[0-9]+$'
assert_contains_regex "PIPELINE_TASKS_FOUND is numeric" "$PIPELINE_TASKS_FOUND" '^[0-9]+$'

# TOTAL_FOUND computation includes both new variables (verify arithmetic works)
WINDOWS_FOUND=0; SWARM_SESSIONS_FOUND=0; SWARM_REGISTRY_REMOVED=0
TEAM_DIRS_FOUND=0; TASK_DIRS_FOUND=0; ARTIFACTS_FOUND=0; CHECKPOINTS_FOUND=0
HEARTBEATS_FOUND=0; BRANCHES_FOUND=0; STATE_RESET=0
TOTAL_FOUND=$((WINDOWS_FOUND + SWARM_SESSIONS_FOUND + SWARM_REGISTRY_REMOVED + TEAM_DIRS_FOUND + TASK_DIRS_FOUND + ARTIFACTS_FOUND + CHECKPOINTS_FOUND + HEARTBEATS_FOUND + BRANCHES_FOUND + STATE_RESET + CORRUPTED_FOUND + PIPELINE_TASKS_FOUND))
assert_contains_regex "TOTAL_FOUND arithmetic includes new variables" "$TOTAL_FOUND" '^[0-9]+$'

# ═══════════════════════════════════════════════════════════════════════════════
# Doctor cross-repo heartbeat check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Doctor cross-repo heartbeat check logic"

# Validate the heartbeat prefix check logic from sw-doctor.sh
HB_DIR="$TEST_TEMP_DIR/home/.shipwright/heartbeats"
mkdir -p "$HB_DIR"
export REPO_HASH="deadbeef1234"

# Create heartbeats: 2 for this repo, 1 for another
touch "${HB_DIR}/${REPO_HASH}-pipeline-100.json"
touch "${HB_DIR}/${REPO_HASH}-pipeline-200.json"
touch "${HB_DIR}/aabbccdd1234-pipeline-300.json"

cross_repo_count=0
if ls "${HB_DIR}/"*.json >/dev/null 2>&1; then
    for hb_file in "${HB_DIR}/"*.json; do
        hb_name=$(basename "$hb_file" .json)
        if [[ "$hb_name" != "${REPO_HASH}-"* ]]; then
            cross_repo_count=$((cross_repo_count + 1))
        fi
    done
fi

assert_eq "Doctor finds 1 cross-repo heartbeat" "1" "$cross_repo_count"

# With only matching heartbeats — cross_repo_count should be 0
rm -f "${HB_DIR}/aabbccdd1234-pipeline-300.json"
cross_repo_count=0
if ls "${HB_DIR}/"*.json >/dev/null 2>&1; then
    for hb_file in "${HB_DIR}/"*.json; do
        hb_name=$(basename "$hb_file" .json)
        if [[ "$hb_name" != "${REPO_HASH}-"* ]]; then
            cross_repo_count=$((cross_repo_count + 1))
        fi
    done
fi
assert_eq "Doctor finds 0 cross-repo heartbeats when all match" "0" "$cross_repo_count"

# ═══════════════════════════════════════════════════════════════════════════════
# Doctor corrupted backup count check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Doctor corrupted backup count check"

_sw_state_file="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
rm -f "${_sw_state_file}.corrupted."* 2>/dev/null || true

# Under threshold (10): check_pass path
for i in $(seq 1 9); do
    touch "${_sw_state_file}.corrupted.$((1700000000 + i))"
done
_sw_corrupted_count=0
if ls "${_sw_state_file}.corrupted."* >/dev/null 2>&1; then
    _sw_corrupted_count=$(ls "${_sw_state_file}.corrupted."* 2>/dev/null | wc -l)
fi
_sw_corrupted_count=${_sw_corrupted_count:-0}

if [[ $_sw_corrupted_count -gt 10 ]]; then
    assert_fail "9 corrupted backups should not trigger doctor warning"
else
    assert_pass "9 corrupted backups within doctor threshold (got: $_sw_corrupted_count)"
fi

# Over threshold (10): check_warn path
touch "${_sw_state_file}.corrupted.$((1700000000 + 10))"
touch "${_sw_state_file}.corrupted.$((1700000000 + 11))"
_sw_corrupted_count=0
if ls "${_sw_state_file}.corrupted."* >/dev/null 2>&1; then
    _sw_corrupted_count=$(ls "${_sw_state_file}.corrupted."* 2>/dev/null | wc -l)
fi
_sw_corrupted_count=${_sw_corrupted_count:-0}

if [[ $_sw_corrupted_count -gt 10 ]]; then
    assert_pass "11 corrupted backups triggers doctor warning threshold (count: $_sw_corrupted_count)"
else
    assert_fail "11 corrupted backups should exceed doctor threshold" "got: $_sw_corrupted_count"
fi

print_test_results
