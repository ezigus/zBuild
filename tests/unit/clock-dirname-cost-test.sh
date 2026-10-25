#!/usr/bin/env bash
# tests/unit/clock-dirname-cost-test.sh — the clock and a file's own folder come
# from the shell, not from programs (ADR-065 §5).
#
# Every state write stamped .updated_at with a `date` (147 in one three-run
# pipeline test), and every library found its own folder with a `dirname` each
# time it was loaded (479).
#
# T1 [change] the state writers, the scope override and the cycle's history row start no date
# T2 [guard]  …and stamp the time date -u gives, in the same form
# T3 [change] stage-io's two records start no date
# T4 [change] loading each library starts no dirname
# T5 [guard]  a library loaded by a name with no folder in it (from its own
#             folder) still finds its siblings
# T6 [change] the cycle's history row and round summary, and the summaries
#             list, start no dirname; the row and summary land where they did
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the clock and a file's folder, from the shell (ADR-065 §5)"
setup_test_env "clock-dirname-cost"

CALLS="$TEST_TEMP_DIR/calls"
date() { printf 'date\n' >> "$CALLS"; command date "$@"; }
dates() { local c; c="$(grep -c '^date$' "$CALLS" 2>/dev/null)"; printf '%s' "${c:-0}"; }
ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
# near <iso>: within 5 seconds of date -u now.
near() {
    local a b; a="$(command date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || command date -u -d "$1" +%s 2>/dev/null)"
    b="$(command date -u +%s)"
    [[ "$1" =~ $ISO && -n "$a" ]] && (( b - a >= 0 && b - a <= 5 ))
}

# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

print_test_section "T1/T2: state writers"
# A state file holding loop c1, made by the engine's own writers.
SF1="$TEST_TEMP_DIR/t1/pipeline-state.json"; mkdir -p "${SF1%/*}"; printf '{}\n' > "$SF1"
zb_engine_loop_state "$SF1" c1 1 3 complete
_bad=""; : > "$CALLS"
export _ZB_STAGE_ID=build _ZB_STAGE_STATUS=complete _ZB_PIPELINE_STATUS=running _ZB_PIPELINE_BRANCH=b \
    _ZB_STAGE_VERDICT=pass _ZB_CYCLE_ID=c1 _ZB_CYCLE_HISTORY=h _ZB_CYCLE_MAX=3 _ZB_CYCLE_N=1 \
    _ZB_CYCLE_VERDICT=pass _ZB_CYCLE_ITER_STATUS=complete _ZB_CYCLE_FC=0 _ZB_CYCLE_OVERALL=running \
    _ZB_CYCLE_MEMBER=build _ZB_CYCLE_MEMBER_STATUS=complete _ZB_CYCLE_MEMBER_VERDICT=pass
for _f in _zbuild_runner_set_stage_status _zbuild_runner_set_pipeline_status _zbuild_runner_set_pipeline_branch \
          _zbuild_runner_set_stage_verdict _zbuild_runner_set_llm_abort_reason \
          _cycle_state_jq_init _cycle_state_jq_write_iter _cycle_state_jq_write_member; do
    _u="$("$_f" < "$SF1" 2>/dev/null | command jq -r '.updated_at // ""')"
    near "$_u" || _bad+="$_f=[$_u] "
done
# The scope override's "Generated:" line (claude-review on #2415).
WSO="$TEST_TEMP_DIR/wso"; mkdir -p "$WSO"
ZBUILD_SCOPE_PATHS="core/x.sh" write_scope_override "$WSO" run-1
_g="$(sed -n 's/^# Generated: //p' "$WSO/scope-override.md" 2>/dev/null)"
near "$_g" || _bad+="scope_override=[$_g] "
H="$TEST_TEMP_DIR/hist/c1.jsonl"
_cycle_emit() { :; }
_cycle_record_iter_outcome "$H" 1 pass complete 0
_ts="$(command jq -r '.ts' "$H" 2>/dev/null)"
near "$_ts" || _bad+="history=[$_ts] "
assert_eq "[T1] none of them starts date" "0" "$(dates)"
assert_eq "[T2] each stamps now, in date -u's form" "" "$_bad"

