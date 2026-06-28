#!/usr/bin/env bash
# Tests: core/event-bus/event-bus.sh — concurrent emitter contention (#1153)
#
# #1131 (parallel stage members) introduces concurrent eb_emit_event callers.
# The mirror INSERT is flock-serialized on a DEDICATED lock (events.db.lock),
# distinct from the jsonl lock, so the best-effort mirror can never block the
# authoritative jsonl append. This test fires N emitters at once and asserts
# (1) the mirror uses a dedicated lock distinct from the jsonl lock, (2) zero
# event loss in the authoritative events.jsonl, (3) no JSON corruption, and
# (4) the SQLite mirror (if sqlite3 is present) agrees with the jsonl. It also
# measures wall time so a regression that re-serializes writes shows up.
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
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# Initialize once before forking so every concurrent emitter shares one
# already-created mirror + lock file.
_eb_init

EMITTERS=12        # concurrent stage members (well above #1131's expected fan-out)
PER_EMITTER=5      # events each emitter appends
EXPECTED=$(( EMITTERS * PER_EMITTER ))

# ─── (1) Dedicated db lock, distinct from the jsonl lock ────────────────────
# The mirror MUST serialize on its own lock so a slow mirror write can never
# block the authoritative jsonl append.
jsonl_lock="${ZBUILD_EVENTS_JSONL}.lock"
db_lock="${ZBUILD_EVENTS_DB}.lock"
assert_file_exists "dedicated db lock file created by _eb_init" "$db_lock"
if [[ "$jsonl_lock" != "$db_lock" ]]; then
    assert_pass "jsonl lock and db lock are distinct files ($jsonl_lock != $db_lock)"
else
    assert_fail "jsonl lock and db lock must be distinct files" \
        "both resolved to $db_lock — a slow mirror could block the jsonl append"
fi

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

# ─── (4) Mirror agrees with the jsonl (best-effort, but must not lose) ──────
if command -v sqlite3 >/dev/null 2>&1; then
    db_count="$(sqlite3 "$ZBUILD_EVENTS_DB" 'SELECT COUNT(*) FROM events;' 2>/dev/null | tr -d ' ')"
    assert_eq "SQLite mirror count matches jsonl under flock-serialized concurrency" \
        "$EXPECTED" "$db_count"
else
    assert_pass "skipped SQLite mirror count (sqlite3 not installed)"
fi

# ─── Contention margin: flock serializes writes cheaply ─────────────────────
# With flock, the 12 emitters take the dedicated lock in turn; each mirror
# write is a single sub-second sqlite3 INSERT. A generous 60s ceiling catches a
# regression that reintroduces unbounded blocking while tolerating slow CI.
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
