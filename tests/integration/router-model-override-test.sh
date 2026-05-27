#!/usr/bin/env bash
# Tests: core/router/route.sh — model override cascade (issue #97)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — model override cascade (issue #97)"
setup_test_env "router-model-override"

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
unset ZBUILD_PLUGIN_MODEL 2>/dev/null || true
unset ZBUILD_RUN_ID 2>/dev/null || true

# Standard success mock
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

# ─── TC-1: --model flag overrides tier's candidates[0] ───────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition --model "override-model-id" 2>/dev/null
rc=$?
set -e
assert_eq "TC-1: --model flag rc=0" "0" "$rc"
tc1_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-1: model.route uses override model_id" "override-model-id" "$tc1_model"
tc1_src="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.selector // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-1: model.route selector=flag" "flag" "$tc1_src"

# ─── TC-2: ZBUILD_PLUGIN_MODEL env used when no --model flag ─────────────────
export ZBUILD_PLUGIN_MODEL="env-model-id"
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-2: ZBUILD_PLUGIN_MODEL rc=0" "0" "$rc"
tc2_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-2: model.route uses ZBUILD_PLUGIN_MODEL" "env-model-id" "$tc2_model"
tc2_src="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.selector // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-2: model.route selector=env" "env" "$tc2_src"
unset ZBUILD_PLUGIN_MODEL

# ─── TC-3: --model flag beats ZBUILD_PLUGIN_MODEL ────────────────────────────
export ZBUILD_PLUGIN_MODEL="env-model-id"
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition --model "flag-wins" 2>/dev/null
rc=$?
set -e
assert_eq "TC-3: --model beats env rc=0" "0" "$rc"
tc3_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-3: --model flag beats ZBUILD_PLUGIN_MODEL" "flag-wins" "$tc3_model"
unset ZBUILD_PLUGIN_MODEL

# ─── TC-4: tier fallback (candidates[0]) when neither set ────────────────────
unset ZBUILD_PLUGIN_MODEL 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null
rc=$?
set -e
assert_eq "TC-4: tier fallback rc=0" "0" "$rc"
tc4_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-4: model.route uses candidates[0] (claude-sonnet-4-6)" "claude-sonnet-4-6" "$tc4_model"
tc4_src="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.selector // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-4: model.route selector=candidates[0]" "candidates[0]" "$tc4_src"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
