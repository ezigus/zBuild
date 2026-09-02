#!/usr/bin/env bash
# Tests: #1237 — router detects a claude rate/session limit (HTTP 429 / 529 or
# is_error:true + limit text) even when the envelope misleadingly says
# subtype:"success" and the process exits rc=1.
#
# Contract:
#   - route_to_model returns rc=1 (recoverable) on a rate-limit — NOT a new rc —
#     so every advisory stage that treats rc=1 as recoverable stays NON-blocking.
#   - the operator sees an honest "rate-limited — resets X" message (stderr),
#     not the opaque "claude CLI failed (rc=1)".
#   - a router.rate_limited event is emitted (distinct from claude_cli_failed).
#   - the rate-limit is NOT immediately auto-retried (retry loop is rc=124 only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router rate-limit detection — #1237"
setup_test_env "router-rate-limit"
_test_cleanup_hook() { cleanup_test_env; }

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

# A claude mock that (a) records each invocation to a counter file and
# (b) emits the given JSON envelope on stdout then exits with the given rc.
_CALL_COUNT_FILE="$TEST_TEMP_DIR/claude_calls"
: > "$_CALL_COUNT_FILE"
_install_json_mock() {
    local rc="$1" json="$2"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf 'x\n' >> "$_CALL_COUNT_FILE"
cat <<'JSON'
$json
JSON
exit $rc
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

RL_JSON='{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"duration_ms":503,"result":"You have hit your session limit · resets 10:30am (America/New_York)","output_tokens":0}'

# ─── T1: 429 + rc=1 → route_to_model returns rc=1 (advisory non-blocking) ────
unset ZBUILD_ROUTER_MAX_TURNS ZBUILD_CURRENT_STAGE
export ZBUILD_ROUTER_JSON_OUTPUT=1
: > "$ZBUILD_EVENTS_JSONL"
: > "$_CALL_COUNT_FILE"
_install_json_mock 1 "$RL_JSON"
set +e
stderr_out="$(route_to_model "T2" "ping" --skip-precondition 2>&1 >/dev/null)"
rc=$?
set -e
assert_eq "T1: rate-limit collapses to route_to_model rc=1 (non-blocking preserved)" "1" "$rc"

# ─── T2: operator sees the honest message, not the opaque rc=1 ───────────────
assert_contains "T2: honest rate-limited message on stderr" "$stderr_out" "rate-limited"
assert_contains "T2: reset time surfaced" "$stderr_out" "resets 10:30am (America/New_York)"

# ─── T3: NOT immediately auto-retried (claude invoked exactly once) ──────────
call_count="$(grep -c . "$_CALL_COUNT_FILE" 2>/dev/null)" || call_count=0
assert_eq "T3: rate-limit not auto-retried (single claude invocation)" "1" "$call_count"

# ─── T4: a distinct router.rate_limited event is emitted ─────────────────────
assert_contains "T4: router.rate_limited event emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "router.rate_limited"

# ─── T5: a GENUINE non-limit rc=1 does NOT emit router.rate_limited ──────────
: > "$ZBUILD_EVENTS_JSONL"
: > "$_CALL_COUNT_FILE"
_install_json_mock 1 '{"type":"result","subtype":"error","is_error":true,"result":"tool failed"}'
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T5: genuine rc=1 still returns rc=1" "1" "$rc"
if grep -q "router.rate_limited" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "T5: non-limit error must NOT emit router.rate_limited"
else
    assert_pass "T5: non-limit error did NOT emit router.rate_limited"
fi

# ─── T6 [SPEC-1][change] the LOOP path must not retry a rate-limited timeout ──
# The sync path has honoured 429 since #1237. route_to_model_loop never did, and
# that is the path `build` uses. Measured on run 33474879520: the CLI reported
# HTTP 429 in 514ms, then hung; gtimeout killed it at 900s (rc=124); the loop
# saw no LOOP_COMPLETE sentinel and retried with an ESCALATED timeout. Ten of
# those = 2.5h of waiting for an answer already known, and the job hit GitHub's
# 6h ceiling with nothing to show.
print_test_section "[SPEC-1][change] a rate-limited timeout is not retried in the loop"

_LOOP_PROMPT="$TEST_TEMP_DIR/loop-prompt.txt"
printf 'do the thing\n' > "$_LOOP_PROMPT"
_LOOP_REPO="$(setup_git_temp_repo looprl)"

# Mock: emit the 429 envelope IMMEDIATELY, then hang so gtimeout returns 124 —
# exactly the shape observed in production.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf 'x\n' >> "$_CALL_COUNT_FILE"
cat <<'JSON'
$RL_JSON
JSON
sleep 30
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

: > "$_CALL_COUNT_FILE"
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_ROUTER_TIMEOUT=1     # force the timeout fast
export ZBUILD_ROUTER_RETRIES=2     # retries available, so a retry WOULD happen
set +e
( cd "$_LOOP_REPO" && route_to_model_loop T2 "$_LOOP_PROMPT" "$_LOOP_REPO" 1 ) >/dev/null 2>&1
set -e
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_RETRIES

_loop_calls=0
if [[ -s "$_CALL_COUNT_FILE" ]]; then
    _loop_calls="$(/usr/bin/grep -c . "$_CALL_COUNT_FILE" || true)"
fi
assert_eq "[SPEC-1] a rate-limited timeout is NOT retried (one claude call)" \
    "1" "$_loop_calls"

# ─── T7 [SPEC-2][change] and the loop path says so ───────────────────────────
# A silent stop is only half the fix: the operator has to learn the run stopped
# because the account is over its limit, not because the model went quiet.
print_test_section "[SPEC-2][change] the loop reports the rate limit"

assert_contains "[SPEC-2] router.rate_limited emitted from the loop path" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "router.rate_limited"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
