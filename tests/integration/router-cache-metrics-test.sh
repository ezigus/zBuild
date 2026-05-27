#!/usr/bin/env bash
# Tests: core/router/route.sh — prompt caching metrics (issue #95)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — prompt caching metrics (issue #95)"
setup_test_env "router-cache"

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

# Source module after env setup.
# shellcheck source=../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── TC-1: cache hit — cache_read_input_tokens > 0 ───────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<CACHEMOCK
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"cached-response","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":800,"cache_creation_input_tokens":0}}\n'
exit 0
CACHEMOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "TC-1: cache hit returns rc=0" "0" "$rc"
assert_eq "TC-1: .result extracted" "cached-response" "$out"

tc1_cache_read="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.cache_read_input_tokens // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-1: model.outcome has cache_read_input_tokens=800" "800" "$tc1_cache_read"

tc1_cache_eligible="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.cache_eligible // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-1: model.outcome has cache_eligible=true (T2)" "true" "$tc1_cache_eligible"

tc1_route_eligible="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.cache_eligible // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-1: model.route has cache_eligible=true (T2)" "true" "$tc1_route_eligible"

# ─── TC-2: cache write — cache_creation_input_tokens > 0 ─────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'WRITEMOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"write-response","usage":{"input_tokens":500,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":500}}\n'
exit 0
WRITEMOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "TC-2: cache write returns rc=0" "0" "$rc"
tc2_creation="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.cache_creation_input_tokens // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-2: model.outcome has cache_creation_input_tokens=500" "500" "$tc2_creation"

tc2_read="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.cache_read_input_tokens // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-2: model.outcome has cache_read_input_tokens=0" "0" "$tc2_read"

# ─── TC-3: cache fields absent in usage block → graceful default to 0 ─────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'NOCACHEMOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"no-cache","usage":{"input_tokens":50,"output_tokens":10}}\n'
exit 0
NOCACHEMOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "TC-3: missing cache fields returns rc=0" "0" "$rc"
tc3_read="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.cache_read_input_tokens // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-3: absent cache_read_input_tokens defaults to 0" "0" "$tc3_read"

# ─── TC-4: T1 (cache_eligible=true) — cache_eligible in event ────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'T1MOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"t1-response","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
T1MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T1" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "TC-4: T1 route returns rc=0" "0" "$rc"
tc4_eligible="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.cache_eligible // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-4: T1 cache_eligible=true in model.route" "true" "$tc4_eligible"

# ─── TC-5: model.outcome not emitted on router failure ────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'FAILMOCK'
#!/usr/bin/env bash
exit 1
FAILMOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "TC-5: claude failure returns rc=1" "1" "$rc"
tc5_outcome="$(grep -c '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "TC-5: no model.outcome event on failure" "0" "$tc5_outcome"

# ─── TC-6: model.route and model.outcome share same model_id ─────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'IDMOCK'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"id-check","usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit 0
IDMOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
set -e

tc6_route_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
tc6_outcome_model="$(grep '"model.outcome"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.outcome") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"
assert_eq "TC-6: model.route and model.outcome share model_id" "$tc6_route_model" "$tc6_outcome_model"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
