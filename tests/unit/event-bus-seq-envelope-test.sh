#!/usr/bin/env bash
# Tests: the event envelope carries the stage-io seq label (#2131, ADR-064).
#
# The hierarchical seq (`6.1.3` = runner cardinal · cycle iteration · member
# position) was display-only: rendered into the stage-io banner and stored
# nowhere a consumer of events.jsonl could read. The live run-status comment
# keys its rows on it, so the envelope stamps it — present only while a stage
# label is active, exactly like `stage`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/event-bus — optional seq envelope key (#2131)"

setup_test_env "event-bus-seq-envelope"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# ─── SPEC-1: an exported label is stamped verbatim ──────────────────────────
export ZBUILD_STAGE_IO_SEQ_LABEL="6.1.3"
export ZBUILD_CURRENT_STAGE="build"
eb_emit_event "plugin.run.start" "plugin=build" "kind=agent"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-1] envelope .seq is the exported label" "6.1.3" "$(jq -r '.seq' <<< "$last")"
assert_eq "[SPEC-1] envelope .stage still present alongside seq" "build" "$(jq -r '.stage' <<< "$last")"

# A linear cardinal is a single segment.
export ZBUILD_STAGE_IO_SEQ_LABEL="5"
eb_emit_event "stage.complete" "stage=plan" "verdict=pass"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-1] single-segment cardinal stamped" "5" "$(jq -r '.seq' <<< "$last")"
unset ZBUILD_STAGE_IO_SEQ_LABEL ZBUILD_CURRENT_STAGE

# ─── SPEC-2: no label → no key (the 8-key envelope is unchanged) ────────────
eb_emit_event "pipeline.start" "run_id=r1" "issue=0"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-2] no seq key when the label is unset" "false" "$(jq -r 'has("seq")' <<< "$last")"
assert_eq "[SPEC-2] stage-less emit keeps exactly 8 keys" \
    "data,issue,kind,plugin,run_id,schema_version,ts,type" \
    "$(jq -r 'keys | sort | join(",")' <<< "$last")"

# An empty export is the same as unset.
export ZBUILD_STAGE_IO_SEQ_LABEL=""
eb_emit_event "pipeline.end" "status=success"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-2] empty label → no seq key" "false" "$(jq -r 'has("seq")' <<< "$last")"
unset ZBUILD_STAGE_IO_SEQ_LABEL

# ─── SPEC-3: a label that is not digits-and-dots is dropped, not stamped ────
# The label is engine-generated; anything else (ANSI, a stray word) is a bug
# upstream and must not become a row key downstream.
export ZBUILD_STAGE_IO_SEQ_LABEL=$'6.1.3\e[0m'
eb_emit_event "plugin.run.complete" "plugin=build" "kind=agent"
last="$(tail -1 "$ZBUILD_EVENTS_JSONL")"
assert_eq "[SPEC-3] malformed label → no seq key" "false" "$(jq -r 'has("seq")' <<< "$last")"
unset ZBUILD_STAGE_IO_SEQ_LABEL

cleanup_test_env
print_test_results
exit $((FAIL > 0))
