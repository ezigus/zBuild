#!/usr/bin/env bash
# tests/lib/cycle-stall-break-fixture.sh — #2191: the shared setup and the stubbed
# dispatch for the build_test_cycle stall-break tests, split across two files so
# neither exceeds the per-file timeout under a loaded CI runner.
# Sourced by core-pipeline-cycle-stall-break-test.sh and
# core-pipeline-cycle-reuse-and-route-back-test.sh AFTER print_test_header.


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"


export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# #2189: the stub below hands over reports through the engine's own extraction —
# sourced explicitly rather than relied on to arrive transitively.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"


# ─── SPEC-3 / SPEC-4 (stall-break vs converge) ───────────────────────────────
# Drive the REAL cycle_orchestrator_run with a stubbed dispatch hook. build always
# emits empty_diff; every mechanical gate passes; the gate-aggregator (the cycle's
# exit_when stage after the B6 #1138 cutover) verdict is parameterized.
_GA_VERDICT="fail"
# shellcheck disable=SC2317
cycle_dispatch_stage() {
    local _st_stage="$1" _st_iter="$2" _st_state_file="$3"
    local _st_dir; _st_dir="$(dirname "$_st_state_file")"
    local _art="$_st_dir/artifacts"; mkdir -p "$_art"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$_st_stage" in
        build)
            # ADR-054: new format — verdict=pass + disposition=complete + data.build_kind=empty_diff
            printf '{"schema_version":1,"result_contract":2,"verdict":"pass","disposition":"complete","data":{"build_kind":"empty_diff"},"iterations":1,"terminated_reason":"done_sentinel","files_changed":[]}' \
                > "$_art/build-summary.json"
            # #2183: a build that re-checked a finding and could not reproduce it.
            if [[ -n "${_BUILD_NOT_REPRODUCED:-}" ]]; then
                jq --arg p "$_BUILD_NOT_REPRODUCED" '.data.not_reproduced = [$p]' \
                    "$_art/build-summary.json" > "$_art/build-summary.json.tmp" \
                    && mv "$_art/build-summary.json.tmp" "$_art/build-summary.json"
            fi
            # #2178: a build that asked for files outside the contract.
            if [[ -n "${_BUILD_SCOPE_REQUEST:-}" ]]; then
                jq --argjson r "$_BUILD_SCOPE_REQUEST" '. + {scope_expansion_request: $r}' \
                    "$_art/build-summary.json" > "$_art/build-summary.json.tmp" \
                    && mv "$_art/build-summary.json.tmp" "$_art/build-summary.json"
            fi
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            _CYCLE_DISPATCH_DATA_KIND="empty_diff"
            # #2189: a real dispatch hands the cycle the member's report.
            _CYCLE_DISPATCH_REPORT="$(_verdict_report_from_file "$_art/build-summary.json")"
            ;;
        test)
            printf '{"result_contract":2,"verdict":"%s","disposition":"complete","reason":"mock","data":{"exit_code":0,"passed":1,"failed":0}}' "${_TEST_VERDICT:-pass}" \
                > "$_art/test-results.json"
            _CYCLE_DISPATCH_VERDICT="${_TEST_VERDICT:-pass}"
            _CYCLE_DISPATCH_VERDICT_RAW="${_TEST_VERDICT:-pass}"
            # v2: a failing suite is verdict=fail with rc 0 (rc 1 = broken).
            ;;
        acceptance-gate)
            _CYCLE_DISPATCH_VERDICT="${_AG_VERDICT:-pass}"
            _CYCLE_DISPATCH_VERDICT_RAW="${_AG_VERDICT:-pass}"
            ;;
        gate-aggregator)
            printf '{"schema_version":1,"verdict":"%s","summary":"x"}' "$_GA_VERDICT" \
                > "$_art/gate-aggregator-result.json"
            _CYCLE_DISPATCH_VERDICT="$_GA_VERDICT"
            _CYCLE_DISPATCH_VERDICT_RAW="$_GA_VERDICT"
            _CYCLE_DISPATCH_FAULT="${_GA_FAULT:-}"
            ;;
        *)
            # shape-floor, acceptance-gate, secret-scan: all pass (verdict
            # defaults set above) so only the aggregator gates. (#1129 Change C
            # dropped lint/coverage/mutation as cycle members.)
            :
            ;;
    esac
    return 0
}
# #2189: the stub plays the test stage, which reports a test count.
# shellcheck source=cycle-report-stub.sh
source "$REPO_ROOT/tests/lib/cycle-report-stub.sh"
zb_stub_reports_tests test

_run_cycle() {
    local _label="$1"
    local _sd="$TEST_TEMP_DIR/run-$_label/state"
    mkdir -p "$_sd/artifacts"
    printf '{"schema_version":1,"status":"in_progress"}' > "$_sd/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    set +e
    cycle_orchestrator_run "build_test_cycle" "$_sd" "$_sd/pipeline-state.json"
    _RUN_RC=$?
    set -e
}

# #1208: the #1117 empty-diff STALL-BREAK was REMOVED. "Run all tries": an
# empty_diff that never converges no longer terminates early — the cycle uses ALL
# its iterations (each cheap: build self-yields on an empty diff) and then
# terminates by-severity. Here the mock's `test` stage passes (gate-aggregator
# fails), so exhaustion routes to rc=2 (unconverged→review, reason
# max_iterations), NOT the old reason=stalled / ≤2-iter early break.
