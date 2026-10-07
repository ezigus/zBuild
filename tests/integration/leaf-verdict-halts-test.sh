#!/usr/bin/env bash
# Integration (#1798, ADR-054 §4): a leaf stage that reports a failure with
# rc=0 ends the run.
#
# A cycle already acts on its members' verdicts. A leaf did not: the runner
# read the verdict, recorded it, emitted it, picked a glyph from it, and marked
# the stage `complete` anyway, so a run whose intake, plan or pr reported
# `fail` ended `success` and went on to open a pull request. #2231 closed the
# rejected-result case (a contract violation); this is the well-formed result
# that says it failed.
#
# Driven through the real runner with synthetic plugins (no model), on BOTH
# paths a leaf finishes on: the linear loop (flat flow) and the dispatch-unit
# loop (a flow with a cycle, as every shipped template has).
#
# SPEC-1 [change]: verdict fail|error|block|scope_violation|corrupt_diff
#   (a v2 result) → the run fails, the stage is `failed`, the run's end names
#   the verdict, the next stage never runs, the runner exits non-zero.
# SPEC-2 [change]: a v1 result with an unrecognised verdict word does not read
#   as success. [guard] truncated JSON and non-JSON already end the run as a
#   rejected result (contract_violation:malformed_json, #2231); kept here so the
#   whole "not a verdict" row is pinned in one place.
# SPEC-3 [change]: a stage the template marks `blocking: false` is advisory:
#   its failing verdict is recorded and the run goes on.
# SPEC-4 [guard]: pass and warn-class verdicts (pass, degraded) still complete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a leaf stage that reports a failure ends the run (#1798, ADR-054 §4)"
setup_test_env "leaf-verdict-halts"

_ZB_ID="$(zb_test_issue)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
AFTER_LOG="$TEST_TEMP_DIR/after.log"

export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export VL_AFTER_LOG="$AFTER_LOG"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# _plugin <id> <contract: 1|2> <body of the run function>
_plugin() {
    local id="$1" contract="$2" fn="${1//-/_}_run" dir="$PLUGINS_ROOT/tool/$1"
    mkdir -p "$dir"
    {
        cat <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: $fn
requires:
  core: [event-bus]
EOF
        [[ "$contract" == 2 ]] && printf 'provides:\n  result_contract: 2\n'
        cat <<EOF
inputs: []
outputs:
  - id: ${fn}_out
    path: \${artifact_dir}/$id-result.json
    type: json
    required: true
    primary: true
valid_verdicts: [pass, degraded, fail, error, block, scope_violation, corrupt_diff]
EOF
    } > "$dir/manifest.yaml"
    printf '%s() {\n    local d; d="$(dirname "$2")/artifacts"; mkdir -p "$d"\n%s\n}\n' \
        "$fn" "$3" > "$dir/plugin.sh"
}

# vl-leaf writes exactly VL_BODY (a whole result file), so a case can be a v2
# result, a v1 result, or bytes that are not a result at all. Its manifest is
# rewritten per case: VL_CONTRACT 2 declares contract v2, 1 leaves it v1.
_vl_leaf() {
    _plugin vl-leaf "$1" '    printf "%s" "${VL_BODY:?}" > "$d/vl-leaf-result.json"; return 0'
}
_plugin vl-noop 2 '    printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}'"'"' > "$d/vl-noop-result.json"; return 0'
_plugin vl-after 2 '    printf '"'"'ran\n'"'"' >> "${VL_AFTER_LOG:?}"
    printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}'"'"' > "$d/vl-after-result.json"; return 0'

OVERLAY_REPO="$(setup_git_temp_repo vl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" leaf-verdict-halt leaf-verdict-halt-units \
    leaf-verdict-halt-advisory leaf-verdict-halt-units-advisory

_v2() { printf '{"result_contract":2,"verdict":"%s","disposition":"complete","reason":"the stage says %s"}' "$1" "$1"; }

