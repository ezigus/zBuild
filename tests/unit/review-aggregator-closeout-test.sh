#!/usr/bin/env bash
# tests/unit/review-aggregator-closeout-test.sh — what #1842's migration left
# undone: the aggregator reads only what the engine hands it, writes only where
# the engine says, and never calls an absent review "ready".
#
# K1 [change] the hook writes into ZBUILD_ARTIFACT_DIR — not a directory derived
#             from the state file's location
# K2 [change] no ZBUILD_ARTIFACT_DIR → rc 1 (never 2) and the error names it
# K3 [guard]  lenses come only from the engine's lens_result set: a lens file
#             lying in the artifacts dir that the engine did not hand over is not
#             aggregated
# K4 [change] no ZBUILD_STAGE_INPUTS → a v2 result that says so (degraded /
#             misconfigured), rc 1, and still the summary — never a glob fallback
# K5 [change] zero lens results is not "ready" (#1753): needs_attention, and the
#             summary says no review happened
# K6 [change] the manifest requires lens_result, so the engine refuses to
#             dispatch an aggregator with nothing to aggregate
# K7 [change] roster and find discovery are gone from plugin.sh
# K8 [change] a signal ends the stage with rc 1 and the guard's disposition
# K9 [change] the verdict key is written literally, not assembled to dodge a grep
# K10 [guard] a passing run's report is unchanged from main's v1 plugin, apart
#             from the v2 envelope (golden: tests/golden/review-aggregator-*)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-aggregator — engine inputs only, no vacuous ready (#1842)"
setup_test_env "review-aggregator-closeout"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
unset ZBUILD_STAGE_INPUTS ZBUILD_ARTIFACT_DIR ZBUILD_CURRENT_STAGE

PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-aggregator"
MANIFEST="$PLUGIN_DIR/manifest.yaml"
# shellcheck source=../../plugins/agent/review-aggregator/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

_f() { jq -r --arg k "$1" '.[$k] // empty' "$2" 2>/dev/null; }
# _inputs <file> <lens-path>... — an engine-style stage-inputs index.
_inputs() {
    local out="$1"; shift
    jq -n '{schema_version:1, stage:"review-aggregator", inputs:{lens_result:$ARGS.positional}}' \
        --args "$@" > "$out"
}
_lens() { printf '{"schema_version":1,"name":"%s","score":%s,"findings":[]}\n' "$2" "$3" > "$1"; }

print_test_section "K1/K2: output goes where the engine says"
_k1="$TEST_TEMP_DIR/k1"; mkdir -p "$_k1/state/artifacts" "$_k1/out" "$_k1/lenses"
printf '{}\n' > "$_k1/state/pipeline-state.json"
_lens "$_k1/lenses/lens-a.json" a 8
_inputs "$_k1/inputs.json" "$_k1/lenses/lens-a.json"
ZBUILD_ARTIFACT_DIR="$_k1/out" ZBUILD_STAGE_INPUTS="$_k1/inputs.json" \
    review_aggregator_run review-aggregator "$_k1/state/pipeline-state.json" >/dev/null 2>&1
assert_file_exists "[K1] the report is written to ZBUILD_ARTIFACT_DIR" "$_k1/out/review-report.json"
if [[ -e "$_k1/state/artifacts/review-report.json" ]]; then
    assert_fail "[K1] nothing is written beside the state file" "state/artifacts/review-report.json exists"
else
    assert_pass "[K1] nothing is written beside the state file"
fi
_err="$(ZBUILD_STAGE_INPUTS="$_k1/inputs.json" review_aggregator_run review-aggregator \
    "$_k1/state/pipeline-state.json" 2>&1 >/dev/null)"; _rc=$?
assert_eq "[K2] no ZBUILD_ARTIFACT_DIR → rc 1" "1" "$_rc"
assert_contains "[K2] ...and the error names it" "$_err" "ZBUILD_ARTIFACT_DIR"

print_test_section "K3/K4: only the engine's lens set"
_k3="$TEST_TEMP_DIR/k3"; mkdir -p "$_k3"
_lens "$_k3/lens-handed.json" handed 8
_lens "$_k3/lens-stray.json" stray 2
_inputs "$_k3/inputs.json" "$_k3/lens-handed.json"
ZBUILD_ARTIFACT_DIR="$_k3" ZBUILD_STAGE_INPUTS="$_k3/inputs.json" \
    review_aggregator_run review-aggregator "$_k3/x" >/dev/null 2>&1
assert_eq "[K3] only the handed lens is aggregated" '["handed"]' \
    "$(jq -c '[.lenses[].name]' "$_k3/review-report.json" 2>/dev/null || echo MISSING)"

_k4="$TEST_TEMP_DIR/k4"; mkdir -p "$_k4"
_lens "$_k4/lens-stray.json" stray 9
ZBUILD_ARTIFACT_DIR="$_k4" review_aggregator_run review-aggregator "$_k4/x" >/dev/null 2>&1; _rc=$?
assert_eq "[K4] no stage inputs → rc 1" "1" "$_rc"
assert_eq "[K4] ...a v2 result" "2" "$(_f result_contract "$_k4/review-report.json")"
assert_eq "[K4] ...verdict degraded" "degraded" "$(_f verdict "$_k4/review-report.json")"
assert_eq "[K4] ...disposition misconfigured" "misconfigured" "$(_f disposition "$_k4/review-report.json")"
assert_eq "[K4] ...no lens found by looking in the directory" "0" \
    "$(jq '.lenses | length' "$_k4/review-report.json" 2>/dev/null || echo MISSING)"
