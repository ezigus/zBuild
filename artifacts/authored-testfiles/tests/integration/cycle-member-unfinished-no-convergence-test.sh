#!/usr/bin/env bash
# tests/integration/cycle-member-unfinished-no-convergence-test.sh
#
# [#2032]: an unfinished cycle member must block convergence even when the
# exit_when predicate matches. A design_verify_cycle has no build member, so
# the existing build-unfinished suppression (cycle.build_unfinished.suppressed_convergence)
# does not fire when design times out — the gap SPEC-1 closes.
#
# SPEC-1 [#2032/SPEC-1] [change]: when converged==0 (exit_when predicate matched)
#   and any iteration member carries an unfinished disposition (timed_out,
#   out_of_turns, or interrupted), the cycle does NOT converge — it emits
#   cycle.member_unfinished.suppressed_convergence and iterates instead.
#   Test must FAIL on old code (false convergence after iter 1).
#
# SPEC-2 [#2032/SPEC-2] [guard]: when all members carry disposition:complete and
#   exit_when predicate matches, the cycle converges normally; the new suppression
#   block does not fire.
#
# SPEC-6 [#2032/SPEC-6] [change]: at max_iterations when the last iteration has any
#   member with an unfinished disposition, the §4/A suppression block fires
#   (preventing false complete), and the cycle takes the existing #1261 exhaustion
#   path — emitting cycle.timeout_exhausted with reason=design_timeout_exhausted and
#   term_rc=8, not rc=0 complete.
#   Test must FAIL on old code (false convergence → rc=0 instead of rc=8).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle: unfinished member blocks convergence even when exit_when matches (#2032)"
setup_test_env "cycle-member-unfinished-no-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# verdict_classify lives in verdict.sh; the mock calls it to classify raw verdicts.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ── design_verify_cycle fixture ───────────────────────────────────────────────
# stages: design + design-gate; exit_when on design-gate.verdict==pass
# max_iterations: 3 (enough for SPEC-1 to suppress once, then converge; enough
# for SPEC-6 to exhaust with all iters unfinished)
DESIGN_TPL="$TEST_TEMP_DIR/design-verify-cycle.yaml"
cat > "$DESIGN_TPL" <<'YAML'
id: design2032
name: design verify cycle — unfinished member convergence test
defaults:
  strategy: fanout
stages:
  - id: design-verify
    type: cycle
    stages: [design, design-gate]
    until:
      stage: design-gate
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
  design-gate:
    roles: [design_gate]
YAML

# ── Mock dispatch ─────────────────────────────────────────────────────────────
# Mock plan format: "stage:v1,v2,...;stage2:v1,v2,..."
# Verdicts:
#   dnf  — disposition=interrupted (mid-flight, unfinished)
#   pass — disposition=complete, verdict=pass
#   fail — verdict=fail (content non-convergence)
# design-gate with verdict=pass makes exit_when predicate match.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v="pass"
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            v="${vs[$idx]}"
            break
        fi
    done
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    _CYCLE_DISPATCH_DISPOSITION=""
    _CYCLE_DISPATCH_DATA_KIND=""
    _CYCLE_DISPATCH_REPORT="{}"
    local rv="$v"
    if [[ "$v" == "dnf" ]]; then
        # ADR-054 (#1832): disposition=interrupted is the signal for a mid-flight stage.
        rv="incomplete"
        _CYCLE_DISPATCH_DISPOSITION="interrupted"
        _CYCLE_DISPATCH_REASON="router_timeout"
    elif [[ "$v" == "fail" ]]; then
        rv="fail"
        _CYCLE_DISPATCH_DISPOSITION="complete"
    else
        _CYCLE_DISPATCH_DISPOSITION="complete"
    fi
    _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$rv" 2>/dev/null || echo warn)"
    _CYCLE_DISPATCH_VERDICT_RAW="$rv"
    return 0
}