_run() {  # <template> <cycles_enabled>
    rm -rf "$STATE_DIR" "$EVENTS_JSONL"; mkdir -p "$STATE_DIR"; : > "$AFTER_LOG"
    set +e
    ( cd "$OVERLAY_REPO" && ZBUILD_CYCLES_ENABLED="$2" \
        bash "$RUNNER" --issue "$_ZB_ID" --template "$1" --no-resume ) \
        >"$TEST_TEMP_DIR/runner.out" 2>"$TEST_TEMP_DIR/runner.err"
    _RC=$?
    set -e
    _END="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | tail -1)"
    _END_REASON="$(jq -r 'select(.type=="pipeline.end") | .data.reason // empty' "$EVENTS_JSONL" 2>/dev/null | tail -1)"
    _AFTER="$(/usr/bin/grep -c ran "$AFTER_LOG" 2>/dev/null || true)"
    _STATUS="$(jq -r '.stage_statuses["vl-leaf"] // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
    _DISPATCHED="$(jq -r 'select(.type=="plugin.run.start") | .data.plugin' "$EVENTS_JSONL" 2>/dev/null || true)"
}

# _expect_halt <label> <template> <cycles> <word the end must name>
_expect_halt() {
    _run "$2" "$3"
    # Non-vacuous: vl-leaf must have been dispatched at all.
    assert_contains "[$1] premise: vl-leaf was dispatched" "$_DISPATCHED" "vl-leaf"
    assert_eq "[$1] the run ends failed" "failed" "$_END"
    assert_eq "[$1] the stage is recorded failed, not complete" "failed" "$_STATUS"
    assert_contains "[$1] the run's end names what the stage reported" "$_END_REASON" "$4"
    assert_eq "[$1] the next stage never runs" "0" "$_AFTER"
    if [[ $_RC -ne 0 ]]; then
        assert_pass "[$1] the runner exits non-zero"
    else
        assert_fail "[$1] the runner exits non-zero" "rc=0"
    fi
}

# _expect_goes_on <label> <template> <cycles>
_expect_goes_on() {
    _run "$2" "$3"
    assert_contains "[$1] premise: vl-leaf was dispatched" "$_DISPATCHED" "vl-leaf"
    assert_eq "[$1] the run succeeds" "success" "$_END"
    assert_eq "[$1] the stage is complete" "complete" "$_STATUS"
    assert_eq "[$1] the next stage runs" "1" "$_AFTER"
}

for _loop in "linear:leaf-verdict-halt:0" "units:leaf-verdict-halt-units:1"; do
    IFS=: read -r _name _tpl _cyc <<< "$_loop"

    print_test_section "[SPEC-1][change] $_name loop — a failing verdict ends the run"
    _vl_leaf 2
    for _w in fail error block scope_violation corrupt_diff; do
        export VL_BODY; VL_BODY="$(_v2 "$_w")"
        _expect_halt "SPEC-1 $_name $_w" "$_tpl" "$_cyc" "$_w"
    done

    print_test_section "[SPEC-2][change] $_name loop — a result that is not a verdict is not success"
    _vl_leaf 1
    VL_BODY='{"verdict":"pa'; _expect_halt "SPEC-2 $_name truncated JSON" "$_tpl" "$_cyc" "malformed_json"
    VL_BODY='this is not a result'; _expect_halt "SPEC-2 $_name non-JSON" "$_tpl" "$_cyc" "malformed_json"
    VL_BODY='{"verdict":"splendid"}'; _expect_halt "SPEC-2 $_name unrecognised word" "$_tpl" "$_cyc" "unknown"

    print_test_section "[SPEC-3][change] $_name loop — a stage marked blocking: false is advisory"
    _vl_leaf 2
    VL_BODY="$(_v2 fail)"; _expect_goes_on "SPEC-3 $_name advisory fail" "$_tpl-advisory" "$_cyc"

    print_test_section "[SPEC-4][guard] $_name loop — pass and warn still complete"
    VL_BODY="$(_v2 pass)"; _expect_goes_on "SPEC-4 $_name pass" "$_tpl" "$_cyc"
    VL_BODY="$(_v2 degraded)"; _expect_goes_on "SPEC-4 $_name degraded" "$_tpl" "$_cyc"
done
unset VL_BODY

print_test_results