assert_file_exists "[K4] ...and the summary is still written" "$_k4/review-report.md"

print_test_section "K5/K6: zero lenses is not a review"
_k5="$TEST_TEMP_DIR/k5"; mkdir -p "$_k5"
_inputs "$_k5/inputs.json"
ZBUILD_ARTIFACT_DIR="$_k5" ZBUILD_STAGE_INPUTS="$_k5/inputs.json" \
    review_aggregator_run review-aggregator "$_k5/x" >/dev/null 2>&1
assert_eq "[K5] zero lens results → needs_attention, never ready" "needs_attention" \
    "$(_f merge_readiness "$_k5/review-report.json")"
assert_contains "[K5] ...the summary says no review happened" \
    "$(_f summary "$_k5/review-report.json")" "no review happened"
_req="$(awk '/- id: lens_result/{f=1; next} f && /required:/{print $2; exit}' "$MANIFEST")"
assert_eq "[K6] lens_result is required: true" "true" "$_req"

print_test_section "K7/K9: no self-discovery, no dodged key"
for _sym in _ra_resolve_group _ra_collect_lenses_roster _ra_member_manifest '_TPL_PARALLEL' 'find '; do
    if grep -qF -- "$_sym" "$PLUGIN_DIR/plugin.sh"; then
        assert_fail "[K7] plugin.sh no longer discovers lenses itself ($_sym)" "still present"
    else
        assert_pass "[K7] plugin.sh no longer discovers lenses itself ($_sym)"
    fi
done
if grep -qF "printf 'verd'" "$PLUGIN_DIR/plugin.sh"; then
    assert_fail "[K9] the verdict key is written literally" "assembled from pieces"
else
    assert_pass "[K9] the verdict key is written literally"
fi

print_test_section "K8: a signal"
_k8="$TEST_TEMP_DIR/k8"; mkdir -p "$_k8"
_inputs "$_k8/inputs.json"
_ready="$_k8/ready"
(
    # shellcheck disable=SC2317  # reached through the plugin's call
    _ra_aggregate() { touch "$_ready"; sleep 20 & wait $!; printf '{}'; }
    ZBUILD_ARTIFACT_DIR="$_k8" ZBUILD_STAGE_INPUTS="$_k8/inputs.json" \
        review_aggregator_run review-aggregator "$_k8/x"
) >/dev/null 2>&1 &
_pid=$!
for _ in $(seq 1 50); do [[ -f "$_ready" ]] && break; sleep 0.1; done
kill -TERM "$_pid" 2>/dev/null; wait "$_pid"; _rc=$?
assert_eq "[K8] a signal ends the stage with rc 1" "1" "$_rc"
assert_eq "[K8] ...disposition from the shared guard" "$STAGE_SIGNAL_DISPOSITION" "$(_f disposition "$_k8/review-report.json")"
assert_eq "[K8] ...reason from the shared guard" "$STAGE_SIGNAL_REASON" "$(_f reason "$_k8/review-report.json")"

print_test_section "K10: a passing run is unchanged"
_k10="$TEST_TEMP_DIR/k10"; mkdir -p "$_k10"
printf '%s\n' '{"schema_version":1,"name":"correctness","score":6,"findings":[{"file":"core/x.sh","category":"logic","severity":"medium","line":42,"message":"off-by-one in loop"}],"result_contract":2,"verdict":"complete","disposition":"complete","reason":"reviewed"}' > "$_k10/lens-correctness.json"
printf '%s\n' '{"schema_version":1,"name":"security","score":8,"findings":[{"file":"core/x.sh","category":"logic","severity":"high","line":47,"message":"same region higher severity"},{"file":"core/z.sh","category":"style","severity":"low","line":3,"message":"pre-existing","introduced":false}],"result_contract":2,"verdict":"complete","disposition":"complete","reason":"reviewed"}' > "$_k10/lens-security.json"
printf '%s\n' '{"schema_version":1,"name":"performance","score":9,"findings":[],"result_contract":2,"verdict":"complete","disposition":"complete","reason":"reviewed"}' > "$_k10/lens-performance.json"
_inputs "$_k10/inputs.json" "$_k10/lens-correctness.json" "$_k10/lens-security.json" "$_k10/lens-performance.json"
ZBUILD_ARTIFACT_DIR="$_k10" ZBUILD_STAGE_INPUTS="$_k10/inputs.json" \
    review_aggregator_run review-aggregator "$_k10/x" >/dev/null 2>&1
assert_eq "[K10] the report matches main's v1 output, less the v2 envelope" \
    "$(cat "$REPO_ROOT/tests/golden/review-aggregator-output-v1.golden")" \
    "$(jq -S 'del(.result_contract, .verdict, .disposition, .reason)' "$_k10/review-report.json" 2>/dev/null)"
assert_eq "[K10] ...and the rendered summary matches" \
    "$(cat "$REPO_ROOT/tests/golden/review-aggregator-report-md-v1.golden")" \
    "$(cat "$_k10/review-report.md" 2>/dev/null)"
assert_eq "[K10] ...with the envelope complete/complete" "complete/complete" \
    "$(_f verdict "$_k10/review-report.json")/$(_f disposition "$_k10/review-report.json")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
