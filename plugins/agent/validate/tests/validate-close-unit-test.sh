#!/usr/bin/env bash
# plugins/agent/validate/tests/validate-close-unit-test.sh — closing #1845 by
# hand: what the pipeline's run (PR #2213) left short of the issue, and what
# its review found. Labels are [close-N], never [SPEC-n]: a SPEC number here
# would collide with another design's SPEC of the same number in the gate.
#
# close-1 [change] the plugin constructs no artifact path in code (issue
#                  acceptance: "assert by grep over its plugin.sh") — PR #2213
#                  kept `$(dirname "$state_file")/stage-inputs.json` and
#                  `$(dirname "$state_file")/artifacts`, and its SPEC-16 grep
#                  only looked for one literal
# close-2 [change] with no engine input index there is no fallback lookup: a
#                  stage-inputs.json beside the state file is NOT read
# close-3 [change] a failed probe keeps its diagnostics under `data`: the probe's
#                  own rc (curl's 6/7/22/28 say different things) and its output
#                  — "plugin-specific detail goes under data" (issue)
# close-4 [change] no probe target configured is `misconfigured` (an operator
#                  fixes it), not a failed deployment — and the probe is not run
# close-5 [guard]  the outer wrapper's no-state-file path writes a v2 result
#                  (review on #2213: never exercised)
# close-6 [change] with no ZBUILD_ARTIFACT_DIR the plugin invents no directory
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate — closing #1845 (paths, diagnostics, misconfiguration)"
setup_test_env "plugin-validate-close"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/validate/plugin.sh"
# shellcheck source=../../../../plugins/agent/validate/plugin.sh
source "$PLUGIN_FILE"
emit_event() { return 0; }

# The real health-check plugin is never sourced; this records whether it ran.
_ZBUILD_HEALTH_CHECK_LOADED=1
# The plugin calls it inside $( ), so a call is recorded in a FILE — a shell
# counter would never leave that subshell and could not fail.
_MOCK_HC_RC=0 _MOCK_HC_OUT="HTTP/1.1 200 OK" _HC_CALLS_F="$TEST_TEMP_DIR/hc-calls"
health_check_run() { printf 'x\n' >> "$_HC_CALLS_F"; printf '%s\n' "$_MOCK_HC_OUT"; return "$_MOCK_HC_RC"; }
_hc_calls() { if [[ -f "$_HC_CALLS_F" ]]; then wc -l < "$_HC_CALLS_F" | tr -d ' '; else printf '0'; fi; }

# _run_dir <name> [with_deploy_result] — a job folder whose engine index names
# the deploy result, exported in THIS shell (not a subshell).
_run_dir() {
    RUN="$TEST_TEMP_DIR/$1"
    mkdir -p "$RUN/artifacts" "$RUN/stage-inputs"
    [[ "${2:-1}" == "1" ]] && printf '{"verdict":"deployed"}\n' > "$RUN/deploy-result.json"
    jq -n --arg p "$RUN/deploy-result.json" '{inputs:{deploy_result:$p}}' > "$RUN/stage-inputs/validate.json"
    printf '{"run_id":"close"}\n' > "$RUN/state.json"
    export ZBUILD_STAGE_INPUTS="$RUN/stage-inputs/validate.json" ZBUILD_ARTIFACT_DIR="$RUN/artifacts"
    export ZBUILD_HEALTH_CHECK_URL="http://127.0.0.1:9/health"
}
_res() { jq -r "$1" "$RUN/artifacts/validate-result.json" 2>/dev/null || true; }

print_test_section "close-1: no artifact path is constructed in code"
_code="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE")"
_built="$(grep -nE 'dirname[[:space:]]+"\$state_file"|/stage-inputs\.json|/deploy-result\.json|/artifacts"?[[:space:]]*\}?$' <<< "$_code" || true)"
if [[ -z "$_built" ]]; then
    assert_pass "[close-1] plugin.sh derives no path from the state file or a filename"
else
    assert_fail "[close-1] plugin.sh derives no path from the state file or a filename" "$_built"
fi

print_test_section "close-2: no fallback when the engine gave no index"
_run_dir c2 1
# A stage-inputs.json beside the state file, naming a real deploy result — the
# shape PR #2213's fallback read. It must be ignored.
jq -n --arg p "$RUN/deploy-result.json" '{inputs:{deploy_result:$p}}' > "$RUN/stage-inputs.json"
unset ZBUILD_STAGE_INPUTS
_rc=0; ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[close-2] no engine index → the input is missing (rc=1)" "1" "$_rc"
assert_eq "[close-2] ...recorded as broken, not found by a guessed path" "broken" "$(_res .disposition)"

print_test_section "close-3: a failed probe keeps its diagnostics in the result"
_run_dir c3 1
_MOCK_HC_RC=7 _MOCK_HC_OUT="curl: (7) Failed to connect to 127.0.0.1 port 9"
_rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[close-3] the stage still exits 1 (clamped)" "1" "$_rc"
assert_eq "[close-3] data.probe_rc is the probe's own exit code" "7" "$(_res '.data.probe_rc // empty')"
assert_contains "[close-3] data.probe_output carries what the probe said" \
    "$(_res '.data.probe_output // empty')" "Failed to connect"
_MOCK_HC_RC=0 _MOCK_HC_OUT="HTTP/1.1 200 OK"

print_test_section "close-4: no probe target is misconfigured, not unhealthy"
rm -f "$_HC_CALLS_F"; _run_dir c4g 1
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || true
assert_eq "[close-4 guard] with a target set, the probe IS run (the recorder works)" "1" "$(_hc_calls)"
_run_dir c4 1
unset ZBUILD_HEALTH_CHECK_URL
rm -f "$_HC_CALLS_F"
_rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[close-4] exits 1" "1" "$_rc"
assert_eq "[close-4] disposition is misconfigured" "misconfigured" "$(_res .disposition)"
assert_contains "[close-4] the reason names what to set" "$(_res .reason)" "ZBUILD_HEALTH_CHECK_URL"
assert_eq "[close-4] the probe is not run" "0" "$(_hc_calls)"

print_test_section "close-5: the wrapper's no-state-file path writes a v2 result"
_run_dir c5 1
_rc=0; validate_agent_run "validate" >/dev/null 2>&1 || _rc=$?
assert_eq "[close-5] exits 1" "1" "$_rc"
assert_eq "[close-5] result_contract=2" "2" "$(_res '.result_contract // empty')"
assert_eq "[close-5] disposition=broken" "broken" "$(_res .disposition)"

print_test_section "close-6: no artifact dir given, none invented"
_run_dir c6 1
unset ZBUILD_ARTIFACT_DIR
rm -rf "$RUN/artifacts"
_rc=0; ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[close-6] exits 1" "1" "$_rc"
if [[ -d "$RUN/artifacts" ]]; then
    assert_fail "[close-6] no artifacts/ directory is created beside the state file" "it was created"
else
    assert_pass "[close-6] no artifacts/ directory is created beside the state file"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
