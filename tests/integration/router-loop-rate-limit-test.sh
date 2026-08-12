#!/usr/bin/env bash
# Integration: the rate-limit detector gets its SECOND caller — the router's
# LOOP path (#1823, absorbs #1723).
#
# #1237 taught `_route_call_claude` to recognise a 429/529 envelope. But
# `route_to_model_loop` does not go through `_route_call_claude` — it spawns
# claude directly and waits on the child — so the one function that could name
# the failure never saw the loop's output. `build` uses the loop path.
#
# The consequence, verbatim from #1723: a session limit surfaced as
# `reason=claude_rc_nonzero`, the loop `continue`d, and it re-spawned against the
# same limit until `max_iterations` returned 1 at zero output. Iterations and
# budget spent to learn nothing already known on the first response.
#
# What this file pins:
#   1. the loop detects the envelope at all (the second caller exists)
#   2. it STOPS instead of iterating — the actual waste in #1723
#   3. it names the failure `router_rate_limited`, not `claude_rc_nonzero`
#   4. it arms the durable marker so the engine can resolve the dispatch to
#      `throttled` (wait, then retry) rather than `broken` (halt)
#   5. a genuine non-limit failure is unaffected — still iterates, still opaque
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router loop rate-limit — the detector's second caller (#1823 / #1723)"
setup_test_env "router-loop-rate-limit"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

_CALL_COUNT_FILE="$TEST_TEMP_DIR/claude_calls"
: > "$_CALL_COUNT_FILE"
mkdir -p "$TEST_TEMP_DIR/bin"

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
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../core/pipeline/dispatch-rc.sh
source "$REPO_ROOT/core/pipeline/dispatch-rc.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"

RL_JSON='{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"duration_ms":503,"result":"You have hit your session limit · resets 10:30am (America/New_York)","output_tokens":0}'

# A REAL git repo. The loop captures a diff after every iteration and returns 2
# with reason=error when that fails — so in a non-repo the loop bails after ONE
# call for reasons that have nothing to do with rate limiting, and "claude was
# invoked once" would hold at the merge-base too. The test would then pass
# without the fix, which is the failure mode that makes a guard worthless.
_WORK="$TEST_TEMP_DIR/work"; mkdir -p "$_WORK"
(
    cd "$_WORK"
    git init -q .
    git config user.email test@example.com
    git config user.name test
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -qm seed
) >/dev/null 2>&1
_PROMPT="$TEST_TEMP_DIR/prompt.txt"; printf 'do the thing\n' > "$_PROMPT"

export ZBUILD_ROUTER_JSON_OUTPUT=1
unset ZBUILD_ROUTER_MAX_TURNS ZBUILD_CURRENT_STAGE

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "1. A 429 on the loop path stops the loop"

: > "$ZBUILD_EVENTS_JSONL"
: > "$_CALL_COUNT_FILE"
_router_clear_throttle_marker
_install_json_mock 1 "$RL_JSON"

# max_iterations 5: if the loop still iterated on a rate limit it would spawn
# claude five times. That count IS the #1723 defect, so it is asserted directly
# rather than inferred from the return code.
set +e
route_to_model_loop "T2" "$_PROMPT" "$_WORK" 5 >/dev/null 2>&1
_loop_rc=$?
set -e

_calls="$(grep -c . "$_CALL_COUNT_FILE" 2>/dev/null || printf '0')"
assert_eq "[SPEC-1] claude is invoked ONCE, not max_iterations times" "1" "$_calls"
assert_eq "[SPEC-1] the loop reports the failure" "1" "$_loop_rc"
assert_eq "[SPEC-1] terminated reason names the rate limit" \
    "router_rate_limited" "$_ROUTE_LOOP_TERMINATED_REASON"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "2. The operator and the event stream are told the truth"

_events="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "[SPEC-2] router.rate_limited is emitted from the loop path" \
    "$_events" "router.rate_limited"
assert_contains "[SPEC-2] the reset time reaches the event stream" \
    "$_events" "resets 10:30am"
# The pre-#1823 reason. Its absence is what proves the new branch was taken
# rather than merely added.
if grep -q 'claude_rc_nonzero' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-2] a rate limit must NOT be reported as claude_rc_nonzero" \
        "events: $_events"
else
    assert_pass "[SPEC-2] a rate limit is no longer reported as claude_rc_nonzero"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "3. The marker makes the dispatch throttled, not broken"

# This is the payoff. Without the marker the engine sees "rc=1, no result" and
# concludes `broken`, which HALTS — killing a run that only needed to wait for
# the limit to reset.
assert_eq "[SPEC-3] the loop armed the throttle marker" \
    "0" "$( _rc=0; _router_throttle_observed || _rc=$?; printf '%s' "$_rc" )"

_disp="$(dispatch_rc_failure_disposition "" 1)"
assert_eq "[SPEC-3] the dispatch resolves to throttled" "throttled" "$_disp"
assert_eq "[SPEC-3] whose response is to wait and retry" \
    "retry_after_wait" "$(disposition_response "$_disp")"
assert_eq "[SPEC-3] and which does NOT halt the run" \
    "1" "$( _rc=0; disposition_halts "$_disp" || _rc=$?; printf '%s' "$_rc" )"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "4. Negative control — a genuine failure is untouched"

# Without this, everything above would pass for an implementation that called
# every loop failure a rate limit — which would wait 30s before retrying every
# real defect.
: > "$ZBUILD_EVENTS_JSONL"
: > "$_CALL_COUNT_FILE"
_router_clear_throttle_marker
_install_json_mock 1 '{"type":"result","subtype":"error","is_error":true,"result":"tool failed"}'

set +e
route_to_model_loop "T2" "$_PROMPT" "$_WORK" 3 >/dev/null 2>&1
_neg_rc=$?
set -e

_neg_calls="$(grep -c . "$_CALL_COUNT_FILE" 2>/dev/null || printf '0')"
assert_eq "[SPEC-4] a genuine failure still ITERATES to max_iterations" "3" "$_neg_calls"
assert_eq "[SPEC-4] and exhausts the loop" "1" "$_neg_rc"
assert_eq "[SPEC-4] its reason is max_iterations, not a rate limit" \
    "max_iterations" "$_ROUTE_LOOP_TERMINATED_REASON"
assert_eq "[SPEC-4] no throttle marker is armed" \
    "1" "$( _rc=0; _router_throttle_observed || _rc=$?; printf '%s' "$_rc" )"
if grep -q 'router.rate_limited' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-4] a genuine failure must NOT emit router.rate_limited"
else
    assert_pass "[SPEC-4] a genuine failure does not emit router.rate_limited"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
