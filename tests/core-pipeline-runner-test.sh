#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — pipeline orchestrator behaviors
# ADR-001 (plugin contract), ADR-006 (resume contract)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — orchestrator behaviors (ADR-001, ADR-006)"
setup_test_env "pipeline-runner"

# ─── Fixtures: fake plugin factory ──────────────────────────────────────────

_make_plugin() {
    local id="$1" kind="${2:-agent}" exit_code="${3:-0}"
    local dir="$TEST_TEMP_DIR/plugins/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() { return $exit_code; }
EOF
}

# Shared env: point all subsystems at the test temp dir.
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# Build the three MVP stage plugins (all succeed by default).
_make_plugin "intake"        "agent" 0
_make_plugin "security-lens" "agent" 0
_make_plugin "output"        "tool"  0

# ─── Test 1: no args → exits 2 ──────────────────────────────────────────────
set +e
bash "$RUNNER" 2>/dev/null
rc=$?
set -e
assert_eq "no args exits 2" "2" "$rc"

# ─── Test 2: --help → exits 0 ────────────────────────────────────────────────
set +e
bash "$RUNNER" --help >/dev/null 2>&1
rc=$?
set -e
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: dry-run prints 3-stage plan without executing ──────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
out="$(bash "$RUNNER" --issue 83 --dry-run 2>&1)"
assert_contains "dry-run shows intake stage" "$out" "intake"
assert_contains "dry-run shows security-lens stage" "$out" "security-lens"
assert_contains "dry-run shows output stage" "$out" "output"
assert_file_not_exists "dry-run leaves state file untouched" "$STATE_DIR/pipeline-state.json"

# ─── Test 4: happy path → exits 0, emits pipeline.start + pipeline.end ──────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
bash "$RUNNER" --issue 83 2>/dev/null
rc=$?
set -e
assert_eq "happy path exits 0" "0" "$rc"
assert_file_exists "events.jsonl created" "$EVENTS_JSONL"

start_count=$(grep -c '"pipeline.start"' "$EVENTS_JSONL" || true)
assert_eq "pipeline.start emitted once" "1" "$start_count"

end_count=$(grep -c '"pipeline.end"' "$EVENTS_JSONL" || true)
assert_eq "pipeline.end emitted once" "1" "$end_count"

success_in_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"success"' || true)
assert_eq "pipeline.end carries status=success" "1" "$success_in_end"

# ─── Test 5: state file has correct stage_statuses after happy path ──────────
STATE_FILE="$STATE_DIR/pipeline-state.json"
assert_file_exists "state file created" "$STATE_FILE"

intake_status="$(jq -r '.stage_statuses.intake // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "intake stage_status=success" "success" "$intake_status"

sl_status="$(jq -r '.stage_statuses["security-lens"] // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "security-lens stage_status=success" "success" "$sl_status"

output_status="$(jq -r '.stage_statuses.output // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "output stage_status=success" "success" "$output_status"

# ─── Test 6: mid-stage failure → exits 1, pipeline.end status=failed ─────────
_make_plugin "security-lens" "agent" 1
rm -f "$EVENTS_JSONL" "$STATE_FILE"

set +e
bash "$RUNNER" --issue 83 2>/dev/null
rc=$?
set -e
assert_eq "mid-stage failure exits 1" "1" "$rc"
assert_file_exists "events.jsonl present on failure" "$EVENTS_JSONL"

failed_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"failed"' || true)
assert_eq "pipeline.end status=failed emitted" "1" "$failed_end"

stage_in_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"security-lens"' || true)
assert_eq "pipeline.end names the failing stage" "1" "$stage_in_end"

sl_fail_status="$(jq -r '.stage_statuses["security-lens"] // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "security-lens stage_status=failed in state" "failed" "$sl_fail_status"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
