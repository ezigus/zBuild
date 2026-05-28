#!/usr/bin/env bash
# Tests: core/event-bus/event-bus.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/event-bus — single-writer + schema-as-warn"

setup_test_env "core-events"

# Point the event bus at the test temp dir
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# ─── Basic emit ─────────────────────────────────────────────────────────────
eb_emit_event "pipeline.start" "issue=42" "template=full"
assert_file_exists "JSONL created" "$ZBUILD_EVENTS_JSONL"

# Verify last line parses as JSON
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
type_field="$(echo "$last" | jq -r .type)"
assert_eq "event has type=pipeline.start" "pipeline.start" "$type_field"

issue_in_data="$(echo "$last" | jq -r '.data.issue')"
assert_eq "event payload has issue=42" "42" "$issue_in_data"

# ─── Envelope fields from env ──────────────────────────────────────────────
export ZBUILD_RUN_ID="test-run-xyz"
export ZBUILD_PLUGIN="security-lens"
export ZBUILD_PLUGIN_KIND="agent"
eb_emit_event "plugin.run.start" "stage=review"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "envelope picks up ZBUILD_RUN_ID" "test-run-xyz" "$(echo "$last" | jq -r .run_id)"
assert_eq "envelope picks up ZBUILD_PLUGIN" "security-lens" "$(echo "$last" | jq -r .plugin)"
assert_eq "envelope picks up ZBUILD_PLUGIN_KIND" "agent" "$(echo "$last" | jq -r .kind)"
unset ZBUILD_RUN_ID ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND

# ─── Schema-as-warn: unknown type does NOT block ────────────────────────────
set +e
eb_emit_event "made.up.event.type" "foo=bar"
rc=$?
set -e
assert_eq "unknown event type does NOT cause emit to fail (schema-as-warn)" "0" "$rc"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "unknown type was still written" "made.up.event.type" "$(echo "$last" | jq -r .type)"

# Warning is unconditional (no ZBUILD_DEBUG needed)
stderr_out="$(eb_emit_event "made.up.event.type.2" 2>&1 >/dev/null)"
assert_eq "unknown type warns to stderr without ZBUILD_DEBUG" \
    "[event-bus] WARN: unknown event type 'made.up.event.type.2' (run_id=)" \
    "$stderr_out"

# ─── Query API ──────────────────────────────────────────────────────────────
count_start=$(eb_query_events "pipeline.start" | wc -l | tr -d ' ')
assert_eq "query filters by type" "1" "$count_start"

count_all=$(eb_query_events "" 100 | wc -l | tr -d ' ')
# We've emitted: pipeline.start, plugin.run.start, made.up.event.type, made.up.event.type.2 = 4
assert_eq "query returns all events" "4" "$count_all"

# ─── SQLite mirror exists if sqlite3 is available ───────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
    assert_file_exists "SQLite mirror created" "$ZBUILD_EVENTS_DB"
    db_count=$(sqlite3 "$ZBUILD_EVENTS_DB" 'SELECT COUNT(*) FROM events;')
    assert_eq "SQLite mirror has 4 events" "4" "$db_count"
else
    assert_pass "skipped SQLite mirror (sqlite3 not installed)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
