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

# ─── Test 1: fresh run_id with no events → C6 check skipped (no events to check)
# The router only enforces C6 when there ARE events for the run_id.
# With no events at all the check passes (fail-open for bootstrapping).
export ZBUILD_RUN_ID="precond-run-fresh-$$"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "fresh run with no events: route_to_model succeeds (C6 skip-open)" "0" "$rc"

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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
