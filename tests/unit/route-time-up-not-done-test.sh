#!/usr/bin/env bash
# tests/unit/route-time-up-not-done-test.sh — a call its hook told that its time
# is up does not end done, whatever its reply says (ADR-063, amended
# 2026-11-14, #2543; ADR-054 §6).
#
# Why: on #1700 run 43617030653 test-author's calls in rounds 1 and 2 reached
# their time limit, were told "give your final reply now", replied
# LOOP_COMPLETE, and the stage passed having written no test. Two rounds were
# lost before the test stage found the tests missing.
#
# T1 [change] a call told its time is up, ending with its done word, ends
#             router_timeout — timed_out — so the engine runs the next try
# T2 [guard]  a call never told, ending with its done word, ends done_sentinel
# T3 [change] a call killed at its grace that was told, its reply ending with its
#             done word, ends router_timeout too (no longer honoured as done)
# T4 [guard]  the words the router looks for are the ones the hook really writes
# T5 [change] the refusal shown as a list of text blocks is found too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a call told its time is up is not done (#2543)"
setup_test_env "route-time-up-not-done"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"
export HOME="$TEST_TEMP_DIR/home"; mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID ZBUILD_ROUTER_RETRIES 2>/dev/null || true

REPO="$(setup_git_temp_repo "time-up")"

# The refusal the hook really writes once a call's deadline has passed.
REFUSAL="$(bash "$REPO_ROOT/core/router/tool-hook.sh" --done-word LOOP_COMPLETE 1 "" \
    <<< '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | jq -r '.hookSpecificOutput.permissionDecisionReason')"
export REFUSAL

mkdir -p "$TEST_TEMP_DIR/bin"
# The mock prints a step stream: optionally the hook's refusal as a tool's
# result, then a final result whose text ends with the done word.
# MOCK_TOLD: none | text | blocks. MOCK_RC: the exit code (124: killed).
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_TOLD:-none}" in
    text)   jq -cn --arg c "$REFUSAL" '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", is_error:true, content:$c}]}}' ;;
    blocks) jq -cn --arg c "$REFUSAL" '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", is_error:true, content:[{type:"text", text:$c}]}]}}' ;;
esac
jq -cn --arg r $'I wrote my notes.\nLOOP_COMPLETE' '{type:"result", subtype:"success", is_error:false, result:$r, usage:{input_tokens:1, output_tokens:1}}'
exit "${MOCK_RC:-0}"
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

PROMPT="$TEST_TEMP_DIR/prompt.txt"; echo "do the work" > "$PROMPT"
_try() {   # <told> [rc]
    _ROUTE_LOOP_TERMINATED_REASON=""
    MOCK_TOLD="$1" MOCK_RC="${2:-0}" route_to_model_loop T2 "$PROMPT" "$REPO" >/dev/null 2>&1
    _RC=$?
}

print_test_section "T1: told its time is up, it is not done"
_try text
assert_eq "[T1] the try ends router_timeout" "router_timeout" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
assert_eq "[T1] ...which is timed_out" "timed_out" "$(router_reason_disposition router_timeout)"
assert_eq "[T1] ...and returns 0, as a timeout does" "0" "$_RC"

print_test_section "T2: never told, its done word is taken"
_try none
assert_eq "[T2] the try ends done_sentinel" "done_sentinel" "${_ROUTE_LOOP_TERMINATED_REASON:-}"

print_test_section "T3: killed after being told, it is not done"
_try text 124
assert_eq "[T3] the try ends router_timeout" "router_timeout" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
_try none 124
assert_eq "[T3] killed but never told, its done word is still taken" "done_sentinel" "${_ROUTE_LOOP_TERMINATED_REASON:-}"

print_test_section "T4: the router looks for the hook's own words"
assert_contains "[T4] the hook's refusal holds the words the router looks for" "$REFUSAL" "${_ROUTE_TIME_UP_WORDS:-<unset>}"

print_test_section "T5: the refusal as text blocks"
_try blocks
assert_eq "[T5] the try ends router_timeout" "router_timeout" "${_ROUTE_LOOP_TERMINATED_REASON:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
