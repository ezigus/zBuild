#!/usr/bin/env bash
# tests/unit/route-one-call-per-try-test.sh — a stage makes one model call per
# try; the engine decides whether there is another try (ADR-054 §6a, ADR-018,
# amended 2026-10-31, #2439).
#
# Why: build called the model up to 10 times inside one try, and gave up only
# after 3 timeouts in a row; then the engine ran the whole try again, 3 more
# times. On #1754 (run 41208786459) that was 12 timed-out calls, about 3 hours,
# before test ran. The retry belongs to the engine alone, set in the template.
#
# O1 [change] a call that ends without saying it is done is made once, and the
#             try ends unusable
# O2 [change] a call that times out is made once, and the try ends timed_out
# O3 [guard]  a call that says it is done is made once, and the try is done
# O4 [change] the call takes no call limit: <tier> <prompt_file> <cwd>
# O5 [change] a call that fails is made once
# O6 [change] router.retries is gone: ZBUILD_ROUTER_RETRIES does not repeat a
#             timed-out call
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "one model call per try (#2439)"
setup_test_env "route-one-call-per-try"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"
export HOME="$TEST_TEMP_DIR/home"; mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID ZBUILD_ROUTER_RETRIES ZBUILD_ROUTER_MAX_ITERATIONS 2>/dev/null || true

REPO="$(setup_git_temp_repo "one-call")"
CALLS="$TEST_TEMP_DIR/calls"
mkdir -p "$TEST_TEMP_DIR/bin"
# The mock: counts each call; MOCK_MODE says how it ends.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
echo call >> "$CALLS"
case "\${MOCK_MODE:-unfinished}" in
    done)       r=\$'Work complete.\nLOOP_COMPLETE' ;;
    unfinished) r='Still working on it.' ;;
    timeout)    exit 124 ;;
    fail)       echo 'boom' >&2; exit 1 ;;
esac
jq -n --arg r "\$r" '{type:"result", subtype:"success", is_error:false, result:\$r, usage:{input_tokens:1, output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

PROMPT="$TEST_TEMP_DIR/prompt.txt"; echo "do the work" > "$PROMPT"
_calls() { grep -c . "$CALLS" 2>/dev/null || echo 0; }
_try() {   # <mode> — one try, 3 arguments, no call limit
    : > "$CALLS"
    MOCK_MODE="$1" route_to_model_loop T2 "$PROMPT" "$REPO" >/dev/null 2>&1
    _RC=$?
}

# ── O1 ───────────────────────────────────────────────────────────────────────
_try unfinished
assert_eq "[O1] a call that does not say it is done is made once" "1" "$(_calls)"
assert_eq "[O1] the try ends on no_done_sentinel" "no_done_sentinel" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
assert_eq "[O1] ...which is unusable" "unusable" "$(router_reason_disposition no_done_sentinel)"

# ── O2 ───────────────────────────────────────────────────────────────────────
_try timeout
assert_eq "[O2] a call that times out is made once" "1" "$(_calls)"
assert_eq "[O2] the try ends on router_timeout" "router_timeout" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
assert_eq "[O2] ...which is timed_out" "timed_out" "$(router_reason_disposition router_timeout)"

# ── O3 ───────────────────────────────────────────────────────────────────────
_try done
assert_eq "[O3] a call that says it is done is made once" "1" "$(_calls)"
assert_eq "[O3] the try is done" "done_sentinel" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
assert_eq "[O3] ...and returns 0" "0" "$_RC"

# ── O4 ───────────────────────────────────────────────────────────────────────
: > "$CALLS"
MOCK_MODE=done route_to_model_loop T2 "$PROMPT" "$REPO" --done-sentinel LOOP_COMPLETE >/dev/null 2>&1; _rc=$?
assert_eq "[O4] flags follow the three arguments directly" "0" "$_rc"
if grep -qE '_route_resolve_max_iterations|max_iterations' "$REPO_ROOT/core/router/route.sh" "$REPO_ROOT/scripts/lib/stage-limits.sh"; then
    assert_fail "[O4] no call limit is resolved anywhere" "route.sh or stage-limits.sh still names max_iterations"
else
    assert_pass "[O4] no call limit is resolved anywhere"
fi

# ── O5 ───────────────────────────────────────────────────────────────────────
_try fail
assert_eq "[O5] a call that fails is made once" "1" "$(_calls)"
if [[ "${_ROUTE_LOOP_TERMINATED_REASON:-}" == "done_sentinel" || -z "${_ROUTE_LOOP_TERMINATED_REASON:-}" ]]; then
    assert_fail "[O5] the try says how the call failed" "reason: '${_ROUTE_LOOP_TERMINATED_REASON:-}'"
else
    assert_pass "[O5] the try says how the call failed (${_ROUTE_LOOP_TERMINATED_REASON})"
fi

# ── O6 ───────────────────────────────────────────────────────────────────────
: > "$CALLS"
ZBUILD_ROUTER_RETRIES=2 MOCK_MODE=timeout route_to_model_loop T2 "$PROMPT" "$REPO" >/dev/null 2>&1
assert_eq "[O6] ZBUILD_ROUTER_RETRIES=2 does not repeat the call" "1" "$(_calls)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