print_test_section "T3: stage-io records"
# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
_sio_fns="$(grep -n 'ts="$(date -u' "$REPO_ROOT/core/output/stage-io.sh" | wc -l | tr -d ' ')"
assert_eq "[T3] stage-io asks date for no record's time" "0" "$_sio_fns"

print_test_section "T4: loading a library"
_LIBS=(core/event-bus/event-bus.sh scripts/lib/helpers.sh core/pipeline/input-resolve.sh
       core/event-bus/known-types.sh scripts/lib/manifest-graph.sh scripts/lib/merge-base.sh
       scripts/lib/prompt-overrides.sh scripts/lib/stage-previous-work.sh scripts/lib/stage-prompt.sh
       core/pipeline/verdict.sh core/plugin-registry/lifecycle.sh core/plugin-registry/manifest-validation.sh
       core/plugin-registry/registry.sh core/pipeline/write-boundary.sh core/memory/contract.sh
       core/pipeline/cycle-orchestrator.sh core/state/atomic.sh core/pipeline/runner.sh)
_loaded=""
for _l in "${_LIBS[@]}"; do
    [[ -f "$REPO_ROOT/$_l" ]] || { _loaded+="missing:$_l "; continue; }
    : > "$CALLS"
    REPO_ROOT="$REPO_ROOT" L="$_l" C="$CALLS" bash -c '
        dirname() { printf "dirname\n" >> "$C"; command dirname "$@"; }
        source "$REPO_ROOT/$L" >/dev/null 2>&1' 2>/dev/null
    _n="$(grep -c '^dirname$' "$CALLS" 2>/dev/null)"
    [[ "$_n" == 0 ]] || _loaded+="$_l=${_n:-?} "
done
assert_eq "[T4] none starts dirname when loaded" "" "$_loaded"

print_test_section "T5: loaded by a bare name"
_t5="$(cd "$REPO_ROOT/core/pipeline" && bash -c 'source verdict.sh >/dev/null 2>&1
    declare -F contract_version_supported >/dev/null && declare -F eb_emit_event >/dev/null && printf ok' 2>/dev/null)"
assert_eq "[T5] verdict.sh, loaded as 'verdict.sh', loads its siblings" "ok" "$_t5"
_t5="$(cd "$REPO_ROOT/core/plugin-registry" && bash -c 'source lifecycle.sh >/dev/null 2>&1
    declare -F _registry_output_path_rows >/dev/null && printf ok' 2>/dev/null)"
assert_eq "[T5] lifecycle.sh, loaded as 'lifecycle.sh', loads its siblings" "ok" "$_t5"
unset -f date

print_test_section "T6: per-round helpers"
dirname() { printf 'dirname\n' >> "$CALLS"; command dirname "$@"; }
: > "$CALLS"
H6="$TEST_TEMP_DIR/t6/hist/c1.jsonl"
_cycle_record_iter_outcome "$H6" 1 pass complete 0
SF6="$TEST_TEMP_DIR/t6/state/pipeline-state.json"; mkdir -p "${SF6%/*}/artifacts"
printf '{"stage_statuses":{}}\n' > "$SF6"
_CYCLE_TRAP_CYCLE_ID="" _cycle_write_round_summary "$SF6" 1 '{}'
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
_summaries_collect "$SF6" "$TEST_TEMP_DIR/plugins" >/dev/null
unset -f dirname
assert_eq "[T6] none of the three starts dirname" "0" "$(grep -c '^dirname$' "$CALLS" 2>/dev/null)"
assert_file_exists "[T6] the history row is in its folder, made for it" "$H6"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
