#!/usr/bin/env bash
# plugins/agent/validate/tests/validate-deploy-target-unit-test.sh — validate
# checks the deployment the deploy stage actually made.
#
# Why: validate required deploy's result but only checked that the file existed.
# It probed a fixed ZBUILD_HEALTH_CHECK_URL whatever deploy did — so a skipped
# or failed deploy still came back "healthy", and a deploy that reported where
# it went (a preview environment, a per-version URL) was never looked at.
#
# D1 [change] deploy did not deploy (skipped / error) → validate says `skipped`,
#             names deploy's verdict, and runs no probe
# D2 [change] deploy reported where it went (data.health_url) → that is probed
# D3 [guard]  deploy reported no address → the configured target is probed
# D4 [change] an address that is not http(s) is `misconfigured`, not probed
# D5 [guard]  `skipped` is a declared verdict (valid_verdicts)
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

# Records which URL each probe saw — to a FILE, since the plugin calls the probe
# inside $( ).
_ZBUILD_HEALTH_CHECK_LOADED=1
_PROBES="$TEST_TEMP_DIR/probes"
health_check_run() { printf '%s\n' "${ZBUILD_HEALTH_CHECK_URL:-<none>}" >> "$_PROBES"; printf 'HTTP/1.1 200 OK\n'; return 0; }

_run_dir() {  # <name> <deploy-result json>
    RUN="$TEST_TEMP_DIR/$1"; mkdir -p "$RUN/artifacts" "$RUN/stage-inputs"
    printf '%s\n' "$2" > "$RUN/deploy-result.json"
    jq -n --arg p "$RUN/deploy-result.json" '{inputs:{deploy_result:$p}}' > "$RUN/stage-inputs/validate.json"
    printf '{"run_id":"dt"}\n' > "$RUN/state.json"
    export ZBUILD_STAGE_INPUTS="$RUN/stage-inputs/validate.json" ZBUILD_ARTIFACT_DIR="$RUN/artifacts"
    export ZBUILD_HEALTH_CHECK_URL="http://configured.example/health"
    rm -f "$_PROBES"
}
_res() { jq -r "$1" "$RUN/artifacts/validate-result.json" 2>/dev/null || true; }
_probed() { cat "$_PROBES" 2>/dev/null || true; }

print_test_section "D1: nothing was deployed"
for _dv in skipped error; do
    _run_dir "d1-$_dv" "{\"verdict\":\"$_dv\",\"reason\":\"gate not pass\"}"
    _rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
    assert_eq "[D1] deploy $_dv → validate verdict skipped" "skipped" "$(_res .verdict)"
    assert_eq "[D1] deploy $_dv → exits 0 (nothing to validate is not a failure)" "0" "$_rc"
    assert_contains "[D1] deploy $_dv → the reason names deploy's verdict" "$(_res .reason)" "$_dv"
    assert_eq "[D1] deploy $_dv → no probe ran" "" "$(_probed)"
done

print_test_section "D2/D3: which address is probed"
_run_dir d2 '{"verdict":"deployed","data":{"health_url":"https://preview-42.example/health"}}'
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || true
assert_eq "[D2] the address deploy reported is probed" "https://preview-42.example/health" "$(_probed)"
assert_eq "[D2] healthy" "healthy" "$(_res .verdict)"

_run_dir d3 '{"verdict":"deployed","data":{"tag":"v1.2.3"}}'
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || true
assert_eq "[D3] no reported address → the configured target is probed" "http://configured.example/health" "$(_probed)"

print_test_section "D4: an unusable reported address"
_run_dir d4 '{"verdict":"deployed","data":{"health_url":"file:///etc/passwd"}}'
_rc=0; ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$RUN/state.json" >/dev/null 2>&1 || _rc=$?
assert_eq "[D4] misconfigured" "misconfigured" "$(_res .disposition)"
assert_eq "[D4] exits 1" "1" "$_rc"
assert_eq "[D4] not probed" "" "$(_probed)"

print_test_section "D5: skipped is declared"
_vv="$(awk '/valid_verdicts:/{f=1;next} f && /^[[:space:]]*-/{print;next} f{exit}' \
        "$REPO_ROOT/plugins/agent/validate/manifest.yaml")"
if grep -qE '^[[:space:]]*-[[:space:]]*skipped[[:space:]]*$' <<< "$_vv"; then
    assert_pass "[D5] valid_verdicts declares skipped"
else
    assert_fail "[D5] valid_verdicts declares skipped" "absent"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
