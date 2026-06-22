#!/usr/bin/env bash
# Tests: ANSI stripping in event log emission (KEEPERS §C.5)
# Legacy citation: legacy/scripts/lib/helpers.sh:431-437 (strip_ansi)
# Proves DoD items 1 (behavior preserved) and 2 (regression test documented).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/event-bus — ANSI stripping in event log emission"

setup_test_env "event-bus-ansi-strip"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# ─── SPEC-1: ANSI in payload value is stripped ──────────────────────────────
# emit with a green-colored value; the JSONL record must contain no ESC bytes
eb_emit_event "stage.start" $'output=\e[32mgreen\e[0m'
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
output_val="$(printf '%s' "$last" | jq -r '.data.output')"
assert_eq "[SPEC-1] ANSI stripped from payload value" "green" "$output_val"

# also assert zero ESC bytes in the full record.
# Count ESC (0x1b) bytes via `tr` rather than `grep -P` — BSD grep (macOS CI
# matrix, #995) has no -P/PCRE, so `grep -cP '\x1b'` errors and yields empty.
esc_count="$(printf '%s' "$last" | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')"
assert_eq "[SPEC-1] no ESC bytes in JSONL record" "0" "$esc_count"

# ─── SPEC-2: ANSI in envelope field (plugin) is stripped ────────────────────
export ZBUILD_PLUGIN=$'\e[31mred-plugin\e[0m'
eb_emit_event "plugin.run.start" "stage=review"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
plugin_val="$(printf '%s' "$last" | jq -r '.plugin')"
assert_eq "[SPEC-2] ANSI stripped from envelope plugin field" "red-plugin" "$plugin_val"
unset ZBUILD_PLUGIN

# Also test run_id and kind envelope fields
export ZBUILD_RUN_ID=$'\e[33mrun-99\e[0m'
export ZBUILD_PLUGIN_KIND=$'\e[34magent\e[0m'
eb_emit_event "plugin.run.complete" "status=ok"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-2] ANSI stripped from envelope run_id field" "run-99" "$(printf '%s' "$last" | jq -r '.run_id')"
assert_eq "[SPEC-2] ANSI stripped from envelope kind field" "agent" "$(printf '%s' "$last" | jq -r '.kind')"
unset ZBUILD_RUN_ID ZBUILD_PLUGIN_KIND

# ─── SPEC-3: clean ASCII values pass through unchanged ──────────────────────
eb_emit_event "test.clean" "key=hello" "msg=world"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-3] clean ASCII key value passes through unchanged" "hello" "$(printf '%s' "$last" | jq -r '.data.key')"
assert_eq "[SPEC-3] clean ASCII msg value passes through unchanged" "world" "$(printf '%s' "$last" | jq -r '.data.msg')"

# ─── SPEC-4: Unicode box-drawing characters pass through unchanged ───────────
eb_emit_event "test.unicode" "output=── divider"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
unicode_val="$(printf '%s' "$last" | jq -r '.data.output')"
assert_eq "[SPEC-4] Unicode box-drawing characters pass through unchanged" "── divider" "$unicode_val"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
