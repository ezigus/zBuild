#!/usr/bin/env bash
# Tests: core/router/route.sh — ADR-003 model router stub (issue #84)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — ADR-003 model router stub (issue #84)"
setup_test_env "router"

# ─── Shared env ──────────────────────────────────────────────────────────────
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# ─── Mock: model-recording claude stub (tests 1-3, 7-8) ──────────────────────
# Parses --model <id> from args, records it to last_model, echoes "OK-RESPONSE"
mock_binary "claude" "$(cat <<'MOCK'
#!/usr/bin/env bash
model_id=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--model" && -n "${2:-}" ]]; then
        model_id="$2"; shift 2
    else
        shift
    fi
done
printf '%s\n' "$model_id" > "${TEST_TEMP_DIR}/last_model"
echo "OK-RESPONSE"
exit 0
MOCK
)"

# TEST_TEMP_DIR must be visible inside the mock at runtime; embed it.
# Rewrite with expanded TEST_TEMP_DIR:
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
model_id=""
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--model" && -n "\${2:-}" ]]; then
        model_id="\$2"; shift 2
    else
        shift
    fi
done
printf '%s\n' "\$model_id" > "$TEST_TEMP_DIR/last_model"
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Source the module under test (after env is set).
# shellcheck source=../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── Test 1: T2 selects Sonnet ───────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "T2 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T2 selects claude-sonnet-4-6" "claude-sonnet-4-6" "$last_model"

# ─── Test 2: T1 selects Haiku ────────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T1" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "T1 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T1 selects claude-haiku-4-5-20251001" "claude-haiku-4-5-20251001" "$last_model"

# ─── Test 3: T3 selects Opus ─────────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T3" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "T3 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T3 selects claude-opus-4-7" "claude-opus-4-7" "$last_model"

# ─── Test 4: T0 (wasm) returns rc=2 ─────────────────────────────────────────
set +e
err="$(route_to_model "T0" "ping" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T0 wasm returns rc=2" "2" "$rc"
assert_contains "T0 stderr mentions not implemented" "$err" "not implemented"

# ─── Test 5: T4 (empty candidates) returns rc=1 ──────────────────────────────
set +e
err="$(route_to_model "T4" "ping" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T4 empty candidates returns rc=1" "1" "$rc"
assert_contains "T4 stderr mentions no candidates" "$err" "no candidates"

# ─── Test 6: invalid tier returns rc=2 ───────────────────────────────────────
set +e
err="$(route_to_model "T9" "ping" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "invalid tier returns rc=2" "2" "$rc"
assert_contains "invalid tier stderr mentions invalid tier" "$err" "invalid tier"

# ─── Test 7: model.route event emitted with correct fields ───────────────────
: > "$ZBUILD_EVENTS_JSONL"
: > "$TEST_TEMP_DIR/last_model"

set +e
route_to_model "T2" "ping" >/dev/null 2>&1
set -e

event_tier="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.tier // empty' 2>/dev/null | tail -1 || true)"
event_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"

assert_eq "model.route event has tier=T2" "T2" "$event_tier"
assert_eq "model.route event has model_id=claude-sonnet-4-6" "claude-sonnet-4-6" "$event_model"

# ─── Test 8: response passthrough ────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "response passthrough returns rc=0" "0" "$rc"
assert_eq "stdout is OK-RESPONSE" "OK-RESPONSE" "$out"

# ─── Test 9: mock claude exits 1 → rc=1 (recoverable) ───────────────────────
# Swap in a failing claude mock.
cat > "$TEST_TEMP_DIR/bin/claude" <<'FAIL_MOCK'
#!/usr/bin/env bash
exit 1
FAIL_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "claude CLI failure returns rc=1 (recoverable)" "1" "$rc"
assert_eq "no stdout on claude failure" "" "$out"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
