#!/usr/bin/env bash
# tests/integration/cycle-member-unfinished-no-convergence-test.sh
# When a cycle's exit_when predicate is satisfied but any iteration member
# carries an unfinished disposition (timed_out, out_of_turns, interrupted),
# the cycle must NOT converge — it emits cycle.member_unfinished.suppressed_convergence
# and iterates. At max_iterations with an unfinished tail, the suppression
# fires first, then the existing #1261 exhaustion path halts (rc=1, outcome
# failed — term_rc=8 before #1850, ADR-054 §4).
#
#   SPEC-1[change] (#2032): exit_when match + unfinished member disposition → convergence
#                           suppressed, cycle.member_unfinished.suppressed_convergence
#                           emitted, cycle iterates instead.
#                           FAILS before: cycle converges immediately (disposition ignored)
#   SPEC-2[guard]  (#2032): all members complete + exit_when match → converges normally;
#                           the suppression block does not fire.
#                           Passes both before and after the change.
#   SPEC-6[change] (#2032): at max_iterations when last iter has an unfinished member,
#                           the §4/A suppression fires (preventing false complete) and the
#                           cycle takes the #1261 exhaustion path: cycle.timeout_exhausted
#                           with reason=design_timeout_exhausted, rc=1, outcome failed.
#                           FAILS before: cycle converges rc=0 (no suppression block)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle: unfinished member suppresses convergence (#2032)"
setup_test_env "cycle-member-unfinished-no-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# verdict_classify lives in verdict.sh; stub below uses it to classify verdicts
# identically to how runner.sh drives the dispatch — the same path the fix keys on.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ── state seed ───────────────────────────────────────────────────────────────
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

# ── Templates ────────────────────────────────────────────────────────────────
# Template A: design-only cycle, max_iterations=2 (for SPEC-1/SPEC-2).
# No build member → the existing build_unfinished suppression (line 2575) does
# NOT fire. Only the new member_unfinished suppression (SPEC-1) can fire.
TPL_A="$TEST_TEMP_DIR/design-only-max2.yaml"
cat > "$TPL_A" <<'YAML'
id: unfinished2032
name: unfinished member test max2
defaults:
  strategy: fanout
stages:
  - id: design-only
    type: cycle
    stages: [design]
    until:
      stage: design
      field: verdict
      op: eq
      value: pass
    max_iterations: 2
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
YAML

# Template B: design-only cycle, max_iterations=1 (for SPEC-6).
# The first (and only) iteration has max_iterations hit, so with an unfinished
# member the §4/A suppression fires, then the exhaustion path fires.
TPL_B="$TEST_TEMP_DIR/design-only-max1.yaml"
cat > "$TPL_B" <<'YAML'
id: unfinished2032max1
name: unfinished member test max1
defaults:
  strategy: fanout
stages:
  - id: design-max1
    type: cycle
    stages: [design]
    until:
      stage: design
      field: verdict
      op: eq
      value: pass
    max_iterations: 1
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
YAML

