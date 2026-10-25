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

# ─── events.jsonl is the only record (ADR-065 §5, 2026-10-24) ────────────────
# The SQLite mirror had no reader and was removed: nothing else is written.
_db_files="$(cd "$ZBUILD_EVENTS_DIR" && ls -A | grep -c '^events\.db' || true)"
assert_eq "no events.db or events.db.lock is written" "0" "$_db_files"
assert_file_exists "events.jsonl is written" "$ZBUILD_EVENTS_JSONL"

# ─── An emit that cannot write never ends a `set -e` caller (#1153) ─────────
# A lock or events file that cannot be opened is a redirect error, which
# `set -e` does not forgive; emits run bare under it throughout the pipeline.
_fs="$TEST_TEMP_DIR/failsoft"
mkdir -p "$_fs/lock/events.jsonl.lock" "$_fs/file/events.jsonl"
for _case in lock file; do
    _out="$(ZBUILD_EVENTS_DIR="$_fs/$_case" ZBUILD_EVENTS_JSONL="$_fs/$_case/events.jsonl" \
        bash -c 'set -e; source "$1/core/event-bus/event-bus.sh"
                 eb_emit_event stage.complete stage=x; echo carried-on' _ "$REPO_ROOT" 2>/dev/null || true)"
    assert_eq "[#1153] an unopenable $_case: the set -e caller carries on" "carried-on" "$_out"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