_seed() {
    STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

_run() {
    # $1 = template, $2 = cycle id, $3 = MOCK_PLAN
    _seed
    load_template "$1"
    MOCK_PLAN="$3"
    set +e
    cycle_orchestrator_run "$2" "$ZBUILD_STATE_DIR" "$STATE_FILE"
    RUN_RC=$?
    set -e
}

# ── SPEC-1 [#2032/SPEC-1]: unfinished member suppresses convergence, iterates ─
# design times out on iter 1 (disposition=interrupted); design-gate passes (exit_when
# matches). Old code: false convergence after iter 1 (rc=0, iter_count=1).
# New code: suppression fires, iterate; design succeeds iter 2, converge (rc=0,
# iter_count=2). Assertions that FAIL on old code: suppression event + iter_count>1.
print_test_section "SPEC-1 [#2032/SPEC-1]: design=dnf/pass + gate=pass → suppression on iter1, converges iter2"
_run "$DESIGN_TPL" "design-verify" "design:dnf,pass,pass;design-gate:pass,pass,pass"
assert_contains "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence emitted (not on old code)" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.member_unfinished.suppressed_convergence"
if [[ "${_CYCLE_LAST_ITERATIONS:-0}" -ge 2 ]]; then
    assert_pass "[#2032/SPEC-1] cycle iterated past iter 1 (suppression prevented false convergence)"
else
    assert_fail "[#2032/SPEC-1] cycle must have iterated past iter 1 — suppression must have fired" \
        "got _CYCLE_LAST_ITERATIONS=${_CYCLE_LAST_ITERATIONS:-?}"
fi
assert_eq "[#2032/SPEC-1] cycle converges when design finishes (rc=0)" "0" "$RUN_RC"
# The suppression event must not carry a converged reason on the suppressed iteration.
# Old code would have emitted a convergence on iter 1 without emitting the suppression event.
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    # converged is expected on iter 2 — but we must also have seen the suppression event
    assert_contains "[#2032/SPEC-1] suppression event present alongside convergence" \
        "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.member_unfinished.suppressed_convergence"
fi

# ── SPEC-2 [#2032/SPEC-2]: all members complete → normal convergence, no suppression
print_test_section "SPEC-2 [#2032/SPEC-2]: design=pass + gate=pass → converges iter1, no suppression event"
_run "$DESIGN_TPL" "design-verify" "design:pass,pass,pass;design-gate:pass,pass,pass"
assert_eq "[#2032/SPEC-2] cycle converges (rc=0)" "0" "$RUN_RC"
assert_eq "[#2032/SPEC-2] converges at iter 1" "1" "${_CYCLE_LAST_ITERATIONS:-}"
if grep -q 'cycle.member_unfinished.suppressed_convergence' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-2] new suppression block must NOT fire when all members are complete" \
        "suppression event emitted unexpectedly"
else
    assert_pass "[#2032/SPEC-2] no cycle.member_unfinished.suppressed_convergence (all members complete)"
fi

# ── SPEC-6 [#2032/SPEC-6]: unfinished at max_iterations → exhaustion, not false complete
# All 3 iters: design=dnf (unfinished) + gate=pass (exit_when matches).
# Old code: false convergence on iter 1 (rc=0). New code: suppression fires all 3
# iters; at max_iterations the #1261 exhaustion path fires (rc=8, design_timeout_exhausted).
# Assertion rc=8 FAILS on old code (which returns rc=0 false convergence).
print_test_section "SPEC-6 [#2032/SPEC-6]: design=dnf all iters, gate=pass → exhaustion rc=8, not false rc=0"
_run "$DESIGN_TPL" "design-verify" "design:dnf,dnf,dnf;design-gate:pass,pass,pass"
assert_eq "[#2032/SPEC-6] persistent unfinished member at max_iterations → rc=8 (not rc=0 false complete)" \
    "8" "$RUN_RC"
assert_eq "[#2032/SPEC-6] terminal reason is design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_contains "[#2032/SPEC-6] cycle.timeout_exhausted emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.timeout_exhausted"
assert_contains "[#2032/SPEC-6] cycle.timeout_exhausted carries reason=design_timeout_exhausted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"reason":"design_timeout_exhausted"'
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-6] must NOT converge when member is unfinished at max_iterations" \
        "converged emitted"
else
    assert_pass "[#2032/SPEC-6] no false convergence at max_iterations with unfinished member"
fi
assert_contains "[#2032/SPEC-6] suppression event emitted at max_iterations too" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.member_unfinished.suppressed_convergence"

# ── Schema registration ───────────────────────────────────────────────────────
if grep -q '"cycle.member_unfinished.suppressed_convergence"' "$REPO_ROOT/config/event-schema.json" 2>/dev/null; then
    assert_pass "schema: cycle.member_unfinished.suppressed_convergence registered in event-schema.json"
else
    assert_fail "schema: cycle.member_unfinished.suppressed_convergence missing from event-schema.json" \
        "event not in config/event-schema.json known_types"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
