#!/usr/bin/env bash
# tests/unit/router-out-of-turns-crosses-subshell-test.sh — a turn-budget hit
# reaches the stage that asked, however it called the router.
#
# Why: #1847 (PR #2221 review). route_to_model records a turn-budget hit in
# _ROUTE_LAST_BUDGET_EXHAUSTED, and _router_rc_classify reads it to name the
# cause `router_out_of_turns` → disposition `out_of_turns`. But every stage calls
# `response="$(route_to_model …)"` — a subshell — so the variable dies with it
# and the hit was always reported as a generic `router_rc_nonzero`. The existing
# test set the variable by hand in the same shell, so it could not see this.
# The rate-limit signal had the same boundary and crosses it with a marker file
# (_router_arm_throttle_marker); the budget hit now does the same.
#
# O1 [change] a turn-budget hit inside `$(route_to_model …)` classifies as
#             router_out_of_turns in the caller, and maps to out_of_turns
# O2 [guard]  a plain failure (not a budget hit) is still router_rc_nonzero
# O3 [change] the next call clears it: a budget hit is not reported for a later,
#             unrelated failure of the same stage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router: a turn-budget hit crosses the subshell to the caller"
setup_test_env "router-out-of-turns-subshell"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"; mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts/stage-io"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="oot-$$" ZBUILD_CURRENT_STAGE=monitor

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: monitor
    gate: auto
    roles: [monitor]
YAML

# The fake model answers according to $FAKE_MODE: max_turns (a budget hit),
# fail (a plain failure) or ok.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
case "${FAKE_MODE:-ok}" in
    max_turns) jq -n '{type:"result",subtype:"error_max_turns",is_error:true,num_turns:10,usage:{output_tokens:5}}'; exit 1 ;;
    fail)      jq -n '{type:"result",subtype:"error_during_execution",is_error:true}'; exit 1 ;;
    *)         jq -n '{type:"result",result:"ok",usage:{input_tokens:1,output_tokens:1}}'; exit 0 ;;
esac
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1

# _call <mode> — call the router the way every stage does, then classify in THIS shell.
_call() {
    local rc=0 _v="" _r=""
    _out="$(FAKE_MODE="$1" route_to_model T1 "prompt" 2>/dev/null)" || rc=$?
    _router_rc_classify "$rc" _v _r
    printf '%s %s' "$rc" "$_r"
}

print_test_section "O1–O3"
_o1="$(_call max_turns)"
assert_eq "[O1] a budget hit inside \$(route_to_model) → router_out_of_turns in the caller" \
    "router_out_of_turns" "${_o1#* }"
assert_eq "[O1] ...which names the disposition out_of_turns" "out_of_turns" \
    "$(router_reason_disposition "${_o1#* }")"
_o2="$(_call fail)"
assert_eq "[O2] a plain failure is still router_rc_nonzero" "router_rc_nonzero" "${_o2#* }"
_call max_turns >/dev/null
_o3="$(_call fail)"
assert_eq "[O3] the next call clears the hit: a later plain failure is not out_of_turns" \
    "router_rc_nonzero" "${_o3#* }"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
