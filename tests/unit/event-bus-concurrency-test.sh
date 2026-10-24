#!/usr/bin/env bash
# Tests: core/event-bus/event-bus.sh — concurrent emitter contention (#1153)
#
# #1131 (parallel stage members) introduces concurrent eb_emit_event callers.
# The jsonl append is flock-serialized. This test fires N emitters at once and
# asserts (2) zero event loss in events.jsonl and (3) no JSON corruption. It
# also measures wall time so a regression that re-serializes writes shows up.
# (1) and (4), the SQLite mirror's own lock and row count, went with the mirror
# (ADR-065 §5, 2026-10-24).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/event-bus — concurrent emitters (dedicated lock, no loss)"

setup_test_env "core-events-concurrency"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# Initialize once before forking so every concurrent emitter shares one
# already-created lock file.
_eb_init

EMITTERS=12        # concurrent stage members (well above #1131's expected fan-out)
PER_EMITTER=5      # events each emitter appends
EXPECTED=$(( EMITTERS * PER_EMITTER ))

# ─── Fire N concurrent emitters ─────────────────────────────────────────────
# "plugin.run.start" is a known event type, so this exercises the hot path
# without schema-as-warn noise on stderr.
start_ns="$(date +%s)"
pids=()
for e in $(seq 1 "$EMITTERS"); do
    (
        for i in $(seq 1 "$PER_EMITTER"); do
            eb_emit_event "plugin.run.start" "emitter=$e" "seq=$i"
        done
    ) &
    pids+=("$!")
done

emit_rc=0
for pid in "${pids[@]}"; do
    wait "$pid" || emit_rc=1
done
end_ns="$(date +%s)"
elapsed=$(( end_ns - start_ns ))

assert_eq "all concurrent emitters exited 0" "0" "$emit_rc"

# ─── (2) No loss: every emitted event is present in the authoritative jsonl ──
jsonl_count="$(wc -l < "$ZBUILD_EVENTS_JSONL" | tr -d ' ')"
assert_eq "events.jsonl has all $EXPECTED concurrently-emitted events (no loss)" \
    "$EXPECTED" "$jsonl_count"

# ─── (3) No corruption: every line is valid JSON of the expected type ───────
valid_json=$(jq -c 'select(.type == "plugin.run.start")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_eq "every jsonl line parses as JSON with the expected type (no interleave corruption)" \
    "$EXPECTED" "$valid_json"

# Every (emitter,seq) pair appears exactly once — proves no append clobbered another.
distinct_pairs="$(jq -r '"\(.data.emitter):\(.data.seq)"' "$ZBUILD_EVENTS_JSONL" | sort -u | wc -l | tr -d ' ')"
assert_eq "all (emitter,seq) pairs present exactly once" "$EXPECTED" "$distinct_pairs"

# ─── Contention margin ──────────────────────────────────────────────────────
# The 12 emitters serialize on the jsonl lock only. A generous
# 60s ceiling catches a regression that reintroduces unbounded blocking while
# tolerating slow CI.
MARGIN_SECONDS=60
if (( elapsed <= MARGIN_SECONDS )); then
    assert_pass "concurrent emit completed in ${elapsed}s (<= ${MARGIN_SECONDS}s contention margin)"
else
    assert_fail "concurrent emit took ${elapsed}s (> ${MARGIN_SECONDS}s)" \
        "possible write re-serialization regression"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
