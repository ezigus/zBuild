#!/usr/bin/env bash
# Tests: core/router/route.sh — C6 precondition enforcement.
# model.route must not fire without a preceding redaction.applied event.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router precondition — C6: model.route requires redaction.applied (ARCHITECTURE.md §3)"

setup_test_env "router-precondition"

EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
mkdir -p "$EVENTS_DIR"

# ─── Mock claude (success) ────────────────────────────────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

# ─── Test 1: fresh run_id with no events for that run → C6 fails CLOSED (#289)
# Pre-#289 this case silently passed (the inner `[[ ... ]]` short-circuited).
# Now: no events for this run_id means we cannot verify redaction.applied, so
# the router refuses.
export ZBUILD_RUN_ID="precond-run-fresh-$$"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "fresh run with no events: route_to_model refuses (#289 fail-closed)" "1" "$rc"

refused_count="$(grep -c '"router.precondition.refused"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "router.precondition.refused event emitted (no_events_for_run)" "$refused_count" "0"

# ─── Test 1a: ZBUILD_RUN_ID unset → C6 fails CLOSED (#289) ───────────────────
# Pre-#289 this silently no-op'd; now it refuses.
saved_run_id="${ZBUILD_RUN_ID:-}"
unset ZBUILD_RUN_ID
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "ZBUILD_RUN_ID unset: route_to_model refuses (#289 fail-closed)" "1" "$rc"

# ─── Test 1b: ZBUILD_EVENTS_JSONL missing → C6 fails CLOSED (#289) ───────────
export ZBUILD_RUN_ID="precond-run-no-log-$$"
saved_events_log="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/does-not-exist.jsonl"
rm -f "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "events log missing: route_to_model refuses (#289 fail-closed)" "1" "$rc"

# Restore for subsequent tests
export ZBUILD_EVENTS_JSONL="$saved_events_log"

# ─── Test 2: run_id with non-redaction last event → C6 violation, rc=1 ───────
export ZBUILD_RUN_ID="precond-run-violation-$$"
: > "$ZBUILD_EVENTS_JSONL"

jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"stage.start",
      plugin:"", kind:"", data:{stage:"intake"}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "C6 precondition violated: last event not redaction.applied → rc=1" "1" "$rc"

# Assert router.precondition.violated event was emitted
violated_count="$(grep -c '"router.precondition.violated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "router.precondition.violated event emitted" "$violated_count" "0"

# Assert no model.route event emitted when C6 blocks
model_route_count="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r --arg rid "$ZBUILD_RUN_ID" 'select(.run_id==$rid) | .type' 2>/dev/null \
    | grep -c "model.route" || true)"
if [[ "$model_route_count" -eq 0 ]]; then
    assert_pass "no model.route event emitted when C6 precondition blocks"
else
    assert_fail "no model.route event emitted when C6 precondition blocks" \
        "found $model_route_count model.route events"
fi

# ─── Test 3: run_id with redaction.applied as last event → succeeds ───────────
export ZBUILD_RUN_ID="precond-run-satisfied-$$"
: > "$ZBUILD_EVENTS_JSONL"

jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "C6 precondition satisfied: last event is redaction.applied → rc=0" "0" "$rc"
assert_eq "response passthrough when precondition satisfied" "OK-RESPONSE" "$out"

# Assert model.route event was emitted
model_route_fired="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r --arg rid "$ZBUILD_RUN_ID" 'select(.run_id==$rid) | .type' 2>/dev/null \
    | grep -c "model.route" || true)"
assert_gt "model.route event emitted when precondition satisfied" "$model_route_fired" "0"

# ─── Test 4: --skip-precondition bypasses C6 (bootstrapping/test path) ────────
export ZBUILD_RUN_ID="precond-run-skip-$$"
: > "$ZBUILD_EVENTS_JSONL"

# Emit a non-redaction event (would normally trigger violation)
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"pipeline.start",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "--skip-precondition bypasses C6 → rc=0" "0" "$rc"

# Audit event emitted on bypass
skipped_count="$(grep -c '"router.precondition.skipped"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "router.precondition.skipped event emitted on --skip-precondition" "$skipped_count" "0"

# ─── Test 5: --skip-precondition tolerates unset ZBUILD_RUN_ID (#289) ────────
# Bootstrapping path: bypass should work even without RUN_ID wiring.
unset ZBUILD_RUN_ID
set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "--skip-precondition works with ZBUILD_RUN_ID unset" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
