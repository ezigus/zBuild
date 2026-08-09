#!/usr/bin/env bash
# Tests: cycle_orchestrator_run end-to-end paths (ADR-021, #512)
# Drives the orchestrator with a mock cycle_dispatch_stage to hit:
#   - happy convergence path
#   - max_iterations
#   - plateau
#   - state init + atomic write
#   - state_init / write_iter helpers
# Lifts coverage on core/pipeline/cycle-orchestrator.sh toward ADR-021 §40% bar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — orchestrator_run paths (ADR-021)"
setup_test_env "cycle-orch-run"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Mock hook scoped by global MOCK_VERDICTS map (stage→csv-of-verdicts)
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_VERDICTS); IFS="$IFS_save"
    local p sname vlist
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            _CYCLE_DISPATCH_VERDICT="${vs[$idx]}"
            [[ "${vs[$idx]}" == "fail" ]] && _CYCLE_DISPATCH_STATUS="failed" || _CYCLE_DISPATCH_STATUS="complete"
            [[ "${vs[$idx]}" == "fail" ]] && return 1
            return 0
        fi
    done
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# T1: bad args → rc=4
set +e; cycle_orchestrator_run "" "" ""; rc=$?; set -e
assert_eq "bad args → rc=4" "4" "$rc"

# T2: invalid cycle id (no template loaded) → rc=4
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
set +e; cycle_orchestrator_run "no-such-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "unknown cycle id → rc=4 (config_invalid)" "4" "$rc"

# T3: converges on iter 1 → state contains cycle_iterations.status=complete
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "iter 1 converges → rc=0" "0" "$rc"
ci_status="$(jq -r '.cycle_iterations["build-test"].status' "$STATE_FILE")"
assert_eq "state.cycle_iterations.status=complete" "complete" "$ci_status"
iter_len="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
assert_eq "1 iter recorded in state" "1" "$iter_len"

# T4: max_iterations exhausted with FAILING tests → rc=8 (#1208 by-severity) +
# history populated. (#1208: exhaustion is the single fatal condition; failing
# tests → hard-fail rc=8. Early plateau/divergence terminators were removed.)
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_VERDICTS="build:pass,pass,pass;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "exhausted with failing tests → rc=8 (by-severity halt)" "8" "$rc"
hist="$ZBUILD_STATE_DIR/cycle-build-test-history.jsonl"
assert_file_exists "history file written" "$hist"
hl="$(wc -l < "$hist" | tr -d ' ')"
assert_eq "history has 3 rows" "3" "$hl"

# T5: cycle.iteration.complete emitted for every iter
ic="$(jq -r 'select(.type=="cycle.iteration.complete") | .type' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')"
assert_eq "3 cycle.iteration.complete events" "3" "$ic"

# T6: schema-additive — cycle_iterations key created when previously absent
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
keys="$(jq -r '.cycle_iterations | keys[]' "$STATE_FILE" 2>/dev/null)"
assert_contains "cycle_iterations key includes build-test" "$keys" "build-test"

# T7: record_iter_outcome writes JSONL row
H="$TEST_TEMP_DIR/h.jsonl"
: > "$H"
_CYCLE_TRAP_CYCLE_ID="t7"
set +e; _cycle_record_iter_outcome "$H" 1 "pass" "complete" 0; rc=$?; set -e
assert_eq "record_iter_outcome rc=0" "0" "$rc"
assert_file_exists "JSONL row file exists" "$H"
verdict="$(jq -r '.verdict' "$H")"
assert_eq "row verdict=pass" "pass" "$verdict"

# T8: handle_terminal_rc emits cycle.complete
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_LAST_ITERATIONS=2
_cycle_handle_terminal_rc 0 "manual" "$STATE_FILE"
assert_event_emitted "cycle.complete on handle_terminal_rc" "$ZBUILD_EVENTS_JSONL" "cycle.complete"

# T9: signal handler emits cycle.aborted
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_CYCLE_ID="t9"; _CYCLE_TRAP_ITER=2
( _cycle_on_signal SIGTERM >/dev/null 2>&1; exit $? ) || true
assert_event_emitted "cycle.aborted on signal" "$ZBUILD_EVENTS_JSONL" "cycle.aborted"

# T10: state_init creates cycle_iterations[id] entry
_seed
set +e; _cycle_state_init "$STATE_FILE" "x1" "/tmp/h.jsonl" 4; rc=$?; set -e
assert_eq "state_init rc=0" "0" "$rc"
v="$(jq -r '.cycle_iterations["x1"].status' "$STATE_FILE")"
assert_eq "x1 status=in_progress" "in_progress" "$v"

# T11: write_iter_atomic appends to iter[]
set +e; _cycle_state_write_iter_atomic "$STATE_FILE" "x1" 1 "pass" "complete" 0 "complete"; rc=$?; set -e
assert_eq "write_iter rc=0" "0" "$rc"
ilen="$(jq -r '.cycle_iterations["x1"].iter | length' "$STATE_FILE")"
assert_eq "iter array has 1 entry" "1" "$ilen"

# T12: _CYCLE_TRAP_CYCLE_ID cleared at every top-level return path
# [SPEC-1]: cleared on success (convergence) path — fails at baseline where
#   the orchestrator leaves _CYCLE_TRAP_CYCLE_ID="build-test" on exit.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12a=$?; set -e
assert_eq "T12 success rc=0" "0" "$rc_t12a"
assert_eq "[SPEC-1] _CYCLE_TRAP_CYCLE_ID cleared after top-level success" "" "$_CYCLE_TRAP_CYCLE_ID"