# ── Dispatch stub ─────────────────────────────────────────────────────────────
# MOCK_DISPOSITIONS: comma-separated list of dispositions, one per dispatch call.
# The stub always returns verdict=pass so the exit_when predicate matches; only
# the disposition varies. This isolates the suppression logic from verdict routing.
MOCK_DISPOSITIONS="complete"
_mock_call=0
cycle_dispatch_stage() {
    _mock_call=$(( _mock_call + 1 ))
    local _IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a _disp_list=($MOCK_DISPOSITIONS); IFS="$_IFS_save"
    local _idx=$(( _mock_call - 1 ))
    [[ $_idx -ge ${#_disp_list[@]} ]] && _idx=$(( ${#_disp_list[@]} - 1 ))
    local _d="${_disp_list[$_idx]:-complete}"
    # verdict=pass satisfies the `until: value: pass` predicate on every iter.
    _CYCLE_DISPATCH_VERDICT="$(verdict_classify "pass" 2>/dev/null || printf 'pass')"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_DISPOSITION="$_d"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    _CYCLE_DISPATCH_DATA_KIND=""
    return 0
}

_run_cycle() {
    # $1 = template file  $2 = cycle id  $3 = MOCK_DISPOSITIONS value
    _seed
    load_template "$1"
    MOCK_DISPOSITIONS="$3"
    _mock_call=0
    RUN_RC=0
    cycle_orchestrator_run "$2" "$ZBUILD_STATE_DIR" "$STATE_FILE" || RUN_RC=$?
}

# ── Event-schema registration check ─────────────────────────────────────────
# The new suppression event MUST be registered in event-schema.json (SPEC-1 wiring).
# Reverting the schema registration would break this assertion.
assert_contains "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence registered in event-schema.json" \
    "$(cat "$ZBUILD_EVENT_SCHEMA" 2>/dev/null)" "cycle.member_unfinished.suppressed_convergence"

# ── SPEC-2[guard]: all members complete + exit_when match → converges normally ─
# The new suppression block must NOT fire when every member's disposition is
# complete. This test passes both before and after the fix.

_run_cycle "$TPL_A" "design-only" "complete"

assert_eq "[#2032/SPEC-2] complete disposition + exit_when match → rc=0 (converges normally)" \
    "0" "$RUN_RC"
assert_eq "[#2032/SPEC-2] terminated reason is converged (not suppressed)" \
    "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
_s2_supp="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-2] suppression event NOT emitted when all dispositions are complete" \
    "0" "$_s2_supp"
assert_eq "[#2032/SPEC-2] exactly 1 dispatch (converged on first iter — suppression did not fire)" \
    "1" "$_mock_call"

# ── SPEC-1[change]: exit_when match + unfinished member → suppressed, iterates ─
# Iter 1: design returns verdict=pass (exit_when matches) AND disposition=timed_out.
# Before fix: cycle converges immediately (rc=0, 1 dispatch, no event emitted).
# After  fix: convergence suppressed, cycle.member_unfinished.suppressed_convergence
#             emitted, cycle iterates. Iter 2: complete → converges (rc=0, 2 dispatches).

_run_cycle "$TPL_A" "design-only" "timed_out,complete"

_s1_supp="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence emitted when member has timed_out disposition" \
    "1" "$_s1_supp"
# Cycle must iterate after suppression: iter 1 suppressed → iter 2 dispatched → 2 total.
# Before fix this is 1 (cycle converged immediately on iter 1).
assert_eq "[#2032/SPEC-1] cycle iterated after suppression (2 dispatch calls, not the pre-fix 1)" \
    "2" "$_mock_call"

# SPEC-1 covers all three unfinished dispositions — also out_of_turns:
_run_cycle "$TPL_A" "design-only" "out_of_turns,complete"
_s1_oot="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-1] suppression fires when member has out_of_turns disposition" \
    "1" "$_s1_oot"
assert_eq "[#2032/SPEC-1] cycle iterated after out_of_turns suppression (2 dispatch calls)" \
    "2" "$_mock_call"

# SPEC-1 covers all three unfinished dispositions — also interrupted:
_run_cycle "$TPL_A" "design-only" "interrupted,complete"
_s1_int="$(grep -c '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-1] suppression fires when member has interrupted disposition" \
    "1" "$_s1_int"
assert_eq "[#2032/SPEC-1] cycle iterated after interrupted suppression (2 dispatch calls)" \
    "2" "$_mock_call"

# ── SPEC-6[change]: at max_iterations with unfinished member → rc=1, failed ───
# max_iterations=1: the only iter has verdict=pass (exit_when matches) but
# disposition=timed_out.
# Before fix: §4/A suppression absent → converged==0 → rc=0 (false complete).
# After  fix: §4/A suppression sets converged=1 → max_iterations path fires →
#             _iter_did_not_finish==1 && _exh_tests_reported==0 → rc=1, outcome failed,
#             cycle.timeout_exhausted emitted with reason=design_timeout_exhausted.

_run_cycle "$TPL_B" "design-max1" "timed_out"

assert_eq "[#2032/SPEC-6] at max_iterations with unfinished member → rc=1, outcome failed (not rc=0 false complete)" \
    "1 failed" "$RUN_RC ${_CYCLE_LAST_OUTCOME:-unset}"
_s6_ev="$(grep -c '"cycle.timeout_exhausted"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-6] cycle.timeout_exhausted emitted" \
    "1" "$_s6_ev"
_s6_reason="$(jq -r 'select(.type == "cycle.timeout_exhausted") | .data.reason' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1 || true)"
assert_eq "[#2032/SPEC-6] cycle.timeout_exhausted reason=design_timeout_exhausted" \
    "design_timeout_exhausted" "${_s6_reason:-MISSING}"
assert_eq "[#2032/SPEC-6] terminated_reason=design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
