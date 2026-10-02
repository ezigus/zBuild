#!/usr/bin/env bash
# tests/integration/cycle-member-unfinished-no-convergence-test.sh
# #2032: when a member carries an unfinished disposition on the iteration
# where exit_when fires, the cycle must NOT converge — it emits
# cycle.member_unfinished.suppressed_convergence and iterates instead.
#
# SPEC-1 [#2032/SPEC-1]: when converged==0 (exit_when predicate matched) and any
#   iteration member carries an unfinished disposition (timed_out, out_of_turns,
#   or interrupted), the cycle does NOT converge — it emits
#   cycle.member_unfinished.suppressed_convergence and iterates instead
# SPEC-2 [#2032/SPEC-2]: when all iteration members carry disposition:complete
#   and exit_when matches, the cycle converges normally; the new
#   unfinished-member suppression block does not fire
# SPEC-6 [#2032/SPEC-6]: at max_iterations when the last iteration has any member
#   with an unfinished disposition, the §4/A suppression block fires (preventing
#   false complete), and the cycle takes the existing #1261 exhaustion path —
#   emitting cycle.timeout_exhausted with reason=design_timeout_exhausted and
#   term_rc=8, not rc=0 complete
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle: unfinished member suppresses false convergence (#2032)"
setup_test_env "cycle-member-unfinished-no-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ─── design_verify_cycle fixture (design → design-gate; NO test member) ───────
# max_iterations=3: room for suppress-on-iter-1, converge-on-iter-2 (SPEC-1/2).
DESIGN_TPL="$TEST_TEMP_DIR/design-verify-3.yaml"
cat > "$DESIGN_TPL" <<'YAML'
id: dvc3
name: design verify cycle (max 3)
defaults:
  strategy: fanout
stages:
  - id: dvc
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

# max_iterations=2 for SPEC-6: suppression fires on iter 1; iter 2 is the last,
# triggering the #1261 exhaustion path after suppression.
DESIGN_TPL2="$TEST_TEMP_DIR/design-verify-2.yaml"
cat > "$DESIGN_TPL2" <<'YAML'
id: dvc2
name: design verify cycle (max 2)
defaults:
  strategy: fanout
stages:
  - id: dvc
    type: cycle
    stages: [design, design-gate]
    until:
      stage: design-gate
      field: verdict
      op: eq
      value: pass
    max_iterations: 2
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
  design-gate:
    roles: [design_gate]
YAML

# ─── Mock dispatch ────────────────────────────────────────────────────────────
# Plan format: "stage:v1,v2,...;stage2:..."  (comma-separated per-iter tokens)
# Tokens:
#   unf  — disposition=timed_out (unfinished), verdict=incomplete
#   pass — disposition=complete (empty / default), verdict=pass
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
    if [[ "$v" == "unf" ]]; then
        # Unfinished: disposition=timed_out, verdict classified from incomplete.
        _CYCLE_DISPATCH_DISPOSITION="timed_out"
        _CYCLE_DISPATCH_VERDICT="$(verdict_classify "incomplete" 2>/dev/null || echo fail)"
        _CYCLE_DISPATCH_VERDICT_RAW="incomplete"
    else
        _CYCLE_DISPATCH_VERDICT="$(verdict_classify "pass" 2>/dev/null || echo pass)"
        _CYCLE_DISPATCH_VERDICT_RAW="pass"
    fi
    return 0
}

_seed() {
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$sf" "${sf}.bak" "${sf}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$sf"
}

_run() {
    # $1=template $2=cycle-id $3=MOCK_PLAN
    _seed
    load_template "$1"
    MOCK_PLAN="$3"
    set +e
    cycle_orchestrator_run "$2" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_DIR/pipeline-state.json"
    RUN_RC=$?
    set +e
}

# ── SPEC-2 [#2032/SPEC-2]: all members disposition:complete → converges normally ──
print_test_section "SPEC-2: all-complete exit_when converges; suppression block absent"
_run "$DESIGN_TPL" "dvc" "design:pass;design-gate:pass"
assert_eq "[#2032/SPEC-2] all-complete exit_when: rc=0 (converged)" "0" "$RUN_RC"
assert_eq "[#2032/SPEC-2] converged on the first iteration (no suppression needed)" \
    "1" "${_CYCLE_LAST_ITERATIONS:-0}"
assert_eq "[#2032/SPEC-2] terminated with reason=converged" \
    "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
_supp2="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-2] suppression block did NOT fire (all members were complete)" \
    "0" "$_supp2"

# ── SPEC-1 [#2032/SPEC-1]: unfinished member blocks convergence despite exit_when ──
# Plan: iter 1 — design=timed_out, design-gate=pass → exit_when fires, suppression
#       fires, cycle iterates.  iter 2 — design=complete, design-gate=pass → converges.
print_test_section "SPEC-1: unfinished member suppresses convergence — cycle iterates instead"
_run "$DESIGN_TPL" "dvc" "design:unf,pass;design-gate:pass,pass"
assert_eq "[#2032/SPEC-1] unfinished member blocks convergence: rc=0 (converges on iter 2, not iter 1)" \
    "0" "$RUN_RC"
assert_eq "[#2032/SPEC-1] cycle ran 2 iterations (not 1): the suppressed iter forced another" \
    "2" "${_CYCLE_LAST_ITERATIONS:-0}"
_supp1="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence was emitted once" \
    "1" "$_supp1"

# ── SPEC-6 [#2032/SPEC-6]: unfinished member at max_iterations → exhaustion path ──
# Plan: both iters — design=timed_out, design-gate=pass.
# iter 1: suppression fires, iterate; iter 2 (last): suppression fires → max_iterations
# check fires → _iter_did_not_finish=1 && _exh_tests_reported=0 → design_timeout_exhausted.
print_test_section "SPEC-6: unfinished at max_iterations — exhaustion path, not rc=0 complete"
_run "$DESIGN_TPL2" "dvc" "design:unf,unf;design-gate:pass,pass"
assert_eq "[#2032/SPEC-6] unfinished at max_iterations: rc=8 (exhaustion halt, not rc=0 complete)" \
    "8" "$RUN_RC"
assert_eq "[#2032/SPEC-6] terminated reason is design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-}"
_texh="$(grep -c '"cycle.timeout_exhausted"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-6] cycle.timeout_exhausted was emitted" "1" "$_texh"
_texh_reason="$(jq -r 'select(.type=="cycle.timeout_exhausted") | .data.reason // empty' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-6] cycle.timeout_exhausted reason=design_timeout_exhausted" \
    "design_timeout_exhausted" "$_texh_reason"
_supp6="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-6] suppression block fired on both iterations preventing false complete" \
    "2" "$_supp6"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