# [SPEC-2]: cleared on config_invalid error path — _CYCLE_TRAP_CYCLE_ID is
#   written at line 1583 before the template check fails; without the fix it
#   remains "no-such-cycle" on exit.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "no-such-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12b=$?; set -e
assert_eq "T12 config_invalid rc=4" "4" "$rc_t12b"
assert_eq "[SPEC-2] _CYCLE_TRAP_CYCLE_ID cleared after config_invalid return" "" "$_CYCLE_TRAP_CYCLE_ID"

# [SPEC-3]: two sequential top-level calls — second must NOT be misclassified as
#   nested re-entry. At baseline _CYCLE_TRAP_CYCLE_ID="build-test" after the first
#   call; the second call with cycle_id="review-remediation" sees _parent_cid=
#   "build-test" != "review-remediation", enters the nested-reentry restore branch,
#   and loads the planted persist into _CYCLE_TIMEOUT_RUN (assertion fails). With
#   the fix, _CYCLE_TRAP_CYCLE_ID="" after the first call → _parent_cid="" →
#   top-level path → persist is cleared, not restored.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12c_1=$?; set -e
# Plant stale persist for the second cycle — a top-level call must clear it.
_CYCLE_TIMEOUT_RUN_PERSIST["review-remediation:s1"]=3
set +e; cycle_orchestrator_run "review-remediation" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12c_2=$?; set -e
assert_eq "T12c first call rc=0" "0" "$rc_t12c_1"
assert_eq "T12c second call config_invalid rc=4" "4" "$rc_t12c_2"
assert_eq "[SPEC-3] second sequential top-level call clears stale persist (not restores)" "" "${_CYCLE_TIMEOUT_RUN[s1]:-}"

# ── N2 (#1225): NESTED cycle route_back propagates rc=11 outward, NOT rc=4 ─────
# An inner cycle that route_backs returns rc=11 to the enclosing outer cycle's
# member dispatch (the `11)` case). BEFORE #1225 the outer main loop had no rc=11
# branch → the `_iter_rc -ne 0` catch-all collapsed it to rc=4 (config_invalid,
# silent HALT), never reaching the runner's rewind. This asserts the outer
# cycle_orchestrator_run now BUBBLES 11 (mirroring rc=8/130) and preserves the
# hand-off globals (route_back target + edge-owner id) for the runner.
NESTED_RB_TPL="$TEST_TEMP_DIR/nested-rb.yaml"
cat > "$NESTED_RB_TPL" <<'EOF'
id: nested-rb-run
defaults:
  strategy: fanout
flow:
  - plan
  - outer
plan:
  roles: [planner]
outer:
  type: cycle
  flow:
    - inner
  exit_when:
    stage: inner
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
inner:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  route_back:
    to: plan
    when:
      stage: test
      field: verdict
      op: eq
      value: retry
    max: 2
  max_iterations: 2
  on_max: continue
build:
  roles: [builder]
test:
  roles: [tester]
EOF
_seed
_TPL_STAGES=(); _TPL_CYCLES=()
set +e; load_template "$NESTED_RB_TPL"; rc=$?; set -e
assert_eq "N2: nested route_back template LOADS rc=0 (#1225 lifts nested rejection)" "0" "$rc"
# inner test always emits verdict=retry (status complete, rc 0) → inner exhausts
# unconverged (rc=2) → route_back predicate (retry) matches → inner returns 11.
MOCK_VERDICTS="build:pass;test:retry"
_CYCLE_ROUTE_BACK_TO=""; _CYCLE_ROUTE_BACK_FALLBACK_RC=""; _CYCLE_ROUTE_BACK_EDGE_ID=""
set +e; cycle_orchestrator_run "outer" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_n2=$?; set -e
assert_eq "N2: outer cycle_orchestrator_run BUBBLES rc=11 (NOT rc=4 collapse)" "11" "$rc_n2"
assert_eq "N2: reason=route_back" "route_back" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "N2: route_back target=plan preserved through the outer loop" "plan" "$_CYCLE_ROUTE_BACK_TO"
assert_eq "N2: edge-owner id = INNER cycle (so runner keys the inner's max)" "inner" "$_CYCLE_ROUTE_BACK_EDGE_ID"

# T13: stage_statuses and stage_verdicts written per cycle member (#1800)
# SPEC-4/5/6 fail at baseline: _cycle_iter_dispatch did not write stage_statuses
# or stage_verdicts. After the fix, both maps contain one entry per dispatched
# member with the classified verdict and terminal status. SPEC-7 is the guard —
# it holds at the merge-base and must keep holding once the writes are added.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t13=$?; set -e
assert_eq "[SPEC-7] cycle still converges → rc=0" "0" "$rc_t13"
t13_iter_status="$(jq -r '.cycle_iterations["build-test"].status // "missing"' "$STATE_FILE")"
assert_eq "[SPEC-7] cycle_iterations status unaffected by member writes" "complete" "$t13_iter_status"
build_ss="$(jq -r '.stage_statuses.build // "missing"' "$STATE_FILE")"
assert_eq "[SPEC-4] build in stage_statuses after leaf dispatch" "complete" "$build_ss"
build_sv="$(jq -r '.stage_verdicts.build // "missing"' "$STATE_FILE")"
assert_eq "[SPEC-5] build in stage_verdicts after leaf dispatch" "pass" "$build_sv"
ss_count="$(jq '.stage_statuses | length' "$STATE_FILE")"
assert_eq "[SPEC-6] stage_statuses key count equals member count (2)" "2" "$ss_count"
sv_count="$(jq '.stage_verdicts | length' "$STATE_FILE")"
assert_eq "[SPEC-6] stage_verdicts key count equals member count (2)" "2" "$sv_count"

print_test_results
