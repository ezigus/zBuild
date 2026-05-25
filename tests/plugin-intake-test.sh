#!/usr/bin/env bash
# Tests: plugins/agent/intake — goal capture, sentinel sanitization, scope manifest (issue #85)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake (goal capture + scope manifest — issue #85)"

setup_test_env "plugin-intake"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/intake"

# ─── Fake state file (intake reads dirname to find platforms.json) ────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"0","stage_statuses":{}}' > "$STATE_FILE"

# ─── Test 1: manifest validates + plugin is discoverable ─────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "intake manifest validates" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "intake discovered in plugin registry" "$discovered" "agent/intake"

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../plugins/agent/intake/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
intake_init >/dev/null 2>&1

# ─── Test 2: ZBUILD_GOAL unset → rc=2 ────────────────────────────────────────
unset ZBUILD_GOAL 2>/dev/null || true

set +e
err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "unset ZBUILD_GOAL returns rc=2" "2" "$rc"
assert_contains "stderr mentions ZBUILD_GOAL" "$err" "ZBUILD_GOAL"

# ─── Test 3: goal written to state/intake.md ─────────────────────────────────
export ZBUILD_GOAL="fix auth bug"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "valid run returns rc=0" "0" "$rc"
assert_file_exists "state/intake.md created" "$STATE_DIR/intake.md"
assert_contains "intake.md contains sanitized goal" "$(cat "$STATE_DIR/intake.md")" "fix auth bug"

# ─── Test 4: synthesized sentinel stripped from goal ─────────────────────────
export ZBUILD_GOAL="$(printf 'fix the login flow\n\n## Plan Summary\nsome noise')"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "sentinel-strip run returns rc=0" "0" "$rc"
intake_content="$(cat "$STATE_DIR/intake.md")"
assert_contains "intake.md has original prefix" "$intake_content" "fix the login flow"
if echo "$intake_content" | grep -q "Plan Summary"; then
    assert_fail "sentinel ## Plan Summary should be stripped from intake.md"
else
    assert_pass "sentinel ## Plan Summary stripped from intake.md"
fi

# ─── Test 5: platforms.json drives scope-manifest lines ──────────────────────
cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","node"],"repo_head_sha":"abc123"}
JSON

export ZBUILD_GOAL="add feature"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "platform-aware run returns rc=0" "0" "$rc"
assert_file_exists "scope-manifest.md created" "$STATE_DIR/scope-manifest.md"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "scope-manifest has + ios/" "$scope" "+ ios/"
assert_contains "scope-manifest has + node/" "$scope" "+ node/"

# ─── Test 6: no platforms.json → generic fallback (+ ./) ─────────────────────
rm -f "$STATE_DIR/platforms.json"

export ZBUILD_GOAL="fix something"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "generic fallback run returns rc=0" "0" "$rc"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "generic fallback writes + ./" "$scope" "+ ./"

# ─── Test 7: plugin.run.complete event emitted ───────────────────────────────
run_complete_count=$(grep -c '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "plugin.run.complete event emitted" "$run_complete_count" "0"

plugin_field="$(grep '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.complete") | .data.plugin // empty' 2>/dev/null | tail -1 || true)"
assert_eq "plugin.run.complete has plugin=intake" "intake" "$plugin_field"

# ─── Test 8: plugin.finalize.complete event after finalize ───────────────────
intake_finalize >/dev/null 2>&1

finalize_count=$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "plugin.finalize.complete event emitted" "$finalize_count" "0"

# ─── Test 9: empty ZBUILD_GOAL → rc=2 ────────────────────────────────────────
export ZBUILD_GOAL=""

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "empty ZBUILD_GOAL returns rc=2" "2" "$rc"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
