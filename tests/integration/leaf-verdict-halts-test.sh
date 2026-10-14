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
# SPEC-1 [change]: outcome fail, or broken (a contract-3 result, #2366) → the
#   run fails, the stage is `failed`, the run's end names what it reported, the
#   next stage never runs, the runner exits non-zero. (Contract 2's other
#   failing words — error, block, scope_violation, corrupt_diff — no longer
#   exist: a stage reports fail, or how it ended.)
# SPEC-2 [guard]: a result that is not a verdict does not read as success.
#   Truncated JSON and non-JSON end the run as a rejected result
#   (contract_violation:malformed_json), and so does an outcome off the engine's
#   list (contract_violation:unknown_outcome, #2366; it was an undeclared
#   verdict word, #2231). Kept
#   here so the whole row is pinned in one place. (A v1 plugin no longer loads
#   at all since #1850 — v1-retired-test.sh R1/R2.)
# SPEC-3 [change]: a stage the template marks `blocking: false` is advisory:
#   its failing verdict is recorded and the run goes on.
# SPEC-4 [guard]: pass still completes. (Contract 2's warn class — degraded —
#   is gone with #2366: a stage reports pass or fail.)
# SPEC-5 (#1850): a leaf that exits 0 having written no result at all ends the
#   run, and the RUN fails, not merely the verdict. [guard] a primary marked
#   `required: true` was already refused by the artifact check (#1803);
#   [change] one that is not was softened to `warn` by the reader and the run
#   went on.
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

# #2366: stub bodies and results are written with the engine's writer.
export STAGE_RESULT_LIB="$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$STAGE_RESULT_LIB"

# _plugin <id> <contract: 1|3> <body of the run function> [required: true|false]
_plugin() {
    local id="$1" contract="$2" fn="${1//-/_}_run" dir="$PLUGINS_ROOT/tool/$1" req="${4:-true}"
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
        [[ "$contract" == 3 ]] && printf 'provides:\n  result_contract: 3\n'
        cat <<EOF
inputs: []
outputs:
  - id: ${fn}_out
    path: \${artifact_dir}/$id-result.json
    type: json
    required: $req
    primary: true
EOF
    } > "$dir/manifest.yaml"
    printf '%s() {\n    local d; d="$(dirname "$2")/artifacts"; mkdir -p "$d"\n%s\n}\n' \
        "$fn" "$3" > "$dir/plugin.sh"
}

# vl-leaf writes exactly VL_BODY (a whole result file), so a case can be a
# contract-3 result, or bytes that are not a result at all. Its manifest is
# rewritten per case: 3 declares contract 3.
_vl_leaf() {  # <contract> [required]
    _plugin vl-leaf "$1" '    if [[ -n "${VL_BODY:-}" ]]; then printf "%s" "$VL_BODY" > "$d/vl-leaf-result.json"; fi; return 0' "${2:-true}"
}
_plugin vl-noop 3 '    source "$STAGE_RESULT_LIB"; stage_result_write "$d/vl-noop-result.json" pass ok; return 0'
_plugin vl-after 3 '    printf '"'"'ran\n'"'"' >> "${VL_AFTER_LOG:?}"
    source "$STAGE_RESULT_LIB"; stage_result_write "$d/vl-after-result.json" pass ok; return 0'

OVERLAY_REPO="$(setup_git_temp_repo vl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" leaf-verdict-halt leaf-verdict-halt-units \
    leaf-verdict-halt-advisory leaf-verdict-halt-units-advisory

# _res <outcome> — a whole contract-3 result, made with the engine's writer.
_res() { stage_result_write "$TEST_TEMP_DIR/res.json" "$1" "the stage says $1" && cat "$TEST_TEMP_DIR/res.json"; }

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
    _vl_leaf 3
    for _w in fail broken; do
        export VL_BODY; VL_BODY="$(_res "$_w")"
        _expect_halt "SPEC-1 $_name $_w" "$_tpl" "$_cyc" "${_w/broken/error}"
    done

    print_test_section "[SPEC-2][guard] $_name loop — a result that is not a verdict is not success"
    _vl_leaf 3
    VL_BODY='{"outcome":"pa'; _expect_halt "SPEC-2 $_name truncated JSON" "$_tpl" "$_cyc" "malformed_json"
    VL_BODY='this is not a result'; _expect_halt "SPEC-2 $_name non-JSON" "$_tpl" "$_cyc" "malformed_json"
    VL_BODY='{"result_contract":3,"outcome":"splendid","reason":"the stage says splendid"}'
    _expect_halt "SPEC-2 $_name word off the outcome list" "$_tpl" "$_cyc" "unknown_outcome"

    print_test_section "[SPEC-3][change] $_name loop — a stage marked blocking: false is advisory"
    _vl_leaf 3
    VL_BODY="$(_res fail)"; _expect_goes_on "SPEC-3 $_name advisory fail" "$_tpl-advisory" "$_cyc"

    print_test_section "[SPEC-5][change] $_name loop — exit 0 with no result written ends the run (#1850)"
    VL_BODY=""; _expect_halt "SPEC-5 $_name absent required result" "$_tpl" "$_cyc" ""
    _vl_leaf 3 false
    VL_BODY=""; _expect_halt "SPEC-5 $_name absent result, primary not marked required" "$_tpl" "$_cyc" "contract_violation:missing_result"
    _vl_leaf 3

    print_test_section "[SPEC-4][guard] $_name loop — pass still completes"
    VL_BODY="$(_res pass)"; _expect_goes_on "SPEC-4 $_name pass" "$_tpl" "$_cyc"
done
unset VL_BODY

print_test_results
