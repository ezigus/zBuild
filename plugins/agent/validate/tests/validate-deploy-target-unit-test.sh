#!/usr/bin/env bash
# plugins/agent/validate/tests/validate-deploy-target-unit-test.sh — validate
# checks the deployment the deploy stage actually made.
#
# Why: validate required deploy's result but only checked that the file existed.
# It probed a fixed ZBUILD_HEALTH_CHECK_URL whatever deploy did — so a skipped
# or failed deploy still came back "healthy", and a deploy that reported where
# it went (a preview environment, a per-version URL) was never looked at.
#
# D1 [change] deploy did not deploy (it deployed nothing, or did not finish) →
#             validate passes with nothing to check, says so, and runs no probe
# D2 [change] deploy reported where it went (data.health_url) → that is probed
# D3 [guard]  deploy reported no address → the configured target is probed
# D4 [change] an address that is not http(s) is `misconfigured`, not probed
# D5 [change] a contract-3 stage declares no verdict words (#2366)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate probes the deployment deploy made"
setup_test_env "plugin-validate-deploy-target"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/validate/plugin.sh"
# shellcheck source=../../../../plugins/agent/validate/plugin.sh
source "$PLUGIN_FILE"
emit_event() { return 0; }

# The deploy result is made with the writer deploy uses (#2366).
# shellcheck source=../../../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

# Records which URL each probe saw — to a FILE, since the plugin calls the probe
# inside $( ).
_ZBUILD_HEALTH_CHECK_LOADED=1
_PROBES="$TEST_TEMP_DIR/probes"
health_check_run() { printf '%s\n' "${ZBUILD_HEALTH_CHECK_URL:-<none>}" >> "$_PROBES"; printf 'HTTP/1.1 200 OK\n'; return 0; }

# <name> <deploy outcome> <reason> [deployed true|false | data-json]. A deploy
# result is written by deploy's own writer; a data-json one only where deploy
# writes no such field (health_url, D2).
_run_dir() {
    RUN="$TEST_TEMP_DIR/$1"; mkdir -p "$RUN/artifacts" "$RUN/stage-inputs"
    if [[ "${4:-}" == "{"* ]]; then stage_result_write "$RUN/deploy-result.json" "$2" "$3" "$4"
    else zb_test_deploy_output "$RUN" "$2" "$3" "" "${5:-}" "${4:-}" >/dev/null; fi
    jq -n --arg p "$RUN/deploy-result.json" '{inputs:{deploy_result:$p}}' > "$RUN/stage-inputs/validate.json"
    printf '{"run_id":"dt"}\n' > "$RUN/state.json"
    export ZBUILD_STAGE_INPUTS="$RUN/stage-inputs/validate.json" ZBUILD_ARTIFACT_DIR="$RUN/artifacts"
    export ZBUILD_HEALTH_CHECK_URL="http://configured.example/health"
    rm -f "$_PROBES"
}
_res() { jq -r "$1" "$RUN/artifacts/validate-result.json" 2>/dev/null || true; }
_probed() { cat "$_PROBES" 2>/dev/null || true; }

print_test_section "D1: nothing was deployed"
for _dv in nothing unavailable; do
    if [[ "$_dv" == nothing ]]; then _run_dir "d1-$_dv" pass "nothing deployed: the run's loops did not all pass" false
    else _run_dir "d1-$_dv" unavailable "push failed"; fi
    _rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
    assert_eq "[D1] deploy $_dv → validate passes with nothing to check" "pass" "$(_res .outcome)"
    assert_eq "[D1] deploy $_dv → exits 0 (nothing to validate is not a failure)" "0" "$_rc"
    assert_contains "[D1] deploy $_dv → the reason says nothing was deployed" "$(_res .reason)" "nothing to validate"
    assert_eq "[D1] deploy $_dv → no probe ran" "" "$(_probed)"
done

print_test_section "D2/D3: which address is probed"
_run_dir d2 pass "deployed" '{"deployed":true,"health_url":"https://preview-42.example/health"}'
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || true
assert_eq "[D2] the address deploy reported is probed" "https://preview-42.example/health" "$(_probed)"
assert_eq "[D2] healthy" "pass" "$(_res .outcome)"

_run_dir d3 pass "deployed" true v1.2.3
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || true
assert_eq "[D3] no reported address → the configured target is probed" "http://configured.example/health" "$(_probed)"

print_test_section "D4: an unusable reported address"
_run_dir d4 pass "deployed" '{"deployed":true,"health_url":"file:///etc/passwd"}'
_rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[D4] misconfigured" "misconfigured" "$(_res .outcome)"
assert_eq "[D4] exits 1" "1" "$_rc"
assert_eq "[D4] not probed" "" "$(_probed)"

print_test_section "D5: no verdict words"
assert_eq "[D5] manifest declares no valid_verdicts (#2366)" "0" \
    "$(grep -v '^#' "$REPO_ROOT/plugins/agent/validate/manifest.yaml" | grep -c 'valid_verdicts' || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
