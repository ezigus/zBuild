#!/usr/bin/env bash
# Integration: a leaf stage whose v2 result the engine rejects ends the run.
#
# The engine already classifies a malformed v2 result as a contract violation
# (verdict.sh) and a cycle halts on it. A LEAF stage recorded it as `error` and
# the run carried on — #1835's run shipped a plan whose success result had no
# `reason`, and only a golden diff noticed. A contract violation is a zBuild
# defect (ADR-054 §6: `broken` — halt, file a bug), never transient, so ending
# the run on it cannot turn a network hiccup into a dead run (the concern #1798
# waits on).
#
# SPEC-1 [change]: flat flow (linear loop) — result missing `reason` → the run
#   fails, names the violation, and the next stage is never dispatched.
# SPEC-2 [change]: same on a flow with a cycle (dispatch-unit loop).
# SPEC-3 [guard]:  a conformant v2 result still completes and the run goes on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a leaf stage's rejected v2 result ends the run (ADR-054 §4/§6)"
setup_test_env "leaf-contract-violation"

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
export CV_AFTER_LOG="$AFTER_LOG"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

_plugin() {  # <id> <body of the run function>
    local id="$1" fn="${1//-/_}_run" dir="$PLUGINS_ROOT/tool/$1"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: $fn
requires:
  core: [event-bus]
provides:
  result_contract: 2
inputs: []
outputs:
  - id: ${fn}_out
    path: \${artifact_dir}/$id-result.json
    type: json
    required: true
    primary: true
valid_verdicts: [pass]
EOF
    printf '%s() {\n    local d; d="$(dirname "$2")/artifacts"; mkdir -p "$d"\n%s\n}\n' \
        "$fn" "$2" > "$dir/plugin.sh"
}

# cv-leaf: CV_REASON unset → the #1835 shape (no reason); set → conformant.
_plugin cv-leaf '    if [[ -n "${CV_REASON:-}" ]]; then
        printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"%s"}'"'"' "$CV_REASON" > "$d/cv-leaf-result.json"
    else
        printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete"}'"'"' > "$d/cv-leaf-result.json"
    fi
    return 0'
_plugin cv-noop '    printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}'"'"' > "$d/cv-noop-result.json"; return 0'
_plugin cv-after '    printf '"'"'ran\n'"'"' >> "${CV_AFTER_LOG:?}"
    printf '"'"'{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}'"'"' > "$d/cv-after-result.json"; return 0'

OVERLAY_REPO="$(setup_git_temp_repo cv-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" leaf-contract-violation leaf-contract-violation-units

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
}

_expect_halt() {  # <spec> <template> <cycles>
    unset CV_REASON
    _run "$2" "$3"
    # Non-vacuous: cv-leaf must have been dispatched at all.
    assert_contains "[$1] premise: cv-leaf was dispatched" \
        "$(jq -r 'select(.type=="plugin.run.start") | .data.plugin' "$EVENTS_JSONL" 2>/dev/null)" "cv-leaf"
    assert_eq "[$1] the run ends failed" "failed" "$_END"
    assert_contains "[$1] and says why: the rejected result" "$_END_REASON" "contract_violation:missing_field:reason"
    assert_eq "[$1] the next stage is never dispatched" "0" "$_AFTER"
    [[ $_RC -ne 0 ]] && assert_pass "[$1] the runner exits non-zero" \
        || assert_fail "[$1] the runner exits non-zero" "rc=0"
}

print_test_section "[SPEC-1][change] flat flow — linear loop"
_expect_halt SPEC-1 leaf-contract-violation 0

print_test_section "[SPEC-2][change] flow with a cycle — dispatch-unit loop"
_expect_halt SPEC-2 leaf-contract-violation-units 1

print_test_section "[SPEC-3][guard] a conformant result still completes"
export CV_REASON="decided"
_run leaf-contract-violation 0
assert_eq "[SPEC-3] linear loop: the run succeeds" "success" "$_END"
assert_eq "[SPEC-3] linear loop: the next stage runs" "1" "$_AFTER"
_run leaf-contract-violation-units 1
assert_eq "[SPEC-3] unit loop: the run succeeds" "success" "$_END"
assert_eq "[SPEC-3] unit loop: the next stage runs" "1" "$_AFTER"
unset CV_REASON

print_test_results
