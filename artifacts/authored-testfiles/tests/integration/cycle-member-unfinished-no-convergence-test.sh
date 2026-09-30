#!/usr/bin/env bash
# Integration: §4/A — an unfinished cycle member blocks convergence (#2032).
#
# Without §4/A, a design_verify_cycle (design → design-gate; no build/test
# member) can falsely converge when design times out but design-gate matches
# the exit_when predicate on stale output.  The #1208 build-unfinished guard
# does not fire because it keys on a COMMIT-PRODUCING member (build), and this
# cycle has none.
#
# §4/A adds a second suppression: when converged==0 (exit_when matched) AND
# _iter_did_not_finish==1 (any member has an unfinished disposition —
# timed_out, out_of_turns, or interrupted), the cycle does NOT converge.
# It emits cycle.member_unfinished.suppressed_convergence and iterates instead.
#
# At max_iterations the suppression prevents the false-complete branch (line
# ~2728) from firing; the existing #1261 exhaustion path then triggers
# (reason=design_timeout_exhausted, term_rc=8).
#
# SPECs covered:
#   SPEC-1 [change] — unfinished member + exit_when matched → suppress + iterate
#   SPEC-2 [guard]  — all-complete members + exit_when matched → converge normally
#   SPEC-6 [change] — unfinished member at max_iterations → exhaustion, rc=8
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle §4/A: unfinished member blocks convergence (#2032)"
setup_test_env "cycle-member-unfinished-no-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# verdict_classify lives in verdict.sh — cycle-orchestrator.sh does not source it.
# The mock uses it to classify member verdicts, mirroring the runner.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ── design_verify_cycle fixture (design → design-gate; no build/test member) ──
DESIGN_TPL="$TEST_TEMP_DIR/design-verify-cycle.yaml"
cat > "$DESIGN_TPL" <<'YAML'
id: design2032
name: design verify cycle (member-unfinished suppression)
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

# Plan-driven mock dispatch.  MOCK_PLAN format: "stage:v1,v2,...;stage2:..."
#   tof  — member has timed_out disposition (a router timeout)
#   cpl  — member has explicit complete disposition
#   pass — member passes with empty (defaulting to complete) disposition
# The gate uses `pass` — its verdict drives the exit_when predicate.
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
    _CYCLE_DISPATCH_FAULT=""
    _CYCLE_DISPATCH_REPORT="{}"
    local rv="$v"
    case "$v" in
        tof)
            rv="incomplete"
            _CYCLE_DISPATCH_DISPOSITION="timed_out"
            _CYCLE_DISPATCH_REASON="router_timeout"
            ;;
        cpl)
            rv="pass"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$rv" 2>/dev/null || echo warn)"
    _CYCLE_DISPATCH_VERDICT_RAW="$rv"
    return 0
}

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

_run() {
    # $1 = MOCK_PLAN
    _seed
    load_template "$DESIGN_TPL"
    MOCK_PLAN="$1"
    set +e
    cycle_orchestrator_run "design-verify" "$ZBUILD_STATE_DIR" "$STATE_FILE"
    RUN_RC=$?
    set -e
}

# ─── SPEC-1: unfinished member + exit_when matched → suppress, iterate ────────
# Without §4/A: iter 1 gate passes → converged=0 → false rc=0 complete.
# With §4/A:    design has timed_out → _iter_did_not_finish=1 → suppression fires
#               → cycle iterates; iter 2 (design=complete, gate=pass) converges.
print_test_section "SPEC-1: unfinished member + exit_when matched → suppress and iterate"
_run "design:tof,cpl;design-gate:pass,pass"
assert_contains "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence emitted on unfinished iter" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.member_unfinished.suppressed_convergence"
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-1] unfinished member must NOT produce a false convergence" \
        "reason:converged found — suppression did not fire"
else
    assert_pass "[#2032/SPEC-1] no false convergence on the suppressed iteration"
fi
assert_eq "[#2032/SPEC-1] cycle iterated past the suppressed iter (converged on iter 2)" \
    "2" "${_CYCLE_LAST_ITERATIONS:-0}"
assert_eq "[#2032/SPEC-1] rc=0 — converges cleanly once design finishes" "0" "$RUN_RC"

# ─── SPEC-2: all-complete members + exit_when matched → converge, no suppression ──
# Guard: the new block must NOT fire when every member is disposition:complete.
print_test_section "SPEC-2: all members complete + exit_when matched → normal convergence"
_run "design:cpl;design-gate:pass"
if grep -q 'cycle.member_unfinished.suppressed_convergence' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-2] suppression block must NOT fire when all members are complete" \
        "cycle.member_unfinished.suppressed_convergence emitted unexpectedly"
else
    assert_pass "[#2032/SPEC-2] no unfinished-member suppression when all members are complete"
fi
assert_eq "[#2032/SPEC-2] cycle converges on iter 1 (no suppression)" "1" "${_CYCLE_LAST_ITERATIONS:-0}"
assert_eq "[#2032/SPEC-2] rc=0 (normal convergence)" "0" "$RUN_RC"

# ─── SPEC-6: unfinished member at max_iterations → exhaustion (rc=8) ──────────
# The §4/A suppression fires on the last iteration (iter 3 = max_iterations),
# preventing the false-complete branch at line ~2728.  The cycle cannot iterate
# further, so the existing #1261 exhaustion path fires:
#   cycle.timeout_exhausted emitted, reason=design_timeout_exhausted, term_rc=8.
# Before §4/A the cycle produces a false rc=0 complete on this scenario.
print_test_section "SPEC-6: unfinished member at max_iterations → exhaustion path (rc=8)"
_run "design:tof,tof,tof;design-gate:pass,pass,pass"
assert_contains "[#2032/SPEC-6] cycle.member_unfinished.suppressed_convergence emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.member_unfinished.suppressed_convergence"
assert_contains "[#2032/SPEC-6] cycle.timeout_exhausted emitted with reason=design_timeout_exhausted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"reason":"design_timeout_exhausted"'
assert_eq "[#2032/SPEC-6] term_rc=8 (not rc=0 false complete)" "8" "$RUN_RC"
assert_eq "[#2032/SPEC-6] terminated reason is design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-NONE}"
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-6] cycle must NOT emit converged when suppression fired at max" \
        "reason:converged found — false-complete branch was not blocked"
else
    assert_pass "[#2032/SPEC-6] no false convergence at max_iterations with unfinished member"
fi

# ── schema: new event must be declared in event-schema.json ───────────────────
if grep -q '"cycle.member_unfinished.suppressed_convergence"' "$REPO_ROOT/config/event-schema.json"; then
    assert_pass "[#2032/SPEC-1] schema: cycle.member_unfinished.suppressed_convergence registered"
else
    assert_fail "[#2032/SPEC-1] schema: cycle.member_unfinished.suppressed_convergence missing from event-schema.json"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
