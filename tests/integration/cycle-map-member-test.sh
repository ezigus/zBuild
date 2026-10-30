#!/usr/bin/env bash
# Integration: a map group (the review lenses) as a loop member (#2433, ADR-040).
#
# The lenses run inside the loop, after the build; what they find sends the
# loop round again, to the stages that can fix it.
#   M0 [change]: a template with a map group in a loop's flow loads, and the
#                group folds under the loop's dispatch unit
#   M1 [change] (R5): a lens fails in round 1 and passes in round 2 — the loop
#                converges on round 2
#   M2 [change] (R6): a lens fails in both rounds — the loop stops after round 2,
#                not converged
#   M3 [change] (R7, R8): a lens that did not finish (or found the issue itself
#                wrong) stops the run at once — no second round
#   M4 [change]: the group's verdict is recorded like any member's
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — map group as member (#2433)"
setup_test_env "cycle-map-member"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}, updated_at:"seed"}' > "$STATE_FILE"
}

TPL="$TEST_TEMP_DIR/cycle-map.yaml"
cat > "$TPL" <<'EOF'
id: cycle-map
name: Cycle With Map Member
defaults:
  strategy: fanout

flow:
  - delivery_loop

delivery_loop:
  type: cycle
  flow:
    - build
    - lenses
  exit_when:
    all:
      - { stage: build, field: verdict, op: eq, value: pass }
      - { stage: lenses, field: verdict, op: eq, value: pass }
  max_iterations: 2
  on_max: halt

lenses:
  type: map
  over: lenses
  elements:
    - id: correctness
    - id: scope
  roles: [review_lens]
  as: ZBUILD_REVIEW_LENS_ID
  max_parallel: 2
  on_member_error: continue

build:
  roles: [builder]
EOF

RAN="$TEST_TEMP_DIR/ran"
# The leaf member always passes.
cycle_dispatch_stage() {
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_VERDICT_RAW="pass"; _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""; _CYCLE_DISPATCH_DISPOSITION="complete"; _CYCLE_DISPATCH_REPORT='{}'
    _CYCLE_DISPATCH_DATA_KIND=""
    return 0
}
# The map group's run: how each round ends is $SCENARIO's word for that round
# (pass | fail | unfinished), set the way _map_write_summary sets it.
map_group_run() {
    local round="${ZBUILD_CYCLE_ITER:-1}" word
    printf '%s\n' "$1" >> "$RAN"
    word="$(cut -d, -f"$round" <<< "$SCENARIO")"
    _ZB_MAP_UNFINISHED=""; _ZB_MAP_NOT_PASSED=""; ZBUILD_RUN_FLAGGED=no
    case "$word" in
        fail)       ZBUILD_RUN_FLAGGED=yes; _ZB_MAP_NOT_PASSED="1 of 2 lenses did not pass: correctness (fail)" ;;
        unfinished) ZBUILD_RUN_FLAGGED=yes; _ZB_MAP_UNFINISHED="1 of 2 lenses did not finish: scope (timed_out)"
                    _ZB_MAP_NOT_PASSED="1 of 2 lenses did not pass: scope (timed_out)" ;;
    esac
    return 0
}
_runs() { [[ -f "$RAN" ]] && wc -l < "$RAN" | tr -d ' ' || printf '0'; }

_TPL_STAGES=(); _TPL_CYCLES=(); _TPL_PARALLEL_GROUPS=(); _TPL_MAP_GROUPS=()

print_test_section "M0: load + folding"
_seed
rc=0; load_template "$TPL" >/dev/null 2>&1 || rc=$?
assert_eq "M0: the template loads" "0" "$rc"
assert_eq "M0: one dispatch unit, the loop" "cycle:delivery_loop" "${_TPL_DISPATCH_UNITS[*]:-}"
assert_eq "M0: the group is a map member" "map" "${_TPL_STAGE_TYPE_lenses:-}"

print_test_section "M1 (R5): fail, then pass — converges on round 2"
_seed; rm -f "$RAN"; SCENARIO="fail,pass"
rc=0; cycle_orchestrator_run "delivery_loop" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "M1: the loop ends well" "0" "$rc"
assert_eq "M1: converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "M1: on round 2" "2" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "M1: the lenses ran each round" "2" "$(_runs)"

print_test_section "M4: the group's verdict is recorded"
assert_eq "M4: stage_verdicts.lenses" "pass" "$(jq -r '.stage_verdicts.lenses // "missing"' "$STATE_FILE")"

print_test_section "M2 (R6): fail both rounds — stops after round 2"
_seed; rm -f "$RAN"; SCENARIO="fail,fail"
rc=0; cycle_orchestrator_run "delivery_loop" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "M2: the loop does not end well" "1" "$(( rc != 0 ))"
assert_eq "M2: after 2 rounds" "2" "$(_runs)"
if [[ "${_CYCLE_LAST_TERMINATED_REASON:-}" == converged ]]; then
    assert_fail "M2: not converged" "converged"
else
    assert_pass "M2: not converged"
fi
assert_eq "M2: the group is recorded failed" "fail" "$(jq -r '.stage_verdicts.lenses // "missing"' "$STATE_FILE")"

print_test_section "M3 (R7, R8): a lens that did not finish stops the run at once"
_seed; rm -f "$RAN"; SCENARIO="unfinished,pass"
rc=0; cycle_orchestrator_run "delivery_loop" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "M3: the run stops" "1" "$(( rc != 0 ))"
assert_eq "M3: no second round" "1" "$(_runs)"
assert_contains "M3: the stop names the group" "${_CYCLE_LAST_TERMINATED_REASON:-}" "lenses"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
