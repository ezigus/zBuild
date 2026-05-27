#!/usr/bin/env bash
# Tests: core/router/route.sh — token budget enforcement (issue #98)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — token budget enforcement (issue #98)"
setup_test_env "router-budget"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_ROUTER_JSON_OUTPUT=1
unset ZBUILD_RUN_ID 2>/dev/null || true

cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

# ─── TC-1: under budget → rc=0 ───────────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
echo "0.001" > "$HOME/.zbuild/cost-ledger.jsonl"
export ZBUILD_BUDGET_USD="10.00"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-1: under budget rc=0" "0" "$rc"
unset ZBUILD_BUDGET_USD

# ─── TC-2: over budget → rc=1, cost.budget_exceeded emitted ──────────────────
: > "$ZBUILD_EVENTS_JSONL"
echo "15.00" > "$HOME/.zbuild/cost-ledger.jsonl"
export ZBUILD_BUDGET_USD="10.00"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-2: over budget rc=1" "1" "$rc"
tc2_event="$(grep '"cost.budget_exceeded"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="cost.budget_exceeded") | .type // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-2: cost.budget_exceeded event emitted" "cost.budget_exceeded" "$tc2_event"
unset ZBUILD_BUDGET_USD

# ─── TC-3: ledger updated after successful call ───────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
: > "$HOME/.zbuild/cost-ledger.jsonl"
unset ZBUILD_BUDGET_USD 2>/dev/null || true
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-3: successful call rc=0" "0" "$rc"
ledger_lines="$(wc -l < "$HOME/.zbuild/cost-ledger.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "TC-3: ledger has 1 entry after call" "1" "$ledger_lines"

# ─── TC-4: no ZBUILD_BUDGET_USD → no enforcement (rc=0) ──────────────────────
: > "$ZBUILD_EVENTS_JSONL"
echo "9999.00" > "$HOME/.zbuild/cost-ledger.jsonl"
unset ZBUILD_BUDGET_USD 2>/dev/null || true
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-4: no budget var → no enforcement rc=0" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
